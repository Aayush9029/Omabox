import Sharing
import SwiftUI

struct SharingPane: View {
    let model: OmaboxModel

    private var canChangeDevices: Bool {
        switch model.state {
        case .absent, .ready, .failed: true
        default: false
        }
    }

    var body: some View {
        SettingsForm {
            Section("Clipboard") {
                Toggle("Share text clipboard", isOn: Binding(
                    get: { model.preferences.clipboardEnabled },
                    set: { isEnabled in
                        model.$preferences.clipboardEnabled.withLock { $0 = isEnabled }
                        model.clipboardPreferenceChanged()
                    }
                ))
                    .accessibilityIdentifier("settings.clipboardSharing")
                Text("Sharing requires the clipboard service inside Linux. Images and files are not shared through the clipboard.")
                    .settingFootnote()
            }

            Section("Microphone") {
                Toggle("Use the Mac microphone", isOn: Binding(
                    get: { model.preferences.microphoneEnabled },
                    set: { _ in Task { await model.microphoneButtonTapped() } }
                ))
                .disabled(!canChangeDevices)
                Text(canChangeDevices
                    ? "macOS asks for access when you enable this. Linux apps also control their own microphone permissions."
                    : "Shut down Linux before changing microphone access.")
                    .settingFootnote()
            }

            Section("Shared Folder") {
                HStack {
                    LabeledContent("Folder", value: model.sharedFolderName ?? "None selected")
                    Button("Choose…") { model.chooseSharedFolder() }
                        .disabled(!canChangeDevices)
                        .accessibilityIdentifier("settings.sharedFolders.add")
                }
                Toggle("Read-only access", isOn: Binding(model.$preferences.sharedFolderReadOnly))
                    .disabled(!canChangeDevices)
                if model.sharedFolderName != nil {
                    Button("Stop Sharing Folder", role: .destructive) {
                        model.removeSharedFolderButtonTapped()
                    }
                    .disabled(!canChangeDevices)
                    .accessibilityIdentifier("settings.sharedFolders.remove")
                }
                Text("Only the folder you choose is shared. Linux can mount it through virtiofs after its next start.")
                    .settingFootnote()
            }

            SSHAccessSection(model: model.ssh)

            Section("Screen Sharing") {
                Label("Share the Linux desktop from inside Linux", systemImage: "rectangle.on.rectangle")
                Text("Apps in Linux use its PipeWire screen sharing portal. Displaying the virtual desktop does not need your Mac’s Screen Recording permission.")
                    .settingFootnote()
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .settingFootnote()
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
