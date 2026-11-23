import AppKit
import ApplicationServices
import KeyKit
import SonosKit

/// The menu bar icon and its menu. Shows what we know and sends the user's clicks and key presses to Sonos.
@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private enum Screen { case searching, ready, noSpeakers, localNetworkDenied, unreachable }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let sonos = SonosController(discover: { await BonjourDiscovery().discover() })
    private let router = KeyRouter()
    private lazy var keyTap = MediaKeyTap(router: router)

    private var screen: Screen = .searching
    private var rooms: [Room] = []
    private var nowPlaying: NowPlaying?
    private var message: String?        // last problem, shown in plain language
    private var refreshing = false
    private var needsAccessibility = false
    private var notice: String?         // problems that aren't about Sonos (e.g. launch at login)
    private var volumeBusy = false
    private var tickBusy: Bool { pendingTicks > 0 }
    private var pendingTicks = 0
    private var tickChain: Task<Void, Never>?
    private lazy var guide = GuideWindow(
        status: { [unowned self] in self.guideStatus() },
        openLocalNetwork: { [unowned self] in self.openLocalNetworkSettings() },
        openAccessibility: { [unowned self] in self.openAccessibilitySettings() })
    private var permissionTimer: Timer?

    private let activeKey = "activeRoomIDs"
    private let nothingTickedKey = "nothingTicked"
    private let keysEnabledKey = "mediaKeysControlSonos"
    private let volumeKeysKey = "volumeKeysControlSonos"
    private let guideShownKey = "guideShown"

    private var keysEnabled: Bool {
        get { UserDefaults.standard.object(forKey: keysEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keysEnabledKey) }
    }

    /// Off by default: the Mac's own volume keys keep working until the user opts in.
    private var volumeKeysEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: volumeKeysKey) }
        set { UserDefaults.standard.set(newValue, forKey: volumeKeysKey) }
    }

    /// The rooms that play together right now: the ticked rooms in the menu.
    private var activeIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: activeKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: activeKey) }
    }

    /// True after the user unticked the last room, until they tick one again.
    private var nothingTicked: Bool {
        get { UserDefaults.standard.bool(forKey: nothingTickedKey) }
        set { UserDefaults.standard.set(newValue, forKey: nothingTickedKey) }
    }

    /// The ticked rooms that exist right now (may be none). Keys and the Play/Pause item control these.
    private var selectedRoomIDs: [String] {
        let ticked = activeIDs
        return rooms.filter { ticked.contains($0.id) }.map(\.id)
    }

    func start() {
        menu.delegate = self
        statusItem.menu = menu

        // What each media key does. The key listener knows nothing about Sonos; to add another
        // action, register another closure here.
        router.register(.playPause) { [weak self] in self?.perform { try await $0.togglePlayPause(roomIDs: $1) } }
        router.register(.next) { [weak self] in self?.perform { try await $0.next(roomIDs: $1) } }
        router.register(.previous) { [weak self] in self?.perform { try await $0.previous(roomIDs: $1) } }

        // Volume keys: only when switched on, and never when the Mac's sound is going to headphones,
        // other speakers or a call (see MacAudio).
        let sonosHandlesVolume = { [unowned self] in self.volumeKeysEnabled && !MacAudio.macShouldHandleVolume() }
        router.register(.volumeUp, isActive: sonosHandlesVolume) { [weak self] in self?.nudgeVolume(by: 2) }
        router.register(.volumeDown, isActive: sonosHandlesVolume) { [weak self] in self?.nudgeVolume(by: -2) }
        router.register(.mute, isActive: sonosHandlesVolume) { [weak self] in
            self?.perform(refreshNowPlaying: false) { try await $0.toggleMute(roomIDs: $1) }
        }

        keyTap.onPermissionLost = { [weak self] in self?.applyKeySetting() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyTap.stop() } // give the keys back to macOS
        }

        applyKeySetting()
        rebuildMenu()
        refresh()

        // Show the guide the first time, and again whenever the keys can't work yet.
        if !UserDefaults.standard.bool(forKey: guideShownKey) || (keysEnabled && needsAccessibility) {
            UserDefaults.standard.set(true, forKey: guideShownKey)
            guide.show()
        }
    }

    private func guideStatus() -> GuideStatus {
        let speakers: GuideStatus.Speakers
        switch screen {
        case .searching: speakers = .searching
        case .ready: speakers = .found(rooms.count)
        case .localNetworkDenied: speakers = .denied
        case .noSpeakers, .unreachable: speakers = .none
        }
        let fnValue = CFPreferencesCopyAppValue("com.apple.keyboard.fnState" as CFString, kCFPreferencesAnyApplication)
        let standard = (fnValue as? Bool) ?? ((fnValue as? Int).map { $0 != 0 } ?? false)
        return GuideStatus(speakers: speakers, accessibilityGranted: AXIsProcessTrusted(), fKeysAreStandard: standard)
    }

    // MARK: - Media keys on/off

    /// Makes the key tap match the on/off switch. If macOS wants a permission first, asks for it
    /// and keeps checking until it's granted.
    private func applyKeySetting() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        needsAccessibility = false

        if keysEnabled {
            if !keyTap.start() {
                needsAccessibility = true
                if !AXIsProcessTrusted() {
                    // Shows macOS's own "wants to control your computer" prompt.
                    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyKeySettingQuietly() }
                }
            }
        } else {
            keyTap.stop()
        }
        updateIcon()
        rebuildMenu()
    }

    /// Same as above but without showing the system prompt again.
    private func applyKeySettingQuietly() {
        guard keysEnabled, !keyTap.isRunning else { return }
        if keyTap.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            needsAccessibility = false
            updateIcon()
            rebuildMenu()
        }
    }

    @objc private func toggleKeys() {
        keysEnabled.toggle()
        applyKeySetting()
    }

    @objc private func toggleVolumeKeys() {
        volumeKeysEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(!LaunchAtLogin.isOn && !LaunchAtLogin.needsApproval)
            if LaunchAtLogin.needsApproval {
                notice = "Approve Mac Sonos Control under Login Items in System Settings."
                LaunchAtLogin.openSystemSettings()
            } else {
                notice = nil
            }
        } catch {
            notice = "Couldn't change the launch at login setting."
        }
        rebuildMenu()
    }

    @objc private func showGuide() {
        guide.show()
    }

    @objc private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: - Talking to Sonos

    /// Runs one Sonos command for the ticked rooms (used by both the menu and the keys).
    /// With nothing ticked, nothing happens.
    private func perform(refreshNowPlaying: Bool = true,
                         _ work: @escaping @Sendable (SonosController, [String]) async throws -> Void) {
        let sonos = self.sonos
        Task {
            let ids = await currentRoomIDs()
            guard !ids.isEmpty else { return }
            do {
                try await work(sonos, ids)
                message = nil
                if refreshNowPlaying { nowPlaying = try? await sonos.nowPlaying(roomIDs: ids) }
            } catch {
                message = error.localizedDescription
            }
            updateIcon()
            rebuildMenu()
        }
    }

    /// One volume step. While the key is held, presses that arrive during a step are skipped,
    /// so the speaker is never flooded with commands.
    private func nudgeVolume(by steps: Int) {
        guard !volumeBusy else { return }
        volumeBusy = true
        let sonos = self.sonos
        Task {
            let ids = await currentRoomIDs()
            if !ids.isEmpty {
                do { try await sonos.adjustVolume(roomIDs: ids, by: steps); message = nil }
                catch { message = error.localizedDescription }
                updateIcon()
                rebuildMenu()
            }
            volumeBusy = false
        }
    }

    /// The rooms to control; searches for rooms first if we don't know any yet.
    private func currentRoomIDs() async -> [String] {
        if rooms.isEmpty { applyResult(await sonos.refresh()) }
        return selectedRoomIDs
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let result = await sonos.refresh()
            if tickBusy { refreshing = false; return } // a tick is mid-change; its own refresh will follow
            if case .rooms = result {
                applyResult(result, playingHosts: await sonos.playingHosts())
            } else {
                applyResult(result)
            }
            let ids = selectedRoomIDs
            nowPlaying = ids.isEmpty ? nil : try? await sonos.nowPlaying(roomIDs: ids)
            refreshing = false
            updateIcon()
            rebuildMenu()
        }
    }

    private func applyResult(_ result: RefreshResult, playingHosts: Set<String> = []) {
        switch result {
        case .rooms(let found):
            rooms = found
            // The ticks always show which rooms really play together, even if someone regrouped in the Sonos app.
            activeIDs = nothingTicked ? [] : ActiveGroup.choose(rooms: found, previous: activeIDs, playingHosts: playingHosts)
            screen = .ready
            if message == SonosError.noSpeakers.errorDescription || message == SonosError.unreachable.errorDescription {
                message = nil
            }
        case .noSpeakers: screen = .noSpeakers; message = SonosError.noSpeakers.errorDescription
        case .localNetworkDenied: screen = .localNetworkDenied; message = SonosError.localNetworkDenied.errorDescription
        case .unreachable: screen = .unreachable; message = SonosError.unreachable.errorDescription
        }
    }

    @objc private func playPause() {
        perform { try await $0.togglePlayPause(roomIDs: $1) }
    }

    // MARK: - Ticks: which rooms play together

    @objc private func tickRoomClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        // Decide from what is really ticked, not from the box's own state (which can be a half-ticked dash).
        setRoom(id, on: !selectedRoomIDs.contains(id))
    }

    @objc private func tickAllClicked(_ sender: NSButton) {
        setAll(on: Set(selectedRoomIDs) != Set(rooms.map(\.id)))
    }

    /// Ticking joins a room to the music; unticking takes it out. Unticking the last room stops the music.
    private func setRoom(_ id: String, on: Bool) {
        let current = selectedRoomIDs
        let sonos = self.sonos
        if on {
            if current.isEmpty {
                // Nothing is playing together yet, so this room (with whatever group it is in) becomes the playing group.
                nothingTicked = false
                activeIDs = [id]
                nowPlaying = nil
                refresh()
                rebuildSoon()
                return
            }
            activeIDs.insert(id)
            runTick { try await sonos.join(roomID: id, to: current[0]) }
        } else if current.filter({ $0 != id }).isEmpty {
            let known = rooms
            nothingTicked = true
            activeIDs = []
            nowPlaying = nil
            runTick {
                await Self.rememberLead(of: current, in: known, sonos: sonos)
                try await sonos.stopAndUngroup(roomIDs: current)
            }
        } else {
            activeIDs.remove(id)
            runTick { try await sonos.leaveGroup(roomID: id) }
        }
    }

    private func setAll(on: Bool) {
        let sonos = self.sonos
        let all = rooms
        let current = selectedRoomIDs
        if !on {
            nothingTicked = true
            activeIDs = []
            nowPlaying = nil
            runTick {
                await Self.rememberLead(of: current, in: all, sonos: sonos)
                try await sonos.stopAndUngroup(roomIDs: all.map(\.id))
            }
            return
        }
        nothingTicked = false
        activeIDs = Set(all.map(\.id))
        let lastLead = self.lastLead
        runTick {
            // Music that is playing right now wins. Otherwise the room that led when everything was last
            // stopped leads again, because it still holds that song (a room ticked on its own meanwhile is just idle).
            let playing = await sonos.playingHosts()
            let playingNow = current.first { id in all.first { $0.id == id }.map { playing.contains($0.coordinatorHost) } ?? false }
            var leadID = playingNow
            var spot: TrackPosition?
            if leadID == nil, let last = lastLead, all.contains(where: { $0.id == last }) {
                leadID = last
                let d = UserDefaults.standard
                if d.object(forKey: Self.lastTrackKey) != nil { spot = TrackPosition(track: d.integer(forKey: Self.lastTrackKey), seconds: d.integer(forKey: Self.lastSecondsKey)) }
            }
            if leadID == nil { leadID = current.first ?? all.first { playing.contains($0.coordinatorHost) }?.id ?? all.first?.id }
            UserDefaults.standard.removeObject(forKey: Self.lastLeadKey) // used up
            UserDefaults.standard.removeObject(forKey: Self.lastTrackKey)
            guard let leadID else { return }
            if let spot { await sonos.restore(spot, ofRoom: leadID) } // the song is back where it was paused
            for room in all where room.id != leadID { try await sonos.join(roomID: room.id, to: leadID) }
        }
    }

    /// The room that led the music when everything was last stopped. It still holds the song, so it can lead again.
    private var lastLead: String? { UserDefaults.standard.string(forKey: Self.lastLeadKey) }
    private nonisolated static let lastLeadKey = "lastLeadRoomID"
    private nonisolated static let lastTrackKey = "lastLeadTrack"
    private nonisolated static let lastSecondsKey = "lastLeadSeconds"

    /// Remembers the leader only if music is really playing, so an idle room never overwrites the real song holder.
    private nonisolated static func rememberLead(of ids: [String], in rooms: [Room], sonos: SonosController) async {
        let playing = await sonos.playingHosts()
        guard let room = rooms.first(where: { ids.contains($0.id) && playing.contains($0.coordinatorHost) }) else { return }
        UserDefaults.standard.set(room.coordinatorID, forKey: lastLeadKey)
        if let spot = await sonos.position(ofRoom: room.id) {
            UserDefaults.standard.set(spot.track, forKey: lastTrackKey)
            UserDefaults.standard.set(spot.seconds, forKey: lastSecondsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastTrackKey)
        }
    }

    /// Runs a grouping change in the background, one at a time and in the order clicked, then re-reads the
    /// real state from the speakers. Clicks are never dropped; the menu shows each change at once.
    private func runTick(_ work: @escaping @Sendable () async throws -> Void) {
        pendingTicks += 1
        message = nil
        rebuildSoon()
        let previous = tickChain
        tickChain = Task {
            await previous?.value
            do { try await work() } catch { message = error.localizedDescription }
            try? await Task.sleep(nanoseconds: 500_000_000) // Sonos needs a moment to update its groups
            pendingTicks -= 1
            if pendingTicks == 0 {
                refresh()
                rebuildMenu()
            }
        }
    }

    /// Rebuilds on the next turn, so a click is never torn down while it is still being handled.
    private func rebuildSoon() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.rebuildMenu() }
        }
    }

    @objc private func searchAgain() {
        screen = .searching
        rebuildMenu()
        refresh()
    }

    @objc private func openLocalNetworkSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    }

    private func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Icon and menu

    /// Filled speaker = keys on, outline = keys off, triangle = a problem to look at.
    private func updateIcon() {
        let name: String
        if needsAccessibility || (message != nil && screen != .searching) {
            name = "exclamationmark.triangle.fill"
        } else {
            name = keysEnabled ? "hifispeaker.fill" : "hifispeaker"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Mac Sonos Control")
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func rebuildMenu() {
        // Never swap the menu's rows while a mouse button is down: that could swallow the click in progress.
        if NSEvent.pressedMouseButtons != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.rebuildMenu() }
            }
            return
        }
        menu.removeAllItems()

        switch screen {
        case .searching:
            addInfo("Looking for Sonos speakers…")
        case .noSpeakers:
            addInfo("No Sonos speakers found.")
            addInfo("Is this Mac on the same Wi-Fi as your speakers?")
            addAction("Search again", #selector(searchAgain))
        case .localNetworkDenied:
            addInfo("Local Network access is turned off.")
            addInfo("Without it the app can't see your speakers.")
            addAction("Open Local Network settings…", #selector(openLocalNetworkSettings))
            addAction("Search again", #selector(searchAgain))
        case .unreachable:
            addInfo("Can't reach your Sonos speakers right now.")
            addAction("Search again", #selector(searchAgain))
        case .ready:
            buildReadyItems()
        }

        menu.addItem(.separator())
        let keys = addAction("Media keys control Sonos", #selector(toggleKeys))
        keys.state = keysEnabled ? .on : .off
        let volume = addAction("Volume keys control Sonos", #selector(toggleVolumeKeys))
        volume.state = volumeKeysEnabled ? .on : .off
        if volumeKeysEnabled {
            addInfo("Mac volume is used for headphones, other speakers and calls.")
        }
        let login = addAction("Launch at login", #selector(toggleLaunchAtLogin))
        login.state = LaunchAtLogin.isOn ? .on : .off
        if keysEnabled && needsAccessibility {
            addInfo("Waiting for permission to use the media keys.")
            addInfo("Switch on Mac Sonos Control under Accessibility.")
            addAction("Open Accessibility settings…", #selector(openAccessibilitySettings))
        }

        if let text = notice ?? (screen == .ready ? message : nil) {
            menu.addItem(.separator())
            addInfo("⚠︎ " + text)
        }
        menu.addItem(.separator())
        addAction("Setup guide…", #selector(showGuide))
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func buildReadyItems() {
        let ticked = Set(selectedRoomIDs)
        let tickedRooms = rooms.filter { ticked.contains($0.id) }
        let allTicked = tickedRooms.count == rooms.count && !rooms.isEmpty

        if tickedRooms.isEmpty {
            addInfo("Playing on: nothing. Tick a speaker below.")
        } else {
            let label = allTicked && rooms.count > 1 ? "all speakers" : tickedRooms.map(\.name).joined(separator: ", ")
            addInfo("Playing on: " + label)
            if let np = nowPlaying, let title = np.title {
                addInfo("♪ " + shorten(np.artist.map { "\(title) – \($0)" } ?? title))
            }
            let isPlaying = nowPlaying?.state == .playing || nowPlaying?.state == .transitioning
            addAction(isPlaying ? "Pause" : "Play", #selector(playPause))
        }

        menu.addItem(.separator())
        addInfo("Play on these speakers")
        // "All speakers" is the master tick; the speakers sit indented underneath it.
        let hasMaster = rooms.count > 1
        if hasMaster {
            addTick("All speakers", state: tickedRooms.isEmpty ? .off : (allTicked ? .on : .mixed),
                    id: nil, action: #selector(tickAllClicked(_:)))
        }
        for room in rooms {
            addTick(room.name, state: ticked.contains(room.id) ? .on : .off,
                    id: room.id, action: #selector(tickRoomClicked(_:)), indented: hasMaster)
        }
    }

    /// A tick box row. Rows like this keep the menu open when clicked, so several rooms can be changed in one go.
    private func addTick(_ title: String, state: NSControl.StateValue, id: String?, action: Selector,
                         indented: Bool = false) {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.allowsMixedState = (id == nil) // only "All speakers" can show a dash
        button.state = state
        let baseFont = NSFont.menuFont(ofSize: 0)
        // The master tick is set in bold so it reads as the heading of the list below it.
        button.font = (id == nil) ? NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask) : baseFont
        if let id { button.identifier = NSUserInterfaceItemIdentifier(id) }
        button.sizeToFit()
        let indent: CGFloat = indented ? 20 : 0
        let width = max(button.frame.width + 40 + indent, 260)
        let height: CGFloat = 24
        button.frame = NSRect(x: 14 + indent, y: (height - button.frame.height) / 2,
                              width: width - 28 - indent, height: button.frame.height)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.addSubview(button)
        let item = NSMenuItem()
        item.view = container
        menu.addItem(item)
    }

    private func shorten(_ text: String, limit: Int = 60) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private func addInfo(_ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
