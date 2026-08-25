import CribWireKit
import SwiftUI

/// Naming this device, wherever a parent goes looking for it.
///
/// Its own view because it appears in two places, and it appears in two places
/// because people look for a nickname in both: on the devices sheet, next to the
/// list of names it explains, and at the top of the paired-devices screen, which
/// is where "what are my devices called" sounds like it should live.
///
/// The field is always live — there is no Rename button to press first. An
/// edit-mode toggle is one more thing to get stuck in, and on a screen whose job
/// is "make these two phones tell each other apart" the fastest correct design
/// is a text field that is simply a text field.
struct DeviceNameCard: View {

    /// This device's role, used only for the example in the hint: a camera is
    /// somewhere, a viewer is with someone.
    let role: PairingRole
    /// Called after a new name has been saved, so a live session can tell the
    /// peer about it. `nil` where there is no session to tell — the
    /// paired-devices screen, which is not connected to anything.
    var onRename: ((String) -> Void)?

    @State private var draft: String
    @State private var savedName: String
    @FocusState private var isFocused: Bool

    private let store = DeviceNameStore()

    init(role: PairingRole, onRename: ((String) -> Void)? = nil) {
        self.role = role
        self.onRename = onRename
        let current = DeviceNameStore().load()
        _draft = State(initialValue: current)
        _savedName = State(initialValue: current)
    }

    var body: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: role == .camera ? "video.fill" : "eye.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textFaint)
                    Text("This device")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.textFaint)
                        .textCase(.uppercase)
                }

                HStack(spacing: 10) {
                    TextField(text: $draft) {
                        Text(DeviceNameStore.suggested)
                    }
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Theme.Palette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
                    )
                    .accessibilityLabel(Text("Device name"))

                    // Only while there is something to save. A button that is
                    // always there and usually does nothing teaches people that
                    // pressing it is pointless, which is a bad thing to teach on
                    // the one control that has to be pressed.
                    if hasUnsavedChange {
                        Button("Save", action: commit)
                            .buttonStyle(KCPrimaryButtonStyle())
                            .fixedSize()
                    }
                }

                Text(hint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasUnsavedChange: Bool {
        DeviceName.sanitized(draft) != DeviceName.sanitized(savedName)
    }

    private var hint: String {
        guard !store.hasCustomName else {
            return String(
                localized: "Your paired devices show this name. It travels encrypted and never reaches the server."
            )
        }
        // Until it is renamed, every phone in the house answers to the same
        // model name — which is the whole reason this control exists.
        return role == .camera
            ? String(localized: "Give this camera a name — “Nursery” — so the other device can tell it apart.")
            : String(localized: "Give this device a name — “Kitchen” — so the camera can tell it apart.")
    }

    private func commit() {
        store.save(draft)
        // Re-read rather than trusting the field: the store trims, collapses and
        // caps, and what is shown has to be what the peer will actually be sent.
        let saved = store.load()
        draft = saved
        savedName = saved
        isFocused = false
        onRename?(saved)
    }
}
