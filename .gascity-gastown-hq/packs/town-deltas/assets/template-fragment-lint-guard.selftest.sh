#!/usr/bin/env bash
# template-fragment-lint-guard.selftest.sh — regression test for
# template-fragment-lint-guard.sh (ga-8fwusw).
#
# Proves, against a throwaway copy of the REAL town-deltas pack (never the
# live tree), that the guard:
#   1. exits 0 and skips gc lint entirely when no changed file matches a
#      template/fragment/pack.toml pattern;
#   2. exits 0 (gc lint passes) against the pack as it stands today;
#   3. exits 1, with gc lint's own diagnostic in the output, when the exact
#      historical bug is reintroduced: `{{rig_root}}` (Go template
#      function-call syntax) written inside a prose sentence instead of the
#      field form `{{ .RigRoot }}` used everywhere else in the file.
#
# Case 3 is the one that matters: it is a test that FAILS against the
# pre-a25cc3724 state (the regression this whole bead is about) and passes
# only because template-fragment-lint-guard.sh now exists and gc lint
# actually parses fragments before the gate can call tests green.
#
# ga-7x28kl added cases 4-12, for the known-artifact list. 4 is the only one
# that expects exit 0 on a lint failure; 5-12 are the ways that tolerance must
# NOT apply (a new error beside the known ones, the same message in another
# file, the same file with another message, unparseable / empty / miscounted
# / unexplained gc output). 4-7 run the real `gc lint` on a fixture pack;
# 8-12 use a stub `gc` so the report shape is exact. 12 also covers the
# stdout/stderr split (a loader warning on stderr must not break parsing).
#
# GUARD_UNDER_TEST overrides the guard script, to prove cases 4 and 12 FAIL
# against the pre-ga-7x28kl guard:
#   GUARD_UNDER_TEST=/path/to/old-guard.sh bash template-fragment-lint-guard.selftest.sh
#
# Run standalone: bash template-fragment-lint-guard.selftest.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GUARD_UNDER_TEST:-$SCRIPT_DIR/template-fragment-lint-guard.sh}"
LIVE_PACK="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

check_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  local desc="$1" haystack="$2" needle_re="$3"
  if printf '%s' "$haystack" | grep -E "$needle_re" >/dev/null; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (pattern '$needle_re' not found in output)"
    FAIL=$((FAIL + 1))
  fi
}

if ! command -v gc >/dev/null 2>&1; then
  echo "SKIP: 'gc' not on PATH -- cannot exercise gc lint in this environment."
  exit 0
fi

if [ ! -x "$GUARD" ] && [ ! -f "$GUARD" ]; then
  echo "FAIL: guard script not found at $GUARD"
  exit 1
fi

if [ ! -f "$LIVE_PACK/pack.toml" ]; then
  echo "FAIL: fixture source $LIVE_PACK/pack.toml not found -- cannot build fixture (is pack.toml tracked/present?)."
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -R "$LIVE_PACK" "$WORK/town-deltas"

FRAG="$WORK/town-deltas/template-fragments/town-deltas.template.md"
if [ ! -f "$FRAG" ]; then
  echo "FAIL: fixture fragment $FRAG missing after copy."
  exit 1
fi

# ── Case 1: irrelevant changed file -- guard must no-op (exit 0) without
# needing gc lint to run at all. ────────────────────────────────────────
set +e
OUT1=$(bash "$GUARD" "$WORK" "README.md" 2>&1)
EXIT1=$?
set -e
check_exit "irrelevant file -> exit 0, no-op" "0" "$EXIT1"
check_contains "irrelevant file -> no-op message" "$OUT1" "skipping gc lint"

# ── Case 2: fragment as shipped today must lint clean. ──────────────────
set +e
OUT2=$(bash "$GUARD" "$WORK" "town-deltas/template-fragments/town-deltas.template.md" "town-deltas/pack.toml" 2>&1)
EXIT2=$?
set -e
check_exit "current fragment lints clean -> exit 0" "0" "$EXIT2"

