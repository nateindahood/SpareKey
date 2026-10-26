"""S98 wire format: pure packet builders and parsers (no I/O).

Every command is HID feature report 9 carrying 519 bytes:
    [cmd, arg1, arg2, package_count, package_index, len_lo, len_hi, payload...]
Get commands (cmd >= 0x80) are answered by reading feature report 9 back; the
answer repeats the 7-byte header followed by the data. Set commands are
acknowledged with input report 9 `[?, 0x06, status]` (status 1 = OK).
See spec/PROTOCOL.md; spec/vectors/*.json holds byte-exact examples that the
macOS implementation is tested against too.
"""

import struct

REPORT_ID = 9
REPORT_LEN = 519
HEADER_LEN = 7

SCREEN_W, SCREEN_H = 320, 172
FRAME_BYTES = SCREEN_W * SCREEN_H * 2
TFT_CHUNK = 512
MAX_FRAMES = 60

KEYS = 126                 # 6 rows x 21 columns in the key matrix
PROFILE_LEN = 128
LED_EFFECT_LEN = 3 * 7 * 20     # 20 effects x 21 bytes
LED_COLORS_LEN = 3 * KEYS       # planar: 126 reds, 126 greens, 126 blues
KEYMATRIX_LEN = 6 * 21 * 4      # 126 x u32 big-endian
MACRO_LEN = 4096
MACRO_CHUNK = 512

# commands
SET_KEYMATRIX, SET_PROFILE, SET_MACROS, SET_LEDCOLORS = 3, 4, 5, 6
SET_LEDEFFECT, SET_SYSINFO, TFT_DATA, TFT_CTRL, FACTORY_RESET = 10, 11, 12, 13, 17
GET_INFO, GET_KEYMATRIX, GET_PROFILE, GET_MACROS, GET_LEDCOLORS, GET_LEDEFFECT = 130, 131, 132, 133, 134, 138

TFT_FINISH, TFT_START, TFT_ABORT = 0, 1, 2
ACK = 0x06


def packet(cmd, arg1=0, arg2=0, count=1, index=0, payload=b"", length=None):
    n = len(payload) if length is None else length
    return bytes([cmd, arg1, arg2, count, index, n & 0xFF, n >> 8]) + bytes(payload)


# Shortest payload a real answer carries. Firmware 0001 cuts answers off after 164-248 data bytes,
# but blocks up to this size (profile, info) always arrive whole.
MIN_ANSWER_PAYLOAD = 128


def is_answer(data, pkt, length):
    """A real answer echoes the whole 7-byte header and carries data. A bare header (no data ready)
    or a status packet must never be read as an all-zero block: writing that back blanks the settings."""
    return (len(data) > HEADER_LEN and len(data) >= HEADER_LEN + min(length, MIN_ANSWER_PAYLOAD)
            and bytes(data[:HEADER_LEN]) == bytes(pkt[:HEADER_LEN]))


def parse_get(data, length):
    """data = feature report 9 contents without the report id."""
    return bytes(data[HEADER_LEN:HEADER_LEN + length]).ljust(length, b"\0")


def parse_ack(report):
    """report = input report as read from hidraw (report id first).
    Returns True (ok), False (resend) or None (not an ack)."""
    if len(report) >= 4 and report[0] == REPORT_ID and report[2] == ACK:
        return report[3] == 1
    return None


# ------------------------------------------------------------------ requests --

def get_info():
    return packet(GET_INFO, 1, length=10)


def parse_info(data):
    d = bytes(data)
    return {"firmware": "%02x%02x" % (d[15], d[16])}


def get_profile(profile=0):
    return packet(GET_PROFILE, 0, profile & 3, length=PROFILE_LEN)


def set_profile(buf, profile=0):
    assert len(buf) == PROFILE_LEN
    return packet(SET_PROFILE, 0, profile & 3, payload=buf)


def get_led_effect(profile=0):
    return packet(GET_LEDEFFECT, 0, profile & 3, length=LED_EFFECT_LEN)


def set_led_effect(buf, profile=0):
    assert len(buf) == LED_EFFECT_LEN
    return packet(SET_LEDEFFECT, 0, profile & 3, payload=buf)


def get_led_colors(profile=0):
    return packet(GET_LEDCOLORS, 0, profile & 3, length=LED_COLORS_LEN)


def set_led_colors(buf, profile=0):
    assert len(buf) == LED_COLORS_LEN
    return packet(SET_LEDCOLORS, 0, profile & 3, payload=buf)


def get_keymatrix(table, layer):
    return packet(GET_KEYMATRIX, (table << 2) | layer, length=KEYMATRIX_LEN)


def set_keymatrix(table, layer, codes):
    assert len(codes) == KEYS
    return packet(SET_KEYMATRIX, (table << 2) | layer, payload=struct.pack(">126I", *codes))


def parse_keymatrix(data):
    """Only the first 62 entries survive a read on firmware 0001; the rest read as 0."""
    return list(struct.unpack(">126I", bytes(data[:KEYMATRIX_LEN])))


def get_macros(chunk):
    return packet(GET_MACROS, 0, 0, 1, chunk, length=MACRO_CHUNK)


def set_macros(blob):
    """Split a serialized macro table into SET_MACROS packets."""
    count = max(1, -(-len(blob) // MACRO_CHUNK))
    return [packet(SET_MACROS, 0, 0, count, i, payload=blob[i * MACRO_CHUNK:(i + 1) * MACRO_CHUNK])
            for i in range(count)]


def factory_reset():
    return packet(FACTORY_RESET, payload=b"\x00")


def sysinfo(year, month, day, hour, minute, second, weekday, volume=0, cpu=0, mem=0):
    """Clock (and optional stats) for the screen. weekday: 0 = Sunday."""
    payload = bytes([volume, cpu, mem, year & 0xFF, year >> 8, month, day, hour, minute, second,
                     weekday, 0, 0, 0])
    return packet(SET_SYSINFO, payload=payload)


def tft_ctrl(mode, frames=0, delay_ms=0):
    """mode: TFT_START / TFT_FINISH / TFT_ABORT. delay_ms is what the keyboard waits per frame."""
    payload = bytes([mode << 6, frames, 0, delay_ms & 0xFF, delay_ms >> 8])
    return packet(TFT_CTRL, payload=payload)


def tft_chunk(frame, index, data):
    p = bytearray(HEADER_LEN + len(data))
    p[0], p[2], p[3] = TFT_DATA, frame, index
    p[4] = sum(data) & 0xFF
    p[5], p[6] = len(data) & 0xFF, len(data) >> 8
    p[HEADER_LEN:] = data
    return bytes(p)


def frame_delay(ms):
    """The vendor app subtracts the keyboard's own ~25 ms draw time."""
    return ms - 25 if ms >= 25 else ms


def rgb565be(rgb_bytes):
    """Packed RGB888 -> RGB565 big-endian (the screen's pixel format)."""
    out = bytearray(len(rgb_bytes) // 3 * 2)
    j = 0
    for i in range(0, len(rgb_bytes) - 2, 3):
        v = (rgb_bytes[i] >> 3) << 11 | (rgb_bytes[i + 1] >> 2) << 5 | rgb_bytes[i + 2] >> 3
        out[j] = v >> 8
        out[j + 1] = v & 0xFF
        j += 2
    return bytes(out)
