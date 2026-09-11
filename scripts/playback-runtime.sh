#!/usr/bin/env bash
set -euo pipefail

action=${1:-}
if [[ -z $action ]]; then
  echo "Usage: scripts/playback-runtime.sh check|start|stop|restart|status|socket" >&2
  exit 2
fi

unit=ytwidget.service
bin="$HOME/.local/bin/ytwidget-server"

socket_file() {
  printf '%s/ytwidget/backend.sock\n' "${XDG_RUNTIME_DIR:-/tmp}"
}

runtime_ready() {
  [[ -x $bin ]] && systemctl --user cat "$unit" >/dev/null 2>&1 \
    && command -v mpv >/dev/null 2>&1 && command -v yt-dlp >/dev/null 2>&1
}

probe_socket() {
  python3 - "$1" <<'PY'
import socket
import sys

path = sys.argv[1]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2.0)
try:
    sock.connect(path)
    data = b""
    while b"\n" not in data and len(data) < 262144:
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
    raise SystemExit(0 if b"\n" in data else 1)
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

wait_healthy() {
  local sock
  sock=$(socket_file)
  for _ in $(seq 1 30); do
    if systemctl --user is-active --quiet "$unit" \
        && [[ -S $sock ]] \
        && probe_socket "$sock"; then
      return 0
    fi
    sleep 0.2
  done
  echo "playback-runtime.sh: backend did not become healthy" >&2
  return 1
}

case $action in
  check)
    runtime_ready
    ;;
  start)
    runtime_ready || { echo "playback-runtime.sh: not installed yet" >&2; exit 1; }
    systemctl --user is-active --quiet "$unit" || systemctl --user start "$unit"
    wait_healthy
    ;;
  stop)
    systemctl --user stop "$unit" 2>/dev/null || true
    ;;
  restart)
    runtime_ready || { echo "playback-runtime.sh: not installed yet" >&2; exit 1; }
    systemctl --user restart "$unit"
    wait_healthy
    ;;
  status)
    runtime_ready || exit 1
    systemctl --user is-active "$unit"
    ;;
  socket)
    printf '%s\n' "$(socket_file)"
    ;;
  *)
    echo "playback-runtime.sh: unknown action: $action" >&2
    exit 2
    ;;
esac
