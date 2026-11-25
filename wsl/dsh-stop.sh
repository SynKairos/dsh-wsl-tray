#!/bin/bash
# 停止 dsh（供托盘"停止服务"调用）
pkill -f 'dsh web' 2>/dev/null
for i in $(seq 1 10); do
  ss -lntH 2>/dev/null | awk '$4 ~ /:3080$/' | grep -q . || exit 0
  sleep 0.3
done
exit 0
