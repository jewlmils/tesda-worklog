#!/bin/bash
# TESDA Worklog installer for macOS.
#
#   bash install.sh
#
# Safe to run again: after you change the code, run it to update the installed copy.
# It copies the app OFF the external drive into ~/Library/Application Support/TESDA-Worklog,
# compiles the menu bar app, creates config.json if it's missing (never overwrites it),
# installs the `worklog` command, and (re)loads two LaunchAgents:
#   ph.tesda.worklog.report   - the morning report (and catch-up at login)
#   ph.tesda.worklog.menubar  - the menu bar icon, started at login
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Library/Application Support/TESDA-Worklog"
AGENTS="$HOME/Library/LaunchAgents"
BIN_DIR="$HOME/.local/bin"
REPORT_JOB="ph.tesda.worklog.report"
MENU_JOB="ph.tesda.worklog.menubar"
GUI="gui/$(id -u)"

say() { printf '%s\n' "$*"; }
die() { say "❌ $*"; exit 1; }

# 1. Requirements -------------------------------------------------------------
PY="$(command -v python3 || true)"
[ -n "$PY" ] || die "python3 not found. Install Apple's Command Line Tools: xcode-select --install"
"$PY" -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "Python 3.9 or newer is needed ($PY is older)."
command -v swiftc >/dev/null || die "swiftc not found. Install Apple's Command Line Tools: xcode-select --install"
CLAUDE="$(command -v claude || true)"
[ -n "$CLAUDE" ] || say "⚠️  'claude' isn't on your PATH. AI summaries won't work until you set claude_path in config.json."

# 2. Copy the app off the external drive -----------------------------------------
mkdir -p "$APP/logs" "$APP/inbox" "$AGENTS" "$BIN_DIR"
cp "$SRC/worklog.py" "$APP/.worklog.py.new" && mv "$APP/.worklog.py.new" "$APP/worklog.py"
say "Compiling the menu bar app (takes ~30 s)…"
swiftc -O "$SRC/menubar.swift" -o "$APP/.TESDAWorklog.new"
mv "$APP/.TESDAWorklog.new" "$APP/TESDAWorklog"

# 3. Config (created once; your edits are kept) -------------------------------------
"$PY" "$APP/worklog.py" init --claude-path="$CLAUDE"
REPORT_TIME="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("report_time","08:00"))' "$APP/config.json")"
HOUR=$((10#${REPORT_TIME%%:*})); MINUTE=$((10#${REPORT_TIME##*:}))

# 3b. Reports live in the app folder (macOS stops background jobs from rewriting files in
#     ~/Documents). ~/Documents/TESDA-Worklog/reports is a link to it, so you can find them there.
REPORTS="$("$PY" "$APP/worklog.py" paths --json | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["reports_dir"])')"
DOCS_LINK="$HOME/Documents/TESDA-Worklog/reports"
if [ "$REPORTS" = "$APP/reports" ]; then
  mkdir -p "$REPORTS" "$(dirname "$DOCS_LINK")"
  if [ -L "$DOCS_LINK" ] || [ ! -e "$DOCS_LINK" ]; then
    ln -sfn "$REPORTS" "$DOCS_LINK"
  else
    # A real folder from an older version: move the reports over (never overwriting), then link.
    for f in "$DOCS_LINK"/*.md "$DOCS_LINK"/*.html "$DOCS_LINK"/*.txt "$DOCS_LINK"/*.json; do
      [ -e "$f" ] && mv -n "$f" "$REPORTS"/
    done
    if rmdir "$DOCS_LINK" 2>/dev/null; then
      ln -s "$REPORTS" "$DOCS_LINK"
      say "Moved your reports to $REPORTS (linked from $DOCS_LINK)."
    else
      say "⚠️  $DOCS_LINK still has other files in it, so I left it alone."
      say "   Reports are now saved in $REPORTS. Move anything you need out of the old folder, delete it,"
      say "   and run install.sh again to create the link."
    fi
  fi
fi

# 4. The `worklog` command ------------------------------------------------------------
cat > "$BIN_DIR/worklog" <<SH
#!/bin/sh
# Installed by TESDA Worklog (install.sh)
exec "$PY" "$APP/worklog.py" "\$@"
SH
chmod +x "$BIN_DIR/worklog"

# 5. LaunchAgents -------------------------------------------------------------------
# launchd starts jobs with a bare PATH, so give it the folders where claude and python3 live.
JOB_PATH="$BIN_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[ -n "$CLAUDE" ] && JOB_PATH="$(dirname "$CLAUDE"):$JOB_PATH"

cat > "$AGENTS/$REPORT_JOB.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$REPORT_JOB</string>
  <key>ProgramArguments</key><array>
    <string>$PY</string><string>$APP/worklog.py</string><string>report</string><string>--scheduled</string>
  </array>
  <key>WorkingDirectory</key><string>$APP</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$JOB_PATH</string>
    <key>LANG</key><string>en_US.UTF-8</string>
  </dict>
  <!-- Every day at $REPORT_TIME; worklog.py skips non-workdays. If the Mac is asleep, launchd runs it on wake. -->
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>$MINUTE</integer>
  </dict>
  <!-- Also at login, to catch up if the Mac was off at $REPORT_TIME (it runs at most once a day). -->
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$APP/logs/report.log</string>
  <key>StandardErrorPath</key><string>$APP/logs/report.log</string>
</dict></plist>
PLIST

cat > "$AGENTS/$MENU_JOB.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$MENU_JOB</string>
  <key>ProgramArguments</key><array><string>$APP/TESDAWorklog</string></array>
  <key>WorkingDirectory</key><string>$APP</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$JOB_PATH</string>
    <key>LANG</key><string>en_US.UTF-8</string>
    <key>WORKLOG_PYTHON</key><string>$PY</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <!-- Restart it if it crashes, but not after you choose Quit. -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$APP/logs/menubar.log</string>
  <key>StandardErrorPath</key><string>$APP/logs/menubar.log</string>
</dict></plist>
PLIST

for JOB in "$MENU_JOB" "$REPORT_JOB"; do
  plutil -lint -s "$AGENTS/$JOB.plist" || die "$JOB.plist is invalid"
  launchctl bootout "$GUI/$JOB" 2>/dev/null || true
  for _ in 1 2 3 4 5; do                       # bootout can take a moment to finish
    launchctl bootstrap "$GUI" "$AGENTS/$JOB.plist" 2>/dev/null && break
    sleep 1
  done
  launchctl print "$GUI/$JOB" >/dev/null 2>&1 || die "Couldn't load $JOB. Try: launchctl bootstrap $GUI \"$AGENTS/$JOB.plist\""
done

# 6. Done -------------------------------------------------------------------------------
say ""
say "✅ TESDA Worklog is installed."
say "   App + config:  $APP"
say "   Reports:       $REPORTS"
[ -L "$DOCS_LINK" ] && say "                  (also at $DOCS_LINK)"
say "   Morning report: every workday at $REPORT_TIME (covers the previous workday)"
say "   Menu bar icon:  running now, starts at login"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) say "   ⚠️  Add $BIN_DIR to your PATH to use the 'worklog' command.";; esac
say ""
say "Next: tell it which folders are TESDA work."
say "   worklog folders          # every folder you've used Claude Code in"
say "   open \"$APP/config.json\""
say "   worklog report today     # try it"
