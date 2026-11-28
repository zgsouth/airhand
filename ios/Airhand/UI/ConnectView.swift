import SwiftUI
import UIKit

/// 首页（远程）：输入 6 位控制码，或者从“我的设备”里点一下就连
struct ConnectView: View {
    @Bindable var app: AppModel
    @State private var digits = ""
    @FocusState private var focused: Bool
    @State private var renaming: SavedDevice?
    @State private var newName = ""
    @State private var deleting: SavedDevice?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if app.settings.server.trimmingCharacters(in: .whitespaces).isEmpty {
                        setupCard
                    }
                    if let s = app.session, s.phase == .live, !app.showingSession {
                        liveCard(s)
                    }
                    codeCard
                    AccountSection(app: app)
                    devices
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .alert(L.t("rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L.t("device_name_placeholder"), text: $newName)
            Button(L.t("save")) {
                if let d = renaming { app.devices.rename(d.code, to: newName) }
                renaming = nil
            }
            Button(L.t("cancel"), role: .cancel) { renaming = nil }
        }
        .confirmationDialog(L.t("device_delete_title"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { d in
            Button(L.t("delete"), role: .destructive) { delete(d) }
        } message: { d in
            Text(L.t("device_delete_text", d.title))
        }
    }

    private var background: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.c1.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
            RadialGradient(colors: [Theme.c3.opacity(0.16), .clear], center: .topTrailing, startRadius: 0, endRadius: 360)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Image("Logo").resizable().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("Airhand").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            }
            Spacer()
            ServerPill(app: app)
        }
        .padding(.top, 12)
    }

    private var setupCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(L.t("setup_server_title"), systemImage: "server.rack").font(.headline).foregroundStyle(Theme.text)
                Text(L.t("setup_server_body")).font(.subheadline).foregroundStyle(Theme.sub)
                Button(L.t("go_settings")) { app.tab = .settings }.buttonStyle(SecondaryButtonStyle(tint: Theme.c3))
            }
        }
    }

    private func liveCard(_ s: RemoteSession) -> some View {
        Button { app.showingSession = true } label: {
            HStack(spacing: 12) {
                DeviceIcon(os: s.os, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.hostName).font(.headline).foregroundStyle(.white)
                    Text(L.t("session_live_card")).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(.white)
            }
            .padding(14)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // ── 控制码 ──

    private var connecting: Bool { app.connectingCode != nil && app.connectingCode == Code.parse(digits) }

    private var codeCard: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("connect_title")).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                    Text(L.t("connect_hint")).font(.subheadline).foregroundStyle(Theme.sub)
                }
                CodeBoxes(digits: digits, focused: focused, error: app.connectError != nil)
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
                    .overlay {
                        TextField("", text: $digits)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focused)
                            .opacity(0.01)
                            .onChange(of: digits) { _, v in onDigits(v) }
                    }
                if let e = app.connectError {
                    Label(e, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote).foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                HStack(spacing: 10) {
                    PasteButton(payloadType: String.self) { strings in
                        guard let code = strings.lazy.compactMap({ Code.find($0) }).first else {
                            DispatchQueue.main.async { app.show(L.t("connect_no_code_in_clipboard")) }
                            return
                        }
                        DispatchQueue.main.async { digits = code }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .tint(Theme.cardHi)
                    Button {
                        if connecting { app.closeSession() } else { submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if connecting { ProgressView().tint(.white) }
                            Text(connecting ? L.t("connecting") : L.t("connect"))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(enabled: Code.parse(digits) != nil))
                    .disabled(Code.parse(digits) == nil)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.connectError)
    }

    private func onDigits(_ v: String) {
        let clean = String(v.filter { $0.isASCII && $0.isNumber }.prefix(6))
        if clean != v { digits = clean; return }
        if app.connectError != nil { app.connectError = nil }
        if clean.count == 6 { submit() }
    }

    private func submit() {
        guard let code = Code.parse(digits) else {
            if digits.count == 6 { app.connectError = L.t("problem_invalid_code") }
            return
        }
        focused = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        app.connect(code: code)
    }

    // ── 我的设备 ──

    private var devices: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: L.t("my_devices"))
            if app.devices.list.isEmpty {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles.tv").font(.title2).foregroundStyle(Theme.faint)
                        Text(L.t("my_devices_empty")).font(.subheadline).foregroundStyle(Theme.sub)
                    }
                }
            } else {
                ForEach(app.devices.list) { d in
                    DeviceRow(app: app, device: d)
                        .contextMenu {
                            Button { newName = d.title; renaming = d } label: { Label(L.t("rename"), systemImage: "pencil") }
                            Button {
                                UIPasteboard.general.string = Code.format(d.code)
                                app.show(L.t("copied"))
                            } label: { Label(L.t("copy_code"), systemImage: "doc.on.doc") }
                            Button(role: .destructive) { deleting = d } label: { Label(L.t("delete"), systemImage: "trash") }
                        }
                }
            }
        }
    }

    private func delete(_ d: SavedDevice) {
        if app.session?.code == d.code { app.closeSession() }
        app.devices.remove(d.code)
        app.show(L.t("device_deleted", d.title), action: L.t("undo")) { app.devices.restore(d) }
    }
}

