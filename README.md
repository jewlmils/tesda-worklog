# TESDA Worklog

<img src="assets/AppIcon-1024.png" width="128" alt="TESDA Worklog icon: a white octopus on blue">

A small macOS menu bar utility. Every weekday morning it gives you a report of what you did for **TESDA** on the previous workday. You can paste it into your accomplishment form.

- **Automatic:** it reads the session history that Claude Code (Claude CLI) already saves. Nothing extra runs while you work.
- **Manual notes:** a *Log something…* dialog for meetings, QA, coordination and documentation.
- **TESDA only:** only folders you list count. Anything unknown goes under *Needs review* and is never added on its own.
- **Honest summary:** your own `claude` CLI (Claude Pro, no API key) turns the evidence into concise bullets. It never invents work, and anything unfinished goes under *In progress / attempted*.
- **On demand:** **Get report now…** (⌘R) for today so far, the previous workday, any date, or a **date range** (e.g. Oct 26 – Nov 10), summarised as one report.
- **Keeps TESDA history for the half-year:** TESDA transcripts are archived until Jun 30 / Dec 31, with an alert beforehand. Other projects keep Claude Code's normal 30 days.

Python 3 (standard library only) + one Swift file + launchd. No database, server, Node, or API key.

---

## Requirements

- macOS 13 or newer (tested on macOS 26 / Apple Silicon)
- Apple Command Line Tools, for `python3` (3.9+) and `swiftc`. Check with `xcode-select -p`; install with `xcode-select --install`.
- [Claude Code](https://claude.com/claude-code), logged in with your Claude Pro account (run `claude` once and use `/login`)

## Install

```bash
cd /Volumes/T7/dev/tesda-worklog
bash install.sh
```

The installer is safe to run again. It:

1. **copies** `worklog.py` to `~/Library/Application Support/TESDA-Worklog/` and builds **`~/Applications/TESDA Worklog.app`** (the menu bar app, with the octopus icon). Nothing that runs in the background depends on the T7 drive being plugged in.
2. creates `config.json` there if it's missing (it never overwrites your edits)
3. installs the `worklog` command in `~/.local/bin`
4. links `~/Documents/TESDA-Worklog/reports` → the reports folder, so you can find your reports in Documents
5. loads two LaunchAgents: the morning report and the menu bar icon (which starts at login)

**Dock icon:** run `bash install.sh --dock` once to pin *TESDA Worklog* to the Dock, or drag it there from `~/Applications`. You can also open it from Launchpad or Spotlight. Opening it shows the report window, and the app appears in the Dock and ⌘-Tab while that window is open. The menu bar icon is always there.

**Update after a code change:** edit the files on T7, then run `bash install.sh` again.

**Uninstall:** `bash uninstall.sh` removes the app (and its Dock pin), menu bar icon, background jobs and `worklog` command, and keeps your config, notes and reports. `bash uninstall.sh --all` also deletes config and notes. Reports are never deleted.

## Set up config.json

Open it from the menu (**Settings**) or with `open ~/Library/Application\ Support/TESDA-Worklog/config.json`.

First, see which folders you've used Claude Code in:

```text
$ worklog folders
Last used   Sessions  Classified as                  Folder
2026-11-02        46  NEEDS REVIEW                   /Users/leon
2026-11-02         4  TESDA Skills Passport (TSP)    /Volumes/T7/Dev/tesda-best
2026-10-06        13  excluded                       /Volumes/T7/Dev/docfill
```

Then edit:

```json
{
  "projects": {
    "TESDA Skills Passport (TSP)": ["/Volumes/T7/Dev/tesda-best"],
    "TESDA-TRACK": ["/Volumes/T7/Dev/tesda-track"]
  },
  "exclude": ["/Volumes/T7/Dev/dailyed-android", "/Volumes/T7/Dev/docfill"],
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
| `archive_purge_dates` | When the TESDA history archive is emptied (`MM-DD`, default `["06-30", "12-31"]`). See *TESDA history*. |
| `archive_warn_days` | How many days before a purge date you get the first alert (default 7). |
| `reports_dir` | Leave empty (see *Where files live*). |

> **Tip:** the folder is decided by where you *start* `claude`. Sessions started in your home folder (`~`) can't be told apart. Your TESDA-TRACK planning and your Appetiser QA both run there, so they land under *Needs review*. Start TESDA sessions inside a TESDA folder, or log that work by hand.

## Daily use

### Menu bar (octopus icon)

| Item | What it does |
|---|---|
| **Get report now… ⌘R** | Opens the report window. Pick **Today so far**, **Previous workday**, **Pick a date**, or **Date range** (From … to …), then **Generate**. A spinner shows while Claude writes (up to a minute), and **Cancel** stops it. If a report for that day already exists, it's shown right away with its *Generated at* time. Claude isn't called again unless you click **Regenerate**. |
| **Log something… ⌘L** | One line of text + a project. It's added to that day's report and treated as true. |
| Open reports folder | Opens the reports folder in Finder. |
| Export TESDA history… | Zips the archived TESDA transcripts into the reports folder and shows the file in Finder. |
| Settings (config.json) | Opens your config. |
| Quit | Stops the icon until the next login. |

In the report window: **Copy** puts a plain-text version on the clipboard (no `#`/`**`, ready for a form, without the *Needs review* appendix). Hold **⌥ Option** while clicking to copy Markdown instead. **Open file** opens the `.md` in your editor. **Regenerate** asks Claude again.

The icon is **dimmed** while any report is being written.

### Every weekday morning

At 8:00 (or as soon as the Mac wakes up or you log in, if it was asleep or off) the report for the previous workday is written. You get a notification like *"TESDA Worklog — report ready · 4 sessions, 2 logged items · 1 to review"*, and the report window opens. If the menu bar app isn't running, the HTML report opens in your browser instead. It runs once per day at most.

### Command line

```bash
worklog report                  # previous workday (Monday → Friday)
worklog report today            # today so far
worklog report 2026-10-30       # any date; also: yesterday, prev
worklog report 2026-10-26..2026-11-10   # one report for a date range (or: 2026-10-26 --to 2026-11-10)
worklog report today --no-ai    # skip Claude: just the raw evidence
worklog report today --open     # show it in the window/browser when done
worklog log "Attended TRACK sprint planning" --project=TRACK      # partial names work
worklog log "Reviewed UAT checklist" --project=TSP --date=2026-10-30
worklog sessions [DAY]          # what was captured and how each session was classified
worklog folders                 # every folder you've used Claude Code in
worklog archive                 # TESDA history archive: size, next purge date
worklog archive export          # zip a copy into the reports folder
worklog paths                   # where everything lives
```

## TESDA history (6-month archive)

Claude Code deletes *all* transcripts after 30 days. That setting is global, so it can't treat TESDA differently. TESDA Worklog handles it like this:

- Every morning (and before every report), transcripts from your **TESDA folders** are **copied** to `~/Library/Application Support/TESDA-Worklog/archive/`. Your other projects (Appetiser, personal) aren't copied and follow Claude Code's 30 days. `~/.claude/projects` itself is only ever read.
- Reports read from both places, so you can still report any TESDA day in the current half-year.
- **7 days before** Jun 30 / Dec 31 and **on the day itself**, you get a notification plus a dialog: **Export a copy…** (zip), **Get report now…**, or **OK**. Use the time to generate any reports you need.
- **The morning after** (Jul 1 / Jan 1, or the next time the Mac is on), that half-year's archive is deleted. Your saved reports and manual entries are **never** deleted.
- The dates are in `archive_purge_dates`. `worklog archive` shows the current size and the next purge date.

Sessions under *Needs review* (for example, ones started in your home folder) aren't TESDA folders, so they aren't archived and disappear after 30 days.

## Where files live

| What | Where |
|---|---|
| Source code (edit here) | `/Volumes/T7/dev/tesda-worklog/` |
| The app (menu bar + Dock) | `~/Applications/TESDA Worklog.app` |
| Installed `worklog.py`, `config.json`, `manual_log.jsonl`, logs | `~/Library/Application Support/TESDA-Worklog/` |
| Reports: `YYYY-MM-DD.md` (ranges: `YYYY-MM-DD_to_YYYY-MM-DD.md`), `.html`, `.txt` (for Copy), `.json` (metadata) | `~/Library/Application Support/TESDA-Worklog/reports/`, also reachable as `~/Documents/TESDA-Worklog/reports` |
| LaunchAgents | `~/Library/LaunchAgents/ph.tesda.worklog.report.plist`, `ph.tesda.worklog.menubar.plist` |
| Archived TESDA transcripts (kept until Jun 30 / Dec 31) | `~/Library/Application Support/TESDA-Worklog/archive/` |
| Your Claude Code history (read-only) | `~/.claude/projects/` |

Why aren't reports stored directly in Documents? macOS privacy protection lets background jobs *create* files in `~/Documents` but stops them from *rewriting* files that another app (such as Terminal) made, so regenerating a report would fail. The app folder doesn't have that restriction. The Documents link gives you the same convenience.

## Troubleshooting

**No notification.** Notifications are sent through AppleScript, so macOS lists them under **Script Editor**. Open System Settings → Notifications → Script Editor and allow them. If a notification fails, `logs/report.log` says so.

**"couldn't find the `claude` command" / works in Terminal but not at 8 AM.** launchd starts jobs with a bare PATH. The installer adds the folder `claude` was in at install time. If you moved or reinstalled Claude Code, run `which claude`, put the result in `config.json` as `"claude_path"`, and run `install.sh` again.

**"the Claude CLI isn't logged in".** Run `claude` in Terminal and type `/login`. The report is still saved, with the raw evidence and a warning at the top. Click **Regenerate** once you're logged in.

**Usage limit reached.** Same fallback. Try again later, or use `--no-ai`.

**The T7 drive isn't mounted.** Nothing breaks: the app runs from `~/Library/Application Support`. Sessions you ran *on* T7 are still in `~/.claude/projects`, so they're still reported. You only need T7 to change the code.

**A session is under "Needs review" but it was TESDA work.** Add its folder to `projects` in config.json and regenerate. If it was in your home folder, log it by hand instead.

**The report job didn't run.**
```bash
tail -20 ~/Library/Application\ Support/TESDA-Worklog/logs/report.log
launchctl print gui/$(id -u)/ph.tesda.worklog.report | head -30
```
To run it right now: `launchctl kickstart -k gui/$(id -u)/ph.tesda.worklog.report`. It runs at most once a day. To force another run the same day, put `{}` in `state.json` in the app folder first.

**The menu bar icon is missing.** Run `launchctl kickstart -k gui/$(id -u)/ph.tesda.worklog.menubar`, or `bash install.sh`. If too many menu bar icons are crowding it out, hold ⌘ and drag icons to rearrange them.

**A TESDA day older than 30 days is missing.** Only sessions from folders listed in `projects` are archived, and only from the day the app was installed. Check with `worklog archive`. If you added a folder to config.json later, sessions older than 30 days from before that are already gone.

## Development

```bash
python3 -m unittest discover -s tests -v       # 45 tests on synthetic transcripts (tests/fixtures)
python3 tests/make_fixtures.py                 # regenerate the fixtures after editing them
swiftc -O menubar.swift -o build/TESDAWorklog  # compile check
swift assets/make_icon.swift                   # redraw the icons (AppIcon.icns, menu bar MenuIcon*.png)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it works and [docs/ROADMAP.md](docs/ROADMAP.md) for what's next. `reference/` holds the earlier prototype this was built from.
