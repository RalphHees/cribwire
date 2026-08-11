import Foundation
import CribWireKit

/// Non-secret metadata about a pairing: who it is with, where its backend is,
/// when it was made.
///
/// Deliberately contains no key material — every secret lives in the Keychain
/// (`PairingSecretsStore`). This is the record the paired-devices list renders.
struct PairingRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// This device's role in the pairing.
    var localRole: PairingRole
    /// Backend base URL for this pairing (from the QR code on the Viewer, from
    /// configuration on the Camera).
    var apiBaseURL: URL
    /// The peer's device ID as assigned by the backend — needed to revoke one
    /// viewer specifically.
    var peerDeviceID: String?
    /// This device's own ID as assigned by the backend, for token rotation.
    var localDeviceID: String?
    /// User-visible name ("Nursery"). Defaults are role-based.
    var displayName: String
    var pairedAt: Date

    init(
        id: UUID,
        localRole: PairingRole,
        apiBaseURL: URL,
        peerDeviceID: String? = nil,
        localDeviceID: String? = nil,
        displayName: String? = nil,
        pairedAt: Date = Date()
    ) {
        self.id = id
        self.localRole = localRole
        self.apiBaseURL = apiBaseURL
        self.peerDeviceID = peerDeviceID
        self.localDeviceID = localDeviceID
        self.displayName = displayName ?? (localRole == .camera ? "Viewer" : "Camera")
        self.pairedAt = pairedAt
    }
}

/// JSON-file store for `PairingRecord`s, in the app's Application Support
/// directory (app-private, excluded from iCloud backup for tidiness).
///
/// An actor so the file is never read and written concurrently; `UserDefaults` is
/// deliberately not used, to keep a hard rule that nothing pairing-related goes
/// into a plist an attacker with file access can trivially enumerate alongside
/// preferences.
actor PairingRegistry {

    private let fileURL: URL
    private var cache: [PairingRecord]?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: `<Application Support>/CribWire/pairings.json`.
    static func makeDefault() throws -> PairingRegistry {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("CribWire", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PairingRegistry(fileURL: directory.appendingPathComponent("pairings.json"))
    }

    // MARK: - Reading

    func all() throws -> [PairingRecord] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let records = (try? JSONDecoder().decode([PairingRecord].self, from: data)) ?? []
        cache = records
        return records
    }

    func record(for pairingID: UUID) throws -> PairingRecord? {
        try all().first { $0.id == pairingID }
    }

    // MARK: - Writing

    func upsert(_ record: PairingRecord) throws {
        var records = try all()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try persist(records)
    }

    func remove(pairingID: UUID) throws {
        let records = try all().filter { $0.id != pairingID }
        try persist(records)
    }

    func removeAll() throws {
        try persist([])
    }

    private func persist(_ records: [PairingRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        cache = records
    }
}