/// 6 个数字格子
struct CodeBoxes: View {
    let digits: String
    let focused: Bool
    let error: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { i in
                let ch = i < digits.count ? String(digits[digits.index(digits.startIndex, offsetBy: i)]) : ""
                let active = focused && i == min(digits.count, 5)
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.cardHi)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(error ? Theme.bad.opacity(0.8) : (active ? Theme.c2 : Theme.stroke), lineWidth: active || error ? 2 : 1)
                    Text(ch).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
                    if active && ch.isEmpty {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.c3).frame(width: 2, height: 24)
                            .modifier(Blink())
                    }
                }
                .frame(height: 58)
                if i == 2 { Spacer().frame(width: 6) }
            }
        }
    }
}

private struct Blink: ViewModifier {
    @State private var on = true
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on = false }
        }
    }
}

/// 与服务器的连接状态
struct ServerPill: View {
    let app: AppModel

    var body: some View {
        switch app.controller.server {
        case .connected: StatusPill(color: Theme.good, text: L.t("server_online"))
        case .connecting: StatusPill(color: Theme.warn, text: L.t("server_connecting"), spinning: true)
        case .disconnected: StatusPill(color: Theme.bad, text: L.t("server_offline"))
        }
    }
}

/// “我的设备”里的一行
struct DeviceRow: View {
    let app: AppModel
    let device: SavedDevice

    private var session: RemoteSession? { app.session?.code == device.code ? app.session : nil }

    private var waiting: Bool {
        if case .waitingHost = session?.phase { return true }
        return false
    }

    private var connecting: Bool { app.connectingCode == device.code }

    var body: some View {
        Button {
            if waiting { return }
            app.connect(code: device.code)
        } label: {
            HStack(spacing: 14) {
                DeviceIcon(os: device.os)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    if waiting {
                        Text(L.t("device_waiting")).font(.caption).foregroundStyle(Theme.warn)
                    } else {
                        Text([Code.format(device.code), device.hostOs, relativeTime(device.lastConnected)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.sub).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if connecting {
                    ProgressView().tint(Theme.c3)
                } else if waiting {
                    Button(L.t("cancel")) { app.closeSession() }.buttonStyle(SecondaryButtonStyle(tint: Theme.sub))
                } else {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.faint)
                }
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(waiting ? Theme.warn.opacity(0.4) : Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

/// 输入配对码（对方要求配对、或者对方的身份变了）
struct PairingSheet: View {
    let app: AppModel
    let request: AppModel.PairingRequest
    @State private var code = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L.t("pairing_title")).font(.title2.weight(.bold)).foregroundStyle(Theme.text)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(Theme.faint) }
            }
            Label(Messages.problem(request.problem), systemImage: request.problem.kind == "hostKeyChanged" ? "exclamationmark.shield.fill" : "lock.shield.fill")
                .font(.subheadline)
                .foregroundStyle(request.problem.kind == "pairingRequired" ? Theme.sub : Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
            CodeBoxes(digits: code, focused: focused, error: false)
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
                .overlay {
                    TextField("", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).focused($focused).opacity(0.01)
                        .onChange(of: code) { _, v in
                            let c = String(v.filter { $0.isASCII && $0.isNumber }.prefix(6))
                            if c != v { code = c } else if c.count == 6 { submit() }
                        }
                }
            Text(L.t("pairing_hint")).font(.footnote).foregroundStyle(Theme.sub)
            Button(L.t("connect")) { submit() }
                .buttonStyle(PrimaryButtonStyle(enabled: code.count == 6))
                .disabled(code.count != 6)
            Spacer()
        }
        .padding(24)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { focused = true }
    }

    private func submit() {
        guard code.count == 6 else { return }
        dismiss()
        app.connect(code: request.code, pairing: code)
    }
}
