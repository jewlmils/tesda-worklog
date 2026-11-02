#!/usr/bin/env python3
"""
TESDA Worklog (MVP)

Reads your Claude Code (Claude CLI) history from ~/.claude/projects,
keeps only TESDA work (based on folders you list in config.json),
asks Claude (through your own `claude` CLI / Pro plan, no API key)
to write an accomplishment report, saves it, and notifies you.

Usage:
  python3 worklog.py report [DATE] [--no-ai]   # default DATE = previous workday
  python3 worklog.py sessions [DATE]           # list what was captured that day
  python3 worklog.py folders                   # list every folder you've used Claude in
  python3 worklog.py log "Attended sprint planning" [--project=TESDA-TRACK]
  python3 worklog.py projects                  # list project names from config.json
DATE can be YYYY-MM-DD, "today" or "yesterday".

No dependencies beyond Python 3's standard library.
"""

import json
import os
import shutil
import subprocess
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

HOME_DIR = Path(__file__).resolve().parent
CONFIG_PATH = HOME_DIR / "config.json"
REPORTS_DIR = HOME_DIR / "reports"
MANUAL_LOG = HOME_DIR / "manual_log.jsonl"
CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"

DEFAULT_CONFIG = {
    "_help": "projects: report name -> list of folders (sub-folders count too). "
             "exclude: folders to always ignore. Anything else shows up under 'Needs review'.",
    "projects": {
        "TESDA Skills Passport (TSP)": ["~/Projects/tesda/tsp"],
        "TESDA-TRACK": ["~/Projects/tesda/track"],
    },
    "exclude": ["~/Projects/appetiser", "~/Projects/personal"],
    "workdays": [0, 1, 2, 3, 4],
    "model": "sonnet",
    "claude_path": "",
    "open_report": True,
}

FILE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
EVIDENCE_WORDS = ("git commit", "git push", "test", "build", "deploy", "lint", "migrate")
SKIP_PREFIXES = ("<command-", "<local-command", "<system-reminder", "Caveat:",
                 "[Request interrupted", "<bash-", "<user-memory")

REPORT_PROMPT = """You write daily accomplishment reports for a developer working at TESDA \
(Philippines' Technical Education and Skills Development Authority).

Below (on stdin) is evidence for {day}, grouped by project: entries the user logged by hand
(meetings, QA, coordination, etc. — written by the user, treat them as true and completed unless they say otherwise),
and evidence from their Claude Code sessions: prompts, files changed, notable commands, and Claude's last message.

Write the report in Markdown, in English, exactly in this shape:

# Daily Accomplishment Report — {day}

## <Project name>
**Accomplishments**
- <one line per accomplishment, past tense, professional, specific>

**In progress / attempted**
- <work that was requested or started but the evidence does not show it was finished>

(repeat per project; omit an empty sub-section)

STRICT RULES:
1. Never invent work. Only use what the evidence shows.
2. Only call something done if the evidence shows it (files changed AND Claude reported success, a commit, passing tests). Otherwise put it under "In progress / attempted".
3. Do not exaggerate impact. Time spent is not an accomplishment.
4. Merge duplicates; keep useful technical detail (feature names, components, endpoints) but drop file paths unless they matter.
5. Skip trivial chatter (questions about syntax, greetings, failed auth, etc.) unless it led to real work.
6. Output only the report, no preamble.
"""


# ---------- config ----------

def load_config():
    if not CONFIG_PATH.exists():
        CONFIG_PATH.write_text(json.dumps(DEFAULT_CONFIG, indent=2))
        print(f"Created {CONFIG_PATH} - edit it to list your TESDA folders.")
    cfg = {**DEFAULT_CONFIG, **json.loads(CONFIG_PATH.read_text())}
    expand = lambda p: str(Path(os.path.expanduser(p)).resolve())
    cfg["_projects"] = {name: [expand(p) for p in paths] for name, paths in cfg["projects"].items()}
    cfg["_exclude"] = [expand(p) for p in cfg["exclude"]] + [str(HOME_DIR)]
    return cfg


