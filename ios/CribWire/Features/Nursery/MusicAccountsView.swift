import CribWireKit
import SwiftUI
import UIKit

/// The Camera's music accounts: which services this phone is signed in to, and
/// the only place in CribWire where signing in and out happens.
///
/// It lives on the Camera because it has to. Every service here authenticates
/// through a web sheet or a system prompt, and one of those raised by a tap in
/// another room is a question nobody is standing in front of — the same rule
/// that keeps `MusicProvider.requestAuthorization` off every remote command
/// path. What the Viewer gets instead is the *result*: the services connected
/// here are exactly the ones it can choose between.
///
/// Written for the moment it is actually used — a parent setting the nursery up
/// with the light on, not somebody half asleep at 3 a.m. — so unlike
/// `NurseryControlsView` it can afford a sentence of explanation per row.
struct MusicAccountsView: View {

    let accounts: [MusicAccount]
    /// Both are the Camera's to perform and both take a moment: a web sheet, a
    /// system prompt, a token exchange. The view awaits them and shows which row
    /// is busy rather than blocking the screen.
    let connect: (MusicProviderKind) async -> Bool
    let disconnect: (MusicProviderKind) async -> Void

    @Environment(\.dismiss) private var dismiss

    /// The row with a sheet or a prompt in front of it. At most one: iOS will
    /// not present two, and a second tap while the first is up should look
    /// unavailable rather than queue something the parent has forgotten asking
    /// for.
    @State private var busyKind: MusicProviderKind?
    /// Services whose connect attempt was tried and left nothing changed.
    ///
    /// Only Apple Music does anything with it — see `button(for:)` — because it
    /// is the only one whose refusal is permanent. A dismissed TIDAL or Spotify
    /// sheet lands here too and is simply never read, which is cheaper than
    /// teaching this set which services it is allowed to remember.
    @State private var needsSettings: Set<MusicProviderKind> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metrics.stackSpacing) {
                    ForEach(accounts) { account in
                        card(for: account)
                    }
                    if accounts.isEmpty { emptyState }
                    footer
                }
                .frame(maxWidth: Theme.Metrics.readableWidth)
                .padding(Theme.Metrics.screenPadding)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.Palette.background.ignoresSafeArea())
            .navigationTitle("Music accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Rows

    private func card(for account: MusicAccount) -> some View {
        KCCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(account.kind.displayName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.text)
                    Spacer(minLength: 12)
                    status(for: account)
                }

                Text(explanation(for: account.kind))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if let warning = warning(for: account) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                button(for: account)
            }
        }
    }

    @ViewBuilder
    private func status(for account: MusicAccount) -> some View {
        if account.isActive {
            // Two facts, not one: connected, and the one the room is currently
            // playing from. A parent with three accounts connected needs to know
            // which one the Viewer's buttons will reach.
            KCPill(title: "Playing from", tint: Theme.Palette.live)
        } else if account.isConnected {
            KCPill(title: "Connected", tint: Theme.Palette.periwinkle)
        } else {
            KCPill(title: "Not connected", tint: Theme.Palette.textFaint, showsDot: false)
        }
    }

    @ViewBuilder
    private func button(for account: MusicAccount) -> some View {
        let isBusy = busyKind == account.kind

        if account.isConnected {
            Button {
                Task {
                    busyKind = account.kind
                    await disconnect(account.kind)
                    // Cleared on the way out: a service that has been signed out
                    // and back in should be able to ask iOS again rather than
                    // being permanently sent to Settings by a refusal from
                    // whoever used this phone last.
                    needsSettings.remove(account.kind)
                    busyKind = nil
                }
            } label: {
                Label(
                    isBusy ? String(localized: "Signing out…") : String(localized: "Sign out"),
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(KCGhostButtonStyle())
            .disabled(busyKind != nil)
        } else if needsSettings.contains(account.kind), account.kind == .appleMusic {
            // iOS shows the music-library prompt exactly once. A second tap on
            // Allow after it has been refused does nothing at all, so once
            // asking has visibly failed the Settings app is the only thing that
            // can still work.
            //
            // True of Apple Music and of nothing else here: a signed-out TIDAL
            // or Spotify is an account, which Settings has no opinion about
            // whatsoever, and a web sheet can be dismissed and raised again as
            // often as anyone likes.
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Allow music in Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KCGhostButtonStyle())
        } else {
            Button {
                Task {
                    busyKind = account.kind
                    let connected = await connect(account.kind)
                    if !connected { needsSettings.insert(account.kind) }
                    busyKind = nil
                }
            } label: {
                Label(
                    isBusy ? String(localized: "Connecting…") : connectLabel(for: account.kind),
                    systemImage: "music.note"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(KCPrimaryButtonStyle())
            .disabled(busyKind != nil)
        }
    }

    /// What the button is offering to do, which is a different act on each
    /// service: Apple Music needs iOS's permission to read the library on this
    /// phone, the other two need an account signed in to them. One label for all
    /// three would have to be vague enough to describe none.
    private func connectLabel(for kind: MusicProviderKind) -> String {
        switch kind {
        case .appleMusic: return String(localized: "Allow music access")
        case .tidal: return String(localized: "Sign in to TIDAL")
        case .spotify: return String(localized: "Sign in to Spotify")
        }
    }

    private func explanation(for kind: MusicProviderKind) -> String {
        switch kind {
        case .appleMusic:
            return String(
                localized: "Plays your library and playlists through this phone's speaker. Needs an Apple Music subscription to start something new."
            )
        case .tidal:
            return String(
                localized: "Signs in with your TIDAL account and plays through this phone's speaker. Needs an active TIDAL subscription."
            )
        case .spotify:
            return String(
                localized: "Plays through the Spotify app on this phone, which CribWire starts for you. Needs Spotify Premium."
            )
        }
    }

    /// The one thing a parent can act on that no status pill can express.
    ///
    /// Spotify is the only provider that cannot play on its own: its catalogue
    /// may only be played by the Spotify app, so a phone without it installed
    /// will sign in perfectly and then stay silent. Saying so here — where the
    /// parent is standing at the phone — is the difference between a fixable
    /// problem and a mystery reported from another room.
    private func warning(for account: MusicAccount) -> String? {
        guard account.kind == .spotify, !SpotifySession.shared.isSpotifyAppInstalled else {
            return nil
        }
        return String(
            localized: "Install the Spotify app on this phone. CribWire plays Spotify through it, so music will not start without it."
        )
    }

    private var emptyState: some View {
        KCCard {
            Text("No music services are set up for this app. Music is optional — everything else in CribWire works without it.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        KCSecurityNote(
            text: "Accounts stay on this phone. Whoever is watching can choose between the services you connect here and press play — they never see your account, and they cannot sign you in or out."
        )
    }
}
