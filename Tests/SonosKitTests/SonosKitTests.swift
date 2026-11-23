import Foundation
import Testing
@testable import SonosKit

// MARK: - Commands and parsing

@Test func commandBodyIsWellFormedAndEscaped() {
    let call = SOAPCall(service: .avTransport, action: "SetThing", arguments: [("InstanceID", "0"), ("Value", "a<b&c")])
    #expect(call.soapActionHeader == "\"urn:schemas-upnp-org:service:AVTransport:1#SetThing\"")
    #expect(call.body.contains("<u:SetThing xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
    #expect(call.body.contains("<Value>a&lt;b&amp;c</Value>"))
    #expect(SimpleXML.leafValues(in: call.body)["Value"] == "a<b&c") // it parses back to the original
}

@Test func roomsAreParsedAndHiddenSpeakersSkipped() {
    let rooms = Topology.rooms(fromZoneGroupState: Fixtures.zoneGroupState)
    #expect(rooms.map(\.name) == ["Bedroom", "Kitchen", "Living Room"]) // no sub, no Boost, no duplicates
}

@Test func groupedRoomsShareTheCoordinator() throws {
    let rooms = Topology.rooms(fromZoneGroupState: Fixtures.zoneGroupState)
    let living = try #require(rooms.first { $0.name == "Living Room" })
    #expect(living.host == "10.0.0.12")
    #expect(living.coordinatorHost == "10.0.0.11") // Kitchen leads the group
    #expect(living.groupedWith == ["Kitchen"])
    #expect(living.groupHosts == ["10.0.0.11", "10.0.0.12"])
    let bedroom = try #require(rooms.first { $0.name == "Bedroom" })
    #expect(bedroom.coordinatorHost == "10.0.0.13")
    #expect(bedroom.groupedWith.isEmpty)
}

@Test func brokenAnswersGiveNoRoomsInsteadOfCrashing() {
    #expect(Topology.rooms(fromZoneGroupState: "").isEmpty)
    #expect(Topology.rooms(fromZoneGroupState: "<not xml").isEmpty)
}

@Test func nowPlayingTitleAndArtistAreRead() {
    let info = TrackInfo.parse(metadata: Fixtures.didl)
    #expect(info.title == "Blue in Green & More")
    #expect(info.artist == "Miles Davis")
    #expect(TrackInfo.parse(metadata: "NOT_IMPLEMENTED").title == nil)
    #expect(TrackInfo.parse(metadata: nil).title == nil)
}

// MARK: - Controller behaviour (against the pretend network)

private let allRoomIDs = ["RINCON_KITCHEN", "RINCON_LIVING", "RINCON_BED"]

private func makeController(_ fake: FakeTransport, found: [String] = ["10.0.0.12"]) -> SonosController {
    SonosController(client: SonosClient(transport: fake), discover: { DiscoveryResult(hosts: found) })
}

@Test func playPauseSendsPlayToTheGroupCoordinator() async throws {
    let fake = FakeTransport()
    fake.transportState = "PAUSED_PLAYBACK"
    let controller = makeController(fake)
    let state = try await controller.togglePlayPause(roomIDs: ["RINCON_LIVING"]) // grouped, not the leader
    #expect(state == .playing)
    #expect(fake.sent.last == FakeTransport.Sent(action: "Play", host: "10.0.0.11"))
}

@Test func playPauseSendsPauseWhenPlaying() async throws {
    let fake = FakeTransport()
    fake.transportState = "PLAYING"
    let state = try await makeController(fake).togglePlayPause(roomIDs: ["RINCON_BED"])
    #expect(state == .paused)
    #expect(fake.sent.last == FakeTransport.Sent(action: "Pause", host: "10.0.0.13"))
}

@Test func radioThatCannotPauseIsStoppedInstead() async throws {
    let fake = FakeTransport()
    fake.transportState = "PLAYING"
    fake.failPauseWithRefusal = true
    _ = try await makeController(fake).togglePlayPause(roomIDs: ["RINCON_BED"])
    #expect(fake.sent.last?.action == "Stop")
}

