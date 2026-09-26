#!/usr/bin/env bash
# mol-digest-generate-send.selftest.sh — regression harness for ga-ghxr1h in
# packs/town-deltas/formulas/mol-digest-generate.toml, step generate-and-send,
# sub-step 2 ("Send to mayor, then verify the send immediately", ga-8h185).
#
# Defect: the send was verified with `gc events ... | tail -5`. The pipe returns
# tail's exit status, so a FAILED `gc events` (city API timeout under load,
# non-zero exit, nothing on stdout) read the same as "the mail was not sent" —
# and the recipe answered by SENDING THE DIGEST AGAIN. A mail cannot be unsent.
# The check has three outcomes, not two: sent / not-sent / unknown. Only a query
# that ran to completion and found no row for THIS digest is "not-sent"; a query
# that failed, or whose output cannot be read, is "unknown" and must never
# trigger a second send.
#
# This formula has no exec script: an agent reads each step's description and
# types the shell it finds there. So the unit under test is the text the agent
# is DELIVERED — the TOML parsed by tomllib, escapes already consumed — never
# the raw source (a backslash in a TOML basic string is an escape; testing the
# source is how a recipe ships that reads fine and is invalid shell). The
# delivered bash is executed against a stubbed `gc`, under bash AND zsh (the
# agent's interactive shell here is zsh; `echo` there rewrites the backslash
# escapes that mail bodies carry in event JSON, which is why the recipe must
# not echo event rows).
#
# The recipe must print `MAIL_CHECK=<sent|not-sent|unknown>` — the machine
# readable verdict step 4's close_reason is written from.
#
# FORMULA=<path> overrides the file under test (used to prove this harness
# fails against the pre-fix formula).  Exit 0 iff every assertion holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMULA="${FORMULA:-$HERE/../formulas/mol-digest-generate.toml}"

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

echo "== mol-digest-generate-send.selftest (ga-ghxr1h) =="
[ -f "$FORMULA" ] || { echo "FATAL: $FORMULA not found"; exit 1; }
command -v python3 >/dev/null && command -v jq >/dev/null || { echo "FATAL: python3 and jq required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- extraction of the DELIVERED text of sub-step 2 ---------------------------
python3 - "$FORMULA" "$TMP/step2.md" "$TMP/recipe.sh" > "$TMP/extract.out" <<'PY' || { echo "FATAL: could not extract sub-step 2 from $FORMULA"; exit 1; }
import sys, tomllib
path, out_md, out_sh = sys.argv[1:4]
d = tomllib.load(open(path, "rb"))
text = next(s["description"] for s in d["steps"] if s["id"] == "generate-and-send")
lines = text.split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("**2. Send to mayor"))
end = next(i for i, l in enumerate(lines) if i > start and l.startswith("**3. Archive as bead"))
region = lines[start:end]
open(out_md, "w").write("\n".join(region) + "\n")
blocks, cur = [], None
for l in region:
    if l.startswith("```"):
        if cur is None: cur = []
        else: blocks.append(cur); cur = None
    elif cur is not None: cur.append(l)
open(out_sh, "w").write("\n".join("\n".join(b) for b in blocks) + "\n")
# a `gc events` whose output is piped onward reports the LAST command's status
for b in blocks:
    for l in b:
        if "gc events" in l and "|" in l.replace("||", ""):
            print("PIPED:" + l.strip())
print("BLOCKS:%d" % len(blocks))
PY

NBLOCKS="$(sed -n 's/^BLOCKS://p' "$TMP/extract.out")"
[ "${NBLOCKS:-0}" -ge 1 ] && ok "sub-step 2 delivers $NBLOCKS bash block(s)" || bad "sub-step 2 delivers no bash block"

# ---- static: the literal cause, and delivered-text validity ---------------------
if grep -q '^PIPED:' "$TMP/extract.out"; then
  bad "a delivered \`gc events\` line pipes its output onward (exit status masked): $(sed -n 's/^PIPED://p' "$TMP/extract.out" | head -1)"
else
  ok "no delivered \`gc events\` line pipes its output onward"
fi
bash -n "$TMP/recipe.sh" 2>"$TMP/syntax.err" && ok "delivered recipe parses as bash" || bad "delivered recipe is not valid bash: $(head -1 "$TMP/syntax.err")"
HAVE_ZSH=0; command -v zsh >/dev/null && HAVE_ZSH=1
if [ "$HAVE_ZSH" = 1 ]; then
  zsh -n "$TMP/recipe.sh" 2>"$TMP/syntax.err" && ok "delivered recipe parses as zsh" || bad "delivered recipe is not valid zsh: $(head -1 "$TMP/syntax.err")"
fi
for want in MAIL_CHECK unknown close_reason; do
  grep -q "$want" "$TMP/step2.md" && ok "delivered text mentions '$want'" || bad "delivered text never mentions '$want'"
done

