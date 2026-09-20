#!/usr/bin/env bash
# pipefail-grepq-codemod.selftest.sh — ga-5bxuam. Golden-file test for the codemod and falsification of
# its independent verifier.
#
# pipefail-grepq-codemod.py rewrites `<writer> | grep -q ...` (an early-exit reader that turns a MATCH
# into "no match" under `set -o pipefail`, see error-empty-conflation-scan.sh C10) to
# `<writer> | grep ... >/dev/null`. It is meant to be run over hundreds of files (the selftests and
# tests still carry ~1400 sites), so "it looked right" is not enough. This file proves:
#   1. DETECTION + REWRITE: on a fixture of every awkward shape (multi-line continuation, $(...), quoted
#      $(...), heredoc body, quoted multi-line string, comment, $((a|b)), case pattern, ! negation, existing
#      redirects, --quiet, -eq where q is -e's argument, "-q" quoted, grep not last, stdout redirected...)
#      the output equals the golden file byte for byte, and only CODE is edited;
#   2. it is idempotent, does not touch a file without pipefail, and honors "# erro-vs-vazio: ok <razao>";
#   3. the output parses (bash 3.2 and 5.x);
#   4. pipefail-grepq-verify-diff.py ACCEPTS the rewrite and REJECTS a tampered one (a checker that
#      cannot fail is not a checker).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEMOD="$SELF_DIR/pipefail-grepq-codemod.py"
VERIFY="$SELF_DIR/pipefail-grepq-verify-diff.py"
P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

command -v python3 >/dev/null 2>&1 || { echo "  BAD: python3 not found"; echo "Results: 0 passed, 1 failed"; exit 1; }
[ -f "$CODEMOD" ] && [ -f "$VERIFY" ] || { echo "  BAD: codemod or verifier missing next to this selftest"; echo "Results: 0 passed, 1 failed"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

cat > "$T/input.sh" <<'FIXTURE_IN'
#!/bin/bash
set -uo pipefail
x="a b"; y=z; cmd() { echo "$x"; }
if printf '%s' "$x" | grep -q foo; then :; fi
echo "$x" | grep -qE 'a|b;c' && echo yes || echo no
printf '%s\n' "$x" | grep -Eq "^a(b|c)\$"
echo "$x" | grep -Fxq -- "$y"
if [ -n "$x" ] && echo "$x" | grep -qE "-adhoc-[0-9a-f]+" 2>/dev/null; then :; fi
v=$(cmd | grep -q pat && echo 1)
msg="$(echo "$x" | grep -q x && echo yes)"
foo() {
  printf '%s' "$x" | grep -Eq \
    'AAA|BBB' && return 0
  return 1
}
# echo "$x" | grep -q commented
cat <<'EOF'
echo "$x" | grep -q inheredoc
EOF
foo='line1
echo "$x" | grep -q inquote
line3'
cmd | grep --quiet foo
cmd | grep pat -q
grep -q foo /etc/hosts
cmd | grep -qe foo
cmd | grep -eq
cmd | grep "-q" foo
cmd | grep -q foo | cat
! cmd | grep -q foo
cmd | grep -q foo 2>&1
cmd | grep -q foo >/dev/null 2>&1
cmd | grep -q foo >out
while read -r l; do :; done < <(cmd | grep -q x)
n=$((3 | 4)); echo $n | grep -q 7
case "$x" in a|b) echo "$y" | grep -q z;; esac
w=$(printf '%s\n' "$y" | tr ' ' '\n' | grep -q '^gate-status:')
[ "$(echo "$x" | grep -c a)" = 1 ] && echo "$x" | grep -qi 'A B' || true
FIXTURE_IN

