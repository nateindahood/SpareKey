"""sparekey command line."""

import argparse
import json
import os
import sys
import time

from . import __version__, keymap, media, store
from . import protocol as P
from .device import Device, DeviceError, find_devices
from .settings import EFFECT_IDS, EFFECTS, BRIGHTNESS_LEVELS, LedEffects, Profile


def _bar(done, total):
    print("\r  %3d%%  chunk %d/%d" % (done * 100 // total, done, total), end="", flush=True)


def _frame_limit(text):
    n = int(text)
    if not 1 <= n <= P.MAX_FRAMES:
        raise argparse.ArgumentTypeError("the S98 holds 1 to %d frames" % P.MAX_FRAMES)
    return n


def _optional(read, fallback):
    try:
        return read()
    except DeviceError:
        return fallback


def backup(d, path=None):
    """Save every readable settings block to a JSON file; returns its path."""
    # A layer is kept only if two reads agree: some (e.g. Mac FN) read back as random memory, and a
    # missing layer falls back to the vendor defaults. Per-key colors and macros often can't be read
    # at all (the keyboard answers with a bare header); they're saved as "" then.
    km = {}
    for t in (0, 1):
        for l in range(4):
            a = d.keymatrix(t, l)
            if d.keymatrix(t, l) == a:
                km["%d/%d" % (t, l)] = a
    data = {"version": 1, "model": d.model, "firmware": d.info()["firmware"], "time": time.time(),
            "profile": d.profile().hex(), "led_effects": d.led_effects().hex(),
            "key_colors": _optional(d.key_colors, b"").hex(), "keymatrix": km,
            "macros": _optional(d.macros_blob, b"").hex()}
    if path is None:
        path = os.path.join(store.BACKUP_DIR, time.strftime("s98-%Y%m%d-%H%M%S.json"))
    store.write_private(path, data)   # macros can hold typed text: readable by you only
    return path


def ensure_first_backup(d):
    """Before the first change, keep a copy of how the keyboard was set up."""
    first = os.path.join(store.BACKUP_DIR, "s98-original.json")
    if not os.path.exists(first):
        backup(d, first)


def read_backup(path):
    """Load and check a backup file. Nothing from a damaged or edited file reaches the keyboard:
    raises ValueError unless every block has the right size and the profile its end marker."""
    try:
        with open(path) as f:
            data = json.load(f)
        profile = bytes.fromhex(data["profile"])
        effects = bytes.fromhex(data["led_effects"])
        colors = bytes.fromhex(data.get("key_colors", ""))
        macros = bytes.fromhex(data.get("macros", "")).rstrip(b"\0")
        layers = {}
        for tl, codes in data.get("keymatrix", {}).items():
            t, l = map(int, tl.split("/"))
            if t not in (0, 1) or l not in range(4) or len(codes) != P.KEYS \
                    or not all(isinstance(c, int) and 0 <= c <= 0xFFFFFFFF for c in codes):
                raise ValueError("key layer %s" % tl)
            layers[(t, l)] = codes
    except (KeyError, TypeError, ValueError, AttributeError) as e:
        raise ValueError("%s isn't a valid SpareKey backup (%s)" % (os.path.basename(path), e))
    if len(profile) != P.PROFILE_LEN or profile[-2:] != b"\x5a\xa5":
        raise ValueError("%s has a damaged lighting profile" % os.path.basename(path))
    if len(effects) != P.LED_EFFECT_LEN or len(colors) not in (0, P.LED_COLORS_LEN) or len(macros) > P.MACRO_LEN:
        raise ValueError("%s has a block of the wrong size" % os.path.basename(path))
    return {"profile": profile, "effects": effects, "colors": colors, "layers": layers, "macros": macros}


def restore(d, path, keys=True):
    b = read_backup(path)   # checked completely before anything is written
    d.set_profile(b["profile"])
    cfg = store.load_config()
    # unreadable blocks were saved empty (or all zero by older versions): skip rather than write
    # something that isn't a real copy
    if any(b["effects"]):
        d.set_led_effects(b["effects"])
    if any(b["colors"]):
        d.set_key_colors(b["colors"])
    if keys:
        km = cfg.setdefault("keymap", {})
        for (t, l), codes in b["layers"].items():
            restored = keymap.merged_matrix(t, l, codes)
            d.set_keymatrix(t, l, restored)
            # what the keyboard now has becomes your saved key changes, so later edits build on it
            base = keymap.merged_matrix(t, l, baseline(t, l))
            changes = {str(i): v for i, v in enumerate(restored) if v != base[i]}
            if changes:
                km.setdefault(str(t), {})[str(l)] = changes
            else:
                km.get(str(t), {}).pop(str(l), None)
    if b["macros"]:
        d.set_macros_blob(b["macros"])
        cfg["macros"] = keymap.decode_macros(b["macros"])
    if any(b["colors"]):
        cfg["key_colors"] = b["colors"].hex()
    store.save_config(cfg)


def factory_reset(d):
    """Back up, reset, and only then forget what SpareKey kept about the old setup."""
    backup(d)
    d.factory_reset()
    cfg = store.load_config()
    for k in ("keymap", "macros", "key_colors"):
        cfg.pop(k, None)
    store.save_config(cfg)


def delete_macro(cfg, number):
    """Remove macro `number` (0-based) from the saved list and fix keys that point at macros by
    position: keys on the deleted one go back to default, later ones move down by one.
    Returns the (table, layer) pairs whose key changes were updated."""
    macros = cfg.get("macros", [])
    if 0 <= number < len(macros):
        macros.pop(number)
    changed = set()
    for t, layers in cfg.get("keymap", {}).items():
        for l, keys in layers.items():
            for idx, action in list(keys.items()):
                if action >> 24 != keymap.MACRO_TYPE:
                    continue
                n = action & 0xFFFF
                if n == number:
                    keys.pop(idx)
                elif n > number:
                    keys[idx] = keymap.macro_action(n - 1)
                else:
                    continue
                changed.add((int(t), int(l)))
    return changed


def layers_using_macros(cfg):
    return {(int(t), int(l)) for t, layers in cfg.get("keymap", {}).items() for l, keys in layers.items()
            if any(a >> 24 == keymap.MACRO_TYPE for a in keys.values())}


def key_overrides(cfg, table, layer):
    return cfg.get("keymap", {}).get(str(table), {}).get(str(layer), {})


def baseline(table, layer, d=None):
    """How the layer looked before SpareKey changed anything: the original backup's readable part.
    Live reads can't be used once keys are remapped, or "Default" would just write the remap back."""
    try:
        with open(os.path.join(store.BACKUP_DIR, "s98-original.json")) as f:
            return json.load(f)["keymatrix"]["%d/%d" % (table, layer)]
    except (OSError, ValueError, KeyError):
        return d.keymatrix(table, layer) if d is not None else None


def layer_codes(table, layer, cfg=None, d=None):
    cfg = store.load_config() if cfg is None else cfg
    return keymap.merged_matrix(table, layer, baseline(table, layer, d), key_overrides(cfg, table, layer))


def write_layer(d, table, layer, cfg=None):
    ensure_first_backup(d)
    d.set_keymatrix(table, layer, layer_codes(table, layer, cfg, d))


# ----------------------------------------------------------------- commands --

def cmd_info(a):
    devs = find_devices()
    if not devs:
        print("No keyboard found (USB 258a:01af). USB selected in the screen's settings menu? Udev rule installed?")
        return 1
    with Device(verbose=a.verbose) as d:
        prof = Profile(d.profile())
        p = prof.led_param()
        print("%s at %s, firmware %s" % (d.model, d.path, d.info()["firmware"]))
        print("lighting: %s, brightness %d/5, speed %d/%d, %s" % (
            EFFECT_IDS.get(prof.effect, (0, "effect %d" % prof.effect))[1], Profile.level_for(p["brightness"]),
            p["speed"], 4, "mixed colors" if p["mix"] else "color #%02x%02x%02x" % LedEffects(d.led_effects()).color(prof.effect)))
        print("sleep after %g min, Win lock %s, WASD/arrows swap %s" % (
            prof.sleep_minutes, "on" if prof.win_lock else "off", "on" if prof.wasd_swap else "off"))
    return 0


def cmd_upload(a):
    images, ms = media.load(a.image, a.fit, a.max_frames, a.delay)
    print("%d frame(s), %d ms each; about %d min to send" % (len(images), ms, round(media.estimate_seconds(len(images)) / 60) or 1))
    if a.preview:
        media.save_preview(images, ms, a.preview)
        print("preview:", a.preview)
    if a.dry_run:
        return 0
    with Device(verbose=a.verbose) as d:
        d.upload(media.encode(images), ms, progress=_bar)
        d.sync_clock()
    print("\ndone")
    return 0


def cmd_abort(a):
    with Device() as d:
        d._set_feature(P.tft_ctrl(P.TFT_ABORT))
    return 0


def cmd_clock(a):
    with Device() as d:
        d.sync_clock()
    print("clock set to", time.strftime("%Y-%m-%d %H:%M:%S"))
    return 0


def cmd_light(a):
    with Device() as d:
        ensure_first_backup(d)
        prof = Profile(d.profile())
        if a.effect is not None:
            match = [e for e in EFFECTS if a.effect.lower() in (str(e[0]), e[1].lower())]
            if not match:
                print("effects:", ", ".join(e[1] for e in EFFECTS))
                return 1
            prof.effect = match[0][0]
        prof.set_led_param(brightness=None if a.brightness is None else BRIGHTNESS_LEVELS[a.brightness],
                           speed=a.speed, mix=True if a.mix else (False if a.color else None))
        d.set_profile(bytes(prof))
        if a.color:
            fx = LedEffects(d.led_effects())
            h = a.color.lstrip("#")
            fx.set_color(prof.effect, (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)))
            d.set_led_effects(bytes(fx))
    return cmd_info(a)


def cmd_backup(a):
    with Device() as d:
        print("saved", backup(d, a.file))
    return 0


def cmd_restore(a):
    with Device() as d:
        restore(d, a.file)
    print("restored", a.file)
    return 0


def cmd_reset(a):
    if not a.yes:
        print("This resets lighting, key maps and macros on the keyboard. Re-run with --yes.")
        return 1
    with Device() as d:
        ensure_first_backup(d)
        factory_reset(d)
    print("keyboard reset to factory settings")
    return 0


def cmd_service(a):
    from . import service
    service.main()


def cmd_gui(a):
    from . import gui
    return gui.main(a.page)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="sparekey", description="Screen, lighting and keys for the RK S98 keyboard")
    ap.add_argument("--version", action="version", version="sparekey " + __version__)
    ap.add_argument("-v", "--verbose", action="store_true", help="show HID traffic")
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("info", help="show the keyboard and its current settings").set_defaults(func=cmd_info)
    up = sub.add_parser("upload", help="send a GIF or image to the screen")
    up.add_argument("image")
    up.add_argument("--fit", choices=[f for f, _ in media.FITS], default="cover")
    up.add_argument("--delay", type=int, help="ms per frame (default: from the GIF)")
    up.add_argument("--max-frames", type=_frame_limit, default=P.MAX_FRAMES, metavar="1-%d" % P.MAX_FRAMES)
    up.add_argument("--preview", metavar="FILE")
    up.add_argument("--dry-run", action="store_true")
    up.set_defaults(func=cmd_upload)
    sub.add_parser("abort", help="cancel an interrupted upload").set_defaults(func=cmd_abort)
    sub.add_parser("clock", help="set the keyboard clock to this computer's time").set_defaults(func=cmd_clock)

    li = sub.add_parser("light", help="change the lighting")
    li.add_argument("--effect", help="name or number")
    li.add_argument("--brightness", type=int, choices=range(6))
    li.add_argument("--speed", type=int, choices=range(5))
    li.add_argument("--color", help="RRGGBB")
    li.add_argument("--mix", action="store_true", help="mixed colors instead of one color")
    li.set_defaults(func=cmd_light)

    b = sub.add_parser("backup", help="save the keyboard's settings to a file")
    b.add_argument("file", nargs="?")
    b.set_defaults(func=cmd_backup)
    r = sub.add_parser("restore", help="write settings saved by backup")
    r.add_argument("file")
    r.set_defaults(func=cmd_restore)
    fr = sub.add_parser("reset", help="factory reset (lighting, keys, macros)")
    fr.add_argument("--yes", action="store_true")
    fr.set_defaults(func=cmd_reset)

    sub.add_parser("service", help="run the clock service (used by systemd)").set_defaults(func=cmd_service)
    g = sub.add_parser("gui", help="open the app")
    g.add_argument("--page", choices=["screen", "lighting", "keys", "macros", "settings"])
    g.set_defaults(func=cmd_gui)

    a = ap.parse_args(argv)
    if not a.cmd:
        a = ap.parse_args(["gui"] + list(argv or []))
    try:
        return a.func(a) or 0
    except (DeviceError, media.MediaError, ValueError, OSError) as e:
        print("error:", e, file=sys.stderr)
        return 1
