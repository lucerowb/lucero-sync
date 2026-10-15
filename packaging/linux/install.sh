#!/usr/bin/env sh
# Installs Lucero Sync for the current user (no root needed).
#   ./install.sh            install to ~/.local
#   ./install.sh --remove   uninstall
set -e
APP_DIR="$HOME/.local/share/lucero-sync"
BIN="$HOME/.local/bin/lucero_sync"
DESKTOP="$HOME/.local/share/applications/lucero-sync.desktop"
ICON="$HOME/.local/share/icons/hicolor/512x512/apps/lucero-sync.png"

if [ "$1" = "--remove" ]; then
  rm -rf "$APP_DIR" "$BIN" "$DESKTOP" "$ICON"
  echo "Lucero Sync removed."
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$APP_DIR" "$(dirname "$BIN")" "$(dirname "$DESKTOP")" "$(dirname "$ICON")"
cp -R "$HERE"/. "$APP_DIR"/
ln -sf "$APP_DIR/lucero_sync" "$BIN"
cp "$HERE/lucero-sync.png" "$ICON"
sed "s|^Exec=.*|Exec=$APP_DIR/lucero_sync|" "$HERE/lucero-sync.desktop" > "$DESKTOP"
command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$DESKTOP")" || true
echo "Installed. Launch Lucero Sync from your app menu, or run: $BIN"
