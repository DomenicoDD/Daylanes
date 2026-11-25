# Daylanes browser extension privacy policy

_Last updated 22 November 2026_

The Daylanes extension connects your browser to the Daylanes app on your own Mac, so Daylanes can assign your browsing time to projects. This policy covers the extension.

## What the extension reads

When the Daylanes app asks for it, the extension reads the address of the tab that is active in the focused browser window. Before passing the address on, it removes:

- the query string and fragment (everything after `?` or `#`)
- any user name or password in the address
- the rest of the path from the first part that contains an email-style `@`

It sends only the site and the path that remain. If you set a profile label such as "Work" in the popup, it sends that label too.

The extension doesn't read page titles, page content, browsing history, cookies, form input, or your Google account. It doesn't run on pages and has no content scripts. Incognito windows are excluded.

## Where the data goes

The address and label go only to the Daylanes app on the same Mac, through Chrome's native messaging and a local connection that only your macOS user account can open. The extension makes no network requests. It sends no data to the developer or to anyone else, and contains no analytics, advertising or remote code.

The Daylanes app keeps addresses in memory to match them against the rules you create. It saves your rules and the projects that time is assigned to in a local database on your Mac. It doesn't upload them.

## What is stored in the browser

The extension stores two settings in Chrome's local extension storage: whether sharing is paused, and your profile label. Removing the extension deletes them.

## Your choices

You can pause sharing for any browser profile in the extension's popup, or remove the extension at any time. Without the Daylanes app installed, the extension does nothing.

## Contact

Questions about this policy: support@daylanes.app. The extension is published by Domenico Marco Di Donna, Via Lamaria 39, 80059 Torre del Greco (NA), Italy.
