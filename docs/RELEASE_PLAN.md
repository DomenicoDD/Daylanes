# Tracker release plan

Status: proposal, nothing built yet. Asset specs come first so design can start now.
Items marked **verify** are things to confirm with a test build on a Mac before relying on them.

## 0. One release blocker found while planning

**The engine runs `/usr/bin/python3`.** On a Mac without the Xcode Command Line Tools,
that path is only a stub that asks the user to install the tools (a ~1 GB download).
Most people who download a time tracker will not have them. Before a public release,
either bundle a signed Python runtime inside `Tracker.app` (about 40–60 MB, every
binary signed for notarization) or port the engine to Swift. Bundling is the quicker
route; porting is the cleaner one. **Decided 2026-11-20: port the engine to Swift**
(section 7). **Done 2026-11-21:** groups A to E are merged and the app no longer runs or ships Python.

Not a blocker, but worth a prompt: running Tracker straight from the DMG still works for
Chrome, because `ChromeBridge.installNow()` copies the helper to
`~/Library/Application Support/Tracker/ChromeBridge/` and registers that path, not the
bundle. A copy left in the DMG or Downloads (App Translocation) cannot be updated by Sparkle
and disappears when the DMG is ejected, so a gentle "Move to Applications" offer on first
launch is still worthwhile.

## 1. Asset specs

### 1.1 DMG installer window

The concept: agents' work (coloured blocks, one lane per agent thread) flows from the
left into a calendar, and that calendar is the Tracker app icon you drag to Applications.

| Item | Value |
|---|---|
| Window content area | **660 × 400 pt** |
| Background @1x | **660 × 400 px**, `background.png` |
| Background @2x | **1320 × 800 px**, `background@2x.png` |
| Shipped as | one `background.tiff` made with `tiffutil -cathidpicheck background.png background@2x.png -out background.tiff` (Finder picks the right resolution) |
| Icon size in Finder | **128 pt** (256 px on Retina, drawn by Finder from the app icon) |
| Label text size | 13 pt, shown under each icon |
| Tracker.app icon centre | **x 180, y 190** (from the top-left of the content area) |
| Applications link centre | **x 480, y 190** |
| Distance between centres | 300 pt; the arrow or flow sits in the 172 pt gap between the icon edges (x 244 to 416) |
| Toolbar, status bar, sidebar | hidden |
| Volume icon (optional) | `.VolumeIcon.icns`, from the same artwork as the app icon |

Design notes:

- **Keep under the icons plain.** Finder draws each icon in a 128 × 128 box centred on the
  points above (x 116–244 and x 416–544, y 126–254), and the label in a band about
  20 pt tall just below (y ≈ 258–278). Do not put artwork that competes with the real
  icon there, because the app icon itself is the end of the "flow".
- **Finder does not theme the background.** The image looks the same in light and dark
  mode, but the label colour follows the system. A mid-light background (or a soft
  plate behind the labels) keeps "Tracker" and "Applications" legible in both. **verify**
  in both appearances.
- **Title bar.** The 660 × 400 is the area under the title bar. When the script sets the
  Finder window bounds, use 660 × 428 (about 28 pt of title bar on macOS 14–26), and
  **verify** the image is not cropped on the first test DMG.
- Leave the top 40 pt and bottom 70 pt for a headline ("Drag Tracker to Applications")
  and optional small print, or keep them empty.
- An animated DMG is not possible; Finder shows a still image. The motion idea can live in
  the welcome screen instead (section 3).

