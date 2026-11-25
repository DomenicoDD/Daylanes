import assert from "node:assert/strict";
import test from "node:test";

import { addressOf, focusedTab, validAlias } from "../extension/context.mjs";

test("tab context rejects credentials and keeps only the HTTP(S) origin and path", () => {
  assert.equal(addressOf("https://example.org/a?recipient=private#draft"), "https://example.org/a");
  assert.equal(addressOf("https://example.org"), "https://example.org/");
  assert.equal(addressOf("https://example.org/mail/person%40example.org/inbox"), "https://example.org/mail/");
  for (const url of ["chrome://settings/", "file:///home/example", "https://user:secret@example.org/", "invalid"]) {
    assert.equal(addressOf(url), null);
  }
  assert.ok(validAlias("Client Work"));
  assert.equal(validAlias("client@example.org"), false);
  assert.equal(validAlias("A".repeat(41)), false);
});

function fakeChrome(overrides = {}) {
  const window = { id: 1, type: "normal", focused: true, incognito: false };
  const tab = { id: 2, windowId: 1, active: true, incognito: false, url: "https://github.com/test/project/pull/1?token=secret" };
  return {
    windows: {
      getAll: async () => overrides.windows ?? [window],
      get: async () => ({ ...window, ...overrides.confirmWindow }),
    },
    tabs: {
      query: async filter => {
        assert.deepEqual(filter, { active: true, windowId: 1 });
        return [{ ...tab, ...overrides.tab }];
      },
      get: async () => ({ ...tab, ...overrides.confirmTab }),
    },
  };
}

test("reads only a verified foreground tab, ignoring window/tab changes and pending navigations", async () => {
  assert.equal(await focusedTab(fakeChrome()), "https://github.com/test/project/pull/1");
  for (const overrides of [
    { windows: [{ id: 1, focused: false }] },
    { windows: [{ id: 1, focused: true, incognito: true }] },
    { confirmWindow: { focused: false } },
    { tab: { pendingUrl: "https://example.org" } },
    { tab: { incognito: true } },
    { confirmTab: { active: false } },
    { confirmTab: { windowId: 5 } },
    { confirmTab: { url: "https://example.org/" } },
  ]) {
    assert.equal(await focusedTab(fakeChrome(overrides)), null);
  }
});

function event() {
  const handlers = [];
  return {
    addListener: handler => handlers.push(handler),
    emit: (...values) => handlers.forEach(handler => handler(...values)),
  };
}

test("worker shares the foreground tab only while sharing is on and for a native snapshot request", async () => {
  const changes = event();
  let enabled = false;
  let connections = 0;
  const sent = [];
  const native = {
    onMessage: event(),
    onDisconnect: event(),
    postMessage: response => sent.push(response),
    disconnect() {},
  };
  const api = fakeChrome();
  Object.assign(api.windows, { onFocusChanged: event() });
  Object.assign(api.tabs, { onUpdated: event(), onActivated: event() });
  globalThis.chrome = {
    ...api,
    storage: { local: { get: async () => ({ enabled, alias: "Work" }) }, onChanged: changes },
    alarms: { create() {}, onAlarm: event() },
    runtime: {
      connectNative: () => { connections += 1; return native; },
      id: "lkckmlojgpfflmkhkaapcijpjehdmobo", lastError: undefined,
      onInstalled: event(), onStartup: event(), onMessage: event(),
    },
  };

  const tick = () => new Promise(resolve => setImmediate(resolve));
  try {
    await import("../extension/background.js");
    await tick();
    assert.equal(connections, 0);
    enabled = undefined;
    changes.emit();
    await tick();
    assert.equal(connections, 1);
    assert.deepEqual(sent, []);
    const request = { version: 1, type: "snapshot", id: "01234567-ABCD-1234-ABCD-0123456789AB" };
    native.onMessage.emit({ ...request, type: "other" });
    native.onMessage.emit(request);
    await tick();
    assert.deepEqual(sent, [{
      version: 1, id: request.id, status: "tab",
      url: "https://github.com/test/project/pull/1", profile: "Work",
    }]);

    // A missing helper is reported to the popup and retried by the alarm.
    globalThis.chrome.runtime.lastError = { message: "Specified native messaging host not found." };
    native.onDisconnect.emit();
    globalThis.chrome.runtime.lastError = undefined;
    const popup = { url: "chrome-extension://lkckmlojgpfflmkhkaapcijpjehdmobo/settings.html" };
    globalThis.chrome.runtime.getURL = path => `chrome-extension://lkckmlojgpfflmkhkaapcijpjehdmobo/${path}`;
    const state = await new Promise(resolve => {
      globalThis.chrome.runtime.onMessage.emit({ type: "status" }, popup, resolve);
    });
    assert.equal(state.connected, false);
    assert.match(state.error, /not found/);
    globalThis.chrome.alarms.onAlarm.emit({ name: "reconnect" });
    await tick();
    assert.equal(connections, 2);
  } finally {
    delete globalThis.chrome;
  }
});
