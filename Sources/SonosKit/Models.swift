import Foundation

/// One Sonos room as the user sees it, plus where to send commands for it.
public struct Room: Equatable, Sendable, Identifiable {
    public let id: String              // the speaker's UUID, e.g. RINCON_...
    public let name: String
    public let host: String            // this speaker's address
    public let coordinatorHost: String // the speaker that runs the group's playback
    public let groupedWith: [String]   // names of the other rooms in the same group
    public let groupHosts: [String]    // every speaker in this room's group, this one included
    public let coordinatorID: String   // the lead speaker's id (what other speakers join)

    public init(id: String, name: String, host: String, coordinatorHost: String, groupedWith: [String],
                groupHosts: [String]? = nil, coordinatorID: String = "") {
        self.id = id
        self.name = name
        self.host = host
        self.coordinatorHost = coordinatorHost
        self.groupedWith = groupedWith
        self.groupHosts = groupHosts ?? [host]
        self.coordinatorID = coordinatorID
    }
}

public enum PlaybackState: Equatable, Sendable {
    case playing, paused, stopped, transitioning, unknown

    init(sonosValue: String?) {
        switch sonosValue {
        case "PLAYING": self = .playing
        case "PAUSED_PLAYBACK": self = .paused
        case "STOPPED": self = .stopped
        case "TRANSITIONING": self = .transitioning
        default: self = .unknown
        }
    }
}

public struct NowPlaying: Equatable, Sendable {
    public let state: PlaybackState
    public let title: String?
    public let artist: String?

    public init(state: PlaybackState, title: String?, artist: String?) {
        self.state = state
        self.title = title
        self.artist = artist
    }
}

/// Plain-language errors; the menu shows `errorDescription` as is.
public enum SonosError: Error, Equatable, LocalizedError {
    case noSpeakers
    case localNetworkDenied
    case unreachable
    case roomNotFound
    case notAllowed          // the speaker refused (e.g. "next" on a radio station)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .noSpeakers: return "No Sonos speakers found. Is this Mac on the same Wi-Fi as your speakers?"
        case .localNetworkDenied: return "Local Network access is turned off for this app."
        case .unreachable: return "Can't reach your Sonos speakers right now."
        case .roomNotFound: return "That speaker isn't available any more."
        case .notAllowed: return "Sonos doesn't allow that for what's playing."
        case .badResponse: return "Got an unexpected answer from Sonos."
        }
    }
}

/// Where a speaker is in its queue: track number and seconds into that track.
public struct TrackPosition: Equatable, Sendable {
    public let track: Int
    public let seconds: Int
    public init(track: Int, seconds: Int) {
        self.track = track
        self.seconds = seconds
    }

    /// Sonos writes times as "H:MM:SS". Anything else (radio streams say NOT_IMPLEMENTED) has no position.
    static func seconds(fromSonosTime text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":").map { Int($0) }
        guard parts.count == 3, let h = parts[0], let m = parts[1], let s = parts[2] else { return nil }
        return h * 3600 + m * 60 + s
    }

    static func sonosTime(fromSeconds total: Int) -> String {
        String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
