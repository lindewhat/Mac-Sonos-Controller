import Foundation
@testable import SonosKit

/// Realistic Sonos answers used by the tests. Names are made up.
enum Fixtures {
    // Kitchen + Living Room are grouped (Kitchen leads). Bedroom is alone and has a hidden sub.
    static let zoneGroupState = """
    <ZoneGroupState><ZoneGroups>
    <ZoneGroup Coordinator="RINCON_KITCHEN" ID="RINCON_KITCHEN:1">
      <ZoneGroupMember UUID="RINCON_KITCHEN" Location="http://10.0.0.11:1400/xml/device_description.xml" ZoneName="Kitchen"/>
      <ZoneGroupMember UUID="RINCON_LIVING" Location="http://10.0.0.12:1400/xml/device_description.xml" ZoneName="Living Room"/>
    </ZoneGroup>
    <ZoneGroup Coordinator="RINCON_BED" ID="RINCON_BED:2">
      <ZoneGroupMember UUID="RINCON_BED" Location="http://10.0.0.13:1400/xml/device_description.xml" ZoneName="Bedroom">
        <Satellite UUID="RINCON_SAT" Location="http://10.0.0.14:1400/xml/device_description.xml" Invisible="1"/>
      </ZoneGroupMember>
      <ZoneGroupMember UUID="RINCON_SUB" Location="http://10.0.0.15:1400/xml/device_description.xml" ZoneName="Bedroom" Invisible="1"/>
    </ZoneGroup>
    <ZoneGroup Coordinator="RINCON_BOOST" ID="RINCON_BOOST:3">
      <ZoneGroupMember UUID="RINCON_BOOST" Location="http://10.0.0.16:1400/xml/device_description.xml" ZoneName="BOOST" IsZoneBridge="1"/>
    </ZoneGroup>
    </ZoneGroups></ZoneGroupState>
    """

    // What Sonos sends back: the group state is XML-escaped inside the SOAP answer.
    static var zoneGroupSOAPAnswer: [String: String] { ["ZoneGroupState": zoneGroupState] }

    static let didl = """
    <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
    xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/"><item id="-1" parentID="-1" restricted="true">\
    <res protocolInfo="x-sonos-http:*:*:*">x-sonos-http:song.mp4</res>\
    <dc:title>Blue in Green &amp; More</dc:title><dc:creator>Miles Davis</dc:creator>\
    <upnp:album>Kind of Blue</upnp:album><upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-http%3asong.mp4</upnp:albumArtURI></item></DIDL-Lite>
    """

    // The next two songs in the queue, as Sonos answers a queue "Browse".
    static let queueDIDL = """
    <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">\
    <item id="Q:0/3" parentID="Q:0"><dc:title>So What</dc:title><dc:creator>Miles Davis</dc:creator></item>\
    <item id="Q:0/4" parentID="Q:0"><dc:title>Freddie Freeloader</dc:title><dc:creator></dc:creator></item></DIDL-Lite>
    """
}

/// A pretend speaker network: records every command and answers from a script.
final class FakeTransport: SonosTransport, @unchecked Sendable {
    struct Sent: Equatable { let action: String; let host: String }

    private let lock = NSLock()
    private var _sent: [Sent] = []
    var reachableHosts: Set<String> = ["10.0.0.11", "10.0.0.12", "10.0.0.13"]
    var transportState = "PAUSED_PLAYBACK"
    var failPauseWithRefusal = false
    var muted = false
    var track = "1"
    var relTime = "0:00:05"
    var trackDuration = "0:03:00"
    var mediaURI = "x-rincon-queue:RINCON_KITCHEN#0" // what is playing: the queue, or a radio stream
    var mediaMetadata = ""
    private var _playMode = "NORMAL"
    var playMode: String { get { lock.lock(); defer { lock.unlock() }; return _playMode } set { lock.lock(); _playMode = newValue; lock.unlock() } }
    private var _args: [String: String] = [:]
    var lastArguments: [String: String] { lock.lock(); defer { lock.unlock() }; return _args }

    var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return _sent }

    private func record(_ item: Sent, _ call: SOAPCall) {
        lock.lock(); _sent.append(item)
        for a in call.arguments { _args[a.name] = a.value }
        lock.unlock()
    }

    func send(_ call: SOAPCall, to host: String) async throws -> [String: String] {
        record(Sent(action: call.action, host: host), call)
        guard reachableHosts.contains(host) else { throw SonosError.unreachable }
        switch call.action {
        case "GetZoneGroupState": return Fixtures.zoneGroupSOAPAnswer
        case "GetTransportInfo": return ["CurrentTransportState": transportState]
        case "GetPositionInfo":
            return ["TrackMetaData": Fixtures.didl, "Track": track, "RelTime": relTime, "TrackDuration": trackDuration]
        case "GetTransportSettings": return ["PlayMode": playMode]
        case "SetPlayMode":
            playMode = call.arguments.first { $0.name == "NewPlayMode" }?.value ?? playMode
            return [:]
        case "GetMediaInfo": return ["CurrentURI": mediaURI, "CurrentURIMetaData": mediaMetadata]
        case "Browse": return ["Result": Fixtures.queueDIDL]
        case "GetGroupMute": return ["CurrentMute": muted ? "1" : "0"]
        case "Pause" where failPauseWithRefusal: throw SonosError.notAllowed
        default: return [:]
        }
    }
}
