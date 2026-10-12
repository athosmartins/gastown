#!/bin/bash
# Selftest for doc-rules-lint.py + its quality-gate wiring (ga-vhzdh5.1).
#
# Fully hermetic: temp dirs + temp git repos only. No network, no bd/gc call,
# no real city state (GC_CITY_PATH is pointed at a sandbox so the live
# `.gc/doc-rules-lint.off` flag file can never leak in).
#
# Cases (the five the story names, plus the edges around them):
#   - `##` inside a code fence / HTML comment / 4-space indent is not a title
#   - YAML frontmatter (incl. a `## ...` YAML comment inside it)
#   - exactly 300 chars (exempt) vs 301 (needs Contents), chars not bytes
#   - `@import` that blows the 200-line cap, exactly 200, cycles, imports in
#     code fences / inline code
#   - incomplete / late / missing Contents
#   - --fix-contents (idempotent, <=100 cols, frontmatter, CRLF)
#   - scope exclusions, upstream exclusion, --diff mode, exit codes
#   - NEGATIVE CONTROL: DOC_RULES_LINT=off lets the bad case through
#   - formula wiring: the step-2c snippet of mol-quality-gate-runner.toml is
#     extracted and executed against a fixture worktree
#
# Bash 3.2-compatible (macOS /bin/bash): no assoc arrays, no mapfile, no ${v,,}.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${DOC_RULES_LINT_SUT:-$HERE/doc-rules-lint.py}"
FORMULA="${DOC_RULES_LINT_FORMULA:-$HERE/../formulas/mol-quality-gate-runner.toml}"
PY="${DOC_RULES_LINT_PY:-python3}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

SBX="$(mktemp -d "${TMPDIR:-/tmp}/doc-rules-lint-selftest.XXXXXX")"
trap 'rm -rf "$SBX"' EXIT

# Hermetic env: no inherited kill switch, no live flag file, no user git config.
unset DOC_RULES_LINT DOC_RULES_UPSTREAM_REF
export GC_CITY_PATH="$SBX/city"
mkdir -p "$GC_CITY_PATH/.gc" "$GC_CITY_PATH/scripts"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ---------------------------------------------------------------- helpers
fill() { printf '%*s' "$1" '' | tr ' ' 'x'; }     # N 'x' chars, no newline
LONG="$(fill 320)"

newcase() { D="$SBX/case-$1"; rm -rf "$D"; mkdir -p "$D"; }
W() { mkdir -p "$(dirname "$D/$1")"; cat > "$D/$1"; }      # W <relpath> < content

# expect <name> <want_rc> <want_grep|-> <args...>   (runs from $D as --root)
expect() {
  local name="$1" want_rc="$2" want_pat="$3"; shift 3
  local out rc
  out="$("$PY" "$SUT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want_rc" ]; then bad "$name" "rc=$rc want=$want_rc :: $out"; return; fi
  if [ "$want_pat" != "-" ] && ! printf '%s\n' "$out" | grep -Eq -- "$want_pat"; then
    bad "$name" "rc ok but output lacks /$want_pat/ :: $out"; return
  fi
  ok "$name"
}
# expect_not <name> <pattern> <args...>: output must NOT match the pattern
expect_not() {
  local name="$1" pat="$2"; shift 2
  local out
  out="$("$PY" "$SUT" "$@" 2>&1)"
  # the summary line proves the script really ran (a missing script prints neither)
  if ! printf '%s\n' "$out" | grep -Eq 'doc-rules-lint: [0-9]+ file'; then bad "$name" "no summary line :: $out"; return; fi
  if printf '%s\n' "$out" | grep -Eq -- "$pat"; then bad "$name" "output matches /$pat/ :: $out"; else ok "$name"; fi
}
# expect_env <name> <want_rc> <want_grep|-> <ENV=VAL> <args...>
expect_env() {
  local name="$1" want_rc="$2" want_pat="$3" envv="$4"; shift 4
  local out rc
  out="$(env "$envv" "$PY" "$SUT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want_rc" ]; then bad "$name" "rc=$rc want=$want_rc :: $out"; return; fi
  if [ "$want_pat" != "-" ] && ! printf '%s\n' "$out" | grep -Eq -- "$want_pat"; then
    bad "$name" "rc ok but output lacks /$want_pat/ :: $out"; return
  fi
  ok "$name"
}
check()  { expect "$1" "$2" "$3" --check --root "$D" "${@:4}"; }

# mkclaude <relpath> <total_lines> [import_line]: a Contents-compliant file of
# exactly N lines (header is 8 lines; if an import line is given it is line 9).
mkclaude() {
  local rel="$1" n="$2" imp="${3:-}" i=8
  mkdir -p "$(dirname "$D/$rel")"
  {
    printf '# T\n\n## Contents\n\n• A\n\n## A\n\n'
    if [ -n "$imp" ]; then printf '%s\n' "$imp"; i=9; fi
    while [ "$i" -lt "$n" ]; do printf 'line %s\n' "$i"; i=$((i+1)); done
  } > "$D/$rel"
}

