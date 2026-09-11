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
                    WelcomeView(model: model, onSettings: onSettings)
                        .background {
                            VisualEffectBackground(material: .underWindowBackground)
                                .ignoresSafeArea()
                        }
                }
            }
            .accessibilityHidden(palette.isPresented)
            if palette.isPresented {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { palette.close() }
                CommandPaletteView(model: palette, onExecute: onCommand)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: palette.isPresented)
        .task { await model.task() }
        .onChange(of: model.state) { _, state in
            if state != .running && state != .paused { palette.close() }
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
            Text("⌃ ⌥ ⌘ K")
                .font(.callout.monospaced().weight(.medium))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .focused($isMenuButtonFocused)
        .onHover { isHoveringMenuButton = $0 }
        .help("Open command menu (Control–Option–Command–K)")
        .accessibilityLabel("Open command menu")
        .accessibilityHint("Control–Option–Command–K")
        .accessibilityIdentifier("desktop.palette")
    }

    private var pausedOverlay: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 30) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button {
                    Task { await model.resumeButtonTapped() }
                } label: {
                    HStack(spacing: 10) {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Text("Resume")
                    }
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 150)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(model.isBusy)
                .accessibilityLabel("Resume paused desktop")
                .accessibilityIdentifier("desktop.resume")
            }
        }
    }

    private var activityOverlay: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
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
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .accessibilityIdentifier("desktop.runtimeError")
        }
    }
}
