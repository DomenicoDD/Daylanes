---
name: daylanes-time
description: Answer questions about tracked time, coding-agent usage and costs per client, project or task from Daylanes, the local Mac time tracker. Use for questions like "how many hours did I spend on Acme this week", "what did my agents cost this month", "what work has no project", or "draft my invoice lines".
---

# Ask Daylanes about time and costs

Daylanes keeps a local ledger on the user's Mac: human time (from the app in front, rules and manual entries), coding-agent sessions (Claude Code, Codex, OpenCode and others, with tokens, model and estimated cost) and expenses, grouped by client and project, with billing rates.

## Prefer the MCP tools

If a `daylanes` MCP server is connected (installed from the Daylanes marketplace, or registered by hand with `TrackerCLI mcp`), use its tools: start with `get_status`, use `resolve_context` to find the project for the current folder, then `usage_report`, `get_day`, `get_week`, `list_entries`, `list_unassigned`, `review_unassigned`, `billing_summary` and `get_report` as needed. They are read-only unless the user turned on project and rule setup in Daylanes.

## Otherwise use the command-line tool

Find `DAYLANES`: the first existing of `/Applications/Daylanes.app/Contents/MacOS/TrackerCLI`, `~/Applications/Daylanes.app/Contents/MacOS/TrackerCLI`, or the app returned by `mdfind "kMDItemCFBundleIdentifier == 'com.domenicodidonna.tracker'"` plus `/Contents/MacOS/TrackerCLI`. If none exists, say that Daylanes is not installed (https://daylanes.app/download) and stop.

Useful read-only commands (all accept `--period week|month`, or `--start YYYY-MM-DD --end YYYY-MM-DD` with the end exclusive, in the ledger's time zone):

- `DAYLANES report --json [--client NAME] [--project NAME] [--task ID]`: hours, tokens and costs.
- `DAYLANES billing summary`: invoice lines per client using the saved rates.
- `DAYLANES review`: agent work with no project, grouped by folder and branch.
- `DAYLANES entries [--project NAME] [--unassigned] [--limit N]`: individual records.
- `DAYLANES blocks --active`: the current five-hour usage window.
- `DAYLANES project list` and `DAYLANES client list`: names to filter by.

## Rules

- Do not change data unless the user asks. Commands such as `assign`, `time`, `expense`, `remove` and `billing set` write to the ledger: show the user what you will run first.
- Agent costs are estimates from local logs and public prices. Say so when you quote them, and give the currency from the report.
- Agent time can overlap human time and other agents; do not add them up as if they were exclusive unless the report already does.
