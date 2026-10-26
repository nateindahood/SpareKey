"""sparekey GTK 3 interface: `sparekey gui`."""

import hashlib
import os
import subprocess
import threading
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, Pango, PangoCairo  # noqa: E402

from . import __version__, cli, keymap, media, store  # noqa: E402
from . import protocol as P  # noqa: E402
from .device import Device, DeviceError, find_devices  # noqa: E402
from .hid_keys import EVDEV_TO_HID  # noqa: E402
from .settings import (BRIGHTNESS_LEVELS, CUSTOM, EFFECT_IDS, EFFECT_INFO, EFFECTS, KeyColors,  # noqa: E402
                       LedEffects, Profile)

SERVICE = "sparekey.service"
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "sparekey", "previews")
PREVIEW_SCALE = 1.4
PREVIEW_VERSION = "2-%d" % P.DRAW_MS   # bump when frame picking changes, so old previews aren't reused
MAX_MACROS = 16


class Worker:
    """Runs device operations one at a time off the GTK thread."""

    def __init__(self, window):
        self.window = window
        self.lock = threading.Lock()

    def run(self, fn, done=None, busy_text=None):
        if busy_text:
            self.window.set_busy(busy_text)

        def target():
            with self.lock:
                try:
                    result, error = fn(), None
                except (DeviceError, media.MediaError, ValueError, OSError) as e:
                    result, error = None, str(e)
                except Exception as e:   # anything unexpected still ends the operation with a message
                    result, error = None, "Unexpected error (%s): %s" % (type(e).__name__, e)
            GLib.idle_add(self._finish, done, result, error)

        threading.Thread(target=target, daemon=True).start()

    def _finish(self, done, result, error):
        self.window.set_busy(None)
        if error:
            self.window.show_error(error)
        elif done:
            done(result)
        return False


def _combo(options, active=None):
    c = Gtk.ComboBoxText()
    for oid, label in options:
        c.append(str(oid), label)
    c.set_active_id(str(active if active is not None else options[0][0]))
    return c


def _row(label_text, widget, hint=None):
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
    lab = Gtk.Label(label=label_text, xalign=0)
    lab.set_size_request(170, -1)
    box.pack_start(lab, False, False, 0)
    box.pack_start(widget, widget.get_halign() == Gtk.Align.FILL, True, 0)
    if hint:
        h = Gtk.Label(label=hint, xalign=0)
        h.get_style_context().add_class("dim-label")
        box.pack_start(h, False, False, 0)
    return box


def _heading(title, top=0):
    lab = Gtk.Label(xalign=0)
    lab.set_markup("<b>%s</b>" % GLib.markup_escape_text(title))
    lab.set_margin_top(top)
    return lab


def _dim(text, **kw):
    lab = Gtk.Label(label=text, xalign=0, wrap=True, **kw)
    lab.get_style_context().add_class("dim-label")
    return lab