# ── Case 3: reintroduce the exact historical bug (ga-3v2n4's fix commit
# shipped it; fixed by a25cc3724). Anchor on the surrounding sentence so
# this fails LOUDLY, not silently, if that text is ever edited away. ────
ANCHOR="mesma técnica"
if ! grep -qF "$ANCHOR" "$FRAG"; then
  echo "FAIL: anchor text for the historical bug not found in $FRAG -- source text has changed, update this selftest's anchor."
  exit 1
fi

if ! python3 - "$FRAG" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = "'{{ .RigRoot }}'` + verificação pós-pour antes de assign/burn) já está"
new = "'{{rig_root}}'` + verificação pós-pour antes de assign/burn) já está"
if old not in text:
    sys.exit(1)
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY
then
  echo "FAIL: could not reintroduce the historical bug into the fixture (exact anchor text mismatch) -- selftest cannot proceed, update the anchor above."
  exit 1
fi

set +e
OUT3=$(bash "$GUARD" "$WORK" "town-deltas/template-fragments/town-deltas.template.md" 2>&1)
EXIT3=$?
set -e
check_exit "historical bug reintroduced -> exit 1" "1" "$EXIT3"
check_contains "historical bug -> gc lint's own diagnostic surfaces" "$OUT3" 'rig_root.*not defined'

# ── Cases 4-13 (ga-7x28kl): the known-artifact list. ────────────────────
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: 'jq' not on PATH -- cannot exercise the known-artifact cases (4-13)."
  echo
  echo "template-fragment-lint-guard.selftest.sh: $PASS passed, $FAIL failed (cases 4-13 SKIPPED)."
  [ "$FAIL" -eq 0 ]
  exit
fi

run_guard() {  # run_guard <args...> -> sets OUT, EXIT
  set +e
  OUT=$(bash "$GUARD" "$@" 2>&1)
  EXIT=$?
  set -e
}

# A pack that reproduces, with the real `gc lint`, the four diagnostics main
# carries today: same relative paths and the same messages (line/col differ).
make_hq_fixture() {
  local d="$1"
  mkdir -p "$d/.gascity-gastown-hq/agents/gate-reviewer" \
           "$d/.gascity-gastown-hq/agents/refino-gate-reviewer" \
           "$d/internal/templates/messages"
  printf '[pack]\nname = "fixture-hq"\nschema = 2\n' > "$d/pack.toml"
  printf '# Gate Reviewer\n\n{{ template "propulsion-dog" . }}\n' \
    > "$d/.gascity-gastown-hq/agents/gate-reviewer/prompt.template.md"
  printf '# Refino Gate Reviewer\n\n{{ template "propulsion-dog" . }}\n' \
    > "$d/.gascity-gastown-hq/agents/refino-gate-reviewer/prompt.template.md"
  printf '{{ range .Suggestions }}\n- {{ . }}\n{{ end }}\n' \
    > "$d/internal/templates/messages/escalation.md.tmpl"
  printf '{{ range $i, $step := .NextSteps }}\n{{ $i }}. {{ $step }}\n{{ end }}\n' \
    > "$d/internal/templates/messages/handoff.md.tmpl"
}
CHANGED_PROMPT=".gascity-gastown-hq/agents/gate-reviewer/prompt.template.md"

# ── Case 4: only the four known artifacts -> exit 0, and they are SHOWN. ─
make_hq_fixture "$WORK/fx4"
run_guard "$WORK/fx4" "$CHANGED_PROMPT"
check_exit "only the 4 known artifacts -> exit 0" "0" "$EXIT"
check_contains "known artifacts are printed as tolerated, not hidden" "$OUT" 'tolerated \(known lint-context artifact'

