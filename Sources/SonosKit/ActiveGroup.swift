import Foundation

/// Decides which group of rooms the app is looking after (the rooms that are ticked in the menu).
public enum ActiveGroup {
    /// - `previous`: the rooms that were ticked last time.
    /// Picks the group that shares the most rooms with `previous`; if none does, a group that is
    /// playing; otherwise the biggest group. Returns the ids of that group's rooms.
    public static func choose(rooms: [Room], previous: Set<String>, playingHosts: Set<String>) -> Set<String> {
        var order: [String] = []
        var byLead: [String: [Room]] = [:]
        for room in rooms {
            if byLead[room.coordinatorHost] == nil { order.append(room.coordinatorHost) }
            byLead[room.coordinatorHost, default: []].append(room)
        }
        var best: (ids: Set<String>, score: [Int])?
        for lead in order {
            let ids = Set(byLead[lead, default: []].map(\.id))
            let score = [ids.intersection(previous).count, playingHosts.contains(lead) ? 1 : 0, ids.count]
            if best == nil || score.lexicographicallyPrecedes(best!.score) == false && score != best!.score {
                best = (ids, score)
            }
        }
        return best?.ids ?? []
    }
}