def _try_box():
    """A scratch area to type in and see lighting or key changes on the keyboard. Nothing is saved."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.pack_start(_heading("Try it out", 8), False, False, 0)
    box.pack_start(_dim("Type here to try your changes on the keyboard. This isn't saved."), False, False, 0)
    view = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR, left_margin=6, right_margin=6, top_margin=6,
                        bottom_margin=6)
    sc = Gtk.ScrolledWindow(shadow_type=Gtk.ShadowType.IN)
    sc.set_size_request(-1, 90)
    sc.add(view)
    box.pack_start(sc, False, False, 0)
    return box


def _button(label, tip, cb, icon=None, suggested=False):
    b = Gtk.Button.new_from_icon_name(icon, Gtk.IconSize.BUTTON) if icon else Gtk.Button(label=label)
    if tip:
        b.set_tooltip_text(tip)
    b.connect("clicked", lambda *_: cb())
    if suggested:
        b.get_style_context().add_class("suggested-action")
    b.set_halign(Gtk.Align.START)
    return b


def _rgba(rgb):
    return Gdk.RGBA(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, 1)


def _rgb(rgba):
    return tuple(int(round(c * 255)) for c in (rgba.red, rgba.green, rgba.blue))


def _thumb(path, w=64, h=36):
    """Small first-frame image (cached), or None."""
    try:
        st = os.stat(path)
        key = hashlib.sha1(("%s|%d|%d|%dx%d" % (path, st.st_size, int(st.st_mtime), w, h)).encode()).hexdigest()[:16]
        out = os.path.join(CACHE_DIR, "thumb-%s.png" % key)
        if not os.path.exists(out):
            from PIL import Image
            os.makedirs(CACHE_DIR, exist_ok=True)
            with Image.open(path) as im:
                im = im.convert("RGB")
                im.thumbnail((w, h))
                im.save(out)
        return GdkPixbuf.Pixbuf.new_from_file(out)
    except Exception:
        return None


def _minutes(seconds):
    m = max(0, int(round(seconds / 60)))
    return "%d min" % m if m < 60 else "%d h %02d min" % (m // 60, m % 60)


SHORT = {"NumLock": "Num", "Backspace": "Bksp", "CapsLock": "Caps", "Delete": "Del", "Space": "",
         "Down": "↓", "Up": "↑", "Left": "←", "Right": "→", "LShift": "Shift", "RShift": "Shift",
         "LCtrl": "Ctrl", "RCtrl": "Ctrl", "LAlt": "Alt", "RAlt": "Alt", "LWin": "Win"}


def short_label(label):
    if label in SHORT:
        return SHORT[label]
    if label.startswith("Num") and len(label) > 3:
        return label[3:].strip()
    return label


class KeyboardView(Gtk.DrawingArea):
    """The S98 drawn from its key rectangles; click a key to select it."""

    def __init__(self, on_click):
        super().__init__()
        self.keys = [dict(k, label=short_label(k["label"])) for k in keymap.LAYOUT["keys"] if k["w"] > 0]
        self.x0 = min(k["x"] for k in self.keys)
        self.y0 = min(k["y"] for k in self.keys)
        self.x1 = max(k["x"] + k["w"] for k in self.keys)
        self.y1 = max(k["y"] + k["h"] for k in self.keys)
        self.labels, self.colors, self.selected, self.marked = {}, {}, set(), set()
        self.on_click = on_click
        self.aspect = (self.y1 - self.y0 + 20) / (self.x1 - self.x0 + 20)
        self.set_size_request(760, int(760 * self.aspect))
        self.set_hexpand(True)
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.connect("draw", self._draw)
        self.connect("button-press-event", self._press)

    def _geometry(self):
        w, h = self.get_allocated_width(), self.get_allocated_height()
        s = min(w / (self.x1 - self.x0 + 20), h / (self.y1 - self.y0 + 20))
        ox = (w - (self.x1 - self.x0) * s) / 2
        oy = (h - (self.y1 - self.y0) * s) / 2
        return s, ox, oy

    def _rect(self, k, geo):
        s, ox, oy = geo
        return ox + (k["x"] - self.x0) * s, oy + (k["y"] - self.y0) * s, k["w"] * s, k["h"] * s

    def _draw(self, _w, cr):
        geo = self._geometry()
        style = self.get_style_context()
        fg = style.get_color(Gtk.StateFlags.NORMAL)
        for k in self.keys:
            x, y, w, h = self._rect(k, geo)
            r = min(6, w / 5)
            cr.new_sub_path()
            cr.arc(x + w - r, y + r, r, -1.5708, 0)
            cr.arc(x + w - r, y + h - r, r, 0, 1.5708)
            cr.arc(x + r, y + h - r, r, 1.5708, 3.1416)
            cr.arc(x + r, y + r, r, 3.1416, 4.7124)
            cr.close_path()
            col = self.colors.get(k["index"])
            if col is not None:
                cr.set_source_rgb(col[0] / 255, col[1] / 255, col[2] / 255)
            else:
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.10)
            cr.fill_preserve()
            if k["index"] in self.selected:
                cr.set_source_rgb(0.2, 0.55, 1.0)
                cr.set_line_width(3)
            elif k["index"] in self.marked:
                cr.set_source_rgb(1.0, 0.6, 0.1)
                cr.set_line_width(2)
            else:
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.35)
                cr.set_line_width(1)
            cr.stroke()
            text = self.labels.get(k["index"], k["label"])
            if col is not None:
                lum = 0.3 * col[0] + 0.59 * col[1] + 0.11 * col[2]
                cr.set_source_rgb(*((0, 0, 0) if lum > 140 else (1, 1, 1)))
            else:
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.95)
            layout = PangoCairo.create_layout(cr)
            fd = Pango.FontDescription.from_string("Sans")
            fd.set_absolute_size(max(7, min(13, h / 3.0)) * Pango.SCALE)
            layout.set_font_description(fd)
            layout.set_width(int((w - 4) * Pango.SCALE))
            layout.set_alignment(Pango.Alignment.CENTER)
            layout.set_wrap(Pango.WrapMode.WORD_CHAR)
            layout.set_height(int((h - 4) * Pango.SCALE))
            layout.set_ellipsize(Pango.EllipsizeMode.END)
            layout.set_text(text, -1)
            _ink, logical = layout.get_pixel_extents()
            cr.move_to(x + 2, y + max(2, (h - logical.height) / 2))
            PangoCairo.show_layout(cr, layout)
        return False

    def _press(self, _w, ev):
        geo = self._geometry()
        for k in self.keys:
            x, y, w, h = self._rect(k, geo)
            if x <= ev.x <= x + w and y <= ev.y <= y + h:
                self.on_click(k["index"], ev)
                return True
        return False

    def key_rect(self, index):
        geo = self._geometry()
        for k in self.keys:
            if k["index"] == index:
                x, y, w, h = self._rect(k, geo)
                r = Gdk.Rectangle()
                r.x, r.y, r.width, r.height = int(x), int(y), int(w), int(h)
                return r
        return None


class Window(Gtk.ApplicationWindow):
    def __init__(self, app, page=None):
        super().__init__(application=app, title="SpareKey")
        self.set_default_size(1240, 780)
        self.worker = Worker(self)
        self.kb = None
        self._loading = False
        self.cancel_upload = False
        self.uploading = False
        self.macros = store.load_config().get("macros", [])

        hb = Gtk.HeaderBar(show_close_button=True, title="SpareKey")
        self.set_titlebar(hb)
        self.header = hb
        hb.pack_end(_button(None, "Read everything from the keyboard again", self.refresh, "view-refresh-symbolic"))
        self.spinner = Gtk.Spinner()
        hb.pack_end(self.spinner)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(outer)
        self.infobar = Gtk.InfoBar(message_type=Gtk.MessageType.ERROR, show_close_button=True)
        self.info_label = Gtk.Label(xalign=0, wrap=True)
        self.infobar.get_content_area().add(self.info_label)
        self.infobar.connect("response", lambda bar, _r: bar.hide())
        outer.pack_start(self.infobar, False, False, 0)

        stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        outer.pack_start(Gtk.StackSwitcher(stack=stack, halign=Gtk.Align.CENTER, margin=6), False, False, 0)
        outer.pack_start(stack, True, True, 0)
        stack.add_titled(self._screen_page(), "screen", "Screen")
        stack.add_titled(self._lighting_page(), "lighting", "Lighting")
        stack.add_titled(self._keys_page(), "keys", "Keys")
        stack.add_titled(self._macros_page(), "macros", "Macros")
        stack.add_titled(self._settings_page(), "settings", "Settings")
        self.stack = stack

        self.status = Gtk.Label(xalign=0, margin=8)
        self.status.get_style_context().add_class("dim-label")
        outer.pack_end(self.status, False, False, 0)

        self.drag_dest_set(Gtk.DestDefaults.ALL, [], Gdk.DragAction.COPY)
        self.drag_dest_add_uri_targets()
        self.connect("drag-data-received", self._on_drop)
        self.connect("key-press-event", self._on_key, False)
        self.connect("key-release-event", self._on_key, True)

        self.show_all()
        self.infobar.hide()
        self.progress_box.hide()
        self.custom_box.hide()
        self._watch_library()
        if page:
            stack.set_visible_child_name(page)
        self.refresh()

    # ------------------------------------------------------------ helpers --

    def set_busy(self, text):
        if text:
            self.spinner.start()
            self.status.set_text(text)
        else:
            self.spinner.stop()

    def show_error(self, text):
        self.info_label.set_text(text)
        self.infobar.show()
        self.status.set_text("")

    def run(self, fn, done=None, busy_text=None):
        self.worker.run(fn, done, busy_text)

    @staticmethod
    def _with_dev(fn):
        with Device() as d:
            return fn(d)

    def _change(self, fn, text, done=None):
        """Run a settings change, keeping a copy of the original settings first."""
        def op(d):
            cli.ensure_first_backup(d)
            return fn(d)
        self.run(lambda: self._with_dev(op), done or (lambda _r: self.status.set_text(text.rstrip("…") + " — done.")),
                 text)

    def refresh(self):
        def load():
            if not find_devices():
                raise DeviceError("Keyboard not found. Plug in the USB cable, then choose USB in the keyboard screen's settings menu (USB 258a:01af)")
            with Device() as d:
                return {"model": d.model, "info": d.info(), "profile": Profile(d.profile()),
                        "effects": LedEffects(d.led_effects()),
                        # per-key colors and macros often can't be read; show them empty rather than fail
                        "colors": KeyColors(cli._optional(d.key_colors, bytes(P.LED_COLORS_LEN))),
                        "macros": keymap.decode_macros(cli._optional(d.macros_blob, b""))}

        self.run(load, self._apply_state, "Reading the keyboard…")

    def _apply_state(self, kb):
        self.kb = kb
        self.infobar.hide()
        saved = store.load_config().get("key_colors")
        if not any(kb["colors"].buf) and saved:
            try:   # the keyboard can't report them: use the ones last sent from here
                kb["colors"] = KeyColors(bytes.fromhex(saved))
            except (ValueError, AssertionError):
                pass
        self.header.set_subtitle("%s · firmware %s" % (kb["model"], kb["info"]["firmware"]))
        cfg = store.load_config()
        if "macros" in cfg:
            self.macros = cfg["macros"]
        else:
            self.macros = kb["macros"]
        self._loading = True
        self._load_lighting()
        self._load_settings()
        self._loading = False
        self._fill_macros()
        self._draw_keys()
        self.status.set_text("Connected.")

    # ------------------------------------------------------------- screen --

    def _screen_page(self):
        paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL, margin=12)
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        head = Gtk.Box(spacing=6)
        self.lib_title = _heading("Your library")
        head.pack_start(self.lib_title, True, True, 0)
        for label, tip, cb in (("Add files…", "Copy GIFs or images into your library", self._choose_add),
                               ("Open folder", "Open the library folder", self._open_library),
                               ("Change folder…", "Use a different folder as your library", self._change_library)):
            head.pack_start(_button(label, tip, cb), False, False, 0)
        left.pack_start(head, False, False, 0)
        self.lib_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.lib_list.connect("row-selected", self._library_row_selected)
        hint = Gtk.Label(label="Drop GIFs or images anywhere on this window\n"
                               "(or copy them into the library folder) to keep them here.",
                         justify=Gtk.Justification.CENTER)
        hint.get_style_context().add_class("dim-label")
        hint.show()
        self.lib_list.set_placeholder(hint)
        sc = Gtk.ScrolledWindow(vexpand=True)
        sc.add(self.lib_list)
        left.pack_start(sc, True, True, 0)
        paned.pack1(left, True, False)

        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin_start=12)
        right.pack_start(_heading("How it will look on the keyboard"), False, False, 0)
        frame = Gtk.Frame(halign=Gtk.Align.START)
        self.preview_img = Gtk.Image()
        self.preview_img.set_size_request(int(320 * PREVIEW_SCALE), int(172 * PREVIEW_SCALE))
        frame.add(self.preview_img)
        right.pack_start(frame, False, False, 0)
        self.preview_caption = _dim("Select a file to preview it.", max_width_chars=50)
        right.pack_start(self.preview_caption, False, False, 0)
        bar = Gtk.Box(spacing=8)
        bar.pack_start(Gtk.Label(label="Send as:"), False, False, 0)
        self.fit_combo = _combo(media.FITS, store.load_config().get("fit", "cover"))
        self.fit_combo.connect("changed", lambda *_: (store.update_config(fit=self.fit_combo.get_active_id()),
                                                      self._refresh_preview()))
        bar.pack_start(self.fit_combo, False, False, 0)
        self.send_btn = _button("Send to keyboard", "Upload this file to the keyboard screen", self._send_selected,
                                suggested=True)
        bar.pack_start(self.send_btn, False, False, 0)
        right.pack_start(bar, False, False, 0)

        self.progress_box = Gtk.Box(spacing=8)
        self.progress = Gtk.ProgressBar(show_text=True)
        self.progress_box.pack_start(self.progress, True, True, 0)
        self.progress_box.pack_start(_button("Cancel", "Stop the upload", self._cancel_upload), False, False, 0)
        right.pack_start(self.progress_box, False, False, 0)
        right.pack_start(_dim("The keyboard holds one animation and shows a frame at most every 0.18 s, so fast "
                              "GIFs are sent with fewer frames to keep their speed (at most 60). Sending takes "
                              "about 13 seconds per frame, and the screen is busy while it receives.",
                              max_width_chars=60), False, False, 0)
        paned.pack2(right, False, False)
        return paned

    def _library_path(self):
        return store.library_dir()

    def _watch_library(self):
        if getattr(self, "_lib_monitor", None):
            self._lib_monitor.cancel()
        self._lib_monitor = Gio.File.new_for_path(self._library_path()).monitor_directory(Gio.FileMonitorFlags.NONE,
                                                                                           None)
        self._lib_monitor.connect("changed", lambda *_: self._schedule_library_refresh())
        self.refresh_library()

    def _schedule_library_refresh(self):
        if getattr(self, "_lib_timer", None):
            GLib.source_remove(self._lib_timer)
        self._lib_timer = GLib.timeout_add(500, self._library_timer_fired)

    def _library_timer_fired(self):
        self._lib_timer = None
        self.refresh_library()
        return False

    def refresh_library(self):
        folder = self._library_path()
        self.lib_title.set_markup("<b>Your library</b>  <small>%s</small>" % GLib.markup_escape_text(
            folder.replace(os.path.expanduser("~"), "~", 1)))
        for child in self.lib_list.get_children():
            self.lib_list.remove(child)
        for path in store.list_library(folder):
            self.lib_list.add(self._library_row(path))
        self.lib_list.show_all()

    def _library_row(self, path):
        row = Gtk.ListBoxRow()
        row.path = path
        box = Gtk.Box(spacing=8, margin=4)
        pix = _thumb(path)
        thumb = Gtk.Image.new_from_pixbuf(pix) if pix else Gtk.Image.new_from_icon_name("image-missing",
                                                                                         Gtk.IconSize.BUTTON)
        box.pack_start(thumb, False, False, 0)
        lab = Gtk.Label(label=os.path.basename(path), xalign=0, ellipsize=3)
        lab.set_tooltip_text(path)
        box.pack_start(lab, True, True, 0)
        n = media.frame_count(path)
        info = Gtk.Label(label="%d frame%s · ~%s" % (n, "" if n == 1 else "s", _minutes(media.estimate_seconds(n))))
        info.get_style_context().add_class("dim-label")
        box.pack_start(info, False, False, 0)
        box.pack_start(_button(None, "Send to the keyboard", lambda: self._upload(path), "go-next-symbolic"),
                       False, False, 0)
        box.pack_start(_button(None, "Move to the trash (removes it from your library only)",
                               lambda: self._trash_library_file(path), "user-trash-symbolic"), False, False, 0)
        row.add(box)
        return row

    def _add_files(self, paths):
        added, skipped = 0, []
        for p in paths:
            try:
                store.add_to_library(p)
                added += 1
            except (ValueError, OSError) as e:
                skipped.append("%s (%s)" % (os.path.basename(p), e))
        self.refresh_library()
        if added:
            self.status.set_text("Added %d file(s) to your library." % added)
        if skipped:
            self.show_error("Not added: " + "; ".join(skipped))

    def _on_drop(self, _w, _ctx, _x, _y, data, _info, _time):
        paths = []
        for uri in data.get_uris() or []:
            try:
                path, _host = GLib.filename_from_uri(uri)
            except GLib.Error:
                continue
            if os.path.isdir(path):
                paths += [os.path.join(path, n) for n in sorted(os.listdir(path)) if store.is_media(n)]
            else:
                paths.append(path)
        if paths:
            self._add_files(paths)

    def _choose_add(self):
        dlg = Gtk.FileChooserDialog(title="Add GIFs or images to your library", transient_for=self,
                                    action=Gtk.FileChooserAction.OPEN, select_multiple=True)
        dlg.add_buttons("_Cancel", Gtk.ResponseType.CANCEL, "_Add", Gtk.ResponseType.ACCEPT)
        flt = Gtk.FileFilter()
        flt.set_name("GIFs and images")
        for ext in store.EXTENSIONS:
            flt.add_pattern("*" + ext)
            flt.add_pattern("*" + ext.upper())
        dlg.add_filter(flt)
        resp = dlg.run()
        paths = dlg.get_filenames()
        dlg.destroy()
        if resp == Gtk.ResponseType.ACCEPT and paths:
            self._add_files(paths)

    def _open_library(self):
        Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(self._library_path()).get_uri(), None)

    def _change_library(self):
        dlg = Gtk.FileChooserDialog(title="Choose your library folder", transient_for=self,
                                    action=Gtk.FileChooserAction.SELECT_FOLDER)
        dlg.add_buttons("_Cancel", Gtk.ResponseType.CANCEL, "_Use this folder", Gtk.ResponseType.ACCEPT)
        dlg.set_current_folder(self._library_path())
        resp = dlg.run()
        folder = dlg.get_filename()
        dlg.destroy()
        if resp == Gtk.ResponseType.ACCEPT and folder:
            store.update_config(library_dir=folder)
            self._watch_library()

    def _trash_library_file(self, path):
        try:
            Gio.File.new_for_path(path).trash(None)
        except GLib.Error as e:
            self.show_error("Couldn't move %s to the trash: %s" % (os.path.basename(path), e.message))
        self.refresh_library()

    def _library_row_selected(self, _box, row):
        self.selected_file = row.path if row is not None and hasattr(row, "path") else None
        self._refresh_preview()

    def _refresh_preview(self):
        path = getattr(self, "selected_file", None)
        if not path:
            return
        fit = self.fit_combo.get_active_id()
        self._preview_gen = getattr(self, "_preview_gen", 0) + 1
        gen = self._preview_gen
        self.preview_caption.set_text("%s\nPreparing preview…" % os.path.basename(path))

        def target():
            try:
                st = os.stat(path)
                key = hashlib.sha1(("%s|%d|%d|%s|%s" % (path, st.st_size, int(st.st_mtime), fit,
                                                         PREVIEW_VERSION)).encode()).hexdigest()[:16]
                out = os.path.join(CACHE_DIR, key + ".gif")
                if not os.path.exists(out):
                    os.makedirs(CACHE_DIR, exist_ok=True)
                    images, ms = media.load(path, fit)
                    images = [im.resize((int(320 * PREVIEW_SCALE), int(172 * PREVIEW_SCALE))) for im in images]
                    media.save_preview(images, ms, out + ".tmp.gif")
                    os.replace(out + ".tmp.gif", out)
                n = media.frame_count(path)
                result, err = (out, n), None
            except (media.MediaError, OSError) as e:
                result, err = None, str(e)
            GLib.idle_add(self._preview_ready, gen, path, result, err)

        threading.Thread(target=target, daemon=True).start()

    def _preview_ready(self, gen, path, result, err):
        if gen != self._preview_gen:
            return False
        name = os.path.basename(path)
        if err:
            self.preview_caption.set_text("%s\nNo preview: %s" % (name, err))
            return False
        out, n = result
        try:
            self.preview_img.set_from_animation(GdkPixbuf.PixbufAnimation.new_from_file(out))
        except GLib.Error as e:
            self.preview_caption.set_text("%s\nNo preview: %s" % (name, e.message))
            return False
        self.preview_caption.set_text("%s — %d frame%s, about %s to send" % (
            name, n, "" if n == 1 else "s", _minutes(media.estimate_seconds(n))))
        return False

    def _send_selected(self):
        path = getattr(self, "selected_file", None)
        if not path:
            self.show_error("Pick a file in your library first.")
            return
        self._upload(path)

    def _upload(self, path):
        if self.uploading:
            self.show_error("An upload is already running. Wait for it to finish, or press Cancel.")
            return
        self.uploading = True
        fit = self.fit_combo.get_active_id()
        self.cancel_upload = False
        self.progress.set_fraction(0)
        self.progress.set_text("Converting…")
        self.progress_box.show()
        self.send_btn.set_sensitive(False)
        started = time.monotonic()

        def progress(done, total):
            el = time.monotonic() - started
            left = el / done * (total - done)
            GLib.idle_add(self._set_progress, done / total,
                          "Sending %d%% — about %s left" % (done * 100 // total, _minutes(left)))

        def op():
            images, ms = media.load(path, fit)
            frames = media.encode(images)
            with Device() as d:
                d.upload(frames, ms, progress=progress, cancel=lambda: self.cancel_upload)
                d.sync_clock()
            return os.path.basename(path)

        def done(name):
            self._upload_ok = True
            self.progress.set_text("Sent %s" % name)
            GLib.timeout_add_seconds(4, lambda: self.progress_box.hide() or False)

        self._upload_ok = False
        self.worker.run(op, done, "Sending %s…" % os.path.basename(path))
        GLib.timeout_add(500, self._watch_upload)

    def _watch_upload(self):
        if self.worker.lock.locked():
            return True
        self.uploading = False
        self.send_btn.set_sensitive(True)
        if not self._upload_ok:   # failed or canceled: the error bar explains it
            self.progress_box.hide()
        return False

    def _cancel_upload(self):
        self.cancel_upload = True

    def _set_progress(self, frac, text):
        self.progress.set_fraction(frac)
        self.progress.set_text(text)
        return False

    # ------------------------------------------------- background service --

    @staticmethod
    def _service_active():
        return subprocess.run(["systemctl", "--user", "is-active", "--quiet", SERVICE]).returncode == 0

    def _service_toggled(self, sw, _p):
        on = sw.get_active()
        if on == self._service_active():
            return
        r = subprocess.run(["systemctl", "--user", "enable" if on else "disable", "--now", SERVICE],
                           capture_output=True, text=True)
        if r.returncode != 0:
            self.show_error("Couldn't %s the background service: %s\nInstall it with ./install.sh."
                            % ("start" if on else "stop", r.stderr.strip()))
            sw.set_active(not on)

    # ----------------------------------------------------------- lighting --

    def _lighting_page(self):
        page = Gtk.Box(spacing=24, margin=16)
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        left.pack_start(_heading("Effect"), False, False, 0)
        self.fx_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        for eid, name, *_ in EFFECTS:
            row = Gtk.ListBoxRow()
            row.effect = eid
            row.add(Gtk.Label(label=name, xalign=0, margin=6))
            self.fx_list.add(row)
        self.fx_list.connect("row-selected", self._effect_selected)
        sc = Gtk.ScrolledWindow(vexpand=True)
        sc.set_size_request(230, -1)
        sc.add(self.fx_list)
        left.pack_start(sc, True, True, 0)
        page.pack_start(left, False, False, 0)

        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        right.pack_start(_heading("Settings for this effect"), False, False, 0)
        self.fx_info = _dim("")
        right.pack_start(self.fx_info, False, False, 0)
        self.bright = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 5, 1)
        self.bright.set_value_pos(Gtk.PositionType.RIGHT)
        self.bright.set_size_request(260, -1)
        self.bright.connect("value-changed", lambda *_: self._light_changed())
        right.pack_start(_row("Brightness", self.bright), False, False, 0)
        self.speed = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 4, 1)
        self.speed.set_value_pos(Gtk.PositionType.RIGHT)
        self.speed.set_size_request(260, -1)
        self.speed.connect("value-changed", lambda *_: self._light_changed())
        right.pack_start(_row("Speed", self.speed), False, False, 0)
        crow = Gtk.Box(spacing=12)
        self.fx_color = Gtk.ColorButton()
        self.fx_color.set_size_request(90, -1)
        self.fx_color.connect("color-set", lambda *_: self._light_changed(color=True))
        crow.pack_start(self.fx_color, False, False, 0)
        self.fx_mix = Gtk.CheckButton(label="Mixed colors")
        self.fx_mix.connect("toggled", lambda *_: self._light_changed())
        crow.pack_start(self.fx_mix, False, False, 0)
        self.color_row = _row("Color", crow)
        right.pack_start(self.color_row, False, False, 0)
        right.pack_start(_try_box(), False, False, 0)

        self.custom_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.custom_box.pack_start(_heading("Per-key colors", 8), False, False, 0)
        self.custom_box.pack_start(_dim("Click keys to select them (click again to deselect), pick a color, "
                                        "then paint."), False, False, 0)
        self.paint_view = KeyboardView(self._paint_click)
        self.custom_box.pack_start(self.paint_view, True, True, 0)
        tools = Gtk.Box(spacing=8)
        self.paint_color = Gtk.ColorButton(rgba=_rgba((255, 255, 255)))
        tools.pack_start(self.paint_color, False, False, 0)
        tools.pack_start(_button("Paint selected", "Give the selected keys this color", self._paint_selected,
                                 suggested=True), False, False, 0)
        tools.pack_start(_button("Select all", None, self._paint_select_all), False, False, 0)
        tools.pack_start(_button("Select none", None, self._paint_select_none), False, False, 0)
        tools.pack_start(_button("Paint all", "Every key in this color", self._paint_all), False, False, 0)
        tools.pack_end(_button("Send to keyboard", "Write the per-key colors", self._send_key_colors),
                       False, False, 0)
        self.custom_box.pack_start(tools, False, False, 0)
        right.pack_start(self.custom_box, False, False, 0)
        page.pack_start(right, True, True, 0)
        return page

    def _load_lighting(self):
        prof = self.kb["profile"]
        for row in self.fx_list.get_children():
            if row.effect == prof.effect:
                self.fx_list.select_row(row)
        self._show_effect_params(prof.effect)
        self.paint_view.colors = {i: self.kb["colors"].get(i) for i in range(126)}
        self.paint_view.queue_draw()

    def _show_effect_params(self, eid):
        prof = self.kb["profile"]
        _id, _name, has_speed, has_bright, has_color = EFFECT_IDS.get(eid, (eid, "?", True, True, True))
        p = prof.led_param(eid)
        was = self._loading
        self._loading = True
        self.bright.set_value(Profile.level_for(p["brightness"]))
        self.speed.set_value(p["speed"])
        self.fx_mix.set_active(p["mix"])
        col = self.kb["effects"].color(eid)
        col = col if any(col) else (255, 255, 255)
        self.fx_color.set_rgba(_rgba(col))
        self._loading = was
        if has_color:
            self._carry = (col, p["mix"])
        self.bright.set_sensitive(has_bright)
        self.speed.set_sensitive(has_speed)
        self.color_row.set_sensitive(has_color)
        self.custom_box.set_visible(eid == CUSTOM)
        self.fx_info.set_text(EFFECT_INFO.get(eid, ""))

    def _effect_selected(self, _box, row):
        if row is None or self.kb is None:
            return
        send_color = not self._loading and self._carry_color(row.effect)
        self._show_effect_params(row.effect)
        if self._loading:
            return
        prof = self.kb["profile"]
        prof.effect = row.effect
        pbuf, fbuf = bytes(prof), bytes(self.kb["effects"])
        name = EFFECT_IDS[row.effect][1]

        def op(d):
            d.set_profile(pbuf)
            if send_color:
                d.set_led_effects(fbuf)

        self._change(op, "Lighting: %s…" % name)

    def _carry_color(self, eid):
        """Give a newly picked effect the color and "Mixed colors" choice the user already had, so trying
        effects keeps them. Returns whether the effect colors need sending."""
        carry = getattr(self, "_carry", None)
        if carry is None or not EFFECT_IDS.get(eid, (eid, "?", True, True, False))[4]:
            return False
        rgb, mix = carry
        prof, fx = self.kb["profile"], self.kb["effects"]
        prof.set_led_param(eid, mix=mix)
        if fx.color(eid) == tuple(rgb):
            return False
        fx.set_color(eid, rgb)
        return True

    def _light_changed(self, color=False):
        if self._loading or self.kb is None:
            return
        if getattr(self, "_light_timer", None):
            GLib.source_remove(self._light_timer)
        self._pending_color = getattr(self, "_pending_color", False) or color
        self._light_timer = GLib.timeout_add(350, self._send_light)

    def _send_light(self):
        self._light_timer = None
        prof, fx = self.kb["profile"], self.kb["effects"]
        eid = prof.effect
        prof.set_led_param(eid, brightness=BRIGHTNESS_LEVELS[int(self.bright.get_value())],
                           speed=int(self.speed.get_value()), mix=self.fx_mix.get_active())
        send_color = self._pending_color
        self._pending_color = False
        if send_color:
            fx.set_color(eid, _rgb(self.fx_color.get_rgba()))
            if self.fx_mix.get_active():
                self._loading = True              # picking a color means "use this color"
                self.fx_mix.set_active(False)
                self._loading = False
                prof.set_led_param(eid, mix=False)
        if EFFECT_IDS.get(eid, (eid, "?", True, True, True))[4]:
            self._carry = (_rgb(self.fx_color.get_rgba()), self.fx_mix.get_active())
        pbuf, fbuf = bytes(prof), bytes(fx)

        def op(d):
            d.set_profile(pbuf)
            if send_color:
                d.set_led_effects(fbuf)

        self._change(op, "Updating lighting…")
        return False

    def _paint_click(self, index, _ev):
        sel = self.paint_view.selected
        sel.symmetric_difference_update({index})
        self.paint_view.queue_draw()

    def _paint_select_all(self):
        self.paint_view.selected = {k["index"] for k in self.paint_view.keys}
        self.paint_view.queue_draw()

    def _paint_select_none(self):
        self.paint_view.selected = set()
        self.paint_view.queue_draw()

    def _paint_selected(self):
        rgb = _rgb(self.paint_color.get_rgba())
        for i in self.paint_view.selected:
            self.kb["colors"].set(i, rgb)
            self.paint_view.colors[i] = rgb
        self.paint_view.queue_draw()

    def _paint_all(self):
        self._paint_select_all()
        self._paint_selected()

    def _send_key_colors(self):
        buf = bytes(self.kb["colors"])
        store.update_config(key_colors=buf.hex())   # the keyboard can't report them back
        self._change(lambda d: d.set_key_colors(buf), "Sending per-key colors…")

    # --------------------------------------------------------------- keys --

    def _keys_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=16)
        bar = Gtk.Box(spacing=12)
        self.table_combo = _combo([(0, "Windows mode"), (1, "Mac mode")])
        self.layer_combo = _combo([(i, n + " layer") for i, n in enumerate(keymap.LAYERS)])
        for c in (self.table_combo, self.layer_combo):
            c.connect("changed", lambda *_: self._draw_keys())
            bar.pack_start(c, False, False, 0)
        bar.pack_end(_button("Reset this layer", "Undo your changes on this layer", self._reset_layer),
                     False, False, 0)
        box.pack_start(bar, False, False, 0)
        box.pack_start(_dim("Click a key to choose what it does. Changes are sent straight to the keyboard; "
                            "keys you changed are outlined in orange. The FN layer is what keys do while FN is "
                            "held."), False, False, 0)
        self.keys_view = KeyboardView(self._key_clicked)
        box.pack_start(self.keys_view, True, True, 0)
        box.pack_start(_try_box(), False, False, 0)
        return box

    def _tl(self):
        return int(self.table_combo.get_active_id()), int(self.layer_combo.get_active_id())

    def _layer_codes(self, t, l):
        cfg = store.load_config()
        return cli.layer_codes(t, l, cfg), cli.key_overrides(cfg, t, l)

    def _draw_keys(self):
        if self.kb is None:
            return
        t, l = self._tl()
        codes, overrides = self._layer_codes(t, l)
        labels = {}
        for k in self.keys_view.keys:
            action = codes[k["index"]]
            if l == 0 and action == keymap.DEFAULTS["mac" if t else "win"][0][k["index"]]:
                labels[k["index"]] = k["label"]
            else:
                labels[k["index"]] = "" if action == 0 else keymap.describe(action)
        self.keys_view.labels = labels
        self.keys_view.marked = {int(i) for i in overrides}
        self.keys_view.queue_draw()

    def _key_clicked(self, index, _ev):
        if self.kb is None:
            return
        t, l = self._tl()
        self.keys_view.selected = {index}
        self.keys_view.queue_draw()
        pop = Gtk.Popover(relative_to=self.keys_view, pointing_to=self.keys_view.key_rect(index))
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin=8)
        key = keymap.KEYS_BY_INDEX.get(index, {"label": "key %d" % index})
        box.pack_start(_heading("%s → %s layer" % (key["label"], keymap.LAYERS[l])), False, False, 0)
        search = Gtk.SearchEntry(placeholder_text="Search keys, media, lighting…")
        box.pack_start(search, False, False, 0)
        lst = Gtk.ListBox()
        choices = [("Default", None)] + [("Macro %d: %s" % (i + 1, m["name"]), keymap.macro_action(i))
                                         for i, m in enumerate(getattr(self, "macros", []))]
        choices += [("Disabled", 0)] + keymap.assignable()
        for label, action in choices:
            row = Gtk.ListBoxRow()
            row.action, row.text = action, label.lower()
            row.add(Gtk.Label(label=label, xalign=0, margin=4))
            lst.add(row)
        lst.set_filter_func(lambda r: search.get_text().lower() in r.text)
        search.connect("search-changed", lambda *_: lst.invalidate_filter())
        sc = Gtk.ScrolledWindow(min_content_height=320, min_content_width=280)
        sc.add(lst)
        box.pack_start(sc, True, True, 0)
        lst.connect("row-activated", lambda _l, row: (pop.popdown(), self._assign_key(t, l, index, row.action)))
        pop.add(box)
        pop.show_all()
        pop.connect("closed", lambda *_: (self.keys_view.selected.clear(), self.keys_view.queue_draw()))
        search.grab_focus()

    def _assign_key(self, t, l, index, action):
        fn = keymap.CODES.get("KEY_Fn1")
        if l == 0 and keymap.DEFAULTS["mac" if t else "win"][0][index] == fn and action not in (None, fn):
            dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,
                                    buttons=Gtk.ButtonsType.OK_CANCEL, text="Remap the FN key?")
            dlg.format_secondary_text("Without FN you can't reach the FN layer (media keys, lighting, "
                                      "connection modes) from the keyboard. You can undo this here any time.")
            resp = dlg.run()
            dlg.destroy()
            if resp != Gtk.ResponseType.OK:
                return
        cfg = store.load_config()
        layer = cfg.setdefault("keymap", {}).setdefault(str(t), {}).setdefault(str(l), {})
        if action is None:
            layer.pop(str(index), None)
        else:
            layer[str(index)] = action
        store.save_config(cfg)
        self._draw_keys()
        self._change(lambda d: cli.write_layer(d, t, l), "Updating key map…")

    def _reset_layer(self):
        t, l = self._tl()
        cfg = store.load_config()
        cfg.get("keymap", {}).get(str(t), {}).pop(str(l), None)
        store.save_config(cfg)
        self._draw_keys()
        self._change(lambda d: cli.write_layer(d, t, l), "Resetting %s layer…" % keymap.LAYERS[l])

    # ------------------------------------------------------------- macros --

    def _macros_page(self):
        page = Gtk.Box(spacing=24, margin=16)
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        head = Gtk.Box(spacing=6)
        head.pack_start(_heading("Macros"), True, True, 0)
        head.pack_start(_button(None, "New macro", self._new_macro, "list-add-symbolic"), False, False, 0)
        head.pack_start(_button(None, "Delete macro", self._delete_macro, "list-remove-symbolic"), False, False, 0)
        left.pack_start(head, False, False, 0)
        self.macro_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.macro_list.connect("row-selected", lambda *_: self._fill_steps())
        sc = Gtk.ScrolledWindow(vexpand=True)
        sc.set_size_request(240, -1)
        sc.add(self.macro_list)
        left.pack_start(sc, True, True, 0)
        left.pack_start(_button("Send macros to keyboard", "Write all macros", self._send_macros, suggested=True),
                        False, False, 0)
        page.pack_start(left, False, False, 0)

        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.macro_name = Gtk.Entry(placeholder_text="Macro name")
        self.macro_name.connect("changed", self._rename_macro)
        right.pack_start(_row("Name", self.macro_name), False, False, 0)
        tools = Gtk.Box(spacing=8)
        self.record_btn = Gtk.ToggleButton(label="● Record")
        self.record_btn.set_tooltip_text("Type the keys you want; press Record again to stop")
        self.record_btn.connect("toggled", self._record_toggled)
        tools.pack_start(self.record_btn, False, False, 0)
        tools.pack_start(Gtk.Label(label="Delay between steps"), False, False, 0)
        self.step_delay = Gtk.SpinButton.new_with_range(0, 60000, 10)
        self.step_delay.set_value(50)
        tools.pack_start(self.step_delay, False, False, 0)
        tools.pack_start(Gtk.Label(label="ms"), False, False, 0)
        self.real_timing = Gtk.CheckButton(label="Keep my real timing")
        tools.pack_start(self.real_timing, False, False, 0)
        tools.pack_end(_button("Clear", "Remove all steps", self._clear_steps), False, False, 0)
        right.pack_start(tools, False, False, 0)
        self.steps = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        ph = _dim("No steps. Press Record and type.")
        ph.show()
        self.steps.set_placeholder(ph)
        sc2 = Gtk.ScrolledWindow(vexpand=True)
        sc2.add(self.steps)
        right.pack_start(sc2, True, True, 0)
        right.pack_start(_dim("Assign a macro to a key on the Keys tab. Macros are kept on this computer too, "
                              "so you can edit them later."), False, False, 0)
        self.macro_right = right
        page.pack_start(right, True, True, 0)
        return page

    def _fill_macros(self, select=None):
        if select is None:
            row = self.macro_list.get_selected_row()
            select = row.get_index() if row else 0
        for c in self.macro_list.get_children():
            self.macro_list.remove(c)
        for i, m in enumerate(self.macros):
            row = Gtk.ListBoxRow()
            row.add(Gtk.Label(label="%d. %s" % (i + 1, m["name"]), xalign=0, margin=6))
            self.macro_list.add(row)
        self.macro_list.show_all()
        r = self.macro_list.get_row_at_index(min(select, len(self.macros) - 1)) if self.macros else None
        if r:
            self.macro_list.select_row(r)
        self._fill_steps()

    def _current_macro(self):
        row = self.macro_list.get_selected_row()
        return self.macros[row.get_index()] if row and row.get_index() < len(self.macros) else None

    def _fill_steps(self):
        m = self._current_macro()
        self.macro_right.set_sensitive(m is not None)
        for c in self.steps.get_children():
            self.steps.remove(c)
        if m is None:
            return
        self._naming = True
        self.macro_name.set_text(m["name"])
        self._naming = False
        for i, s in enumerate(m["steps"]):
            box = Gtk.Box(spacing=8, margin=3)
            box.pack_start(Gtk.Label(label="%d" % (i + 1), width_chars=3), False, False, 0)
            box.pack_start(Gtk.Label(label=keymap.describe_step(s), xalign=0), True, True, 0)
            delay = Gtk.SpinButton.new_with_range(0, 60000, 10)
            delay.set_value(s["delay"])
            delay.connect("value-changed", lambda w, s=s: s.update(delay=int(w.get_value())) or self._save_macros_local())
            box.pack_start(delay, False, False, 0)
            box.pack_start(_button(None, "Remove step", lambda i=i: self._remove_step(i), "list-remove-symbolic"),
                           False, False, 0)
            row = Gtk.ListBoxRow()
            row.add(box)
            self.steps.add(row)
        self.steps.show_all()

    def _save_macros_local(self):
        store.update_config(macros=self.macros)

    def _new_macro(self):
        if len(self.macros) >= MAX_MACROS:
            self.show_error("That's the most macros this app keeps (%d)." % MAX_MACROS)
            return
        self.macros.append({"name": "Macro %d" % (len(self.macros) + 1), "steps": []})
        self._save_macros_local()
        self._fill_macros(len(self.macros) - 1)

    def _delete_macro(self):
        row = self.macro_list.get_selected_row()
        if row is None:
            return
        i = row.get_index()
        self._save_macros_local()
        cfg = store.load_config()
        changed = cli.delete_macro(cfg, i)
        store.save_config(cfg)
        self.macros = cfg.get("macros", [])
        self._fill_macros(max(0, i - 1))
        self._draw_keys()
        if changed:
            self.status.set_text("Keys using macro %d went back to default; later macros moved up. Press "
                                 "“Send macros to keyboard” to update the keyboard." % (i + 1))

    def _rename_macro(self, entry):
        m = self._current_macro()
        if m is None or getattr(self, "_naming", False):
            return
        m["name"] = entry.get_text()[:60]
        self._save_macros_local()
        row = self.macro_list.get_selected_row()
        row.get_child().set_text("%d. %s" % (row.get_index() + 1, m["name"]))

    def _remove_step(self, i):
        m = self._current_macro()
        m["steps"].pop(i)
        self._save_macros_local()
        self._fill_steps()

    def _clear_steps(self):
        m = self._current_macro()
        if m:
            m["steps"] = []
            self._save_macros_local()
            self._fill_steps()

    def _record_toggled(self, btn):
        self._last_key_time = None
        if btn.get_active():
            btn.set_label("■ Stop recording")
            self.status.set_text("Recording: type your keys (keys typed now aren't sent anywhere else in this window).")
        else:
            btn.set_label("● Record")
            self.status.set_text("Recording stopped.")
            self._fill_steps()

    def _on_key(self, _w, ev, up):
        if not getattr(self, "record_btn", None) or not self.record_btn.get_active():
            return False
        m = self._current_macro()
        usage = EVDEV_TO_HID.get(ev.hardware_keycode - 8)
        if m is None or usage is None:
            return True
        now = time.monotonic()
        if m["steps"] and self.real_timing.get_active() and self._last_key_time is not None:
            m["steps"][-1]["delay"] = int((now - self._last_key_time) * 1000)
        self._last_key_time = now
        if m["steps"] and not m["steps"][-1]["up"] and m["steps"][-1]["key"] == usage and not up:
            return True   # auto-repeat
        kind = keymap.T_MODIFIER if 0xE0 <= usage <= 0xE7 else keymap.T_KEY
        m["steps"].append({"up": up, "type": kind, "key": usage, "delay": int(self.step_delay.get_value())})
        self._save_macros_local()
        self._fill_steps()
        return True

    def _send_macros(self):
        try:
            blob = keymap.encode_macros(self.macros)
        except ValueError as e:
            self.show_error(str(e))
            return
        cfg = store.load_config()
        layers = cli.layers_using_macros(cfg) | {(int(t), int(l)) for t, ls in cfg.get("keymap", {}).items()
                                                  for l in ls}

        def op(d):
            d.set_macros_blob(blob)
            for t, l in sorted(layers):   # macro numbers may have moved: rewrite the keys that use them
                cli.write_layer(d, t, l)

        self._change(op, "Sending %d macro(s)…" % len(self.macros))

    # ----------------------------------------------------------- settings --

    def _settings_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=16)
        box.pack_start(_heading("Keyboard"), False, False, 0)
        self.sleep_spin = Gtk.SpinButton.new_with_range(0, 120, 0.5)
        self.sleep_spin.set_digits(1)
        self.sleep_spin.connect("value-changed", lambda *_: self._setting_changed())
        box.pack_start(_row("Lights off after", self.sleep_spin, "minutes idle (0 = never)"), False, False, 0)
        self.winlock = Gtk.Switch(halign=Gtk.Align.START)
        self.winlock.connect("notify::active", lambda *_: self._setting_changed())
        box.pack_start(_row("Lock the Windows key", self.winlock), False, False, 0)
        self.wasd = Gtk.Switch(halign=Gtk.Align.START)
        self.wasd.connect("notify::active", lambda *_: self._setting_changed())
        box.pack_start(_row("Swap WASD and arrows", self.wasd), False, False, 0)

        box.pack_start(_heading("Clock", 12), False, False, 0)
        box.pack_start(_row("Keyboard clock", _button("Set to this computer's time", None, self._sync_clock)),
                       False, False, 0)
        self.svc_switch = Gtk.Switch(halign=Gtk.Align.START, active=self._service_active())
        self.svc_switch.connect("notify::active", self._service_toggled)
        box.pack_start(_row("Keep it in sync", self.svc_switch, "small background service, starts at login"),
                       False, False, 0)

        box.pack_start(_heading("Backup", 12), False, False, 0)
        bb = Gtk.Box(spacing=8)
        bb.pack_start(_button("Save backup…", "Save lighting, keys and macros to a file", self._save_backup),
                      False, False, 0)
        bb.pack_start(_button("Restore backup…", "Write a saved backup to the keyboard", self._restore_backup),
                      False, False, 0)
        box.pack_start(bb, False, False, 0)
        box.pack_start(_dim("Your settings from before SpareKey's first change are kept in %s."
                            % os.path.join(store.BACKUP_DIR, "s98-original.json").replace(os.path.expanduser("~"), "~")),
                       False, False, 0)
        box.pack_start(_heading("Factory reset", 12), False, False, 0)
        box.pack_start(_row("Reset lighting, keys and macros", _button("Factory reset…", None, self._factory_reset)),
                       False, False, 0)
        box.pack_start(_heading("Firmware", 12), False, False, 0)
        self.fw_label = Gtk.Label(xalign=0)
        box.pack_start(self.fw_label, False, False, 0)
        box.pack_start(_dim("SpareKey doesn't flash firmware (a failed flash can leave the keyboard unusable). "
                            "With SpareKey's udev rule installed, RK's web driver at drive.rkgaming.com works in "
                            "Chrome or Chromium on Linux if you need an update."), False, False, 0)
        return box

    def _load_settings(self):
        prof = self.kb["profile"]
        self.sleep_spin.set_value(prof.sleep_minutes)
        self.winlock.set_active(prof.win_lock)
        self.wasd.set_active(prof.wasd_swap)
        self.fw_label.set_text("%s, firmware %s" % (self.kb["model"], self.kb["info"]["firmware"]))

    def _setting_changed(self):
        if self._loading or self.kb is None:
            return
        if getattr(self, "_set_timer", None):
            GLib.source_remove(self._set_timer)
        self._set_timer = GLib.timeout_add(500, self._send_settings)

    def _send_settings(self):
        self._set_timer = None
        prof = self.kb["profile"]
        prof.sleep_minutes = self.sleep_spin.get_value()
        prof.win_lock = self.winlock.get_active()
        prof.wasd_swap = self.wasd.get_active()
        buf = bytes(prof)
        self._change(lambda d: d.set_profile(buf), "Saving keyboard settings…")
        return False

    def _sync_clock(self):
        self.run(lambda: self._with_dev(lambda d: d.sync_clock()),
                 lambda _r: self.status.set_text("Keyboard clock set to %s." % time.strftime("%H:%M:%S")),
                 "Setting the clock…")

    def _save_backup(self):
        dlg = Gtk.FileChooserDialog(title="Save keyboard backup", transient_for=self, action=Gtk.FileChooserAction.SAVE,
                                    do_overwrite_confirmation=True)
        dlg.add_buttons("_Cancel", Gtk.ResponseType.CANCEL, "_Save", Gtk.ResponseType.ACCEPT)
        dlg.set_current_name(time.strftime("s98-backup-%Y%m%d.json"))
        resp = dlg.run()
        path = dlg.get_filename()
        dlg.destroy()
        if resp == Gtk.ResponseType.ACCEPT and path:
            self.run(lambda: self._with_dev(lambda d: cli.backup(d, path)),
                     lambda p: self.status.set_text("Saved %s" % p), "Saving backup…")

    def _restore_backup(self):
        dlg = Gtk.FileChooserDialog(title="Restore keyboard backup", transient_for=self,
                                    action=Gtk.FileChooserAction.OPEN)
        dlg.add_buttons("_Cancel", Gtk.ResponseType.CANCEL, "_Restore", Gtk.ResponseType.ACCEPT)
        if os.path.isdir(store.BACKUP_DIR):
            dlg.set_current_folder(store.BACKUP_DIR)
        resp = dlg.run()
        path = dlg.get_filename()
        dlg.destroy()
        if resp == Gtk.ResponseType.ACCEPT and path:
            self.run(lambda: self._with_dev(lambda d: cli.restore(d, path)), lambda _r: self.refresh(),
                     "Restoring backup…")

    def _factory_reset(self):
        dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,
                                buttons=Gtk.ButtonsType.OK_CANCEL,
                                text="Reset the keyboard to factory settings?")
        dlg.format_secondary_text("Lighting, key maps and macros go back to how they shipped. SpareKey saves a "
                                  "backup first.")
        resp = dlg.run()
        dlg.destroy()
        if resp != Gtk.ResponseType.OK:
            return

        def done(_r):
            self.macros = []
            self._fill_macros()
            self.refresh()

        self._change(cli.factory_reset, "Factory reset…", done)


class App(Gtk.Application):
    def __init__(self, page=None):
        super().__init__(application_id="io.github.nateindahood.sparekey")
        self.page = page

    def do_activate(self):
        win = self.get_active_window() or Window(self, self.page)
        if self.page:
            win.stack.set_visible_child_name(self.page)
        win.present()


def main(page=None):
    GLib.set_prgname("sparekey")
    GLib.set_application_name("SpareKey %s" % __version__)
    Gtk.Window.set_default_icon_name("sparekey")   # installed by install.sh; the theme falls back if missing
    return App(page).run([])
