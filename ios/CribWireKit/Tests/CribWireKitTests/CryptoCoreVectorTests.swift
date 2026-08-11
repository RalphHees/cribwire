import XCTest
@testable import CribWireKit

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Contract tests against `shared/test-vectors/cribwire-v1.json`.
///
/// These are the tests that keep the iOS app and the Node backend byte-compatible.
/// If one of them fails, the wire format changed and both implementations plus the
/// vector file have to move together (`shared/protocol.md`).
final class CryptoCoreVectorTests: XCTestCase {

    private var vectors: TestVectors!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vectors = try TestVectors.load()
        XCTAssertEqual(vectors.version, 1, "Vector file version changed — review the protocol")
    }

    // MARK: - HKDF

    func testDerivesAllFourKeysFromVectorRootSecret() throws {
        let rootSecret = try makeRootSecret()
        let keys = rootSecret.deriveKeys()

        assertKey(keys.auth, matches: "k_auth")
        assertKey(keys.signaling, matches: "k_sig")
        assertKey(keys.event, matches: "k_evt")
        assertKey(keys.sas, matches: "k_sas")
    }

    func testInfoStringsMatchTheVectorFile() {
        // The `info` strings are normative; a typo here silently breaks interop
        // without breaking anything locally, so assert them explicitly.
        XCTAssertEqual(PairingKeys.Info.auth, vectors.key("k_auth").info)
        XCTAssertEqual(PairingKeys.Info.signaling, vectors.key("k_sig").info)
        XCTAssertEqual(PairingKeys.Info.event, vectors.key("k_evt").info)
        XCTAssertEqual(PairingKeys.Info.sas, vectors.key("k_sas").info)
    }

    func testRootSecretRejectsWrongLength() {
        XCTAssertThrowsError(try RootSecret(bytes: Data(repeating: 0, count: 31))) { error in
            XCTAssertEqual(
                error as? CryptoError,
                .invalidRootSecretLength(expected: 32, actual: 31)
            )
        }
    }

    func testGeneratedSecretsAreDistinctAndCorrectlySized() throws {
        let first = try RootSecret.generate()
        let second = try RootSecret.generate()
        XCTAssertEqual(first.rawBytesForKeychainStorage.count, RootSecret.byteCount)
        XCTAssertNotEqual(
            first.rawBytesForKeychainStorage,
            second.rawBytesForKeychainStorage
        )
    }

    func testRootSecretDescriptionNeverLeaksBytes() throws {
        let secret = try makeRootSecret()
        XCTAssertFalse(secret.description.contains("000102"))
        XCTAssertTrue(secret.description.contains("redacted"))
    }

    // MARK: - SAS

    func testSASCodeMatchesVector() throws {
        let keys = try makeRootSecret().deriveKeys()
        XCTAssertEqual(keys.sasCode.digits, vectors.sas.code)
        XCTAssertEqual(keys.sasCode.digits.count, 6)
    }

    func testSASCodeIsZeroPaddedToSixDigits() {
        // First four bytes 0x00000001 → 1 → "000001".
        var bytes = Data(repeating: 0, count: 32)
        bytes[3] = 1
        let code = SASCode(derivedFrom: SymmetricKey(data: bytes))
        XCTAssertEqual(code.digits, "000001")
    }

    func testSASCodeTakesModuloOfBigEndianUInt32() {
        // 0xFFFFFFFF = 4294967295 → mod 1e6 = 967295.
        var bytes = Data(repeating: 0, count: 32)
        for index in 0..<4 { bytes[index] = 0xFF }
        XCTAssertEqual(SASCode(derivedFrom: SymmetricKey(data: bytes)).digits, "967295")
    }

    func testSASConstantTimeComparison() throws {
        let code = try makeRootSecret().deriveKeys().sasCode
        XCTAssertTrue(code.matches(SASCode(digits: vectors.sas.code)))
        XCTAssertFalse(code.matches(SASCode(digits: "000000")))
        // Same first digits, different tail — must still be rejected.
        let nearMiss = SASCode(digits: String(vectors.sas.code.dropLast()) + "0")
        XCTAssertNotEqual(nearMiss.digits, code.digits)
        XCTAssertFalse(code.matches(nearMiss))
    }

    // MARK: - Sealed envelope

    func testSealsSignalingEnvelopeExactlyAsInVector() throws {
        let vector = vectors.sealedEnvelope.signaling
        let sealed = try SealedEnvelope.seal(
            Data(vector.plaintextUtf8.utf8),
            using: try key(hex: vector.keyHex),
            associatedData: .signaling(pairingID: vectors.pairingUUID, senderRole: .camera),
            nonce: try nonce(hex: vector.nonceHex)
        )
        XCTAssertEqual(sealed, vector.sealedBase64)
    }

    func testSealsEventEnvelopeExactlyAsInVector() throws {
        let vector = vectors.sealedEnvelope.event
        let sealed = try SealedEnvelope.seal(
            Data(vector.plaintextUtf8.utf8),
            using: try key(hex: vector.keyHex),
            associatedData: .event(pairingID: vectors.pairingUUID),
            nonce: try nonce(hex: vector.nonceHex)
        )
        XCTAssertEqual(sealed, vector.sealedBase64)
    }

    func testAssociatedDataStringsMatchVector() {
        XCTAssertEqual(
            SealedEnvelope.AssociatedData
                .signaling(pairingID: vectors.pairingUUID, senderRole: .camera)
                .stringValue,
            vectors.sealedEnvelope.signaling.aad
        )
        XCTAssertEqual(
            SealedEnvelope.AssociatedData
                .event(pairingID: vectors.pairingUUID)
                .stringValue,
            vectors.sealedEnvelope.event.aad
        )
    }

    func testOpensBothVectorEnvelopes() throws {
        let signaling = vectors.sealedEnvelope.signaling
        let openedSignaling = try SealedEnvelope.open(
            signaling.sealedBase64,
            using: try key(hex: signaling.keyHex),
            associatedData: .signaling(pairingID: vectors.pairingUUID, senderRole: .camera)
        )
        XCTAssertEqual(String(decoding: openedSignaling, as: UTF8.self), signaling.plaintextUtf8)

        let event = vectors.sealedEnvelope.event
        let openedEvent = try SealedEnvelope.open(
            event.sealedBase64,
            using: try key(hex: event.keyHex),
            associatedData: .event(pairingID: vectors.pairingUUID)
        )
        XCTAssertEqual(String(decoding: openedEvent, as: UTF8.self), event.plaintextUtf8)
    }

    func testRandomNonceRoundTripsAndIsNeverReused() throws {
        let sessionKey = SymmetricKey(size: .bits256)
        let aad = SealedEnvelope.AssociatedData
            .signaling(pairingID: vectors.pairingUUID, senderRole: .viewer)
        let plaintext = Data(#"{"t":"ice","c":"candidate:1"}"#.utf8)

        let first = try SealedEnvelope.seal(plaintext, using: sessionKey, associatedData: aad)
        let second = try SealedEnvelope.seal(plaintext, using: sessionKey, associatedData: aad)

        XCTAssertNotEqual(first, second, "Nonce must be fresh for every message")
        XCTAssertEqual(
            try SealedEnvelope.open(first, using: sessionKey, associatedData: aad),
            plaintext
        )
        XCTAssertEqual(
            try SealedEnvelope.open(second, using: sessionKey, associatedData: aad),
            plaintext
        )
    }

    // MARK: - Tamper rejection

    func testRejectsFlippedCiphertextBit() throws {
        let vector = vectors.sealedEnvelope.signaling
        var raw = Data(base64Encoded: vector.sealedBase64)!
        // Flip a bit inside the ciphertext (after the 12-byte nonce).
        raw[SealedEnvelope.nonceByteCount] ^= 0x01

        XCTAssertThrowsError(
            try SealedEnvelope.open(
                raw.base64EncodedString(),
                using: try key(hex: vector.keyHex),
                associatedData: .signaling(pairingID: vectors.pairingUUID, senderRole: .camera)
            )
        ) { XCTAssertEqual($0 as? CryptoError, .authenticationFailed) }
    }

    func testRejectsFlippedTagBit() throws {
        let vector = vectors.sealedEnvelope.event
        var raw = Data(base64Encoded: vector.sealedBase64)!
        raw[raw.count - 1] ^= 0x80

        XCTAssertThrowsError(
            try SealedEnvelope.open(
                raw.base64EncodedString(),
                using: try key(hex: vector.keyHex),
                associatedData: .event(pairingID: vectors.pairingUUID)
            )
        ) { XCTAssertEqual($0 as? CryptoError, .authenticationFailed) }
    }

    func testRejectsWrongSenderRoleInAAD() throws {
        // A camera blob replayed as if it came from the viewer must not open —
        // this is the role binding from security.md §4.
        let vector = vectors.sealedEnvelope.signaling
        XCTAssertThrowsError(
            try SealedEnvelope.open(
                vector.sealedBase64,
                using: try key(hex: vector.keyHex),
                associatedData: .signaling(pairingID: vectors.pairingUUID, senderRole: .viewer)
            )
        ) { XCTAssertEqual($0 as? CryptoError, .authenticationFailed) }
    }

    func testRejectsWrongPairingIDInAAD() throws {
        let vector = vectors.sealedEnvelope.event
        XCTAssertThrowsError(
            try SealedEnvelope.open(
                vector.sealedBase64,
                using: try key(hex: vector.keyHex),
                associatedData: .event(pairingID: UUID())
            )
        ) { XCTAssertEqual($0 as? CryptoError, .authenticationFailed) }
    }

    func testRejectsSignalingEnvelopeOpenedAsEvent() throws {
        // Cross-purpose replay: right pairing, right key material shape, wrong
        // context string.
        let vector = vectors.sealedEnvelope.signaling
        XCTAssertThrowsError(
            try SealedEnvelope.open(
                vector.sealedBase64,
                using: try key(hex: vector.keyHex),
                associatedData: .event(pairingID: vectors.pairingUUID)
            )
        ) { XCTAssertEqual($0 as? CryptoError, .authenticationFailed) }
    }

    func testRejectsWrongKey() throws {
        let vector = vectors.sealedEnvelope.signaling
        XCTAssertThrowsError(
            try SealedEnvelope.open(
                vector.sealedBase64,
                using: SymmetricKey(size: .bits256),
                associatedData: .signaling(pairingID: vectors.pairingUUID, senderRole: .camera)
            )
        ) { XCTAssertEqual($0 as? CryptoError, .authenticationFailed) }
    }

    func testRejectsNonBase64AndTruncatedEnvelopes() throws {
        let aad = SealedEnvelope.AssociatedData.event(pairingID: vectors.pairingUUID)
        let randomKey = SymmetricKey(size: .bits256)

        XCTAssertThrowsError(
            try SealedEnvelope.open("not base64 at all!!", using: randomKey, associatedData: aad)
        ) { XCTAssertEqual($0 as? CryptoError, .malformedEnvelope) }

        // 27 bytes: one short of nonce(12) + tag(16).
        let tooShort = Data(repeating: 0, count: 27).base64EncodedString()
        XCTAssertThrowsError(
            try SealedEnvelope.open(tooShort, using: randomKey, associatedData: aad)
        ) { XCTAssertEqual($0 as? CryptoError, .malformedEnvelope) }
    }

    // MARK: - Helpers

    private func makeRootSecret() throws -> RootSecret {
        let bytes = try XCTUnwrap(Data.kc_fromHex(vectors.hkdf.rootSecretHex))
        return try RootSecret(bytes: bytes)
    }

    private func key(hex: String) throws -> SymmetricKey {
        SymmetricKey(data: try XCTUnwrap(Data.kc_fromHex(hex)))
    }

    private func nonce(hex: String) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: try XCTUnwrap(Data.kc_fromHex(hex)))
    }

    private func assertKey(
        _ key: SymmetricKey,
        matches vectorName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            key.kc_dataRepresentation.kc_hexEncodedString,
            vectors.key(vectorName).keyHex,
            "HKDF output for \(vectorName) does not match the shared vector",
            file: file,
            line: line
        )
    }
}
