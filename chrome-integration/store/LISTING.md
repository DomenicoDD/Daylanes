# Chrome Web Store listing

Copy these into the developer dashboard.

## Store listing

**Name:** Daylanes (from the manifest)

**Summary (up to 132 characters):**
Lets the Daylanes time tracker on your Mac see which site you’re working on. Nothing leaves your computer. (From the manifest.)

**Category:** Productivity → Tools

**Language:** English

**Description:**

The Daylanes extension connects your browser to Daylanes, a time tracker for macOS that records which app you're working in and assigns the time to clients and projects.

With the extension installed, Daylanes can also see which website is open in your active tab. So time in Gmail, Figma, Linear or a client's portal goes to the right project automatically. Add an optional label to each browser profile, such as Work or Personal, and the same site can go to different projects depending on the profile you use.

Privacy comes first:
• Only the site and path of the active tab are shared, never page content, titles or history.
• Query strings, fragments and anything that looks like an email address are removed first.
• Data goes only to the Daylanes app on the same Mac. The extension makes no network requests.
• Incognito windows are never read.
• You can pause sharing for each profile from the toolbar popup.

Requires the Daylanes app for macOS. The extension does nothing on its own.

Works in Google Chrome, Microsoft Edge, Brave, Arc and Vivaldi.

## Privacy practices tab

**Single purpose:**
Send the address of the active tab to the Daylanes desktop app on the same Mac, so it can assign tracked time to the user's projects.

**Permission justifications:**
- `tabs`: Reads the address of the active tab in the focused window when the Daylanes app asks for it. No other tab data is used.
- `nativeMessaging`: The only way the extension talks to the Daylanes app installed on the same computer. It doesn't connect to any server.
- `storage`: Saves the user's profile label and whether sharing is paused.
- `alarms`: Retries the connection to the Daylanes app once a minute when it isn't running yet.

**Remote code:** No, I am not using remote code.

**Data usage:** Tick only **Web history**. Even though only the active tab's site and path are shared with the app on the same device, the store counts visited addresses as web history. Then confirm all three statements:
- I do not sell or transfer user data to third parties, outside of the approved use cases.
- I do not use or transfer user data for purposes that are unrelated to my item's single purpose.
- I do not use or transfer user data to determine creditworthiness or for lending purposes.

**Privacy policy URL:** a public page with PRIVACY.md, for example https://daylanes.app/privacy/extension once the site is live.

## Graphic assets

All in `store/images/`, made from the lanes illustration in Figma (App Icon z). `tools/store-images/render.js` rebuilds them.

- Store icon: `store-icon-128.png` (96 px of art with 16 px of transparent padding)
- Screenshot: `screenshot-1280x800.png`, with the real popup in its connected state
- Small promo tile: `promo-small-440x280.png`
- Marquee promo tile: `promo-marquee-1400x560.png`

## Visibility

Start with **Unlisted**. Only people with the link can install it while you test with real users.
