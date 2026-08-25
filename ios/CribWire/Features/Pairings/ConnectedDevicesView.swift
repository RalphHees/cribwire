import CribWireKit
import SwiftUI

/// Who is connected right now, and what everything is called.
///
/// The same sheet on both sides of a pairing, deliberately. A parent holding the
/// Viewer and a parent standing at the Camera are asking the same question —
/// *who else is looking at this room* — and answering it two different ways
/// would mean two screens to keep in step. What differs is only what each device
/// can know: the Camera builds the roster from its own sessions, the Viewer
/// draws the copy the Camera sent it inside the sealed `status` message.
///
/// It is also where this device gets its name, because this is where a parent
/// discovers they need one: a list reading "iPhone, iPhone" is what sends
/// somebody looking for a rename.
struct ConnectedDevicesView: View {

    /// This device's role, which decides how the roster is worded — a Camera is
    /// being watched, a Viewer is watching alongside others.
    let role: PairingRole
    /// The peer's name, when there is a single peer: the Camera's name on a
    /// Viewer. `nil` on a peer too old to send one.
    let peerName: String?
    let connectedDevices: [ConnectedDevice]
    /// Whether a live session exists at all. Without it an empty roster is
    /// ambiguous — nobody watching, or nothing connected yet — and those read
    /// completely differently to somebody checking on a nursery.
    let isConnected: Bool

    @Environment(\.dismiss) private var dismiss

    /// Called after this device is renamed, so the live session can tell the
    /// peer straight away rather than at the next reconnect.
    var onRename: ((String) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metrics.stackSpacing) {
                    DeviceNameCard(role: role, onRename: onRename)
                    if role == .viewer { camera }
                    watching
                    footer
                }
                .frame(maxWidth: Theme.Metrics.readableWidth)
                .padding(Theme.Metrics.screenPadding)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.Palette.background.ignoresSafeArea())
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - The camera (viewer side)

    private var camera: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 8) {
                header("Camera", symbol: "video.fill")
                Text(peerName ?? String(localized: "Camera"))
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.text)
                if peerName == nil {
                    Text("This camera has not sent a name. Open CribWire on it to give it one.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Who is watching

    private var watching: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 12) {
                header(
                    role == .camera ? "Watching this room" : "Also watching",
                    symbol: "eye.fill"
                )

                if connectedDevices.isEmpty {
                    Text(emptyMessage)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(connectedDevices) { device in
                        row(for: device)
                    }
                }
            }
        }
    }

    /// Three different situations, and only one of them is "nobody is here".
    ///
    /// A Viewer whose Camera is too old to send a roster must not be told the
    /// room is unwatched — its own parent is watching it at that moment, which
    /// would make the sentence visibly false and the rest of the screen suspect.
    private var emptyMessage: String {
        guard isConnected else {
            return String(localized: "Nothing is connected right now.")
        }
        switch role {
        case .camera:
            return String(localized: "Nobody is watching this room right now.")
        case .viewer:
            return String(localized: "Nobody else is watching right now.")
        }
    }

    private func row(for device: ConnectedDevice) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "eye.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Palette.periwinkle)
                .frame(width: 34, height: 34)
                .background(
                    Theme.Palette.periwinkle.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 11)
                )

            VStack(alignment: .leading, spacing: 2) {
                // A peer that sent no name is drawn as its role rather than as a
                // blank row or a device id: "Viewer" is true, and an id is a
                // string nobody in a household recognises.
                Text(device.name ?? String(localized: "Viewer"))
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.text)
                if let since = device.since {
                    Text("Since \(since.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                }
            }

            Spacer(minLength: 8)
            KCPill(title: "Live", tint: Theme.Palette.live)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Chrome

    private func header(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textFaint)
            Text(title)
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.textFaint)
                .textCase(.uppercase)
        }
    }

    private var footer: some View {
        KCSecurityNote(
            text: "Names travel encrypted between your paired devices, like the video. Only devices that hold the pairing key can read them — the server never sees a name."
        )
    }
}