cat > "$T/golden.sh" <<'FIXTURE_OUT'
#!/bin/bash
set -uo pipefail
x="a b"; y=z; cmd() { echo "$x"; }
if printf '%s' "$x" | grep foo >/dev/null; then :; fi
echo "$x" | grep -E 'a|b;c' >/dev/null && echo yes || echo no
printf '%s\n' "$x" | grep -E "^a(b|c)\$" >/dev/null
echo "$x" | grep -Fx -- "$y" >/dev/null
if [ -n "$x" ] && echo "$x" | grep -E "-adhoc-[0-9a-f]+" 2>/dev/null >/dev/null; then :; fi
v=$(cmd | grep pat >/dev/null && echo 1)
msg="$(echo "$x" | grep x >/dev/null && echo yes)"
foo() {
  printf '%s' "$x" | grep -E \
    'AAA|BBB' >/dev/null && return 0
  return 1
}
# echo "$x" | grep -q commented
cat <<'EOF'
echo "$x" | grep -q inheredoc
EOF
foo='line1
echo "$x" | grep -q inquote
line3'
cmd | grep foo >/dev/null
cmd | grep pat >/dev/null
grep -q foo /etc/hosts
cmd | grep -e foo >/dev/null
cmd | grep -eq
cmd | grep "-q" foo
cmd | grep -q foo | cat
! cmd | grep foo >/dev/null
cmd | grep foo 2>&1 >/dev/null
cmd | grep foo >/dev/null 2>&1
cmd | grep -q foo >out
while read -r l; do :; done < <(cmd | grep x >/dev/null)
n=$((3 | 4)); echo $n | grep 7 >/dev/null
case "$x" in a|b) echo "$y" | grep z >/dev/null;; esac
w=$(printf '%s\n' "$y" | tr ' ' '\n' | grep '^gate-status:' >/dev/null)
[ "$(echo "$x" | grep -c a)" = 1 ] && echo "$x" | grep -i 'A B' >/dev/null || true
FIXTURE_OUT

cat > "$T/nopf.sh" <<'FIXTURE_NOPF'
#!/bin/bash
echo "$x" | grep -q foo && echo hit
FIXTURE_NOPF
cp "$T/input.sh" "$T/input.pristine"; cp "$T/nopf.sh" "$T/nopf.pristine"

echo "── dry run changes nothing ──"
out="$(python3 "$CODEMOD" "$T" input.sh nopf.sh 2>&1)"
cmp -s "$T/input.sh" "$T/input.pristine" && cmp -s "$T/nopf.sh" "$T/nopf.pristine" && ok "no --apply: files are byte-identical" || bad "a dry run modified a file"
[[ "$out" == *"input.sh: sites=22 rewritten=19 skipped=3"* ]] && ok "reports 22 sites, 19 rewritten, 3 skipped" || bad "dry-run summary unexpected: $out"
[[ "$out" == *"[quoted-flag-cluster]"* && "$out" == *"[grep-not-last-stage]"* && "$out" == *"[stdout-redirected-to >out]"* ]] && ok "each skip is reported WITH its reason" || bad "skip reasons missing: $out"
[[ "$out" == *"nopf.sh: sites=1 rewritten=0 skipped=1"* && "$out" == *"[no-pipefail-before]"* ]] && ok "a file that never sets pipefail is reported and skipped" || bad "no-pipefail handling: $out"

echo "── apply: golden file ──"
python3 "$CODEMOD" --apply "$T" input.sh nopf.sh >/dev/null 2>&1
cmp -s "$T/input.sh" "$T/golden.sh" && ok "rewrite equals the golden file byte for byte (19 sites, code only)" || { bad "rewrite differs from golden:"; diff "$T/golden.sh" "$T/input.sh" | head -10; }
cmp -s "$T/nopf.sh" "$T/nopf.pristine" && ok "the file without pipefail was NOT touched" || bad "no-pipefail file was modified"
/bin/bash -n "$T/input.sh" && /opt/homebrew/bin/bash -n "$T/input.sh" 2>/dev/null; [ $? -eq 0 ] && ok "output parses under /bin/bash (3.2) and bash 5.x" || bad "output does not parse"
cp "$T/input.sh" "$T/after1"
python3 "$CODEMOD" --apply "$T" input.sh >/dev/null 2>&1
cmp -s "$T/input.sh" "$T/after1" && ok "idempotent: a second run changes nothing" || bad "second run changed the file again"

