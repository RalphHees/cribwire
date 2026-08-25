import CribWireKit

/// One music service as the Camera's own screen shows it.
///
/// Camera-side only, and deliberately not part of `NurseryState`: nothing here
/// ever crosses the pairing. A Viewer is told which services it may *choose*
/// between — `MusicState.availableProviders`, the connected ones — and never
/// which ones this phone could connect but has not. That is not secrecy for its
/// own sake; it is that the list of accounts a parent has not signed into is
/// only actionable in the room where the phone is, and a Viewer showing rows it
/// cannot act on is a Viewer inviting taps that do nothing.
struct MusicAccount: Equatable, Identifiable {

    var kind: MusicProviderKind

    /// Whether a parent has signed in — or, for Apple Music, granted access and
    /// left the service switched on here. See `MusicProvider.isConnected`.
    var isConnected: Bool

    /// Whether this is the service the Camera would play from right now.
    ///
    /// At most one account is active. It is the selection *and* connected: a
    /// service a parent signed out of is not what the room plays from, however
    /// the stored preference on this phone still reads.
    var isActive: Bool

    var id: MusicProviderKind { kind }
}
