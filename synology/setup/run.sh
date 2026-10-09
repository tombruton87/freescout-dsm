#!/usr/bin/env bash
#
# The setup container's life: install FreeScout into the shared folder, start
# it, keep watch, and do the things only root can — backups, a new password
# for a locked-out administrator, mail-queue repairs, updates, a support
# report. Runs as root with Docker's socket (setup/compose.yaml).
#
# Everything the package's own user leaves for it ($VAR/answers.env from the
# wizard, $VAR/request from the window's api.cgi, $VAR/prefs) is read as
# data — every line matched, every key allow-listed, every value re-checked —
# and never sourced or eval'd. What it leaves for the window ($VAR/status.json,
# logs, a report, a one-time password) is written whole and owned by the
# package's user, which is who api.cgi runs as.
set -euo pipefail

# A test can set these (tests/e2e.sh runs this container against a scratch
# share); nothing but setup/compose.yaml sets this container's environment.
PKG=${FREESCOUT_PKG:-/pkg}
VAR=${FREESCOUT_VAR:-/pkgvar}
APP=${FREESCOUT_APP:-/var/packages/freescout/shares/freescout}
LOG=$VAR/package.log
APP_ID="FreeScout.AppInstance"
REPO="tombruton87/freescout-dsm"          # where releases (and the Update button) come from
UPDATES=updates                           # under $APP
export COMPOSE_PROJECT_NAME=freescout

BUSY=""; LAST="null"; UPDATE_AT=0; DISK_AT=0; STOPPING=0; WIPED=0
ADMINS_JSON="[]"; USERS_JSON="[]"; MAIL_JSON="null"; DISK_JSON="null"; UPDATE_JSON="null"; IMAGE_UPDATE="null"
STORAGE_JSON="null"; STORAGE_AT=0; ACTIVITY_JSON="null"; ACTIVITY_AT=0
HOST_UID=1000; HOST_GID=1000

# ------------------------------------------------------------------ basics
say() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" | tee -a "$LOG"; }
set_state() { echo "$1" > "$VAR/state"; }          # starting|running|failed|stopped — start-stop-status reads it
phase() { printf '%s\n' "$1" > "$VAR/phase.tmp" && mv "$VAR/phase.tmp" "$VAR/phase"; say "$1"; }   # what start-up is doing, for the window
publish_log() { cp "$LOG" "$APP/package.log" 2>/dev/null || true; }
failed() { say "✗ $*"; set_state failed; write_status 2>/dev/null || true; publish_log; exit 1; }   # restart: "no" keeps it stopped
fresh() { [[ -f "$1" ]] && (( $(date +%s) - $(stat -c %Y "$1") < $2 )); }
env_get() { grep -E "^$1=" "$APP/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
env_set() {   # key value — .env rewritten whole; values are from validated inputs or made here
  { grep -vE "^$1=" "$APP/.env" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } > "$APP/.env.tmp"
  chmod 600 "$APP/.env.tmp"; mv "$APP/.env.tmp" "$APP/.env"
}
json() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$(tr -d '\000-\037' <<< "$s")"; }
for_window() { chown "$HOST_UID:$HOST_GID" "$1.tmp" 2>/dev/null || true; chmod 600 "$1.tmp"; mv "$1.tmp" "$1"; }
now() { date +%s; }
rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }
compose() { docker compose -f "$APP/compose.yaml" --project-directory "$APP" "$@"; }
# A short-lived container over one of FreeScout's volumes (the setup image
# has tar and du): in_volume <volume> <ro|rw> [host dir to mount at /out] -- cmd…
# Nothing from the share is mounted into it: what goes in arrives on its stdin,
# what comes out leaves on its stdout — so DSM's share paths and ACLs never matter.
in_volume() {
  local vol=$1 mode=$2 out=${3:-}; shift 3; [[ "${1:-}" == -- ]] && shift
  docker run --rm -i --entrypoint sh -v "freescout_$vol:/vol:$mode" freescout-setup:local -c "$*"
}
artisan() { docker exec freescout-app sudo -H -u nginx php /www/html/artisan "$@"; }
sql() { docker exec -i -e MYSQL_PWD="$DB_ROOT_PASS" freescout-db mariadb -uroot -N -B freescout; }   # SQL on stdin, rows as TSV
sql_root() { docker exec -i -e MYSQL_PWD="$DB_ROOT_PASS" freescout-db mariadb -uroot -N -B; }

# A file the package's user wrote: only the names given, each with a value of
# its own shape, and the whole file refused on one bad line.
read_settings() {   # file, allowed names…
  local file=$1 line key value re="^([A-Z_]+)='([A-Za-z0-9._/+@:-]*)'$"; shift
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $re ]] || return 1
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    [[ " $* " == *" $key "* ]] || return 1
    [[ -z "$value" ]] && continue
    case "$key" in
      FS_LAN_IP)                 [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ;;
      FS_TZ|APP_TZ)              [[ "$value" =~ ^([A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+)+|UTC)$ ]] ;;
      FS_HTTP_PORT|HTTP_PORT)    [[ "$value" =~ ^[0-9]{2,5}$ ]] && (( value >= 1024 && value <= 65535 )) ;;
      FS_ADMIN_EMAIL|EMAIL)      [[ "$value" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ;;
      FS_ADMIN_FIRST|FS_ADMIN_LAST|FIRST_NAME|LAST_NAME) [[ "$value" =~ ^[A-Za-z0-9._-]{1,40}$ ]] ;;
      FS_ADMIN_PASS_HEX)         [[ "$value" =~ ^([0-9a-f]{2}){8,64}$ ]] ;;
      FS_HOST_UID|FS_HOST_GID)   [[ "$value" =~ ^[0-9]{1,6}$ ]] ;;
      ACTION)                    [[ "$value" =~ ^(restart|reset|newadmin|logout|backup|restore|delbackup|settings|fetch|retryjobs|flushjobs|updateapp|upgrade|check|maintenance|clearcache|report|modinstall|modupdate|modactivate|moddeactivate|modremove|modcheck|userenable|userdisable|userrole|userdelete|cleansendlog|cleannotifications|cleantmp|clearlogs|wipe)$ ]] ;;
      CONFIRM)                   [[ "$value" == REMOVEEVERYTHING ]] ;;
      ROLE)                      [[ "$value" =~ ^[12]$ ]] ;;
      MODULE)                    [[ "$value" =~ ^[a-z0-9]{1,40}$ ]] ;;
      BY)                        [[ "$value" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] ;;
      USER_ID)                   [[ "$value" =~ ^[0-9]{1,9}$ ]] ;;
      BACKUP)                    [[ "$value" =~ ^freescout-[0-9]{8}-[0-9]{4}(-[a-z]{1,12})?\.tar$ ]] ;;
      APP_URL)                   [[ "$value" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{2,5})?$ ]] ;;
      SSL_PROXY|ON)              [[ "$value" =~ ^[01]$ ]] ;;
      *) false ;;
    esac || return 1
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$file"
}
ANSWER_KEYS="FS_LAN_IP FS_TZ FS_HTTP_PORT FS_ADMIN_EMAIL FS_ADMIN_FIRST FS_ADMIN_LAST FS_ADMIN_PASS_HEX FS_HOST_UID FS_HOST_GID"
REQUEST_KEYS="ACTION BY USER_ID EMAIL FIRST_NAME LAST_NAME BACKUP APP_URL HTTP_PORT SSL_PROXY APP_TZ ON MODULE ROLE CONFIRM"
clear_request_vars() { unset ACTION BY USER_ID EMAIL FIRST_NAME LAST_NAME BACKUP APP_URL HTTP_PORT SSL_PROXY APP_TZ ON MODULE ROLE CONFIRM; }

# The window's switches ($VAR/prefs, written by api.cgi): a number each, by name.
pref() {   # name default
  local v
  v=$(sed -n "s/^$1='\([0-9]\{1,3\}\)'$/\1/p" "$VAR/prefs" 2>/dev/null | tail -1)
  echo "${v:-$2}"
}

# DSM's firewall list of applications, as .env has the port now. DSM wrote the
# file from the package before the wizard ran, so with the default port.
sync_dsm() {
  local http sc=""
  http=$(env_get HTTP_PORT); [[ -n "$http" ]] || return 0
  for sc in /dsm-etc/services.d/freescout.sc /dsm-etc/service.d/freescout.sc ""; do [[ -f "$sc" ]] && break; done
  [[ -n "$sc" ]] || { say "no freescout.sc under /usr/local/etc to update"; return 0; }
  cat > "$sc" 2>/dev/null <<SC
[freescout_web]
title="FreeScout: web app"
desc="FreeScout help desk"
port_forward="no"
dst.ports="${http}/tcp"
SC
  [[ $? == 0 ]] && say "the firewall's application list: FreeScout on $http" || say "couldn't rewrite $sc for the firewall's application list"
}

# A DSM notification: synodsmnotify only runs as root on the Synology itself,
# so a short-lived container steps into its namespaces. Strings: ui/texts.
# Each message goes at most once per `hours`.
notify() {   # key, hours between, values for its {0} {1}…
  local key=$1 hours=$2 mark arg args=(); shift 2
  for arg in "$@"; do args+=("$(printf '%s' "$arg" | tr -d '\000-\037' | cut -c1-80)"); done
  mkdir -p "$VAR/notified"
  mark="$VAR/notified/$key-$(printf '%s|' "${args[@]}" | md5sum | cut -c1-12)"
  fresh "$mark" $(( hours * 3600 )) && return 0
  touch "$mark"
  if docker run --rm --privileged --pid=host --network=host --entrypoint nsenter freescout-setup:local \
       -t 1 -m -u -i -n -p -- /usr/syno/bin/synodsmnotify -c "$APP_ID" @administrators \
       "$APP_ID:notification:title" "$APP_ID:notification:$key" "${args[@]}" >> "$LOG" 2>&1; then
    say "told DSM: $key${args[*]:+ (${args[*]})}"
  else
    say "a DSM notification ($key) didn't go — the lines above say why"
  fi
}

# ------------------------------------------------------- the app's containers
state_of() {   # name → "status health"
  docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$1" 2>/dev/null || echo "missing -"
}
app_up() { local s; read -r s _ < <(state_of freescout-app); [[ "$s" == running ]]; }
db_up() { local s; read -r s _ < <(state_of freescout-db); [[ "$s" == running ]]; }

# Waits for FreeScout to answer on its port (this container is on the host's
# network), saying so every half minute. The first start migrates the database.
wait_ready() {   # seconds
  local limit=${1:-600} t=0 port
  port=$(env_get HTTP_PORT)
  while (( t < limit )); do
    (( STOPPING )) && stop
    local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/login" 2>/dev/null)
    if [[ "$code" =~ ^(2|3|503) ]]; then say "✓ FreeScout answers on port $port$([[ "$code" == 503 ]] && echo " (in maintenance mode)")"; return 0; fi
    app_up || db_up || { say "FreeScout's containers aren't running"; return 1; }
    (( t % 30 == 0 )) && say "waiting for FreeScout to answer ($t s)…"
    sleep 5; t=$(( t + 5 ))
  done
  say "FreeScout hasn't answered after $limit s"; container_logs; return 1
}
# What the containers themselves said, for the package log — one exported
# log should be enough to see why a start failed.
container_logs() {
  local c
  for c in freescout-db freescout-app; do
    say "--- last lines from $c ($(docker inspect -f '{{.State.Status}}, exit {{.State.ExitCode}}' "$c" 2>/dev/null || echo missing)):"
    docker logs --tail 40 "$c" 2>&1 | sed 's/^/    /' | tee -a "$LOG" >/dev/null || true
  done
}

