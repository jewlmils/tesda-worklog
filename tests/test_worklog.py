"""Tests for worklog.py using synthetic transcripts. Run:  python3 -m unittest discover -s tests -v"""
import json
import os
import shutil
import stat
import sys
import tempfile
import time
import unittest
from datetime import date, datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp(prefix="worklog-test-"))

# Must be set before importing worklog: paths are read at import time.
os.environ["TZ"] = "Asia/Manila"
time.tzset()
os.environ["WORKLOG_HOME"] = str(TMP / "app")
os.environ["WORKLOG_REPORTS"] = str(TMP / "reports")
os.environ["WORKLOG_CLAUDE_PROJECTS"] = str(HERE / "fixtures" / "projects")
sys.path.insert(0, str(HERE.parent))
import worklog  # noqa: E402

FRI, THU, MON = date(2026, 10, 30), date(2026, 10, 29), date(2026, 11, 2)
TSP, TRACK = "TESDA Skills Passport (TSP)", "TESDA-TRACK"

CONFIG = {
    "projects": {TSP: ["/users/dev/work/tesda/tsp"], TRACK: ["/Users/dev/work/tesda/track"]},
    "exclude": ["/Users/dev/appetiser"],
    "workdays": ["Mon", "Tue", "Wed", "Thu", "Fri"],
    "model": "sonnet",
}

FAKE_OK = r"""#!/usr/bin/env python3
import json, os, sys
log = os.environ["FAKE_CLAUDE_LOG"]
json.dump({"argv": sys.argv[1:], "stdin": sys.stdin.read(), "cwd": os.getcwd()}, open(log, "w"))
print("```markdown\n# Daily Accomplishment Report — Friday, October 30, 2026\n\n## TESDA Skills Passport (TSP)\n\n"
      "**Accomplishments**\n- Added a liveness-check fallback bottom sheet\n```")
"""
FAKE_FAIL = "#!/bin/sh\necho 'Invalid API key · Please run /login'\nexit 1\n"


def fake_claude(body):
    path = TMP / f"fake-claude-{abs(hash(body))}"
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return str(path)


def setUpModule():
    (TMP / "app").mkdir(parents=True, exist_ok=True)
    (TMP / "app" / "config.json").write_text(json.dumps(CONFIG))


def tearDownModule():
    shutil.rmtree(TMP, ignore_errors=True)


def cfg(**overrides):
    c = worklog.load_config()
    c.update(overrides)
    return c


class Classification(unittest.TestCase):
    def test_project_subfolder_and_case_insensitive(self):
        self.assertEqual(worklog.classify("/Users/dev/work/TESDA/TSP/mobile", cfg()), ("project", TSP))
        self.assertEqual(worklog.classify("/Users/dev/work/tesda/track", cfg()), ("project", TRACK))

    def test_excluded_and_unknown(self):
        self.assertEqual(worklog.classify("/Users/dev/appetiser/olie", cfg()), ("exclude", None))
        self.assertEqual(worklog.classify("/Users/dev/sandbox", cfg()), ("review", None))

    def test_prefix_is_not_a_match(self):
        # "/tesda/track-old" is not inside "/tesda/track"
        self.assertEqual(worklog.classify("/Users/dev/work/tesda/track-old", cfg()), ("review", None))

    def test_most_specific_folder_wins(self):
        c = cfg(exclude=["/Users/dev/work"])
        self.assertEqual(worklog.classify("/Users/dev/work/tesda/tsp/x", c), ("project", TSP))
        self.assertEqual(worklog.classify("/Users/dev/work/other", c), ("exclude", None))

    def test_app_folder_is_always_excluded(self):
        self.assertEqual(worklog.classify(str(worklog.DATA_DIR), cfg()), ("exclude", None))


