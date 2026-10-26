"""Typed views over the keyboard's profile, lighting and per-key colour blocks."""

from . import protocol as P

EFFECTS = [  # (id, name, has_speed, has_brightness, has_colour)
    (1, "Static", False, True, True), (2, "Breathing", True, True, True), (3, "Rainbow", True, True, False),
    (4, "Flash away", True, True, True), (5, "Raindrops", True, True, True),
    (6, "Rainbow wheel", True, True, False), (7, "Ripple shining", True, True, True),
    (8, "Stars twinkle", True, True, True), (9, "Shadow disappear", True, True, True),
    (10, "Retro snake", True, True, True), (11, "Neon stream", True, True, True),
    (12, "Reaction", True, True, True), (13, "Sine wave", True, True, True),
    (14, "Side scan", True, True, True), (15, "Rotating windmill", True, True, True),
    (16, "Colourful waterfall", True, True, False), (17, "Blossoming", True, True, True),
    (18, "Custom (per key)", False, False, False), (0, "Off", False, False, False),
]
EFFECT_IDS = {e[0]: e for e in EFFECTS}
CUSTOM = 18

# profile byte offsets (the full layout is in spec/PROTOCOL.md)
F_BRIGHTNESS, F_SPEED = 6, 7
F_MODE_SELECTION, F_MODE, F_WINLOCK, F_WASD, F_SLEEP = 9, 10, 15, 17, 24
LED_PARAM_BASE = 56
MIX = 7                      # colour index meaning "mix colours"
BRIGHTNESS_LEVELS = [0, 4, 8, 12, 16, 20]   # hardware values for UI levels 0..5
SPEED_MAX = 4
SLEEP_STEP_S = 30


class Profile:
    def __init__(self, buf):
        assert len(buf) == P.PROFILE_LEN
        self.buf = bytearray(buf)

    def __bytes__(self):
        return bytes(self.buf)

    @property
    def effect(self):
        return self.buf[F_MODE]

    @effect.setter
    def effect(self, value):
        self.buf[F_MODE] = value
        self.buf[F_MODE_SELECTION] = 1 if value == CUSTOM else 0

    def led_param(self, effect=None):
        e = self.effect if effect is None else effect
        if e > 17:
            return {"brightness": self.buf[F_BRIGHTNESS], "speed": self.buf[F_SPEED], "mix": False}
        o = LED_PARAM_BASE + e * 2
        return {"brightness": self.buf[o], "speed": self.buf[o + 1] >> 4, "mix": (self.buf[o + 1] & 15) == MIX}

    def set_led_param(self, effect=None, brightness=None, speed=None, mix=None):
        e = self.effect if effect is None else effect
        if e > 17:
            return
        o = LED_PARAM_BASE + e * 2
        if brightness is not None:
            self.buf[o] = max(0, min(20, brightness))
        sp, col = self.buf[o + 1] >> 4, self.buf[o + 1] & 15
        if speed is not None:
            sp = max(0, min(SPEED_MAX, speed))
        if mix is not None:
            col = MIX if mix else 0
        self.buf[o + 1] = (sp << 4) | col

    @staticmethod
    def level_for(brightness):
        return min(range(len(BRIGHTNESS_LEVELS)), key=lambda i: abs(BRIGHTNESS_LEVELS[i] - brightness))

    @property
    def sleep_minutes(self):
        return self.buf[F_SLEEP] * SLEEP_STEP_S / 60

    @sleep_minutes.setter
    def sleep_minutes(self, minutes):
        self.buf[F_SLEEP] = max(0, min(255, round(minutes * 60 / SLEEP_STEP_S)))

    @property
    def win_lock(self):
        return bool(self.buf[F_WINLOCK])

    @win_lock.setter
    def win_lock(self, on):
        self.buf[F_WINLOCK] = 1 if on else 0

    @property
    def wasd_swap(self):
        return bool(self.buf[F_WASD])

    @wasd_swap.setter
    def wasd_swap(self, on):
        self.buf[F_WASD] = 1 if on else 0


class LedEffects:
    """Per-effect RGB colour (first 3 of every 21 bytes)."""

    def __init__(self, buf):
        assert len(buf) == P.LED_EFFECT_LEN
        self.buf = bytearray(buf)

    def __bytes__(self):
        return bytes(self.buf)

    def color(self, effect):
        o = effect * 21
        return tuple(self.buf[o:o + 3]) if o + 3 <= len(self.buf) else (255, 255, 255)

    def set_color(self, effect, rgb):
        o = effect * 21
        if o + 3 <= len(self.buf):
            self.buf[o:o + 3] = bytes(rgb)


class KeyColors:
    """Per-key colours for the Custom effect, stored planar (R[126] G[126] B[126])."""

    def __init__(self, buf):
        assert len(buf) == P.LED_COLORS_LEN
        self.buf = bytearray(buf)

    def __bytes__(self):
        return bytes(self.buf)

    def get(self, index):
        return (self.buf[index], self.buf[index + P.KEYS], self.buf[index + 2 * P.KEYS])

    def set(self, index, rgb):
        self.buf[index], self.buf[index + P.KEYS], self.buf[index + 2 * P.KEYS] = rgb
