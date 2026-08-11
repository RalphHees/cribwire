import CryptoKit
import CribWireKit
import XCTest
@testable import CribWire

/// App-layer tests that need no camera, no network and no device.
///
/// The crypto, protocol and pairing-state-machine suites live in
/// `CribWireKit/Tests` so they can also run with `swift test`; this target covers
/// the glue that only exists inside the app.
final class AppConfigurationTests: XCTestCase {

    func testReadsIdentifiersFromInfoDictionary() {
        let configuration = AppConfiguration(bundle: Bundle(for: Self.self))
        // The test bundle has no CribWire keys, so everything should be nil
        // rather than a bogus value.
        XCTAssertNil(configuration.defaultAPIBaseURL)
    }

    func testExplicitInitialiserKeepsValues() throws {
        let url = try XCTUnwrap(URL(string: "https://api.cribwire.example"))
        let configuration = AppConfiguration(defaultAPIBaseURL: url)
        XCTAssertEqual(configuration.defaultAPIBaseURL, url)
    }
}

/// The decryption the Notification Service Extension used to do, now that it
/// runs in the app. The rule it has to keep: everything that is not a payload
/// this device can open must be indistinguishable — one `nil`, one generic
/// alert, no hint about key state (`security.md` §5).
final class EventNotificationDecoderTests: XCTestCase {

    private let pairingID = UUID(uuidString: "0f3b8b8a-1d2c-4a5b-9c8d-7e6f5a4b3c2d")!
    private let eventKey = SymmetricKey(size: .bits256)

    private func decoder(
        holding keys: [UUID: SymmetricKey]
    ) -> EventNotificationDecoder {
        EventNotificationDecoder { pairingID in keys[pairingID] }
    }

    private func userInfo(pairingID: UUID, ciphertext: String) -> [AnyHashable: Any] {
        [
            EventNotificationPayload.pairingIDKey: pairingID.uuidString,
            EventNotificationPayload.ciphertextKey: ciphertext
        ]
    }

    func testOpensAnEventSealedForThisPairing() async throws {
        let event = DetectionEvent(type: .noise, ts: 1_754_850_000)
        let ciphertext = try event.sealed(using: eventKey, pairingID: pairingID)

        let decoded = await decoder(holding: [pairingID: eventKey])
            .decode(userInfo: userInfo(pairingID: pairingID, ciphertext: ciphertext))

        XCTAssertEqual(decoded, DecodedEvent(pairingID: pairingID, event: event))
        XCTAssertEqual(EventAlert.body(for: try XCTUnwrap(decoded).event), "Noise detected")
    }

    func testReturnsNilWhenTheDeviceHoldsNoKeyForThePairing() async throws {
        let ciphertext = try DetectionEvent(type: .motion, ts: 1)
            .sealed(using: eventKey, pairingID: pairingID)

        let decoded = await decoder(holding: [:])
            .decode(userInfo: userInfo(pairingID: pairingID, ciphertext: ciphertext))

        XCTAssertNil(decoded)
    }

    func testReturnsNilForAnotherPairingsCiphertext() async throws {
        // Right key, wrong pairing: the pairing id is the AAD, so this must fail
        // exactly like a tampered payload.
        let other = UUID()
        let ciphertext = try DetectionEvent(type: .noise, ts: 1)
            .sealed(using: eventKey, pairingID: other)

        let decoded = await decoder(holding: [pairingID: eventKey])
            .decode(userInfo: userInfo(pairingID: pairingID, ciphertext: ciphertext))

        XCTAssertNil(decoded)
    }

    func testReturnsNilForTamperedCiphertext() async throws {
        var ciphertext = try DetectionEvent(type: .noise, ts: 1)
            .sealed(using: eventKey, pairingID: pairingID)
        ciphertext = String(ciphertext.dropLast()) + (ciphertext.hasSuffix("A") ? "B" : "A")

        let decoded = await decoder(holding: [pairingID: eventKey])
            .decode(userInfo: userInfo(pairingID: pairingID, ciphertext: ciphertext))

        XCTAssertNil(decoded)
    }

