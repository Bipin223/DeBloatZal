"use strict";

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

const bridge = window.chrome && window.chrome.webview ? window.chrome.webview : null;

const ICONS = {
  chevron: '<svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="m9 6 6 6-6 6"/></svg>',
  lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><rect x="5" y="10" width="14" height="10" rx="2.6"/><path d="M8 10V7.6a4 4 0 0 1 8 0V10"/></svg>',
  phone: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><rect x="6" y="2.8" width="12" height="18.4" rx="2.6"/><path d="M11 18.2h2"/></svg>'
};

const S = {
  device: null,
  profiles: [],
  profile: "",
  packages: [],
  map: new Map(),
  view: "recommended",
  selected: new Set(),
  detail: null,
  search: "",
  busy: false,
  demo: false,
  userOnly: false,
  loadingText: "Reading packages…",
  pendingRestore: null
};

let searchTimer = null;
let toastTimer = null;
let modalResolve = null;

function send(type, payload) {
  if (!bridge) return;
  bridge.postMessage(Object.assign({ type }, payload || {}));
}

function esc(value) {
  return String(value == null ? "" : value).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}

function cap(value) {
  const s = String(value || "");
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

function tierLabel(tier) {
  return { core: "Core", optional: "Optional", protect: "Protected", other: "Other" }[tier] || cap(tier);
}

function riskLabel(risk) {
  return { low: "Low", medium: "Medium", high: "High", critical: "Critical", unknown: "Unknown" }[risk] || cap(risk);
}

function stateLabel(state) {
  return { enabled: "Installed", disabled: "Disabled", uninstalled: "Removed" }[state] || state;
}

function badge(p) {
  const map = { recommended: "safe", optional: "optional", caution: "caution", risky: "risky", critical: "critical", unknown: "unknown", user: "user" };
  const label = p.recLabel || p.rec;
  return `<span class="badge ${map[p.rec] || "unknown"}"><span class="dot"></span>${esc(label)}</span>`;
}

function stateChip(p) {
  const cls = p.state === "uninstalled" ? "removed" : p.state === "disabled" ? "disabled" : "installed";
  return `<span class="state ${cls}"><span class="dot"></span>${stateLabel(p.state)}</span>`;
}


function byId(id) {
  return S.map.get(id) || null;
}

function setPackages(list) {
  S.packages = Array.isArray(list) ? list : [];
  S.map = new Map(S.packages.map((p) => [p.id, p]));
  const alive = new Set(S.packages.map((p) => p.id));
  for (const id of Array.from(S.selected)) {
    if (!alive.has(id)) S.selected.delete(id);
  }
  if (S.detail && !alive.has(S.detail)) S.detail = null;
}

function clearUserFilter() {
  if (!S.userOnly) return;
  S.userOnly = false;
  $("#userAppsBtn").classList.remove("active");
}

function setView(view, preserveSelection) {
  if (!["recommended", "optional", "critical", "all", "removed"].includes(view)) view = "recommended";
  const previous = S.view;
  const crossing = (previous === "removed") !== (view === "removed");
  S.view = view;
  if (crossing && !preserveSelection) S.selected.clear();
  $$("#viewSegments button").forEach((b) => b.classList.toggle("active", b.dataset.view === view));
  positionSegThumb();
  const rows = visibleRows();
  if (rows.length && !rows.some((p) => p.id === S.detail)) S.detail = rows[0].id;
  renderList();
  renderDetail();
  renderFooter();
}

function visibleRows() {
  const q = S.search.trim().toLowerCase();

  // A search is global and matches apps, not description words: app names
  // and package ids across every package on the phone.
  if (q) {
    return S.packages
      .map((p) => ({ p, score: searchScore(p, q) }))
      .filter((x) => x.score < 99)
      .sort((a, b) => (a.score - b.score) || (a.p.rank - b.p.rank) || String(a.p.name).localeCompare(String(b.p.name)))
      .map((x) => x.p);
  }

  return S.packages
    .filter((p) => {
      if (S.userOnly && !p.user) return false;
      if (S.view === "removed") return p.state === "uninstalled";
      if (p.state === "uninstalled") return false;
      if (S.view === "recommended") return p.rec === "recommended";
      if (S.view === "optional") return p.rec === "optional";
      if (S.view === "critical") return p.rec === "critical";
      return true;
    })
    .sort((a, b) => (a.rank - b.rank) || String(a.name).localeCompare(String(b.name)));
}

const GENERIC_PREFIX_WORDS = new Set([
  "installer", "installs", "installed", "installing", "installation", "instance", "instant", "instantly"
]);

function wordMatches(word, q) {
  if (!word.startsWith(q)) return false;
  if (q.length < 6 && GENERIC_PREFIX_WORDS.has(word)) return false;
  return true;
}

function searchScore(p, q) {
  const name = String(p.name || "").toLowerCase();
  const id = String(p.id || "").toLowerCase();

  if (name === q) return 0;
  if (name.startsWith(q)) return 1;
  if (wordsOf(name).some((w) => wordMatches(w, q))) return 2;
  if (id === q) return 2;
  if (id.split(".").some((w) => wordMatches(w, q))) return 3;
  if (q.includes(".") && id.includes(q)) return 3;
  if (q.length >= 6 && name.includes(q)) return 4;
  return 99;
}

function wordsOf(text) {
  return String(text || "")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
}

function rowHtml(p, index) {
  const selected = S.selected.has(p.id);
  const removed = p.state === "uninstalled";
  const locked = !!p.protected;
  const cls = [
    "row",
    selected ? "selected" : "",
    removed ? "removed" : "",
    removed && selected ? "restore" : "",
    locked ? "locked" : "",
    S.detail === p.id ? "inspecting" : ""
  ].filter(Boolean).join(" ");
  const check = locked
    ? `<span class="check locked" title="Protected by the tool">${ICONS.lock}</span>`
    : `<button class="check ${selected ? "checked" : ""}" data-act="toggle" aria-label="Select"></button>`;

  return `<div class="${cls}" data-id="${esc(p.id)}" style="--i:${Math.min(index, 18)}">
    ${check}
    <div class="app" title="${esc(p.id)}">
      <div class="app-name">${esc(p.name)}</div>
      <div class="app-desc">${esc(p.desc)}</div>
    </div>
    <div class="row-badges">${badge(p)}${stateChip(p)}</div>
    ${ICONS.chevron}
  </div>`;
}

function renderList() {
  const list = $("#list");
  const empty = $("#empty");
  const rows = visibleRows();
  const action = $("#emptyAction");

  if (action) {
    action.textContent = S.search ? "Clear search" : S.userOnly ? "Show all apps" : "Refresh";
  }

  list.innerHTML = rows.map(rowHtml).join("");
  empty.hidden = rows.length > 0;
  if (S.detail && !rows.some((p) => p.id === S.detail)) {
    S.detail = rows.length ? rows[0].id : null;
  }

  const names = { recommended: "Recommended", optional: "Optional", critical: "Critical", all: "All packages", removed: "Removed" };
  $("#listSection").textContent = S.search ? "Search results" : (S.userOnly ? `My apps · ${names[S.view]}` : names[S.view]);
  $("#listCount").textContent = `${rows.length} package${rows.length === 1 ? "" : "s"}`;

  if (!rows.length) {
    let copy;
    if (!S.device) {
      copy = ["No phone connected", "Enable USB debugging, plug in, then press refresh."];
    }
    else if (S.search) {
      copy = ["No apps found", `Nothing matches “${S.search}” by app name or package id. Try a shorter name.`];
    }
    else if (S.userOnly) {
      copy = ["No user apps", "Only apps you installed yourself are shown. Turn off My apps or switch to All."];
    }
    else {
      copy = {
        recommended: ["No recommended packages", "Nothing in this profile is marked safe, or it is already removed."],
        optional: ["No optional apps", "Switch to All to see everything on the phone."],
        critical: ["Nothing critical", "No locked system packages match this profile on the phone."],
        removed: ["No removed apps", "Apps you remove will appear here, ready to restore."],
        all: ["No packages", "This profile has no matching packages on the phone."]
      }[S.view] || ["No packages", ""];
    }
    $("#emptyTitle").textContent = copy[0];
    $("#emptyText").textContent = copy[1];
  }
}

function renderStats() {
  const installed = S.packages.filter((p) => p.state !== "uninstalled");
  $("#statSafe").textContent = installed.filter((p) => p.rec === "recommended").length;
  $("#statOptional").textContent = installed.filter((p) => p.rec === "optional").length;
  $("#statCritical").textContent = installed.filter((p) => p.rec === "critical").length;
  $("#statRemoved").textContent = S.packages.filter((p) => p.state === "uninstalled").length;
  $("#statSelected").textContent = S.selected.size;
  updateSegmentCounts();
}

function updateSegmentCounts() {
  const installed = S.packages.filter((p) => p.state !== "uninstalled");
  const counts = {
    recommended: installed.filter((p) => p.rec === "recommended").length,
    optional: installed.filter((p) => p.rec === "optional").length,
    critical: installed.filter((p) => p.rec === "critical").length,
    all: installed.length,
    removed: S.packages.filter((p) => p.state === "uninstalled").length
  };
  const labels = { recommended: "Recommended", optional: "Optional", critical: "Critical", all: "All", removed: "Removed" };
  $$("#viewSegments button").forEach((b) => {
    b.innerHTML = `${labels[b.dataset.view]} <span class="seg-count">${counts[b.dataset.view]}</span>`;
  });
  const userCount = installed.filter((p) => p.user).length;
  const chip = $("#userAppsCount");
  if (chip) chip.textContent = userCount;
  requestAnimationFrame(positionSegThumb);
}

function positionSegThumb() {
  const active = $("#viewSegments button.active");
  const thumb = $("#viewThumb");
  if (!active || !thumb) return;
  thumb.style.width = `${active.offsetWidth}px`;
  thumb.style.transform = `translateX(${active.offsetLeft}px)`;
}

function removeSelection() {
  return Array.from(S.selected)
    .map(byId)
    .filter((p) => p && !p.protected && p.state !== "uninstalled");
}

function restoreSelection() {
  return Array.from(S.selected)
    .map(byId)
    .filter((p) => p && !p.protected && p.state === "uninstalled");
}

function renderFooter() {
  const remove = removeSelection();
  const restore = restoreSelection();
  const hasDevice = !!S.device;
  const busy = S.busy;
  const viewRemoved = S.view === "removed";

  const removeWord = "Remove";
  $("#applyBtn").textContent = `${removeWord} ${remove.length}`;
  $("#restoreBtn").textContent = `Restore ${restore.length}`;

  const showRemove = remove.length > 0 || (restore.length === 0 && !viewRemoved);
  const showRestore = restore.length > 0 || (remove.length === 0 && viewRemoved);
  $("#applyBtn").hidden = !showRemove;
  $("#restoreBtn").hidden = !showRestore;

  $("#applyBtn").disabled = !hasDevice || busy || remove.length === 0;
  $("#restoreBtn").disabled = !hasDevice || busy || restore.length === 0;

  const selectBtn = $("#selectSafeBtn");
  if (viewRemoved) {
    selectBtn.textContent = "Select all removed";
    const removedCount = S.packages.filter((p) => p.state === "uninstalled" && !p.protected).length;
    selectBtn.disabled = !hasDevice || busy || removedCount === 0;
  }
  else {
    selectBtn.textContent = "Select recommended";
    const canSelectSafe = hasDevice && !busy && !S.userOnly && S.packages.length > 0 && (S.view === "recommended" || S.view === "all");
    selectBtn.disabled = !canSelectSafe;
  }

  $("#clearBtn").disabled = busy || S.selected.size === 0;

  if (!S.busy) {
    const total = S.packages.length;
    const shown = visibleRows().length;
    const removedTotal = S.packages.filter((p) => p.state === "uninstalled").length;
    const parts = [];
    if (remove.length) parts.push(`${remove.length} to remove`);
    if (restore.length) parts.push(`${restore.length} to restore`);
    const selText = parts.length ? parts.join(" · ") : "0 selected";
    const scope = viewRemoved
      ? `${removedTotal} removed`
      : `${total} total · ${shown} shown${S.userOnly ? " · My apps" : ""}`;
    $("#footerNote").textContent = hasDevice
      ? (S.search ? `“${S.search}” · ${shown} match${shown === 1 ? "" : "es"} · ${selText}` : `${scope} · ${selText}`)
      : "No phone connected";
  }
}

function renderDevice() {
  const d = S.device;
  const name = $("#deviceName");
  const meta = $("#deviceMeta");
  const dot = $("#statusDot");
  const warning = $("#warning");
  const profileBtn = $("#profileBtn");
  const profileLabel = $("#profileLabel");

  if (!d) {
    name.textContent = "No phone connected";
    meta.textContent = "Enable USB debugging, plug in, then refresh.";
    dot.className = "status-dot";
    warning.hidden = true;
    profileBtn.disabled = true;
    profileLabel.textContent = "No profile";
    $("#powerBtn").disabled = true;
    return;
  }

  name.textContent = `${cap(d.manufacturer)} ${d.model}`;
  const os = d.os ? `${d.os} · ` : "";
  meta.textContent = `${os}Android ${d.android}`;
  meta.title = d.serial || "";
  dot.className = "status-dot " + (S.demo ? "demo" : "online");
  profileBtn.disabled = S.profiles.length === 0;
  profileLabel.textContent = S.profile || "Choose profile";
  $("#powerBtn").disabled = false;

  if (d.warning) {
    warning.textContent = d.warning;
    warning.hidden = false;
  } else {
    warning.hidden = true;
  }

  $("#demoChip").hidden = !S.demo;
}

function renderProfileMenu() {
  const menu = $("#profileMenu");
  if (!S.profiles.length) {
    menu.innerHTML = '<button disabled>No profiles found</button>';
    return;
  }
  menu.innerHTML = S.profiles.map((name) =>
    `<button data-profile="${esc(name)}" class="${name === S.profile ? "active" : ""}">${esc(name)}</button>`
  ).join("");
}

function renderDetail() {
  const detail = $("#detail");
  const p = S.detail ? byId(S.detail) : null;

  if (!p) {
    detail.innerHTML = `<div class="detail-empty">
      <div class="empty-icon">${ICONS.phone}</div>
      <div class="detail-empty-title">Select a package</div>
      <div class="detail-empty-text">Pick a row to see what it is, how risky it is, and whether it is safe to remove.</div>
    </div>`;
    return;
  }

  const selected = S.selected.has(p.id);
  const locked = !!p.protected;
  const removed = p.state === "uninstalled";
  let cta;
  if (locked) {
    cta = `<button class="pill full" disabled>${ICONS.lock}<span>Protected — cannot remove</span></button>`;
  } else if (removed) {
    cta = `<button class="pill full success" data-act="toggle-detail">${selected ? "Deselect restore" : "Select to restore"}</button>`;
  } else {
    cta = `<button class="pill full primary" data-act="toggle-detail">${selected ? "Deselect remove" : "Select to remove"}</button>`;
  }

  detail.innerHTML = `
    <div class="detail-eyebrow">PACKAGE</div>
    <div class="detail-name">${esc(p.name)}</div>
    <div class="detail-pkg">${esc(p.id)}</div>
    <div class="detail-badges">${badge(p)}${stateChip(p)}</div>
    <div class="detail-section-label">WHAT IT DOES</div>
    <p class="detail-desc">${esc(p.desc)}</p>
    <div class="why">
      <div class="why-label">RECOMMENDATION</div>
      <div class="why-text">${esc(p.why)}</div>
    </div>
    <div class="meta">
      <div class="meta-row"><span class="meta-key">Tier</span><span class="meta-val">${tierLabel(p.tier)}</span></div>
      <div class="meta-row"><span class="meta-key">Risk</span><span class="meta-val">${riskLabel(p.risk)}</span></div>
      <div class="meta-row"><span class="meta-key">State</span><span class="meta-val">${stateLabel(p.state)}</span></div>
      <div class="meta-row"><span class="meta-key">Type</span><span class="meta-val">${p.user ? "User app" : "System app"}</span></div>
      <div class="meta-row"><span class="meta-key">Recommendation</span><span class="meta-val">${esc(p.recLabel)}</span></div>
    </div>
    <div class="detail-cta">${cta}</div>`;
}

function refreshSelectionUI() {
  $$(".row").forEach((row) => {
    const p = byId(row.dataset.id);
    if (!p) return;
    const selected = S.selected.has(p.id);
    const removed = p.state === "uninstalled";
    row.classList.toggle("selected", selected);
    row.classList.toggle("restore", selected && removed);
    row.classList.toggle("inspecting", p.id === S.detail);
    const check = row.querySelector(".check");
    if (check && !p.protected) check.classList.toggle("checked", selected);
  });
  renderStats();
  renderFooter();
  renderDetail();
}

function updateInspecting() {
  $$(".row").forEach((row) => row.classList.toggle("inspecting", row.dataset.id === S.detail));
}

function toggleSelect(id) {
  const p = byId(id);
  if (!p) return;
  S.detail = id;
  if (p.protected) {
    updateInspecting();
    renderDetail();
    toast("This package is protected by the tool.", "warn");
    return;
  }
  if (S.selected.has(id)) S.selected.delete(id);
  else {
    const removed = p.state === "uninstalled";
    const mixed = Array.from(S.selected).some((sid) => {
      const q = byId(sid);
      return q && (q.state === "uninstalled") !== removed;
    });
    if (mixed) S.selected.clear();
    S.selected.add(id);
  }
  refreshSelectionUI();
}

function selectSafe() {
  const safe = S.packages.filter((p) =>
    p.rec === "recommended" &&
    p.state !== "uninstalled" &&
    !p.protected
  );
  S.selected.clear();
  safe.forEach((p) => S.selected.add(p.id));
  refreshSelectionUI();
  toast(`${safe.length} safe package${safe.length === 1 ? "" : "s"} selected.`);
}

function selectAllRemoved() {
  const rows = S.packages.filter((p) => p.state === "uninstalled" && !p.protected);
  S.selected.clear();
  rows.forEach((p) => S.selected.add(p.id));
  refreshSelectionUI();
  toast(`${rows.length} removed package${rows.length === 1 ? "" : "s"} selected.`);
}

function clearSelection() {
  S.selected.clear();
  refreshSelectionUI();
}

function setBusy(busy, text) {
  S.busy = !!busy;
  const progress = $("#topProgress");
  progress.classList.toggle("show", S.busy && !$("#loading").offsetParent);
  $("#refreshBtn").classList.toggle("spinning", S.busy);
  if (S.busy && text) {
    $("#footerNote").textContent = text;
    $("#loadingText").textContent = text;
  }
  if (!S.busy) {
    progress.classList.remove("indeterminate");
    $("#topProgressBar").style.width = "0%";
  }
  renderFooter();
}

function setProgress(value, total, text) {
  const bar = $("#topProgressBar");
  const progress = $("#topProgress");
  progress.classList.add("show");
  if (total && total > 0) {
    progress.classList.remove("indeterminate");
    bar.style.width = `${Math.min(100, Math.round((value / total) * 100))}%`;
    $("#footerNote").textContent = text || `Working ${value} / ${total}`;
  } else {
    progress.classList.add("indeterminate");
    $("#footerNote").textContent = text || "Working…";
  }
}

function toast(text, kind) {
  const el = $("#toast");
  el.textContent = text;
  el.className = "toast show" + (kind ? " " + kind : "");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.className = "toast"; }, 3400);
}