class Dates(unittest.TestCase):
    def test_monday_covers_friday(self):
        self.assertEqual(worklog.previous_workday(MON, {0, 1, 2, 3, 4}), FRI)

    def test_tuesday_covers_monday_and_weekend_covers_friday(self):
        self.assertEqual(worklog.previous_workday(date(2026, 11, 3), {0, 1, 2, 3, 4}), MON)
        self.assertEqual(worklog.previous_workday(date(2026, 11, 1), {0, 1, 2, 3, 4}), FRI)

    def test_custom_workdays(self):
        c = cfg(workdays=["Mon", "Tue", "Wed", "Thu", "Fri", "Sat"])
        c["_workdays"] = worklog.parse_workdays(c["workdays"])
        self.assertEqual(worklog.resolve_day("prev", c, today=MON), date(2026, 10, 31))

    def test_resolve_words_and_errors(self):
        self.assertEqual(worklog.resolve_day("today", cfg(), today=MON), MON)
        self.assertEqual(worklog.resolve_day("yesterday", cfg(), today=MON), date(2026, 11, 1))
        self.assertEqual(worklog.resolve_day("2026-10-30", cfg()), FRI)
        with self.assertRaises(worklog.WorklogError):
            worklog.resolve_day("next tuesday", cfg())

    def test_utc_to_local(self):
        self.assertEqual(worklog.local_time("2026-10-29T16:20:00.5Z"), datetime(2026, 10, 30, 0, 20, 0, 500000))
        self.assertIsNone(worklog.local_time("not a time"))


class Sessions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fri = {s["id"][:4]: s for s in worklog.read_sessions(FRI)}
        cls.thu = {s["id"][:4]: s for s in worklog.read_sessions(THU)}

    def test_found_all_friday_sessions(self):
        self.assertEqual(set(self.fri), {"aaaa", "bbbb", "cccc", "dddd"})

    def test_noise_is_skipped_and_pasted_content_unwrapped(self):
        self.assertEqual(self.fri["aaaa"]["prompts"], [
            "Add a fallback bottom sheet when the liveness check fails 3 times",   # once, despite duplicate
            "Spec: the sheet must offer Retry and Manual upload follow this spec",
            "Fix the lint errors too",
        ])

    def test_files_changed_skip_failed_and_sidechain(self):
        self.assertEqual(self.fri["aaaa"]["files"], ["src/LivenessSheet.tsx", "/Users/dev/shared/theme.ts"])

    def test_notable_commands_with_status(self):
        cmds = [(c["cmd"], c["ok"]) for c in self.fri["aaaa"]["commands"]]
        self.assertEqual(cmds, [("npm test -- --watch=false", True), ("npm run lint", False),
                                ('git commit -m "feat(liveness): add fallback bottom sheet"', True)])

    def test_shell_edits_are_evidence(self):
        self.assertEqual([c["cmd"] for c in self.fri["aaaa"]["shell_edits"]],
                         ["sed -i '' 's/RETRY_LIMIT = 2/RETRY_LIMIT = 3/' src/config.ts"])
        self.assertTrue(worklog.SHELL_EDIT.search("cd x && python3 - <<'EOF'\nopen(p,'w')"))
        self.assertFalse(worklog.SHELL_EDIT.search("cat README.md | grep x"))

    def test_title_times_and_last_reply(self):
        s = self.fri["aaaa"]
        self.assertEqual(s["title"], "Liveness check fallback bottom sheet")
        self.assertEqual((f"{s['start']:%H:%M}", f"{s['end']:%H:%M}"), ("09:00", "11:30"))
        self.assertTrue(s["last_reply"].startswith("Done: the fallback sheet"))

    def test_session_spanning_midnight_is_split(self):
        thu, fri = self.thu["bbbb"], self.fri["bbbb"]
        self.assertEqual(thu["prompts"], ["Start migrating TRACK reports to the new API"])
        self.assertEqual(thu["files"], ["src/api.ts"])
        self.assertEqual(f"{thu['start']:%H:%M}-{thu['end']:%H:%M}", "23:30-23:40")
        self.assertEqual(fri["prompts"], ["Now update the report screen"])
        self.assertEqual(fri["files"], ["src/ReportScreen.tsx"])
        self.assertEqual(f"{fri['start']:%H:%M}", "00:20")

    def test_grouping(self):
        tesda, review, excluded = worklog.group(worklog.read_sessions(FRI), cfg())
        self.assertEqual(list(tesda), [TSP, TRACK])
        self.assertEqual([s["id"][:4] for s in review], ["dddd"])
        self.assertEqual([s["id"][:4] for s in excluded], ["cccc"])

    def test_other_day_is_empty(self):
        self.assertEqual(worklog.read_sessions(date(2026, 10, 1)), [])


