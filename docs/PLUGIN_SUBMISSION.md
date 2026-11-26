# Submitting the Daylanes plugin

The plugin is in `plugins/daylanes`. It has two manifests: `.claude-plugin/plugin.json` for Claude and `.codex-plugin/plugin.json` for OpenAI. To have the directories pick up a release, bump `version` in both.

## What ships where

| How someone gets it | Skills (Diary, time and costs) | MCP server |
| --- | --- | --- |
| Claude directory listing | Yes | No. The directory accepts local MCP servers only from Verified organizations. |
| `claude plugin install daylanes@daylanes` from this repo | Yes | Yes, added by the entry in `.claude-plugin/marketplace.json` |
| `codex plugin marketplace add DomenicoDD/Daylanes` | Yes | Yes, through `codex.mcp.json` |
| Daylanes' **Connect an agent** dialog, or `claude mcp add` / `codex mcp add` | No | Yes |

The MCP server is always the `TrackerCLI mcp` that ships inside Daylanes.app. The skills reach the same data by running `TrackerCLI` in the agent's shell. They work wherever the agent can run commands directly on the Mac, such as Claude Code and Codex. Cowork runs commands in a Linux sandbox that cannot start Daylanes.app, so Cowork needs the MCP server (untested yet). On claude.ai web and mobile chat there is no Mac shell, so the skills can only say that Daylanes is needed.

When the organization becomes Verified, move the `mcpServers` entry from `.claude-plugin/marketplace.json` back into `plugins/daylanes/.claude-plugin/plugin.json`, bump `version`, and push. The listing picks up the new version for review.

Before you submit, try the repo install on a Mac with Daylanes installed:

```sh
claude plugin marketplace add DomenicoDD/Daylanes
claude plugin install daylanes@daylanes
# In Claude Code: /mcp shows "daylanes" connected. Then ask "write my Daylanes diary".
```

## Claude directory (plugin bundle)

Needs a Pro, Max, Team or Enterprise account, and a GitHub account with push access to DomenicoDD/Daylanes.

1. Open https://claude.ai/directory/manage and choose **Submit new → Plugin bundle**.
2. **Source:** Repository `DomenicoDD/Daylanes`, Plugin path `plugins/daylanes`, Branch `main`. Click **Validate**. Install the Claude GitHub App if asked. If it still shows the old findings, click **Re-validate** so it reads the latest `main`.
3. **Listing details** come from `plugin.json` and the plugin README (read-only).
4. **Data handling:**
   - Reads or stores personal data: **Yes**. It reads the local Daylanes ledger (project and client names, hours, agent usage, costs, Diary briefs and entries), and the Diary skill saves drafts into it. Everything stays on the Mac.
   - Sends data to other services: **No**. The skills make no network requests. What the agent reads becomes part of the conversation with Claude.
   - Retention: the plugin keeps nothing. Data stays in the user's local Daylanes ledger until the user deletes it.
   - Intended for under 18: **No**.
5. **Compliance:** contact email `support@daylanes.app`, and accept the four acknowledgements.
6. **Review and submit:** updates by **GitHub push webhook**. Leave **Auto-publish passing versions** off for the first release, then click **Submit for review**.

What to expect:
- Validation should pass with no Blocks.
- The listing may show Cowork too, but there the skills only work alongside the MCP server.
- The safety scan reads the skills. They run only `TrackerCLI` commands, and the README discloses every one of them.

## OpenAI (Codex and ChatGPT desktop)

There are two routes.

**Now, no review:** anyone can install the plugin from this repository:

```sh
codex plugin marketplace add DomenicoDD/Daylanes
```

Then install **Daylanes** from the plugins list in the ChatGPT desktop app or Codex. You can put this line on the website.

**Public plugin directory:** OpenAI accepts local (stdio) MCP plugins only from approved partners.

1. In https://platform.openai.com/settings/organization/general, complete individual verification (publishing as Domenico Marco Di Donna) and copy the organization ID.
2. Ask OpenAI to allowlist the organization for desktop-only local MCP plugins, through an OpenAI representative or developer support. Include the org ID, a link to the repo and one line on what the plugin does.
3. Once allowlisted: https://platform.openai.com/plugins → **Create plugin → Skills only → Upload ZIP**. Make the ZIP from inside `plugins/daylanes`:
   `cd plugins/daylanes && zip -r ../../daylanes-plugin.zip . -x '.claude-plugin/*'`
4. Fill in the review details: 5 positive and 3 negative test prompts, a short demo video URL, and release notes. The positive prompts could be:
   - "how many hours on <client> this week"
   - "what did my agents cost this month"
   - "what agent work has no project"
   - "write my Daylanes diary"
   - "draft invoice lines for last month"

   Reviewer credentials are not needed. Reviewers need a Mac with Daylanes. Point them to the free build at daylanes.app/download with sample data, or describe the demo video.

   The negative prompts could be:
   - weather questions
   - "delete all my projects" (refused without write access)
   - a request about a project that does not exist

Without allowlisting, the only option is a skills-only listing with no MCP. You can't add MCP to it later: OpenAI doesn't support adding an MCP server to an existing skills-only plugin. So wait for the allowlist rather than submitting a skills-only version first.
