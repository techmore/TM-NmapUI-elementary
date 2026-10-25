#!/usr/bin/env bash
# Render the app window to PNGs (light and dark) without a desktop session, for visual review
# and pull requests. Needs xvfb-run and a reachable scanner at NMAPUI_URL (default 127.0.0.1:9000).
#   scripts/snapshot.sh BUILD_DIR OUT_DIR
set -euo pipefail
build=$1; out=$2; mkdir -p "$out"
for scheme in light dark; do
  prefer=0; [[ $scheme == dark ]] && prefer=1
  xvfb-run -a -s "-screen 0 1400x960x24" dbus-run-session -- env GSK_RENDERER=cairo WEBKIT_DISABLE_DMABUF_RENDERER=1 \
    NMAPUI_SNAPSHOT="$out/window-$scheme.png" NMAPUI_SNAPSHOT_DELAY=${NMAPUI_SNAPSHOT_DELAY:-6000} \
    NMAPUI_FORCE_DARK=$prefer "$build/io.github.techmore.NmapUI" 2>&1 | grep -viE "egl|mesa|dri3" || true
  test -s "$out/window-$scheme.png"
done
ls -la "$out"
