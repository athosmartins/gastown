#!/usr/bin/env bash
# pilot-dispatcher.salvage-branch.selftest.sh — ga-vpan6h8: a bead cujo builder morreu com commit local, reclamada pelo inflight-reclaim-guard, não era re-despachada: o ramo crew/<pool>/<bead> que ele deixou
# (e, depois do ga-ufr7, a cópia que o guard empurrava para origin com o mesmo nome) lia como entrega — _beadid_branch_signal dizia `block` até 48 h depois do último commit (PILOT_ORPHAN_BRANCH_STALE_HOURS).
# wa-4qu2n6.1, 19/11 (relato do witness): 48 recusas em ~13 h. Reproduzido com git real: SÓ o ramo local já basta para o veto (o push do guard é um segundo ref com o mesmo nome).
#
# O guard grava na bead onde salvou o trabalho (pilot.salvage_sha = os commits, separados por espaço). Um ramo AINDA nessa ponta não teve commit desde que o builder se foi: nada em voo, nada entregue.
#
# O QUE PROVA (git de verdade, as funções REAIS cortadas do dispatcher, sem bd/gc/rede):
#   S1  _beadid_branch_signal: ramo não mesclado cuja ponta é um sha de pilot.salvage_sha → classe `salvage` (ramo local, local com dois shas na lista, ref de origin). Qualquer outra coisa mantém o veto de antes
#       (`block`): ponta que andou, sha de outro commit, bead com dono, valor que não é sha / não é texto, bead sem pilot.salvage_sha, git que não consegue resolver a ponta (falhou não é "congelado");
#       um ramo já mesclado segue `merged` (a prova do guard não afrouxa nada além do `block`).
#   S2  _filter_built: a bead `salvage` segue candidata e o log diz por quê; `block` segue excluída; rótulo gate:* ou marker aberto do gate ainda a derruba.
#   S3  _ownership_guard_should_refuse: `salvage` não recusa o despacho; ponta que andou e bead com dono ainda recusam.
#
# PD_UNDER_TEST=<outro pilot-dispatcher.sh> roda as mesmas asserções noutra árvore: é assim que "falha antes do fix" se prova (o dispatcher do commit pai). Exit 0 iff todas valem.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PD="${PD_UNDER_TEST:-$SELF_DIR/pilot-dispatcher.sh}"
LIB="${LIB_UNDER_TEST:-$SELF_DIR/delivery-branch-patterns.sh}"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -r "$PD" ]  || { echo "FATAL: $PD missing" >&2; exit 2; }
[ -r "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq missing" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git missing" >&2; exit 2; }
REAL_GIT="$(command -v git)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pilot-salvage-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
echo "── pilot-dispatcher salvage-branch (ga-vpan6h8)${PD_UNDER_TEST:+ — UNDER TEST: $PD_UNDER_TEST} ──"

# ── the REAL functions (signature line .. first top-level "}"); one the tree under test lacks is simply absent ──
FNS="$TMP/fns.sh"
: > "$FNS"
for _fn in _delivery_branch_patterns_ready _delivery_branch_local_ref _delivery_branch_listed_ref _delivery_branch_remote_hit \
           _beadid_matched_crew_branch_ref _beadid_branch_signal _filter_built _ownership_guard_should_refuse; do
  awk -v n="$_fn" '$0 ~ "^"n"\\(\\) *\\{" {f=1} f {print} f && /^}$/ {exit}' "$PD" >> "$FNS"
done
# Everything those functions call and this test does not exercise: no gate artifact, no attached session, no live owner.
cat >> "$FNS" <<'STUBS'
_ownership_guard_repos() { return 0; }
_beadid_has_active_gate_artifact() { return 1; }
_beadid_has_open_gate_marker() { case " ${OPEN_MARKER_IDS:-} " in *" $1 "*) return 0 ;; esac; return 1; }
_ownership_guard_flag_orphan_branch() { :; }
_beadid_mentioned_in_attached_session() { return 1; }
_session_is_active_owner() { return 1; }
log() { printf '[pilot-dispatcher] %s\n' "$*"; }          # like the real log/warn: STDOUT — a line that forgets its >&2 corrupts the JSON stream
warn() { printf '[pilot-dispatcher] WARN: %s\n' "$*"; }
timeout() { shift; "$@"; }
bd() {   # the guard's fresh re-read says "open, nobody owns it"
  case " $* " in *" show "*) printf '[{"status":"open","assignee":"","labels":[]}]' ;; esac
  return 0
}
STUBS
bash -n "$FNS" 2>/dev/null || { echo "FATAL: extracted functions do not parse" >&2; exit 2; }

