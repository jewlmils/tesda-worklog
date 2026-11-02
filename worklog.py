#!/usr/bin/env python3
"""
TESDA Worklog: turns your Claude Code history and your own notes into a daily
accomplishment report for TESDA.

  worklog report [prev|today|yesterday|YYYY-MM-DD] [--no-ai] [--open] [--json]
  worklog report 2026-10-26..2026-11-10        one report for a date range
  worklog log "Attended TRACK sprint planning" [--project=NAME] [--date=YYYY-MM-DD]
  worklog sessions [DAY]     what was captured that day and how it was classified
  worklog folders            every folder you've used Claude Code in
  worklog projects           project names from config.json
  worklog paths              where everything lives

DAY defaults to "prev" (the previous workday, so Monday -> Friday) for
`report`, and "today" for `sessions`.

Python 3 standard library only. ~/.claude/projects is only ever read.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import date, datetime, time as dtime, timedelta
from pathlib import Path

APP_NAME = "TESDA-Worklog"


def _env_path(var, default):
    value = os.environ.get(var)
    return Path(os.path.expanduser(value)) if value else default


# Everything the app writes lives here, NOT on the external drive (see docs/ARCHITECTURE.md).
DATA_DIR = _env_path("WORKLOG_HOME", Path.home() / "Library" / "Application Support" / APP_NAME)
CLAUDE_PROJECTS = _env_path("WORKLOG_CLAUDE_PROJECTS", Path.home() / ".claude" / "projects")
CONFIG_PATH = DATA_DIR / "config.json"
MANUAL_LOG = DATA_DIR / "manual_log.jsonl"
STATE_PATH = DATA_DIR / "state.json"
RUNNING_PATH = DATA_DIR / "running.json"   # exists while a report is being written (menu bar dims)
INBOX = DATA_DIR / "inbox"                 # "show this report" requests for the menu bar app
DEFAULT_REPORTS = DATA_DIR / "reports"     # ~/Documents/TESDA-Worklog/reports links here (see install.sh)
OLD_DEFAULT_REPORTS = "~/Documents/TESDA-Worklog/reports"
ARCHIVE = DATA_DIR / "archive"             # copies of TESDA transcripts, kept until the half-year purge

APPENDIX_MARK = "<!-- appendix: not part of the report you submit -->"
WEEKDAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

DEFAULT_CONFIG = {
    "_help": [
        "projects: report name -> list of folders. Sub-folders count too. Matching ignores upper/lower case.",
        "exclude: folders that are never TESDA work (Appetiser, personal...). They are skipped silently.",
        "Any other folder is listed under 'Needs review' and is NEVER added to the report automatically.",
        "Run `worklog folders` to see every folder you've used Claude Code in.",
        "workdays: which days count as workdays (the report covers the previous one).",
        "report_time: when the morning report runs (24h). Re-run install.sh after changing it.",
        "archive_purge_dates: TESDA transcripts are copied to the app's archive (so they outlive Claude Code's "
        "30-day cleanup) and deleted the morning after these dates (MM-DD). You're alerted archive_warn_days before.",
        "reports_dir: leave empty. Reports are then kept in the app folder, and ~/Documents/TESDA-Worklog/reports "
        "links to them (macOS blocks background jobs from rewriting files in Documents).",
    ],
    "projects": {
        "TESDA Skills Passport (TSP)": [],
        "TESDA-TRACK": [],
    },
    "exclude": [],
    "workdays": ["Mon", "Tue", "Wed", "Thu", "Fri"],
    "report_time": "08:00",
    "reports_dir": "",
    "model": "sonnet",
    "claude_path": "",
    "claude_timeout_seconds": 300,
    "open_report": True,
    "archive_purge_dates": ["06-30", "12-31"],
    "archive_warn_days": 7,
}

FILE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}

# Bash commands worth showing as evidence (commits, tests, builds, deploys).
NOTABLE_COMMAND = re.compile(
    r"""\b(
        git\s+(commit|push|merge|tag|cherry-pick|revert)
      | gh\s+(pr|release)\s+(create|merge)
      | (npm|pnpm|yarn|bun)\s+(run\s+)?(test|build|lint|deploy|e2e|typecheck)\b
      | npx\s+(jest|vitest|playwright|tsc|eslint|cypress|expo|eas)
      | pytest | jest | vitest | phpunit | rspec
      | python3?\s+-m\s+(pytest|unittest)
      | go\s+(test|build) | cargo\s+(test|build)
      | (\./)?gradlew\s | gradle\s
      | xcodebuild | swift\s+(build|test) | swiftc
      | flutter\s+(test|build) | fastlane | eas\s+(build|submit|update)
      | php\s+artisan\s+(test|migrate) | composer\s+test
      | docker(\s+compose)?\s+(build|push|up) | kubectl\s+apply | terraform\s+apply
      | firebase\s+deploy | vercel\b | netlify\s+deploy | serverless\s+deploy
      | make\b
    )""",
    re.IGNORECASE | re.VERBOSE,
)

# Bash commands that change files without the Edit/Write tools (common in auto mode).
SHELL_EDIT = re.compile(
    r"""(\bsed\s+(-[a-zA-Z]+\s+)*-i | \bperl\s+-[a-zA-Z]*i | \bpython3?\s+-\s*<< | \bcat\s+>[^&]
      | (^|[;&|]\s*)tee\s | \bgit\s+apply | \bapply_patch | \bpatch\s+-p)""",
    re.IGNORECASE | re.VERBOSE,
)

# User "prompts" that are really Claude Code plumbing, not something you typed.
NOISE_PREFIXES = (
    "<command-", "<local-command", "<system-reminder", "<task-notification", "<bash-",
    "<user-memory", "Caveat:", "[Request interrupted", "[Image", "Base directory for this skill",
)


class WorklogError(Exception):
    """An error with a message that is safe and useful to show the user."""


# ---------------------------------------------------------------- config

def load_config(path=None):
    path = Path(path or CONFIG_PATH)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(DEFAULT_CONFIG, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    try:
        user = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as ex:
        raise WorklogError(f"{path} has a syntax error on line {ex.lineno}: {ex.msg}. "
                           "Fix it (a missing comma or quote is the usual cause) and try again.")
    if not isinstance(user, dict):
        raise WorklogError(f"{path} should contain a JSON object.")
    cfg = dict(DEFAULT_CONFIG)
    cfg.update(user)
    projects = cfg.get("projects") or {}
    if not isinstance(projects, dict):
        raise WorklogError('"projects" in config.json must look like {"Name": ["/folder", ...]}.')
    cfg["projects"] = {str(k): ([v] if isinstance(v, str) else list(v or [])) for k, v in projects.items()}
    excl = cfg.get("exclude") or []
    cfg["exclude"] = [excl] if isinstance(excl, str) else list(excl)
    cfg["_workdays"] = parse_workdays(cfg.get("workdays"))
    return cfg


def parse_workdays(value):
    days = set()
    for v in value or []:
        if isinstance(v, int) and 0 <= v <= 6:
            days.add(v)
        elif isinstance(v, str) and v.strip()[:3].lower() in WEEKDAYS:
            days.add(WEEKDAYS.index(v.strip()[:3].lower()))
        else:
            raise WorklogError(f'Unknown workday {v!r} in config.json. Use names like "Mon" or "Friday".')
    return days or {0, 1, 2, 3, 4}


def configured_reports_dir(cfg):
    custom = cfg.get("reports_dir") or ""
    return _env_path("WORKLOG_REPORTS", Path(os.path.expanduser(custom)) if custom else DEFAULT_REPORTS)


def reports_dir(cfg):
    """Folder for reports. Falls back to the app folder if a custom folder can't be written."""
    wanted = configured_reports_dir(cfg)
    try:
        wanted.mkdir(parents=True, exist_ok=True)
        probe = wanted / ".write-test"
        probe.write_text("ok")
        probe.unlink()
        return wanted, None
    except OSError as ex:
        DEFAULT_REPORTS.mkdir(parents=True, exist_ok=True)
        return DEFAULT_REPORTS, f"Couldn't write to {wanted} ({ex.strerror}); saved in {DEFAULT_REPORTS} instead."


