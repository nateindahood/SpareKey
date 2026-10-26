"""Talking to the keyboard over Linux hidraw."""

import fcntl
import glob
import os
import select
import time

from . import protocol as P

VID = 0x258A
PIDS = {0x01AF: "RK S98"}
LOCK_PATH = os.path.join(os.environ.get("XDG_RUNTIME_DIR")
                         or os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "sparekey"),
                         "sparekey-device.lock")
PACKET_GAP = 0.020         # the keyboard paces itself through its acks
ACK_TIMEOUT = 2.0


class DeviceError(Exception):
    pass


def _ioc(nr, size):
    return (3 << 30) | (size << 16) | (ord("H") << 8) | nr


def find_devices():
    """[(hidraw path, pid)] of vendor interfaces (the ones carrying report 9)."""
    found = []
    for node in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(os.path.join(node, "device/uevent")) as f:
                uevent = f.read()
            with open(os.path.join(node, "device/report_descriptor"), "rb") as f:
                desc = f.read()
        except OSError:
            continue
        for pid in PIDS:
            if "HID_ID=0003:0000%04X:0000%04X" % (VID, pid) in uevent and b"\x85\x09" in desc:
                found.append(("/dev/" + os.path.basename(node), pid))
    return found


class Device:
    """Use as a context manager; holds a lock so the GUI and the clock service never interleave."""

    def __init__(self, path=None, verbose=False, wait=True):
        devs = find_devices()
        if path is None:
            if not devs:
                raise DeviceError("Keyboard not found. Plug in the USB cable, then choose USB in the keyboard screen's settings menu.")
            path, self.pid = devs[0]
        else:
            self.pid = dict(devs).get(path, 0x01AF)
        self.path, self.verbose, self.wait = path, verbose, wait
        self.fd = self.lock = None

    @property
    def model(self):
        return PIDS.get(self.pid, "RK keyboard")

    def __enter__(self):
        os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
        self.lock = open(LOCK_PATH, "a")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | (0 if self.wait else fcntl.LOCK_NB))
        except BlockingIOError:
            self.lock.close()
            raise DeviceError("The keyboard is busy (an upload is running).")
        try:
            self.fd = os.open(self.path, os.O_RDWR | os.O_NONBLOCK)
        except PermissionError:
            self.close()
            raise DeviceError("No permission to open %s. Install the udev rule: ./install.sh" % self.path)
        except OSError as e:
            self.close()
            raise DeviceError("Couldn't open %s: %s" % (self.path, e.strerror))
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        if self.lock:
            self.lock.close()
            self.lock = None

    # ------------------------------------------------------------ transport --

    def _set_feature(self, pkt):
        buf = bytearray(P.REPORT_LEN + 1)
        buf[0] = P.REPORT_ID
        buf[1:1 + len(pkt)] = pkt
        try:
            fcntl.ioctl(self.fd, _ioc(0x06, len(buf)), buf)
        except OSError as e:
            raise DeviceError("Write to the keyboard failed (%s). Was it unplugged?" % e.strerror)
        if self.verbose:
            print("SET", bytes(buf[:16]).hex(" "))

    def _get_feature(self):
        buf = bytearray(P.REPORT_LEN + 1)
        buf[0] = P.REPORT_ID
        try:
            n = fcntl.ioctl(self.fd, _ioc(0x07, len(buf)), buf)
        except OSError as e:
            raise DeviceError("Read from the keyboard failed (%s)." % e.strerror)
        if self.verbose:
            print("GET", n, bytes(buf[:24]).hex(" "))
        # n = bytes the keyboard actually sent, report id included; the rest of buf is padding
        return bytes(buf[1:n])

    def _drain(self):
        while True:
            try:
                os.read(self.fd, 64)
            except (BlockingIOError, OSError):
                return

    def _wait_ack(self, timeout=ACK_TIMEOUT):
        end = time.monotonic() + timeout
        while (left := end - time.monotonic()) > 0:
            r, _, _ = select.select([self.fd], [], [], left)
            if not r:
                break
            try:
                rep = os.read(self.fd, 64)
            except BlockingIOError:
                continue
            ok = P.parse_ack(rep)
            # only the keyboard's replies (report 9): other reports on this interface carry key presses
            if self.verbose and rep[:1] == bytes([P.REPORT_ID]):
                print("IN ", rep.hex(" "))
            if ok is not None:
                return ok
        return None

    def query(self, pkt, length, attempts=6):
        """Get command. The keyboard sometimes answers with a status packet (`0a 06 …`) instead of the
        data, or a bare header, so only accept real answers (P.is_answer), and ask again otherwise."""
        for _ in range(attempts):
            self._drain()
            self._set_feature(pkt)
            data = self._get_feature()
            if P.is_answer(data, pkt, length):
                return P.parse_get(data, length)
            time.sleep(0.01)
        raise DeviceError("The keyboard kept answering out of turn (cmd %d). Try again, or replug it." % pkt[0])

    def send(self, pkt):
        """Set command, then wait for the keyboard's ack so commands never overlap.
        Settings commands are acked with status 0 (`06 00 02`); only screen chunks use status 1 for "ok, next"."""
        self._drain()
        self._set_feature(pkt)
        if self._wait_ack() is None:
            raise DeviceError("The keyboard didn't answer (cmd %d). Is USB selected in the keyboard screen's settings?" % pkt[0])

    # ------------------------------------------------------------ commands --

    def info(self):
        return P.parse_info(bytes(7) + self.query(P.get_info(), 10) + bytes(519))

    def profile(self, n=0):
        return self.query(P.get_profile(n), P.PROFILE_LEN)

    def set_profile(self, buf, n=0):
        self.send(P.set_profile(bytes(buf), n))

    def led_effects(self, n=0):
        return self.query(P.get_led_effect(n), P.LED_EFFECT_LEN)

    def set_led_effects(self, buf, n=0):
        self.send(P.set_led_effect(bytes(buf), n))

    def key_colors(self, n=0):
        return self.query(P.get_led_colors(n), P.LED_COLORS_LEN)

    def set_key_colors(self, buf, n=0):
        self.send(P.set_led_colors(bytes(buf), n))

    def keymatrix(self, table, layer):
        return P.parse_keymatrix(self.query(P.get_keymatrix(table, layer), P.KEYMATRIX_LEN))

    def set_keymatrix(self, table, layer, codes):
        if layer == 0 and sum(1 for c in codes if c) < 80:
            # a base layer is ~100 real keys; anything emptier would disable typing
            raise DeviceError("Refusing to write a base layer with only %d keys set." % sum(1 for c in codes if c))
        self.send(P.set_keymatrix(table, layer, codes))

    def macros_blob(self):
        return b"".join(self.query(P.get_macros(i), P.MACRO_CHUNK) for i in range(P.MACRO_LEN // P.MACRO_CHUNK))

    def set_macros_blob(self, blob):
        for pkt in P.set_macros(blob):
            self.send(pkt)

    def factory_reset(self):
        self.send(P.factory_reset())

    def sync_clock(self, t=None):
        t = time.localtime() if t is None else t
        self.send(P.sysinfo(t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec, (t.tm_wday + 1) % 7))

    def upload(self, frames, delay_ms, progress=None, cancel=None, gap=PACKET_GAP):
        """frames: RGB565BE byte strings (P.FRAME_BYTES each). progress(done, total)."""
        if not 1 <= len(frames) <= P.MAX_FRAMES:
            # the S98 has room for 60 frames; sending more could write past the animation's flash area
            raise DeviceError("between 1 and %d frames are needed" % P.MAX_FRAMES)
        dev_delay = P.frame_delay(delay_ms)
        self._drain()
        self._set_feature(P.tft_ctrl(P.TFT_START, len(frames), dev_delay))
        self._wait_ack()
        last = time.monotonic()
        total = sum(-(-len(f) // P.TFT_CHUNK) for f in frames)
        done = 0
        for fi, buf in enumerate(frames):
            for ci in range(-(-len(buf) // P.TFT_CHUNK)):
                if cancel and cancel():
                    self._set_feature(P.tft_ctrl(P.TFT_ABORT))
                    raise DeviceError("Upload canceled.")
                pkt = P.tft_chunk(fi, ci, buf[ci * P.TFT_CHUNK:(ci + 1) * P.TFT_CHUNK])
                for _attempt in range(6):
                    pause = gap - (time.monotonic() - last)
                    if pause > 0:
                        time.sleep(pause)
                    self._set_feature(pkt)
                    last = time.monotonic()
                    if self._wait_ack():
                        break
                else:
                    self._set_feature(P.tft_ctrl(P.TFT_ABORT))
                    raise DeviceError("The keyboard stopped responding during the upload (frame %d)." % (fi + 1))
                done += 1
                if progress:
                    progress(done, total)
        time.sleep(max(0.0, gap - (time.monotonic() - last)))
        self._set_feature(P.tft_ctrl(P.TFT_FINISH, len(frames), dev_delay))
