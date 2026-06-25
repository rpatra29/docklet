import AppKit

// Set before run() so app never briefly appears in Dock
NSApplication.shared.setActivationPolicy(.accessory)

let delegate = MainActor.assumeIsolated { AppDelegate() }
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
