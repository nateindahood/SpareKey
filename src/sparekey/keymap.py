"""Key codes, the S98 key layout, default key maps and macro serialization.

A key action is a u32: type << 24 | param << 16 | code.
  type 0: HID usage in `code`, modifier bits in `param` (1 Ctrl, 2 Shift, 4 Alt, 8 Win, x16 for right side)
  type 3: macro number `code`
  other types: media / lighting / keyboard functions (names come from the vendor table)
"""

import json
import os
import struct

DATA = os.path.join(os.path.dirname(__file__), "data")
LAYERS = ["Base", "FN", "FN2", "Tap"]
TABLES = ["Windows", "Mac"]
MACRO_TYPE = 3


def _load():
    with open(os.path.join(DATA, "keymap.json")) as f:
        km = json.load(f)
    with open(os.path.join(DATA, "layout_s98.json")) as f:
        layout = json.load(f)
    return km, layout


_KM, LAYOUT = _load()
CODES = {k: v for k, v in _KM["keycodes"].items() if not k.startswith("SP_TEST")}
NAMES = {}
for _name, _value in CODES.items():
    NAMES.setdefault(_value, _name)
DEFAULTS = {"win": _KM["defaults"]["win"], "mac": _KM["defaults"]["mac"]}
KEYS_BY_INDEX = {k["index"]: k for k in LAYOUT["keys"] if k["w"] > 0}

_PRETTY = {"L_": "Left ", "R_": "Right ", "NUM_": "Num ", "LED_": "Light ", "Fn1": "FN"}


def pretty(name):
    if name is None:
        return "?"
    n = name
    for prefix in ("KEY_", "SP_", "MAC_"):
        if n.startswith(prefix):
            n = n[len(prefix):]
            break
    for k, v in _PRETTY.items():
        n = n.replace(k, v)
    return n.replace("_", " ").strip()


def describe(action):
    if action == 0:
        return "(default)"
    if action >> 24 == MACRO_TYPE:
        return "Macro %d" % ((action & 0xFFFF) + 1)
    return pretty(NAMES.get(action)) if action in NAMES else "0x%08x" % action


def assignable():
    """[(label, action)] for the remap picker, grouped roughly by kind."""
    out = []
    for name, value in CODES.items():
        if value == 0 or name.startswith(("KEY_CODE", "SP_BT", "SP_TEST")):
            continue
        out.append((pretty(name), value))
    out.sort(key=lambda t: (t[1] >> 24, t[0].lower()))
    return out


def macro_action(number):
    return (MACRO_TYPE << 24) | number


def merged_matrix(table, layer, from_device=None, overrides=None):
    """Full 126-key map: vendor default, then the readable part from the keyboard, then the user's edits."""
    codes = list(DEFAULTS["mac" if table else "win"][layer])
    if from_device:
        known = set(CODES.values()) | {0}
        head = from_device[:62]
        # the Mac table reads back as all zeros although it works: empty where the default isn't = no read
        unread = not any(head) and any(codes[:62])
        if not unread and all(v in known or v >> 24 == MACRO_TYPE for v in head):
            codes[:62] = head
    for idx, action in (overrides or {}).items():
        codes[int(idx)] = action
    return codes


# ------------------------------------------------------------------- macros --

ACTION_DOWN, ACTION_UP = 0, 1
T_KEY, T_MODIFIER, T_MOUSE = 0, 1, 2
MODIFIERS = {224: "Left Ctrl", 225: "Left Shift", 226: "Left Alt", 227: "Left Win",
             228: "Right Ctrl", 229: "Right Shift", 230: "Right Alt", 231: "Right Win"}
MOUSE = {1: "Mouse left", 2: "Mouse right", 4: "Mouse middle", 8: "Mouse back", 16: "Mouse forward"}


def encode_step(step):
    """step = {"up": bool, "type": 0/1/2, "key": usage, "delay": ms}"""
    d = max(0, min(0xFFFFF, int(step.get("delay", 50))))
    return bytes([(1 if step.get("up") else 0) << 7 | (step.get("type", 0) & 7) << 4 | d >> 16,
                  (d >> 8) & 0xFF, d & 0xFF, step["key"] & 0xFF])


def decode_step(b):
    return {"up": bool(b[0] >> 7), "type": (b[0] >> 4) & 7, "delay": (b[0] & 15) << 16 | b[1] << 8 | b[2],
            "key": b[3]}


def encode_macros(macros):
    """macros = [{"name": str, "steps": [step]}] -> table blob (<= 4096 bytes)."""
    bodies = []
    for m in macros:
        name = m["name"].encode("utf-16-le")[:254]
        bodies.append(bytes([len(name)]) + name + b"".join(encode_step(s) for s in m["steps"]))
    head_len = 4 * len(bodies)
    head, off = b"", head_len
    for b in bodies:
        head += struct.pack("<HH", off, len(b))
        off += len(b)
    blob = head + b"".join(bodies)
    if len(blob) > 4096:
        raise ValueError("macros too long (%d bytes, the keyboard holds 4096)" % len(blob))
    return blob


def decode_macros(blob):
    if len(blob) < 4:
        return []
    first = struct.unpack_from("<H", blob, 0)[0]
    if first == 0 or first % 4 or first > len(blob):
        return []
    out = []
    for i in range(first // 4):
        off, ln = struct.unpack_from("<HH", blob, i * 4)
        body = blob[off:off + ln]
        if len(body) < 1:
            continue
        nlen = body[0]
        name = body[1:1 + nlen].decode("utf-16-le", errors="replace")
        steps = [decode_step(body[j:j + 4]) for j in range(1 + nlen, len(body) - 3, 4)]
        out.append({"name": name, "steps": steps})
    return out


def describe_step(s):
    if s["type"] == T_MODIFIER:
        what = MODIFIERS.get(s["key"], "Mod %d" % s["key"])
    elif s["type"] == T_MOUSE:
        what = MOUSE.get(s["key"], "Mouse %d" % s["key"])
    else:
        what = pretty(NAMES.get(s["key"], "0x%02x" % s["key"]))
    return "%s %s, then wait %d ms" % ("Release" if s["up"] else "Press", what, s["delay"])
