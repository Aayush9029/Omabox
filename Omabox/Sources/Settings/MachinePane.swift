import Sharing
import SwiftUI

struct MachinePane: View {
    let model: OmaboxModel

    private var canChangeHardware: Bool {
        switch model.state {
        case .absent, .ready, .failed: true
        default: false
        }
    }

    var body: some View {
        SettingsForm {
            Section("Resources") {
                LabeledContent("Processors") {
                    HStack(spacing: 10) {
                        Text("\(model.preferences.cpuCount) cores")
                            .monospacedDigit()
                        Stepper("Processors", value: Binding(model.$preferences.cpuCount), in: model.resourcePolicy.cpuRange)
                            .labelsHidden()
                            .accessibilityLabel("Processors")
                            .accessibilityValue("\(model.preferences.cpuCount) cores")
                            .accessibilityIdentifier("settings.cpu")
                    }
                    .accessibilityElement(children: .contain)
                }
                .accessibilityElement(children: .contain)
                .disabled(!canChangeHardware)

                LabeledContent("Memory") {
                    HStack(spacing: 10) {
                        Text("\(model.preferences.memoryGiB) GB")
                            .monospacedDigit()
                        Stepper("Memory", value: Binding(model.$preferences.memoryGiB), in: model.resourcePolicy.memoryRangeGiB)
                            .labelsHidden()
                            .accessibilityLabel("Memory")
                            .accessibilityValue("\(model.preferences.memoryGiB) GB")
                            .accessibilityIdentifier("settings.memory")
                    }
                    .accessibilityElement(children: .contain)
                }
                .accessibilityElement(children: .contain)
                .disabled(!canChangeHardware)

                Text(canChangeHardware
                    ? "Leave some memory and processors for your Mac. Changes apply the next time Linux starts."
                    : "Shut down Linux to change its processors or memory.")
                    .settingFootnote()
            }

            Section("Storage") {
                LabeledContent("Disk capacity") {
                    HStack(spacing: 10) {
                        Text("\(model.preferences.diskSizeGiB) GB")
                            .monospacedDigit()
                        Stepper("Disk capacity", value: Binding(model.$preferences.diskSizeGiB), in: model.resourcePolicy.diskRangeGiB, step: 8)
                            .labelsHidden()
                            .accessibilityLabel("Disk capacity")
                            .accessibilityValue("\(model.preferences.diskSizeGiB) GB")
                            .accessibilityIdentifier("settings.disk")
                    }
                    .accessibilityElement(children: .contain)
                }
                .accessibilityElement(children: .contain)
                .disabled(model.installationURL != nil || !canChangeHardware)
                Text("Capacity is chosen before installation. The disk uses space on your Mac as Linux writes to it.")
                    .settingFootnote()
            }

            Section("Display") {
                Picker("Scale", selection: Binding(model.$preferences.displayScale)) {
                    Text("Automatic").tag(DisplayScale.automatic)
                    Text("Standard · 1×").tag(DisplayScale.standard)
                    Text("Retina · 2×").tag(DisplayScale.retina)
                }
                .disabled(!canChangeHardware)

                Picker("Rendering threads", selection: Binding(model.$preferences.renderThreadCount)) {
                    Text("Automatic · \(model.preferences.cpuCount)").tag(0)
                    ForEach(1...max(1, model.preferences.cpuCount), id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                    if model.preferences.renderThreadCount > model.preferences.cpuCount {
                        Text("\(model.preferences.renderThreadCount) · limited to \(model.preferences.effectiveRenderThreadCount)")
                            .tag(model.preferences.renderThreadCount)
                    }
                }
                .disabled(!canChangeHardware)

                Text(canChangeHardware
                    ? "Changes apply at the next start. Automatic rendering uses the processors assigned to Linux."
                    : "Shut down Linux to change its display scale or rendering threads.")
                    .settingFootnote()
            }

            Section("Desktop customization") {
                Text("You can change blur, shadows, animations, and desktop behavior inside Linux.")
                    .settingFootnote()
                LabeledContent("Desktop configuration") {
                    Text("~/.config/omabox/hyprland.lua")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Environment overrides") {
                    Text("~/.config/omabox/desktop.env")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("These files are inside Linux. Your overrides take priority over Omabox settings and stay in place when the app updates.")
                    .settingFootnote()
            }

            Section("Virtualization") {
                LabeledContent("Processor architecture", value: "Apple silicon · ARM64")
                LabeledContent("Engine", value: "Apple Virtualization")
                LabeledContent("Networking", value: "Shared with your Mac · NAT")
            }
        }
    }
}
