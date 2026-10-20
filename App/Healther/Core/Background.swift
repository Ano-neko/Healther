import BackgroundTasks
import HealtherCore
import UIKit
import UserNotifications

/// Local notifications for messages she sends on her own.
enum Notifier {
    static var center: UNUserNotificationCenter { .current() }

    static func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func content(_ text: String, from name: String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = name
        c.body = text.replacingOccurrences(of: "\n\n", with: "\n")
        c.sound = .default
        c.threadIdentifier = "chat"
        c.userInfo = ["tab": "chat"]
        return c
    }

    /// Right now (wake-up greeting written in the background).
    static func post(_ text: String, from name: String) async {
        let req = UNNotificationRequest(identifier: "now-\(UUID().uuidString)", content: content(text, from: name), trigger: nil)
        try? await center.add(req)
    }

    /// At the message's time; the identifier is the message id so it can be withdrawn.
    static func schedule(_ messages: [ProactiveMessage], from name: String) async {
        let cal = Calendar.current
        for m in messages where m.fireAt > Date() {
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: m.fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: m.id, content: content(m.text, from: name), trigger: trigger))
        }
    }

    static func withdraw(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Launch hooks that SwiftUI doesn't cover: HealthKit background delivery, background refresh,
/// and notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTask = "io.github.healther.refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            Self.handleRefresh(task as! BGAppRefreshTask)
        }
        // Background launches (HealthKit wake-ups) also come through here, before any view exists.
        MainActor.assumeIsolated {
            AppModel.shared.bootstrap()
            AppModel.shared.startObservingSleep()
        }
        Self.scheduleRefresh()
        return true
    }

    /// Asks iOS for a background slot early tomorrow morning, to write the day's check-ins
    /// even on days without a wake-up signal from the watch.
    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTask)
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        req.earliestBeginDate = cal.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow)
        try? BGTaskScheduler.shared.submit(req)
    }

    static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            await AppModel.shared.proactiveTick(inBackground: true)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    // While the app is open, her message goes straight into the chat instead of a banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await Self.tick()
        return []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { AppModel.shared.tab = "chat" }
        await Self.tick()
    }

    @MainActor
    static func tick() async {
        await AppModel.shared.proactiveTick(inBackground: false)
    }
}
