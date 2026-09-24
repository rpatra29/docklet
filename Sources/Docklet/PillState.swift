import SwiftUI

@MainActor
class PillState: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case music, shelf, weather, capture, clipboard
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .music:     return "music.note"
            case .shelf:     return "tray.full"
            case .weather:   return "cloud.sun.fill"
            case .capture:   return "mic.fill"
            case .clipboard: return "doc.on.clipboard"
            }
        }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    enum AccentMode: String, CaseIterable, Identifiable {
        case albumArt, custom
        var id: String { rawValue }
        var title: String { self == .albumArt ? "Album artwork" : "Custom colour" }
    }

    // What the compact pill shows on the idle (no-music) side.
    enum IdleContent: String, CaseIterable, Identifiable {
        case weather, clock, battery, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .weather: return "Weather"
            case .clock:   return "Clock"
            case .battery: return "Battery"
            case .none:    return "Nothing"
            }
        }
        var icon: String {
            switch self {
            case .weather: return "cloud.sun.fill"
            case .clock:   return "clock"
            case .battery: return "battery.100"
            case .none:    return "minus"
            }
        }
    }

    /// Set on init so non-UI singletons (e.g. ShelfStore) can flash the pill.
    static weak var shared: PillState?

    @Published var isExpanded = false
    @Published var tab: Tab = .music
    @Published var isDragTargeted = false

    // MARK: Transient pill notification ("toast")

    struct Toast: Equatable {
        let icon: String
        let text: String
        // Distinguishes successive toasts with identical content so the view re-triggers.
        let stamp: Date = Date()
    }
    @Published var toast: Toast? = nil
    private var toastDismiss: DispatchWorkItem?

    /// Briefly flash the compact pill with an icon + short label, then auto-clear.
    /// Renders only while collapsed (see NotchView) — an ambient, sound-free notification.
    func flash(icon: String, text: String) {
        toastDismiss?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = Toast(icon: icon, text: text) }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.25)) { self?.toast = nil }
        }
        toastDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: work)
    }

    // MARK: Persisted user settings

    @Published var glowEnabled: Bool {
        didSet { defaults.set(glowEnabled, forKey: "glowEnabled") }
    }
    @Published var useFahrenheit: Bool {
        didSet { defaults.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    @Published var enlargeOnHover: Bool {
        didSet { defaults.set(enlargeOnHover, forKey: "enlargeOnHover") }
    }
    @Published var expandOnHover: Bool {
        didSet { defaults.set(expandOnHover, forKey: "expandOnHover") }
    }
    @Published var defaultTab: Tab {
        didSet { defaults.set(defaultTab.rawValue, forKey: "defaultTab") }
    }
    @Published var accentMode: AccentMode {
        didSet { defaults.set(accentMode.rawValue, forKey: "accentMode") }
    }
    @Published var customAccentHex: String {
        didSet { defaults.set(customAccentHex, forKey: "customAccentHex") }
    }
    @Published var idleContent: IdleContent {
        didSet { defaults.set(idleContent.rawValue, forKey: "idleContent") }
    }
    // Which tabs appear in the navbar (ordered as Tab.allCases).
    @Published var enabledTabs: Set<String> {
        didSet {
            let valid = Set(Tab.allCases.map(\.rawValue))
            var normalized = enabledTabs.intersection(valid)
            if normalized.isEmpty { normalized = [Tab.music.rawValue] }
            if normalized != enabledTabs { enabledTabs = normalized }
            defaults.set(Array(enabledTabs), forKey: "enabledTabs")
            // Never leave an invalid selection.
            if !enabledTabs.contains(tab.rawValue), let first = visibleTabs.first {
                withAnimation(.easeInOut(duration: 0.25)) { tab = first }
            }
        }
    }

    // Closures wired by OverlayPanel.
    var onExpandRequest: ((Bool) -> Void)?
    var onHoverRequest: ((Bool) -> Void)?

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        glowEnabled    = d.object(forKey: "glowEnabled")    as? Bool ?? true
        useFahrenheit  = d.object(forKey: "useFahrenheit")  as? Bool ?? false
        enlargeOnHover = d.object(forKey: "enlargeOnHover") as? Bool ?? true
        expandOnHover  = d.object(forKey: "expandOnHover")  as? Bool ?? false
        accentMode     = AccentMode(rawValue: d.string(forKey: "accentMode") ?? "") ?? .albumArt
        customAccentHex = d.string(forKey: "customAccentHex") ?? "#3A86FF"
        idleContent    = IdleContent(rawValue: d.string(forKey: "idleContent") ?? "") ?? .weather
        let savedTab = Tab(rawValue: d.string(forKey: "defaultTab") ?? "") ?? .music
        defaultTab = savedTab
        let validTabs = Set(Tab.allCases.map(\.rawValue))
        let savedTabs = Set(d.stringArray(forKey: "enabledTabs") ?? []).intersection(validTabs)
        enabledTabs = savedTabs.isEmpty ? validTabs : savedTabs
        tab = enabledTabs.contains(savedTab.rawValue) ? savedTab : (Tab.allCases.first { enabledTabs.contains($0.rawValue) } ?? .music)
        PillState.shared = self
    }

    // MARK: Derived

    /// Tabs to show in the navbar, in canonical order.
    var visibleTabs: [Tab] { Tab.allCases.filter { enabledTabs.contains($0.rawValue) } }

    var customAccent: Color { Color(hex: customAccentHex) ?? .blue }

    /// Resolves the accent colour for a given album tint, honouring the accent mode.
    func accent(albumTint: Color) -> Color {
        switch accentMode {
        case .albumArt: return albumTint == .clear ? customAccent : albumTint
        case .custom:   return customAccent
        }
    }

    /// Formats a Celsius temperature for display, honouring the unit setting.
    func temp(_ celsius: Int) -> String {
        if useFahrenheit {
            return "\(Int((Double(celsius) * 9 / 5 + 32).rounded()))°"
        }
        return "\(celsius)°"
    }

    /// Move to the next/previous *visible* tab (wraps around) — keyboard nav.
    func cycleTab(_ delta: Int) {
        let all = visibleTabs
        guard !all.isEmpty, let i = all.firstIndex(of: tab) else { return }
        let n = (i + delta + all.count) % all.count
        withAnimation(.easeInOut(duration: 0.3)) { tab = all[n] }
    }

    func isTabEnabled(_ t: Tab) -> Bool { enabledTabs.contains(t.rawValue) }

    /// Restore every persisted setting to its shipped default.
    func resetToDefaults() {
        withAnimation(.easeInOut(duration: 0.25)) {
            glowEnabled    = true
            useFahrenheit  = false
            enlargeOnHover = true
            expandOnHover  = false
            accentMode     = .albumArt
            customAccentHex = "#3A86FF"
            idleContent    = .weather
            enabledTabs    = Set(Tab.allCases.map(\.rawValue))
            defaultTab     = .music
        }
    }

    func setTab(_ t: Tab, enabled: Bool) {
        if enabled { enabledTabs.insert(t.rawValue) }
        else if visibleTabs.count > 1 { enabledTabs.remove(t.rawValue) }
        // Keep the default-tab selection pointing at a visible tab.
        if !enabledTabs.contains(defaultTab.rawValue), let first = visibleTabs.first {
            defaultTab = first
        }
    }
}
