import Foundation

/// The individual Sonos commands we use. Each one talks to a single speaker.
public struct SonosClient: Sendable {
    let transport: SonosTransport

    public init(transport: SonosTransport = HTTPSonosTransport()) {
        self.transport = transport
    }

    private func avTransport(_ action: String, _ extra: [(name: String, value: String)] = []) -> SOAPCall {
        SOAPCall(service: .avTransport, action: action, arguments: [("InstanceID", "0")] + extra)
    }

    public func rooms(host: String) async throws -> [Room] {
        let answer = try await transport.send(
            SOAPCall(service: .zoneGroupTopology, action: "GetZoneGroupState"), to: host)
        guard let state = answer["ZoneGroupState"] else { throw SonosError.badResponse }
        return Topology.rooms(fromZoneGroupState: state)
    }

    /// Makes this speaker leave its group and play on its own.
    public func leaveGroup(host: String) async throws {
        _ = try await transport.send(avTransport("BecomeCoordinatorOfStandaloneGroup"), to: host)
    }

    /// Makes this speaker join the group led by the speaker with the given id.
    public func join(host: String, coordinatorID: String) async throws {
        _ = try await transport.send(
            avTransport("SetAVTransportURI", [("CurrentURI", "x-rincon:\(coordinatorID)"), ("CurrentURIMetaData", "")]),
            to: host)
    }

    public func play(host: String) async throws {
        _ = try await transport.send(avTransport("Play", [("Speed", "1")]), to: host)
    }

    public func pause(host: String) async throws {
        _ = try await transport.send(avTransport("Pause"), to: host)
    }

    public func stop(host: String) async throws {
        _ = try await transport.send(avTransport("Stop"), to: host)
    }

    public func next(host: String) async throws {
        _ = try await transport.send(avTransport("Next"), to: host)
    }

    public func previous(host: String) async throws {
        _ = try await transport.send(avTransport("Previous"), to: host)
    }

    public func state(host: String) async throws -> PlaybackState {
        let answer = try await transport.send(avTransport("GetTransportInfo"), to: host)
        return PlaybackState(sonosValue: answer["CurrentTransportState"])
    }

    /// Everything the menu shows about what is playing. Only the first two questions must be answered;
    /// play mode, source and queue are extras, so a speaker that skips them still gives a usable result.
    public func nowPlaying(host: String) async throws -> NowPlaying {
        let state = try await self.state(host: host)
        let position = try await transport.send(avTransport("GetPositionInfo"), to: host)
        let info = TrackInfo.parse(metadata: position["TrackMetaData"])
        let track = position["Track"].flatMap { Int($0) } ?? 0
        let duration = TrackPosition.seconds(fromSonosTime: position["TrackDuration"]).flatMap { $0 > 0 ? $0 : nil }
        let elapsed = duration == nil ? nil : TrackPosition.seconds(fromSonosTime: position["RelTime"])

        async let modeAnswer: PlayMode? = (try? await self.playMode(host: host)) ?? nil
        async let mediaAnswer: MediaInfo? = try? await self.mediaInfo(host: host)
        let mode = await modeAnswer
        let media = await mediaAnswer
        let hasQueue = media?.uri?.hasPrefix("x-rincon-queue:") ?? false

        // The next songs are only known when the queue plays in order: with shuffle Sonos picks the next
        // song itself and does not tell, and with repeat-one the next song is this one again.
        var upNext: [QueueItem] = []
        if hasQueue, track > 0, let mode, !mode.shuffle, mode.repeatMode != .one {
            upNext = (try? await queue(host: host, after: track, count: 2)) ?? []
        }
        return NowPlaying(
            state: state, title: info.title, artist: info.artist, album: info.album,
            station: hasQueue ? nil : (media?.station ?? info.station),
            artURL: info.artPath.flatMap { URL(string: "http://\(host):1400\($0)") },
            elapsedSeconds: elapsed, durationSeconds: duration,
            playMode: hasQueue ? mode : nil, hasQueue: hasQueue, upNext: upNext)
    }

    struct MediaInfo: Sendable {
        let uri: String?
        let station: String?
    }

    func mediaInfo(host: String) async throws -> MediaInfo {
        let answer = try await transport.send(avTransport("GetMediaInfo"), to: host)
        return MediaInfo(uri: answer["CurrentURI"], station: TrackInfo.sourceName(metadata: answer["CurrentURIMetaData"]))
    }

    public func playMode(host: String) async throws -> PlayMode? {
        let answer = try await transport.send(avTransport("GetTransportSettings"), to: host)
        return PlayMode(sonosValue: answer["PlayMode"])
    }

    public func setPlayMode(host: String, _ mode: PlayMode) async throws {
        _ = try await transport.send(avTransport("SetPlayMode", [("NewPlayMode", mode.sonosValue)]), to: host)
    }

    /// The songs after the current one, in queue order. `track` is the current song's 1-based number.
    func queue(host: String, after track: Int, count: Int) async throws -> [QueueItem] {
        let call = SOAPCall(service: .contentDirectory, action: "Browse", arguments: [
            ("ObjectID", "Q:0"), ("BrowseFlag", "BrowseDirectChildren"), ("Filter", "dc:title,dc:creator"),
            ("StartingIndex", String(track)), ("RequestedCount", String(count)), ("SortCriteria", "")])
        let answer = try await transport.send(call, to: host)
        return QueueList.parse(didl: answer["Result"])
    }

    /// Track number and time into the track, or nil for things without a position (radio streams).
    public func position(host: String) async throws -> TrackPosition? {
        let answer = try await transport.send(avTransport("GetPositionInfo"), to: host)
        guard let track = answer["Track"].flatMap({ Int($0) }), track > 0,
              let seconds = TrackPosition.seconds(fromSonosTime: answer["RelTime"]) else { return nil }
        return TrackPosition(track: track, seconds: seconds)
    }

    public func seek(host: String, track: Int) async throws {
        _ = try await transport.send(avTransport("Seek", [("Unit", "TRACK_NR"), ("Target", String(track))]), to: host)
    }

    public func seek(host: String, seconds: Int) async throws {
        _ = try await transport.send(
            avTransport("Seek", [("Unit", "REL_TIME"), ("Target", TrackPosition.sonosTime(fromSeconds: seconds))]), to: host)
    }

    // Volume and mute apply to the whole group, so they go to the group's coordinator.

    private func groupVolume(_ action: String, _ extra: [(name: String, value: String)] = []) -> SOAPCall {
        SOAPCall(service: .groupRenderingControl, action: action, arguments: [("InstanceID", "0")] + extra)
    }

    /// Turns one speaker's own volume up or down by `steps` (negative = down).
    public func adjustVolume(host: String, by steps: Int) async throws {
        let call = SOAPCall(service: .renderingControl, action: "SetRelativeVolume",
                            arguments: [("InstanceID", "0"), ("Channel", "Master"), ("Adjustment", String(steps))])
        _ = try await transport.send(call, to: host)
    }

    public func isGroupMuted(host: String) async throws -> Bool {
        let answer = try await transport.send(groupVolume("GetGroupMute"), to: host)
        return answer["CurrentMute"] == "1"
    }

    public func setGroupMute(host: String, muted: Bool) async throws {
        _ = try await transport.send(groupVolume("SetGroupMute", [("DesiredMute", muted ? "1" : "0")]), to: host)
    }
}
