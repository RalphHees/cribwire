import Combine
import Foundation
import CribWireKit
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

    private let store: DetectionSettingsStore

    var isAboveThreshold: Bool { currentLevel > settings.noise.thresholdDBFS }

    init(defaults: UserDefaults = .standard) {
        let store = DetectionSettingsStore(defaults: defaults)
        self.store = store
        self.settings = store.load()
    }

    /// Feed from the audio tap while the settings screen is visible.
    func updateLevel(_ level: Double) {
        currentLevel = level
    }

    private func persist() {
        store.save(settings)
    }
}
