#!/usr/bin/env bash
# story-delivery.selftest.sh — prove the ga-266z8 task-reconciler merge-verification
# guard in isolation, with NO live Dolt/gc/launchd and NO network.
#
# Sources story-delivery.sh in lib-only mode for the REAL functions (one source
# of truth, no copy-drift), unit-tests the pure verdict decision across every
# branch, then runs a real-git integration test for the content-check helper
# (commit-subject scan with conventional-commit-scope discrimination). Exit 0
# iff every assertion holds.
#
# Covers the ga-266z8 DoD:
#   1. A non-story bead with gate:passed but NO commit scoped to it in
#      origin/<default_branch> is NOT closed by the sweep (verdict = keep).
#   2. A bead carrying BOTH gate:passed and gate:needs-fix/gate:failed is NOT
#      closed, regardless of merge state (contradiction guard wins).
#   3. A genuinely-merged bead (a real commit scoped to its id exists in the
#      ref's history) still closes normally (no regression).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/story-delivery.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
rc0() { if "$@" >/dev/null 2>&1; then ok "rc0: $*"; else bad "expected rc0: $*"; fi; }
rc1() { if "$@" >/dev/null 2>&1; then bad "expected non-zero: $*"; else ok "rc!=0: $*"; fi; }

# ── 0. bash -n clean ─────────────────────────────────────────────────────────
echo "── 0. bash -n (syntax) ──"
if bash -n "$SCRIPT" 2>/tmp/story-delivery-selftest-syntax.$$; then
  ok "bash -n $SCRIPT"
else
  bad "bash -n $SCRIPT: $(cat /tmp/story-delivery-selftest-syntax.$$)"
fi
rm -f /tmp/story-delivery-selftest-syntax.$$

# ── Load the REAL functions (lib-only = no live sweep) ──────────────────────
STORY_DELIVERY_LIB_ONLY=1 source "$SCRIPT" \
  || { echo "FATAL: could not source story-delivery.sh in lib-only mode"; exit 1; }
for fn in rig_gitdir git_in token_bounded subject_impl_scopes_bead \
          scan_commit_subject_for_bead task_reconciler_verdict \
          extract_gate_merge_info story_merge_verdict; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by story-delivery.sh"; exit 1; }
done

# ── 1. task_reconciler_verdict — pure decision, every branch ────────────────
# Args: <is_contradicted> <is_merge_verified>
echo "── 1. task_reconciler_verdict (pure verdict) ──"
eq "DoD#1: unverified, not contradicted → keep (never trust label alone)" \
   "$(task_reconciler_verdict 0 0)" "keep:merge-not-verified"
eq "DoD#2: contradicted, unverified → keep (contradiction guard)" \
   "$(task_reconciler_verdict 1 0)" "keep:contradicted-by-gate-failed-or-needs-fix"
eq "DoD#2: contradicted EVEN IF merge-verified → keep (contradiction wins)" \
   "$(task_reconciler_verdict 1 1)" "keep:contradicted-by-gate-failed-or-needs-fix"
eq "DoD#3: verified, not contradicted → close (no regression on real merges)" \
   "$(task_reconciler_verdict 0 1)" "close:commit-in-origin-main"
eq "verb-only check: unverified is keep"     "$(task_reconciler_verdict 0 0 | cut -d: -f1)" "keep"
eq "verb-only check: contradicted is keep"   "$(task_reconciler_verdict 1 0 | cut -d: -f1)" "keep"
eq "verb-only check: verified is close"      "$(task_reconciler_verdict 0 1 | cut -d: -f1)" "close"

# ── 2. rig_gitdir — container vs self-repo detection ────────────────────────
echo "── 2. rig_gitdir (container vs self-repo) ──"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

SELFREPO="$TMPROOT/self-repo"
mkdir -p "$SELFREPO"
PAIR=$(rig_gitdir "$SELFREPO")
eq "self-repo gdir"      "${PAIR%$'\t'*}" "$SELFREPO"
eq "self-repo container" "${PAIR#*$'\t'}" "0"

CONTAINERREPO="$TMPROOT/container-repo"
mkdir -p "$CONTAINERREPO/.repo.git"
PAIR=$(rig_gitdir "$CONTAINERREPO")
eq "container gdir"      "${PAIR%$'\t'*}" "$CONTAINERREPO/.repo.git"
eq "container flag"      "${PAIR#*$'\t'}" "1"