# ── Case 5: a NEW error next to the known four -> exit 1 and it is named. ─
make_hq_fixture "$WORK/fx5"
mkdir -p "$WORK/fx5/.gascity-gastown-hq/agents/newbie"
printf 'prose with {{rig_root}} in it\n' > "$WORK/fx5/.gascity-gastown-hq/agents/newbie/prompt.template.md"
run_guard "$WORK/fx5" "$CHANGED_PROMPT" ".gascity-gastown-hq/agents/newbie/prompt.template.md"
check_exit "known four + a new error -> exit 1" "1" "$EXIT"
check_contains "the new error is flagged NEW, with its file" "$OUT" 'NEW \(not on the known list\): \.gascity-gastown-hq/agents/newbie/prompt\.template\.md'

# ── Case 6: the SAME message in a file that is not on the list -> exit 1.
# The list is path-bound on purpose: a new agent prompt that calls a
# system-pack fragment must be added deliberately. ───────────────────────
make_hq_fixture "$WORK/fx6"
mkdir -p "$WORK/fx6/.gascity-gastown-hq/agents/newbie"
printf '{{ template "propulsion-dog" . }}\n' > "$WORK/fx6/.gascity-gastown-hq/agents/newbie/prompt.template.md"
run_guard "$WORK/fx6" "$CHANGED_PROMPT" ".gascity-gastown-hq/agents/newbie/prompt.template.md"
check_exit "known message in an unlisted file -> exit 1" "1" "$EXIT"
check_contains "unlisted file is flagged NEW" "$OUT" 'NEW \(not on the known list\): \.gascity-gastown-hq/agents/newbie/'

# ── Case 7: a listed file, but a DIFFERENT message -> exit 1. ────────────
make_hq_fixture "$WORK/fx7"
printf '{{ range .Suggestionz }}\n- {{ . }}\n{{ end }}\n' > "$WORK/fx7/internal/templates/messages/escalation.md.tmpl"
run_guard "$WORK/fx7" "$CHANGED_PROMPT"
check_exit "listed file with a different message -> exit 1" "1" "$EXIT"
check_contains "changed message is flagged NEW" "$OUT" 'NEW \(not on the known list\): internal/templates/messages/escalation\.md\.tmpl'

# Stub `gc`: prints $STUB_GC_JSON_FILE on stdout, $STUB_GC_STDERR on stderr,
# exits $STUB_GC_EXIT. Lets cases 8-12 control the report shape exactly.
mkdir -p "$WORK/stub" "$WORK/stubpack"
printf '[pack]\nname = "stubpack"\nschema = 2\n' > "$WORK/stubpack/pack.toml"
cat > "$WORK/stub/gc" <<'STUB'
#!/bin/bash
[ -n "${STUB_GC_STDERR:-}" ] && echo "$STUB_GC_STDERR" >&2
[ -n "${STUB_GC_JSON_FILE:-}" ] && cat "$STUB_GC_JSON_FILE"
exit "${STUB_GC_EXIT:-1}"
STUB
chmod +x "$WORK/stub/gc"

cat > "$WORK/known4.json" <<'JSON'
{"schema_version":"2","ok":true,"passed":false,"error_count":4,"packs":[{"path":"/p","name":"p","ok":false,"diagnostics":[
 {"severity":"error","path":"/p/.gascity-gastown-hq/agents/gate-reviewer/prompt.template.md","line":5,"message":"template: prompt:5:12: executing \"prompt\" at <{{template \"propulsion-dog\" .}}>: template \"propulsion-dog\" not defined"},
 {"severity":"error","path":"/p/.gascity-gastown-hq/agents/refino-gate-reviewer/prompt.template.md","line":5,"message":"template: prompt:5:12: executing \"prompt\" at <{{template \"propulsion-dog\" .}}>: template \"propulsion-dog\" not defined"},
 {"severity":"error","path":"/p/internal/templates/messages/escalation.md.tmpl","line":16,"message":"template: prompt:16:9: executing \"prompt\" at <.Suggestions>: range can't iterate over"},
 {"severity":"error","path":"/p/internal/templates/messages/handoff.md.tmpl","line":20,"message":"template: prompt:20:22: executing \"prompt\" at <.NextSteps>: range can't iterate over"}
]}]}
JSON

