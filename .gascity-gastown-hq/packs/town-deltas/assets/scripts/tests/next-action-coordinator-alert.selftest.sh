#!/usr/bin/env bash
# next-action-coordinator-alert.selftest.sh (ga-njj5zk)
#
# Runs the REAL next-action-coordinator-alert.sh (not a reimplementation)
# against two disposable fake "stores" with fixture bd list/show JSON, and
# bd/gc/notify swapped for fakes via the script's own BD_BIN/GC_BIN/
# NOTIFY_BIN env-var seams. Exit 0 iff every assertion holds.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../next-action-coordinator-alert.sh"
FAKE_BD="$SELF_DIR/next-action-coordinator-alert.fake-bd"
FAKE_GC="$SELF_DIR/next-action-coordinator-alert.fake-gc"
FAKE_NOTIFY="$SELF_DIR/next-action-coordinator-alert.fake-notify"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STORE1="$WORK/store1"
STORE2="$WORK/store2"
NOTIFY_LOG="$WORK/notify.log"
BD_LOG="$WORK/bd.log"
MAIL_LOG="$WORK/mail.log"
MAIL_BODY_LOG="$WORK/mail-body.log"
: > "$NOTIFY_LOG"; : > "$BD_LOG"; : > "$MAIL_LOG"; : > "$MAIL_BODY_LOG"

echo "── 1. syntax ──"
if bash -n "$SCRIPT"; then ok "next-action-coordinator-alert.sh passes bash -n"; else bad "bash -n FAILED"; exit 1; fi

echo "── setup: two fake stores with fixture bd list/show JSON ──"
mkdir -p "$STORE1" "$STORE2"

# store1 (one combined list, matching the real script's single
# --status open,in_progress call): ga-alertx (next-action:mayor, HAS a
# Pergunta comment), ga-alerty (next-action:deacon, comments exist but NONE
# start with "Pergunta:" -- exercises the fallback string, not the "show
# failed entirely" path), ga-noalrt (next-action:athos — must NOT alert,
# wrong target entirely), ga-otherz (no next-action label at all — must
# NOT alert).
cat > "$STORE1/list-open,in_progress.json" <<'EOF'
[
  {"id": "ga-alertx", "labels": ["ctx:ready", "next-action:mayor"]},
  {"id": "ga-alerty", "labels": ["ctx:ready", "next-action:deacon"]},
  {"id": "ga-noalrt", "labels": ["ctx:ready", "next-action:athos"]},
  {"id": "ga-otherz", "labels": ["area:infra"]}
]
EOF
cat > "$STORE1/show-ga-alertx.json" <<'EOF'
[{"id": "ga-alertx", "comments": [
  {"text": "Progresso: investigando.", "created_at": "2026-08-21T10:00:00Z"},
  {"text": "Pergunta: sigo com o plano A ou paro aqui pro Mayor decidir?", "created_at": "2026-08-21T10:05:00Z"}
]}]
EOF
cat > "$STORE1/show-ga-alerty.json" <<'EOF'
[{"id": "ga-alerty", "comments": [
  {"text": "Progresso: só um comentário de status, nenhuma pergunta aqui.", "created_at": "2026-08-21T11:00:00Z"}
]}]
EOF
# Deliberately NO show-ga-noalrt.json / show-ga-otherz.json: neither bead
# should ever reach latest_pergunta() at all, since both are filtered out
# before that call -- if the script ever called bd show for them, fake-bd's
# missing-fixture path (exit 1) would surface as a harmless empty question,
# masking a real over-broad-matching bug. Section 4 below asserts BD_LOG
# only ever names the 3 real targets, which is what actually catches this.

# store2: ga-alertw (next-action:mayor). Its show-*.json is deliberately
# ABSENT -- exercises "bd show failed entirely" (fake-bd exits 1, not just
# "no Pergunta comment"), proving latest_pergunta's own failure path
# degrades to the same visible fallback string rather than crashing the
# whole sweep under set -e.
cat > "$STORE2/list-open,in_progress.json" <<'EOF'
[
  {"id": "ga-alertw", "labels": ["next-action:mayor"]}
]
EOF

run_guard() {
    env -i \
        PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" \
        HOME="$HOME" \
        GC_CITY_PATH="$STORE1" \
        NEXT_ACTION_ALERT_STORES="$STORE1 $STORE2" \
        NEXT_ACTION_ALERT_SEEN_FILE="$WORK/seen.json" \
        NEXT_ACTION_ALERT_COOLDOWN_S="${TEST_COOLDOWN_S:-14400}" \
        GC_PACK_STATE_DIR="$WORK/state" \
        BD_BIN="$FAKE_BD" \
        GC_BIN="$FAKE_GC" \
        NOTIFY_BIN="$FAKE_NOTIFY" \
        NOTIFY_LOG="$NOTIFY_LOG" \
        BD_LOG="$BD_LOG" \
        MAIL_LOG="$MAIL_LOG" \
        MAIL_BODY_LOG="$MAIL_BODY_LOG" \
        bash "$SCRIPT"
}

