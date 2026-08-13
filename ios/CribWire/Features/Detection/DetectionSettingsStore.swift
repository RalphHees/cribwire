import Foundation
import CribWireKit

/// Where the Camera's alert settings live.
///
/// Ordinary preferences, not secrets — nothing here is key material, so
/// `UserDefaults` is the right home and the Keychain is not. It exists as its own
/// type because two unrelated places need the same values: the settings screen
/// that edits them, and the streaming engine, which has to know whether a
/// detector is still consuming frames before it stops the capture pipeline.
struct DetectionSettingsStore {

    static let key = "cribwire.detectionSettings"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Falls back to the defaults — both detectors off — for anything unreadable.
    func load() -> DetectionSettings {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(DetectionSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    func save(_ settings: DetectionSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
