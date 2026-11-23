import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    controller.start()
    app.run()
}
