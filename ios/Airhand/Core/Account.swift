import Foundation
import Observation

/// 服务器上的一台设备（account-api 的 /device/list；配对码不在里面）
struct AccountDevice: Equatable, Identifiable {
    var uuid: String
    var name: String
    /// 6 位控制码
    var code: String
    var online: Bool
    /// 最后一次心跳（Unix 毫秒）
    var lastSeen: Double

    var id: String { uuid }
}

/// account-api 的错：`kind` 给界面挑一句人话（见 [Account.message]）
enum AccountError: Error {
    case noServer
    case network(String)
    case unauthorized
    case notFound
    case server(Int)
}

/// 登录状态（存 account.json）：服务器地址、token、用户名、本机的 uuid
struct AccountLogin: Codable, Equatable {
    var base: String = ""
    var token: String = ""
    var user: String = ""
    /// 本机在账号服务里的 id：只是主键，不是密钥
    var uuid: String = ""

    var signedIn: Bool { !token.isEmpty && !base.isEmpty }
}

/**
 account-api 的客户端（见 account-api/README.md）。

 用 URLSession：这几个接口很简单，不用再引三方库。所有方法都是 async 的，
 失败一律抛 [AccountError]，由 [Account] 翻成界面上的文案。
 */
enum AccountAPI {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        c.waitsForConnectivity = false
        // token 在请求头里，不经过 cookie
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }()

    static func login(base: String, user: String, password: String) async throws -> String {
        let body: JSON = ["username": user, "password": password]
        let r = try await call(base, "/auth/login", method: "POST", body: body, token: nil)
        guard let token = (r as? JSON)?["token"] as? String, !token.isEmpty else {
            throw AccountError.server(200)
        }
        return token
    }

    static func devices(base: String, token: String) async throws -> [AccountDevice] {
        let r = try await call(base, "/device/list", token: token)
        guard let list = r as? [Any] else { return [] }
        return list.compactMap { item in
            guard let o = item as? JSON else { return nil }
            return AccountDevice(
                uuid: o.str("device_uuid") ?? "",
                name: o.str("device_name") ?? "",
                code: o.str("control_code") ?? "",
                online: o.bool("online"),
                lastSeen: o.dbl("last_seen") ?? 0
            )
        }
        .filter { !$0.uuid.isEmpty }
    }

    /// 把本机登记到账号。配对码在服务器上加密保存，只有 /device/credential 取得回来
    static func register(base: String, token: String, uuid: String, name: String, code: String, pairing: String) async throws {
        let body: JSON = ["device_uuid": uuid, "device_name": name, "control_code": code, "pairing_code": pairing]
        _ = try await call(base, "/device/register", method: "POST", body: body, token: token)
    }

    /// 取某台设备的配对码：连接时才取，平时不留在本机
    static func credential(base: String, token: String, uuid: String) async throws -> String? {
        let path = "/device/credential?device_uuid=" + (uuid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uuid)
        let r = try await call(base, path, token: token)
        let code = (r as? JSON)?.str("pairing_code")
        return (code?.isEmpty == false) ? code : nil
    }

    /// 发一个请求，返回解析好的 JSON（204 返回 nil）
    private static func call(
        _ base: String,
        _ path: String,
        method: String = "GET",
        body: JSON? = nil,
        token: String?
    ) async throws -> Any? {
        let root = base.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !root.isEmpty else { throw AccountError.noServer }
        guard let url = URL(string: root + path) else { throw AccountError.network("bad url: \(root + path)") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Json.string(body).data(using: .utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // 服务器没开、IP 写错、明文 HTTP 被 ATS 拦下（Info.plist 没开 NSAllowsLocalNetworking）都到这儿
            throw AccountError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 401: throw AccountError.unauthorized
        case 404: throw AccountError.notFound
        case 200..<300: break
        default: throw AccountError.server(status)
        }
        if status == 204 || data.isEmpty { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/**
 账号：登录、同账号的设备列表、把本机登记到账号。

 和"我的设备"（[DeviceStore]）的分工：我的设备存在本机，只有这台设备知道；
 账号设备存在服务器上，同一账号的每台设备都能看到、点一下就能连。

 登录之后每 [syncSeconds] 做一次：把本机登记上去（顺便刷新 last_seen）+ 拉一次列表。
 */
@Observable
final class Account {
    private(set) var login: AccountLogin

    var devices: [AccountDevice] = []
    var busy = false
    /// 至少拉过一次列表（决定要不要显示"还没有设备"）
    var loaded = false
    var error: String?
    /// 本机在账号里的登记情况
    var selfState: SelfState = .unknown

    /// 本机登记不上账号的原因（没在共享本机之类），已经是给人看的文案
    enum SelfState: Equatable {
        case unknown
        case registered
        case cannot(String)
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let file = "account.json"

    /// 多久同步一次：够快看到别的设备上线，又不至于一直发请求
    static let syncSeconds: TimeInterval = 45

    init() {
        login = SharedStore.read(file, as: AccountLogin.self) ?? AccountLogin()
        if login.base.isEmpty { login.base = BuildDefaults.accountAPI }
    }

    var signedIn: Bool { login.signedIn }
    var base: String { login.base }
    var user: String { login.user }

    // ───────────────────────────── 登录 / 退出 ─────────────────────────────

    /// 登录。成功之后 [startSync] 自动开始；失败时 [error] 里是给人看的原因
    @discardableResult
    func signIn(user name: String, password: String, base raw: String) async -> Bool {
        let url = Account.normalize(raw)
        useBase(url)
        busy = true
        error = nil
        do {
            let token = try await AccountAPI.login(base: url, user: name.trimmingCharacters(in: .whitespaces), password: password)
            var l = login
            l.base = url
            l.token = token
            l.user = name.trimmingCharacters(in: .whitespaces)
            if l.uuid.isEmpty { l.uuid = UUID().uuidString }
            login = l
            save()
            devices = []
            loaded = false
            busy = false
            startSync()
            return true
        } catch {
            busy = false
            self.error = message(error)
            return false
        }
    }

    /// 退出登录：删掉 token，回到未登录状态（本机的"我的设备"不动）
    func signOut() {
        stopSync()
        login.token = ""
        login.user = ""
        save()
        devices = []
        loaded = false
        error = nil
        selfState = .unknown
    }

    /// 换服务器地址（登录页里改的）：换地址要重新登录
    func useBase(_ raw: String) {
        let url = Account.normalize(raw)
        guard url != login.base else { return }
        stopSync()
        login.base = url
        login.token = ""
        login.user = ""
        save()
        devices = []
        loaded = false
        selfState = .unknown
    }

    // ───────────────────────────── 同步 ─────────────────────────────

    func startSync() {
        stopSync()
        guard login.signedIn else { return }
        Task { await tick() }
        let t = Timer.scheduledTimer(withTimeInterval: Account.syncSeconds, repeats: true) { [weak self] _ in
            Task { await self?.tick() }
        }
        // 滚动列表时不耽误计时
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopSync() {
        timer?.invalidate()
        timer = nil
    }

    /// 手动刷新（点刷新按钮）：只重拉列表
    func refresh() async {
        guard login.signedIn else { return }
        await pullDevices()
    }

    private func tick() async {
        guard login.signedIn else {
            stopSync()
            return
        }
        await registerSelf()
        await pullDevices()
    }

    private func pullDevices() async {
        let l = login
        guard l.signedIn else { return }
        busy = true
        do {
            let list = try await AccountAPI.devices(base: l.base, token: l.token)
            devices = list
            loaded = true
            busy = false
            error = nil
        } catch AccountError.unauthorized {
            // token 不管用了（服务器换了 TOKEN_SECRET？）：回未登录
            signOut()
            error = L.t("account_error_auth")
            busy = false
        } catch {
            busy = false
            loaded = true
            self.error = message(error)
        }
    }

    /// 把本机登记到账号。
    ///
    /// 控制码用服务器分配的（[SavedHostCode]）：手机没在共享本机时用上次存下的那个，
    /// 这样别的设备照样看得到这台手机、只是显示离线，点一下会等它上线（AirHand 本来就有这个流程）。
    private func registerSelf() async {
        let l = login
        guard l.signedIn else { return }
        guard let code = Self.hostCode() else {
            selfState = .cannot(L.t("account_self_no_host"))
            return
        }
        guard let pairing = Self.pairingCode() else {
            selfState = .cannot(L.t("account_self_no_pairing"))
            return
        }
        do {
            if l.uuid.isEmpty {
                login.uuid = UUID().uuidString
                save()
            }
            try await AccountAPI.register(base: l.base, token: l.token, uuid: login.uuid,
                                         name: AppModel.deviceName(AppModel.shared.settings), code: code, pairing: pairing)
            selfState = .registered
        } catch AccountError.unauthorized {
            signOut()
            error = L.t("account_error_auth")
        } catch {
            selfState = .cannot(message(error))
        }
    }

    /// 连账号设备时按需取配对码：取不到就让界面照常连（对方可能要求手动输配对码）
    func credential(_ uuid: String) async -> String? {
        let l = login
        guard l.signedIn else { return nil }
        return try? await AccountAPI.credential(base: l.base, token: l.token, uuid: uuid)
    }

    // ───────────────────────────── 本机身份 ─────────────────────────────

    /// 本机的控制码：正在共享时以扩展写下的为准，否则用上次保存的
    static func hostCode() -> String? {
        if let live = HostLive.load(), live.isLive, let c = live.code { return String(format: "%06d", c) }
        if let saved = SavedHostCode.load() { return String(format: "%06d", saved.code) }
        return nil
    }

    /// 本机的配对码：共享时扩展会写下当前的那个；没在共享时用 pairing.json 里存着的
    static func pairingCode() -> String? {
        if let live = HostLive.load(), live.isLive, let c = live.pairingCode, !c.isEmpty { return c }
        if let c = PairingFile.load()?.str("code"), !c.isEmpty, !c.allSatisfy({ $0 == "0" }) { return c }
        return nil
    }

    // ───────────────────────────── 工具 ─────────────────────────────

    private static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func save() { SharedStore.write(file, login) }

    /// 把 [AccountError] 翻成界面上的文案
    private func message(_ e: Error) -> String {
        switch e {
        case AccountError.noServer: return L.t("account_error_no_server")
        case AccountError.unauthorized: return L.t("account_error_auth")
        case AccountError.notFound: return L.t("account_error_not_found")
        case AccountError.server(let code): return L.t("account_error_server", String(code))
        case AccountError.network: return L.t("account_error_network")
        default: return L.t("account_error_network")
        }
    }
}
