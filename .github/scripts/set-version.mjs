// 把发布版本（来自 git tag）写进各端的清单文件，只在 CI 的检出目录里改，不提交。
//
//   node .github/scripts/set-version.mjs 0.4.0-rc.1
//
// 版本号只能是 X.Y.Z 或 X.Y.Z-rc.N：Android 的 versionCode 由它算出（见 android/app/build.gradle.kts 的 appVersionCode）。
// iOS 只写数字部分：CFBundleShortVersionString 必须是 X.Y.Z；其余各端写完整版本（含 -rc.N）。
import { readFileSync, writeFileSync } from "node:fs";

const version = process.argv[2] ?? "";
const m = /^(\d+)\.(\d+)\.(\d+)(?:-rc\.\d+)?$/.exec(version);
if (!m) {
  console.error(`expected X.Y.Z or X.Y.Z-rc.N (e.g. 0.4.0, 0.4.0-rc.1), got "${version}"`);
  process.exit(1);
}
const base = `${m[1]}.${m[2]}.${m[3]}`;
const root = new URL("../../", import.meta.url);

// [文件, 匹配（第 2 组是旧版本号）, 新版本号]；都只替换第一处
const targets = [
  // 桌面版：安装包文件名、程序里显示的版本
  ["client/src-tauri/tauri.conf.json", /("version"\s*:\s*")([^"]*)(")/, version],
  // 桌面版 Rust（config.rs 的 VERSION = CARGO_PKG_VERSION）
  ["client/src-tauri/Cargo.toml", /^(version\s*=\s*")([^"]*)(")/m, version],
  // Android：versionName 和 APK 文件名
  ["android/app/build.gradle.kts", /^(val appVersion\s*=\s*")([^"]*)(")/m, version],
  ["android/native/Cargo.toml", /^(version\s*=\s*")([^"]*)(")/m, version],
  // iOS
  ["ios/native/Cargo.toml", /^(version\s*=\s*")([^"]*)(")/m, version],
  ["ios/project.yml", /^(\s*MARKETING_VERSION:\s*")([^"]*)(")/m, base],
];

for (const [file, pattern, value] of targets) {
  const url = new URL(file, root);
  const text = readFileSync(url, "utf8");
  const found = pattern.exec(text);
  if (!found) {
    console.error(`${file}: version field not found`);
    process.exit(1);
  }
  writeFileSync(url, text.replace(pattern, (_, pre, _old, post) => pre + value + post));
  console.log(`${file}: ${found[2]} -> ${value}`);
}
