#!/usr/bin/env bash
# pool-probe-disk-floor.selftest.sh — ga-vln2py (P0, 17/10).
#
# The wa-worker and ps-worker self-serve probes (Step 1b2 and its Step 1b3 fallback) hand out NO new bead while the
# free disk is under the new-work floor (disk-headroom-lib.sh, 5 GB): a builder started on a disk that low is what
# filled it on 17/10 and took Dolt down. Same answer as the gate focus mode gives when it has nothing for you: [].
#
# End to end: the WHOLE Step 1b2 block is extracted from each tracked prompt and run against a fake `bd`, with the
# disk reading pinned by DISK_FREE_OVERRIDE_MB (the lib's own seam). The Step 1b3 program is extracted off its line and
# run on its own. Three states, never two: low holds back, ok does not, and a disk that cannot be read (unknown) holds
# NOTHING back but says so on stderr — it must not be mistaken for "the disk is fine", nor stop the pool.
# Two textual MUTANTS of the block (the hold never fires; an unknown disk fails closed) must each be caught.
# ga-nyug12: the low-disk hold is silent for ordinary beads, but a bead of the FIX class (gate:needs-fix, gate:fix-attempt:*,
# origem:auto-healer-notify, impacto:dano-ao-vivo - the focus-mode set) held back by it gets a NOTE on stderr naming it and the
# Mayor nudge (the answer stays [] - drain); a third mutant (the NOTE dropped) must be caught. Step 1b3 stays silent on an
# unknown disk ON PURPOSE (1b2 ran first in the same turn and warned) - its comment says so and a check pins the sentence.
#
# Exit 0 iff every scenario, for both files, behaves as expected.
set -uo pipefail
export GATE_FOCUS_ACTIVE_OVERRIDE=0   # the probes read the gate focus mode too; pin it OFF so only the disk decides

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pool-probe-disk-floor.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
trap '[ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin"

# (the extraction and the fake bd follow pool-probe-priority-sort.selftest.sh, duplicated on purpose: each guard
# must fail on its own if the block's shape changes, not inherit a sibling's broken extractor)
extract_step1b2_block() {
  awk '
    /^# Step 1b2/ { seen = 1; next }
    seen && /^# If it returns a bead/ { exit }
    seen && !started && (/^#/ || /^$/) { next }
    seen { started = 1; print }
  ' "$1"
}
extract_fallback_postfilter_jq() {
  local line marker after prog
  line="$(grep -F '{{ .RoutedPoolQuery }} | jq -c ' "$1" | head -1)"; [ -n "$line" ] || return 1
  marker='{{ .RoutedPoolQuery }} | jq -c '"'"
  after="${line#*$marker}"; [ "$after" != "$line" ] || return 1
  prog="${after%\'}"; { [ -n "$prog" ] && [ "$prog" != "$after" ]; } || return 1
  printf '%s' "$prog"
}
cat > "$WORK/bin/bd" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_BD_FAIL:-}" ]; then echo "bd: simulated failure" >&2; exit 1; fi
jq -c 'sort_by(.priority // 99)' "$WA_FIXTURE"
SH
chmod +x "$WORK/bin/bd"
FIXTURE='[{"id":"p1-bead","priority":1,"issue_type":"task","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","labels":[]},{"id":"p2-bead","priority":2,"issue_type":"task","created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","labels":[]}]'
printf '%s' "$FIXTURE" > "$WORK/fixture.json"
FIX_FIXTURE='[{"id":"fix-1","priority":1,"issue_type":"task","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","labels":["gate:needs-fix"]},{"id":"live-2","priority":2,"issue_type":"task","created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","labels":["impacto:dano-ao-vivo"]},{"id":"plain-3","priority":3,"issue_type":"task","created_at":"2026-01-03T00:00:00Z","updated_at":"2026-01-03T00:00:00Z","labels":[]}]'
printf '%s' "$FIX_FIXTURE" > "$WORK/fixture-fix.json"

