# Contributing to Daylanes

Thanks for helping. Daylanes is a local-first Mac app, so most changes can be built and checked on your own Mac without any accounts.

## Build

You need macOS 14 or later and Xcode (or the Command Line Tools).

```sh
./bin/build-desktop
open build/Daylanes.app
```

The default build is free and leaves out the trial, licensing and checkout. Set `TRACKER_ENABLE_PAYMENTS=1` or `TRACKER_ENABLE_GOOGLE_CALENDAR=1` only when you work on those parts (see the [README](README.md#open-the-mac-app)).

To try a change without touching your own data, run the CLI against a copy of the ledger with `--db /tmp/ledger.sqlite3` (before the command), or set `TRACKER_DB`.

## Check your change

Run the checks in the README's [Verify](README.md#verify) section. CI runs the same checks on every pull request. At a minimum:

- `python3 -m unittest discover -s tests` for the Python reference engine,
- the Swift checks for any area you touched (`tests/*Checks.swift`),
- `python3 tests/parity.py …` after changing an operation that both engines implement.

## Code layout

- `core/` is the engine: an operation registry shared by the app, the `TrackerCLI` binary and the MCP server. It has no UI code.
- `desktop/` is the SwiftUI app. `cli/` is the command-line entry point.
- `chrome-integration/` is the Chrome extension and its native helper.
- `server/checkout/` is the optional Cloudflare checkout Worker used by the official build.
- `tracker/` is the Python reference engine, kept only for parity tests.

## Pull requests

- Keep each pull request to one change, and describe what a person sees differently.
- Add or update a check in `tests/` when you change behaviour.
- Tracking is always on by design: there is a Snooze, never a pause. Exclusions go through Do Not Track rules.
- User-facing text should be short and plain. The app ships in English, Italian, French, Spanish and German, so avoid wording that only works in English.
- Never commit API keys, licence keys, Polar or Google OAuth settings, or ledgers. `.gitignore` already excludes the usual files.

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
