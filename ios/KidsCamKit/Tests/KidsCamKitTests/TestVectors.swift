import Foundation
import XCTest

/// Typed view of `shared/test-vectors/kidscam-v1.json`.
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

    struct AuthExample: Decodable {
        let role: String
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
        let examples: [AuthExample]
    }

    let version: Int
    let hkdf: HKDF
    let sas: SAS
    let qrPayload: QR
    let sealedEnvelope: SealedEnvelopes
    let requestAuth: RequestAuth

    // MARK: - Loading

    static let resourceName = "kidscam-v1"
    static let resourceExtension = "json"

    static func load(file: StaticString = #filePath, line: UInt = #line) throws -> TestVectors {
        let url = try locate(file: file, line: line)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TestVectors.self, from: data)
    }

    private static func locate(file: StaticString, line: UInt) throws -> URL {
        if let bundled = Bundle.module.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) {
            return bundled
        }

        // Fallback: climb from this source file to the repo root.
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = directory
                .appendingPathComponent("shared/test-vectors")
                .appendingPathComponent("\(resourceName).\(resourceExtension)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }

        XCTFail(
            "Could not locate shared/test-vectors/kidscam-v1.json",
            file: file,
            line: line
        )
        throw CocoaError(.fileNoSuchFile)
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
}
