#!/bin/bash
#
# What the window asks. DSM runs this as the package's user, which can't use
# Docker: reads come from files the setup container keeps fresh, writes become
# a request file it acts on — every value checked here, and again there
# (setup/run.sh read_settings). Nothing here runs anything.
#
#   GET  api.cgi?action=status                 how it is, as JSON (and "someone's watching")
#   GET  api.cgi?action=log&part=P             a log's last lines: setup app db scheduler worker laravel fetch
#   GET  api.cgi?action=report                 the support report, once made, to save
#   GET  api.cgi?action=backup&name=N          a backup file, to save (only one the setup container listed)
#   GET  api.cgi?action=changelog              the package's changelog
#   GET  api.cgi?action=modimg&alias=A         a module's logo, as the setup container fetched it
#   POST api.cgi  action=restart | logout | backup | fetch | retryjobs | flushjobs | updateapp | upgrade | check | clearcache | report
#                 action=reset        user_id=
#                 action=newadmin     email= first= last=
#                 action=restore | delbackup   name=
#                 action=settings     url= port= ssl_proxy=0|1 tz=
#                 action=maintenance  on=0|1
#                 action=modinstall | modupdate | modactivate | moddeactivate | modremove   alias=
#                 action=modcheck
#                 action=userenable | userdisable | userdelete   user_id=
#                 action=userrole     user_id= role=1|2
#                 action=wipe         confirm=remove everything          (removes FreeScout, its data, the package)
#                 action=prefs        nightly=0|1 keep=1..365          (kept here, in $VAR/prefs)
#                 action=take_secret                                   (a one-time password: handed over once, then removed)
#
# For someone signed in to DSM: an administrator, for everything; any other
# DSM user the app has been granted to (Control Panel → User & Group →
# Applications), to look. A test can set these; a browser can't (only HTTP_*
# comes from it).
VAR=${FREESCOUT_VAR:-/var/packages/freescout/var}
SHARE=${FREESCOUT_SHARE:-/var/packages/freescout/shares/freescout}
PKG=${FREESCOUT_PKG:-/var/packages/freescout/target}
AUTH=${FREESCOUT_AUTH_CGI:-/usr/syno/synoman/webman/modules/authenticate.cgi}
ADMINS=${FREESCOUT_ADMINS:-administrators}

reply() { printf 'Status: %s\r\nContent-Type: %s\r\nCache-Control: no-store\r\n\r\n%s' "$1" "$2" "$3"; exit 0; }
error() { reply "$1" application/json "{\"error\":\"$2\"}"; }

# Who's asking: DSM's own sign-in check names the user, from their session.
user=$("$AUTH" 2>/dev/null | head -1 | tr -cd 'A-Za-z0-9._@-')
[[ -n "$user" ]] || error "401 Unauthorized" "Sign in to DSM first."
if id -Gn "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$ADMINS"; then role=admin; else role=viewer; fi
admin_only() { [[ "$role" == admin ]] || error "403 Forbidden" "Only DSM administrators can do that."; }