gitq() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
mkrepo() { # <dir>
  mkdir -p "$1"; git -C "$1" init -q; git -C "$1" symbolic-ref HEAD refs/heads/main
}
commit_all() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -q -m "${2:-c}" >/dev/null 2>&1; }

GOOD_DOC() { printf '# Doc\n\n## Contents\n\n• Alpha · Beta\n\n## Alpha\n\n%s\n\n## Beta\n\ntext\n' "$LONG"; }
BAD_DOC()  { printf '# Doc\n\n## Alpha\n\n%s\n\n## Beta\n\ntext\n' "$LONG"; }

echo "== prerequisites"
if [ -f "$SUT" ]; then ok "lint script exists ($SUT)"; else bad "lint script exists" "missing: $SUT"; fi
if /bin/bash -n "$0" 2>/dev/null; then ok "selftest parses under /bin/bash (3.2)"; else bad "selftest parses under /bin/bash" "syntax error"; fi
if "$PY" -I -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$SUT" "$SBX/sut.pyc" 2>/dev/null; then ok "lint script compiles"; else bad "lint script compiles" "py_compile failed"; fi

# ---------------------------------------------------------------- rule (b)
echo "== rule (b): Contents"
newcase b1; GOOD_DOC | W good.md
check "good doc passes" 0 ', 0 violation' good.md
newcase b2; BAD_DOC | W bad.md
check "no Contents -> contents-missing" 1 'bad\.md:[0-9]+: \[contents-missing\]' bad.md
newcase b3; printf '# Doc\n\n## Alpha\n\n%s\n\n## Contents\n\n• Alpha\n' "$LONG" | W late.md
check "Contents after first ## -> contents-late" 1 '\[contents-late\]' late.md
newcase b4; printf '# Doc\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n%s\n\n## Beta\n\ntext\n' "$LONG" | W inc.md
check "Contents missing a title -> contents-incomplete naming it" 1 'contents-incomplete.*Beta' inc.md
newcase b5; printf '# Doc\n\n## Contents\n\n• Alpha\n\n## Alpha\n\nBeta is mentioned here in the body.\n%s\n\n## Beta\n\ntext\n' "$LONG" | W scoped.md
check "title mentioned only OUTSIDE the Contents section still incomplete" 1 'contents-incomplete' scoped.md

echo "== rule (b): code fences / comments / indent are not titles"
newcase f1; printf '# Doc\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n```\n## Fake\n```\n%s\n' "$LONG" | W fence.md
check "## inside a triple-backtick fence ignored" 0 ', 0 violation' fence.md
newcase f2; printf '# Doc\n\n```\n## Contents\n• Alpha\n```\n\n## Alpha\n\n%s\n' "$LONG" | W fakec.md
check "fenced fake '## Contents' does not count" 1 'contents-missing' fakec.md
newcase f3; printf '# Doc\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n~~~\n## Fake\n~~~\n%s\n' "$LONG" | W tilde.md
check "## inside ~~~ fence ignored" 0 ', 0 violation' tilde.md
newcase f4; printf '# Doc\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n````\n```\n## Fake\n```\n````\n%s\n' "$LONG" | W longfence.md
check "3-backtick line inside a 4-backtick fence does not close it" 0 ', 0 violation' longfence.md
newcase f5; printf '# Doc\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n<!--\n## Hidden\n-->\n%s\n' "$LONG" | W comment.md
check "## inside HTML comment ignored" 0 ', 0 violation' comment.md
newcase f6; printf '# Doc\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n    ## Fake (indented code)\n%s\n' "$LONG" | W indent.md
check "4-space indented ## is code, not a title" 0 ', 0 violation' indent.md
newcase f7; printf '# Doc\n\n##Contents\n\n• Alpha\n\n## Alpha\n\n%s\n' "$LONG" | W nospace.md
check "'##Contents' (no space) is not a Contents heading" 1 'contents-missing' nospace.md

