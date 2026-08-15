import Foundation
import UIKit
import UserNotifications
import CribWireKit

/// Everything the app does with push notifications: permission, APNs
/// registration, and opening the sealed event payload for display.
///
/// The decryption half used to be a separate binary — a Notification Service
/// Extension. Merging it into the app removes the app group, the second bundle
/// id and the second provisioning profile, and it changes *when* the specific
/// text can be shown, because only an extension may rewrite a push before iOS
/// displays it:
///
/// * **App in the foreground** — the push is opened here and re-posted with the
///   real sentence before anything is shown, so the user sees "Noise detected".
/// * **App in the background or closed** — iOS shows the server's generic
///   "Activity detected" (nothing is running that could rewrite it). The text is
///   upgraded in Notification Centre the next time the app is opened, and the
///   tap is routed to the right pairing.
///
/// Restoring the specific text at delivery time means reintroducing an
/// extension; the backend payload is unchanged either way.
@MainActor
@Observable
final class PushNotificationCoordinator: NSObject {

    /// Marks the copies this app posts itself, so `willPresent` can tell a fresh
    /// push from an upgrade of one that was delivered while the app was closed.
    private enum Presentation: String {
        /// Opened while the app was in front: alert as usual.
        case alert
        /// Rewritten after the fact. It has to reach Notification Centre without
        /// buzzing about an event the user was already told about.
        case silent

        static let userInfoKey = "cribwire.presentation"
    }

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Hex APNs device token, once registration succeeds. `nil` means this
    /// device cannot receive pushes yet — pairing sends an empty token and the
    /// backend simply has nothing to fan out to.
    private(set) var apnsToken: String?
    /// The last event this device managed to open. Held in memory only: a push
    /// is a signal, not a record, and nothing about one is written to disk.
    private(set) var latestEvent: DecodedEvent?
    /// Set when the user taps an event notification. The live view that should
    /// consume it is Phase 2 (`docs/TASKS.md` → "Notification tap → deep-link").
    var pendingPairingID: UUID?

    /// A token is only valid in the environment it was minted for, and the
    /// backend picks the APNs host from what we register at pairing time. The
    /// entitlement in `project.yml` decides which one this build gets, so the
    /// two have to agree.
    #if DEBUG
    let apnsEnvironment: API.APNSEnvironment = .sandbox
    #else
    let apnsEnvironment: API.APNSEnvironment = .production
    #endif

    private let decoder: EventNotificationDecoder
    private let center: UNUserNotificationCenter

    init(secrets: PairingSecretsStore, center: UNUserNotificationCenter = .current()) {
        self.decoder = EventNotificationDecoder(secrets: secrets)
        self.center = center
        super.init()
        center.delegate = self
    }

    // MARK: - Permission and registration

    /// Launch-time wiring. Registers for remote notifications if the user has
    /// already said yes, and never prompts: the prompt belongs to the moment the
    /// token is needed, not to the first launch.
    func prepare() async {
        await refreshAuthorizationStatus()
        registerForRemoteNotificationsIfAuthorized()
    }

    /// Asks for permission, at the point where a push token is about to be
    /// registered with the backend (pairing).
    ///
    /// Denial is not an error — CribWire works without pushes — so this reports
    /// nothing and only updates `authorizationStatus`. A Viewer that has denied
    /// alerts is told so on its home screen, with a link into Settings, because
    /// iOS will never show this prompt a second time.
    func requestAuthorization() async {
        await refreshAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge]))
                ?? false
            authorizationStatus = granted ? .authorized : .denied
        }
        registerForRemoteNotificationsIfAuthorized()
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    private func registerForRemoteNotificationsIfAuthorized() {
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else {
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// - Parameter deviceToken: raw token bytes from `UIApplicationDelegate`.
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    func didFailToRegisterForRemoteNotifications() {
        // Nothing to report and nothing to retry: iOS registers again on the
        // next launch, and every call site already handles "no token".
        apnsToken = nil
    }

    // MARK: - Catching up

    /// Rewrites event notifications that were delivered while the app was not
    /// running.
    ///
    /// Opening the app is the first moment `K_evt` is reachable, so this is
    /// where "Activity detected" in Notification Centre becomes "Noise
    /// detected". Silent by design: the user has already been alerted, these
    /// entries only have to read correctly.
    func upgradeDeliveredNotifications() async {
        // Identifier and payload are pulled out first: everything after this is
        // plain values, which keeps the sealed `UNNotification` objects from
        // travelling any further than the loop that produced them.
        let sealed: [(String, EventNotificationPayload)] =
            await center.deliveredNotifications().compactMap { notification in
                EventNotificationPayload(userInfo: notification.request.content.userInfo)
                    .map { (notification.request.identifier, $0) }
            }

        for (identifier, payload) in sealed {
            guard let decoded = await decoder.open(payload) else { continue }
            latestEvent = decoded
            await repost(identifier: identifier, decoded: decoded, as: .silent)
        }
    }

    // MARK: - Presentation

    /// Re-posts a push with the decrypted text.
    ///
    /// Reusing the identifier is what makes this a replacement rather than a
    /// second notification about the same event. The copy carries the pairing id
    /// (so a tap still deep-links) but no ciphertext, which is what stops
    /// `decode` — and therefore this method — from running on it a second time.
    /// - Returns: `false` if the copy could not be posted, which is the caller's
    ///   cue to let the original generic alert through rather than swallowing
    ///   the event entirely.
    @discardableResult
    private func repost(
        identifier: String,
        decoded: DecodedEvent,
        as presentation: Presentation
    ) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = EventAlert.title
        content.body = EventAlert.body(for: decoded.event)
        content.userInfo = [
            Presentation.userInfoKey: presentation.rawValue,
            EventNotificationPayload.pairingIDKey: decoded.pairingID.uuidString
        ]
        if presentation == .alert {
            content.sound = .default
        }

        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        do {
            try await center.add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
            return true
        } catch {
            return false
        }
    }

    private func pairingID(fromUserInfo userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[EventNotificationPayload.pairingIDKey] as? String).flatMap(UUID.init(uuidString:))
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationCoordinator: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let identifier = notification.request.identifier
        let userInfo = notification.request.content.userInfo

        // An upgraded copy of something the user has already been alerted about:
        // it belongs in the list, and nowhere else.
        if userInfo[Presentation.userInfoKey] as? String == Presentation.silent.rawValue {
            return [.list]
        }

        guard let payload = EventNotificationPayload(userInfo: userInfo),
              let decoded = await decoder.open(payload)
        else {
            // Either a copy this app posted (already decrypted, nothing left to
            // do) or a payload it cannot open — in which case the server's
            // generic text is the correct thing to show.
            return [.banner, .sound, .list]
        }

        latestEvent = decoded
        // Suppress the sealed original only once the copy that replaces it is
        // actually posted — the copy is what does the alerting, with the
        // sentence that says what happened.
        let reposted = await repost(identifier: identifier, decoded: decoded, as: .alert)
        return reposted ? [] : [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        if let payload = EventNotificationPayload(userInfo: userInfo),
           let decoded = await decoder.open(payload) {
            latestEvent = decoded
            pendingPairingID = decoded.pairingID
        } else {
            // A copy this app already opened, or a payload it cannot read. The
            // deep link still works; only the detail is missing.
            pendingPairingID = pairingID(fromUserInfo: userInfo)
        }
    }
}
