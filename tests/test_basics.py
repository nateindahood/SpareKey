"""Offline tests (no keyboard needed): python3 -m unittest discover -s tests"""

import json
import os
import random
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src"))

from sparekey import keymap, store  # noqa: E402
from sparekey import protocol as P  # noqa: E402
from sparekey.settings import Profile  # noqa: E402


class Protocol(unittest.TestCase):
    def test_vectors_still_match(self):
        with open(os.path.join(ROOT, "spec", "vectors", "packets.json")) as f:
            vec = {p["name"]: p["hex"] for p in json.load(f)["packets"]}
        self.assertEqual(vec["get_info"], P.get_info().hex())
        self.assertEqual(vec["sysinfo"], P.sysinfo(2026, 10, 25, 21, 50, 43, 0).hex())
        self.assertEqual(vec["tft_start"], P.tft_ctrl(P.TFT_START, 39, 75).hex())

    def test_tft_chunk_header(self):
        pkt = P.tft_chunk(3, 7, b"\x01\x02\x03")
        self.assertEqual(pkt[:7], bytes([12, 0, 3, 7, 6, 3, 0]))

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


class Playlists(unittest.TestCase):
    def test_loop_and_shuffle(self):
        with tempfile.TemporaryDirectory() as tmp:
            files = []
            for n in "abc":
                path = os.path.join(tmp, n + ".gif")
                open(path, "w").close()
                files.append(path)
            st = {}
            loop = [store.next_item({"items": files}, st) for _ in range(4)]
            self.assertEqual(loop, files + files[:1])
            st, rng = {}, random.Random(1)
            seen = [store.next_item({"items": files, "order": "shuffle"}, st, rng) for _ in range(9)]
            for i in range(0, 9, 3):
                self.assertEqual(sorted(seen[i:i + 3]), files)
            self.assertTrue(all(a != b for a, b in zip(seen, seen[1:])))
            os.remove(files[1])
            self.assertNotIn(files[1], [store.next_item({"items": files}, {}) for _ in range(3)])


if __name__ == "__main__":
    unittest.main()
