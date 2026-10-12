#!/bin/bash
# rea-patch.selftest.sh — tests for rea-patch.sh (ga-pfc2ww).
#
# Hermetic: every scenario builds a throwaway fake `rea-agents` package and a throwaway patch root under
# a mktemp dir and points the script at them (REA_PKG_DIR / REA_PATCH_ROOT). The LIVE install is never
# written; it is only READ in the last section, and that section reports without failing the run (a
# deliberate `rea update` bead must not turn unrelated gate runs red).
#
# What each section proves is stated in its header. Scenarios that must NOT change a file assert the
# sha256 before/after, not just the exit code.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/rea-patch.sh"
REAL_ROOT="$HERE/rea-patches"

T="$(mktemp -d /tmp/rea-patch-selftest.XXXXXX)" || exit 2
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
sha() { shasum -a 256 -- "$1" | awk '{print $1}'; }
# run <env assignments...> -- <subcommand>   -> OUT, RC
run() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  OUT="$(env "${envs[@]}" bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
expect_rc()  { [ "$RC" -eq "$1" ] && ok "$2 (rc=$RC)" || bad "$2 — expected rc=$1, got rc=$RC: $OUT"; }
expect_out() { case "$OUT" in *"$1"*) ok "$2" ;; *) bad "$2 — output lacks «$1»: $OUT" ;; esac; }
expect_no()  { case "$OUT" in *"$1"*) bad "$2 — output has «$1»: $OUT" ;; *) ok "$2" ;; esac; }

# ── fixture: pristine / patched content and a real `diff -u` patch between them ─────────────────────────
mkdir -p "$T/gen/a/dist" "$T/gen/b/dist"
printf '%s\n' 'function a() {}' 'const t = {' '  timeout: 60_000,' '  max: 1,' '};' > "$T/gen/a/dist/x.js"
printf '%s\n' 'function a() {}' 'const t = {' '  timeout: 300_000, // patched' '  max: 1,' '};' > "$T/gen/b/dist/x.js"
(cd "$T/gen" && diff -u a/dist/x.js b/dist/x.js | sed -e '1s/	.*$//' -e '2s/	.*$//') > "$T/x.patch"
PRI_SHA="$(sha "$T/gen/a/dist/x.js")"; PAT_SHA="$(sha "$T/gen/b/dist/x.js")"
# second file, for the all-or-nothing scenario
printf '%s\n' 'let y = 1;' 'let z = 2;' > "$T/gen/a/dist/y.js"
printf '%s\n' 'let y = 1;' 'let z = 3;' > "$T/gen/b/dist/y.js"
(cd "$T/gen" && diff -u a/dist/y.js b/dist/y.js | sed -e '1s/	.*$//' -e '2s/	.*$//') > "$T/y.patch"
PRI_Y="$(sha "$T/gen/a/dist/y.js")"; PAT_Y="$(sha "$T/gen/b/dist/y.js")"

# mk <name> <pin> <pkg-version> -> builds $T/<name>/{root,pkg} with ONE file (x.js, pristine) and its manifest
mk() {
  local d="$T/$1"
  mkdir -p "$d/root/$2" "$d/pkg/dist" "$d/tmp"
  printf '%s\n' "$2" > "$d/root/PIN"
  cp "$T/x.patch" "$d/root/$2/0001-x.patch"
  printf 'dist/x.js\t%s\t%s\t0001-x.patch\n' "$PRI_SHA" "$PAT_SHA" > "$d/root/$2/MANIFEST.tsv"
  printf '{"name":"rea-agents","version":"%s"}\n' "$3" > "$d/pkg/package.json"
  cp "$T/gen/a/dist/x.js" "$d/pkg/dist/x.js"
}
ENVS() { echo "REA_PKG_DIR=$T/$1/pkg REA_PATCH_ROOT=$T/$1/root TMPDIR=$T/$1/tmp"; }
r() { local n="$1"; shift; local e; read -r -a e <<<"$(ENVS "$n")"; run "${e[@]}" -- "$@"; }

echo "=== rea-patch.selftest.sh ==="

