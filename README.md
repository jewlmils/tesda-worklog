# TESDA Worklog

<img src="assets/AppIcon-1024.png" width="128" alt="TESDA Worklog icon: a white octopus on blue">

A small macOS menu bar and Dock app. Every weekday morning it gives you a report of what you did for **TESDA** on the previous workday, ready to paste into your accomplishment form.

- **Automatic:** it reads the session history that Claude Code (Claude CLI) already saves. Nothing extra runs while you work.
- **Git commits:** commits *you* made in your TESDA repos count as proof of finished work, even without Claude.
- **Manual notes:** a *Log something…* dialog for meetings, QA, coordination and documentation, for TSP, TRACK, *General TESDA work*, or any project name you type.
- **TESDA only:** only folders you list count. Anything unknown goes under *Needs review* and is never added on its own.
- **Honest summary:** your own `claude` CLI (Claude Pro, no API key) turns the evidence into concise bullets. It never invents work, and anything unfinished goes under *In progress / attempted*.
- **On demand:** **Get report now…** for today so far, the previous workday, any date, or a **date range** picked on a mini calendar and written day by day.
- **Keeps TESDA history for the half-year:** TESDA transcripts are archived until Jun 30 / Dec 31, with an alert beforehand. Other projects keep Claude Code's normal 30 days.

Built with Python 3 (standard library only), two small Swift files and launchd. No database, server, Node, or API key. **macOS only** for now (see [docs/ROADMAP.md](docs/ROADMAP.md) for Windows).

---

## Requirements

