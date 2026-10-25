#!/usr/bin/env bash
# Render the real native shell against a pinned, isolated shared engine; never start a scan.
# Usage: online-snapshot.sh BUILD_DIR OUT_DIR ENGINE_DIR ENGINE_PYTHON
set -euo pipefail
build=$(realpath "$1"); mkdir -p "$2"; out=$(realpath "$2")
engine=$(realpath "$3"); python=$(cd "$(dirname "$4")" && pwd)/$(basename "$4")
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runtime=$(mktemp -d)
export NMAPUI_DATA_DIR="$runtime/data" NMAPUI_LOG_DIR="$runtime/logs"
export NMAPUI_SKIP_LEGACY_MIGRATION=1 NMAPUI_STARTUP_TRACEROUTE=false
export NMAPUI_ENABLE_NETWORK_FINGERPRINT=false NMAPUI_ENABLE_VULNERS=false NMAPUI_ENABLE_UPDATE_CHECK=false
export NMAPUI_HOST=127.0.0.1 NMAPUI_PORT=19001 NMAPUI_TRUST_LOCAL_UI=true
export NMAPUI_URL="http://127.0.0.1:$NMAPUI_PORT"
export XDG_DATA_HOME="$runtime/ui-data" XDG_CACHE_HOME="$runtime/ui-cache" XDG_CONFIG_HOME="$runtime/ui-config"
"$python" -m gunicorn --chdir "$engine" --bind "127.0.0.1:$NMAPUI_PORT" \
  --workers 1 --threads 10 --timeout 60 nmapui.wsgi:application > "$out/engine.log" 2>&1 &
engine_pid=$!
trap 'kill "$engine_pid" 2>/dev/null || true; wait "$engine_pid" 2>/dev/null || true; rm -rf "$runtime"' EXIT
"$python" - "$out/readiness.json" <<'PY'
import json, os, sys, time, urllib.request
origin = os.environ['NMAPUI_URL']
for attempt in range(100):
    try:
        with urllib.request.urlopen(origin + '/api/health/ready', timeout=2) as response:
            ready = json.load(response)
        if ready.get('ready') is True:
            break
    except (OSError, ValueError):
        pass
    time.sleep(.3)
else:
    raise SystemExit('Isolated engine did not become ready')
with urllib.request.urlopen(origin + '/api/runtime/status', timeout=3) as response:
    runtime = json.load(response)
assert runtime['active_jobs'] == [], runtime
with urllib.request.urlopen(origin, timeout=3) as response:
    html = response.read().decode()
assert 'reports-tab-panel' in html and 'network-key-banner' in html
with open(sys.argv[1], 'w') as output:
    json.dump({'ready': ready, 'runtime': runtime}, output, indent=2)
PY
for scheme in light dark; do
  dark=0; [[ $scheme == dark ]] && dark=1
  xvfb-run -a -s '-screen 0 1400x960x24' dbus-run-session -- \
    "$here/online-window.sh" "$build" "$out/dashboard-$scheme.png" "$dark" dashboard
  tesseract "$out/dashboard-$scheme.png" "$out/dashboard-$scheme" 2>/dev/null
  grep -qi 'network topology' "$out/dashboard-$scheme.txt"
  ! grep -qi "scanner service isn't running" "$out/dashboard-$scheme.txt"
done
xvfb-run -a -s '-screen 0 1400x960x24' dbus-run-session -- \
  "$here/online-window.sh" "$build" "$out/reports-light.png" 0 reports
tesseract "$out/reports-light.png" "$out/reports-light" 2>/dev/null
grep -qi 'Open saved reports' "$out/reports-light.txt"
git -C "$engine" rev-parse HEAD > "$out/engine-commit.txt"
