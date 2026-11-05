#!/usr/bin/env bash
# pilot-dispatcher.session-liveness.selftest.sh
#
# Regression guard for the "drained ephemeral worker counts as live" wedge
# (ga-mrfb / ps-mrfb + ps-joc0 stuck story:in-flight 80+min behind asleep
# ps-worker-adhoc sessions that `gc session peek` reported "not found").
#
# ROOT CAUSE: _LIVE_SESSION_IDS selects every session with .closed != true. An
# ephemeral pool worker (…-adhoc-…, wake_mode=fresh) goes state=="asleep" after it
# drain-acks but keeps .closed==false for a while, so the broad _session_is_live
# counted it "live" → (a) NEVERSTARTED's live-worker guard KEPT its in-flight bead
# (never reclaimed) and (b) the dead-worker slot-correction KEPT its pool slot
# (falsely full) — a deadlock: the bead is in-flight (never a dispatch candidate,
# so never woken/reused) yet never released.
#
# FIX: _session_is_live_builder("…-adhoc-…") returns DEAD when the worker is asleep,
# while _session_is_live (used by the ownership/crew-owner guards and the gt-4st3n
# REUSE wake path) keeps its full not-closed semantics — an asleep NAMED crew is
# still live. This test extracts the REAL helper defs from the dispatcher and
# exercises every case.
set -u
SRC="$(cd "$(dirname "$0")" && pwd)/pilot-dispatcher.sh"
[ -r "$SRC" ] || { echo "FATAL: cannot read $SRC"; exit 2; }

# Pull the real set-building assignments + the three liveness helpers out of the
# dispatcher (from the _LIVE_SESSION_IDS assignment through the close of
# _session_is_live_builder) so we test shipped code, never a copy.
SNIP="$(awk '/^_LIVE_SESSION_IDS=\$\(echo "\$_SESSIONS_JSON" \\/{f=1}
             f{print}
             /^_session_is_live_builder\(\)/{g=1}
             g&&/^}/{exit}' "$SRC")"
case "$SNIP" in
  *_session_is_live_builder*) : ;;
  *) echo "FATAL: could not extract liveness helpers — did they move/rename?"; exit 2 ;;
esac

FAILS=0
_t() { # desc id want(live|dead)
  _session_is_live_builder "$2"; local rc=$? got="dead"
  [ "$rc" -eq 0 ] && got="live"
  if [ "$got" = "$3" ]; then echo "  ok   $1 → $got"
  else echo "  FAIL $1 → got=$got want=$3"; FAILS=$((FAILS+1)); fi
}

export _SESSIONS_JSON='{"sessions":[
  {"session_name":"mila-wa","state":"active","closed":false},
  {"session_name":"thies-wa","state":"asleep","closed":false},
  {"session_name":"oracle-wa","state":"active","closed":true},
  {"session_name":"ps-worker-adhoc-AWAKE01","state":"active","closed":false},
  {"session_name":"ps-worker-adhoc-b942bd1523","state":"asleep","closed":false},
  {"session_name":"wa-worker-adhoc-8ba5da233e","state":"asleep","closed":false}
]}'
eval "$SNIP"

echo "Scenario: _session_is_live_builder — drained adhoc worker is NOT a live builder"
_t "awake named crew"                       "mila-wa"                    "live"
_t "ASLEEP named crew (preserved live)"     "thies-wa"                   "live"
_t "closed crew"                            "oracle-wa"                  "dead"
_t "awake adhoc worker"                     "ps-worker-adhoc-AWAKE01"    "live"
_t "ASLEEP adhoc ps-worker (the wedge)"     "ps-worker-adhoc-b942bd1523" "dead"
_t "ASLEEP adhoc wa-worker"                 "wa-worker-adhoc-8ba5da233e" "dead"
_t "unknown id"                             "ghost-xyz"                  "dead"

echo "Scenario: _session_is_live UNCHANGED (broad not-closed semantics intact)"
if _session_is_live "ps-worker-adhoc-b942bd1523"; then
  echo "  ok   _session_is_live(asleep adhoc)=live — ownership/REUSE semantics preserved"
else
  echo "  FAIL _session_is_live no longer treats asleep adhoc as live (ownership/REUSE regression)"; FAILS=$((FAILS+1))
fi
if _session_is_asleep "ps-worker-adhoc-b942bd1523" && ! _session_is_asleep "mila-wa"; then
  echo "  ok   _session_is_asleep distinguishes asleep from active"
