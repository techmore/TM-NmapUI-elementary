#!/usr/bin/env bash
# Remove the native app from its documented per-user prefix, preserving profiles and scanner data.
# Add --backend to remove our managed user service as well. The system Wingpanel module is separate.
set -euo pipefail
[[ $# -le 1 ]] || exit 2
case ${1:-} in
  '') ;;
  --backend) bash "$(dirname "${BASH_SOURCE[0]}")/uninstall-backend.sh" ;;
  *) echo 'Usage: uninstall.sh [--backend]' >&2; exit 2 ;;
esac
prefix="$HOME/.local"
id=io.github.techmore.NmapUI
rm -f "$prefix/bin/$id" "$prefix/share/applications/$id.desktop" \
  "$prefix/share/metainfo/$id.metainfo.xml" \
  "$prefix/share/icons/hicolor/scalable/apps/$id.svg" \
  "$prefix/share/icons/hicolor/symbolic/apps/$id-symbolic.svg" \
  "$prefix/share/$id/nmapui.service.in" "$prefix/bin/nmapui-summary"
echo 'Removed the native app. Scanner data, profiles, releases and the system Wingpanel module are preserved.'
