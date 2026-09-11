import SwiftUI

struct CommandPaletteView: View {
    @Bindable var model: PaletteModel
    let onExecute: (DesktopCommand) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    private let radius: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider().opacity(0.4)
            results
            Divider().opacity(0.4)
            HStack(spacing: 12) {
                Label("Navigate", systemImage: "arrow.up.arrow.down")
                Label("Open", systemImage: "return")
                Spacer()
                Text("esc to close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 510, height: 370)
        .glassEffect(.regular, in: .rect(cornerRadius: radius))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        .defaultFocus($isFocused, true, priority: .userInitiated)
        .onExitCommand { model.close() }
        .task(id: model.presentationID) {
            isFocused = false
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            guard !Task.isCancelled, model.isPresented else { return }
            isFocused = true
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("What would you like to do?", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($isFocused)
                .accessibilityIdentifier("palette.search")
                .onSubmit { if let command = model.selection { onExecute(command) } }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
            Text("⌘ K").font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.results.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                        .accessibilityIdentifier("palette.empty")
                        .frame(height: 215)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(model.results) { command in
                            Button { onExecute(command) } label: {
                                CommandPaletteRow(command: command, isHighlighted: command == model.selection)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("palette.command.\(command.rawValue)")
                            .accessibilityValue(command == model.selection ? "Selected" : "")
                            .id(command.id)
                        }
                    }
                    .padding(6)
                }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: model.selection) { _, command in
                if let command {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(command.id) }
                }
            }
        }
    }
}