# ---------------------------------------------------------------- folders -> projects

def _norm(p):
    return os.path.normpath(os.path.expanduser(str(p)))


def under(path, folder):
    """True if path is folder or inside it. Case-insensitive, like the macOS disk."""
    path, folder = _norm(path).casefold(), _norm(folder).casefold().rstrip("/")
    return path == folder or path.startswith(folder + "/")


def classify(cwd, cfg):
    """Returns ("project", name), ("exclude", None) or ("review", None). The most specific folder wins."""
    best, best_len = ("review", None), -1
    for name, folders in cfg["projects"].items():
        for f in folders:
            if under(cwd, f) and len(_norm(f)) > best_len:
                best, best_len = ("project", name), len(_norm(f))
    for f in list(cfg["exclude"]) + [str(DATA_DIR)]:
        if under(cwd, f) and len(_norm(f)) >= best_len:   # a tie goes to exclude: safer
            best, best_len = ("exclude", None), len(_norm(f))
    return best


def label_of(cwd, cfg):
    kind, name = classify(cwd, cfg)
    return name if kind == "project" else ("excluded" if kind == "exclude" else "NEEDS REVIEW")


# ---------------------------------------------------------------- dates

def previous_workday(today, workdays):
    d = today - timedelta(days=1)
    for _ in range(7):
        if d.weekday() in workdays:
            return d
        d -= timedelta(days=1)
    return today - timedelta(days=1)


def resolve_day(arg, cfg, today=None):
    today = today or date.today()
    a = (arg or "prev").strip().lower()
    if a in ("prev", "previous", "workday", "last"):
        return previous_workday(today, cfg["_workdays"])
    if a == "today":
        return today
    if a == "yesterday":
        return today - timedelta(days=1)
    try:
        return date.fromisoformat(a)
    except ValueError:
        raise WorklogError(f"I don't understand the day {arg!r}. Use today, prev, yesterday or YYYY-MM-DD.")


def local_time(ts):
    """Claude Code timestamps are UTC ISO strings like 2026-10-30T01:02:03.456Z."""
    if not isinstance(ts, str) or not ts:
        return None
    s = ts.strip().replace("Z", "+00:00")
    s = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], s, count=1)  # py3.9 wants 6 digits
    try:
        t = datetime.fromisoformat(s)
    except ValueError:
        return None
    if t.tzinfo is None:
        return t
    return t.astimezone().replace(tzinfo=None)   # naive local time


def pretty_day(day):
    return f"{day:%A}, {day:%B} {day.day}, {day.year}"


MAX_RANGE_DAYS = 366


def pretty_period(start, end=None):
    """'Monday, November 2, 2026' for one day; 'October 26 – November 10, 2026' for a range."""
    end = end or start
    if start == end:
        return pretty_day(start)
    if start.year != end.year:
        return f"{start:%B} {start.day}, {start.year} – {end:%B} {end.day}, {end.year}"
    if start.month != end.month:
        return f"{start:%B} {start.day} – {end:%B} {end.day}, {end.year}"
    return f"{start:%B} {start.day} – {end.day}, {end.year}"


def period_key(start, end=None):
    """File name stem: 2026-11-02, or 2026-10-26_to_2026-11-10 for a range."""
    end = end or start
    return start.isoformat() if start == end else f"{start.isoformat()}_to_{end.isoformat()}"


def resolve_period(arg, cfg, today=None):
    """'prev', 'today', a date, or a range 'YYYY-MM-DD..YYYY-MM-DD'. Returns (start, end)."""
    today = today or date.today()
    a = (arg or "prev").strip()
    if ".." in a:
        left, right = (x.strip() for x in a.split("..", 1))
        start, end = resolve_day(left, cfg, today), resolve_day(right or "today", cfg, today)
        if end < start:
            start, end = end, start
        if (end - start).days + 1 > MAX_RANGE_DAYS:
            raise WorklogError(f"That range is {(end - start).days + 1} days; the maximum is {MAX_RANGE_DAYS}.")
        return start, end
    d = resolve_day(a, cfg, today)
    return d, d


def _when(t_start, t_end=None, ranged=False):
    span = f"{t_start:%H:%M}" + (f"–{t_end:%H:%M}" if t_end is not None else "")
    return f"{t_start:%a %b} {t_start.day} {span}" if ranged else span


# ---------------------------------------------------------------- manual entries

GENERAL_PROJECT = "General TESDA work"   # for TESDA work that isn't part of a specific project


def logged_projects():
    """Project names used in manual entries, most recently used first."""
    seen = []
    if MANUAL_LOG.exists():
        for line in reversed(MANUAL_LOG.read_text(encoding="utf-8").splitlines()):
            try:
                p = json.loads(line).get("project")
            except (ValueError, AttributeError):
                continue
            if p and p not in seen:
                seen.append(p)
    return seen


def log_choices(cfg):
    """What the Log dialog offers: config projects, General, then names you've typed before."""
    out = list(cfg["projects"]) + [GENERAL_PROJECT]
    keys = {n.casefold() for n in out}
    for p in logged_projects():
        if p.casefold() not in keys:
            out.append(p)
            keys.add(p.casefold())
    return out


def match_project(name, cfg):
    """Configured or previously used project with that name (any case), a unique partial match of a
    configured project ("track" -> "TESDA-TRACK"), or else a NEW project with exactly that name."""
    names = list(cfg["projects"])
    name = " ".join((name or "").split())
    if not name:
        return names[0] if names else GENERAL_PROJECT
    for n in log_choices(cfg):
        if n.casefold() == name.casefold():
            return n
    partial = [n for n in names if name.casefold() in n.casefold()]
    if len(partial) == 1:
        return partial[0]
    return name


def add_manual(text, project, cfg, on_day=None):
    text = " ".join((text or "").split())
    if not text:
        raise WorklogError("Nothing to log: the text is empty.")
    now = datetime.now().astimezone()
    if on_day:
        now = now.replace(year=on_day.year, month=on_day.month, day=on_day.day)
    entry = {"ts": now.isoformat(timespec="seconds"), "project": match_project(project, cfg), "text": text}
    MANUAL_LOG.parent.mkdir(parents=True, exist_ok=True)
    with MANUAL_LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return entry


def read_manual(day, end=None):
    end = end or day
    out = []
    if not MANUAL_LOG.exists():
        return out
    for line in MANUAL_LOG.read_text(encoding="utf-8").splitlines():
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = local_time(e.get("ts")) if isinstance(e, dict) else None
        if t and day <= t.date() <= end and e.get("text"):
            e["_t"] = t
            e["project"] = e.get("project") or "General"
            out.append(e)
    return sorted(out, key=lambda e: e["_t"])


# ---------------------------------------------------------------- reading Claude Code transcripts

def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
    return ""


def clip(s, n):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def clean_prompt(txt):
    txt = re.sub(r"<system-reminder>.*?</system-reminder>", " ", txt, flags=re.S)
    txt = re.sub(r"</?pasted_content[^>]*>", " ", txt)   # keep pasted text, drop the wrapper
    txt = txt.strip()
    if not txt or txt.startswith(NOISE_PREFIXES):
        return ""
    return txt


def _rel(path, cwd):
    if under(path, cwd):
        return os.path.relpath(_norm(path), _norm(cwd))
    return path


