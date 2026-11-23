# Mac Sonos Control

## What this app does
A macOS menu bar app (no Dock icon) that lets the keyboard's media keys control Sonos speakers directly over the local network.
- F8 play/pause, F9 next, F7 previous on the chosen Sonos room/group (later: F10-F12 volume, optional).
- Menu shows the controlled room (switchable), what's playing, play/pause, an on/off switch for "media keys control Sonos", "launch at login", Quit.
- Talks to Sonos speakers directly (UPnP/SOAP over HTTP, port 1400, speakers found via Bonjour `_sonos._tcp`). No Sonos Mac app, no Sonos account, no cloud.
- Grouped rooms: commands go to the group coordinator.
- Unreachable speakers: clear message in the menu. Never crash.

## Build and install (one command)
`./build.sh` runs tests, builds, signs, installs to /Applications and launches. `./build.sh --no-run` skips launching.
Tests only: `swift test`.

## Layout
- `Sources/SonosKit`: all Sonos logic (discovery, SOAP, groups, now-playing). Unit-testable, no UI.
- `Sources/KeyKit`: key handling only (decodes media-key events, routes key -> action). Knows nothing about Sonos.
- `Sources/MacSonosControl`: the app (menu bar, event tap, setup guide, launch at login, Mac-audio check). `AppController.start()` is where keys are wired to actions.
- Keys vs actions are separate: the key listener only emits key values; a small router maps key -> action. Adding a new action must not require touching key-handling code. No plugin system or settings framework.
- Bundle id: `com.lindewhat.mac-sonos-control`. Info.plist in `Resources/`.
- App icon: `Resources/AppIcon.icns`, drawn by `swift scripts/make-icon.swift` (rerun only to change the design; build.sh copies the .icns into the app).

## Key decisions (and why)
- Swift Package + build.sh, no hand-made Xcode project: small, scriptable, no third-party dependencies.
- AppKit `NSStatusItem`/`NSMenu` for the menu bar: simple, reliable dynamic menus.
- Media keys are caught with an event tap and swallowed so Apple Music never launches. Needs Accessibility (maybe Input Monitoring: verify on a real Mac).
- Plain F-keys ("Use F1, F2 as standard function keys" on): only the media-key events are taken by default; never grab plain F7-F9 without the user's explicit OK.
- Stuck-key safety: tap callback does no slow work; re-enable if macOS disables it; crash/quit removes the tap so keys return to normal; switch-off/Quit remove the tap explicitly.
- Signing: macOS ties the Accessibility grant to the app signature. build.sh signs with a stable identity (Apple Development, Developer ID, or local "Mac Sonos Control Local" cert) so permissions survive rebuilds. Ad-hoc signing loses the grant each rebuild.
- Volume keys (F10-F12) are opt-in (default off). When on, Sonos group volume/mute is used unless the Mac's output is not the built-in speakers (headphones, Bluetooth, HDMI, AirPlay, USB) or the microphone is in use (calls): then the Mac keeps the keys (`MacAudio.swift`).
- Menu "Play on these speakers": one tick box per speaker (plus "All speakers"); ticked rooms play the same music together. Ticking joins a room to the playing group (SetAVTransportURI x-rincon:<lead id>), unticking takes it out (BecomeCoordinatorOfStandaloneGroup), unticking the last room pauses and splits everything so nothing plays. Keys and volume act on the ticked rooms. The ticks always reflect the real groups (`ActiveGroup.choose` after every refresh), so changes made in the Sonos app show up too. Rows are custom checkbox views so the menu stays open while ticking. Volume changes each speaker by the same step (Sonos group volume scales proportionally, which left quiet speakers unchanged).
- Menu top block (`NowPlayingView`): cover (`ArtLoader`), title, artist, album (or radio station), progress bar, shuffle / previous / play-pause / next / repeat, and "Up next" (next two songs from the queue). The buttons call the same controller functions as the keys. The speaker is asked once when the menu opens; the Mac counts the seconds while it stays open. Parts a source doesn't have are left out (radio: no progress, shuffle, repeat or up next; previous/next greyed out).
- Cover art is only fetched from the speaker itself (`/getaa...` path on port 1400). A full web address in the metadata is ignored, so the app never contacts the internet.
- "Up next" reads the queue in order, so it is only shown when that order is real: with shuffle on Sonos picks the next song itself and does not say, so the menu shows a hint instead; with repeat-one it shows "Repeating this song". Sonos does not tell which playlist the queue came from, so there is no playlist name.
- Room order (`RoomOrder`): natural numbers/letters, and rooms that differ only by a position word follow the position (up→middle→down, left→middle→right, front→back, first→second, one→two; English and Danish), so "Kitchen, up" comes before "Kitchen, down". Same rules as the Hue app's light order.
- Holding Option while pressing a media key sends it to the Mac as usual (escape hatch). The app removes Option from the event before passing it on: macOS ignores play/next/previous with Option attached, and Option+volume would open Sound settings instead of changing the volume. The whole press goes to the Mac even if Option is released early. (When the app does not claim a key, e.g. volume keys switched off, Option is untouched and macOS behaves as normal.)
- Apple keyboards send F7/F9 as "rewind"/"fast" codes (20/19), others as previous/next (18/17): both handled.
- macOS 27 shows "Choose Apps / Override System Protections" for Accessibility. Choose Apps is not enough for system-wide keys; the guide tells users to pick Override.
- build.sh stamps the program with the real macOS SDK version (`vtool`, after building, before signing). SwiftPM stamps SDK 14.0, and macOS then gives the app the old look: a nearly solid menu that ignores "Reduce transparency". With the real SDK the menu looks like every current menu. The minimum macOS stays 14.
- build.sh assembles the app in $TMPDIR (not the Desktop folder): iCloud/Finder markings there break code signing. It verifies the signature after installing.
- Privacy: only LAN traffic to Sonos. No analytics, no cloud calls, no logging of personal data (room names, IPs, track titles).
- Sharing later (not done): paid Apple Developer Program, Developer ID signing, Hardened Runtime, notarization.

## If someone asks you to install this app
Follow the "For Claude: installing this for someone" section of `README.md`. It is the single source of truth; keep it in step with `build.sh` when either changes.

## Must work on any Mac (no manual setup beyond granting permissions)
- When on, the app takes the media keys so they control Sonos and do NOT launch/control Apple Music or anything else. When off or quit, keys return to normal.
- Works whether or not "Use F1, F2, etc. as standard function keys" is on; explain behaviour in plain language.
- Nothing tied to one machine: no hardcoded room names, IPs or paths. Speakers found automatically.
- First launch guides through permissions in plain language, detects when granted, never fails silently.
