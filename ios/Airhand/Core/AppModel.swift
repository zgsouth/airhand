import Foundation
import Observation
import UIKit

/// 整个应用的状态：设置、我的设备、与服务器的连接、当前的远程会话、本机的共享状态
@Observable
final class AppModel {
    static let shared = AppModel()

    var settings: AppSettings {
        didSet { if settings != oldValue { settings.save() } }
    }

    let devices = DeviceStore()
    let games = GameStore()
    /// 账号（account-api）：登录状态、同账号的设备列表
    let account = Account()
    @ObservationIgnored private(set) var controller: ControllerClient!

    /// 当前的远程会话（同一时间一个，和 Android 一样）
    var session: RemoteSession?
    /// 远程画面全屏显示着
    var showingSession = false {
        didSet {
            session?.setHidden(!showingSession)
            // 在这里推出 / 收回远程画面，不能靠 SwiftUI 的 onChange：远程画面是 .fullScreen 弹出的，
            // 下面的 SwiftUI 视图被移出窗口、不再更新，回到首页和断开时 onChange 不会触发。
            // 放到下一轮：session 和 showingSession 都改完了再同步
            DispatchQueue.main.async { [self] in SessionPresenter.sync(self) }
        }
    }
    /// 首页正在连接的控制码（按钮上转圈），以及连接失败的原因
    var connectingCode: String?
    var connectError: String?
    /// 对方要求配对码：弹出对话框
    var pairingFor: PairingRequest?
    /// 广播扩展的实时状态
    var hostLive: HostLive?
    var toast: Toast?
    var tab: Tab = .connect

    enum Tab: Hashable { case connect, share, settings }

    struct PairingRequest: Identifiable {
        var code: String
        var problem: Problem
        var id: String { code + problem.kind }
    }

    struct Toast: Equatable, Identifiable {
        var text: String
        var action: String? = nil
        var id = UUID()
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    @ObservationIgnored var toastAction: (() -> Void)?
    @ObservationIgnored private var phaseWatch: Timer?

    private init() {
        settings = AppSettings.load()
        controller = ControllerClient(settings: { AppModel.shared.settings }, learnTrust: { server, fp in
            AppModel.shared.settings.trustServer = server
            AppModel.shared.settings.trustFp = fp
        })
        hostLive = HostLive.load()
        IPC.observe(IPC.hostLive) { [weak self] in self?.hostLive = HostLive.load() }
        // 上次登录过：启动就开始同步（本机登记 + 同账号的设备列表）
        if account.signedIn { account.startSync() }
        // 扩展被系统停掉时来不及说：隔一会儿看一下状态是不是太旧了
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let live = HostLive.load()
            if live != self.hostLive { self.hostLive = live }
        }
    }

    static func deviceName(_ s: AppSettings) -> String {
        let n = s.deviceName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? UIDevice.current.name : n
    }

    static var osName: String {
        let d = UIDevice.current
        let name = d.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        return "\(name) \(d.systemVersion)"
    }

    static var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0" }

    func show(_ text: String, action: String? = nil, _ f: (() -> Void)? = nil) {
        toastAction = f
        toast = Toast(text: text, action: action)
    }

    // ───────────────────────────── 远程会话 ─────────────────────────────

    /// 连接一台设备（首页输入的控制码、我的设备、配对码对话框）。连接过程留在首页，连上了才进入远程画面
    func connect(code: String, pairing: String? = nil, forgetKey: Bool = false) {
        if let s = session {
            if s.code == code, pairing == nil, s.phase.isActive {
                if s.phase == .live { showingSession = true }
                return
            }
            s.close()
            session = nil
        }
        let saved = devices.get(code)
        let s = RemoteSession(app: self, code: code, resume: saved?.resume.isEmpty == false ? saved?.resume : nil,
                              hostKey: forgetKey ? nil : saved?.hostKey, pairing: pairing)
        session = s
        connectingCode = code
        connectError = nil
        s.onPhase = { [weak self, weak s] phase in
            guard let self, let s, self.session === s else { return }
            self.onPhase(s, phase)
        }
        s.start()
    }

    private func onPhase(_ s: RemoteSession, _ phase: RemoteSession.Phase) {
        switch phase {
        case .live:
            connectingCode = nil
            showingSession = true
        case .waitingHost:
            // 我的设备里的设备不在线：等它上线（卡片上显示“对方不在线 · 上线后自动连接”）
            connectingCode = nil
        case .failed(let p):
            connectingCode = nil
            session = nil
            showingSession = false
            if p.needsPairing {
                pairingFor = PairingRequest(code: s.code, problem: p)
            } else {
                connectError = Messages.problem(p)
            }
        case .ended(let p):
            if !showingSession {
                session = nil
                connectError = Messages.problem(p)
            }
        case .closed:
            if session === s { session = nil }
            connectingCode = nil
        default: break
        }
    }

    /// 关掉当前会话（断开、取消等待）
    func closeSession() {
        session?.close()
        session = nil
        showingSession = false
        connectingCode = nil
    }

    /// 链接：`airhand://connect/123456?pairing=654321`（分享控制码时可以发这样的链接，点一下就连）
    func open(_ url: URL) {
        guard url.scheme == "airhand", url.host == "connect" || url.host == "c" else { return }
        let code = Code.parse(url.lastPathComponent) ?? Code.find(url.absoluteString)
        guard let code else { return }
        let pairing = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pairing" }?.value
            .flatMap { $0.count == 6 && $0.allSatisfy(\.isNumber) ? $0 : nil }
        tab = .connect
        connect(code: code, pairing: pairing)
    }

    // ───────────────────────────── 共享本机 ─────────────────────────────

    var sharing: Bool { hostLive?.isLive == true }

    /// 更换控制码（没在共享时：下次共享时分配新的；配对码也换一个、配对过的全部忘掉）
    func newHostCode() {
        if sharing {
            HostCommand.send("newCode")
        } else {
            SavedHostCode.clear()
            PairingFile.reset()
            show(L.t("settings_code_reset"))
        }
    }

    func forgetPaired() {
        if sharing { HostCommand.send("forgetPaired") } else { PairingFile.forgetPaired() }
    }
}
