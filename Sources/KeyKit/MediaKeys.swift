import Foundation

/// The media keys we know how to handle. Add a case here (and in `decode`) to support another key.
public enum MediaKey: Hashable, Sendable, CaseIterable {
    case playPause, next, previous
    case volumeUp, volumeDown, mute

    /// Holding these keys keeps sending presses (like holding volume up to keep turning it up).
    public var repeatsWhenHeld: Bool { self == .volumeUp || self == .volumeDown }

    /// Play/pause, next, previous: keys where an Option modifier has no meaning of its own in macOS.
    public var isTransport: Bool { self == .playPause || self == .next || self == .previous }
}

public struct MediaKeyEvent: Equatable, Sendable {
    public let key: MediaKey
    public let isDown: Bool
    public let isRepeat: Bool
}

public enum MediaKeyDecoder {
    /// Reads the raw number macOS attaches to a media key event ("data1").
    /// Returns nil for keys we don't handle, so those keep working normally.
    public static func decode(data1: Int) -> MediaKeyEvent? {
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0x0000_FFFF
        let state = (flags & 0xFF00) >> 8      // 0xA = pressed, 0xB = released
        guard state == 0xA || state == 0xB else { return nil }

        let key: MediaKey
        switch code {
        case 16: key = .playPause          // F8
        case 17, 19: key = .next           // F9 (Apple keyboards report 19 "fast", others 17 "next")
        case 18, 20: key = .previous       // F7 (Apple keyboards report 20 "rewind", others 18 "previous")
        case 0: key = .volumeUp            // F12
        case 1: key = .volumeDown          // F11
        case 7: key = .mute                // F10
        default: return nil
        }
        return MediaKeyEvent(key: key, isDown: state == 0xA, isRepeat: (flags & 0x1) == 1)
    }
}

/// Connects keys to actions. It never knows what the actions do.
public final class KeyRouter {
    private struct Entry {
        var action: () -> Void
        var isActive: () -> Bool
    }
    private var entries: [MediaKey: Entry] = [:]

    public init() {}

    /// `isActive` is asked on every key press: return false to let the key go to the Mac as usual.
    /// It runs inside the key listener, so it must be quick.
    public func register(_ key: MediaKey, isActive: @escaping () -> Bool = { true }, action: @escaping () -> Void) {
        entries[key] = Entry(action: action, isActive: isActive)
    }

    /// True if some action wants this key right now (so the key should be kept away from other apps).
    public func claims(_ key: MediaKey) -> Bool {
        entries[key]?.isActive() ?? false
    }

    public func fire(_ key: MediaKey) {
        entries[key]?.action()
    }
}
