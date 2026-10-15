/*
 * Lucero Sync browser extension: background (Chrome service worker /
 * Firefox event page).
 *
 * Owns the right-click menus: "Send to Lucero Sync device" for pages, links,
 * selections and images, with one entry per paired device. Menus are rebuilt
 * whenever the cached device list or the connection token changes.
 */
"use strict";

if (typeof importScripts === "function" && !globalThis.LuceroSync) {
  importScripts("lib.js"); // Chrome service worker; Firefox loads lib.js via the manifest
}

const api = globalThis.browser ?? globalThis.chrome;
const LS = globalThis.LuceroSync;

const CONTEXTS = ["page", "link", "selection", "image"];
const PARENT_TITLE = "Send to Lucero Sync device";
const ALL_URLS = { origins: ["<all_urls>"] };
const MAX_IMAGE_BYTES = 200 * 1024 * 1024;

// ------------------------------------------------------------------ menus

function createMenu(props) {
  return new Promise((resolve) => {
    api.contextMenus.create(props, () => {
      void api.runtime.lastError; // ignore "duplicate id" during races
      resolve();
    });
  });
}

let menuChain = Promise.resolve();

/** Serialised rebuild so concurrent triggers never interleave. */
function rebuildMenus() {
  menuChain = menuChain.then(buildMenus).catch((e) => console.warn("Lucero Sync: menu build failed", e));
  return menuChain;
}

async function buildMenus() {
  await api.contextMenus.removeAll();
  const { token, devices } = await api.storage.local.get(["token", "devices"]);

  if (!token) {
    await createMenu({ id: "connect", title: "Connect Lucero Sync…", contexts: CONTEXTS });
  } else {
    const list = Array.isArray(devices) ? devices : [];
    for (const ctx of CONTEXTS) {
      const parentId = `p:${ctx}`;
      await createMenu({ id: parentId, title: PARENT_TITLE, contexts: [ctx] });
      if (list.length === 0) {
        await createMenu({
          id: `none:${ctx}`,
          parentId,
          title: "No paired devices yet",
          enabled: false,
          contexts: [ctx],
        });
        continue;
      }
      for (const d of list) {
        await createMenu({
          id: `s:${ctx}:${d.id}`,
          parentId,
          title: d.online ? d.name : `${d.name} (offline)`,
          contexts: [ctx],
        });
      }
    }
  }
  // Firefox can update a menu that is already open.
  if (api.menus && typeof api.menus.refresh === "function") {
    try {
      await api.menus.refresh();
    } catch (_) {}
  }
}

/** Fetch devices from the app; the storage listener rebuilds the menus. */
async function refreshDevices() {
  try {
    await LS.listDevices();
  } catch (e) {
    // Not connected / app closed: keep whatever is cached.
  }
}

async function init() {
  await rebuildMenus();
  const { token } = await LS.getState();
  if (token) await refreshDevices();
}

api.runtime.onInstalled.addListener(() => void init());
api.runtime.onStartup.addListener(() => void init());

api.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  if ("token" in changes || "devices" in changes) void rebuildMenus();
});

// Firefox only: refresh devices each time a context menu opens.
if (api.menus && api.menus.onShown) {
  api.menus.onShown.addListener(() => {
    void refreshDevices();
  });
}

// ------------------------------------------------------------- notifications

function notify(title, message) {
  try {
    const p = api.notifications.create({
      type: "basic",
      iconUrl: api.runtime.getURL("icons/icon-128.png"),
      title,
      message: message || "",
    });
    if (p && typeof p.catch === "function") p.catch(() => {});
  } catch (_) {}
}

function truncate(s, n) {
  s = String(s || "").replace(/\s+/g, " ").trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

// ------------------------------------------------------------- click logic

// Remember a refused image permission so we don't prompt on every click.
// The popup offers an "Allow" button that clears this flag.
let imagePermissionDeclined = false;
api.storage.local.get("imagePermissionDeclined").then((v) => {
  imagePermissionDeclined = !!(v && v.imagePermissionDeclined);
});
api.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && "imagePermissionDeclined" in changes) {
    imagePermissionDeclined = !!changes.imagePermissionDeclined.newValue;
  }
});

async function openConnect() {
  try {
    if (api.action && typeof api.action.openPopup === "function") {
      await api.action.openPopup();
      return;
    }
  } catch (_) {
    /* fall through */
  }
  await api.tabs.create({ url: api.runtime.getURL("popup.html?view=tab") });
}

