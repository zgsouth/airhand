import SwiftUI
import UIKit
import UserNotifications

@main
struct AirhandApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var phase
    @State private var app = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: phase) { _, p in
            app.controller.setForeground(p == .active)
            app.session?.setBackground(p == .background)
            if p == .active { app.hostLive = HostLive.load() }
            // 账号同步只在用得着的时候跑：回到前台立刻拉一次，退到后台就停，省电
            if p == .active, app.account.signedIn { app.account.startSync() }
            if p == .background { app.account.stopSync() }
            // 切到别的应用一会儿（复制个东西）再回来，会话不断：系统给的后台时间里连接保持着
            if p == .background, app.session != nil {
                BackgroundTask.begin()
            } else if p == .active {
                BackgroundTask.end()
            }
        }
    }
}

enum BackgroundTask {
    private static var id: UIBackgroundTaskIdentifier = .invalid

    static func begin() {
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: "airhand-session") { end() }
    }

    static func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// 远程画面可以锁定方向（跟着对方画面横 / 竖）
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Native.initialize()
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

struct RootView: View {
    @Bindable var app: AppModel

    var body: some View {
        TabView(selection: $app.tab) {
            ConnectView(app: app)
                .tabItem { Label(L.t("tab_connect"), systemImage: "display") }
                .tag(AppModel.Tab.connect)
            ShareView(app: app)
                .tabItem { Label(L.t("tab_share"), systemImage: "dot.radiowaves.left.and.right") }
                .tag(AppModel.Tab.share)
            SettingsView(app: app)
                .tabItem { Label(L.t("tab_settings"), systemImage: "gearshape") }
                .tag(AppModel.Tab.settings)
        }
        .toasts(app)
        .onOpenURL { url in app.open(url) }
        #if DEBUG
        .task {
            // 开发用：xcrun simctl launch <模拟器> app.airhand.ios -AirhandConnect 123456 [-AirhandPairing 654321]
            switch UserDefaults.standard.string(forKey: "AirhandTab") {
            case "share": app.tab = .share
            case "settings": app.tab = .settings
            default: break
            }
            if UserDefaults.standard.bool(forKey: "AirhandHostSelfTest") { DebugHost.start() }
            if let code = UserDefaults.standard.string(forKey: "AirhandConnect") {
                try? await Task.sleep(for: .seconds(1.5))
                app.connect(code: code, pairing: UserDefaults.standard.string(forKey: "AirhandPairing"))
            }
        }
        #endif
        .sheet(item: $app.pairingFor) { req in
            PairingSheet(app: app, request: req)
                .presentationDetents([.medium, .large])
        }
    }
}