echo "== rule (b): frontmatter / preamble"
newcase m1; printf -- '---\nname: x\ndescription: y\n# yaml comment\n## not-a-heading\n---\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n%s\n' "$LONG" | W fm.md
check "frontmatter then Contents (## yaml comment inside is not a title)" 0 ', 0 violation' fm.md
newcase m2; printf -- '---\nname: x\n---\n\n# Doc\n\nOne intro paragraph.\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n%s\n' "$LONG" | W intro1.md
check "frontmatter + title + 1 intro paragraph before Contents is fine" 0 ', 0 violation' intro1.md
newcase m3; printf '# Doc\n\nFirst intro.\n\nSecond intro.\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n%s\n' "$LONG" | W intro2.md
check "2 intro paragraphs before Contents -> contents-late" 1 'contents-late' intro2.md
newcase m4; printf '# Doc\n\n## contents\n\n• Alpha\n\n## Alpha\n\n%s\n' "$LONG" | W lower.md
check "'## contents' lowercase accepted" 0 ', 0 violation' lower.md
newcase m5; printf '# Doc\n\n## Contents\n\n- [Alpha](#alpha)\n- [Beta](#beta)\n\n## Alpha\n\n%s\n\n## Beta\n\nx\n' "$LONG" | W links.md
check "link-style Contents accepted" 0 ', 0 violation' links.md
newcase m6; printf '# Doc\n\n## Contents\n\n• Alpha\n\n## Alpha ##\n\n%s\n' "$LONG" | W closers.md
check "closing #s stripped from the title" 0 ', 0 violation' closers.md
newcase m7; printf '# Doc\n\n## Contents\n\n• The code and emph\n\n## The `code` and *emph*\n\n%s\n' "$LONG" | W inline.md
check "inline markup normalized when matching titles" 0 ', 0 violation' inline.md
newcase m8; { printf '# Doc\n\n'; fill 320; printf '\n'; } | W flat.md
check "doc with no ## at all and >300 chars still needs Contents" 1 'contents-missing' flat.md

echo "== rule (b): the 300-char threshold"
newcase t1
# '# T\n\n## Foo\n\n' is 13 chars; body without trailing newline.
{ printf '# T\n\n## Foo\n\n'; fill 287; } > "$D/e300.md"
{ printf '# T\n\n## Foo\n\n'; fill 288; } > "$D/e301.md"
{ printf '# T\n\n## Foo\n\n'; i=0; while [ $i -lt 150 ]; do printf 'é'; i=$((i+1)); done; } > "$D/nonascii.md"
n300="$(wc -c < "$D/e300.md" | tr -d ' ')"; n301="$(wc -c < "$D/e301.md" | tr -d ' ')"
[ "$n300" = 300 ] && [ "$n301" = 301 ] && ok "fixtures are exactly 300 / 301 bytes" || bad "fixtures are exactly 300 / 301 bytes" "got $n300 / $n301"
nb="$(wc -c < "$D/nonascii.md" | tr -d ' ')"
[ "$nb" -gt 300 ] && ok "non-ASCII fixture is >300 bytes but <300 chars" || bad "non-ASCII fixture size" "bytes=$nb"
check "exactly 300 chars -> exempt" 0 ', 0 violation' e300.md
check "301 chars -> Contents required" 1 'contents-missing' e301.md
check ">300 BYTES but <=300 CHARS -> exempt (chars, not bytes)" 0 ', 0 violation' nonascii.md
newcase t2; printf '# Short\n\n## A\n\nshort doc\n' | W short.md
check "short doc exempt" 0 ', 0 violation' short.md
newcase t3; { printf 'plain text '; fill 400; } | W notes.txt
check "non-.md file not linted" 0 ', 0 violation' notes.txt
newcase t4; BAD_DOC | W README.MD
check ".MD (uppercase ext) is linted" 1 'contents-missing' README.MD

