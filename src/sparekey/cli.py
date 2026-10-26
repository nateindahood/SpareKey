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


def _optional(read, fallback):
    try:
        return read()
    except DeviceError:
        return fallback


def backup(d, path=None):
    """Save every readable settings block to a JSON file; returns its path."""
    # A layer is kept only if two reads agree: some (e.g. Mac FN) read back as random memory, and a
    # missing layer falls back to the vendor defaults. Per-key colours and macros often can't be read
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
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=1)
    return path


def ensure_first_backup(d):
    """Before the first change, keep a copy of how the keyboard was set up."""
    first = os.path.join(store.BACKUP_DIR, "s98-original.json")
    if not os.path.exists(first):
        backup(d, first)


def restore(d, path, keys=True):
    with open(path) as f:
        data = json.load(f)
    d.set_profile(bytes.fromhex(data["profile"]))
    d.set_led_effects(bytes.fromhex(data["led_effects"]))
    # older backups and unreadable blocks: skip rather than write something that isn't a real copy
    colors = bytes.fromhex(data["key_colors"])
    if len(colors) == P.LED_COLORS_LEN and any(colors):
        d.set_key_colors(colors)
    if keys:
        for tl, codes in data["keymatrix"].items():
            t, l = map(int, tl.split("/"))
            d.set_keymatrix(t, l, keymap.merged_matrix(t, l, codes))
    blob = bytes.fromhex(data["macros"]).rstrip(b"\0")
    if blob:
        d.set_macros_blob(blob)


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
            p["speed"], 4, "mixed colours" if p["mix"] else "colour #%02x%02x%02x" % LedEffects(d.led_effects()).color(prof.effect)))
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
        d.factory_reset()
    cfg = store.load_config()
    cfg.pop("keymap", None)
    store.save_config(cfg)
    print("keyboard reset to factory settings")
    return 0


def cmd_playlist(a):
    pls = store.playlists()
    st = store.load_state()
    if a.action == "list":
        for name, pl in pls.items():
            mark = "▶" if st.get("active") == name else " "
            print("%s %s  (%d files, %s, every %d min)" % (mark, name, len(pl["items"]), pl["order"], pl["interval"]))
        return 0
    if a.action == "create":
        store.save_playlist(a.name, [os.path.abspath(p) for p in a.files], a.order, a.interval, a.fit)
    elif a.action == "start":
        if a.name not in pls:
            print("no playlist named %r" % a.name)
            return 1
        store.start_playlist(a.name)
        print("started; the sparekey service uploads the first GIF within a few seconds")
    elif a.action == "stop":
        store.stop_playlist()
    elif a.action == "delete":
        store.delete_playlist(a.name)
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
    up.add_argument("--max-frames", type=int, default=P.MAX_FRAMES)
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
    li.add_argument("--mix", action="store_true", help="mixed colours instead of one colour")
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

    pl = sub.add_parser("playlist", help="manage GIF playlists")
    pl.add_argument("action", choices=["list", "create", "start", "stop", "delete"])
    pl.add_argument("name", nargs="?")
    pl.add_argument("files", nargs="*")
    pl.add_argument("--order", choices=["loop", "shuffle"], default="loop")
    pl.add_argument("--interval", type=int, default=store.DEFAULT_INTERVAL, help="minutes between GIFs")
    pl.add_argument("--fit", choices=[f for f, _ in media.FITS], default="cover")
    pl.set_defaults(func=cmd_playlist)

    sub.add_parser("service", help="run the playlist/clock service (used by systemd)").set_defaults(func=cmd_service)
    g = sub.add_parser("gui", help="open the app")
    g.add_argument("--page", choices=["screen", "playlists", "lighting", "keys", "macros", "settings"])
    g.set_defaults(func=cmd_gui)

    a = ap.parse_args(argv)
    if not a.cmd:
        a = ap.parse_args(["gui"] + list(argv or []))
    try:
        return a.func(a) or 0
    except (DeviceError, media.MediaError, ValueError, OSError) as e:
        print("error:", e, file=sys.stderr)
        return 1
