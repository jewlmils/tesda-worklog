#!/bin/bash
# Removes TESDA Worklog's background jobs, menu bar app and `worklog` command.
# Your config, manual log and reports are KEPT unless you pass --all (reports are never deleted).
#
#   bash uninstall.sh          # remove the app, keep your data
#   bash uninstall.sh --all    # also delete config.json, the manual log and logs
set -uo pipefail
APP="$HOME/Library/Application Support/TESDA-Worklog"
GUI="gui/$(id -u)"

for JOB in ph.tesda.worklog.report ph.tesda.worklog.menubar; do
  launchctl bootout "$GUI/$JOB" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$JOB.plist"
done
if grep -q "Installed by TESDA Worklog" "$HOME/.local/bin/worklog" 2>/dev/null; then
  rm -f "$HOME/.local/bin/worklog"
fi
rm -rf "$HOME/Applications/TESDA Worklog.app"
rm -f "$APP/TESDAWorklog" "$APP/worklog.py"
# Unpin from the Dock if it was pinned (install.sh --dock).
if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "TESDA%20Worklog.app"; then
  /usr/bin/python3 - <<'PY'
import plistlib, subprocess
raw = subprocess.run(["defaults", "export", "com.apple.dock", "-"], capture_output=True).stdout
dock = plistlib.loads(raw)
dock["persistent-apps"] = [a for a in dock.get("persistent-apps", [])
                           if "TESDA%20Worklog.app" not in str(a.get("tile-data", {}).get("file-data", {}).get("_CFURLString", ""))]
subprocess.run(["defaults", "import", "com.apple.dock", "-"], input=plistlib.dumps(dock))
PY
  killall Dock
fi
rm -rf "$APP/inbox" "$APP/running.json"

if [ "${1:-}" = "--all" ]; then
  rm -rf "$APP"
  echo "Removed TESDA Worklog and its data. Your reports are still in ~/Documents/TESDA-Worklog/reports."
else
  echo "Removed TESDA Worklog. Kept your data in: $APP"
  echo "(config.json, manual_log.jsonl, logs). Reports are in ~/Documents/TESDA-Worklog/reports."
  echo "To delete the data too: bash uninstall.sh --all"
fi
