import SwiftUI

struct CommandPaletteView: View {
    @Bindable var model: PaletteModel
    let onExecute: (DesktopCommand) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let radius: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider().opacity(0.4)
            results
        }
        .frame(maxWidth: 560, maxHeight: 400)
        .glassEffect(.regular, in: .rect(cornerRadius: radius))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        .onExitCommand { model.goBackOrClose() }
    }

    private var field: some View {
        HStack(spacing: 10) {
            if model.page == .resolutions {
                Button { model.goBackOrClose() } label: {
                    Image(systemName: "chevron.left").font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Back to commands")
                .accessibilityIdentifier("palette.back")
                .help("Back (Escape)")
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            PaletteSearchField(model: model, onExecute: onExecute)
                .id(model.presentationID)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if !model.hasResults {
                    Text("No commands match “\(model.query)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .accessibilityIdentifier("palette.empty")
                } else {
                    resultRows
                        .padding(6)
                }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: model.highlightedIdentifier) { _, identifier in
                if let identifier {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(identifier) }
                }
            }
        }
    }

    private var resultRows: some View {
        LazyVStack(spacing: 2) {
            switch model.page {
            case .commands:
                ForEach(model.results) { command in
                    Button { model.selectCommand(command, onExecute: onExecute) } label: {
                        CommandPaletteRow(command: command, isHighlighted: command == model.selection)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("palette.command.\(command.rawValue)")
                    .accessibilityValue(command == model.selection ? "Selected" : "")
                    .id("command.\(command.rawValue)")
                }
            case .resolutions:
                ForEach(model.resolutionResults) { preset in
                    Button { model.selectResolution(preset) } label: {
                        ResolutionPaletteRow(
                            preset: preset,
                            isHighlighted: preset == model.resolutionSelection,
                            isCurrent: preset.matches(model.currentResolution)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("palette.resolution.\(preset.rawValue)")
                    .accessibilityValue(resolutionStatus(preset))
                    .id("resolution.\(preset.rawValue)")
                }
            }
        }
    }

    private func resolutionStatus(_ preset: DesktopResolutionPreset) -> String {
        let isCurrent = preset.matches(model.currentResolution)
        if preset == model.resolutionSelection {
            return isCurrent ? "Selected, current resolution" : "Selected"
        }
        return isCurrent ? "Current resolution" : ""
    }
}
