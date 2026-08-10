import Foundation
import XCTest

/// Typed view of `shared/test-vectors/kidscam-v1.json` (revision 1.1).
///
/// The file is *not* copied into this target — `Resources/kidscam-v1.json` is a
/// symlink to the one normative copy in `shared/`, so the iOS and backend suites
/// can never drift onto different vectors. If the resource cannot be found (some
/// build systems do not follow symlinks when copying), the loader walks up from
/// this source file to the repository root and reads the original.
struct TestVectors: Decodable {
    struct HKDF: Decodable {
        struct Key: Decodable {
            let info: String
            let keyHex: String
        }
        let rootSecretHex: String
        let keys: [String: Key]
    }

    struct SAS: Decodable {
        let code: String
    }

    struct QR: Decodable {
        let example: String
        let sBase64url: String
    }

    struct Envelope: Decodable {
        let keyHex: String
        let nonceHex: String
        let aad: String
        let plaintextUtf8: String
        let sealedBase64: String
    }

    struct SealedEnvelopes: Decodable {
        let signaling: Envelope
        let event: Envelope
    }

    /// Revision 1.1: the per-device keys that sign everything after bootstrap.
    struct DeviceKeys: Decodable {
        let cameraDeviceId: String
        let viewerDeviceId: String
        let cameraDeviceKeyBase64: String
        let viewerDeviceKeyBase64: String
    }

    struct AuthExample: Decodable {
        /// `bootstrap`, or a device UUID. Revision 1.1 replaced the role here.
        let principal: String
        let method: String
        let path: String
        let timestamp: String
        let bodyUtf8: String
        let bodySha256Hex: String
        let canonicalString: String
        let macHex: String
        let authorizationHeader: String
    }

    struct RequestAuth: Decodable {
        let pairingId: String
        /// Keyed by example name: `bootstrapCreate`, `bootstrapClaim`,
        /// `deviceCameraRevoke`, `deviceViewerTurnCredentials`.
        let examples: [String: AuthExample]
    }

    let version: Int
    let revision: String?
    let hkdf: HKDF
    let sas: SAS
    let qrPayload: QR
    let deviceKeys: DeviceKeys
    let sealedEnvelope: SealedEnvelopes
    let requestAuth: RequestAuth

    // MARK: - Loading

    static let resourceName = "kidscam-v1"
    static let resourceExtension = "json"

    static func load(file: StaticString = #filePath, line: UInt = #line) throws -> TestVectors {
        // Try each candidate location and take the first that actually reads:
        // a build system that copies the symlink rather than its target leaves a
        // resource URL that exists but cannot be opened.
        for url in candidateURLs(file: file) {
            guard let data = try? Data(contentsOf: url) else { continue }
            return try JSONDecoder().decode(TestVectors.self, from: data)
        }

        XCTFail(
            "Could not read shared/test-vectors/kidscam-v1.json from the test bundle "
                + "or the source tree",
            file: file,
            line: line
        )
        throw CocoaError(.fileNoSuchFile)
    }

    private static func candidateURLs(file: StaticString) -> [URL] {
        var urls: [URL] = []

        if let bundled = Bundle.module.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) {
            urls.append(bundled)
        }

        // Climb from this source file towards the repository root.
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            urls.append(
                directory
                    .appendingPathComponent("shared/test-vectors")
                    .appendingPathComponent("\(resourceName).\(resourceExtension)")
            )
            directory = directory.deletingLastPathComponent()
        }

        return urls
    }
}

// MARK: - Convenience

extension TestVectors {
    /// The pairing ID used throughout the vectors.
    var pairingUUID: UUID {
        UUID(uuidString: requestAuth.pairingId)!
    }

    func key(_ name: String) -> HKDF.Key {
        guard let key = hkdf.keys[name] else {
            fatalError("Test vector file is missing hkdf.keys.\(name)")
        }
        return key
    }

    func authExample(_ name: String) -> AuthExample {
        guard let example = requestAuth.examples[name] else {
            fatalError("Test vector file is missing requestAuth.examples.\(name)")
        }
        return example
    }
}
