/*
 * Lucero Sync browser extension: popup UI.
 * States: loading → notfound | connect | connected.
 */
"use strict";

const api = globalThis.browser ?? globalThis.chrome;
const LS = globalThis.LuceroSync;

const LIVE_INTERVAL_MS = 1500;
const DEVICES_INTERVAL_MS = 5000;
const ALL_URLS = { origins: ["<all_urls>"] };

const params = new URLSearchParams(location.search);
const inTab = params.get("view") === "tab";

const $ = (id) => document.getElementById(id);
const els = {
  appName: $("app-name"),
  views: {
    loading: $("view-loading"),
    notfound: $("view-notfound"),
    connect: $("view-connect"),
    connected: $("view-connected"),
  },
  retry: $("retry"),
  connectForm: $("connect-form"),
  code: $("code"),
  connectBtn: $("connect-btn"),
  connectError: $("connect-error"),
  tabTitle: $("tab-title"),
  devices: $("devices"),
  noDevices: $("no-devices"),
  target: $("target"),
  text: $("text"),
  sendText: $("send-text"),
  chooseFiles: $("choose-files"),
  files: $("files"),
  imageHint: $("image-hint"),
  allowImages: $("allow-images"),
  live: $("live"),
  liveList: $("live-list"),
  toast: $("toast"),
  foot: $("foot"),
  footStatus: $("foot-status"),
  disconnect: $("disconnect"),
};

let state = "loading";
let devices = [];
let currentTab = null;
let liveTimer = null;
let devicesTimer = null;
let toastTimer = null;
const uploads = new Map(); // local uploads awaiting the app's response

if (inTab) {
  document.body.classList.add("tab-view");
  $("devices-h").textContent = "Your devices";
}

// ------------------------------------------------------------------ views

function show(next) {
  state = next;
  for (const [name, el] of Object.entries(els.views)) el.hidden = name !== next;
  els.foot.hidden = next !== "connected";
  if (next === "connected") startPolling();
  else stopPolling();
  if (next === "connect") {
    els.code.value = "";
    setTimeout(() => els.code.focus(), 30);
  }
}

function toast(message, kind) {
  els.toast.textContent = message;
  els.toast.className = "toast" + (kind ? " " + kind : "");
  els.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (els.toast.hidden = true), kind === "bad" ? 6000 : 3500);
}

/** Route common errors to the right state. Returns true if handled. */
function handleFatal(err) {
  if (err && err.code === "unauthorized") {
    show("connect");
    return true;
  }
  if (err && err.code === "app_not_found") {
    show("notfound");
    return true;
  }
  return false;
}

// ------------------------------------------------------------------- boot

async function boot() {
  show("loading");
  let hello;
  try {
    hello = (await LS.discover()).hello;
  } catch (_) {
    show("notfound");
    return;
  }
  if (hello.name) {
    els.appName.textContent = hello.name;
    els.appName.hidden = false;
  }
  const { token } = await LS.getState();
  if (!token) {
    show("connect");
    return;
  }
  try {
    await loadDevices();
  } catch (e) {
    if (!handleFatal(e)) show("notfound");
    return;
  }
  show("connected");
  els.footStatus.textContent = hello.name ? `Connected to ${hello.name}` : "Connected";
  void updateImageHint();
}

async function loadTab() {
  if (inTab) return;
  try {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    currentTab = tab || null;
  } catch (_) {
    currentTab = null;
  }
  const label = currentTab ? currentTab.title || currentTab.url || "" : "";
  els.tabTitle.textContent = label;
  els.tabTitle.title = label;
}

// ---------------------------------------------------------------- connect

els.retry.addEventListener("click", () => void boot());

els.code.addEventListener("input", () => {
  const digits = els.code.value.replace(/\D/g, "").slice(0, 6);
  if (digits !== els.code.value) els.code.value = digits;
  els.connectError.hidden = true;
  if (digits.length === 6) els.connectForm.requestSubmit();
});

els.connectForm.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const code = els.code.value.trim();
  if (!/^\d{6}$/.test(code)) {
    showConnectError("Enter all 6 digits.");
    return;
  }
  els.connectBtn.disabled = true;
  els.connectBtn.textContent = "Connecting…";
  try {
    await LS.connect(code);
    await boot();
  } catch (e) {
    if (e.code === "app_not_found") show("notfound");
    else showConnectError(LS.describeError(e));
  } finally {
    els.connectBtn.disabled = false;
    els.connectBtn.textContent = "Connect";
  }
});

function showConnectError(msg) {
  els.connectError.textContent = msg;
  els.connectError.hidden = false;
  els.code.select();
}

els.disconnect.addEventListener("click", async () => {
  els.disconnect.disabled = true;
  await LS.disconnect();
  els.disconnect.disabled = false;
  show("connect");
});

// ---------------------------------------------------------------- devices

