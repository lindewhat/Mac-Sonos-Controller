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

    public func nowPlaying(host: String) async throws -> NowPlaying {
        let state = try await self.state(host: host)
        let position = try await transport.send(avTransport("GetPositionInfo"), to: host)
        let info = TrackInfo.parse(metadata: position["TrackMetaData"])
        return NowPlaying(state: state, title: info.title, artist: info.artist)
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
