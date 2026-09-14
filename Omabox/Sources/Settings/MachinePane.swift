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

    private var cpuStops: [Int] {
        stops([1, 2, 4, 6, 8, 10, 12, 16, 24, 32, 64], in: model.resourcePolicy.cpuRange, current: model.preferences.cpuCount)
    }

    private var memoryStops: [Int] {
        stops([2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128], in: model.resourcePolicy.memoryRangeGiB, current: model.preferences.memoryGiB)
    }

    private var diskStops: [Int] {
        stops([16, 24, 32, 40, 64, 96, 128, 256, 512, 1_024], in: model.resourcePolicy.diskRangeGiB, current: model.preferences.diskSizeGiB)
    }

    var body: some View {
        SettingsForm {
            Section("Resources") {
                ResourceSlider(
                    title: "Processors",
                    stops: cpuStops,
                    unit: { "\($0) core\($0 == 1 ? "" : "s")" },
                    value: model.preferences.cpuCount,
                    accessibilityID: "settings.cpu"
                ) { value in model.$preferences.cpuCount.withLock { $0 = value } }
                .disabled(!canChangeHardware)

                ResourceSlider(
                    title: "Memory",
                    stops: memoryStops,
                    unit: { "\($0) GB" },
                    value: model.preferences.memoryGiB,
                    accessibilityID: "settings.memory"
                ) { value in model.$preferences.memoryGiB.withLock { $0 = value } }
                .disabled(!canChangeHardware)

                Text(canChangeHardware
                    ? "Up to \(model.resourcePolicy.cpuRange.upperBound) cores and \(model.resourcePolicy.memoryRangeGiB.upperBound) GB, leaving room for your Mac. Changes apply at the next start."
                    : "Shut down Linux to change its processors or memory.")
                    .settingFootnote()
            }

            Section("Disk") {
                ResourceSlider(
                    title: "Capacity",
                    stops: diskStops,
                    unit: { "\($0) GB" },
                    value: model.preferences.diskSizeGiB,
                    accessibilityID: "settings.disk"
                ) { value in model.$preferences.diskSizeGiB.withLock { $0 = value } }
                .disabled(model.installationURL != nil || !canChangeHardware)
                Text(model.installationURL == nil
                    ? "Chosen before setup. The disk only takes the space Linux writes."
                    : "Fixed after setup. The disk only takes the space Linux writes.")
                    .settingFootnote()
            }

            Section("Display") {
                Picker("Scale", selection: Binding(model.$preferences.displayScale)) {
                    Text("Automatic").tag(DisplayScale.automatic)
                    Text("1×").tag(DisplayScale.standard)
                    Text("2×").tag(DisplayScale.retina)
                }
                .pickerStyle(.segmented)
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
                    ? "Automatic scale follows the window. Rendering is on the CPU, so more threads make the desktop smoother."
                    : "Shut down Linux to change its display scale or rendering threads.")
                    .settingFootnote()
            }

            Section("Linux Configuration Files") {
                ForEach(LinuxConfigurationFile.allCases, id: \.self) { file in
                    LabeledContent {
                        Button("Open in Editor", systemImage: "square.and.pencil") {
                            Task { await model.openLinuxConfigurationFile(file) }
                        }
                        .accessibilityLabel("Open \(file.fileName) in editor")
                        .accessibilityIdentifier("settings.configuration.\(file.rawValue)")
                    } label: {
                        Label(file.fileName, systemImage: file.symbol)
                    }
                }
                Text("Edited on your Mac. Saved changes apply when Linux starts and win over its local configuration.")
                    .settingFootnote()
            }
        }
    }

    private func stops(_ candidates: [Int], in range: ClosedRange<Int>, current: Int) -> [Int] {
        var values = Set(candidates.filter(range.contains))
        values.insert(range.lowerBound)
        values.insert(range.upperBound)
        values.insert(current)
        return values.sorted()
    }
}
