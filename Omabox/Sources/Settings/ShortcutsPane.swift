import Sharing
import SwiftUI

struct ShortcutsPane: View {
    let model: OmaboxModel

    var body: some View {
        SettingsForm {
            Section("In Omabox") {
                LabeledContent("Command menu", value: "⌘ K")
                LabeledContent("Settings", value: "⌘ ,")
                LabeledContent("Close command menu", value: "Escape")
                LabeledContent("Release keyboard and pointer", value: "⌃ ⌥ esc")
                Text("The command menu is available while Omarchy is running.")
                    .settingFootnote()
            }

            Section("Linux Keyboard") {
                Toggle("Send system shortcuts to Linux", isOn: Binding(model.$preferences.captureSystemKeys))
                    .accessibilityIdentifier("settings.captureSystemKeys")
                Text("When the desktop has focus, supported system shortcuts go to Linux. Press Control–Option–Escape to return control to your Mac. Click the desktop to capture input again. Command–K stays available for Omabox commands.")
                    .settingFootnote()
                Text("The Command key acts as the Linux Super key. Choose your preferred keyboard layout in Linux settings.")
                    .settingFootnote()
            }
        }
    }
}
