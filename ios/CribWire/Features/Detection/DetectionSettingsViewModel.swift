import Foundation
import CribWireKit
import SwiftUI

/// Backs the camera's alert settings screen.
///
/// Settings are ordinary preferences, not secrets, so they live in
/// `UserDefaults` — nothing here is key material and nothing belongs in the
/// Keychain. Both detectors persist as **off** until the user opts in.
@MainActor
@Observable
final class DetectionSettingsViewModel {

    /// Computed over `storedSettings` rather than carrying a `didSet`: the
    /// `@Observable` macro turns stored properties into get/set accessors, and a
    /// property cannot have both accessors and observers. Writes still land on
    /// the tracked stored property, so bindings and redraws behave as before.
    var settings: DetectionSettings {
        get { storedSettings }
        set {
            storedSettings = newValue
            store.save(newValue)
        }
    }

    private var storedSettings: DetectionSettings

    /// Most recent room level in dBFS, driven by the capture pipeline so the
    /// user can calibrate the threshold against the actual room.
    private(set) var currentLevel: Double = NoiseDetectionSettings.thresholdRange
        .lowerBound

    private let store: DetectionSettingsStore

    var isAboveThreshold: Bool { currentLevel > settings.noise.thresholdDBFS }

    init(defaults: UserDefaults = .standard) {
        let store = DetectionSettingsStore(defaults: defaults)
        self.store = store
        // Straight to the backing store: assigning through `settings` would save
        // the value it was just loaded from back to UserDefaults.
        self.storedSettings = store.load()
    }

    /// Feed from the audio tap while the settings screen is visible.
    func updateLevel(_ level: Double) {
        currentLevel = level
    }
}
