import ServiceManagement

/// "Open when I log in", using Apple's built-in login item support.
enum LaunchAtLogin {
    static var isOn: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS wants the user to approve the login item in System Settings.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