def read_sessions(day, projects_dir=None, end=None):
    """One record per Claude Code session per LOCAL day, for `day` (or every day from `day` to `end`).

    A session that runs past midnight therefore shows up on both days, each with its own part.
    One pass over the transcripts, however long the range.
    """
    end = end or day
    projects_dir = Path(projects_dir or CLAUDE_PROJECTS)
    day_start = datetime.combine(day, dtime.min).timestamp()
    sessions, titles, seen = {}, {}, set()
    live = sorted(projects_dir.glob("*/*.jsonl")) if projects_dir.is_dir() else []
    live_names = {(f.parent.name, f.name) for f in live}
    archived = [f for f in sorted(ARCHIVE.glob("*/*.jsonl")) if (f.parent.name, f.name) not in live_names] \
        if ARCHIVE.is_dir() else []

    for f in live + archived:
        try:
            if f.stat().st_mtime < day_start:      # untouched since before that day: nothing to find
                continue
            fh = f.open(encoding="utf-8", errors="replace")
        except OSError:
            continue
        pending = {}   # tool_use id -> evidence record, so a failed tool result can mark it failed
        with fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(e, dict):
                    continue
                kind = e.get("type")
                if kind == "ai-title":
                    if e.get("sessionId") and e.get("aiTitle"):
                        titles[e["sessionId"]] = str(e["aiTitle"])
                    continue
                if kind not in ("user", "assistant") or e.get("isSidechain"):
                    continue
                uid = e.get("uuid")
                if uid:
                    if uid in seen:     # resumed/forked sessions can repeat old messages
                        continue
                    seen.add(uid)
                t = local_time(e.get("timestamp"))
                cwd = e.get("cwd")
                if t is None or not (day <= t.date() <= end) or not cwd:
                    continue
                sid = e.get("sessionId") or f.stem
                s = sessions.get((t.date(), sid))
                if s is None:
                    s = sessions[(t.date(), sid)] = {
                        "id": sid, "day": t.date(), "cwd": cwd, "branch": "", "start": t, "end": t, "title": "",
                        "prompts": [], "_files": [], "_commands": [], "last_reply": "", "transcript": str(f),
                    }
                s["start"], s["end"] = min(s["start"], t), max(s["end"], t)
                if e.get("gitBranch") and e["gitBranch"] != "HEAD":
                    s["branch"] = e["gitBranch"]
                content = (e.get("message") or {}).get("content")
                if kind == "user":
                    _read_user_line(e, content, s, pending)
                else:
                    _read_assistant_line(content, s, pending)

    result = []
    for s in sessions.values():
        s["title"] = titles.get(s["id"], "")
        files = []
        for rec in s.pop("_files"):
            if rec["ok"] and rec["path"] not in files:
                files.append(rec["path"])
        s["files"] = files
        cmds = s.pop("_commands")
        s["commands"] = [c for c in cmds if c["kind"] == "check"]
        s["shell_edits"] = [c for c in cmds if c["kind"] == "edit" and c["ok"]]
        s["last_reply"] = clip(s["last_reply"], 1000)
        if s["prompts"] or s["files"] or s["commands"] or s["shell_edits"]:
            result.append(s)
    return sorted(result, key=lambda s: s["start"])


def _read_user_line(e, content, s, pending):
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error"):
                rec = pending.get(b.get("tool_use_id"))
                if rec is not None:
                    rec["ok"] = False
    if e.get("isMeta") or e.get("promptSource") == "system":
        return
    origin = e.get("origin")
    if isinstance(origin, dict) and origin.get("kind") not in (None, "human"):
        return
    txt = clean_prompt(text_of(content))
    if txt:
        s["prompts"].append(clip(txt, 600))


def _read_assistant_line(content, s, pending):
    txt = text_of(content).strip()
    if txt:
        s["last_reply"] = txt
    if not isinstance(content, list):
        return
    for b in content:
        if not isinstance(b, dict) or b.get("type") != "tool_use":
            continue
        name, inp = b.get("name"), b.get("input") or {}
        if not isinstance(inp, dict):
            continue
        rec = None
        if name in FILE_TOOLS:
            p = inp.get("file_path") or inp.get("notebook_path")
            if isinstance(p, str) and p:
                rec = {"path": _rel(p, s["cwd"]), "ok": True}
                s["_files"].append(rec)
        elif name == "Bash":
            cmd = inp.get("command")
            if isinstance(cmd, str) and SHELL_EDIT.search(cmd):
                rec = {"cmd": clip(cmd, 400), "ok": True, "kind": "edit"}
                s["_commands"].append(rec)
            elif isinstance(cmd, str) and NOTABLE_COMMAND.search(cmd):
                rec = {"cmd": clip(cmd, 240), "ok": True, "kind": "check"}
                s["_commands"].append(rec)
        if rec is not None and b.get("id"):
            pending[b["id"]] = rec


def group(sessions, cfg):
    """Split sessions into TESDA projects (config order), Needs review, and excluded."""
    tesda = {name: [] for name in cfg["projects"]}
    review, excluded = [], []
    for s in sessions:
        kind, name = classify(s["cwd"], cfg)
        s["project"] = name
        if kind == "project":
            tesda[name].append(s)
        elif kind == "review":
            review.append(s)
        else:
            excluded.append(s)
    return {k: v for k, v in tesda.items() if v}, review, excluded


# ---------------------------------------------------------------- evidence for the AI

def _project_order(tesda, manual):
    return list(dict.fromkeys(list(tesda) + [m["project"] for m in manual]))


def _session_evidence(s, max_prompts, prompt_len, ranged=False):
    title = f' "{s["title"]}"' if s["title"] else ""
    out = [f"--- Claude Code session{title} | {_when(s['start'], s['end'], ranged)} | "
           f"folder {s['cwd']} | branch {s['branch'] or '-'}"]
    prompts = [clip(p, prompt_len) for p in s["prompts"]]
    if len(prompts) > max_prompts:
        keep = max_prompts - max_prompts // 3
        prompts = prompts[:keep] + [f"(… {len(prompts) - max_prompts} more requests …)"] + prompts[-(max_prompts - keep):]
    if prompts:
        out.append("User requests:")
        out += [f"  - {p}" for p in prompts]
    if s["files"]:
        shown = s["files"][:40]
        more = f" (+{len(s['files']) - 40} more)" if len(s["files"]) > 40 else ""
        out.append(f"Files changed ({len(s['files'])}): " + ", ".join(shown) + more)
    elif not s["shell_edits"]:
        out.append("Files changed: none")
    if s["shell_edits"]:
        out.append(f"Shell commands that edited files ({len(s['shell_edits'])}):")
        out += [f"  $ {clip(c['cmd'], 300)}" for c in s["shell_edits"][:6]]
    if s["commands"]:
        out.append("Notable commands (✓ succeeded, ✗ failed):")
        out += [f"  {'✓' if c['ok'] else '✗'} $ {c['cmd']}" for c in s["commands"][:12]]
    if s["last_reply"]:
        out.append(f"Assistant's final message: {s['last_reply']}")
    return out


def days_in_period(tesda, manual, start, end, workdays):
    """For a range: [(day, {project: sessions}, [manual entries])] for every day with evidence,
    plus workdays with nothing (so 'no work captured' is visible). Weekends only if worked."""
    out = []
    d = start
    while d <= end:
        t = {p: [x for x in ss if x["day"] == d] for p, ss in tesda.items()}
        t = {p: ss for p, ss in t.items() if ss}
        m = [x for x in manual if x["_t"].date() == d]
        if t or m or d.weekday() in workdays:
            out.append((d, t, m))
        d += timedelta(days=1)
    return out


def _projects_evidence(tesda, manual, max_prompts, prompt_len):
    out = []
    for project in _project_order(tesda, manual):
        out.append(f"=== PROJECT: {project} ===")
        mine = [m for m in manual if m["project"] == project]
        if mine:
            out.append("Logged by the user (true and done):")
            out += [f"  - [{m['_t']:%H:%M}] {m['text']}" for m in mine]
        for s in tesda.get(project, []):
            out += _session_evidence(s, max_prompts, prompt_len)
        out.append("")
    return out


