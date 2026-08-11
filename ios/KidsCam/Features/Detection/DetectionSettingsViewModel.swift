import Combine
import Foundation
import KidsCamKit
import SwiftUI

/// Backs the camera's alert settings screen.
///
/// Settings are ordinary preferences, not secrets, so they live in
/// `UserDefaults` — nothing here is key material and nothing belongs in the
/// Keychain. Both detectors persist as **off** until the user opts in.
@MainActor
final class DetectionSettingsViewModel: ObservableObject {

    @Published var settings: DetectionSettings {
        didSet { persist() }
    }

    /// Most recent room level in dBFS, driven by the capture pipeline so the
    /// user can calibrate the threshold against the actual room.
    @Published private(set) var currentLevel: Double = NoiseDetectionSettings.thresholdRange
        .lowerBound

    private let defaults: UserDefaults
    private static let settingsKey = "kidscam.detectionSettings"

    var isAboveThreshold: Bool { currentLevel > settings.noise.thresholdDBFS }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
            let decoded = try? JSONDecoder().decode(DetectionSettings.self, from: data)
        {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    /// Feed from the audio tap while the settings screen is visible.
    func updateLevel(_ level: Double) {
        currentLevel = level
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }
}
