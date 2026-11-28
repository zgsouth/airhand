import Foundation

/// App 和屏幕广播扩展共用的存储：都在 App Group 的共享目录里（没有 App Group 时退回 App 自己的目录，
/// 例如没签名的调试构建；那样扩展读不到，共享本机就用不了）。只有这台设备上 Airhand 自己的两个进程能读，
/// 不备份，卸载应用时系统一并删除。
enum SharedStore {
    static let group: String = (Bundle.main.object(forInfoDictionaryKey: "AirhandAppGroup") as? String)
        .flatMap { $0.isEmpty ? nil : $0 } ?? "group.app.airhand.ios"

    static let dir: URL = {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Airhand", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        var u = d
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return d
    }()

    static var hasGroup: Bool { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil }

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func write<T: Encodable>(_ name: String, _ v: T) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        try? d.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func readRaw(_ name: String) -> JSON? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        return Json.parse(d)
    }

    static func writeRaw(_ name: String, _ o: Any) {
        try? Json.string(o).data(using: .utf8)?.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

    // ── 文件名 ──
    static let settingsFile = "settings.json"
    static let identityFile = "identity.json"
    /// 本机做被控端时分配到的控制码和取回它用的密钥
    static let hostCodeFile = "host.json"
    /// 配对码和配对过的控制端（Rust 的 PairingState，原样存、原样传回去）
    static let pairingFile = "pairing.json"
    /// 广播扩展的实时状态（扩展写、App 读）
    static let hostLiveFile = "host-live.json"
    /// App 发给广播扩展的命令
    static let hostCommandFile = "host-command.json"
}

/// 设置（App 和扩展都读；只有 App 写）
struct AppSettings: Codable, Equatable {
    var server: String = BuildDefaults.server
    var fingerprint: String = BuildDefaults.fingerprint
    /// 第一次连上服务器时记下的证书指纹（指纹留空时）
    var trustServer: String? = nil
    var trustFp: String? = nil
    var deviceName: String = ""
    var preset: String = Preset.default.rawValue
    /// 用户选的编码格式（空 = 自动）
    var codec: String = ""
    /// auto / trackpad / touch
    var touchMode: String = "auto"
    var audio: Bool = true
    var avSync: Bool = false
    var navKeys: Bool = true
    var localCursor: Bool = true
    var tipsShown: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        // 每一项都有默认值：以后加了新的设置，旧文件照样读得出
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        server = (try? c.decode(String.self, forKey: .server)) ?? d.server
        fingerprint = (try? c.decode(String.self, forKey: .fingerprint)) ?? d.fingerprint
        trustServer = try? c.decode(String.self, forKey: .trustServer)
        trustFp = try? c.decode(String.self, forKey: .trustFp)
        deviceName = (try? c.decode(String.self, forKey: .deviceName)) ?? d.deviceName
        preset = (try? c.decode(String.self, forKey: .preset)) ?? d.preset
        codec = (try? c.decode(String.self, forKey: .codec)) ?? d.codec
        touchMode = (try? c.decode(String.self, forKey: .touchMode)) ?? d.touchMode
        audio = (try? c.decode(Bool.self, forKey: .audio)) ?? d.audio
        avSync = (try? c.decode(Bool.self, forKey: .avSync)) ?? d.avSync
        navKeys = (try? c.decode(Bool.self, forKey: .navKeys)) ?? d.navKeys
        localCursor = (try? c.decode(Bool.self, forKey: .localCursor)) ?? d.localCursor
        tipsShown = (try? c.decode(Bool.self, forKey: .tipsShown)) ?? d.tipsShown
    }

    static func load() -> AppSettings { SharedStore.read(SharedStore.settingsFile, as: AppSettings.self) ?? AppSettings() }
    func save() { SharedStore.write(SharedStore.settingsFile, self) }

    /// 第一次连上服务器时记下的指纹（交给 Rust）
    var trustJson: Any {
        if let s = trustServer, let f = trustFp, fingerprint.trimmingCharacters(in: .whitespaces).isEmpty {
            return ["server": s, "fp": f]
        }
        return NSNull()
    }
}

