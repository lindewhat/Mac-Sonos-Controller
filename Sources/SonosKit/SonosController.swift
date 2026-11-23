import Foundation

/// What a search for speakers on the network found.
public struct DiscoveryResult: Sendable {
    public var hosts: [String]
    public var localNetworkDenied: Bool
    public init(hosts: [String], localNetworkDenied: Bool = false) {
        self.hosts = hosts
        self.localNetworkDenied = localNetworkDenied
    }
}

public enum RefreshResult: Equatable, Sendable {
    case rooms([Room])
    case noSpeakers
    case localNetworkDenied
    case unreachable
}

/// Knows the rooms and sends commands to the right speaker.
/// Before every command it re-reads the room groups, so grouping changes are always respected:
/// commands for a room go to the coordinator of that room's current group.
public actor SonosController {
    private let client: SonosClient
    private let discover: @Sendable () async -> DiscoveryResult
    private var hosts: [String] = []
    private var rooms: [Room] = []

    public init(client: SonosClient = SonosClient(), discover: @escaping @Sendable () async -> DiscoveryResult) {
        self.client = client
        self.discover = discover
    }

    /// Re-reads the rooms; searches the network again only if known speakers don't answer.
    public func refresh() async -> RefreshResult {
        if let found = await roomsFromKnownHosts() { return .rooms(found) }
        let result = await discover()
        if result.hosts.isEmpty {
            return result.localNetworkDenied ? .localNetworkDenied : .noSpeakers
        }
        hosts = result.hosts
        if let found = await roomsFromKnownHosts() { return .rooms(found) }
        return .unreachable
    }

    private func roomsFromKnownHosts() async -> [Room]? {
        for host in hosts {
            if let found = try? await client.rooms(host: host), !found.isEmpty {
                rooms = found
                // Remember every speaker we learned about, the one that answered first.
                hosts = [host] + found.map(\.host).filter { $0 != host }
                return found
            }
        }
        return nil
    }

    /// The rooms a command is for.
    private func rooms(for roomIDs: [String]) async throws -> [Room] {
        switch await refresh() {
        case .rooms(let found):
            let chosen = found.filter { roomIDs.contains($0.id) }
            if chosen.isEmpty { throw SonosError.roomNotFound }
            return chosen
        case .noSpeakers: throw SonosError.noSpeakers
        case .localNetworkDenied: throw SonosError.localNetworkDenied
        case .unreachable: throw SonosError.unreachable
        }
    }

    /// The lead speaker of each group involved (one entry per group).
    private func coordinatorHosts(for roomIDs: [String]) async throws -> [String] {
        unique(try await rooms(for: roomIDs).map(\.coordinatorHost))
    }

    private func unique(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    /// Runs a command on several speakers at the same time. A speaker that fails is skipped;
    /// it only counts as a failure if every speaker failed.
    private func run(on hosts: [String], _ operation: @escaping @Sendable (String) async throws -> Void) async throws {
        let errors: [Error?] = await withTaskGroup(of: Error?.self) { group in
            for host in hosts {
                group.addTask {
                    do { try await operation(host); return nil } catch { return error }
                }
            }
            var all: [Error?] = []
            for await result in group { all.append(result) }
            return all
        }
        if !errors.isEmpty, errors.allSatisfy({ $0 != nil }), let first = errors.compactMap({ $0 }).first {
            throw first
        }
    }

    private func playbackStates(_ hosts: [String]) async -> [(host: String, state: PlaybackState)] {
        let client = self.client
        return await withTaskGroup(of: (String, PlaybackState)?.self) { group in
            for host in hosts {
                group.addTask {
                    guard let state = try? await client.state(host: host) else { return nil }
                    return (host, state)
                }
            }
            var found: [(host: String, state: PlaybackState)] = []
            for await item in group { if let item { found.append((host: item.0, state: item.1)) } }
            // Keep the original order so results are predictable.
            return hosts.compactMap { host in found.first { $0.host == host } }
        }
    }

    private func isPlaying(_ state: PlaybackState) -> Bool { state == .playing || state == .transitioning }

    /// Plays if nothing is playing, pauses whatever is playing. Returns the new state.
    @discardableResult
    public func togglePlayPause(roomIDs: [String]) async throws -> PlaybackState {
        let hosts = try await coordinatorHosts(for: roomIDs)
        let states = await playbackStates(hosts)
        if states.isEmpty { throw SonosError.unreachable }
        let client = self.client
        let playing = states.filter { isPlaying($0.state) }.map(\.host)
        if !playing.isEmpty {
            try await run(on: playing) { host in
                do {
                    try await client.pause(host: host)
                } catch SonosError.notAllowed {
                    try await client.stop(host: host) // radio stations can't pause, only stop
                }
            }
            return .paused
        }
        try await run(on: hosts) { try await client.play(host: $0) }
        return .playing
    }

    /// Pauses whatever is playing in these rooms (stops it if the source can't pause). Does nothing if nothing plays.
    public func pause(roomIDs: [String]) async throws {
        let hosts = try await coordinatorHosts(for: roomIDs)
        let client = self.client
        let playing = await playbackStates(hosts).filter { isPlaying($0.state) }.map(\.host)
        try await run(on: playing) { host in
            do {
                try await client.pause(host: host)
            } catch SonosError.notAllowed {
                try await client.stop(host: host)
            }
        }
    }

    /// Takes one room out of its group; it plays on its own (and is quiet unless started again).
    public func leaveGroup(roomID: String) async throws {
        let room = try await singleRoom(roomID)
        guard room.groupHosts.count > 1 else { return } // already on its own
        try await client.leaveGroup(host: room.host)
    }

    /// Adds a room to the music another room is playing. Does nothing if they already play together.
    public func join(roomID: String, to targetRoomID: String) async throws {
        guard case .rooms(let found) = await refresh() else { throw SonosError.unreachable }
        guard let room = found.first(where: { $0.id == roomID }),
              let target = found.first(where: { $0.id == targetRoomID }) else { throw SonosError.roomNotFound }
        if room.coordinatorHost == target.coordinatorHost { return }
        if room.groupHosts.count > 1 { try await client.leaveGroup(host: room.host) } // leave the old group first
        try await client.join(host: room.host, coordinatorID: target.coordinatorID)
    }

    /// Stops the music in these rooms and splits them up, so each is on its own.
    public func stopAndUngroup(roomIDs: [String]) async throws {
        let rooms = try await self.rooms(for: roomIDs)
        try await pause(roomIDs: roomIDs)
        // Followers first, lead speakers last, so the group never has to hand over to someone already leaving.
        let followers = rooms.filter { $0.host != $0.coordinatorHost }
        for room in followers where room.groupHosts.count > 1 {
            try await client.leaveGroup(host: room.host)
        }
        // A leader that is already alone is left untouched: asking it to "leave" could reset its song.
        let leaders = rooms.filter { $0.host == $0.coordinatorHost }
        if !followers.isEmpty, case .rooms(let fresh) = await refresh() {
            for leader in leaders where fresh.first(where: { $0.id == leader.id })?.groupHosts.count ?? 1 > 1 {
                try await client.leaveGroup(host: leader.host)
            }
        } else {
            for leader in leaders where leader.groupHosts.count > 1 { try await client.leaveGroup(host: leader.host) }
        }
    }

    /// Where the music of this room's group is right now (track and time), if it has a position.
    public func position(ofRoom roomID: String) async -> TrackPosition? {
        guard let hosts = try? await coordinatorHosts(for: [roomID]), let host = hosts.first else { return nil }
        return (try? await client.position(host: host)) ?? nil
    }

    /// Puts the music of this room's group back at a saved spot, if it has drifted back (for example to the start).
    public func restore(_ saved: TrackPosition, ofRoom roomID: String) async {
        guard let hosts = try? await coordinatorHosts(for: [roomID]), let host = hosts.first,
              let now = (try? await client.position(host: host)) ?? nil else { return }
        let sameTrack = now.track == saved.track
        if sameTrack && now.seconds >= saved.seconds - 3 { return } // already where it was
        if !sameTrack { try? await client.seek(host: host, track: saved.track) }
        if saved.seconds > 3 { try? await client.seek(host: host, seconds: saved.seconds) }
    }

    /// Lead speakers (as host addresses) that are playing right now, among the rooms we know.
    public func playingHosts() async -> Set<String> {
        let hosts = unique(rooms.map(\.coordinatorHost))
        return Set(await playbackStates(hosts).filter { isPlaying($0.state) }.map(\.host))
    }

    private func singleRoom(_ roomID: String) async throws -> Room {
        guard let room = try await rooms(for: [roomID]).first else { throw SonosError.roomNotFound }
        return room
    }

    public func next(roomIDs: [String]) async throws {
        let client = self.client
        try await run(on: try await hostsToSkip(roomIDs)) { try await client.next(host: $0) }
    }

    public func previous(roomIDs: [String]) async throws {
        let client = self.client
        try await run(on: try await hostsToSkip(roomIDs)) { try await client.previous(host: $0) }
    }

    /// For several groups, skipping only makes sense for the ones that are playing.
    private func hostsToSkip(_ roomIDs: [String]) async throws -> [String] {
        let hosts = try await coordinatorHosts(for: roomIDs)
        guard hosts.count > 1 else { return hosts }
        let playing = await playbackStates(hosts).filter { isPlaying($0.state) }.map(\.host)
        return playing.isEmpty ? hosts : playing
    }

    /// Volume up/down for every speaker in the room's group (or in every group), each by the same
    /// number of steps, so every speaker audibly changes, even quiet ones.
    public func adjustVolume(roomIDs: [String], by steps: Int) async throws {
        let hosts = unique(try await rooms(for: roomIDs).flatMap(\.groupHosts))
        let client = self.client
        try await run(on: hosts) { try await client.adjustVolume(host: $0, by: steps) }
    }

    /// Mutes if anything is unmuted, unmutes if everything is muted.
    public func toggleMute(roomIDs: [String]) async throws {
        let hosts = try await coordinatorHosts(for: roomIDs)
        let client = self.client
        let muted = await withTaskGroup(of: Bool?.self) { group in
            for host in hosts { group.addTask { try? await client.isGroupMuted(host: host) } }
            var all: [Bool] = []
            for await m in group { if let m { all.append(m) } }
            return all
        }
        if muted.isEmpty { throw SonosError.unreachable }
        let desired = !muted.allSatisfy { $0 }
        try await run(on: hosts) { try await client.setGroupMute(host: $0, muted: desired) }
    }

    public func nowPlaying(roomIDs: [String]) async throws -> NowPlaying {
        let hosts = try await coordinatorHosts(for: roomIDs)
        let client = self.client
        var results: [NowPlaying] = []
        for host in hosts {
            if let info = try? await client.nowPlaying(host: host) { results.append(info) }
        }
        // With several groups, show the first one that is playing.
        guard let best = results.first(where: { isPlaying($0.state) }) ?? results.first else {
            throw SonosError.unreachable
        }
        return best
    }
}
