import Sharing
import SwiftUI

struct GeneralPane: View {
    let model: OmaboxModel
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        SettingsForm {
            Section {
                HStack(alignment: .top, spacing: 20) {
                    ToggleCard(
                        title: "Open at Login",
                        description: "Omabox is ready as soon as you log in.",
                        icon: "power",
                        isOn: launchAtLogin.isEnabled,
                        accessibilityID: "settings.openAtLogin",
                        action: { launchAtLogin.set(!launchAtLogin.isEnabled) }
                    ) {
                        AnimatedImage(resource: SettingsIllustration.launchAtLogin)
                    }

                    ToggleCard(
                        title: "Show in Dock",
                        description: "Adds a Dock icon and an app switcher entry.",
                        icon: "dock.rectangle",
                        isOn: model.preferences.showsDockIcon,
                        accessibilityID: "settings.showInDock",
                        action: { model.$preferences.showsDockIcon.withLock { $0.toggle() } }
                    ) {
                        AnimatedImage(resource: SettingsIllustration.dockIcon)
                    }

                    ToggleCard(
                        title: "Show in Menu Bar",
                        description: "Keep your desktop close, with quick access to Omabox and Settings.",
                        icon: "menubar.rectangle",
                        isOn: model.preferences.showsMenuBarIcon,
                        accessibilityID: "settings.showInMenuBar",
                        action: { model.$preferences.showsMenuBarIcon.withLock { $0.toggle() } }
                    ) {
                        MenuBarIllustration()
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))

                if let failureMessage = launchAtLogin.failureMessage {
                    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                        .settingFootnote()
                        .foregroundStyle(.orange)
                }
            }

            Section("Your Desktop") {
                Toggle("Start when Omabox opens", isOn: Binding(model.$preferences.startsOnLaunch))
                Text("Starts your installed Linux desktop when you open the app.")
                    .settingFootnote()
            }

            Section("Appearance") {
                LabeledContent("Theme", value: "Follows your Mac")
                Text("Glass, colors, and contrast follow your macOS appearance and accessibility settings.")
                    .settingFootnote()
            }
        }
        .task { launchAtLogin.refresh() }
    }
}
