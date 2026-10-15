/*
 * Lucero Sync browser extension: shared helpers for the loopback API.
 *
 * Loaded as a classic script by the popup (<script src>), by the Chrome
 * service worker (importScripts) and by the Firefox background page
 * (manifest background.scripts). Exposes globalThis.LuceroSync.
 *
 * The extension only ever talks to the Lucero Sync desktop app on
 * http://127.0.0.1:<port>. It never contacts any other host, except to
 * download an image the user explicitly chose to send from a context menu.
 */
(function () {
  "use strict";

  const api = globalThis.browser ?? globalThis.chrome;

  const PORTS = [47865, 47866, 47867, 47868, 47869];
  const HELLO_TIMEOUT_MS = 900;
  const REQUEST_TIMEOUT_MS = 15000;

  const isFirefox =
    typeof api.runtime.getURL === "function" &&
    api.runtime.getURL("").startsWith("moz-extension:");
  const CLIENT = isFirefox ? "Firefox" : "Chrome";

  class ApiError extends Error {
    constructor(code, status, message) {
      super(message || code);
      this.name = "ApiError";
      this.code = code; // e.g. "app_not_found", "unauthorized", "offline"
      this.status = status || 0;
    }
  }

  // ---------------------------------------------------------------- storage

  async function getState() {
    const s = await api.storage.local.get(["port", "token", "appName"]);
    return { port: s.port || null, token: s.token || null, appName: s.appName || null };
  }

  async function setState(patch) {
    await api.storage.local.set(patch);
  }

  async function clearToken() {
    await api.storage.local.remove(["token", "devices"]);
  }

  // -------------------------------------------------------------- transport

  async function fetchWithTimeout(url, init, timeoutMs) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      return await fetch(url, { ...init, signal: ctrl.signal, credentials: "omit", cache: "no-store" });
    } finally {
      clearTimeout(timer);
    }
  }

  async function tryHello(port) {
    try {
      const res = await fetchWithTimeout(`http://127.0.0.1:${port}/ext/v1/hello`, {}, HELLO_TIMEOUT_MS);
      if (!res.ok) return null;
      const body = await res.json();
      return body && body.app === "lucero-sync" ? body : null;
    } catch (_) {
      return null;
    }
  }

  /**
   * Find the desktop app. Tries the cached port first, then 47865..47869.
   * Returns { port, hello } or throws ApiError("app_not_found").
   */
  async function discover({ force = false } = {}) {
    const { port: cached } = await getState();
    if (cached && !force) {
      const hello = await tryHello(cached);
      if (hello) {
        await setState({ appName: hello.name || null });
        return { port: cached, hello };
      }
    }
    const candidates = PORTS.filter((p) => p !== cached || force);
    const results = await Promise.all(candidates.map((p) => tryHello(p).then((h) => [p, h])));
    const hit = results.find(([, h]) => h);
    if (!hit) throw new ApiError("app_not_found");
    const [port, hello] = hit;
    if (cached && cached !== port) {
      // A different app instance answered; any old token is meaningless now.
      await clearToken();
    }
    await setState({ port, appName: hello.name || null });
    return { port, hello };
  }

  async function errorFromResponse(res) {
    let code = "http_" + res.status;
    try {
      const body = await res.json();
      if (body && typeof body.error === "string") code = body.error;
    } catch (_) {
      /* not JSON */
    }
    if (res.status === 401 && code !== "bad_code") code = "unauthorized";
    return new ApiError(code, res.status);
  }

  /**
   * Authenticated request. On a network failure the port is rediscovered
   * once. On 401 the token is cleared and ApiError("unauthorized") thrown.
   */
  async function request(path, { method = "GET", json, body, headers = {}, auth = true, timeout } = {}) {
    let { port, token } = await getState();
    if (auth && !token) throw new ApiError("unauthorized", 401);
    if (!port) port = (await discover()).port;

    const init = { method, headers: { ...headers } };
    if (auth) init.headers.Authorization = `Bearer ${token}`;
    if (json !== undefined) {
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(json);
    } else if (body !== undefined) {
      init.body = body;
    }

    const send = (p) => fetchWithTimeout(`http://127.0.0.1:${p}${path}`, init, timeout || REQUEST_TIMEOUT_MS);

    let res;
    try {
      res = await send(port);
    } catch (_) {
      // App may have restarted on another port.
      const found = await discover({ force: true });
      if (auth) {
        const st = await getState();
        if (!st.token) throw new ApiError("unauthorized", 401);
      }
      try {
        res = await send(found.port);
      } catch (_) {
        throw new ApiError("app_not_found");
      }
    }

    if (!res.ok) {
      const err = await errorFromResponse(res);
      if (err.code === "unauthorized") await clearToken();
      throw err;
    }
    const text = await res.text();
    if (!text) return {};
    try {
      return JSON.parse(text);
    } catch (_) {
      return {};
    }
  }

  // --------------------------------------------------------------- endpoints

  async function connect(code) {
    const { port } = await discover();
    let res;
    try {
      res = await fetchWithTimeout(
        `http://127.0.0.1:${port}/ext/v1/connect`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ code: String(code), client: CLIENT }),
        },
        REQUEST_TIMEOUT_MS
      );
    } catch (_) {
      throw new ApiError("app_not_found");
    }
    if (!res.ok) {
      let codeStr = "http_" + res.status;
      try {
        const b = await res.json();
        if (b && b.error) codeStr = b.error;
      } catch (_) {}
      throw new ApiError(codeStr, res.status);
    }
    const body = await res.json();
    if (!body || typeof body.token !== "string" || !body.token) throw new ApiError("bad_response");
    await setState({ token: body.token });
    return body.token;
  }

  async function listDevices() {
    const body = await request("/ext/v1/devices");
    const devices = Array.isArray(body.devices) ? body.devices : [];
    await cacheDevices(devices);
    return devices;
  }

  /** Store devices only when they changed, so listeners don't churn. */
  async function cacheDevices(devices) {
    const norm = devices.map((d) => ({
      id: String(d.id),
      name: String(d.name || "Device"),
      platform: String(d.platform || ""),
      online: !!d.online,
    }));
    const { devices: prev } = await api.storage.local.get("devices");
    if (JSON.stringify(prev || null) !== JSON.stringify(norm)) {
      await api.storage.local.set({ devices: norm });
    }
    return norm;
  }

  function sendText(deviceId, text) {
    return request("/ext/v1/send", { method: "POST", json: { deviceId, text } });
  }

  function sendFile(deviceId, name, blob) {
    const q = `deviceId=${encodeURIComponent(deviceId)}&name=${encodeURIComponent(name)}`;
    return request(`/ext/v1/file?${q}`, {
      method: "PUT",
      body: blob,
      headers: { "Content-Type": (blob && blob.type) || "application/octet-stream" },
      timeout: 10 * 60 * 1000, // large local uploads to loopback
    });
  }

  function live() {
    return request("/ext/v1/live", { timeout: 5000 });
  }

  async function disconnect() {
    try {
      await request("/ext/v1/disconnect", { method: "POST", json: {} });
    } catch (_) {
      /* forget the token locally regardless */
    }
    await clearToken();
  }

  // ----------------------------------------------------------------- helpers

  /** Human-readable message for an error, optionally naming the device. */
  function describeError(err, deviceName) {
    const who = deviceName || "the device";
    const code = err && err.code;
    switch (code) {
      case "app_not_found":
        return "Couldn't reach Lucero Sync. Is the desktop app open?";
      case "unauthorized":
        return "This browser is no longer connected. Open the Lucero Sync popup to reconnect.";
      case "bad_code":
        return "That code didn't match. Check Lucero Sync › Settings › Browser extension.";
      case "rate_limited":
        return "Too many attempts. Wait a minute, then try again.";
      case "no_device":
        return `${who} isn't paired with Lucero Sync anymore.`;
      case "offline":
        return `${who} isn't reachable right now. Is it on the same Wi-Fi?`;
      case "declined":
        return `${who} declined the transfer.`;
      default:
        return "Something went wrong sending that. Try again.";
    }
  }

  /** Make a safe, reasonable filename. */
  function sanitizeFilename(name) {
    const cleaned = String(name || "")
      .replace(/[\u0000-\u001f\u007f<>:"/\\|?*]+/g, "_")
      .replace(/^\.+/, "")
      .trim()
      .slice(0, 180);
    return cleaned || "file";
  }

  const MIME_EXT = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/gif": "gif",
    "image/webp": "webp",
    "image/avif": "avif",
    "image/svg+xml": "svg",
    "image/bmp": "bmp",
    "image/x-icon": "ico",
    "image/vnd.microsoft.icon": "ico",
    "image/tiff": "tiff",
    "image/heic": "heic",
    "image/heif": "heif",
  };

  /** Derive a filename for an image from its URL and/or content type. */
  function imageFilename(url, contentType) {
    const type = String(contentType || "").split(";")[0].trim().toLowerCase();
    const ext = MIME_EXT[type] || (type.startsWith("image/") ? type.slice(6).replace(/[^a-z0-9]/g, "") : "");
    let base = "";
    try {
      const u = new URL(url);
      if (u.protocol === "http:" || u.protocol === "https:") {
        const last = u.pathname.split("/").filter(Boolean).pop() || "";
        base = decodeURIComponent(last);
      }
    } catch (_) {}
    base = base.replace(/[?#].*$/, "");
    const hasExt = /\.[a-z0-9]{2,5}$/i.test(base);
    if (!base) base = "image-" + new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
    if (!hasExt && ext) base += "." + ext;
    else if (!hasExt) base += ".img";
    return sanitizeFilename(base);
  }

  globalThis.LuceroSync = {
    api,
    CLIENT,
    isFirefox,
    ApiError,
    getState,
    discover,
    connect,
    listDevices,
    cacheDevices,
    sendText,
    sendFile,
    live,
    disconnect,
    clearToken,
    describeError,
    sanitizeFilename,
    imageFilename,
  };
})();
