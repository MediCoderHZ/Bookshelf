#!/bin/sh
# A short-lived child inherits the app sandbox. Arguments are never evaluated as
# shell source. It opens the exact same bundle only after its parent has exited.
set -eu
parent_pid=${1:-}
application_path=${2:-}
case "$parent_pid" in ''|*[!0-9]*) exit 64 ;; esac
[ "$parent_pid" -gt 1 ] && [ "$parent_pid" = "$PPID" ] || exit 64
[ -d "$application_path" ] && [ -f "$application_path/Contents/Info.plist" ] || exit 66

printf 'READY\n'
IFS= read -r command || exit 0
[ "$command" = 'RELAUNCH' ] || exit 0

# The parent's pipe closes on exit. This gate does not depend on permission to
# query another PID. A cancelled quit terminates this child and closes the pipe.
if IFS= read -r command; then exit 0; fi

# Allow the old process to finish exiting before asking Launch Services to open
# the bundle. Never terminate the parent ourselves.
attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || exit 75
  /bin/sleep 0.1
done
# Launch Services can retain the old application's record after its PID exits.
# A normal open may be delivered to that dying instance and silently do nothing.
# Only after the exit gates above, explicitly launch a fresh process of this
# exact bundle. -a identifies the application rather than opening it as a file.
exec /usr/bin/open -n -a "$application_path"
