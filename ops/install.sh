#!/bin/bash
#
# ops/install.sh — bring up the skillz MCP surface, its smoke-alarm and a
# dedicated adhd instance; optionally start the lab's wan-ingress in front.
#
#   ops/install.sh up [--with-ingress]
#   ops/install.sh down
#   ops/install.sh status
#   ops/install.sh doctor
#   ops/install.sh logs [-f]
#   ops/install.sh ingress           # start only the ingress
#   ops/install.sh render            # write state/ops/* without starting
#
# Everything generated lives under state/ops/ (gitignored). Secrets are created
# once with mode 600 and reused; delete state/ops/secrets.env to rotate them.
#
# SECURITY: the MCP server, alarm and adhd bind loopback. The only public
# listener is the ingress, which requires a bearer token and forwards through a
# signed border. Do not widen any of these binds to work around a failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPS="$ROOT/ops"
STATE="$ROOT/state/ops"
LOGS="$STATE/logs"
ALARM_STATE="$ROOT/state/alarm"

BIN="${SKILLZ_BIN:-$ROOT/bin/skillz}"
SMOKE="${OCD_SMOKE_ALARM:-$HOME/.lezz/bin/ocd-smoke-alarm}"
ADHD="${ADHD_BIN:-$HOME/.lezz/bin/adhd}"

MCP_PORT="${SKILLZ_MCP_PORT:-8090}"
ALARM_PORT="${SKILLZ_ALARM_PORT:-18098}"
ADHD_PORT="${SKILLZ_ADHD_PORT:-9091}"
INGRESS_PORT="${SKILLZ_INGRESS_PORT:-8443}"
WATCH_INGRESS="${SKILLZ_WATCH_INGRESS:-0}"

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

need() {
  [ -x "$1" ] || { echo "missing executable: $1" >&2; return 1; }
}

pid_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

read_pid() {
  [ -f "$1" ] && cat "$1" 2>/dev/null || true
}

