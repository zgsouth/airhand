//! 模拟一台被控端（开发调试用）：彩色的测试画面（OpenH264 编码，跟着控制端发来的鼠标画一个十字），
//! 在电脑上测试 iOS 控制端（模拟器）不需要真的屏幕采集。走和 iPhone 被控端完全一样的网络代码（`airhand_mobile::host`）。
//!
//! ```text
//! cargo run --release --example fake_host -- [--server 127.0.0.1:4433] [--secs 600] [--state fake_host.json]
//! ```
//!
//! `--state`：把控制码、配对状态和身份存进这个文件，下次启动时取回同一个控制码（测“对方上线后自动连接”）
//!
//! 打印控制码和配对码；收到的输入事件、剪贴板、连上来的控制端也都打印出来。

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use airhand_mobile::host::{Host, HostConfig};
use openh264::OpenH264API;
use openh264::encoder::{
    BitRate, Encoder, EncoderConfig, FrameRate, FrameType, IntraFramePeriod, RateControlMode,
    UsageType,
};
use openh264::formats::YUVSource;

struct I420 {
    w: usize,
    h: usize,
    y: Vec<u8>,
    u: Vec<u8>,
    v: Vec<u8>,
}

impl YUVSource for I420 {
    fn dimensions(&self) -> (usize, usize) {
        (self.w, self.h)
    }
    fn strides(&self) -> (usize, usize, usize) {
        (self.w, self.w / 2, self.w / 2)
    }
    fn y(&self) -> &[u8] {
        &self.y
    }
    fn u(&self) -> &[u8] {
        &self.u
    }
    fn v(&self) -> &[u8] {
        &self.v
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut server = "127.0.0.1:4433".to_string();
    let mut secs = 600u64;
    let mut state: Option<String> = None;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--server" => server = args.next().expect("--server host:port"),
            "--secs" => secs = args.next().and_then(|s| s.parse().ok()).expect("--secs N"),
            "--state" => state = Some(args.next().expect("--state file")),
            _ => panic!("unknown argument {a}"),
        }
    }
    unsafe { airhand_ios::ah_init(c"info,quinn=warn".as_ptr(), None) };
    let (w, h) = (1280usize, 720usize);
    let saved: serde_json::Value = state
        .as_ref()
        .and_then(|f| std::fs::read_to_string(f).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| serde_json::json!({}));
    let saved = Arc::new(Mutex::new(saved));
    let cfg: HostConfig = serde_json::from_value(serde_json::json!({
        "server": server, "fingerprint": "", "name": "Fake PC", "os": "Windows 11 (fake)",
        "version": "0.4.0", "reclaim": saved.lock().unwrap().get("reclaim").cloned().unwrap_or_default(),
        "pairing": saved.lock().unwrap().get("pairing").cloned().unwrap_or_default(),
        "identity": saved.lock().unwrap().get("identity").cloned().unwrap_or_default(),
        "displays": [{"index":0,"name":"Fake","x":0,"y":0,"width":w,"height":h,"primary":true}],
        "codecs": ["h264"], "input": true, "touch": false, "actions": [], "platform": "windows"
    }))
    .unwrap();
    let host = Host::start(cfg).expect("host");

    // 鼠标位置（控制端发来的绝对坐标，0..1 × 10000）
    let mouse = Arc::new((AtomicU32::new(5000), AtomicU32::new(5000)));
    let settings = Arc::new(Mutex::new((30u8, 4000u32, false)));
    {
        let host = host.clone();
        let mouse = mouse.clone();
        let saved = saved.clone();
        let save = move |key: &str, v: serde_json::Value| {
            let mut s = saved.lock().unwrap();
            s[key] = v;
            if let Some(f) = &state {
                let _ = std::fs::write(f, s.to_string());
            }
        };
        std::thread::spawn(move || loop {
            let Some(e) = host.poll_event(Duration::from_millis(500)) else {
                continue;
            };
            let v: serde_json::Value = serde_json::from_str(&e).unwrap();
            match v["type"].as_str() {
                Some("registered") => {
                    println!("\n=== control code {} ===\n", v["code"].as_u64().unwrap_or(0));
                    save("reclaim", serde_json::json!({ "code": v["code"], "secret": v["secret"] }));
                }
                Some("pairing") => {
                    println!("=== pairing code {} ===", v["state"]["code"]);
                    save("pairing", v["state"].clone());
                }
                Some("identity") => save("identity", v["key"].clone()),
                Some("input") => {
                    for ev in v["events"].as_array().unwrap() {
                        if ev["type"] == "mouseMove" {
                            mouse.0.store((ev["x"].as_f64().unwrap() * 10000.0) as u32, Ordering::Relaxed);
                            mouse.1.store((ev["y"].as_f64().unwrap() * 10000.0) as u32, Ordering::Relaxed);
                        } else {
                            println!("input {ev}");
                        }
                    }
                }
                _ => println!("event {e}"),
            }
        });
    }

    let mut enc: Option<(Encoder, u32)> = None;
    let mut yuv = I420 {
        w,
        h,
        y: vec![0; w * h],
        u: vec![128; w * h / 4],
        v: vec![128; w * h / 4],
    };
    let start = Instant::now();
    let mut n = 0u64;
    let mut force_key = false;
    while start.elapsed() < Duration::from_secs(secs) {
        if let Some(t) = host.video_hub().tick() {
            let mut s = settings.lock().unwrap();
            *s = (t.fps.max(1), t.kbps.max(300), t.key);
            force_key |= t.key;
        }
        let (fps, kbps, _) = *settings.lock().unwrap();
        let frame_start = Instant::now();
        if !host.video_hub().wait_window(Duration::from_millis(100)) {
            continue;
        }
        if enc.as_ref().is_none_or(|(_, k)| (*k as f32 - kbps as f32).abs() / kbps as f32 > 0.2) {
            let cfg = EncoderConfig::new()
                .usage_type(UsageType::ScreenContentRealTime)
                .rate_control_mode(RateControlMode::Bitrate)
                .bitrate(BitRate::from_bps(kbps * 1000))
                .max_frame_rate(FrameRate::from_hz(fps as f32))
                .skip_frames(false)
                .intra_frame_period(IntraFramePeriod::from_num_frames(0));
            enc = Some((Encoder::with_api_config(OpenH264API::from_source(), cfg).unwrap(), kbps));
            force_key = true;
        }
        draw(&mut yuv, n, &mouse);
        let (e, _) = enc.as_mut().unwrap();
        if std::mem::take(&mut force_key) {
            e.force_intra_frame();
        }
        let bs = e.encode(&yuv).unwrap();
        let ft = bs.frame_type();
        if !matches!(ft, FrameType::Skip | FrameType::Invalid) {
            let data = bs.to_vec();
            let us = start.elapsed().as_micros() as u64;
            host.video_hub().push(
                &data,
                matches!(ft, FrameType::IDR | FrameType::I),
                false,
                us,
                airhand_proto::session::Codec::H264,
                w as u16,
                h as u16,
            );
        }
        n += 1;
        let period = Duration::from_secs_f64(1.0 / fps as f64);
        if let Some(rest) = period.checked_sub(frame_start.elapsed()) {
            std::thread::sleep(rest);
        }
    }
}