# ---------------------------------------------------------------- rule (a)
echo "== rule (a): CLAUDE.md / CLAUDE.local.md / AGENTS.md <= 200 lines incl. @imports"
newcase c1; mkclaude CLAUDE.md 200
check "CLAUDE.md with exactly 200 lines passes" 0 ', 0 violation' CLAUDE.md
newcase c2; mkclaude CLAUDE.md 201
check "CLAUDE.md with 201 lines fails" 1 'CLAUDE\.md:[0-9]*: \[claude-md-max-lines\].*201' CLAUDE.md
newcase c3; mkclaude CLAUDE.local.md 201
check "CLAUDE.local.md is covered" 1 'claude-md-max-lines' CLAUDE.local.md
newcase c4; mkclaude AGENTS.md 201
check "AGENTS.md is covered" 1 'claude-md-max-lines' AGENTS.md
newcase c5; mkclaude sub/dir/CLAUDE.md 201
check "nested CLAUDE.md is covered (any depth)" 1 'claude-md-max-lines' sub/dir/CLAUDE.md
newcase c6; mkclaude claude.md 250
check "'claude.md' (lowercase) is not one of the three names" 0 ', 0 violation' claude.md
# import-only line is REPLACED by the imported lines: 8 header + 192 = 200
newcase c7; mkclaude CLAUDE.md 9 '@AGENTS.md'; mkclaude AGENTS.md 192
check "@import: 8 own + 192 imported = 200 passes" 0 ', 0 violation' CLAUDE.md
newcase c8; mkclaude CLAUDE.md 9 '@AGENTS.md'; mkclaude AGENTS.md 193
check "@import that blows 200 (8 + 193) fails" 1 'claude-md-max-lines.*201' CLAUDE.md
newcase c9; mkclaude CLAUDE.md 9 '@a.md'; printf '@b.md\n' > "$D/a.md"; mkclaude b.md 193
check "@import is recursive (CLAUDE -> a -> b)" 1 'claude-md-max-lines' CLAUDE.md
newcase c10; mkclaude CLAUDE.md 9 '@sub/a.md'; mkdir -p "$D/sub"; printf '@b.md\n' > "$D/sub/a.md"; mkclaude sub/b.md 193
check "nested @import resolves relative to the importing file" 1 'claude-md-max-lines' CLAUDE.md
newcase c11; mkclaude CLAUDE.md 9 '@a.md'; printf 'a1\n@CLAUDE.md\n' > "$D/a.md"
check "@import cycle terminates (no loop)" 0 ', 0 violation' CLAUDE.md
newcase c12; mkclaude CLAUDE.md 195; printf '```\n@big.md\n```\n' >> "$D/CLAUDE.md"; mkclaude big.md 100
check "@import inside a code fence is not followed" 0 ', 0 violation' CLAUDE.md
newcase c13; mkclaude CLAUDE.md 198; printf 'use `@big.md` here\n' >> "$D/CLAUDE.md"; mkclaude big.md 100
check "@import inside inline code is not followed" 0 ', 0 violation' CLAUDE.md
newcase c14; mkclaude CLAUDE.md 195; printf 'mail a@b.com or ping @nobody or @missing/file.md\n' >> "$D/CLAUDE.md"
check "emails / @mentions / imports of missing files are not imports" 0 ', 0 violation' CLAUDE.md
newcase c15; mkclaude CLAUDE.md 9 '@AGENTS.md'; mkclaude AGENTS.md 193
check "violation message shows the own/imported breakdown" 1 'own 8.*imported 193' CLAUDE.md
newcase c16; mkclaude CLAUDE.md 150 'see @AGENTS.md for more'; mkclaude AGENTS.md 60
check "line with prose + import counts itself AND the imported lines" 1 'claude-md-max-lines.*210' CLAUDE.md
newcase c17; mkdir -p "$D"
{ printf '# T\r\n\r\n## Contents\r\n\r\n• A\r\n\r\n## A\r\n\r\n'; i=8; while [ $i -lt 200 ]; do printf 'l%s\r\n' "$i"; i=$((i+1)); done; } > "$D/CLAUDE.md"
check "CRLF CLAUDE.md with 200 lines passes" 0 ', 0 violation' CLAUDE.md
# an import target that cannot be stat'ed (EACCES on the directory) is "could not evaluate", never silently "not an import"
# (root ignores directory modes, so the case only means something for a non-root user)
if [ "$(id -u)" != 0 ]; then
  newcase c18; mkclaude CLAUDE.md 9 '@locked/a.md'; mkdir -p "$D/locked"; printf 'x\n' > "$D/locked/a.md"; chmod 000 "$D/locked"
  check "@import target behind an unsearchable directory -> exit 2, not a silent pass" 2 'doc-rules-lint: (ERROR|error).*locked' CLAUDE.md
  chmod 755 "$D/locked"
fi

# ---------------------------------------------------------------- --fix-contents
echo "== --fix-contents"
newcase x1; BAD_DOC | W doc.md
expect "fix on bad doc" 0 - --fix-contents --root "$D" doc.md
check "fixed doc now passes --check" 0 ', 0 violation' doc.md
cp "$D/doc.md" "$D/doc.once"
expect "fix again (idempotent run)" 0 - --fix-contents --root "$D" doc.md
if cmp -s "$D/doc.md" "$D/doc.once"; then ok "second --fix-contents is byte-identical (idempotent)"; else bad "idempotent" "file changed on second run"; fi

newcase x2; GOOD_DOC | W good.md; cp "$D/good.md" "$D/good.orig"
expect "fix on already-compliant doc" 0 - --fix-contents --root "$D" good.md
if cmp -s "$D/good.md" "$D/good.orig"; then ok "compliant doc is left byte-identical"; else bad "compliant doc untouched" "file was rewritten"; fi

newcase x3
{ printf '# Big\n\n'; i=1; while [ $i -le 40 ]; do printf '## Section number %s with a reasonably long title\n\ntext %s\n\n' "$i" "$i"; i=$((i+1)); done; } > "$D/big.md"
expect "fix on 40-heading doc" 0 - --fix-contents --root "$D" big.md
check "40-heading fixed doc passes" 0 ', 0 violation' big.md
over="$("$PY" -c '
import sys
txt = open(sys.argv[1], encoding="utf-8").read().split("\n")
i = txt.index("## Contents") + 1
bad = []
while i < len(txt) and not txt[i].startswith("#"):
    if len(txt[i]) > 100: bad.append(txt[i])
    i += 1
