#!/usr/bin/env python3
"""Writes the synthetic Claude Code transcripts in tests/fixtures/projects/.

They mimic the real format (~/.claude/projects/<encoded-folder>/<session-id>.jsonl).
Timestamps are UTC; the tests run with TZ=Asia/Manila (UTC+8), so 01:00Z = 09:00 local.
Re-run this script if you change it:  python3 tests/make_fixtures.py
"""
import json
from pathlib import Path

OUT = Path(__file__).parent / "fixtures" / "projects"
_n = 0


def line(kind, ts, cwd, sid, content, **extra):
    global _n
    _n += 1
    e = {"parentUuid": None, "isSidechain": False, "type": kind, "uuid": f"u-{sid[:4]}-{_n}",
         "timestamp": ts, "cwd": cwd, "sessionId": sid, "version": "2.1.316", "gitBranch": "main",
         "userType": "external", "message": {"role": kind, "content": content}}
    e.update(extra)
    return e


def tool(name, tid, **inp):
    return {"type": "tool_use", "id": tid, "name": name, "input": inp}


def result(tid, error=False):
    return [{"type": "tool_result", "tool_use_id": tid, "content": "Exit code 1" if error else "ok", "is_error": error}]


def write(folder, sid, lines):
    d = OUT / folder
    d.mkdir(parents=True, exist_ok=True)
    with (d / f"{sid}.jsonl").open("w") as f:
        for e in lines:
            f.write(e if isinstance(e, str) else json.dumps(e))
            f.write("\n")


