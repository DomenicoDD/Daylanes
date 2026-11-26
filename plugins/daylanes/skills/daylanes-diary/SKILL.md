---
name: daylanes-diary
description: Write or refresh the Daylanes project Diary (a daily standup-style entry per project) on this Mac. Use when the user asks to write their diary, daily log, standup or work summary for a Daylanes project, or for "yesterday" in Daylanes.
---

# Write the Daylanes Diary

Daylanes is a local time tracker on the user's Mac. Each project can have a Diary: one entry per workday, written by an agent from the evidence it can reach (Git history, pull requests, chats, calendar, notes) and saved back into Daylanes. Daylanes decides which workday is due and what time window it covers; you gather the evidence and write the entry.

Everything here runs on the Mac through the command-line tool inside Daylanes.app. Nothing is sent to Daylanes' servers.

## 1. Find the command-line tool

Use the first of these that exists and call it `DAYLANES` below:

1. `/Applications/Daylanes.app/Contents/MacOS/TrackerCLI`
2. `~/Applications/Daylanes.app/Contents/MacOS/TrackerCLI`
3. The app that `mdfind "kMDItemCFBundleIdentifier == 'com.domenicodidonna.tracker'"` returns, plus `/Contents/MacOS/TrackerCLI`

If none exists, tell the user that the Diary needs the Daylanes Mac app (https://daylanes.app/download) and stop. Quote the path when you run it.

## 2. Pick the diary

Run `DAYLANES diary list`. It prints a JSON array of the diaries the user has set up, each with `project`, `client`, `routine_id` and the project's `folders`.

- If the user named a project, use that one.
- Otherwise use the diary whose `folders` contain the current working directory.
- If several still fit, ask the user which project they mean. Never guess between clients.
- If the list is empty, tell the user to open Daylanes, choose **Diary → Set up diary…** for the project, and save it. You cannot create a diary yourself.

## 3. Follow the guide

Run `DAYLANES diary guide ROUTINE_ID` and follow what it prints, step by step. The guide is the contract: it contains the user's brief for this project, the workday naming rules, how to read the due workday with `diary work`, the entry format, and how to save it by piping JSON to `diary submit`. The commands it prints already include the right paths.

Rules that always apply:

- Only use evidence from inside the window that `diary work` returns. Use the user's own words and facts; do not invent progress, names or numbers.
- Leave out secrets, credentials, personal data about other people and anything the brief asks you to skip.
- If `diary submit` reports a conflict or a newer revision, run `diary work` again and resubmit on top of it; the user's own edits in Daylanes are kept.
- When you are done, tell the user the work date you wrote and the headline, and that they can review or edit it in Daylanes → Diary.
