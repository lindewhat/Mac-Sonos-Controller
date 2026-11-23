import AppKit
import SonosKit

/// The top of the menu: cover, title, artist, album, progress, shuffle / skip / play / repeat buttons,
/// and what plays next. Parts the speaker doesn't report (radio has no progress or shuffle) are left out.
@MainActor
final class NowPlayingView: NSView {
    struct Actions {
        var previous: () -> Void
        var playPause: () -> Void
        var next: () -> Void
        var shuffle: () -> Void
        var repeatMode: () -> Void
    }

    private static let width: CGFloat = 300
    private static let margin: CGFloat = 14

    private let now: NowPlaying?
    private let actions: Actions
    private var timer: Timer?
    private var buttons: [NSButton] = []
    private var buttonsY: CGFloat = 0
    private let progressFill = NSView()
    private let elapsedLabel = NowPlayingView.label(size: 11, color: .tertiaryLabelColor)

    private var isPlaying: Bool { now?.state == .playing || now?.state == .transitioning }
    override var isFlipped: Bool { true } // lay out from the top

    init(nowPlaying: NowPlaying?, cover: NSImage?, actions: Actions) {
        self.now = nowPlaying
        self.actions = actions
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 1))
        autoresizingMask = [.width] // the menu stretches the view to its own width, so nothing is left empty
        let height = build(cover: cover)
        setFrameSize(NSSize(width: Self.width, height: height))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    /// Adds everything and returns the total height.
    private func build(cover: NSImage?) -> CGFloat {
        let m = Self.margin
        var y: CGFloat = 8

        // Cover (or a plain tile with an icon) and the three text lines next to it.
        addSubview(coverView(cover, frame: NSRect(x: m, y: y, width: 64, height: 64)))
        let textX = m + 64 + 12
        let textWidth = Self.width - textX - m
        var lines: [(String, NSFont, NSColor)] = [(now?.title ?? "Nothing playing",
                                                   .systemFont(ofSize: 14, weight: .medium), .labelColor)]
        if now?.title != nil {
            if let artist = now?.artist { lines.append((artist, .menuFont(ofSize: 13), .secondaryLabelColor)) }
            if let detail = now?.detail { lines.append((detail, .menuFont(ofSize: 12), .secondaryLabelColor)) }
        }
        let blockHeight = lines.reduce(CGFloat(0)) { $0 + Self.lineHeight($1.1) }
        var lineY = y + (64 - blockHeight) / 2
        for (text, font, color) in lines {
            let label = Self.label(size: font.pointSize, color: color, font: font)
            label.stringValue = text
            label.frame = NSRect(x: textX, y: lineY, width: textWidth, height: Self.lineHeight(font))
            label.autoresizingMask = [.width]
            addSubview(label)
            lineY += Self.lineHeight(font)
        }
        y += 64 + 8

        // Progress: a thin bar with the time played on the left and the length on the right.
        if let duration = now?.durationSeconds {
            let track = NSView(frame: NSRect(x: m, y: y, width: Self.width - 2 * m, height: 4))
            track.wantsLayer = true
            track.layer?.cornerRadius = 2
            track.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            track.autoresizingMask = [.width]
            progressFill.wantsLayer = true
            progressFill.layer?.cornerRadius = 2
            progressFill.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
            track.addSubview(progressFill)
            addSubview(track)
            elapsedLabel.frame = NSRect(x: m, y: y + 7, width: 80, height: 14)
            addSubview(elapsedLabel)
            let total = Self.label(size: 11, color: .tertiaryLabelColor)
            total.stringValue = Self.clock(duration)
            total.alignment = .right
            total.frame = NSRect(x: Self.width - m - 80, y: y + 7, width: 80, height: 14)
            total.autoresizingMask = [.minXMargin]
            addSubview(total)
            updateProgress()
            y += 4 + 3 + 14 + 4
        }

        // Buttons. Shuffle and repeat exist only for the queue; skipping only makes sense there too.
        let hasModes = now?.hasQueue == true && now?.playMode != nil
        var buttons: [NSButton] = []
        if hasModes, let mode = now?.playMode {
            buttons.append(button("shuffle", "Shuffle", #selector(shuffleClicked), on: mode.shuffle))
        }
        buttons.append(button("backward.fill", "Previous", #selector(previousClicked), enabled: now?.hasQueue == true))
        buttons.append(button(isPlaying ? "pause.fill" : "play.fill", isPlaying ? "Pause" : "Play",
                              #selector(playPauseClicked), size: 24))
        buttons.append(button("forward.fill", "Next", #selector(nextClicked), enabled: now?.hasQueue == true))
        if hasModes, let mode = now?.playMode {
            buttons.append(button(mode.repeatMode == .one ? "repeat.1" : "repeat", "Repeat",
                                  #selector(repeatClicked), on: mode.repeatMode != .off))
        }
        self.buttons = buttons
        buttonsY = y
        for b in buttons { addSubview(b) }
        layoutButtons()
        y += 30 + 2

        // What comes next. With shuffle or repeat-one the speaker doesn't say, so a short hint stands in.
        if let mode = now?.playMode, now?.hasQueue == true {
            var rows: [(String, NSColor)] = now?.upNext.enumerated().map { i, item in
                ("\(i + 1)   " + (item.artist.map { "\(item.title) – \($0)" } ?? item.title), NSColor.labelColor)
            } ?? []
            if mode.shuffle { rows = [("Shuffle is on, so the next song is a surprise.", .secondaryLabelColor)] }
            else if mode.repeatMode == .one { rows = [("Repeating this song.", .secondaryLabelColor)] }
            if !rows.isEmpty {
                let line = NSBox(frame: NSRect(x: m, y: y + 4, width: Self.width - 2 * m, height: 1))
                line.boxType = .separator
                line.autoresizingMask = [.width]
                addSubview(line)
                y += 10
                let heading = Self.label(size: 12, color: .secondaryLabelColor)
                heading.stringValue = "Up next"
                heading.frame = NSRect(x: m, y: y, width: Self.width - 2 * m, height: 16)
                heading.autoresizingMask = [.width]
                addSubview(heading)
                y += 18
                for (text, color) in rows {
                    let row = Self.label(size: 13, color: color)
                    row.stringValue = text
                    row.frame = NSRect(x: m, y: y, width: Self.width - 2 * m, height: 17)
                    row.autoresizingMask = [.width]
                    addSubview(row)
                    y += 18
                }
            }
        }
        return y + 6
    }

    /// The buttons stay centred however wide the menu is.
    private func layoutButtons() {
        let spacing: CGFloat = 52
        let first = bounds.width / 2 - spacing * CGFloat(buttons.count - 1) / 2
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: first + spacing * CGFloat(i) - 20, y: buttonsY, width: 40, height: 30)
        }
    }

    /// The menu stretches the view to its own width after it is built. The bar's filled part is not stretched
    /// by autoresizing (it is a share of the track), so it is recalculated here, or it would stay too short
    /// until the next tick.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutButtons()
        updateProgress()
    }

    private func coverView(_ cover: NSImage?, frame: NSRect) -> NSView {
        let tile = NSView(frame: frame)
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 8
        tile.layer?.masksToBounds = true
        if let cover {
            let image = NSImageView(frame: tile.bounds)
            image.image = cover
            image.imageScaling = .scaleAxesIndependently
            tile.addSubview(image)
        } else {
            tile.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            let symbol = now?.hasQueue == false && now?.title != nil ? "radio" : "music.note"
            let icon = NSImageView(frame: tile.bounds)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
            icon.contentTintColor = .tertiaryLabelColor
            tile.addSubview(icon)
        }
        return tile
    }

    private func button(_ symbol: String, _ label: String, _ action: Selector, on: Bool = false,
                        enabled: Bool = true, size: CGFloat = 17) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        let b = NSButton(image: image ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = on ? .controlAccentColor : (enabled ? .labelColor : .quaternaryLabelColor)
        b.isEnabled = enabled
        b.setAccessibilityLabel(label)
        b.toolTip = label
        return b
    }

    private static func label(size: CGFloat, color: NSColor, font: NSFont? = nil) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = font ?? .menuFont(ofSize: size)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.pointSize * 1.3) }

    // MARK: - Progress

    private func elapsedNow() -> Double {
        guard let now, let base = now.elapsedSeconds, let duration = now.durationSeconds else { return 0 }
        let passed = isPlaying ? Date().timeIntervalSince(now.observedAt) : 0
        return min(Double(duration), Double(base) + max(0, passed))
    }

    private func updateProgress() {
        guard let duration = now?.durationSeconds, duration > 0, let track = progressFill.superview else { return }
        progressFill.frame = NSRect(x: 0, y: 0, width: track.bounds.width * CGFloat(elapsedNow() / Double(duration)),
                                    height: track.bounds.height)
        elapsedLabel.stringValue = Self.clock(Int(elapsedNow()))
    }

    /// While the menu is open the bar moves on its own: the speaker was asked once, the Mac counts the seconds.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil, isPlaying, now?.durationSeconds != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.updateProgress() }
        }
        RunLoop.main.add(t, forMode: .common) // menus run in their own tracking mode
        timer = t
    }

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Clicks

    @objc private func previousClicked() { actions.previous() }
    @objc private func playPauseClicked() { actions.playPause() }
    @objc private func nextClicked() { actions.next() }
    @objc private func shuffleClicked() { actions.shuffle() }
    @objc private func repeatClicked() { actions.repeatMode() }
}