@Test func nextAndPreviousGoToTheCoordinator() async throws {
    let fake = FakeTransport()
    let controller = makeController(fake)
    try await controller.next(roomIDs: ["RINCON_LIVING"])
    #expect(fake.sent.last == FakeTransport.Sent(action: "Next", host: "10.0.0.11"))
    try await controller.previous(roomIDs: ["RINCON_LIVING"])
    #expect(fake.sent.last == FakeTransport.Sent(action: "Previous", host: "10.0.0.11"))
}

@Test func volumeChangesEveryoneInTheGroup() async throws {
    let fake = FakeTransport()
    let controller = makeController(fake)
    try await controller.adjustVolume(roomIDs: ["RINCON_LIVING"], by: 2)
    let volumeCommands = fake.sent.filter { $0.action == "SetRelativeVolume" }
    #expect(Set(volumeCommands.map(\.host)) == ["10.0.0.11", "10.0.0.12"]) // Kitchen and Living Room, nobody else
    #expect(volumeCommands.count == 2)
    #expect(fake.lastArguments["Adjustment"] == "2")
    #expect(fake.lastArguments["Channel"] == "Master")
    try await controller.adjustVolume(roomIDs: ["RINCON_LIVING"], by: -2)
    #expect(fake.lastArguments["Adjustment"] == "-2")
}

@Test func volumeWorksEvenIfOneSpeakerInTheGroupIsOffline() async throws {
    let fake = FakeTransport()
    fake.reachableHosts = ["10.0.0.11"] // Living Room (10.0.0.12) doesn't answer commands
    // The room list still comes from a reachable speaker, so this must not throw.
    try await makeController(fake, found: ["10.0.0.11"]).adjustVolume(roomIDs: ["RINCON_KITCHEN"], by: 2)
    #expect(fake.sent.contains(.init(action: "SetRelativeVolume", host: "10.0.0.11")))
}

// MARK: - All rooms

@Test func allRoomsPlayStartsEveryGroupOnce() async throws {
    let fake = FakeTransport()
    fake.transportState = "PAUSED_PLAYBACK"
    let state = try await makeController(fake).togglePlayPause(roomIDs: allRoomIDs)
    #expect(state == .playing)
    let plays = fake.sent.filter { $0.action == "Play" }
    #expect(Set(plays.map(\.host)) == ["10.0.0.11", "10.0.0.13"]) // Kitchen's group and Bedroom
    #expect(plays.count == 2)
}

@Test func allRoomsPausesEverythingThatIsPlaying() async throws {
    let fake = FakeTransport()
    fake.transportState = "PLAYING"
    let state = try await makeController(fake).togglePlayPause(roomIDs: allRoomIDs)
    #expect(state == .paused)
    #expect(Set(fake.sent.filter { $0.action == "Pause" }.map(\.host)) == ["10.0.0.11", "10.0.0.13"])
}

@Test func allRoomsVolumeReachesEverySpeaker() async throws {
    let fake = FakeTransport()
    try await makeController(fake).adjustVolume(roomIDs: allRoomIDs, by: -2)
    let hosts = Set(fake.sent.filter { $0.action == "SetRelativeVolume" }.map(\.host))
    #expect(hosts == ["10.0.0.11", "10.0.0.12", "10.0.0.13"])
}

@Test func allRoomsNextSkipsEveryPlayingGroup() async throws {
    let fake = FakeTransport()
    fake.transportState = "PLAYING"
    try await makeController(fake).next(roomIDs: allRoomIDs)
    #expect(Set(fake.sent.filter { $0.action == "Next" }.map(\.host)) == ["10.0.0.11", "10.0.0.13"])
}

