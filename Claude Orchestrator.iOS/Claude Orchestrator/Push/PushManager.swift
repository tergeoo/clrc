import Foundation
import Combine
import UIKit
import UserNotifications
import ClrcCore

/// Push notifications: permission, categories, device registration with
/// the relay on every connect, and answers from the lock screen.
@MainActor
final class PushManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushManager()

    /// A chat to open after the user tapped a notification.
    @Published var openRequest: PushTarget?

    private var relay: RelayWebSocket?
    private var auth: AuthService?
    private var deviceToken: String?
    private var cancellables = Set<AnyCancellable>()

    #if DEBUG
    private static let sandbox = true
    #else
    private static let sandbox = false
    #endif

    func configure(relay: RelayWebSocket, auth: AuthService) {
        guard self.relay == nil else { return }
        self.relay = relay
        self.auth = auth
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Set(PushCategories.all.map(Self.category)))

        // Ask once signed in; register the token on every connect.
        auth.$isAuthenticated
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.requestPermission() }
            .store(in: &cancellables)
        relay.$connectionState
            .removeDuplicates()
            .filter { $0 == .connected }
            .sink { [weak self] _ in self?.registerWithRelay() }
            .store(in: &cancellables)
    }

    func didRegister(token: Data) {
        deviceToken = PushNotify.hex(token)
        registerWithRelay()
    }

    /// Re-sends the registration (e.g. after Settings → Уведомления changed).
    func registerWithRelay() {
        guard let relay, let deviceToken, relay.connectionState == .connected else { return }
        let notify = PushNotify.decode(UserDefaults.standard.string(forKey: PushNotify.storageKey))
        relay.sendPushRegister(token: deviceToken, sandbox: Self.sandbox, notify: notify)
    }

    private func requestPermission() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    private static func category(_ category: PushCategory) -> UNNotificationCategory {
        var actions: [UNNotificationAction] = category.answerActions.map {
            UNNotificationAction(identifier: $0.id, title: $0.title, options: [])
        }
        actions.append(UNTextInputNotificationAction(identifier: PushCategories.textReplyID, title: "Ответить текстом…",
                                                     options: [], textInputButtonTitle: "Отправить",
                                                     textInputPlaceholder: "Ответ Claude"))
        return UNNotificationCategory(identifier: category.id, actions: actions, intentIdentifiers: [], options: [])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// In the foreground the Inbox already shows the card: no banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        await handle(userInfo: userInfo, actionID: actionID, typed: typed)
    }

    private func handle(userInfo: [AnyHashable: Any], actionID: String, typed: String?) async {
        guard let target = PushTarget(userInfo: userInfo) else { return }
        guard let answer = PushCategories.answer(actionID: actionID, typedText: typed) else {
            if actionID == UNNotificationDefaultActionIdentifier { openRequest = target }
            return
        }
        guard let auth else { return }
        do {
            try await ChatReplyClient(auth: auth).send(answer, to: target)
        } catch {
            await notifyFailure(error.localizedDescription, target: target)
        }
    }

    /// A reply from the lock screen failed: say so with a local notification.
    private func notifyFailure(_ message: String, target: PushTarget) async {
        let content = UNMutableNotificationContent()
        content.title = "Ответ не отправлен"
        content.body = message
        content.threadIdentifier = target.sessionID
        content.userInfo = ["agent_id": target.agentID, "session_id": target.sessionID]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Receives the APNs device token.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push registration failed: \(error.localizedDescription)")
    }
}
