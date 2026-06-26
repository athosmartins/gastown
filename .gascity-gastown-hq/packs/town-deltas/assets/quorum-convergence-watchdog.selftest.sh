#!/usr/bin/env bash
# quorum-convergence-watchdog.selftest.sh — hermetic unit tests for
# quorum-convergence-watchdog.py (ga-qw3p.3).
#
# Tests the Python logic via DRY_RUN=1 with environment stubs.
# Passes: prints "OK N/N" at the end. Fails: non-zero exit.
#
# Run: bash quorum-convergence-watchdog.selftest.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG="$SCRIPT_DIR/../../../scripts/quorum-convergence-watchdog.py"

if [ ! -f "$WATCHDOG" ]; then
    echo "FAIL: watchdog not found at $WATCHDOG"
    exit 1
fi

PASS=0
FAIL=0

check() {
    local name="$1" result="$2" expected="$3"
    if printf '%s' "$result" | grep -q "$expected"; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name"
        echo "    expected to contain: $expected"
        echo "    got: $result"
    fi
}

check_empty() {
    local name="$1" result="$2"
    if [ -z "$result" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name"
        echo "    expected empty result, got: $result"
    fi
}

check_absent() {
    local name="$1" result="$2" absent="$3"
    if ! printf '%s' "$result" | grep -q "$absent"; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name"
        echo "    expected NOT to contain: $absent"
        echo "    got: $result"
    fi
}

echo "=== quorum-convergence-watchdog selftest ==="
echo ""

# ── 1. Domain classification tests (inline Python) ───────────────────────────
echo "1. Domain classification"

classify() {
    python3 - "$1" "$2" <<'PY'
import sys, re
title, desc = sys.argv[1], sys.argv[2]
hay = (title + " " + desc).lower()
# WA integration FIRST (mirrors watchdog logic + pilot-dispatcher WA-INTEGRATION PRECEDENCE)
if re.search(r'pipedrive|whapi|whatsapp|painel|kanban|frota|canais|disparo|urblink|design.system', hay):
    if re.search(r'design.system|frontend|\bui\b', hay):
        print("frontend"); raise SystemExit(0)
    print("wa-integration"); raise SystemExit(0)
if re.search(r'warming|warm.?up|aquecimento|\bchip\b|ban.?prevention|on.?device', hay):
    print("warming"); raise SystemExit(0)
# property-scrapers BEFORE real-estate
if re.search(r'\bscraper\b|\bscrape\b|\bcnpj\b|\bcnae\b|\brbf\b|\bpbh\b|motherduck|hex notebook|pesquisa_mercado|proprietár', hay):
    print("property-scrapers"); raise SystemExit(0)
if re.search(r'arcgis|zoneamento|geo.?match|\bitbi\b|im[oó]ve|quarte[ií]r|terreno|cadastr', hay):
    print("real-estate"); raise SystemExit(0)
if re.search(r'financeiro|\bledger\b|enrichment|\bemail\b|mega.?data', hay):
    print("data"); raise SystemExit(0)
print("")
PY
}

check       "wa-integration: painel keyword"      "$(classify 'Novo painel Kanban' '')"           "wa-integration"
check       "warming: chip keyword"               "$(classify 'Warming: chip anti-ban' '')"       "warming"
check       "property-scrapers: scraper+imóveis"  "$(classify 'Scraper imóveis PBH' '')"          "property-scrapers"
check       "property-scrapers: CNPJ"             "$(classify 'Enriquecer CNPJ via RFB' '')"      "property-scrapers"
check       "real-estate: ITBI keyword"           "$(classify 'Indexar dados ITBI' '')"           "real-estate"
check       "real-estate: arcgis keyword"         "$(classify 'Rotas ArcGIS zoneamento' '')"      "real-estate"
check       "data: financeiro"                    "$(classify 'Ledger financeiro' '')"             "data"
check_empty "empty: generic/infra bead"           "$(classify 'Fix gate dispatcher' '')"

echo ""

# ── 2. Vote parsing tests ─────────────────────────────────────────────────────
echo "2. Vote parsing"

parse_vote() {
    python3 - <<PY
import re
text = """$1"""
m = re.search(r'^QUORUM_VOTE:\s*(.+)$', text, re.MULTILINE | re.IGNORECASE)
print(m.group(1).strip() if m else "")
PY
}

check       "parses simple vote"        "$(parse_vote 'QUORUM_VOTE: reclaim')"        "reclaim"
check       "parses reassign vote"      "$(parse_vote 'QUORUM_VOTE: reassign:mila-wa')" "reassign:mila-wa"
check       "case insensitive"          "$(parse_vote 'quorum_vote: reclaim')"         "reclaim"
check       "parses close with reason"  "$(parse_vote 'QUORUM_VOTE: close:invalid-story')" "close:invalid-story"
check       "multiline: vote in middle" "$(parse_vote 'some text
QUORUM_VOTE: needs-human
more text')" "needs-human"
check_empty "ignores non-vote lines"   "$(parse_vote 'I think we should just reclaim it')"

echo ""

# ── 3. Action validation tests ────────────────────────────────────────────────
echo "3. Action validation"

is_valid() {
    python3 - "$1" <<'PY'
import sys, re
action = sys.argv[1]
m = re.match(r'^(reclaim|reassign:[a-zA-Z0-9._-]+|needs-human|close:.+)$', action, re.IGNORECASE)
print("valid" if m else "invalid")
PY
}

check "reclaim is valid"              "$(is_valid 'reclaim')"              "valid"
check "needs-human is valid"          "$(is_valid 'needs-human')"          "valid"
check "reassign with crew is valid"   "$(is_valid 'reassign:mila-wa')"     "valid"
check "close with reason is valid"    "$(is_valid 'close:invalid-story')"  "valid"
check "empty string is invalid"       "$(is_valid '')"                     "invalid"
check "random text is invalid"        "$(is_valid 'do something')"         "invalid"
check "reassign without crew invalid" "$(is_valid 'reassign:')"            "invalid"

echo ""

# ── 4. Majority decision tests ────────────────────────────────────────────────
echo "4. Majority decision (2-of-3)"

decide() {
    python3 - "$1" <<'PY'
import sys, json
from collections import Counter
votes = json.loads(sys.argv[1])
counts = Counter(votes.values())
for action, count in counts.most_common(1):
    if count >= 2:
        print(action)
        raise SystemExit(0)
print("")
PY
}

check       "2-of-3 same → decided"    "$(decide '{"a":"reclaim","b":"reclaim","c":"needs-human"}')" "reclaim"
check       "3-of-3 same → decided"    "$(decide '{"a":"reclaim","b":"reclaim","c":"reclaim"}')"     "reclaim"
check       "2-of-2 → decided"         "$(decide '{"a":"reclaim","b":"reclaim"}')"                   "reclaim"
check_empty "1-of-3 → no decision"     "$(decide '{"a":"reclaim","b":"needs-human","c":"close:x"}')"
check_empty "all diverge → no decision" "$(decide '{"a":"reclaim","b":"needs-human","c":"close:x"}')"
check_empty "empty votes → no decision" "$(decide '{}')"

echo ""

# ── 5. DRY_RUN smoke test ─────────────────────────────────────────────────────
echo "5. DRY_RUN smoke test (imports + logic)"

smoke=$(QUORUM_DRY_RUN=1 QUORUM_WATCHDOG_ENABLED=0 GC_CITY_PATH=/tmp \
    python3 -c "
import sys, os, types
sys.path.insert(0, '$(dirname "$WATCHDOG")')
# Stub gc_ledger to avoid missing ledger dir.
mod = types.ModuleType('gc_ledger')
mod.gc_ledger_append = lambda *a, **kw: None
sys.modules['gc_ledger'] = mod
import importlib.util
spec = importlib.util.spec_from_file_location('qcw', '$(realpath "$WATCHDOG")')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Test domain classification.
assert m._classify_domain('painel Kanban') == 'wa-integration', 'classify wa-integration failed'
assert m._classify_domain('Scraper imóveis PBH') == 'property-scrapers', 'classify property-scrapers failed'
assert m._classify_domain('arcgis zoneamento') == 'real-estate', 'classify real-estate failed'
assert m._classify_domain('Fix gate dispatcher') == '', 'classify empty failed'

# Test _decide.
votes = {'a': 'reclaim', 'b': 'reclaim', 'c': 'needs-human'}
assert m._decide(votes) == 'reclaim', 'decide majority failed'
votes_diverged = {'a': 'reclaim', 'b': 'needs-human', 'c': 'close:x'}
assert m._decide(votes_diverged) is None, 'decide diverged failed'

# Test VALID_ACTION_RE.
assert m.VALID_ACTION_RE.match('reclaim'), 'regex reclaim failed'
assert m.VALID_ACTION_RE.match('reassign:mila-wa'), 'regex reassign failed'
assert m.VALID_ACTION_RE.match('needs-human'), 'regex needs-human failed'
assert m.VALID_ACTION_RE.match('close:some-reason'), 'regex close failed'
assert not m.VALID_ACTION_RE.match(''), 'regex empty should fail'
assert not m.VALID_ACTION_RE.match('reassign:'), 'regex reassign-empty should fail'

# Test VOTE_LINE_RE.
import re
text = 'Some context\nQUORUM_VOTE: reclaim\nMore text'
match = m.VOTE_LINE_RE.search(text)
assert match and match.group(1).strip() == 'reclaim', 'vote line re failed'

print('imports OK')
" 2>&1)

check       "DRY_RUN smoke: all assertions pass" "$smoke" "imports OK"
check_absent "DRY_RUN smoke: no traceback"       "$smoke" "Traceback"
check_absent "DRY_RUN smoke: no AssertionError"  "$smoke" "AssertionError"

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo "=== Results: $PASS/$TOTAL passed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "OK $PASS/$TOTAL"
exit 0
