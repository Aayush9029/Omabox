import SwiftUI

struct WelcomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: OmaboxModel
    let onSettings: () -> Void
    @State private var setupTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                welcomeColumn
                    .padding(.horizontal, 30)
                    .padding(.top, 38)
                    .padding(.bottom, 20)
                    .frame(width: geometry.size.width * 0.39)
                Divider()
                HomeConfigurationView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.primary.opacity(0.025))
            }
        }
    }

    private var welcomeColumn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)
            identity
            desktopPreview
                .padding(.top, 28)
            Spacer(minLength: 28)
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("desktop.error")
                    .padding(.bottom, 16)
            }
            primaryAction
            footer
                .padding(.top, 22)
        }
    }

    private var identity: some View {
        VStack(spacing: 12) {
            if let mark = HomeAssets.mark {
                Image(nsImage: mark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
                    .padding(.bottom, 8)
            }
            Text("Omabox")
                .font(.system(size: 27, weight: .semibold))
                .tracking(-0.6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Omabox")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("welcome.title")
            Text("Omarchy for Mac")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Omarchy for Mac")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var desktopPreview: some View {
        if let preview = HomeAssets.preview {
            Image(nsImage: preview)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260)
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                }
                .accessibilityLabel("Omarchy desktop preview")
                .accessibilityIdentifier("home.preview")
        }
    }

    private var primaryAction: some View {
        VStack(spacing: 12) {
            if model.isBusy {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("desktop.progress")
                Text(model.state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if model.state == .preparing {
                    Button("Cancel Setup") { setupTask?.cancel() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("welcome.cancelSetup")
                }
            } else {
                Button {
                    setupTask?.cancel()
                    setupTask = Task {
                        if model.installationURL == nil {
                            await model.prepareButtonTapped()
                        }
                        guard !Task.isCancelled, model.installationURL != nil else { return }
                        await model.startButtonTapped()
                    }
                } label: {
                    Label(model.installationURL == nil ? "Set Up Omarchy" : "Start Omarchy", systemImage: model.installationURL == nil ? "arrow.down.circle" : "play.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(.primary)
                .controlSize(.large)
                .accessibilityIdentifier("welcome.setup")
                Text(model.installationURL == nil ? "Creates a Linux disk on your Mac." : "Ready to start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings", systemImage: "gearshape", action: onSettings)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("desktop.settings")
            Spacer()
            Text(HomeAssets.version)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
