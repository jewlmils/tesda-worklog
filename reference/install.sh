#!/bin/bash
# TESDA Worklog installer (macOS). Run from inside the TESDA-Worklog folder:
#   bash install.sh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"
REPORT_JOB="ph.tesda.worklog.report"
MENU_JOB="ph.tesda.worklog.menubar"

PY="$(command -v python3 || true)"
[ -z "$PY" ] && { echo "python3 not found. Run: xcode-select --install"; exit 1; }
CLAUDE="$(command -v claude || true)"
[ -z "$CLAUDE" ] && echo "⚠️  'claude' not found on PATH — set claude_path in config.json later."

cd "$DIR"
"$PY" worklog.py projects >/dev/null           # creates config.json on first run
"$PY" - "$CLAUDE" <<'EOF'
import json, sys
cfg = json.load(open("config.json"))
if sys.argv[1]:
    cfg["claude_path"] = sys.argv[1]
json.dump(cfg, open("config.json", "w"), indent=2)
EOF

ENV_PATH="$(dirname "$CLAUDE"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$AGENTS" "$DIR/logs"

# 1) Morning report: weekdays 8:00 AM (runs on wake if the Mac was asleep)
cat > "$AGENTS/$REPORT_JOB.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$REPORT_JOB</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>$DIR/worklog.py</string><string>report</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$ENV_PATH</string></dict>
  <key>StartCalendarInterval</key><array>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>2</integer><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>4</integer><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>5</integer><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
  </array>
  <key>StandardOutPath</key><string>$DIR/logs/report.log</string>
  <key>StandardErrorPath</key><string>$DIR/logs/report.log</string>
</dict></plist>
EOF

# 2) Menu bar icon (optional — needs the Swift compiler from Xcode Command Line Tools)
MENU_OK=0
if command -v swiftc >/dev/null; then
  echo "Building menu bar icon…"
  swiftc -O menubar.swift -o TESDAWorklog && MENU_OK=1
else
  echo "⚠️  swiftc not found — skipping menu bar icon (install with: xcode-select --install)"
fi
if [ "$MENU_OK" = 1 ]; then
cat > "$AGENTS/$MENU_JOB.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$MENU_JOB</string>
  <key>ProgramArguments</key><array><string>$DIR/TESDAWorklog</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$ENV_PATH</string>
    <key>WORKLOG_PYTHON</key><string>$PY</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$DIR/logs/menubar.log</string>
</dict></plist>
EOF
fi

for JOB in $REPORT_JOB $MENU_JOB; do
  [ -f "$AGENTS/$JOB.plist" ] || continue
  launchctl bootout "gui/$UID_NUM/$JOB" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$AGENTS/$JOB.plist"
done

echo
echo "✅ Installed."
echo "   • Weekday 8:00 AM report → $DIR/reports/"
[ "$MENU_OK" = 1 ] && echo "   • Menu bar icon (checklist) is running and starts at login"
echo
echo "Next: tell it which folders are TESDA work."
echo "   1. See every folder you've used Claude in:   python3 worklog.py folders"
echo "   2. Put your TESDA ones in:                   open config.json"
echo "   3. Try a report right now:                   python3 worklog.py report"
