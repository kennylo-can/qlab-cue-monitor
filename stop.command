#!/bin/bash
cd "$(dirname "$0")"
PIDFILE=".qlab-cue-monitor.pid"
PORT=8080
LSOF_BIN="/usr/sbin/lsof"

if [ -f "$PIDFILE" ]; then
  PID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    rm -f "$PIDFILE"
    echo "QLab Cue Monitor 已关闭。"
  else
    rm -f "$PIDFILE"
    echo "没有找到正在运行的服务。"
  fi
else
  PIDS=$("$LSOF_BIN" -ti tcp:$PORT 2>/dev/null)
  if [ -n "$PIDS" ]; then
    kill $PIDS
    rm -f "$PIDFILE"
    echo "已关闭占用 $PORT 端口的服务。"
  else
    echo "QLab Cue Monitor 没有在运行。"
  fi
fi

read -p "按回车关闭此窗口。"
