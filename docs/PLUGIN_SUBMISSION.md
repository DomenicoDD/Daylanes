# Submitting the Daylanes plugin

The plugin lives in `plugins/daylanes` and has two manifests: `.claude-plugin/plugin.json` for Claude and `.codex-plugin/plugin.json` for OpenAI. Bump `version` in both for each release you want the directories to pick up.

Before either submission: merge the plugin PR on `main`, deploy the website so https://daylanes.app/privacy has the "AI agents you connect" section, and try the plugin on a Mac with Daylanes installed:

```sh
claude plugin marketplace add DomenicoDD/Daylanes
claude plugin install daylanes@daylanes
# in Claude Code: /mcp shows "daylanes" connected; ask "write my Daylanes diary"
```

## Claude directory (plugin bundle)

Needs a Pro, Max, Team or Enterprise account, and a GitHub account with push access to DomenicoDD/Daylanes.

1. Open https://claude.ai/directory/manage and choose **Submit new → Plugin bundle**.
2. **Source:** Repository `DomenicoDD/Daylanes`, Plugin path `plugins/daylanes`, Branch `main`. Click **Validate**. Install the Claude GitHub App if asked.
3. **Listing details** come from `plugin.json` and the plugin README (read-only).
4. **Data handling:**
   - Reads or stores personal data: **Yes**. It reads the local Daylanes ledger (project and client names, hours, agent usage, costs, Diary briefs and entries), and the Diary skill saves drafts into it. Everything stays on the Mac.
   - Sends data to other services: **No**. The plugin makes no network requests. What the agent reads is part of the conversation with Claude.
   - Retention: the plugin keeps nothing. Data stays in the user's local Daylanes ledger until the user deletes it.
   - Intended for under 18: **No**.
5. **Compliance:** contact email `support@daylanes.app`, and accept the four acknowledgements.
6. **Review and submit:** updates by **GitHub push webhook**. Leave **Auto-publish passing versions** off for the first release, then click **Submit for review**.

The directory takes local MCP servers and scripts only from Verified organizations, so the directory folder holds skills only. The skills run `TrackerCLI` through the agent's own shell. The repo's Claude marketplace (`.claude-plugin/marketplace.json`) adds the MCP server for people who install from the repository. If the organization becomes Verified, the MCP server can move back into `plugin.json`. The listing will show Claude Code and Cowork. Chat on claude.ai, desktop and mobile ignores local MCP servers, but the skills still load there. Without the app, the skills just say Daylanes is needed.

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
