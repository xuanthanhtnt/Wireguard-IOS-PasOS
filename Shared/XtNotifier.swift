// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import Foundation
import UserNotifications

/// Local notifications posted by the watchdog (from the extension or the app).
enum XtNotifier {
    static let pausedCategory = "XT_PAUSED"
    static let resumeAction = "XT_RESUME"
    static let cancelAction = "XT_CANCEL"
    static let updateCategory = "XT_UPDATE"

    static let pausedId = "xt.paused"
    static let eventId = "xt.event"
    static let updateId = "xt.update"

    static func registerCategories() {
        let resume = UNNotificationAction(identifier: resumeAction, title: "Kết nối lại ngay", options: [])
        let cancel = UNNotificationAction(identifier: cancelAction, title: "Hủy chờ", options: [.destructive])
        let paused = UNNotificationCategory(identifier: pausedCategory, actions: [resume, cancel], intentIdentifiers: [], options: [])
        let update = UNNotificationCategory(identifier: updateCategory, actions: [], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([paused, update])
    }

    static func showPaused(tunnelName: String, killSwitch: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Đã tạm ngắt VPN: máy chủ không phản hồi"
        if killSwitch {
            content.body = "Máy chủ của “\(tunnelName)” không liên lạc được (cúp điện hoặc đang khởi động lại?). VPN đã tắt để Internet vẫn hoạt động. Mở WG VPN hoặc bấm “Kết nối lại ngay” khi máy chủ có điện trở lại."
        } else {
            content.body = "Máy chủ của “\(tunnelName)” không liên lạc được (cúp điện hoặc đang khởi động lại?). VPN đã tạm ngừng định tuyến để Internet vẫn hoạt động và sẽ tự kết nối lại khi máy chủ có điện trở lại."
        }
        content.categoryIdentifier = pausedCategory
        content.threadIdentifier = "watchdog"
        if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }
        post(id: pausedId, content: content)
    }

    static func removePaused() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [pausedId])
        center.removePendingNotificationRequests(withIdentifiers: [pausedId])
    }

    static func showEvent(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "watchdog"
        post(id: eventId, content: content)
    }

    static func showUpdate(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Có phiên bản WG VPN mới"
        content.body = "Phiên bản \(version) đã sẵn sàng. Mở Giới thiệu › Kiểm tra cập nhật để tải về."
        content.categoryIdentifier = updateCategory
        post(id: updateId, content: content)
    }

    private static func post(id: String, content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { XtLog.error("Notification \(id) failed: \(error.localizedDescription)") }
        }
    }
}
