#!/bin/bash
# dsh-log.sh — print the tail of the dsh web log in a console window (tray fallback)
LOG="$HOME/.local/state/dsh-web.log"
if [ ! -f "$LOG" ]; then
  echo "log not found: $LOG"
  echo "press Enter to close"
  read -r _
  exit 1
fi
echo "== $LOG ($(wc -l <"$LOG") lines) =="
tail -n 200 "$LOG"
echo
echo "press Enter to close"
read -r _
