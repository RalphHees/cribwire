import Foundation
import CribWireKit

/// Where the Camera's exposure setting lives.
///
/// The same shape and the same reasoning as `DetectionSettingsStore`: an ordinary
/// preference, nothing secret, so `UserDefaults` and not the Keychain. It has to
/// persist because it is a property of the *room* — a Camera that came back after
/// a restart with the picture black again would have to be re-tuned from the
/// other end of the house every time.
struct CameraSensitivityStore {

    static let key = "cribwire.cameraSensitivity"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Anything unreadable falls back to what the phone would do on its own,
    /// which is exactly how the Camera behaved before this setting existed.
    func load() -> CameraSensitivity {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(CameraSensitivity.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    func save(_ sensitivity: CameraSensitivity) {
        guard let data = try? JSONEncoder().encode(sensitivity) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