const ICONS = {
  phone:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="6" y="2" width="12" height="20" rx="3"/><path d="M11 18h2"/></svg>',
  tablet:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="2" width="16" height="20" rx="3"/><path d="M11 18h2"/></svg>',
  laptop:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="4" width="16" height="11" rx="2"/><path d="M2 19h20"/></svg>',
  desktop:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="13" rx="2"/><path d="M8 21h8M12 16v5"/></svg>',
};

function platformInfo(platform) {
  const p = String(platform || "").toLowerCase();
  if (p === "android") return { icon: "phone", label: "Android" };
  if (p === "ios" || p === "iphone") return { icon: "phone", label: "iPhone" };
  if (p === "ipados" || p === "ipad" || p === "tablet") return { icon: "tablet", label: "iPad" };
  if (p === "macos" || p === "mac" || p === "darwin") return { icon: "laptop", label: "Mac" };
  if (p === "windows") return { icon: "desktop", label: "Windows" };
  if (p === "linux") return { icon: "desktop", label: "Linux" };
  return { icon: "desktop", label: "" };
}

async function loadDevices() {
  devices = await LS.listDevices();
  renderDevices();
}

function renderDevices() {
  const selected = els.target.value;
  els.devices.textContent = "";
  els.target.textContent = "";
  els.noDevices.hidden = devices.length > 0;

  for (const d of devices) {
    const info = platformInfo(d.platform);
    const li = document.createElement("li");
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "device";
    btn.dataset.id = d.id;
    const stateText = d.online ? "Online" : "Offline";
    btn.setAttribute(
      "aria-label",
      inTab ? `Select ${d.name} (${stateText})` : `Send this tab to ${d.name} (${stateText})`
    );

    const icon = document.createElement("span");
    icon.className = "icon";
    icon.innerHTML = ICONS[info.icon]; // static, trusted markup
    const meta = document.createElement("span");
    meta.className = "meta";
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = d.name;
    const st = document.createElement("span");
    st.className = "state";
    const dot = document.createElement("span");
    dot.className = "dot" + (d.online ? " on" : "");
    st.append(dot, document.createTextNode(info.label ? `${stateText} · ${info.label}` : stateText));
    meta.append(name, st);
    const action = document.createElement("span");
    action.className = "action";
    action.textContent = inTab ? "" : "Send tab";
    btn.append(icon, meta, action);
    btn.addEventListener("click", () => onDeviceClick(d, btn, action));
    li.append(btn);
    els.devices.append(li);

    const opt = document.createElement("option");
    opt.value = d.id;
    opt.textContent = d.online ? d.name : `${d.name} (offline)`;
    els.target.append(opt);
  }

  if (devices.some((d) => d.id === selected)) els.target.value = selected;
  else {
    const firstOnline = devices.find((d) => d.online);
    if (firstOnline) els.target.value = firstOnline.id;
  }
  const disabled = devices.length === 0;
  els.target.disabled = disabled;
  els.sendText.disabled = disabled;
  els.chooseFiles.disabled = disabled;
  markSelected();
}

function markSelected() {
  for (const b of els.devices.querySelectorAll(".device")) {
    b.classList.toggle("selected", inTab && b.dataset.id === els.target.value);
  }
}
els.target.addEventListener("change", markSelected);

async function onDeviceClick(device, btn, action) {
  if (inTab) {
    els.target.value = device.id;
    markSelected();
    return;
  }
  if (!currentTab || !currentTab.url) {
    toast("Couldn't read this tab's address.", "bad");
    return;
  }
  const url = currentTab.url;
  const title = currentTab.title || "";
  const text = title && title !== url ? `${title}\n${url}` : url;
  btn.disabled = true;
  action.textContent = "Sending…";
  action.className = "action";
  try {
    await LS.sendText(device.id, text);
    action.textContent = "Sent ✓";
    action.classList.add("ok");
    toast(`Sent to ${device.name}`, "ok");
  } catch (e) {
    action.textContent = "Failed";
    action.classList.add("bad");
    if (!handleFatal(e)) toast(LS.describeError(e, device.name), "bad");
    if (e.code === "no_device") void loadDevices().catch(() => {});
  } finally {
    btn.disabled = false;
    setTimeout(() => {
      action.textContent = "Send tab";
      action.className = "action";
    }, 2500);
  }
}

function targetDevice() {
  return devices.find((d) => d.id === els.target.value) || null;
}

// ------------------------------------------------------------------- text

els.sendText.addEventListener("click", sendTextNow);
els.text.addEventListener("keydown", (ev) => {
  if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
    ev.preventDefault();
    void sendTextNow();
  }
});

async function sendTextNow() {
  const device = targetDevice();
  const text = els.text.value;
  if (!device) return;
  if (!text.trim()) {
    toast("Type something to send first.", "bad");
    els.text.focus();
    return;
  }
  els.sendText.disabled = true;
  els.sendText.textContent = "Sending…";
  try {
    await LS.sendText(device.id, text);
    els.text.value = "";
    toast(`Sent to ${device.name}`, "ok");
  } catch (e) {
    if (!handleFatal(e)) toast(LS.describeError(e, device.name), "bad");
  } finally {
    els.sendText.disabled = devices.length === 0;
    els.sendText.textContent = "Send";
  }
}

