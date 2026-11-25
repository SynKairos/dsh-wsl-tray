#!/bin/bash
# dsh-stop.sh — stop the dsh-web systemd user unit and wait for the port to be
# released. Never kills by command-line pattern: another profile's dsh must not
# die because this one is stopped.
set -u

UNIT="${DSH_UNIT:-dsh-web}"
PORT="${DSH_PORT:-3080}"

is_up() { ss -lntH 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; }

systemctl --user stop "$UNIT" 2>/dev/null || true

for _ in $(seq 1 30); do
  is_up || exit 0
  sleep 0.3
done
echo "[warn] port $PORT is still bound after $UNIT stopped" >&2
exit 0