function confirmModal(opts) {
  return new Promise((resolve) => {
    modalResolve = resolve;
    $("#modalTitle").textContent = opts.title;
    $("#modalText").textContent = opts.text || "";
    const ok = $("#modalOk");
    ok.textContent = opts.ok || "Confirm";
    ok.className = "pill " + (opts.danger === false ? "success" : "danger");
    const modal = $("#modal");
    modal.hidden = false;
    requestAnimationFrame(() => modal.classList.add("show"));
  });
}

function closeModal(value) {
  const modal = $("#modal");
  modal.classList.remove("show");
  setTimeout(() => { modal.hidden = true; }, 160);
  if (modalResolve) {
    const resolve = modalResolve;
    modalResolve = null;
    resolve(value);
  }
}

async function applySelected() {
  const ids = removeSelection().map((p) => p.id);
  if (!ids.length) return;
  if (S.demo) { toast("Preview only — connect a phone to apply changes.", "warn"); return; }
  const word = "Remove";
  const ok = await confirmModal({
    title: `${word} ${ids.length} package${ids.length === 1 ? "" : "s"}?`,
    text: `From ${S.device ? S.device.model : "the phone"}. They disappear from the app drawer and can be restored from Removed at any time.`,
    ok: word
  });
  if (!ok) return;
  setBusy(true, `${word}…`);
  setProgress(0, ids.length, `${word} 0 / ${ids.length}`);
  send("apply", { packages: ids });
}

