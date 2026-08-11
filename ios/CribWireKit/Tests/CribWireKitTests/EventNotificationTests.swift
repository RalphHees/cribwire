import XCTest
@testable import CribWireKit

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The push payload as the app receives it, and the sentence shown for it.
///
/// This used to be the Notification Service Extension's contract with the
/// backend. The extension is gone — the app decrypts the payload itself — but
/// the contract is unchanged, so it stays pinned here rather than in the app
/// target, where `swift test` cannot reach it.
final class EventNotificationTests: XCTestCase {

    private let pairingID = UUID(uuidString: "9d1c8f22-6b0a-4d9e-8f27-3c5a6b7d8e90")!

    // MARK: - Payload parsing

    func testParsesTheBackendPayload() throws {
        // Exactly the shape pinned in backend.md §3.
        let userInfo: [AnyHashable: Any] = [
            "pairingId": pairingID.uuidString,
            "ciphertext": "c2VhbGVk"
        ]

        let payload = try XCTUnwrap(EventNotificationPayload(userInfo: userInfo))
        XCTAssertEqual(payload.pairingID, pairingID)
        XCTAssertEqual(payload.ciphertext, "c2VhbGVk")
    }

    func testRejectsPayloadsThatAreNotSealedEvents() {
        let cases: [[AnyHashable: Any]] = [
            [:],
            ["ciphertext": "c2VhbGVk"],
            ["pairingId": pairingID.uuidString],
            ["pairingId": pairingID.uuidString, "ciphertext": ""],
            ["pairingId": "not-a-uuid", "ciphertext": "c2VhbGVk"],
            ["pairingId": 42, "ciphertext": "c2VhbGVk"]
        ]

        for userInfo in cases {
            XCTAssertNil(
                EventNotificationPayload(userInfo: userInfo),
                "must not be read as an event: \(userInfo)"
            )
        }
    }

    func testKeysMatchTheWireFormat() {
        // A rename here would silently degrade every push to the generic text.
        XCTAssertEqual(EventNotificationPayload.pairingIDKey, "pairingId")
        XCTAssertEqual(EventNotificationPayload.ciphertextKey, "ciphertext")
    }

    // MARK: - Alert text

    func testEveryEventKindHasItsOwnSentence() {
        let bodies = [
            EventAlert.body(for: DetectionEvent(type: .noise, ts: 1)),
            EventAlert.body(for: DetectionEvent(type: .motion, ts: 1)),
            EventAlert.body(for: DetectionEvent(type: .lowBattery, ts: 1))
        ]

        XCTAssertEqual(bodies, ["Noise detected", "Movement detected", "Camera battery low"])
        XCTAssertFalse(
            bodies.contains(EventAlert.genericBody),
            "a decrypted event must say more than the fallback"
        )
    }

    // MARK: - Round trip

    func testSealedEventOpensBackIntoItsAlertText() throws {
        let key = SymmetricKey(size: .bits256)
        let event = DetectionEvent(type: .motion, ts: 1_754_850_000)

        let sealed = try event.sealed(using: key, pairingID: pairingID)
        let payload = try XCTUnwrap(
            EventNotificationPayload(
                userInfo: ["pairingId": pairingID.uuidString, "ciphertext": sealed]
            )
        )
        let opened = try DetectionEvent.open(
            sealed: payload.ciphertext,
            using: key,
            pairingID: payload.pairingID
        )

        XCTAssertEqual(opened, event)
        XCTAssertEqual(EventAlert.body(for: opened), "Movement detected")
    }
}
