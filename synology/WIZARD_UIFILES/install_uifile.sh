#!/bin/bash
#
# The install wizard, in Package Center. Made fresh each time it runs, so it
# can suggest this Synology's own address, time zone and a port nothing holds.
# The answers reach scripts/postinst as wizard_* variables.

lan_ip=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)

# DSM keeps a city name ("London"); find it among the zone names.
tz=""
syno=$(sed -n 's/^timezone="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/synoinfo.conf 2>/dev/null | head -1)
if [ -n "$syno" ] && [ -d /usr/share/zoneinfo ]; then
  tz=$(cd /usr/share/zoneinfo && ls -d */"$syno" 2>/dev/null | grep -vE '^(posix|right)/' | head -1)
fi
tz=${tz:-UTC}

# Ports something already listens on — DSM's own and other packages'.
if command -v netstat >/dev/null 2>&1; then used=$(netstat -lntu 2>/dev/null | awk 'NR > 2 {print $4}')
else used=$(ss -Hlntu 2>/dev/null | awk '{print $5}'); fi
used=$(printf '%s\n' "$used" | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un)
in_use() { printf '%s\n' "$used" | grep -qx "$1"; }
first_free() { local p; for p in "$@"; do in_use "$p" || { echo "$p"; return; }; done; echo "$1"; }
http_port=$(first_free 8060 8061 8070 8090 8180)
taken=$(printf '%s\n' "$used" | paste -sd'|' -)
port_expr="/^(?!(?:${taken:+$taken})\$)(102[4-9]|10[3-9][0-9]|1[1-9][0-9]{2}|[2-9][0-9]{3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])\$/"

# Only their own characters, as they go into JSON.
lan_ip=$(printf '%s' "$lan_ip" | tr -cd '0-9.')
tz=$(printf '%s' "$tz" | tr -cd 'A-Za-z0-9_/+-')

cat > "$SYNOPKG_TEMP_LOGFILE" <<JSON
[{
    "step_title": "Welcome to FreeScout",
    "items": [{
        "desc": "FreeScout is a help desk and shared mailbox: your support@ address, answered by a team, with assignments, notes, saved replies and reports.<br><br>It runs in Container Manager. The first start downloads FreeScout and MariaDB (a few hundred MB) and sets the database up, which takes a few minutes — follow it in <b>Package Center → FreeScout → View log</b>, or open the <b>FreeScout</b> app from DSM's main menu once it's installed.<br><br>Its backups and settings go in a new shared folder, <b>freescout</b>; its data lives in Container Manager volumes (DSM's shared-folder permissions don't let the containers write there). Both stay if the package is removed. To see the backups in File Station, give yourself access: <b>Control Panel → Shared Folder → freescout → Edit → Permissions</b>."
    }]
}, {
    "step_title": "Your network",
    "items": [{
        "type": "textfield",
        "desc": "The address this Synology has on your network. Reserve it in your router so it stays the same. FreeScout's address will be http://this:port — it can be changed later in the FreeScout window, for instance to a domain behind DSM's reverse proxy.",
        "subitems": [{
            "key": "wizard_lan_ip",
            "desc": "Address",
            "defaultValue": "$lan_ip",
            "validator": { "allowBlank": false, "regex": { "expr": "/^([0-9]{1,3}\\\\.){3}[0-9]{1,3}\$/", "errorText": "Looks like 192.168.1.10" } }
        }]
    }, {
        "type": "textfield",
        "desc": "The port for FreeScout's web app. Suggested: one nothing here is using.",
        "subitems": [{
            "key": "wizard_http_port",
            "desc": "Web port",
            "defaultValue": "$http_port",
            "validator": { "allowBlank": false, "regex": { "expr": "$port_expr", "errorText": "A number from 1024 to 65535 that isn't in use on this Synology" } }
        }]
    }, {
        "type": "textfield",
        "desc": "Time zone, for FreeScout's timestamps, schedules and reports.",
        "subitems": [{
            "key": "wizard_tz",
            "desc": "Time zone",
            "defaultValue": "$tz",
            "validator": { "allowBlank": false, "regex": { "expr": "/^[A-Za-z_]+(\\\\/[A-Za-z0-9_+-]+)*\$/", "errorText": "Looks like Europe/London" } }
        }]
    }]
}, {
    "step_title": "The first administrator",
    "items": [{
        "type": "textfield",
        "desc": "FreeScout's first administrator — you. Sign in with this email and password once it's up. If you ever lose the password, the FreeScout window in DSM can set a new one.",
        "subitems": [{
            "key": "wizard_admin_email",
            "desc": "Email",
            "defaultValue": "",
            "validator": { "allowBlank": false, "regex": { "expr": "/^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\\\\.[A-Za-z]{2,}\$/", "errorText": "An email address, like you@example.com" } }
        }, {
            "key": "wizard_admin_first",
            "desc": "First name",
            "defaultValue": "Admin",
            "validator": { "allowBlank": false, "regex": { "expr": "/^[A-Za-z0-9._-]{1,40}\$/", "errorText": "Letters and digits only here — it can be changed in FreeScout later" } }
        }, {
            "key": "wizard_admin_last",
            "desc": "Last name",
            "defaultValue": "User",
            "validator": { "allowBlank": false, "regex": { "expr": "/^[A-Za-z0-9._-]{1,40}\$/", "errorText": "Letters and digits only here — it can be changed in FreeScout later" } }
        }]
    }, {
        "type": "password",
        "desc": "A password of 8 to 64 characters: letters, digits and ! @ # \$ % ^ & * ( ) _ + = . , : ; ? -",
        "subitems": [{
            "key": "wizard_admin_pass",
            "desc": "Password",
            "defaultValue": "",
            "validator": { "allowBlank": false, "regex": { "expr": "/^[A-Za-z0-9!@#\$%^&*()_+=.,:;?-]{8,64}\$/", "errorText": "8 to 64 characters: letters, digits and ! @ # \$ % ^ & * ( ) _ + = . , : ; ? -" } }
        }]
    }]
}]
JSON
exit 0