port_free() {
  python3 - "$1" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", port))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

wait_http() {
  local url="$1" i
  for i in $(seq 1 60); do
    if curl -fsS --max-time 1 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

wait_port() {
  python3 - "$1" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
for _ in range(60):
    s = socket.socket()
    s.settimeout(0.2)
    try:
        s.connect(("127.0.0.1", port))
        s.close()
        sys.exit(0)
    except OSError:
        s.close()
        time.sleep(0.2)
sys.exit(1)
PY
}

render_one() {
  local src="$1" dst="$2"
  shift 2
  sed "$@" "$src" > "$dst"
  chmod 600 "$dst" 2>/dev/null || true
}

render() {
  mkdir -p "$STATE" "$LOGS" "$ALARM_STATE" "$ROOT/cache/external"
  chmod 700 "$STATE" 2>/dev/null || true

  if [ ! -f "$STATE/secrets.env" ]; then
    umask 077
    {
      printf 'SKILLZ_BORDER_KEY=%s\n' "$(openssl rand -hex 32)"
      printf 'SKILLZ_INGRESS_TOKEN=%s\n' "$(openssl rand -hex 32)"
    } > "$STATE/secrets.env"
  fi
  chmod 600 "$STATE/secrets.env"
  # shellcheck disable=SC1091
  . "$STATE/secrets.env"
  printf '%s' "$SKILLZ_BORDER_KEY" > "$STATE/border.key"
  chmod 600 "$STATE/border.key"

  local ingress_enabled="false"
  [ "$WATCH_INGRESS" = "1" ] && ingress_enabled="true"

  render_one "$OPS/smoke-alarm.yaml.tmpl" "$STATE/smoke-alarm.yaml" \
    -e "s|@ROOT@|$ROOT|g" \
    -e "s|@ALARM_PORT@|$ALARM_PORT|g" \
    -e "s|@MCP_PORT@|$MCP_PORT|g" \
    -e "s|@INGRESS_PORT@|$INGRESS_PORT|g" \
    -e "s|@ALARM_STATE@|$ALARM_STATE|g" \
    -e "s|@INGRESS_ENABLED@|$ingress_enabled|g"

  render_one "$OPS/adhd.yaml.tmpl" "$STATE/adhd.yaml" \
    -e "s|@ADHD_PORT@|$ADHD_PORT|g" \
    -e "s|@ALARM_PORT@|$ALARM_PORT|g"

  render_one "$OPS/ingress-agreement.json.tmpl" "$STATE/agreements.json" \
    -e "s|@MCP_PORT@|$MCP_PORT|g"

  render_one "$OPS/wan-ingress.json.tmpl" "$STATE/wan-ingress.json" \
    -e "s|@INGRESS_PORT@|$INGRESS_PORT|g" \
    -e "s|@ALARM_PORT@|$ALARM_PORT|g" \
    -e "s|@STATE@|$STATE|g" \
    -e "s|@TOKEN@|$SKILLZ_INGRESS_TOKEN|g" \
    -e "s|@BORDER_KEY@|$SKILLZ_BORDER_KEY|g"

  # Fail closed: the generated ingress config must not be world-readable.
  chmod 600 "$STATE/wan-ingress.json" "$STATE/border.key" "$STATE/secrets.env"
}

start_mcp() {
  local pid
  pid="$(read_pid "$STATE/mcp.pid")"
  if pid_alive "$pid"; then
    echo "mcp: already running (pid $pid)"
    return 0
  fi
  if ! port_free "$MCP_PORT"; then
    echo "mcp: port $MCP_PORT is busy" >&2
    return 1
  fi
  nohup "$BIN" serve --port "$MCP_PORT" --border-key-file "$STATE/border.key" \
    >>"$LOGS/mcp.log" 2>&1 &
  echo $! > "$STATE/mcp.pid"
  if ! wait_http "http://127.0.0.1:$MCP_PORT/readyz"; then
    echo "mcp: did not become ready; tail of $LOGS/mcp.log:" >&2
    tail -n 20 "$LOGS/mcp.log" >&2 || true
    return 1
  fi
  echo "mcp: http://127.0.0.1:$MCP_PORT/mcp (pid $(cat "$STATE/mcp.pid"))"
}

start_alarm() {
  local pid
  pid="$(read_pid "$STATE/alarm.pid")"
  if pid_alive "$pid"; then
    echo "alarm: already running (pid $pid)"
    return 0
  fi
  if ! port_free "$ALARM_PORT"; then
    echo "alarm: port $ALARM_PORT is busy" >&2
    return 1
  fi
  nohup "$SMOKE" serve --config="$STATE/smoke-alarm.yaml" --mode=foreground -tui=false \
    >>"$LOGS/alarm.log" 2>&1 &
  echo $! > "$STATE/alarm.pid"
  if ! wait_http "http://127.0.0.1:$ALARM_PORT/healthz"; then
    echo "alarm: did not become ready; tail of $LOGS/alarm.log:" >&2
    tail -n 20 "$LOGS/alarm.log" >&2 || true
    return 1
  fi
  echo "alarm: http://127.0.0.1:$ALARM_PORT/status (pid $(cat "$STATE/alarm.pid"))"
}

start_adhd() {
  local pid
  pid="$(read_pid "$STATE/adhd.pid")"
  if pid_alive "$pid"; then
    echo "adhd: already running (pid $pid)"
    return 0
  fi
  if ! port_free "$ADHD_PORT"; then
    echo "adhd: port $ADHD_PORT is busy" >&2
    return 1
  fi
  nohup "$ADHD" --headless --config "$STATE/adhd.yaml" \
    >"$LOGS/adhd.jsonl" 2>"$LOGS/adhd.err" &
  echo $! > "$STATE/adhd.pid"
  if ! wait_port "$ADHD_PORT"; then
    echo "adhd: did not listen; tail of $LOGS/adhd.err:" >&2
    tail -n 20 "$LOGS/adhd.err" >&2 || true
    return 1
  fi
  echo "adhd: http://127.0.0.1:$ADHD_PORT/mcp (pid $(cat "$STATE/adhd.pid"))"
}

find_ingress_bin() {
  if [ -n "${WAN_INGRESS_BIN:-}" ]; then
    printf '%s' "$WAN_INGRESS_BIN"
    return 0
  fi
  if command -v wan-ingress >/dev/null 2>&1; then
    command -v wan-ingress
    return 0
  fi
  return 1
}

start_ingress() {
  local porch
  porch="$(find_ingress_bin || true)"
  if [ -z "$porch" ]; then
    cat >&2 <<'EOF'
ingress: no wan-ingress binary found.
  Set WAN_INGRESS_BIN=/path/to/wan-ingress, or install it on PATH.
  This is an optional integration for the author's lab; the core install does
  not need it.
EOF
    return 1
  fi
  local pid
  pid="$(read_pid "$STATE/ingress.pid")"
  if pid_alive "$pid"; then
    echo "ingress: already running (pid $pid)"
    return 0
  fi
  if ! port_free "$INGRESS_PORT"; then
    echo "ingress: port $INGRESS_PORT is busy" >&2
    return 1
  fi
  nohup "$porch" -config "$STATE/wan-ingress.json" \
    >>"$LOGS/ingress.log" 2>&1 &
  echo $! > "$STATE/ingress.pid"
  if ! wait_http "http://127.0.0.1:$INGRESS_PORT/healthz"; then
    echo "ingress: did not become ready; tail of $LOGS/ingress.log:" >&2
    tail -n 20 "$LOGS/ingress.log" >&2 || true
    return 1
  fi
  echo "ingress: http://127.0.0.1:$INGRESS_PORT (pid $(cat "$STATE/ingress.pid"))"
}

stop_pid() {
  local label="$1" pidfile="$2" marker="$3"
  local pid cmd
  pid="$(read_pid "$pidfile")"
  if ! pid_alive "$pid"; then
    rm -f "$pidfile"
    echo "$label: stopped"
    return 0
  fi
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  if [[ "$cmd" != *"$marker"* ]]; then
    echo "$label: pid $pid does not look like ours; refusing to kill" >&2
    echo "  command: $cmd" >&2
    return 1
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 25); do
    pid_alive "$pid" || break
    sleep 0.2
  done
  if pid_alive "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
  echo "$label: stopped (pid $pid)"
}

cmd_up() {
  need "$BIN" || return 1
  need "$SMOKE" || return 1
  need "$ADHD" || return 1
  render
  start_mcp || { cmd_down || true; return 1; }
  # Start the ingress before the alarm so the first poll does not race the bind.
  if [ "$WATCH_INGRESS" = "1" ]; then
    start_ingress || { cmd_down || true; return 1; }
  fi
  start_alarm || { cmd_down || true; return 1; }
  start_adhd || { cmd_down || true; return 1; }
  echo
  cmd_status
}

cmd_down() {
  local failures=0
  stop_pid "mcp" "$STATE/mcp.pid" "skillz_mcp.py" || failures=$((failures + 1))
  stop_pid "alarm" "$STATE/alarm.pid" "$STATE/smoke-alarm.yaml" || failures=$((failures + 1))
  stop_pid "adhd" "$STATE/adhd.pid" "$STATE/adhd.yaml" || failures=$((failures + 1))
  stop_pid "ingress" "$STATE/ingress.pid" "$STATE/wan-ingress.json" || failures=$((failures + 1))
  return "$failures"
}

http_code() {
  local out
  out="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null || true)"
  printf '%s' "${out:-000}"
}

alarm_healthy() {
  local status
  status="$(curl -fsS --max-time 2 "http://127.0.0.1:$ALARM_PORT/status" 2>/dev/null || true)"
  [ -n "$status" ] || return 1
  printf '%s' "$status" | python3 -c '
import json, sys
data = json.load(sys.stdin)
targets = data.get("targets") or {}
rows = targets.values() if isinstance(targets, dict) else targets
for row in rows:
    if (row.get("state") or row.get("current_status")) not in ("healthy", "ok"):
        sys.exit(1)
'
}

alarm_summary() {
  local status
  status="$(curl -fsS --max-time 2 "http://127.0.0.1:$ALARM_PORT/status" 2>/dev/null || true)"
  [ -n "$status" ] || return 0
  printf '%s' "$status" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
targets = data.get("targets") or {}
rows = targets.values() if isinstance(targets, dict) else targets
for row in rows:
    if not isinstance(row, dict):
        continue
    print("  %-14s %-10s %s" % (
        row.get("id") or row.get("target_id") or "?",
        row.get("state") or row.get("current_status") or "?",
        (row.get("message") or row.get("last_error") or "")[:80]))
'
}

cmd_status() {
  local label port path pid code
  echo "skillz ops — root $ROOT"
  for spec in "mcp:$MCP_PORT:/readyz" "alarm:$ALARM_PORT:/healthz" "adhd:$ADHD_PORT:/mcp" "ingress:$INGRESS_PORT:/healthz"; do
    label="${spec%%:*}"; spec="${spec#*:}"
    port="${spec%%:*}"; path="${spec#*:}"
    pid="$(read_pid "$STATE/$label.pid")"
    if pid_alive "$pid"; then
      code="$(http_code "http://127.0.0.1:$port$path")"
      printf '%-8s pid %-7s port %-5s http %s\n' "$label" "$pid" "$port" "$code"
    else
      printf '%-8s stopped\n' "$label"
    fi
  done
  echo "alarm targets:"
  alarm_summary
}

exercise_ingress() {
  local pid body upstream
  pid="$(read_pid "$STATE/ingress.pid")"
  if ! pid_alive "$pid"; then
    echo "ingress: not running; skipping forward exercise"
    return 0
  fi
  if [ ! -f "$STATE/secrets.env" ]; then
    echo "ingress: secrets.env missing" >&2
    return 1
  fi
  # shellcheck disable=SC1091
  . "$STATE/secrets.env"
  body="$(curl -s --max-time 3 -X POST \
    -H "Authorization: Bearer $SKILLZ_INGRESS_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"skills/status","params":{}}' \
    "http://127.0.0.1:$INGRESS_PORT/forward?name=skillz" 2>/dev/null || true)"
  upstream="$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("upstream_status", ""))
except Exception:
    print("")
')"
  if [ "$upstream" = "200" ]; then
    echo "ingress: forward accepted (upstream 200)"
    return 0
  fi
  echo "ingress: forward failed: ${body:0:220}" >&2
  return 1
}