# ── fixture: a rig clone R with a bare origin; every dead-builder branch has ONE commit of its own (the unmerged work the guard saves) ──
ORIGIN="$TMP/origin.git"; R="$TMP/rig"
git init -q --bare "$ORIGIN"
git init -q "$R"
git -C "$R" config user.email t@t.invalid
git -C "$R" config user.name selftest
mkc() { # <message> — one file per message: a counter would not survive the $(...) subshells that run most calls, and a repeated file means "nothing to commit"
  local _f; _f="f_$(printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '_').txt"
  echo "$1" > "$R/$_f"; git -C "$R" add "$_f"; git -C "$R" commit -q -m "$1"
}
echo base > "$R/README"; git -C "$R" add README; git -C "$R" commit -q -m init
MAINBR="$(git -C "$R" symbolic-ref --short HEAD)"
git -C "$R" remote add origin "$ORIGIN"
git -C "$R" push -q origin "HEAD:refs/heads/main" 2>/dev/null
git -C "$R" fetch -q origin 2>/dev/null
BASE="$(git -C "$R" rev-parse HEAD)"
branch_with_commit() { # <branch> → prints the tip sha; one commit of its own on top of main
  git -C "$R" checkout -q -b "$1" "$BASE"; mkc "feat($1): half-built, the builder died here"
  git -C "$R" rev-parse HEAD; git -C "$R" checkout -q "$MAINBR"
}
S01="$(branch_with_commit crew/wa-worker/wa-sal01)"      # the incident: frozen tip
S02="$(branch_with_commit crew/wa-worker/wa-sal02)"      # evidence names ANOTHER commit
S03A="$(branch_with_commit crew/wa-worker/wa-sal03)"     # evidence names A; a builder then committed B on top
git -C "$R" checkout -q crew/wa-worker/wa-sal03; mkc "feat(wa-sal03): B, after the reclaim"; S03B="$(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q "$MAINBR"
S04="$(branch_with_commit fix/wa-sal04-slug)"            # a fix/ branch; the list holds two shas
S05="$(branch_with_commit crew/wa-worker/wa-sal05)"      # only as a fetched origin ref
git -C "$R" push -q origin crew/wa-worker/wa-sal05 2>/dev/null; git -C "$R" branch -D crew/wa-worker/wa-sal05 >/dev/null 2>&1; git -C "$R" fetch -q origin 2>/dev/null
S06="$(branch_with_commit crew/wa-worker/wa-sal06)"      # the bead has an owner again
S07="$(branch_with_commit crew/wa-worker/wa-sal07)"      # malformed evidence
S08="$(branch_with_commit crew/wa-worker/wa-sal08)"      # the pre-fix state: no evidence at all
mkc "fix(wa-mrg01): delivered"; git -C "$R" branch fix/wa-mrg01-slug HEAD; MRG="$(git -C "$R" rev-parse HEAD)"   # a branch whose tip is on main and a commit there names the bead
git -C "$R" push -q origin "HEAD:refs/heads/main" 2>/dev/null; git -C "$R" fetch -q origin 2>/dev/null
# the fixture itself: every tip below must exist and differ, or a "tip moved" case would pass for a reason that is not the code's
for _s in "$S01" "$S02" "$S03A" "$S03B" "$S04" "$S05" "$S06" "$S07" "$S08"; do [ -n "$_s" ] || { echo "FATAL: a fixture branch has no tip" >&2; exit 2; }; done
[ "$S03A" != "$S03B" ] || { echo "FATAL: the commit on top of wa-sal03 was not made" >&2; exit 2; }
[ "$(printf '%s\n' "$S01" "$S02" "$S04" "$S05" "$S06" "$S07" "$S08" "$S03A" | sort -u | wc -l | tr -d ' ')" = "8" ] || { echo "FATAL: two fixture branches share a tip" >&2; exit 2; }
# a git that fails when asked a given subcommand (SHIM_FAIL=rev-parse), everything else is the real one
mkdir -p "$TMP/shim"
cat > "$TMP/shim/git" <<'SHIM'
#!/bin/sh
if [ -n "${SHIM_FAIL:-}" ]; then
  for a in "$@"; do [ "$a" = "$SHIM_FAIL" ] && { echo "fatal: shim says no" >&2; exit 128; }; done
fi
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$TMP/shim/git"