/// 移动的彩色条纹 + 跟着鼠标的十字 + 左上角的走动方块（看得出卡没卡）
fn draw(f: &mut I420, n: u64, mouse: &(AtomicU32, AtomicU32)) {
    let (w, h) = (f.w, f.h);
    for y in 0..h {
        for x in 0..w {
            let band = ((x + n as usize * 4) / 80) % 6;
            f.y[y * w + x] = 60 + (band as u8) * 25 + ((y * 40 / h) as u8);
        }
    }
    for y in 0..h / 2 {
        for x in 0..w / 2 {
            let band = ((x * 2 + n as usize * 4) / 80) % 6;
            f.u[y * (w / 2) + x] = [90, 160, 200, 60, 120, 180][band];
            f.v[y * (w / 2) + x] = [200, 90, 120, 160, 60, 140][band];
        }
    }
    let bx = (n as usize * 8) % (w - 40);
    for y in 20..60 {
        for x in bx..bx + 40 {
            f.y[y * w + x] = 235;
        }
    }
    let mx = (mouse.0.load(Ordering::Relaxed) as usize * (w - 1) / 10000).min(w - 1);
    let my = (mouse.1.load(Ordering::Relaxed) as usize * (h - 1) / 10000).min(h - 1);
    for x in mx.saturating_sub(30)..(mx + 30).min(w) {
        f.y[my * w + x] = 16;
    }
    for y in my.saturating_sub(30)..(my + 30).min(h) {
        f.y[y * w + mx] = 16;
    }
}
