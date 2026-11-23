import AppKit
import SwiftUI

/// What the setup guide needs to know right now.
struct GuideStatus {
    enum Speakers { case searching, found(Int), denied, none }
    var speakers: Speakers
    var accessibilityGranted: Bool
    var fKeysAreStandard: Bool   // "Use F1, F2, etc. keys as standard function keys" is on
}

/// The first-launch guide: a short checklist that updates by itself as permissions are granted.
@MainActor
final class GuideWindow {
    private var window: NSWindow?
    private let status: () -> GuideStatus
    private let openLocalNetwork: () -> Void
    private let openAccessibility: () -> Void

    init(status: @escaping () -> GuideStatus, openLocalNetwork: @escaping () -> Void,
         openAccessibility: @escaping () -> Void) {
        self.status = status
        self.openLocalNetwork = openLocalNetwork
        self.openAccessibility = openAccessibility
    }

    func show() {
        if window == nil {
            let view = GuideView(status: status, openLocalNetwork: openLocalNetwork,
                                 openAccessibility: openAccessibility, close: { [weak self] in self?.window?.close() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Mac Sonos Control"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct GuideView: View {
    let status: () -> GuideStatus
    let openLocalNetwork: () -> Void
    let openAccessibility: () -> Void
    let close: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content(status())
        }
    }

    private func content(_ s: GuideStatus) -> some View {
        let speakersOK: Bool = { if case .found = s.speakers { return true } else { return false } }()
        return VStack(alignment: .leading, spacing: 18) {
            Text(speakersOK && s.accessibilityGranted ? "You're all set" : "Let's get you set up")
                .font(.title2.bold())

            step(done: speakersOK, title: "1. Find your Sonos speakers") {
                switch s.speakers {
                case .searching:
                    Text("Looking… macOS will ask whether this app may find devices on your network. Click Allow.")
                case .found(let n):
                    Text("Found \(n) speaker\(n == 1 ? "" : "s").")
                case .denied:
                    Text("Local Network access is turned off, so the app can't see your speakers.")
                    Button("Open Local Network settings…", action: openLocalNetwork)
                case .none:
                    Text("No speakers found. Is this Mac on the same Wi-Fi as your Sonos speakers?")
                }
            }

            step(done: s.accessibilityGranted, title: "2. Let the app use your media keys") {
                if s.accessibilityGranted {
                    Text("Allowed.")
                } else {
                    Text("Open the Accessibility settings and switch on Mac Sonos Control. If macOS asks you to choose apps or to override system protections, choose Override System Protections: the app needs that to catch the keys before other apps do.")
                    Button("Open Accessibility settings…", action: openAccessibility)
                }
            }

            step(done: nil, title: "3. Using the keys") {
                Text("F8 plays or pauses, F9 skips to the next song, F7 goes back. Hold Option while pressing a key to send it to your Mac instead. Turn the keys off any time from the menu bar icon.")
                if s.fKeysAreStandard {
                    Text("Your Mac is set to use F1, F2, etc. as standard function keys, so hold the fn key while you press F7, F8 or F9.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func step<C: View>(done: Bool?, title: String, @ViewBuilder _ body: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done == true ? "checkmark.circle.fill" : (done == false ? "circle.dotted" : "info.circle"))
                .foregroundStyle(done == true ? Color.green : Color.secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                body().fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