print(len(bad))' "$D/big.md")"
[ "$over" = 0 ] && ok "generated Contents lines are <= 100 cols" || bad "Contents width" "$over line(s) over 100 cols"

newcase x4; printf '# Doc\n\n```\n## Fenced\n```\n\n## Real\n\n%s\n' "$LONG" | W fenced.md
expect "fix on doc with fenced heading" 0 - --fix-contents --root "$D" fenced.md
if sed -n '/^## Contents/,/^```/p' "$D/fenced.md" | grep -q 'Fenced'; then bad "fixer ignores fenced headings" "fenced title leaked into Contents"; else ok "fixer ignores headings inside code fences"; fi
sed -n '/^## Contents/,/^```/p' "$D/fenced.md" | grep -q 'Real' && ok "fixer lists the real heading" || bad "fixer lists the real heading" "Real missing from Contents"

newcase x5; printf -- '---\nname: mem\ndescription: d\n---\n\n## Alpha\n\n%s\n' "$LONG" | W mem.md
expect "fix on doc with frontmatter" 0 - --fix-contents --root "$D" mem.md
head4="$(head -4 "$D/mem.md" | tr '\n' '|')"
[ "$head4" = '---|name: mem|description: d|---|' ] && ok "frontmatter preserved verbatim at the top" || bad "frontmatter preserved" "head: $head4"
check "frontmatter doc passes after fix" 0 ', 0 violation' mem.md
if [ "$(sed -n '5,7p' "$D/mem.md" | grep -c 'Contents')" -ge 1 ]; then ok "Contents lands right after the frontmatter"; else bad "Contents right after frontmatter" "$(sed -n '1,9p' "$D/mem.md")"; fi

newcase x6; printf '# Doc\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n%s\n\n## Beta\n\nx\n' "$LONG" | W stale.md
expect "fix on incomplete Contents" 0 - --fix-contents --root "$D" stale.md
check "incomplete Contents repaired" 0 ', 0 violation' stale.md
[ "$(grep -c '^## Contents' "$D/stale.md")" = 1 ] && ok "no duplicate Contents section after repair" || bad "no duplicate Contents" "$(grep -c '^## Contents' "$D/stale.md") sections"

newcase x7; printf '# Doc\n\n## Alpha\n\n%s\n\n## Contents\n\n• Alpha\n' "$LONG" | W misplaced.md
expect "fix on misplaced (late) Contents" 0 - --fix-contents --root "$D" misplaced.md
check "late Contents moved to the top" 0 ', 0 violation' misplaced.md

newcase x8; { printf '# Doc\r\n\r\n## Alpha\r\n\r\n%s\r\n' "$LONG"; } > "$D/crlf.md"
expect "fix on CRLF doc" 0 - --fix-contents --root "$D" crlf.md
check "CRLF doc passes after fix" 0 ', 0 violation' crlf.md
lines="$(wc -l < "$D/crlf.md" | tr -d ' ')"; crs="$(grep -c "$(printf '\r')" "$D/crlf.md")"
[ "$lines" = "$crs" ] && ok "CRLF preserved on every line" || bad "CRLF preserved" "lines=$lines crlf-lines=$crs"

newcase x9; printf '# Short\n\n## A\n\nshort\n' | W short.md; cp "$D/short.md" "$D/short.orig"
expect "fix on short doc" 0 - --fix-contents --root "$D" short.md
cmp -s "$D/short.md" "$D/short.orig" && ok "short doc untouched by the fixer" || bad "short doc untouched" "rewritten"

newcase x10; { printf '# Doc\n\n'; fill 320; printf '\n'; } | W flat.md
expect "fix on flat doc (no ##)" 0 - --fix-contents --root "$D" flat.md
check "flat doc passes after fix" 0 ', 0 violation' flat.md

# ---------------------------------------------------------------- exclusions
echo "== scope exclusions"
newcase s1
for p in vendor/a.md third_party/b.md node_modules/c.md .gc-worktrees/w/d.md .worktrees/e.md .wt-foo/f.md beads/g.md logs/h.md .gc/i.md; do BAD_DOC | W "$p"; done
BAD_DOC | W docs/beads/keep.md
out="$("$PY" "$SUT" --check --root "$D" vendor/a.md third_party/b.md node_modules/c.md .gc-worktrees/w/d.md .worktrees/e.md .wt-foo/f.md beads/g.md logs/h.md .gc/i.md 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "vendor/third_party/node_modules/worktree dirs/beads/logs/.gc are excluded (rc 0)" || bad "exclusions" "rc=$rc :: $out"
printf '%s\n' "$out" | grep -Eq 'skipped.*9|9 .*skipped' && ok "summary reports 9 skipped" || bad "summary reports skipped" "$out"
check "only TOP-LEVEL beads/ is excluded (docs/beads/x.md is ours)" 1 'docs/beads/keep\.md' docs/beads/keep.md
# the root itself living under a worktree dir must not exclude everything
newcase s2; mkdir -p "$D/.gc-worktrees/wt1"; BAD_DOC > "$D/.gc-worktrees/wt1/bad.md"
expect "root inside a .gc-worktrees dir: exclusion is relative to --root" 1 'contents-missing' --check --root "$D/.gc-worktrees/wt1" bad.md

