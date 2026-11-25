#!/bin/bash
# dsh-run.sh — 一键启动器（前台运行，与 wsl.exe 同生命周期）
#   已在运行 → 打开浏览器后退出
#   未运行   → 前台启动 dsh web，并在 URL 就绪后打开浏览器
# 关掉启动它的窗口 = 停止服务
# 用法: dsh-run.sh [--no-browser]
set -u

PORT=3080
LOG="$HOME/.local/state/dsh-web.log"
WS="${DSH_WORKSPACE:-$HOME/dsh-workspace}"
NO_BROWSER=0
[ "${1:-}" = "--no-browser" ] && NO_BROWSER=1

mkdir -p "$(dirname "$LOG")" "$WS"

is_up() { ss -lntH 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; }
get_token() { grep -o 'token=[A-Za-z0-9_-]*' "$LOG" 2>/dev/null | tail -1 | cut -d= -f2; }

open_url() {
  [ "$NO_BROWSER" = "1" ] && { echo "URL=$1"; return 0; }
  local c
  for c in /mnt/c/Windows/System32/cmd.exe /mnt/c/Windows/system32/cmd.exe; do
    if [ -x "$c" ]; then "$c" /c start "" "$1" >/dev/null 2>&1 && return 0; fi
  done
  echo "请手动打开: $1"
  return 1
}

# --- 已运行：只开浏览器 ---
if is_up; then
  T=$(get_token)
  if [ -n "$T" ]; then
    open_url "http://127.0.0.1:$PORT/?token=$T"
    exit 0
  fi
  # 端口在监听但没有 token：几乎可以确定不是本实例（dsh 启动必打印 token）
  echo "[error] port $PORT is held by another process (no token in log)" >>"$LOG"
  echo "port $PORT is held by another process"
  exit 2
fi

# --- 冷启动 ---
cd "$WS" || exit 1
: > "$LOG"
# 可选钩子：若你把代理配置放在 ~/.config/wsl/proxy.sh，这里 source 一次让 dsh 继承环境；
# 文件不存在则什么也不做。
[ -f "$HOME/.config/wsl/proxy.sh" ] && . "$HOME/.config/wsl/proxy.sh" --force >/dev/null 2>&1
# dsh 不支持 socks:// 形式的 all_proxy：会打印警告并对该 scheme 直连。
# 清掉它即可消除噪音，http_proxy / https_proxy 继续生效（2026-11-24 实测）。
unset all_proxy ALL_PROXY

# 等 URL 出现后打开浏览器（后台协程，不阻塞主进程）
(
  for _ in $(seq 1 90); do
    T=$(get_token)
    if [ -n "$T" ] && is_up; then open_url "http://127.0.0.1:$PORT/?token=$T"; exit 0; fi
    sleep 1
  done
) &

echo "[boot] $(date '+%F %T') workspace=$WS" >>"$LOG"
exec dsh web --no-open >>"$LOG" 2>&1