    func testIgnoresNotificationsTheAppPostedItself() async {
        // The re-posted, already-decrypted copy carries a pairing id but no
        // ciphertext — that is what stops it being decrypted a second time.
        let decoded = await decoder(holding: [pairingID: eventKey]).decode(
            userInfo: [EventNotificationPayload.pairingIDKey: pairingID.uuidString]
        )

        XCTAssertNil(decoded)
    }
}

final class PairingRegistryTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cribwire-tests-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
        try super.tearDownWithError()
    }

    func testRoundTripsRecords() async throws {
        let registry = PairingRegistry(fileURL: fileURL)
        let record = PairingRecord(
            id: UUID(),
            localRole: .camera,
            apiBaseURL: try XCTUnwrap(URL(string: "https://api.cribwire.example")),
            peerDeviceID: "viewer-1"
        )

        try await registry.upsert(record)

        // A second registry over the same file proves it actually persisted.
        let reloaded = try await PairingRegistry(fileURL: fileURL).all()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, record.id)
        XCTAssertEqual(reloaded.first?.localRole, .camera)
        XCTAssertEqual(reloaded.first?.peerDeviceID, "viewer-1")
        XCTAssertEqual(reloaded.first?.apiBaseURL, record.apiBaseURL)
    }

    func testUpsertReplacesRatherThanDuplicates() async throws {
        let registry = PairingRegistry(fileURL: fileURL)
        let id = UUID()
        let url = try XCTUnwrap(URL(string: "https://api.cribwire.example"))

        try await registry.upsert(
            PairingRecord(id: id, localRole: .camera, apiBaseURL: url, displayName: "Nursery")
        )
        try await registry.upsert(
            PairingRecord(id: id, localRole: .camera, apiBaseURL: url, displayName: "Bedroom")
        )

        let records = try await registry.all()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.displayName, "Bedroom")
    }

    func testRemoveDropsOnlyTheNamedPairing() async throws {
        let registry = PairingRegistry(fileURL: fileURL)
        let url = try XCTUnwrap(URL(string: "https://api.cribwire.example"))
        let keep = PairingRecord(id: UUID(), localRole: .camera, apiBaseURL: url)
        let drop = PairingRecord(id: UUID(), localRole: .camera, apiBaseURL: url)

        try await registry.upsert(keep)
        try await registry.upsert(drop)
        try await registry.remove(pairingID: drop.id)

        let records = try await registry.all()
        XCTAssertEqual(records.map(\.id), [keep.id])
    }

    func testRecordStoresNoKeyMaterial() throws {
        // A regression guard: the metadata file must never gain a secret field.
        let record = PairingRecord(
            id: UUID(),
            localRole: .viewer,
            apiBaseURL: try XCTUnwrap(URL(string: "https://api.cribwire.example"))
        )
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(record), encoding: .utf8))
        for forbidden in ["secret", "kAuth", "k_auth", "key", "sas"] {
            XCTAssertFalse(
                json.lowercased().contains(forbidden.lowercased()),
                "PairingRecord must not carry \(forbidden)"
            )
        }
    }
}

/// The Xcode test bundle carries the same shared vector file the SwiftPM suite
/// loads, so a broken reference is caught here too.
final class SharedTestVectorResourceTests: XCTestCase {

    func testVectorFileIsBundledAndParses() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "cribwire-v1", withExtension: "json"),
            "shared/test-vectors/cribwire-v1.json is not in the test bundle"
        )
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let root = try XCTUnwrap(json as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 1)
    }

    func testAppLinksTheSameCryptoAsTheVectors() throws {
        // A smoke test that CribWireKit is actually linked into the app target.
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "cribwire-v1", withExtension: "json")
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        let hkdf = try XCTUnwrap(root["hkdf"] as? [String: Any])
        let hex = try XCTUnwrap(hkdf["rootSecretHex"] as? String)

        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }

        let sas = try RootSecret(bytes: Data(bytes)).deriveKeys().sasCode
        let expected = try XCTUnwrap((root["sas"] as? [String: Any])?["code"] as? String)
        XCTAssertEqual(sas.digits, expected)
    }
}
