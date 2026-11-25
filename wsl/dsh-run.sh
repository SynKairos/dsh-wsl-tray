#!/bin/bash
# dsh-run.sh — manual CLI launcher kept for terminals (the tray no longer uses
# it). Starts the systemd unit and, unless --no-browser is given, opens the Web
# UI with the current process token.
#
#   dsh-run.sh               start the service and open the browser
#   dsh-run.sh --no-browser  start the service and print URL=<...>
set -u

UNIT="${DSH_UNIT:-dsh-web}"
PORT="${DSH_PORT:-3080}"
LOG="${DSH_LOG:-$HOME/.local/state/dsh-web.log}"
NO_BROWSER=0
[ "${1:-}" = "--no-browser" ] && NO_BROWSER=1

is_up() { ss -lntH 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; }
# Only the token printed after the newest [boot] marker belongs to this run.
get_token() {
  awk '/\[boot\]/{t=""} { if (match($0, /token=[A-Za-z0-9_-]+/)) t=substr($0, RSTART+6, RLENGTH-6) } END{print t}' "$LOG" 2>/dev/null
}
open_url() {
  [ "$NO_BROWSER" = "1" ] && { echo "URL=$1"; return 0; }
  local c
  for c in /mnt/c/Windows/System32/cmd.exe /mnt/c/Windows/system32/cmd.exe; do
    if [ -x "$c" ]; then "$c" /c start "" "$1" >/dev/null 2>&1 && return 0; fi
  done
  echo "open manually: $1"
  return 1
}

if ! systemctl --user start "$UNIT" 2>/dev/null; then
  echo "[error] systemctl --user start $UNIT failed" >&2
  echo "        is the unit installed (tools/install.ps1) and linger enabled?" >&2
  exit 1
fi

for _ in $(seq 1 60); do
  T=$(get_token)
  if [ -n "$T" ] && is_up; then
    open_url "http://127.0.0.1:$PORT/?token=$T"
    exit 0
  fi
  sleep 1
done

echo "[error] port $PORT did not come up within 60s" >&2
exit 1
