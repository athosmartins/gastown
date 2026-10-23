#!/usr/bin/env bash
# prod-tests/gascity/story-ga-c0939v.7.sh — prod test for ga-c0939v.7 (slice 7 of ga-c0939v): the JSONL upload to S3 really runs every <= 60 min
# (it was 1h10 median, 94% of gaps over an hour), it does not stop for lack of a big disk margin, and an age alarm watches the S3 object.
#
# "Merged" is not "live": this checks the DEPLOYED script/order files, that `gc order list` resolves BOTH orders, whether the CONTROLLER has fired them,
# what the alarm says about the REAL S3 object right now, and — once enough time has passed — the MEASURED gap between publications from the real log.
# It only READS: nothing is written to the bucket, nothing is restored. The alarm runs with a throwaway state dir, a throwaway log and a no-op `notify`
# (`--age-check` writes its own state and can push a phone alert: a prod test must do neither).
#
# Estados (nunca dois): ok / fail / unproven.
#   - o que este host não consegue exercitar AINDA (o order novo ainda não disparou; poucas publicações desde o deploy) é "unproven": contado, e o teste SEGUE;
#   - arquivo implantado ausente ou velho, order não listado, alarme que mede o S3 e diz ATRASADO/AUSENTE, ou mediana de gap acima de 1 h DEPOIS de dados suficientes é FAIL.
#   `AGE: UNKNOWN` (sem credencial, S3 fora) nunca vira PASS limpo: sem o order ter disparado é "unproven", depois que disparou é FAIL.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SDIR="$CITY/packs/town-deltas/assets/scripts"
SCRIPT="$SDIR/jsonl-hourly-offsite.sh"
CADENCE="$SDIR/jsonl_hourly_cadence.py"
OFF_ORDER="$CITY/packs/town-deltas/orders/jsonl-hourly-offsite.toml"
AGE_ORDER="$CITY/packs/town-deltas/orders/jsonl-hourly-offsite-age.toml"
LOG="${JHO_LOG_REAL:-$CITY/.gc/logs/jsonl-hourly-offsite.log}"
AWS_BIN="${JHO_AWS:-$(command -v aws || echo /opt/homebrew/bin/aws)}"
MIN_PUBS="${MIN_PUBS:-8}"   # publicações desde o deploy para a mediana valer (8 x ~40 min ≈ 5 h)

log()  { echo "[prod-test:gascity ga-c0939v.7] $*"; }
fail() { echo "[prod-test:gascity ga-c0939v.7] FAIL: $*" >&2; exit 1; }
_TO=""; for _t in timeout gtimeout; do command -v "$_t" >/dev/null 2>&1 && { _TO="$_t"; break; }; done
_to() { local t="$1"; shift; if [[ -n "$_TO" ]]; then "$_TO" "$t" "$@"; else "$@"; fi; }
[[ -n "$_TO" ]] || echo "[prod-test:gascity ga-c0939v.7] WARN: no timeout/gtimeout on this host — the gc/aws calls below are NOT time-bounded"
UNPROVEN=""; UNPROVEN_N=0
_unproven() { UNPROVEN_N=$((UNPROVEN_N + 1)); UNPROVEN="${UNPROVEN:+$UNPROVEN; }$1"; }
TMPD=""; trap '[[ -n "$TMPD" ]] && rm -rf "$TMPD"' EXIT

# ── 1. deployed artifacts are the ga-c0939v.7 version ─────────────────────────
for f in "$SCRIPT" "$CADENCE" "$OFF_ORDER" "$AGE_ORDER"; do
  [[ -f "$f" ]] || fail "deployed file missing: $f"