/**
 * Must be called synchronously inside the click handler so the browser
 * treats it as user-initiated. Resolves to true if we may fetch any image.
 */
function requestImagePermission() {
  try {
    const p = api.permissions.request(ALL_URLS);
    return Promise.resolve(p).then(
      (granted) => {
        if (!granted) void api.storage.local.set({ imagePermissionDeclined: true });
        return !!granted;
      },
      () => false
    );
  } catch (_) {
    return Promise.resolve(false);
  }
}

async function fetchImage(srcUrl) {
  const res = await fetch(srcUrl, { credentials: "include" });
  if (!res.ok) throw new Error("http " + res.status);
  const len = Number(res.headers.get("content-length") || 0);
  if (len > MAX_IMAGE_BYTES) throw new Error("too large");
  const blob = await res.blob();
  if (blob.size === 0 || blob.size > MAX_IMAGE_BYTES) throw new Error("bad size");
  const type = blob.type || res.headers.get("content-type") || "";
  return { blob, name: LS.imageFilename(srcUrl, type) };
}

async function deviceName(deviceId) {
  const { devices } = await api.storage.local.get("devices");
  const d = (devices || []).find((x) => x.id === deviceId);
  return d ? d.name : "your device";
}

async function handleSend(ctx, deviceId, info, tab, permissionPromise) {
  const name = await deviceName(deviceId);
  try {
    if (ctx === "image") {
      await sendImage(deviceId, name, info.srcUrl || "", permissionPromise);
      return;
    }

    let text = "";
    let summary = "";
    if (ctx === "page") {
      const url = info.pageUrl || (tab && tab.url) || "";
      const title = (tab && tab.title) || "";
      text = title && title !== url ? `${title}\n${url}` : url;
      summary = title || url;
    } else if (ctx === "link") {
      text = info.linkUrl || "";
      summary = text;
    } else if (ctx === "selection") {
      text = info.selectionText || "";
      summary = text;
    }
    if (!text) throw new LS.ApiError("empty");

    await LS.sendText(deviceId, text);
    notify(`Sent to ${name}`, truncate(summary, 120));
  } catch (e) {
    await reportError(e, name);
  }
}

async function sendImage(deviceId, name, srcUrl, permissionPromise) {
  const isHttp = /^https?:/i.test(srcUrl);
  const isData = /^data:/i.test(srcUrl);

  let file = null;
  if (isData || (isHttp && (await permissionPromise))) {
    try {
      file = await fetchImage(srcUrl);
    } catch (_) {
      file = null;
    }
  }

  if (file) {
    await LS.sendFile(deviceId, file.name, file.blob);
    notify(`Sending to ${name}`, file.name);
    return;
  }
  if (isHttp) {
    // Couldn't (or may not) download it: send the address instead.
    await LS.sendText(deviceId, srcUrl);
    notify(`Sent to ${name}`, "Image link: " + truncate(srcUrl, 100));
    return;
  }
  throw new LS.ApiError("image_unavailable");
}

async function reportError(e, name) {
  const code = e && e.code;
  if (code === "empty") {
    notify("Nothing to send", "There was nothing to send from that spot.");
    return;
  }
  if (code === "image_unavailable") {
    notify("Couldn't send image", "This image can't be downloaded. Try saving it and sending the file from the popup.");
    return;
  }
  if (code === "no_device") void refreshDevices();
  if (code === "app_not_found") {
    notify("Couldn't reach Lucero Sync", "Is the desktop app open?");
    return;
  }
  notify(`Couldn't send to ${name}`, LS.describeError(e, name));
}

api.contextMenus.onClicked.addListener((info, tab) => {
  const id = String(info.menuItemId);
  if (id === "connect") {
    void openConnect();
    return;
  }
  if (!id.startsWith("s:")) return;
  const rest = id.slice(2);
  const sep = rest.indexOf(":");
  const ctx = rest.slice(0, sep);
  const deviceId = rest.slice(sep + 1);

  // Ask for image access synchronously, while the click still counts as a
  // user gesture. Already-granted permissions resolve without a prompt.
  let permissionPromise = Promise.resolve(false);
  if (ctx === "image" && /^https?:/i.test(info.srcUrl || "")) {
    permissionPromise = imagePermissionDeclined
      ? Promise.resolve(api.permissions.contains(ALL_URLS)).catch(() => false)
      : requestImagePermission();
  }
  void handleSend(ctx, deviceId, info, tab, permissionPromise);
});
