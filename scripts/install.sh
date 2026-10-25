#!/usr/bin/env bash
# Build and install Network Scanner for the current user (prefix ~/.local), pin it to the dock,
# and optionally install the Wingpanel indicator (system-wide, needs sudo) and the scanner engine.
#
#   scripts/install.sh                 # app + indicator + engine
#   scripts/install.sh --no-indicator  # skip the Wingpanel module
#   scripts/install.sh --no-backend    # skip scripts/install-backend.sh
set -euo pipefail
[[ $(id -u) != 0 ]] || { echo 'Run this installer as your desktop user, without sudo.' >&2; exit 1; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
indicator=1; backend=1
for arg in "$@"; do
  case "$arg" in
    --no-indicator) indicator=0 ;;
    --no-backend) backend=0 ;;
    *) echo "Usage: install.sh [--no-indicator] [--no-backend]" >&2; exit 2 ;;
  esac
done

if ((backend)) && [[ ! ${NMAPUI_REF:-} =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo 'Set NMAPUI_REF to a reviewed full engine commit SHA, or use --no-backend.' >&2; exit 2
fi

echo "== Build tools"
tools=(meson ninja-build valac pkg-config libgtk-4-dev libgranite-7-dev libwebkitgtk-6.0-dev libsoup-3.0-dev libjson-glib-dev gtk-update-icon-cache desktop-file-utils)
((indicator)) && tools+=(libwingpanel-9-dev)
missing=()
for pkg in "${tools[@]}"; do dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg"); done
if ((${#missing[@]})); then
  echo "Installing: ${missing[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y "${missing[@]}"
fi

echo "== Build"
build="$root/build"
setup_args=()
[[ ! -f "$build/meson-private/coredata.dat" ]] || setup_args+=(--reconfigure)
meson setup "$build" "$root" --prefix="$HOME/.local" -Dindicator=false "${setup_args[@]}" >/dev/null
meson compile -C "$build"
meson install -C "$build" >/dev/null
echo "installed $HOME/.local/bin/io.github.techmore.NmapUI"

if ((indicator)); then
  echo "== Wingpanel indicator (system-wide)"
  ibuild=$(mktemp -d); trap 'rm -rf "$ibuild"' EXIT
  meson setup "$ibuild" "$root" -Dindicator=true --prefix=/usr >/dev/null
  meson compile -C "$ibuild" >/dev/null
  indicators_dir=$(pkg-config --variable=indicatorsdir wingpanel-9)
  sudo install -m 0755 "$ibuild/indicator/libnmapui.so" "$indicators_dir/libnmapui.so"
  sudo install -Dm644 "$root/indicator/icons/mseries-nmapui-radar-symbolic.svg" \
    /usr/share/icons/hicolor/symbolic/apps/mseries-nmapui-radar-symbolic.svg
  sudo gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
  echo "installed $indicators_dir/libnmapui.so (loads at next login; Wingpanel was not restarted)"
fi

echo "== Dock"
desktop=io.github.techmore.NmapUI.desktop
current=$(dconf read /io/elementary/dock/launchers 2>/dev/null || true)
if [[ -n "$current" && "$current" != *"$desktop"* ]]; then
  dconf write /io/elementary/dock/launchers "${current%]}, '$desktop']"
  echo "pinned Network Scanner to the dock"
fi

if ((backend)); then
  echo "== Scanner engine"
  bash "$here/install-backend.sh"
fi
echo "Done. Open 'Network Scanner' from the dock or the applications menu."
