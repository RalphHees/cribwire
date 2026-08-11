import CribWireKit
import SwiftUI

/// The list of paired devices with per-pairing revocation
/// (`ios-app.md` §2.2, `security.md` §6).
///
/// Revocation is two-sided on purpose: the backend `DELETE` cuts the peer off
/// from signaling, TURN and pushes, and the local wipe destroys this device's
/// copy of the keys. The local half runs even if the network call fails, because
/// a user who taps "Remove" must not be left with a pairing that still works.
struct PairedDevicesView: View {
    @EnvironmentObject private var services: AppServices
    @State private var pendingRevocation: PairingRecord?
    @State private var revokingIDs: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        KCScreen {
            ScrollView {
                VStack(spacing: 12) {
                    if services.pairings.isEmpty {
                        emptyState
                    } else {
                        ForEach(services.pairings) { record in
                            row(for: record)
                        }
                    }

                    if let errorMessage {
                        KCInlineError(message: errorMessage)
                    }
                }
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("Paired devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await services.reloadPairings() }
        .confirmationDialog(
            "Remove this pairing?",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRevocation
        ) { record in
            Button("Remove", role: .destructive) {
                let target = record
                pendingRevocation = nil
                Task { await revoke(target) }
            }
            Button("Cancel", role: .cancel) { pendingRevocation = nil }
        } message: { _ in
            Text("The other device loses access immediately and the keys on this device are erased. Pairing again means scanning a new code.")
        }
    }

    // MARK: - Rows

    private func row(for record: PairingRecord) -> some View {
        KCCard {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: record.localRole == .camera ? "eye.fill" : "video.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent(for: record.localRole.peer))
                    .frame(width: 44, height: 44)
                    .background(
                        Theme.accent(for: record.localRole.peer).opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 14)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.displayName)
                        .font(.system(size: 17, weight: .semibold))
                    Text("Paired \(record.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.textMuted)
                    KCPill(title: "End-to-end encrypted", tint: Theme.Palette.live, showsDot: false)
                        .padding(.top, 2)
                }

                Spacer(minLength: 8)

                if revokingIDs.contains(record.id) {
                    ProgressView().tint(Theme.Palette.textMuted)
                } else {
                    Button {
                        pendingRevocation = record
                    } label: {
                        Text("Remove")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.Palette.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove pairing with \(record.displayName)")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(Theme.Palette.textFaint)
            Text("No paired devices yet")
                .font(Theme.Typography.title)
            Text("Pair a device by showing its QR code on the Camera and scanning it with the Viewer.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 60)
    }

    // MARK: - Revocation

    private func revoke(_ record: PairingRecord) async {
        revokingIDs.insert(record.id)
        defer { revokingIDs.remove(record.id) }
        errorMessage = nil

        do {
            if let client = try await services.makeAPIClient(for: record) {
                switch record.localRole {
                case .camera:
                    if let viewerDeviceID = record.peerDeviceID {
                        try await client.revokeViewer(deviceID: viewerDeviceID)
                    } else {
                        try await client.revokePairing()
                    }
                case .viewer:
                    // A Viewer removing a Camera drops the whole pairing for
                    // itself; the Camera keeps its other viewers.
                    try await client.revokePairing()
                }
            }
        } catch {
            // Server-side revocation failed (offline, already gone). Say so, but
            // still erase the local keys below — leaving them would be worse.
            errorMessage = (error as? APIError)?.userFacingMessage
                ?? "The server could not be reached. The keys on this device were erased anyway."
        }

        await services.forgetPairing(record.id)
    }
}
