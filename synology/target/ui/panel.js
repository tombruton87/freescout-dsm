// FreeScout's window: polls api.cgi for how things are, shows it, and turns
// buttons into requests the setup container acts on. Plain JS, no framework.
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var S = null, role = "viewer", tab = "overview", lastShown = 0, secretShown = false;

  // DSM's own session token, from the DSM page around this one: DSM checks it
  // with every request, so another site can't make them in your name.
  function token() { try { return window.parent.SYNO.SDS.Session.SynoToken || ""; } catch (e) { return ""; } }
  function withToken(url) { var k = token(); return k ? url + "&SynoToken=" + encodeURIComponent(k) : url; }
  function api(query, body) {
    var opts = { credentials: "same-origin", headers: { "X-SYNO-TOKEN": token() } };
    if (body) { opts.method = "POST"; opts.headers["Content-Type"] = "application/x-www-form-urlencoded"; opts.body = new URLSearchParams(body).toString(); }
    return fetch(withToken("api.cgi?" + query), opts).then(function (r) {
      var json = (r.headers.get("Content-Type") || "").indexOf("json") >= 0;
      return (json ? r.json() : r.text()).then(function (data) {
        if (!r.ok) throw new Error((data && data.error) || ("FreeScout's window didn't get an answer (" + r.status + ")."));
        return data;
      });
    });
  }

  // ------------------------------------------------------------- helpers
  function el(tag, text, cls) { var e = document.createElement(tag); if (text != null) e.textContent = text; if (cls) e.className = cls; return e; }
  function cell(value, cls) { var td = el("td", null, cls); if (value instanceof Node) td.appendChild(value); else td.textContent = value == null ? "" : value; return td; }
  function kv(tbody, label, value, num) { return row(tbody, [cell(label, "k"), cell(value, num ? "n" : "")]); }
  function row(tbody, cells) { var tr = el("tr"); cells.forEach(function (c) { tr.appendChild(c instanceof Node && c.tagName === "TD" ? c : cell(c)); }); tbody.appendChild(tr); return tr; }
  function chip(text, cls) { var s = el("span", null, "chip " + (cls || "")); s.appendChild(el("i")); s.appendChild(el("span", text)); return s; }
  function btn(text, cls, onclick) { var b = el("button", text, "btn " + (cls || "")); b.onclick = onclick; b.disabled = busy() || role !== "admin"; return b; }
  function bytes(n) { if (n == null) return "–"; var u = ["B", "KB", "MB", "GB", "TB"], i = 0, b = n; while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; } return (b >= 10 || i === 0 ? Math.round(b) : b.toFixed(1)) + " " + u[i]; }
  function mb(n) { return bytes((n || 0) * 1024 * 1024); }
  function when(ts) { if (!ts) return "never"; var d = new Date(ts * 1000); return d.toLocaleDateString(undefined, { day: "numeric", month: "short" }) + ", " + d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }); }
  function ago(ts) { if (!ts) return "never"; var s = Math.max(0, Math.floor(Date.now() / 1000 - ts)); if (s < 90) return s + " s ago"; if (s < 5400) return Math.round(s / 60) + " min ago"; if (s < 172800) return Math.round(s / 3600) + " h ago"; return Math.round(s / 86400) + " days ago"; }
  function busy() { return !!(S && S.status && S.status.busy) || !!(S && S.pending); }
  function tile(parent, value, label) { var d = el("div", null, "tile"); d.appendChild(el("b", value)); d.appendChild(el("span", label)); parent.appendChild(d); }
  function showErr(msg) { $("err").textContent = msg; $("err").hidden = !msg; }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  // A request: the setup container acts on it within seconds; its answer
  // arrives in status.last and is shown above the page.
  function act(action, extra, confirmText) {
    if (confirmText && !window.confirm(confirmText)) return Promise.resolve();
    showErr("");
    var body = Object.assign({ action: action }, extra || {});
    return api("action=" + action, body).then(function () { $("busy").textContent = "Working on it…"; $("busy").hidden = false; poll(); })
      .catch(function (e) { showErr(e.message); });
  }
  document.querySelectorAll("[data-act]").forEach(function (b) {
    b.addEventListener("click", function () { act(b.dataset.act, null, b.dataset.confirm); });
  });

  // ---------------------------------------------------------------- tabs
  function showTab(name) {
    tab = name;
    document.querySelectorAll("#nav button").forEach(function (b) { b.setAttribute("aria-selected", b.dataset.tab === name ? "true" : "false"); });
    document.querySelectorAll("section[data-page]").forEach(function (s) { s.hidden = s.dataset.page !== name; });
    $("title").textContent = document.querySelector('#nav button[data-tab="' + name + '"]').firstChild.textContent;
    if (name === "overview") loadLog("setup", "setup-log");
    if (name === "mail") loadLog(current("mail-log-tabs"), "mail-log");
    if (name === "maintenance") loadLog(current("maint-log-tabs"), "maint-log");
    if (name === "updates") api("action=changelog").then(function (t) { $("changelog").textContent = t || "(no changelog)"; }).catch(function () {});
    render();
  }
  document.querySelectorAll("#nav button").forEach(function (b) { b.addEventListener("click", function () { showTab(b.dataset.tab); }); });
  function current(tabsId) { var b = document.querySelector("#" + tabsId + " button[aria-selected='true']"); return b ? b.dataset.log : ""; }
  ["mail-log-tabs", "maint-log-tabs"].forEach(function (id) {
    document.querySelectorAll("#" + id + " button").forEach(function (b) {
      b.addEventListener("click", function () {
        document.querySelectorAll("#" + id + " button").forEach(function (o) { o.setAttribute("aria-selected", o === b ? "true" : "false"); });
        loadLog(b.dataset.log, id === "mail-log-tabs" ? "mail-log" : "maint-log");
      });
    });
  });
  function loadLog(part, into) {
    if (!S) return;   // the first status poll says who's asking
    if (role !== "admin") { $(into).textContent = "Only DSM administrators can read logs."; return; }
    api("action=log&part=" + part).then(function (t) { var pre = $(into), atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20; pre.textContent = t || "(empty)"; if (atEnd) pre.scrollTop = pre.scrollHeight; }).catch(function (e) { $(into).textContent = e.message; });
  }
  $("reload-setup-log").onclick = function () { loadLog("setup", "setup-log"); };
  $("last-log").onclick = function (e) {
    e.preventDefault(); showTab("maintenance");
    document.querySelectorAll("#maint-log-tabs button").forEach(function (o) { o.setAttribute("aria-selected", o.dataset.log === "setup" ? "true" : "false"); });
    loadLog("setup", "maint-log"); $("maint-log").scrollIntoView();
  };

  // ------------------------------------------------------------- render
  function stateChip() {
    var st = S.status || {}, a = st.app || {}, d = st.db || {};
    if (busy()) return chip(st.busy ? "Busy: " + st.busy : "Busy", "warn");
    if (S.state === "failed") return chip("Failed — see the setup log", "bad");
    if (S.state === "removed") return chip("Removed — Package Center is uninstalling", "bad");
    if (S.state === "stopped") return chip("Stopped", "bad");
    if (S.state === "starting") return chip(S.phase ? "Starting: " + S.phase : "Starting…", "warn");
    if (a.state === "running" && d.state === "running" && a.health !== "unhealthy") return chip(st.maintenance ? "Up, in maintenance mode" : "Up", st.maintenance ? "warn" : "ok");
    return chip("Not all running", "bad");
  }
  function render() {
    if (!S) return;
    var st = S.status || {};
    clear($("chip")); $("chip").appendChild(stateChip());
    $("busy").hidden = !busy();
    if (busy()) $("busy").textContent = st.busy ? "Working on it: " + st.busy + "…" : "Working on it…";
    $("foot").textContent = "package " + (st.build || "–") + " · " + (S.user || "");
    $("brand-version").textContent = st.version ? "FreeScout " + st.version : "help desk";
    document.querySelectorAll("button[data-act], #newadmin, #save-settings, #save-prefs, #maint-on, #maint-off, #wipe").forEach(function (b) { b.disabled = role !== "admin" || busy(); });
    $("readonly").hidden = role === "admin";
    var fa = st.activity && st.activity.failed_last_hour || 0; $("badge-activity").hidden = !(fa >= 5); $("badge-activity").textContent = String(fa);
    if (tab === "users") $("users").dataset.sig = "";   // buttons there carry their own state

    // What the last request came to, for a minute after.
    var last = st.last;
    if (last && last.at && last.at !== lastShown && Date.now() / 1000 - last.at < 120) {
      $("last").className = "note " + (last.ok ? "good" : "bad"); $("last-text").textContent = (last.ok ? "✓ " : "✗ ") + (last.message || last.action); $("last").hidden = false;
      $("last-detail").textContent = last.detail || ""; $("last-detail").hidden = !(last.ok === false && last.detail);
      $("last-log").hidden = last.ok !== false;
      if (last.at + 120 < Date.now() / 1000 + 1) lastShown = last.at;
      if (last.action === "report" && last.ok) $("report-link").hidden = false;
    } else if (!last || Date.now() / 1000 - last.at >= 120) $("last").hidden = true;
    if (st.secret && !secretShown && role === "admin") takeSecret();

    // badges
    var admins = st.admins || [], active = admins.filter(function (u) { return u.status === 1; }).length;
    $("badge-access").hidden = !(admins.length && !active); $("badge-access").textContent = "!";
    var bl = st.backup && st.backup.last;
    $("badge-backups").hidden = !(bl && bl.ok === false); $("badge-backups").textContent = "!";
    var m = st.mail; $("badge-mail").hidden = !(m && (m.failed > 0 || m.worker === "stopped")); $("badge-mail").textContent = m && m.failed > 0 ? String(m.failed) : "!";
    var modUp = (st.modules || []).filter(function (m) { return m.update; }).length;
    $("badge-modules").hidden = !modUp; $("badge-modules").textContent = String(modUp);
    var up = (st.update && st.update.newer) || (st.image_update && st.image_update.available);
    $("badge-updates").hidden = !up; $("badge-updates").textContent = "1";

    if (tab === "overview") renderOverview(st);
    if (tab === "access") renderAccess(st);
    if (tab === "users") renderUsers(st);
    if (tab === "backups") renderBackups(st);
    if (tab === "site") renderSite(st);
    if (tab === "mail") renderMail(st);
    if (tab === "modules") renderModules(st);
    if (tab === "updates") renderUpdates(st);
    if (tab === "maintenance") renderMaintenance(st);
    if (tab === "storage") renderStorage(st);
    if (tab === "activity") renderActivity(st);
  }

  function renderOverview(st) {
    var a = st.app || {}, d = st.db || {}, ok = a.state === "running" && d.state === "running";
    $("hero-dot").className = "dot " + (S.state === "failed" || S.state === "stopped" ? "bad" : busy() || S.state === "starting" ? "warn" : ok ? "ok" : "bad");
    $("hero-title").textContent = S.state === "failed" ? "FreeScout didn't start" : S.state === "stopped" ? "FreeScout is stopped" : S.state === "starting" ? "FreeScout is starting" + (S.phase ? ": " + S.phase : "") : ok ? "FreeScout is up" : "FreeScout isn't fully running";
    $("hero-sub").textContent = (st.url ? st.url + " · " : "") + (st.version ? "FreeScout " + st.version : "") + (st.at ? " · checked " + ago(st.at) : "");
    $("open-link").href = st.url || "#"; $("open-link").hidden = !st.url;
    var t = $("tiles"); clear(t);
    var dk = st.disk || {};
    tile(t, admins(st).length ? String(admins(st).length) : "–", "administrators");
    tile(t, st.mail ? String(st.mail.mailboxes) : "–", "mailboxes");
    tile(t, st.mail ? String(st.mail.failed) : "–", "failed mail jobs");
    tile(t, st.backup && st.backup.last && st.backup.last.at ? ago(st.backup.last.at) : "never", "last backup");
    tile(t, dk.free_mb != null ? mb(dk.free_mb) : "–", "free on the volume");
    tile(t, dk.data_mb != null ? mb(dk.data_mb + dk.db_mb) : "–", "data and database");
    var c = $("containers"); clear(c);
    [["freescout-app", a], ["freescout-db", d]].forEach(function (p) {
      var s = p[1].state || "missing", h = p[1].health && p[1].health !== "-" ? ", " + p[1].health : "";
      row(c, [p[0], chip(s + h, s === "running" && p[1].health !== "unhealthy" ? "ok" : s === "running" ? "warn" : "bad")]);
    });
  }
  function admins(st) { return st.admins || []; }

  function renderAccess(st) {
    var tb = $("admins"); clear(tb);
    if (!admins(st).length) { var tr = el("tr"); var td = cell("No administrators listed yet — FreeScout and its database have to be running, and the list comes in a moment.", "empty"); td.colSpan = 4; tr.appendChild(td); tb.appendChild(tr); }
    admins(st).forEach(function (u) {
      var status = u.status === 1 ? chip("active", "ok") : u.status === 2 ? chip("disabled", "warn") : chip("deleted", "bad");
      var b = btn("Reset password", "", function () { act("reset", { user_id: u.id }, "Set a new password for " + u.email + "? Their current password stops working, their account is made active, and they're signed out everywhere."); });
      row(tb, [u.name || "–", u.email, status, cell(b, "n")]);
    });
  }
  function takeSecret() {
    secretShown = true;
    api("action=take_secret", { action: "take_secret" }).then(function (s) {
      $("secret-for").textContent = s.email || ""; $("secret").textContent = s.password || ""; $("secret-card").hidden = false; showTab("access");
    }).catch(function (e) { secretShown = false; showErr(e.message); });
  }
  $("copy-secret").onclick = function () { try { navigator.clipboard.writeText($("secret").textContent); $("copy-secret").textContent = "Copied"; } catch (e) { /* select by hand */ } };
  $("newadmin").onclick = function () {
    secretShown = false; $("secret-card").hidden = true;
    act("newadmin", { email: $("new-email").value.trim(), first: $("new-first").value.trim(), last: $("new-last").value.trim() });
  };

  var userQuery = "";
  $("users-q").addEventListener("input", function () { userQuery = $("users-q").value.trim().toLowerCase(); if (S) renderUsers(S.status || {}); });
  function renderUsers(st) {
    var tb = $("users"), all = st.users || [];
    var users = all.filter(function (u) { return !userQuery || ((u.name || "") + " " + u.email).toLowerCase().indexOf(userQuery) >= 0; });
    var sig = JSON.stringify(users) + "|" + busy() + "|" + role;
    $("users-count").textContent = all.length ? (users.length === all.length ? all.length + " users" : users.length + " of " + all.length) : "";
    if (tb.dataset.sig === sig) return; tb.dataset.sig = sig;
    clear(tb);
    if (!all.length) { var tr = el("tr"); var td = cell("No users listed yet — FreeScout and its database have to be running, and the list comes in a moment.", "empty"); td.colSpan = 6; tr.appendChild(td); tb.appendChild(tr); return; }
    var activeAdmins = all.filter(function (u) { return u.role === 2 && u.status === 1; }).length;
    users.forEach(function (u) {
      var who = u.name || u.email, last = u.role === 2 && u.status === 1 && activeAdmins === 1;
      var status = u.status === 1 ? chip(u.invite === 2 ? "invited" : "active", "ok") : u.status === 2 ? chip("disabled", "warn") : chip("removed", "bad");
      var acts = el("span", null, "row");
      if (u.status !== 3) {
        acts.appendChild(btn("Reset password", "", function () { act("reset", { user_id: u.id }, "Set a new password for " + who + "? Their current password stops working, the account is made active, and they're signed out everywhere."); }));
        if (u.status === 1) { var d = btn("Disable", "", function () { act("userdisable", { user_id: u.id }, "Disable " + who + "? They can't sign in until re-enabled."); }); d.disabled = d.disabled || last; d.title = last ? "The last active administrator" : ""; acts.appendChild(d); }
        else acts.appendChild(btn("Enable", "", function () { act("userenable", { user_id: u.id }); }));
        if (u.role === 2) { var r = btn("Make agent", "", function () { act("userrole", { user_id: u.id, role: 1 }, "Make " + who + " an agent? They lose access to Manage."); }); r.disabled = r.disabled || last; r.title = last ? "The last active administrator" : ""; acts.appendChild(r); }
        else acts.appendChild(btn("Make administrator", "", function () { act("userrole", { user_id: u.id, role: 2 }, "Make " + who + " an administrator?"); }));
        var x = btn("Remove", "danger", function () { act("userdelete", { user_id: u.id }, "Remove " + who + "?\n\nTheir conversations become unassigned, they're disconnected from mailboxes, and their email address is freed. FreeScout keeps their history; this is what FreeScout's own Delete does."); }); x.disabled = x.disabled || last; x.title = last ? "The last active administrator" : ""; acts.appendChild(x);
      }
      row(tb, [u.name || "–", u.email, u.role === 2 ? "administrator" : "agent", status, u.last_login ? ago(u.last_login) + " (" + when(u.last_login) + ")" : "never", cell(acts, "n")]);
    });
  }

  function renderBackups(st) {
    var tb = $("backups"); clear(tb);
    var list = st.backups || [];
    if (!list.length) { var tr = el("tr"); var td = cell("No backups yet.", "empty"); td.colSpan = 4; tr.appendChild(td); tb.appendChild(tr); }
    list.forEach(function (b) {
      var acts = el("span", null, "row");
      var a = el("a", "Save", "btn"); a.href = withToken("api.cgi?action=backup&name=" + encodeURIComponent(b.name)); acts.appendChild(a);
      acts.appendChild(btn("Restore", "", function () { act("restore", { name: b.name }, "Restore " + b.name + "?\n\nFreeScout's database and files go back to that moment; everything since is lost. A backup of the current state is made first."); }));
      acts.appendChild(btn("Delete", "danger", function () { act("delbackup", { name: b.name }, "Delete " + b.name + "?"); }));
      row(tb, [b.name, cell(bytes(b.size), "n"), when(b.at), cell(acts, "n")]);
    });
    if (!$("pref-nightly").dataset.touched && st.backup) { $("pref-nightly").checked = !!st.backup.nightly; $("pref-keep").value = st.backup.keep || 14; }
    if (st.backup && st.backup.last && st.backup.last.ok === false) { showErr("The last backup didn't finish — the setup log says why."); }
  }
  ["pref-nightly", "pref-keep"].forEach(function (id) { $(id).addEventListener("input", function () { $("pref-nightly").dataset.touched = "1"; }); });
  $("save-prefs").onclick = function () {
    api("action=prefs", { action: "prefs", nightly: $("pref-nightly").checked ? 1 : 0, keep: $("pref-keep").value })
      .then(function () { $("pref-nightly").dataset.touched = ""; $("last").className = "note good"; $("last").textContent = "✓ Saved."; $("last").hidden = false; })
      .catch(function (e) { showErr(e.message); });
  };

  function renderSite(st) {
    if (!$("set-url").dataset.touched) { $("set-url").value = st.url || ""; $("set-port").value = st.port || ""; $("set-tz").value = st.tz || ""; $("set-ssl").checked = !!st.ssl_proxy; }
    $("site-port").textContent = st.port || "8060";
  }
  ["set-url", "set-port", "set-tz", "set-ssl"].forEach(function (id) { $(id).addEventListener("input", function () { $("set-url").dataset.touched = "1"; }); });
  $("save-settings").onclick = function () {
    act("settings", { url: $("set-url").value.trim(), port: $("set-port").value, ssl_proxy: $("set-ssl").checked ? 1 : 0, tz: $("set-tz").value.trim() }, "Save and restart FreeScout? It's away for a minute or two.")
      .then(function () { $("set-url").dataset.touched = ""; });
  };

  function renderMail(st) {
    var t = $("mail-tiles"); clear(t); var m = st.mail;
    if (!m) { tile(t, "–", "FreeScout isn't running"); return; }
    tile(t, String(m.mailboxes), "mailboxes"); tile(t, String(m.queued), "jobs queued"); tile(t, String(m.failed), "jobs failed");
    tile(t, m.worker === "running" ? "running" : "stopped", "queue worker"); tile(t, m.scheduler_at ? ago(m.scheduler_at) : "never", "scheduler last ran");
  }

  var modQuery = "", modFilter = "all";
  $("mods-q").addEventListener("input", function () { modQuery = $("mods-q").value.trim().toLowerCase(); if (S) renderModules(S.status || {}); });
  document.querySelectorAll("#mods-filter button").forEach(function (b) {
    b.addEventListener("click", function () {
      modFilter = b.dataset.f;
      document.querySelectorAll("#mods-filter button").forEach(function (o) { o.setAttribute("aria-selected", o === b ? "true" : "false"); });
      if (S) renderModules(S.status || {});
    });
  });
  function moduleMatches(m) {
    if (modFilter === "installed" && !m.installed) return false;
    if (modFilter === "updates" && !m.update) return false;
    if (modFilter === "ready" && (m.installed || m.error || (m.missing && m.missing.length) || m.app_ok === false)) return false;
    if (!modQuery) return true;
    var hay = [m.name, m.alias, m.description, m.repo, m.note, m.version].concat((m.requires || []).map(function (r) { return r.name; })).join(" ").toLowerCase();
    return modQuery.split(/\s+/).every(function (w) { return hay.indexOf(w) >= 0; });
  }
  function renderModules(st) {
    var box = $("mods"), all = st.modules || [], mods = all.filter(moduleMatches);
    var sig = JSON.stringify(mods) + "|" + busy() + "|" + role + "|" + modQuery + "|" + modFilter;
    $("mods-count").textContent = all.length ? (mods.length === all.length ? all.length + " modules" : mods.length + " of " + all.length) : "";
    if (box.dataset.sig === sig) return; box.dataset.sig = sig;
    clear(box);
    if (!all.length) { box.appendChild(el("div", "No modules listed yet — the catalog is read when FreeScout is up; look again in a minute.", "empty")); return; }
    if (!mods.length) { box.appendChild(el("div", "Nothing matches.", "empty")); return; }
    var checked = all.reduce(function (a, m) { return Math.max(a, m.checked || 0); }, 0);
    $("mods-checked").textContent = checked ? "catalog checked " + ago(checked) : "";
    mods.forEach(function (m) {
      var card = el("div", null, "mod" + (m.error ? " bad" : ""));
      var logo = el("div", null, "logo");
      if (m.logo) { var img = el("img"); img.alt = ""; img.src = withToken("api.cgi?action=modimg&alias=" + encodeURIComponent(m.alias)); logo.appendChild(img); }
      else logo.textContent = (m.name || m.alias || "?").charAt(0).toUpperCase();
      card.appendChild(logo);
      var body = el("div", null, "body"); card.appendChild(body);
      var title = el("b"); title.appendChild(el("span", m.name || m.alias || m.repo));
      if (m.installed) title.appendChild(chip(m.active ? "active" : "inactive", m.active ? "ok" : "warn")); title.lastChild.style.marginLeft = "8px";
      body.appendChild(title);
      var ver = el("div", null, "ver");
      if (m.error) ver.textContent = m.error;
      else if (m.installed) { ver.textContent = "installed " + (m.installed_version || m.installed_tag || "?") + (m.version ? " · latest " + m.version : ""); if (m.update) ver.appendChild(el("span", "  update available", "up")); }
      else ver.textContent = (m.version ? "version " + m.version : "no release yet") + " · not installed";
      body.appendChild(ver);
      if (m.description) body.appendChild(el("p", m.description));
      if (m.note) body.appendChild(el("p", m.note, "muted small"));
      if (m.app_version && m.app_ok === false) { var av = el("p", null, "small"); av.appendChild(chip("needs FreeScout " + m.app_version + " or newer (this is " + (st.version || "?") + ")", "bad")); body.appendChild(av); }
      (m.requires || []).forEach(function (r) {
        var line = el("p", null, "small");
        line.appendChild(chip((r.optional ? "optional: " : "needs ") + r.name + (r.for ? " (" + r.for + ")" : "") + (r.active ? " — active" : r.optional ? " — not installed" : " — not installed in FreeScout"), r.active ? "ok" : r.optional ? "" : "warn"));
        if (r.url) { line.appendChild(el("span", " ")); var a = el("a", "get it", "small"); a.href = r.url; a.target = "_blank"; a.rel = "noopener"; line.appendChild(a); }
        body.appendChild(line);
      });
      var row = el("div", null, "row");
      var blocked = (m.missing && m.missing.length) ? "Needs " + m.missing.join(" and ") + " first" : (m.app_version && m.app_ok === false) ? "Needs FreeScout " + m.app_version : "";
      if (!m.error && !m.installed) {
        if (blocked) { var nb = btn(blocked, "", null); nb.disabled = true; nb.title = "Install what it needs in FreeScout (Manage → Modules), then look again."; row.appendChild(nb); }
        else row.appendChild(btn("Install", "primary", function () { act("modinstall", { alias: m.alias }); }));
      }
      if (m.update) row.appendChild(btn("Update to " + m.version, "primary", function () { act("modupdate", { alias: m.alias }, "Update " + m.name + " to " + m.version + "? FreeScout's caches are rebuilt; it's a few seconds."); }));
      if (m.installed && m.active) row.appendChild(btn("Deactivate", "", function () { act("moddeactivate", { alias: m.alias }); }));
      if (m.installed && !m.active) { var ab = btn(blocked ? blocked : "Activate", "", function () { act("modactivate", { alias: m.alias }); }); if (blocked) ab.disabled = true; row.appendChild(ab); }
      if (m.installed) row.appendChild(btn("Remove", "danger", function () { act("modremove", { alias: m.alias }, "Remove " + m.name + "? Its files go; its settings and tables stay in the database."); }));
      var link = el("a", "GitHub", "btn"); link.href = m.url; link.target = "_blank"; link.rel = "noopener"; row.appendChild(link);
      body.appendChild(row);
      box.appendChild(card);
    });
  }

  function renderUpdates(st) {
    var a = $("upd-app"); clear(a); var iu = st.image_update, pu = st.update;
    a.appendChild(el("p", "Installed: FreeScout " + (st.version || "?") + " from " + (st.image || "nfrastack/freescout:latest") + "."));
    if (iu && iu.available) {
      a.appendChild(el("p", "A newer FreeScout image is available. Updating backs everything up first, pulls the new image and restarts FreeScout; it migrates its database on the way. Away for a few minutes.", "muted small"));
      a.appendChild(btn("Update FreeScout", "primary", function () { act("updateapp", null, "Update FreeScout now? A backup is made first; FreeScout is away for a few minutes."); }));
    } else a.appendChild(el("p", iu && iu.error ? "Couldn't check the registry: " + iu.error : "FreeScout's image is current" + (iu && iu.checked ? " (checked " + ago(iu.checked) + ")" : "") + ".", "muted small"));
    var p = $("upd-pkg"); clear(p);
    p.appendChild(el("p", "Installed: package " + (st.build || "?") + "."));
    if (pu && pu.newer) {
      p.appendChild(el("p", "Package " + pu.latest + " is out. Installing it hands the package to Package Center; this window goes away and comes back with the new version.", "muted small"));
      var l = el("a", "What's new", ""); l.href = pu.page; l.target = "_blank"; l.rel = "noopener"; p.appendChild(l); p.appendChild(el("span", " "));
      p.appendChild(btn("Update the package", "primary", function () { act("upgrade", null, "Install package " + pu.latest + " now? FreeScout stops and starts again with it."); }));
    } else p.appendChild(el("p", pu && pu.error ? "Couldn't check GitHub: " + pu.error : "The package is current" + (pu && pu.checked ? " (checked " + ago(pu.checked) + ")" : "") + ".", "muted small"));
    p.appendChild(el("span", " ")); p.appendChild(btn("Look for updates now", "", function () { act("check"); }));
  }

  function renderStorage(st) {
    var s = st.storage, t = $("storage-tiles"); clear(t);
    if (!s) { tile(t, "–", "FreeScout isn't running, or the report comes in a moment"); return; }
    var d = s.dirs || {}, l = s.logs || {}, r = s.rows || {};
    tile(t, mb(d.data), "data volume"); tile(t, mb(d["storage/app/attachment"]), "attachments"); tile(t, mb(s.db_mb), "database");
    tile(t, mb((l.logs || 0) + (d["storage/logs"] || 0)), "logs"); tile(t, mb(d.Modules), "modules");
    tile(t, String(r.conversations || 0), "conversations"); tile(t, String(r.customers || 0), "customers"); tile(t, String(r.attachments || 0), "attachment records");
    var mbx = $("storage-mailboxes"); clear(mbx);
    (s.mailboxes || []).forEach(function (m) { row(mbx, [m.name, cell(String(m.count), "n"), cell(bytes(m.bytes), "n")]); });
    if (!(s.mailboxes || []).length) { var tr = el("tr"); var td = cell("No attachments yet.", "empty"); td.colSpan = 3; tr.appendChild(td); mbx.appendChild(tr); }
    var tb = $("storage-tables"); clear(tb);
    (s.tables || []).forEach(function (x) { row(tb, [x.name, cell(String(x.rows), "n"), cell(bytes(x.bytes), "n")]); });
    var dr = $("storage-dirs"); clear(dr);
    [["Attachments (storage/app/attachment)", d["storage/app/attachment"]], ["Uploads and app files (storage/app)", d["storage/app"]], ["FreeScout log files (storage/logs)", d["storage/logs"]], ["Caches and sessions (storage/framework)", d["storage/framework"]], ["Modules", d.Modules], ["Configuration", d.config], ["nginx logs", l.nginx], ["PHP logs", l["php-fpm"]], ["Scheduler and worker logs", l.laravel]].forEach(function (p) { kv(dr, p[0], mb(p[1] || 0), true); });
    kv(dr, "Rows that get trimmed: send log / notifications / activity", (r.send_logs || 0) + " / " + (r.notifications || 0) + " / " + (r.activity || 0), true);
    $("storage-tiles").title = s.at ? "measured " + ago(s.at) : "";
  }
  var activityQuery = "";
  $("activity-q").addEventListener("input", function () { activityQuery = $("activity-q").value.trim().toLowerCase(); if (S) renderActivity(S.status || {}); });
  function renderActivity(st) {
    var a = st.activity, t = $("activity-tiles"); clear(t);
    if (!a) { tile(t, "–", "FreeScout isn't running, or the report comes in a moment"); return; }
    var ents = a.entries || [], logins = ents.filter(function (e) { return e.what === "login"; });
    tile(t, String(a.failed_last_hour || 0), "failed sign-ins, last hour"); tile(t, String((a.failed_by_ip || []).reduce(function (n, x) { return n + x.count; }, 0)), "failed, last 24 h");
    tile(t, logins.length ? ago(logins[0].at) : "none seen", "last sign-in"); tile(t, String(ents.length), "events listed");
    $("activity-byip-card").hidden = !(a.failed_by_ip || []).length;
    var bi = $("activity-byip"); clear(bi); (a.failed_by_ip || []).forEach(function (x) { row(bi, [x.ip, cell(String(x.count), "n")]); });
    var names = { login: "signed in", logout: "signed out", login_failed: "failed sign-in", locked: "locked out (too many attempts)", password_reset: "password reset", register: "registered" };
    var rows = $("activity-rows"); clear(rows);
    var shown = ents.filter(function (e) { return !activityQuery || ((names[e.what] || e.what) + " " + e.who + " " + e.ip).toLowerCase().indexOf(activityQuery) >= 0; });
    shown.slice(0, 200).forEach(function (e) {
      var kind = names[e.what] || e.what, c = e.what === "login_failed" || e.what === "locked" ? "bad" : e.what === "login" ? "ok" : "";
      row(rows, [when(e.at), chip(kind, c), e.who || "–", e.ip || "–"]);
    });
    if (!shown.length) { var tr = el("tr"); var td = cell(ents.length ? "Nothing matches." : "No events yet.", "empty"); td.colSpan = 4; tr.appendChild(td); rows.appendChild(td.parentNode); }
  }

  function renderMaintenance(st) {
    $("maint-state").textContent = st.maintenance ? "FreeScout is in maintenance mode: visitors see a notice while you work on it." : "FreeScout is open to everyone. Maintenance mode shows visitors a notice instead, for instance while restoring a backup by hand.";
    $("maint-on").disabled = role !== "admin" || busy() || !!st.maintenance; $("maint-off").disabled = role !== "admin" || busy() || !st.maintenance;
  }
  $("wipe").onclick = function () {
    if (!$("wipe-saved").checked) { showErr("Tick the box first — the backups go too."); return; }
    if ($("wipe-phrase").value.trim() !== "remove everything") { showErr("Type exactly: remove everything"); return; }
    act("wipe", { confirm: $("wipe-phrase").value.trim() }, "Last chance. FreeScout, all of its data and backups, and the package will be removed. There is no undo.\n\nRemove everything?");
  };
  $("maint-on").onclick = function () { act("maintenance", { on: 1 }); };
  $("maint-off").onclick = function () { act("maintenance", { on: 0 }); };

  // ---------------------------------------------------------------- poll
  var polling = false;
  function poll() {
    if (polling || document.hidden) return; polling = true;
    api("action=status").then(function (s) { var first = !S; S = s; role = s.role; showErr(""); if (first) showTab(tab); else render(); }).catch(function (e) { showErr(e.message); }).then(function () { polling = false; });
  }
  // A tab named in the URL (panel.html#modules) opens first; the hash follows the tab.
  var wanted = (location.hash || "").slice(1);
  if (wanted && document.querySelector('#nav button[data-tab="' + wanted + '"]')) tab = wanted;
  document.querySelectorAll("#nav button").forEach(function (b) { b.addEventListener("click", function () { try { history.replaceState(null, "", "#" + b.dataset.tab); } catch (e) { /* fine */ } }); });
  poll(); setInterval(poll, 3000);
  setInterval(function () { if (tab === "overview") loadLog("setup", "setup-log"); if (tab === "mail") loadLog(current("mail-log-tabs"), "mail-log"); if (tab === "maintenance") loadLog(current("maint-log-tabs"), "maint-log"); }, 8000);
  document.addEventListener("visibilitychange", function () { if (!document.hidden) poll(); });
  showTab(tab);
})();
