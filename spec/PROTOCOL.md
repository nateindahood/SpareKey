# RK S98 USB protocol

Both SpareKey implementations (Linux/Python in `src/sparekey/protocol.py`,
macOS/Swift in `macos/Sources/SpareKeyKit/Protocol.swift`) follow this document
and are tested against the byte-exact examples in `vectors/`. Regenerate those
with `python3 tests/make_vectors.py` after changing the Python side, then run
both test suites.

Worked out from RK's WebHID driver (drive.rkgaming.com, the S98 class) and the
Windows app's `DeviceDriver.exe`; every command below was checked on an S98 (US,
firmware `0001`).

## Device

| | |
|---|---|
| USB ID | `258a:01af` (wired). The 2.4 GHz dongle is `258a:0150` and isn't supported yet. |
| Interface | the HID interface whose report descriptor has report ID 9 (interface 1, vendor usage page `0xFF00`) |
| Commands | **feature report 9**, 519 data bytes (520 with the report ID) |
| Acks | **input report 9**, 7 data bytes: `0a 06 <status> ...` |

Linux: `HIDIOCSFEATURE`/`HIDIOCGFEATURE` on `/dev/hidrawN`, reads for acks.
macOS: `IOHIDDeviceSetReport`/`GetReport` (`kIOHIDReportTypeFeature`, ID 9) and an
input-report callback.

## Packet layout

```
byte 0  cmd
byte 1  arg1     (key matrix: table << 2 | layer)
byte 2  arg2     (profile number, 0)
byte 3  package count (1 unless chunked)
byte 4  package index
byte 5  length low
byte 6  length high
byte 7… payload (zero padded to 519)
```

**Get** commands (`cmd >= 0x80`): send the packet with the expected length
and no payload, then read feature report 9. The answer echoes the 7-byte header,
followed by the data.

**Answers out of turn:** about 1 in 5 reads, the answer is a status packet
(`0a 06 00 01 …`) instead of the data, more often right after another command.
The keyboard can also answer with **just the 7-byte header** and no data (no
data ready), or with nothing at all. Accept an answer only if it echoes the whole
7-byte header *and* carries data (at least `min(length, 128)` bytes), and
otherwise ask again. An unchecked bad read looks like an all-zero block, and
writing that back blanks the settings (this happened once on macOS: a header-only
profile read was written back with a brightness change, turning the lighting off).

Answer lengths: macOS (IOKit) reports the real length the keyboard sent; Linux
`HIDIOCGFEATURE` pads the buffer, but the ioctl's return value is the real length
(report ID included). Seen with firmware 0001: info 17 data bytes, profile 135,
effect colors 171 (all zero), key matrix 255.

**Read limit:** with firmware 0001, only about the first 248 data bytes of
an answer are real (the answer is cut off there). Key matrices therefore show keys 0–61
only. Writers must merge with the vendor defaults (`src/sparekey/data/keymap.json`)
instead of writing back what they read. They must also build from the layout
*before* the first change (SpareKey keeps it in `s98-original.json`), not from a
fresh read: once a key is remapped, the keyboard reports the remap, and
"default" would just write it back. A read layer can be random memory instead of key codes (seen on the Mac
table). Tell the two apart by the **type byte** of every action (`action >> 24`), not by looking codes
up in the vendor's list: real layers contain actions the list doesn't have (the S98's FN+1 is
`0x08091300`).

**Unreadable blocks (firmware 0001):** per-key colors (0x86) and macros (0x85)
answer with a bare header every time, so treat them as unknown, not as empty.
Effect colors (0x8a) read back as zeros. The Mac table (table 1) reads as all
zeros (base layer) or random memory (FN layers) even though Mac mode types
normally: a key layer that reads as all zeros where the vendor default isn't
empty is a failed read, and backups keep a layer only if two reads agree.

**Set** commands are acknowledged with `0a 06 00 02`; screen chunks and the
clock with `0a 06 01 01`. Wait for the ack before sending the next packet.

## Commands

| cmd | name | args | payload |
|---|---|---|---|
| 0x82 (130) | get info | arg1 = 1, len 10 | answer data[15..16] = firmware version bytes |
| 0x84 (132) | get profile | arg2 = profile | 128 bytes |
| 0x04 | set profile | arg2 = profile | 128 bytes |
| 0x8a (138) | get effect colors | arg2 = profile | 420 bytes |
| 0x0a (10) | set effect colors | arg2 = profile | 420 bytes |
| 0x86 (134) | get per-key colors | arg2 = profile | 378 bytes |
| 0x06 | set per-key colors | arg2 = profile | 378 bytes |
| 0x83 (131) | get key matrix | arg1 = table << 2 \| layer | 504 bytes |
| 0x03 | set key matrix | arg1 = table << 2 \| layer | 504 bytes |
| 0x85 (133) | get macros | index = chunk 0–7 | 512 bytes |
| 0x05 | set macros | count/index = chunks | ≤512 bytes per chunk |
| 0x0b (11) | set clock / system info | – | 14 bytes |
| 0x0c (12) | screen frame chunk | see below | ≤512 bytes |
| 0x0d (13) | screen start/finish/abort | – | 5 bytes |
| 0x11 (17) | factory reset | – | 1 byte (0) |

