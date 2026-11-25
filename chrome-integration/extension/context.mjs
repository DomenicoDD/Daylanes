export function validAlias(value) {
  if (typeof value !== "string") return false;
  return value.length <= 40 && !/[^a-zA-Z0-9 _-]/.test(value);
}

export function addressOf(value) {
  if (typeof value !== "string") return null;
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return null;
    const segments = url.pathname.split("/");
    const account = segments.findIndex(part => /@|%40/.test(part));
    const path = account < 0 ? url.pathname : segments.slice(0, account).join("/") + "/";
    const address = url.origin + path;
    return address.length <= 2048 ? address : null;
  } catch {
    return null;
  }
}

export async function focusedTab(api) {
  const windows = await api.windows.getAll({ windowTypes: ["normal"] });
  const focused = windows.find(window => window.focused && !window.incognito);
  if (!focused || focused.id === undefined) return null;

  const [tab] = await api.tabs.query({ active: true, windowId: focused.id });
  if (!tab || tab.incognito || tab.pendingUrl || tab.id === undefined) return null;

  const [confirmedWindow, confirmedTab] = await Promise.all([
    api.windows.get(focused.id),
    api.tabs.get(tab.id),
  ]);
  if (!confirmedWindow.focused || confirmedWindow.incognito || confirmedWindow.type !== "normal" ||
      !confirmedTab.active || confirmedTab.windowId !== focused.id || confirmedTab.incognito ||
      confirmedTab.pendingUrl || confirmedTab.url !== tab.url) return null;

  return addressOf(confirmedTab.url);
}