cmd_doctor() {
  local failures=0
  echo "== verify =="
  "$BIN" verify || failures=$((failures + 1))
  echo
  echo "== MCP handshake =="
  "$BIN" probe --url "http://127.0.0.1:$MCP_PORT/mcp" || failures=$((failures + 1))
  echo
  echo "== signed ingress border =="
  "$BIN" ingress-probe --url "http://127.0.0.1:$MCP_PORT" \
    --key-file "$STATE/border.key" --namespace skillz || failures=$((failures + 1))
  echo
  echo "== ingress forward =="
  exercise_ingress || failures=$((failures + 1))
  echo
  echo "== alarm state =="
  local healthy=0 status=""
  for _ in $(seq 1 20); do
    status="$(curl -fsS --max-time 2 "http://127.0.0.1:$ALARM_PORT/status" 2>/dev/null || true)"
    if [ -n "$status" ] && alarm_healthy; then
      healthy=1
      break
    fi
    sleep 1
  done
  if [ -z "$status" ]; then
    echo "alarm: not answering on :$ALARM_PORT"
    failures=$((failures + 1))
  else
    printf '%s' "$status" | python3 -c '
import json, sys
data = json.load(sys.stdin)
targets = data.get("targets") or {}
rows = targets.values() if isinstance(targets, dict) else targets
for row in rows:
    print("  %-14s %s" % (
        row.get("id") or row.get("target_id") or "?",
        row.get("state") or row.get("current_status") or "?"))
' || true
    if [ "$healthy" -ne 1 ]; then
      failures=$((failures + 1))
    fi
  fi
  echo
  if [ "$failures" -eq 0 ]; then
    echo "doctor: PASS"
  else
    echo "doctor: FAIL ($failures check group(s))"
  fi
  return "$failures"
}

