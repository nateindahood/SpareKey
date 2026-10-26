"""Regenerate spec/vectors/*.json from the Python implementation.

The macOS app's tests load the same files, so both implementations must produce
identical bytes. Run: python3 tests/make_vectors.py
"""

import json
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src"))

from sparekey import keymap  # noqa: E402
from sparekey import protocol as P  # noqa: E402
from sparekey.settings import KeyColors, LedEffects, Profile  # noqa: E402

OUT = os.path.join(ROOT, "spec", "vectors")


def h(b):
    return bytes(b).hex()


def main():
    os.makedirs(OUT, exist_ok=True)
    profile = bytes(range(128))
    codes = [(i * 2654435761) & 0xFFFFFFFF for i in range(126)]
    chunk = bytes((i * 7) & 0xFF for i in range(512))
    macros = [{"name": "Hi", "steps": [{"up": False, "type": 1, "key": 225, "delay": 30},
                                       {"up": False, "type": 0, "key": 11, "delay": 50},
                                       {"up": True, "type": 0, "key": 11, "delay": 50},
                                       {"up": True, "type": 1, "key": 225, "delay": 70000}]},
              {"name": "Ünï", "steps": [{"up": False, "type": 2, "key": 1, "delay": 0}]}]
    packets = [
        {"name": "get_info", "hex": h(P.get_info())},
        {"name": "get_profile", "args": {"profile": 0}, "hex": h(P.get_profile(0))},
        {"name": "set_profile", "args": {"profile": 1, "payload": h(profile)}, "hex": h(P.set_profile(profile, 1))},
        {"name": "get_led_effect", "args": {"profile": 0}, "hex": h(P.get_led_effect(0))},
        {"name": "get_led_colors", "args": {"profile": 0}, "hex": h(P.get_led_colors(0))},
        {"name": "get_keymatrix", "args": {"table": 1, "layer": 2}, "hex": h(P.get_keymatrix(1, 2))},
        {"name": "set_keymatrix", "args": {"table": 0, "layer": 1, "codes": codes},
         "hex": h(P.set_keymatrix(0, 1, codes))},
        {"name": "get_macros", "args": {"chunk": 3}, "hex": h(P.get_macros(3))},
        {"name": "factory_reset", "hex": h(P.factory_reset())},
        {"name": "sysinfo", "args": {"year": 2026, "month": 10, "day": 25, "hour": 21, "minute": 50, "second": 43,
                                     "weekday": 0}, "hex": h(P.sysinfo(2026, 10, 25, 21, 50, 43, 0))},
        {"name": "tft_start", "args": {"frames": 39, "delay_ms": P.frame_delay(100)},
         "hex": h(P.tft_ctrl(P.TFT_START, 39, P.frame_delay(100)))},
        {"name": "tft_finish", "args": {"frames": 39, "delay_ms": 75}, "hex": h(P.tft_ctrl(P.TFT_FINISH, 39, 75))},
        {"name": "tft_abort", "hex": h(P.tft_ctrl(P.TFT_ABORT))},
        {"name": "tft_chunk", "args": {"frame": 2, "index": 214, "data": h(chunk)}, "hex": h(P.tft_chunk(2, 214, chunk))},
    ]
    blob = keymap.encode_macros(macros)
    for i, pkt in enumerate(P.set_macros(blob)):
        packets.append({"name": "set_macros[%d]" % i, "hex": h(pkt)})
    with open(os.path.join(OUT, "packets.json"), "w") as f:
        json.dump({"packets": packets}, f, indent=1)

    pixels = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 18, 52, 86, 0, 0, 0])
    prof = Profile(bytes(128))
    prof.effect = 9
    prof.set_led_param(9, brightness=12, speed=3, mix=True)
    prof.sleep_minutes = 5
    prof.win_lock = True
    fx = LedEffects(bytes(420))
    fx.set_color(9, (1, 2, 3))
    kc = KeyColors(bytes(378))
    kc.set(5, (10, 20, 30))
    data = {
        "rgb565be": {"rgb": h(pixels), "out": h(P.rgb565be(pixels))},
        "frame_delay": [[100, P.frame_delay(100)], [25, 0], [20, 20]],
        "macros": {"macros": macros, "blob": h(blob)},
        "profile_edit": {"ops": "effect=9; led_param(9, brightness=12, speed=3, mix=true); sleep=5min; winlock=on",
                         "out": h(bytes(prof))},
        "led_effect_color": {"effect": 9, "rgb": [1, 2, 3], "out": h(bytes(fx))},
        "key_color": {"index": 5, "rgb": [10, 20, 30], "out": h(bytes(kc))},
        "ack": [{"report": "090a060101000000", "ok": True}, {"report": "090a060002000000", "ok": False},
                {"report": "0901000000000000", "ok": None}],
        "keymatrix_parse": {"data": h(struct.pack(">126I", *codes)), "codes": codes},
    }
    with open(os.path.join(OUT, "models.json"), "w") as f:
        json.dump(data, f, indent=1)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