// ------------------------------------------------------------------ files

els.chooseFiles.addEventListener("click", () => {
  // Firefox closes the popup when the native file picker opens, so pick
  // files from a full tab instead.
  if (LS.isFirefox && !inTab) {
    void api.tabs.create({ url: api.runtime.getURL("popup.html?view=tab") });
    window.close();
    return;
  }
  els.files.click();
});

els.files.addEventListener("change", async () => {
  const device = targetDevice();
  const files = Array.from(els.files.files || []);
  els.files.value = "";
  if (!device || files.length === 0) return;
  let ok = 0;
  for (const file of files) {
    const key = Math.random().toString(36).slice(2);
    uploads.set(key, { title: file.name, peer: device.name });
    renderLive(lastLive);
    try {
      await LS.sendFile(device.id, LS.sanitizeFilename(file.name), file);
      ok++;
    } catch (e) {
      if (handleFatal(e)) return;
      toast(`${file.name}: ${LS.describeError(e, device.name)}`, "bad");
    } finally {
      uploads.delete(key);
      renderLive(lastLive);
    }
  }
  if (ok > 0) toast(ok === 1 ? `Sending to ${device.name}` : `Sending ${ok} files to ${device.name}`, "ok");
});

// ------------------------------------------------------------------- live

let lastLive = null;

function renderLive(data) {
  const items = (data && Array.isArray(data.items) ? data.items : []).slice();
  for (const u of uploads.values()) {
    items.unshift({
      id: "local",
      direction: "sending",
      peer: u.peer,
      title: u.title,
      status: "Handing to Lucero Sync…",
      fraction: null,
    });
  }
  els.live.hidden = items.length === 0;
  els.liveList.textContent = "";
  for (const it of items) {
    const li = document.createElement("li");
    li.className = "live-item";
    const top = document.createElement("div");
    top.className = "live-top";
    const title = document.createElement("span");
    title.className = "live-title";
    title.textContent = it.title || "Transfer";
    title.title = it.title || "";
    const peer = document.createElement("span");
    peer.className = "live-peer";
    const arrow = it.direction === "receiving" ? "from" : "to";
    peer.textContent = it.peer ? `${it.backup ? "Backup " : ""}${arrow} ${it.peer}` : "";
    top.append(title, peer);
    const status = document.createElement("div");
    status.className = "live-status";
    status.textContent = it.status || "";
    const bar = document.createElement("div");
    bar.className = "bar";
    bar.setAttribute("role", "progressbar");
    bar.setAttribute("aria-label", it.title || "Transfer");
    const fill = document.createElement("span");
    if (typeof it.fraction === "number" && isFinite(it.fraction)) {
      const pct = Math.max(0, Math.min(1, it.fraction)) * 100;
      fill.style.width = pct.toFixed(1) + "%";
      bar.setAttribute("aria-valuemin", "0");
      bar.setAttribute("aria-valuemax", "100");
      bar.setAttribute("aria-valuenow", String(Math.round(pct)));
    } else {
      bar.classList.add("indeterminate");
    }
    bar.append(fill);
    li.append(top, status, bar);
    els.liveList.append(li);
  }
}

async function pollLive() {
  try {
    lastLive = await LS.live();
    renderLive(lastLive);
  } catch (e) {
    if (handleFatal(e)) return;
  }
}

async function pollDevices() {
  try {
    const prev = JSON.stringify(devices);
    const next = await LS.listDevices();
    if (JSON.stringify(next) !== prev) {
      devices = next;
      renderDevices();
    }
  } catch (e) {
    handleFatal(e);
  }
}

function startPolling() {
  if (liveTimer) return;
  void pollLive();
  liveTimer = setInterval(pollLive, LIVE_INTERVAL_MS);
  devicesTimer = setInterval(pollDevices, DEVICES_INTERVAL_MS);
}

function stopPolling() {
  clearInterval(liveTimer);
  clearInterval(devicesTimer);
  liveTimer = devicesTimer = null;
}

// ------------------------------------------------------- image permission

async function updateImageHint() {
  let granted = false;
  try {
    granted = await api.permissions.contains(ALL_URLS);
  } catch (_) {}
  els.imageHint.hidden = granted;
}

els.allowImages.addEventListener("click", async () => {
  let granted = false;
  try {
    granted = await api.permissions.request(ALL_URLS);
  } catch (_) {}
  await api.storage.local.set({ imagePermissionDeclined: !granted });
  els.imageHint.hidden = granted;
  if (granted) toast("Images will be sent as files.", "ok");
});

// -------------------------------------------------------------------- go

window.addEventListener("unload", stopPolling);
void loadTab();
void boot();
