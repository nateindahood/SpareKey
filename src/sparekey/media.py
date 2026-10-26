"""Images and GIFs -> screen frames (320x172 RGB565)."""

from . import protocol as P

FITS = [("cover", "Fill (crop)"), ("contain", "Fit (letterbox)"), ("stretch", "Stretch")]
SECONDS_PER_FRAME = 12.7     # measured: 215 chunks per frame, ~59 ms each


class MediaError(Exception):
    pass


def load(path, fit="cover", max_frames=P.MAX_FRAMES, delay=None):
    """Returns (list of PIL RGB images, ms each is shown). Fast GIFs are thinned out to keep their speed."""
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
    idx, ms = P.pick_frames(durations, max_frames)
    frames = [frames[i] for i in idx]
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


def frame_count(path, max_frames=P.MAX_FRAMES):
    """Frames that will be sent (after thinning out fast GIFs)."""
    try:
        from PIL import Image, ImageSequence
        with Image.open(path) as im:
            durations = [fr.info.get("duration", 100) or 100 for fr in ImageSequence.Iterator(im)]
        return len(P.pick_frames(durations, max_frames)[0])
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