param() { sed -n "s/^\(.*&\)\{0,1\}$1=\([^&]*\).*$/\2/p" <<< "$2" | head -1; }   # $1: a literal from this script
decode() { local v=${1//+/ }; printf '%b' "${v//%/\\x}"; }
listed_backup() { [[ "$1" =~ ^freescout-[0-9]{8}-[0-9]{4}(-[a-z]{1,12})?\.tar$ ]] && grep -qF "\"name\":\"$1\"" "$VAR/status.json" 2>/dev/null; }

if [[ "${REQUEST_METHOD:-GET}" == GET ]]; then
  action=$(param action "${QUERY_STRING:-}")
  [[ "$action" == status || "$action" == changelog || "$action" == modimg ]] || admin_only
  case "$action" in
    status)
      touch "$VAR/watching" 2>/dev/null   # the setup container refreshes the dearer parts while this is fresh
      state=$(tr -cd 'a-z' < "$VAR/state" 2>/dev/null)
      status=$(cat "$VAR/status.json" 2>/dev/null); status=${status:-null}
      phase=$(head -c 160 "$VAR/phase" 2>/dev/null | tr -d '\000-\037"\\')
      reply "200 OK" application/json "{\"role\":\"$role\",\"user\":\"$user\",\"state\":\"${state:-unknown}\",\"phase\":\"$phase\",\"now\":$(date +%s),\"pending\":$([[ -f "$VAR/request" ]] && echo true || echo false),\"status\":$status}" ;;
    log)
      part=$(param part "${QUERY_STRING:-}")
      case "$part" in
        setup|"") reply "200 OK" "text/plain; charset=utf-8" "$(tail -n 400 "$VAR/package.log" 2>/dev/null)" ;;
        app|db|scheduler|worker|laravel|fetch) reply "200 OK" "text/plain; charset=utf-8" "$(cat "$VAR/logs/$part.log" 2>/dev/null || echo "Nothing here yet — it comes in a moment while the window is open.")" ;;
        *) error "400 Bad Request" "Unknown part." ;;
      esac ;;
    report)
      [[ -f "$VAR/report.txt" ]] || error "404 Not Found" "No report has been made yet."
      printf 'Status: 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Disposition: attachment; filename="freescout-report-%s.txt"\r\n\r\n' "$(date -r "$VAR/report.txt" +%Y%m%d-%H%M)"
      cat "$VAR/report.txt"; exit 0 ;;
    backup)
      name=$(param name "${QUERY_STRING:-}")
      listed_backup "$name" && [[ -f "$SHARE/backups/$name" ]] || error "404 Not Found" "No such backup."
      printf 'Status: 200 OK\r\nContent-Type: application/x-tar\r\nContent-Length: %s\r\nContent-Disposition: attachment; filename="%s"\r\n\r\n' "$(stat -c %s "$SHARE/backups/$name")" "$name"
      cat "$SHARE/backups/$name"; exit 0 ;;
    changelog) reply "200 OK" "text/plain; charset=utf-8" "$(cat "$PKG/CHANGELOG.md" 2>/dev/null)" ;;
    modimg)
      alias=$(param alias "${QUERY_STRING:-}")
      [[ "$alias" =~ ^[a-z0-9]{1,40}$ ]] || error "404 Not Found" "No such module."
      for ext in png jpg jpeg gif svg; do [[ -f "$VAR/modules/logos/$alias.$ext" ]] && break; ext=""; done
      [[ -n "$ext" ]] || error "404 Not Found" "No logo."
      case "$ext" in png) type=image/png ;; jpg|jpeg) type=image/jpeg ;; gif) type=image/gif ;; svg) type=image/svg+xml ;; esac
      printf 'Status: 200 OK\r\nContent-Type: %s\r\nCache-Control: max-age=3600\r\n\r\n' "$type"
      cat "$VAR/modules/logos/$alias.$ext"; exit 0 ;;
    *) error "400 Bad Request" "Unknown request." ;;
  esac
fi

[[ "${REQUEST_METHOD:-}" == POST ]] || error "405 Method Not Allowed" "Unknown request."
admin_only
[[ "${CONTENT_LENGTH:-0}" =~ ^[0-9]+$ ]] && (( CONTENT_LENGTH > 0 && CONTENT_LENGTH < 4096 )) || error "400 Bad Request" "Unknown request."
read -r -n "$CONTENT_LENGTH" body
action=$(param action "$body")

# Two things are kept here rather than passed on: the window's switches, and
# the one-time password the setup container left.
case "$action" in
  prefs)
    nightly=$(param nightly "$body"); keep=$(param keep "$body")
    [[ "$nightly" =~ ^[01]$ ]] || error "400 Bad Request" "Nightly is on or off."
    [[ "$keep" =~ ^[0-9]{1,3}$ ]] && (( keep >= 1 && keep <= 365 )) || error "400 Bad Request" "Keep backups for 1 to 365 days."
    printf "NIGHTLY='%s'\nKEEP='%s'\n" "$nightly" "$keep" > "$VAR/prefs.tmp" && mv "$VAR/prefs.tmp" "$VAR/prefs" || error "500 Internal Server Error" "Couldn't keep that."
    reply "200 OK" application/json '{"ok":true}' ;;
  take_secret)
    [[ -f "$VAR/secret.json" ]] || error "404 Not Found" "There's no new password waiting — it's shown once, and may have been collected already."
    secret=$(cat "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"
    reply "200 OK" application/json "$secret" ;;
esac

[[ -f "$VAR/request" ]] && error "409 Conflict" "FreeScout is still busy with the last request."
case "$action" in
  restart|logout|backup|fetch|retryjobs|flushjobs|updateapp|upgrade|check|clearcache|report|modcheck|cleansendlog|cleannotifications|cleantmp|clearlogs) lines="ACTION='$action'" ;;
  modinstall|modupdate|modactivate|moddeactivate|modremove)
    alias=$(param alias "$body")
    [[ "$alias" =~ ^[a-z0-9]{1,40}$ ]] || error "400 Bad Request" "Pick a module."
    lines="ACTION='$action'
