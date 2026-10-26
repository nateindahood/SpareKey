# SpareKey for macOS

Native SwiftUI version of SpareKey: the same features as the Linux app (screen
library and upload, lighting, per-key colors, key
remapping, macros, clock, backup/restore, factory reset), talking to the
keyboard through IOKit. It needs no Python.

> **Status:** working on a real S98 (connecting, lighting, colors, brightness,
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

> **Updating from 0.5.2 or older, or going back to one of those versions?** Allow Input Monitoring
> again this one time. Those versions were signed differently, so macOS treats them as another app.
> The switch in Settings may still look on, but it belongs to the version you had before. Remove
> SpareKey from the Input Monitoring list with the − button, then open SpareKey and allow it when
> asked. From 0.5.3 on, releases are signed with the same certificate, and the permission carries over
> when you update. See [How releases are signed](#how-releases-are-signed).

## Build

Requires macOS 13+ and the Xcode command line tools (`xcode-select --install`).

```sh
cd macos
swift test                    # protocol tests against ../spec/vectors (no keyboard needed)
./build-app.sh                # -> build/SpareKey.app (signed ad hoc)
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

**When the permission doesn't carry over,** macOS blocks the keyboard even though the
Input Monitoring switch is still on. This happens when you move between a release from
0.5.3 on and 0.5.2 or older, or install a copy you built yourself, because macOS ties the
permission to how the app is signed. The switch then belongs to the copy you had
before, and SpareKey says so. Select SpareKey in the Input Monitoring list, remove it with the −
button, then reopen SpareKey and allow it when asked. Or reset the grant from a
terminal:

```sh
tccutil reset ListenEvent io.github.nateindahood.sparekey
```

If you build SpareKey yourself and rebuild often, sign with your own self-signed
certificate to keep the permission across your builds: Keychain Access → Certificate
Assistant → Create a Certificate, type "Code Signing", then
`SIGN_IDENTITY="<name>" ./build-app.sh`.

## How releases are signed

From 0.5.3 on, the `SpareKey.app` in each release is signed with a **self-signed certificate
named "SpareKey"**. Every release uses the same certificate, so macOS knows a new version is
the same app and keeps your Input Monitoring permission.

- **It isn't an Apple Developer ID.** Apple hasn't checked it, and it says nothing about who made
  the app. It only shows that every release came from the same signer. macOS still asks you to
  click **Open Anyway** the first time.
- **Everything about it is public except the private key.** The certificate's public half is
  [`SpareKey-signing.pem`](SpareKey-signing.pem), and
  [the release workflow](../.github/workflows/release.yml) shows how each DMG is built and signed
  on GitHub's Macs, with the logs on the repo's Actions page. The private key is stored only as an
  encrypted GitHub secret (plus an offline backup), so nobody else can sign as SpareKey. The
  workflow refuses to sign if the secret doesn't match the published certificate.
- **Builds from source or forks** are signed ad hoc (or with your own certificate) and work the
  same way, but macOS treats them as a different app.

Its SHA-256 fingerprint is:

```
25:94:FD:18:89:4C:A5:D5:D2:2A:64:4E:65:2B:42:FB:4C:35:2F:36:B3:F3:E4:FF:1A:E9:36:2E:BD:A1:DA:49
```

To check an installed copy:

```sh
codesign -dvv /Applications/SpareKey.app 2>&1 | grep Authority          # Authority=SpareKey
cd "$(mktemp -d)" && codesign -d --extract-certificates /Applications/SpareKey.app \
  && openssl x509 -inform DER -in codesign0 -noout -fingerprint -sha256    # matches the line above
```

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
