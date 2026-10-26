#!/usr/bin/env bash
# Install SpareKey for the current user (no pip needed):
#   ./install.sh             install / update (GUI, CLI, udev rule, clock service)
#   ./install.sh --uninstall
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB="${XDG_DATA_HOME:-$HOME/.local/share}/sparekey"
BIN="$HOME/.local/bin/sparekey"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
RULE="/etc/udev/rules.d/70-sparekey.rules"

if [ "${1:-}" = "--uninstall" ]; then
    systemctl --user disable --now sparekey.service 2>/dev/null || true
    rm -f "$UNIT_DIR/sparekey.service" "$BIN" "$APPS/sparekey.desktop" "$ICONS"/*/apps/sparekey.png
    rm -rf "$LIB"
    [ -f "$RULE" ] && sudo rm -f "$RULE" && sudo udevadm control --reload
    echo "sparekey uninstalled (settings in ~/.config/sparekey and your library were kept)."
    exit 0
fi

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
python3 -c "import PIL" 2>/dev/null || echo "Note: Pillow is needed for GIFs (sudo apt install python3-pil)."
python3 -c "import gi; gi.require_version('Gtk', '3.0')" 2>/dev/null \
    || echo "Note: the GUI needs GTK 3 for Python (sudo apt install python3-gi gir1.2-gtk-3.0)."

# the pre-release name was "keyframe": remove that install (settings move over on first run)
if [ -e "$HOME/.local/bin/keyframe" ] || [ -d "${XDG_DATA_HOME:-$HOME/.local/share}/keyframe" ]; then
    echo "==> Removing the old keyframe install"
    systemctl --user disable --now keyframe.service 2>/dev/null || true
    rm -rf "$HOME/.local/bin/keyframe" "${XDG_DATA_HOME:-$HOME/.local/share}/keyframe" \
        "$UNIT_DIR/keyframe.service" "$APPS/keyframe.desktop"
fi

echo "==> Installing to $LIB"
rm -rf "$LIB"
mkdir -p "$LIB" "$(dirname "$BIN")" "$APPS" "$UNIT_DIR"
cp -r "$HERE/src/sparekey" "$LIB/"
find "$LIB" -name __pycache__ -prune -exec rm -rf {} +
cat >"$BIN" <<EOF
#!/bin/sh
exec python3 -I -c "import sys; sys.path.insert(0, '$LIB'); from sparekey.cli import main; sys.exit(main(sys.argv[1:]))" "\$@"
EOF
chmod +x "$BIN"
sed "s|^Exec=sparekey|Exec=$BIN|" "$HERE/packaging/sparekey.desktop" >"$APPS/sparekey.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" 2>/dev/null || true
for f in "$HERE"/packaging/icons/hicolor/*/apps/sparekey.png; do
    size="$(basename "$(dirname "$(dirname "$f")")")"
    install -Dm0644 "$f" "$ICONS/$size/apps/sparekey.png"
done
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -qtf "$ICONS" 2>/dev/null || true

OLD_RULES="/etc/udev/rules.d/70-rk-keyboard.rules /etc/udev/rules.d/70-keyframe.rules"   # earlier names
have_old=false
for r in $OLD_RULES; do [ -f "$r" ] && have_old=true; done
if ! cmp -s "$HERE/packaging/70-sparekey.rules" "$RULE" 2>/dev/null || $have_old; then
    echo "==> Installing udev rule $RULE (needs sudo)"
    sudo install -m 0644 "$HERE/packaging/70-sparekey.rules" "$RULE"
    for r in $OLD_RULES; do [ -f "$r" ] && sudo rm -f "$r"; done
    sudo udevadm control --reload
    sudo udevadm trigger --subsystem-match=hidraw
    echo "    Unplug and replug the keyboard once so the new rule fully applies."
fi

cp "$HERE/packaging/sparekey.service" "$UNIT_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now sparekey.service >/dev/null 2>&1 \
    && echo "==> Clock service enabled (keeps the keyboard clock in sync)" \
    || echo "Note: couldn't start sparekey.service; turn it on under Settings → Clock."
systemctl --user try-restart sparekey.service 2>/dev/null || true

case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Note: add ~/.local/bin to your PATH";; esac
echo "==> Done. Open 'sparekey' from the app menu, or run: sparekey info"
