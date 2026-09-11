import SwiftUI

struct SSHAccessSection: View {
    @Bindable var model: SSHAccessModel

    var body: some View {
        Section("SSH Access") {
            Toggle("Enable SSH access", isOn: Binding(get: { model.isEnabled }, set: { model.enabledChanged($0) }))
                .disabled(!model.isEnabled && !model.canEnable)
                .accessibilityIdentifier("settings.ssh.enabled")

            HStack {
                LabeledContent("SSH Folder", value: model.folderPath ?? "None selected")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") { Task { await model.chooseFolderButtonTapped() } }
                    .disabled(!model.canChooseFolder)
                    .accessibilityIdentifier("settings.ssh.chooseFolder")
            }

            if model.folderPath != nil {
                Picker("Public Key", selection: Binding(get: { model.selectedKeyName }, set: { model.publicKeySelected($0) })) {
                    Text("Choose a public key").tag(String?.none)
                    ForEach(model.publicKeys) { key in
                        Text(key.fileName).tag(Optional(key.fileName))
                    }
                }
                .disabled(!model.canChooseKey)
                .accessibilityIdentifier("settings.ssh.publicKey")

                HStack {
                    TextField("Host Alias", text: $model.draftAlias)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.ssh.alias")
                    Button("Apply Alias", action: model.applyAliasButtonTapped)
                        .disabled(model.draftAlias == model.preferences.sshAlias)
                }
            }

            status

            if let command = model.connectionCommand {
                HStack {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy SSH Command", action: model.copyCommandButtonTapped)
                }
                Text("Run this command in Terminal. Your private key remains on your Mac; SSH may ask you to unlock it.")
                    .settingFootnote()
            }

            if model.isEnabled || model.preferences.sshNeedsDisable || model.preferences.sshManagedFiles != nil {
                Button("Refresh Connection", action: model.refreshButtonTapped)
                    .accessibilityIdentifier("settings.ssh.refresh")
            }

            Text("Choose your .ssh folder and a public key. Omabox installs only that public key in Linux and adds a managed SSH entry in the chosen folder. This folder is not shared with Linux.")
                .settingFootnote()
        }
        .task { await model.task() }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .disabled:
            Text("SSH is off.").settingFootnote()
        case .waitingForDesktop:
            Text(model.preferences.sshNeedsDisable
                ? "Resume or start Linux to finish disabling SSH."
                : "Start Linux to configure SSH.")
                .settingFootnote()
        case .configuring:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.isEnabled ? "Configuring SSH…" : "Disabling SSH…")
                    .settingFootnote()
            }
        case .pendingOwner:
            Text("Finish creating your Linux account. SSH will be configured for that account.")
                .settingFootnote()
        case .pendingNetwork:
            Text("Waiting for Linux to connect to the network.").settingFootnote()
        case let .ready(endpoint):
            Label("SSH configured for \(endpoint.user)", systemImage: "checkmark.shield")
                .settingFootnote()
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .settingFootnote()
                .foregroundStyle(.orange)
        }
    }
}