# Starts (or re-starts, after a settings change) FreeScout's compose project.
# The first administrator's password, if the wizard left one, goes in through
# the environment for this one `up` and is then forgotten.
start_app() {
  local pass="" hex
  hex=${FS_ADMIN_PASS_HEX:-}
  [[ -n "$hex" ]] && pass=$(printf '%b' "$(sed 's/../\\x&/g' <<< "$hex")")
  # Pull only what isn't here: a pull on every start is slow on a NAS and, with
  # Docker Hub's anonymous limit, can stall for hours. Updates pull on purpose.
  local img
  for img in "$(env_get FREESCOUT_IMAGE)" "$(env_get MARIADB_IMAGE)"; do
    [[ -n "$img" ]] || continue
    docker image inspect "$img" >/dev/null 2>&1 && continue
    phase "pulling $img (a few hundred MB; follow it in the log)"
    docker pull "$img" 2>&1 | grep -vE '^\s*$' | tail -n 20 | tee -a "$LOG" >/dev/null || true
  done
  phase "starting FreeScout's containers"
  ADMIN_PASS="$pass" compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { container_logs; return 1; }
  heal_modules
  phase "waiting for FreeScout to answer on port $(env_get HTTP_PORT)"
  if [[ -n "$hex" ]]; then
    # Forget the password: the wizard's file is rewritten without it.
    grep -v '^FS_ADMIN_PASS_HEX=' "$VAR/answers.env" > "$VAR/answers.env.tmp" && mv "$VAR/answers.env.tmp" "$VAR/answers.env"
    unset FS_ADMIN_PASS_HEX
    say "the first administrator (${FS_ADMIN_EMAIL:-?}) is made on this first start; their password isn't kept anywhere"
  fi
  wait_ready 600
}

# ----------------------------------------------------------- what's known
# The image keeps "1.8.245 first installed on …" beside FreeScout's code.
freescout_version() { docker exec freescout-app cat /www/html/.freescout-version 2>/dev/null | awk 'NR == 1 {print $1}' | tr -cd '0-9.' | head -c 20; }
in_maintenance() { docker exec freescout-app test -f /www/html/storage/framework/down 2>/dev/null; }

# Every agent, with the last sign-in FreeScout's activity log has for them.
list_users() {
  app_up && db_up || { echo "[]"; return 0; }
  printf '%s\n' "SELECT u.id, u.email, u.first_name, u.last_name, u.role, u.status, u.invite_state, UNIX_TIMESTAMP(u.created_at),
      IFNULL((SELECT UNIX_TIMESTAMP(MAX(a.created_at)) FROM activity_logs a WHERE a.causer_id = u.id AND a.causer_type LIKE '%User' AND a.description = 'login'), 0)
    FROM users u ORDER BY u.status, u.id;" | sql 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {id: (.[0] | tonumber), email: .[1],
        name: (((.[2] // "") + " " + (.[3] // "")) | gsub("NULL"; "") | gsub("^ +| +$"; "")),
        role: (.[4] | tonumber), status: (.[5] | tonumber), invite: (.[6] | tonumber? // 0),
        created: (.[7] | tonumber? // 0), last_login: (.[8] | tonumber? // 0)})' 2>/dev/null \
    || echo "[]"
}
list_admins() { jq -c 'map(select(.role == 2)) | map({id, email, name, status})' <<< "$USERS_JSON" 2>/dev/null || echo "[]"; }

# FreeScout's own User code, for the few things the window does to accounts.
# Values go through env(1) (sudo drops the environment) and were matched first.
fs_user_php() {   # id, code using $u (the user) and $me (an active administrator)
  [[ "$1" =~ ^[0-9]{1,9}$ ]] || return 1
  docker exec freescout-app sudo -H -u nginx env FS_UID="$1" php -r '
    require "/www/html/vendor/autoload.php"; $app = require "/www/html/bootstrap/app.php";
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    $u = \App\User::find((int) getenv("FS_UID")); if (!$u) { fwrite(STDERR, "no such user\n"); exit(2); }
    $me = \App\User::where("role", \App\User::ROLE_ADMIN)->where("status", \App\User::STATUS_ACTIVE)->where("id", "<>", $u->id)->first() ?: $u;
    '"$2" >> "$LOG" 2>&1
}
# The last active administrator can't be disabled, demoted or removed.
last_admin() {   # id → 0 if others remain
  local n; n=$(printf "SELECT COUNT(*) FROM users WHERE role = 2 AND status = 1 AND id <> %s;\n" "$1" | sql 2>/dev/null | tr -cd '0-9')
  [[ "${n:-0}" == 0 ]]
}
user_name() { jq -r --argjson id "$1" '.[] | select(.id == $id) | (if .name != "" then .name else .email end)' <<< "$USERS_JSON" 2>/dev/null | head -1; }
user_action() {   # action id [role]
  local act=$1 id=$2 role=${3:-} who
  app_up && db_up || { MSG="FreeScout has to be running to change a user."; return 1; }
  modules_state 0; USERS_JSON=$(list_users)
  who=$(user_name "$id"); [[ -n "$who" ]] || { MSG="There's no user with that id."; return 1; }
  case "$act" in
    userdisable) last_admin "$id" && { MSG="$who is the last active administrator — make someone else an administrator first."; return 1; }
                 fs_user_php "$id" '$u->status = \App\User::STATUS_DISABLED; $u->remember_token = null; $u->save();' && MSG="$who is disabled and can't sign in." ;;
    userenable)  fs_user_php "$id" '$u->status = \App\User::STATUS_ACTIVE; $u->save();' && MSG="$who can sign in again." ;;
    userrole)    [[ "$role" == 1 ]] && last_admin "$id" && { MSG="$who is the last active administrator — make someone else an administrator first."; return 1; }
                 fs_user_php "$id" "\$u->role = $role; \$u->save();" && MSG="$who is now $([[ "$role" == 2 ]] && echo "an administrator" || echo "an agent")." ;;
    userdelete)  last_admin "$id" && { MSG="$who is the last active administrator — make someone else an administrator first."; return 1; }
                 fs_user_php "$id" '$u->deleteUser($me, []);' && MSG="$who was removed; their conversations are unassigned and their email address freed." ;;
  esac || { MSG="FreeScout didn't make that change — the log has what it said."; return 1; }
  say "✓ $act: $MSG"
}

mail_health() {
  local failed queued mailboxes worker sched_at sched_last
  app_up && db_up || { echo "null"; return 0; }
  failed=$(printf 'SELECT COUNT(*) FROM failed_jobs;\n' | sql 2>/dev/null | tr -cd '0-9'); failed=${failed:-0}
  queued=$(printf 'SELECT COUNT(*) FROM jobs;\n' | sql 2>/dev/null | tr -cd '0-9'); queued=${queued:-0}
  mailboxes=$(printf 'SELECT COUNT(*) FROM mailboxes;\n' | sql 2>/dev/null | tr -cd '0-9'); mailboxes=${mailboxes:-0}
  if docker exec freescout-app pgrep -f 'queue:work' >/dev/null 2>&1; then worker=running; else worker=stopped; fi
  sched_at=$(docker exec freescout-app stat -c %Y /logs/laravel/scheduler.log 2>/dev/null | tr -cd '0-9'); sched_at=${sched_at:-0}
  sched_last=$(docker exec freescout-app tail -n 1 /logs/laravel/scheduler.log 2>/dev/null | cut -c1-160)
  jq -n -c --argjson failed "$failed" --argjson queued "$queued" --argjson mailboxes "$mailboxes" \
    --arg worker "$worker" --argjson sched_at "$sched_at" --arg sched_last "$sched_last" \
    '{failed: $failed, queued: $queued, mailboxes: $mailboxes, worker: $worker, scheduler_at: $sched_at, scheduler_last: $sched_last}'
}

disk_usage() {
  local data db backups free
  data=$(in_volume app-data ro "" -- du -sm /vol 2>/dev/null | cut -f1)
  db=$(in_volume db-data ro "" -- du -sm /vol 2>/dev/null | cut -f1)
  backups=$(du -sm "$APP/backups" 2>/dev/null | cut -f1); free=$(df -Pm "$APP" 2>/dev/null | awk 'NR == 2 {print $4}')
  jq -n -c --argjson data "${data:-0}" --argjson db "${db:-0}" --argjson backups "${backups:-0}" --argjson free "${free:-0}" \
    '{data_mb: $data, db_mb: $db, backups_mb: $backups, free_mb: $free}'
}

list_backups() {
  local f
  for f in "$APP"/backups/freescout-*.tar; do
    [[ -f "$f" ]] || continue
    printf '%s\t%s\t%s\n' "$(basename "$f")" "$(stat -c %s "$f")" "$(stat -c %Y "$f")"
  done | sort -r | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], size: (.[1] | tonumber), at: (.[2] | tonumber)})'
}

# How FreeScout is, for the window (ui/api.cgi only reads this). Written
# whole, owned by the package's user. The dearer parts (users, mail, disk)
# are refreshed only while someone has the window open.
write_status() {
  local a_state a_health d_state d_health
  read -r a_state a_health < <(state_of freescout-app)
  read -r d_state d_health < <(state_of freescout-db)
  jq -n -c \
    --argjson at "$(now)" --arg build "$BUILD" --arg busy "$BUSY" --argjson last "$LAST" \
    --arg a_state "$a_state" --arg a_health "$a_health" --arg d_state "$d_state" --arg d_health "$d_health" \
    --arg version "$(freescout_version)" --arg image "$(env_get FREESCOUT_IMAGE)" \
    --arg url "$(env_get APP_URL)" --arg port "$(env_get HTTP_PORT)" --arg lan_ip "$(env_get LAN_IP)" \
    --arg tz "$(env_get TZ)" --arg ssl_proxy "$(env_get SSL_PROXY)" \
    --argjson maintenance "$(in_maintenance && echo true || echo false)" \
    --argjson admins "$ADMINS_JSON" --argjson users "$USERS_JSON" --argjson mail "$MAIL_JSON" --argjson disk "$DISK_JSON" --argjson storage "$STORAGE_JSON" --argjson activity "$ACTIVITY_JSON" \
    --argjson backups "$(list_backups)" --argjson nightly "$(pref NIGHTLY 1)" --argjson keep "$(pref KEEP 14)" \
    --argjson backup_last "$(cat "$VAR/backup.last" 2>/dev/null || echo null)" \
    --argjson update "$UPDATE_JSON" --argjson image_update "$IMAGE_UPDATE" \
    --argjson secret "$([[ -f "$VAR/secret.json" ]] && echo true || echo false)" --argjson modules "$MODULES_JSON" \
    '{at: $at, build: $build, busy: $busy, last: $last, modules: $modules,
      app: {state: $a_state, health: $a_health}, db: {state: $d_state, health: $d_health},
      version: $version, image: $image, url: $url, port: $port, lan_ip: $lan_ip, tz: $tz, ssl_proxy: ($ssl_proxy == "1"),
      maintenance: $maintenance, admins: $admins, users: $users, mail: $mail, disk: $disk, storage: $storage, activity: $activity,
      backups: $backups, backup: {nightly: ($nightly == 1), keep: $keep, last: $backup_last},
      update: $update, image_update: $image_update, secret: $secret}' > "$VAR/status.json.tmp" 2>/dev/null \
    && for_window "$VAR/status.json"
}

# Logs for the window, while it's open: each written whole.
write_logs() {
  mkdir -p "$VAR/logs"; chown "$HOST_UID:$HOST_GID" "$VAR/logs" 2>/dev/null || true
  docker logs --tail 300 freescout-app > "$VAR/logs/app.log.tmp" 2>&1 || true; for_window "$VAR/logs/app.log"
  docker logs --tail 200 freescout-db > "$VAR/logs/db.log.tmp" 2>&1 || true; for_window "$VAR/logs/db.log"
  docker exec freescout-app tail -n 200 /logs/laravel/scheduler.log > "$VAR/logs/scheduler.log.tmp" 2>/dev/null || true; for_window "$VAR/logs/scheduler.log"
  docker exec freescout-app tail -n 200 /logs/laravel/queue-worker.log > "$VAR/logs/worker.log.tmp" 2>/dev/null || true; for_window "$VAR/logs/worker.log"
  docker exec freescout-app sh -c 'f=$(ls -t /www/html/storage/logs/laravel*.log 2>/dev/null | head -1); [ -n "$f" ] && tail -n 300 "$f"' \
    > "$VAR/logs/laravel.log.tmp" 2>/dev/null || true; for_window "$VAR/logs/laravel.log"
}

