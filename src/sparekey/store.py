"""Settings, the media library folder and playlists (all plain JSON in your home)."""

import json
import os
import random
import shutil
import subprocess
import tempfile
import time

CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "sparekey")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "sparekey")
CONFIG = os.path.join(CONFIG_DIR, "config.json")
STATE = os.path.join(STATE_DIR, "playlist-state.json")
BACKUP_DIR = os.path.join(CONFIG_DIR, "backups")
EXTENSIONS = (".gif", ".png", ".jpg", ".jpeg", ".webp", ".bmp")
MIN_INTERVAL = 15
DEFAULT_INTERVAL = 60


def _move_old_dirs():
    """Settings, backups and playlists from the pre-release name "keyframe" move over once."""
    for new in (CONFIG_DIR, STATE_DIR):
        old = os.path.join(os.path.dirname(new), "keyframe")
        if os.path.isdir(old) and not os.path.exists(new):
            try:
                shutil.move(old, new)
            except OSError:
                pass


_move_old_dirs()


def _read(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def load_config():
    return _read(CONFIG, {})


def save_config(cfg):
    _write(CONFIG, cfg)


def update_config(**changes):
    cfg = load_config()
    cfg.update(changes)
    save_config(cfg)
    return cfg


def load_state():
    return _read(STATE, {})


def save_state(state):
    _write(STATE, state)


# ------------------------------------------------------------------ library --

def default_library():
    pictures = None
    try:
        r = subprocess.run(["xdg-user-dir", "PICTURES"], capture_output=True, text=True, timeout=3)
        pictures = r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        pass
    if not pictures or pictures == os.path.expanduser("~"):
        pictures = os.path.expanduser("~/Pictures")
    return os.path.join(pictures, "sparekey")


def library_dir(cfg=None):
    cfg = load_config() if cfg is None else cfg
    path = cfg.get("library_dir") or default_library()
    os.makedirs(path, exist_ok=True)
    return path


def is_media(path):
    return path.lower().endswith(EXTENSIONS) and not os.path.basename(path).startswith(".")


def list_library(folder=None):
    folder = folder or library_dir()
    try:
        names = sorted(os.listdir(folder), key=str.lower)
    except OSError:
        return []
    return [os.path.join(folder, n) for n in names if is_media(n) and os.path.isfile(os.path.join(folder, n))]


def add_to_library(src, folder=None):
    folder = folder or library_dir()
    if not is_media(src):
        raise ValueError("%s isn't a GIF or image" % os.path.basename(src))
    stem, ext = os.path.splitext(os.path.basename(src))
    dest = os.path.join(folder, stem + ext)
    if os.path.abspath(src) == os.path.abspath(dest):
        return dest
    n = 2
    while os.path.exists(dest):
        dest = os.path.join(folder, "%s (%d)%s" % (stem, n, ext))
        n += 1
    shutil.copy2(src, dest)
    return dest


# ---------------------------------------------------------------- playlists --

def playlists(cfg=None):
    cfg = load_config() if cfg is None else cfg
    return cfg.get("playlists", {})


def save_playlist(name, items, order="loop", interval=DEFAULT_INTERVAL, fit="cover"):
    cfg = load_config()
    pls = cfg.setdefault("playlists", {})
    pls[name] = {"items": list(items), "order": order, "interval": max(MIN_INTERVAL, int(interval)), "fit": fit}
    save_config(cfg)
    return pls[name]


def delete_playlist(name):
    cfg = load_config()
    cfg.get("playlists", {}).pop(name, None)
    save_config(cfg)
    st = load_state()
    if st.get("active") == name:
        stop_playlist()


def rename_playlist(old, new):
    cfg = load_config()
    pls = cfg.get("playlists", {})
    if old in pls and new and new not in pls:
        pls[new] = pls.pop(old)
        save_config(cfg)
        st = load_state()
        if st.get("active") == old:
            st["active"] = new
            save_state(st)


def start_playlist(name, now=True):
    st = load_state()
    st.update({"active": name, "position": -1, "bag": [], "next_at": 0 if now else time.time()})
    save_state(st)


def stop_playlist():
    st = load_state()
    st.update({"active": None, "next_at": None})
    save_state(st)


def next_item(pl, st, rng=random):
    """Pick the next file and update `st` in place. Missing files are skipped."""
    items = [p for p in pl.get("items", []) if os.path.exists(p)]
    if not items:
        return None
    if pl.get("order") == "shuffle":
        bag = [p for p in st.get("bag", []) if p in items]
        if not bag:
            bag = items[:]
            rng.shuffle(bag)
            if len(bag) > 1 and bag[0] == st.get("current"):
                bag.append(bag.pop(0))   # don't play the same GIF twice in a row
        item = bag.pop(0)
        st["bag"] = bag
    else:
        pos = (st.get("position", -1) + 1) % len(items)
        if items[pos] == st.get("current") and len(items) > 1 and st.get("position", -1) == -1:
            pos = (pos + 1) % len(items)
        st["position"] = pos
        item = items[pos]
    st["current"] = item
    return item
