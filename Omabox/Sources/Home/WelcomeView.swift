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
                    .padding(.top, 20)
                    .padding(.bottom, 20)
                    .frame(width: geometry.size.width * 0.39)
                Divider()
                HomeConfigurationView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.primary.opacity(0.025))
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var welcomeColumn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)
            identity
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
            settingsButton
                .padding(.bottom, 8)
            primaryAction
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
            Text("Run Omarchy in a virtual machine.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Run Omarchy in a virtual machine.")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
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
                if model.installationURL == nil {
                    Text("Creates a Linux disk on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var settingsButton: some View {
        Button(action: onSettings) {
            Text("Settings")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("desktop.settings")
    }
}
