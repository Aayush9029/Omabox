import SwiftUI

struct SettingsView: View {
    let model: OmaboxModel
    @State private var tab: SettingsTab?

    init(model: OmaboxModel, initialTab: SettingsTab = .general) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsTab.allCases, selection: $tab) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    SettingsTabIcon(tab: tab, isSelected: tab == currentTab)
                }
                .padding(.vertical, 4)
                .tag(tab)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tab.title)
                .accessibilityIdentifier("settings.tab.\(tab.rawValue)")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane
                .navigationTitle("Omabox Settings")
                .background {
                    VisualEffectBackground(material: .underWindowBackground)
                        .ignoresSafeArea()
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 460)
    }

    private var currentTab: SettingsTab { tab ?? .general }

    @ViewBuilder
    private var pane: some View {
        switch currentTab {
        case .general: GeneralPane(model: model)
        case .machine: MachinePane(model: model)
        case .sharing: SharingPane(model: model)
        case .shortcuts: ShortcutsPane(model: model)
        case .about: AboutPane()
        }
    }
}
