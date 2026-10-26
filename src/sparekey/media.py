"""Images and GIFs -> screen frames (320x172 RGB565)."""

import os

from . import protocol as P

FITS = [("cover", "Fill (crop)"), ("contain", "Fit (letterbox)"), ("stretch", "Stretch")]
SECONDS_PER_FRAME = 12.7     # measured: 215 chunks per frame, ~59 ms each


class MediaError(Exception):
    pass


MAX_SOURCE_FRAMES = 5000


def _durations(im):
    """Each frame's display time, without keeping any frame in memory."""
    durations = []
    for n in range(getattr(im, "n_frames", 1)):
        if n >= MAX_SOURCE_FRAMES:
            raise MediaError("too many frames (more than %d)" % MAX_SOURCE_FRAMES)
        im.seek(n)
        durations.append(im.info.get("duration", 100) or 100)
    return durations


def _open(path):
    from PIL import Image
    try:
        return Image.open(path)
    except Image.DecompressionBombError:
        raise MediaError("%s is too large to load" % path)
    except (OSError, ValueError) as e:
        raise MediaError("Couldn't read %s: %s" % (path, e))


def load(path, fit="cover", max_frames=P.MAX_FRAMES, delay=None):
    """Returns (list of PIL RGB images, ms each is shown). Fast GIFs are thinned out to keep their speed;
    only the frames that will be sent are decoded into memory."""
    try:
        from PIL import Image, ImageOps
    except ImportError:
        raise MediaError("Pillow is needed for images (sudo apt install python3-pil)")
    max_frames = max(1, min(max_frames, P.MAX_FRAMES))
    try:
        with _open(path) as im:
            idx, ms = P.pick_frames(_durations(im), max_frames)
            picked = {}
            for n in sorted(set(idx)):
                im.seek(n)
                picked[n] = im.convert("RGBA")
    except Image.DecompressionBombError:
        raise MediaError("%s is too large to load" % path)
    except (OSError, ValueError, EOFError) as e:
        raise MediaError("Couldn't read %s: %s" % (path, e))
    frames = [picked[n] for n in idx]
    if delay:
        ms = max(P.DRAW_MS, delay)
    size = (P.SCREEN_W, P.SCREEN_H)
    out = []
    for fr in frames:
        if fit == "cover":
            fr = ImageOps.fit(fr, size, Image.LANCZOS)
        elif fit == "contain":
            fr = ImageOps.pad(fr, size, Image.LANCZOS, color=(0, 0, 0, 255))
        else:
            fr = fr.resize(size, Image.LANCZOS)
        bg = Image.new("RGBA", size, (0, 0, 0, 255))
        bg.alpha_composite(fr)
        out.append(bg.convert("RGB"))
    return out, max(10, min(65535, ms))


_count_cache = {}


def frame_count(path, max_frames=P.MAX_FRAMES):
    """Frames that will be sent (after thinning out fast GIFs). Cached by file size and date."""
    try:
        st = os.stat(path)
        key = (path, st.st_size, st.st_mtime_ns, max_frames)
        if key not in _count_cache:
            with _open(path) as im:
                _count_cache[key] = len(P.pick_frames(_durations(im), max_frames)[0])
        return _count_cache[key]
    except (MediaError, OSError):
        return 1


def encode(images):
    return [P.rgb565be(im.tobytes()) for im in images]


def estimate_seconds(frames):
    return frames * SECONDS_PER_FRAME


def save_preview(images, ms, out):
    if len(images) == 1:
        images[0].save(out)
    else:
        images[0].save(out, save_all=True, append_images=images[1:], duration=ms, loop=0)
    return out