async function restoreSelected() {
  const ids = restoreSelection().map((p) => p.id);
  if (!ids.length) return;
  if (S.demo) { toast("Preview only — connect a phone to restore.", "warn"); return; }
  const ok = await confirmModal({
    title: `Restore ${ids.length} package${ids.length === 1 ? "" : "s"}?`,
    text: "They will reappear in the app drawer. This only works when the app is still installed for another user.",
    ok: "Restore",
    danger: false
  });
  if (!ok) return;
  S.pendingRestore = ids;
  setBusy(true, "Restoring…");
  setProgress(0, ids.length, `Restore 0 / ${ids.length}`);
  send("restore", { packages: ids });
}

async function rebootPhone() {
  if (S.demo) { toast("Preview only — no phone connected.", "warn"); return; }
  const ok = await confirmModal({
    title: "Reboot the phone?",
    text: "The phone will restart so the launcher picks up the changes.",
    ok: "Reboot"
  });
  if (!ok) return;
  send("reboot");
}

function renderAll() {
  renderDevice();
  renderProfileMenu();
  renderStats();
  $("#userAppsBtn").classList.toggle("active", S.userOnly);
  const rows = visibleRows();
  if (!S.detail && rows.length) S.detail = rows[0].id;
  renderList();
  renderDetail();
  renderFooter();
  $$("#viewSegments button").forEach((b) => b.classList.toggle("active", b.dataset.view === S.view));
}