# ── 3. scan_commit_subject_for_bead — real-git integration (content check) ──
# Build a throwaway git repo with a real merge history so the DoD's "branch is
# an ancestor" and "no commit landed" scenarios are proven against real git,
# not simulated booleans.
echo "── 3. scan_commit_subject_for_bead (real-git content check) ──"
REPO="$TMPROOT/repo.git"
git init -q --bare "$REPO"
WORK="$TMPROOT/work"
git clone -q "$REPO" "$WORK"
git -C "$WORK" config user.email "test@example.com"
git -C "$WORK" config user.name "Test"
git -C "$WORK" checkout -q -b main
echo "seed" > "$WORK/seed.txt"
git -C "$WORK" add seed.txt
git -C "$WORK" commit -q -m "chore: seed repo"

# DoD#3 fixture: a genuinely-merged bead — a commit whose SUBJECT SCOPE is the
# bead id lands on main.
echo "fix1" > "$WORK/fix1.txt"
git -C "$WORK" add fix1.txt
git -C "$WORK" commit -q -m "fix(ga-266z8-merged): implements the fix for ga-266z8-merged"

# DoD#1 fixture (negative control): a commit exists that MENTIONS a different
# bead id only as trailing context, never as the implementing scope — must NOT
# count as merged (this is exactly the wa-iy9s8 false-positive class the
# subject-scope discriminator prevents).
echo "fix2" > "$WORK/fix2.txt"
git -C "$WORK" add fix2.txt
git -C "$WORK" commit -q -m "fix(unrelated): tweak unrelated area (ga-266z8-context-only)"

git -C "$WORK" push -q origin main

BARE_PAIR=$(rig_gitdir "$REPO")
BARE_GDIR="${BARE_PAIR%$'\t'*}"
BARE_CONTAINER="${BARE_PAIR#*$'\t'}"

rc0 scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-merged"
rc1 scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-context-only"
rc1 scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-never-landed"
rc1 scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "no-such-ref" "ga-266z8-merged"

