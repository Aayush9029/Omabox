import SwiftUI

struct CommandPaletteView: View {
    @Bindable var model: PaletteModel
    let onExecute: (DesktopCommand) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let radius: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: min(510, max(0, geometry.size.width - 32)), height: min(370, max(0, geometry.size.height - 32)))
                .glassEffect(.regular, in: .rect(cornerRadius: radius))
                .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand { model.goBackOrClose() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            field
            Divider().opacity(0.4)
            results
            Divider().opacity(0.4)
            HStack(spacing: 12) {
                Label("Navigate", systemImage: "arrow.up.arrow.down")
                Label(model.page == .resolutions ? "Apply" : "Open", systemImage: "return")
                Spacer()
                Text(model.page == .resolutions ? "esc to go back" : "esc to close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            if model.page == .resolutions {
                Button { model.goBackOrClose() } label: {
                    Image(systemName: "chevron.left").font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to commands")
                .accessibilityIdentifier("palette.back")
                .help("Back (Escape)")
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            PaletteSearchField(model: model, onExecute: onExecute)
                .id(model.presentationID)
            if model.page == .commands {
                Text("⌃ ⌥ ⌘ K").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if !model.hasResults {
                    ContentUnavailableView.search(text: model.query)
                        .accessibilityIdentifier("palette.empty")
                        .frame(height: 215)
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
