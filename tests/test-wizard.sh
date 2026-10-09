#!/usr/bin/env bash
# The install wizard writes JSON DSM can read; check it on this box.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp); trap 'rm -f "$out"' EXIT
SYNOPKG_TEMP_LOGFILE=$out bash "$here/../synology/WIZARD_UIFILES/install_uifile.sh"
if jq -e 'length == 3 and (.[1].items | length) == 3 and (.[2].items[1].type == "password") and ([.. | .key? | select(. != null)] | sort == ["wizard_admin_email","wizard_admin_first","wizard_admin_last","wizard_admin_pass","wizard_http_port","wizard_lan_ip","wizard_tz"])' "$out" >/dev/null; then
  echo "  ok   wizard JSON: 3 pages, 7 fields, password field"
  echo "       suggested: ip $(jq -r '.[1].items[0].subitems[0].defaultValue' "$out"), port $(jq -r '.[1].items[1].subitems[0].defaultValue' "$out"), tz $(jq -r '.[1].items[2].subitems[0].defaultValue' "$out")"
  echo; echo "wizard: 1 passed, 0 failed"
else
  echo "  FAIL wizard JSON"; jq . "$out" 2>&1 | head -20; echo; echo "wizard: 0 passed, 1 failed"; exit 1
fi