echo "── allowlist ──"
cat > "$T/allow.sh" <<'FIXTURE_ALLOW'
set -uo pipefail
( set -o pipefail; printf '%s\n' "$BIG" | grep -q needle ) || n=1   # erro-vs-vazio: ok deliberate: this IS the race
echo "$x" | grep -q other
FIXTURE_ALLOW
python3 "$CODEMOD" --apply "$T" allow.sh >/dev/null 2>&1
l1="$(sed -n 2p "$T/allow.sh")"; l2="$(sed -n 3p "$T/allow.sh")"
[[ "$l1" == *"grep -q needle"* ]] && ok "a line carrying '# erro-vs-vazio: ok <razao>' is left alone" || bad "allowlisted line was rewritten: $l1"
[[ "$l2" == *"grep other >/dev/null"* ]] && ok "the next, unmarked line IS rewritten" || bad "unmarked line not rewritten: $l2"

echo "── the independent verifier accepts the rewrite and rejects tampering ──"
R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q 2>/dev/null
cp "$T/input.pristine" "$R/input.sh"
git -C "$R" add input.sh
git -C "$R" -c user.name=selftest -c user.email=selftest@example.invalid commit -q -m base 2>/dev/null
python3 "$CODEMOD" --apply "$R" input.sh >/dev/null 2>&1
vout="$(python3 "$VERIFY" "$R" HEAD 2>&1)"; vrc=$?
[ "$vrc" = 0 ] && [[ "$vout" == *"failures=0"* ]] && ok "verifier: accepts the codemod's own output (${vout##*# })" || bad "verifier rejected a correct rewrite (rc=$vrc): $vout"
# tamper: append a command to one rewritten line
python3 - "$R/input.sh" <<'PYTAMPER'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("grep foo >/dev/null; then :; fi", "grep foo >/dev/null; then :; fi; echo tampered", 1)
open(p, "w").write(s)
PYTAMPER
vout="$(python3 "$VERIFY" "$R" HEAD 2>&1)"; vrc=$?
[ "$vrc" = 1 ] && [[ "$vout" == *"FAIL"* ]] && ok "verifier: REJECTS a rewrite with an extra command spliced in" || bad "verifier accepted a tampered rewrite (rc=$vrc): $vout"
git -C "$R" checkout -q -- input.sh
python3 "$CODEMOD" --apply "$R" input.sh >/dev/null 2>&1
# tamper 2: drop a pre-existing >/dev/null
python3 - "$R/input.sh" <<'PYTAMPER2'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("grep foo >/dev/null 2>&1", "grep foo 2>&1", 1)
open(p, "w").write(s)
PYTAMPER2
vout="$(python3 "$VERIFY" "$R" HEAD 2>&1)"; vrc=$?
[ "$vrc" = 1 ] && [[ "$vout" == *"LOST"* ]] && ok "verifier: REJECTS a rewrite that loses an existing >/dev/null" || bad "verifier accepted a lost redirect (rc=$vrc): $vout"

echo "── verifier: the '-q --' alignment ambiguity does not false-positive ──"
# ga-d37l4y: a bare "-q" word immediately followed by another "-"-led token (a
# literal "--" end-of-options marker is the common case) removes cleanly, but
# difflib's SequenceMatcher can represent that same net edit as deleting "q -"
# instead of " -q" -- an alignment artifact, not a different edit. A checker
# that pattern-matches one opcode's shape misreports it as unrecognized. Real,
# not hypothetical: 20 sites across the *.selftest.sh sweep hit exactly this.
AMBIG="$T/ambig"; mkdir -p "$AMBIG"
git -C "$AMBIG" init -q 2>/dev/null
cat > "$AMBIG/f.sh" <<'FIXTURE_AMBIG'
#!/bin/bash
set -uo pipefail
if [ -n "$x" ] && echo "$x" | grep -q -- '--strict-mcp-config'; then :; fi
FIXTURE_AMBIG
git -C "$AMBIG" add f.sh
git -C "$AMBIG" -c user.name=selftest -c user.email=selftest@example.invalid commit -q -m base 2>/dev/null
python3 "$CODEMOD" --apply "$AMBIG" f.sh >/dev/null 2>&1
vout="$(python3 "$VERIFY" "$AMBIG" HEAD 2>&1)"; vrc=$?
[ "$vrc" = 0 ] && [[ "$vout" == *"failures=0"* ]] && ok "verifier: accepts a -q immediately followed by -- (the alignment-ambiguity case)" || bad "verifier false-positived on '-q --' (rc=$vrc): $vout"

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
