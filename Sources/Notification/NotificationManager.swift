import Foundation
import UserNotifications
import AppKit

public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask for notification authorization while the system considers the app
    /// undecided (`.notDetermined`). That covers the first launch and, once
    /// again after the user resets notifications in System Settings — a reset
    /// returns the system status to `.notDetermined`, so the next clean
    /// launch re-prompts automatically without any manual state edit.
    /// `.denied` is respected (no re-prompt), and authorized states do nothing.
    /// The caller (post-ready scheduler) runs this once per clean launch, so
    /// the system prompt never appears while startup surfaces are alive and
    /// never re-enters the macOS 26 safe-area constraint loop.
    public func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Display a task completion notification.
    public func showTaskDoneNotification(title: String?, cwd: String?) {
        var lines = [sessionLabel(from: title)]
        if let workspace = workspaceName(from: cwd) {
            lines.append("工作区：\(workspace)")
        }
        deliver(title: "任务完成", body: lines.joined(separator: "\n"))
    }

    /// Display a notification for a task that is blocked waiting on the user:
    /// an approval prompt or a question the agent asked. While one of those is
    /// pending the turn stays open, so no completion event exists to react to.
    ///
    /// The body is the prompt itself. The session name and workspace are
    /// deliberately omitted here: the user just triggered this in the app, and
    /// the prompt is the only thing they need to decide whether to come back.
    /// The session name is kept as a fallback for a prompt that carries no text
    /// (an approval without a reason).
    public func showNeedsInputNotification(title: String?, reason: String?) {
        deliver(title: "需要你的输入", body: promptBody(title: title, reason: reason))
    }

    /// Display a notification for a tool approval the agent is waiting on.
    /// It has its own title because the user is asked to *decide* on an action,
    /// not to answer a question.
    public func showNeedsApprovalNotification(title: String?, reason: String?) {
        deliver(title: "需要你的批准", body: promptBody(title: title, reason: reason))
    }

    /// Display a notification for a plan the agent submitted for review. The
    /// body names the plan (its heading) so the user knows what they are being
    /// asked to approve.
    public func showNeedsReviewNotification(title: String?, reason: String?) {
        deliver(title: "需要你的确认", body: promptBody(title: title, reason: reason))
    }

    /// Body shared by the two prompt notifications: the prompt itself, with the
    /// session name only as a fallback for a prompt that carries no text.
    private func promptBody(title: String?, reason: String?) -> String {
        let detail = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (detail?.isEmpty == false) ? String(detail!.prefix(240)) : sessionLabel(from: title)
    }

    private func sessionLabel(from title: String?) -> String {
        (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "会话"
    }

    private func workspaceName(from cwd: String?) -> String? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self?.post(content, using: center)
            case .notDetermined:
                // Permission is asked once, after a clean normal launch
                // (see requestAuthorizationIfNeeded). Never prompt from a
                // task callback: the startup surfaces may still be alive.
                return
            case .denied:
                return
            @unknown default:
                return
            }
        }
    }

    private func post(_ content: UNNotificationContent, using center: UNUserNotificationCenter) {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                print("[NotificationManager] Failed to post notification:", error)
            }
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            // Match Electron's click behavior: bring the actual DSH window
            // back when it was hidden behind the Dock or the red light.
            MainWindowController.shared.showMainWindow()
            completionHandler()
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