/// 编译时写进 Info.plist 的默认服务器（AIRHAND_SERVER / AIRHAND_SERVER_FP）和账号服务地址（AIRHAND_ACCOUNT_API）
enum BuildDefaults {
    static var server: String { plist("AirhandServer") }
    static var fingerprint: String { plist("AirhandServerFingerprint") }
    /// account-api 的地址（登录页预填用；用户可以在登录页里改，改完存在 account.json）
    static var accountAPI: String { plist("AirhandAccountAPI") }

    private static func plist(_ k: String) -> String {
        let v = (Bundle.main.object(forInfoDictionaryKey: k) as? String) ?? ""
        return v.hasPrefix("$(") ? "" : v.trimmingCharacters(in: .whitespaces)
    }
}

/// 本机的端到端加密身份（64 位十六进制的私钥）：做控制端、被控端用的是同一个，配对过的设备靠它认出本机
enum IdentityStore {
    struct File: Codable { var key: String }

    static func load() -> String? { SharedStore.read(SharedStore.identityFile, as: File.self)?.key }

    static func save(_ key: String) {
        guard key.count == 64, load() == nil else { return }
        SharedStore.write(SharedStore.identityFile, File(key: key))
    }
}

/// 本机做被控端时的控制码（固定不变，直到用户更换）
struct SavedHostCode: Codable, Equatable {
    var code: Int
    var secret: String

    static func load() -> SavedHostCode? { SharedStore.read(SharedStore.hostCodeFile, as: SavedHostCode.self) }
    func save() { SharedStore.write(SharedStore.hostCodeFile, self) }
    static func clear() { SharedStore.remove(SharedStore.hostCodeFile) }
}

/// 广播扩展的实时状态（扩展每隔一会儿、有变化时写）
struct HostLive: Codable, Equatable {
    struct Viewer: Codable, Equatable, Identifiable {
        var id: String
        var key: String
        var name: String
        var ip: String
        var safety: String
        var justPaired: Bool
    }

    var running = false
    /// 写入的时间（秒）：扩展被系统停掉时来不及写，太旧的状态当作没在共享
    var updated: Double = 0
    /// connecting / connected / disconnected
    var server = "connecting"
    var serverProblem: String? = nil
    var code: Int? = nil
    var pairingCode: String? = nil
    var pairingLocked = false
    var pairedCount = 0
    var viewers: [Viewer] = []
    var watching = false
    var audioActive = false
    var audioFailure: String? = nil

    var isLive: Bool { running && Date().timeIntervalSince1970 - updated < 6 }

    static func load() -> HostLive? { SharedStore.read(SharedStore.hostLiveFile, as: HostLive.self) }
    func save() { SharedStore.write(SharedStore.hostLiveFile, self) }
}

/// App 发给广播扩展的命令
struct HostCommand: Codable {
    var id: String
    /// kickAll / newCode / newPairingCode / forgetPaired / stop
    var op: String

    static func send(_ op: String) {
        SharedStore.write(SharedStore.hostCommandFile, HostCommand(id: UUID().uuidString, op: op))
        IPC.post(IPC.hostCommand)
    }
}

/// 配对状态（Rust 的 PairingState：`{code, locked, paired:[{key,name,since}]}`），原样存着
enum PairingFile {
    static func load() -> JSON? { SharedStore.readRaw(SharedStore.pairingFile) }
    static func save(_ state: Any) { SharedStore.writeRaw(SharedStore.pairingFile, state) }
    static var pairedCount: Int { (load()?.arr("paired") ?? []).count }

    /// 忘掉配对过的设备（没在共享时直接改文件）
    static func forgetPaired() {
        guard var s = load() else { return }
        s["paired"] = [Any]()
        save(s)
    }

    /// 换一个配对码：下次开始共享时由 Rust 生成
    static func reset() { SharedStore.remove(SharedStore.pairingFile) }
}

/// 进程之间的通知（Darwin notify）：只是“有变化了，去读文件”
enum IPC {
    static let hostLive = "app.airhand.ios.host.live"
    static let hostCommand = "app.airhand.ios.host.command"

    private final class Box { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f } }
    private static var boxes: [String: Box] = [:]
    private static let lock = NSLock()

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    /// 观察一个通知（每个名字一个回调，在主线程上调用）
    static func observe(_ name: String, _ f: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let box = Box(f)
        if let old = boxes[name] {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(old).toOpaque(),
                                               CFNotificationName(name as CFString), nil)
        }
        boxes[name] = box
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(box).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let box = Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { box.f() }
        }, name as CFString, nil, .deliverImmediately)
    }
}
