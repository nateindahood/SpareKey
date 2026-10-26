# SpareKey

*The official app only opens Windows. SpareKey lets Linux and macOS in.*

> ### 🚧 Work in progress
> SpareKey is **mostly working**, but it's still a work in progress. So far it's been tested on one
> S98 (US layout, firmware 0001) on Linux and on macOS. **Feedback is very welcome.** Bug reports,
> "it works on my keyboard" reports and pull requests all help. Please open an
> [issue](https://github.com/nateindahood/SpareKey/issues) and include the output of `sparekey -v info`
> (Linux) or `SpareKey --probe` (macOS).

Screen GIFs, playlists, lighting, key remapping and macros for the **Royal Kludge
S98** keyboard on **Linux** and **macOS**, with no Windows software. It talks to
the keyboard directly over USB HID.

| | Linux | macOS |
|---|---|---|
| App | GTK 3 (`sparekey gui`) | SwiftUI (`macos/`) |
| Keyboard access | hidraw + udev rule | IOKit (Input Monitoring permission) |
| Background playlists + clock | systemd user service | LaunchAgent |
| Status | tested on an S98 (US, fw 0001) | tested on an S98 (US, fw 0001) |

## What it does

- **Screen**: a library folder of GIFs/images with drag and drop, an exact
  preview at 320×172, and upload with progress, an ETA and cancel.
- **Playlists**: pick any GIFs from your library, put them in order, choose
  play in order or shuffle, and set how often they switch (15 min and up). The
  background service does the switching, even with the window closed.
- **Lighting**: the 18 built-in effects (plus Off) with brightness, speed and
  colour or mixed colours, and per-key colours painted on a picture of the
  keyboard.
- **Keys**: remap any key on the base, FN, FN2 and tap layers, for both
  Windows and Mac modes. You can assign media/lighting functions and macros.
- **Macros**: record from your keyboard (with optional real timing) or edit
  steps and delays.
- **Settings**: light sleep timer, Win-key lock, WASD/arrow swap, clock sync,
  backup/restore, factory reset.

Before the first change, SpareKey saves your keyboard's original settings to
`~/.config/sparekey/backups/s98-original.json`.

**Not included:** firmware updates. A failed flash can leave the keyboard
unusable, so SpareKey doesn't flash. RK's web driver (drive.rkgaming.com)
works in Chrome/Chromium once the udev rule is installed.

**Limits of the keyboard:** it holds one animation (up to 60 frames) and
receives about 13 s per frame. The keyboard sets that pace, not the app. A
playlist therefore re-sends each GIF when it switches.

## Install (Linux)

```sh
git clone https://github.com/nateindahood/SpareKey && cd SpareKey
sudo apt install python3-gi gir1.2-gtk-3.0 python3-pil   # usually already there
./install.sh            # app + CLI, udev rule (asks for sudo), background service
```

Then open **SpareKey** from the app menu. The keyboard must be connected by
cable with USB selected in the screen's settings menu (USB `258a:01af`).

```sh
sparekey info                         # what's connected and how it's set up
sparekey upload cat.gif --fit contain
sparekey light --effect breathing --brightness 3 --color ff8800
sparekey playlist create Chill a.gif b.gif --order shuffle --interval 30
sparekey playlist start Chill
sparekey backup / restore FILE / reset --yes / clock
```

`./install.sh --uninstall` removes it (it keeps your settings and library).

## macOS

See [macos/README.md](macos/README.md).

## Development

- `spec/PROTOCOL.md`: the USB protocol (both implementations follow it)
- `python3 tests/make_vectors.py`: regenerates the byte-exact test vectors from the Python code
- `python3 -m unittest discover -s tests`: Linux tests; `cd macos && swift test`: macOS tests on the same vectors

## Credits

The protocol was worked out for interoperability, from how RK's own web and Windows
drivers talk to the keyboard. `src/sparekey/data/` holds the key codes, default key
maps and key positions for the S98 found that way. SpareKey isn't affiliated with or
endorsed by Royal Kludge. "Royal Kludge" and "RK" are their trademarks, used here only
to say which keyboard SpareKey works with.

## License

MIT, see [LICENSE](LICENSE).
