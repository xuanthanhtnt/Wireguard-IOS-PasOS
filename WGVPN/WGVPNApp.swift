// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import SwiftUI
import UIKit
import UserNotifications

@main
struct WGVPNApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.tunnels)
                .environmentObject(model.watchdog)
                .environmentObject(model.updates)
                .environmentObject(model.lock)
                .task { await model.start() }
                .onOpenURL { url in
                    Task { await model.handleURL(url) }
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                model.lock.willEnterForeground()
                Task { await model.becameActive() }
            case .background:
                model.lock.didEnterBackground()
                model.watchdog.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        XtNotifier.registerCategories()
        let model = AppModel.shared
        WatchdogController.registerBackgroundTask(tunnels: model.tunnels, controller: model.watchdog)
        XtLog.info("WG VPN \(AppInfo.version) (\(AppInfo.build)) started, app group shared: \(AppGroup.isShared)")
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            await AppModel.shared.handleNotification(action: action, category: category)
            completionHandler()
        }
    }
}

/// Everything the app needs, shared with the app delegate and Shortcuts actions.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let tunnels = TunnelsManager()
    let watchdog = WatchdogController()
    let updates = UpdateChecker()
    let lock = AppLock()

    @Published var alertMessage: String?
    @Published var selectedTab = Tab.tunnels
    @Published var selectedTunnelId: String?

    enum Tab: Hashable {
        case tunnels
        case watchdog
        case settings
        case about
    }

    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        watchdog.attach(tunnels)
        await tunnels.reload()
        await watchdog.reconcile()
        await requestNotificationPermission()
        await updates.checkIfDue()
    }

    func becameActive() async {
        guard started else { return }
        await tunnels.reload()
        watchdog.reloadFromStore()
        await watchdog.reconcile()
        await watchdog.probeStoppedPause(force: false)
        watchdog.scheduleBackgroundRefresh()
    }

    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func handleNotification(action: String, category: String) async {
        await tunnels.reload()
        watchdog.reloadFromStore()
        switch action {
        case XtNotifier.resumeAction:
            await watchdog.resumeNow()
        case XtNotifier.cancelAction:
            await watchdog.cancelPause()
        default:
            if category == XtNotifier.updateCategory {
                selectedTab = .about
            } else if category == XtNotifier.pausedCategory {
                selectedTab = .watchdog
            }
        }
    }

    // MARK: - URLs (files opened with WG VPN, wgvpn:// remote control)

    func handleURL(_ url: URL) async {
        if !started { await start() }
        if url.isFileURL {
            do {
                let candidates = try ImportService.candidates(fromFile: url)
                let report = await ImportService.add(candidates, to: tunnels)
                alertMessage = report.message
                selectedTab = .tunnels
            } catch {
                alertMessage = "Không nhập được file: \(error.localizedDescription)"
            }
            return
        }
        guard url.scheme?.lowercased() == "wgvpn" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let name = components?.queryItems?.first { $0.name == "name" }?.value
        let action = (url.host ?? "").lowercased()
        await tunnels.reload()
        func target() -> TunnelItem? {
            if let name = name { return tunnels.tunnels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            return tunnels.activeTunnel ?? tunnels.tunnels.first
        }
        do {
            switch action {
            case "connect", "start":
                guard let item = target() else { throw TunnelsError.system("Không tìm thấy tunnel \(name ?? "")") }
                try await tunnels.connect(item)
            case "disconnect", "stop":
                if let item = name == nil ? tunnels.activeTunnel : target() { await tunnels.disconnect(item) }
            case "toggle":
                guard let item = target() else { throw TunnelsError.system("Không tìm thấy tunnel \(name ?? "")") }
                try await tunnels.toggle(item)
            case "import":
                guard let link = components?.queryItems?.first(where: { $0.name == "url" })?.value else { return }
                let candidates = try await ImportService.candidates(fromURL: link)
                alertMessage = await ImportService.add(candidates, to: tunnels).message
            case "check":
                await watchdog.checkNow()
            default:
                break
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