@Test func allRoomsMuteMutesEverythingUnlessAllAreMuted() async throws {
    let fake = FakeTransport()
    fake.muted = false
    try await makeController(fake).toggleMute(roomIDs: allRoomIDs)
    #expect(fake.sent.filter { $0.action == "SetGroupMute" }.count == 2)
    #expect(fake.lastArguments["DesiredMute"] == "1")
    fake.muted = true
    try await makeController(fake).toggleMute(roomIDs: allRoomIDs)
    #expect(fake.lastArguments["DesiredMute"] == "0")
}

@Test func pauseOnlyTouchesRoomsThatArePlaying() async throws {
    let fake = FakeTransport()
    fake.transportState = "PLAYING"
    try await makeController(fake).pause(roomIDs: ["RINCON_BED"])
    #expect(fake.sent.filter { $0.action == "Pause" }.map(\.host) == ["10.0.0.13"])
    fake.transportState = "PAUSED_PLAYBACK"
    let before = fake.sent.count
    try await makeController(fake).pause(roomIDs: ["RINCON_BED"])
    #expect(!fake.sent.dropFirst(before).contains { $0.action == "Pause" }) // already paused: nothing to do
}

@Test func onlyTheChosenRoomsAreControlled() async throws {
    let fake = FakeTransport()
    fake.transportState = "PAUSED_PLAYBACK"
    try await makeController(fake).togglePlayPause(roomIDs: ["RINCON_BED"]) // Kitchen's group not chosen
    #expect(fake.sent.filter { $0.action == "Play" }.map(\.host) == ["10.0.0.13"])
}

@Test func leavingTakesOneRoomOutOfItsGroup() async throws {
    let fake = FakeTransport()
    try await makeController(fake).leaveGroup(roomID: "RINCON_LIVING")
    #expect(fake.sent.last == FakeTransport.Sent(action: "BecomeCoordinatorOfStandaloneGroup", host: "10.0.0.12"))
}

@Test func aRoomAloneHasNothingToLeave() async throws {
    let fake = FakeTransport()
    try await makeController(fake).leaveGroup(roomID: "RINCON_BED")
    #expect(!fake.sent.contains { $0.action == "BecomeCoordinatorOfStandaloneGroup" })
}

@Test func joiningPointsTheRoomAtTheLeadSpeaker() async throws {
    let fake = FakeTransport()
    try await makeController(fake).join(roomID: "RINCON_BED", to: "RINCON_LIVING") // Kitchen leads that group
    #expect(fake.sent.last == FakeTransport.Sent(action: "SetAVTransportURI", host: "10.0.0.13"))
    #expect(fake.lastArguments["CurrentURI"] == "x-rincon:RINCON_KITCHEN")
}

@Test func joiningLeavesTheOldGroupFirst() async throws {
    let fake = FakeTransport()
    try await makeController(fake).join(roomID: "RINCON_LIVING", to: "RINCON_BED")
    let actions = fake.sent.map(\.action).filter { $0 == "BecomeCoordinatorOfStandaloneGroup" || $0 == "SetAVTransportURI" }
    #expect(actions == ["BecomeCoordinatorOfStandaloneGroup", "SetAVTransportURI"])
}

@Test func joiningARoomThatIsAlreadyInTheGroupDoesNothing() async throws {
    let fake = FakeTransport()
    try await makeController(fake).join(roomID: "RINCON_LIVING", to: "RINCON_KITCHEN")
    #expect(!fake.sent.contains { $0.action == "SetAVTransportURI" })
}

@Test func stopAndUngroupPausesThenSplitsFollowersBeforeTheLeader() async throws {
    let fake = FakeTransport()
    fake.transportState = "PLAYING"
    try await makeController(fake).stopAndUngroup(roomIDs: ["RINCON_KITCHEN", "RINCON_LIVING"])
    let relevant = fake.sent.filter { $0.action == "Pause" || $0.action == "BecomeCoordinatorOfStandaloneGroup" }
    #expect(relevant.first?.action == "Pause")
    #expect(relevant.last == FakeTransport.Sent(action: "BecomeCoordinatorOfStandaloneGroup", host: "10.0.0.11")) // leader last
    #expect(relevant.filter { $0.action == "BecomeCoordinatorOfStandaloneGroup" }.count == 2)
}