run_stub() {  # run_stub <json-file-or-empty> <exit> [stderr-text]
  set +e
  OUT=$(STUB_GC_JSON_FILE="$1" STUB_GC_EXIT="$2" STUB_GC_STDERR="${3:-}" PATH="$WORK/stub:$PATH" \
        bash "$GUARD" "$WORK/stubpack" "x.template.md" 2>&1)
  EXIT=$?
  set -e
}

# ── Case 8: stdout is not JSON -> exit 1 ("could not tell" is not "ok"). ─
printf 'this is not json at all\n' > "$WORK/garbage.txt"
run_stub "$WORK/garbage.txt" 1
check_exit "unparseable gc output -> exit 1" "1" "$EXIT"
check_contains "unparseable output is named as the reason" "$OUT" 'not tolerated: gc lint output is empty or not parseable'

# ── Case 9: gc fails with NO output at all -> exit 1 (jq passes empty
# input with exit 0 and no output; that must not read as tolerable). ─────
run_stub "" 1
check_exit "empty gc output with a failing exit -> exit 1" "1" "$EXIT"

# ── Case 10: declared error_count disagrees with the diagnostics found. ──
jq '.error_count = 5' "$WORK/known4.json" > "$WORK/count-mismatch.json"
run_stub "$WORK/count-mismatch.json" 1
check_exit "error_count does not match diagnostics -> exit 1" "1" "$EXIT"
check_contains "mismatch is named as the reason" "$OUT" 'declared error_count=5, error diagnostics found=4'

# ── Case 11: a pack reports ok:false with no error diagnostic at all. ────
printf '{"ok":true,"passed":false,"error_count":0,"packs":[{"path":"/p","name":"p","ok":false}]}\n' > "$WORK/silent.json"
run_stub "$WORK/silent.json" 1
check_exit "pack ok:false with nothing to explain it -> exit 1" "1" "$EXIT"

# ── Case 12: the four known artifacts plus a loader WARNING on stderr ->
# exit 0. Merging stderr into the JSON (the pre-ga-7x28kl 2>&1) breaks the
# parse, so the known list could never apply. ────────────────────────────
run_stub "$WORK/known4.json" 1 "warning: builtin pack \"gastown\" on disk differs from the embedded copy"
check_exit "known four + stderr warning -> exit 0" "0" "$EXIT"

# ── Case 13: jq absent from PATH -> exit 1, never a silent pass. ─────────
NOJQ="$WORK/nojq"
mkdir -p "$NOJQ"
for t in grep dirname mktemp sort rm cat sed basename; do
  for dir in /usr/bin /bin; do
    if [ -x "$dir/$t" ]; then ln -s "$dir/$t" "$NOJQ/$t"; break; fi
  done
done
ln -s "$WORK/stub/gc" "$NOJQ/gc"
if PATH="$NOJQ" command -v jq >/dev/null 2>&1; then
  echo "FAIL: case 13 fixture is broken -- jq is still resolvable on the restricted PATH."
  FAIL=$((FAIL + 1))
else
  set +e
  OUT=$(STUB_GC_JSON_FILE="$WORK/known4.json" STUB_GC_EXIT=1 PATH="$NOJQ" /bin/bash "$GUARD" "$WORK/stubpack" "x.template.md" 2>&1)
  EXIT=$?
  set -e
  check_exit "jq missing -> exit 1" "1" "$EXIT"
  check_contains "missing jq is named as the reason" "$OUT" 'not tolerated: jq not on PATH'
fi

echo
echo "template-fragment-lint-guard.selftest.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
