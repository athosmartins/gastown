#!/usr/bin/env bash
# gate-done-pregate-stamp.selftest.sh (ga-gnr3tw, gate attempt 1 of the pre-gate experiment)
#
# Proves /gate-done Step 3's pre-gate roster + arm stamp by EXECUTING THE SHIPPED BLOCKS — extracted verbatim from
# gate-done.md between their SELFTEST-EXTRACT sentinels (pregate-roster, pregate-stamp) — under BOTH bash and zsh, with a
# stub `bd` and the REAL pre-gate-review.sh `roster` subcommand. Nothing here touches the live town.
#
# Why this file exists (gate ga-46y473, attempt 1, reviewer 1/1 CORRECTNESS):
#   1. The first cut passed the arm to `bd create` as `$PREGATE_LABEL_ARG` (= "-l pregate:on"), UNQUOTED. Every agent
#      session in this city runs /gate-done under zsh (SHELL=/bin/zsh), which does NOT split an unquoted parameter: bd
#      received ONE argv word "-l pregate:on" and stored the label " pregate:on" (leading space), so `bd list -l pregate:on`
#      read the arm as having no beads (error and empty collapsed into one answer). PREGATE_LABEL_ARG lived only in
#      gate-done.md and nothing ever ran Step 3 in zsh. The fix stamps the label with a separate, fully quoted call and
#      reads it back; (P1)-(P2) prove the label that LANDS is exactly "pregate:<arm>" in both shells, (P7) proves the old
#      shape really is broken under this zsh (so a green (P1) is not vacuous).
#   2. The roster call was `... roster ... 2>/dev/null) || PREGATE_ARM=""`: the WARN that a failed roster write prints, the
#      selftest that asserted it, and the exit status 2/3 (empty id / no sha256 tool) were all thrown away by the only
#      production caller, so a submission could fall off the intention-to-treat roster with no trace anywhere. (P3)-(P4)
#      prove the failure now reaches the builder's terminal (stderr) AND is stated on stdout, in both shells.
#
# Covers (each scenario under every available shell):
#   P1 on-arm bead, everything healthy      -> arm on, rc 0, roster row written, label "pregate:on" lands, confirmed
#   P2 off-arm bead                         -> same with off (the control arm is stamped too)
#   P3 roster write fails                   -> rc 4, arm still stamped, WARN visible on stderr, "NOT recorded" on stdout
#   P4 no arm (empty bead id -> roster rc 2) -> arm empty, NO pregate label added, "NOT recorded ... no arm" on stdout
#   P5 label add does not land              -> the read-back says so ("does NOT carry"), never a silent success
#   P6 marker labels unreadable             -> reported as <unreadable>, not as success
#   P7 (mutation) the OLD `$PREGATE_LABEL_ARG` shape hands bd ONE word under zsh and two under bash, so P1 can discriminate
#   P8 structure: no PREGATE_LABEL_ARG left in either copy of gate-done.md, the roster call no longer discards stderr,
#      and the two copies of gate-done.md (commands/ and internal/templates/) are byte-identical
#
# Exit 0 iff every assertion holds. zsh scenarios are skipped (loudly) only when zsh is not installed.
# Bash 3.2 compatible (no associative arrays, no mapfile).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gate-done.md resolution (same priority as the sibling gate-done selftests)
GATE_DONE="$SELF_DIR/../../../commands/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/../../../internal/templates/commands/bodies/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/gate-done.md"
GATE_DONE_COPY="$SELF_DIR/../../../../internal/templates/commands/bodies/gate-done.md"
PG="$SELF_DIR/pre-gate-review.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — expected [$2] got [$1]"; fi; }
# here-string, never `printf | grep -q`: under pipefail grep -q can SIGPIPE the writer and flip a true match to false
has_str() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 — not found: $2"; fi; }
not_str() { if grep -qF -- "$2" <<<"$1"; then bad "$3 — present: $2"; else ok "$3"; fi; }

