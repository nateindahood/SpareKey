"""Background service: keeps the keyboard clock right (sent at login and every 10 minutes)."""

import signal
import sys
import time

from .device import Device, DeviceError

CLOCK_EVERY = 600
POLL = 15


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log("SpareKey clock service started")
    last_clock = 0
    while True:
        now = time.time()
        if now - last_clock >= CLOCK_EVERY:
            try:
                with Device(wait=False) as d:   # never wait behind an upload from the app
                    d.sync_clock()
                last_clock = now
            except DeviceError as e:
                if "busy" not in str(e) and "not found" not in str(e):
                    log("device:", e)
        time.sleep(POLL)
