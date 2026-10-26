"""Offline tests (no keyboard needed): python3 -m unittest discover -s tests"""

import json
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src"))

from sparekey import keymap  # noqa: E402
from sparekey import protocol as P  # noqa: E402
from sparekey.settings import Profile  # noqa: E402


class Protocol(unittest.TestCase):
    def test_vectors_still_match(self):
        with open(os.path.join(ROOT, "spec", "vectors", "packets.json")) as f:
            vec = {p["name"]: p["hex"] for p in json.load(f)["packets"]}
        self.assertEqual(vec["get_info"], P.get_info().hex())
        self.assertEqual(vec["sysinfo"], P.sysinfo(2026, 10, 25, 21, 50, 43, 0).hex())
        self.assertEqual(vec["tft_start"], P.tft_ctrl(P.TFT_START, 39, P.frame_delay(100)).hex())

    def test_tft_chunk_header(self):
        pkt = P.tft_chunk(3, 7, b"\x01\x02\x03")
        self.assertEqual(pkt[:7], bytes([12, 0, 3, 7, 6, 3, 0]))

    def test_fast_gif_keeps_its_speed(self):
        # 53 frames x 60 ms (3.18 s): the keyboard draws a frame in 180 ms, so send ~18 frames, no extra delay
        idx, ms = P.pick_frames([60] * 53)
        self.assertEqual((len(idx), ms, P.frame_delay(ms)), (18, 180, 0))
        self.assertAlmostEqual(len(idx) * ms, 3180, delta=180)
        self.assertEqual(idx, sorted(idx))
        # slow GIFs keep every frame and wait the difference
        self.assertEqual(P.pick_frames([500] * 3), ([0, 1, 2], 500))
        self.assertEqual(P.frame_delay(500), 320)
        # long GIFs: at most 60 frames, same total length
        idx, ms = P.pick_frames([250] * 100)
        self.assertEqual(len(idx), 60)
        self.assertAlmostEqual(len(idx) * ms, 25000, delta=60)

    def test_rgb565(self):
        self.assertEqual(P.rgb565be(bytes([255, 0, 0, 0, 0, 255])), b"\xf8\x00\x00\x1f")

    def test_ack(self):
        self.assertTrue(P.parse_ack(bytes.fromhex("090a060101")))
        self.assertFalse(P.parse_ack(bytes.fromhex("090a060002")))
        self.assertIsNone(P.parse_ack(bytes.fromhex("0301020304")))


class Keys(unittest.TestCase):
    def test_macro_roundtrip(self):
        ms = [{"name": "Test", "steps": [{"up": False, "type": 0, "key": 4, "delay": 50},
                                         {"up": True, "type": 0, "key": 4, "delay": 123456}]}]
        self.assertEqual(keymap.decode_macros(keymap.encode_macros(ms) + bytes(100)), ms)

    def test_merge_keeps_defaults_beyond_readable_part(self):
        device = [0x29] + [0] * 125
        merged = keymap.merged_matrix(0, 0, device, {"79": keymap.macro_action(0)})
        self.assertEqual(merged[0], 0x29)
        self.assertEqual(merged[79], keymap.macro_action(0))
        self.assertEqual(merged[81], keymap.DEFAULTS["win"][0][81])   # Enter survives

    def test_garbage_read_is_ignored(self):
        merged = keymap.merged_matrix(1, 3, [0x900BA6E0] * 126)
        self.assertEqual(merged, keymap.DEFAULTS["mac"][3])

    def test_all_zero_read_is_ignored(self):
        self.assertEqual(keymap.merged_matrix(1, 0, [0] * 126), keymap.DEFAULTS["mac"][0])


class Settings(unittest.TestCase):
    def test_led_param(self):
        p = Profile(bytes(128))
        p.set_led_param(9, brightness=20, speed=2, mix=True)
        self.assertEqual(p.led_param(9), {"brightness": 20, "speed": 2, "mix": True})
        p.effect = 18
        self.assertEqual(p.buf[9], 1)


if __name__ == "__main__":
    unittest.main()
