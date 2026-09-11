import SwiftUI

struct AboutPane: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsForm {
            Section {
                HStack(spacing: 14) {
                    FlareAppIcon(size: 52)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Omabox")
                            .font(.title3.weight(.semibold))
                        Text("Version \(version)")
                            .settingFootnote()
                        Text("Your Linux desktop, at home on your Mac.")
                            .settingFootnote()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }

            Section("Built for Your Mac") {
                LabeledContent("Requires", value: "macOS 26 or later · Apple silicon")
                LabeledContent("Virtualization", value: "Apple Virtualization framework")
                LabeledContent("Desktop", value: "Stored on this Mac")
            }

            Section("Credits") {
                LabeledContent("Design and artwork", value: "Flare · Aayush Pokharel")
                Text("Omabox is an independent project and is not an official Omarchy release.")
                    .settingFootnote()
            }
        }
    }
}
