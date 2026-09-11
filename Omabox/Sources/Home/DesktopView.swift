import AppKit
import SwiftUI

struct DesktopView: View {
    let model: OmaboxModel
    let palette: PaletteModel
    let onSettings: () -> Void
    let onPalette: () -> Void
    let onCommand: (DesktopCommand) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmsForceStop = false

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea()
            Group {
                if model.virtualMachine != nil && model.state.hasActiveSession {
                    VStack(spacing: 0) {
                        toolbar
                        content
                        footer
                    }
                    .padding(.top, 28)
                } else {
                    WelcomeView(model: model, onSettings: onSettings)
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
        .frame(minWidth: 760, minHeight: 610)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: palette.isPresented)
        .task { await model.task() }
        .onChange(of: model.state) { _, state in
            if state != .running { palette.close() }
        }
        .alert("Force stop Omarchy?", isPresented: $confirmsForceStop) {
            Button("Keep Running", role: .cancel) {}
            Button("Force Stop", role: .destructive) { Task { await model.forceStopButtonTapped() } }
        } message: {
            Text("This turns off the virtual machine immediately. Unsaved work inside Linux may be lost.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill").font(.title3).symbolRenderingMode(.hierarchical)
            Text("Omabox").font(.headline)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.state.isRunning ? Color.green : Color.secondary).frame(width: 5, height: 5)
                Text(model.state.title).font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.trailing, 10)
            Button { onCommand(.settings) } label: { Image(systemName: "gearshape") }
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("desktop.settings")
                .buttonStyle(.glass)
            Button(action: onPalette) { Text("⌘ K").font(.callout.monospaced()) }
                .help("Command palette")
                .accessibilityLabel("Command palette")
                .accessibilityIdentifier("desktop.palette")
                .buttonStyle(.glass)
                .disabled(model.state != .running)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var content: some View {
        if let machine = model.virtualMachine, model.state.isRunning || model.state == .paused || model.state == .stopping {
            ZStack {
                VirtualMachineDisplay(
                    machine: machine,
                    capturesSystemKeys: model.state == .running && model.preferences.captureSystemKeys && !palette.isPresented,
                    acceptsGuestInput: model.state == .running && !palette.isPresented
                )
                    .allowsHitTesting(model.state == .running && !palette.isPresented)
                if model.state == .paused {
                    VStack(spacing: 14) {
                        Image(systemName: "pause.circle.fill").font(.system(size: 42)).symbolRenderingMode(.hierarchical)
                        Text("Desktop paused").font(.title2.weight(.semibold))
                        Button("Resume desktop") { Task { await model.resumeButtonTapped() } }
                            .buttonStyle(.glassProminent)
                    }
                    .padding(32)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
            .overlay(alignment: .bottom) {
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
                    .padding(16)
                }
            }
            .clipShape(.rect(cornerRadius: 12))
            .padding(.horizontal, 12)
        } else {
            WelcomeView(model: model, onSettings: onSettings)
        }
    }

    private var footer: some View {
        HStack {
            Label("Omarchy", systemImage: "desktopcomputer")
            Spacer()
            if model.state.isRunning {
                Text("⌃ ⌥ esc releases your keyboard")
                Button("Pause", systemImage: "pause") { Task { await model.pauseButtonTapped() } }
                    .labelStyle(.iconOnly)
                    .help("Pause desktop")
                Button("Shut down", systemImage: "power") { Task { await model.shutDownButtonTapped() } }
                    .labelStyle(.iconOnly)
                    .help("Shut down Omarchy")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
    }
}
