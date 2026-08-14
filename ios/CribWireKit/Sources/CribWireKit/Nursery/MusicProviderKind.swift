import Foundation

/// A music service the Camera can play from.
///
/// The Viewer never talks to a music service itself — it asks the Camera, and the
/// Camera is the only device that holds a session with Apple Music or TIDAL. That
/// is deliberate: the phone in the nursery is the one with the speaker, and
/// keeping the account on that device alone means no listening history, token or
/// playlist name ever has to cross the pairing except inside the seal.
public enum MusicProviderKind: String, Codable, CaseIterable, Sendable {
    case appleMusic = "apple"
    case tidal = "tidal"

    /// Name to show a parent. Not localised: these are trademarks and read the
    /// same in every language the app ships in.
    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .tidal: return "TIDAL"
        }
    }
}