**Apple-style variant (like Icon Composer's DMG).** Domenico shared Icon Composer 27.2's
installer as a reference. Measured from that @2x screenshot: the window content is about
**886 × 644 pt**, with a light grid-paper background and a rounded card (about 47 to 661 pt
wide) holding one centred app icon (128 pt, centre about x 341, y 245) and a footer band
with the product name and version in large blue type. It has **no Applications link**:
users drag the app out themselves.

For Tracker, the same look works with the calendar grid as the "paper" and the agent
lanes flowing into the icon, and the version line in the footer
("Tracker 0.3"). Specs for that variant:

| Item | Value |
|---|---|
| Window content area | **880 × 640 pt** |
| Background | **880 × 640 px** @1x, **1760 × 1280 px** @2x |
| Tracker.app icon centre | x 340, y 245 (128 pt icon) |
| Applications link (recommended, see below) | x 600, y 245, or leave it out to match Apple |
| Footer band | y 400 to 600: product name and version baked into the image |

Recommendation: keep an Applications link even in this style, so it is obvious where the
app goes. Chrome keeps working either way (section 0), but an app run from the DMG cannot
update itself. With Apple's single-icon look, the "Move to Applications" offer matters more. The version in the footer means a new
background for every release, so either keep it generic or render it in the release script.

Build tool: `create-dmg` (Homebrew, the shell one by andreyvit) produces exactly this:

```sh
create-dmg --volname "Tracker" --volicon VolumeIcon.icns \
  --background background.tiff --window-size 660 428 --icon-size 128 --text-size 13 \
  --icon "Tracker.app" 180 190 --app-drop-link 480 190 --hide-extension "Tracker.app" \
  Tracker-0.3.0.dmg build/Tracker.app
```

### 1.2 App icon

Tracker targets macOS 14 and later, so it needs a macOS 26 Liquid Glass icon *and*
a classic icon for macOS 14 and 15.

**macOS 26: Icon Composer (`AppIcon.icon`)**

| Item | Value |
|---|---|
| Tool | Icon Composer (ships with Xcode 26) |
| Canvas | **1024 × 1024 px**, square, full bleed; the system applies the rounded shape |
| Layers | export each layer as **SVG** (preferred) or PNG at 1024 × 1024, transparent, flat colour; no baked-in shadows, gloss or blur, since Icon Composer adds glass, specular and shadow |
| Groups | up to 4 groups, back to front. Suggested: 1 background (calendar sheet), 2 grid / day columns, 3 the coloured agent blocks, 4 the "today" marker |
| Appearances to check | Default, Dark, Clear (light and dark), Tinted. Give the coloured blocks enough contrast to survive Tinted mode, where colour is removed |
| Output | `AppIcon.icon` package, committed to the repo |

**macOS 14 and 15: classic icon**

Xcode 26 can generate the older rendering from the `.icon` file, but our build uses plain
`swiftc`, not an Xcode project (see 1.4). To be safe, also export a classic icon:

| Size (pt) | @1x px | @2x px |
|---|---|---|
| 16 | 16 | 32 |
| 32 | 32 | 64 |
| 128 | 128 | 256 |
| 256 | 256 | 512 |
| 512 | 512 | 1024 |

On the 1024 px canvas, the classic macOS shape is a rounded rectangle of **824 × 824 px**
centred (100 px margin on each side), corner radius about **185 px**, with the drop shadow
inside the margin. These ten PNGs become `AppIcon.icns` via `iconutil -c icns AppIcon.iconset`.

**Menu bar icon (separate asset):** a template image, black on transparent,
**18 × 18 pt** (18 and 36 px), PDF or SVG preferred. A simplified calendar glyph, not the
full icon.

**Chrome extension icon:** already 16/32/48/128 px. For the Web Store, the 128 px icon should
have its artwork in the centre **96 × 96 px** with 16 px transparent padding.

### 1.3 Mac App Store screenshots

Only needed if Tracker goes to the Mac App Store (see section 2: not recommended for v1).
They are still the right size for a website or Product Hunt, so worth making once.

| Item | Value |
|---|---|
| Aspect | 16:10 |
| Accepted sizes | **2880 × 1800** (recommended), 2560 × 1600, 1440 × 900, 1280 × 800 px |
| Count | 1 to 10 per language |
| Format | PNG or JPEG, no transparency, RGB |
| Per language | each localization (it, fr, es, de) can have its own set; otherwise English is used |
| Preview video (optional) | up to 30 s, 1920 × 1080, H.264 or ProRes |

Suggested five: 1 day calendar with you + agent columns, 2 billing columns and invoice
lines, 3 menu bar quick view, 4 per-project overview with AI cost, 5 privacy (all local,
Chrome extension).

**Chrome Web Store assets** (needed regardless):

| Asset | Size |
|---|---|
| Screenshots | 1280 × 800 px (or 640 × 400), 1 to 5, can differ per language |
| Small promo tile | 440 × 280 px (required for featuring) |
| Marquee promo tile | 1400 × 560 px (optional) |

### 1.4 Build changes the assets need

The app is built with `swiftc` in `bin/build-desktop`, so there is no asset catalog step.
To ship the icon and string catalogs, the script will call the tools directly:

- `xcrun actool AppIcon.icon --compile build/... --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist ...` (**verify** that actool accepts the `.icon` package from the command line), and add `CFBundleIconName` / `CFBundleIconFile` to Info.plist.
- `xcrun xcstringstool compile Localizable.xcstrings --output-directory build/.../Resources` for strings (section 4).

If these command-line steps turn out fragile, the alternative is moving the app into an
Xcode project. That is a bigger change, so it is a question for Domenico, not a default.

## 2. Distribution: App Store or direct?

**Recommendation: direct distribution (Developer ID, notarized DMG) for v1.** The App
Sandbox, which is mandatory on the Mac App Store, blocks most of what makes Tracker work:

| Tracker feature | Under the App Sandbox |
|---|---|
| Window titles via Accessibility (`AXIsProcessTrusted`, `AXUIElementCopyAttributeValue` in `WindowTitles.swift`) | **Blocked.** Sandboxed apps cannot be granted Accessibility access to read other apps' UI. |
| Chrome tab via Apple events (`ChromeTabs.swift`) | Needs a `temporary-exception.apple-events` entitlement for Chrome, which App Review generally rejects. |
| Registering the native messaging host in `~/Library/Application Support/Google/Chrome/NativeMessagingHosts` (and Edge, Brave) | **Blocked**: writing outside the container needs a temporary-exception file entitlement, also generally rejected. The user could pick the folder in an Open panel, which is a poor experience for every browser and channel. |
| Reading agent history (`~/.codex`, `~/.claude`, OpenCode) | Possible only after the user picks each folder once (security-scoped bookmarks). Workable but clumsy. |
| Running `/usr/bin/python3` and `gh` | Children inherit the sandbox; `gh` reads its own config and keychain outside the container and would fail. Also App Review expects the app to be self-contained. |
| Frontmost app via `NSWorkspace` | Fine. |

A split (a reduced App Store edition plus the full direct one) would mean a second
target, two sets of onboarding and support, and an App Store edition without window
titles or Chrome, which is most of the value. Not worth it for v1. Revisit if App Store
discovery matters later; the screenshots in 1.3 keep that door open.

Direct distribution needs:

- Apple Developer Program membership (99 USD a year) for the Developer ID certificate.
- Hardened runtime, Developer ID signing, notarization and stapling (section 5).
- An update mechanism: Sparkle 2 (EdDSA-signed appcast, hosted on GitHub Releases or a
  small static site). Without it every update is a manual re-download.
- A download page (can be the GitHub release at first).

## 3. First-launch welcome screen

Modelled on Apple's "What's New" sheet (the Icon Composer screenshot): a fixed-size sheet
with the app icon, a large title, a short subtitle, three rows of SF Symbol + title +
body, and one full-width Continue button.

**Measurements taken from the screenshot (it was a @2x capture):**

| Element | Value |
|---|---|
| Sheet | about **460 × 680 pt**, dark material, 26 pt corner radius (system sheet) |
| App icon | 64–70 pt, centred, 40 pt from the top |
| Title | 26 pt bold, left-aligned at a 64 pt inset |
| Subtitle | 22 pt regular, secondary colour |
| Feature rows | SF Symbol 34 pt in the accent colour in a 50 pt column; title 15 pt semibold; body 15 pt secondary; 28 pt between rows |
| Button | full width minus 96 pt, 36–40 pt tall capsule, accent fill, 15 pt semibold label, 32 pt from the bottom |

In SwiftUI this is a `.sheet` on the main window with `.presentationSizing(.fixed)`
(macOS 15) and a fixed frame fallback on macOS 14. All text and symbols are native, so
it localizes and adapts to light and dark without image assets. The only asset is the
app icon.

**Flow (three pages, same frame, Continue advances):**

1. **Welcome to Tracker.** Subtitle: "Your time and your agents' time, on one calendar."
   Rows: *Day calendar* (`calendar.day.timeline.left`): you and every agent thread side by
   side. *Agents included* (`sparkles`): Codex, Claude Code and OpenCode sessions are
   imported with tokens and cost. *Ready to bill* (`banknote`): rates per client and project
   for you and your agents.
   Optional: replace the app icon at the top with a short looping animation of blocks
   flowing into the calendar; this is where the DMG concept can move.
2. **Permissions.** Same row style, but each row has a live status on the right
   (Granted / Set up) instead of only text:
   - *Window titles* (`macwindow`): Accessibility. Button opens
     `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`;
     the row polls `AXIsProcessTrusted()` every second and turns green when granted.
   - *Websites in Chrome* (`globe`): link to the Chrome Web Store listing; status turns
     green once the extension answers through the native host. Edge and Brave mentioned
     in the body.
   - *Agent history* (`folder`): shows which of `~/.codex`, `~/.claude`, OpenCode were
     found; nothing to grant in direct distribution.
   - *GitHub* (`arrow.triangle.pull`, optional): detects `gh` and its sign-in.
   Continue is always enabled; skipped items remain in Settings > Integrations.
3. **Your first project.** Client defaults to "Me" (yourself as client), project name,
   optional hourly rate. "Start tracking" closes the sheet.

**Reuse as "What's New":** store `lastSeenVersion` in UserDefaults. On first launch show
the full flow; after an update to a new minor version show only page 1 with that
release's three highlights (from a small `WhatsNew` table in code, localized like other
strings). Settings gets a "Show Welcome" button.