echo "== upstream exclusion (files that exist upstream are not ours)"
newcase u1; R="$D"; mkrepo "$R"
BAD_DOC > "$R/UP.md"; commit_all "$R" "upstream state"
git -C "$R" update-ref refs/remotes/upstream/main HEAD
BAD_DOC > "$R/OURS.md"; commit_all "$R" "ours"
expect "file present in upstream/main is skipped; ours is flagged" 1 'OURS\.md' --check --root "$R" UP.md OURS.md
expect_not "upstream file not reported" 'UP\.md:' --check --root "$R" UP.md OURS.md
expect "--upstream-ref none disables the exclusion" 1 'UP\.md' --check --root "$R" --upstream-ref none UP.md
expect_env "DOC_RULES_UPSTREAM_REF env override (none)" 1 'UP\.md' DOC_RULES_UPSTREAM_REF=none --check --root "$R" UP.md
newcase u2; R="$D"; mkrepo "$R"; BAD_DOC > "$R/A.md"; commit_all "$R"
expect "repo without an upstream ref: file is linted" 1 'A\.md' --check --root "$R" A.md
# ref present but unreadable as a tree -> loud exit 2, never a silent pass
blob="$(printf 'x' | git -C "$R" hash-object -w --stdin)"
git -C "$R" update-ref refs/remotes/upstream/main "$blob" 2>/dev/null
expect "upstream ref that cannot be listed -> exit 2 (unknown != pass)" 2 'doc-rules-lint: (ERROR|error)' --check --root "$R" A.md

# ---------------------------------------------------------------- --diff mode
echo "== --diff mode"
newcase d1; R="$D"; mkrepo "$R"
BAD_DOC > "$R/old-bad.md"; BAD_DOC > "$R/gone.md"; commit_all "$R" base
BASE="$(git -C "$R" rev-parse HEAD)"
BAD_DOC > "$R/new-bad.md"; GOOD_DOC > "$R/new-good.md"; git -C "$R" rm -q gone.md; commit_all "$R" change
expect "--diff flags the changed bad file" 1 'new-bad\.md' --check --root "$R" --diff "$BASE..HEAD"
expect_not "--diff does not flag untouched old-bad.md" 'old-bad\.md' --check --root "$R" --diff "$BASE..HEAD"
expect_not "--diff does not flag the deleted file" 'gone\.md' --check --root "$R" --diff "$BASE..HEAD"
expect_not "--diff does not flag the changed good file" 'new-good\.md' --check --root "$R" --diff "$BASE..HEAD"
expect "--diff accepts the A...B (merge-base) form" 1 'new-bad\.md' --check --root "$R" --diff "$BASE...HEAD"
git -C "$R" checkout -q -b only-good "$BASE"; GOOD_DOC > "$R/only-good.md"; commit_all "$R" good
expect "--diff with only compliant changes passes even though old-bad.md exists" 0 ', 0 violation' --check --root "$R" --diff "$BASE..HEAD"
expect "--diff with an unknown revision -> exit 2" 2 'doc-rules-lint: (ERROR|error)' --check --root "$R" --diff "nonexistent-rev..HEAD"
mkdir -p "$SBX/nogit"
expect "--diff outside a git repo -> exit 2" 2 'doc-rules-lint: (ERROR|error)' --check --root "$SBX/nogit" --diff "a..b"

# ---------------------------------------------------------------- exit codes / usage
echo "== exit codes"
newcase e1
expect "explicit missing file -> exit 2" 2 'doc-rules-lint: (ERROR|error)' --check --root "$D" nope.md
expect "no files and no --diff -> exit 2" 2 'doc-rules-lint: (ERROR|error)' --check --root "$D"
expect "no mode flag -> exit 2" 2 'doc-rules-lint: (ERROR|error)' --root "$D" x.md
expect "--check and --fix-contents together -> exit 2" 2 'doc-rules-lint: (ERROR|error)' --check --fix-contents --root "$D" x.md
newcase e2; BAD_DOC | W u.md; chmod 000 "$D/u.md"
if [ "$(id -u)" = 0 ]; then ok "unreadable file (skipped: running as root)"; else expect "unreadable file -> exit 2 (not a pass)" 2 'doc-rules-lint: (ERROR|error)' --check --root "$D" u.md; fi
chmod 644 "$D/u.md"
newcase e3; { printf '# Doc\n\n## Alpha\n\n'; printf 'caf\351 '; fill 320; printf '\n'; } > "$D/latin1.md"
check "invalid UTF-8 still evaluated (not a crash)" 1 'contents-missing' latin1.md

