import Testing
@testable import SonosKit

@Test func roomsWithTheSameNameFollowThePositionNotTheAlphabet() {
    #expect(RoomOrder.sorted(["Kitchen, down", "Kitchen, up"]) == ["Kitchen, up", "Kitchen, down"])
    #expect(RoomOrder.sorted(["Shelf bottom", "Shelf middle", "Shelf top"]) == ["Shelf top", "Shelf middle", "Shelf bottom"])
    #expect(RoomOrder.sorted(["TV, højre", "TV, left"]) == ["TV, left", "TV, højre"])
    #expect(RoomOrder.sorted(["Right room", "Left room"]) == ["Left room", "Right room"])
}

@Test func numbersAreNaturalAndOtherRoomsStayAlphabetical() {
    #expect(RoomOrder.sorted(["Room 10", "Room 2", "Room 1"]) == ["Room 1", "Room 2", "Room 10"])
    #expect(RoomOrder.sorted(["Pendant three", "Pendant one", "Pendant two"]) == ["Pendant one", "Pendant two", "Pendant three"])
    #expect(RoomOrder.sorted(["Kitchen, up", "Guest Room", "Kitchen, down", "Dining Room"])
            == ["Dining Room", "Guest Room", "Kitchen, up", "Kitchen, down"])
    #expect(RoomOrder.sorted(["Up", "Down", "Lamp"]) == ["Down", "Lamp", "Up"]) // a lone word is not a position
}