@Test func muteFlipsTheCurrentState() async throws {
    let fake = FakeTransport()
    let controller = makeController(fake)
    fake.muted = false
    try await controller.toggleMute(roomIDs: ["RINCON_BED"])
    #expect(fake.sent.last == FakeTransport.Sent(action: "SetGroupMute", host: "10.0.0.13"))
    #expect(fake.lastArguments["DesiredMute"] == "1")
    fake.muted = true
    try await controller.toggleMute(roomIDs: ["RINCON_BED"])
    #expect(fake.lastArguments["DesiredMute"] == "0")
}

@Test func nowPlayingComesFromTheCoordinator() async throws {
    let fake = FakeTransport()
    fake.transportState = "PLAYING"
    let info = try await makeController(fake).nowPlaying(roomIDs: ["RINCON_LIVING"])
    #expect(info.state == .playing)
    #expect(info.title == "Blue in Green & More")
    #expect(info.artist == "Miles Davis")
    #expect(info.album == "Kind of Blue")
    // The cover is fetched from the speaker that leads the group, never from anywhere else.
    #expect(info.artURL?.absoluteString == "http://10.0.0.11:1400/getaa?s=1&u=x-sonos-http%3asong.mp4")
}

@Test func nowPlayingFromTheQueueHasProgressControlsAndUpNext() async throws {
    let fake = FakeTransport()
    fake.transportState = "PLAYING"
    fake.track = "2"
    fake.relTime = "0:01:30"
    let info = try await makeController(fake).nowPlaying(roomIDs: ["RINCON_LIVING"])
    #expect(info.elapsedSeconds == 90 && info.durationSeconds == 180)
    #expect(info.hasQueue)
    #expect(info.playMode == PlayMode(shuffle: false, repeatMode: .off))
    #expect(info.upNext == [QueueItem(title: "So What", artist: "Miles Davis"),
                            QueueItem(title: "Freddie Freeloader", artist: nil)])
    // Browse starts after the current song: song 2 is queue index 1, so the next one starts at index 2.
    #expect(fake.lastArguments["StartingIndex"] == "2")
}

@Test func upNextIsHiddenWhenTheOrderIsNotKnown() async throws {
    for mode in ["SHUFFLE_NOREPEAT", "SHUFFLE", "REPEAT_ONE", "SHUFFLE_REPEAT_ONE"] {
        let fake = FakeTransport()
        fake.transportState = "PLAYING"
        fake.playMode = mode
        let info = try await makeController(fake).nowPlaying(roomIDs: ["RINCON_LIVING"])
        #expect(info.upNext.isEmpty, "mode \(mode)")
        #expect(!fake.sent.contains { $0.action == "Browse" }, "mode \(mode) should not even ask for the queue")
        #expect(info.playMode != nil)
    }
}

@Test func radioHasNoQueueShuffleOrProgressButKeepsTheStationName() async throws {
    let fake = FakeTransport()
    fake.transportState = "PLAYING"
    fake.mediaURI = "x-sonosapi-stream:s1234?sid=254"
    fake.mediaMetadata = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><item><dc:title>Radio Example</dc:title></item></DIDL-Lite>"
    fake.trackDuration = "0:00:00"
    let info = try await makeController(fake).nowPlaying(roomIDs: ["RINCON_LIVING"])
    #expect(!info.hasQueue)
    #expect(info.playMode == nil && info.upNext.isEmpty)
    #expect(info.durationSeconds == nil && info.elapsedSeconds == nil)
    #expect(info.station == "Radio Example")
    #expect(!fake.sent.contains { $0.action == "Browse" })
}

