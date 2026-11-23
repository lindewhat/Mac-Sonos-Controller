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
        return rooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
enum TrackInfo {
    static func parse(metadata: String?) -> (title: String?, artist: String?) {
        guard let metadata, metadata.contains("<") else { return (nil, nil) }
        let v = SimpleXML.leafValues(in: metadata)
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        let title = clean(v["dc:title"]) ?? clean(v["r:streamContent"])
        return (title, clean(v["dc:creator"]))
    }
}
