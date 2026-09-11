import Sharing
import SwiftUI

struct HomeConfigurationView: View {
    let model: OmaboxModel

    private var canChangeHardware: Bool {
        !model.isBusy && !model.state.hasActiveSession
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                resources
                sharing
                keyboard
                customization
                configurationFiles
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
    }

    private var resources: some View {
        HomeConfigurationSection(title: "Resources") {
            HomeResourcePresetRow(
                title: "Processors",
                symbol: "cpu",
                unit: "cores",
                values: presetValues([2, 4, 8, 16, 32, 64, 128, model.resourcePolicy.cpuRange.upperBound], in: model.resourcePolicy.cpuRange, current: model.preferences.cpuCount),
                identifier: "home.cpu",
                selection: Binding(model.$preferences.cpuCount)
            )
            .disabled(!canChangeHardware)
            rowDivider
            HomeResourcePresetRow(
                title: "Memory",
                symbol: "memorychip",
                unit: "GB",
                values: presetValues([4, 8, 12, 16, 32, 48], in: model.resourcePolicy.memoryRangeGiB, current: model.preferences.memoryGiB),
                identifier: "home.memory",
                selection: Binding(model.$preferences.memoryGiB)
            )
            .disabled(!canChangeHardware)
            rowDivider
            HomeConfigurationRow(title: "Disk", symbol: "internaldrive", subtitle: "Not editable") {
                Text("\(model.preferences.diskSizeGiB) GB")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(model.preferences.diskSizeGiB) GB")
                    .accessibilityIdentifier("home.disk.value")
            }
        }
    }

    private var sharing: some View {
        HomeConfigurationSection(title: "Sharing") {
            HomeConfigurationRow(title: "Clipboard", symbol: "document.on.clipboard", subtitle: "Share text with your Mac") {
                Toggle("Share clipboard", isOn: Binding(
                    get: { model.preferences.clipboardEnabled },
                    set: { value in
                        model.$preferences.clipboardEnabled.withLock { $0 = value }
                        model.clipboardPreferenceChanged()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier("home.clipboardSharing")
            }
            rowDivider
            HomeConfigurationRow(title: "Microphone", symbol: "mic", subtitle: "Use your Mac’s microphone") {
                Toggle("Share microphone", isOn: Binding(
                    get: { model.preferences.microphoneEnabled },
                    set: { _ in Task { await model.microphoneButtonTapped() } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!canChangeHardware)
                .accessibilityIdentifier("home.microphone")
            }
            rowDivider
            HomeConfigurationRow(title: "Shared Folder", symbol: "folder", subtitle: model.sharedFolderName ?? "Choose a folder to share") {
                HStack(spacing: 8) {
                    if model.sharedFolderName != nil {
                        Button("Remove shared folder", systemImage: "xmark.circle") {
                            model.removeSharedFolderButtonTapped()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("home.sharedFolder.remove")
                    }
                    Button(model.sharedFolderName == nil ? "Choose…" : "Change…") {
                        model.chooseSharedFolder()
                    }
                    .accessibilityIdentifier("home.sharedFolder.choose")
                }
                .disabled(!canChangeHardware)
            }
            if model.sharedFolderName != nil {
                rowDivider
                HomeConfigurationRow(title: "Read-only Access", symbol: "lock", subtitle: "Protect files in the shared folder") {
                    Toggle("Read-only folder access", isOn: Binding(model.$preferences.sharedFolderReadOnly))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!canChangeHardware)
                        .accessibilityIdentifier("home.sharedFolder.readOnly")
                }
            }
        }
    }

    private var keyboard: some View {
        HomeConfigurationSection(title: "Keyboard") {
            HomeConfigurationRow(title: "System Shortcuts", symbol: "keyboard", subtitle: "Send Mac shortcuts to Linux") {
                Toggle("Send system shortcuts to Linux", isOn: Binding(model.$preferences.captureSystemKeys))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("home.keyboard")
            }
        }
    }

    private var customization: some View {
        HomeConfigurationSection(title: "Customize Linux") {
            HomeConfigurationRow(title: "Display Scale", symbol: "display") {
                Picker("Display scale", selection: Binding(model.$preferences.displayScale)) {
                    Text("Automatic").tag(DisplayScale.automatic)
                    Text("Standard · 1×").tag(DisplayScale.standard)
                    Text("Retina · 2×").tag(DisplayScale.retina)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!canChangeHardware)
                .accessibilityIdentifier("home.displayScale")
            }
            rowDivider
            HomeConfigurationRow(title: "Rendering Threads", symbol: "square.3.layers.3d", subtitle: "Used for software graphics") {
                Picker("Rendering threads", selection: Binding(model.$preferences.renderThreadCount)) {
                    Text("Automatic").tag(0)
                    ForEach(1...max(1, model.preferences.cpuCount), id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                    if model.preferences.renderThreadCount > model.preferences.cpuCount {
                        Text("\(model.preferences.renderThreadCount) · limited to \(model.preferences.cpuCount)")
                            .tag(model.preferences.renderThreadCount)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!canChangeHardware)
                .accessibilityIdentifier("home.renderThreads")
            }
        }
    }

    private var configurationFiles: some View {
        HomeConfigurationSection(title: "Linux Configuration Files") {
            configurationFileRow(.environment)
            rowDivider
            configurationFileRow(.desktop)
            Text("Saved changes apply when Linux starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 40)
                .padding(.top, 6)
        }
    }

    private func configurationFileRow(_ file: LinuxConfigurationFile) -> some View {
        HomeConfigurationRow(title: file.title, symbol: file.symbol, subtitle: file.fileName) {
            Button("Open in Editor", systemImage: "square.and.pencil") {
                Task { await model.openLinuxConfigurationFile(file) }
            }
            .disabled(!canChangeHardware)
            .accessibilityIdentifier("home.configFiles.\(file.rawValue)")
        }
    }

    private func presetValues(_ candidates: [Int], in range: ClosedRange<Int>, current: Int) -> [Int] {
        let values = Set((candidates + [current]).filter { range.contains($0) }).sorted()
        return values.isEmpty ? [range.lowerBound] : values
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 40)
    }

}