# ---------------------------------------------------------------- kill switch / negative control
echo "== negative control: lint off -> the bad case passes"
newcase k1; BAD_DOC | W bad.md; mkclaude CLAUDE.md 300
expect "control: bad doc FAILS with lint on" 1 'contents-missing' --check --root "$D" bad.md
expect_env "NEGATIVE CONTROL: DOC_RULES_LINT=off -> bad doc passes" 0 'DISABLED' DOC_RULES_LINT=off --check --root "$D" bad.md CLAUDE.md
expect_env "DOC_RULES_LINT=on stays enabled" 1 'contents-missing' DOC_RULES_LINT=on --check --root "$D" bad.md
: > "$GC_CITY_PATH/.gc/doc-rules-lint.off"
expect "flag file .gc/doc-rules-lint.off disables the lint" 0 'DISABLED' --check --root "$D" bad.md
rm -f "$GC_CITY_PATH/.gc/doc-rules-lint.off"
expect "removing the flag file re-enables it" 1 'contents-missing' --check --root "$D" bad.md
expect_env "--fix-contents is NOT affected by the kill switch" 0 - DOC_RULES_LINT=off --fix-contents --root "$D" bad.md
check "fixed by --fix-contents even with the switch off" 0 ', 0 violation' bad.md

# ---------------------------------------------------------------- interpreter matrix
echo "== interpreter matrix (the gate may resolve a different python3)"
for P in /usr/bin/python3 /opt/homebrew/bin/python3; do
  [ -x "$P" ] || continue
  newcase p1; GOOD_DOC | W good.md; BAD_DOC | W bad.md
  o1="$("$P" "$SUT" --check --root "$D" good.md 2>&1)"; r1=$?
  o2="$("$P" "$SUT" --check --root "$D" bad.md 2>&1)"; r2=$?
  v="$("$P" -c 'import sys;print("%d.%d" % sys.version_info[:2])')"
  if [ "$r1" = 0 ] && [ "$r2" = 1 ]; then ok "python $v ($P): good=0 bad=1"; else bad "python $v ($P)" "good rc=$r1 :: $o1 || bad rc=$r2 :: $o2"; fi
done

# ---------------------------------------------------------------- formula wiring
echo "== quality-gate wiring (mol-quality-gate-runner.toml step 2c)"
if [ ! -f "$FORMULA" ]; then
  bad "formula exists" "missing: $FORMULA"
else
  # vazio (markers/body ausentes) → bad "step 2c snippet present" e nenhum teste de wiring roda; falhou (formula ilegível) → o awk dá vazio = o mesmo FAIL, nunca um pass
  SNIPPET="$(awk '/SELFTEST-EXTRACT doc-rules-lint-step2c: BEGIN/{f=1;next} /SELFTEST-EXTRACT doc-rules-lint-step2c: END/{f=0} f' "$FORMULA")"
  if [ -z "$SNIPPET" ]; then
    bad "step 2c snippet present in the formula" "no SELFTEST-EXTRACT doc-rules-lint-step2c markers/body"
  else
    ok "step 2c snippet present in the formula"
    printf '%s' "$SNIPPET" | grep -q '\\' && bad "snippet has no backslash (TOML basic string)" "found a backslash" || ok "snippet has no backslash (TOML \"\"\" strings would eat it)"
    printf '%s\n' "$SNIPPET" > "$SBX/snippet.body"
    { printf 'TEST_EXIT=${PRE_TEST_EXIT:-0}\nTEST_OUTPUT=""\n'; cat "$SBX/snippet.body"; printf '\necho "__TEST_EXIT=$TEST_EXIT"\necho "__TEST_OUTPUT_BEGIN"\necho "$TEST_OUTPUT"\n'; } > "$SBX/snippet.sh"
    /bin/bash -n "$SBX/snippet.sh" 2>/dev/null && ok "snippet parses under /bin/bash (3.2)" || bad "snippet parses under /bin/bash" "syntax error"

    # TOML round-trip: the snippet must survive TOML escape processing verbatim.
    if "$PY" -c 'import tomllib' 2>/dev/null; then
      if "$PY" - "$FORMULA" "$SBX/snippet.body" <<'PYEOF'