else
  echo "  FAIL _session_is_asleep misclassified"; FAILS=$((FAILS+1))
fi

# ── ga-d63o9n1: o gêmeo de alias de um slot de pool NÃO é o builder da bead do dog morto ───────────────────────
# Mesma regra do guard (ga-lotseol → bead_state.alias_claim_predates_session): a sessão que casa o assignee SÓ pelo alias do slot não é a dona se a bead
# ficou parada desde ANTES de ela nascer (> 60 s). O 2º argumento é o `updated_at` da bead; sem ele (ou ilegível) vale "dono vivo", como antes.
# ⚠️ A ponte TEM de estar de pé aqui: com ela quebrada o fallback bash também diria "vivo" e estes cenários passariam pelo motivo errado.
SC="$(cd "$(dirname "$0")/../../../scripts" && pwd)"
export PILOT_BEAD_STATE_PY_OVERRIDE="$SC/bead_state.py"
[ -f "$PILOT_BEAD_STATE_PY_OVERRIDE" ] || { echo "FATAL: bead_state.py não achado em $SC"; exit 2; }
log()  { echo "[pilot-dispatcher] $*"; }          # como no Pilot: stdout. O `>&2` da ponte é o que o AT-11 prova
warn() { echo "[pilot-dispatcher] WARN: $*"; }
NOW=$(date +%s)
iso() { python3 -c 'import datetime as d,sys; print(d.datetime.fromtimestamp(int(sys.argv[1]), tz=d.timezone(d.timedelta(hours=int(sys.argv[2])))).replace(microsecond=0).isoformat().replace("+00:00","Z"))' "$1" "${2:-0}"; }
dog() { # dog <id> <session_name> <idade da sessão em s> [offset h]  — slot de dog como o `gc session list --json` o devolve (medido 05/11)
  printf '{"id":"%s","name":"gastown.dog-2","alias":"gastown.dog-2","session_name":"%s","agent_name":"gastown.dog-2","template":"gastown.dog","state":"active","closed":false,"created_at":"%s"}' \
    "$1" "$2" "$(iso $((NOW - $3)) "${4:-0}")"
}
load() { export _SESSIONS_JSON="{\"sessions\":[$1]}"; eval "$SNIP" >/dev/null 2>&1; }
at() { # at <desc> <live|dead> <assignee> [bead_updated_at]  — a ponte real; o log do gêmeo vai para o stderr (guardado em $AT_ERR)
  local rc got; AT_ERR=$(_session_is_live_builder "$3" ${4+"$4"} 2>&1 >/dev/null); rc=$?
  got=dead; [ "$rc" -eq 0 ] && got=live
  if [ "$got" = "$2" ]; then echo "  ok   $1 → $got"; else echo "  FAIL $1 → got=$got want=$2"; FAILS=$((FAILS+1)); fi
}
ALIAS="gastown.dog-2"
echo "Scenario: alias-twin (ga-d63o9n1) — a sessão nascida DEPOIS do último toque da bead não é quem a reivindicou"
load "$(dog ga-new dog-galsnew 300)"
at "AT-1 (THE bug) gêmeo nasceu há 300 s, bead parada há 3600 s"          dead "$ALIAS" "$(iso $((NOW - 3600)))"
case "$AT_ERR" in *alias-twin*dog-galsnew*) echo "  ok   AT-1b o descarte deixa rastro (stderr) com o session_name" ;;
  *) echo "  FAIL AT-1b o descarte não deixou rastro no stderr: [$AT_ERR]"; FAILS=$((FAILS+1)) ;; esac
OUT=$(_session_is_live_builder "$ALIAS" "$(iso $((NOW - 3600)))" 2>/dev/null)
[ -z "$OUT" ] && echo "  ok   AT-11 stdout vazio (o JSON de _inflight_drop_dead_workers é stdout: log ali o corromperia)" \
  || { echo "  FAIL AT-11 a função escreveu no stdout: [$OUT]"; FAILS=$((FAILS+1)); }