echo "── pristine at the pinned version: check says DRIFT, apply fixes it, second apply is a no-op ──"
mk s1 1.2.3 1.2.3
r s1 check;  expect_rc 1 "check on a pristine file is DRIFT, not OK"; expect_out "DRIFT: not patched dist/x.js" "check names the file"
r s1 apply;  expect_rc 0 "apply succeeds"; expect_out "APPLIED   dist/x.js" "apply reports the file it patched"
[ "$(sha "$T/s1/pkg/dist/x.js")" = "$PAT_SHA" ] && ok "file now has the patched sha256" || bad "file sha256 is not the patched one"
grep -q 'timeout: 300_000' "$T/s1/pkg/dist/x.js" && ! grep -q 'timeout: 60_000' "$T/s1/pkg/dist/x.js" && ok "content really changed (60_000 -> 300_000)" || bad "content did not change"
r s1 check;  expect_rc 0 "check is OK after apply"; expect_out "OK rea-agents 1.2.3 (pinned), 1/1" "OK line carries version and count"
B4="$(sha "$T/s1/pkg/dist/x.js")"; M4="$(ls -l -T "$T/s1/pkg/dist/x.js" | awk '{print $6,$7,$8,$9}')"
r s1 apply;  expect_rc 0 "second apply succeeds"; expect_out "already   dist/x.js" "second apply says already"; expect_no "APPLIED" "second apply patches nothing"
[ "$(sha "$T/s1/pkg/dist/x.js")" = "$B4" ] && [ "$(ls -l -T "$T/s1/pkg/dist/x.js" | awk '{print $6,$7,$8,$9}')" = "$M4" ] && ok "second apply left the file untouched (sha and mtime)" || bad "second apply rewrote the file"
LEFT=("$T/s1/pkg/dist/"*rea-patch*); [ -e "${LEFT[0]}" ] && bad "staging file left behind in the package" || ok "no staging leftovers in the package"
[ -z "$(ls -A "$T/s1/tmp")" ] && ok "temp dir cleaned up" || bad "temp dir left behind: $(ls -A "$T/s1/tmp")"

echo "── version drift: a version nobody reviewed is neither OK nor patched ──"
mk s2 1.2.3 1.2.4
B="$(sha "$T/s2/pkg/dist/x.js")"
r s2 check;  expect_rc 1 "check on another version is DRIFT"; expect_out "installed rea-agents 1.2.4 but pinned 1.2.3" "message names both versions"
r s2 apply;  expect_rc 1 "apply refuses another version"; expect_out "REFUSED" "apply says REFUSED"
[ "$(sha "$T/s2/pkg/dist/x.js")" = "$B" ] && ok "file untouched on version mismatch" || bad "file changed despite version mismatch"
mk s2b 1.2.3 1.2.4; cp "$T/gen/b/dist/x.js" "$T/s2b/pkg/dist/x.js"
r s2b check; expect_rc 1 "an already-patched file on the WRONG version is still DRIFT (version outranks hash)"

echo "── a file that is neither pristine nor patched is never touched (apply and check agree) ──"
mk s3 1.2.3 1.2.3; printf 'something else entirely\n' > "$T/s3/pkg/dist/x.js"; B="$(sha "$T/s3/pkg/dist/x.js")"
r s3 check;  expect_rc 2 "check says UNKNOWN (2), not OK and not DRIFT"; expect_out "UNKNOWN" "message says UNKNOWN"
r s3 apply;  expect_rc 2 "apply refuses"; expect_out "Nothing was changed" "message says nothing changed"
[ "$(sha "$T/s3/pkg/dist/x.js")" = "$B" ] && ok "modified file left byte-identical" || bad "modified file was changed"

echo "── can't tell is exit 2: missing package, wrong package, garbage package.json, no rea on PATH ──"
mk s4 1.2.3 1.2.3; rm -r "$T/s4/pkg"
r s4 check;  expect_rc 2 "missing package dir"
mk s4b 1.2.3 1.2.3; printf '{"name":"not-rea","version":"1.2.3"}\n' > "$T/s4b/pkg/package.json"
r s4b check; expect_rc 2 "package.json of another package"
mk s4c 1.2.3 1.2.3; printf 'not json at all\n' > "$T/s4c/pkg/package.json"
r s4c check; expect_rc 2 "unparseable package.json"
r s4c apply; expect_rc 2 "apply on unparseable package.json"
OUT="$(env -u REA_PKG_DIR "REA_PATCH_ROOT=$T/s1/root" PATH=/usr/bin:/bin bash "$SCRIPT" check 2>&1)"; RC=$?
expect_rc 2 "no REA_PKG_DIR and no \`rea\` on PATH"