def main():
    # 1) TESDA TSP, Friday 2026-10-30 09:00-11:30 Manila. Sub-folder + different letter case than config.
    sid, cwd = "aaaa1111-0000-0000-0000-000000000001", "/Users/dev/work/TESDA/TSP/mobile"
    human = {"origin": {"kind": "human"}, "promptSource": "typed"}
    dup = line("user", "2026-10-30T01:05:00.000Z", cwd, sid,
               "Add a fallback bottom sheet when the liveness check fails 3 times", **human)
    write("-Users-dev-work-TESDA-TSP-mobile", sid, [
        {"type": "ai-title", "aiTitle": "Liveness check fallback bottom sheet", "sessionId": sid},
        {"type": "permission-mode", "permissionMode": "default", "sessionId": sid},
        line("user", "2026-10-30T01:00:00.000Z", cwd, sid, "<command-name>/clear</command-name>"),
        line("user", "2026-10-30T01:00:01.000Z", cwd, sid,
             "<local-command-caveat>Caveat: The messages below were generated…</local-command-caveat>", isMeta=True),
        line("user", "2026-10-30T01:00:02.000Z", cwd, sid, "<local-command-stdout></local-command-stdout>"),
        dup,
        dup,   # same uuid twice (as after a resume): must be counted once
        line("user", "2026-10-30T01:06:00.000Z", cwd, sid,
             [{"type": "text", "text": "[Image: original 1200x800]"}], isMeta=True),
        line("user", "2026-10-30T01:07:00.000Z", cwd, sid,
             '<pasted_content id="p1">Spec: the sheet must offer Retry and Manual upload</pasted_content> follow this spec',
             **human),
        line("user", "2026-10-30T01:08:00.000Z", cwd, sid,
             "Fix the lint errors too<system-reminder>internal stuff</system-reminder>", **human),
        line("user", "2026-10-30T01:09:00.000Z", cwd, sid,
             "<task-notification><status>completed</status></task-notification>",
             origin={"kind": "task-notification"}, promptSource="system"),
        line("assistant", "2026-10-30T01:10:00.000Z", cwd, sid, [
            {"type": "thinking", "thinking": "plan"},
            tool("Edit", "t1", file_path=cwd + "/src/LivenessSheet.tsx", old_string="a", new_string="b"),
        ]),
        line("user", "2026-10-30T01:10:05.000Z", cwd, sid, result("t1"), toolUseResult={}),
        line("assistant", "2026-10-30T01:11:00.000Z", cwd, sid, [
            tool("Write", "t2", file_path=cwd + "/src/broken.ts", content="x")]),
        line("user", "2026-10-30T01:11:05.000Z", cwd, sid, result("t2", error=True), toolUseResult={}),
        line("assistant", "2026-10-30T01:12:00.000Z", cwd, sid, [tool("Read", "t3", file_path=cwd + "/README.md")]),
        line("assistant", "2026-10-30T01:13:00.000Z", cwd, sid, [
            tool("MultiEdit", "t4", file_path="/Users/dev/shared/theme.ts", edits=[])]),
        line("assistant", "2026-10-30T01:14:00.000Z", cwd, sid, [tool("Bash", "t5", command="ls -la src")]),
        line("assistant", "2026-10-30T01:14:30.000Z", cwd, sid, [
            tool("Bash", "t5b", command="sed -i '' 's/RETRY_LIMIT = 2/RETRY_LIMIT = 3/' src/config.ts")]),
        line("assistant", "2026-10-30T01:15:00.000Z", cwd, sid, [tool("Bash", "t6", command="npm test -- --watch=false")]),
        line("user", "2026-10-30T01:15:30.000Z", cwd, sid, result("t6")),
        line("assistant", "2026-10-30T01:16:00.000Z", cwd, sid, [tool("Bash", "t7", command="npm run lint")]),
        line("user", "2026-10-30T01:16:30.000Z", cwd, sid, result("t7", error=True)),
        line("assistant", "2026-10-30T01:20:00.000Z", cwd, sid, [
            tool("Bash", "t8", command='git commit -m "feat(liveness): add fallback bottom sheet"')]),
        line("user", "2026-10-30T01:20:05.000Z", cwd, sid, result("t8")),
        line("assistant", "2026-10-30T01:21:00.000Z", cwd, sid, [
            tool("Edit", "t9", file_path=cwd + "/src/SECRET_SIDECHAIN.ts")], isSidechain=True),
        line("user", "2026-10-30T01:22:00.000Z", cwd, sid, "[Request interrupted by user]"),
        "this line is not json {",
        line("assistant", "2026-10-30T03:30:00.000Z", cwd, sid, [
            {"type": "text", "text": "Done: the fallback sheet is in place, tests pass, and I committed it."}]),
    ])

    # 2) TESDA-TRACK session spanning midnight: Thu 23:30 -> Fri 00:20 Manila.
    sid, cwd = "bbbb2222-0000-0000-0000-000000000002", "/Users/dev/work/tesda/track"
    write("-Users-dev-work-tesda-track", sid, [
        line("user", "2026-10-29T15:30:00.000Z", cwd, sid, "Start migrating TRACK reports to the new API"),
        line("assistant", "2026-10-29T15:40:00.000Z", cwd, sid, [tool("Edit", "m1", file_path=cwd + "/src/api.ts")]),
        line("user", "2026-10-29T16:20:00.000Z", cwd, sid, "Now update the report screen"),
        line("assistant", "2026-10-29T16:25:00.000Z", cwd, sid, [
            tool("Edit", "m2", file_path=cwd + "/src/ReportScreen.tsx")]),
        line("assistant", "2026-10-29T16:30:00.000Z", cwd, sid, [{"type": "text", "text": "Report screen updated."}]),
    ])

    # 3) Excluded folder (Appetiser), Friday 10:00 Manila.
    sid, cwd = "cccc3333-0000-0000-0000-000000000003", "/Users/dev/appetiser/olie"
    write("-Users-dev-appetiser-olie", sid, [
        line("user", "2026-10-30T02:00:00.000Z", cwd, sid, "Write a QA bug report for the paywall"),
        line("assistant", "2026-10-30T02:05:00.000Z", cwd, sid, [tool("Write", "x1", file_path=cwd + "/bug.md")]),
    ])

    # 4) Unknown folder -> Needs review, Friday 14:00 Manila.
    sid, cwd = "dddd4444-0000-0000-0000-000000000004", "/Users/dev/sandbox/experiments"
    write("-Users-dev-sandbox-experiments", sid, [
        {"type": "ai-title", "aiTitle": "Charting library experiment", "sessionId": sid},
        line("user", "2026-10-30T06:00:00.000Z", cwd, sid, "Try a new charting lib for dashboards"),
        line("assistant", "2026-10-30T06:10:00.000Z", cwd, sid, [{"type": "text", "text": "Here is a demo."}]),
    ])
    print(f"Wrote fixtures to {OUT}")


if __name__ == "__main__":
    main()