def under(path, folder):
    return path == folder or path.startswith(folder.rstrip("/") + "/")


def classify(cwd, cfg):
    """Returns project name, 'EXCLUDE', or None (needs review)."""
    best, best_len = None, -1
    for name, folders in cfg["_projects"].items():
        for f in folders:
            if under(cwd, f) and len(f) > best_len:
                best, best_len = name, len(f)
    for f in cfg["_exclude"]:
        if under(cwd, f) and len(f) > best_len:
            return "EXCLUDE"
    return best


# ---------- manual entries ----------

def add_manual(text, project, cfg):
    project = project or next(iter(cfg["projects"]), "General")
    entry = {"ts": datetime.now().astimezone().isoformat(timespec="seconds"),
             "project": project, "text": text.strip()}
    with MANUAL_LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return entry


def read_manual(day):
    out = []
    if MANUAL_LOG.exists():
        for line in MANUAL_LOG.read_text(encoding="utf-8").splitlines():
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = local_time(e.get("ts"))
            if t and t.date() == day and e.get("text"):
                e["_t"] = t
                out.append(e)
    return out


# ---------- dates ----------

def parse_day(arg, cfg):
    today = date.today()
    if arg in (None, ""):
        d = today - timedelta(days=1)
        while d.weekday() not in cfg["workdays"]:
            d -= timedelta(days=1)
        return d
    if arg == "today":
        return today
    if arg == "yesterday":
        return today - timedelta(days=1)
    return date.fromisoformat(arg)


def local_time(ts):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


# ---------- reading Claude Code transcripts ----------

def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text")
    return ""


def clip(s, n):
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def read_sessions(day):
    """One record per (session, day): only messages whose local date == day."""
    sessions = {}
    if not CLAUDE_PROJECTS.exists():
        return []
    start_of_day = datetime.combine(day, datetime.min.time()).timestamp()
    for f in CLAUDE_PROJECTS.glob("*/*.jsonl"):
        try:
            if f.stat().st_mtime < start_of_day:   # not touched since that day -> skip fast
                continue
            lines = f.open(encoding="utf-8", errors="replace")
        except OSError:
            continue
        with lines:
            for line in lines:
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if e.get("type") not in ("user", "assistant") or e.get("isSidechain"):
                    continue
                t = local_time(e.get("timestamp"))
                if not t or t.date() != day or not e.get("cwd"):
                    continue
                sid = e.get("sessionId") or f.stem
                s = sessions.setdefault(sid, {
                    "id": sid, "cwd": e["cwd"], "branch": e.get("gitBranch"),
                    "start": t, "end": t, "prompts": [], "files": [], "commands": [],
                    "last_reply": "",
                })
                s["start"], s["end"] = min(s["start"], t), max(s["end"], t)
                msg = e.get("message") or {}
                content = msg.get("content")
                if e["type"] == "user":
                    if e.get("isMeta"):
                        continue
                    txt = text_of(content).strip()
                    if txt and not txt.startswith(SKIP_PREFIXES):
                        s["prompts"].append(clip(txt, 500))
                else:
                    txt = text_of(content).strip()
                    if txt:
                        s["last_reply"] = clip(txt, 700)
                    for b in content if isinstance(content, list) else []:
                        if not isinstance(b, dict) or b.get("type") != "tool_use":
                            continue
                        inp = b.get("input") or {}
                        if b.get("name") in FILE_TOOLS:
                            p = inp.get("file_path") or inp.get("notebook_path")
                            if p:
                                rel = os.path.relpath(p, s["cwd"]) if p.startswith(s["cwd"]) else p
                                if rel not in s["files"]:
                                    s["files"].append(rel)
                        elif b.get("name") == "Bash":
                            cmd = inp.get("command", "")
                            if any(w in cmd for w in EVIDENCE_WORDS):
                                s["commands"].append(clip(cmd, 200))
    return sorted((s for s in sessions.values() if s["prompts"] or s["files"]),
                  key=lambda s: s["start"])


