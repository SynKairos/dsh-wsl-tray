#!/bin/bash
# dsh-serve.sh — foreground server for the systemd user unit.
# systemd owns the process lifetime; this script only prepares the environment
# and hands over to `dsh web`. No daemonizing, no browser, no port hunting.
set -u

WS="${DSH_WORKSPACE:-$HOME/dsh-workspace}"
LOG_DIR="$HOME/.local/state"

mkdir -p "$LOG_DIR" "$WS"

# Optional per-machine proxy hook (same contract as the manual launcher).
if [ -f "$HOME/.config/wsl/proxy.sh" ]; then
  . "$HOME/.config/wsl/proxy.sh" --force >/dev/null 2>&1 || true
fi
# dsh does not support socks:// URLs in all_proxy: it warns and connects
# directly, so drop it. http_proxy / https_proxy stay in effect.
unset all_proxy ALL_PROXY

cd "$WS" || exit 1
# Stderr goes to the same append-only log the tray reads. The marker lets the
# tray tell a token from the current run apart from a stale one left behind.
echo "[boot] $(date '+%F %T') workspace=$WS" >&2

# The listener port comes from the unit's Environment=DSH_PORT, so the port is
# configured in one place per side (tray config + unit) instead of in scripts.
if [ -n "${DSH_PORT:-}" ]; then
  exec dsh web --no-open --port "$DSH_PORT"
fi
exec dsh web --no-open