# run_block <block-file> <disk-env...> — OUT / ERR
run_block() {
  local blk="$1"; shift
  OUT="$(env PATH="$WORK/bin:$PATH" WA_FIXTURE="$WORK/fixture.json" GC_CITY_PATH="${CITY:-$CITY_ROOT}" GC_CITY="${CITY:-$CITY_ROOT}" "$@" bash "$blk" 2>"$WORK/err")"
  ERR="$(cat "$WORK/err")"
}
first_id() { printf '%s' "$OUT" | jq -r '.[0].id // "EMPTY"' 2>/dev/null; }

check_template() {
  local label="$1" tpl="$2" pfx="$3" blk got prog
  [ -f "$tpl" ] || { bad "$label: template not found at $tpl"; return; }
  blk="$WORK/$pfx.block.sh"
  extract_step1b2_block "$tpl" > "$blk"
  [ -s "$blk" ] || { bad "$label: could not extract the Step 1b2 block (anchors changed?)"; return; }
  bash -n "$blk" 2>"$WORK/syntax" || { bad "$label: the Step 1b2 block does not parse: $(cat "$WORK/syntax")"; return; }

  run_block "$blk" DISK_FREE_OVERRIDE_MB=100000
  got="$(first_id)"; [ "$got" = "p1-bead" ] && ok "$label: roomy disk -> the best bead is handed out" || bad "$label: roomy disk answered '$got' (stdout: ${OUT:0:120}; stderr: ${ERR:0:200})"
  [ -z "$ERR" ] && ok "$label: roomy disk -> nothing on stderr" || bad "$label: roomy disk wrote on stderr: ${ERR:0:200}"

  run_block "$blk" DISK_FREE_OVERRIDE_MB=3000
  [ "$OUT" = "[]" ] && ok "$label: disk 3000 MB (< 5120) -> [] (nothing for you)" || bad "$label: disk 3000 MB did not answer [] (stdout: ${OUT:0:160})"
  [ -z "$ERR" ] && ok "$label: …and silent: a hold is an answer, not a doubt" || bad "$label: the hold wrote on stderr: ${ERR:0:200}"

  run_block "$blk" DISK_FREE_OVERRIDE_MB=5120; got="$(first_id)"
  [ "$got" = "p1-bead" ] && ok "$label: exactly the floor (5120 MB) is not low" || bad "$label: 5120 MB held the pool back ('$got')"
  run_block "$blk" DISK_FREE_OVERRIDE_MB=5119
  [ "$OUT" = "[]" ] && ok "$label: one MB under the floor holds back" || bad "$label: 5119 MB did not hold back (stdout: ${OUT:0:120})"

  run_block "$blk" DISK_FREE_OVERRIDE_MB=garbage; got="$(first_id)"
  [ "$got" = "p1-bead" ] && ok "$label: unreadable disk -> fail OPEN (the pool is served)" || bad "$label: unreadable disk answered '$got' — it must not stop the pool"
  case "$ERR" in *"free disk could not be read"*) ok "$label: …and says so on stderr (unknown is not 'fine')" ;; *) bad "$label: unreadable disk left no WARN on stderr: ${ERR:0:200}" ;; esac

  run_block "$blk" DISK_FREE_OVERRIDE_MB=3000 DISK_HEADROOM_ENABLED=0; got="$(first_id)"
  [ "$got" = "p1-bead" ] && ok "$label: kill switch DISK_HEADROOM_ENABLED=0 -> as before" || bad "$label: kill switch ignored ('$got')"

  # the library file missing from the city: unknown -> the pool is served and the WARN is there
  mkdir -p "$WORK/city/packs/town-deltas/assets/scripts"
  for f in work-order.sh gate-focus-lib.sh; do cp "$CITY_ROOT/packs/town-deltas/assets/scripts/$f" "$WORK/city/packs/town-deltas/assets/scripts/$f"; done
  CITY="$WORK/city" run_block "$blk" DISK_FREE_OVERRIDE_MB=3000; got="$(first_id)"
  [ "$got" = "p1-bead" ] && case "$ERR" in *"free disk could not be read"*) true ;; *) false ;; esac \
    && ok "$label: library missing -> unknown: pool served, WARN on stderr" || bad "$label: library missing answered '$got' / stderr '${ERR:0:160}'"

  # a failed query on a low disk is still "could not tell", not "nothing for you"
  run_block "$blk" DISK_FREE_OVERRIDE_MB=3000 FAKE_BD_FAIL=1
  [ "$OUT" != "[]" ] && case "$ERR" in *"pool query printed nothing"*) true ;; *) false ;; esac \
    && ok "$label: failed query + low disk -> still the 'query printed nothing' WARN, never a fake []" || bad "$label: failed query + low disk read as 'nothing for you' (stdout: ${OUT:0:80}; stderr: ${ERR:0:200})"

  # ga-nyug12 (item 2): a fix-class bead held by the low disk is named on stderr, with the Mayor nudge; the answer is still []
  run_block "$blk" DISK_FREE_OVERRIDE_MB=3000 WA_FIXTURE="$WORK/fixture-fix.json"
  [ "$OUT" = "[]" ] && ok "$label: fix-class beads + disk 3000 MB -> still [] (the hold has no exception)" || bad "$label: fix-class beads + low disk did not answer [] (stdout: ${OUT:0:160})"
  case "$ERR" in *"NOTE disk floor (Step 1b2)"*"fix-1"*"live-2"*"gc session nudge mayor"*) ok "$label: …with a NOTE naming the held fix/live-damage beads and the Mayor nudge" ;; *) bad "$label: fix-class beads held by the low disk left no NOTE on stderr: ${ERR:0:300}" ;; esac
  case "$ERR" in *plain-3*) bad "$label: the NOTE names a bead that is not fix-class: ${ERR:0:300}" ;; *) ok "$label: …and does not name the ordinary bead" ;; esac
  run_block "$blk" DISK_FREE_OVERRIDE_MB=3000 WA_FIXTURE="$WORK/fixture-fix.json" GATE_FOCUS_ACTIVE_OVERRIDE=1
  case "$ERR" in *"NOTE disk floor (Step 1b2)"*"fix-1"*) ok "$label: focus mode on + low disk -> the same NOTE" ;; *) bad "$label: focus mode + low disk left no NOTE: ${ERR:0:300}" ;; esac
  run_block "$blk" DISK_FREE_OVERRIDE_MB=100000 WA_FIXTURE="$WORK/fixture-fix.json"; got="$(first_id)"
  [ "$got:$ERR" = "fix-1:" ] && ok "$label: roomy disk + fix-class beads -> served, silent (no NOTE without a hold)" || bad "$label: roomy disk answered '$got' / stderr '${ERR:0:200}'"
  run_block "$blk" DISK_FREE_OVERRIDE_MB=garbage WA_FIXTURE="$WORK/fixture-fix.json"; got="$(first_id)"
  case "$ERR" in *"NOTE disk floor"*) bad "$label: unreadable disk wrote the held-back NOTE although nothing was held: ${ERR:0:200}" ;; *"free disk could not be read"*) [ "$got" = "fix-1" ] && ok "$label: unreadable disk + fix-class beads -> served with the WARN only, no NOTE" || bad "$label: unreadable disk answered '$got'" ;; *) bad "$label: unreadable disk left no WARN: ${ERR:0:200}" ;; esac

  # Step 1b3: the program after the Go-rendered query
  if prog="$(extract_fallback_postfilter_jq "$tpl")"; then
    got="$(printf '[{"id":"x","labels":[]}]' | DISK_HEADROOM_PROBE=low jq -c "$prog" 2>&1)"
    [ "$got" = "[]" ] && ok "$label: Step 1b3 post-filter with a low disk -> []" || bad "$label: Step 1b3 post-filter let a bead through on a low disk: $got"
    got="$(printf '[{"id":"x","labels":[]}]' | DISK_HEADROOM_PROBE=ok jq -c "$prog" 2>&1)"
    [ "$got" = '[{"id":"x","labels":[]}]' ] && ok "$label: Step 1b3 post-filter with ok -> unchanged" || bad "$label: Step 1b3 post-filter changed the answer on an ok disk: $got"
    got="$(printf '[{"id":"x","labels":[]}]' | env -u DISK_HEADROOM_PROBE jq -c "$prog" 2>&1)"
    [ "$got" = '[{"id":"x","labels":[]}]' ] && ok "$label: Step 1b3 post-filter with the variable unset -> unchanged (fail open)" || bad "$label: Step 1b3 post-filter failed with the variable unset: $got"
    got="$(printf '[{"id":"x","labels":[]}]' | DISK_HEADROOM_PROBE=unknown jq -c "$prog" 2>&1)"
    [ "$got" = '[{"id":"x","labels":[]}]' ] && ok "$label: Step 1b3 post-filter with the disk 'unknown' -> unchanged and silent (1b2 warned already)" || bad "$label: Step 1b3 post-filter changed or spoke on an unknown disk: $got"
  else
    bad "$label: could not extract the Step 1b3 post-filter (line shape changed?)"
  fi
  # ga-nyug12 (item 5): the 1b3 line says nothing on an unknown disk; that is right only because 1b2 ran first in the same turn, and the comment above it must say so
  sect="$(awk '/^# Step 1b3/ { f = 1 } f && /^export GATE_FOCUS_PROBE=/ { exit } f' "$tpl")"
  case "$sect" in *"silent on purpose"*"same turn"*) ok "$label: the Step 1b3 comment says why an unknown disk is silent there (on purpose; 1b2 warned in the same turn)" ;; *) bad "$label: the Step 1b3 comment does not explain the silence on an unknown disk" ;; esac
  grep -E '^export GATE_FOCUS_PROBE=.*export DISK_HEADROOM_PROBE="\$\(\. .*disk-headroom-lib\.sh" 2>/dev/null && disk_headroom_state\)"; \{\{ \.RoutedPoolQuery \}\}' "$tpl" >/dev/null \
    && ok "$label: Step 1b3 reads the disk BEFORE the query pipeline" || bad "$label: Step 1b3 does not export DISK_HEADROOM_PROBE ahead of the Go-rendered query"

  # mutants of the 1b2 block: each must break the scenario named for it
  sed 's/WA_CAND="\[\]" ;;/WA_CAND="$WA_CAND" ;;/; s/PS_CAND="\[\]" ;;/PS_CAND="$PS_CAND" ;;/' "$blk" > "$WORK/$pfx.mut-nohold.sh"
  cmp -s "$blk" "$WORK/$pfx.mut-nohold.sh" && bad "$label: mutant 'the hold never fires' did not change the block"
  run_block "$WORK/$pfx.mut-nohold.sh" DISK_FREE_OVERRIDE_MB=3000
  [ "$OUT" != "[]" ] && ok "$label: mutant 'the hold never fires' is caught (the low-disk answer is no longer [])" || bad "$label: mutant 'the hold never fires' SURVIVED"
  sed 's/^    \[ -n "\$'"$pfx"'_FIX_HELD" \] && echo "NOTE disk floor.*$/    :/' "$blk" > "$WORK/$pfx.mut-nonote.sh"
  cmp -s "$blk" "$WORK/$pfx.mut-nonote.sh" && bad "$label: mutant 'the NOTE is dropped' did not change the block"
  run_block "$WORK/$pfx.mut-nonote.sh" DISK_FREE_OVERRIDE_MB=3000 WA_FIXTURE="$WORK/fixture-fix.json"
  case "$ERR" in *"NOTE disk floor"*) bad "$label: mutant 'the NOTE is dropped' SURVIVED" ;; *) ok "$label: mutant 'the NOTE is dropped' is caught (a held fix-class bead would be silent again)" ;; esac
  sed 's/^  \*) echo "WARN disk floor (Step 1b2): the free disk could not be read.*$/  *) '"$pfx"'_CAND="[]" ;;/' "$blk" > "$WORK/$pfx.mut-closed.sh"
  cmp -s "$blk" "$WORK/$pfx.mut-closed.sh" && bad "$label: mutant 'unknown fails closed' did not change the block"
  run_block "$WORK/$pfx.mut-closed.sh" DISK_FREE_OVERRIDE_MB=garbage
  [ "$OUT" = "[]" ] && ok "$label: mutant 'unknown fails closed' is caught (it would stop the pool on a df hiccup)" || bad "$label: mutant 'unknown fails closed' SURVIVED"
}

check_template "wa-worker" "$CITY_ROOT/agents/wa-worker/prompt.template.md" WA
check_template "ps-worker" "$CITY_ROOT/agents/ps-worker/prompt.template.md" PS

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
