"""Settings and the media library folder (plain JSON in your home)."""

import json
import os
import shutil
import subprocess
import tempfile

CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "sparekey")
CONFIG = os.path.join(CONFIG_DIR, "config.json")
BACKUP_DIR = os.path.join(CONFIG_DIR, "backups")
EXTENSIONS = (".gif", ".png", ".jpg", ".jpeg", ".webp", ".bmp")


def _move_old_dirs():
    """Settings and backups from the pre-release name "keyframe" move over once."""
    for new in (CONFIG_DIR,):
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
