"""Background service: rotates the active playlist and keeps the keyboard clock right."""

import os
import signal
import sys
import time

from . import media, store
from .device import Device, DeviceError

CLOCK_EVERY = 600
POLL = 15


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def upload_file(path, fit="cover", progress=None, cancel=None):
    images, ms = media.load(path, fit)
    frames = media.encode(images)
    with Device() as d:
        d.upload(frames, ms, progress=progress, cancel=cancel)
        d.sync_clock()
    return len(frames)


def run_once(st, now):
    """One scheduling step; returns True when it uploaded something."""
    name = st.get("active")
    pl = store.playlists().get(name) if name else None
    if not pl or st.get("next_at") is None or now < st["next_at"]:
        return False
    item = store.next_item(pl, st)
    if item is None:
        log("playlist %r has no files left; stopping" % name)
        st.update({"active": None, "next_at": None})
        store.save_state(st)
        return False
    st.update({"uploading": item, "progress": 0.0})
    store.save_state(st)
    log("uploading", os.path.basename(item))
    last = [0.0]

    def progress(done, total):
        frac = done / total
        if frac - last[0] >= 0.02:     # don't rewrite the state file for every chunk
            last[0] = frac
            cur = store.load_state()
            if cur.get("active") != name:
                raise DeviceError("playlist stopped")
            cur.update({"progress": frac})
            store.save_state(cur)

    try:
        upload_file(item, pl.get("fit", "cover"), progress)
        err = None
    except (DeviceError, media.MediaError) as e:
        err = str(e)
    cur = store.load_state()
    if cur.get("active") == name:
        interval = max(store.MIN_INTERVAL, pl.get("interval", store.DEFAULT_INTERVAL)) * 60
        st.update({"uploading": None, "progress": None, "error": err, "last_upload": time.time(),
                   "next_at": time.time() + (120 if err else interval)})
        store.save_state(st)
    log("done" if not err else "failed: %s" % err)
    return err is None


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log("sparekey service started")
    last_clock = 0
    while True:
        now = time.time()
        st = store.load_state()
        try:
            if run_once(st, now):
                last_clock = time.time()
            elif now - last_clock >= CLOCK_EVERY:
                with Device(wait=False) as d:
                    d.sync_clock()
                last_clock = now
        except DeviceError as e:
            if "busy" not in str(e):
                log("device:", e)
        time.sleep(POLL)
