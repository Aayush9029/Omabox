import Sharing
import SwiftUI

struct ShortcutsPane: View {
    let model: OmaboxModel

    var body: some View {
        SettingsForm {
            Section("In Omabox") {
                LabeledContent("Commands", value: "⌘ K")
                LabeledContent("Commands, always", value: "⌃ ⌥ ⌘ K")
                LabeledContent("Settings", value: "⌘ ,")
                LabeledContent("Close commands", value: "Escape")
                LabeledContent("Release keyboard and pointer", value: "⌃ ⌥ esc")
                Text("⌘K reaches Omabox unless Linux has your system shortcuts and the keyboard. ⌃⌥⌘K always does.")
                    .settingFootnote()
            }

            Section("Linux Keyboard") {
                Toggle("Send system shortcuts to Linux", isOn: Binding(model.$preferences.captureSystemKeys))
                    .accessibilityIdentifier("settings.captureSystemKeys")
                Text("When the desktop has focus, system shortcuts go to Linux, ⌘K included. Press Control–Option–Escape to return control to your Mac and click the desktop to capture input again.")
                    .settingFootnote()
                Text("The Command key acts as the Linux Super key. Choose your preferred keyboard layout in Linux settings.")
                    .settingFootnote()
            }
        }
    }
}
