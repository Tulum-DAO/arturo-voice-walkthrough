#!/usr/bin/env bash
# check-voice-path.sh — measure, don't guess: is the browser live-voice path to Arturo wired?
# Run from an OrchestraOS checkout (the directory that holds orchestra.toml).
# Every line is a measurement with the command that produced it; nothing here changes state.
set -u
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
note() { printf '  --    %s\n' "$*"; }
# SKIP is not FAIL. An install with no vendor key is NOT CONFIGURED, not broken; counting it as a
# failure makes a working install read as broken and is the crash-vs-verdict confusion one layer
# out (gm ruling, 2026-09-23). Skips are reported and do not affect the exit code.
skip() { printf '  SKIP  %s\n' "$*"; SKIPS=$((SKIPS+1)); }
FAILS=0
SKIPS=0

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
# MEASURE the API's own default rather than asserting one. This probe hardcoded 9091 and kept
# reporting FAIL after voice-live.ts was fixed to default to the gateway port (0b63d2a) — the
# instrument outlived the defect and would have had a builder "fix" working code to satisfy it.
API_DEFAULT_PORT="$(sed -n 's|.*ws://127\.0\.0\.1:\([0-9][0-9]*\).*|\1|p' api/src/routes/voice-live.ts 2>/dev/null | head -1)"
API_PID="$(ss -ltnp 2>/dev/null | grep -E "[:.]$API_PORT\b" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
if [ -n "${API_PID:-}" ] && [ -r "/proc/$API_PID/environ" ]; then
  WSURL="$(tr '\0' '\n' < "/proc/$API_PID/environ" | grep '^WATCH_GATEWAY_WS_URL=' | cut -d= -f2-)"
  KEY_IN_API="$(tr '\0' '\n' < "/proc/$API_PID/environ" | grep -c '^GEMINI_API_KEY=')"
  if [ -n "$WSURL" ]; then ok "api pid $API_PID has WATCH_GATEWAY_WS_URL=$WSURL"
  elif [ -n "$API_DEFAULT_PORT" ] && [ "$GW_PORT" = "$API_DEFAULT_PORT" ]; then
    ok "api dials its default ws://127.0.0.1:$API_DEFAULT_PORT and the gateway is on :$GW_PORT"
  elif [ -n "$API_DEFAULT_PORT" ]; then
    bad "api dials its default ws://127.0.0.1:$API_DEFAULT_PORT but [gateway] port = $GW_PORT — export WATCH_GATEWAY_WS_URL=ws://127.0.0.1:$GW_PORT"
  else note "could not read voice-live.ts's default from this checkout; compare [gateway] port=$GW_PORT by hand"; fi
else note "could not read the API process env (pid not found or not readable); voice-live.ts default=${API_DEFAULT_PORT:-unknown}, [gateway] port=$GW_PORT"
fi

echo "4. GEMINI_API_KEY where the bridge reads it (gemini_live_bridge.py:113 — <repo>/.env.secrets, then env)"
GW_PID="$(ss -ltnp 2>/dev/null | grep -E "[:.]$GW_PORT\b" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
if [ -f .env.secrets ] && grep -q '^GEMINI_API_KEY=' .env.secrets; then ok "GEMINI_API_KEY= in ./.env.secrets (repo root — the file the bridge reads)"
elif [ -n "${GW_PID:-}" ] && [ -r "/proc/$GW_PID/environ" ] && tr '\0' '\n' < "/proc/$GW_PID/environ" | grep -q '^GEMINI_API_KEY='; then ok "GEMINI_API_KEY in the gateway process environment (pid $GW_PID)"
else skip "no GEMINI_API_KEY visible to the gateway/bridge — NOT CONFIGURED, not broken. Export it in the environment 'orchestra up' runs under, or put GEMINI_API_KEY= in ./.env.secrets"; fi

echo "5. voice-call journal dir: bridge writes <repo>/state/voice-calls, gateway reads <data>/state/voice-calls (issue #86)"
# ASK THE BRIDGE WHERE IT WRITES rather than testing for the symlink that used to be the
# workaround. Once the bridge resolves the configured data dir itself there is nothing to link,
# and a probe that still demands the link reports a FAIL on a correctly wired install — the same
# way item 3 kept failing after voice-live.ts was fixed.
BRIDGE_DIR="$(python3 - <<'PYEOF' 2>/dev/null
import sys
from pathlib import Path
b = Path("services/arturo/gemini_live_bridge.py")
if not b.exists():
    sys.exit(1)
sys.path.insert(0, "services/arturo"); sys.path.insert(0, "services")
ns = {"__file__": str(b.resolve()), "__name__": "_probe"}
exec(compile(b.read_text().split("execute_tool_fn = None")[0], "head", "exec"), ns)
print(ns["ORCHESTRA_DIR"])
PYEOF
)"
if [ -n "$BRIDGE_DIR" ]; then
  if [ "$(readlink -f "$BRIDGE_DIR/state/voice-calls")" = "$(readlink -f "$DATA_DIR/state/voice-calls")" ]; then
    ok "bridge journals to $BRIDGE_DIR/state/voice-calls, which is where the gateway reads"
  else
    bad "bridge journals to $BRIDGE_DIR/state/voice-calls but the gateway reads $DATA_DIR/state/voice-calls — transcript cards 404"
  fi
elif [ "$(readlink -f "$DATA_DIR")" = "$(readlink -f .)" ]; then ok "data dir == repo root; the two paths coincide"
elif [ "$(readlink -f state/voice-calls 2>/dev/null)" = "$(readlink -f "$DATA_DIR/state/voice-calls" 2>/dev/null)" ] && [ -n "$(readlink -f state/voice-calls 2>/dev/null)" ]; then ok "state/voice-calls -> $DATA_DIR/state/voice-calls (legacy symlink workaround)"
else bad "state/voice-calls is not $DATA_DIR/state/voice-calls — transcript cards 404"; fi

echo "6. arturo /health"
H="$(curl -s --max-time 5 "127.0.0.1:$ARTURO_PORT/health" || true)"
if [ -z "$H" ]; then bad "no answer from 127.0.0.1:$ARTURO_PORT/health"
else
  MODE="$(printf '%s' "$H" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("mode"),"brain="+str((d.get("brain") or {}).get("kind")))' 2>/dev/null || echo '?')"
  case "$MODE" in
    voice*) ok "mode $MODE" ;;
    *) if [ "${SKIPS:-0}" -gt 0 ]; then
         skip "mode $MODE — downstream of the missing vendor key above, not an independent defect"
       else
         bad "mode $MODE — a vendor key (GEMINI_API_KEY is enough) must be in the service env"
       fi ;;
  esac
fi

echo
if [ "$FAILS" -eq 0 ] && [ "$SKIPS" -eq 0 ]; then
  echo "all measurements OK — open http://127.0.0.1:8891 in Chrome/Edge and press the phone"
elif [ "$FAILS" -eq 0 ]; then
  echo "no defects — $SKIPS thing(s) NOT CONFIGURED (see SKIP above); the wiring itself is sound"
else
  echo "$FAILS thing(s) to fix above${SKIPS:+, $SKIPS not configured}"
fi
exit "$FAILS"
