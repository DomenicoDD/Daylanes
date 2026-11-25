# Daylanes browser extension

The Daylanes extension gives the local Daylanes desktop app (still called Tracker in this repository) the active Chrome tab's site and path and an optional label you set per Chrome profile. It is written in plain JavaScript and Swift, with a Python script to register the helper. The files in this directory use the [MIT License](LICENSE).

## Install from source

The unpacked extension supports Google Chrome, Microsoft Edge, Brave, Arc, Vivaldi and Chromium on macOS. It uses developer mode and works without a Google account or the Google Calendar build flag.

1. Build Tracker from the repository root using `./bin/build-desktop`, then open the built app. On every launch Tracker installs its helper in `~/Library/Application Support/Tracker/ChromeBridge`, registers it with every supported browser installed for this macOS user, and copies the extension to `~/Library/Application Support/Tracker/Chrome Extension`.
2. In Tracker, open **Settings → Integrations → Chrome extension** and choose **Show folder**.
3. In each Chrome profile you want to use, open `chrome://extensions`, turn on **Developer mode**, and drag that folder onto the page (or choose **Load unpacked** and select it). Remove any older copy of the extension (Tracker for Chrome) first. The manifest carries a fixed key, so the extension ID is always `lkckmlojgpfflmkhkaapcijpjehdmobo`, whichever folder you load it from.
4. Sharing starts right away. Open the extension's toolbar popup to check the connection, set an optional label such as `Client Work` or `Personal`, or pause sharing for that profile.
5. Start tracking in Tracker and focus a regular Chrome tab for a few seconds. The Chrome extension card turns **Active**, and **Last Chrome tab** shows the address. Use **Create tab rule** or enter the same label under **Chrome profile** in a domain or URL rule. With different profile labels, the same Gmail URL can map to two projects.

After rebuilding Tracker, open it once and reload the extension in `chrome://extensions` to pick up extension changes. The helper and registration update themselves.

The popup shows one of these states:

- **Connected. Tracker is reading tabs**: everything works.
- **Connected to Tracker**: the helper is running, but Tracker hasn't asked for a tab in the last two minutes. Check that tracking is on.
- **Tracker's helper isn't installed**: open Tracker once. The extension retries every minute.
- **Paused**: sharing is off for this profile.

The label identifies the browser profile you configured. It applies to every site that profile visits. A label does not identify which Gmail account or draft is open inside the profile.

Tracker can use the extension without macOS Automation permission for Chrome. If you previously granted Automation, Tracker can still use it to read a user-named window for an existing window-scoped rule or to capture context in a Chrome profile without a usable extension result. The **Allow Automation** button in Tracker requests macOS Automation for that existing method. To use extension context exclusively, disable Tracker's Chrome access under **System Settings → Privacy & Security → Automation**.

To stop sharing from one profile, choose **Pause sharing** in that profile's popup, or remove the extension. To remove the helper registration for all profiles, run `python3 chrome-integration/register.py remove`; Tracker registers it again on its next launch. To register a helper by hand, run `python3 chrome-integration/register.py install <path-to-TrackerChromeHost>`.

## Publish to the Chrome Web Store

The store is how most people should install the extension. Edge, Brave, Arc and Vivaldi install from it too.

1. Run `python3 chrome-integration/package.py` and upload the zip in the [Chrome Web Store developer dashboard](https://chrome.google.com/webstore/devconsole). The zip leaves out the manifest `key`, because the store assigns its own ID. The listing text and permission justifications are in [store/LISTING.md](store/LISTING.md).
2. Copy that ID into `storeExtensionIDs` in `TrackerChromeWire.swift`. Tracker then registers the helper for both the store ID and the development ID.
3. Optionally, copy the item's public key from the dashboard (**Package → View public key**) into `key` in `manifest.json` and update `extensionID` and `EXTENSION_ID` in `register.py` to the store ID. Unpacked builds then share the store's ID, and the development ID can be dropped.

The listing needs a public privacy policy: [store/PRIVACY.md](store/PRIVACY.md). The extension asks for `nativeMessaging`, which gets extra review, so explain in the listing that it talks only to the Tracker app on the same Mac.

## Audit the data flow

1. The extension keeps its paused setting and profile label in local Chrome storage. It requests the `tabs` and `nativeMessaging` permissions at install, plus `alarms` to retry the helper connection. It has no content scripts, remote code, web host permissions, or network destinations.
2. Chrome launches the built helper and talks to it over standard input and output. Its manifest is registered under the current macOS user and allows exactly the one extension ID supplied at setup. The helper independently checks the origin before startup and rechecks the registration before each request. [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
3. While recording foreground Chrome, Tracker asks the helper for one sample over a Unix domain socket in a directory readable only by the current macOS user. The helper and desktop client both check the socket peer's user ID. The trust boundary is the macOS account. Another process running as that user can access the local socket. The bridge uses no TCP or HTTP listener.
4. The helper sends a versioned, one-time request over the Chrome pipe. The extension verifies that a normal window in its profile is focused, the tab is active, and no navigation is pending. It rechecks the window and tab before replying and invalidates samples when focus or tab state changes. Tracker also checks for a fresh, matching reply and ignores ambiguous replies from multiple profiles and replies after Chrome loses macOS focus. Incognito is disabled in the extension manifest. [Chrome window API](https://developer.chrome.com/docs/extensions/reference/api/windows) · [Incognito manifest setting](https://developer.chrome.com/docs/extensions/reference/manifest/incognito)
5. The response has a request ID, a status, and, for a usable tab, its HTTP(S) origin and path and optional profile label. Credentials, query strings, and fragments are excluded. The browser also cuts off the path before any segment containing an email-style at sign. Titles, content, history, account identities, and click or keyboard input are outside the message contract. Paths may still include document or account IDs. Tracker uses the response in memory for matching and the last-tab readout. User-configured rules and their matches are saved to the ledger.

To audit the package without registering anything in Chrome:

```sh
node --test chrome-integration/tests/context.test.mjs
python3 -m unittest discover -s chrome-integration/tests -v
```

These tests use fake Chrome windows and tabs and the real Swift bridge with synthetic, framed pipe messages. The extension is loaded directly from source with no package manager or bundling step.
