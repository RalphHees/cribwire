import Foundation

/// Build-time configuration, read from `Info.plist` (which XcodeGen fills from
/// the `KIDSCAM_*` build settings in `project.yml`).
///
/// Nothing secret lives here — only identifiers and the default backend URL.
struct AppConfiguration {
    let appGroupIdentifier: String?
    let keychainAccessGroup: String?
    /// Backend the Camera registers new pairings with. The Viewer ignores this
    /// and uses the URL carried in the scanned QR code.
    let defaultAPIBaseURL: URL?

    static let current = AppConfiguration(bundle: .main)

    init(bundle: Bundle) {
        func string(_ key: String) -> String? {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  !value.isEmpty,
                  // An unsubstituted build setting is a configuration mistake,
                  // not a value.
                  !value.hasPrefix("$(")
            else { return nil }
            return value
        }

        self.appGroupIdentifier = string("KidsCamAppGroupIdentifier")
        self.keychainAccessGroup = string("KidsCamKeychainAccessGroup")
        self.defaultAPIBaseURL = string("KidsCamAPIBaseURL").flatMap(URL.init(string:))
    }

    init(
        appGroupIdentifier: String?,
        keychainAccessGroup: String?,
        defaultAPIBaseURL: URL?
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.keychainAccessGroup = keychainAccessGroup
        self.defaultAPIBaseURL = defaultAPIBaseURL
    }
}