### Profile (128 bytes)

| offset | meaning |
|---|---|
| 3 | debounce |
| 5 | LED parameter type (0 = per-effect parameters below) |
| 6, 7, 8 | global brightness, speed, color (used when byte 5 ≠ 0) |
| 9 | 1 when effect = Custom |
| 10 | effect (see list) |
| 15 | Windows-key lock |
| 17 | WASD ↔ arrows swap |
| 22 | tap delay |
| 24 | sleep timeout, in 30 s steps (0 = never) |
| 56 + 2·effect | brightness: 0, 4, 8, 12, 16, 20 (levels 0–5) |
| 57 + 2·effect | `speed << 4 \| color`; speed 0–4; color 7 = mixed colors, 0 = use the effect color |
| 126, 127 | `5a a5` |

Effects: 0 off, 1 static, 2 breathing, 3 rainbow, 4 flash away, 5 raindrops,
6 rainbow wheel, 7 ripple shining, 8 stars twinkle, 9 shadow disappear,
10 retro snake, 11 neon stream, 12 reaction, 13 sine wave, 14 side scan,
15 rotating windmill, 16 colorful waterfall, 17 blossoming, 18 custom (per key).

### Effect colors (420 bytes)

20 effects × 21 bytes (7 RGB triples). The first triple is the color used
when "mixed colors" is off. Change only the selected effect's first triple
and write back the rest as read.

### Per-key colors (378 bytes)

Planar layout: 126 red bytes, then 126 green, then 126 blue, indexed by key
matrix position.

### Key matrix (504 bytes)

126 big-endian u32 key actions, indexed by matrix position (6 rows × 21
columns, column-major: 0 Esc, 1 \`, 2 Tab, 3 Caps, 4 LShift, 5 LCtrl, 7 1, …).
Positions and on-screen rectangles: `src/sparekey/data/layout_s98.json`.

`action = type << 24 | param << 16 | code`

* type 0: HID usage in `code`, modifier mask in `param` (1 Ctrl, 2 Shift, 4 Alt, 8 GUI; ×16 for the right-hand keys)
* type 3: macro number in `code`
* other types: media, lighting and keyboard functions (named in `keymap.json`)

Tables: 0 Windows, 1 Mac. Layers: 0 base, 1 FN, 2 FN2, 3 tap.

### Macros (≤ 4096 bytes, written in 512-byte chunks)

```
offset table: per macro u16le offset, u16le length (offsets from the blob start)
macro:        u8 name_bytes, UTF-16LE name, steps…
step (4 B):   b0 = up << 7 | type << 4 | delay >> 16
              b1 = delay >> 8, b2 = delay, b3 = key
              type 0 key (HID usage), 1 modifier (HID 0xE0–0xE7), 2 mouse (1 L, 2 R, 4 M, 8, 16)
```

### Clock (cmd 0x0b, 14 bytes)

`[volume, cpu%, mem%, year_lo, year_hi, month, day, hour, minute, second, weekday (0 = Sunday), 0, 0, 0]`

The Windows app sends this once a second, with `SysParamMask = 5` for the S98.

### Screen

320 × 172 pixels, RGB565 **big-endian**, row-major: 110,080 bytes per frame,
215 chunks of 512 bytes. Up to 60 frames, with one delay for every frame.

1. `0d 00 00 01 00 05 00 | 40 <frames> 00 <delay_lo> <delay_hi>` (start; byte 7 = mode << 6, mode 1)
2. for each frame, for each chunk: `0c 00 <frame> <chunk> <sum(data) & ff> <len_lo> <len_hi> <data>`;
   wait for the ack: status 1 = next, otherwise resend
3. `0d … | 00 <frames> 00 <delay>` (finish, mode 0). Abort = mode 2.

**Timing.** The keyboard needs about **180 ms to draw a frame** (`DrawFrameTime=180` in the
Windows app's S98 file) and waits `delay` ms on top, so a frame is shown for `180 + delay` ms.
The Windows app therefore thins out GIFs that change faster than that: with more than 6 frames, it
sends `k = round(total_ms / 180)` frames (at most 60), picked evenly in time, with
`delay = max(0, ms_per_frame − 180)`. RK's web driver subtracts only 25 ms, which plays S98 GIFs
about 3× too slowly. See `pick_frames` in protocol.py and the `pick_frames` vectors.
Each chunk takes about 59 ms (the keyboard sets the pace), so about 12.7 s per frame.
