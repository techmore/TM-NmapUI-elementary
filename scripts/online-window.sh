#!/usr/bin/env bash
# Internal Xvfb/DBus-session worker for online-snapshot.sh.
set -euo pipefail
build=$1; output=$2; dark=$3; tab=$4
export NMAPUI_SNAPSHOT="$output" NMAPUI_SNAPSHOT_DELAY=14000 NMAPUI_FORCE_DARK="$dark"
export GSK_RENDERER=cairo WEBKIT_DISABLE_DMABUF_RENDERER=1 GTK_A11Y=none
"$build/io.github.techmore.NmapUI" &
app_pid=$!
trap 'kill "$app_pid" 2>/dev/null || true' EXIT
if [[ $tab == reports ]]; then
  # Exercise the shipped Ctrl+3 action: native toggle -> JS hash -> web Reports panel.
  for attempt in {1..40}; do
    window=$(xdotool search --onlyvisible --name '^Network Scanner$' 2>/dev/null | tail -n 1) || true
    [[ -n ${window:-} ]] && break
    sleep 0.25
  done
  test -n "${window:-}"
  # Send the real shortcut as soon as the window exists; startup must retain it.
  xdotool windowfocus --sync "$window"
  xdotool key --clearmodifiers ctrl+3
fi
wait "$app_pid"
test -s "$output"
