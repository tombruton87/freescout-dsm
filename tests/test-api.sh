#!/usr/bin/env bash
# api.cgi on a laptop: a stub sign-in, a throwaway var dir, every branch.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$here/..
CGI=$root/synology/target/ui/api.cgi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export FREESCOUT_VAR=$work/var FREESCOUT_SHARE=$work/share FREESCOUT_PKG=$work/pkg FREESCOUT_AUTH_CGI=$here/stub-auth.sh
export FREESCOUT_ADMINS=$(id -gn)     # the test user's own group stands in for "administrators"
mkdir -p "$FREESCOUT_VAR" "$FREESCOUT_SHARE/backups" "$FREESCOUT_PKG"
echo running > "$FREESCOUT_VAR/state"
echo '{"at":1,"backups":[{"name":"freescout-20260101-0200.tar","size":3,"at":1}]}' > "$FREESCOUT_VAR/status.json"
echo "hi" > "$FREESCOUT_SHARE/backups/freescout-20260101-0200.tar"
echo "# notes" > "$FREESCOUT_PKG/CHANGELOG.md"

pass=0; fail=0
get() { STUB_USER=$1 REQUEST_METHOD=GET QUERY_STRING=$2 "$CGI"; }
post() { local body=$3; STUB_USER=$1 REQUEST_METHOD=POST QUERY_STRING="action=$2" CONTENT_LENGTH=${#body} "$CGI" <<< "$body"; }
expect() {   # description, expected status, output
  local desc=$1 want=$2 out=$3 got
  got=$(sed -n '1s/^Status: \([0-9]*\).*/\1/p' <<< "$out")
  if [[ "$got" == "$want" ]]; then (( pass++ )); echo "  ok   $desc"; else (( fail++ )); echo "  FAIL $desc: wanted $want, got ${got:-nothing}"; echo "$out" | head -5 | sed 's/^/       /'; fi
}
request_is() {   # description, expected file content
  if [[ "$(cat "$FREESCOUT_VAR/request" 2>/dev/null)" == "$2" ]]; then (( pass++ )); echo "  ok   $desc_prefix$1"; else (( fail++ )); echo "  FAIL $1:"; cat "$FREESCOUT_VAR/request" 2>/dev/null | sed 's/^/       /'; fi
  rm -f "$FREESCOUT_VAR/request"
}
desc_prefix=""
me=$(id -un)

echo "sign-in and roles"
expect "no session → 401" 401 "$(get '' 'action=status')"
expect "a DSM user who isn't an administrator → viewer, status 200" 200 "$(FREESCOUT_ADMINS=no-such-group-xyz get "$me" 'action=status')"
FREESCOUT_ADMINS=no-such-group-xyz get "$me" 'action=status' | grep -q '"role":"viewer"' && { (( pass++ )); echo "  ok   role is viewer"; } || { (( fail++ )); echo "  FAIL role not viewer"; }
expect "admin status → 200" 200 "$(get "$me" 'action=status')"
[[ -f "$FREESCOUT_VAR/watching" ]] && { (( pass++ )); echo "  ok   status touches watching"; } || { (( fail++ )); echo "  FAIL status didn't touch watching"; }
FREESCOUT_ADMINS=no-such-group-xyz
expect "viewer status → 200" 200 "$(get "$me" 'action=status')"
expect "viewer log → 403" 403 "$(get "$me" 'action=log&part=setup')"
expect "viewer POST → 403" 403 "$(post "$me" restart 'action=restart')"
FREESCOUT_ADMINS=$(id -gn)

echo "reads"
expect "log setup" 200 "$(get "$me" 'action=log&part=setup')"
expect "log app" 200 "$(get "$me" 'action=log&part=app')"
expect "log bad part" 400 "$(get "$me" 'action=log&part=../../etc/passwd')"
expect "changelog" 200 "$(get "$me" 'action=changelog')"
expect "report before made → 404" 404 "$(get "$me" 'action=report')"
echo "r" > "$FREESCOUT_VAR/report.txt"; expect "report" 200 "$(get "$me" 'action=report')"
expect "backup listed" 200 "$(get "$me" 'action=backup&name=freescout-20260101-0200.tar')"
expect "backup not listed → 404" 404 "$(get "$me" 'action=backup&name=freescout-20260102-0200.tar')"
expect "backup traversal → 404" 404 "$(get "$me" 'action=backup&name=../.env')"
expect "unknown GET" 400 "$(get "$me" 'action=shell')"
expect "modimg none → 404" 404 "$(get "$me" 'action=modimg&alias=mail365')"
mkdir -p "$FREESCOUT_VAR/modules/logos"; printf 'PNG' > "$FREESCOUT_VAR/modules/logos/mail365.png"
expect "modimg → 200" 200 "$(get "$me" 'action=modimg&alias=mail365')"
expect "modimg traversal → 404" 404 "$(get "$me" 'action=modimg&alias=../secret')"

echo "writes"
expect "restart → 202" 202 "$(post "$me" restart 'action=restart')"
request_is "restart request" "ACTION='restart'
BY='$me'"
expect "second while pending → 409" 409 "$(touch "$FREESCOUT_VAR/request"; post "$me" restart 'action=restart')"; rm -f "$FREESCOUT_VAR/request"
expect "reset good" 202 "$(post "$me" reset 'action=reset&user_id=7')"
request_is "reset request" "ACTION='reset'
USER_ID='7'
BY='$me'"
expect "reset bad id" 400 "$(post "$me" reset 'action=reset&user_id=7;drop')"
expect "userdisable" 202 "$(post "$me" userdisable 'action=userdisable&user_id=3')"
request_is "userdisable request" "ACTION='userdisable'
USER_ID='3'
BY='$me'"
expect "userrole good" 202 "$(post "$me" userrole 'action=userrole&user_id=3&role=2')"
request_is "userrole request" "ACTION='userrole'
USER_ID='3'
ROLE='2'
BY='$me'"
expect "userrole bad role" 400 "$(post "$me" userrole 'action=userrole&user_id=3&role=9')"
expect "userdelete bad id" 400 "$(post "$me" userdelete 'action=userdelete&user_id=x')"
expect "newadmin good" 202 "$(post "$me" newadmin 'action=newadmin&email=you%40example.com&first=Jo&last=Bloggs')"
request_is "newadmin request" "ACTION='newadmin'
EMAIL='you@example.com'
FIRST_NAME='Jo'
LAST_NAME='Bloggs'
BY='$me'"
expect "newadmin bad email" 400 "$(post "$me" newadmin 'action=newadmin&email=you%27%20or%201%3D1&first=Jo&last=B')"
expect "newadmin bad name" 400 "$(post "$me" newadmin 'action=newadmin&email=a%40b.co&first=Jo%20Anne&last=B')"
expect "restore listed" 202 "$(post "$me" restore 'action=restore&name=freescout-20260101-0200.tar')"; rm -f "$FREESCOUT_VAR/request"
expect "restore unlisted" 400 "$(post "$me" restore 'action=restore&name=freescout-20260109-0200.tar')"
expect "delbackup traversal" 400 "$(post "$me" delbackup 'action=delbackup&name=..%2F.env')"
expect "settings good" 202 "$(post "$me" settings 'action=settings&url=https%3A%2F%2Fhelp.example.com&port=8060&ssl_proxy=1&tz=Europe%2FLondon')"
request_is "settings request" "ACTION='settings'
APP_URL='https://help.example.com'
HTTP_PORT='8060'
SSL_PROXY='1'
APP_TZ='Europe/London'
BY='$me'"
expect "settings url with path" 400 "$(post "$me" settings 'action=settings&url=http%3A%2F%2F1.2.3.4%3A8060%2Fx&port=8060&ssl_proxy=0&tz=UTC')"
expect "settings url with quote" 400 "$(post "$me" settings "action=settings&url=http%3A%2F%2Fa%27b&port=8060&ssl_proxy=0&tz=UTC")"
expect "settings low port" 400 "$(post "$me" settings 'action=settings&url=http%3A%2F%2F1.2.3.4&port=80&ssl_proxy=0&tz=UTC')"
expect "settings bad tz" 400 "$(post "$me" settings 'action=settings&url=http%3A%2F%2F1.2.3.4&port=8060&ssl_proxy=0&tz=%24(id)')"
expect "maintenance on" 202 "$(post "$me" maintenance 'action=maintenance&on=1')"; rm -f "$FREESCOUT_VAR/request"
expect "maintenance bad" 400 "$(post "$me" maintenance 'action=maintenance&on=2')"
expect "wipe without the phrase" 400 "$(post "$me" wipe 'action=wipe&confirm=yes')"
expect "wipe with the phrase" 202 "$(post "$me" wipe 'action=wipe&confirm=remove+everything')"
request_is "wipe request" "ACTION='wipe'
CONFIRM='REMOVEEVERYTHING'
BY='$me'"
expect "modinstall good" 202 "$(post "$me" modinstall 'action=modinstall&alias=mail365')"
request_is "modinstall request" "ACTION='modinstall'
MODULE='mail365'
BY='$me'"
expect "modinstall bad alias" 400 "$(post "$me" modinstall 'action=modinstall&alias=Mail-365')"
expect "modcheck" 202 "$(post "$me" modcheck 'action=modcheck')"; rm -f "$FREESCOUT_VAR/request"
expect "clearlogs" 202 "$(post "$me" clearlogs 'action=clearlogs')"; rm -f "$FREESCOUT_VAR/request"
expect "cleansendlog" 202 "$(post "$me" cleansendlog 'action=cleansendlog')"; rm -f "$FREESCOUT_VAR/request"
expect "prefs good" 200 "$(post "$me" prefs 'action=prefs&nightly=1&keep=30')"
[[ "$(cat "$FREESCOUT_VAR/prefs")" == "NIGHTLY='1'
KEEP='30'" ]] && { (( pass++ )); echo "  ok   prefs file"; } || { (( fail++ )); echo "  FAIL prefs file"; }
expect "prefs bad keep" 400 "$(post "$me" prefs 'action=prefs&nightly=1&keep=0')"
expect "unknown action" 400 "$(post "$me" rm 'action=rm')"
expect "oversized body" 400 "$(STUB_USER=$me REQUEST_METHOD=POST CONTENT_LENGTH=99999 "$CGI" <<< 'action=restart')"
expect "non-numeric length" 400 "$(STUB_USER=$me REQUEST_METHOD=POST CONTENT_LENGTH='x[$(id)]' "$CGI" <<< 'action=restart')"
expect "take_secret none → 404" 404 "$(post "$me" take_secret 'action=take_secret')"
echo '{"email":"a@b.co","password":"x"}' > "$FREESCOUT_VAR/secret.json"
expect "take_secret once → 200" 200 "$(post "$me" take_secret 'action=take_secret')"
[[ ! -f "$FREESCOUT_VAR/secret.json" ]] && { (( pass++ )); echo "  ok   secret removed after hand-over"; } || { (( fail++ )); echo "  FAIL secret still there"; }

echo; echo "api.cgi: $pass passed, $fail failed"; (( fail == 0 ))