## 4. Localization: Italian, French, Spanish, German

**App (String Catalogs)**

- Add `desktop/Localizable.xcstrings` with source language English and `it`, `fr`, `es`,
  `de`, plus `InfoPlist.xcstrings` for `NSAppleEventsUsageDescription` and the
  Accessibility explanation.
- Set `CFBundleLocalizations` in Info.plist to `en it fr es de`.
- Code changes, in rough order of effort:
  1. `Text("literal")` already localizes. Strings built as `String` and passed to `Text`
     or `Label` do not: change them to `String(localized:)` or `LocalizedStringResource`
     (there are around 130 literal `Text(...)` calls plus menus, alerts and buttons).
  2. Plurals ("3 agents", "and 4 more") use catalog plural variants, not `if count == 1`.
  3. Dates, durations, currency and token counts go through `FormatStyle`
     (`.formatted(.currency(code:))`, `Duration.formatted`) so 1.234,5 and 24-hour time
     follow the locale. Some of this is formatted by hand today (`hoursText`).
  4. Messages produced by the Python engine (errors such as "Install GitHub CLI and sign
     in…") reach the UI as English text. Give them stable error codes and translate in
     Swift.
- Extraction without Xcode: `swiftc ... -emit-localized-strings -emit-localized-strings-path build/strings`
  then `xcrun xcstringstool sync Localizable.xcstrings --stringsdata build/strings/*.stringsdata`,
  and `xcstringstool compile` at build time (**verify** both flags on the Mac's Xcode).
- German runs about 30 % longer than English: check the sidebar, toolbar pill, billing
  editor and the welcome sheet at 460 pt.
- Translations: I can draft all four. Domenico reviews Italian; French, Spanish and German
  need one native read-through each before release (the billing vocabulary matters most).

**Chrome extension**

- Add `_locales/{en,it,fr,es,de}/messages.json`, set `"default_locale": "en"`, and change
  `name`, `description` and the popup text to `__MSG_…__` / `chrome.i18n.getMessage`.
- Store listing: in the developer dashboard add a listing per language (name, summary up
  to 132 characters, description, and optionally localized screenshots). Draft the four
  translations of `chrome-integration/store/LISTING.md` and `PRIVACY.md` alongside.

**DMG:** keep the background wordless (or English only), since one DMG serves every
language.

## 5. Signing and notarization

One-time setup:

1. Join the Apple Developer Program; create a **Developer ID Application** certificate
   (Xcode > Settings > Accounts, or developer.apple.com) and keep it in the login keychain.
2. Store notarization credentials:
   `xcrun notarytool store-credentials tracker-notary --apple-id … --team-id … --password <app-specific password>`
   (or an App Store Connect API key, better for CI).

Each release, in `bin/release` (new script, replaces the ad-hoc `codesign --sign -`):

1. Build as today.
2. Sign inside out with hardened runtime and a timestamp:
   - every bundled binary first (`TrackerChromeHost`, and the Python runtime's binaries and
     `.dylib`/`.so` files if Python is bundled),
   - then `Tracker.app`:
     `codesign --force --options runtime --timestamp --entitlements desktop/Tracker.entitlements --sign "Developer ID Application: … (TEAMID)" build/Tracker.app`
3. Entitlements (`desktop/Tracker.entitlements`, new):
   - `com.apple.security.automation.apple-events` = true. **Required**: under the hardened
     runtime, Apple events to Chrome fail without it, even with the usage description.
   - No sandbox, no other exceptions expected. If a bundled Python needs
     `com.apple.security.cs.allow-unsigned-executable-memory` or
     `disable-library-validation`, add only what the test build proves necessary.
4. Make the DMG (1.1), then sign it: `codesign --sign "Developer ID Application: …" --timestamp Tracker.dmg`.
5. Notarize: `xcrun notarytool submit Tracker.dmg --keychain-profile tracker-notary --wait`;
   on failure `xcrun notarytool log <id>`.
6. Staple: `xcrun stapler staple Tracker.dmg` (the app inside is covered by the DMG's ticket;
   also stapling `Tracker.app` before packaging helps offline first launch).
7. Check: `spctl -a -vvv -t open --context context:primary-signature Tracker.dmg` and
   `spctl -a -vvv build/Tracker.app` should say "Notarized Developer ID".
8. Publish the DMG, then the update feed (docs/UPDATES.md).

Later: move steps 2–7 to a GitHub Actions macOS runner with the certificate and API key as
secrets.

## 6. Proposed order

1. **Assets (Domenico):** DMG background, `AppIcon.icon`, classic icon set, menu bar glyph.
2. **Port the engine to Swift** (section 7). Blocks a public release.
3. **Signing and notarization script** with a test DMG (needs the developer account).
4. **Welcome sheet** plus the "Move to Applications" check.
5. **Localization**: string cleanup and catalog first, then translations and review, then
   the extension and store listings.
6. **Sparkle updates** and the download page.
7. **Pricing and licensing** (section 8): Polar product, checkout Worker, Account pane.
   Must ship with the first public DMG.

Questions for Domenico:

- ~~Bundle Python or port to Swift?~~ Swift (2026-11-20).
- ~~Developer Program active?~~ Yes (2026-11-20).
- Keep the `swiftc` build script, or move to an Xcode project now that icons and string
  catalogs are coming?

## 7. Porting the engine to Swift

The engine is about 3,100 lines of Python in `tracker/` (store and schema 505, `__main__`
CLI 420, importers 396, billing 378, focus 297, toggl 238, github 227, reports 177,
desktop 161, pricing/openrouter/mcp about 115 each). It uses only the standard library:
`sqlite3`, `json`, `decimal`, `datetime`/`zoneinfo`, `urllib`, `csv`, `subprocess` (for `gh`).
All of that has a direct Swift counterpart (system `libsqlite3`, `Codable`/`JSONSerialization`,
`Decimal`, `Calendar`/`TimeZone`, `URLSession`, `Process`).

**Approach: in place, one command group at a time, behind the existing interface.**

The app talks to the engine only through `Ledger.run([args]) -> JSON`. That stays:

1. Add `TrackerCore` (Swift, no UI imports): SQLite wrapper, the same schema and
   migrations as `store.py`, and an `Engine.run(arguments) -> Data` that returns the
   same JSON the Python CLI prints.
2. `Ledger.run` calls `Engine.run` for every command already ported, and falls back to
   `/usr/bin/python3` for the rest. Each PR ports a group and removes it from the fallback.
3. **Same database, same JSON.** Existing ledgers open unchanged; no migration step for
   Domenico's real data.
4. **Parity check on the Mac:** a script runs each command through Python and Swift on a
   copy of the ledger and diffs the JSON. A group is done when the diff is empty (or the
   difference is a known, intended fix). The Python tests stay until the last group lands.
5. A small `tracker` command-line binary built from `TrackerCore` replaces `bin/tracker`
   and serves the MCP server, so agents keep their tools without Python.

**Order (each a PR, each built and parity-checked on the Mac):**

| PR | Ports | Why this order |
|---|---|---|
| A | store/schema, `init`, `project`, `client`, settings | everything else depends on it |
| B | `focus` (record, rules, assign) | runs all day; biggest win for battery and latency |
| C | `importers` and `sync` (Codex, Claude Code, OpenCode) | reads agent logs |
| D | `reports`, `billing`, `pricing`, CSV export | numbers must match to the cent |
| E | `github`, `toggl`, `openrouter` (network) | `URLSession`, keychain tokens already in Swift |
| F | `tracker` CLI binary, MCP server, stop shipping and calling Python | Python gone from the app (`tracker/` stays as the parity reference) |

The cloud environment cannot compile Swift (no toolchain, and the toolchain download is
blocked), so every PR is built and checked on the Mac before it is marked ready.

## 8. Pricing, trial and licensing

Decided with Domenico on 2026-11-20.

**Price:** one-time purchase, **49 USD**. Buying during the trial costs **29 USD**.
The official installer includes a **14-day trial**. When it ends, the price goes up and the app locks until licensed. The default open-source build compiles without payments or a trial.

**License terms** (changed by Domenico on 2026-11-25, was 12 months of updates): the
licence is perpetual. The app keeps working forever and every future update is included,
with no renewal. 2 Macs per license (Polar activation limit).

The license key itself **never expires**, and the app no longer compares the purchase date
with the build's release date. New versions are announced by the update check (docs/UPDATES.md).

**Merchant of Record: Polar** (also supported by TrustMRR). New organizations pay
5% + 0.50 USD per sale, +1.5% for non-US cards, plus Stripe payout fees; no monthly fee.
A 49 USD sale on an EU card nets about 45.30 USD; a 29 USD sale about 26.60 USD. Stay on
the free Starter plan until sales pass about 1,400 USD a month (Pro breakeven).
Domenico creates the Polar organization himself (identity and bank details).

**How the trial price is enforced**

1. **Trial start.** On first launch the app writes the trial start date and a random
   install ID to the Keychain (`IntegrationKeychain.swift` already wraps it), so deleting
   and reinstalling the app does not reset the trial.
2. **Checkout server.** A small Cloudflare Worker holds the Polar access token; the app
   never does. Two endpoints:
   - `POST /trial` with the install ID records the trial end on the first call and returns it with the current duration in days. Existing seven-day records gain seven days based on their original start. The same server deadline controls checkout pricing.
   - `POST /checkout` with the install ID: creates a Polar Checkout Session through the
     Checkout API for the Tracker product. Inside the trial window it attaches a code-less
     discount (fixed 20 USD off, `duration: once`, scoped to the product), so checkout shows
     29 USD. After it, no discount, 49 USD. Returns the checkout URL; the app opens it in
     the browser.
   Code-less discounts can only be applied through the API, so there is no code to share.
   The Worker stores the trial end in KV with the original duration in metadata. A record without metadata comes from the seven-day release.
3. **Activation.** The Polar product grants a License Key benefit (prefix `DAYLANES`,
   activation limit 2, no expiry). After paying, the user pastes the key
   (or opens a `tracker://activate?key=` link from the success page). The app calls Polar's
   public customer-portal license endpoints (`activate`, then `validate` on launch and
   once a day, with offline grace of 14 days); these need no token.
4. **After the trial.** Decided by Domenico on 2026-11-22: the app becomes unusable and only
   prompts to buy or enter a licence key (`desktop/LicenceGate.swift`). Tracking keeps running
   behind the lock, following the always-on rule; Domenico hasn't confirmed that part. A copy with a key is not locked when it is offline.
   The agent tools lock too (Domenico, 2026-11-25): the MCP server, `tracker call` and
   `tracker diary` read a stamp the app writes to
   `~/Library/Application Support/Daylanes/licence-stamp.json` (`core/LicenceStamp.swift`),
   because a Keychain prompt would block an agent-started process. After the trial without a key,
   only `get_status` answers (with `locked` and the reason); other tools return `trial_ended`. No
   stamp (the app was never opened) also locks. The stamp is not signed: Daylanes is open source,
   so a key in the code would be public, and anyone can build without the lock anyway. A build
   without payments (`TRACKER_ENABLE_PAYMENTS=0`, the source default) never locks the agent tools.

Someone can wipe the Keychain to get a new install ID and a new trial. That is rare and
acceptable for a 49 USD app.

**In the app**

- **Settings > Account** pane: trial status ("5 days left at 29 USD" / "Licensed to
  name@example.com, 1 of 2 Macs"), Buy button, Enter License Key, Deactivate this Mac.
- **Trial banner** at the top of the main window during the last 3 days,
  with the price it will be.
- **Menu bar**: "Buy Tracker…" item while unlicensed.
- Welcome flow (section 3) page 3 gets one line: "14-day free trial. Buy before it ends for
  29 USD."

**Steps**

1. Domenico: create the Polar organization (start in Polar's sandbox for testing).
2. Polar: Tracker product at 49 USD one-time, License Key benefit, success URL.
3. Cloudflare Worker with `/trial` and `/checkout`, KV namespace, Polar token as a secret.
4. App: `Licensing.swift` (Keychain trial + install ID, Worker calls, Polar license
   activate/validate), Account pane, banner, menu bar item.
5. End-to-end test in Polar sandbox: buy inside the trial (29), after it (49), third Mac
   activation refused.

The dashboard steps, the Worker deployment and the sandbox test are written out in
[POLAR_SETUP.md](POLAR_SETUP.md). The app side is `desktop/Licensing.swift` and
`desktop/AccountSettings.swift`; the Worker is `server/checkout`.

## 9. Publish the open-source release

1. Publish the MIT-licensed app repository from a reviewed source snapshot. Use example data in documentation and tests.
2. For the official installer, configure Polar and verify the 14-day trial and discounted checkout in the sandbox. Existing installations pick up the extended deadline when they upgrade.
3. Run `bin/release arm64` and `bin/release x86_64` using the production signing profile. Upload the notarized DMGs to the download host. Enable Google Calendar only with an approved Desktop OAuth client.
4. Update the public source, license, and official download links in the separate website repository once those URLs are reachable.
