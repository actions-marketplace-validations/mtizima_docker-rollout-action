#!/usr/bin/env bash
# Traffic during a deploy: `load.sh start <log>` hammers the app until `load.sh stop <log>`,
# which prints the stats and fails if any request was not a 200.
set -euo pipefail
url="http://127.0.0.1:${TRAEFIK_PORT:-18080}/"
log="$2"

case "$1" in
start)
  : >"$log"
  rm -f "$log.stop"
  (
    while [[ ! -f "$log.stop" ]]; do
      curl -s -o /dev/null --max-time 5 -w '%{http_code}\n' "$url" >>"$log" || echo "curl-error" >>"$log"
      sleep 0.02
    done
  ) &
  echo $! >"$log.pid"
  ;;
stop)
  touch "$log.stop"
  wait "$(cat "$log.pid")" 2>/dev/null || while kill -0 "$(cat "$log.pid")" 2>/dev/null; do sleep 0.1; done
  total=$(wc -l <"$log")
  failed=$(grep -vcx 200 "$log" || true)
  echo "requests: $total, failed: $failed"
  if ((failed > 0)); then
    sort "$log" | uniq -c
    exit 1
  fi
  ((total >= 50)) || { echo "too few requests to be meaningful"; exit 1; }
  ;;
esac
