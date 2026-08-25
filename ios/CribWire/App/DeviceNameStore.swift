import CribWireKit
import Foundation
import UIKit

/// What this phone calls itself to the devices it is paired with.
///
/// ## Why a stored name and not the device's own
///
/// The obvious source is `UIDevice.current.name`, and it is not available: since
/// iOS 16 it answers the *model* ("iPhone") to any app without a special
/// entitlement, because a name a person set for AirDrop years ago frequently
/// contains their full name and was never meant to travel.
///
/// That restriction points the right way for CribWire regardless. A name here is
/// sent to another household device and drawn on its screen, so it should be one
/// somebody chose for this purpose — "Nursery", "Landing" — rather than one
/// inherited from a setup assistant. The model is only the starting point, and
/// `hasCustomName` is what lets the UI tell the two apart and nudge.
///
/// `UserDefaults`, deliberately: this is a label, not a credential. It says
/// nothing that is not already visible to anyone holding the phone.
struct DeviceNameStore {

    static let key = "cribwire.deviceName"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The name to send, always something: a phone that has never been renamed
    /// still has to introduce itself, and "iPhone" is a better answer on another
    /// device's screen than a blank row.
    func load() -> String {
        stored ?? Self.suggested
    }

    /// Whether a person has actually chosen this, as opposed to it being the
    /// model name this type made up. Two phones in a house are both "iPhone",
    /// which is exactly the situation this feature exists to fix — so the UI
    /// offers a rename rather than leaving a parent to guess which is which.
    var hasCustomName: Bool { stored != nil }

    /// Saves a name, or clears it back to the default when what is left says
    /// nothing.
    ///
    /// Sanitised through the same path a *peer's* name takes on the way in, so
    /// the name this device sends can never be one it would refuse to receive —
    /// which is the sort of asymmetry that shows up as a name that silently
    /// truncates on one screen and not the other.
    func save(_ raw: String) {
        guard let name = DeviceName.sanitized(raw) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(name, forKey: Self.key)
    }

    private var stored: String? {
        defaults.string(forKey: Self.key).flatMap(DeviceName.sanitized)
    }

    /// The fallback: what kind of device this is.
    ///
    /// `model` rather than `name` because they are the same string on iOS 16 and
    /// later, and this one says so honestly instead of looking like a name that
    /// happens to be generic.
    static var suggested: String {
        DeviceName.sanitized(UIDevice.current.model) ?? "Device"
    }
}
