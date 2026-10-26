#!/bin/bash
# login-agent.sh install|remove - a one-shot LaunchAgent that runs the harness's login section (240 s of WindowServer
# CPU and flips per second) at the next login, for the "no hitch right after login" row. It removes itself after the
# run, so one install measures one login. Results land in ~/rtx2060-runs/<date>-login/ like any run.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/local.rtx2060.login.plist"
case "${1:-}" in
    install)
        cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.rtx2060.login</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>-c</string>
    <string>"$HERE/run.sh" --label login --only state,login; rm -f "$PLIST"; launchctl bootout gui/\$(id -u)/local.rtx2060.login</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
        echo "installed: the next login is measured" ;;
    remove) rm -f "$PLIST"; echo "removed" ;;
    *) sed -n '2,4p' "$0"; exit 2 ;;
esac
