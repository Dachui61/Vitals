import AppKit
import Foundation
import UserNotifications
import VitalsCore

/// 把告警送到用户面前：系统通知 + 界面内提示。
///
/// 判定逻辑在 `VitalsCore.AlertEngine`（可单测），这里只负责投递与授权。
final class AlertCoordinator: NSObject, UNUserNotificationCenterDelegate {

    private var engine = AlertEngine()
    private var center: UNUserNotificationCenter?
    /// 通知授权被拒时退化为界面内提示。
    private(set) var notificationsAuthorized = false
    /// 最近一条告警，供界面显示。
    private(set) var latestAlert: Alert?

    var onAlert: ((Alert) -> Void)?

    override init() {
        super.init()
        center = UNUserNotificationCenter.current()
        center?.delegate = self
    }

    /// 首次启动时请求通知权限（被拒也不影响其它功能）。
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notificationsAuthorized = granted
            }
        }
    }

    func apply(settings: AlertSettings) {
        engine.update(settings: settings)
    }

    func evaluate(_ snapshot: CoreSnapshot) {
        let alerts = engine.evaluate(snapshot)
        guard let alert = alerts.first else { return }
        latestAlert = alert
        onAlert?(alert)
        post(alert)
    }

    private func post(_ alert: Alert) {
        guard notificationsAuthorized, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// 前台也显示通知（默认前台不显示）。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
