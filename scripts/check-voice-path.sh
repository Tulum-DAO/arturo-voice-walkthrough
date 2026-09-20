#!/usr/bin/env bash
# check-voice-path.sh — measure, don't guess: is the browser live-voice path to Arturo wired?
# Run from an OrchestraOS checkout (the directory that holds orchestra.toml).
# Every line is a measurement with the command that produced it; nothing here changes state.
set -u
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
note() { printf '  --    %s\n' "$*"; }
FAILS=0

TOML="${ORCHESTRA_CONFIG:-orchestra.toml}"
[ -f "$TOML" ] || { echo "no $TOML here — run from the orchestraos checkout"; exit 2; }
toml_get() { # section key default
  python3 - "$TOML" "$1" "$2" "$3" <<'PY'
import sys,tomllib
raw=tomllib.load(open(sys.argv[1],'rb'))
print(raw.get(sys.argv[2],{}).get(sys.argv[3],sys.argv[4]))
PY
}
DATA_DIR="$(toml_get data dir "$HOME/.orchestra")"; DATA_DIR="${ORCHESTRA_DIR:-$DATA_DIR}"; DATA_DIR="${DATA_DIR/#\~/$HOME}"
GW_PORT="$(toml_get gateway port 8890)"
ARTURO_PORT="$(toml_get arturo port 5071)"
API_PORT="$(toml_get api port 8888)"
echo "config: data=$DATA_DIR gateway=:$GW_PORT arturo=:$ARTURO_PORT api=:$API_PORT"

echo "1. listeners  (ss -ltn)"
for p in "$GW_PORT" "$ARTURO_PORT" "$API_PORT"; do
  if ss -ltn 2>/dev/null | grep -qE "[:.]$p\b"; then ok "something listens on :$p"; else bad "nothing listens on :$p — is 'orchestra up' running?"; fi
done

echo "2. gateway bearer token"
TOK="$DATA_DIR/state/watch-gateway-token"
[ -s "$TOK" ] && ok "$TOK present" || bad "$TOK missing/empty — 'orchestra init' writes it"
LEGACY="$HOME/.config/jarvis/watch-gateway-token"
if [ -e "$LEGACY" ]; then ok "$LEGACY present (needed by api/src/routes/voice.ts for transcript cards, issue #85)"
else bad "$LEGACY missing — transcript cards will say 'unavailable' (issue #85). Fix: mkdir -p ~/.config/jarvis && ln -sf \"$TOK\" \"$LEGACY\""; fi

echo "3. the API's voice WebSocket target vs the gateway port (issue #84)"
API_PID="$(ss -ltnp 2>/dev/null | grep -E "[:.]$API_PORT\b" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
if [ -n "${API_PID:-}" ] && [ -r "/proc/$API_PID/environ" ]; then
  WSURL="$(tr '\0' '\n' < "/proc/$API_PID/environ" | grep '^WATCH_GATEWAY_WS_URL=' | cut -d= -f2-)"
  KEY_IN_API="$(tr '\0' '\n' < "/proc/$API_PID/environ" | grep -c '^GEMINI_API_KEY=')"
  if [ -n "$WSURL" ]; then ok "api pid $API_PID has WATCH_GATEWAY_WS_URL=$WSURL"
  elif [ "$GW_PORT" = "9091" ]; then ok "api dials its default ws://127.0.0.1:9091 and the gateway is on :9091"
  else bad "api dials its default ws://127.0.0.1:9091 but [gateway] port = $GW_PORT — set [gateway] port = 9091 or export WATCH_GATEWAY_WS_URL=ws://127.0.0.1:$GW_PORT"; fi
else note "could not read the API process env (pid not found or not readable); compare [gateway] port=$GW_PORT with voice-live.ts default 9091 by hand"
fi

echo "4. GEMINI_API_KEY where the bridge reads it (gemini_live_bridge.py:113 — <repo>/.env.secrets, then env)"
GW_PID="$(ss -ltnp 2>/dev/null | grep -E "[:.]$GW_PORT\b" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
if [ -f .env.secrets ] && grep -q '^GEMINI_API_KEY=' .env.secrets; then ok "GEMINI_API_KEY= in ./.env.secrets (repo root — the file the bridge reads)"
elif [ -n "${GW_PID:-}" ] && [ -r "/proc/$GW_PID/environ" ] && tr '\0' '\n' < "/proc/$GW_PID/environ" | grep -q '^GEMINI_API_KEY='; then ok "GEMINI_API_KEY in the gateway process environment (pid $GW_PID)"
else bad "no GEMINI_API_KEY visible to the gateway/bridge — export it in the environment 'orchestra up' runs under (issue #86 explains the file path)"; fi

echo "5. voice-call journal dir: bridge writes <repo>/state/voice-calls, gateway reads <data>/state/voice-calls (issue #86)"
if [ "$(readlink -f "$DATA_DIR")" = "$(readlink -f .)" ]; then ok "data dir == repo root; the two paths coincide"
elif [ "$(readlink -f state/voice-calls 2>/dev/null)" = "$(readlink -f "$DATA_DIR/state/voice-calls" 2>/dev/null)" ] && [ -n "$(readlink -f state/voice-calls 2>/dev/null)" ]; then ok "state/voice-calls -> $DATA_DIR/state/voice-calls"
else bad "state/voice-calls is not $DATA_DIR/state/voice-calls — transcript cards 404. Fix: mkdir -p \"$DATA_DIR/state/voice-calls\" state && ln -sfn \"$DATA_DIR/state/voice-calls\" state/voice-calls"; fi

echo "6. arturo /health"
H="$(curl -s --max-time 5 "127.0.0.1:$ARTURO_PORT/health" || true)"
if [ -z "$H" ]; then bad "no answer from 127.0.0.1:$ARTURO_PORT/health"
else
  MODE="$(printf '%s' "$H" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("mode"),"brain="+str((d.get("brain") or {}).get("kind")))' 2>/dev/null || echo '?')"
  case "$MODE" in voice*) ok "mode $MODE";; *) bad "mode $MODE — a vendor key (GEMINI_API_KEY is enough) must be in the service env";; esac
fi

echo
[ "$FAILS" -eq 0 ] && echo "all measurements OK — open http://127.0.0.1:8891 in Chrome/Edge and press the phone" || echo "$FAILS thing(s) to fix above"
exit "$FAILS"
