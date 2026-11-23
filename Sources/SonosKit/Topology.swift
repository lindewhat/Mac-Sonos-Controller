import Foundation

/// Turns Sonos' "zone group state" answer into a list of rooms.
enum Topology {
    static func rooms(fromZoneGroupState xml: String) -> [Room] {
        let delegate = Parser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()

        var rooms: [Room] = []
        for group in delegate.groups {
            guard let coordinator = group.members.first(where: { $0.uuid == group.coordinatorUUID }),
                  !coordinator.host.isEmpty else { continue }
            let visible = group.members.filter { !$0.hidden && !$0.host.isEmpty }
            for member in visible {
                rooms.append(Room(
                    id: member.uuid,
                    name: member.name,
                    host: member.host,
                    coordinatorHost: coordinator.host,
                    groupedWith: visible.filter { $0.uuid != member.uuid }.map(\.name),
                    groupHosts: visible.map(\.host),
                    coordinatorID: coordinator.uuid
                ))
            }
        }
        return rooms.sorted { RoomOrder.areInIncreasingOrder($0.name, $1.name) }
    }

    private struct Member { var uuid: String; var name: String; var host: String; var hidden: Bool }
    private struct Group { var coordinatorUUID: String; var members: [Member] = [] }

    private final class Parser: NSObject, XMLParserDelegate {
        var groups: [Group] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            if name == "ZoneGroup" {
                groups.append(Group(coordinatorUUID: a["Coordinator"] ?? ""))
            } else if name == "ZoneGroupMember", !groups.isEmpty {
                let host = a["Location"].flatMap { URL(string: $0)?.host } ?? ""
                // Hidden = bonded extras (surround speakers, subs) and Sonos Boost units.
                let hidden = a["Invisible"] == "1" || a["IsZoneBridge"] == "1"
                groups[groups.count - 1].members.append(
                    Member(uuid: a["UUID"] ?? "", name: a["ZoneName"] ?? "Sonos", host: host, hidden: hidden))
            }
        }
    }
}

/// Reads the track info Sonos returns while something is playing.
struct TrackInfo: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var station: String?
    /// Where the speaker serves the cover art, e.g. "/getaa?s=1&u=...". Only paths on the speaker are accepted:
    /// a full web address would mean fetching from the internet, which this app never does.
    var artPath: String?

    static func parse(metadata: String?) -> TrackInfo {
        guard let metadata, metadata.contains("<") else { return TrackInfo() }
        let v = SimpleXML.leafValues(in: metadata)
        let name = clean(v["dc:title"])
        let onAir = clean(v["r:streamContent"]) // for radio: what is playing right now
        let art = clean(v["upnp:albumArtURI"])
        return TrackInfo(title: onAir ?? name, artist: clean(v["dc:creator"]), album: clean(v["upnp:album"]),
                         station: onAir == nil ? nil : name,
                         artPath: art?.hasPrefix("/") == true ? art : nil)
    }

    /// The title of what a speaker is set to play (for radio, the station name).
    static func sourceName(metadata: String?) -> String? {
        guard let metadata, metadata.contains("<") else { return nil }
        return clean(SimpleXML.leafValues(in: metadata)["dc:title"])
    }

    private static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }
}

/// Reads a list of songs from a speaker's queue answer.
enum QueueList {
    static func parse(didl: String?) -> [QueueItem] {
        guard let didl, didl.contains("<") else { return [] }
        let delegate = Parser()
        let parser = XMLParser(data: Data(didl.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var items: [QueueItem] = []
        private var inItem = false
        private var field: String?
        private var title = ""
        private var artist = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" { inItem = true; title = ""; artist = "" }
            else if inItem, name == "dc:title" || name == "dc:creator" { field = name }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if field == "dc:title" { title += string } else if field == "dc:creator" { artist += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "dc:title" || name == "dc:creator" { field = nil }
            if name == "item" {
                inItem = false
                let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { items.append(QueueItem(title: t, artist: a.isEmpty ? nil : a)) }
            }
        }
    }
}