def group(sessions, cfg):
    tesda, review = {}, []
    for s in sessions:
        p = classify(s["cwd"], cfg)
        if p == "EXCLUDE":
            continue
        if p is None:
            review.append(s)
        else:
            s["project"] = p
            tesda.setdefault(p, []).append(s)
    return tesda, review


def mins(s):
    return int((s["end"] - s["start"]).total_seconds() // 60)


def evidence_text(tesda, manual=()):
    out = []
    projects = list(tesda) + [m["project"] for m in manual if m["project"] not in tesda]
    for project in dict.fromkeys(projects):
        out.append(f"=== PROJECT: {project} ===")
        mine = [m for m in manual if m["project"] == project]
        if mine:
            out.append("Logged by the user:")
            out += [f"  - [{m['_t']:%H:%M}] {m['text']}" for m in mine]
        for s in tesda.get(project, []):
            out.append(f"\n--- Session {s['id'][:8]} | {s['start']:%H:%M}-{s['end']:%H:%M} "
                       f"| folder {s['cwd']} | branch {s['branch'] or '-'}")
            prompts = s["prompts"]
            if len(prompts) > 15:
                prompts = prompts[:10] + ["(…more prompts omitted…)"] + prompts[-4:]
            out.append("User prompts:")
            out += [f"  - {p}" for p in prompts]
            if s["files"]:
                out.append("Files changed: " + ", ".join(s["files"][:40]))
            if s["commands"]:
                out.append("Notable commands:")
                out += [f"  $ {c}" for c in s["commands"][:10]]
            if s["last_reply"]:
                out.append(f"Claude's last message: {s['last_reply']}")
        out.append("")
    return "\n".join(out)


# ---------- Claude (headless, uses your Pro login) ----------

def find_claude(cfg):
    candidates = [cfg.get("claude_path"), shutil.which("claude"),
                  "~/.claude/local/claude", "~/.local/bin/claude",
                  "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    for c in candidates:
        if c and os.access(os.path.expanduser(c), os.X_OK):
            return os.path.expanduser(c)
    return None


def ask_claude(prompt, stdin_text, cfg):
    exe = find_claude(cfg)
    if not exe:
        raise RuntimeError("Couldn't find the `claude` command. Put its path in config.json -> claude_path.")
    cmd = [exe, "-p", prompt, "--no-session-persistence", "--tools", ""]
    if cfg.get("model"):
        cmd += ["--model", cfg["model"]]
    r = subprocess.run(cmd, input=stdin_text, capture_output=True, text=True,
                       timeout=600, cwd=str(HOME_DIR))
    if r.returncode != 0 or not r.stdout.strip():
        raise RuntimeError((r.stderr or r.stdout or "claude returned nothing").strip()[:500])
    return r.stdout.strip()


# ---------- output ----------

def notify(title, message):
    if sys.platform != "darwin":
        return
    esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"')
    subprocess.run(["osascript", "-e",
                    f'display notification "{esc(message)}" with title "{esc(title)}" sound name "Glass"'],
                   capture_output=True)


def build_report(day, cfg, use_ai=True):
    sessions = read_sessions(day)
    tesda, review = group(sessions, cfg)
    manual = read_manual(day)
    pretty = f"{day:%A, %B} {day.day}, {day.year}"
    n = sum(len(v) for v in tesda.values())

    parts = []
    evidence = evidence_text(tesda, manual)
    if not tesda and not manual:
        parts.append(f"# Daily Accomplishment Report — {pretty}\n\n"
                     "_No TESDA Claude Code sessions found for this day._")
    elif use_ai:
        try:
            parts.append(ask_claude(REPORT_PROMPT.format(day=pretty), evidence, cfg))
        except Exception as ex:  # fall back to raw evidence so you still get something
            parts.append(f"# Daily Accomplishment Report — {pretty}\n\n"
                         f"> ⚠️ Couldn't generate the summary ({ex}). Raw evidence below.\n\n"
                         f"```\n{evidence}\n```")
    else:
        parts.append(f"# Daily Accomplishment Report — {pretty}\n\n```\n{evidence}\n```")

    if review:
        parts.append("\n---\n## Needs review (folder not in config.json)\n"
                     "_Not included above. If any of these are TESDA, add the folder to config.json "
                     "and run the report again._\n")
        for s in review:
            parts.append(f"- `{s['cwd']}` {s['start']:%H:%M}–{s['end']:%H:%M}: "
                         f"{clip(s['prompts'][0] if s['prompts'] else '(no prompts)', 120)}")

    if tesda:
        parts.append("\n---\n## Sessions captured\n\n| Time | Project | Folder | Mins | Files changed |\n|---|---|---|---|---|")
        for p, ss in tesda.items():
            for s in ss:
                parts.append(f"| {s['start']:%H:%M}–{s['end']:%H:%M} | {p} | `{Path(s['cwd']).name}` "
                             f"| {mins(s)} | {len(s['files'])} |")

    parts.append(f"\n\n_Draft generated {datetime.now():%Y-%m-%d %H:%M} by TESDA Worklog — review before submitting._\n")

    REPORTS_DIR.mkdir(exist_ok=True)
    out = REPORTS_DIR / f"{day.isoformat()}.md"
    out.write_text("\n".join(parts), encoding="utf-8")
    return out, n, len(review), len(manual)


def main(argv):
    cfg = load_config()
    args = [a for a in argv if not a.startswith("--")]
    flags = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    cmd = args[0] if args else "report"
    day_arg = args[1] if len(args) > 1 else None

    if cmd == "report":
        day = parse_day(day_arg, cfg)
        out, n, r, m = build_report(day, cfg, use_ai="--no-ai" not in argv)
        msg = (f"{n} Claude session(s), {m} logged item(s) on {day:%a %b %d}"
               + (f" · {r} to review" if r else ""))
        print(f"{msg}\nSaved: {out}")
        notify("TESDA Worklog — report ready", msg)
        if cfg.get("open_report") and sys.platform == "darwin" and "--no-open" not in argv:
            subprocess.run(["open", str(out)])
    elif cmd == "log":
        text = " ".join(args[1:]).strip()
        if not text:
            sys.exit('Usage: worklog.py log "what you did" [--project=NAME]')
        e = add_manual(text, flags.get("project"), cfg)
        print(f"Logged to {e['project']}: {e['text']}")
    elif cmd == "projects":
        print("\n".join(cfg["projects"]))
    elif cmd == "sessions":
        day = parse_day(day_arg or "today", cfg)
        for s in read_sessions(day):
            p = classify(s["cwd"], cfg)
            label = "excluded" if p == "EXCLUDE" else (p or "NEEDS REVIEW")
            print(f"{s['start']:%H:%M}-{s['end']:%H:%M}  [{label}]  {s['cwd']}  "
                  f"({len(s['prompts'])} prompts, {len(s['files'])} files)")
    elif cmd == "folders":
        seen = {}
        for f in CLAUDE_PROJECTS.glob("*/*.jsonl"):
            with f.open(encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if '"cwd"' in line:
                        try:
                            cwd = json.loads(line).get("cwd")
                        except json.JSONDecodeError:
                            continue
                        if cwd:
                            seen[cwd] = seen.get(cwd, 0) + 1
                            break
        for cwd, count in sorted(seen.items(), key=lambda kv: -kv[1]):
            p = classify(cwd, cfg)
            label = "excluded" if p == "EXCLUDE" else (p or "-")
            print(f"{count:4} sessions  {cwd}   [{label}]")
    else:
        print(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