def evidence_text(day, tesda, manual, budget=None, end=None, workdays=None):
    """Plain-text evidence. Only TESDA projects and manual entries; Needs-review sessions are never included.
    For a range, it's grouped by date first, then by project."""
    ranged = bool(end and end != day)
    budget = budget or (100000 if ranged else 60000)
    for max_prompts, prompt_len in ((15, 600), (8, 300), (4, 160), (2, 100)):
        out = [f"EVIDENCE FOR {pretty_period(day, end).upper()}", ""]
        if ranged:
            for d, t, m in days_in_period(tesda, manual, day, end, workdays or {0, 1, 2, 3, 4}):
                out.append(f"##### DATE: {pretty_day(d).upper()}")
                if not t and not m:
                    out += ["(no TESDA work captured)", ""]
                out += _projects_evidence(t, m, max_prompts, prompt_len)
        else:
            out += _projects_evidence(tesda, manual, max_prompts, prompt_len)
        text = "\n".join(out)
        if len(text) <= budget:
            return text
    return text[:budget] + "\n(… evidence truncated …)"


AI_PROMPT = """You are writing {kind} for a software developer at TESDA \
(the Philippines' Technical Education and Skills Development Authority). It will be pasted into \
an official work log, so it must be accurate.

The evidence for {period} is included in this message, {grouping}. There are two kinds:
1. "Logged by the user": entries the user typed by hand (meetings, QA, coordination, documentation…). \
Treat them as true and completed unless the text says otherwise.
2. "Claude Code session": what the user asked their AI coding assistant to do, the files that were \
changed, notable commands (✓ succeeded / ✗ failed), and the assistant's final message.

Write the report in Markdown, in English, in exactly this shape:

{shape}

Rules:
1. Never invent work. Use only what the evidence shows. When unsure, leave it out or put it under \
"In progress / attempted".
2. Call something done only when the evidence shows it: files were changed AND the assistant \
reported success, OR a commit was made, OR tests passed. Everything else goes under \
"In progress / attempted".
3. Every "Logged by the user" entry must appear under Accomplishments for its project (light \
rewording is fine).
4. Time spent is not an accomplishment; don't mention durations. Don't exaggerate. Avoid filler \
such as "successfully", "seamlessly", "robust", "comprehensive".
5. Keep useful technical detail (feature, screen, component, endpoint, bug), but leave out file \
paths, session IDs and tool names unless they matter. Merge duplicates. Skip chit-chat, plain \
questions, and setup problems that led nowhere.
6. Output only the report: no preamble, no closing remarks, no code fences.{extra}"""

DAY_SHAPE = """{title}

## <Project name>

**Accomplishments**
- <one line per accomplishment: past tense, specific, professional>

**In progress / attempted**
- <work that was started or requested, but the evidence doesn't show it was finished>

Repeat for each project, in the order given. Leave out an empty sub-section. Leave out a project \
with nothing worth reporting."""

RANGE_SHAPE = """{title}

## <Weekday, Month D, YYYY>

### <Project name>

**Accomplishments**
- <one line per accomplishment: past tense, specific, professional>

**In progress / attempted**
- <work that was started or requested, but the evidence doesn't show it was finished>

Write one "##" section per DATE in the evidence, in date order, with the date written exactly as \
in the evidence (e.g. "## Monday, October 26, 2026"). Inside each date, one "###" sub-section per \
project that had work that day, in the order given. Leave out an empty sub-section. For a date \
marked "(no TESDA work captured)", write the date heading and then the line \
"_No TESDA work captured._" on its own."""

RANGE_RULE = """
7. Report day by day. Keep each piece of work under the date it was done; never merge work from \
different days into one bullet or move it to another date. If a task continued over several \
days, say what was done on each of those days."""


def report_title(start, end=None):
    if end and end != start:
        return f"# Accomplishment Report — {pretty_period(start, end)}"
    return f"# Daily Accomplishment Report — {pretty_day(start)}"


def build_prompt(start, end=None):
    ranged = bool(end and end != start)
    title = report_title(start, end)
    return AI_PROMPT.format(kind="a day-by-day accomplishment report covering several days" if ranged
                            else "a daily accomplishment report",
                            period=pretty_period(start, end),
                            grouping="grouped by date and then by project" if ranged else "grouped by project",
                            shape=(RANGE_SHAPE if ranged else DAY_SHAPE).format(title=title),
                            extra=RANGE_RULE if ranged else "")


def find_claude(cfg):
    candidates = [cfg.get("claude_path"), shutil.which("claude"), "~/.local/bin/claude",
                  "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    for c in candidates:
        if c and os.access(os.path.expanduser(c), os.X_OK):
            return os.path.expanduser(c)
    return None


def _explain_claude_failure(code, out, err):
    said = clip((err or "").strip() or (out or "").strip() or "no output", 300)
    if re.search(r"log ?in|/login|not authenticated|api key|credential|oauth|unauthori", said, re.I):
        return (f"the Claude CLI isn't logged in (it said: {said}). Open Terminal, run `claude`, "
                "type /login, then try again.")
    if re.search(r"usage limit|rate limit|quota|overloaded", said, re.I):
        return f"Claude is busy or you've hit your plan's usage limit (it said: {said}). Try again later."
    return f"`claude` exited with code {code}: {said}"


def ask_claude(evidence, prompt, cfg):
    exe = find_claude(cfg)
    if not exe:
        raise WorklogError("couldn't find the `claude` command. Run `which claude` in Terminal and put "
                           "the result in config.json as \"claude_path\".")
    cmd = [exe, "-p", prompt, "--no-session-persistence", "--tools", ""]
    if cfg.get("model"):
        cmd += ["--model", str(cfg["model"])]
    # If we're started from inside a Claude Code session, don't let the child think it's nested.
    env = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT")}
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    timeout = int(cfg.get("claude_timeout_seconds") or 300)
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, encoding="utf-8", errors="replace", cwd=str(DATA_DIR), env=env)
    except OSError as ex:
        raise WorklogError(f"couldn't start `{exe}` ({ex.strerror}).")
    try:
        out, err = proc.communicate(evidence, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise WorklogError(f"`claude` didn't answer within {timeout} seconds.")
    finally:
        if proc.poll() is None:      # timed out or we were cancelled: don't leave claude running
            proc.kill()
            proc.wait()
    if proc.returncode != 0 or not out.strip():
        raise WorklogError(_explain_claude_failure(proc.returncode, out, err))
    return out


def clean_ai_output(text, title):
    t = text.strip()
    fence = re.match(r"^```[a-zA-Z]*\n(.*)\n```$", t, re.S)
    if fence:
        t = fence.group(1).strip()
    m = re.search(r"^# ", t, re.M)
    if m and m.start() > 0:
        t = t[m.start():]               # drop any preamble before the title
    if not t.startswith("# "):
        t = f"{title}\n\n{t}"
    return t


# ---------------------------------------------------------------- report text

def _raw_projects(tesda, manual, level="##"):
    out = []
    for project in _project_order(tesda, manual):
        out += [f"{level} {project}", ""]
        mine = [m for m in manual if m["project"] == project]
        if mine:
            out += ["**Logged by you**"] + [f"- {m['_t']:%H:%M} — {m['text']}" for m in mine] + [""]
        ss = tesda.get(project, [])
        if ss:
            out.append("**Claude Code sessions**")
            for s in ss:
                head = s["title"] or (clip(s["prompts"][0], 90) if s["prompts"] else "Session")
                branch = f" · branch `{s['branch']}`" if s["branch"] else ""
                out.append(f"- **{head}** · {s['start']:%H:%M}–{s['end']:%H:%M}{branch}")
                if s["prompts"]:
                    more = f" (+{len(s['prompts']) - 1} more requests)" if len(s["prompts"]) > 1 else ""
                    out.append(f"  - Asked: “{clip(s['prompts'][0], 200)}”{more}")
                if s["files"]:
                    names = ", ".join(f"`{Path(p).name}`" for p in s["files"][:8])
                    more = ", …" if len(s["files"]) > 8 else ""
                    out.append(f"  - Changed {len(s['files'])} file(s): {names}{more}")
                if s["shell_edits"]:
                    out.append(f"  - Edited files from the shell: {len(s['shell_edits'])} command(s)")
                if s["commands"]:
                    cmds = ", ".join(f"`{clip(c['cmd'], 70)}` {'✓' if c['ok'] else '✗'}" for c in s["commands"][:5])
                    out.append(f"  - Ran: {cmds}")
                if s["last_reply"]:
                    out.append(f"  - Claude's last message: “{clip(s['last_reply'], 300)}”")
            out.append("")
    return out


def raw_body(day, tesda, manual, warning=None, end=None, workdays=None):
    ranged = bool(end and end != day)
    out = [report_title(day, end), ""]
    if warning:
        out += [f"> ⚠️ **The AI summary couldn't be written:** {warning}", ">",
                "> Below is the raw evidence instead. Fix the problem and regenerate, or write the bullets yourself.", ""]
    else:
        out += ["> Raw evidence (no AI summary). Turn it into accomplishment bullets before you submit it.", ""]
    if ranged:
        for d, t, m in days_in_period(tesda, manual, day, end, workdays or {0, 1, 2, 3, 4}):
            out += [f"## {pretty_day(d)}", ""]
            out += _raw_projects(t, m, "###") if (t or m) else ["_No TESDA work captured._", ""]
    else:
        out += _raw_projects(tesda, manual)
    return "\n".join(out).rstrip() + "\n"


def appendix(review, tesda, generated_at, ai_status, cfg, ranged=False):
    out = []
    if review:
        out += ["---", "", "## Needs review", "",
                "_These Claude Code sessions are in folders that aren't in config.json, so they were **not** used "
                "in the report above. If one is TESDA work, add its folder to `projects` in config.json and "
                "regenerate, or log it by hand._", ""]
        for s in review:
            what = s["title"] or (clip(s["prompts"][0], 100) if s["prompts"] else "(no prompts)")
            out.append(f"- `{s['cwd']}` · {_when(s['start'], s['end'], ranged)} · {what}")
        out.append("")
    all_s = [s for ss in tesda.values() for s in ss]
    if all_s:
        out += ["---", "", "## Sessions used", "",
                "| Time | Project | Folder | Requests | Files changed |", "|---|---|---|---|---|"]
        for s in sorted(all_s, key=lambda s: s["start"]):
            out.append(f"| {_when(s['start'], s['end'], ranged)} | {s['project']} | `{Path(s['cwd']).name}` "
                       f"| {len(s['prompts'])} | {len(s['files'])}"
                       + (f" + {len(s['shell_edits'])} shell edit(s)" if s["shell_edits"] else "") + " |")
        out.append("")
    how = {"ok": f"AI summary by Claude ({cfg.get('model') or 'default model'})", "failed": "AI summary failed",
           "off": "no AI", "empty": "nothing to summarise"}.get(ai_status, ai_status)
    out += ["---", "", f"_Draft generated {generated_at:%Y-%m-%d %H:%M} by TESDA Worklog ({how}). "
                       "Review it before you submit._", ""]
    return "\n".join(out)


def md_to_text(md):
    """Plain text for pasting into a form: no #, **, backticks; bullets become •."""
    out = []
    for line in md.splitlines():
        s = line.rstrip()
        if s.strip() in ("---", "***"):
            continue
        m = re.match(r"^(#{1,6})\s+(.*)$", s)
        if m:
            s = ("" if m.group(1) == "#" else "\n") + m.group(2)
        bold_label = re.match(r"^\*\*(.+?)\*\*$", s.strip())
        if bold_label:
            s = bold_label.group(1) + ":"
        s = re.sub(r"^>\s?", "", s)
        s = re.sub(r"^(\s*)[-*+]\s+", lambda m: m.group(1) + "• ", s)
        s = re.sub(r"\*\*(.+?)\*\*", r"\1", s)
        s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"\1", s)
        s = re.sub(r"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)", r"\1", s)
        s = re.sub(r"`([^`]*)`", r"\1", s)
        s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", s)
        out.append(s)
    text = "\n".join(out)
    return re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"