echo "── malformed patch data is exit 2, not a guess ──"
mk s5 1.2.3 1.2.3; rm "$T/s5/root/PIN"
r s5 check; expect_rc 2 "missing PIN"
mk s5b 1.2.3 1.2.3; printf 'dist/x.js\tnothex\t%s\t0001-x.patch\n' "$PAT_SHA" > "$T/s5b/root/1.2.3/MANIFEST.tsv"
r s5b check; expect_rc 2 "bad pristine sha in the manifest"
mk s5c 1.2.3 1.2.3; printf 'dist/x.js\t%s\t%s\t0001-x.patch\n' "$PRI_SHA" "$PRI_SHA" > "$T/s5c/root/1.2.3/MANIFEST.tsv"
r s5c check; expect_rc 2 "pristine == patched sha in the manifest"
mk s5d 1.2.3 1.2.3; printf '../evil.js\t%s\t%s\t0001-x.patch\n' "$PRI_SHA" "$PAT_SHA" > "$T/s5d/root/1.2.3/MANIFEST.tsv"
r s5d check; expect_rc 2 "manifest path escaping the package"
mk s5e 1.2.3 1.2.3; rm "$T/s5e/root/1.2.3/0001-x.patch"
r s5e check; expect_rc 2 "manifest lists a patch file that is not there"
mk s5f 1.2.3 1.2.3; rm "$T/s5f/root/1.2.3/MANIFEST.tsv"
r s5f check; expect_rc 2 "no manifest for the pinned version"
mk s5g 1.2.3 1.2.3; printf '# no rows: upstream fixed it, nothing to patch\n' > "$T/s5g/root/1.2.3/MANIFEST.tsv"
r s5g check; expect_rc 0 "a manifest with zero rows is a valid 'nothing to patch'"; expect_out "0/0" "…and says 0/0"

echo "── a patch that fails or yields the wrong bytes leaves the package untouched and the temp dir clean ──"
mk s6 1.2.3 1.2.3; printf '%s\n' '--- a/dist/x.js' '+++ b/dist/x.js' '@@ -1,3 +1,3 @@' ' not the context' '-nor this' '+nor that' ' at all' > "$T/s6/root/1.2.3/0001-x.patch"
B="$(sha "$T/s6/pkg/dist/x.js")"
r s6 apply;  expect_rc 2 "patch that does not apply cleanly (no fuzz)"; expect_out "does not apply cleanly" "message says why"
[ "$(sha "$T/s6/pkg/dist/x.js")" = "$B" ] && ok "file untouched when the patch fails" || bad "file changed although the patch failed"
[ -z "$(ls -A "$T/s6/tmp")" ] && ok "temp dir cleaned after failure" || bad "temp dir left behind after failure"
mk s6b 1.2.3 1.2.3; printf 'dist/x.js\t%s\t%s\t0001-x.patch\n' "$PRI_SHA" "$(printf 'wrong' | shasum -a 256 | awk '{print $1}')" > "$T/s6b/root/1.2.3/MANIFEST.tsv"
B="$(sha "$T/s6b/pkg/dist/x.js")"
r s6b apply; expect_rc 2 "patch applies but result hash != manifest"; expect_out "left untouched" "message says package left untouched"
[ "$(sha "$T/s6b/pkg/dist/x.js")" = "$B" ] && ok "file untouched when the result hash is wrong" || bad "file changed although the result hash was wrong"

echo "── no fuzz: a patch whose outermost context line is stale must be refused, not 'close enough' ──"
mk s6c 1.2.3 1.2.3; sed 's/^ function a() {}$/ function STALE() {}/' "$T/x.patch" > "$T/s6c/root/1.2.3/0001-x.patch"
grep -q 'STALE' "$T/s6c/root/1.2.3/0001-x.patch" && ok "fixture: patch context made stale" || bad "fixture: could not make the context stale"
B="$(sha "$T/s6c/pkg/dist/x.js")"
r s6c apply; expect_rc 2 "stale-context patch is refused"; expect_out "does not apply cleanly" "message says why"
[ "$(sha "$T/s6c/pkg/dist/x.js")" = "$B" ] && ok "file untouched when the context is stale" || bad "file changed by a fuzzy match"