# ── runner: a fresh `set -euo pipefail` shell like the dispatcher's; sets RC, OUT, ERR ──
RC=0; OUT=""; ERR=""
run() { # <env assignments (may be empty; no spaces inside a value)> <snippet>
  local _env="$1" _snip="$2"
  RC=0
  OUT="$(env FNS="$FNS" LIB="$LIB" R="$R" REAL_GIT="$REAL_GIT" TMP="$TMP" $_env bash -c '
    set -euo pipefail
    . "$FNS"; . "$LIB"
    _OWNERSHIP_GUARD_REPOS="$R"; _NS_BRANCH_REPOS="$R"; _NS_RIG_LIST_OK=1; GC_CITY=/nonexistent
    SELF_BEAD_ID=self-bead; _DEADWORKER_OK=0; PILOT_ORPHAN_BRANCH_STALE_HOURS=48
    PILOT_TEST_GATE_OPEN_BEADS=""
    '"$_snip" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err" 2>/dev/null)"
}
class_of() { printf '%s' "${OUT%%$'\t'*}"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — want '$2' got '$3'"; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — '$2' not in: $(printf '%s' "$3" | head -c 300)" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1 — '$2' unexpectedly in: $(printf '%s' "$3" | head -c 300)" ;; *) ok "$1" ;; esac; }
bj() { # <bead> <salvage_sha value, raw JSON; empty = no key> [assignee] → the candidate row the Pilot reads
  jq -cn --arg id "$1" --argjson s "${2:-null}" --arg a "${3:-}" '{id:$id, assignee:$a, labels:[], metadata:(if $s == null then {} else {"pilot.salvage_sha":$s} end)}'
}
sig() { run "${3:-}" "_beadid_branch_signal $1 '$2'"; }   # <bead> <row json> [env]
js() { jq -cn --arg v "$1" '$v'; }                        # a sha (or a list of shas) as a JSON string

echo "── S1. _beadid_branch_signal: a branch frozen by the reclaim guard is not a delivery ──"
TAB=$'\t'
sig wa-sal01 "$(bj wa-sal01 "$(js "$S01")")";   eq "local branch, tip == pilot.salvage_sha → salvage, and ONLY that (the whole output: a stray second verdict would hide behind the class)" "salvage${TAB}crew/wa-worker/wa-sal01" "$OUT"
sig wa-sal04 "$(bj wa-sal04 "$(js "$S01 $S04")")"; eq "the tip is the SECOND sha of the list (two branches saved for one bead) → salvage" "salvage" "$(class_of)"
sig wa-sal05 "$(bj wa-sal05 "$(js "$S05")")";   eq "only a fetched origin ref (the push the guard used to make) → salvage, on the origin ref" "salvage" "$(class_of)"
has "…(origin/<name>)" "origin/crew/wa-worker/wa-sal05" "$OUT"
sig wa-sal02 "$(bj wa-sal02 "$(js "$S01")")";   eq "evidence names ANOTHER commit → block (the veto of before)" "block" "$(class_of)"
sig wa-sal03 "$(bj wa-sal03 "$(js "$S03A")")";   eq "a builder committed on top after the reclaim (tip moved) → block: live work is in-flight again" "block" "$(class_of)"
sig wa-sal03 "$(bj wa-sal03 "$(js "$S03B")")";   eq "control: the same branch with evidence naming its CURRENT tip → salvage (the tip is what counts, not the branch)" "salvage" "$(class_of)"
sig wa-sal06 "$(bj wa-sal06 "$(js "$S06")" wa-worker-adhoc-1)"; eq "the bead has an owner again → block, whatever the evidence says" "block" "$(class_of)"
sig wa-sal08 "$(bj wa-sal08 '')";                eq "no pilot.salvage_sha on the bead (the state before this fix) → block" "block" "$(class_of)"
sig wa-sal08 '{"id":"wa-sal08","assignee":"","labels":[]}'; eq "a row with no metadata at all → block" "block" "$(class_of)"
sig wa-sal08 'not json at all';                  eq "a row that is not JSON → block (unreadable evidence never frees a bead)" "block" "$(class_of)"
for _bad in '"salvaged"' '"abc123"' "[\"$S07\"]" '12345' "\"${S07}x\"" "\"$S07 \"" "\"$S07\\n$S07\"" '""'; do
  sig wa-sal07 "$(bj wa-sal07 "$_bad")"; eq "malformed evidence $_bad → block" "block" "$(class_of)"
done
sig wa-sal01 "$(bj wa-sal01 "$(js "$S01")")" "SHIM_FAIL=rev-parse PATH=$TMP/shim:$PATH"
eq "git cannot resolve the tip (rev-parse fails) → block: failed is not frozen" "block" "$(class_of)"
sig wa-mrg01 "$(bj wa-mrg01 "$(js "$MRG")")";    eq "a merged delivery stays merged, and ONLY merged — the evidence never loosens what block did not cover" "merged${TAB}fix/wa-mrg01-slug" "$OUT"

echo "── S2. _filter_built ──"
ALL="[$(bj wa-sal01 "$(js "$S01")"),$(bj wa-sal02 "$(js "$S01")"),$(bj wa-sal03 "$(js "$S03A")"),$(bj wa-sal04 "$(js "$S01 $S04")"),$(bj wa-sal05 "$(js "$S05")"),$(bj wa-sal06 "$(js "$S06")" wa-worker-adhoc-1),$(bj wa-sal08 '')]"
fb() { run "$1" "printf '%s' '$2' | _filter_built | jq -c '[.[].id] | sort'"; }
fb "" "$ALL"
eq "frozen-branch beads stay candidates; a moved tip, stale evidence, an owner and no evidence are still dropped" '["wa-sal01","wa-sal04","wa-sal05"]' "$OUT"
has   "the kept bead is said out loud, with the reason (the log line)" "wa-sal01 has branch" "$ERR"
has   "…the reason names the guard's evidence" "pilot.salvage_sha" "$ERR"
hasnt "…and it is NOT reported as EXCLUÍDO" "EXCLUÍDO wa-sal01" "$ERR"
has   "control: a dropped one is still reported EXCLUÍDO" "EXCLUÍDO wa-sal03" "$ERR"
fb "" "[$(jq -c '.labels=["gate:passed"]' <<< "$(bj wa-sal01 "$(js "$S01")")")]"
eq "a gate:* label still drops it (gate artifacts win over the guard's evidence)" '[]' "$OUT"
fb "OPEN_MARKER_IDS=wa-sal01" "[$(bj wa-sal01 "$(js "$S01")")]"
eq "an OPEN gate marker still drops it" '[]' "$OUT"
fb "" "[$(jq -c '.labels=["gate:needs-fix"]' <<< "$(bj wa-sal01 "$(js "$S01")")")]"
eq "gate:needs-fix keeps its own carve-out (candidate)" '["wa-sal01"]' "$OUT"

echo "── S3. the dispatch-time guard ──"
guard() { run "" "_ownership_guard_should_refuse $1 '$2' /fake"; }
guard wa-sal01 "$(bj wa-sal01 "$(js "$S01")")";  eq "frozen branch → not refused (rc 1, silent)" "1:" "$RC:$OUT"
guard wa-sal03 "$(bj wa-sal03 "$(js "$S03A")")"; has "a moved tip is still refused" "branch:crew/wa-worker/wa-sal03" "$OUT"
guard wa-sal06 "$(bj wa-sal06 "$(js "$S06")" wa-worker-adhoc-1)"; has "a bead with an owner is still refused" "branch:crew/wa-worker/wa-sal06" "$OUT"
guard wa-sal08 "$(bj wa-sal08 '')";              has "no evidence → still refused (the veto of before)" "branch:crew/wa-worker/wa-sal08" "$OUT"

echo "── S4. the writer and the reader name the same keys (drift guard) ──"
GUARD_SRC="${GUARD_UNDER_TEST:-$SELF_DIR/../../../scripts/inflight-reclaim-guard.py}"
if [ -r "$GUARD_SRC" ]; then
  grep -F 'pilot.salvage_sha={' "$GUARD_SRC" >/dev/null && ok "inflight-reclaim-guard.py writes pilot.salvage_sha, the key _beadid_branch_signal reads" || bad "the guard no longer writes pilot.salvage_sha — the Pilot would never see the proof"
  grep -F 'pilot.salvage_ref={' "$GUARD_SRC" >/dev/null && ok "…and pilot.salvage_ref (where the work is saved)" || bad "the guard no longer writes pilot.salvage_ref"
else bad "guard not readable at $GUARD_SRC — the writer of pilot.salvage_sha cannot be checked"; fi
grep -F 'pilot.salvage_sha' "$PD" >/dev/null && ok "the dispatcher under test reads pilot.salvage_sha" || bad "the dispatcher under test never reads pilot.salvage_sha"

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"
[ "$FAIL" -eq 0 ]