# ---- stubs: a fake `gc` (mail send + events) and a no-op `sleep` ---------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gc" <<'STUB'
#!/usr/bin/env bash
# `gc mail send` logs subject+body. `gc events` behaves per EV_MODES: a comma
# list, one mode per call, the last one repeating.
D="${STUB_DIR:?}"
if [ "$1" = mail ] && [ "$2" = send ]; then
  subj=""; body=""
  while [ $# -gt 0 ]; do case "$1" in -s) subj="$2"; shift;; -m) body="$2"; shift;; esac; shift; done
  printf '%s\t%s\n' "$subj" "$body" >> "$D/sends.log"
  echo '{"ok":true,"id":"ga-wisp-stub"}'
  exit 0
fi
if [ "$1" = events ]; then
  n=$(( $(cat "$D/events.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/events.count"
  IFS=, read -r -a modes <<< "$EV_MODES"
  idx=$(( n - 1 )); [ "$idx" -ge "${#modes[@]}" ] && idx=$(( ${#modes[@]} - 1 ))
  mode="${modes[$idx]}"
  sends=$(wc -l < "$D/sends.log" | tr -d ' ')
  # A real mail.sent row: the mail body carries JSON escapes (newline, quote, >).
  row() { jq -nc --arg s "$1" --arg to "$2" '{seq:2427386,type:"mail.sent",ts:"2026-09-26T13:09:25.053912-03:00",actor:"human",subject:"ga-wisp-x",message:$to,payload:{message:{id:"ga-wisp-x",from:"human",to:$to,subject:$s,body:"first line\nsecond \"quoted\" > arrow",read:false}}}'; }
  case "$mode" in
    row)       row "Gas Town Digest: 2026-09-26" gastown.mayor ;;
    late)      [ "$sends" -ge 2 ] && row "Gas Town Digest: 2026-09-26" gastown.mayor ;;
    empty)     : ;;
    fail)      echo 'Get "http://127.0.0.1:8372/v0/city/gascity/events": context deadline exceeded' >&2; exit 1 ;;
    garbage)   echo "<html>502 bad gateway</html>" ;;
    othersubj) row "Gas Town Digest: 2026-09-25" gastown.mayor ;;
    otherto)   row "Gas Town Digest: 2026-09-26" gastown.deacon ;;
    *) echo "stub gc: bad mode $mode" >&2; exit 99 ;;
  esac
  exit 0
fi
echo "stub gc: unexpected call: $*" >&2; exit 98
STUB
chmod +x "$TMP/bin/gc"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sleep"; chmod +x "$TMP/bin/sleep"

# run <shell> <events-modes>: execute the delivered recipe once; set the result vars.
run() {
  local sh="$1" modes="$2" d
  d="$(mktemp -d "$TMP/run.XXXXXX")"; : > "$d/sends.log"
  OUT="$(cd "$d" && env PATH="$TMP/bin:$PATH" STUB_DIR="$d" EV_MODES="$modes" DATE=2026-09-26 \
        DIGEST='digest body: 3 filed, "quoted", a\nb' "$sh" "$TMP/recipe.sh" 2>"$d/stderr")"
  SENDS="$(wc -l < "$d/sends.log" | tr -d ' ')"
  EVCALLS="$(cat "$d/events.count" 2>/dev/null || echo 0)"
  VERDICT="$(printf '%s\n' "$OUT" | sed -n 's/^MAIL_CHECK=//p' | tail -1)"
  SUBJ_UNIQ="$(cut -f1 "$d/sends.log" | sort -u | wc -l | tr -d ' ')"
  BODY_UNIQ="$(cut -f2- "$d/sends.log" | sort -u | wc -l | tr -d ' ')"
  FIRST_SUBJ="$(head -1 "$d/sends.log" | cut -f1)"
}

# scenario <name> <modes> <want-sends> <want-verdict> <want-events-calls>
scenario() {
  local name="$1" modes="$2" wsends="$3" wverdict="$4" wev="$5" sh
  local shells="bash"; [ "$HAVE_ZSH" = 1 ] && shells="bash zsh"
  for sh in $shells; do
    run "$sh" "$modes"
    if [ "$SENDS" = "$wsends" ] && [ "$VERDICT" = "$wverdict" ] && [ "$EVCALLS" = "$wev" ]; then
      ok "[$sh] $name -> sends=$SENDS verdict=$VERDICT events-calls=$EVCALLS"
    else
      bad "[$sh] $name -> sends=$SENDS (want $wsends) verdict='${VERDICT}' (want $wverdict) events-calls=$EVCALLS (want $wev)"
    fi
  done
}

# -- the digest is sent once, and the check finds it
scenario "row found on first check"                    row            1 sent     1
# -- a completed check that finds nothing is the ONLY thing that earns a second send
scenario "checked, nothing -> one resend, which lands" late           2 sent     2
scenario "checked, nothing, resend still nothing"      empty          2 not-sent 2
scenario "row is for another day's digest"             othersubj      2 not-sent 2
scenario "row is addressed to someone else"            otherto        2 not-sent 2
# -- THE BUG: a query that FAILED must not cause a second send
scenario "gc events fails on every try"                fail           1 unknown  2
scenario "gc events fails, then finds the row"         fail,row       1 sent     2
scenario "gc events exits 0 but prints garbage"        garbage        1 unknown  2
# -- failed then completed-empty is a real answer; a failed check after the resend is still unknown
scenario "gc events fails, then checked and empty"     fail,empty     2 not-sent 3
scenario "resend happened, then the check fails"       empty,fail     2 unknown  3

# -- the resend must be the same mail: same subject, same body
run bash late
[ "$SUBJ_UNIQ" = 1 ] && [ "$BODY_UNIQ" = 1 ] && ok "resend repeats the identical subject and body" || bad "resend differs from the first send (subjects=$SUBJ_UNIQ bodies=$BODY_UNIQ)"
[ "$FIRST_SUBJ" = "Gas Town Digest: 2026-09-26" ] && ok "send subject is 'Gas Town Digest: <date>'" || bad "send subject is '$FIRST_SUBJ'"

echo "== $P passed, $F failed =="
[ "$F" -eq 0 ]