class ManualEntries(unittest.TestCase):
    def setUp(self):
        if worklog.MANUAL_LOG.exists():
            worklog.MANUAL_LOG.unlink()

    def test_add_and_read_by_day(self):
        worklog.add_manual("Attended TRACK sprint planning", "track", cfg(), on_day=FRI)
        worklog.add_manual("Today thing", TSP, cfg())
        fri = worklog.read_manual(FRI)
        self.assertEqual([(m["project"], m["text"]) for m in fri], [(TRACK, "Attended TRACK sprint planning")])

    def test_unknown_project_and_empty_text_are_errors(self):
        with self.assertRaises(worklog.WorklogError):
            worklog.add_manual("x", "Nope", cfg())
        with self.assertRaises(worklog.WorklogError):
            worklog.add_manual("   ", TSP, cfg())

    def test_cli_log(self):
        self.assertEqual(worklog.main(["log", "QA", "of", "TSP", "--project=TSP", "--date=2026-10-30"]), 0)
        self.assertEqual(worklog.read_manual(FRI)[0]["text"], "QA of TSP")


class Reports(unittest.TestCase):
    def setUp(self):
        if worklog.MANUAL_LOG.exists():
            worklog.MANUAL_LOG.unlink()
        worklog.add_manual("Coordinated UAT schedule with the regional office", TRACK, cfg(), on_day=FRI)

    def test_evidence_has_only_tesda(self):
        tesda, review, _ = worklog.group(worklog.read_sessions(FRI), cfg())
        ev = worklog.evidence_text(FRI, tesda, worklog.read_manual(FRI))
        self.assertIn("=== PROJECT: TESDA-TRACK ===", ev)
        self.assertIn("Coordinated UAT schedule", ev)
        self.assertIn("✓ $ git commit", ev)
        self.assertIn("✗ $ npm run lint", ev)
        for leaked in ("charting", "paywall", "SECRET_SIDECHAIN", "internal stuff", "broken.ts"):
            self.assertNotIn(leaked, ev.lower() if leaked.islower() else ev)

    def test_no_ai_report(self):
        meta = worklog.build_report(FRI, cfg(), use_ai=False)
        self.assertEqual((meta["ai"], meta["sessions"], meta["manual"], meta["review"]), ("off", 2, 1, 1))
        md = Path(meta["md"]).read_text()
        body, appendix = md.split(worklog.APPENDIX_MARK)
        self.assertIn("## TESDA-TRACK", body)
        self.assertIn("Coordinated UAT schedule", body)
        self.assertIn("Liveness check fallback bottom sheet", body)
        self.assertNotIn("experiments", body)                 # Needs review stays out of the report body
        self.assertIn("## Needs review", appendix)
        self.assertIn("/Users/dev/sandbox/experiments", appendix)
        self.assertNotIn("appetiser", md)                     # excluded: not even listed
        txt = Path(meta["txt"]).read_text()
        self.assertNotIn("Needs review", txt)
        self.assertNotIn("**", txt)
        html = Path(meta["html"]).read_text()
        self.assertIn("<h2>TESDA-TRACK</h2>", html)
        self.assertIn("<table>", html)
        self.assertEqual(json.loads(Path(meta["json"]).read_text())["day"], "2026-10-30")

    def test_ai_report_calls_claude_correctly(self):
        os.environ["FAKE_CLAUDE_LOG"] = str(TMP / "fake.json")
        meta = worklog.build_report(FRI, cfg(claude_path=fake_claude(FAKE_OK)), use_ai=True)
        self.assertEqual(meta["ai"], "ok")
        call = json.loads((TMP / "fake.json").read_text())
        argv = call["argv"]
        self.assertEqual(argv[0], "-p")
        self.assertIn("Never invent work", argv[1])
        for flag in ("--no-session-persistence", "--tools", "--model"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--tools") + 1], "")
        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")
        self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(worklog.DATA_DIR))
        self.assertIn("Coordinated UAT schedule", call["stdin"])
        self.assertNotIn("charting", call["stdin"].lower())
        md = Path(meta["md"]).read_text()
        self.assertTrue(md.startswith("# Daily Accomplishment Report"))   # code fence stripped
        self.assertIn("## Needs review", md)

    def test_ai_failure_falls_back_to_raw_evidence(self):
        meta = worklog.build_report(FRI, cfg(claude_path=fake_claude(FAKE_FAIL)), use_ai=True)
        self.assertEqual(meta["ai"], "failed")
        self.assertIn("isn't logged in", meta["error"])
        md = Path(meta["md"]).read_text()
        self.assertIn("The AI summary couldn't be written", md)
        self.assertIn("Coordinated UAT schedule", md)
        self.assertFalse(worklog.RUNNING_PATH.exists())

    def test_write_refused_falls_back_to_app_folder(self):
        real = worklog._atomic_write
        target = str(TMP / "reports")

        def refuse(path, text):
            if str(path).startswith(target):
                raise PermissionError(1, "Operation not permitted")
            return real(path, text)
        worklog._atomic_write = refuse
        try:
            meta = worklog.build_report(FRI, cfg(), use_ai=False)
        finally:
            worklog._atomic_write = real
        self.assertTrue(meta["md"].startswith(str(worklog.DEFAULT_REPORTS)))
        self.assertIn("didn't allow writing", meta["warning"])
        self.assertTrue(Path(meta["html"]).exists())

    def test_read_meta_uses_current_location(self):
        meta = worklog.build_report(FRI, cfg(), use_ai=False)
        stored = json.loads(Path(meta["json"]).read_text())
        stored["md"] = "/old/place/2026-10-30.md"
        Path(meta["json"]).write_text(json.dumps(stored))
        self.assertEqual(worklog.read_meta(FRI, cfg())["md"], meta["md"])

    def test_empty_day(self):
        meta = worklog.build_report(date(2026, 10, 1), cfg(), use_ai=True)   # must not call claude
        self.assertEqual(meta["ai"], "empty")
        self.assertIn("No TESDA work was captured", Path(meta["md"]).read_text())