@Test func shuffleAndRepeatControlsChangeTheModeStepByStep() async throws {
    let fake = FakeTransport()
    let controller = makeController(fake)
    try await controller.toggleShuffle(roomIDs: ["RINCON_LIVING"])
    #expect(fake.playMode == "SHUFFLE_NOREPEAT")
    try await controller.cycleRepeat(roomIDs: ["RINCON_LIVING"])
    #expect(fake.playMode == "SHUFFLE") // shuffle with repeat all
    try await controller.cycleRepeat(roomIDs: ["RINCON_LIVING"])
    #expect(fake.playMode == "SHUFFLE_REPEAT_ONE")
    try await controller.toggleShuffle(roomIDs: ["RINCON_LIVING"])
    #expect(fake.playMode == "REPEAT_ONE")
    try await controller.cycleRepeat(roomIDs: ["RINCON_LIVING"])
    #expect(fake.playMode == "NORMAL")
    // Group commands go to the coordinator (the Kitchen), not to the room that was ticked.
    #expect(fake.sent.filter { $0.action == "SetPlayMode" }.allSatisfy { $0.host == "10.0.0.11" })
}

@Test func playModeWordsRoundTrip() {
    for word in ["NORMAL", "REPEAT_ALL", "REPEAT_ONE", "SHUFFLE_NOREPEAT", "SHUFFLE", "SHUFFLE_REPEAT_ONE"] {
        #expect(PlayMode(sonosValue: word)?.sonosValue == word)
    }
    #expect(PlayMode(sonosValue: "NOT_IMPLEMENTED") == nil)
    #expect(PlayMode(sonosValue: nil) == nil)
}

@Test func coverArtMustBeAPathOnTheSpeaker() {
    func didl(_ art: String) -> String {
        "<DIDL-Lite xmlns:dc=\"d\" xmlns:upnp=\"u\"><item><dc:title>T</dc:title><upnp:albumArtURI>\(art)</upnp:albumArtURI></item></DIDL-Lite>"
    }
    #expect(TrackInfo.parse(metadata: didl("/getaa?s=1")).artPath == "/getaa?s=1")
    // A web address would send the app to the internet; it is ignored.
    #expect(TrackInfo.parse(metadata: didl("https://cdn.example.com/cover.jpg")).artPath == nil)
}

@Test func radioShowsWhatIsOnAirAsTheTitleAndTheStationAsDetail() {
    let metadata = "<DIDL-Lite xmlns:dc=\"d\" xmlns:r=\"r\"><item><dc:title>Radio Example</dc:title><r:streamContent>Some Artist - Some Song</r:streamContent></item></DIDL-Lite>"
    let info = TrackInfo.parse(metadata: metadata)
    #expect(info.title == "Some Artist - Some Song")
    #expect(info.station == "Radio Example")
}

@Test func missingSpeakersGiveAClearErrorNotACrash() async {
    let fake = FakeTransport()
    let controller = makeController(fake, found: [])
    await #expect(throws: SonosError.noSpeakers) { try await controller.togglePlayPause(roomIDs: ["RINCON_BED"]) }
    #expect(await controller.refresh() == .noSpeakers)
}

@Test func deniedLocalNetworkIsReportedSeparately() async {
    let controller = SonosController(
        client: SonosClient(transport: FakeTransport()),
        discover: { DiscoveryResult(hosts: [], localNetworkDenied: true) })
    #expect(await controller.refresh() == .localNetworkDenied)
}

@Test func speakersThatStopAnsweringAreReportedAsUnreachable() async {
    let fake = FakeTransport()
    fake.reachableHosts = []
    let controller = makeController(fake)
    #expect(await controller.refresh() == .unreachable)
}

@Test func unknownRoomIsReported() async {
    let controller = makeController(FakeTransport())
    await #expect(throws: SonosError.roomNotFound) { try await controller.next(roomIDs: ["RINCON_GONE"]) }
}

