import SwiftUI
import UIKit

/// “账号”那一块（首页里，在“我的设备”上面）。
///
/// 没登录：一张卡片，填用户名 / 密码登录。登录之后同账号的设备直接列出来，点一下就连，
/// 配对码连接时才向服务器要（平时不留在本机）。
struct AccountSection: View {
    @Bindable var app: AppModel

    @State private var user = ""
    @State private var password = ""
    @State private var base = ""
    @State private var showBase = false
    @FocusState private var focus: Field?

    private enum Field { case user, password, base }

    private var account: Account { app.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if account.signedIn { signedIn } else { signInForm }
        }
        .onAppear {
            if base.isEmpty { base = account.base.isEmpty ? BuildDefaults.accountAPI : account.base }
        }
    }

    // ── 没登录：登录卡片 ──

    private var canSubmit: Bool {
        !user.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !account.busy
    }

    private var signInForm: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L.t("account_title"), systemImage: "person.crop.circle")
                        .font(.headline).foregroundStyle(Theme.text)
                    Text(L.t("account_subtitle")).font(.subheadline).foregroundStyle(Theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }

                field(icon: "person", placeholder: L.t("account_user"), text: $user, field: .user,
                      content: .username, submit: .next) { focus = .password }
                field(icon: "lock", placeholder: L.t("account_password"), text: $password, field: .password,
                      content: .password, secure: true, submit: .go) { submit() }

                if let e = account.error {
                    Label(e, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote).foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if account.busy { ProgressView().tint(.white) }
                        Text(account.busy ? L.t("account_signing_in") : L.t("account_sign_in"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: canSubmit))
                .disabled(!canSubmit)

                serverField
            }
        }
    }

    /// 服务器地址：平时收起来只显示现在连的是哪个，点一下才展开
    private var serverField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showBase {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack").font(.footnote).foregroundStyle(Theme.faint)
                    TextField("http://192.168.110.176:8080", text: $base)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .base)
                        .submitLabel(.done)
                        .onSubmit { focus = nil }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
                Text(L.t("account_server_hint")).font(.caption2).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    showBase = true
                    focus = .base
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack").font(.caption2)
                        Text(L.t("account_server")).font(.caption)
                        Text(base.isEmpty ? "—" : base).font(.caption.monospaced()).lineLimit(1)
                    }
                    .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func field(
        icon: String, placeholder: String, text: Binding<String>, field: Field,
        content: UITextContentType, secure: Bool = false, submit: SubmitLabel,
        onSubmit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.footnote).foregroundStyle(Theme.faint).frame(width: 18)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.text)
            .textContentType(content)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: field)
            .submitLabel(submit)
            .onSubmit(onSubmit)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        let name = user.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = await account.signIn(user: name, password: password, base: base)
            if ok {
                password = ""
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                focus = .password
            }
        }
    }

    // ── 登录之后：账号设备 ──

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle(text: L.t("account_devices"))
                Spacer(minLength: 0)
                if account.busy {
                    ProgressView().controlSize(.mini).tint(Theme.c3)
                }
                Button {
                    Task { await account.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.sub)
                Text(account.user).font(.caption).foregroundStyle(Theme.faint).lineLimit(1)
                Menu {
                    Button(role: .destructive) { account.signOut() } label: {
                        Label(L.t("account_sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 4)

            if let e = account.error {
                Label(e, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if account.devices.isEmpty {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.slash").font(.title2).foregroundStyle(Theme.faint)
                        Text(account.loaded ? L.t("account_devices_empty") : L.t("account_loading"))
                            .font(.subheadline).foregroundStyle(Theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ForEach(account.devices) { d in
                    AccountDeviceRow(app: app, device: d)
                }
            }

            // 本机登记不上（没在共享本机）时说明原因，不然用户会奇怪为什么这台手机不在列表里
            if case .cannot(let reason) = account.selfState {
                Label(reason, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 账号设备的一行
private struct AccountDeviceRow: View {
    @Bindable var app: AppModel
    let device: AccountDevice

    private var connecting: Bool { app.connectingCode == Code.parse(device.code) }
    private var session: RemoteSession? { app.session?.code == device.code ? app.session : nil }

    private var waiting: Bool {
        if case .waitingHost = session?.phase { return true }
        return false
    }

    var body: some View {
        Button {
            guard !waiting else { return }
            Task {
                // 配对码按需向服务器要：拿不到就照常连，对方要求时手机会弹配对码输入
                let pairing = await app.account.credential(device.uuid)
                app.connect(code: device.code, pairing: pairing)
            }
        } label: {
            HStack(spacing: 14) {
                DeviceIcon(os: .unknown, size: 40)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(device.online ? Theme.good : Theme.faint)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name.isEmpty ? Code.format(device.code) : device.name)
                        .font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    if waiting {
                        Text(L.t("device_waiting")).font(.caption).foregroundStyle(Theme.warn)
                    } else {
                        Text([Code.format(device.code), device.online ? L.t("account_online") : L.t("account_offline")]
                            .joined(separator: " · "))
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
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(device.online ? Theme.good.opacity(0.28) : Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}