echo "== gate-done-pregate-stamp.selftest =="

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
[ -f "$PG" ] || { echo "missing $PG"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-done-pgstamp.XXXXXX")" || { echo "mktemp failed"; exit 2; }
cleanup() { [ -n "${T:-}" ] && [ -d "$T" ] && rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SHELLS=(bash)
if command -v zsh >/dev/null 2>&1; then
  SHELLS+=(zsh)
else
  echo "  (skip) zsh is not installed — the zsh half of this suite is NOT being run"
fi

# extract_sentinel_block <file> <name> — the lines strictly BETWEEN the "# SELFTEST-EXTRACT <name>: BEGIN" / ": END"
# sentinels; fails unless each occurs exactly once and END follows BEGIN (a sed range with a missing END would run to EOF).
extract_sentinel_block() {
  local file="$1" name="$2" nb ne
  nb=$(grep -cF "# SELFTEST-EXTRACT ${name}: BEGIN" "$file")
  ne=$(grep -cF "# SELFTEST-EXTRACT ${name}: END" "$file")
  case "$nb:$ne" in
    1:1) : ;;
    *) echo "expected exactly one BEGIN and one END sentinel for '${name}', found BEGIN='$nb' END='$ne'" >&2; return 1 ;;
  esac
  awk -v b="# SELFTEST-EXTRACT ${name}: BEGIN" -v e="# SELFTEST-EXTRACT ${name}: END" '
    index($0, b) { inblk = 1; next }
    index($0, e) { if (inblk) closed = 1; exit }
    inblk        { print }
    END          { exit (closed ? 0 : 1) }' "$file" \
    || { echo "'${name}': END sentinel does not follow BEGIN" >&2; return 1; }
}

# ── (P0) the shipped blocks must be extractable and must parse in every shell ──
RUN=1
for blk in pregate-roster pregate-stamp; do
  if [ ! -f "$GATE_DONE" ]; then bad "(P0) gate-done.md not found at $GATE_DONE"; RUN=0; break; fi
  if extract_sentinel_block "$GATE_DONE" "$blk" > "$T/$blk.sh" 2> "$T/extract.err" && [ -s "$T/$blk.sh" ]; then
    ok "(P0) extracted '$blk' from gate-done.md via its SELFTEST-EXTRACT sentinels ($(wc -l < "$T/$blk.sh" | tr -d ' ') lines)"
    for sh in "${SHELLS[@]}"; do
      if "$sh" -n "$T/$blk.sh" 2> "$T/parse.err"; then ok "(P0/$sh) '$blk' parses"
      else bad "(P0/$sh) '$blk' does not parse: $(head -3 "$T/parse.err" | tr '\n' ' ')"; RUN=0; fi
    done
  else
    bad "(P0) could not extract '$blk' from $GATE_DONE: $(cat "$T/extract.err" 2>/dev/null)"; RUN=0
  fi
done

# ── fixture: a fake city whose pre-gate-review.sh is the REAL one, and a stub bd ──
CITY="$T/city"; mkdir -p "$CITY/packs/town-deltas" "$T/bin" "$T/work" "$T/state"
ln -s "$SELF_DIR" "$CITY/packs/town-deltas/assets"

# bd stub. Records every call (one argv word per line, so a word that contains a space is visible as such), keeps the
# marker's labels in $STUB_DIR/labels, and can be told to fail: BD_STUB_LABEL_FAIL=1 (label add exits 1, stores nothing),
# BD_STUB_LABEL_DROP=1 (label add exits 0 but stores nothing — the exit code lies), BD_STUB_SHOW_FAIL=1 (show unreadable).
cat > "$T/bin/bd" <<'STUB'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
{ printf 'CALL\n'; for a in "$@"; do printf 'ARG:%s\n' "$a"; done; } >> "$d/bd.log"
[ "${1:-}" = "-C" ] && shift 2
case "${1:-} ${2:-}" in
  "label add")
    [ "${BD_STUB_LABEL_FAIL:-0}" = 1 ] && exit 1
    [ "${BD_STUB_LABEL_DROP:-0}" = 1 ] && exit 0
    printf '%s\n' "${4:-}" >> "$d/labels"
    exit 0 ;;
  "show "*)
    [ "${BD_STUB_SHOW_FAIL:-0}" = 1 ] && exit 1
    { echo gate-status:ready; [ -f "$d/labels" ] && cat "$d/labels"; } | jq -R . | jq -s --arg id "${2:-}" '[{id: $id, labels: .}]'
    exit 0 ;;
  "create "*)
    for a in "$@"; do printf 'W:%s\n' "$a"; done
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/bd"