MODULE='$alias'" ;;
  reset|userenable|userdisable|userdelete)
    id=$(param user_id "$body")
    [[ "$id" =~ ^[0-9]{1,9}$ ]] || error "400 Bad Request" "Pick a user."
    lines="ACTION='$action'
USER_ID='$id'" ;;
  userrole)
    id=$(param user_id "$body"); role=$(param role "$body")
    [[ "$id" =~ ^[0-9]{1,9}$ ]] || error "400 Bad Request" "Pick a user."
    [[ "$role" =~ ^[12]$ ]] || error "400 Bad Request" "A role is administrator or agent."
    lines="ACTION='userrole'
USER_ID='$id'
ROLE='$role'" ;;
  newadmin)
    email=$(decode "$(param email "$body")"); first=$(decode "$(param first "$body")"); last=$(decode "$(param last "$body")")
    [[ "$email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || error "400 Bad Request" "An email address, like you@example.com."
    [[ "$first" =~ ^[A-Za-z0-9._-]{1,40}$ && "$last" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || error "400 Bad Request" "Names here are letters and digits only (they can be changed in FreeScout later)."
    lines="ACTION='newadmin'
EMAIL='$email'
FIRST_NAME='$first'
LAST_NAME='$last'" ;;
  restore|delbackup)
    name=$(param name "$body")
    listed_backup "$name" || error "400 Bad Request" "Pick a backup from the list."
    lines="ACTION='$action'
BACKUP='$name'" ;;
  settings)
    url=$(decode "$(param url "$body")"); port=$(param port "$body"); ssl=$(param ssl_proxy "$body"); tz=$(decode "$(param tz "$body")")
    [[ "$url" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{2,5})?$ ]] || error "400 Bad Request" "The address is http://name-or-ip:port or https://your.domain, with nothing after it."
    [[ "$port" =~ ^[0-9]{2,5}$ ]] && (( port >= 1024 && port <= 65535 )) || error "400 Bad Request" "The port is a number from 1024 to 65535."
    [[ "$ssl" =~ ^[01]$ ]] || error "400 Bad Request" "Behind HTTPS is on or off."
    [[ "$tz" =~ ^([A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+)+|UTC)$ ]] || error "400 Bad Request" "A time zone looks like Europe/London."
    lines="ACTION='settings'
APP_URL='$url'
HTTP_PORT='$port'
SSL_PROXY='$ssl'
APP_TZ='$tz'" ;;
  wipe)
    phrase=$(decode "$(param confirm "$body")")
    [[ "$phrase" == "remove everything" ]] || error "400 Bad Request" "Type exactly: remove everything"
    lines="ACTION='wipe'
CONFIRM='REMOVEEVERYTHING'" ;;
  maintenance)
    on=$(param on "$body")
    [[ "$on" =~ ^[01]$ ]] || error "400 Bad Request" "Maintenance mode is on or off."
    lines="ACTION='maintenance'
ON='$on'" ;;
  *) error "400 Bad Request" "Unknown request." ;;
esac

# Whole, or not at all: the setup container only sees a finished file.
printf '%s\nBY=%s\n' "$lines" "'$user'" > "$VAR/request.tmp" && mv "$VAR/request.tmp" "$VAR/request" \
  || error "500 Internal Server Error" "Couldn't pass the request on."
reply "202 Accepted" application/json '{"ok":true}'
