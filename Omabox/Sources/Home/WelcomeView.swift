import SwiftUI

/// The start screen: the mark, one line of status, one button. Everything else
/// lives in Settings and the ⌘K palette.
struct WelcomeView: View {
    let model: OmaboxModel
    let onSettings: () -> Void
    let onPalette: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            identity
            primaryAction
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: 440)
                    .accessibilityIdentifier("desktop.error")
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: model.state)
    }

    private var identity: some View {
        VStack(spacing: 14) {
            if let mark = HomeAssets.mark {
                Image(nsImage: mark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .accessibilityHidden(true)
            }
            Text("Omabox")
                .font(.title2.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Omabox")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("welcome.title")
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .contentTransition(.opacity)
        }
    }

    private var subtitle: String {
        if model.isBusy { return model.state.detail }
        if model.installationURL == nil {
            return "Omarchy on your Mac, in its own window. Setup creates a private Linux disk of \(model.preferences.diskSizeGiB) GB."
        }
        if case .failed = model.state { return model.state.title }
        return "Ready with \(model.preferences.cpuCount) cores and \(model.preferences.memoryGiB) GB of memory."
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.isBusy {
            VStack(spacing: 10) {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .frame(width: 260)
                    .accessibilityIdentifier("desktop.progress")
                if model.state == .preparing {
                    Button("Cancel Setup") { model.cancelSetupButtonTapped() }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("welcome.cancelSetup")
                }
            }
        } else {
            Button {
                Task { await model.setUpOrStartButtonTapped() }
            } label: {
                Label(
                    model.installationURL == nil ? "Set Up Omarchy" : "Start Omarchy",
                    systemImage: model.installationURL == nil ? "arrow.down.circle.fill" : "play.fill"
                )
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityIdentifier("welcome.setup")
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(action: onPalette) {
                HStack(spacing: 6) {
                    Text("⌘ K")
                        .font(.caption.monospaced().weight(.medium))
                    Text("Commands")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open commands")
            .accessibilityIdentifier("welcome.palette")
            Button(action: onSettings) {
                HStack(spacing: 6) {
                    Text("⌘ ,")
                        .font(.caption.monospaced().weight(.medium))
                    Text("Settings")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("desktop.settings")
        }
    }
}
