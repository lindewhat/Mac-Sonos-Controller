import Testing
@testable import SonosKit

private func rooms(_ groups: [[String]]) -> [Room] {
    groups.flatMap { group in
        group.map { name in
            Room(id: name, name: name, host: "host-\(name)", coordinatorHost: "host-\(group[0])",
                 groupedWith: group.filter { $0 != name }, groupHosts: group.map { "host-\($0)" })
        }
    }
}

@Test func theGroupThatKeepsMostOfTheTickedRoomsStaysActive() {
    // Dining left the group of four; the three that stay together are still the active group.
    let now = rooms([["Dining"], ["Guest", "KitchenUp", "KitchenDown"]])
    #expect(ActiveGroup.choose(rooms: now, previous: ["Dining", "Guest", "KitchenUp", "KitchenDown"], playingHosts: []) == ["Guest", "KitchenUp", "KitchenDown"])
}

@Test func whenNothingOverlapsAPlayingGroupWins() {
    let now = rooms([["A", "B", "C"], ["D"]])
    #expect(ActiveGroup.choose(rooms: now, previous: [], playingHosts: ["host-D"]) == ["D"])
}

@Test func whenNothingOverlapsAndNothingPlaysTheBiggestGroupWins() {
    let now = rooms([["A"], ["B", "C"]])
    #expect(ActiveGroup.choose(rooms: now, previous: [], playingHosts: []) == ["B", "C"])
}

@Test func noRoomsMeansNothingIsActive() {
    #expect(ActiveGroup.choose(rooms: [], previous: ["A"], playingHosts: []).isEmpty)
}
