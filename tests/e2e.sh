#!/usr/bin/env bash
#
# The setup container for real, on any Linux box with Docker: a scratch
# "share" mounted at the same path inside and out (as on DSM), the wizard's
# answers as postinst leaves them, then the whole life — install, the
# request-file actions one by one, stop. Pulls FreeScout and MariaDB, so the
# first run takes a few minutes.
#
#   tests/e2e.sh [up|act|down|all]     (all is the default)
#
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$here/..
E2E=${E2E_DIR:-${TMPDIR:-/tmp}/freescout-e2e}
PKG=$E2E/target; VAR=$E2E/var; APP=$E2E/share
PORT=${E2E_PORT:-8060}
NAME=freescout-setup-e2e
log() { echo "== $*"; }

up() {
  mkdir -p "$PKG" "$VAR" "$APP"
  # The package's target, as build.sh lays it out.
  rm -rf "$PKG"/*; mkdir -p "$PKG/app"; cp "$root/app/compose.yaml" "$root/app/env.example" "$PKG/app/"; cp -r "$root/synology/setup" "$PKG/setup"; cp -r "$root/modules" "$PKG/modules"; cp -r "$root/synology/target/." "$PKG/"; echo "0.1.0-e2e" > "$PKG/build-id"
  # What postinst leaves: the wizard's answers (password "password1", hex).
  if [[ ! -f "$APP/.env" ]]; then
    cat > "$VAR/answers.env" <<EOF
FS_LAN_IP='127.0.0.1'
FS_TZ='Europe/London'
FS_HTTP_PORT='$PORT'
FS_ADMIN_EMAIL='admin@example.com'
FS_ADMIN_FIRST='Admin'
FS_ADMIN_LAST='User'
FS_ADMIN_PASS_HEX='$(printf 'password1' | od -An -v -tx1 | tr -d ' \n')'
FS_HOST_UID='$(id -u)'
FS_HOST_GID='$(id -g)'
EOF
  fi
  docker build -q -t freescout-setup:local "$root/synology/setup" >/dev/null || { echo "the setup image didn't build"; exit 1; }
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -f "$VAR/state"                                   # a stale state from an earlier run must not be read as this one's
  log "starting the setup container ($NAME); its log: $VAR/package.log"
  docker run -d --name "$NAME" --user 0:0 --network host \
    -e FREESCOUT_PKG=/pkg -e FREESCOUT_VAR=/pkgvar -e FREESCOUT_APP="$APP" \
    -v /var/run/docker.sock:/var/run/docker.sock -v "$PKG:/pkg:ro" -v "$VAR:/pkgvar" -v "$APP:$APP" \
    --entrypoint bash freescout-setup:local /pkg/setup/run.sh >/dev/null || exit 1
  local t=0
  while (( t < 900 )); do
    case "$(cat "$VAR/state" 2>/dev/null)" in
      starting) [[ -f "$VAR/phase" && -z "${phase_seen:-}" ]] && { phase_seen=1; echo "  (phase: $(cat "$VAR/phase"))"; } ;;
      running) until jq -e '.at' "$VAR/status.json" >/dev/null 2>&1; do sleep 2; done; log "state: running"; [[ -f "$VAR/phase" ]] && { echo "  FAIL phase file left behind"; }; return 0 ;;
      failed) log "state: FAILED"; tail -n 30 "$VAR/package.log"; return 1 ;;
    esac
    docker ps -q --filter "name=^$NAME$" | grep -q . || { log "the setup container exited"; tail -n 30 "$VAR/package.log"; return 1; }
    sleep 5; t=$(( t + 5 ))
  done
  log "not running after 15 minutes"; tail -n 30 "$VAR/package.log"; return 1
}

# A request as api.cgi writes it; wait for the answer in status.json.
request() {   # lines…
  local f="$VAR/request" start what; start=$(date +%s)
  what=$(sed -n "s/^ACTION='\([a-z]*\)'$/\1/p" <<< "$1")
  printf '%s\n' "$@" "BY='e2e'" > "$f.tmp" && mv "$f.tmp" "$f"
  touch "$VAR/watching"                           # as an open window would: the loop ticks every 10 s
  # Done when the loop has answered THIS request: no file, not busy, and the last answer is for it, from now.
  while [[ -f "$f" || "$(jq -r '.busy // ""' "$VAR/status.json" 2>/dev/null)" != "" \
          || "$(jq -r '.last.action // ""' "$VAR/status.json" 2>/dev/null)" != "$what" \
          || "$(jq -r '.last.at // 0' "$VAR/status.json" 2>/dev/null)" -lt "$start" ]]; do
    sleep 2; touch "$VAR/watching"; (( $(date +%s) - start > 900 )) && { echo "  TIMEOUT waiting for: $1"; return 1; }
    docker ps -q --filter "name=^$NAME$" | grep -q . || { echo "  FAIL the setup container died during: $1"; docker logs --tail 3 "$NAME" 2>&1 | sed 's/^/       /'; return 1; }
  done
  jq -r '"  " + (if .last.ok then "ok  " else "FAIL" end) + " " + .last.action + " (" + (.last.took|tostring) + " s): " + .last.message' "$VAR/status.json"
  [[ "$(jq -r '.last.ok' "$VAR/status.json")" == true ]]
}
act() {
  local fail=0 id secret name
  log "status"; jq -c '{app, db, version, url, admins, mail, disk, maintenance}' "$VAR/status.json"
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/login"); [[ "$code" =~ ^(2|3|503) ]] && echo "  ok   FreeScout answers: HTTP $code on /login" || { echo "  FAIL FreeScout doesn't answer ($code)"; fail=1; }
  [[ "$code" == 503 ]] && { echo "  (left in maintenance mode by an earlier run; turning it off)"; request "ACTION='maintenance'" "ON='0'" >/dev/null; }
  log "actions"
  request "ACTION='clearcache'" || fail=1
  request "ACTION='maintenance'" "ON='1'" || fail=1
  [[ "$(jq -r .maintenance "$VAR/status.json")" == true ]] && echo "  ok   status shows maintenance" || { echo "  FAIL status doesn't show maintenance"; fail=1; }
  request "ACTION='maintenance'" "ON='0'" || fail=1
  request "ACTION='backup'" || fail=1
  name=$(jq -r '.backups[0].name // ""' "$VAR/status.json"); [[ -n "$name" ]] && echo "  ok   backup listed: $name ($(jq -r '.backups[0].size' "$VAR/status.json") bytes)" || { echo "  FAIL no backup listed"; fail=1; }
  tar -tf "$APP/backups/$name" | grep -qE '/(db\.sql\.gz|data\.tar\.gz|MANIFEST|env)$' && echo "  ok   backup has db, data, manifest" || { echo "  FAIL backup contents"; fail=1; }
  id=$(jq -r '.admins[0].id // ""' "$VAR/status.json")
  if [[ -n "$id" ]]; then
    request "ACTION='reset'" "USER_ID='$id'" || fail=1
    secret=$(jq -r '.password // ""' "$VAR/secret.json" 2>/dev/null)
    [[ ${#secret} -ge 12 ]] && echo "  ok   one-time password left for $(jq -r .email "$VAR/secret.json")" || { echo "  FAIL no one-time password"; fail=1; }
    # Does it sign in? FreeScout's login form: a CSRF token, then POST.
    local jar tokenv; jar=$(mktemp); tokenv=$(curl -fsS -c "$jar" "http://127.0.0.1:$PORT/login" | grep -oE 'name="_token" value="[^"]+"' | head -1 | sed 's/.*value="//; s/"$//')
    if curl -fsS -b "$jar" -c "$jar" -o /dev/null -w '%{http_code} %{redirect_url}\n' --data-urlencode "_token=$tokenv" --data-urlencode "email=admin@example.com" --data-urlencode "password=$secret" "http://127.0.0.1:$PORT/login" | grep -qE '^302 .*/(mailbox|dashboard|)'; then
      echo "  ok   the new password signs in"; else echo "  FAIL the new password didn't sign in"; fail=1; fi
    rm -f "$jar" "$VAR/secret.json"
  else echo "  FAIL no administrators listed"; fail=1; fi
  request "ACTION='newadmin'" "EMAIL='second@example.com'" "FIRST_NAME='Second'" "LAST_NAME='Admin'" || fail=1
  [[ "$(jq -r '.email // ""' "$VAR/secret.json" 2>/dev/null)" == second@example.com ]] && echo "  ok   one-time password left for the new administrator" || { echo "  FAIL no password for the new admin"; fail=1; }; rm -f "$VAR/secret.json"
  if request "ACTION='newadmin'" "EMAIL='second@example.com'" "FIRST_NAME='Second'" "LAST_NAME='Admin'" >/dev/null; then echo "  FAIL duplicate admin was accepted"; fail=1
  else echo "  ok   duplicate admin refused: $(jq -r '.last.message' "$VAR/status.json")"; fi
  act_users || fail=1
  act_storage_activity || fail=1
  request "ACTION='logout'" || fail=1
  request "ACTION='fetch'" || fail=1
  [[ -s "$VAR/logs/fetch.log" ]] && echo "  ok   fetch log written" || echo "  (fetch log empty — no mailboxes, that's fine)"
  request "ACTION='retryjobs'" || fail=1
  request "ACTION='flushjobs'" || fail=1
  request "ACTION='check'" || fail=1
  jq -c '{update, image_update}' "$VAR/status.json"
  act_modules || fail=1
  act_rest || fail=1
  echo; (( fail == 0 )) && echo "e2e actions: all passed" || echo "e2e actions: something FAILED (above)"
  return $fail
}
act_storage_activity() {
  local fail=0 jar tokenv
  log "storage and activity"
  # A failed sign-in and a good one, so the activity log has both.
  jar=$(mktemp); tokenv=$(curl -fsS -c "$jar" "http://127.0.0.1:$PORT/login" | grep -oE 'name="_token" value="[^"]+"' | head -1 | sed 's/.*value="//; s/"$//')
  curl -s -b "$jar" -c "$jar" -o /dev/null -w '  (failed sign-in attempt: HTTP %{http_code})\n' --data-urlencode "_token=$tokenv" --data-urlencode "email=admin@example.com" --data-urlencode "password=wrong-password" "http://127.0.0.1:$PORT/login"; rm -f "$jar"
  # The activity report is refreshed at most once a minute while the window is open: keep it open and wait for the event.
  for i in $(seq 1 40); do touch "$VAR/watching"; jq -e '.activity.entries | map(select(.what == "login_failed")) | length > 0' "$VAR/status.json" >/dev/null 2>&1 && break; sleep 4; done
  jq -e '.storage.tables | length > 0' "$VAR/status.json" >/dev/null && echo "  ok   storage: $(jq -r '.storage.tables | length' "$VAR/status.json") tables, data $(jq -r '.storage.dirs.data' "$VAR/status.json") MB, db $(jq -r '.storage.db_mb' "$VAR/status.json") MB" || { echo "  FAIL storage report: $(jq -c '.storage' "$VAR/status.json" | cut -c1-200)"; fail=1; }
  jq -e '.activity.entries | length > 0' "$VAR/status.json" >/dev/null && echo "  ok   activity: $(jq -r '.activity.entries | length' "$VAR/status.json") events ($(jq -r '.activity.entries | map(.what) | unique | join(", ")' "$VAR/status.json"))" || { echo "  FAIL no events in the activity report: $(jq -c '.activity' "$VAR/status.json" | cut -c1-200)"; fail=1; }
  jq -e '.activity.entries | map(select(.what == "login_failed" and .ip != "")) | length > 0' "$VAR/status.json" >/dev/null && echo "  ok   the failed sign-in is listed with its address: $(jq -r '.activity.failed_by_ip | map(.ip + " x" + (.count|tostring)) | join(", ")' "$VAR/status.json")" || { echo "  FAIL failed sign-in not listed"; fail=1; }
  request "ACTION='cleansendlog'" || fail=1
  request "ACTION='cleannotifications'" || fail=1
  request "ACTION='cleantmp'" || fail=1
  request "ACTION='clearlogs'" || fail=1
  docker exec freescout-app sh -c 'test ! -s /logs/nginx/access.log' && echo "  ok   nginx access log emptied" || { echo "  FAIL nginx log not emptied"; fail=1; }
  (( fail == 0 )) && echo "  storage/activity: all passed" || echo "  storage/activity: something FAILED"
  return $fail
}
# Destructive, so on its own: tests/e2e.sh wipe — removes containers, volumes,
# images and the share's contents; on a non-Synology the DSM hand-off is skipped.
act_wipe() {
  local fail=0
  log "remove everything"
  # A wrong phrase never reaches the loop as a request: the file fails validation and is dropped, with a log line.
  local n0; n0=$(grep -c "ignoring a request that wasn't in order" "$VAR/package.log")
  printf "ACTION='wipe'\nCONFIRM='YES'\nBY='e2e'\n" > "$VAR/request"
  for i in $(seq 1 30); do touch "$VAR/watching"; [[ ! -f "$VAR/request" ]] && break; sleep 3; done
  [[ "$(grep -c "ignoring a request that wasn't in order" "$VAR/package.log")" -gt "$n0" ]] && docker ps --format '{{.Names}}' | grep -q '^freescout-app$' && echo "  ok   refused without the confirmation phrase" || { echo "  FAIL wrong phrase not refused"; fail=1; }
  request "ACTION='wipe'" "CONFIRM='REMOVEEVERYTHING'" || fail=1
  docker ps -a --format '{{.Names}}' | grep -qE '^freescout-(app|db)$' && { echo "  FAIL containers remain"; fail=1; } || echo "  ok   containers removed"
  docker volume ls -q | grep -qE '^freescout_' && { echo "  FAIL volumes remain: $(docker volume ls -q | grep freescout_ | paste -sd' ')"; fail=1; } || echo "  ok   volumes removed"
  docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -qE '^(nfrastack/freescout:latest|mariadb:11.4)$' && echo "  (images still present — in use by another container here, fine locally)" || echo "  ok   images removed"
  [[ -z "$(ls -A "$APP" | grep -v package.log)" ]] && echo "  ok   shared folder emptied" || { echo "  FAIL share not empty: $(ls -A "$APP" | paste -sd' ')"; fail=1; }
  [[ "$(cat "$VAR/state")" == removed ]] && echo "  ok   state: removed" || { echo "  FAIL state: $(cat "$VAR/state")"; fail=1; }
  (( fail == 0 )) && echo "  wipe: all passed" || echo "  wipe: something FAILED"
  return $fail
}
act_users() {
  local fail=0 id2
  log "users"
  id2=$(jq -r '.users[] | select(.email == "second@example.com") | .id' "$VAR/status.json")
  if [[ -z "$id2" ]]; then   # run on its own: make the second administrator here
    request "ACTION='newadmin'" "EMAIL='second@example.com'" "FIRST_NAME='Second'" "LAST_NAME='Admin'" >/dev/null; rm -f "$VAR/secret.json"
    id2=$(jq -r '.users[] | select(.email == "second@example.com") | .id' "$VAR/status.json")
  fi
  [[ -n "$id2" ]] || { echo "  FAIL second admin not in the user list: $(jq -c '.users' "$VAR/status.json")"; return 1; }
  jq -r '.users | length' "$VAR/status.json" | grep -qE '^[2-9]' && echo "  ok   $(jq -r '.users | length' "$VAR/status.json") users listed, with last sign-in: $(jq -r '.users[0].last_login' "$VAR/status.json")" || { echo "  FAIL user list"; fail=1; }
  request "ACTION='userdisable'" "USER_ID='$id2'" || fail=1
  jq -r --argjson i "$id2" '.users[] | select(.id == $i) | .status' "$VAR/status.json" | grep -qx 2 && echo "  ok   disabled" || { echo "  FAIL not disabled"; fail=1; }
  request "ACTION='userenable'" "USER_ID='$id2'" || fail=1
  jq -r --argjson i "$id2" '.users[] | select(.id == $i) | .status' "$VAR/status.json" | grep -qx 1 && echo "  ok   enabled again" || { echo "  FAIL not enabled"; fail=1; }
  request "ACTION='userrole'" "USER_ID='$id2'" "ROLE='1'" || fail=1
  jq -r --argjson i "$id2" '.users[] | select(.id == $i) | .role' "$VAR/status.json" | grep -qx 1 && echo "  ok   made an agent" || { echo "  FAIL role"; fail=1; }
  if request "ACTION='userdisable'" "USER_ID='1'" >/dev/null; then echo "  FAIL the last administrator was disabled"; fail=1; else echo "  ok   last administrator protected: $(jq -r '.last.message' "$VAR/status.json" | cut -c1-70)…"; fi
  request "ACTION='userrole'" "USER_ID='$id2'" "ROLE='2'" || fail=1
  request "ACTION='userdelete'" "USER_ID='$id2'" || fail=1
  jq -r --argjson i "$id2" '.users[] | select(.id == $i) | "\(.status) \(.email)"' "$VAR/status.json" | grep -qE '^3 second@example.com' && echo "  ok   removed the way FreeScout does (status 3, email suffixed)" || { echo "  FAIL remove: $(jq -c --argjson i "$id2" '.users[] | select(.id == $i)' "$VAR/status.json")"; fail=1; }
  curl -fsS -o /dev/null -w '  ok   FreeScout still answers: HTTP %{http_code}\n' "http://127.0.0.1:$PORT/login" || { echo "  FAIL FreeScout down after user changes"; fail=1; }
  (( fail == 0 )) && echo "  users: all passed" || echo "  users: something FAILED"
  return $fail
}
act_modules() {
  local fail=0
  log "modules"
  request "ACTION='modcheck'" || fail=1
  jq -c '.modules | map({alias, version, tag, installed, logo, error})' "$VAR/status.json"
  if [[ "$(jq -r '.modules | map(select(.alias == "mail365")) | length' "$VAR/status.json")" == 1 ]]; then
    [[ -f "$VAR/modules/logos/mail365.png" ]] && echo "  ok   mail365 logo fetched" || { echo "  FAIL mail365 logo missing"; fail=1; }
    # As on a NAS that has run for hours: FreeScout's cached scan of the Modules folder is warm and doesn't know the new module.
    docker exec freescout-app sudo -H -u nginx php /www/html/artisan module:list >/dev/null 2>&1 && echo "  (FreeScout's module scan cache warmed)"
    request "ACTION='modinstall'" "MODULE='mail365'" || fail=1
    jq -r '.modules[] | select(.alias == "mail365") | "\(.installed) \(.active) \(.installed_version)"' "$VAR/status.json" | grep -q '^true true' && echo "  ok   mail365 installed and active" || { echo "  FAIL mail365 not installed/active: $(jq -c '.modules[] | select(.alias == "mail365")' "$VAR/status.json")"; fail=1; }
    docker exec freescout-app test -L /www/html/public/modules/mail365 && echo "  ok   public symlink made" || { echo "  FAIL no public symlink"; fail=1; }
    curl -fsS -o /dev/null -w '  ok   FreeScout still answers with the module: HTTP %{http_code}\n' "http://127.0.0.1:$PORT/login" || { echo "  FAIL FreeScout broke after the module"; fail=1; }
    request "ACTION='moddeactivate'" "MODULE='mail365'" || fail=1
    jq -r '.modules[] | select(.alias == "mail365") | .active' "$VAR/status.json" | grep -q false && echo "  ok   deactivated" || { echo "  FAIL still active"; fail=1; }
    request "ACTION='modactivate'" "MODULE='mail365'" || fail=1
    request "ACTION='modremove'" "MODULE='mail365'" || fail=1
    docker exec freescout-app test -d /data/Modules/Mail365 && { echo "  FAIL module folder still there"; fail=1; } || echo "  ok   module folder removed"
    request "ACTION='modinstall'" "MODULE='nosuchmodule'" >/dev/null && { echo "  FAIL unknown module accepted"; fail=1; } || echo "  ok   unknown module refused"
    # Modules kept in a folder of their repository, and their logos.
    jq -r '.modules[] | select(.alias == "apikeymanager") | "\(.folder) \(.tag) \(.logo) \(.error)"' "$VAR/status.json" | grep -qE '^ApiKeyManager v[0-9.]+ png $' && echo "  ok   apikeymanager resolved from its subfolder, with logo" || { echo "  FAIL apikeymanager: $(jq -c '.modules[] | select(.alias == "apikeymanager") | {folder, tag, logo, error}' "$VAR/status.json")"; fail=1; }
    jq -r '.modules[] | select(.alias == "sortablecustomfields") | "\(.folder) \(.tag) \(.error)"' "$VAR/status.json" | grep -qE '^SortableCustomFields v[0-9.]+ $' && echo "  ok   sortablecustomfields resolved from src/" || { echo "  FAIL sortablecustomfields"; fail=1; }
    # Requirements: from the catalog and from module.json, with their state in FreeScout.
    jq -r '.modules[] | select(.alias == "apikeymanager") | .requires | map(.alias + ":" + (.active | tostring)) | join(",")' "$VAR/status.json" | grep -q 'apiwebhooks:false' && echo "  ok   apikeymanager needs apiwebhooks (not active here)" || { echo "  FAIL apikeymanager requirements"; fail=1; }
    if request "ACTION='modinstall'" "MODULE='apikeymanager'" >/dev/null; then echo "  FAIL apikeymanager installed despite a missing requirement"; fail=1
    else jq -r '.last.message' "$VAR/status.json" | grep -q 'needs API & Webhooks installed and active' && echo "  ok   apikeymanager refused: $(jq -r '.last.message' "$VAR/status.json" | cut -c1-90)…" || { echo "  FAIL refusal message: $(jq -r '.last.message' "$VAR/status.json")"; fail=1; }; fi
    jq -r '.last.detail' "$VAR/status.json" | grep -q 'request from' && echo "  ok   a failed action carries its log lines for the window" || { echo "  FAIL no detail on a failed action: $(jq -c '.last' "$VAR/status.json" | cut -c1-200)"; fail=1; }
    docker exec freescout-app test -d /data/Modules/ApiKeyManager && { echo "  FAIL files were placed despite the refusal"; fail=1; } || echo "  ok   nothing placed for the refused module"
    jq -r '.modules[] | select(.alias == "apiuserauth") | .missing | join(",")' "$VAR/status.json" | grep -q 'API & Webhooks' && echo "  ok   apiuserauth lists API & Webhooks as missing" || { echo "  FAIL apiuserauth missing list"; fail=1; }
    jq -r '.modules[] | select(.alias == "multiassign") | .missing | length' "$VAR/status.json" | grep -qx 0 && echo "  ok   multiassign's optional modules don't count as missing" || { echo "  FAIL multiassign optional"; fail=1; }
    jq -r '.modules[] | select(.alias == "internalconversations") | "\(.tag) \(.version) \(.logo) \(.error)"' "$VAR/status.json" | grep -qE '^1\.[0-9.]+ 1\.[0-9.]+ svg $' && echo "  ok   internalconversations: a tag without v, svg logo" || { echo "  FAIL internalconversations: $(jq -c '.modules[] | select(.alias == "internalconversations") | {tag, version, logo, error}' "$VAR/status.json")"; fail=1; }
    jq -r '.modules[] | select(.alias == "secrets") | "\(.folder) \(.tag) \(.logo) \(.error)"' "$VAR/status.json" | grep -qE '^Secrets v[0-9.]+ png $' && echo "  ok   secrets resolved from its Secrets/ folder, with logo" || { echo "  FAIL secrets: $(jq -c '.modules[] | select(.alias == "secrets") | {folder, tag, logo, error}' "$VAR/status.json")"; fail=1; }
    jq -r '.modules[] | select(.alias == "cleanup") | "\(.logo) \(.error)"' "$VAR/status.json" | grep -qE '^svg $' && echo "  ok   cleanup: logo fetched from the author's site" || { echo "  FAIL cleanup: $(jq -c '.modules[] | select(.alias == "cleanup") | {tag, logo, error}' "$VAR/status.json")"; fail=1; }
    jq -r '.modules[] | select(.alias == "allinoneaccessibility") | "\(.tag)|\(.error)"' "$VAR/status.json" | grep -qx '|' && echo "  ok   allinoneaccessibility: no release, branch head" || { echo "  FAIL allinoneaccessibility: $(jq -c '.modules[] | select(.alias == "allinoneaccessibility") | {tag, logo, error}' "$VAR/status.json")"; fail=1; }
    jq -r '.modules[] | select(.alias == "kanbanworkflow") | .requires | map(.alias) | sort | join(",")' "$VAR/status.json" | grep -qx 'kanban,workflows' && echo "  ok   kanbanworkflow: requirements from module.json's object form" || { echo "  FAIL kanbanworkflow requires: $(jq -c '.modules[] | select(.alias == "kanbanworkflow") | .requires' "$VAR/status.json")"; fail=1; }
    jq -r '.modules[] | select(.alias == "cobrowse") | "\(.logo) \(.error)"' "$VAR/status.json" | grep -qE '^svg $' && echo "  ok   cobrowse: logo from a ../modules path" || { echo "  FAIL cobrowse: $(jq -c '.modules[] | select(.alias == "cobrowse") | {logo, error}' "$VAR/status.json")"; fail=1; }
    jq -r '.modules[] | select(.alias == "clickupintegration") | "\(.logo) \(.error)"' "$VAR/status.json" | grep -qE '^png $' && echo "  ok   clickup: logo with a ?v= query" || { echo "  FAIL clickup: $(jq -c '.modules[] | select(.alias == "clickupintegration") | {logo, error}' "$VAR/status.json")"; fail=1; }
    jq -r '.modules[] | select(.alias == "orgportal") | "\(.folder) \(.tag) \(.error)"' "$VAR/status.json" | grep -qE '^OrgPortal v[0-9.]+ $' && echo "  ok   orgportal from Modules/OrgPortal" || { echo "  FAIL orgportal: $(jq -c '.modules[] | select(.alias == "orgportal") | {folder, tag, error}' "$VAR/status.json")"; fail=1; }
    docker exec freescout-app php -m 2>/dev/null | grep -qix zip && echo "  ok   PHP zip extension present (Attachment Security)" || echo "  (PHP zip extension absent — Attachment Security's note would be wrong)"
    [[ "$(jq -r '.modules | length' "$VAR/status.json")" -ge 15 ]] && echo "  ok   $(jq -r '.modules | length' "$VAR/status.json") modules in the catalog, $(jq -r '.modules | map(select(.error == "")) | length' "$VAR/status.json") resolved" || { echo "  FAIL catalog short: $(jq -c '.modules | map({alias, error})' "$VAR/status.json")"; fail=1; }
    # A module without releases (branch head), and one that needs Composer in its own folder.
    request "ACTION='modinstall'" "MODULE='unassignedcount'" || fail=1
    jq -r '.modules[] | select(.alias == "unassignedcount") | "\(.installed) \(.active) \(.installed_tag)"' "$VAR/status.json" | grep -q '^true true main' && echo "  ok   unassignedcount installed from the main branch" || { echo "  FAIL unassignedcount: $(jq -c '.modules[] | select(.alias == "unassignedcount") | {installed, active, installed_tag}' "$VAR/status.json")"; fail=1; }
    request "ACTION='modremove'" "MODULE='unassignedcount'" || fail=1
    request "ACTION='modinstall'" "MODULE='stripe'" || fail=1
    docker exec freescout-app test -d /data/Modules/Stripe/vendor/stripe && echo "  ok   stripe's own vendor folder installed by Composer" || { echo "  FAIL stripe vendor missing"; fail=1; }
    jq -r '.modules[] | select(.alias == "stripe") | .active' "$VAR/status.json" | grep -q true && echo "  ok   stripe active" || { echo "  FAIL stripe not active"; fail=1; }
    curl -fsS -o /dev/null -w '  ok   FreeScout still answers with stripe: HTTP %{http_code}\n' "http://127.0.0.1:$PORT/login" || { echo "  FAIL FreeScout broke after stripe"; fail=1; }
    request "ACTION='modremove'" "MODULE='stripe'" || fail=1
    # A module folder deleted behind the store's back must not take FreeScout down.
    request "ACTION='modinstall'" "MODULE='unassignedcount'" || fail=1
    docker run --rm --entrypoint sh -v freescout_app-data:/vol freescout-setup:local -c 'rm -rf /vol/Modules/UnassignedCount'
    request "ACTION='modcheck'" || fail=1
    jq -r '.modules[] | select(.alias == "unassignedcount") | "\(.installed) \(.active)"' "$VAR/status.json" | grep -q '^false false' && echo "  ok   hand-deleted module was deactivated" || { echo "  FAIL hand-deleted module: $(jq -c '.modules[] | select(.alias == "unassignedcount") | {installed, active}' "$VAR/status.json")"; fail=1; }
    grep -q 'its files are gone' "$VAR/package.log" && echo "  ok   and the log says so" || { echo "  FAIL no heal line in the log"; fail=1; }
    curl -fsS -o /dev/null -w '  ok   FreeScout still answers afterwards: HTTP %{http_code}\n' "http://127.0.0.1:$PORT/login" || { echo "  FAIL FreeScout down after a hand-deleted module"; fail=1; }
  else echo "  FAIL mail365 isn't in the catalog state"; fail=1; fi
  (( fail == 0 )) && echo "  modules: all passed" || echo "  modules: something FAILED"
  return $fail
}
act_rest() {
  local fail=0 name
  name=$(jq -r '.backups | map(select(.name | test("pre-restore|nightly") | not)) | .[0].name // ""' "$VAR/status.json")
  request "ACTION='report'" || fail=1
  grep -qE 'lan-ip-1|email-1' "$VAR/report.txt" && echo "  ok   report is redacted" || { echo "  FAIL report not redacted"; fail=1; }
  grep -qE 'DB_(ROOT_)?PASS=' "$VAR/report.txt" && { echo "  FAIL report has a password"; fail=1; } || echo "  ok   report has no passwords"
  request "ACTION='settings'" "APP_URL='http://127.0.0.1:$PORT'" "HTTP_PORT='$PORT'" "SSL_PROXY='1'" "APP_TZ='Europe/Paris'" || fail=1
  docker exec "$NAME" sh -c "grep -qx 'TRUSTED_PROXIES=\*' '$APP/.env' && grep -qx 'TZ=Europe/Paris' '$APP/.env'" && echo "  ok   .env updated" || { echo "  FAIL .env not updated"; fail=1; }
  docker exec freescout-app sh -c 'grep -E "^(APP_TRUSTED_PROXIES|SESSION_SECURE_COOKIE)=" /data/config/config' | sed 's/^/       in FreeScout: /'
  request "ACTION='settings'" "SSL_PROXY='0'" "APP_TZ='Europe/London'" || fail=1
  request "ACTION='restore'" "BACKUP='$name'" || fail=1
  sleep 12   # the next tick re-reads the users
  jq -r '.admins | map(.email) | join(", ")' "$VAR/status.json" | grep -q second@example.com && { echo "  FAIL restore didn't roll the database back"; fail=1; } || echo "  ok   restore rolled the database back (second admin gone)"
  request "ACTION='delbackup'" "BACKUP='$name'" || fail=1
  request "ACTION='restart'" || fail=1
  log "a request that isn't in order"
  local n0; n0=$(grep -c "ignoring a request that wasn't in order" "$VAR/package.log")
  printf "ACTION='restart'\nBY='\$(id)'\n" > "$VAR/request"
  for i in $(seq 1 30); do touch "$VAR/watching"; [[ ! -f "$VAR/request" ]] && break; sleep 3; done
  [[ "$(grep -c "ignoring a request that wasn't in order" "$VAR/package.log")" -gt "$n0" ]] && echo "  ok   hostile request ignored" || { echo "  FAIL hostile request not ignored"; fail=1; }
  return $fail
}
down() {
  log "stopping the setup container (SIGTERM, as Container Manager does)"
  docker stop -t 180 "$NAME" >/dev/null 2>&1
  sleep 1; tail -n 3 "$VAR/package.log"
  [[ "$(cat "$VAR/state" 2>/dev/null)" == stopped ]] && echo "  ok   state: stopped" || echo "  FAIL state: $(cat "$VAR/state" 2>/dev/null)"
  docker ps -q --filter name='^freescout-app$' | grep -q . && echo "  FAIL freescout-app still running" || echo "  ok   freescout-app stopped"
  echo "  setup container's last stderr lines:"; docker logs "$NAME" 2>&1 >/dev/null | tail -n 6 | sed 's/^/     /'
  docker rm -f "$NAME" >/dev/null 2>&1
}
clean() {
  down
  log "removing FreeScout's containers, volumes, network and the scratch share"
  docker rm -f freescout-app freescout-db >/dev/null 2>&1
  docker volume rm freescout_app-data freescout_app-logs freescout_db-data >/dev/null 2>&1
  docker network rm freescout_default >/dev/null 2>&1
  docker volume ls -q | grep -E '^freescout_' && { echo "  FAIL volumes still there"; }
  # Root-owned files inside (made by containers) need root to go; never mount a missing dir (Docker would make it as root).
  [[ -d "$E2E" ]] && docker run --rm -v "$E2E:/e" alpine sh -c 'rm -rf /e/share /e/var /e/target' 2>/dev/null
  rm -rf "$E2E" 2>/dev/null || rmdir "$E2E" 2>/dev/null || true
}
case "${1:-all}" in
  up) up ;; act) act ;; modules) act_modules ;; storage) act_storage_activity ;; users) act_users ;; wipe) act_wipe ;; down) down ;; clean) clean ;;
  all) up && act; rc=$?; down; exit $rc ;;
esac