# one on-arm and one off-arm bead id, from the REAL rule (never hard-coded: the rule is the thing under test's dependency)
ON_BEAD=""; OFF_BEAD=""; i=0
while [ -z "$ON_BEAD" ] || [ -z "$OFF_BEAD" ]; do
  id="ga-ps$i"; a="$(bash "$PG" arm "$id" 2>/dev/null)"
  [ "$a" = "on" ] && [ -z "$ON_BEAD" ] && ON_BEAD="$id"
  [ "$a" = "off" ] && [ -z "$OFF_BEAD" ] && OFF_BEAD="$id"
  i=$((i+1)); [ "$i" -gt 200 ] && break
done
if [ -n "$ON_BEAD" ] && [ -n "$OFF_BEAD" ]; then ok "fixture beads: on=$ON_BEAD off=$OFF_BEAD"; else bad "could not find an on and an off bead id"; RUN=0; fi

# run_file <shell> <file> — a clean, rc-less shell of that kind (zsh -f: default options, SH_WORD_SPLIT off — the setting
# the agents' live Bash tool, which is zsh, runs under).
run_file() {
  case "$1" in
    bash) env -u BASH_ENV -u ENV bash --noprofile --norc "$2" ;;
    zsh)  env -u BASH_ENV -u ENV zsh -f "$2" ;;
  esac
}

# run_step3 <shell> <bead-id> <log-dir> [ENV=VAL ...] — run the two shipped blocks in one driver, as Step 3 does (roster
# first, then the stamp once the marker exists). Sets OUT (stdout), ERR (stderr) and RC_END (0 iff the driver reached its end).
OUT=""; ERR=""; RC_END=1
run_step3() {
  local sh="$1" bead="$2" logdir="$3"; shift 3
  rm -f "$T/state/bd.log" "$T/state/labels"
  {
    echo 'BEAD_ID="$AC_BEAD"; BRANCH="feat/x"; GC_CITY_PATH="$AC_CITY"; MARKER_ID="ga-marker1"'
    cat "$T/pregate-roster.sh"
    echo 'printf "__ARM__=[%s]\n__RC__=[%s]\n" "$PREGATE_ARM" "$PREGATE_RC"'
    cat "$T/pregate-stamp.sh"
    echo 'printf "__END__\n"'
  } > "$T/driver.sh"
  # a subshell that exports the environment, then calls run_file: `env ... run_file` cannot exec a shell function
  OUT="$( cd "$T/work" && export AC_BEAD="$bead" AC_CITY="$CITY" PATH="$T/bin:$PATH" STUB_DIR="$T/state" \
            PRE_GATE_LOG_DIR="$logdir" PRE_GATE_CITY="$CITY"
          for kv in "$@"; do export "$kv"; done
          run_file "$sh" "$T/driver.sh" 2> "$T/stderr.txt" )"
  ERR="$(cat "$T/stderr.txt")"
  if grep -qF '__END__' <<<"$OUT"; then RC_END=0; else RC_END=1; fi
}
field() { sed -n "s/^__$2__=\[\(.*\)\]\$/\1/p" <<<"$1" | head -1; }
labels_file() { cat "$T/state/labels" 2>/dev/null || true; }
# how many `label add` calls bd saw; 0 when bd was never called (no log at all), never an empty string
label_add_calls() { local n; n=$(grep -c '^ARG:add$' "$T/state/bd.log" 2>/dev/null); echo "${n:-0}"; }

