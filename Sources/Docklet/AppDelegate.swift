import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel?
    private var statusItem: NSStatusItem?
    private var state = PillState()
    private var settings: SettingsWindowController?
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = OverlayPanel(sharedState: state)
        panel?.orderFront(nil)
        settings = SettingsWindowController(state: state)
        setupStatusItem()
        if Onboarding.needsOnboarding {
            // Populate the default weather pill via IP without showing a location
            // permission alert before onboarding has explained why it is needed.
            WeatherMonitor.shared.refresh(requestLocationPermission: false)
            onboarding = OnboardingWindowController()
            onboarding?.show()
        } else {
            WeatherMonitor.shared.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaptureMonitor.shared.finishRecordingIfNeeded()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem?.button {
            btn.image = NSImage(systemSymbolName: "oval.fill", accessibilityDescription: "Docklet")
            btn.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Docklet", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func openSettings() { settings?.show() }

    @objc private func quit() { NSApp.terminate(nil) }
}
