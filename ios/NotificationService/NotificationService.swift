import UserNotifications

/// Notification Service Extension.
///
/// **Phase 3 skeleton.** Today it passes the APNs payload through untouched. In
/// Phase 3 it will do the job described in `security.md` §5:
///
/// 1. Read `pairingId` and `ciphertext` from `request.content.userInfo`.
/// 2. Load `K_evt` for that pairing from the **app-group** Keychain access group
///    (the only key this binary is allowed to see — the root secret and `K_sig`
///    live in the app's private access group and must stay unreachable here).
/// 3. `SealedEnvelope.open(ciphertext, using: kEvt, associatedData: .event(...))`
///    and render "Noise detected" / "Movement detected" / "Low battery".
/// 4. On *any* failure — missing key, wrong pairing, tampered ciphertext — show
///    the generic "Activity detected" text. Never surface an error, and never log
///    anything about key state.
///
/// The extension deliberately links neither WebRTC nor the app's UI code; the
/// less that runs in this process, the smaller the blast radius of a bug in it.
///
/// TODO(Phase 3): implement decryption (docs/TASKS.md → Phase 3, iOS Viewer).
final class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        // Passthrough: the alert the server sent is the generic, localizable
        // `EVENT_GENERIC` text, which is exactly the correct fallback until
        // decryption lands.
        contentHandler(bestAttemptContent ?? request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Deliver the generic alert rather than nothing.
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}
