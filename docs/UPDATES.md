# Update checks

Daylanes looks for a newer version by downloading one small JSON file:

```
https://daylanes.app/updates/latest.json
```

It lives in the website repository at `site/updates/latest.json`, so it ships with the same site
deploy that updates the download page.

## When the app checks

- 10 seconds after the main window opens, then every 6 hours while the app runs.
- When someone chooses **Daylanes > Check for Updates…**. This always answers: "up to date",
  "version X is available", or "couldn't check".

The request sends no install ID, licence key or usage data. The only identifying detail is the
`User-Agent: Daylanes/<version>` header.

When the feed names a newer version than `CFBundleShortVersionString`, an **Update available**
pill appears at the bottom of the sidebar. Clicking it shows the notes and a **Download** button,
which opens the DMG for this Mac's architecture (or `page` if that architecture has no DMG).
Builds from source (no `TRACKER_PAYMENTS`) open the GitHub repository instead.

Every licence includes all future updates, so the app never checks the licence before offering one.

## The feed

```json
{
  "version": "0.4.1",
  "released": "2026-11-25",
  "notes": "One or two sentences on what changed.",
  "page": "https://daylanes.app/download",
  "downloads": {
    "arm64": "https://downloads.daylanes.app/Daylanes-0.4.1-arm64.dmg",
    "x86_64": "https://downloads.daylanes.app/Daylanes-0.4.1-x86_64.dmg"
  }
}
```

Only `version` is required. Versions compare number by number (`0.10.0` is newer than `0.9.9`),
and anything after a hyphen is ignored.

## Publishing a release

1. Build, notarize and upload both DMGs to R2 (`bin/release arm64`, `bin/release x86_64`).
2. In the website repository, update the download page links **and** `site/updates/latest.json`
   in the same PR.
3. Deploy the site. Running copies notice the update within 6 hours, or at their next launch.

Publish the feed only after the DMGs are reachable, or the Download button leads to a 404.

## Later: one-click install

This check only tells people about a new version; they still drag the new app into Applications.
For download, verify and relaunch inside the app, add Sparkle 2: an EdDSA key pair (private key in
the Mac's Keychain), `Sparkle.framework` embedded and signed by `bin/release`, and an appcast next
to the DMGs. Copies with this check would keep reading `latest.json`, so keep publishing it.
