# Mac Sonos Control

Control your Sonos speakers with the Mac's media keys, from the menu bar: F8 play/pause, F9 next, F7 previous, and optionally F10–F12 for mute and volume.

- Talks straight to your Sonos speakers on your home network. No Sonos Mac app, no Sonos account, nothing goes to the internet.
- The media keys are taken over while the app is on, so Apple Music does not open. Switch the app off or quit it and the keys work as normal again.
- Changes made in the Sonos app on your phone (grouping, what is playing) show up in the menu.

## Easiest way: let Claude install it

Open [Claude Code](https://claude.com/claude-code) (or the Code tab in the Claude desktop app) and say:

> Help me install https://github.com/lindewhat/Mac-Sonos-Controller

Claude checks your Mac, does the technical steps itself and tells you, one at a time, the few things only you can do (such as clicking **Allow**). If you would rather do it yourself, follow **Install** below.

## Requirements

- **A Mac with Apple Silicon** (M1 or newer) running **macOS 14 or newer**. The app is built for macOS 14 and up; so far it has been tried on the latest macOS only.
- **Sonos speakers** on the same home network as your Mac (same Wi-Fi or cable network, not a separate guest network). No Sonos account is needed.
- **Xcode**, free from the App Store. It is large, so leave plenty of free disk space.
- **An Apple ID** (optional, free), used only to create the signing certificate in step 2 below.
- **A keyboard with media keys.** Apple keyboards work; with other keyboards the keys may differ.
- **An internet connection** for downloading Xcode and this project. Using the app afterwards only needs your home network.

## Install

There is no ready-made download yet: you build the app on your own Mac, which takes a few minutes and one command.

### 1. Get Xcode (once)

1. Open the **App Store**, search for **Xcode** and install it (it is free and large, so this takes a while).
2. Open Xcode once and agree to the licence if it asks. You can then close it.

### 2. Get a free signing certificate (optional, recommended if you will update the app)

macOS remembers the app's permissions only if the app is signed with a stable certificate. Without this step the app still works, but you have to grant the Accessibility permission again after every rebuild or update. If you only install once, you can skip this.

1. Open Xcode, then choose **Xcode → Settings → Accounts**.
2. Click **+**, choose **Apple ID** and sign in with your normal Apple ID. No payment is needed.
3. Select your account, click **Manage Certificates…**, click **+** and choose **Apple Development**.

### 3. Download this project

On this page, click the green **Code** button, then **Download ZIP**, and double-click the ZIP in your Downloads folder to unpack it.

### 4. Build and install the app

1. Open **Terminal** (press ⌘ Space, type "Terminal", press Return). It is a window where you type commands.
2. Type `cd ` (with a space after it), drag the unpacked folder from Finder into the Terminal window, and press Return. This tells Terminal which folder to work in.
3. Type the line below and press Return:

```
./build.sh
```

This tests the app, builds it, puts it in your **Applications** folder and opens it. It takes a few minutes the first time. Use `./build.sh --no-run` if you do not want it to open straight away.

### 5. Allow what the app needs

A setup guide opens the first time. macOS asks for two permissions:

- **Local Network**: so the app can find your speakers. Click **Allow**.
- **Accessibility**: so the app can catch the media keys. In System Settings, choose **Override System Protections** (not "Choose Apps"), otherwise the keys will not work everywhere. The guide shows a tick when this is done.

## Use

- Click the speaker icon in the menu bar. It is filled when the keys control Sonos and an outline when they do not.
- **Play on these speakers**: tick the speakers that should play together, or **All speakers**. Ticking a speaker adds it to the music, unticking removes it, and unticking the last one pauses everything.
- **Media keys control Sonos** switches the keys on and off. **Volume keys control Sonos** is off by default; when on, the Mac keeps the keys while headphones, Bluetooth or other outputs are used, or during calls.
- **Launch at login** starts the app when you log in.
- Hold **Option** while pressing a media key to send that press to the Mac as usual.
- With "Use F1, F2, etc. as standard function keys" turned on, press **Fn** with the key (for example Fn+F8).

**If something goes wrong:** the app keeps a short text log on your Mac at `~/Library/Logs/MacSonosControl/MacSonosControl.log` (open it from Finder with Go > Go to Folder). It lists what failed and why, and never leaves your Mac. If you ask Claude for help, tell it where the log is.

## Update

When a new version is published here, it is not sent to your Mac automatically: your installed app stays as it is until you update it. To update:

1. Say to Claude: **"Update Mac Sonos Control"**. It fetches the latest version and rebuilds the app for you.
2. Or do it yourself: open **Terminal**, type `cd ` (with a space), drag the project folder in and press Return, then run these two lines, one after the other:

```
git pull
./build.sh
```

This works if you installed with Claude, which downloads the project with `git`. If you installed from a downloaded ZIP, download the new ZIP from this page and run `./build.sh` in it again.

If the app was signed ad hoc (no Apple Development certificate), macOS asks for the Accessibility permission again after an update.

## For Claude: installing this for someone

If a person asks you to help install this app, follow this. They may not be technical. Do every step you can yourself, explain in plain words, and give them **one** human step at a time. Never ask for their password; if a command needs `sudo`, show it and let them run it.

1. **Check the Mac.** `uname -m` must print `arm64` and `sw_vers -productVersion` must be 14 or newer. If not, stop and tell them plainly why this app cannot run on their Mac.
2. **Check Xcode.** Run `xcodebuild -version`. If it fails, ask them to install Xcode from the App Store (`open "macappstore://apps.apple.com/app/xcode/id497799835"` opens the page), open it once and accept the licence, then re-check. Wait until it passes.
3. **Get the code.** `git clone https://github.com/lindewhat/Mac-Sonos-Controller ~/Mac-Sonos-Controller` and `cd` into it. Read `CLAUDE.md` there for the design.
4. **Build and install.** Run `./build.sh` (a few minutes; run it in the background and say so). It checks the Mac itself and prints a plain message if something is missing. If it says it signed ad hoc, tell the person the app works but macOS will ask for the Accessibility permission again after an update; offer the optional free certificate (README, Install step 2) only if they plan to update.
5. **Permissions, one at a time.** The app opens a setup guide. Tell them to click **Allow** on the Local Network question, then in System Settings → Privacy & Security → Accessibility to choose **Override System Protections** (not "Choose Apps"). The guide shows a tick when each is done.
6. **Test with them.** Ask them to play something on a Sonos speaker, then press **F8** (**Fn+F8** if "Use F1, F2, etc. as standard function keys" is on). It should pause and play, and Apple Music must not open. Show them the menu bar speaker icon and the **Play on these speakers** ticks.

**To update an existing install** (the person says "update Mac Sonos Control"): `cd ~/Mac-Sonos-Controller` (or wherever it was cloned), run `git pull`, then `./build.sh`, and tell them it takes a few minutes. If `git pull` reports local changes, do not discard them; explain and ask. If they installed from a ZIP, there is no git history, so download the new ZIP and build from it.

If something fails:

| What they see | Cause and fix |
|---|---|
| Menu says it is looking for speakers, or finds none | Local Network permission is off (System Settings → Privacy & Security → Local Network, switch the app on), or the Mac is not on the speakers' network (not a guest network) |
| Keys do nothing, menu warns about permission | Accessibility is not granted, or "Choose Apps" was used instead of "Override System Protections" |
| Apple Music opens when a key is pressed | The app is off or quit, or Accessibility is missing |
| Permission asked again after an update | Ad hoc signing; see step 4 |

## For developers

- `swift test` runs the tests only.
- `Sources/SonosKit` talks to Sonos, `Sources/KeyKit` handles keys, `Sources/MacSonosControl` is the app. See `CLAUDE.md` for the design decisions.

## Licence

MIT: you are free to use, copy, change and share this software, as long as the licence text stays with it. See `LICENSE`.
