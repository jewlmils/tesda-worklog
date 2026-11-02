# TESDA Worklog (MVP)

A small Mac helper. Every weekday at 8 AM it shows you what you did for TESDA the day before.

## How it works
1. **Claude CLI work is picked up automatically.** Claude Code already saves your sessions in `~/.claude/projects`, so nothing extra runs while you work.
2. **Anything else you log yourself.** Use the menu bar icon → *Log something…* for meetings, QA, coordination and so on.
3. **Weekdays at 8:00 AM** (or as soon as your Mac wakes up), it collects the previous workday's TESDA sessions and your logged items. It then asks your own `claude` CLI to write clean accomplishment bullets. This runs on your Pro plan, so there's no API key and no extra cost. You get a notification and the report opens.
4. Reports are saved in `reports/YYYY-MM-DD.md`. Edit them freely.

Only folders you list in `config.json` count as TESDA work. Folders you exclude (Appetiser, personal) are skipped. Any other folder shows up under **Needs review** and is never added to the report on its own.

## Install
```bash
cd ~/TESDA-Worklog
bash install.sh
python3 worklog.py folders     # shows every folder you've used Claude in
open config.json               # put your TESDA folders under "projects"
python3 worklog.py report      # try it now (previous workday)
```

## Commands
| Command | What it does |
|---|---|
| `python3 worklog.py report [DATE]` | Build a report (default: previous workday; also `today`, `2026-10-30`) |
| `python3 worklog.py report --no-ai` | Same, but just the raw list with no AI |
| `python3 worklog.py log "Did X" --project="TESDA-TRACK"` | Add a manual entry from the terminal |
| `python3 worklog.py sessions [DATE]` | See which sessions were found and how each was classified |
| `bash uninstall.sh` | Remove the background jobs |

## Good to know
- Claude Code deletes sessions after **30 days** by default. To keep history longer for monthly reports, add `"cleanupPeriodDays": 365` to `~/.claude/settings.json`.
- The first time, macOS may ask you to allow notifications for "Script Editor". Allow it.
- Background job log: `logs/report.log`.
