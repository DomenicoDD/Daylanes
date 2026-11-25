# Tracker as an agent-first local tool: use cases and API plan

Status: plan for review, nothing built. Written 2026-11-20 against `main` (eeba5c1) and the
open work in PR #9 (new look, snooze, Swift port plan), PR #11 (20 agent tools, precise
token pricing, five-hour windows), PR #12 (Polar licensing) and the Reports branch
(`report-rows`, PDF and CSV).

The goal: an agent running on the same Mac (Claude Code, Codex, Cursor, any MCP client)
connects to Tracker and can ask real questions ("does October's invoice for Acme match what
I tracked?") and do real work ("assign Tuesday's unassigned blocks, then export the
report"), with the human keeping control of anything that changes money.

Contents

1. Where we are today
2. Use case catalogue
3. Design principles
4. One API, three front ends (app, CLI, MCP)
5. Transport, auth and privacy
6. Write safety and confirmation
7. Conventions (types, ids, errors, versioning)
8. Tools
9. Resources
10. Prompts
11. Feature coverage map
12. Data model changes the API needs
13. Phasing
14. Open questions

---

## 1. Where we are today

`tracker/mcp.py` is a 114-line stdio server (`tracker mcp`). It negotiates MCP protocol
versions up to 2025-11-25 and exposes three read-only tools:

| Tool | Backed by | Returns |
|---|---|---|
| `list_projects` | `store.project_list` | projects, client, kind, folders, GitHub repo |
| `usage_report` | `reports.report` | hours, agent runtime, tokens, expenses, billing summary |
| `review_unassigned` | `reports.review` | agent usage whose folder maps to no project |

Everything else the app can do lives behind the CLI (`python3 -m tracker …`), which the
app calls through `Ledger.run([args]) -> JSON`. The CLI has about 45 commands. None of the
write commands, the day timeline, rules, billing terms, Toggl, GitHub, pricing or exports
are reachable from an agent.

Things that shape the design:

- **The engine is being rewritten in Swift** (release plan section 7, PRs A to F, MCP
  server in PR F). The API below is therefore specified as a contract, independent of the
  language, and doubles as the parity test for the port.
- **Entities are keyed by name.** `projects.name` and `clients.name` are primary keys, and
  renaming a client rewrites four tables. Entries, blocks and rules already have stable
  ids (`focus:<uuid>`, `toggl:<account>:<id>`, `time:<hex>`, `expense:<hex>`, importer ids).
- **Some state lives outside the ledger.** Snooze is in the app's `UserDefaults`, tokens
  are in the Keychain, the recorder's live state is in the app process.
- **There is no audit trail and no undo.** A write is final the moment it commits.
- **Missing concepts** that the use cases need: tags you can set by hand (today a tag
  only comes from a rule match), notes on a block, invoices as records, budgets beyond the
  monthly agent cap, and an agent describing its own work.

## 2. Use case catalogue

Grouped by the job the person is trying to get done. "Tools" refers to section 8. "Gap"
is what the data model lacks today.

### A. Reconciliation

| # | Use case | What the agent is asked | Tools | Gap |
|---|---|---|---|---|
| A1 | Invoice against tracked time | "Here's the October invoice PDF for Acme. Does it match?" The agent reads the PDF itself and passes its lines. | `reconcile(against: "rows")`, `explain_bill` | none for a pasted invoice; invoice records for A4 |
| A2 | Toggl against Tracker | "Which Toggl entries have no matching tracked time, and the reverse?" | `reconcile(against: "toggl")`, `import_toggl`, `push_toggl` | Toggl comparison and push exist only in the uncommitted Tracker-Toggl folder |
| A3 | Git against time | "Which PRs merged this month have no time on them? Which time has no PR?" | `cost_of`, `query_time(group_by: ["pr"])` | none |
| A4 | Month close | "Close October for Acme: check gaps, check rates, produce the report, record the invoice." | prompt `close-month`, `find_gaps`, `billing_summary`, `export_report`, `record_invoice` | invoices and locked periods |
| A5 | Provider bill against usage | "OpenRouter charged 212 USD in October. Where did it go?" | `query_time(who: "agent", group_by: ["project","model"])`, `get_pricing` | none |
| A6 | Subscription value | "Is my Claude Max plan paying for itself?" | `usage_windows`, `query_time`, `get_pricing` | none |
| A7 | Double billing check | "Did I bill the same hour to two clients?" (allowed by design, but worth seeing) | `find_gaps(kind: "overlap")` | none |

### B. Finding and fixing time

| # | Use case | What the agent is asked | Tools | Gap |
|---|---|---|---|---|
| B1 | Untracked time | "What working hours last week have nothing recorded?" | `find_gaps(kind: "untracked")` | working hours setting |
| B2 | Unassigned time | "Show me everything without a project and suggest where it goes." | `list_unassigned`, `resolve_context` | none |
| B3 | Bulk assign | "Everything in Figma on Tuesday afternoon was Acme Website." | `assign_time` | none |
| B4 | Assign and remember | "…and do that from now on." | `assign_time(remember: true)` or `save_rule` | none |
| B5 | Exclude | "Don't count Slack or anything on youtube.com." | `ignore_time`, `save_rule(action: "ignore")` | don't-track rules in the ledger |
| B6 | Fix a mistake | "Move yesterday's 14:00 to 16:00 from Acme to Internal." | `assign_time`, `undo_change` | change log |
| B7 | Add missed time | "Add 90 minutes of client call for Acme yesterday at 10." | `log_time` | none |
| B8 | Split or trim a block | "Only the first hour of that block was Acme." | `assign_time(range)` | splitting a focus block |

### C. Understanding money

| # | Use case | What the agent is asked | Tools | Gap |
|---|---|---|---|---|
| C1 | Explain a bill | "Why is Acme 4,310 EUR this month?" | `explain_bill` | none |
| C2 | Explain one line | "What's in the 'Agent usage 612.40' line?" | `explain_bill(line)` , `get_report` | none |
| C3 | Cost of a task or PR | "What did PR #482 cost, in my time and in tokens?" | `cost_of` | none |
| C4 | Cost of a session | "How much did this Claude Code session cost so far?" | `cost_of(session)`, `resolve_context` | none |
| C5 | What-if | "What would October be at 120 an hour, agents billed by usage with 1.3 markup?" | `billing_summary(terms_override)` | none |
| C6 | Effective rate | "What's my effective hourly rate on Acme once agent cost is in?" | `query_time`, `billing_summary` | none |
| C7 | Missing rates | "Which projects have billable time and no rate?" | `billing_summary` (flags), `get_billing_terms` | none |

### D. Budgets, caps and limits

| # | Use case | What the agent is asked | Tools | Gap |
|---|---|---|---|---|
| D1 | Cap status | "How close is Acme to its monthly agent cap?" | `budget_status` | none |
| D2 | Self-throttling agent | Before a long run, the agent checks the budget of the project it is in and stops or asks. | `resolve_context`, `budget_status` | budgets beyond the client cap |
| D3 | Plan limits | "How much of my five-hour window is left? What's the burn rate?" | `usage_windows` | none (PR #11) |
| D4 | Alerts | "Tell me when any client passes 80% of its cap." | resource subscription on `tracker://budgets` | live notifications (phase 4) |
| D5 | Forecast | "At this pace, where does Acme end the month?" | `budget_status(forecast: true)` | none |

### E. Reports and exports

| # | Use case | What the agent is asked | Tools | Gap |
|---|---|---|---|---|
| E1 | Invoice report | "Make the October report for Acme, by day, in Italian, as PDF." | `get_report`, `export_report` | PDF is drawn by the app (needs the app running, or PDF moved into the core) |
| E2 | CSV for the accountant | "Export Q3 billable rows as semicolon CSV." | `export_report(format: "csv")` | none |
| E3 | Weekly summary | "Write my weekly update from what I tracked." | prompt `weekly-review`, `query_time` | none |
| E4 | Standup | "What did I and my agents do yesterday?" | `get_day` | none |
| E5 | Timesheet for a client portal | "Give me hours per day per project to paste into their system." | `query_time(group_by: ["day","project"])` | none |

### F. Setup and rules

| # | Use case | What the agent is asked | Tools | Gap |
|---|---|---|---|---|
| F1 | Onboard a repo | "Track this repo as Acme Website, billable, 110 an hour." | prompt `setup-project`, `save_client`, `save_project`, `set_billing_terms` | none |
| F2 | Write rules from history | "Look at last month's unassigned time and propose rules." | `list_unassigned`, `test_rule`, `save_rule` | none |
| F3 | Check a rule first | "What would a rule for 'linear.app/acme' have matched last month?" | `test_rule` | none |
| F4 | Route a PR | "PR #51 in the monorepo belongs to Acme Mobile." | `route_pull_request` | none |
| F5 | Prices | "Set the rate for a model OpenRouter doesn't list." | `set_pricing` | none |
| F6 | Health check | "Is everything connected and importing?" | `get_status`, `list_integrations`, `sync` | none |

### G. Agents accounting for themselves

| # | Use case | What happens | Tools | Gap |
|---|---|---|---|---|
| G1 | Know where I am | At session start the agent asks which client, project and task its folder and branch belong to. | `resolve_context` | none |
| G2 | Describe my work | At the end the agent attaches a summary, task id, PR and tags to its own session, so the report has a description instead of "Claude Code, 2 h". | `log_agent_work` | session annotations |
| G3 | Unsupported harness | A tool Tracker can't import logs its own usage. | `log_agent_work(usage)` | today only `import-harness` JSONL on stdin |
| G4 | Tag sessions | "Tag every session on the billing-refactor branch as 'refactor'." | `annotate_time` | manual tags |
| G5 | Hand-off cost | An orchestrator asks what each sub-agent thread cost. | `list_sessions`, `cost_of` | none |
| G6 | Snooze | "Stop tracking for 30 minutes, I'm on a personal call." | `snooze_tracking` | snooze in the ledger |

### H. Things an agent should not do

Listed so the API says no on purpose: read or set tokens and keys (Toggl, OpenRouter,
GitHub, Polar), activate or deactivate a license, turn tracking off other than a
snooze, delete imported history, change the ledger currency, read another client's data
when the connection is scoped to one client.

## 3. Design principles

1. **Local and offline first.** The server is a binary on the Mac reading the same SQLite
   ledger as the app. No cloud, no account, and it works when the app is closed.
2. **One operation set.** Every feature is an operation in the core with a typed input
   and output. The app, the CLI and MCP are three ways to call the same operation, so a
   feature can't exist in the UI and be missing for agents.
3. **Questions over tables.** Tools answer the question an agent actually has
   (`explain_bill`, `cost_of`, `reconcile`, `find_gaps`) and do the arithmetic in the
   core, to the cent. An agent adding up hours from raw rows will get billing wrong
   (overlap rules, monthly cap, rounding by largest remainder).
4. **Read by default, write on purpose.** A fresh connection can only read. Writes are
   switched on per client, and anything touching money or future behaviour needs a human
   yes that the agent cannot give itself.
5. **Every write is recorded and reversible** where the data allows it.
6. **Small surface.** About 45 tools in three toolsets, so a client that only needs
   reading sees about 25. Broad filters on few tools, not a tool per report.
7. **Privacy by scope.** A connection can be limited to one client or project, and
   window titles and URLs are only included when asked for.

## 4. One API, three front ends

```
            ┌──────────── TrackerCore (Swift, no UI) ────────────┐
            │  Operation registry                                │
 App UI ───▶│   name · input schema · output schema · effect     │──▶ ledger.sqlite3
 CLI    ───▶│   handler(params, context) -> result               │    (WAL, same file)
 MCP    ───▶│  Context: actor, access, scope, locale, license    │
            │  Change log · undo · approvals · licensing gate    │
            └────────────────────────────────────────────────────┘
```

An **operation** is declared once:

```swift
Operation(
  name: "assign_time",
  summary: "Assign captured time to a project.",
  input: AssignTimeInput.self,      // Codable, JSON Schema derived from it
  output: ChangeResult.self,
  effect: .write(.reversible),      // .read | .write(.reversible | .config | .guarded) | .external
  handler: assignTime)
```

From the registry:

- **MCP** builds `tools/list` (name, description, `inputSchema`, `outputSchema`,
  annotations `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`),
  filtered by the connection's access level and toolset. `tools/call` validates, runs the
  handler, returns `structuredContent` plus the same JSON as text for older clients.
- **CLI** gets `tracker call <operation> --json '{…}'` for free, and the friendly
  commands (`tracker report`, `tracker assign`, …) become thin wrappers that build the
  same input. `tracker api schema` prints the registry as JSON Schema.
- **The app** calls the handler in process with typed Swift values. The `snapshot`
  command, which today returns one large blob for the whole window, is split over time
  into the read operations below. Writes made in the UI go through the same change log
  with actor `you`, which gives the app undo for free.

This replaces the port plan's `Engine.run(arguments) -> Data` with
`Engine.call(operation, params, context) -> Result` while keeping the old argument form
as a wrapper until the app has moved over. The parity check from the port plan (same
ledger, Python against Swift, diff the JSON) runs per operation.

What stays out of the registry: the recorder loop (app only), Keychain access (app
only), drawing the PDF (app today, see open question 7), the Chrome native host.

## 5. Transport, auth and privacy

### Transport

**Phase 1 to 3: stdio.** The app bundle ships a `tracker` binary
(`Tracker.app/Contents/MacOS/tracker`, built from TrackerCore). `tracker mcp` speaks MCP
over stdin/stdout, opens the ledger directly, and exits when the client closes it. Every
MCP client supports this, it needs no port and no daemon, and it works with the app
closed. SQLite in WAL mode with `BEGIN IMMEDIATE` and a busy timeout already handles the
app and several agents writing at once; the app already reloads when the ledger changes.

```bash
# Claude Code
claude mcp add tracker -- /Applications/Tracker.app/Contents/MacOS/tracker mcp

# Codex (~/.codex/config.toml)
[mcp_servers.tracker]
command = "/Applications/Tracker.app/Contents/MacOS/tracker"
args = ["mcp"]
```

Settings gets an **Agents** pane with a "Connect" button per detected client that writes
this config (`tracker mcp install --client claude-code|codex|cursor|…`), shows which
clients have connected and when, and sets each one's access.

**Phase 4: a Unix socket to the running app**, for the things only the live app knows or
can do: recorder state, approvals shown as a notification, resource subscriptions, PDF
drawing. Path `~/Library/Application Support/Tracker/tracker.sock`, mode 0600, peer
user id checked. `tracker mcp` uses it when present and falls back to the ledger when not;
the agent sees one server either way.

**Not planned: an HTTP port on localhost.** Any local process and, without careful origin
checks, any web page can reach it. If a client ever requires Streamable HTTP, the binary
can serve it on the Unix socket or on a random port with a per-launch bearer token, off
by default.

### Auth and access

Anything that can launch `tracker mcp` already runs as the user and could read the SQLite
file, so the server is not a security boundary against local malware. What it does
protect against is an agent that is confused or prompt-injected. So access is about
**what a connection may do**, set by the human, outside the agent's reach:

| Access | Reads | Writes |
|---|---|---|
| `read` (default) | yes | none; write tools are not listed |
| `propose` | yes | every write becomes a proposal in the app's Inbox for the human to accept |
| `write` | yes | reversible writes apply at once; config and guarded writes still need approval (section 6) |

Set with `tracker mcp --access read|propose|write` in the client's config, and capped by
the per-client setting in Settings > Agents (the lower of the two wins). The client is
identified by `clientInfo.name` from MCP `initialize` plus the parent process's signing
identity where available; it is recorded as the actor on every change.

Never available over MCP at any level: tokens and keys, license activation, currency
change, deleting imported history, changing a connection's own access.

### Privacy scope

- `--client <id>` or `--project <id>` (repeatable): the connection sees only that data.
  Other clients are absent from every result, and totals don't include them.
- `--scope auto`: resolve the server's working directory to a project through the folder
  mapping and scope to that project's client. This is the recommended setting for a
  coding agent started inside a client's repo.
- `--detail titles`: window titles, URLs and domains are left out of rows unless this is
  set. App names and durations are always there. Default is off.
- Tool descriptions and results never contain file contents, only metadata the ledger
  already holds.

### Licensing

The license gate lives in the core, so MCP and the CLI are gated exactly like the UI. If
the decision in PR #12 is that an unlicensed copy loses reports, exports and billing
totals after the trial, then `billing_summary`, `explain_bill`, `get_report`,
`export_report` and `reconcile` return error `license_required`, and time queries keep
working. `get_status` reports `trial`, `licensed` or `unlicensed` and never the key.

## 6. Write safety and confirmation

### Effect classes

| Class | Meaning | Examples | `write` access | `propose` access |
|---|---|---|---|---|
| R | read | `query_time`, `explain_bill` | runs | runs |
| W1 reversible | changes how existing captured data is labelled; evidence stays | `assign_time`, `ignore_time`, `annotate_time`, `log_agent_work` (annotation only), `undo_change`, `sync` | applies, logged, undoable | proposal |
| W2 config | changes future behaviour or money inputs, or adds billable data with no captured evidence | `save_rule`, `save_project`, `save_client`, `set_billing_terms`, `set_pricing`, `log_time`, `log_agent_work` (with `usage`), `add_expense`, `snooze_tracking`, `import_toggl`, `export_report` to a chosen path | needs approval | proposal |
| W3 guarded | deletes, or leaves the Mac, or freezes a period | `delete_entry`, `delete_rule`, `push_toggl`, `record_invoice` | needs approval, always in the app | proposal |

`log_time` is W2 on purpose: an agent assigning a block that the recorder captured is
relabelling evidence, an agent adding 90 minutes that nothing captured is creating
billable hours.

### Preview, then apply

Every write tool takes `dry_run` (default `false`) and returns the same shape either way:

```jsonc
{
  "change_id": "chg_01JD…",
  "status": "applied" | "preview" | "pending_approval" | "rejected",
  "summary": "Assigned 7 blocks (3 h 40 min) on 2026-11-17 to Acme Website",
  "affected": { "count": 7, "millis": 13200000, "ids": ["focus:…", "…"] },
  "billing_effect": { "client": "Acme", "month": "2026-11", "before": "4310.00", "after": "4713.33", "currency": "EUR" },
  "undo": { "available": true, "expires_at": null },
  "approval": { "where": "app", "expires_at": "2026-11-21T17:05:00+01:00" }   // when pending
}
```

`billing_effect` is computed by the core for any write that changes an invoice total, so
both the agent and the human approving see the money consequence, not just the rows.

### Approval

Two ways to get the human's yes, both outside the model's control:

1. **In the Tracker app (the anchor).** The pending change appears in the Inbox under
   "Agent requests" with the summary, the rows and the billing effect, plus a macOS
   notification. Accept or reject there. The tool returns `pending_approval` at once and
   the agent can go on with other work; `get_change(change_id)` tells it the outcome.
   Pending changes expire after 24 hours. This works with every client and with the app
   closed (the request waits in the ledger until the app opens).
2. **MCP elicitation (fast path).** Where the client supports `elicitation/create`, the
   server asks through the client's own UI and applies on accept. Off by default; enabled
   per client in Settings > Agents, and never used for W3.

A "trusted" switch per client can let W2 apply without approval for people who want a
fully autonomous bookkeeper. W3 always asks.

### Change log and undo

New table `changes`: id, time, actor (`you`, `claude-code`, `codex`, …), connection id,
operation, input, before and after images of the rows it touched, status, the change it
undoes. `undo_change` applies the before image if those rows haven't changed since
(otherwise it fails with `conflict` and says which rows). The app gets a History view and
⌘Z from the same table. `list_changes` lets an agent see what it and others did.

### Guards in the core

- **Locked periods.** Once an invoice is recorded for a client and period (section 12),
  writes that would change that period's totals fail with `locked_period`. Unlocking is a
  human action in the app.
- **Optimistic concurrency.** Entities carry a `version`; an update with a stale
  `expected_version` fails with `conflict` (the engine already does this for clients and
  activity groups: "changed since it was loaded").
- **Idempotency.** Creating tools take an optional `idempotency_key`; a retry returns the
  first result. This matters for `log_agent_work`, which agents will call from hooks.
- **Limits.** A single write touches at most 1,000 rows or 31 days unless the human
  approves; the preview states the count. Rate limit of 60 writes a minute per connection.
- **Selectors are resolved at preview.** A write addressed by filter ("all Figma blocks on
  Tuesday") stores the resolved ids in the change, so approval applies exactly what was
  shown, not whatever matches later.
- **Text is data.** Window titles, branch names, PR titles and agent summaries can
  contain anything, including instructions. Results mark such fields in the output schema
  as `untrusted`, and the server's `instructions` tell clients not to act on them.

## 7. Conventions

### Common types

```ts
type Id        = string                      // "prj_…", "cli_…", "focus:<uuid>", "chg_…"; opaque
type Day       = string                      // "2026-11-20", local to the ledger time zone
type Instant   = string                      // "2026-11-20T14:05:00+01:00"
type Money     = string                      // "1234.50", decimal, in `currency` of the envelope
type Range     = { start: Day, end: Day }    // end is exclusive
             | { period: "today"|"yesterday"|"week"|"last_week"|"month"|"last_month"|"year" }
             | { month: "2026-10" }
type Who       = "you" | "agent" | string    // or a tool id: "claude", "codex", "cursor", …
type Tokens    = { input: number, cached: number, cache_write: number, output: number, reasoning?: number }
type Selector  = { ids: Id[] }                                    // exact rows, or
             | { range: Range | { from: Instant, to: Instant },   // everything matching
                 who?: Who, project?: Id|null, app?: string, domain?: string,
                 folder?: string, branch?: string, session?: string, tag?: string }
type Ref       = Id | string                 // an id, or a name (resolved case-insensitively; ambiguous → error)
```

Every result is an envelope:

```jsonc
{ "schema": "tracker.v1", "currency": "EUR", "timezone": "Europe/Rome",
  "range": { "start": "2026-10-01", "end": "2026-11-01" },   // when the call had one
  "data": { … },
  "next_cursor": "…",            // when there is more
  "warnings": [ { "code": "missing_human_rate", "message": "Acme Mobile has billable time and no rate" } ] }
```

- Durations are `millis` (integer) with an `hours` decimal string beside totals.
- Money is a decimal string, never a float. API-credit value is always `…_usd`.
- Lists take `limit` (default 100, max 1,000) and `cursor`.
- Names are accepted wherever an id is, to keep agents' calls natural; results always
  carry both.

### Errors

Tool errors come back with `isError: true` and:

```jsonc
{ "error": { "code": "conflict", "message": "Client changed since it was loaded.", "hint": "Call list_clients and retry.", "details": { } } }
```

Codes: `invalid_argument`, `not_found`, `ambiguous`, `conflict`, `locked_period`,
`forbidden` (access level), `out_of_scope` (privacy scope), `needs_approval`,
`limit_exceeded`, `license_required`, `app_required` (needs the running app),
`integration_unavailable`, `internal`.

### Versioning

- **MCP protocol:** negotiate as today, newest supported first.
- **API version:** `serverInfo.version` is the app version; `get_status.api` is
  `{ "major": 1, "minor": N }`; every envelope has `schema: "tracker.v1"`.
- **Within v1, changes are additive only:** new tools, new optional inputs, new output
  fields. Clients must ignore unknown fields. No renames, no meaning changes.
- **Breaking changes** get a new tool name (`explain_bill_v2`) or a new major served with
  `tracker mcp --api 2`; the old one stays for at least two app releases and its
  description starts with "Deprecated:".
- **The three v0 tools stay as aliases for one release:** `usage_report` →
  `query_time` + `billing_summary`, `review_unassigned` → `list_unassigned`,
  `list_projects` unchanged.
- The registry's JSON Schema is committed (`docs/api/tracker.v1.json`) and a test fails
  when a change to it isn't additive.

## 8. Tools

Toolsets: **core** (reading and everyday fixes), **billing**, **admin** (setup, rules,
integrations). `tracker mcp --toolsets core,billing` trims the list. Effect class in the
last column.

### 8.1 Orientation

| Tool | Input | Output (`data`) | Set | Class |
|---|---|---|---|---|
| `get_status` | none | `api`, `access`, `scope`, `tracking: { state: "tracking"\|"snoozed"\|"app_closed", snoozed_until? }`, `last_sync`, `license`, `integrations[]` summary, counts (`unassigned_blocks`, `pending_approvals`) | core | R |
| `resolve_context` | `{ folder?, branch?, repo?, pull_request?, session? }` (defaults to the server's working directory and its Git state) | `{ client, project, task, pull_request, kind, billable, terms, matched_by: "folder"\|"pr_route"\|"repo"\|"none" }` | core | R |
| `list_clients` | `{ include_archived? }` | `[{ id, name, is_self, icon, projects: number, terms, monthly_cap, version }]` | core | R |
| `list_projects` | `{ client?: Ref, kind? }` | `[{ id, name, client, kind, color, folders[], github_repo, routed_prs[], terms (effective, with source per field), version }]` | core | R |

### 8.2 Time and activity

| Tool | Input | Output (`data`) | Set | Class |
|---|---|---|---|---|
| `query_time` | `{ range, client?, project?, who?, task?, tag?, pull_request?, billable?: boolean, assigned?: boolean, group_by?: ("day"\|"week"\|"month"\|"client"\|"project"\|"task"\|"who"\|"tool"\|"model"\|"pr"\|"tag"\|"app")[], rows?: boolean, limit?, cursor? }` | `totals: { you_millis, agent_millis, tokens, api_value_usd, expenses, bill_amount }`, `groups[]` (one per key combination, same measures), and `rows[]` when asked: `{ id, kind: "you"\|"agent_run"\|"agent_usage"\|"expense", started_at, ended_at, millis, project, client, task, tags[], source: "automatic"\|"manual"\|"toggl"\|tool, app?, session?, model?, tokens?, pull_request?, title? (only with --detail titles) }` | core | R |
| `get_day` | `{ day?: Day, columns?: ("you"\|"agents"\|"billing")[] }` | the day view as data: `you[]` blocks, `agents[]` one per thread with `runs[]` and `lane`, `billing: { you[], ai[] }` spans with amounts, `totals` | core | R |
| `list_unassigned` | `{ range, who? }` | `groups[]`: `{ key: { who, app?, domain?, folder?, branch? }, count, millis, tokens, sample_ids[], suggestion?: { project, reason: "folder"\|"repo"\|"similar_rule"\|"history", confidence } }` | core | R |
| `find_gaps` | `{ range, kind: "untracked"\|"overlap"\|"ignored"\|"no_task"\|"no_rate", working_hours?: { start: "09:00", end: "18:00", days: number[] }, min_minutes?: 15 }` | `gaps[]`: `{ day, from, to, millis, kind, neighbours: { before, after }, details }` | core | R |
| `list_sessions` | `{ range, tool?, project?, folder?, branch? }` | `[{ id, tool, session, project, folder, branch, started_at, ended_at, runtime_millis, tokens, api_value_usd, models[], summary?, task?, pull_request?, tags[] }]` | core | R |
| `assign_time` | `{ select: Selector, project: Ref \| null, task?, range?: { from: Instant, to: Instant } (assign only this part of a block, splitting it), remember?: "folder"\|"rule"\|false, dry_run? }` | change result | core | W1 (`remember` makes it W2) |
| `ignore_time` | `{ select: Selector, ignored: boolean, dry_run? }` | change result | core | W1 |
| `annotate_time` | `{ select: Selector, add_tags?: string[], remove_tags?: string[], task?: string\|null, note?: string\|null, dry_run? }` | change result | core | W1 |
| `log_time` | `{ project: Ref, minutes?: number \| from+to: Instant, activity?: "prompting"\|"reviewing"\|"meeting"\|"other", task?, note?, at?: Instant, idempotency_key?, dry_run? }` | change result with the new `id` | core | W2 |
| `log_agent_work` | `{ session?: string (defaults to the caller's, when the client passes one), tool?: string, summary?: string, task?, pull_request?: { repo, number }, tags?: string[], usage?: { started_at, ended_at, model, tokens: Tokens, cost_usd? }[], folder?, branch?, idempotency_key?, dry_run? }` | change result | core | W1 for annotation, W2 when it adds `usage` |
| `delete_entry` | `{ id: Id, dry_run? }` (manual time and expenses only) | change result | core | W3 |

`log_agent_work` has two halves. **Annotation** (summary, task, PR, tags) attaches to a
session Tracker already imports from the tool's own logs, keyed by tool and session id,
so nothing is counted twice. **Usage** rows are only accepted for tools Tracker has no
importer for; for the 20 imported tools the server ignores `usage` and says so in
`warnings`. A call that adds usage is W2, like `log_time`: those rows are new billable
data with no captured evidence behind them, and under usage billing they raise the invoice.

### 8.3 Billing and money

| Tool | Input | Output (`data`) | Set | Class |
|---|---|---|---|---|
| `get_billing_terms` | `{ client?, project? }` | per client and project: `human_rate`, `agent_mode` (`none`\|`time`\|`usage`\|`hybrid`), `agent_rate`, `usage_markup`, `monthly_cap`, each with `source: "client"\|"project"\|"unset"`; plus `usd_exchange_rate` | billing | R |
| `billing_summary` | `{ range, client?, project?, terms_override?: { human_rate?, agent_mode?, agent_rate?, usage_markup?, monthly_cap? } }` | `clients[]`: `{ client, projects[]: { project, lines[]: { item: "you"\|"agent_time"\|"agent_usage", hours?, rate?, api_usd?, markup?, amount }, subtotal }, cap_reduction, total }`, `total`, flags `needs_exchange_rate`, `missing_human_rate`; `what_if: true` when overridden | billing | R |
| `explain_bill` | `{ client: Ref, range, project?, line?: "you"\|"agent_time"\|"agent_usage"\|"cap", depth?: "summary"\|"days"\|"rows" }` | for each line: the formula in words and numbers (`"38.25 h × 110.00 = 4207.50"`), where each term came from, the rows or days behind it (amounts allocated so they sum to the line to the cent), the cap calculation for the whole calendar month, exchange rate used, tokens with no price, overlaps counted once, and `checks[]` that passed or failed | billing | R |
| `cost_of` | one of `{ task }`, `{ pull_request: { repo, number } }`, `{ branch, repo? }`, `{ session }`, `{ tag }`, plus `range?` | `{ you: { millis, amount }, agents: { runtime_millis, tokens, api_value_usd, by_tool[], by_model[] , amount }, expenses, bill_amount, first_at, last_at, sessions[], days[] }` | billing | R |
| `budget_status` | `{ client?, project?, month?, forecast? }` | per client: `{ cap, used, remaining, percent, capped_reduction, by_project[], pace_per_day, forecast_month_end?, forecast_hits_cap_on? }`; per budget once budgets exist | billing | R |
| `usage_windows` | `{ hours?: 24, active_only? }` | five-hour windows per tool: `{ start, end, tokens, api_value_usd, burn_per_hour, projected, plan_limits? }` (PR #11 `blocks`) | billing | R |
| `list_expenses` | `{ range, client?, project?, reimbursable? }` | `[{ id, at, project, description, amount, reimbursable, task }]` | billing | R |
| `add_expense` | `{ project: Ref, description, amount: Money, reimbursable?, task?, at?, idempotency_key?, dry_run? }` | change result | billing | W2 |
| `set_billing_terms` | `{ client?: Ref \| project?: Ref, human_rate?: Money\|null, agent_mode?, agent_rate?: Money\|null, usage_markup?: string\|null, monthly_cap?: Money\|null, expected_version?, dry_run? }` (only the fields given change; `null` clears) | change result with `billing_effect` for the current month | billing | W2 |
| `get_pricing` | `{ model?, tool? }` | manual model rates, OpenRouter catalog match and fetch time, subscriptions with monthly total, `usd_exchange_rate`, models seen with no price | billing | R |
| `set_pricing` | one of `{ model_rate: { tool, model, input, cached, cache_write, output } }`, `{ subscription: { name, monthly: Money\|null, provider? } }`, `{ usd_exchange_rate: string\|null }`, plus `dry_run?` | change result | billing | W2 |

### 8.4 Reports and reconciliation

| Tool | Input | Output (`data`) | Set | Class |
|---|---|---|---|---|
| `get_report` | `{ client: Ref, range, projects?: Ref[], who?: "you"\|"agents"\|"both", billable_only?: true, detail: "totals"\|"project"\|"day"\|"task"\|"entry", group_under?: "project"\|"day"\|"task"\|"who", include_expenses?, language?: "en"\|"it"\|"fr"\|"es"\|"de" }` | the report as rows (`report-rows`): `{ id, who, date, started_at, ended_at, project, task, tags, description, tool, models, millis, billed_millis, tokens, time_amount, usage_amount }`, `adjustments[]` (monthly cap), `expenses[]`, `totals`; sums equal `billing_summary` to the cent | billing | R |
| `export_report` | the `get_report` input plus `{ format: "pdf"\|"csv"\|"csv_raw", columns?: string[], hours_format?: "decimal"\|"hm", paper?: "a4"\|"letter", separator?: ","\|";", path?: string }` | `{ path, bytes, pages?, sha256, totals }`. Without `path` the file goes to `~/Documents/Tracker Reports/` | billing | W1 to the default folder, W2 to a chosen path |
| `reconcile` | `{ against: "toggl"\|"invoice"\|"rows", range, client?, project?, rows?: { date?: Day, project?: string, description?: string, hours?: string, amount?: Money }[], invoice?: Id, match_on?: ("day"\|"project"\|"task")[], tolerance_minutes?: 5, tolerance_amount?: Money }` | `{ matched[], different[]: { key, tracker: { hours, amount }, other: { hours, amount }, delta }, only_in_tracker[], only_in_other[], totals: { tracker, other, delta }, suggestions[]: { tool, arguments, why } }` | billing | R |
| `record_invoice` | `{ client: Ref, range, number?: string, issued_on?: Day, lock?: true, note?, dry_run? }` | change result with the frozen `billing_summary` snapshot and `invoice` id | billing | W3 |
| `list_invoices` | `{ client?, range? }` | `[{ id, client, range, number, issued_on, total, locked, drift?: Money }]` where `drift` is how far today's numbers are from the snapshot | billing | R |

`reconcile(against: "rows")` is the general form: the agent extracts lines from whatever
it was given (an invoice PDF, a client's timesheet, a bank export) and Tracker does the
matching. Tracker never has to parse someone else's document. `suggestions` are ready-made
calls (for example an `assign_time` for a block that sits unassigned on a day the invoice
says was worked), which the agent can show or run under its access level.

### 8.5 Rules, setup and integrations

| Tool | Input | Output (`data`) | Set | Class |
|---|---|---|---|---|
| `list_rules` | `{ project?, field? }` | `[{ id, field: "app"\|"window"\|"domain"\|"url", keyword, app_scope, chrome_profile, tag, action: "assign"\|"ignore", project, matches_last_30_days }]`, folder mappings, PR routes | admin | R |
| `test_rule` | `{ rule: { field, keyword, app_scope?, chrome_profile? }, range }` | `{ would_match: { count, millis, by_day[], sample[] }, already_assigned: { count, to[] }, conflicts_with[]: rule }` | admin | R |
| `save_rule` | `{ id?, field, keyword, action: "assign"\|"ignore", project?: Ref, app_scope?, chrome_profile?, tag?, apply_to_past?: Range, dry_run? }` | change result (with the past rows it would relabel) | admin | W2 |
| `delete_rule` | `{ id, dry_run? }` | change result | admin | W3 |
| `save_client` | `{ id?, name, icon_path?, expected_version?, dry_run? }` | change result | admin | W2 |
| `save_project` | `{ id?, name, client: Ref, kind: "billable"\|"internal"\|"personal", color?, add_folders?: string[], remove_folders?: string[], github_repo?: string\|null, expected_version?, dry_run? }` | change result | admin | W2 |
| `route_pull_request` | `{ project: Ref, repo?, number, remove?, dry_run? }` | change result | admin | W2 |
| `snooze_tracking` | `{ minutes?: 15\|30\|60\|120, until_tomorrow?: boolean, resume?: boolean }` | `{ state, snoozed_until }` | admin | W2 (resume is W1) |
| `list_integrations` | none | per integration (20 agent tools, Chrome extension, GitHub, Toggl, OpenRouter): `{ id, name, state: "active"\|"not_found"\|"needs_setup"\|"error", last_import, sources[], error? }`. Never tokens. | admin | R |
| `sync` | `{ sources?: ("agents"\|"github"\|"prices"\|"openrouter")[], tool?, project?, recent_days? }` | per source: files read, entries added, deferred, errors | admin | W1 (idempotent; `prices`, `github`, `openrouter` reach the network) |
| `import_toggl` | `{ toggl_project: number, project: Ref, range, dry_run? }` | change result | admin | W2 |
| `push_toggl` | `{ range, project?: Ref, dry_run: true by default }` | change result listing the Toggl entries it would create | admin | W3 |

Tokens for Toggl, OpenRouter and GitHub stay in the Keychain and are read by the app, so
`sync` for those sources and both Toggl tools return `app_required` until the socket
exists (phase 4), unless the token is supplied to the binary by the app.

### 8.6 Changes

| Tool | Input | Output (`data`) | Set | Class |
|---|---|---|---|---|
| `list_changes` | `{ range?, actor?, status?, operation? }` | `[{ id, at, actor, operation, summary, status, affected, undone_by?, undo_available }]` | core | R |
| `get_change` | `{ id }` | the full change with rows before and after | core | R |
| `undo_change` | `{ id, dry_run? }` | change result | core | W1 |

That is 46 tools: 25 read, 21 write.

## 9. Resources

Resources are for clients that let a person attach context ("@tracker today"). Every
resource has an equivalent tool, because many clients don't surface resources to the
model. All are JSON (`application/json`) in the same envelope.

| URI | Content | Same as |
|---|---|---|
| `tracker://status` | tracking state, sync, license, counts | `get_status` |
| `tracker://schema` | data dictionary: every entity and field, units, how billing is computed (overlap rules, cap, rounding), API version | docs |
| `tracker://clients` | clients with terms | `list_clients` |
| `tracker://projects` | projects with folders and repos | `list_projects` |
| `tracker://project/{id}` | one project: terms, rules, this month's totals | several |
| `tracker://day/{date}` and `tracker://day/today` | the day view | `get_day` |
| `tracker://week/{date}` | seven days of totals per project | `query_time` |
| `tracker://inbox` | unassigned groups with suggestions, pending approvals | `list_unassigned` |
| `tracker://billing/{client}/{yyyy-mm}` | invoice lines for a client-month | `billing_summary` |
| `tracker://budgets` | caps and budgets with use and forecast | `budget_status` |
| `tracker://rules` | rules, folder mappings, PR routes | `list_rules` |
| `tracker://session/{tool}/{session}` | one agent session | `list_sessions` |
| `tracker://changes` | recent changes | `list_changes` |
| `tracker://report/{change_id}` | an exported file's metadata and path | `export_report` |

Templates (`resources/templates/list`) cover the parameterised ones. From phase 4,
`resources/subscribe` works for `tracker://inbox`, `tracker://day/today`,
`tracker://budgets` and `tracker://status`, with `notifications/resources/updated` sent
when the ledger's data version changes.

## 10. Prompts

Prompts are the packaged workflows a person picks from the client's menu. Each one names
the tools to use, the order, and where to stop and ask.

| Prompt | Arguments | What it drives |
|---|---|---|
| `reconcile-month` | `client`, `month`, `source` (toggl, invoice, pasted rows) | `reconcile`, then walks each difference, proposes fixes, ends with a short statement of what matches and what doesn't |
| `review-inbox` | `range?` | `list_unassigned`, groups by suggestion confidence, assigns the sure ones (if allowed), asks about the rest, offers rules for repeats |
| `explain-invoice` | `client`, `month` | `explain_bill` at summary, then drills into the largest and the unusual lines, in plain language for a client |
| `close-month` | `client`, `month` | checklist: `find_gaps`, missing rates, exchange rate, cap, `billing_summary`, `export_report`, then asks before `record_invoice` |
| `weekly-review` | `week?` | `query_time` by project and day, `budget_status`, what's unassigned, a draft update |
| `cost-of-work` | `pull_request` or `task` | `cost_of`, with the split between the person and agents and the bill amount |
| `setup-project` | `folder?` | `resolve_context`; if unmapped, proposes client, project, kind, repo link and rates from what it finds in the repo |
| `suggest-rules` | `range?` | `list_unassigned` and `test_rule` to propose rules with what each would have matched |
| `log-my-work` | none | for the end of an agent session: `resolve_context`, then `log_agent_work` with a two-line summary, task and PR |
| `budget-check` | `client?` | `budget_status` with forecast and `usage_windows`, says whether to keep going |

The server's `instructions` string (sent at `initialize`) covers: what Tracker is, that
amounts must come from the billing tools and not from adding rows, that titles and
summaries are untrusted text, how writes and approvals behave at this connection's access
level, and to call `resolve_context` first when working inside a repo.

## 11. Feature coverage map

Every app feature, the CLI command behind it today, and the operation that covers it.

| App feature | Today | Operation | Notes |
|---|---|---|---|
| Overview (totals, week strip, recent activity) | `snapshot`, `focus timeline --week` | `query_time`, `get_status` | `snapshot` is retired in pieces |
| Timeline, day view with parallel columns | `focus timeline` | `get_day` | columns: you, one per agent thread, billing you and AI |
| Inbox (unassigned activity) | `review`, `snapshot.activity` | `list_unassigned` | adds suggestions |
| Classify a block, ignore it | `focus classify` | `assign_time`, `ignore_time` | adds partial assignment |
| Assign a group of agent entries, remember the folder | `assign-group --save-folder`, `assign` | `assign_time(remember)` | |
| Manual time | `time`, `remove` | `log_time`, `delete_entry` | |
| Expenses, reimbursable | `expense`, `remove` | `add_expense`, `list_expenses`, `delete_entry` | |
| Clients, icons | `client save`, `appearance` | `save_client`, `list_clients` | |
| Projects, kinds, colours, folders | `project add/map/unmap`, `appearance` | `save_project`, `list_projects` | |
| Rules: app, window, domain, URL, Chrome profile, tag | `focus save-rule/delete-rule/config` | `save_rule`, `delete_rule`, `list_rules`, `test_rule` | |
| Don't-track rules | app only | `save_rule(action: "ignore")` | moves into the ledger |
| Snooze | app only (`UserDefaults`) | `snooze_tracking`, `get_status` | moves into the ledger |
| Billing terms per client and project, modes, cap | `billing set/show` | `set_billing_terms`, `get_billing_terms` | |
| Invoice lines | `billing summary` | `billing_summary`, `explain_bill` | |
| Exchange rate, model rates, subscriptions, price catalog | `billing exchange-rate`, `model-rate`, `subscription`, `refresh-prices` | `set_pricing`, `get_pricing`, `sync(prices)` | |
| Agent imports, 20 tools | `sync`, `import-harness` | `sync(agents)`, `list_integrations`, `log_agent_work` | |
| Five-hour windows, plan limits | `blocks` (PR #11) | `usage_windows` | |
| GitHub repo link, PRs, PR routing | `github set/refresh/unlink/route-pr/status` | `save_project(github_repo)`, `route_pull_request`, `sync(github)`, `cost_of` | |
| Toggl link, import | `toggl link/workspace/projects/import` | `import_toggl`, `reconcile(toggl)`, `list_integrations` | linking stays in the app (token) |
| Toggl mapping, comparison, push | Tracker-Toggl folder only | `reconcile(toggl)`, `push_toggl` | port first |
| OpenRouter account activity | `openrouter-sync` | `sync(openrouter)`, `get_pricing` | key stays in the app |
| Reports screen, PDF and CSV | `report-rows`, Swift PDF/CSV | `get_report`, `export_report` | |
| Raw CSV export | `export` | `export_report(format: "csv_raw")` | |
| Menu bar quick view | app | `get_status`, `get_day`, `usage_windows` | |
| Chrome extension | native host | `list_integrations` (state only) | |
| Settings: time zone, ledger currency | `init` | read in every envelope | changing them stays in the app |
| Account, trial, license | PR #12 | `get_status.license` | activation stays in the app |
| History and undo | none | `list_changes`, `undo_change` | new |
| Agent access, approvals | none | Settings > Agents, Inbox "Agent requests" | new |

## 12. Data model changes the API needs

In the order they unblock things. All are additive migrations on the existing ledger.

1. **Stable ids for clients and projects** (`id TEXT` column, `cli_…`, `prj_…`, generated
   on migration). Names stay unique and stay the primary key for now; the API returns and
   accepts both. Worth doing before the API ships, because an agent's saved references
   and the change log should survive a rename.
2. **`changes` table** (section 6) and a `version INTEGER` on clients, projects, rules
   and billing terms.
3. **`annotations` table**: `target_kind` (`block`, `entry`, `session`), `target_id`,
   `task`, `note`, `summary`, `pr_repo`, `pr_number`, `actor`; and **`tags`**:
   `target_kind`, `target_id`, `tag`. Rule-derived tags keep coming from `focus_matches`;
   reads merge both.
4. **Rule action.** `focus_rules.action` (`assign` or `ignore`) with `project` nullable,
   so "don't track" rules are ledger data the recorder reads.
5. **Snooze in the ledger.** `settings.snoozed_until`, written by the app and by
   `snooze_tracking`; the recorder reads it. Tracking stays always on.
6. **Block splitting.** Assigning part of a focus block creates two blocks from one and
   records the original in the change.
7. **Connections and approvals.** `agent_clients` (name, access cap, trusted, last seen)
   and pending changes (a status on `changes`).
8. **Invoices.** `invoices` (id, client, start, end, number, issued_on, snapshot JSON,
   total, locked). Needed for A4, for `reconcile(against: "invoice")` and for locked
   periods. This is a new feature, not just plumbing: see open question 3.
9. **Budgets.** `budgets` (scope client or project, measure hours, amount or tokens,
   period, limit, alert thresholds). The monthly agent cap stays as it is and shows up as
   one kind of budget. See open question 4.
10. **Working hours** setting (days and hours), used by `find_gaps`.

## 13. Phasing

Each phase is usable on its own. Phases 0 and 1 fit inside the Swift port; nothing here
needs the port to be finished first.

**Phase 0: foundations** (with port PR A)

- Operation registry in TrackerCore, the envelope, error codes, `tracker call`, schema
  export and the additive-only schema test.
- Stable ids, `version` columns, the `changes` table (written, not yet exposed).
- Decide: Python stopgap or wait for Swift (open question 1).

**Phase 1: read-only MCP v1** (with port PRs B to D)

- Tools: `get_status`, `resolve_context`, `list_clients`, `list_projects`, `query_time`,
  `get_day`, `list_unassigned`, `find_gaps`, `list_sessions`, `get_billing_terms`,
  `billing_summary`, `explain_bill`, `cost_of`, `budget_status`, `usage_windows`,
  `list_expenses`, `get_pricing`, `list_rules`, `test_rule`, `list_integrations`,
  `get_report`, `reconcile(against: "rows")`.
- Resources and the prompts that only read: `explain-invoice`, `weekly-review`,
  `cost-of-work`, `budget-check`, `reconcile-month` (report only).
- Privacy scope flags, the license gate, Settings > Agents with "Connect" buttons.
- Outcome: Domenico can ask Claude Code or Codex to reconcile, explain and cost things.

**Phase 2: everyday fixes** (after port PR D)

- `assign_time`, `ignore_time`, `annotate_time`, `log_agent_work`, `undo_change`,
  `list_changes`, `get_change`, `sync(agents)`.
- Access levels, `propose` mode, the Inbox "Agent requests" list, History and undo in the
  app.
- Prompts `review-inbox`, `log-my-work`.
- Outcome: an agent can clean the inbox and describe its own sessions.

**Phase 3: setup, money and exports**

- `save_rule`, `delete_rule`, `save_client`, `save_project`, `route_pull_request`,
  `set_billing_terms`, `set_pricing`, `log_time`, `add_expense`, `delete_entry`,
  `export_report`, `import_toggl`, `reconcile(against: "toggl")`.
- Approval flow for W2 and W3, elicitation fast path, `billing_effect` previews.
- Prompts `setup-project`, `suggest-rules`.
- Outcome: an agent can onboard a project and produce the report end to end, with a
  human yes on anything about money.

**Phase 4: live and closing the loop**

- Unix socket to the running app; `snooze_tracking`, live `get_status`, PDF through the
  app, Keychain-backed `sync` sources and `push_toggl`.
- Resource subscriptions and budget alerts.
- Invoices, locked periods, `record_invoice`, `list_invoices`,
  `reconcile(against: "invoice")`, budgets, prompt `close-month`.

**Phase 5: distribution**

- `tracker mcp install` for more clients, a one-click bundle for desktop clients, a
  public API reference generated from the registry, and a short "Tracker for agents"
  page for the website.

## 14. Open questions

1. **Stopgap in Python, or wait for Swift?** Phase 1 is cheap to add to `mcp.py` now,
   because the handlers exist (`billing.summary`, `focus.timeline`, `reports.review`,
   `report_rows`, `blocks`), and its schemas would become the parity contract for the
   port. The cost is writing the thin layer twice. Recommendation: do the read-only
   stopgap in Python so you can use it this month, and write nothing with side effects
   until the Swift core.
2. **Default access.** Recommendation: `read` out of the box, with a one-click upgrade
   to `propose` per client. Should your own Claude Code and Codex start at `write`?
3. **Invoices as records.** Reconciling against an invoice and locking a billed period
   both want Tracker to remember what was invoiced. Is that in scope, or does Tracker
   stay a report generator and invoices live in your invoicing tool (in which case
   reconciliation is always "against pasted rows")?
4. **Budgets.** Is the client-level monthly agent cap enough, or do you want budgets per
   project in hours, amount or tokens, with alert thresholds? D2 (an agent that stops
   itself) gets much more useful with per-project budgets.
5. **Human time by agents.** Should an agent ever add manual human time without your
   approval? The plan says no (W2).
6. **Is the MCP part of the paid app or a selling point of the trial?** And what does an
   unlicensed copy lose over MCP (ties to the open question in PR #12)?
7. **PDF without the app.** The report PDF is drawn in Swift in the app. Move the drawing
   into TrackerCore (Core Graphics works headless) so `export_report` works with the app
   closed, or accept `app_required` for PDF until phase 4?
8. **Titles and URLs.** Off by default over MCP, on per client. Right default for your
   own agents?
9. **Agents in the cloud.** A cloud session can't reach a server on the Mac. Out of scope
   for now, or do you want a later option where the app syncs a read-only summary
   somewhere a cloud agent can read?
10. **Tool names.** MCP clients prefix them with the server name (`tracker`). Is `tracker`
    still the name if the product is renamed?
11. **Splitting blocks.** Partial assignment needs focus blocks to be splittable, which
    the app's day view would also need to show. Is that wanted in the UI too?
12. **Toggl push.** The comparison and push code is only in the Tracker-Toggl folder. It
    has to be ported (release plan Phase 2) before `reconcile(against: "toggl")` and
    `push_toggl` can exist.