echo "── all-or-nothing: one odd file in the set blocks the whole apply ──"
mk s7 1.2.3 1.2.3
cp "$T/y.patch" "$T/s7/root/1.2.3/0002-y.patch"
printf 'dist/y.js\t%s\t%s\t0002-y.patch\n' "$PRI_Y" "$PAT_Y" >> "$T/s7/root/1.2.3/MANIFEST.tsv"
printf 'someone else edited this\n' > "$T/s7/pkg/dist/y.js"
BX="$(sha "$T/s7/pkg/dist/x.js")"
r s7 apply;  expect_rc 2 "apply refuses the set"
[ "$(sha "$T/s7/pkg/dist/x.js")" = "$BX" ] && ok "the clean file was NOT patched either (no half-patched set)" || bad "first file got patched although the second blocked the set"
cp "$T/gen/a/dist/y.js" "$T/s7/pkg/dist/y.js"
r s7 apply;  expect_rc 0 "with both pristine, apply patches both"; expect_out "2/2 patched file(s) in place (2 applied now)" "summary counts both"
r s7 check;  expect_rc 0 "check OK for both"

echo "── the real patch data in git is well-formed, and the real patch applies to the real hunk ──"
RPIN="$(tr -d '[:space:]' < "$REAL_ROOT/PIN" 2>/dev/null)"
[[ "$RPIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "rea-patches/PIN is a x.y.z version ($RPIN)" || bad "rea-patches/PIN missing or malformed"
RMAN="$REAL_ROOT/$RPIN/MANIFEST.tsv"
[ -r "$RMAN" ] && ok "manifest exists for the pinned version" || bad "no manifest for $RPIN"
ROWS=0; BADROW=0
while IFS=$'\t' read -r rel pri pat pf; do
  case "$rel" in ''|'#'*) continue ;; esac
  ROWS=$((ROWS + 1))
  [[ "$pri" =~ ^[0-9a-f]{64}$ && "$pat" =~ ^[0-9a-f]{64}$ && "$pri" != "$pat" && -r "$REAL_ROOT/$RPIN/$pf" && "$rel" != /* && "$rel" != *..* ]] || { BADROW=$((BADROW + 1)); echo "    bad row: $rel"; }
done < "$RMAN"
[ "$ROWS" -ge 1 ] && [ "$BADROW" -eq 0 ] && ok "every manifest row has valid hashes and an existing patch ($ROWS row(s))" || bad "manifest rows: $ROWS, malformed: $BADROW"
# Rebuild the hunk's before-image from the real patch and apply the real patch to it.
RP="$(ls "$REAL_ROOT/$RPIN"/*.patch 2>/dev/null | head -1)"
START="$(grep -m1 '^@@ ' "$RP" | sed -E 's/^@@ -([0-9]+).*/\1/')"
TARGET="$(grep -m1 '^+++ ' "$RP" | sed -E 's#^\+\+\+ b/##')"
mkdir -p "$T/real/$(dirname "$TARGET")"
{ i=1; while [ "$i" -lt "$START" ]; do echo "filler $i"; i=$((i + 1)); done
  awk '/^@@ /{h=1; next} h && /^[ -]/{print substr($0,2)}' "$RP"
  echo "tail 1"; echo "tail 2"; } > "$T/real/$TARGET"
patch -p1 -F0 -s -d "$T/real" -i "$RP" >/dev/null 2>&1; PRC=$?
[ "$PRC" -eq 0 ] && ok "real patch applies to the before-image of its own hunk (no fuzz)" || bad "real patch does not apply (patch rc=$PRC)"
grep -q 'timeout: 300_000' "$T/real/$TARGET" && ! grep -q 'timeout: 60_000' "$T/real/$TARGET" && ok "real patch turns timeout 60_000 into 300_000" || bad "real patch did not produce timeout: 300_000"
grep -c '^[-+][^-+]' "$RP" | grep -qx 2 && ok "real patch changes exactly one line (-1/+1)" || bad "real patch changes more or less than one line"

echo "── live install (informational only; never fails the run) ──"
OUT="$(bash "$SCRIPT" check 2>&1)"; RC=$?
echo "  INFO: live check rc=$RC — $(printf '%s' "$OUT" | tail -1)"
[ "$RC" -ne 0 ] && echo "  INFO: rc!=0 means the live REA is not on the pin or lost the patch: run rea-patch.sh apply (or open the update bead)"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
