import Foundation

/// A music service the Camera can play from.
///
/// The Viewer never talks to a music service itself — it asks the Camera, and the
/// Camera is the only device that holds a session with a music service. That is
/// deliberate: the phone in the nursery is the one with the speaker, and keeping
/// the account on that device alone means no listening history, token or playlist
/// name ever has to cross the pairing except inside the seal.
///
/// It is also why **signing in and out happens on the Camera and nowhere else**.
/// Every service here authenticates through a web sheet or a system prompt, and
/// one of those raised by a tap on another phone is a question nobody is standing
/// in front of. So a Viewer chooses between the accounts a parent has already
/// connected — see `MusicState.availableProviders`, which carries exactly those —
/// and never sees the ones they have not.
public enum MusicProviderKind: String, Codable, CaseIterable, Sendable {
    case appleMusic = "apple"
    case tidal = "tidal"
    case spotify = "spotify"

    /// Name to show a parent. Not localised: these are trademarks and read the
    /// same in every language the app ships in.
    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .tidal: return "TIDAL"
        case .spotify: return "Spotify"
        }
    }
}