FOUND_SHA=$(scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-merged" 2>/dev/null || true)
if [ -n "$FOUND_SHA" ]; then ok "scan prints a sha for the merged bead ($FOUND_SHA)"; else bad "scan printed no sha for the merged bead"; fi

# ── 4. End-to-end: verdict wiring matches the real content-check outcome ────
echo "── 4. End-to-end verdict wiring ──"
if scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-merged" >/dev/null 2>&1; then
  MERGED_VERIFIED=1
else
  MERGED_VERIFIED=0
fi
eq "DoD#3 e2e: real merged bead → close verdict" \
   "$(task_reconciler_verdict 0 "$MERGED_VERIFIED")" "close:commit-in-origin-main"

if scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-never-landed" >/dev/null 2>&1; then
  UNMERGED_VERIFIED=1
else
  UNMERGED_VERIFIED=0
fi
eq "DoD#1 e2e: never-landed bead → keep verdict (not closed)" \
   "$(task_reconciler_verdict 0 "$UNMERGED_VERIFIED")" "keep:merge-not-verified"

# A bead that DID land (by content) but ALSO carries gate:needs-fix must still
# be kept — contradiction beats even real merge evidence (DoD#2, no regression
# vs DoD#3's independent proof that the content-check machinery itself works).
eq "DoD#2 e2e: merged bead but contradicted by gate:needs-fix → keep" \
   "$(task_reconciler_verdict 1 "$MERGED_VERIFIED")" "keep:contradicted-by-gate-failed-or-needs-fix"

# ── 5. extract_gate_merge_info — gate-comment parsing (ga-mmdm2) ────────────
# gate:passed is a LABEL; the sha it actually merged lives only in the gate
# dispatcher's own comment text ("merged to <rig>/<branch> (sha=<sha>)",
# quality-gate-dispatcher.sh's PASSED comment). This is the STORY-path analog
# of scan_commit_subject_for_bead above — content, not label, decides.
echo "── 5. extract_gate_merge_info (gate-comment parsing) ──"
REAL_COMMENT="Quality gate PASSED. Branch fix/ga-mmdm2-x merged to gascity/main (sha=b97b13384330605cc2dbc81abbd2d518f7e380ae) via autonomous dispatcher (gate_run=ga-wisp-bt5lw8)."
INFO=$(extract_gate_merge_info "$REAL_COMMENT")
eq "real gate comment: rig/branch" "${INFO%%$'\t'*}" "gascity/main"
eq "real gate comment: sha"        "${INFO#*$'\t'}"  "b97b13384330605cc2dbc81abbd2d518f7e380ae"

# Multiple gate cycles (fix-attempt retries) accumulate comments — only the
# MOST RECENT merge is authoritative; must pick the LAST match, not the first.
MULTI_COMMENT="Quality gate PASSED. Branch fix/ga-x-attempt1 merged to gascity/main (sha=1111111111111111111111111111111111111111) via autonomous dispatcher (gate_run=ga-wisp-aaa).
Quality gate PASSED. Branch fix/ga-x-attempt2 merged to gascity/main (sha=2222222222222222222222222222222222222222) via autonomous dispatcher (gate_run=ga-wisp-bbb)."
INFO=$(extract_gate_merge_info "$MULTI_COMMENT")
eq "multiple merge comments: picks the LAST (most recent) sha" "${INFO#*$'\t'}" "2222222222222222222222222222222222222222"

# No merge comment at all (never merged, or gate:passed set some other way) —
# ga-mmdm2 control #2: this is NOT skip-the-check, it is evidence of no merge.
rc1 extract_gate_merge_info "Quality gate PASSED. Branch fix/x could not determine rig automatically."
rc1 extract_gate_merge_info ""

# ── ga-fic5d: A LINHA QUEBRADA — o caso que deixou o bug passar por aqui ──────
# Todos os fixtures acima são de UMA LINHA SÓ, e por isso passavam mesmo com o
# defeito presente. Em produção o comentário do gate é longo, e `bd comments`
# (o canal que story-delivery usava para lê-lo) quebra o texto em ~80 colunas —
# a quebra caía exatamente entre "merged to" e "<rig>/<branch> (sha=…)", então
# o regex NUNCA casava e toda entrega travava com "no gate merge comment found".
#
# Este teste fixa as DUAS metades do contrato:
#   (a) com a quebra, extract_gate_merge_info NÃO deve inventar um resultado —
#       falha honesta é correta, a função só vê o texto que recebe;
#   (b) e é por isso que o CHAMADOR tem de ler por --json (não formatado). O
#       guard de fonte abaixo prova que ele lê.
BROKEN_COMMENT="Quality gate PASSED. Branch crew/oracle/wa-8ok7u merged to
whatsapp_automation/main (sha=fc40e581f79635ad5f0e33c76a51a7438ade7743) via autonomous gate."
rc1 extract_gate_merge_info "$BROKEN_COMMENT"

# A mesma linha ÍNTEGRA (como o --json entrega) tem de casar — senão o conserto
# não serviu de nada.
WHOLE_COMMENT="Quality gate PASSED. Branch crew/oracle/wa-8ok7u merged to whatsapp_automation/main (sha=fc40e581f79635ad5f0e33c76a51a7438ade7743) via autonomous gate."
INFO=$(extract_gate_merge_info "$WHOLE_COMMENT")
eq "linha íntegra (via --json): rig/branch" "${INFO%%$'\t'*}" "whatsapp_automation/main"
eq "linha íntegra (via --json): sha"        "${INFO#*$'\t'}"  "fc40e581f79635ad5f0e33c76a51a7438ade7743"

# DRIFT-GUARD: o chamador precisa continuar lendo por um canal NÃO formatado.
# Se alguém voltar a alimentar extract_gate_merge_info com `bd comments`, o bug
# ressurge inteiro e silenciosamente — nenhum teste de unidade acima o pegaria.
if grep -qE 'STORY_COMMENTS_TEXT=\$\(bd -C "\$STORY_STORE" show .* --json --include-comments' "$SCRIPT" 2>/dev/null; then
  ok "merge-verification lê comentários por --json (não pelo formatado)"
else
  bad "merge-verification NÃO lê por --json — o bug ga-fic5d ressuscitou (bd comments quebra a linha)"
fi

# SEGUNDO sítio, achado varrendo o idioma e não o sintoma: a derivação do RIG
# ("merged to <rig>/main") lia pelo mesmo canal formatado. Com a quebra caindo no
# "merged to", RIG saía vazio e a entrega falhava ANTES da verificação de merge —
# um modo de falha diferente, mesma causa. Guardar os dois separadamente: consertar
# um e deixar o outro foi exatamente como este bug sobreviveu ao primeiro passe.
if grep -qE '_SD_COMMENTS=\$\(bd -C "\$STORY_STORE" show .* --json --include-comments' "$SCRIPT" 2>/dev/null; then
  ok "derivação do RIG lê comentários por --json (não pelo formatado)"
else
  bad "derivação do RIG NÃO lê por --json — segundo sítio do ga-fic5d regrediu"
fi

# E os fallbacks para o canal formatado DEVEM continuar existindo: se o JSON
# render vazio (bd antigo, jq ausente, Dolt fora), o pior caso tem de ser o bug
# conhecido — nunca um resultado vazio silencioso por um caminho novo.
if [ "$(grep -c 'comments "\$STORY_ID" 2>/dev/null || echo ""' "$SCRIPT" 2>/dev/null)" -ge 2 ]; then
  ok "ambos os sítios mantêm fallback explícito para o canal formatado"
else
  bad "fallback para o canal formatado sumiu — falha do JSON viraria vazio silencioso"
fi

# A "merged to X/Y" mention that ISN'T immediately followed by "(sha=...)"
# must not false-positive — e.g. a comment discussing gate-sha-failed (the sha
# that FAILED, not what merged) in prose near an unrelated "merged to" phrase.
rc1 extract_gate_merge_info "The bug ga-sb11i.2 has gate-sha-failed:8b612cf5eb42875c8080b65778d98c6ac64c5180 on a branch that never merged to gascity/main; sha=8b612cf5e is what FAILED, not what merged."

# ── 6. story_merge_verdict — real-git ancestor check (ga-mmdm2) ─────────────
echo "── 6. story_merge_verdict (real-git ancestor check) ──"
# Extend the section-3 fixture with a side branch: a real commit that lands in
# the SAME repo but is never merged to main — the exact ga-sb11i.2 shape
# (commit exists, gate said "merged", but main never received it).
git -C "$WORK" checkout -q -b side-branch main
echo "side" > "$WORK/side.txt"
git -C "$WORK" add side.txt
git -C "$WORK" commit -q -m "chore: side commit never merged to main"
SIDE_SHA=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" push -q origin side-branch
git -C "$WORK" checkout -q main

eq "verdict: sha IS ancestor of main → verified" \
   "$(story_merge_verdict "$BARE_GDIR" "$BARE_CONTAINER" "main" "$FOUND_SHA")" "verified"
rc0 story_merge_verdict "$BARE_GDIR" "$BARE_CONTAINER" "main" "$FOUND_SHA"

eq "verdict: sha exists but NOT ancestor of main (side-branch only) → not-ancestor" \
   "$(story_merge_verdict "$BARE_GDIR" "$BARE_CONTAINER" "main" "$SIDE_SHA")" "not-ancestor"
rc1 story_merge_verdict "$BARE_GDIR" "$BARE_CONTAINER" "main" "$SIDE_SHA"

eq "verdict: sha never existed → unresolvable (fail-closed, not false-pass)" \
   "$(story_merge_verdict "$BARE_GDIR" "$BARE_CONTAINER" "main" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")" "unresolvable"
rc1 story_merge_verdict "$BARE_GDIR" "$BARE_CONTAINER" "main" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

eq "verdict: branch_ref does not resolve → unresolvable" \
   "$(story_merge_verdict "$BARE_GDIR" "$BARE_CONTAINER" "no-such-ref" "$FOUND_SHA")" "unresolvable"
rc1 story_merge_verdict "$BARE_GDIR" "$BARE_CONTAINER" "no-such-ref" "$FOUND_SHA"

echo ""
echo "═══════════════════════════════════════"
echo "PASS=$PASS FAIL=$FAIL"
echo "═══════════════════════════════════════"
[ "$FAIL" -eq 0 ]
