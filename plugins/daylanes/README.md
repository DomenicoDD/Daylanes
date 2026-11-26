# Daylanes plugin for Claude and Codex

[Daylanes](https://daylanes.app) is a Mac app that tracks consultant time, coding-agent usage and costs per client and project, and keeps a daily project Diary. This plugin connects Claude Code, Codex and the ChatGPT desktop app to the Daylanes ledger on your Mac.

**Requires the Daylanes app on macOS.** [Download Daylanes](https://daylanes.app/download), open it once, then install the plugin. The plugin contains only instructions, no code, and downloads nothing. If Daylanes is not installed, the agent tells you where to get it.

## What it adds

- **`daylanes-diary` skill**: writes or refreshes the Diary entry for a project you set up in **Daylanes → Diary**, following that project's brief. Ask "write my Daylanes diary".
- **`daylanes-time` skill**: answers questions such as "how many hours did I spend on Acme this week?" or "what did my agents cost this month?".
- **Daylanes MCP server** (`daylanes`), when you install from the Daylanes marketplace below (not from the Claude directory): read-only tools for status, projects, clients, rules, days and weeks of activity, ledger entries, agent work with no project, hours, tokens and costs, invoice lines and rates.

## What it runs

Everything runs locally on your Mac, so the skills work where the agent can run commands directly on your Mac, such as Claude Code and Codex. Cowork runs commands in a sandbox that cannot start Daylanes.app, so in Cowork use the MCP server instead (install from the Daylanes marketplace, or add `TrackerCLI mcp` as a local MCP server in the Claude desktop app).

- The skills ask the agent to run the command-line tool inside the app, `/Applications/Daylanes.app/Contents/MacOS/TrackerCLI` (or the copy that Spotlight finds by the app's bundle identifier): `diary list`, `diary guide`, `diary work` and `diary submit` for the Diary, and read-only commands such as `report`, `review` and `billing summary` for questions.
- The MCP server, when installed, is the same tool started as `TrackerCLI mcp`.
- `TrackerCLI` reads and writes the Daylanes SQLite ledger on your Mac (by default `~/.local/share/tracker/ledger.sqlite3`). It makes no network requests for these commands.

## Data and privacy

The plugin sends nothing to Daylanes or to anyone else. What the agent reads from Daylanes (project names, hours, agent usage, costs, Diary briefs and entries) becomes part of the agent's conversation, and so is sent to your agent's AI provider under that provider's terms. The Diary skill saves only drafts for diaries you set up in Daylanes, and your edits in Daylanes are kept. See the [Daylanes privacy policy](https://daylanes.app/privacy).

## Install

**Claude Code** (skills and MCP server)

```sh
claude plugin marketplace add DomenicoDD/Daylanes
claude plugin install daylanes@daylanes
```

**Codex**

```sh
codex plugin marketplace add DomenicoDD/Daylanes
```

Then install **Daylanes** from the plugin directory in the ChatGPT desktop app or Codex.

**Without the plugin**, register the MCP server directly:

```sh
claude mcp add --scope user --transport stdio daylanes -- /Applications/Daylanes.app/Contents/MacOS/TrackerCLI mcp
codex mcp add daylanes -- /Applications/Daylanes.app/Contents/MacOS/TrackerCLI mcp
```

## Support

Open an issue at https://github.com/DomenicoDD/Daylanes/issues or write to support@daylanes.app. Licensed under MIT, like the rest of Daylanes.