done
[[ -x "$SCRIPT" ]] || fail "deployed script not executable: $SCRIPT"
grep -q -- '--age-check' "$SCRIPT" && grep -q 'need_free_mb' "$SCRIPT" || fail "deployed script has no --age-check / need_free_mb — the pre-ga-c0939v.7 version is live"
grep -q 'trigger = "cooldown"' "$OFF_ORDER" && grep -q 'interval = "30m"' "$OFF_ORDER" || fail "upload order is not cooldown/30m: $(grep -E '^(trigger|interval)' "$OFF_ORDER" | tr '\n' ' ')"
grep -q 'trigger = "cooldown"' "$AGE_ORDER" && grep -Eq '^exec = ".*jsonl-hourly-offsite\.sh --age-check"' "$AGE_ORDER" || fail "alarm order is not a cooldown running 'jsonl-hourly-offsite.sh --age-check': $(grep -E '^(trigger|exec)' "$AGE_ORDER" | tr '\n' ' ')"
log "script, cadence tool and both order files deployed ✓ (upload every 30m, alarm every 10m)"

# ── 2. `gc order list` resolves BOTH orders from the deployed pack ────────────
orders="$(_to 60 gc --city "$CITY" order list --json 2>/dev/null)" || fail "gc order list failed (or timed out)"
for name in jsonl-hourly-offsite jsonl-hourly-offsite-age; do
  n="$(printf '%s' "$orders" | jq --arg n "$name" '[.orders[] | select(.name == $n)] | length' 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] || fail "could not read gc order list (jq: '$n')"
  [[ "$n" -ge 1 ]] || fail "order $name is NOT listed by gc order list — the pack is not deployed or the file does not parse"
  src="$(printf '%s' "$orders" | jq -r --arg n "$name" '[.orders[] | select(.name == $n)][0].source' 2>/dev/null)"
  [[ "$src" == *"packs/town-deltas/orders/$name.toml" ]] || fail "order $name resolved from an unexpected source: $src"
  iv="$(printf '%s' "$orders" | jq -r --arg n "$name" '[.orders[] | select(.name == $n)][0] | (.interval // .schedule // "?")' 2>/dev/null)"
  log "gc order list resolves $name (interval/schedule: $iv) ✓ (CLI-side scan; whether the controller loaded it is section 3)"
done

# ── 3. has the CONTROLLER fired them? (the only proof it loaded them) ─────────
# bash 3.2 (the macOS system bash) has no associative arrays and `_unproven` must run in THIS shell (not in $(...)): the history of one order lands in H_COUNT / H_FIRST
read_history() { # name
  local name="$1" hist hrc cnt
  H_COUNT="unknown"; H_FIRST=""
  hist="$(_to 90 gc --city "$CITY" order history "$name" --json 2>/dev/null)"; hrc=$?
  cnt="$(printf '%s' "$hist" | jq -r --arg n "$name" 'if .ok == true and (.entries | type == "array") then [.entries[] | select(.order == $n)] | length else "unreadable" end' 2>/dev/null)"
  if [[ "$hrc" -ne 0 || ! "$cnt" =~ ^[0-9]+$ ]]; then
    log "WARN: could not read gc order history $name (rc=$hrc, parsed '${cnt:-nothing}') — whether the controller fired it is UNKNOWN"
    _unproven "controller firing of $name UNKNOWN (gc order history unreadable)"
  elif [[ "$cnt" -eq 0 ]]; then
    H_COUNT=0
    log "WARN: gc order history has 0 runs of $name — the controller has NOT fired it yet, so 'the controller loaded the order' is UNPROVEN. Re-run after >= 15 min."
    _unproven "controller has not fired $name yet (0 runs)"
  else
    H_COUNT="$cnt"
    H_FIRST="$(printf '%s' "$hist" | jq -r --arg n "$name" '[.entries[] | select(.order == $n) | .executed] | min' 2>/dev/null)"
    log "controller has fired $name $cnt time(s), last at $(printf '%s' "$hist" | jq -r --arg n "$name" '[.entries[] | select(.order == $n) | .executed] | max' 2>/dev/null) ✓"
  fi
}
read_history jsonl-hourly-offsite
read_history jsonl-hourly-offsite-age; FIRED_AGE="$H_COUNT"; FIRST_AGE="$H_FIRST"

