import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The one envelope format KidsCam uses for everything the backend relays:
/// signaling blobs (`K_sig`) and push event payloads (`K_evt`).
///
/// Normative layout (`shared/protocol.md`):
///
/// ```
/// sealed = base64( nonce(12) || ChaCha20-Poly1305-ct || tag(16) )
/// ```
///
/// which is exactly CryptoKit's `ChaChaPoly.SealedBox.combined` representation,
/// base64-encoded with standard alphabet and padding. The AAD binds each
/// ciphertext to its pairing and its purpose so a signaling blob can never be
/// replayed as an event, or a camera blob as a viewer blob.
public enum SealedEnvelope {

    // MARK: - Associated data

    /// The additional authenticated data prefixed to every envelope.
    ///
    /// UTF-8 of `<pairingId>|<senderRole>` for signaling and
    /// `<pairingId>|event` for events, where `pairingId` is the lowercase UUID.
    public enum AssociatedData: Equatable, Sendable {
        case signaling(pairingID: UUID, senderRole: PairingRole)
        case event(pairingID: UUID)

        public var stringValue: String {
            switch self {
            case .signaling(let pairingID, let senderRole):
                return "\(pairingID.kc_lowercasedString)|\(senderRole.rawValue)"
            case .event(let pairingID):
                return "\(pairingID.kc_lowercasedString)|event"
            }
        }

        var bytes: Data { Data(stringValue.utf8) }
    }

    // MARK: - Constants

    /// ChaCha20-Poly1305 nonce length in bytes.
    public static let nonceByteCount = 12
    /// Poly1305 tag length in bytes.
    public static let tagByteCount = 16

    // MARK: - Seal

    /// Seals `plaintext` under `key` with a fresh random 96-bit nonce.
    ///
    /// - Returns: the base64 envelope, ready to put in a signaling frame or an
    ///   APNs payload.
    public static func seal(
        _ plaintext: Data,
        using key: SymmetricKey,
        associatedData: AssociatedData
    ) throws -> String {
        try seal(plaintext, using: key, associatedData: associatedData, nonce: nil)
    }

    /// Nonce injection exists only so the shared test vectors — which fix the
    /// nonce — can be reproduced. Production callers use the public overload and
    /// always get a random nonce.
    static func seal(
        _ plaintext: Data,
        using key: SymmetricKey,
        associatedData: AssociatedData,
        nonce: ChaChaPoly.Nonce?
    ) throws -> String {
        do {
            let box = try ChaChaPoly.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: associatedData.bytes
            )
            return box.combined.base64EncodedString()
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    // MARK: - Open

    /// Opens a base64 envelope.
    ///
    /// - Throws: `CryptoError.malformedEnvelope` when the input is not base64 or
    ///   is too short to hold a nonce and a tag; `CryptoError.authenticationFailed`
    ///   for a wrong key, wrong AAD or tampered bytes. Callers must not
    ///   distinguish the failure modes to the user or in logs.
    public static func open(
        _ sealedBase64: String,
        using key: SymmetricKey,
        associatedData: AssociatedData
    ) throws -> Data {
        guard let combined = Data(base64Encoded: sealedBase64),
              combined.count >= nonceByteCount + tagByteCount
        else {
            throw CryptoError.malformedEnvelope
        }

        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: combined)
        } catch {
            throw CryptoError.malformedEnvelope
        }

        do {
            return try ChaChaPoly.open(box, using: key, authenticating: associatedData.bytes)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }
}

// MARK: - UUID formatting

extension UUID {
    /// The lowercase UUID string the protocol pins for `pairingId` in both the
    /// QR payload and every AAD.
    var kc_lowercasedString: String { uuidString.lowercased() }
}