class Scheduled(unittest.TestCase):
    def setUp(self):
        for p in (worklog.STATE_PATH, worklog.INBOX / "show.json"):
            if p.exists():
                p.unlink()
        self.calls = []
        self._notify, self._show, self._build = worklog.notify, worklog.show_report, worklog.build_report
        worklog.notify = lambda t, m: self.calls.append(("notify", t, m))
        worklog.show_report = lambda meta, wait=0: self.calls.append(("show", meta["day"])) or "window"

        def fake_build(day, c, use_ai=True, projects_dir=None):
            self.calls.append(("build", day.isoformat()))
            return self._build(day, c, use_ai=False)
        worklog.build_report = fake_build

    def tearDown(self):
        worklog.notify, worklog.show_report, worklog.build_report = self._notify, self._show, self._build

    def test_monday_8am_reports_friday_once(self):
        worklog.run_scheduled(cfg(), now=datetime(2026, 11, 2, 8, 0, 5))
        self.assertEqual(self.calls[0], ("build", "2026-10-30"))
        self.assertEqual(self.calls[1][1], "TESDA Worklog — report ready")
        self.assertRegex(self.calls[1][2], r"^\d+ sessions?, \d+ logged items? · \d+ to review$")
        self.assertEqual(self.calls[2], ("show", "2026-10-30"))
        self.calls.clear()
        worklog.run_scheduled(cfg(), now=datetime(2026, 11, 2, 9, 0))      # wake/login later: no repeat
        self.assertEqual(self.calls, [])

    def test_not_before_report_time_or_on_weekends(self):
        worklog.run_scheduled(cfg(), now=datetime(2026, 11, 2, 7, 59))
        worklog.run_scheduled(cfg(), now=datetime(2026, 10, 31, 9, 0))      # Saturday
        self.assertEqual(self.calls, [])


