import Sharing
import SwiftUI

struct HomeConfigurationView: View {
    let model: OmaboxModel
    @State private var search = ""

    private var canChangeHardware: Bool {
        !model.isBusy && !model.state.hasActiveSession
    }

    private var showsResources: Bool { matches("Resources CPU processors memory RAM disk storage capacity") }
    private var showsSharing: Bool { matches("Sharing clipboard text microphone audio folder files read-only permissions") }
    private var showsKeyboard: Bool { matches("Keyboard shortcuts system keys command option control") }
    private var showsCustomization: Bool { matches("Customize Linux display scale retina renderer threads desktop configuration Hyprland") }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 24)
                .padding(.top, 38)
                .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if showsResources { resources }
                    if showsSharing { sharing }
                    if showsKeyboard { keyboard }
                    if showsCustomization { customization }
                    if !showsResources && !showsSharing && !showsKeyboard && !showsCustomization {
                        ContentUnavailableView.search(text: search)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search configuration", text: $search)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("home.search")
            if !search.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }

    private var resources: some View {
        HomeConfigurationSection(title: "Resources") {
            HomeConfigurationRow(title: "Processors", symbol: "cpu") {
                HStack(spacing: 10) {
                    Text("\(model.preferences.cpuCount) cores")
                        .monospacedDigit()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(model.preferences.cpuCount) cores")
                        .accessibilityIdentifier("home.cpu.value")
                    Stepper("Processors", value: Binding(model.$preferences.cpuCount), in: model.resourcePolicy.cpuRange)
                        .labelsHidden()
                        .accessibilityIdentifier("home.cpu")
                }
                .accessibilityElement(children: .contain)
                .disabled(!canChangeHardware)
            }
            rowDivider
            HomeConfigurationRow(title: "Memory", symbol: "memorychip") {
                HStack(spacing: 10) {
                    Text("\(model.preferences.memoryGiB) GB")
                        .monospacedDigit()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(model.preferences.memoryGiB) GB")
                        .accessibilityIdentifier("home.memory.value")
                    Stepper("Memory", value: Binding(model.$preferences.memoryGiB), in: model.resourcePolicy.memoryRangeGiB)
                        .labelsHidden()
                        .accessibilityIdentifier("home.memory")
                }
                .accessibilityElement(children: .contain)
                .disabled(!canChangeHardware)
            }
            rowDivider
            HomeConfigurationRow(title: "Disk", symbol: "internaldrive", subtitle: model.installationURL == nil ? "Uses space as needed" : "Capacity set during installation") {
                HStack(spacing: 10) {
                    Text("\(model.preferences.diskSizeGiB) GB")
                        .monospacedDigit()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(model.preferences.diskSizeGiB) GB")
                        .accessibilityIdentifier("home.disk.value")
                    Stepper("Disk capacity", value: Binding(model.$preferences.diskSizeGiB), in: model.resourcePolicy.diskRangeGiB, step: 8)
                        .labelsHidden()
                        .accessibilityIdentifier("home.disk")
                }
                .accessibilityElement(children: .contain)
                .disabled(!canChangeHardware || model.installationURL != nil)
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
            DisclosureGroup("Linux Configuration Files") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Edit these files inside Linux:")
                    Text("~/.config/omabox/desktop.env\n~/.config/omabox/hyprland.lua")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Your changes are preserved when Omabox starts.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 40)
            .padding(.top, 10)
            .accessibilityIdentifier("home.configFiles")
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 40)
    }

    private func matches(_ keywords: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || keywords.localizedStandardContains(query)
    }
}
