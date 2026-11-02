# Roadmap

Next steps toward the long-term vision, roughly in the order they pay off. Each one builds on the MVP's shape: `worklog.py` does the work, and the menu bar app is a thin UI.

## 1. Evidence snapshots (pairs with the half-year archive)

TESDA transcripts are already archived until Jun 30 / Dec 31. Next, snapshot each day's *evidence* into `reports/YYYY-MM-DD.evidence.json` when a report is generated. It's tiny, it survives the purge, and it would let a semester report (IPCR-style) be rebuilt even after the archive is emptied. It also makes summaries reproducible.

## 2. Weekly and monthly shortcuts (custom ranges are done)

- Custom date ranges already work (`worklog report A..B`, and **Date range** in the window). Next: shortcuts `--week [DATE]`, `--month 2026-10`.
- Summarise from the **daily reports + manual entries**, not raw transcripts. That's smaller, already reviewed, and survives transcript cleanup. Fall back to transcripts for days without a report.
- Window: add *This week*, *Last week*, *This month* and *Range…* to the period picker.
- Prompt: group by project, then by theme (features, fixes, QA, coordination). Count deliverables, not hours.

## 3. Git commit tracking

Commits are the strongest evidence of "done", and they also catch work done without Claude.

- Config: `"git_author": "you@example.com"` and per-project repo folders (reuse `projects`).
- For the report day, run `git log --since/--until --author --no-merges --format=…` in each repo (read-only), plus `--shortstat`.
- Add a "Commits" block to the evidence. A commit counts as done even if no Claude session mentions it.
- Watch out: repos on T7 can be read only when the drive is mounted. Note "repo not available" in the report instead of failing.

## 4. Holidays and configurable workdays

- `workdays` already exists. Add `"holidays": ["2026-12-25", …]` and `"leave": [...]`.
- Optional: import Philippine regular and special non-working days from an `.ics` file once a year.
- "Previous workday" and the morning job skip holidays. A report for a holiday still works on demand.

## 5. In-app report editor

- Add an **Edit** button in the report window: a split view with Markdown on the left and the live preview on the right.
- Saving writes the `.md` and re-renders `.html`/`.txt` with `worklog render DAY` (a new command that renders without calling Claude).
- Mark edited reports (`"edited": true` in the `.json`) so **Regenerate** asks before overwriting your edits, and keep the previous version as `YYYY-MM-DD.prev.md`.

## 6. PDF and DOCX export with official TESDA templates

- **PDF:** print the styled HTML through WebKit (`WKWebView.createPDF`) from the menu bar app: **Export → PDF**. No new dependencies.
- **DOCX:** fill an official template (`templates/TESDA-accomplishment.docx`). A `.docx` is a zip of XML, so Python's `zipfile` can replace placeholders such as `{{DATE}}`, `{{NAME}}` and `{{ACCOMPLISHMENTS}}` without dependencies. Bullets need the template's list style, so keep one example paragraph in the template and clone it.
- Config: `"profile": {"name": "...", "position": "...", "office": "..."}` for header fields.
- Weekly and monthly exports reuse the same templates.

## Smaller ideas

- Show a *Needs review* section in the window, with **Add folder to project** and **Log it** buttons, so you don't have to edit JSON.
- Edit and delete manual entries from the menu (today's entries, with an undo).
- Add a **Copy section** button per project.
- Switch to native notifications (`UNUserNotificationCenter`) via a small signed `.app` bundle, so they show "TESDA Worklog" instead of *Script Editor* and clicking one opens the window.
- Keyword rules as an *optional* second signal for shared folders (e.g. sessions in `~` whose title mentions "TRACK"). They would suggest, never auto-include.
- A `worklog doctor` command that checks claude login, PATH, LaunchAgents, notification permission and transcript format in one go.
