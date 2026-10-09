#!/usr/bin/env bash
# run.sh's read_settings, with good and hostile files. The function is cut
# out of run.sh and run on its own, so this needs nothing but bash.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$here/../synology/setup/run.sh
fn=$(awk '/^read_settings\(\) \{/,/^}/' "$src")
keys=$(sed -n 's/^REQUEST_KEYS="\(.*\)"$/\1/p' "$src")
akeys=$(sed -n 's/^ANSWER_KEYS="\(.*\)"$/\1/p' "$src")
eval "$fn"
pass=0; fail=0
try() {   # description, expect ok|bad, keys, file content
  local f; f=$(mktemp); printf '%s\n' "$4" > "$f"
  ( read_settings "$f" $3 ); local rc=$?; rm -f "$f"
  if { [[ "$2" == ok && $rc == 0 ]] || [[ "$2" == bad && $rc != 0 ]]; }; then (( pass++ )); echo "  ok   $1"
  else (( fail++ )); echo "  FAIL $1 (rc $rc)"; fi
}
try "plain restart" ok "$keys" "ACTION='restart'
BY='tom'"
try "reset with id" ok "$keys" "ACTION='reset'
USER_ID='12'
BY='tom'"
try "settings https" ok "$keys" "ACTION='settings'
APP_URL='https://help.example.com'
HTTP_PORT='8060'
SSL_PROXY='1'
APP_TZ='Europe/London'
BY='tom'"
try "settings ip:port" ok "$keys" "ACTION='settings'
APP_URL='http://192.168.1.10:8060'
HTTP_PORT='8060'
SSL_PROXY='0'
APP_TZ='UTC'
BY='tom'"
try "newadmin" ok "$keys" "ACTION='newadmin'
EMAIL='you+help@example.co.uk'
FIRST_NAME='Jo'
LAST_NAME='Bloggs-Smith'
BY='tom'"
try "backup name with suffix" ok "$keys" "ACTION='restore'
BACKUP='freescout-20260101-0200-nightly.tar'
BY='tom'"
try "module install" ok "$keys" "ACTION='modinstall'
MODULE='mail365'
BY='tom'"
try "wipe confirmed" ok "$keys" "ACTION='wipe'
CONFIRM='REMOVEEVERYTHING'"
try "wipe wrong phrase" bad "$keys" "ACTION='wipe'
CONFIRM='YES'"
try "user role" ok "$keys" "ACTION='userrole'
USER_ID='3'
ROLE='1'"
try "user role bad" bad "$keys" "ACTION='userrole'
USER_ID='3'
ROLE='3'"
try "module alias with slash" bad "$keys" "ACTION='modinstall'
MODULE='../x'"
try "module alias uppercase" bad "$keys" "ACTION='modremove'
MODULE='Mail365'"
try "wizard answers" ok "$akeys" "FS_LAN_IP='192.168.1.10'
FS_TZ='Europe/London'
FS_HTTP_PORT='8060'
FS_ADMIN_EMAIL='me@example.com'
FS_ADMIN_FIRST='Admin'
FS_ADMIN_LAST='User'
FS_ADMIN_PASS_HEX='70617373776f726431'
FS_HOST_UID='1027'
FS_HOST_GID='65536'"
try "unknown action" bad "$keys" "ACTION='shell'
BY='tom'"
try "unknown key" bad "$keys" "ACTION='restart'
PATH='/tmp'
BY='tom'"
try "unquoted value" bad "$keys" "ACTION=restart"
try "command substitution" bad "$keys" "ACTION='restart'
BY='\$(id)'"
try "backtick" bad "$keys" "ACTION='restart'
BY='\`id\`'"
try "quote breakout" bad "$keys" "ACTION='restart'
BY='x'; rm -rf /; echo '"
try "space in value" bad "$keys" "ACTION='restart'
BY='tom smith'"
try "semicolon in email" bad "$keys" "ACTION='newadmin'
EMAIL='a@b.co;x'
FIRST_NAME='A'
LAST_NAME='B'"
try "sql in id" bad "$keys" "ACTION='reset'
USER_ID='1 OR 1=1'"
try "backup traversal" bad "$keys" "ACTION='restore'
BACKUP='../.env'"
try "backup wrong shape" bad "$keys" "ACTION='delbackup'
BACKUP='freescout-2026-01-01.tar'"
try "url with path" bad "$keys" "ACTION='settings'
APP_URL='http://1.2.3.4:8060/x'"
try "url with user@" bad "$keys" "ACTION='settings'
APP_URL='http://a@b.c'"
try "port too low" bad "$keys" "ACTION='settings'
HTTP_PORT='80'"
try "port too high" bad "$keys" "ACTION='settings'
HTTP_PORT='70000'"
try "tz lowercase" bad "$keys" "ACTION='settings'
APP_TZ='europe/london'"
try "tz traversal" bad "$keys" "ACTION='settings'
APP_TZ='Europe/../../etc'"
try "hex odd length" bad "$akeys" "FS_ADMIN_PASS_HEX='abc'"
try "hex too short (under 8 chars)" bad "$akeys" "FS_ADMIN_PASS_HEX='70617373'"
try "answer key in request" bad "$keys" "ACTION='restart'
FS_HOST_UID='0'"
try "lowercase key" bad "$keys" "action='restart'"
try "wrong ip" bad "$akeys" "FS_LAN_IP='192.168.1'"
echo; echo "read_settings: $pass passed, $fail failed"; (( fail == 0 ))