# ---------------------------------------------------------------- tiny Markdown -> HTML

def _inline(s):
    s = html.escape(s, quote=False)
    codes = []

    def keep(m):
        codes.append(m.group(1))
        return f"\x00{len(codes) - 1}\x00"

    s = re.sub(r"`([^`]+)`", keep, s)
    s = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", s)
    s = re.sub(r"(?<![\w])_(?!\s)(.+?)(?<!\s)_(?![\w])", r"<em>\1</em>", s)
    return re.sub(r"\x00(\d+)\x00", lambda m: f"<code>{codes[int(m.group(1))]}</code>", s)


def md_to_html(md):
    out, para, lists = [], [], []      # lists: stack of [indent, tag]
    lines = md.splitlines()

    def flush():
        if para:
            out.append("<p>" + "<br>".join(_inline(p) for p in para) + "</p>")
            para.clear()

    def close_lists(min_indent=-1):
        while lists and lists[-1][0] > min_indent:
            out.append(f"</li></{lists.pop()[1]}>")

    i = 0
    while i < len(lines):
        line = lines[i]
        st = line.strip()
        item = re.match(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$", line)
        if st.startswith("```"):
            flush(); close_lists()
            body = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                body.append(lines[i]); i += 1
            out.append("<pre><code>" + html.escape("\n".join(body)) + "</code></pre>")
        elif not st:
            flush()
        elif st.startswith("<!--"):
            pass
        elif re.match(r"^#{1,6}\s", st):
            flush(); close_lists()
            level = len(st) - len(st.lstrip("#"))
            out.append(f"<h{level}>{_inline(st[level:].strip())}</h{level}>")
        elif st in ("---", "***", "___"):
            flush(); close_lists()
            out.append("<hr>")
        elif st.startswith(">"):
            flush(); close_lists()
            quote = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote.append(lines[i].strip()[1:].strip()); i += 1
            i -= 1
            paras = "\n".join(quote).split("\n\n")
            out.append("<blockquote>" + "".join("<p>" + "<br>".join(_inline(x) for x in p.splitlines() if x) + "</p>"
                                                for p in paras if p.strip()) + "</blockquote>")
        elif st.startswith("|"):
            flush(); close_lists()
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")]); i += 1
            i -= 1
            body = [r for r in rows if not all(re.match(r"^:?-+:?$", c) for c in r)]
            if body:
                h = "".join(f"<th>{_inline(c)}</th>" for c in body[0])
                b = "".join("<tr>" + "".join(f"<td>{_inline(c)}</td>" for c in r) + "</tr>" for r in body[1:])
                out.append(f"<table><thead><tr>{h}</tr></thead><tbody>{b}</tbody></table>")
        elif item:
            flush()
            indent, tag = len(item.group(1)), ("ol" if item.group(2)[0].isdigit() else "ul")
            close_lists(indent)
            if lists and lists[-1][0] == indent and lists[-1][1] != tag:
                out.append(f"</li></{lists.pop()[1]}>")
            if lists and lists[-1][0] == indent:
                out.append("</li><li>" + _inline(item.group(3)))
            else:
                lists.append([indent, tag])
                out.append(f"<{tag}><li>" + _inline(item.group(3)))
        elif lists and line.startswith(" "):
            out.append(" " + _inline(st))          # continuation of a list item
        else:
            close_lists()
            para.append(st)
        i += 1
    flush(); close_lists()
    return "\n".join(out)


HTML_PAGE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>{title}</title>
<style>
:root {{ --bg:#ffffff; --fg:#1d1d1f; --muted:#6e6e73; --line:#e5e5ea; --accent:#0a4ea2; --soft:#f5f7fb; --warn:#fff6e0; --warnline:#e6b54a; }}
@media (prefers-color-scheme: dark) {{
  :root {{ --bg:#1e1e20; --fg:#f2f2f7; --muted:#a1a1a6; --line:#3a3a3c; --accent:#7ab0ff; --soft:#2a2a2d; --warn:#3a3020; --warnline:#b88a2a; }}
}}
* {{ box-sizing: border-box; }}
body {{ margin:0; background:var(--bg); color:var(--fg);
  font: 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }}
main {{ max-width: 760px; margin: 0 auto; padding: 28px 28px 48px; }}
h1 {{ font-size: 22px; line-height:1.3; margin: 0 0 18px; padding-bottom: 12px; border-bottom: 3px solid var(--accent); }}
h2 {{ font-size: 17px; margin: 28px 0 8px; color: var(--accent); }}
h3 {{ font-size: 15px; margin: 16px 0 6px; color: var(--accent); }}
h2 + h3 {{ margin-top: 8px; }}
p {{ margin: 8px 0; }}
p strong:only-child {{ display:block; margin-top: 14px; font-size: 13px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }}
ul, ol {{ margin: 6px 0 12px; padding-left: 22px; }}
li {{ margin: 4px 0; }}
li > ul {{ margin: 2px 0 6px; color: var(--muted); font-size: 14px; }}
code {{ font: 12.5px ui-monospace, "SF Mono", Menlo, monospace; background: var(--soft); padding: 1px 5px; border-radius: 4px; }}
pre {{ background: var(--soft); padding: 12px; border-radius: 8px; overflow:auto; }}
pre code {{ background:none; padding:0; }}
blockquote {{ margin: 12px 0; padding: 8px 14px; background: var(--warn); border-left: 4px solid var(--warnline); border-radius: 6px; }}
hr {{ border: 0; border-top: 1px solid var(--line); margin: 28px 0 8px; }}
hr ~ h2 {{ color: var(--muted); font-size: 15px; }}
hr ~ ul, hr ~ p, hr ~ table {{ color: var(--muted); font-size: 13.5px; }}
table {{ border-collapse: collapse; width: 100%; margin: 8px 0; }}
th, td {{ text-align:left; padding: 5px 8px; border-bottom: 1px solid var(--line); }}
th {{ font-weight:600; }}
a {{ color: var(--accent); }}
</style></head>
<body><main>
{body}
</main></body></html>
"""


# ---------------------------------------------------------------- building and saving a report

def _atomic_write(path, text):
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=path.suffix)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def report_paths(day, cfg, end=None):
    folder, warning = reports_dir(cfg)
    base = folder / period_key(day, end)
    return {"md": base.with_suffix(".md"), "html": base.with_suffix(".html"),
            "txt": base.with_suffix(".txt"), "json": base.with_suffix(".json")}, warning


def read_meta(day, cfg, end=None):
    paths, _ = report_paths(day, cfg, end)
    try:
        meta = json.loads(paths["json"].read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not (paths["html"].exists() and paths["md"].exists()):
        return None
    meta.update({k: str(v) for k, v in paths.items()})   # the files may have been moved since
    return meta


def build_report(day, cfg, use_ai=True, projects_dir=None, end=None):
    """Collects evidence for `day` (or `day`..`end`), writes <key>.{md,html,txt,json}, returns the metadata.

    <key> is YYYY-MM-DD, or YYYY-MM-DD_to_YYYY-MM-DD for a range.
    """
    end = end or day
    if end < day:
        day, end = end, day
    ranged = end != day
    _mark_running(period_key(day, end))
    try:
        try:
            archive_sync(cfg, projects_dir)
        except OSError:
            pass
        sessions = read_sessions(day, projects_dir, end=end)
        tesda, review, _excluded = group(sessions, cfg)
        manual = read_manual(day, end)
        title = report_title(day, end)
        error = None
        if not tesda and not manual:
            ai_status = "empty"
            body = (f"{title}\n\n_No TESDA work was captured for this {'period' if ranged else 'day'}: no Claude "
                    "Code sessions in your TESDA folders and nothing logged by hand._\n")
        elif use_ai:
            try:
                evidence = evidence_text(day, tesda, manual, end=end, workdays=cfg["_workdays"])
                body = clean_ai_output(ask_claude(evidence, build_prompt(day, end), cfg), title)
                ai_status = "ok"
            except WorklogError as ex:
                ai_status, error = "failed", str(ex)
                body = raw_body(day, tesda, manual, warning=error, end=end, workdays=cfg["_workdays"])
        else:
            ai_status = "off"
            body = raw_body(day, tesda, manual, end=end, workdays=cfg["_workdays"])

        now = datetime.now()
        md = body.rstrip() + "\n\n" + APPENDIX_MARK + "\n" + appendix(review, tesda, now, ai_status, cfg, ranged)
        paths, warning = report_paths(day, cfg, end)
        try:
            _atomic_write(paths["md"], md)
        except PermissionError as ex:
            folder = paths["md"].parent
            DEFAULT_REPORTS.mkdir(parents=True, exist_ok=True)
            paths = {k: DEFAULT_REPORTS / v.name for k, v in paths.items()}
            warning = f"macOS didn't allow writing to {folder} ({ex.strerror}); saved in {DEFAULT_REPORTS} instead."
            _atomic_write(paths["md"], md)
        meta = {
            "day": period_key(day, end), "start": day.isoformat(), "end": end.isoformat(), "range": ranged,
            "generated_at": now.isoformat(timespec="seconds"),
            "ai": ai_status, "error": error, "warning": warning, "model": cfg.get("model"),
            "sessions": sum(len(v) for v in tesda.values()), "manual": len(manual), "review": len(review),
            "projects": _project_order(tesda, manual),
            **{k: str(v) for k, v in paths.items()},
        }
        _atomic_write(paths["txt"], md_to_text(body))
        _atomic_write(paths["html"], HTML_PAGE.format(title=html.escape(f"TESDA report — {pretty_period(day, end)}"),
                                                      body=md_to_html(md)))
        _atomic_write(paths["json"], json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
        return meta
    finally:
        _clear_running()


def _mark_running(key):
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        RUNNING_PATH.write_text(json.dumps({"pid": os.getpid(), "day": key}))
    except OSError:
        pass


def _clear_running():
    try:
        if RUNNING_PATH.exists() and json.loads(RUNNING_PATH.read_text()).get("pid") == os.getpid():
            RUNNING_PATH.unlink()
    except (OSError, ValueError):
        pass


def summary_line(meta):
    s = (f"{meta['sessions']} session{'s' if meta['sessions'] != 1 else ''}, "
         f"{meta['manual']} logged item{'s' if meta['manual'] != 1 else ''} · {meta['review']} to review")
    if meta["ai"] == "failed":
        s += " · AI summary failed"
    return s


# ---------------------------------------------------------------- TESDA transcript archive
#
# Claude Code deletes transcripts after 30 days (all projects). To keep TESDA history for the
# half-year, TESDA transcripts are COPIED here; ~/.claude/projects itself is never modified.
# The morning after each purge date (Jun 30, Dec 31) the archive is emptied, after alerts.

def transcript_cwd(f):
    try:
        with f.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"cwd"' not in line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if isinstance(e, dict) and e.get("type") in ("user", "assistant") and e.get("cwd"):
                    return e["cwd"]
    except OSError:
        pass
    return None


def archive_sync(cfg, projects_dir=None):
    """Copy new or changed TESDA transcripts into the archive. Returns how many were copied."""
    projects_dir = Path(projects_dir or CLAUDE_PROJECTS)
    if not projects_dir.is_dir():
        return 0
    cutoff = read_state().get("archive_purged_through")
    not_before = datetime.combine(date.fromisoformat(cutoff) + timedelta(days=1), dtime.min).timestamp() if cutoff else 0
    copied = 0
    for f in projects_dir.glob("*/*.jsonl"):
        try:
            st = f.stat()
        except OSError:
            continue
        if st.st_mtime < not_before:           # belongs to a half-year that was already purged
            continue
        dest = ARCHIVE / f.parent.name / f.name
        try:
            d = dest.stat()
            if d.st_size == st.st_size and int(d.st_mtime) == int(st.st_mtime):
                continue
        except OSError:
            pass
        cwd = transcript_cwd(f)
        if not cwd or classify(cwd, cfg)[0] != "project":
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            shutil.copy2(f, dest)
            copied += 1
        except OSError:
            continue
    return copied


def _purge_dates(cfg, years):
    out = []
    for y in years:
        for mmdd in cfg.get("archive_purge_dates") or []:
            try:
                m, d = (int(x) for x in str(mmdd).split("-"))
                out.append(date(y, m, d))
            except ValueError:
                raise WorklogError(f"archive_purge_dates: {mmdd!r} should look like \"12-31\".")
    return sorted(out)


def next_purge(cfg, today):
    later = [d for d in _purge_dates(cfg, (today.year, today.year + 1)) if d >= today]
    return later[0] if later else None


def last_purge_due(cfg, today):
    """The most recent purge date that has fully passed (the purge runs the morning after)."""
    passed = [d for d in _purge_dates(cfg, (today.year - 1, today.year)) if d < today]
    return passed[-1] if passed else None


def archive_files(until=None):
    files = sorted(ARCHIVE.glob("*/*.jsonl")) if ARCHIVE.is_dir() else []
    if until:
        end = datetime.combine(until + timedelta(days=1), dtime.min).timestamp()
        files = [f for f in files if f.stat().st_mtime < end]
    return files


def archive_purge(through):
    """Delete archived transcripts last changed on or before `through`. Only touches the archive."""
    removed = 0
    for f in archive_files(until=through):
        f.unlink()
        removed += 1
    for d in list(ARCHIVE.glob("*")) if ARCHIVE.is_dir() else []:
        if d.is_dir() and not any(d.iterdir()):
            d.rmdir()
    return removed


def archive_export(cfg):
    """Zip the archive into the reports folder. Returns the zip path (or None if empty)."""
    import zipfile
    files = archive_files()
    if not files:
        return None
    folder, _ = reports_dir(cfg)
    out = folder / f"TESDA-transcripts-{date.today().isoformat()}.zip"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in files:
            z.write(f, f"{f.parent.name}/{f.name}")
    return out


def archive_maintenance(cfg, now=None, alert=None):
    """Runs every day from the morning job: archive, purge after a purge date, warn before one."""
    now = now or datetime.now()
    today = now.date()
    alert = alert or send_alert
    state = read_state()
    due = last_purge_due(cfg, today)
    if due and state.get("archive_purged_through", "") < due.isoformat():
        removed = archive_purge(due)
        state = read_state()
        state["archive_purged_through"] = due.isoformat()
        _write_state(state)
        print(f"[{now:%Y-%m-%d %H:%M:%S}] Archive: purged {removed} TESDA transcript(s) up to {due}.")
    copied = archive_sync(cfg)
    nxt = next_purge(cfg, today)
    if nxt:
        days_left = (nxt - today).days
        warn_days = int(cfg.get("archive_warn_days", 7))
        warned = set(state.get("archive_warned") or [])
        for stage in sorted({warn_days, 0}, reverse=True):
            key = f"{nxt.isoformat()}:{stage}"
            if days_left <= stage and key not in warned:
                n = len(archive_files())
                when = "tonight" if days_left == 0 else f"on {nxt:%b} {nxt.day} ({days_left} days)"
                alert("TESDA history will be deleted " + ("tonight" if days_left == 0 else "soon"),
                      f"{n} archived TESDA session transcript(s) will be deleted {when}, at the end of "
                      f"{nxt:%B} {nxt.day}. Generate any reports you need before then, or export a copy. "
                      "Your saved reports and logged entries are kept.")
                state = read_state()
                state["archive_warned"] = sorted(set(state.get("archive_warned") or []) | {key})
                _write_state(state)
                break
    if copied:
        print(f"[{now:%Y-%m-%d %H:%M:%S}] Archive: copied {copied} TESDA transcript(s).")


# ---------------------------------------------------------------- delivery

def notify(title, message):
    if sys.platform != "darwin":
        return
    r = subprocess.run(["osascript", "-e", "on run argv",
                        "-e", 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"',
                        "-e", "end run", title, message], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"Notification failed: {r.stderr.strip()}", file=sys.stderr)


def show_report(meta, wait=6.0):
    """Ask the menu bar app to show the report window. If it doesn't answer, open the HTML in the browser."""
    INBOX.mkdir(parents=True, exist_ok=True)
    req = INBOX / "show.json"
    _atomic_write(req, json.dumps({"day": meta["day"], "at": time.time()}))
    deadline = time.time() + wait
    while time.time() < deadline:
        if not req.exists():
            return "window"
        time.sleep(0.2)
    try:
        req.unlink()
    except OSError:
        pass
    if sys.platform == "darwin":
        subprocess.run(["open", meta["html"]], capture_output=True)
    return "browser"


def read_state():
    try:
        return json.loads(STATE_PATH.read_text())
    except (OSError, ValueError):
        return {}


def _write_state(state):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    _atomic_write(STATE_PATH, json.dumps(state, indent=2))


def send_alert(title, message):
    """Notification, plus a dialog with an "Export a copy" button if the menu bar app is running."""
    notify(title, message)
    INBOX.mkdir(parents=True, exist_ok=True)
    _atomic_write(INBOX / "alert.json", json.dumps({"title": title, "message": message, "action": "export-archive",
                                                         "at": time.time()}))


def run_scheduled(cfg, now=None):
    """The 8 AM job. Also runs at login/wake, so it decides for itself whether there's work to do."""
    now = now or datetime.now()
    today = now.date()
    stamp = f"[{now:%Y-%m-%d %H:%M:%S}]"
    try:
        archive_maintenance(cfg, now)
    except Exception as ex:    # never let housekeeping block the report
        print(f"{stamp} Archive maintenance failed: {ex}", file=sys.stderr)
    if today.weekday() not in cfg["_workdays"]:
        print(f"{stamp} Not a workday; nothing to do.")
        return None
    hh, mm = (int(x) for x in str(cfg.get("report_time") or "08:00").split(":"))
    if now.time() < dtime(hh, mm):
        print(f"{stamp} Before {hh:02d}:{mm:02d}; nothing to do yet.")
        return None
    state = read_state()
    if state.get("last_scheduled") == today.isoformat():
        print(f"{stamp} Already delivered today's report.")
        return None
    day = previous_workday(today, cfg["_workdays"])
    meta = read_meta(day, cfg)
    day_over = datetime.combine(day + timedelta(days=1), dtime.min)
    if meta and meta.get("ai") in ("ok", "empty") and datetime.fromisoformat(meta["generated_at"]) >= day_over:
        print(f"{stamp} Report for {day} already exists; reusing it.")
    else:
        print(f"{stamp} Writing report for {day}…")
        meta = build_report(day, cfg, use_ai=True)
    print(f"{stamp} {summary_line(meta)} → {meta['md']}")
    notify("TESDA Worklog — report ready", summary_line(meta))
    if cfg.get("open_report", True):
        print(f"{stamp} Shown in: {show_report(meta, wait=10)}")
    state = read_state()
    state["last_scheduled"] = today.isoformat()
    _write_state(state)
    return meta


# ---------------------------------------------------------------- other commands

def list_folders(cfg, projects_dir=None):
    projects_dir = Path(projects_dir or CLAUDE_PROJECTS)
    info = {}
    for f in projects_dir.glob("*/*.jsonl") if projects_dir.is_dir() else []:
        cwd = None
        try:
            with f.open(encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if '"cwd"' not in line:
                        continue
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(e, dict) and e.get("type") in ("user", "assistant") and e.get("cwd"):
                        cwd = e["cwd"]
                        break
            mtime = f.stat().st_mtime
        except OSError:
            continue
        if cwd:
            key = _norm(cwd).casefold()
            rec = info.setdefault(key, {"cwd": cwd, "sessions": 0, "last": 0})
            rec["sessions"] += 1
            rec["last"] = max(rec["last"], mtime)
    return sorted(info.values(), key=lambda r: -r["last"])


def cmd_report(args, cfg):
    if args.scheduled:
        run_scheduled(cfg)
        return
    spec = args.day if not args.to else f"{args.day}..{args.to}"
    start, end = resolve_period(spec, cfg)
    meta = build_report(start, cfg, use_ai=not args.no_ai, end=end)
    if args.json:
        print(json.dumps({"ok": True, **meta}, ensure_ascii=False))
    else:
        print(f"{pretty_period(start, end)}: {summary_line(meta)}")
        if meta["error"]:
            print(f"⚠️  {meta['error']}")
        if meta["warning"]:
            print(f"⚠️  {meta['warning']}")
        print(f"Saved: {meta['md']}\n       {meta['html']}")
    if args.open:
        show_report(meta)


def cmd_sessions(args, cfg):
    day = resolve_day(args.day or "today", cfg)
    sessions = read_sessions(day)
    print(f"Claude Code sessions on {pretty_day(day)} (local time):")
    if not sessions:
        print("  (none)")
    for s in sessions:
        what = s["title"] or (clip(s["prompts"][0], 60) if s["prompts"] else "")
        print(f"  {s['start']:%H:%M}-{s['end']:%H:%M}  [{label_of(s['cwd'], cfg)}]  {s['cwd']}\n"
              f"               {what}  ({len(s['prompts'])} requests, {len(s['files'])} files, "
              f"{len(s['shell_edits'])} shell edits, {len(s['commands'])} notable commands)")
    manual = read_manual(day)
    if manual:
        print("Logged by hand:")
        for m in manual:
            print(f"  {m['_t']:%H:%M}  [{m['project']}]  {m['text']}")


def cmd_folders(args, cfg):
    rows = list_folders(cfg)
    if not rows:
        print(f"No Claude Code sessions found in {CLAUDE_PROJECTS}")
        return
    print(f"{'Last used':<11} {'Sessions':>8}  {'Classified as':<30} Folder")
    for r in rows:
        print(f"{datetime.fromtimestamp(r['last']):%Y-%m-%d}  {r['sessions']:>8}  "
              f"{clip(label_of(r['cwd'], cfg), 30):<30} {r['cwd']}")
    print(f"\nEdit {CONFIG_PATH} to put TESDA folders under \"projects\" and the rest under \"exclude\".")


def cmd_archive(args, cfg):
    if args.action == "export":
        out = archive_export(cfg)
        print(f"Exported to {out}" if out else "The archive is empty; nothing to export.")
        return
    copied = archive_sync(cfg)
    if args.action == "sync":
        print(f"Copied {copied} TESDA transcript(s) into the archive.")
        return
    files = archive_files()
    size = sum(f.stat().st_size for f in files)
    oldest = min((datetime.fromtimestamp(f.stat().st_mtime) for f in files), default=None)
    nxt = next_purge(cfg, date.today())
    print(f"Archive: {ARCHIVE}\n  {len(files)} TESDA transcript(s), {size / 1e6:.1f} MB"
          + (f", oldest last changed {oldest:%Y-%m-%d}" if oldest else ""))
    if nxt:
        print(f"  Next purge: end of {nxt:%B} {nxt.day}, {nxt.year} "
              f"(alerts {cfg.get('archive_warn_days', 7)} days before and on the day)")
    print("  Export a copy any time: worklog archive export")


def main(argv=None):
    p = argparse.ArgumentParser(prog="worklog", description="TESDA Worklog: daily accomplishment reports "
                                "from your Claude Code history and manual notes.")
    sub = p.add_subparsers(dest="cmd", metavar="{report,log,sessions,folders,projects,archive,paths}")
    r = sub.add_parser("report", help="build a report (default: previous workday)")
    r.add_argument("day", nargs="?", default="prev",
                   help="prev (default), today, yesterday, YYYY-MM-DD, or a range YYYY-MM-DD..YYYY-MM-DD")
    r.add_argument("--to", help="end of a date range (same as DAY..TO)")
    r.add_argument("--no-ai", action="store_true", help="skip Claude; just list the raw evidence")
    r.add_argument("--open", action="store_true", help="show the report when done")
    r.add_argument("--json", action="store_true", help="print the result as JSON (used by the menu bar app)")
    r.add_argument("--scheduled", action="store_true", help=argparse.SUPPRESS)
    lg = sub.add_parser("log", help="log something you did outside Claude Code")
    lg.add_argument("text", nargs="+")
    lg.add_argument("--project", "-p", help='project: one from config.json (partial names work), '
                    f'"{GENERAL_PROJECT}", or any new name (default: the first project)')
    lg.add_argument("--date", help="log it on another day (YYYY-MM-DD); default today")
    s = sub.add_parser("sessions", help="list the sessions captured for a day")
    s.add_argument("day", nargs="?", default="today")
    sub.add_parser("folders", help="list every folder you've used Claude Code in")
    pr = sub.add_parser("projects", help="list project names from config.json")
    pr.add_argument("--log", action="store_true", help=argparse.SUPPRESS)   # choices for the Log dialog (JSON)
    ar = sub.add_parser("archive", help="TESDA transcript archive: status, or export a zip copy")
    ar.add_argument("action", nargs="?", default="status", choices=["status", "export", "sync"])
    rs = sub.add_parser("resolve", help=argparse.SUPPRESS)
    rs.add_argument("day", nargs="?", default="prev")
    pa = sub.add_parser("paths", help="show where files live")
    pa.add_argument("--json", action="store_true")
    ini = sub.add_parser("init", help=argparse.SUPPRESS)
    ini.add_argument("--claude-path", default="")
    args = p.parse_args(argv)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))   # Cancel button: clean up and stop claude
    want_json = getattr(args, "json", False)
    try:
        if args.cmd is None:
            p.print_help()
            return 0
        cfg = load_config()
        if args.cmd == "report":
            cmd_report(args, cfg)
        elif args.cmd == "log":
            day = resolve_day(args.date, cfg) if args.date else None
            known = {n.casefold() for n in log_choices(cfg)}
            e = add_manual(" ".join(args.text), args.project, cfg, day)
            new = "" if e["project"].casefold() in known else " (new project)"
            print(f"Logged to {e['project']}{new}: {e['text']}")
        elif args.cmd == "sessions":
            cmd_sessions(args, cfg)
        elif args.cmd == "folders":
            cmd_folders(args, cfg)
        elif args.cmd == "projects":
            if args.log:
                used = logged_projects()
                print(json.dumps({"choices": log_choices(cfg), "last": used[0] if used else None}, ensure_ascii=False))
            else:
                print("\n".join(cfg["projects"]))
        elif args.cmd == "archive":
            cmd_archive(args, cfg)
        elif args.cmd == "resolve":
            print(period_key(*resolve_period(args.day, cfg)))
        elif args.cmd == "paths":
            folder, warning = reports_dir(cfg)
            paths = {"data_dir": str(DATA_DIR), "config": str(CONFIG_PATH), "reports_dir": str(folder),
                     "manual_log": str(MANUAL_LOG), "claude_projects": str(CLAUDE_PROJECTS),
                     "inbox": str(INBOX), "running": str(RUNNING_PATH), "warning": warning}
            print(json.dumps(paths, indent=None if args.json else 2))
        elif args.cmd == "init":
            user = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            changed = False
            if args.claude_path and not user.get("claude_path"):
                user["claude_path"], changed = args.claude_path, True
            if user.get("reports_dir") == OLD_DEFAULT_REPORTS:     # older default: Documents (see README)
                user["reports_dir"], changed = "", True
            for key, value in DEFAULT_CONFIG.items():             # new settings after an update
                if key not in user or (key == "_help" and user[key] != value):
                    user[key], changed = value, True
            if changed:
                CONFIG_PATH.write_text(json.dumps(user, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
                cfg = load_config()
            folder, warning = reports_dir(cfg)
            print(f"Config:  {CONFIG_PATH}\nReports: {folder}" + (f"\n⚠️  {warning}" if warning else ""))
        return 0
    except WorklogError as ex:
        if want_json:
            print(json.dumps({"ok": False, "error": str(ex)}))
        print(f"Error: {ex}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
