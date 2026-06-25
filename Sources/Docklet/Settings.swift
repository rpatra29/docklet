import SwiftUI
import AppKit

// MARK: - Settings view (System Settings-style sidebar + detail)

struct SettingsView: View {
    @ObservedObject var state: PillState
    @State private var section: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.icon)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                detail
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle((section ?? .general).title)
        }
        .frame(width: 740, height: 480)
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .general {
        case .general:    GeneralSettings(state: state)
        case .appearance: AppearanceSettings(state: state)
        case .tabs:       TabsSettings(state: state)
        case .weather:    WeatherSettings(state: state)
        case .about:      AboutSettings(state: state)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, tabs, weather, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:    return "General"
        case .appearance: return "Appearance"
        case .tabs:       return "Tabs"
        case .weather:    return "Weather"
        case .about:      return "About"
        }
    }
    var icon: String {
        switch self {
        case .general:    return "gearshape"
        case .appearance: return "paintbrush"
        case .tabs:       return "square.grid.2x2"
        case .weather:    return "cloud.sun"
        case .about:      return "info.circle"
        }
    }
}

// MARK: - Sections

private struct GeneralSettings: View {
    @ObservedObject var state: PillState
    var body: some View {
        Form {
            Section {
                Picker("Open to", selection: $state.defaultTab) {
                    ForEach(state.visibleTabs) { tab in
                        Label(tab.title, systemImage: tab.icon).tag(tab)
                    }
                }
            } header: {
                Text("Default tab")
            } footer: {
                Text("The widget opens to this tab when expanded.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle(isOn: $state.expandOnHover) {
                    Text("Expand on hover")
                    Text("Open the full card just by moving the pointer over the pill.")
                }
                Toggle(isOn: $state.enlargeOnHover) {
                    Text("Enlarge on hover")
                    Text("Grow the whole pill when the pointer is over it.")
                }
                .disabled(state.expandOnHover)
            }

            Section {
                Picker("When idle, show", selection: $state.idleContent) {
                    ForEach(PillState.IdleContent.allCases) { c in
                        Label(c.title, systemImage: c.icon).tag(c)
                    }
                }
            } header: {
                Text("Compact pill")
            } footer: {
                Text("What the pill displays when nothing is playing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Keyboard shortcuts") {
                LabeledContent("Navigate tabs", value: "⌘← / ⌘→")
                LabeledContent("Collapse",      value: "⌘↓ or Esc")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var state: PillState

    private var accentBinding: Binding<Color> {
        Binding(get: { state.customAccent },
                set: { state.customAccentHex = $0.hexString })
    }

    var body: some View {
        Form {
            Section {
                Picker("Accent colour", selection: $state.accentMode) {
                    ForEach(PillState.AccentMode.allCases) { Text($0.title).tag($0) }
                }
                if state.accentMode == .custom {
                    ColorPicker("Colour", selection: accentBinding, supportsOpacity: false)
                }
            } header: {
                Text("Accent")
            } footer: {
                Text("Colours the glow, progress bar and now-playing highlights.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $state.glowEnabled) {
                    Text("Accent glow")
                    Text("Cast a soft accent-coloured glow behind the player.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TabsSettings: View {
    @ObservedObject var state: PillState
    var body: some View {
        Form {
            Section {
                ForEach(PillState.Tab.allCases) { tab in
                    Toggle(isOn: Binding(
                        get: { state.isTabEnabled(tab) },
                        set: { state.setTab(tab, enabled: $0) }
                    )) {
                        Label(tab.title, systemImage: tab.icon)
                    }
                }
            } header: {
                Text("Visible tabs")
            } footer: {
                Text("Choose which tabs appear in the navbar. At least one stays on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct WeatherSettings: View {
    @ObservedObject var state: PillState
    @StateObject private var weather = WeatherMonitor.shared
    var body: some View {
        Form {
            Section("Units") {
                Picker("Temperature", selection: $state.useFahrenheit) {
                    Text("Celsius (°C)").tag(false)
                    Text("Fahrenheit (°F)").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Section {
                LabeledContent("Location") {
                    Text(weather.current.city.isEmpty ? "—" : weather.current.city)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh weather now") { weather.refresh() }
            } footer: {
                Text("Weather data from Open-Meteo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    @ObservedObject var state: PillState
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "oval.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Docklet").font(.title3.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("A live widget for your notch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Button("Restore Defaults") { state.resetToDefaults() }
                Button("Quit Docklet", role: .destructive) { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Settings window

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let state: PillState

    init(state: PillState) { self.state = state }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: state))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Docklet Settings"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // The app is an accessory (no Dock icon), so explicitly bring it forward.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