cmd_ingress() {
  WATCH_INGRESS=1
  render
  local pid
  pid="$(read_pid "$STATE/alarm.pid")"
  if pid_alive "$pid"; then
    stop_pid "alarm" "$STATE/alarm.pid" "$STATE/smoke-alarm.yaml" || return 1
    start_alarm || return 1
  fi
  start_ingress
}

cmd_logs() {
  local follow="${1:-}"
  local files=("$LOGS/mcp.log" "$LOGS/alarm.log" "$LOGS/adhd.jsonl" "$LOGS/adhd.err" "$LOGS/ingress.log")
  local existing=()
  local f
  for f in "${files[@]}"; do
    [ -f "$f" ] && existing+=("$f")
  done
  if [ "${#existing[@]}" -eq 0 ]; then
    echo "no logs yet under $LOGS"
    return 0
  fi
  if [ "$follow" = "-f" ]; then
    tail -n 20 -f "${existing[@]}"
  else
    for f in "${existing[@]}"; do
      echo "== $f =="
      tail -n 20 "$f"
    done
  fi
}

ACTION="${1:-}"
[ $# -gt 0 ] && shift || true
case "$ACTION" in
  up)
    for arg in "$@"; do
      case "$arg" in
        --with-ingress) WATCH_INGRESS=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
      esac
    done
    cmd_up
    ;;
  down) cmd_down ;;
  status) cmd_status ;;
  doctor) cmd_doctor ;;
  logs) cmd_logs "${1:-}" ;;
  ingress) cmd_ingress ;;
  render)
    render
    echo "rendered $STATE/{smoke-alarm.yaml,adhd.yaml,agreements.json,wan-ingress.json}"
    ;;
  *) usage; exit 2 ;;
esac
