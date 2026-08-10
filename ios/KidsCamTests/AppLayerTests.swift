import KidsCamKit
import XCTest
@testable import KidsCam

/// App-layer tests that need no camera, no network and no device.
///
/// The crypto, protocol and pairing-state-machine suites live in
/// `KidsCamKit/Tests` so they can also run with `swift test`; this target covers
/// the glue that only exists inside the app.
final class AppConfigurationTests: XCTestCase {

    func testReadsIdentifiersFromInfoDictionary() {
        let configuration = AppConfiguration(bundle: Bundle(for: Self.self))
        // The test bundle has no KidsCam keys, so everything should be nil
        // rather than a bogus value.
        XCTAssertNil(configuration.appGroupIdentifier)
        XCTAssertNil(configuration.defaultAPIBaseURL)
    }

    func testExplicitInitialiserKeepsValues() throws {
        let url = try XCTUnwrap(URL(string: "https://api.kidscam.example"))
        let configuration = AppConfiguration(
            appGroupIdentifier: "group.test",
            keychainAccessGroup: "group.test",
            defaultAPIBaseURL: url
        )
        XCTAssertEqual(configuration.appGroupIdentifier, "group.test")
        XCTAssertEqual(configuration.defaultAPIBaseURL, url)
    }
}

final class PairingRegistryTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kidscam-tests-\(UUID().uuidString).json")
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
            apiBaseURL: try XCTUnwrap(URL(string: "https://api.kidscam.example")),
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
        let url = try XCTUnwrap(URL(string: "https://api.kidscam.example"))

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
        let url = try XCTUnwrap(URL(string: "https://api.kidscam.example"))
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
            apiBaseURL: try XCTUnwrap(URL(string: "https://api.kidscam.example"))
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
            Bundle(for: Self.self).url(forResource: "kidscam-v1", withExtension: "json"),
            "shared/test-vectors/kidscam-v1.json is not in the test bundle"
        )
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let root = try XCTUnwrap(json as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 1)
    }

    func testAppLinksTheSameCryptoAsTheVectors() throws {
        // A smoke test that KidsCamKit is actually linked into the app target.
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "kidscam-v1", withExtension: "json")
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
