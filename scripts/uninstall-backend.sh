#!/usr/bin/env bash
# Remove only our managed user service. Keep all source releases, config and scanner data.
set -euo pipefail
unit="$HOME/.config/systemd/user/nmapui.service"
[[ -e "$unit" ]] || { echo 'No managed user service installed.'; exit 0; }
grep -Fxq '# Managed by TM-NmapUI-elementary installer' "$unit" \
  || { echo "Refusing to remove an unmanaged user unit: $unit" >&2; exit 1; }
systemctl --user disable --now nmapui.service
rm "$unit"
systemctl --user daemon-reload
echo 'Removed the user service. Scanner data, configuration and releases are preserved.'
