#!/bin/bash
# Removes the background jobs. Your reports and logs in this folder are kept.
for JOB in ph.tesda.worklog.report ph.tesda.worklog.menubar; do
  launchctl bootout "gui/$(id -u)/$JOB" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$JOB.plist"
done
echo "Background jobs removed. Delete this folder to remove everything."