class Archive(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(worklog.ARCHIVE, ignore_errors=True)
        if worklog.STATE_PATH.exists():
            worklog.STATE_PATH.unlink()
        self.alerts = []

    tearDown = setUp

    def alert(self, title, message):
        self.alerts.append((title, message))

    def test_sync_copies_only_tesda_transcripts(self):
        self.assertEqual(worklog.archive_sync(cfg()), 2)
        names = sorted(f.name[:4] for f in worklog.archive_files())
        self.assertEqual(names, ["aaaa", "bbbb"])
        self.assertEqual(worklog.archive_sync(cfg()), 0)            # unchanged files aren't copied again

    def test_reports_still_work_after_claude_deletes_transcripts(self):
        worklog.archive_sync(cfg())
        empty = TMP / "no-live-transcripts"
        empty.mkdir(exist_ok=True)
        found = {s["id"][:4] for s in worklog.read_sessions(FRI, projects_dir=empty)}
        self.assertEqual(found, {"aaaa", "bbbb"})
        both = [s["id"][:4] for s in worklog.read_sessions(FRI)]  # live + archive: no duplicates
        self.assertEqual(sorted(both), ["aaaa", "bbbb", "cccc", "dddd"])

    def test_purge_dates(self):
        c = cfg()
        self.assertEqual(worklog.next_purge(c, date(2026, 11, 2)), date(2026, 12, 31))
        self.assertEqual(worklog.next_purge(c, date(2027, 1, 1)), date(2027, 6, 30))
        self.assertEqual(worklog.last_purge_due(c, date(2026, 12, 31)), date(2026, 6, 30))
        self.assertEqual(worklog.last_purge_due(c, date(2027, 1, 1)), date(2026, 12, 31))

    def test_alerts_before_and_purge_after_dec_31(self):
        c = cfg()
        run = lambda y, m, d: worklog.archive_maintenance(c, datetime(y, m, d, 8, 0), alert=self.alert)
        run(2026, 11, 2)                                 # first run: archives, no alert yet
        self.assertEqual((len(worklog.archive_files()), self.alerts), (2, []))
        run(2026, 12, 24)                                # 7 days before: alert
        run(2026, 12, 25)                                # no repeat
        self.assertEqual(len(self.alerts), 1)
        self.assertIn("2 archived TESDA session", self.alerts[0][1])
        self.assertIn("December 31", self.alerts[0][1])
        run(2026, 12, 31)                                # on the day: last-chance alert
        self.assertEqual(len(self.alerts), 2)
        self.assertIn("tonight", self.alerts[1][0])
        self.assertEqual(len(worklog.archive_files()), 2)  # nothing deleted yet
        run(2027, 1, 1)                                  # the morning after: purged
        self.assertEqual(worklog.archive_files(), [])
        run(2027, 1, 2)                                  # old live transcripts aren't re-archived
        self.assertEqual(worklog.archive_files(), [])
        self.assertTrue((HERE / "fixtures" / "projects").exists())   # ~/.claude/projects is never touched

    def test_export_zip(self):
        worklog.archive_sync(cfg())
        out = worklog.archive_export(cfg())
        import zipfile
        self.assertEqual(len(zipfile.ZipFile(out).namelist()), 2)


class Rendering(unittest.TestCase):
    def test_markdown_to_html(self):
        out = worklog.md_to_html("# T\n\n**Accomplishments**\n- a `x<y>`\n  - nested\n- b\n\n> warn\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        self.assertIn("<h1>T</h1>", out)
        self.assertIn("<code>x&lt;y&gt;</code>", out)
        self.assertIn("<ul><li>a <code>x&lt;y&gt;</code>\n<ul><li>nested\n</li></ul>\n</li><li>b", out)
        self.assertIn("<blockquote>", out)
        self.assertIn("<td>2</td>", out)

    def test_clean_ai_output(self):
        t = "# Daily Accomplishment Report — X"
        self.assertEqual(worklog.clean_ai_output("Sure! Here it is:\n\n# Daily Accomplishment Report — X\n- a", t),
                         "# Daily Accomplishment Report — X\n- a")
        self.assertTrue(worklog.clean_ai_output("- just bullets", t).startswith(t))


if __name__ == "__main__":
    unittest.main()
