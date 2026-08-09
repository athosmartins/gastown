#!/bin/bash
# file-bead-from-mail.selftest.sh — hermetic test for file-bead-from-mail.sh
# (ga-3rqwa acceptance criteria).
#
# Hermetic: stubs `bd` with a fake executable (prepended to PATH) that serves
# canned `bd show` fixtures and logs `bd create`'s full argv (as JSON) instead
# of executing it. No real bd/Dolt is ever contacted, nothing is ever created.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/file-bead-from-mail.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/bin" "$WORKDIR/fixtures"

jq -nc '[{id:"test-mail-good", issue_type:"message", sender:"oracle-wa", assignee:"mila-wa", created_at:"2026-08-09T15:18:08Z"}]' \
  > "$WORKDIR/fixtures/test-mail-good.json"
jq -nc '[{id:"test-mail-nosender", issue_type:"message", sender:null, assignee:null, created_at:"2026-08-09T15:18:08Z"}]' \
  > "$WORKDIR/fixtures/test-mail-nosender.json"
jq -nc '[{id:"test-not-mail", issue_type:"task", sender:null, assignee:null, created_at:"2026-08-09T15:18:08Z"}]' \
  > "$WORKDIR/fixtures/test-not-mail.json"

cat > "$WORKDIR/bin/bd" <<'STUB'
#!/bin/bash
case "$1" in
  show)
    id="$2"
    if [ "$id" = "test-mail-typo" ]; then
      # Simulates bd's real, confirmed-live fuzzy-match behavior: an id
      # that doesn't exactly exist silently resolves to a DIFFERENT real
      # bead (here: test-mail-good's content, under the WRONG requested id).
      cat "$FIXTURE_DIR/test-mail-good.json"
      exit 0
    fi
    f="$FIXTURE_DIR/$id.json"
    if [ -f "$f" ]; then
      cat "$f"
    else
      echo '{"error":"no issue found"}' >&2
      exit 1
    fi
    ;;
  create)
    shift
    jq -nc '$ARGS.positional' --args -- "$@" > "$CALLLOG_FILE"
    ;;
  *)
    echo "unexpected bd call: $*" >&2
    exit 1
    ;;
esac
exit 0
STUB
chmod +x "$WORKDIR/bin/bd"

run_script() {
  CALLLOG="$WORKDIR/create-call.json"
  rm -f "$CALLLOG"
  PATH="$WORKDIR/bin:$PATH" FIXTURE_DIR="$WORKDIR/fixtures" CALLLOG_FILE="$CALLLOG" \
    bash "$SCRIPT" "$@" >"$WORKDIR/stdout.log" 2>"$WORKDIR/stderr.log"
  echo $?
}

# metadata value passed to bd create is always the argv element right after
# the literal "--metadata" flag.
metadata_of() {
  jq -r '. as $a | ($a | index("--metadata")) as $i | $a[$i+1]' "$WORKDIR/create-call.json"
}

echo "=== file-bead-from-mail.selftest.sh ==="

# ── positive case: full provenance copied forward ─────────────────────────
RC=$(run_script --mail-id test-mail-good "My Title" --description "desc" --type bug)
[ "$RC" -eq 0 ] && ok "positive case exits 0" || bad "positive case exited $RC — $(cat "$WORKDIR/stderr.log")"
META=$(metadata_of)
[ "$(echo "$META" | jq -r '."mail.source_id"')" = "test-mail-good" ] && ok "mail.source_id set" || bad "mail.source_id missing/wrong: $META"
[ "$(echo "$META" | jq -r '."mail.author"')" = "oracle-wa" ] && ok "mail.author set from sender" || bad "mail.author missing/wrong: $META"
[ "$(echo "$META" | jq -r '."mail.recipient"')" = "mila-wa" ] && ok "mail.recipient set from assignee" || bad "mail.recipient missing/wrong: $META"
[ "$(echo "$META" | jq -r '."mail.sent_at"')" = "2026-08-09T15:18:08Z" ] && ok "mail.sent_at set from created_at" || bad "mail.sent_at missing/wrong: $META"
ARGV=$(cat "$WORKDIR/create-call.json")
echo "$ARGV" | jq -e 'index("My Title") != null' >/dev/null && ok "title forwarded to bd create" || bad "title not forwarded: $ARGV"
echo "$ARGV" | jq -e 'index("--type") != null' >/dev/null && ok "extra flags (--type) forwarded to bd create" || bad "extra flags not forwarded: $ARGV"

# ── MANDATORY negative test (ga-3rqwa acceptance criterion): no --mail-id
# ── means no mail.* key is ever added, no author is ever invented ─────────
echo "── mandatory negative test: no mail source given ──"
RC=$(run_script "Plain bead, no mail origin" --type task)
[ "$RC" -eq 0 ] && ok "no-mail-id case exits 0" || bad "no-mail-id case exited $RC"
META=$(metadata_of)
[ "$META" = "{}" ] && ok "no-mail-id case: metadata is exactly {} — no key invented" || bad "no-mail-id case: metadata is '$META', expected '{}' — AN AUTHOR OR SOURCE KEY WAS INVENTED"

