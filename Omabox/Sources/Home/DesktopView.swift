import AppKit
import SwiftUI

struct DesktopView: View {
    let model: OmaboxModel
    let palette: PaletteModel
    let onSettings: () -> Void
    let onPalette: () -> Void
    let onCommand: (DesktopCommand) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.appearsActive) private var appearsActive
    @FocusState private var isMenuButtonFocused: Bool
    @State private var isHoveringMenuButton = false
    @State private var controls = DesktopControlsPresentation()
    @State private var confirmsForceStop = false

    var body: some View {
        ZStack {
            Group {
                if hasDesktop {
                    desktop
                } else {
                    WelcomeView(model: model, onSettings: onSettings, onPalette: onPalette)
                }
            }
            .accessibilityHidden(palette.isPresented)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelScrim())
        .overlay(alignment: .top) {
            if palette.isPresented {
                CommandPaletteView(model: palette, onExecute: onCommand)
                    .padding(.horizontal, 16)
                    .padding(.top, hasDesktop ? 16 : 40)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .bouncy(duration: 0.28), value: palette.isPresented)
        .task { await model.task() }
        .onChange(of: model.state) { _, state in
            if state.isBusy { palette.close() }
            controls.reveal()
        }
        .alert("Force stop Omarchy?", isPresented: $confirmsForceStop) {
            Button("Keep Running", role: .cancel) {}
            Button("Force Stop", role: .destructive) { Task { await model.forceStopButtonTapped() } }
        } message: {
            Text("This turns off the virtual machine immediately. Unsaved work inside Linux may be lost.")
        }
    }

    private var keepsControlsVisible: Bool {
        voiceOverEnabled || isMenuButtonFocused || isHoveringMenuButton || palette.isPresented
    }

    private var hasDesktop: Bool {
        model.virtualMachine != nil && model.state.hasActiveSession
    }

    @ViewBuilder
    private var desktop: some View {
        if let machine = model.virtualMachine {
            ZStack {
                VirtualMachineDisplay(
                    machine: machine,
                    capturesSystemKeys: model.state == .running && model.preferences.captureSystemKeys && !palette.isPresented,
                    acceptsGuestInput: model.state == .running && !palette.isPresented
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(model.state == .running && !palette.isPresented)
                .accessibilityHidden(model.state != .running || palette.isPresented)
                if model.state == .paused {
                    pausedOverlay
                } else if model.state == .starting || model.state == .stopping {
                    activityOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                errorBanner
                    .padding(.horizontal, 20)
                    .padding(.bottom, controls.isVisible ? 72 : 20)
            }
            .overlay(alignment: .bottomLeading) {
                if model.state == .running || model.state == .paused {
                    commandAffordance
                        .padding(20)
                        .opacity(controls.isVisible ? 1 : 0)
                        .allowsHitTesting(controls.isVisible)
                }
            }
            .onContinuousHover { phase in
                if case .active = phase { controls.reveal() }
            }
            .onChange(of: appearsActive) { _, isActive in
                if isActive { controls.reveal() }
            }
            .onChange(of: keepsControlsVisible, initial: true) { _, keepsVisible in
                controls.setPersistent(keepsVisible)
            }
            .onAppear { controls.reveal() }
            .task(id: controls.presentationID) { await controls.hideAfterInactivity() }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controls.isVisible)
        }
    }

    private var commandAffordance: some View {
        Button(action: onPalette) {
            Text("⌘ K")
                .font(.callout.monospaced().weight(.medium))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .focused($isMenuButtonFocused)
        .onHover { isHoveringMenuButton = $0 }
        .help("Open commands (⌘K, or ⌃⌥⌘K while Linux has your shortcuts)")
        .accessibilityLabel("Open commands")
        .accessibilityHint("Command–K")
        .accessibilityIdentifier("desktop.palette")
    }

    private var pausedOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button {
                    Task { await model.resumeButtonTapped() }
                } label: {
                    HStack(spacing: 10) {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Text("Resume")
                    }
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 120)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.isBusy)
                .accessibilityLabel("Resume paused desktop")
                .accessibilityIdentifier("desktop.resume")
            }
        }
    }

    private var activityOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityIdentifier("desktop.activity")
                Text(model.state.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.errorMessage {
            HStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer()
                Button("Force Stop", role: .destructive) { confirmsForceStop = true }
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("desktop.runtimeError")
        }
    }
}