# Where the space goes: attachments per mailbox and biggest tables (from the
# database), folders in the data and logs volumes (one helper call each).
storage_report() {
  local mailboxes tables rows dirs logs dbv
  app_up && db_up || { echo "null"; return 0; }
  mailboxes=$(printf '%s\n' "SELECT m.name, COUNT(a.id), IFNULL(SUM(a.size), 0) FROM attachments a JOIN threads t ON t.id = a.thread_id JOIN conversations c ON c.id = t.conversation_id JOIN mailboxes m ON m.id = c.mailbox_id GROUP BY m.id, m.name ORDER BY 3 DESC LIMIT 30;" | sql 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], count: (.[1] | tonumber? // 0), bytes: (.[2] | tonumber? // 0)})' 2>/dev/null || echo "[]")
  tables=$(printf '%s\n' "SELECT table_name, data_length + index_length, table_rows FROM information_schema.tables WHERE table_schema = 'freescout' ORDER BY 2 DESC LIMIT 12;" | sql 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], bytes: (.[1] | tonumber? // 0), rows: (.[2] | tonumber? // 0)})' 2>/dev/null || echo "[]")
  rows=$(printf '%s\n' "SELECT (SELECT COUNT(*) FROM send_logs), (SELECT COUNT(*) FROM notifications), (SELECT COUNT(*) FROM activity_logs), (SELECT COUNT(*) FROM conversations), (SELECT COUNT(*) FROM customers), (SELECT COUNT(*) FROM attachments);" | sql 2>/dev/null \
    | jq -R -c 'split("\t") | {send_logs: (.[0] | tonumber? // 0), notifications: (.[1] | tonumber? // 0), activity: (.[2] | tonumber? // 0), conversations: (.[3] | tonumber? // 0), customers: (.[4] | tonumber? // 0), attachments: (.[5] | tonumber? // 0)}' 2>/dev/null | head -1); [[ -n "$rows" ]] || rows="{}"
  dirs=$(in_volume app-data ro "" -- 'cd /vol && for d in storage/app/attachment storage/app storage/logs storage/framework Modules config .; do [ -e "$d" ] && printf "%s\t%s\n" "$d" "$(du -sm "$d" 2>/dev/null | cut -f1)"; done' 2>/dev/null </dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: (if .[0] == "." then "data" else .[0] end), value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}")
  logs=$(in_volume app-logs ro "" -- 'cd /vol && for d in laravel nginx php-fpm .; do [ -e "$d" ] && printf "%s\t%s\n" "$d" "$(du -sm "$d" 2>/dev/null | cut -f1)"; done' 2>/dev/null </dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: (if .[0] == "." then "logs" else .[0] end), value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}")
  dbv=$(in_volume db-data ro "" -- du -sm /vol 2>/dev/null </dev/null | cut -f1); dbv=${dbv:-0}
  jq -n -c --argjson mailboxes "$mailboxes" --argjson tables "$tables" --argjson rows "$rows" --argjson dirs "$dirs" --argjson logs "$logs" --argjson dbv "$dbv" --argjson at "$(now)" \
    '{at: $at, mailboxes: $mailboxes, tables: $tables, rows: $rows, dirs: $dirs, logs: $logs, db_mb: $dbv}'
}

# Who signed in, from where, and who failed: FreeScout's own activity log.
# A burst of failed sign-ins is told to DSM.
activity_report() {
  local entries byip hour
  app_up && db_up || { echo "null"; return 0; }
  entries=$(printf '%s\n' "SELECT a.id, UNIX_TIMESTAMP(a.created_at), a.description, IFNULL(u.email, ''), IFNULL(JSON_UNQUOTE(JSON_EXTRACT(a.properties, '$.ip')), ''), IFNULL(JSON_UNQUOTE(JSON_EXTRACT(a.properties, '$.email')), '') FROM activity_logs a LEFT JOIN users u ON u.id = a.causer_id AND a.causer_type LIKE '%User' WHERE a.log_name = 'users' ORDER BY a.id DESC LIMIT 200;" | sql 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {id: (.[0] | tonumber? // 0), at: (.[1] | tonumber? // 0), what: .[2], who: (if (.[3] // "") != "" then .[3] else (.[5] // "") end), ip: (.[4] // "")})' 2>/dev/null || echo "[]")
  byip=$(printf '%s\n' "SELECT IFNULL(JSON_UNQUOTE(JSON_EXTRACT(properties, '$.ip')), '?'), COUNT(*) FROM activity_logs WHERE log_name = 'users' AND description IN ('login_failed', 'locked') AND created_at > NOW() - INTERVAL 1 DAY GROUP BY 1 ORDER BY 2 DESC LIMIT 10;" | sql 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {ip: .[0], count: (.[1] | tonumber? // 0)})' 2>/dev/null || echo "[]")
  hour=$(printf '%s\n' "SELECT COUNT(*) FROM activity_logs WHERE log_name = 'users' AND description IN ('login_failed', 'locked') AND created_at > NOW() - INTERVAL 1 HOUR;" | sql 2>/dev/null | tr -cd '0-9'); hour=${hour:-0}
  (( hour >= 20 )) && notify bruteforce 6 "$hour"
  jq -n -c --argjson entries "$entries" --argjson byip "$byip" --argjson hour "$hour" --argjson at "$(now)" '{at: $at, entries: $entries, failed_by_ip: $byip, failed_last_hour: $hour}'
}

refresh_rich() {
  USERS_JSON=$(list_users); ADMINS_JSON=$(list_admins); MAIL_JSON=$(mail_health); modules_state
  if (( $(now) - DISK_AT > 600 )); then DISK_JSON=$(disk_usage); DISK_AT=$(now); fi
  if (( $(now) - STORAGE_AT > 600 )); then STORAGE_JSON=$(storage_report); STORAGE_AT=$(now); fi
  if (( $(now) - ACTIVITY_AT > 60 )); then ACTIVITY_JSON=$(activity_report); ACTIVITY_AT=$(now); fi
}

# -------------------------------------------------------------- the watchdog
# A container that's stopped for a minute and a half is started again, and
# DSM told. One that's been started three times in an hour is left, and DSM
# told it needs a look instead.
declare -A BAD_SINCE=() RESTARTS=()
watchdog() {
  [[ -z "$BUSY" && "$(cat "$VAR/state" 2>/dev/null)" != removed ]] || return 0
  local name state health t recent
  for name in db app; do
    read -r state health < <(state_of "freescout-$name")
    if [[ "$state" == running && "$health" != unhealthy ]]; then BAD_SINCE[$name]=""; continue; fi
    [[ -n "${BAD_SINCE[$name]:-}" ]] || { BAD_SINCE[$name]=$(now); continue; }
    (( $(now) - BAD_SINCE[$name] >= 90 )) || continue
    recent=0; for t in ${RESTARTS[$name]:-}; do (( $(now) - t < 3600 )) && (( recent++ )); done
    if (( recent >= 3 )); then notify failing 6 "freescout-$name" "$recent"; continue; fi
    say "watchdog: freescout-$name $([[ "$state" == running ]] && echo "stopped answering" || echo "is $state") — starting it again"
    if [[ "$state" == running ]]; then docker restart "freescout-$name" >> "$LOG" 2>&1 || true
    else compose up -d --no-deps "$name" >> "$LOG" 2>&1 || true; fi
    RESTARTS[$name]="${RESTARTS[$name]:-} $(now)"; BAD_SINCE[$name]=""
    notify restarted 1 "freescout-$name"
  done
}

# ------------------------------------------------------------------ backups
# A backup is one tar: the database (mariadb-dump, gzipped), FreeScout's data
# folder (its config with APP_KEY — which encrypts mailbox passwords — plus
# attachments and modules), the package's .env, and a MANIFEST.
MADE=""
make_backup() {   # [suffix] → the file's name in $MADE
  local name dir work
  MADE=""
  name="freescout-$(date +%Y%m%d-%H%M)${1:+-$1}"
  work="$APP/backups/.work"; dir="$work/$name"
  rm -rf "$work"; mkdir -p "$dir"
  db_up || { say "✗ can't back up: the database isn't running"; return 1; }
  say "backup $name: the database"
  if ! docker exec -e MYSQL_PWD="$DB_ROOT_PASS" freescout-db mariadb-dump -uroot --single-transaction --quick --routines --triggers --events freescout 2>>"$LOG" | gzip > "$dir/db.sql.gz" \
     || [[ "${PIPESTATUS[0]}" != 0 ]]; then say "✗ the database dump didn't finish"; rm -rf "$work"; return 1; fi
  say "backup $name: files (config, attachments, modules)"
  in_volume app-data ro "" -- 'tar -C / --transform "s|^vol|data|" -czf - vol' > "$dir/data.tar.gz" 2>>"$LOG" </dev/null \
    && [[ -s "$dir/data.tar.gz" ]] && tar -tzf "$dir/data.tar.gz" >/dev/null 2>&1 || { say "✗ the files didn't tar"; rm -rf "$work"; return 1; }
  cp "$APP/.env" "$dir/env"
  printf 'package=freescout\nbuild=%s\nfreescout=%s\nat=%s\n' "$BUILD" "$(freescout_version)" "$(now)" > "$dir/MANIFEST"
  tar -C "$work" -cf "$APP/backups/$name.tar.tmp" "$name" && mv "$APP/backups/$name.tar.tmp" "$APP/backups/$name.tar" \
    || { say "✗ the backup file didn't finish"; rm -rf "$work" "$APP/backups/$name.tar.tmp"; return 1; }
  rm -rf "$work"
  chown "$HOST_UID:$HOST_GID" "$APP/backups/$name.tar" 2>/dev/null || true; chmod 640 "$APP/backups/$name.tar" 2>/dev/null || true
  say "✓ backup $name.tar ($(du -h "$APP/backups/$name.tar" | cut -f1))"
  MADE="$name.tar"
}
record_backup() {   # ok name
  printf '{"at":%s,"ok":%s,"name":%s}\n' "$(now)" "$1" "$(json "${2:-}")" > "$VAR/backup.last.tmp"; for_window "$VAR/backup.last"
}
prune_backups() {
  local keep count
  keep=$(pref KEEP 14); count=$(ls "$APP"/backups/freescout-*.tar 2>/dev/null | wc -l)
  (( count > 1 )) || return 0
  find "$APP/backups" -maxdepth 1 -name 'freescout-*.tar' -mtime +"$keep" -print -delete 2>/dev/null \
    | while read -r f; do say "backup $(basename "$f") was older than $keep days and was removed"; done
}
# Due at 02:00; made on the first tick after that, so one that was missed
# (the package stopped or restarting at the time) is caught up, not skipped.
nightly_backup() {
  local due last
  [[ "$(pref NIGHTLY 1)" == 1 && -z "$BUSY" && "$WIPED" == 0 ]] || return 0
  due=$(date -d "$(date +%Y-%m-%d) 02:00" +%s 2>/dev/null) || return 0
  (( $(now) < due )) && due=$(( due - 86400 ))
  last=$(cat "$VAR/backup.nightly" 2>/dev/null | tr -cd '0-9'); last=${last:-0}
  (( last < due )) || return 0
  echo "$(now)" > "$VAR/backup.nightly"          # one attempt per night, whatever comes of it
  BUSY=backup; write_status
  say "the nightly backup"
  if make_backup nightly; then record_backup true "$MADE"; prune_backups
  else record_backup false ""; notify backupfailed 12; fi
  BUSY=""; write_status; publish_log
}

restore_backup() {   # file name (validated)
  local file="$APP/backups/$BACKUP" work dir name safety
  [[ -f "$file" ]] || { MSG="There's no backup called $BACKUP."; return 1; }
  name=${BACKUP%.tar}; work="$APP/backups/.restore"; dir="$work/$name"
  rm -rf "$work"; mkdir -p "$work"
  tar -C "$work" -xf "$file" 2>>"$LOG" || { MSG="That backup couldn't be unpacked."; rm -rf "$work"; return 1; }
  if ! grep -qx 'package=freescout' "$dir/MANIFEST" 2>/dev/null || [[ ! -f "$dir/db.sql.gz" || ! -f "$dir/data.tar.gz" ]]; then
    MSG="That file isn't a FreeScout backup."; rm -rf "$work"; return 1
  fi
  say "restoring $BACKUP — first, a backup of how things are now"
  make_backup pre-restore || { MSG="Couldn't back up the current state first, so nothing was restored."; rm -rf "$work"; return 1; }
  safety=$MADE; record_backup true "$safety"
  say "stopping FreeScout's web app while the database and files are put back"
  compose stop -t 60 app >> "$LOG" 2>&1 || true
  say "restoring the database"
  printf 'DROP DATABASE IF EXISTS freescout; CREATE DATABASE freescout CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' | sql_root \
    || { MSG="The database couldn't be re-made; the web app is left stopped — the log says more."; rm -rf "$work"; return 1; }
  if ! gunzip -c "$dir/db.sql.gz" | sql 2>>"$LOG"; then
    MSG="The database didn't load from the backup; the web app is left stopped — the log says more. $safety has the state from just before."; rm -rf "$work"; return 1
  fi
  say "restoring files"
  if ! in_volume app-data rw "" -- 'find /vol -mindepth 1 -delete && tar -C /vol --strip-components=1 -xzf -' < "$dir/data.tar.gz" 2>>"$LOG"; then
    MSG="The files didn't unpack into FreeScout's data volume; the web app is left stopped. Restore again, or $safety."; rm -rf "$work"; return 1
  fi
  rm -rf "$work"
  say "starting FreeScout again"
  compose up -d app >> "$LOG" 2>&1 || true
  wait_ready 600 || { MSG="Restored, but FreeScout hasn't come back up yet — see the log."; return 1; }
  MSG="Restored from $BACKUP. The state from just before is in $safety."
}

# ------------------------------------------------- the first administrator
# A locked-out administrator gets a new password, made here, shown once in
# the window (api.cgi hands it over and removes it) and written nowhere else.
# The account is made active again and its remembered sessions dropped.
reset_password() {
  local email new hash
  app_up && db_up || { MSG="FreeScout has to be running to set a password."; return 1; }
  email=$(printf 'SELECT email FROM users WHERE id=%s;\n' "$USER_ID" | sql 2>/dev/null | head -1)
  [[ "$email" =~ ^[^[:space:]]+@[^[:space:]]+$ ]] || { MSG="There's no user with that id."; return 1; }
  new=$(rand 16)
  hash=$(docker exec -e NEWPASS="$new" freescout-app php -r 'echo password_hash(getenv("NEWPASS"), PASSWORD_BCRYPT);' 2>/dev/null)
  [[ "$hash" =~ ^\$2y\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]] || { MSG="The password couldn't be hashed inside FreeScout's container."; return 1; }
  printf "UPDATE users SET password='%s', status=1, remember_token=NULL WHERE id=%s;\n" "$hash" "$USER_ID" | sql 2>>"$LOG" \
    || { MSG="The database didn't take the new password — see the log."; return 1; }
  leave_secret "$email" "$new" reset
  say "✓ a new password was set for $email, and the account made active"
  MSG="A new password for $email is ready — it's shown once, below."
}
leave_secret() {   # email password kind
  jq -n -c --arg email "$1" --arg password "$2" --arg kind "$3" --argjson at "$(now)" \
    '{email: $email, password: $password, kind: $kind, at: $at}' > "$VAR/secret.json.tmp" && for_window "$VAR/secret.json"
}
new_admin() {
  local new out count
  app_up && db_up || { MSG="FreeScout has to be running to add a user."; return 1; }
  count=$(printf "SELECT COUNT(*) FROM users WHERE email='%s';\n" "$EMAIL" | sql 2>/dev/null | tr -cd '0-9')
  [[ "${count:-0}" == 0 ]] || { MSG="There's already a user with the email $EMAIL — reset their password instead."; return 1; }
  new=$(rand 16)
  if ! out=$(artisan -n freescout:create-user --role=admin --firstName="$FIRST_NAME" --lastName="$LAST_NAME" --email="$EMAIL" --password="$new" 2>&1); then
    printf '%s\n' "${out//$new/••••}" | tail -n 5 | sed 's/^/    /' >> "$LOG"
    MSG="FreeScout didn't create the user — the log says what it said."; return 1
  fi
  leave_secret "$EMAIL" "$new" new
  say "✓ administrator $EMAIL ($FIRST_NAME $LAST_NAME) was created"
  MSG="Administrator $EMAIL was created — their password is shown once, below."
}
expire_secret() { [[ -f "$VAR/secret.json" ]] && ! fresh "$VAR/secret.json" 900 && rm -f "$VAR/secret.json" && say "the one-time password wasn't collected in 15 minutes and was discarded"; true; }

# ------------------------------------------------------------------ updates
# Twice a day: is there a newer package on GitHub, and a newer FreeScout
# image in the registry? Both only looked at, never acted on by themselves.
check_updates() {
  local release latest page spk
  UPDATE_AT=$(now)
  local code
  code=$(curl -sS --max-time 15 -o "$VAR/release.json" -w '%{http_code}' "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || echo 0)
  release=$(cat "$VAR/release.json" 2>/dev/null); rm -f "$VAR/release.json"
  if [[ "$code" == 404 ]]; then
    UPDATE_JSON=$(jq -n -c --argjson at "$UPDATE_AT" '{checked: $at, error: "no release has been published yet"}')
  elif [[ "$code" != 200 ]]; then
    UPDATE_JSON=$(jq -n -c --argjson at "$UPDATE_AT" --arg code "$code" '{checked: $at, error: ("GitHub could not be reached (" + $code + ")")}')
  else
    latest=$(jq -r '.tag_name // ""' <<< "$release" | sed -E 's/^v//' | tr -cd '0-9A-Za-z.-')
    page=$(jq -r '.html_url // ""' <<< "$release"); spk=$(jq -r '[.assets[]? | .browser_download_url | select(endswith(".spk"))][0] // ""' <<< "$release")
    [[ "$page" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/tag/[A-Za-z0-9_.-]+$ ]] || page=""
    [[ "$spk" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/[A-Za-z0-9_./-]+\.spk$ ]] || spk=""
    UPDATE_JSON=$(jq -n -c --argjson at "$UPDATE_AT" --arg latest "$latest" --arg page "$page" --arg spk "$spk" --arg build "$BUILD" \
      '{checked: $at, latest: $latest, page: $page, spk: $spk, newer: ($latest != "" and $spk != "" and ([$latest, $build] | sort | .[1]) == $latest and $latest != $build)}')
  fi
  check_image_update
  refresh_catalog || true
  local pkg_latest img_state
  pkg_latest=$(jq -r '.latest // "?"' <<< "$UPDATE_JSON")
  img_state=$(jq -r 'if .available then "newer available" elif .error then .error else "current" end' <<< "$IMAGE_UPDATE")
  say "looked for updates: package $pkg_latest (this is $BUILD); FreeScout image: $img_state"
}
check_image_update() {
  local img name tag token remote local_digest
  img=$(env_get FREESCOUT_IMAGE); img=${img:-nfrastack/freescout:latest}
  name=${img%%:*}; tag=latest; [[ "$img" == *:* ]] && tag=${img##*:}
  [[ "$name" == */* ]] || name="library/$name"
  if [[ "$name" == *.*/* ]]; then IMAGE_UPDATE='{"error":"only Docker Hub images are checked"}'; return 0; fi   # ghcr.io/… and the like
  token=$(curl -fsS --max-time 15 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$name:pull" 2>/dev/null | jq -r '.token // ""')
  remote=$(curl -fsSI --max-time 15 -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/$name/manifests/$tag" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}' | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
  local_digest=$(docker image inspect "$img" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
  if [[ -z "$remote" ]]; then IMAGE_UPDATE='{"error":"the registry could not be reached"}'
  else IMAGE_UPDATE=$(jq -n -c --arg img "$img" --arg remote "$remote" --arg local "$local_digest" --argjson at "$(now)" \
    '{checked: $at, image: $img, available: ($local != "" and $remote != $local), remote: $remote[:19], local: $local[:19]}'); fi
}
update_app() {
  local safety
  say "updating FreeScout — first, a backup"
  make_backup pre-update || { MSG="Couldn't back up first, so FreeScout wasn't updated."; return 1; }
  safety=$MADE; record_backup true "$safety"
  say "pulling the newest images"
  compose pull 2>&1 | grep -vE '^\s*$' | tail -n 20 | tee -a "$LOG" >/dev/null || true
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { MSG="The updated containers didn't start — see the log."; return 1; }
  wait_ready 900 || { MSG="FreeScout was updated but hasn't answered yet — give it a few minutes, then see the log."; return 1; }
  docker image prune -f >/dev/null 2>&1 || true
  check_image_update
  MSG="FreeScout is updated to $(freescout_version). The state from before is in $safety."
}

# A newer package, from the window's Update button: its .spk from the GitHub
# release, handed to DSM's own installer (synopkg) — which only runs as root
# on the Synology itself. It runs in a helper container of its own, since
# upgrading the package stops this one. The new version reports how it went.
upgrade_package() {
  local url latest file got
  url=$(jq -r '.spk // ""' <<< "$UPDATE_JSON"); latest=$(jq -r '.latest // ""' <<< "$UPDATE_JSON")
  if [[ ! "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/[A-Za-z0-9_./-]+\.spk$ || ! "$latest" =~ ^[0-9A-Za-z.-]+$ ]]; then
    MSG="There's no newer package to install — look for updates first."; return 1
  fi
  mkdir -p "$APP/$UPDATES"; rm -f "$APP/$UPDATES"/freescout-*.spk "$APP/$UPDATES"/upgrade.*
  file="$APP/$UPDATES/freescout-$latest.spk"
  say "downloading the FreeScout package $latest"
  curl -fsSL --max-time 600 -o "$file" "$url" || { rm -f "$file"; MSG="The download didn't finish."; return 1; }
  got=$(tar -xOf "$file" INFO 2>/dev/null | sed -n 's/^version="\([0-9A-Za-z.-]*\)"$/\1/p')
  if ! tar -xOf "$file" INFO 2>/dev/null | grep -qx 'package="freescout"' || [[ -z "$got" || "$got" == "$BUILD" ]] \
     || [[ "$(printf '%s\n%s\n' "$got" "$BUILD" | sort -V | tail -1)" != "$got" ]]; then
    rm -f "$file"; MSG="That download isn't a newer FreeScout package (${got:-no version}), so it wasn't installed."; return 1
  fi
  printf '%s\n' "$BUILD" > "$APP/$UPDATES/upgrade.from"; printf '%s\n' "$got" > "$APP/$UPDATES/upgrade.to"
  say "handing FreeScout $got to Package Center — the package stops, and starts again with it"
  publish_log
  docker rm -f freescout-upgrade >/dev/null 2>&1 || true
  docker run -d --rm --privileged --pid=host --network=host --name freescout-upgrade --entrypoint busybox docker:27-cli \
      nsenter -t 1 -m -u -i -n -p -- sh -c '/usr/syno/bin/synopkg install "$1" > "$2" 2>&1; echo "exit $?" >> "$2"' \
      sh "$file" "$APP/$UPDATES/upgrade.log" >> "$LOG" 2>&1 \
    || { MSG="DSM's installer couldn't be started."; return 1; }
  MSG="Package Center is installing FreeScout $got; this window will go away and come back."
}
report_upgrade() {
  local from to result
  [[ -f "$APP/$UPDATES/upgrade.to" ]] || return 0
  docker ps -q --filter name='^freescout-upgrade$' 2>/dev/null | grep -q . && return 0   # still installing
  from=$(cat "$APP/$UPDATES/upgrade.from" 2>/dev/null); to=$(cat "$APP/$UPDATES/upgrade.to" 2>/dev/null)
  result=$(tail -n 20 "$APP/$UPDATES/upgrade.log" 2>/dev/null)
  if [[ "$BUILD" == "$to" ]]; then
    say "✓ updated from package $from to $to"
    LAST=$(jq -n -c --argjson at "$(now)" '{action: "upgrade", ok: true, message: "The package was updated.", at: $at, by: ""}')
  else
    say "✗ updating to package $to didn't finish — DSM's installer said:"
    printf '%s\n' "${result:-(nothing)}" | sed 's/^/    /' | tee -a "$LOG"
    LAST=$(jq -n -c --argjson at "$(now)" '{action: "upgrade", ok: false, message: "The package update did not finish, see the log.", at: $at, by: ""}')
  fi
  rm -f "$APP/$UPDATES"/freescout-*.spk "$APP/$UPDATES"/upgrade.*
}

# ------------------------------------------------------------ support report
# What a helper needs to see, with the household taken out: addresses, email
# addresses and host names become stable stand-ins (lan-ip-1, email-2…), so the
# report still reads but can be pasted into a public issue.
redact() {
  awk '
    function swap(re, pre,   m, out) {
      out = ""
      while (match($0, re)) {
        m = substr($0, RSTART, RLENGTH)
        if (!(m in seen)) seen[m] = pre "-" (++n[pre])
        out = out substr($0, 1, RSTART - 1) seen[m]; $0 = substr($0, RSTART + RLENGTH)
      }
      $0 = out $0
    }
    { swap("[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]+", "email")
      swap("[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+", "lan-ip")
      swap("https?://[A-Za-z0-9.-]+(:[0-9]+)?", "site")
      print }'
}
make_report() {
  local f="$VAR/report.txt.tmp"
  {
    echo "FreeScout package support report — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "package: $BUILD; FreeScout: $(freescout_version); image: $(env_get FREESCOUT_IMAGE)"
    echo "DSM: $(sed -n 's/^productversion="\(.*\)"$/\1/p' /etc.defaults/VERSION 2>/dev/null) build $(sed -n 's/^buildnumber="\(.*\)"$/\1/p' /etc.defaults/VERSION 2>/dev/null); model: $(sed -n 's/^upnpmodelname="\(.*\)"$/\1/p' /etc/synoinfo.conf 2>/dev/null)"
    echo "Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null); setup runs as $(id -u):$(id -g)"
    echo; echo "== settings (.env, without secrets)"; grep -vE '^(DB_PASS|DB_ROOT_PASS)=' "$APP/.env" 2>/dev/null
    echo; echo "== status"; jq . "$VAR/status.json" 2>/dev/null | grep -vE '"(email|name|password)"'
    echo; echo "== containers"; docker ps -a --filter name=freescout- --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
    echo; echo "== disk"; df -Ph "$APP" 2>/dev/null; du -sh "$APP"/backups 2>/dev/null; docker system df 2>/dev/null
    echo; echo "== memory"; free -m 2>/dev/null
    echo; echo "== package log (last 300 lines)"; tail -n 300 "$LOG"
    echo; echo "== freescout-app (last 150 lines)"; docker logs --tail 150 freescout-app 2>&1
    echo; echo "== freescout-db (last 60 lines)"; docker logs --tail 60 freescout-db 2>&1
    echo; echo "== FreeScout's own log (last 150 lines)"; docker exec freescout-app sh -c 'f=$(ls -t /www/html/storage/logs/laravel*.log 2>/dev/null | head -1); [ -n "$f" ] && tail -n 150 "$f"' 2>/dev/null
    echo; echo "== scheduler (last 30 lines)"; docker exec freescout-app tail -n 30 /logs/laravel/scheduler.log 2>/dev/null
    echo; echo "== queue worker (last 30 lines)"; docker exec freescout-app tail -n 30 /logs/laravel/queue-worker.log 2>/dev/null
  } 2>/dev/null | redact > "$f" && for_window "$VAR/report.txt"
}

# ---------------------------------------------------------------- settings
apply_settings() {
  local changed=0 old_port
  old_port=$(env_get HTTP_PORT)
  [[ -n "${APP_URL:-}" ]] && { env_set APP_URL "$APP_URL"; changed=1; }
  [[ -n "${HTTP_PORT:-}" ]] && { env_set HTTP_PORT "$HTTP_PORT"; changed=1; }
  [[ -n "${APP_TZ:-}" ]] && { env_set TZ "$APP_TZ"; export TZ=$APP_TZ; changed=1; }
  if [[ -n "${SSL_PROXY:-}" ]]; then
    env_set SSL_PROXY "$SSL_PROXY"
    if [[ "$SSL_PROXY" == 1 ]]; then env_set TRUSTED_PROXIES '*'; env_set SECURE_COOKIE true
    else env_set TRUSTED_PROXIES unset; env_set SECURE_COOKIE unset; fi
    changed=1
  fi
  (( changed )) || { MSG="Nothing to change."; return 0; }
  say "settings: address $(env_get APP_URL), port $(env_get HTTP_PORT), time zone $(env_get TZ), behind HTTPS proxy: $(env_get SSL_PROXY)"
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { MSG="FreeScout didn't restart with the new settings — see the log."; return 1; }
  [[ "$(env_get HTTP_PORT)" != "$old_port" ]] && sync_dsm
  wait_ready 300 || { MSG="Settings saved, but FreeScout hasn't answered yet — see the log."; return 1; }
  artisan freescout:clear-cache >> "$LOG" 2>&1 || true
  MSG="Settings saved; FreeScout is up at $(env_get APP_URL)."
}


# ------------------------------------------------------------------ modules
# A small store for FreeScout modules kept on GitHub: the shipped catalog
# (modules/catalog.json) plus the owner's own list (modules.json in the share)
# name repositories; each repository's module.json gives the name, alias,
# description and logo, its latest release the version. Installing puts the
# release into the app-data volume under Modules/<Folder> and activates it
# the way FreeScout's own Modules page does (App\Module::setActive, then
# freescout:module-install). Everything read from the network is matched
# against a strict shape before it is used as a path or an argument.
MOD=$VAR/modules
MODULES_JSON="[]"; MODULES_AT=0; NGINX_UID=80; NGINX_GID=82
mod_re_alias='^[a-z0-9]{1,40}$'; mod_re_folder='^[A-Za-z0-9]{1,60}$'; mod_re_tag='^v?[0-9A-Za-z][0-9A-Za-z._-]{0,39}$'
mod_re_repo='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'

catalog_repos() {   # one JSON object per line: the shipped catalog, then the owner's modules.json in the share
  { jq -c '.modules[]? | select(.repo | type == "string")' "$PKG/modules/catalog.json" 2>/dev/null
    jq -c '.modules[]? | select(.repo | type == "string")' "$APP/modules.json" 2>/dev/null; } \
    | jq -c 'select(.repo | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
             | {repo, note: ((.note // "") | tostring | .[:200]), path: ((.path // "") | tostring),
                requires: ((.requires // []) | map(select(type == "object" and (.alias | type == "string")) | {alias, name: ((.name // .alias) | tostring | .[:60]), url: ((.url // "") | tostring | .[:200]), optional: ((.optional // false) == true), for: ((.for // "") | tostring | .[:120])})),
                composer_install: ((.composer_install // false) == true)}' 2>/dev/null \
    | awk -F'"repo":"' '{split($2, a, "\""); if (!seen[a[1]]++) print}'
}
# Official modules a catalogued one may need, by alias, for the card.
known_module() {   # alias → name<TAB>url
  case "$1" in
    apiwebhooks) printf 'API & Webhooks\thttps://freescout.net/module/api-webhooks/\n' ;;
    crm) printf 'Customers Management (CRM)\thttps://freescout.net/module/crm/\n' ;;
    customfields) printf 'Custom Fields\thttps://freescout.net/module/custom-fields/\n' ;;
    exportconversations) printf 'Export Conversations\thttps://freescout.net/module/export-conversations/\n' ;;
    snooze) printf 'Snooze\thttps://freescout.net/module/snooze/\n' ;;
    sendlater) printf 'Send Later\thttps://freescout.net/module/send-later/\n' ;;
    workflows) printf 'Workflows\thttps://freescout.net/module/workflows/\n' ;;
    kanban) printf 'Kanban\thttps://freescout.net/module/kanban/\n' ;;
    knowledgebase) printf 'Knowledge Base\thttps://freescout.net/module/knowledge-base/\n' ;;
    tags) printf 'Tags\thttps://freescout.net/module/tags/\n' ;;
    teams) printf 'Teams\thttps://freescout.net/module/teams/\n' ;;
    enduserportal) printf 'End-User Portal\thttps://freescout.net/module/end-user-portal/\n' ;;
    timetracking) printf 'Time Tracking\thttps://freescout.net/module/time-tracking/\n' ;;
    *) printf '%s\t\n' "$1" ;;
  esac
}

# Asks GitHub about every catalogued module: module.json from the default
# branch, the latest release, the logo. Writes $MOD/catalog.json whole.
refresh_catalog() {
  local item repo note path branch mj alias name folder desc version img tag rel code url ext entries="[]" entry err appver reqs comp
  mkdir -p "$MOD/logos"
  while IFS= read -r item; do
    repo=$(jq -r .repo <<< "$item"); note=$(jq -r .note <<< "$item"); path=$(jq -r .path <<< "$item"); reqs=$(jq -c .requires <<< "$item"); comp=$(jq -r .composer_install <<< "$item")
    [[ "$repo" =~ $mod_re_repo ]] || continue
    [[ -z "$path" || "$path" =~ ^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+){0,3}$ ]] || continue
    err=""; branch=main
    mj=$(curl -fsSL --max-time 15 "https://raw.githubusercontent.com/$repo/main/${path:+$path/}module.json" 2>/dev/null) \
      || { branch=master; mj=$(curl -fsSL --max-time 15 "https://raw.githubusercontent.com/$repo/master/${path:+$path/}module.json" 2>/dev/null) || { mj=""; err="no module.json on GitHub, or GitHub could not be reached"; }; }
    appver=$(jq -r '.requiredAppVersion // ""' <<< "$mj" 2>/dev/null | tr -cd '0-9.' | head -c 20)
    # What it needs: the catalog's list, plus aliases the module.json names (requires / requiredModules), named if known.
    reqs=$(jq -c --argjson cat "$reqs" --arg known "$(for a in $(jq -r '[(.requires // []), (.requiredModules // [])] | map(if type == "object" then keys elif type == "array" then map(select(type == "string")) else [] end) | add | .[]' <<< "$mj" 2>/dev/null | tr -cd 'a-z0-9\n' | sort -u); do printf '%s\t%s\n' "$a" "$(known_module "$a")"; done)" '
      ($known | split("\n") | map(select(length > 0) | split("\t") | {alias: .[0], name: (.[1] // .[0]), url: (.[2] // ""), optional: false, for: ""})) as $mine
      | ($cat + ($mine | map(select(.alias as $a | ($cat | map(.alias) | index($a)) == null))))' <<< "null" 2>/dev/null || echo "[]")
    alias=$(jq -r '.alias // ""' <<< "$mj" 2>/dev/null | tr -cd 'a-z0-9' | head -c 40)
    name=$(jq -r '.name // ""' <<< "$mj" 2>/dev/null | tr -d '\000-\037' | head -c 60)
    desc=$(jq -r '.description // ""' <<< "$mj" 2>/dev/null | tr -d '\000-\037' | head -c 400)
    version=$(jq -r '.version // ""' <<< "$mj" 2>/dev/null | tr -cd '0-9A-Za-z.-' | head -c 30)
    img=$(jq -r '.img // ""' <<< "$mj" 2>/dev/null | tr -d '\000-\037' | head -c 200)
    folder=$(jq -r '.providers[0] // ""' <<< "$mj" 2>/dev/null | sed -E 's/^Modules\\+([A-Za-z0-9]+)\\+.*$/\1/' | tr -cd 'A-Za-z0-9' | head -c 60)
    [[ -n "$folder" ]] || folder=$(tr -cd 'A-Za-z0-9' <<< "$name" | head -c 60)
    [[ -n "$mj" && ( ! "$alias" =~ $mod_re_alias || ! "$folder" =~ $mod_re_folder ) ]] && err="its module.json has no usable alias or provider"
    tag=""
    if [[ -z "$err" ]]; then
      # The latest release, without GitHub's rate-limited API: the releases/latest page redirects to the tag
      # (or back to /releases when there is none).
      local loc prev_tag
      # Redirects are followed (a repository renamed on GitHub answers with one first); the last Location seen is the tag's.
      loc=$(curl -sSIL --max-redirs 5 --max-time 20 "https://github.com/$repo/releases/latest" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "location:" {print $2}' | tail -1)
      prev_tag=$(jq -r --arg r "$repo" '.[] | select(.repo == $r) | .tag // ""' "$MOD/catalog.json" 2>/dev/null | head -1)
      if [[ "$loc" =~ /releases/tag/([^/?#]+)$ ]]; then
        tag=$(printf '%b' "${BASH_REMATCH[1]//%/\\x}" | head -c 40); [[ "$tag" =~ $mod_re_tag ]] || tag=""
      elif [[ "$loc" =~ /releases/?$ ]]; then tag=""              # GitHub says: no releases
      elif [[ "$prev_tag" =~ $mod_re_tag ]]; then tag=$prev_tag   # no clear answer this time: keep what was known
      elif [[ -z "$loc" ]]; then err="GitHub could not be reached"; fi
      [[ -n "$tag" ]] && version=$(sed -E 's/^[vV]//' <<< "$tag")
      # The logo: a file under the module's own Public folder, by a plain name — as FreeScout's path
      # (/modules/<alias>/…) or as a raw GitHub URL into the same repository.
      url=""; img=${img%%\?*}; img=${img#..}            # "…?v=1" and "../modules/…" are seen in the wild
      if [[ "$img" =~ ^/modules/$alias/([A-Za-z0-9_/-]+\.(png|jpg|jpeg|gif|svg))$ ]]; then
        url="https://raw.githubusercontent.com/$repo/$branch/${path:+$path/}Public/${BASH_REMATCH[1]}"; ext=${BASH_REMATCH[2]}
      elif [[ "$img" =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9_./%-]*/([A-Za-z0-9_-]+\.(png|jpg|jpeg|gif|svg))$ ]]; then
        url=$img; ext=${BASH_REMATCH[2]}          # a picture the module's author hosts (GitHub or their own site); 2 MB at most, nothing else
      fi
      if [[ -n "$url" ]]; then   # a logo already here stays if the fetch fails
        if curl -fsSL --max-time 20 --max-filesize 2000000 -o "$MOD/logos/$alias.$ext.tmp" "$url" 2>/dev/null && [[ -s "$MOD/logos/$alias.$ext.tmp" ]]; then
          find "$MOD/logos" -maxdepth 1 -name "$alias.*" ! -name "$alias.$ext.tmp" -delete 2>/dev/null
          for_window "$MOD/logos/$alias.$ext"
        else rm -f "$MOD/logos/$alias.$ext.tmp"; fi
      fi
    fi
    entry=$(jq -n -c --arg repo "$repo" --arg note "$note" --arg branch "$branch" --arg path "$path" --arg alias "$alias" --arg name "$name" --arg folder "$folder" \
      --arg desc "$desc" --arg version "$version" --arg tag "$tag" --arg err "$err" --argjson at "$(now)" --arg appver "$appver" --argjson reqs "$reqs" --argjson comp "$comp" \
      --arg logo "$(ls "$MOD/logos/$alias".* 2>/dev/null | head -1 | sed 's/.*\.//')" \
      '{repo: $repo, note: $note, branch: $branch, path: $path, alias: $alias, name: $name, folder: $folder, description: $desc, version: $version, tag: $tag, logo: $logo, error: $err, checked: $at, app_version: $appver, requires: $reqs, composer_install: $comp}')
    entries=$(jq -c --argjson e "$entry" '. + [$e]' <<< "$entries")
  done < <(catalog_repos)
  printf '%s\n' "$entries" > "$MOD/catalog.json.tmp" && for_window "$MOD/catalog.json"
  say "looked at the module catalog: $(jq -r 'map(select(.error == "")) | length' <<< "$entries") of $(jq -r 'length' <<< "$entries") modules answered"
  modules_state 1
}
catalog_entry() { jq -c --arg a "$1" '.[] | select(.alias == $a)' "$MOD/catalog.json" 2>/dev/null | head -1; }

# What's installed and active, joined with the catalog, for the window.
modules_state() {   # [1 to force]
  local force=${1:-0} active installed entry alias folder ver rec list="[]"
  (( force )) || (( $(now) - MODULES_AT > 60 )) || return 0
  MODULES_AT=$(now)
  heal_modules
  [[ -f "$MOD/catalog.json" ]] || { MODULES_JSON="[]"; return 0; }
  active="{}"; installed="{}"
  if app_up && db_up; then
    active=$(printf 'SELECT alias, active FROM modules;\n' | sql 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")) | map({key: .[0], value: (.[1] == "1")}) | from_entries' 2>/dev/null || echo "{}")
    # One trip into the container for everything: nginx's ids and every module.json's folder and version.
    local found
    found=$(docker exec freescout-app sh -c 'id -u nginx; id -g nginx; for f in /data/Modules/*/module.json; do [ -f "$f" ] || continue; d=${f%/module.json}; printf "%s\t%s\n" "${d##*/}" "$(sed -n "s/.*\"version\" *: *\"\([0-9A-Za-z.-]*\)\".*/\1/p" "$f" | head -1)"; done' 2>/dev/null)
    NGINX_UID=$(sed -n 1p <<< "$found" | tr -cd '0-9'); NGINX_UID=${NGINX_UID:-80}
    NGINX_GID=$(sed -n 2p <<< "$found" | tr -cd '0-9'); NGINX_GID=${NGINX_GID:-82}
    installed=$(jq -n -c --arg found "$(tail -n +3 <<< "$found")" --slurpfile cat "$MOD/catalog.json" '
      ($found | split("\n") | map(select(length > 0) | split("\t") | {folder: .[0], version: (.[1] // "")})) as $f
      | [ $cat[0][] | select(.alias != "") | . as $m | ($f[] | select(.folder == $m.folder) | {key: $m.alias, value: .version}) ] | from_entries' 2>/dev/null || echo "{}")
  fi
  rec=$(cat "$MOD/installed.json" 2>/dev/null); [[ "$rec" == \{* ]] || rec="{}"
  MODULES_JSON=$(jq -c --argjson active "$active" --argjson inst "$installed" --argjson rec "$rec" --arg fsv "$(freescout_version)" '
    map(. as $m | ($inst[$m.alias] // null) as $iv | ($rec[$m.alias] // "") as $it
      | {alias, name, repo, note, description, version, tag, logo, error, checked, app_version, composer_install, folder, path, branch,
         url: ("https://github.com/" + .repo),
         requires: ((.requires // []) | map(. + {active: ($active[.alias] // false)})),
         missing: ((.requires // []) | map(select(.optional | not) | select(($active[.alias] // false) | not) | .name)),
         app_ok: (.app_version == "" or $fsv == "" or (([.app_version, $fsv] | sort_by(split(".") | map(tonumber? // 0)) | .[0]) == .app_version)),
         installed: ($iv != null), installed_version: ($iv // ""), installed_tag: $it,
         active: ($active[$m.alias] // false),
         update: ($iv != null and (
           if $it != "" and $m.tag != "" then $it != $m.tag          # installed by this store: the release tag decides
           else ($m.version != "" and $iv != $m.version and ([$iv, $m.version] | sort_by(split(".") | map(tonumber? // 0)) | .[1]) == $m.version) end))})' "$MOD/catalog.json" 2>/dev/null || echo "[]")
}

# A module FreeScout's database has as active but whose folder is gone (deleted
# by hand, an update cut short) stops FreeScout booting at all: its provider
# class can't be found. So: deactivate any such module, straight in the
# database (FreeScout's own code can't run in that state), and say so.
heal_modules() {
  local present active alias n=0
  db_up || return 0
  present=$(docker exec freescout-app sh -c 'for f in /data/Modules/*/module.json; do [ -f "$f" ] && sed -n "s/.*\"alias\" *: *\"\([a-z0-9]*\)\".*/\1/p" "$f" | head -1; done' 2>/dev/null | tr -cd 'a-z0-9\n' | sort -u)
  [[ -n "$present" ]] || present="-"
  active=$(printf 'SELECT alias FROM modules WHERE active = 1;\n' | sql 2>/dev/null | tr -cd 'a-z0-9\n')
  for alias in $active; do
    [[ "$alias" =~ $mod_re_alias ]] || continue
    grep -qx "$alias" <<< "$present" && continue
    printf "UPDATE modules SET active = 0 WHERE alias = '%s';\n" "$alias" | sql 2>>"$LOG" || continue
    say "module $alias was active in FreeScout's database but its files are gone — deactivated it, so FreeScout can start"
    n=$(( n + 1 ))
  done
  # Laravel's cached config, its services manifest and FreeScout's cached providers list (in the file cache)
  # all still name the provider, and artisan can't even boot with them: drop them (they're made again), then
  # rebuild the caches.
  (( n )) && { docker exec freescout-app sh -c 'rm -f /www/html/bootstrap/cache/config.php /www/html/bootstrap/cache/services.php /www/html/bootstrap/cache/*_module.php; rm -rf /www/html/storage/framework/cache/data/*' >> "$LOG" 2>&1 || true
               artisan freescout:clear-cache >> "$LOG" 2>&1 || true; }
  return 0
}

mod_set_active() {   # alias 1|0 — through FreeScout's own code, as its Modules page does
  # (sudo drops the environment, so the two values go through env(1); both were matched against their shape.)
  [[ "$1" =~ $mod_re_alias && "$2" =~ ^[01]$ ]] || return 1
  if docker exec freescout-app sudo -H -u nginx env MOD_ALIAS="$1" MOD_ON="$2" php -r '
    require "/www/html/vendor/autoload.php"; $app = require "/www/html/bootstrap/app.php";
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    \App\Module::setActive(getenv("MOD_ALIAS"), getenv("MOD_ON") === "1");' >> "$LOG" 2>&1; then return 0; fi
  # FreeScout's code couldn't even boot (the lines above say why — usually another module that is
  # broken). The flag is a row in its modules table; set it there, so the install can still be worked on.
  say "FreeScout's own code couldn't run (above); setting the module's flag straight in the database instead"
  printf "INSERT INTO modules (alias, active) VALUES ('%s', %s) ON DUPLICATE KEY UPDATE active = %s;\n" "$1" "$2" "$2" | sql 2>>"$LOG"
}
# FreeScout caches the modules library's scan of the Modules folder for an
# hour (config modules.cache, key laravel-modules): a module just placed there
# isn't seen by freescout:module-install until that entry is gone.
mod_forget_scan() {
  artisan cache:forget laravel-modules >> "$LOG" 2>&1 || artisan cache:clear >> "$LOG" 2>&1 || true
}
mod_activate() {   # alias — register (migrations, public symlink, cache), as FreeScout's Modules page does
  local alias=$1 out
  mod_forget_scan
  mod_set_active "$alias" 1 || { MSG="FreeScout couldn't mark the module active — see the log."; return 1; }
  out=$(artisan freescout:module-install "$alias" 2>&1); printf '%s\n' "$out" | tail -n 12 | sed 's/^/    /' >> "$LOG"
  if ! grep -q 'Configuration cached successfully' <<< "$out"; then
    mod_set_active "$alias" 0 || true; artisan freescout:clear-cache >> "$LOG" 2>&1 || true
    # What FreeScout said, for the window: the telling lines, without colour codes, kept short.
    local said; said=$(printf '%s\n' "$out" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\000-\011\013-\037' | grep -iE 'error|exception|not found|missing|requires|fail|denied' | head -n 3 | cut -c1-200 | paste -sd' ' -)
    [[ -n "$said" ]] || said=$(printf '%s\n' "$out" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\000-\011\013-\037' | grep -vE '^\s*$' | tail -n 2 | cut -c1-200 | paste -sd' ' -)
    MSG="FreeScout didn't accept the module, so it was left inactive. It said: ${said:-nothing}"; return 1
  fi
  artisan freescout:clear-cache >> "$LOG" 2>&1 || true
}
# A module isn't installed or activated unless what it needs is there: every
# required module active in FreeScout, and FreeScout new enough. MSG says what's missing.
mod_requirements_ok() {   # alias
  local m missing appver fsv name
  modules_state 1
  m=$(jq -c --arg a "$1" '.[] | select(.alias == $a)' <<< "$MODULES_JSON" 2>/dev/null | head -1); [[ -n "$m" ]] || return 0
  name=$(jq -r '.name // .alias' <<< "$m"); missing=$(jq -r '.missing | join(" and ")' <<< "$m"); appver=$(jq -r '.app_version // ""' <<< "$m"); fsv=$(freescout_version)
  if [[ -n "$missing" ]]; then
    MSG="$name needs $missing installed and active in FreeScout first (FreeScout → Manage → Modules; see the card's links). Nothing was installed."; return 1
  fi
  if [[ "$(jq -r '.app_ok' <<< "$m")" == false ]]; then
    MSG="$name needs FreeScout $appver or newer; this is $fsv. Update FreeScout first (Updates tab). Nothing was installed."; return 1
  fi
}
mod_install() {   # alias (install or update)
  local entry alias=$1 repo folder tag branch url work
  app_up && db_up || { MSG="FreeScout has to be running to install a module."; return 1; }
  entry=$(catalog_entry "$alias"); [[ -n "$entry" ]] || { MSG="That module isn't in the catalog — look for updates first."; return 1; }
  mod_requirements_ok "$alias" || return 1
  repo=$(jq -r .repo <<< "$entry"); folder=$(jq -r .folder <<< "$entry"); tag=$(jq -r .tag <<< "$entry"); branch=$(jq -r .branch <<< "$entry")
  local path comp; path=$(jq -r '.path // ""' <<< "$entry"); comp=$(jq -r '.composer_install // false' <<< "$entry")
  [[ "$repo" =~ $mod_re_repo && "$folder" =~ $mod_re_folder && ( -z "$tag" || "$tag" =~ $mod_re_tag ) && "$branch" =~ ^(main|master)$ ]] || { MSG="The catalog entry for $alias isn't in order."; return 1; }
  [[ -z "$path" || "$path" =~ ^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+){0,3}$ ]] || { MSG="The catalog entry for $alias isn't in order."; return 1; }
  [[ -n "$tag" ]] && url="https://github.com/$repo/archive/refs/tags/$tag.tar.gz" || url="https://github.com/$repo/archive/refs/heads/$branch.tar.gz"
  say "module $alias: downloading ${tag:-$branch} of $repo"
  # The work folder is on the share: a helper container mounts it, and only
  # the share has the same path inside this container and on the Synology.
  work="$APP/$UPDATES/module-work"; rm -rf "$work"; mkdir -p "$work/src"
  curl -fsSL --max-time 300 --max-filesize 200000000 -o "$work/module.tar.gz" "$url" || { MSG="The module couldn't be downloaded from GitHub."; rm -rf "$work"; return 1; }
  # Look inside first: the archive's one top folder, then the module's folder under it.
  local top depth
  top=$(tar -tzf "$work/module.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1); [[ "$top" =~ ^[A-Za-z0-9._-]+$ ]] || { MSG="The download didn't unpack."; rm -rf "$work"; return 1; }
  tar -xzf "$work/module.tar.gz" -C "$work/src" -O "$top/${path:+$path/}module.json" > "$work/module.json" 2>/dev/null \
    || { MSG="The download has no ${path:+$path/}module.json."; rm -rf "$work"; return 1; }
  [[ "$(jq -r '.alias // ""' "$work/module.json" 2>/dev/null)" == "$alias" ]] || { MSG="What GitHub sent isn't the $alias module."; rm -rf "$work"; return 1; }
  depth=1; [[ -n "$path" ]] && depth=$(( 1 + $(tr -cd '/' <<< "$path" | wc -c) + 1 ))
  say "module $alias: putting it in Modules/$folder"
  # Streamed into the volume: the helper container gets the archive on stdin and keeps only the module's folder.
  in_volume app-data rw "" -- "rm -rf /vol/Modules/$folder && mkdir -p /vol/Modules/$folder && tar -C /vol/Modules/$folder --strip-components=$depth --wildcards -xzf - '$top/${path:+$path/}*' && chown -R $NGINX_UID:$NGINX_GID /vol/Modules/$folder" < "$work/module.tar.gz" 2>>"$LOG" \
    || { MSG="The module couldn't be put into FreeScout's data volume — see the log."; rm -rf "$work"; return 1; }
  rm -rf "$work"
  # Seen from FreeScout's own container, before anything is activated.
  if ! docker exec freescout-app test -f "/data/Modules/$folder/module.json" 2>/dev/null; then
    docker exec freescout-app sh -c "ls -la /data/Modules /data/Modules/$folder" >> "$LOG" 2>&1 || true
    MSG="The files were written, but FreeScout's container doesn't see Modules/$folder/module.json — the log shows what it sees."; return 1
  fi
  if [[ "$comp" == true ]]; then   # the module brings its own composer.json and loads its own vendor/
    say "module $alias: installing its PHP libraries with Composer (in its own folder)"
    if ! docker exec freescout-app sudo -H -u nginx env COMPOSER_HOME=/tmp/composer composer install --no-dev --no-interaction --no-progress --ignore-platform-reqs --working-dir="/data/Modules/$folder" >> "$LOG" 2>&1; then
      MSG="Composer couldn't install the module's PHP libraries — the log has what it said. The module's files are in place but it wasn't activated."; return 1
    fi
  fi
  say "module $alias: activating"
  mod_activate "$alias" || return 1
  jq -c --arg a "$alias" --arg t "${tag:-$branch}" '. + {($a): $t}' "$MOD/installed.json" 2>/dev/null > "$MOD/installed.json.tmp" 2>/dev/null \
    || jq -n -c --arg a "$alias" --arg t "${tag:-$branch}" '{($a): $t}' > "$MOD/installed.json.tmp"
  mv "$MOD/installed.json.tmp" "$MOD/installed.json"
  say "✓ module $alias ${tag:-$branch} is installed and active"
  MSG="$(jq -r .name <<< "$entry")${tag:+ $tag} is installed and active."
}
mod_remove() {   # alias
  local entry alias=$1 folder
  entry=$(catalog_entry "$alias"); folder=$(jq -r '.folder // ""' <<< "$entry")
  [[ "$folder" =~ $mod_re_folder ]] || { MSG="That module isn't in the catalog."; return 1; }
  if app_up && db_up; then mod_set_active "$alias" 0 || true; artisan freescout:clear-cache >> "$LOG" 2>&1 || true; fi
  in_volume app-data rw "" -- "rm -rf /vol/Modules/$folder" 2>>"$LOG" || { MSG="The module's folder couldn't be removed — see the log."; return 1; }
  app_up && mod_forget_scan
  jq -c --arg a "$alias" 'del(.[$a])' "$MOD/installed.json" 2>/dev/null > "$MOD/installed.json.tmp" && mv "$MOD/installed.json.tmp" "$MOD/installed.json" || true
  say "✓ module $alias was removed"
  MSG="$(jq -r .name <<< "$entry") was removed. Its settings and tables stay in the database, so installing it again picks them up."
}

# ------------------------------------------------------- removing everything
# The window's "Remove FreeScout and everything", confirmed by a typed phrase:
# FreeScout's containers, network and volumes (database, attachments and
# modules, logs), its images, the contents of the shared folder — then, on a
# Synology, a helper on the NAS itself uninstalls the package and deletes the
# shared folder with DSM's own tools, since the package can't remove itself.
wipe_everything() {
  [[ "${CONFIRM:-}" == REMOVEEVERYTHING ]] || { MSG="Not confirmed — nothing was removed."; return 1; }
  say "REMOVING EVERYTHING, as ${BY:-?} asked"
  say "stopping and removing FreeScout's containers, network and volumes"
  compose down --remove-orphans -v -t 30 >> "$LOG" 2>&1 || true
  docker rm -f freescout-app freescout-db >> "$LOG" 2>&1 || true
  docker volume rm freescout_app-data freescout_app-logs freescout_db-data >> "$LOG" 2>&1 || true
  docker network rm freescout_default >> "$LOG" 2>&1 || true
  say "removing FreeScout's images"
  docker image rm "$(env_get FREESCOUT_IMAGE)" "$(env_get MARIADB_IMAGE)" >> "$LOG" 2>&1 || true
  say "emptying the shared folder (backups, settings, logs, updates)"
  find "$APP" -mindepth 1 -maxdepth 1 ! -name 'package.log' -exec rm -rf {} + 2>>"$LOG" || true
  rm -rf "$VAR/modules" "$VAR/logs" "$VAR/status.json" "$VAR/secret.json" "$VAR/report.txt" "$VAR/backup.last" "$VAR/backup.nightly" "$VAR/prefs" "$VAR/answers.env" 2>/dev/null
  if [[ -f /etc.defaults/VERSION ]]; then
    say "handing the rest to DSM: uninstalling the package and deleting the freescout shared folder"
    publish_log
    docker rm -f freescout-remove >/dev/null 2>&1 || true
    docker run -d --rm --privileged --pid=host --network=host --name freescout-remove --entrypoint busybox docker:27-cli \
        nsenter -t 1 -m -u -i -n -p -- sh -c 'sleep 5; { /usr/syno/bin/synopkg uninstall freescout; /usr/syno/sbin/synoshare --del true freescout; echo "exit $?"; } > /tmp/freescout-removed.log 2>&1' \
      >> "$LOG" 2>&1 || { MSG="FreeScout's data is gone, but DSM's uninstaller couldn't be started: uninstall the package in Package Center and delete the freescout shared folder in Control Panel."; return 1; }
    MSG="FreeScout, its data and images are removed. Package Center is now uninstalling the package and deleting the freescout shared folder; this window goes away."
  else
    MSG="FreeScout, its data and images are removed. This isn't a Synology, so the package and shared folder are left for you to remove."
  fi
  set_state removed; WIPED=1          # from here the loop only keeps the window informed
}

# ---------------------------------------------- a request from the window
# ui/api.cgi wrote it (one at a time): read as data, acted on, answered in
# $LAST, which the window shows.
act() {
  local f="$VAR/request" ok=true started
  [[ -f "$f" ]] || return 0
  mv "$f" "$f.doing"                                 # taken, so a crash doesn't replay it
  clear_request_vars; MSG=""
  if ! read_settings "$f.doing" $REQUEST_KEYS || [[ -z "${ACTION:-}" ]]; then
    say "✗ ignoring a request that wasn't in order"; rm -f "$f.doing"; return 0
  fi
  rm -f "$f.doing"
  local log_from; log_from=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  say "request from ${BY:-?}: $ACTION"
  BUSY=$ACTION; write_status; started=$(now)
  case "$ACTION" in
    restart)     compose restart 2>&1 | tee -a "$LOG" >/dev/null && wait_ready 300 && MSG="FreeScout was restarted." || { ok=false; MSG=${MSG:-"FreeScout didn't come back after the restart — see the log."}; } ;;
    reset)       reset_password || ok=false ;;
    newadmin)    new_admin || ok=false ;;
    logout)      artisan freescout:logout-users >> "$LOG" 2>&1 && MSG="Everyone was signed out of FreeScout." || { ok=false; MSG="FreeScout couldn't sign everyone out — see the log."; } ;;
    backup)      if make_backup; then record_backup true "$MADE"; prune_backups; MSG="Backed up to $MADE."; else record_backup false ""; ok=false; MSG="The backup didn't finish — see the log."; fi ;;
    restore)     restore_backup || ok=false ;;
    delbackup)   if [[ -f "$APP/backups/$BACKUP" ]]; then rm -f "$APP/backups/$BACKUP"; say "backup $BACKUP was removed"; MSG="$BACKUP was removed."; else ok=false; MSG="There's no backup called $BACKUP."; fi ;;
    settings)    apply_settings || ok=false ;;
    fetch)       mkdir -p "$VAR/logs"; artisan freescout:fetch-emails --days=3 --unseen=1 > "$VAR/logs/fetch.log.tmp" 2>&1 || true; for_window "$VAR/logs/fetch.log"; MSG="Mail was fetched; what FreeScout said is under Mail." ;;
    retryjobs)   artisan queue:retry all >> "$LOG" 2>&1 && MSG="Failed jobs were put back in the queue." || { ok=false; MSG="The jobs couldn't be retried — see the log."; } ;;
    flushjobs)   artisan queue:flush >> "$LOG" 2>&1 && MSG="Failed jobs were cleared." || { ok=false; MSG="The failed jobs couldn't be cleared — see the log."; } ;;
    updateapp)   update_app || ok=false ;;
    upgrade)     upgrade_package || ok=false ;;
    check)       check_updates || true; MSG="Looked for updates." ;;
    maintenance) if [[ "${ON:-0}" == 1 ]]; then artisan down >> "$LOG" 2>&1 && MSG="FreeScout is in maintenance mode: visitors see a notice." || { ok=false; MSG="Couldn't turn maintenance mode on."; }
                 else artisan up >> "$LOG" 2>&1 && MSG="FreeScout is back for everyone." || { ok=false; MSG="Couldn't turn maintenance mode off."; }; fi ;;
    clearcache)  artisan freescout:clear-cache >> "$LOG" 2>&1 && MSG="FreeScout's caches were cleared." || { ok=false; MSG="The caches couldn't be cleared — see the log."; } ;;
    report)      make_report && MSG="The support report is ready to save." || { ok=false; MSG="The report couldn't be made."; } ;;
    modinstall|modupdate) mod_install "${MODULE:-}" || ok=false ;;
    modactivate) app_up && db_up && mod_requirements_ok "${MODULE:-}" && mod_activate "${MODULE:-}" && MSG="The module is active." || { ok=false; MSG=${MSG:-"FreeScout has to be running to activate a module."}; } ;;
    moddeactivate) app_up && db_up && mod_set_active "${MODULE:-}" 0 && { artisan freescout:clear-cache >> "$LOG" 2>&1 || true; MSG="The module is inactive; its files stay."; } || { ok=false; MSG="The module couldn't be deactivated — see the log."; } ;;
    modremove)   mod_remove "${MODULE:-}" || ok=false ;;
    modcheck)    refresh_catalog || true; MSG="Looked at the module catalog." ;;
    userenable|userdisable|userdelete) user_action "$ACTION" "${USER_ID:-0}" || ok=false ;;
    userrole)    user_action userrole "${USER_ID:-0}" "${ROLE:-}" || ok=false ;;
    wipe)        wipe_everything || ok=false ;;
    cleansendlog) artisan freescout:clean-send-log >> "$LOG" 2>&1 && MSG="The send log was cleaned (FreeScout keeps recent entries)." || { ok=false; MSG="FreeScout couldn't clean the send log — see the log."; } ;;
    cleannotifications) artisan freescout:clean-notifications-table >> "$LOG" 2>&1 && MSG="Old notifications were removed." || { ok=false; MSG="FreeScout couldn't clean notifications — see the log."; } ;;
    cleantmp)    out=$(artisan freescout:clean-tmp 2>&1); printf '%s\n' "$out" | tail -n 5 >> "$LOG"
                 if grep -qiE 'usage: find|busybox' <<< "$out"; then ok=false; MSG="FreeScout's clean-tmp uses find options this image's find doesn't have, so nothing was removed (FreeScout's own schedule hits the same; harmless)."
                 else MSG="Temporary files were removed."; fi ;;
    clearlogs)   docker exec freescout-app sh -c 'for f in /www/html/storage/logs/*.log /logs/laravel/*.log /logs/nginx/*.log /logs/php-fpm/*.log; do [ -f "$f" ] && : > "$f"; done' >> "$LOG" 2>&1 && MSG="FreeScout's, nginx's and PHP's log files were emptied." || { ok=false; MSG="The log files couldn't be emptied — see the log."; } ;;
  esac
  # What the log gained meanwhile, for the window to show under a failure: the telling lines, without colour codes.
  local detail=""
  [[ "$ok" == false ]] && detail=$(tail -n +"$(( log_from + 1 ))" "$LOG" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\000-\010\013-\037' | grep -avE '^\s*$|^ Container ' | tail -n 60 | cut -c1-300 | head -c 6000)
  LAST=$(jq -n -c --arg action "$ACTION" --argjson ok "$ok" --arg message "$MSG" --argjson at "$(now)" --arg by "${BY:-}" --argjson took "$(( $(now) - started ))" --arg detail "$detail" \
    '{action: $action, ok: $ok, message: $message, at: $at, by: $by, took: $took, detail: $detail}')
  say "$([[ "$ok" == true ]] && echo ✓ || echo ✗) $ACTION: $MSG"
  case "$ACTION" in wipe) ADMINS_JSON="[]"; USERS_JSON="[]"; MODULES_JSON="[]"; MAIL_JSON="null"; STORAGE_JSON="null"; ACTIVITY_JSON="null" ;; reset|newadmin|restore|backup|delbackup|updateapp|retryjobs|flushjobs|fetch|user*) refresh_rich ;; mod*) modules_state 1 ;; clean*|clearlogs) STORAGE_AT=0; refresh_rich ;; esac
  BUSY=""; write_status; publish_log
}

stop() {
  say "package stopping: taking FreeScout down"
  compose stop -t 30 >> "$LOG" 2>&1 || true
  set_state stopped; write_status 2>/dev/null || true; publish_log; exit 0
}
# The signal handler only raises a flag: a handler that runs commands while
# bash is mid-way through parsing a command substitution dies with
# "unexpected EOF while looking for matching `)'" and the stop never happens.
# The loop (and the start-up waits) act on the flag.
trap 'STOPPING=1' TERM INT
# If this script ends any other way, say so and show it: Package Center would
# otherwise keep showing "running" with nobody watching FreeScout.
unexpected_exit() {
  local rc=$?
  case "$(cat "$VAR/state" 2>/dev/null)" in stopped|failed) return 0 ;; esac
  say "✗ the setup container stopped unexpectedly (exit $rc). FreeScout may still be running, but nothing is watching it — Package Center → FreeScout → Run starts the watch again."
  set_state failed; publish_log
}
trap unexpected_exit EXIT

# ------------------------------------------------------------------- start
[[ -f "$LOG" ]] && tail -n 3000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
set_state starting
BUILD=$(cat "$PKG/build-id")
echo >> "$LOG"
say "package started: freescout $BUILD"

# Who this runs as, and whether Docker answers: what everything else depends on.
say "running as $(id -u):$(id -g) (groups $(id -G)); Docker's socket: $(stat -c 'owner %u:%g, mode %a' /var/run/docker.sock 2>/dev/null || echo 'not there')"
if v=$(docker version --format '{{.Server.Version}}' 2>&1); then say "Docker answers: $v"
else say "Docker doesn't answer: $v"; failed "The setup container can't use Docker. Container Manager ran it as $(id -u):$(id -g) — please send this log."; fi
[[ -d "$APP" && -w "$APP" ]] || failed "The freescout shared folder isn't there. DSM makes it when the package is installed — reinstalling the package should bring it back."

# A package upgrade has Container Manager recreate this container. Compose does
# that by renaming the old one to <id>_freescout-setup, making the new one and
# removing the old; cut short (a timeout), it leaves the renamed one, which is
# then what runs — and Container Manager, looking for "freescout-setup", can't
# find it and refuses every action. Put the name back, and clear stopped leftovers.
heal_name() {
  local id name state
  for id in $(docker ps -aq --filter label=com.docker.compose.project=freescout-setup --filter label=com.docker.compose.service=setup 2>/dev/null); do
    name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||'); state=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null)
    [[ "$name" =~ ^[0-9a-f]{12}_freescout-setup$ ]] || continue
    if [[ "$state" == running ]]; then
      if docker rename "$id" freescout-setup >> "$LOG" 2>&1; then say "this container had been left named $name by an interrupted recreate — renamed it back to freescout-setup"
      else say "this container is named $name (left by an interrupted recreate) and couldn't be renamed: Container Manager may show the setup container as missing. Package Center → Uninstall and install again puts it right; FreeScout's data stays."; fi
    else
      docker rm -f "$id" >/dev/null 2>&1 && say "removed a stopped leftover setup container ($name)"
    fi
  done
}
heal_name

if [[ -f "$VAR/answers.env" ]]; then
  read_settings "$VAR/answers.env" $ANSWER_KEYS || failed "The install wizard's answers weren't in order — reinstalling the package asks them again."
  say "using the answers from the install wizard"
fi
HOST_UID=${FS_HOST_UID:-$(env_get HOST_UID)}; HOST_UID=${HOST_UID:-1000}
HOST_GID=${FS_HOST_GID:-$(env_get HOST_GID)}; HOST_GID=${HOST_GID:-$HOST_UID}

# This version's compose file, into the shared folder (the app's data is
# whatever the containers have made there; the package only brings the file).
if [[ "$(cat "$APP/.package-files" 2>/dev/null)" != "$BUILD" ]]; then
  say "putting this version's files in the shared folder"
  cp "$PKG/app/compose.yaml" "$APP/compose.yaml.tmp" && mv "$APP/compose.yaml.tmp" "$APP/compose.yaml" \
    || failed "Couldn't put FreeScout's compose file in the shared folder."
  cp "$PKG/app/env.example" "$APP/env.example" 2>/dev/null || true
  echo "$BUILD" > "$APP/.package-files"
fi

# The first time: .env from the wizard's answers, with passwords made here.
if [[ ! -f "$APP/.env" ]]; then
  [[ -n "${FS_LAN_IP:-}" && -n "${FS_HTTP_PORT:-}" ]] || failed "There's no .env in the freescout shared folder and no answers from the install wizard — reinstalling the package asks them again."
  if docker volume inspect freescout_db-data >/dev/null 2>&1; then
    failed "There's a FreeScout database volume (freescout_db-data) from an earlier install, but no settings file (.env) in the shared folder, so its passwords are unknown. Either put the env file from a backup back as .env in the freescout shared folder, or remove the volumes freescout_db-data, freescout_app-data and freescout_app-logs in Container Manager → Volume (that deletes the old help desk) and run the package again."
  fi
  say "first start: writing .env from the wizard's answers"
  : > "$APP/.env"; chmod 600 "$APP/.env"
  env_set HTTP_PORT "$FS_HTTP_PORT"; env_set LAN_IP "$FS_LAN_IP"; env_set TZ "${FS_TZ:-UTC}"
  env_set APP_URL "http://$FS_LAN_IP:$FS_HTTP_PORT"; env_set SSL_PROXY 0; env_set TRUSTED_PROXIES unset; env_set SECURE_COOKIE unset
  env_set DB_PASS "$(rand 32)"; env_set DB_ROOT_PASS "$(rand 32)"
  env_set ADMIN_EMAIL "${FS_ADMIN_EMAIL:-admin@example.com}"; env_set ADMIN_FIRST_NAME "${FS_ADMIN_FIRST:-Admin}"; env_set ADMIN_LAST_NAME "${FS_ADMIN_LAST:-User}"
  env_set FREESCOUT_IMAGE nfrastack/freescout:latest; env_set MARIADB_IMAGE mariadb:11.4
  env_set HOST_UID "$HOST_UID"; env_set HOST_GID "$HOST_GID"
fi
DB_ROOT_PASS=$(env_get DB_ROOT_PASS)
[[ "$(env_get MARIADB_IMAGE)" == mariadb:11 ]] && env_set MARIADB_IMAGE mariadb:11.4   # builds before 0.1.0-2
if [[ -d "$APP/db" || -d "$APP/data" || -d "$APP/logs" ]]; then   # builds before 0.1.0-3 tried to keep these on the share
  say "FreeScout's data, logs and database now live in Docker volumes (freescout_app-data, freescout_app-logs, freescout_db-data); the data, logs and db folders in the shared folder are from an earlier attempt and can be deleted"
fi
[[ -n "$DB_ROOT_PASS" ]] || failed "The .env in the freescout shared folder has no database password — it's been edited by hand; restore it from a backup's env file."
export TZ; TZ=$(env_get TZ); TZ=${TZ:-UTC}

for d in backups "$UPDATES"; do mkdir -p "$APP/$d"; done   # every bind-mounted folder, before compose
chown "$HOST_UID:$HOST_GID" "$APP/backups" "$APP/$UPDATES" 2>/dev/null || true
mkdir -p "$VAR/logs"; chown "$HOST_UID:$HOST_GID" "$VAR/logs" 2>/dev/null || true
say "FreeScout's address: $(env_get APP_URL) (port $(env_get HTTP_PORT), time zone $TZ)"

start_app || failed "FreeScout couldn't start — the lines above say why. Package Center → FreeScout → Run tries again."
phase "first look at users, mail, modules and storage"
# From here on a failing command is a condition to report, not a reason to
# die: every function below says what went wrong and carries on watching. Nor
# may an unset variable (a value a container didn't answer in time) end the
# watch — every value is checked where it matters.
set +eu
sync_dsm
report_upgrade
set_state running; rm -f "$VAR/phase"; write_status; publish_log
say "✓ FreeScout $(freescout_version) is up at $(env_get APP_URL)"
refresh_rich; write_status
mkdir -p "$MOD/logos"; chown -R "$HOST_UID:$HOST_GID" "$MOD" 2>/dev/null || true
[[ -f "$MOD/catalog.json" ]] && modules_state 1 || { refresh_catalog || true; }
write_status

# ------------------------------------------- once a minute, or more when watched
TICK=0
while true; do
  if fresh "$VAR/watching" 30; then sleep 10 & else sleep 60 & fi
  wait $! || true
  (( STOPPING )) && stop
  TICK=$(( TICK + 1 ))
  if (( WIPED )); then write_status; continue; fi   # nothing left to watch, back up or update
  act
  if (( WIPED )); then write_status; publish_log; continue; fi   # the request just handled was the wipe
  watchdog
  nightly_backup
  expire_secret
  (( $(now) - UPDATE_AT > 43200 )) && check_updates
  if fresh "$VAR/watching" 30; then refresh_rich; write_logs; fi
  write_status
  (( TICK % 10 == 0 )) && publish_log
  (( STOPPING )) && stop
done