# ── missing sender: absent field, not a guessed/empty one ─────────────────
echo "── mail with no recorded sender ──"
RC=$(run_script --mail-id test-mail-nosender "Title")
[ "$RC" -eq 0 ] && ok "no-sender mail case exits 0" || bad "no-sender mail case exited $RC"
META=$(metadata_of)
echo "$META" | jq -e 'has("mail.author") | not' >/dev/null \
  && ok "mail.author key is ABSENT (not empty string) when sender is unknown" \
  || bad "mail.author key present when it should be absent: $META"
echo "$META" | jq -e 'has("mail.recipient") | not' >/dev/null \
  && ok "mail.recipient key is ABSENT when assignee is unknown" \
  || bad "mail.recipient key present when it should be absent: $META"
echo "$META" | jq -e '."mail.source_id" == "test-mail-nosender"' >/dev/null \
  && ok "mail.source_id still set even when sender is unknown (the mail id itself is always known)" \
  || bad "mail.source_id missing: $META"
grep -qi "no recorded sender" "$WORKDIR/stderr.log" && ok "stderr warns about the missing sender" || bad "no stderr warning about missing sender"

# ── zero extra args: must not crash on bash <4.4's "unbound variable" for an
# ── empty array expansion under set -u (this box's /usr/bin/env bash is 3.2) ─
echo "── no positional args at all (only --mail-id) ──"
RC=$(run_script --mail-id test-mail-good)
[ "$RC" -eq 0 ] && ok "zero extra args does not crash (bash 3.2 empty-array-under-set-u safe)" \
  || bad "zero extra args exited $RC — $(cat "$WORKDIR/stderr.log")"
META=$(metadata_of)
[ "$(echo "$META" | jq -r '."mail.author"')" = "oracle-wa" ] && ok "zero extra args still carries mail.author" || bad "zero extra args: metadata wrong: $META"

# ── refuses a fuzzy-matched id (bd's real, confirmed-live behavior: an id
# ── that doesn't exactly exist silently resolves to a DIFFERENT bead
# ── instead of erroring) — this is the highest-severity case: silently
# ── attributing authorship to the WRONG real person is worse than the
# ── original no-attribution bug ─────────────────────────────────────────
echo "── --mail-id is a typo that fuzzy-matches a DIFFERENT real bead ──"
rm -f "$WORKDIR/create-call.json"
RC=$(run_script --mail-id test-mail-typo "Title")
[ "$RC" -ne 0 ] && ok "fuzzy-matched id is refused (nonzero exit)" || bad "fuzzy-matched id was NOT refused — WRONG AUTHOR could be attributed"
[ -f "$WORKDIR/create-call.json" ] && bad "bd create was called despite the fuzzy-match mismatch" || ok "bd create was never called for a fuzzy-matched id"
grep -qi "fuzzy-matched" "$WORKDIR/stderr.log" && ok "stderr explains the fuzzy-match refusal" || bad "no stderr explanation for the fuzzy-match refusal"

# ── refuses a non-mail bead as a mail source ───────────────────────────────
echo "── --mail-id points at a non-message bead ──"
RC=$(run_script --mail-id test-not-mail "Title")
[ "$RC" -ne 0 ] && ok "non-mail --mail-id target is refused (nonzero exit)" || bad "non-mail --mail-id target was NOT refused"
[ -s "$WORKDIR/create-call.json" ] 2>/dev/null && bad "bd create was called despite the refusal" || ok "bd create was never called"

# ── aborts rather than filing blind when the mail id can't be read
# ── (e.g. already purged) ──────────────────────────────────────────────────
echo "── --mail-id points at a nonexistent bead ──"
rm -f "$WORKDIR/create-call.json"
RC=$(run_script --mail-id does-not-exist "Title")
[ "$RC" -ne 0 ] && ok "unreadable mail id is refused (nonzero exit)" || bad "unreadable mail id was NOT refused"
[ -f "$WORKDIR/create-call.json" ] && bad "bd create was called despite the unreadable mail id" || ok "bd create was never called for an unreadable mail id"

# ── user-supplied --metadata keys survive the merge ────────────────────────
echo "── user-supplied --metadata is preserved alongside mail.* keys ──"
RC=$(run_script --mail-id test-mail-good --metadata '{"foo":"bar"}' "Title")
[ "$RC" -eq 0 ] && ok "user-metadata case exits 0" || bad "user-metadata case exited $RC"
META=$(metadata_of)
[ "$(echo "$META" | jq -r '.foo')" = "bar" ] && ok "user's own metadata key survives the merge" || bad "user's own metadata key lost: $META"
[ "$(echo "$META" | jq -r '."mail.author"')" = "oracle-wa" ] && ok "mail.* keys still added alongside user metadata" || bad "mail.* keys lost when user metadata was present: $META"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
