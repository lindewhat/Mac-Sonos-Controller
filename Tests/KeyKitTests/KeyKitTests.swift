import Testing
@testable import KeyKit

private func data1(code: Int, state: Int, isRepeat: Bool = false) -> Int {
    (code << 16) | (state << 8) | (isRepeat ? 1 : 0)
}

@Test func playPausePressAndRelease() {
    #expect(MediaKeyDecoder.decode(data1: data1(code: 16, state: 0xA)) == MediaKeyEvent(key: .playPause, isDown: true, isRepeat: false))
    #expect(MediaKeyDecoder.decode(data1: data1(code: 16, state: 0xB))?.isDown == false)
}

@Test func holdingAKeyIsMarkedAsRepeat() {
    #expect(MediaKeyDecoder.decode(data1: data1(code: 16, state: 0xA, isRepeat: true))?.isRepeat == true)
}

@Test func appleAndOtherKeyboardsBothWork() {
    #expect(MediaKeyDecoder.decode(data1: data1(code: 19, state: 0xA))?.key == .next)
    #expect(MediaKeyDecoder.decode(data1: data1(code: 17, state: 0xA))?.key == .next)
    #expect(MediaKeyDecoder.decode(data1: data1(code: 20, state: 0xA))?.key == .previous)
    #expect(MediaKeyDecoder.decode(data1: data1(code: 18, state: 0xA))?.key == .previous)
}

@Test func otherKeysAreLeftAlone() {
    #expect(MediaKeyDecoder.decode(data1: data1(code: 2, state: 0xA)) == nil)   // brightness etc.
    #expect(MediaKeyDecoder.decode(data1: data1(code: 21, state: 0xA)) == nil)
    #expect(MediaKeyDecoder.decode(data1: 0) == nil)
}

@Test func volumeKeysAreRecognisedAndRepeat() {
    #expect(MediaKeyDecoder.decode(data1: data1(code: 0, state: 0xA))?.key == .volumeUp)
    #expect(MediaKeyDecoder.decode(data1: data1(code: 1, state: 0xA))?.key == .volumeDown)
    #expect(MediaKeyDecoder.decode(data1: data1(code: 7, state: 0xA))?.key == .mute)
    #expect(MediaKey.volumeUp.repeatsWhenHeld && MediaKey.volumeDown.repeatsWhenHeld)
    #expect(!MediaKey.mute.repeatsWhenHeld && !MediaKey.playPause.repeatsWhenHeld)
    #expect(MediaKey.playPause.isTransport && MediaKey.next.isTransport && MediaKey.previous.isTransport)
    #expect(!MediaKey.volumeUp.isTransport && !MediaKey.mute.isTransport)
}

@Test func routerLetsKeysThroughWhenAnActionStepsAside() {
    let router = KeyRouter()
    var active = true
    router.register(.volumeUp, isActive: { active }) {}
    #expect(router.claims(.volumeUp))
    active = false
    #expect(!router.claims(.volumeUp)) // e.g. headphones plugged in: the Mac handles the key
}

@Test func routerOnlyClaimsKeysThatHaveAnAction() {
    let router = KeyRouter()
    var fired: [MediaKey] = []
    router.register(.playPause) { fired.append(.playPause) }
    #expect(router.claims(.playPause))
    #expect(!router.claims(.next))
    router.fire(.playPause)
    router.fire(.next) // nothing registered: nothing happens
    #expect(fired == [.playPause])
}