- macOS 13 or newer (developed on macOS 26, Apple Silicon)
- **Apple Command Line Tools**, which provide `git`, `python3` (3.9+) and `swiftc`. Install them with `xcode-select --install`.
- **[Claude Code](https://claude.com/claude-code)**, logged in with your Claude Pro account (run `claude` once and type `/login`)

## Install

```bash
git clone https://github.com/<your-username>/tesda-worklog.git ~/dev/tesda-worklog
cd ~/dev/tesda-worklog
bash install.sh --dock        # --dock also pins the app to your Dock (leave it out if you don't want that)
```

The source folder can be anywhere: an external drive, `~/dev`, and so on. The installer **copies** what it needs, so nothing that runs in the background depends on that folder. It:

1. builds **`~/Applications/TESDA Worklog.app`** (menu bar + Dock app, octopus icon)
2. copies `worklog.py` to `~/Library/Application Support/TESDA-Worklog/` and creates `config.json` there if it's missing (it never overwrites your edits; new settings are added)
3. installs the `worklog` command in `~/.local/bin`
4. links `~/Documents/TESDA-Worklog/reports` → the reports folder
5. loads two LaunchAgents: the morning report and the menu bar app (which starts at login)

**Update:** `git pull`, then `bash install.sh` again.
**Uninstall:** `bash uninstall.sh` removes the app (and its Dock pin), background jobs and `worklog` command. It keeps your config, notes and reports. `bash uninstall.sh --all` also deletes config and notes. Reports are never deleted.

## Set up config.json

Open it from the menu (**Settings**) or with `open ~/Library/Application\ Support/TESDA-Worklog/config.json`. First, see which folders you've used Claude Code in:

```text
$ worklog folders
Last used   Sessions  Classified as                  Folder
2026-11-02         4  TESDA Skills Passport (TSP)    /Volumes/T7/Dev/tesda-best
2026-11-02        46  NEEDS REVIEW                   /Users/you
2026-10-06        13  excluded                       /Volumes/T7/Dev/docfill
```

Then edit:

```json
{
  "projects": {
    "TESDA Skills Passport (TSP)": ["/Volumes/T7/Dev/tesda-best"],
    "TESDA-TRACK": ["~/dev/tesda-track"]
  },
  "exclude": ["/Volumes/T7/Dev/docfill"],
  "workdays": ["Mon", "Tue", "Wed", "Thu", "Fri"],
  "report_time": "08:00",
  "model": "sonnet"
}
```

| Key | Meaning |
|---|---|
| `projects` | Report name → list of folders. Sub-folders count too, and upper/lower case doesn't matter. The most specific folder wins. |
| `exclude` | Folders that are never TESDA work. They're skipped silently. |
| *(anything else)* | Listed under **Needs review** at the bottom of the report and never summarised. |
| `workdays` | Which days are workdays. "Previous workday" skips the others, so Monday covers Friday. |
| `report_time` | When the morning report runs. **Re-run `install.sh` after changing it.** |
| `model` | Passed to `claude --model`. `sonnet` is fast and good at this. |
| `claude_path` | Full path to `claude`, if it can't be found automatically. |
| `open_report` | `false` = notification only; the report window doesn't open in the morning. |
| `git_tracking` | `true` (default): also read commits you made in the git repos inside your project folders (read-only, any branch, not stashes). |
| `git_authors` | Extra author emails that are you, e.g. a work address (`["you@tesda.gov.ph"]`). Your repo's `git user.email` is always included. |
| `git_repos` | Repos that aren't inside a project folder, per project: `{"TESDA-TRACK": ["~/dev/track-api"]}`. |
| `archive_purge_dates` / `archive_warn_days` | When the TESDA history archive is emptied (default `["06-30", "12-31"]`) and how many days ahead you're warned (default 7). |
| `reports_dir` | Leave empty (see *Where files live*). |

> **Tip:** a session's folder is where you *started* `claude`. Sessions started in your home folder (`~`) mix all kinds of work, so they land under *Needs review*. Start TESDA sessions inside a TESDA folder, or log that work by hand.

## Daily use

### Menu bar (octopus icon) and Dock

| Item | What it does |
|---|---|
| **Get report now… ⌘R** | Opens the report window. Choose **Today so far**, **Previous workday**, **Pick a date**, or **Date range**, then **Generate**. A spinner shows while Claude writes (up to a minute), and **Cancel** stops it. If that report already exists, it's shown right away with its *Generated at* time; Claude isn't called again unless you click **Regenerate**. |
| **Log something… ⌘L** | One line of text + a project. It's added to that day's report and treated as true. The project box lists your config projects, **General TESDA work**, and names you've typed before. You can also **type a new name** (e.g. *Regional Office Support*). It autocompletes and preselects the last project you used. |
| Open reports folder | Opens the reports folder in Finder. |
| Export TESDA history… | Zips the archived TESDA transcripts into the reports folder. |
| Settings (config.json) | Opens your config. |
| Quit | Stops the app until the next login (or until you open it from the Dock). |

- **Date range:** choosing it opens a two-month mini calendar (◀ ▶ to move). Click the first day, then the last; the days between are highlighted. The 📅 button changes the range later. A range report is written **day by day**: one section per date, projects inside each date. Workdays with nothing captured say so, and weekends appear only if you worked.
- **Report window buttons:** **Copy** puts a plain-text version on the clipboard (no `#`/`**`, without the *Needs review* appendix), ready for a form. Hold **⌥ Option** to copy Markdown instead. **Open file** opens the `.md` in your editor. **Regenerate** asks Claude again.
- **Dock:** clicking the octopus in the Dock (or opening it from Launchpad/Spotlight) opens the report window. The app shows in the Dock and ⌘-Tab only while that window is open.
- **Busy indicator:** the menu bar icon is **dimmed** while any report is being written.

### Every weekday morning

At 8:00 (or as soon as the Mac wakes up or you log in, if it was asleep or off) the report for the previous workday is written. You get a notification like *"TESDA Worklog — report ready · 4 sessions, 2 logged items · 1 to review"*, and the report window opens. If the app isn't running, the HTML report opens in your browser instead. It runs once per day at most.

### Command line

```bash
worklog report                          # previous workday (Monday → Friday)
worklog report today                    # today so far
worklog report 2026-10-30               # any date; also: yesterday, prev
worklog report 2026-10-26..2026-11-10   # a date range, day by day (or: 2026-10-26 --to 2026-11-10)
worklog report today --no-ai            # skip Claude: just the raw evidence
worklog report today --open             # show it in the window/browser when done
worklog log "Attended TRACK sprint planning" --project=TRACK        # partial names of config projects work
worklog log "Monthly staff meeting" --project="General TESDA work"
worklog log "Set up the training room projector" --project="Regional Office Support"   # new names are fine
worklog log "Reviewed UAT checklist" --project=TSP --date=2026-10-30
worklog sessions [DAY]                  # what was captured and how each session was classified
worklog commits [DAY or A..B]           # your git commits in the project repos
worklog folders                         # every folder you've used Claude Code in
worklog archive [export]                # TESDA history archive: status, or zip a copy
worklog paths                           # where everything lives
```

## Git commits

Commits are the strongest evidence that something is *done*, and they cover work you did without Claude. For every project folder, TESDA Worklog finds its git repo(s):
- a folder that is a repo, or is inside one (a sub-folder only counts commits touching it)
- a parent folder: the repos inside it
- anything in `git_repos`

It then reads the commits **you** authored on the report day(s), by author date in local time. It reads all local and remote branches, skipping merges and stashes. Matching uses your repo's `user.email` plus `git_authors`.

They're listed as evidence, and Claude turns them into plain-language accomplishments. A commit can also show that something a Claude session left unfinished was completed later. Everything is read-only (`git log` / `git config`). A repo on an unplugged drive is skipped, with a note at the bottom of the report. **How to check it's working:**
- The summary line (notification, window status, CLI) says e.g. *"4 sessions, 0 logged items, **4 commits** · 2 to review"*.
- Every report ends with a **Commits used** table (time, project, commit + hash, branch, changes). Like *Sessions used*, it isn't part of what Copy puts on the clipboard.
- `worklog report DAY --no-ai` shows the raw evidence, including a **Git commits** list per project.
- `worklog commits DAY` lists the repos it searches and the commits it finds.

## TESDA history (6-month archive)

Claude Code deletes *all* transcripts after 30 days, and that setting is global. So TESDA Worklog handles it like this:

- Every morning (and before every report), transcripts from your **TESDA folders** are **copied** to the app's `archive/` folder. Other projects aren't copied and follow Claude Code's 30 days. `~/.claude/projects` itself is only ever read.
- Reports read from both places, so you can still report any TESDA day in the current half-year.
- **7 days before** Jun 30 / Dec 31 and **on the day itself**, you get a notification plus a dialog with **Export a copy…**, **Get report now…** and **OK**.
- **The morning after**, that half-year's archive is deleted. Your reports and logged entries are **never** deleted.

Only sessions in configured TESDA folders are archived, starting from the day you install.

## Set up on another Mac

Each Mac reads **its own** Claude Code history. A Mac's reports only include sessions run on that Mac, plus whatever you log there.

1. Install the requirements: `xcode-select --install`, then [Claude Code](https://claude.com/claude-code), then run `claude` once and `/login`.
2. Clone and install (see **Install** above).
3. **Optional: bring your settings and notes over.** On the old Mac, copy these from `~/Library/Application Support/TESDA-Worklog/`: `config.json`, `manual_log.jsonl`, and `reports/` if you want old reports. Put them in the same folder on the new Mac (AirDrop, iCloud Drive, or a USB drive), then run `bash install.sh` again. Check the folder paths in `config.json`, because projects may live elsewhere on the new Mac.
4. Run `worklog folders`, adjust `config.json`, and try `worklog report today`.
5. Allow notifications for **Script Editor** when macOS asks (System Settings → Notifications).

## Where files live

| What | Where |
|---|---|
| Source code (edit here, `git pull` here) | wherever you cloned it |
| The app (menu bar + Dock) | `~/Applications/TESDA Worklog.app` |
| Installed `worklog.py`, `config.json`, `manual_log.jsonl`, `state.json`, logs | `~/Library/Application Support/TESDA-Worklog/` |
| Reports: `YYYY-MM-DD.md` (ranges: `START_to_END.md`), plus `.html`, `.txt` (for Copy), `.json` (metadata) | `~/Library/Application Support/TESDA-Worklog/reports/`, also at `~/Documents/TESDA-Worklog/reports` |
| Archived TESDA transcripts | `~/Library/Application Support/TESDA-Worklog/archive/` |
| LaunchAgents | `~/Library/LaunchAgents/ph.tesda.worklog.report.plist`, `ph.tesda.worklog.menubar.plist` |
| Your Claude Code history (read-only) | `~/.claude/projects/` |

Why aren't reports stored directly in Documents? macOS privacy protection lets background jobs *create* files in `~/Documents` but stops them from *rewriting* files that another app (such as Terminal) made. The app folder doesn't have that restriction, and the Documents link keeps them easy to find.

## Troubleshooting

**No notification.** Notifications are sent through AppleScript, so macOS lists them under **Script Editor**: System Settings → Notifications → Script Editor → allow. If a notification fails, `logs/report.log` says so.

**"couldn't find the `claude` command" / works in Terminal but not at 8 AM.** launchd starts jobs with a bare PATH. The installer adds the folder `claude` was in at install time. If you moved or reinstalled Claude Code, run `which claude`, put the result in `config.json` as `"claude_path"`, and run `install.sh` again.

**"the Claude CLI isn't logged in" / usage limit reached.** Run `claude` in Terminal and `/login`, or try again later. The report is still saved, with the raw evidence and a warning. Click **Regenerate** when it's fixed.

**The source drive isn't mounted.** Nothing breaks: the app runs from `~/Applications` and `~/Library/Application Support`. You only need the source folder to update.

**A session is under "Needs review" but it was TESDA work.** Add its folder to `projects` in config.json and regenerate. If it was in your home folder, log it by hand instead.

**The Dock or menu bar shows an old or blank icon.** Run `killall Dock`. For the menu bar: `launchctl kickstart -k gui/$(id -u)/ph.tesda.worklog.menubar`.

**The report job didn't run.**
```bash
tail -20 ~/Library/Application\ Support/TESDA-Worklog/logs/report.log
launchctl print gui/$(id -u)/ph.tesda.worklog.report | head -30
```
To run it right now: `launchctl kickstart -k gui/$(id -u)/ph.tesda.worklog.report`. It runs at most once a day; to force another run the same day, remove `"last_scheduled"` from `state.json` in the app folder first.

**A TESDA day older than 30 days is missing.** Only sessions from folders listed in `projects` are archived, and only from install day onwards. Check with `worklog archive`.

## Development

```bash
python3 -m unittest discover -s tests -v       # 57 tests on synthetic transcripts (tests/fixtures)
python3 tests/make_fixtures.py                 # regenerate the fixtures after editing them
swiftc -O menubar.swift -o build/TESDAWorklog  # compile check (install.sh builds the real app)
swift assets/make_icon.swift                   # redraw the icons (AppIcon.icns, menu bar MenuIcon*.png)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it works and [docs/ROADMAP.md](docs/ROADMAP.md) for what's next. `reference/` holds the first prototype.