function onMessage(msg) {
  if (!msg || !msg.type) return;
  switch (msg.type) {
    case "init": {
      S.device = msg.device || null;
      S.profiles = msg.profiles || [];
      S.profile = msg.profile || "";
      S.demo = !!msg.demo;
      if (msg.view) S.view = msg.view;
      S.userOnly = !!msg.userOnly;
      S.search = msg.search || "";
      if (S.userOnly && ["recommended", "optional", "critical"].includes(S.view)) S.view = "all";
      $("#searchInput").value = S.search;
      $("#searchClear").hidden = !S.search;
      $("#searchScope").hidden = !S.search;
      setPackages(msg.packages || []);
      S.selected.clear();
      S.detail = null;
      $("#loading").hidden = true;
      $("#demoChip").hidden = !S.demo;
      renderAll();
      break;
    }
    case "device": {
      S.device = msg.device || null;
      S.profile = msg.profile || S.profile;
      S.profiles = msg.profiles || S.profiles;
      S.demo = !!msg.demo;
      renderDevice();
      renderProfileMenu();
      renderFooter();
      break;
    }
    case "packages": {
      setPackages(msg.packages || []);
      $("#loading").hidden = true;
      renderAll();
      break;
    }
    case "busy": {
      setBusy(!!msg.value, msg.text || "");
      if (msg.value) {
        $("#topProgress").classList.add("show");
      }
      break;
    }
    case "progress": {
      setProgress(msg.value || 0, msg.total || 0, msg.text || "");
      break;
    }
    case "done": {
      setBusy(false, "");
      $("#topProgress").classList.remove("show");
      const word = msg.kind === "restore" ? "Restored" : "Removed";
      toast(`${word} ${msg.applied}${msg.failed ? ` · ${msg.failed} failed` : ""}.`, msg.failed ? "warn" : "");
      if (msg.kind === "apply" && msg.applied > 0) {
        setView("removed", true);
      }
      if (msg.kind === "restore") {
        if (S.pendingRestore) {
          S.pendingRestore.forEach((id) => S.selected.delete(id));
          S.pendingRestore = null;
          refreshSelectionUI();
        }
      }
      break;
    }
    case "toast": {
      setBusy(false, "");
      toast(msg.text || "", msg.kind || "");
      break;
    }
    case "windowState": {
      document.body.classList.toggle("maximized", !!msg.maximized);
      $("#maxBtn").title = msg.maximized ? "Restore" : "Maximize";
      break;
    }
    case "error": {
      setBusy(false, "");
      $("#loading").hidden = true;
      toast(msg.text || "Something went wrong.", "error");
      break;
    }
    default:
      break;
  }
}

