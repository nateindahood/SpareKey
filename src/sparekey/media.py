"""Images and GIFs -> screen frames (320x172 RGB565)."""

from . import protocol as P

FITS = [("cover", "Fill (crop)"), ("contain", "Fit (letterbox)"), ("stretch", "Stretch")]
SECONDS_PER_FRAME = 12.7     # measured: 215 chunks per frame, ~59 ms each


class MediaError(Exception):
    pass


def load(path, fit="cover", max_frames=P.MAX_FRAMES, delay=None):
    """Returns (list of PIL RGB images, ms per frame)."""
    try:
        from PIL import Image, ImageOps, ImageSequence
    except ImportError:
        raise MediaError("Pillow is needed for images (sudo apt install python3-pil)")
    try:
        im = Image.open(path)
        frames, durations = [], []
        for fr in ImageSequence.Iterator(im):
            durations.append(fr.info.get("duration", 100) or 100)
            frames.append(fr.convert("RGBA"))
    except (OSError, ValueError) as e:
        raise MediaError("Couldn't read %s: %s" % (path, e))
    if len(frames) > max_frames:   # keep playback speed: merge the skipped frames' time
        step = len(frames) / max_frames
        idx = [int(i * step) for i in range(max_frames)]
        durations = [sum(durations[idx[i]:idx[i + 1] if i + 1 < len(idx) else len(durations)])
                     for i in range(len(idx))]
        frames = [frames[i] for i in idx]
    ms = delay or round(sum(durations) / len(durations))
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


def frame_count(path, max_frames=P.MAX_FRAMES):
    try:
        from PIL import Image
        with Image.open(path) as im:
            return min(max_frames, getattr(im, "n_frames", 1))
    except Exception:
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
