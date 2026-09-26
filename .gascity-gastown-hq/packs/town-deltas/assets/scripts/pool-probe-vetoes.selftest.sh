#!/usr/bin/env bash
# pool-probe-vetoes.selftest.sh — ga-aijm2v.5 (gate round 3, blocking 2).
#
# Proves the shared veto lists are READ from the probes they claim to mirror, not asserted, and that
# the jq the two consumers share behaves. Needs only bash, jq, python3. Exit 0 iff every check holds.
#   * the wa/ps lists are compared with the TRACKED agents/{wa-worker,ps-worker}/prompt.template.md;
#   * the dog list is compared with the live `gc` binary's embedded probe when it is readable
#     (a SKIP is printed and NOT counted as a pass when it is not);
#   * the derived intersection is pinned to the literal nudge-on-route-gated.sh used before this lib.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${PPV_LIB_UNDER_TEST:-$SELF_DIR/pool-probe-vetoes.sh}"      # override = mutation checks
AGENTS_DIR="${PPV_AGENTS_DIR:-$SELF_DIR/../../../../agents}"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
skip() { echo "  ~ SKIP: $*"; SKIP=$((SKIP+1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }

echo "== 1. sourcing the lib has no side effect and survives set -euo pipefail (the dispatcher sources it)"
OUT="$(bash -c 'set -euo pipefail; source "$1"; source "$1"; echo REACHED' _ "$LIB" 2>&1)"
eq "sourced twice under set -euo pipefail: prints only REACHED" "$OUT" "REACHED"
# shellcheck disable=SC1090
source "$LIB"
for v in POOL_VETO_EXACT_DOG POOL_VETO_EXACT_WA POOL_VETO_PREFIX_DOG POOL_VETO_PREFIX_WA POOL_VETO_JQ_DEFS; do
  if [ -n "${!v:-}" ]; then ok "$v is defined"; else bad "$v is empty"; fi
done
for v in POOL_VETO_EXACT_DOG POOL_VETO_EXACT_WA POOL_VETO_PREFIX_DOG POOL_VETO_PREFIX_WA; do
  if printf '%s' "${!v}" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then ok "$v is a JSON array of strings"; else bad "$v is not a JSON array of strings"; fi
done

echo "== 2. the wa/ps snapshots equal what the TRACKED worker prompts actually exclude"
tmpl_lists() { # <template> -> prints: exact-labels-json, prefix-json, next-action(true/false), each on one line
  python3 - "$1" <<'PY'
import json, re, sys
t = open(sys.argv[1], encoding="utf-8").read()
exact = sorted(set(re.findall(r'--exclude-label\s+"([^"]+)"', t)))
# startswith("x") families that are VETOES. pilot:held* is the expiring hold (code, pool_held) and
# pilot:reclaim-count: is a SORT key in these probes — neither belongs in the veto prefix list.
pref = sorted(p for p in set(re.findall(r'startswith\("([^"]+)"\)', t))
              if p not in ("pilot:held", "pilot:held-until:", "pilot:reclaim-count:"))
na = 'test("^next-action:") and (test("(constroi|corrige-gate|corrige)$") | not)' in t
print(json.dumps(exact)); print(json.dumps(pref)); print("true" if na else "false")
PY
}
for w in wa-worker ps-worker; do
  f="$AGENTS_DIR/$w/prompt.template.md"
  if [ ! -r "$f" ]; then bad "$w template not readable at $f"; continue; fi
  { read -r ex; read -r px; read -r na; } < <(tmpl_lists "$f")
  eq "$w: exact exclude-labels == POOL_VETO_EXACT_WA" "$(printf '%s' "$ex" | jq -c 'sort')" "$(printf '%s' "$POOL_VETO_EXACT_WA" | jq -c 'sort')"
  eq "$w: veto prefixes == POOL_VETO_PREFIX_WA" "$(printf '%s' "$px" | jq -c 'sort')" "$(printf '%s' "$POOL_VETO_PREFIX_WA" | jq -c 'sort')"
  eq "$w: next-action class == POOL_VETO_NEXT_ACTION_WA" "$na" "$POOL_VETO_NEXT_ACTION_WA"
done

echo "== 3. the dog snapshot equals the live gc binary's embedded probe (when readable)"
GCBIN="$(readlink -f "$(command -v gc 2>/dev/null)" 2>/dev/null || true)"
if [ -n "$GCBIN" ] && [ -r "$GCBIN" ] && command -v strings >/dev/null 2>&1; then
  BIN_EXACT="$(strings -a "$GCBIN" | grep -o -- '--exclude-label "[^"]*"' | sed 's/--exclude-label "//; s/"$//' | sort -u | jq -R . | jq -sc .)"
  if [ "$BIN_EXACT" = "[]" ]; then skip "no --exclude-label strings found in $GCBIN (stripped or different build) — dog snapshot NOT cross-checked"
  else eq "live gc's exclude-label set == POOL_VETO_EXACT_DOG" "$BIN_EXACT" "$(printf '%s' "$POOL_VETO_EXACT_DOG" | jq -c 'sort')"; fi
  NA_IN_BIN="$(strings -a "$GCBIN" | grep -c 'test("^next-action:")' || true)"
  if [ "$NA_IN_BIN" -gt 0 ]; then NA_BIN=true; else NA_BIN=false; fi
  eq "live gc has the next-action class iff POOL_VETO_NEXT_ACTION_DOG" "$NA_BIN" "$POOL_VETO_NEXT_ACTION_DOG"
else
  skip "gc binary not readable here — dog snapshot NOT cross-checked (re-check on the next engine window)"
fi

echo "== 4. derived configs: the intersection is pinned to the literal the route script used before this lib"
OLD_GNR='["auto-refino:escalated","auto-refino:refining","ctx:thin","exec:manual","gate:queued","gate:reviewing","needs-human","needs-human-decision","needs:engine-window","on-device","phone-proxy","pilot:no-auto-dispatch","refino:info-gap","refino:policy-gap","story:blocked","story:epic","story:needs-approval","story:needs-device","story:needs-human","story:refinement-in-progress","story:refino-escalado","story:refino-review","story:unrefined"]'
ALL="$(pool_veto_cfg all)"; ANY="$(pool_veto_cfg any)"
eq "all.exact == old GNR_NOT_READY_LABELS (regression pin, 23 labels)" "$(printf '%s' "$ALL" | jq -c '.exact | sort')" "$(printf '%s' "$OLD_GNR" | jq -c 'sort')"
eq "any.exact is the UNION (23 common + delivery:partial + scope:needs-review + delivery:pending-restart)" "$(printf '%s' "$ANY" | jq -c '.exact | length')" "26"
eq "any.exact carries a label only the DOG refuses" "$(printf '%s' "$ANY" | jq -r '.exact | index("delivery:partial") != null')" "true"
eq "any.exact carries a label only wa/ps refuse" "$(printf '%s' "$ANY" | jq -r '.exact | index("delivery:pending-restart") != null')" "true"
eq "all.exact does NOT carry either (one pool alone must not suppress a wake)" "$(printf '%s' "$ALL" | jq -r '(.exact | index("delivery:partial")) == null and (.exact | index("delivery:pending-restart")) == null')" "true"
eq "any.prefix is the union (6)" "$(printf '%s' "$ANY" | jq -c '.prefix | length')" "6"
eq "all.prefix is the intersection (5: no blocked-reason:)" "$(printf '%s' "$ALL" | jq -c '.prefix | length')" "5"
eq "next_action: any=or, all=and" "$(printf '%s' "$ANY" | jq -r '.next_action'):$(printf '%s' "$ALL" | jq -r '.next_action')" "true:false"
OUT="$(pool_veto_cfg bogus)"; rc=$?
eq "an unknown mode yields NOTHING and rc != 0 (never an empty config that reads as 'no vetoes')" "$rc:${OUT:-<empty>}" "5:<empty>"

echo "== 5. pool_veto_reasons — what refuses a bead, per pool_veto_cfg any"
NOW=1790400000
reasons() { # <bead json> [cfg-mode] -> comma-joined reasons ('-' when none)
  local cfg; cfg="$(pool_veto_cfg "${2:-any}")"
  printf '%s' "$1" | jq -r --argjson now "$NOW" --argjson cfg "$cfg" "$POOL_VETO_JQ_DEFS"' pool_veto_reasons($now; $cfg) | if length == 0 then "-" else join(",") end'
}
# this very bead's real label set: the state a gate-FAILED source bead is in, and it MUST stay poolable
REAL='{"id":"ga-x","status":"open","title":"Camada 1 da portaria","labels":["ctx:ready","exec:auto","framework","gate-sha-failed:2ba4a0deb:code","gate:failed","gate:fix-attempt:2","gate:needs-fix","lane:small"]}'
eq "a plain gate-FAILED bead (gate:needs-fix, gate:failed, gate-sha-failed:*) is NOT vetoed" "$(reasons "$REAL")" "-"
eq "no labels at all is not vetoed" "$(reasons '{"id":"x","status":"open"}')" "-"
eq "pilot:no-auto-dispatch" "$(reasons '{"labels":["gate:needs-fix","pilot:no-auto-dispatch"]}')" "label:pilot:no-auto-dispatch"
eq "needs-human" "$(reasons '{"labels":["needs-human"]}')" "label:needs-human"
eq "pool:refused:<reason> (prefix family)" "$(reasons '{"labels":["pool:refused:engine-rebuild-required"]}')" "prefix:pool:refused:engine-rebuild-required"
eq "blocked-reason:<slug> (hyphen family — only the dog lists it, still a veto for 'any')" "$(reasons '{"labels":["blocked-reason:decision"]}')" "prefix:blocked-reason:decision"
eq "blocked-reason:<slug> is NOT in the intersection (wa/ps do not refuse it)" "$(reasons '{"labels":["blocked-reason:decision"]}' all)" "-"
eq "gate:needs-human:<x> (prefix family)" "$(reasons '{"labels":["gate:needs-human:sibling-race"]}')" "prefix:gate:needs-human:sibling-race"
eq "pilot:refused-reason:<x>" "$(reasons '{"labels":["pilot:refused-reason:x"]}')" "prefix:pilot:refused-reason:x"
eq "pilot:text-veto:<x>" "$(reasons '{"labels":["pilot:text-veto:engine"]}')" "prefix:pilot:text-veto:engine"
eq "delivery:partial (dog-only exact)" "$(reasons '{"labels":["delivery:partial"]}')" "label:delivery:partial"
eq "delivery:pending-restart (wa/ps-only exact)" "$(reasons '{"labels":["delivery:pending-restart"]}')" "label:delivery:pending-restart"
eq "next-action:mayor is a veto" "$(reasons '{"labels":["next-action:mayor"]}')" "next-action:mayor"
eq "next-action:athos+oracle is a veto" "$(reasons '{"labels":["next-action:athos+oracle"]}')" "next-action:athos+oracle"
eq "next-action:<crew>-constroi is refino's ROUTING suffix, not a veto" "$(reasons '{"labels":["next-action:batista-constroi"]}')" "-"
eq "next-action:<crew>-corrige-gate is not a veto" "$(reasons '{"labels":["next-action:peter-corrige-gate"]}')" "-"
eq "issue_type epic" "$(reasons '{"issue_type":"epic","labels":[]}')" "type:epic"
eq "title EPIC: (case-insensitive)" "$(reasons '{"title":"epic: migrar tudo","labels":[]}')" "title:epic"
eq "title ÉPICO: " "$(reasons '{"title":"ÉPICO: v55","labels":[]}')" "title:epic"
eq "a title that merely CONTAINS epic is not a veto" "$(reasons '{"title":"fix the epicenter map","labels":[]}')" "-"
eq "pilot:held (bare) is a hold" "$(reasons '{"labels":["pilot:held"]}')" "held"
eq "pilot:held-until in the FUTURE is a hold" "$(reasons "{\"labels\":[\"pilot:held-until:$((NOW+600))\"]}")" "held"
eq "pilot:held-until in the PAST released the hold" "$(reasons "{\"labels\":[\"pilot:held-until:$((NOW-600))\"]}")" "-"
eq "pilot:held-until with no parseable deadline is a hold" "$(reasons '{"labels":["pilot:held-until:soon"]}')" "held"
eq "several vetoes are all listed" "$(reasons '{"labels":["needs-human","exec:manual"]}')" "label:needs-human,label:exec:manual"
eq "pilot:reclaim-count:<n> (a SORT key in the probes) is not a veto" "$(reasons '{"labels":["pilot:reclaim-count:2"]}')" "-"

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
