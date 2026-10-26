# SpareKey for macOS

Native SwiftUI version of SpareKey: the same features as the Linux app (screen
library and upload, lighting, per-key colours, key
remapping, macros, clock, backup/restore, factory reset), talking to the
keyboard through IOKit. It needs no Python.

> **Status:** working on a real S98 (connecting, lighting, colours, brightness,
> both key layouts). The protocol code is also checked against the Linux
> version's test vectors (`swift test`).

## Install

1. Download `SpareKey-<version>.dmg` from the [releases page](https://github.com/nateindahood/SpareKey/releases),
   open it, and drag **SpareKey** onto **Applications**.
2. The first time, macOS says it can't verify SpareKey: it isn't signed with a paid Apple Developer
   ID. On macOS 15 or later, open **System Settings → Privacy & Security** and click **Open Anyway**
   next to SpareKey. On older versions, right-click SpareKey in Applications and choose **Open**.
   You only do this once.
3. Allow SpareKey under **Input Monitoring** when macOS asks (see Permissions below).

## Build

Requires macOS 13+ and the Xcode command line tools (`xcode-select --install`).

```sh
cd macos
swift test                    # protocol tests against ../spec/vectors (no keyboard needed)
./build-app.sh                # -> build/SpareKey.app (ad-hoc signed)
open build/SpareKey.app
```

`./build-app.sh --install` also copies the app to /Applications, and `bash make-dmg.sh` makes
`build/SpareKey-<version>.dmg` for a release.

## Permissions

The S98's configuration interface is part of the keyboard, so macOS may ask for
**Input Monitoring** the first time SpareKey opens it. Allow SpareKey in
System Settings → Privacy & Security → Input Monitoring, then quit and reopen
the app. SpareKey only uses the vendor configuration reports; it doesn't read
your typing.

**After rebuilding,** macOS may block the keyboard again even though the
Input Monitoring switch is still on. `build-app.sh` signs the app ad hoc, so every
build looks like a new app to macOS. Reset the grant, then reopen SpareKey and allow
it again:

```sh
tccutil reset ListenEvent io.github.nateindahood.sparekey
```

Signing with a stable self-signed certificate (Keychain Access → Certificate
Assistant → Create a Certificate, type "Code Signing", then `codesign -s "<name>"`
in `build-app.sh`) avoids this.

## Troubleshooting

- **Keyboard not found:** choose USB in the keyboard screen's settings
  menu. In 2.4G/Bluetooth mode it isn't a USB device at all. The first time, macOS asks
  to allow the accessory.
- `SpareKey --probe` (read-only) lists the HID interfaces and what each read
  returns. `SpareKey --backup` and `SpareKey --restore-profile` save the
  original settings, and put the profile back from that backup.

## Background service

Turning on "Keep it in sync" (Settings → Clock) installs a LaunchAgent,
`~/Library/LaunchAgents/io.github.nateindahood.sparekey.service.plist`. It runs
`SpareKey --service` at login to keep the keyboard clock right. Its log is in
`~/Library/Application Support/SpareKey/service.log`.
If you move the app, turn the background service off and on again.

## First-run checklist

Plug in the cable, choose USB in the keyboard screen's settings menu, then:

1. `swift test`: all tests pass.
2. `build/SpareKey.app/Contents/MacOS/SpareKey --info -v`: prints `RK S98, firmware 0001` and the
   lighting, and the `IN` lines show acks. If it fails with an Input Monitoring message, grant it and retry.
3. `… SpareKey --clock`: the keyboard clock jumps to the Mac's time.
4. Open the app: the footer shows "RK S98 · firmware 0001".
5. **Lighting**: change the brightness slider. The keyboard dims within half a second.
6. **Screen**: send a small GIF (a few frames). The progress bar moves at about 13 s per frame, and the GIF plays on the keyboard.
7. **Keys**: remap a spare key on the FN2 layer, then "Reset this layer".

Report anything that fails (with the error text) as an issue.

Data files in `Sources/SpareKeyKit/Data` are copies of `src/sparekey/data`;
`build-app.sh` refreshes them.