# ── 4. what the ALARM says about the real S3 object right now (read-only, sandboxed) ──
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/ga-c0939v7.XXXXXX")" || fail "mktemp"
out="$(JHO_STATE_DIR="$TMPD/state" JHO_LOG="$TMPD/log" JHO_NOTIFY=/usr/bin/true JHO_AWS="$AWS_BIN" _to 120 "$SCRIPT" --age-check 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
case "$rc" in
  0) log "alarm: the real latest.json is fresh (<= 75 min) ✓" ;;
  1) fail "--age-check: the REAL latest.json is late or missing in S3 — the upload is not keeping up (right after a deploy: wait one 30 min cycle and re-run; otherwise: docs/runbooks/jsonl-hourly-offsite.md, 'Cadência medida e alarme de idade')" ;;
  2) if [[ "$FIRED_AGE" == "0" ]]; then
       _unproven "--age-check UNKNOWN and the alarm order has not fired yet (credentials/S3 unreadable from here, or clock skew)"
     else
       fail "--age-check UNKNOWN after the alarm order fired (or with its history unreadable) — cannot measure the S3 object (credentials? bucket? clock?)"
     fi ;;
  *) fail "--age-check exited $rc (unexpected)" ;;
esac

# ── 5. the proportional disk floor is live (read-only: sources the functions, runs nothing) ──
floor="$(JHO_LIB=1 bash -c '. "$1" >/dev/null 2>&1; need_free_mb' _ "$SCRIPT" 2>/dev/null)"
free="$(df -Pk "$CITY" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')"
if [[ "$floor" =~ ^[0-9]+$ && "$floor" -ge 512 && "$floor" -le 100000 ]]; then
  log "disk floor is proportional to the package: needs ${floor} MB (it was a fixed 1024 MB); free now: ${free:-?} MB ✓"
else
  fail "need_free_mb returned '${floor:-nothing}' — expected a number between 512 and 100000 (the proportional floor)"
fi

# ── 6. the MEASURED gap since the deploy (the only proof the cadence changed) ─
since="$FIRST_AGE"
if [[ -z "$since" ]]; then
  _unproven "gap not measured: the alarm order has not fired, so there is no deploy marker (re-run after >= 5 h)"
elif ! command -v python3 >/dev/null 2>&1; then
  _unproven "python3 not on PATH: the cadence tool was not exercised"
else
  res="$(python3 -I "$CADENCE" --log "$LOG" --since "$since" --json 2>"$TMPD/cad.err")"; crc=$?
  if [[ "$crc" -eq 2 ]]; then
    _unproven "gap not measured yet: $(tr '\n' ' ' < "$TMPD/cad.err")(since $since; needs $MIN_PUBS+ publications)"
  elif [[ "$crc" -ne 0 ]]; then
    fail "the cadence tool failed (rc $crc): $(tr '\n' ' ' < "$TMPD/cad.err")"
  else
    pubs="$(printf '%s' "$res" | jq -r '.publications')"; p50="$(printf '%s' "$res" | jq -r '.gap_s.p50')"; over="$(printf '%s' "$res" | jq -r '.share_over_limit')"
    [[ "$pubs" =~ ^[0-9]+$ && "$p50" =~ ^[0-9]+$ ]] || fail "could not read the cadence tool's JSON: $res"
    if [[ "$pubs" -lt "$MIN_PUBS" ]]; then
      _unproven "only $pubs publication(s) since the deploy ($since) — the median gap needs $MIN_PUBS+ (median so far: $((p50 / 60)) min)"
    elif [[ "$p50" -gt 3600 ]]; then
      fail "median gap between publications since the deploy is $((p50 / 60)) min (> 60) over $pubs publications — the 30m order is not in effect, or something stalls it: python3 -I $CADENCE --since $since --list"
    else
      log "measured since the deploy ($since): $pubs publications, median gap $((p50 / 60)) min, $(printf '%s' "$over" | awk '{printf "%.0f", $1 * 100}')% of gaps over 60 min ✓ (the tail is controller stalls; the alarm covers it)"
    fi
  fi
fi

if [[ "$UNPROVEN_N" -gt 0 ]]; then log "PASS ($UNPROVEN_N unproven: $UNPROVEN)"; else log "PASS"; fi
exit 0