if [ "$RUN" -eq 1 ]; then
  for sh in "${SHELLS[@]}"; do
    echo "── $sh ──"
    : > "$T/notadir"

    # P1 on-arm, healthy
    rm -rf "$T/logs"
    run_step3 "$sh" "$ON_BEAD" "$T/logs"
    eq "$RC_END" "0" "(P1/$sh) on-arm: the driver ran to its end (a block that dies must not read as a pass)"
    eq "$(field "$OUT" ARM)" "on" "(P1/$sh) on-arm: PREGATE_ARM=on"; eq "$(field "$OUT" RC)" "0" "(P1/$sh) roster exit 0"
    eq "$(labels_file)" "pregate:on" "(P1/$sh) the label that LANDED is exactly 'pregate:on' — one word, no leading space"
    has_str "$OUT" "Pre-gate arm: pregate:on is on marker ga-marker1." "(P1/$sh) the stamp is confirmed by a read-back, out loud"
    not_str "$OUT" "NOT recorded" "(P1/$sh) nothing is reported as unrecorded when it was recorded"
    has_str "$(cat "$T/logs/runs.jsonl" 2>/dev/null)" "\"bead\": \"$ON_BEAD\"" "(P1/$sh) the roster row for the bead was written"
    eq "$(label_add_calls)" "1" "(P1/$sh) exactly one 'label add' call"
    # the word that reached bd, byte for byte: 'pregate:on' — not '-l pregate:on', not ' pregate:on'
    has_str "$(cat "$T/state/bd.log")" "ARG:pregate:on" "(P1/$sh) bd received the label as its own argv word"
    not_str "$(cat "$T/state/bd.log")" "ARG: pregate:on" "(P1/$sh) …with no leading space"
    not_str "$(cat "$T/state/bd.log")" "ARG:-l pregate" "(P1/$sh) …and not glued to a '-l' flag inside one word"

    # P2 off-arm
    rm -rf "$T/logs"
    run_step3 "$sh" "$OFF_BEAD" "$T/logs"
    eq "$(field "$OUT" ARM)" "off" "(P2/$sh) off-arm: PREGATE_ARM=off"; eq "$(labels_file)" "pregate:off" "(P2/$sh) the control arm is stamped too ('pregate:off')"
    has_str "$(cat "$T/logs/runs.jsonl" 2>/dev/null)" "\"bead\": \"$OFF_BEAD\"" "(P2/$sh) the control bead is on the roster"

    # P3 roster write fails: WARN must reach the builder, the arm must still be stamped, the gap must be stated
    run_step3 "$sh" "$ON_BEAD" "$T/notadir/sub"
    eq "$RC_END" "0" "(P3/$sh) roster write fails: the driver still runs to its end (fail-open on tooling)"
    eq "$(field "$OUT" RC)" "4" "(P3/$sh) roster exit 4 (arm printed, roster row NOT written) reaches the caller"
    eq "$(field "$OUT" ARM)" "on" "(P3/$sh) …and the arm is not withheld"
    has_str "$ERR" "could NOT be written to the roster" "(P3/$sh) the WARN reaches the builder's terminal (stderr is not discarded)"
    has_str "$OUT" "pre-gate roster NOT recorded" "(P3/$sh) the gap is stated on stdout too"
    eq "$(labels_file)" "pregate:on" "(P3/$sh) the label is still stamped"

    # P4 no arm: empty bead id -> roster usage error (rc 2). Not "off", not stamped, and said out loud.
    rm -rf "$T/logs"
    run_step3 "$sh" "" "$T/logs"
    eq "$RC_END" "0" "(P4/$sh) no arm: the driver still runs to its end"
    eq "$(field "$OUT" ARM)" "" "(P4/$sh) no arm: PREGATE_ARM is empty — unknown is not 'off'"
    eq "$(field "$OUT" RC)" "2" "(P4/$sh) the roster's own exit status (2) is kept, not collapsed into an empty arm"
    has_str "$OUT" "pre-gate roster NOT recorded: no arm could be determined" "(P4/$sh) …and it is stated, not silent"
    eq "$(label_add_calls)" "0" "(P4/$sh) no 'label add' at all when there is no arm"
    eq "$(labels_file)" "" "(P4/$sh) no pregate:* label on the marker"
    [ ! -s "$T/logs/runs.jsonl" ] && ok "(P4/$sh) nothing was written to the roster" || bad "(P4/$sh) a bead with no arm reached the roster"

    # P5 the label add exits 0 but does not land: the exit code lies, the read-back must not
    rm -rf "$T/logs"
    run_step3 "$sh" "$ON_BEAD" "$T/logs" BD_STUB_LABEL_DROP=1
    has_str "$OUT" "does NOT carry pregate:on" "(P5/$sh) label add exit 0 but nothing landed → the read-back reports it"
    not_str "$OUT" "Pre-gate arm: pregate:on is on marker" "(P5/$sh) …and does NOT claim success"
    # …and the failing variant
    run_step3 "$sh" "$ON_BEAD" "$T/logs" BD_STUB_LABEL_FAIL=1
    has_str "$OUT" "does NOT carry pregate:on" "(P5/$sh) label add exits 1 → the read-back reports it"

    # P6 the marker's labels cannot be read back
    run_step3 "$sh" "$ON_BEAD" "$T/logs" BD_STUB_SHOW_FAIL=1
    has_str "$OUT" "labels: <unreadable>" "(P6/$sh) unreadable read-back is reported as <unreadable>, not as success"
    not_str "$OUT" "Pre-gate arm: pregate:on is on marker" "(P6/$sh) …and does NOT claim success"
  done

  # ── P7 mutation check: the OLD shape (an unquoted "-l pregate:<arm>" variable) under each shell ──
  echo "── (P7) mutation check: the previous shape ──"
  cat > "$T/old.sh" <<'OLD'
