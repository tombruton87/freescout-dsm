# Changelog

## 1.0.2

- The Copy button for one-time passwords works when DSM is opened over plain
  HTTP (http://nas:5000), where browsers don't offer the clipboard API. If
  copying is refused, the password is selected with a Ctrl+C hint.

## 1.0.1

- A new icon: FreeScout's own mark on a tile shaped like DSM's own icons, in
  FreeScout's blue fading to its navy, in Package Center, the main menu and
  the window.

## 1.0.0

First release. Everything below was developed as builds 1–17 of 0.1.0 and verified on a Synology NAS (DSM 7.2, Container Manager) and locally end to end.

**FreeScout on DSM.** FreeScout (nfrastack/freescout, amd64 and arm64) and MariaDB 11.4 as a Container Manager project; data, logs and database in Docker volumes (`freescout_app-data`, `freescout_app-logs`, `freescout_db-data`), because a DSM shared folder's ACLs admit only the package's user; backups, settings and the package log in the `freescout` shared folder. Install wizard with the NAS's address, a free port, time zone and the first administrator.

**The window in DSM** (administrators edit; a user the app is granted to gets a read-only window):
- Overview — state, containers, free space, last backup, setup log; Open, Restart.
- Access — a new password for a locked-out administrator, shown once; add an administrator; sign everyone out.
- Users — every agent with role, status and last sign-in; reset password, enable/disable, make administrator/agent, remove (FreeScout's own routine); the last administrator is protected.
- Backups — one tar per backup (database dump, config incl. the APP_KEY, attachments, modules); manual, nightly (caught up if missed), save, restore (safety backup first), delete, retention.
- Site address — URL, port, time zone; HTTPS behind DSM's reverse proxy; the DSM steps written out.
- Mail & queue — mailboxes, queued and failed jobs, worker, scheduler; fetch now, retry/clear failed jobs; fetch, scheduler, worker and FreeScout logs.
- Modules — a store of 52 FreeScout modules from GitHub (the author's own, plus FreeScout's Community Modules wiki, GitHub-hosted only): logo, description, latest release, what each needs (official modules by name and whether they're active here, minimum FreeScout version); install, update, activate, deactivate, remove; search and filters; modules in repository subfolders, with their own Composer libraries, or with logos on the author's site; a `modules.json` in the share adds your own. Nothing is installed or activated unless its requirements are met. FreeScout's module-scan cache is dropped before activation; a module left active with its files gone is deactivated and its caches cleared so FreeScout keeps booting.
- Updates — a newer FreeScout image (backup first, pull, migrate) and a newer package (installed through DSM from inside).
- Storage — attachments per mailbox, biggest tables, folder sizes; trim the send log, notifications, temporary files; empty log files.
- Activity — sign-ins, sign-outs, failed attempts and lockouts with addresses; a DSM notification on a burst of failures; sign everyone out.
- Maintenance — maintenance mode, clear caches, a redacted support report, container logs, and "Remove FreeScout and everything" (containers, images, volumes, the shared folder, then the package through DSM's own uninstaller).

**Looking after itself.** A watchdog restarts a stopped container and tells DSM; a compose-renamed setup container heals its name on start; the stop signal is handled by a flag; failed actions show their log lines in the window; images are pulled only when missing; start-up shows which step it is on.

## 0.1.0 (development builds)


First release.

- FreeScout (nfrastack/freescout, amd64 + arm64) and MariaDB 11.4 as a Container Manager project. Data, logs and database in Docker volumes (`freescout_app-data`, `freescout_app-logs`, `freescout_db-data`); backups, settings and the package log in the `freescout` shared folder. (Builds 1 and 2 tried the share for these: DSM's shared-folder ACLs refuse the containers' own users.)
- Install wizard: NAS address, a free port, time zone, first administrator.
- DSM window: Overview, Access (password reset, new administrator, sign everyone out), Backups (manual, nightly, restore, save), Site address (URL/port/time zone, HTTPS behind DSM's reverse proxy), Mail & queue (failed jobs, fetch now, logs), Updates (image and package), Maintenance (maintenance mode, caches, redacted support report, logs).
- DSM notifications when a container keeps stopping or a nightly backup fails.
- Modules tab (build 4): a store of FreeScout modules from GitHub — logo, description, latest release; install, update, activate, deactivate, remove. Catalog shipped in `modules/catalog.json`, extendable with a `modules.json` in the shared folder.
- Build 17: a repository renamed on GitHub (API Key Manager moved to ShowDotFM) is followed through GitHub's redirect; a module whose latest release can't be read this time keeps the release it had. Images are pulled only when missing (a pull on every start was slow on a NAS and could stall for hours under Docker Hub's anonymous limit; updates still pull); while starting, the window shows which step it is on (pulling, starting containers, waiting for FreeScout, first look at users and modules).
- Build 16: Maintenance → "Remove FreeScout and everything": after a ticked box and a typed phrase, the setup container removes FreeScout's containers, network and volumes (database, attachments, modules, logs), its images and the shared folder's contents, then a helper on the NAS runs DSM's own `synopkg uninstall` and deletes the `freescout` shared folder — nothing left to do by hand. The uninstall wizard points to it.
- Build 15: a Storage tab (attachments per mailbox, biggest tables, folder sizes in the data and logs volumes; trim the send log, notifications and temporary files; empty log files) and an Activity tab (sign-ins, sign-outs, failed attempts and lockouts from FreeScout's activity log, failed attempts by address, a DSM notification at twenty failures in an hour). DSM roles: the app is for administrators by default (an administrator can grant it to a user or group under Control Panel → User & Group → Applications, who then gets a read-only window); the page itself is read-only for anyone who isn't a DSM administrator, and every change is refused server-side as before.
- Build 14: a failed action in the window now shows the log lines it produced, with a link to the setup log; when FreeScout's own code can't boot (a broken module), marking a module active falls back to its database flag so the install can still be repaired; the health check and start-up wait accept maintenance mode (503) instead of restarting FreeScout; the status refresh reads all installed module versions in one call instead of one per module; the stop signal is handled by a flag, which ends a bash crash ("unexpected EOF while looking for matching `)'") when a stop landed mid-command.
- Build 14: a Users tab — every agent with role, status and last sign-in (from FreeScout's activity log); reset password, disable or enable, make administrator or agent, remove (FreeScout's own routine: conversations unassigned, mailboxes disconnected, email freed). The last active administrator can't be disabled, demoted or removed.
- Build 13: the Modules tab has a search box (name, description, author, what it needs) and All / Installed / Updates / Ready-to-install filters with a count; long names, requirement lines and buttons wrap inside their card instead of running past its edge.
- Build 12: thirty-seven more modules from FreeScout's Community Modules wiki (GitHub-hosted ones only; browser extensions, migration scripts, an MCP server, a WordPress plugin and a Redis driver this package can't serve were left out), each read for what it needs. Requirements written as an object in module.json, logos as `../modules/…` or with a `?v=` query, and more official modules by name (Kanban, Knowledge Base, Tags, Teams, End-User Portal) are understood.
- Build 11: four more modules in the catalog (Internal Conversations, Cleanup, Secrets, All in One Accessibility) after reading every module's README and module.json for what it needs; logos hosted on the author's own site are accepted.
- Build 10: FreeScout caches its scan of the Modules folder for an hour, so a module just placed there was "not found" on activation; the store now drops that cache entry before activating (and after removing).
- Build 9: module files and backup archives now go through the helper container on its stdin/stdout rather than a folder of the share mounted by host path (on DSM that path is a symlink into /volume1 with Synology ACLs, which left a module's folder empty: "Module with the specified alias not found"). The files are also checked from FreeScout's own container before activation.
- Build 8: a module isn't installed or activated unless what it needs is there — every required official module active in FreeScout, and FreeScout new enough; the card's Install button becomes "Needs … first" and the setup container refuses the request, naming what's missing. A module FreeScout has as active but whose files are gone (deleted by hand, an update cut short) is deactivated on start and its stale caches dropped, instead of taking FreeScout down.
- Build 7: when FreeScout refuses a module on activation, the window now shows the lines FreeScout gave (missing class, failed migration…) instead of pointing at the log.
- Build 6: a package upgrade can leave the setup container renamed `<id>_freescout-setup` (Compose's recreate cut short), after which Container Manager can't find it and Package Center can't start or repair the package. The setup container now renames itself back on start and removes stopped leftovers; stopping is quicker so the recreate isn't cut short.
- Modules (build 5): eleven modules in the catalog; each card shows what the module needs (official modules and whether they're active in this FreeScout, the minimum FreeScout version) and warns before installing without them; modules kept in a repository subfolder; modules with their own Composer libraries (installed into the module's folder); logos given as GitHub URLs.