function bind() {
  if (bridge) {
    bridge.addEventListener("message", (event) => onMessage(event.data));
  }

  $("#viewSegments").addEventListener("click", (e) => {
    const btn = e.target.closest("button[data-view]");
    if (btn) {
      clearUserFilter();
      setView(btn.dataset.view);
    }
  });

  $("#userAppsBtn").addEventListener("click", () => {
    S.userOnly = !S.userOnly;
    $("#userAppsBtn").classList.toggle("active", S.userOnly);
    if (S.userOnly && S.view !== "all") {
      setView("all");
    }
    else {
      renderList();
      renderDetail();
      renderFooter();
      renderStats();
    }
  });

  $$(".sum").forEach((stat) => {
    stat.addEventListener("click", () => {
      clearUserFilter();
      setView(stat.dataset.jump);
    });
  });

  $("#searchInput").addEventListener("input", (e) => {
    clearTimeout(searchTimer);
    const value = e.target.value;
    if (value) clearUserFilter();
    $("#searchClear").hidden = !value;
    $("#searchScope").hidden = !value;
    searchTimer = setTimeout(() => {
      S.search = value;
      renderList();
      renderDetail();
      renderFooter();
    }, 70);
  });

  $("#searchClear").addEventListener("click", () => {
    $("#searchInput").value = "";
    $("#searchClear").hidden = true;
    $("#searchScope").hidden = true;
    S.search = "";
    renderList();
    renderDetail();
    renderFooter();
    $("#searchInput").focus();
  });

  $("#list").addEventListener("click", (e) => {
    const row = e.target.closest(".row");
    if (!row) return;
    const id = row.dataset.id;
    S.detail = id;
    const p = byId(id);
    if (p && !p.protected) {
      toggleSelect(id);
    } else {
      updateInspecting();
      renderDetail();
    }
  });

  let inspectTimer = null;
  $("#list").addEventListener("mouseover", (e) => {
    const row = e.target.closest(".row");
    if (!row) return;
    const id = row.dataset.id;
    if (id === S.detail) return;
    clearTimeout(inspectTimer);
    inspectTimer = setTimeout(() => {
      S.detail = id;
      updateInspecting();
      renderDetail();
    }, 80);
  });
  $("#list").addEventListener("mouseleave", () => clearTimeout(inspectTimer));

  $("#detail").addEventListener("click", (e) => {
    if (e.target.closest("[data-act='toggle-detail']")) {
      toggleSelect(S.detail);
    }
  });

  $("#selectSafeBtn").addEventListener("click", () => {
    if (S.view === "removed") selectAllRemoved();
    else selectSafe();
  });
  $("#clearBtn").addEventListener("click", clearSelection);

  $("#emptyAction").addEventListener("click", () => {
    if (S.search) {
      $("#searchInput").value = "";
      $("#searchClear").hidden = true;
      $("#searchScope").hidden = true;
      S.search = "";
      renderList();
      renderDetail();
      renderFooter();
      return;
    }
    if (S.userOnly) {
      S.userOnly = false;
      $("#userAppsBtn").classList.remove("active");
      renderList();
      renderDetail();
      renderFooter();
      renderStats();
      return;
    }
    send("refresh");
  });
  $("#applyBtn").addEventListener("click", applySelected);
  $("#restoreBtn").addEventListener("click", restoreSelected);
  $("#powerBtn").addEventListener("click", rebootPhone);

  $("#refreshBtn").addEventListener("click", () => {
    if (S.busy) return;
    setBusy(true, "Reading packages…");
    setProgress(0, 0, "Reading packages…");
    send("refresh");
  });

  $("#profileBtn").addEventListener("click", (e) => {
    e.stopPropagation();
    if ($("#profileBtn").disabled) return;
    $("#profileMenu").hidden = !$("#profileMenu").hidden;
  });

  $("#profileMenu").addEventListener("click", (e) => {
    const btn = e.target.closest("button[data-profile]");
    if (!btn) return;
    const name = btn.dataset.profile;
    $("#profileMenu").hidden = true;
    if (name === S.profile) return;
    setBusy(true, "Loading profile…");
    setProgress(0, 0, "Loading profile…");
    send("profile", { profile: name });
  });

  document.addEventListener("click", (e) => {
    if (!e.target.closest(".profile-wrap")) $("#profileMenu").hidden = true;
  });

  $("#modalCancel").addEventListener("click", () => closeModal(false));
  $("#modalOk").addEventListener("click", () => closeModal(true));
  $("#modal").addEventListener("click", (e) => {
    if (e.target === $("#modal")) closeModal(false);
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      if (!$("#modal").hidden) closeModal(false);
      $("#profileMenu").hidden = true;
    }
    if (e.key === "/" && !e.target.closest("input")) {
      e.preventDefault();
      $("#searchInput").focus();
    }
    if (e.key === "Escape" && e.target === $("#searchInput") && $("#searchInput").value) {
      $("#searchInput").value = "";
      $("#searchClear").hidden = true;
      $("#searchScope").hidden = true;
      S.search = "";
      renderList();
      renderDetail();
      renderFooter();
    }
  });

  $("#minBtn").addEventListener("click", () => send("minimize"));
  $("#maxBtn").addEventListener("click", () => send("maximize"));
  $("#closeBtn").addEventListener("click", () => send("close"));

  $("#titlebar").addEventListener("mousedown", (e) => {
    if (e.button !== 0) return;
    if (e.target.closest("button")) return;
    send("drag");
  });

  $("#titlebar").addEventListener("dblclick", (e) => {
    if (e.target.closest("button")) return;
    send("maximize");
  });

  window.addEventListener("resize", positionSegThumb);
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(() => requestAnimationFrame(positionSegThumb));
  }

  document.addEventListener("DOMContentLoaded", () => {});
}

bind();
send("ready");