// MARK: - Real HTTP layer, with a stand-in for the network

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let (status, body) = Self.handler?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct HTTPTransportTests {
    private func transport(log: Log? = nil) -> HTTPSonosTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return HTTPSonosTransport(session: URLSession(configuration: config), log: log)
    }

    @Test func theLogNamesSpeakersByAnonymousLabelNeverByAddress() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("log-test-\(UUID().uuidString)")
        let log = Log(fileURL: folder.appendingPathComponent("Test.log"), verbose: true)
        let sender = transport(log: log)
        StubURLProtocol.handler = { _ in (200, "<s:Envelope><s:Body><u:R><X>1</X></u:R></s:Body></s:Envelope>") }
        _ = try await sender.send(SOAPCall(service: .avTransport, action: "GetTransportInfo"), to: "10.0.0.5")
        StubURLProtocol.handler = { _ in (500, "<s:Envelope><s:Body><s:Fault><errorCode>701</errorCode></s:Fault></s:Body></s:Envelope>") }
        _ = try? await sender.send(SOAPCall(service: .avTransport, action: "Pause"), to: "10.0.0.6")
        _ = try? await sender.send(SOAPCall(service: .avTransport, action: "Pause"), to: "10.0.0.5")
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(!text.contains("10.0.0."))
        #expect(text.contains("speaker 1 GetTransportInfo ok"))
        #expect(text.contains("speaker 2 Pause refused"))
        #expect(text.contains("speaker 1 Pause refused")) // the same speaker keeps its label
    }

    @Test func sendsTheRightRequest() async throws {
        StubURLProtocol.handler = { _ in (200, "<s:Envelope><s:Body><u:R><CurrentTransportState>PLAYING</CurrentTransportState></u:R></s:Body></s:Envelope>") }
        let answer = try await transport().send(SOAPCall(service: .avTransport, action: "GetTransportInfo"), to: "10.0.0.5")
        #expect(answer["CurrentTransportState"] == "PLAYING")
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "http://10.0.0.5:1400/MediaRenderer/AVTransport/Control")
        #expect(request.value(forHTTPHeaderField: "SOAPACTION") == "\"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo\"")
    }

    @Test func refusalBecomesNotAllowed() async {
        StubURLProtocol.handler = { _ in (500, "<s:Envelope><s:Body><s:Fault><errorCode>701</errorCode></s:Fault></s:Body></s:Envelope>") }
        await #expect(throws: SonosError.notAllowed) {
            try await transport().send(SOAPCall(service: .avTransport, action: "Pause"), to: "10.0.0.5")
        }
    }
}

@Test func positionTimesAreParsedAndFormatted() {
    #expect(TrackPosition.seconds(fromSonosTime: "0:03:25") == 205)
    #expect(TrackPosition.seconds(fromSonosTime: "NOT_IMPLEMENTED") == nil)
    #expect(TrackPosition.sonosTime(fromSeconds: 3725) == "1:02:05")
}

@Test func restoreSeeksBackWhenTheSongStartedOver() async throws {
    let fake = FakeTransport() // reports track 1 at 0:00:05
    await makeController(fake).restore(TrackPosition(track: 4, seconds: 125), ofRoom: "RINCON_KITCHEN")
    let seeks = fake.sent.filter { $0.action == "Seek" }
    #expect(seeks.count == 2) // first the track, then the time
    #expect(fake.lastArguments["Unit"] == "REL_TIME")
    #expect(fake.lastArguments["Target"] == "0:02:05")
}

@Test func restoreLeavesAnAlreadyCorrectPositionAlone() async throws {
    let fake = FakeTransport()
    fake.track = "4"
    fake.relTime = "0:02:06"
    await makeController(fake).restore(TrackPosition(track: 4, seconds: 125), ofRoom: "RINCON_KITCHEN")
    #expect(!fake.sent.contains { $0.action == "Seek" })
}
