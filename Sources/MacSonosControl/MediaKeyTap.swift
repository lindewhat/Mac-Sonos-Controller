import AppKit
import ApplicationServices
import KeyKit

/// Listens for the keyboard's media keys and keeps them away from other apps (so Apple Music
/// doesn't start) whenever the router has an action for them.
///
/// Safety: the tap lives on the main thread. If the app ever freezes, macOS switches the tap off
/// by itself after about a second and the keys behave normally again. If the app quits or
/// crashes, the tap disappears with it.
@MainActor
final class MediaKeyTap {
    private let router: KeyRouter
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var passedToMac: Set<MediaKey> = [] // keys whose current press was handed to the Mac (Option held)

    var isRunning: Bool { tap != nil }

    init(router: KeyRouter) {
        self.router = router
    }

    /// Returns false if macOS refused (permission missing).
    func start() -> Bool {
        if isRunning { return true }
        let systemDefined: CGEventType = CGEventType(rawValue: 14)! // NX_SYSDEFINED: media keys live here
        let mask: CGEventMask = 1 << systemDefined.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: mediaKeyTapCallback, userInfo: refcon) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Belt and braces: if macOS ever switches the tap off, switch it back on.
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAlive() }
        }
        return true
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    /// Called every few seconds. Returns normally; if permission was taken away, the tap is dropped.
    var onPermissionLost: (() -> Void)?

    private func checkAlive() {
        guard let tap else { return }
        if !AXIsProcessTrusted() {
            stop()
            onPermissionLost?()
        } else if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14,
              let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8,
              let media = MediaKeyDecoder.decode(data1: nsEvent.data1),
              router.claims(media.key)
        else {
            return Unmanaged.passUnretained(event)
        }
        // Holding Option sends the key to the Mac as usual. The whole press (down, repeats, up) goes to the
        // Mac even if Option is let go early. Play/next/previous with Option held do nothing in macOS, so
        // Option is taken off the event first; volume keys keep it (Option+volume opens Sound settings).
        if media.isDown && !media.isRepeat {
            if nsEvent.modifierFlags.contains(.option) { passedToMac.insert(media.key) } else { passedToMac.remove(media.key) }
        }
        if passedToMac.contains(media.key) {
            if !media.isDown { passedToMac.remove(media.key) }
            if media.key.isTransport { event.flags.remove(.maskAlternate) }
            return Unmanaged.passUnretained(event)
        }
        if media.isDown && (!media.isRepeat || media.key.repeatsWhenHeld) {
            router.fire(media.key) // the action itself starts its work in the background
        }
        return nil // swallow press, repeat and release so no other app sees them
    }
}

private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
}
