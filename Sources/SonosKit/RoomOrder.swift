import Foundation

/// Sorts room names the way a person would read them (same rules as the Hue app's light order).
///
/// - Numbers and letters in natural order: "Room 2" before "Room 10", "Zone a" before "Zone b".
/// - Rooms that share a name and differ only by a position word follow the position, not the alphabet:
///   up → middle → down, left → middle → right, front → back, first → second → third, one → two → three.
///   Danish works too (venstre/højre, øverst/nederst, op/ned, første/anden...).
///   So "Kitchen, up" comes before "Kitchen, down", and "TV, left" before "TV, højre".
/// The position word can be the last word ("Kitchen, up", "TV, left") or the first ("Left lamp").
public enum RoomOrder {
    public static func areInIncreasingOrder(_ a: String, _ b: String) -> Bool {
        let ka = key(a), kb = key(b)
        if let ra = ka.rank, let rb = kb.rank, ka.base == kb.base, ra != rb {
            return ra < rb
        }
        // Different families of names: order by the shared part first, so "TV left/right" stay together.
        let baseOrder = ka.base.localizedStandardCompare(kb.base)
        if baseOrder != .orderedSame { return baseOrder == .orderedAscending }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    public static func sorted(_ names: [String]) -> [String] { names.sorted(by: areInIncreasingOrder) }

    /// The name without its position word, plus where that word puts it (nil when there's no position word).
    static func key(_ name: String) -> (base: String, rank: Int?) {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "-" || $0 == "(" || $0 == ")" || $0 == "/" })
            .map(String.init)
        guard words.count >= 2, let first = words.first, let last = words.last else { return (name.lowercased(), nil) }
        if let rank = rank(of: last) {
            return (words.dropLast().joined(separator: " ").lowercased(), rank)
        }
        if let rank = rank(of: first) {
            return (words.dropFirst().joined(separator: " ").lowercased(), rank)
        }
        return (name.lowercased(), nil)
    }

    static func rank(of word: String) -> Int? {
        ranks[word.lowercased()]
    }

    /// Lower comes first. Each family uses 0 for its start, 10 for the middle and 20 for its end, so mixed
    /// families still line up (left/up/front before middle before right/down/back).
    private static let ranks: [String: Int] = {
        var r: [String: Int] = [:]
        func add(_ words: [String], _ value: Int) { for w in words { r[w] = value } }

        // Top to bottom
        add(["top", "upper", "up", "over", "above", "high", "øverst", "øverste", "øvre", "øvert", "op", "oppe", "top"], 0)
        add(["bottom", "lower", "down", "under", "below", "low", "nederst", "nederste", "nedre", "ned", "nede"], 20)
        // Left to right
        add(["left", "venstre"], 0)
        add(["right", "højre", "hojre", "hoejre"], 20)
        // Front to back
        add(["front", "forrest", "forreste", "foran"], 0)
        add(["back", "rear", "bagerst", "bagerste", "bag", "bagved"], 20)
        // Inner to outer
        add(["inner", "inside", "indre", "inderst"], 0)
        add(["outer", "outside", "ydre", "yderst"], 20)
        // Middle of any of the above
        add(["middle", "mid", "center", "centre", "central", "midt", "midterste", "midterst", "mellem", "midten"], 10)

        // First, second, third... and one, two, three... (English and Danish)
        let ordinals = [["first", "første", "one", "en", "et", "1st"],
                        ["second", "anden", "andet", "two", "2nd"],
                        ["third", "tredje", "three", "tre", "3rd"],
                        ["fourth", "fjerde", "four", "fire", "4th"],
                        ["fifth", "femte", "five", "fem", "5th"],
                        ["sixth", "sjette", "six", "seks", "6th"]]
        for (i, words) in ordinals.enumerated() { add(words, 100 + i) }
        return r
    }()
}
