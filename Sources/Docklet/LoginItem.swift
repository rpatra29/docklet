import ServiceManagement

// Thin wrapper around SMAppService for the "Launch at login" toggle.
// The grant is registered with the running app bundle, so it only takes
// effect for the installed .app (not transient `swift run` builds).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister the app as a login item. Returns false if the
    /// system rejected the change (e.g. running outside a proper bundle).
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("Docklet: login item \(enabled ? "register" : "unregister") failed — \(error.localizedDescription)")
            return false
        }
    }
}