import sys, tomllib
f = tomllib.load(open(sys.argv[1], "rb"))
snip = open(sys.argv[2], encoding="utf-8").read().strip()
steps = [s for s in f["steps"] if s.get("id") == "run-tests"]
assert len(steps) == 1, "run-tests step missing"
assert snip in steps[0]["description"], "snippet altered by TOML parsing"
PYEOF
      then ok "formula is valid TOML and the snippet round-trips verbatim"; else bad "TOML round-trip" "formula invalid or snippet mangled"; fi
    else
      ok "TOML round-trip skipped (python has no tomllib)"
    fi

    # Fixture city + worktree with origin/main.
    CITY="$SBX/wiring-city"; mkdir -p "$CITY/scripts" "$CITY/.gc"; cp "$SUT" "$CITY/scripts/doc-rules-lint.py"
    WT="$SBX/wiring-wt"; mkrepo "$WT"
    BAD_DOC > "$WT/old-bad.md"; printf 'code\n' > "$WT/a.txt"; commit_all "$WT" base
    git -C "$WT" update-ref refs/remotes/origin/main HEAD
    git -C "$WT" checkout -q -b feat

    run2c() { # <shell> [env assignments...] -> sets W_OUT W_RC (TEST_EXIT)
      local sh="$1"; shift
      W_OUT="$(env "$@" WORKTREE_PATH="$WT" GC_CITY_PATH="$CITY" "$sh" "$SBX/snippet.sh" 2>&1)"
      # vazio (o snippet morreu antes de imprimir __TEST_EXIT) → W_RC vazio e todo check abaixo conta como FAIL (nenhum aceita vazio como 0); falhou → idem
      W_RC="$(printf '%s\n' "$W_OUT" | sed -n 's/^__TEST_EXIT=//p' | tail -1)"
    }

    BAD_DOC > "$WT/new-bad.md"; commit_all "$WT" "bad doc"
    for SH in bash /bin/bash; do
      run2c "$SH" X=1
      if [ "$W_RC" != "" ] && [ "$W_RC" != 0 ]; then ok "wiring ($SH): changed bad .md -> TEST_EXIT != 0"; else bad "wiring ($SH): changed bad .md fails the gate" "TEST_EXIT=$W_RC :: $W_OUT"; fi
    done
    printf '%s\n' "$W_OUT" | grep -q 'new-bad.md' && ok "wiring: failure output names the offending file" || bad "wiring: names the file" "$W_OUT"
    printf '%s\n' "$W_OUT" | grep -q -- '--fix-contents' && ok "wiring: failure output tells the builder how to fix it" || bad "wiring: fix hint" "$W_OUT"
    printf '%s\n' "$W_OUT" | grep -q 'old-bad.md' && bad "wiring: untouched old-bad.md must not be flagged" "$W_OUT" || ok "wiring: untouched old-bad.md not flagged (backfill is another slice)"

    run2c bash DOC_RULES_LINT=off
    if [ "$W_RC" = 0 ]; then ok "wiring NEGATIVE CONTROL: DOC_RULES_LINT=off -> the same bad diff passes"; else bad "wiring negative control" "TEST_EXIT=$W_RC :: $W_OUT"; fi

    git -C "$WT" checkout -q -b feat2 refs/remotes/origin/main; GOOD_DOC > "$WT/new-good.md"; commit_all "$WT" "good doc"
    run2c bash X=1
    [ "$W_RC" = 0 ] && ok "wiring: changed good .md -> TEST_EXIT 0" || bad "wiring: good doc passes" "TEST_EXIT=$W_RC :: $W_OUT"
    run2c bash PRE_TEST_EXIT=1
    [ "$W_RC" = 1 ] && ok "wiring: a prior test failure is not reset to 0 by a passing lint" || bad "wiring: prior failure preserved" "TEST_EXIT=$W_RC"

    git -C "$WT" checkout -q -b feat3 refs/remotes/origin/main; printf 'more\n' >> "$WT/a.txt"; commit_all "$WT" "non-md change"
    run2c bash X=1
    [ "$W_RC" = 0 ] && ok "wiring: diff touching no .md passes (old-bad.md untouched)" || bad "wiring: non-md diff" "TEST_EXIT=$W_RC :: $W_OUT"

    mv "$CITY/scripts/doc-rules-lint.py" "$CITY/scripts/doc-rules-lint.py.off"
    run2c bash X=1
    if [ "$W_RC" = 0 ] && printf '%s\n' "$W_OUT" | grep -q 'NOTE'; then ok "wiring: lint script absent (pre-merge city) -> NOTE and skip, no block"; else bad "wiring: absent script is fail-soft" "TEST_EXIT=$W_RC :: $W_OUT"; fi
    mv "$CITY/scripts/doc-rules-lint.py.off" "$CITY/scripts/doc-rules-lint.py"

    git -C "$WT" update-ref -d refs/remotes/origin/main
    run2c bash X=1
    if [ "$W_RC" != "" ] && [ "$W_RC" != 0 ]; then ok "wiring: cannot determine the base (no origin/main) -> fails, not a silent pass"; else bad "wiring: unknown base must not pass" "TEST_EXIT=$W_RC :: $W_OUT"; fi
  fi
fi

echo
echo "doc-rules-lint selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