echo "── 2. functional: first run alerts exactly the 3 real next-action:mayor|deacon beads across both stores ──"
run_guard >/dev/null

MAIL_COUNT1=$(wc -l < "$MAIL_LOG" | tr -d ' ')
if [ "$MAIL_COUNT1" = "3" ]; then ok "exactly 3 mail sends (ga-alertx, ga-alerty, ga-alertw)"; else bad "expected 3 mail sends, got $MAIL_COUNT1"; fi

if grep -q "^MAIL mayor|||Decisão pendente: ga-alertx" "$MAIL_LOG"; then ok "ga-alertx alerted to mayor"; else bad "ga-alertx NOT alerted to mayor"; fi
if grep -q "^MAIL deacon|||Decisão pendente: ga-alerty" "$MAIL_LOG"; then ok "ga-alerty alerted to deacon"; else bad "ga-alerty NOT alerted to deacon"; fi
if grep -q "^MAIL mayor|||Decisão pendente: ga-alertw" "$MAIL_LOG"; then ok "ga-alertw (store2) alerted to mayor -- multi-store loop works"; else bad "ga-alertw NOT alerted -- multi-store loop broken"; fi
if grep -q "ga-noalrt" "$MAIL_LOG"; then bad "ga-noalrt (next-action:athos) was alerted -- wrong-target leak"; else ok "ga-noalrt (next-action:athos) correctly never alerted"; fi
if grep -q "ga-otherz" "$MAIL_LOG"; then bad "ga-otherz (no next-action label) was alerted"; else ok "ga-otherz (no next-action label) correctly never alerted"; fi

echo "── 3. functional: mail body carries the real Pergunta text when present, an explicit fallback when absent (never silence) ──"
if grep -q "sigo com o plano A ou paro aqui pro Mayor decidir" "$MAIL_BODY_LOG"; then ok "ga-alertx's mail body contains the actual Pergunta comment"; else bad "ga-alertx's real Pergunta text missing from mail body"; fi
FALLBACK_COUNT=$(grep -c "nenhum comentário 'Pergunta:' encontrado" "$MAIL_BODY_LOG" || true)
if [ "$FALLBACK_COUNT" = "2" ]; then ok "fallback string appears exactly twice (ga-alerty: no Pergunta comment; ga-alertw: bd show fails entirely)"; else bad "expected fallback string exactly twice, got $FALLBACK_COUNT"; fi

echo "── 4. functional: notify fires once per alerted bead, bd comment posted only to the 3 real targets ──"
NOTIFY_COUNT1=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
if [ "$NOTIFY_COUNT1" = "3" ]; then ok "exactly 3 notify calls"; else bad "expected 3 notify calls, got $NOTIFY_COUNT1"; fi
BD_COUNT1=$(wc -l < "$BD_LOG" | tr -d ' ')
if [ "$BD_COUNT1" = "3" ]; then ok "exactly 3 bd comment calls"; else bad "expected 3 bd comment calls, got $BD_COUNT1"; fi
if grep -q "ga-noalrt\|ga-otherz" "$BD_LOG"; then bad "bd comment posted to a bead that should never have been touched"; else ok "no bd comment posted to ga-noalrt/ga-otherz"; fi

echo "── 5. functional: dedup -- immediate re-run within the cooldown window adds ZERO new mail/notify/bd-comment ──"
run_guard >/dev/null
MAIL_COUNT2=$(wc -l < "$MAIL_LOG" | tr -d ' ')
NOTIFY_COUNT2=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
BD_COUNT2=$(wc -l < "$BD_LOG" | tr -d ' ')
if [ "$MAIL_COUNT2" = "$MAIL_COUNT1" ]; then ok "second run within cooldown added zero new mail ($MAIL_COUNT2 total)"; else bad "second run re-mailed (got $MAIL_COUNT2, expected $MAIL_COUNT1) -- dedup ledger not honored"; fi
if [ "$NOTIFY_COUNT2" = "$NOTIFY_COUNT1" ]; then ok "second run within cooldown added zero new notifies"; else bad "second run re-notified"; fi
if [ "$BD_COUNT2" = "$BD_COUNT1" ]; then ok "second run within cooldown added zero new bd comments"; else bad "second run added new bd comments -- will spam the bead once per order tick"; fi

echo "── 6. functional: a run past the cooldown window DOES re-alert all 3 (re-fire cadence, not permanent silence) ──"
TEST_COOLDOWN_S=0 run_guard >/dev/null
MAIL_COUNT3=$(wc -l < "$MAIL_LOG" | tr -d ' ')
if [ "$MAIL_COUNT3" -gt "$MAIL_COUNT2" ]; then ok "re-alerted after cooldown elapsed ($MAIL_COUNT2 -> $MAIL_COUNT3)"; else bad "did NOT re-alert after cooldown elapsed (stuck at $MAIL_COUNT3) -- a bead nobody ever answers would go silent forever"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
