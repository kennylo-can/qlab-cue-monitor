#!/bin/bash
cd "$(dirname "$0")"
PORT=8080
PIDFILE=".qlab-cue-monitor.pid"
LOGFILE="server.log"
NODE_BIN="/Applications/Codex.app/Contents/Resources/node"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "QLab Cue Monitor 已经在运行。"
else
  nohup "$NODE_BIN" server.js > "$LOGFILE" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
fi

IP=$(ipconfig getifaddr en0)
if [ -z "$IP" ]; then IP=$(ipconfig getifaddr en1); fi
if [ -z "$IP" ]; then IP="你的电脑IP"; fi

URL="http://$IP:$PORT/index.html"
LOCAL="http://127.0.0.1:$PORT/index.html"

echo ""
echo "QLab Cue Monitor 已启动"
echo "本机访问: $LOCAL"
echo "局域网访问: $URL"
echo ""
echo "如需关闭，请双击 stop.command"
echo ""
open "$LOCAL"
read -p "按回车关闭此窗口。服务会继续运行。"