PREGATE_ARM=on
PREGATE_LABEL_ARG=""
case "$PREGATE_ARM" in on|off) PREGATE_LABEL_ARG="-l pregate:$PREGATE_ARM" ;; esac
bd create "ready-for-gate: x" -t chore -l type:quality-gate-marker $PREGATE_LABEL_ARG -d "d"
OLD
  for sh in "${SHELLS[@]}"; do
    words="$( export PATH="$T/bin:$PATH" STUB_DIR="$T/state"; run_file "$sh" "$T/old.sh" 2>/dev/null )"
    case "$sh" in
      bash)
        has_str "$words" "W:pregate:on" "(P7/bash) the old shape splits into '-l' and 'pregate:on' under bash (which is why nobody noticed)"
        not_str "$words" "W:-l pregate:on" "(P7/bash) …no combined word under bash" ;;
      zsh)
        has_str "$words" "W:-l pregate:on" "(P7/zsh) the old shape hands bd ONE word '-l pregate:on' under this zsh — the bug the gate found, reproduced"
        not_str "$words" "W:pregate:on" "(P7/zsh) …so 'pregate:on' never arrives as a label of its own" ;;
    esac
  done
fi

# ── (P8) structure ──
echo "── (P8) structure ──"
if [ -f "$GATE_DONE" ]; then
  n_old=$(grep -c 'PREGATE_LABEL_ARG' "$GATE_DONE" || true)
  eq "$n_old" "0" "(P8) no PREGATE_LABEL_ARG left in gate-done.md (nothing in Step 3 depends on word-splitting the arm)"
  # the roster call itself: its stderr must not be discarded (the WARN is the only trace of a failed roster write)
  roster_line="$(grep -F 'pre-gate-review.sh" roster' "$GATE_DONE" | head -1)"
  has_str "$roster_line" 'roster "$BEAD_ID" "$BRANCH"' "(P8) the roster call is present in Step 3"
  not_str "$roster_line" '2>/dev/null' "(P8) the roster call does not discard stderr"
  not_str "$roster_line" '|| PREGATE_ARM=""' "(P8) the roster call does not swallow its exit status into an empty arm"
  # the create call must not carry the pregate label at all any more
  create_block="$(awk '/MARKER_ID=\$\(bd -C "\$GC_CITY_PATH" create/ { f = 1 } f { print } /--json 2>\/dev\/null/ { if (f) exit }' "$GATE_DONE")"
  not_str "$create_block" 'pregate' "(P8) the marker's bd create call carries no pregate argument"
fi
if [ -f "$GATE_DONE_COPY" ] && [ -f "$GATE_DONE" ]; then
  if cmp -s "$GATE_DONE" "$GATE_DONE_COPY"; then ok "(P8) commands/gate-done.md and internal/templates/.../gate-done.md are byte-identical"
  else bad "(P8) the two copies of gate-done.md differ — the engine template would ship a different Step 3"; fi
else
  echo "  (skip) (P8) copy-parity: only one copy of gate-done.md is reachable from here"
fi

echo
echo "gate-done-pregate-stamp.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