at "AT-2 bead tocada há 120 s (depois do nascimento)"                       live "$ALIAS" "$(iso $((NOW - 120)))"
at "AT-3 sem o 2º argumento (chamador antigo / sem dado da bead)"           live "$ALIAS"
at "AT-4a updated_at vazio"                                                 live "$ALIAS" ""
at "AT-4b updated_at ilegível"                                              live "$ALIAS" "ontem"
at "AT-5a assignee = session_name da encarnação, bead parada"               live "dog-galsnew" "$(iso $((NOW - 3600)))"
at "AT-5b assignee = id da encarnação, bead parada"                         live "ga-new" "$(iso $((NOW - 3600)))"
at "AT-8 assignee de template nu (carimbo de pool), bead parada"            live "gastown.dog" "$(iso $((NOW - 3600)))"
load "$(dog ga-new dog-galsnew 300 -3)"
at "AT-9 created_at no dialeto de offset local (-03:00) do gc session list" dead "$ALIAS" "$(iso $((NOW - 3600)))"
load "$(dog ga-new dog-galsnew 300 | sed 's/"created_at":"[^"]*"/"created_at":""/')"
at "AT-10 sessão sem created_at (não sei quando nasceu)"                    live "$ALIAS" "$(iso $((NOW - 3600)))"
load "$(dog ga-new dog-galsnew 300),$(dog ga-old dog-galsold 7200)"
at "AT-7a encarnação mais velha viva + gêmea nova → a velha ainda pode ser a dona" live "$ALIAS" "$(iso $((NOW - 3600)))"
load "$(dog ga-old dog-galsold 7200),$(dog ga-new dog-galsnew 300)"
at "AT-7b (a ordem do roster não importa)"                                  live "$ALIAS" "$(iso $((NOW - 3600)))"
load '{"id":"ga-crew","name":"thies-wa","alias":"thies","session_name":"thies-wa-x","agent_name":"thies-wa","template":"thies-wa","state":"active","closed":false,"created_at":"'"$(iso $((NOW - 16 * 86400)))"'"}'
at "AT-6 crew de alias estável (template == nome), bead parada há 30 dias"  live "thies" "$(iso $((NOW - 30 * 86400)))"

echo "Scenario: a ponte indisponível ou quebrada NÃO vira 'gêmeo descartado' (falhou/ilegível → dono vivo)"
load "$(dog ga-new dog-galsnew 300)"
GOOD_BSP="$PILOT_BEAD_STATE_PY_OVERRIDE"
PILOT_BEAD_STATE_PY_OVERRIDE=/nonexistent/bead_state.py
at "AT-12 bead_state.py ausente → checagem bash de antes"                   live "$ALIAS" "$(iso $((NOW - 3600)))"
BROKEN=$(mktemp -d "${TMPDIR:-/tmp}/slb-broken.XXXXXX"); trap 'rm -rf "$BROKEN"' EXIT; cp "$SC/park_labels.py" "$BROKEN/"
sed 's/^def live_builder_report/def live_builder_report_RENOMEADA/' "$SC/bead_state.py" > "$BROKEN/bead_state.py"
PILOT_BEAD_STATE_PY_OVERRIDE="$BROKEN/bead_state.py"
at "AT-13 ponte quebrada (nome da entrada mudou) → fallback bash, vivo"      live "$ALIAS" "$(iso $((NOW - 3600)))"
case "$AT_ERR" in *"bridge"*"quebrado"*) echo "  ok   AT-13b a ponte quebrada aparece (warn no stderr), não some em silêncio" ;;
  *) echo "  FAIL AT-13b ponte quebrada sem aviso: [$AT_ERR]"; FAILS=$((FAILS+1)) ;; esac
PILOT_BEAD_STATE_PY_OVERRIDE="$GOOD_BSP"

echo "Scenario: os 3 pontos de uso passam o updated_at da bead (sem ele a regra desliga SEM um som)"
SRC_CALLS=$(grep -v '^[[:space:]]*#' "$SRC" | grep -c '_session_is_live_builder "' || true)
SRC_WITH=$(grep -v '^[[:space:]]*#' "$SRC" | grep -cE '_session_is_live_builder "\$[_a-z0-9]+" "\$[_a-z0-9]+"' || true)
if [ "$SRC_CALLS" = 3 ] && [ "$SRC_WITH" = 3 ]; then echo "  ok   AT-14 os 3 pontos de uso passam 2 argumentos (calls=$SRC_CALLS com-updated_at=$SRC_WITH)"
else echo "  FAIL AT-14 pontos de uso: $SRC_CALLS, com 2 argumentos: $SRC_WITH (esperado 3 e 3)"; FAILS=$((FAILS+1)); fi

echo ""
if [ "$FAILS" -eq 0 ]; then echo "SELFTEST PASS"; exit 0
else echo "SELFTEST FAIL ($FAILS)"; exit 1; fi
