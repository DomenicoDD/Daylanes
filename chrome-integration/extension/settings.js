import { validAlias } from "./context.mjs";

const form = document.querySelector("#settings");
const alias = document.querySelector("#alias");
const error = document.querySelector("#error");
const statusLine = document.querySelector("#status");
const hint = document.querySelector("#hint");
const toggle = document.querySelector("#toggle");
const identifier = document.querySelector("#id");
let enabled = true;

// Chrome's messages when the helper is not registered for this extension.
const notInstalled = /not found|forbidden/i;

function show(state) {
  enabled = state.enabled;
  toggle.textContent = enabled ? "Pause sharing" : "Resume sharing";
  identifier.textContent = `Extension ID ${state.id}.`;
  let label, tone, help = "";
  if (!enabled) {
    [label, tone] = ["Sharing is paused in this profile", "paused"];
  } else if (state.tracking) {
    [label, tone] = ["Connected. Daylanes is reading tabs", "tracking"];
  } else if (state.connected) {
    [label, tone] = ["Connected to Daylanes", "waiting"];
    help = "Daylanes asks for the tab only while your browser is in front and tracking isn’t snoozed.";
  } else {
    tone = "error";
    if (notInstalled.test(state.error ?? "")) {
      label = "Daylanes isn’t set up on this Mac";
      help = "Install and open the Daylanes app once. It sets up the connection, and this page connects within a minute.";
    } else {
      label = "Not connected to Daylanes";
      help = state.error ? `Chrome said: ${state.error}` : "";
    }
  }
  statusLine.textContent = label;
  statusLine.dataset.state = tone;
  hint.textContent = help;
}

async function refresh(type = "status") {
  try {
    show(await chrome.runtime.sendMessage({ type }));
  } catch {
    statusLine.textContent = "Chrome couldn’t reach the extension. Reload it in chrome://extensions.";
    statusLine.dataset.state = "error";
  }
}

form.addEventListener("submit", async event => {
  event.preventDefault();
  const value = alias.value.trim();
  if (!validAlias(value)) {
    error.textContent = "Use up to 40 letters, numbers, spaces, hyphens, or underscores.";
    return;
  }
  error.textContent = "";
  try {
    await chrome.storage.local.set({ alias: value });
    error.textContent = value ? `Saved. Rules can now use the label “${value}”.` : "Label removed.";
  } catch {
    error.textContent = "Chrome couldn’t save the label. Try again.";
  }
});

toggle.addEventListener("click", async () => {
  try {
    await chrome.storage.local.set({ enabled: !enabled });
  } catch {
    error.textContent = "Chrome couldn’t save this change. Try again.";
  }
  await refresh("connect");
});

(async () => {
  try {
    const { alias: saved } = await chrome.storage.local.get("alias");
    alias.value = saved ?? "";
  } catch { /* Leave the field empty. */ }
  await refresh("connect");
  // Keep the status current while the popup is open.
  setInterval(() => void refresh(), 2000);
})();
