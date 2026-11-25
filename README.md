# Daylanes

Daylanes is a local Mac app, CLI, and MCP server for consultant time, agent usage, and costs. It reads the history of Codex, Claude Code, OpenCode and 17 other coding agents on the Mac and stores the reporting metadata in SQLite.

The source is available under the [MIT License](LICENSE). The [official Mac installer](https://daylanes.app/download) includes a 14-day free trial. A licence costs **$29 during the trial** or **$49 afterward**, with 12 months of updates and activation on up to two Macs.

## Open the Mac app

On macOS 14 or later, with Xcode or Apple Command Line Tools installed:

```sh
./bin/build-desktop
open build/Daylanes.app
```

The default build is free to use and requires no checkout or licence key. Both features below are off by default and can be enabled independently when compiling.

| Build flag | Effect when set to `1` |
|---|---|
| `TRACKER_ENABLE_PAYMENTS` | Adds the trial, Polar licensing and checkout. The official `bin/release` build enables it. See [Polar setup](docs/POLAR_SETUP.md) to use your own Polar organization and checkout worker. |
| `TRACKER_ENABLE_GOOGLE_CALENDAR` | Adds read-only Google Calendar. Use your own Google Cloud Desktop OAuth client. See [Google Calendar setup](docs/GOOGLE_CALENDAR_PLAN.md#enable-google-calendar-in-your-build). |

This repository provides the macOS app, CLI, MCP server, browser extension, and optional checkout Worker. The project website has its own repository. See [CONTRIBUTING](CONTRIBUTING.md) to build and send changes, and [SECURITY](SECURITY.md) to report a vulnerability.

The app opens to **Timeline** and imports recent local transcripts on launch. The sidebar holds **Timeline**, **Diary**, **Review**, **Reports**, **Overview**, **Clients** and **Projects**, followed by your projects grouped by client. The tracking pill in the toolbar shows what Daylanes is tracking; click it to snooze tracking for a while. The refresh button (⌘R) imports new activity while the app is open. On Review, Overview and project pages, the period selector switches between this and last week or month.

- **Timeline** shows auto-tracked and Toggl time for a day or week, with agent activity for the day. Use **Rules…** to route future time to projects.
- **Review** groups unassigned agent activity by recorded folder, branch, and provider. Assign a group to a project, or save a folder rule to apply to all unassigned activity in that folder and its descendants. You can move already assigned groups and keep individual exceptions.
- **Overview** shows human time, agent activity, actual expenses and estimated API costs for the selected period. The **Today** panel previews one timeline lane at a time with **You**, **Codex** and **Claude** tabs. **Open** jumps to today’s Timeline. Connected AI providers show spend or usage for the selected period, with API-key assignments on project and client pages.
- **Clients** lists every client with its period time, agent tokens and API equivalent; open one to see its projects. **Projects** lists projects grouped by client, with a client filter. New projects choose a client first; client work requires one, internal and personal projects may have none.
- Projects also appear in the sidebar under their client, or under Internal and Personal. Use the **+** button below the sidebar to create a project or client, and right-click a client to rename it or add a project. A project page shows its totals, GitHub pull requests and agent activity; its toolbar menu logs time and expenses, edits the project and links a GitHub repository.
- **Settings** (⌘,) opens the standard macOS Settings window with **General**, **Integrations**, **AI costs** and **Privacy** tabs. General controls automatic tracking and tracking rules. Privacy shows your ledger location and explains how Daylanes handles external requests and credentials.
- **Export CSV** saves usage, time, estimates, and expenses for the selected period. Export from a project or client to restrict the file to that scope. The export carries separate rows and fields for human time, agent runtime, model usage, estimates, and actual expenses, including whether an expense is reimbursable.

### Subscriptions and API value

Open **Settings → AI costs** to enter a provider, plan name and monthly fee. The same section lets you refresh OpenRouter reference prices and set manual per-model rates.

**API equivalent** estimates what the tracked uncached input, cache reads, cache writes and output would cost at current [OpenRouter catalog base rates](https://openrouter.ai/docs/api/api-reference/models/get-models). Daylanes fetches the public catalog without an API key or any usage data. The desktop app checks for new rates when it imports usage and the cache is more than a day old. The last successful download is available offline. Historical usage is valued at those cached rates. Requests with an unmatched model or a missing token rate are counted as unpriced. Quotes exclude tool fees, long-context surcharges, cache duration premiums, and provider-specific routing prices. CSV puts the reference model and estimate in `openrouter_model` and `api_equivalent_usd`, separate from manually priced estimates and logged expenses.

Enter the fee you actually pay in the ledger currency, including regional pricing as applicable. The subscription list shows current monthly fees regardless of the report dates; choose **This month** for a month-to-date usage comparison. OpenRouter estimates stay in USD. [Codex can use a ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) and [Claude Code can use a Claude plan](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-max-or-ultra-plan), but those tools can also accrue usage charges. The transcript's model name alone does not tell Daylanes how a run was paid for. Subscription fees are account-wide, and estimates include only tracked runs. Record actual invoices or overages as expenses when needed.

### Billing

Set rates with **Billing rates…** on a client (every project uses them) or on a project (blank fields use the client's). Personal and internal work belongs to your own client and is never billed.

- **Your time**: hours × your hourly rate. Time on different projects can overlap, so an hour switching between two projects bills two hours. Overlapping records inside one project count once.
- **Agents**: choose *Time* (agent hours × the agent rate; parallel threads each bill their running time), *Usage* (the API-credit value at OpenRouter rates × a markup, converted with the USD exchange rate in Settings → AI costs), *Time + usage* (both lines), or *Not billed*.
- **Monthly cap** (client): agent lines never add up to more than this in a calendar month. A week inside a capped month bills its proportional share.

The Timeline day view shows **Billing · you** and **Billing · AI** columns, Overview and client pages show invoice lines, and the CSV export ends with `invoice` rows. From the CLI: `tracker billing set --client Acme --human-rate 90 --agent-mode hybrid --agent-rate 25 --markup 1.3`, `tracker billing exchange-rate 0.92`, `tracker billing summary --period month`.

### OpenRouter account activity

In **Settings → Integrations → OpenRouter**, enter a management key with activity access. Daylanes stores the key in macOS Keychain and refreshes account totals on launch and when you click Refresh. Usage shows reported USD spend, requests and tokens by model for the selected dates within the last 30 completed UTC days. A workspace-scoped key shows its workspace's activity. The last successful sync is available offline. **Manage → Disconnect** removes the key and clears the cache. [OpenRouter management keys](https://openrouter.ai/settings/management-keys) · [Activity API](https://openrouter.ai/docs/api/api-reference/analytics/get-user-activity-grouped-by-endpoint)

Account activity can include requests already tracked by OpenCode or another harness. You can see the account figures in Usage and in the unfiltered CLI and MCP reports. Project totals and CSV exports use the existing local ledger records. OpenRouter reports usage spend in USD, while credit purchase fees and direct provider invoices are handled separately. For terminal syncs, supply `OPENROUTER_MANAGEMENT_KEY` through your environment and run `./bin/tracker openrouter-sync`. [OpenRouter billing](https://openrouter.ai/pricing)

### AI provider usage

Open **Settings → Integrations → AI provider usage**, connect a provider, then expand **Assign API keys to projects** where available. A key's synced usage follows the assigned project to its client. Existing records in the synced period follow changes to that assignment as well. Daylanes refreshes the last 30 completed UTC days on launch and refresh, and keeps the last successful sync available offline. Provider usage appears in Overview and in the native CLI and MCP usage reports. It is tracked independently of logged expenses and of the OpenRouter-priced agent estimates used for invoicing. Provider sync uses GET requests only. Higgsfield, Replicate and Ollama Cloud use standard API credentials for these reads.

| Provider | What Daylanes can read | How to connect and assign |
| --- | --- | --- |
| OpenRouter | Reported spend, requests and tokens by model | Use a management key with activity and API-key listing access. Project keys come from that key's workspace, or the default workspace for an organization key. [Activity](https://openrouter.ai/docs/api/api-reference/analytics/get-user-activity-grouped-by-endpoint) · [Key listing](https://openrouter.ai/docs/api/api-reference/api-keys/list-api-keys) |
| fal | Model API usage and costs after discounts | Use a `BILLING` key. Daylanes lists keys by name and matches usage to their IDs. [Usage](https://fal.ai/docs/platform-apis/v1/models/usage) · [Key permissions](https://fal.ai/docs/documentation/model-apis/authentication/key-based#permissions) |
| Higgsfield | Completed API generations and estimated USD cost | Enter a dedicated Console key ID and secret. The usage API is documented under Enterprise. Assign keys after they appear in the usage results, and give them recognizable names in Daylanes. Consumer credits are managed separately. [Usage](https://docs.higgsfield.ai/docs/enterprise/usage-and-billing) · [API billing terms](https://open.higgsfield.ai/terms-of-service) |
| Replicate | Account or organization prediction counts and available processing time by model | Enter an account or organization token. The prediction list provides neither billed amounts nor token-level attribution. [Prediction API](https://replicate.com/docs/reference/http#predictions.list) · [Billing](https://replicate.com/docs/topics/billing/) |
| Ollama Cloud | Personal account usage by model and included or purchased credit balances | Enter a cloud API key. Usage value can include the plan allowance and purchased credits. Ollama lists API-key breakdowns as forthcoming. Local Ollama runs on your hardware. [Usage](https://docs.ollama.com/api/cloud-usage) · [Balance](https://docs.ollama.com/api/balance) |

OpenCode is already supported through its local session history and folder-to-project mapping. For example, a session routed through OpenRouter can appear as local agent activity and as reported provider spend for the same call. [OpenCode providers](https://opencode.ai/docs/providers/)

### GitHub

Open **Settings → Integrations → GitHub → Project repositories** and link an `owner/repo` to a project. Daylanes uses your existing GitHub CLI sign-in (`gh auth login`) to read metadata for up to 150 pull requests, including closed ones. Open the project in the sidebar to see its **Pull requests** to see the cached titles and states. Use **Manage → Refresh pull requests** after opening a new PR. [GitHub CLI sign-in](https://cli.github.com/manual/gh_auth_login)

- **Agent usage** uses the recorded working directory's local Git remote and the branch when available. Daylanes assigns unclassified usage to a uniquely connected project and links the PR when exactly one cached, same-repository PR matches the recorded branch. Manual assignments take precedence, followed by explicit PR routes, mapped folders, and the repository default. An existing folder mapping can also supply repository context when the recorded checkout is unavailable.
- **Human time** uses the foreground Chrome tab while Activity tracking is enabled. GitHub time follows the connected repo or PR unless a custom activity rule applies. The timeline shows the repo or PR link. Daylanes records the repo and PR number, and does not need the full page URL in the ledger.
- **Shared repositories** can connect to multiple Daylanes projects. In a project's **Pull request routing**, enter a PR number to send matching activity to that project. A shared repo has no default project. Configure a PR route or use the review queue when Daylanes has no other assignment.

Repository and PR numbers are included in CSV exports. Agent attribution is recalculated for existing imports when routing changes. Browser rules apply to new captures, and existing timeline blocks can be reassigned from Timeline.

### Toggl Track

Open **Settings → Integrations → Toggl Track** and enter the API token from your Toggl Track profile. Daylanes saves it in macOS Keychain. Choose **Import time**, a Toggl project, a Daylanes project and up to 31 days. Daylanes reads your completed entries that started in that range and includes their time in Usage, project reports and CSV exports. For older dates, Daylanes queries the workspace's detailed report filtered to your account and the selected project. Reimporting the same project and range reconciles those entries. Imported time adds to other logged time, including overlapping automatic tracking. Disconnecting removes the token and keeps imported time. [Toggl Track authentication](https://engineering.toggl.com/docs/authentication/) · [Toggl Track time-entry history](https://engineering.toggl.com/docs/tracking/) · [Toggl detailed reports](https://engineering.toggl.com/docs/track/reports/detailed_reports/)

### Local data

Daylanes stores its ledger on this Mac and has no hosted workspace or cross-device sync. Integration requests go directly to their providers. Daylanes stores Toggl and AI provider credentials in macOS Keychain, outside the ledger and CSV exports. The desktop app, CLI and MCP server share the same SQLite ledger, which defaults to `~/.local/share/tracker/ledger.sqlite3`. You can set `TRACKER_DB` to select a different ledger or pass `--db` to the CLI. The desktop app sets the reporting timezone from macOS if the ledger has no timezone. Daylanes stores reporting metadata in the ledger. Diary also stores your project briefs, entries and reference links there. Source conversations and their connections stay with the chosen agent.

## CLI and MCP

The CLI is `TrackerCLI` inside the app (`Daylanes.app/Contents/MacOS/TrackerCLI`). From the checkout, run `bin/build-desktop` once, then use `./bin/tracker` as below.

```sh
./bin/tracker init --timezone Europe/Rome --currency EUR
./bin/tracker project add 'Website redesign' --client Acme --kind billable --folder /path/to/website
./bin/tracker project add 'Side project' --kind personal --folder /path/to/side-project
./bin/tracker project map 'Website redesign' /path/to/worktree
./bin/tracker github set 'Website redesign' owner/repo
./bin/tracker github refresh 'Website redesign'
./bin/tracker github route-pr 'Website redesign' 42
./bin/tracker time 'Website redesign' --minutes 35 --activity reviewing --task WEB-42
./bin/tracker expense 'Website redesign' 'fal asset generation' --amount 8.50 --task WEB-42 --reimburse
./bin/tracker sync --recent-days 14
./bin/tracker refresh-prices --if-stale
./bin/tracker subscription set 'Claude Pro' --monthly 20.00
./bin/tracker report
./bin/tracker review
./bin/tracker export --period month --project 'Website redesign' > monthly-costs.csv
```

Use `--start` and `--end` for an explicit date range. Start is inclusive, end is exclusive, and both use the reporting timezone. Manual time and expenses can be backdated with `--at`. `entries` lists record IDs, `assign` corrects imported attribution, and `remove` deletes manual entries. Report by client, project, or task with `--client`, `--project`, or `--task`.

`sync` reads local and archived Codex sessions, Claude Code project history and OpenCode's local SQLite history, including subagent sessions. The desktop app imports the last 64 days on launch and refresh. For Codex and Claude Code the filter uses file modification dates and reads matching files in full. For OpenCode it uses message dates. Run `sync` without `--recent-days` for older history. Claude Code history is read from both `~/.config/claude/projects` and `~/.claude/projects`, or from each folder in a comma-separated `CLAUDE_CONFIG_DIR`. Use `--codex-dir` or `--claude-dir` to specify another transcript directory. Use `--rescan` to read unchanged files again, for example to pick up agent time and long-context prices for history imported by an earlier version.

OpenCode works with the app closed. Daylanes opens its SQLite history in read-only mode and reads model IDs, token totals, timestamps and working folders. It looks under `~/.local/share/opencode` (or `$XDG_DATA_HOME/opencode`) for `opencode.db` and channel databases and respects `OPENCODE_DB`. To use a custom file, run `./bin/tracker sync --provider opencode --opencode-db /path/to/opencode.db`. OpenCode can print the path with `opencode debug paths db`. Remote-only sessions need their own source. [OpenCode CLI paths](https://opencode.ai/docs/cli)

Codex duration measures elapsed turns. Claude Code duration comes from the conversation: a span starts at your prompt and runs through the agent's replies and tool calls until your next prompt or a pause of more than 5 minutes (subagents add tokens, not extra time). OpenCode duration estimates the model request window when both timestamps are available. API-credit values use OpenRouter's long-context prices for requests whose prompt passes the model's threshold (for example 272K tokens on recent GPT models). `blocks` groups agent usage into five-hour windows like the plan limits, with burn rate and a projection to the reset; the menu bar shows the open window. The window times are estimates from the local logs. Agent work can overlap human time or other agents. Set separate manual token estimates in the ledger currency using `model-rate HARNESS MODEL --input AMOUNT --cached AMOUNT --cache-write AMOUNT --output AMOUNT`. List current fees with `subscription list` or delete a plan with `subscription remove NAME`.

### Other agents

`sync` also reads these agents' local history, with the same read-only approach. Each reads from its default folder, or from a comma-separated list in the variable shown:

| Agent | Default location | Override |
| --- | --- | --- |
| Amp | `~/.local/share/amp/threads` | `AMP_DATA_DIR` |
| Antigravity | `~/.gemini/antigravity*/conversations/*.db` | `ANTIGRAVITY_DATA_DIR` |
| Cline (VS Code, Cursor, Windsurf, VSCodium and CLI) | editor `globalStorage/saoudrizwan.claude-dev`, `~/.cline` | `CLINE_DATA_DIR` |
| Codebuff | `~/.config/manicode*` | `CODEBUFF_DATA_DIR` |
| DeepSeek Harness | `~/.dsh/sessions` | `DSH_HOME` |
| Droid | `~/.factory/sessions` | `DROID_SESSIONS_DIR` |
| Gemini CLI | `~/.gemini/tmp/*/chats` | `GEMINI_DATA_DIR` |
| GitHub Copilot CLI | `~/.copilot/session-state` | `COPILOT_HOME` |
| Goose | `~/.local/share/goose/sessions/sessions.db` | `GOOSE_PATH_ROOT` |
| Grok Build | `~/.grok/sessions` | `GROK_HOME` |
| Hermes Agent | `~/.hermes/state.db` | `HERMES_HOME` |
| Kilo | `~/.local/share/kilo/kilo.db` | `KILO_DATA_DIR` |
| Kimi | `~/.kimi`, `~/.kimi-code` | `KIMI_DATA_DIR` |
| OpenClaw | `~/.openclaw` (and its older names) | `OPENCLAW_DIR` |
| pi | `~/.pi/agent/sessions` | `PI_AGENT_DIR` |
| Qwen Code | `~/.qwen/projects` | `QWEN_DATA_DIR` |
| ZCode | `~/.zcode/cli/db/db.sqlite` | `ZCODE_HOME` |

The formats follow [ccusage](https://github.com/ryoppippi/ccusage)'s adapters (MIT). Where a tool records what a request cost (OpenClaw, pi, Cline, Kilo, Hermes, Grok, GitHub Copilot credits, older Claude Code logs), Daylanes uses that figure; otherwise it prices the tokens. Forked, archived and migrated copies of a request count once. OpenClaw agents work outside a repository, so their entries carry the agent's folder (`~/.openclaw/agents/<agent>`), or `…/channels/<channel>` for a session from a channel such as Telegram: add either folder to a project to bill that agent or channel to it.

Pricing also covers 1-hour cache writes, fast, flex and ultrafast speed tiers, web searches and long-context rates. Codex's own plan usage (its 5-hour and weekly windows) appears in `blocks` and the menu bar. Codex's compressed `.jsonl.zst` logs are read with a zstd decoder built into the app.

### Other harnesses

Harnesses can use several models and billing routes in one session. For example, OpenCode supports OpenRouter and API key or OAuth connections. Daylanes groups by the harness and prices each model independently when it can match the recorded ID to the OpenRouter catalog. For tools without a built-in importer, use an adapter to write a JSON object per request to a JSONL file, then run `./bin/tracker import-harness my-agent < usage.jsonl` with your harness ID. [OpenCode providers](https://opencode.ai/docs/providers) · [OpenCode authentication](https://opencode.ai/docs/cli/providers/)

```json
{"id":"req-42","timestamp":"2026-11-16T09:00:00Z","model":"anthropic/claude-opus-4.6","input":1200,"cached":300,"cache_write":0,"output":230,"folder":"/path/to/project","branch":"feature/example"}
```

Use the resolved `author/model` catalog ID for each request. Supply nonoverlapping token counts: `input` is only the uncached portion, and `output` includes reasoning tokens if they are billed as output. Missing token fields count as zero. `folder`, `branch` and `session` are optional; folder mappings and the review queue work as usual. Use a stable request ID unique within the harness so reimporting updates the existing record. The importer only stores reporting fields; it does not need prompts, API keys, or account access. For requests actually routed through OpenRouter, [generation metadata](https://openrouter.ai/docs/api/api-reference/generations/get-generation) can supply per-request charges for a future billing integration.

Register the MCP server with an absolute path to the engine's command line, which `bin/build-desktop` puts inside the app:

```sh
tracker_cli="$(pwd)/build/Daylanes.app/Contents/MacOS/TrackerCLI"
codex mcp add tracker -- "$tracker_cli" mcp
claude mcp add --scope user --transport stdio tracker -- "$tracker_cli" mcp
```

The server runs locally over stdio and reads the ledger directly, so it works with the app closed. Read access includes projects, rules, the installed app catalog, activity and billing reports. Some data is also available as `tracker://` resources. Turn on **Allow project and rule setup** in Daylanes’ **Connect an agent** dialog or start the server with `--access write` to let an agent set up clients, projects, folder mappings and tracking rules. For example, the agent can find Xcode with `list_installed_apps` and map the returned app identifier to a project with `create_tracking_rule`. Rules set up this way appear in **Timeline → Rules**. `--toolsets core,billing,admin,setup` trims the list, and `--db` or `TRACKER_DB` selects another ledger. Results become available to the connected agent and can be included in its model context. See [MCP queries](docs/MCP_QUERIES.md) for example calls.

## Project diary

Open **Diary → Project routines**, choose a project and a writing agent, then save the prefilled brief or customize its sources and format. Set when the workday starts and which time zone it uses. Choose a run time or **First morning availability**. For example, with a 05:00 cutoff in Europe/Rome, Wednesday at 03:15 is part of Tuesday’s diary. A run at 03:00 drafts Tuesday through 03:00 and refreshes the same entry from 05:00.

Open the setup disclosure and run the generated MCP registration command with the selected CLI. Start a dedicated local Codex or Claude Code conversation in the project folder. Give the agent access to the chats, GitHub contributions, Slack channels, calendar or meeting notes your prompt calls for. Paste the generated standing instruction into that conversation once. The project’s MCP connection exposes just two tools. The instruction uses `get_diary_work` to fetch the latest brief and due draft, then `submit_diary_entry` to save the result.

For recurring runs, enter the local conversation UUID, the project folder and the full CLI path (from `command -v codex` or `command -v claude`) in Daylanes. Choose **Enable local schedule**. macOS resumes the conversation when a workday is due and checks for missed work on wake or sign-in, including when Daylanes is closed. Verify your conversation can use its required tools without prompting. If a run fails, check the status in **Project routines** and the agent’s local conversation. Use **Turn off schedule** before changing the conversation or moving the app. For a one-off backfill, ask the registered agent to fetch and write a specific work date.

In Diary, select the work date, client and project. **Copy** copies the filtered standup. **Edit** changes the displayed wording. Later agent refreshes update any untouched fields and keep your edits.

See [the Diary MCP contract](docs/MCP_QUERIES.md#write-a-project-diary) for payload fields and retry behavior.

## Automatic human time

Tracking is always on once you choose **Start tracking** on the welcome screen. There is no pause: to step away, click the tracking pill or the clock in the menu bar and choose **Snooze** for 15, 30, 60 or 120 minutes or until tomorrow. A countdown shows how long is left, and tracking resumes by itself; **Resume** ends a snooze early. To leave an app, window or site out for good, add a **Do Not Track** rule. Close the window to leave Daylanes running in the menu bar. For startup at login, choose **Settings → General → Open at login**. macOS manages that preference under Login Items. [Apple Login Items API](https://developer.apple.com/documentation/servicemanagement/smappservice)

Daylanes records time in the foreground app and closes the current block after two minutes without input. It starts a fresh block when you return and pauses for sleep and inactive login sessions. The idle threshold can include brief periods away or undercount stretches of reading.

### Route time with keywords

Open **Timeline → Rules** to view or edit your saved rules. Choose **New rule…** to create one. Each project also shows its own rules under **Settings → Tracking rules**. In the editor, choose **App**, **Window title**, or **Website**. Choose **Track** to pick a project and an optional CSV tag. **Do Not Track** keeps the app and duration in **Ignored** and excludes the time from project totals and review.

- Choose an installed app to match its macOS bundle identifier. Use **Browse…** in the picker for an app stored elsewhere, or **Match by app name** for a partial name match. [Apple bundle identifiers](https://developer.apple.com/documentation/appkit/nsrunningapplication/bundleidentifier)
- Window rules match part of the title. Use **Only in app** to select an installed app when the title rule should apply there. Window titles need macOS Accessibility permission. [Apple Accessibility attributes](https://developer.apple.com/documentation/applicationservices/carbon_accessibility/attributes)
- For browser rules, open Google Chrome and choose **Allow Automation**. A domain like `example.com` includes its subdomains. A URL prefix like `https://app.example.com/portal` matches the same origin and that path or its descendants. Queries and fragments are ignored. Add an optional **Chrome window** name to scope a rule, such as `Client Mail` or `Personal Mail` for two Gmail windows. In Chrome, right-click an empty part of the tab bar and select **Name window**. [Chrome window naming](https://support.google.com/chrome/answer/2391819)

For a domain or URL rule, **Chrome profile** lists the Google Chrome profiles on this Mac. Grant Daylanes macOS Accessibility access so it can match a Chrome window to the selected profile. When Chrome supplies the profile name and Daylanes can identify it uniquely, **Create tab rule** selects it automatically. The **Extension label…** option works with labels you set in the [Chrome extension](chrome-integration/README.md).

While tracking, **Timeline → Last Chrome tab** appears when the last observed tab needs a rule or has competing rules. **Create tab rule** starts a domain rule from the tab, and **Review rules** opens the rules list. Manage existing rules from **Timeline → Rules**. Use **New project** from the sidebar's + button or the plus next to Project in the rule editor to create a project immediately.

Daylanes reads the active tab in a foreground Chrome window and skips Incognito URLs. [Chrome scripting dictionary](https://chromium.googlesource.com/chromium/src.git/%2B/lkgr/chrome/browser/ui/cocoa/applescript/scripting.sdef) · [macOS Automation consent](https://developer.apple.com/videos/play/wwdc2019/701/?time=1007)

**Do Not Track** takes precedence when it matches alongside other rules. Among **Track** rules, URL rules take precedence over domain rules, then window and app rules. Window rules scoped to an installed app take precedence over app-name scopes and unscoped window rules. App rules for a selected app take precedence over partial app-name rules. Among rules that match text at the same priority, the longer match wins. Equally specific rules with different destinations leave the block in review. Changes apply to future captures. Daylanes saves rule text and tags. Raw window titles and visited addresses are used in memory. Chrome window names are labels you choose. They do not reveal the signed-in Chrome profile or Gmail mailbox. Gmail compose recipients or actions require a separate integration with its own permissions. [Chrome profile identity API](https://developer.chrome.com/docs/extensions/reference/api/identity) · [Gmail compose metadata](https://developers.google.com/workspace/add-ons/gmail/extending-compose-ui)

Use **Timeline → Week** to view auto-tracked and Toggl time in a Monday-to-Sunday calendar. Select a day in the calendar to open its detailed timeline. The daily timeline lists auto-tracked blocks and imported Toggl Track entries together. Each row names its source, and the day overview gives each source its own lane so overlaps stay visible. Use the menu on auto-tracked rows to assign, ignore, restore, or create an app rule. Toggl entries show the Daylanes project selected during import. The **Agent activity** section shows imported runtime and tokens by project or unassigned folder. Project totals and CSV use finished assigned blocks. A time entry crossing midnight appears on both days, split at the reporting boundary. Manual and imported time add to auto-tracked time.

## Verify

```sh
python3 -m unittest discover -s tests -v
focus_checks_dir="$(mktemp -d)"
xcrun swiftc desktop/ChromeTabs.swift desktop/FocusRules.swift desktop/FocusSession.swift tests/FocusSessionChecks.swift -o "$focus_checks_dir/check"
"$focus_checks_dir/check"
xcrun swiftc -parse-as-library desktop/ReportBuilder.swift desktop/ReportCSV.swift desktop/ReportData.swift \
  desktop/ReportOptions.swift desktop/ReportStrings.swift desktop/ReportPDF.swift tests/ReportChecks.swift -o "$focus_checks_dir/reports"
"$focus_checks_dir/reports"
xcrun swiftc -parse-as-library core/*.swift tests/CoreChecks.swift -o "$focus_checks_dir/core"
"$focus_checks_dir/core"
xcrun swiftc -parse-as-library core/*.swift tests/MCPChecks.swift -o "$focus_checks_dir/mcp"
"$focus_checks_dir/mcp"
xcrun swiftc -parse-as-library core/*.swift tests/DiaryChecks.swift -o "$focus_checks_dir/diary"
"$focus_checks_dir/diary"
xcrun swiftc -parse-as-library core/HTTP.swift desktop/GoogleCalendarAPI.swift desktop/GoogleCalendarAccountStore.swift \
  desktop/GoogleCalendarCallback.swift tests/GoogleCalendarChecks.swift -o "$focus_checks_dir/calendar"
"$focus_checks_dir/calendar"
node --test server/checkout/tests/worker.test.mjs
# After bin/build-desktop: run the ported commands through both engines and diff the results.
python3 tests/parity.py build/Daylanes.app/Contents/MacOS/TrackerCLI --ledger ~/.local/share/tracker/ledger.sqlite3
```

### Swift engine

The engine is Swift (`core/`). `core/` has no UI code: an operation registry (`Engine.call`) that the
app, the `TrackerCLI` binary and the MCP server all call. `CLI.run` takes the arguments of the former
Python engine and prints the same output, and the app calls it in process. The app doesn't use or
ship Python.

`tracker/` and the Python tests are kept only as the reference for `tests/parity.py`, which runs the same
commands through both engines on copies of a ledger and diffs the output, the requests sent to a local
fixture server, and every table.
`TrackerCLI call <operation> --json '{…}'` runs an operation directly, and
`TrackerCLI api schema` lists them.
