import { focusedTab, validAlias } from "./context.mjs";

const hostName = "com.domenicodidonna.tracker.chrome";
// Tracker asks for a sample every few seconds while Chrome is in front.
const recentRequest = 2 * 60 * 1000;
let port;
let configuration = Promise.resolve();
let revision = 0;
// What the popup shows: whether the helper is reachable and when Tracker last asked for a tab.
const health = { connected: false, error: null, lastRequest: null };

function configure() {
  configuration = configuration.then(configurePort);
  return configuration;
}

// Sharing is on unless this profile turned it off in the popup.
async function sharing() {
  const { enabled } = await chrome.storage.local.get("enabled");
  return enabled !== false;
}

async function configurePort() {
  try {
    if (!(await sharing())) {
      const previous = port;
      port = undefined;
      health.connected = false;
      health.error = null;
      previous?.disconnect();
      return;
    }
    if (port) return;

    const connection = chrome.runtime.connectNative(hostName);
    port = connection;
    health.connected = true;
    health.error = null;
    connection.onMessage.addListener(request => {
      void respond(connection, request);
    });
    connection.onDisconnect.addListener(() => {
      // Reading lastError also keeps Chrome from logging an unchecked failure.
      const failure = chrome.runtime.lastError;
      if (port !== connection) return;
      port = undefined;
      health.connected = false;
      health.error = failure?.message ?? "The Daylanes helper stopped.";
      // The retry alarm and the next focus change reconnect.
    });
  } catch (error) {
    health.connected = false;
    health.error = String(error?.message ?? error);
  }
}

async function respond(connection, request) {
  if (request?.version !== 1 || request.type !== "snapshot" ||
      typeof request.id !== "string" || !/^[a-f0-9-]{36}$/i.test(request.id)) return;
  health.lastRequest = Date.now();
  const response = { version: 1, id: request.id, status: "no_tab" };
  const samplingRevision = revision;
  try {
    const { alias } = await chrome.storage.local.get("alias");
    if (await sharing()) {
      const url = await focusedTab(chrome);
      if (url && samplingRevision === revision) {
        response.status = "tab";
        response.url = url;
        if (alias && validAlias(alias)) response.profile = alias;
      }
    }
  } catch {
    // A closed or newly unfocused window can invalidate a read in flight.
  }
  if (port === connection) {
    try { connection.postMessage(response); } catch { /* The host disconnected. */ }
  }
}

async function status() {
  await configuration;
  const recent = health.lastRequest !== null && Date.now() - health.lastRequest < recentRequest;
  return {
    enabled: await sharing(),
    connected: health.connected,
    error: health.error,
    lastRequest: health.lastRequest,
    tracking: health.connected && recent,
    id: chrome.runtime.id,
  };
}

chrome.windows.onFocusChanged.addListener(() => {
  revision += 1;
  if (!port) void configure();
});
chrome.tabs.onActivated.addListener(() => { revision += 1; });
chrome.tabs.onUpdated.addListener((_id, change, tab) => {
  if (tab.active && (Object.hasOwn(change, "url") || change.status)) revision += 1;
});
chrome.storage.onChanged.addListener(() => { revision += 1; void configure(); });
chrome.runtime.onInstalled.addListener(() => { void configure(); });
chrome.runtime.onStartup.addListener(() => { void configure(); });
// Retry when the helper was missing, for example before Tracker installed it.
chrome.alarms?.create("reconnect", { periodInMinutes: 1 });
chrome.alarms?.onAlarm.addListener(() => { if (!port) void configure(); });
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.url !== chrome.runtime.getURL("settings.html")) return;
  if (message?.type === "connect") {
    if (!port) health.error = null;
    configure().then(status).then(reply);
    return true;
  }
  if (message?.type === "status") {
    status().then(reply);
    return true;
  }
});
void configure();
