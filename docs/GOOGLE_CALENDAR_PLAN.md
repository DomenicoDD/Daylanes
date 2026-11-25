# Google Calendar and meeting time

The optional integration reads selected Google calendars and shows accepted invitations and meetings you organize under **Scheduled meetings** in Timeline. You can connect multiple accounts. Refresh tokens and calendar selections are stored in macOS Keychain. Event details stay in memory during the app session.

## Enable Google Calendar in your build

1. Create a project in [Google Cloud Console](https://console.cloud.google.com/) under your own Google account or organization, then enable the **Google Calendar API**. [Enable Google Workspace APIs](https://developers.google.com/workspace/guides/enable-apis)
2. Under **Google Auth Platform**, set the branding and support contacts. For a personal test choose **External → Testing** and add your Google account to **Test users**. **Internal** is available when the project and users are in the same Workspace organization. External test grants for these scopes expire after seven days. [Audience setup](https://support.google.com/cloud/answer/15549945)
3. Under **Data Access**, add `https://www.googleapis.com/auth/calendar.calendarlist.readonly` for the calendar picker and `https://www.googleapis.com/auth/calendar.events.readonly` for the selected calendars' events. [Calendar scopes](https://developers.google.com/workspace/calendar/api/auth)
4. Under **Clients**, create a **Desktop app** OAuth client and download its JSON. Store the JSON outside the Git checkout. Daylanes uses the system browser, a loopback callback and PKCE. [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
5. Build with the flag enabled.

   ```sh
   TRACKER_ENABLE_GOOGLE_CALENDAR=1 ./bin/build-desktop
   open build/Daylanes.app
   ```

6. In **Settings → Integrations → Google Calendar**, select **Import Desktop OAuth client…**, choose the JSON, then click **Connect**. Approve access in the browser, choose calendars and click **Check access**. Add an accepted timed meeting to a selected calendar to verify it appears in Timeline.

For a build with a preconfigured Desktop client, set `TRACKER_GOOGLE_CALENDAR_CLIENT_FILE` to the absolute path to that JSON at build time. This packages the file inside the app. Anybody who receives that app can read the packaged file. User refresh tokens are created after individual consent and stay in Keychain. Keep the feature off for builds that should omit Calendar code and credentials.

If you distribute a Calendar-enabled build that uses your own OAuth client, review Google's branding and sensitive-scope verification requirements before distribution. Managed Workspace accounts may require their administrator to allow your OAuth client and the requested scopes. [Sensitive-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification) · [Workspace app access controls](https://knowledge.workspace.google.com/admin/apps/control-which-apps-access-google-workspace-data)

Use **Disconnect** next to an account to remove its local connection and loaded events. Revoke the account's grant entirely from [your Google Account](https://myaccount.google.com/connections).

## Roadmap for meeting time

### Sync and display accepted meetings

- Use `events.list` on selected calendars with `singleEvents=true` and a bounded rolling window. Start with the previous 30 and next 30 days. Fetch every page before replacing that calendar's snapshot in a single SQLite transaction. Keep the previous snapshot after a partial fetch, permission failure or rate limit, and show its age. Add incremental sync if volumes warrant it, with a complete resync on HTTP 410 and query parameters compatible with sync tokens. [Events list](https://developers.google.com/workspace/calendar/api/v3/reference/events/list) · [Incremental sync](https://developers.google.com/workspace/calendar/api/guides/sync)
- Start with timed, non-cancelled events where `attendees[].self` has `responseStatus: accepted`. Include timed meetings organized by the connected user when the organizer is marked `self` and the event is confirmed. Use explicit event types and ignore all-day entries, focus time, working locations and transparent events that aren't meetings. Keep scheduled times in UTC and display them in the ledger's timezone. [Event fields](https://developers.google.com/workspace/calendar/api/v3/reference/events)
- Store the connection/calendar/event key, recurring event ID, original instance time when present, RSVP, scheduled times, optional title and a local meeting-code fingerprint. Read the conference code from Google Meet `conferenceData` or a validated Meet entry point. Use a keyed local hash for matching, and keep the account roster, event descriptions, invitation URLs and meeting codes out of reports and MCP results. For duplicates across connected calendars, coalesce the same occurrence only when the event identity and scheduled interval agree. Preserve rescheduled exceptions and manual routes with a stable recurring-instance key.

### Route observed time using the calendar

- Add a **Meetings** lane to Timeline. Show the scheduled interval and let the user choose a project for an occurrence, for its series, or as a calendar default. The project supplies its client. A calendar default handles a dedicated client calendar, while a series route handles a recurring meeting on a mixed calendar.
- When Daylanes observes a confirmed normal Chrome tab on `meet.google.com`, hash its validated Meet code in memory and look up overlapping accepted events. Match by code and interval to distinguish recurring uses. Use the observed Chrome profile as context where configured. Leave unresolved or competing matches for review.
- Keep manual block assignments first. Apply a matching event's occurrence, series or calendar route ahead of a generic Meet domain rule. Keep an explicit URL rule as the fallback when calendar context is unavailable. Date matching and calendar resyncs must preserve existing confirmed allocations.
- Record this source as **observed Meet activity**, since a foreground tab can show a lobby or miss time spent elsewhere. Scheduled time stays visible even when attendance is unknown. A user can explicitly confirm an interval as meeting time. Reconcile a confirmed or attended interval against overlapping tracked activity so the same time is represented once.

### Add attendance where Google permits it

- Pilot the Meet REST API with the account that joined the call before enabling attendance sync. Request `meetings.space.readonly` for this optional feature. Look up the matching conference record by meeting code and time, then retrieve the connected user's participant sessions only. Validate how to identify the authenticated participant across Workspace and external meetings. Treat guest identities and inaccessible records as unknown. [Meet authorization](https://developers.google.com/workspace/meet/api/guides/authenticate-authorize) · [Conference lookup](https://developers.google.com/workspace/meet/api/reference/rest/v2/conferenceRecords/list) · [Participant sessions](https://developers.google.com/workspace/meet/api/guides/participants)
- Union overlapping sessions from the same person across devices, preserve gaps when they leave and rejoin, and use those intervals as **attended** time. For a 60-minute invitation with a 35-minute verified session, keep the original scheduled duration and credit 35 minutes of attendance. Import verified sessions through the same idempotent ledger path as other time sources.

### Reports, MCP and release checks

- Add calendar totals and source labels to Timeline first. Report and export confirmed or attended time alongside other human time when the project is assigned. Add read-only MCP tools for redacted meeting summaries and a write-access operation for project routing after the local flow is stable.
- Test accepted, tentative and declined invitations, an organizer-only event, external calendars, recurring instances with reused Meet codes, time-zone changes, reschedules, cancellation, pagination, multiple calendars, duplicate invites, intermittent auth and rate limits, two simultaneous meetings and repeated imports. Include one managed-account test for creating a Meet rule with a managed Chrome profile, linking a Calendar event and verifying that overlapping browser and meeting time is counted once.
