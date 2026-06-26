#!/usr/bin/env bash
# escalation-router.selftest.sh — prove escalation-router.sh (ga-qw3p.1) in isolation.
#
# Sources the router in library mode (--lib) so the REAL functions are tested —
# one source of truth, no copy-drift. Zero live Dolt / gc / network access.
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER="$SELF_DIR/escalation-router.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label (=$got)"
  else bad "$label: expected [$want], got [$got]"
  fi
}

# ── Load REAL functions in library mode ──────────────────────────────────────
source "$ROUTER" --lib \
  || { echo "FATAL: could not source escalation-router.sh in lib mode"; exit 1; }

for fn in escalation_classify_topic escalation_topic_to_crew escalation_route; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined"; exit 1; }
done

# ── 1. escalation_classify_topic — pure text classification ─────────────────
echo "── 1. escalation_classify_topic ──"
eq "empty text → no topic"    "$(escalation_classify_topic "")"                      ""
eq "random text → no topic"   "$(escalation_classify_topic "o servidor caiu")"       ""

# warming signals
eq "warming keyword"          "$(escalation_classify_topic "chip warming issue")"    "warming"
eq "warm-up hyphen"           "$(escalation_classify_topic "warm-up failure")"       "warming"
eq "aquecimento"              "$(escalation_classify_topic "aquecimento de chip")"   "warming"
eq "ban-prevention"           "$(escalation_classify_topic "ban-prevention rate")"   "warming"
eq "on-device send"           "$(escalation_classify_topic "on-device send failing")" "warming"

# phone-proxy signals
eq "phone-proxy"              "$(escalation_classify_topic "phone-proxy pool")"      "phone-proxy"
eq "WAP uppercase"            "$(escalation_classify_topic "WAP slot exhausted")"    "phone-proxy"
eq "IP pool"                  "$(escalation_classify_topic "IP pool saturated")"     "phone-proxy"
eq "relay-server"             "$(escalation_classify_topic "relay-server down")"     "phone-proxy"

# wa-integration signals
eq "painel"                   "$(escalation_classify_topic "painel.urblink error")"  "wa"
eq "kanban"                   "$(escalation_classify_topic "kanban column broken")"  "wa"
eq "pipedrive"                "$(escalation_classify_topic "pipedrive sync failing")" "wa"
eq "whapi"                    "$(escalation_classify_topic "whapi 429 rate limit")"  "wa"
eq "whatsapp"                 "$(escalation_classify_topic "whatsapp delivery fail")" "wa"
eq "urblink_design_system"    "$(escalation_classify_topic "urblink_design_system")" "wa"
eq "drive bridge"             "$(escalation_classify_topic "drive bridge trigger")"  "wa"

# geo signals
eq "arcgis"                   "$(escalation_classify_topic "ArcGIS layer missing")"  "geo"
eq "zoneamento"               "$(escalation_classify_topic "zoneamento error")"      "geo"
eq "geocod"                   "$(escalation_classify_topic "geocodificação falhou")"  "geo"
eq "incorporação"             "$(escalation_classify_topic "incorporação query")"    "geo"
eq "centroid"                 "$(escalation_classify_topic "centroid calculation")"  "geo"

# property-scraper signals
eq "scraper"                  "$(escalation_classify_topic "scraper timeout")"       "property"
eq "ITBI"                     "$(escalation_classify_topic "ITBI fetch failed")"     "property"
eq "CNPJ"                     "$(escalation_classify_topic "CNPJ lookup error")"     "property"
eq "motherduck"               "$(escalation_classify_topic "motherduck timeout")"    "property"
eq "cadastro"                 "$(escalation_classify_topic "cadastro query hung")"   "property"
eq "terreno"                  "$(escalation_classify_topic "terreno lookup")"        "property"
eq "RFB"                      "$(escalation_classify_topic "RFB crawl blocked")"     "property"

# infra signals
eq "gate"                     "$(escalation_classify_topic "gate dispatcher hung")"  "infra"
eq "dolt"                     "$(escalation_classify_topic "dolt timeout")"          "infra"
eq "supervisor"               "$(escalation_classify_topic "supervisor crash-loop")" "infra"
eq "refino"                   "$(escalation_classify_topic "refino gate stalled")"   "infra"
eq "plist"                    "$(escalation_classify_topic "plist reload failed")"   "infra"

# precedence: warming beats wa (WA stack is used for warming but topic is warming)
eq "warming beats wa"         "$(escalation_classify_topic "chip warming whatsapp")" "warming"
# wa beats geo (WA painel mentions ArcGIS data layer)
eq "wa beats geo"             "$(escalation_classify_topic "painel arcgis layer")"   "wa"
# wa beats property (painel mentions ITBI)
eq "wa beats property"        "$(escalation_classify_topic "painel ITBI filter")"    "wa"

# ── 2. escalation_topic_to_crew — routing map ────────────────────────────────
echo ""
echo "── 2. escalation_topic_to_crew (default map) ──"
eq "property → batista-ps"   "$(escalation_topic_to_crew property)"    "batista-ps"
eq "wa → mila-wa"            "$(escalation_topic_to_crew wa)"           "mila-wa"
eq "warming → oracle-wa"     "$(escalation_topic_to_crew warming)"      "oracle-wa"
eq "phone-proxy → digo-wa"   "$(escalation_topic_to_crew phone-proxy)"  "digo-wa"
eq "geo → peter-wa"          "$(escalation_topic_to_crew geo)"          "peter-wa"
eq "infra → mayor"           "$(escalation_topic_to_crew infra)"        "mayor"
eq "no topic → mayor"        "$(escalation_topic_to_crew '')"           "mayor"
eq "unknown → mayor"         "$(escalation_topic_to_crew unknown)"      "mayor"

echo ""
echo "── 2b. escalation_topic_to_crew (env overrides) ──"
got=$(ESCALATION_PROPERTY_CREW=custom-crew escalation_topic_to_crew property)
eq "override property crew" "$got" "custom-crew"
got=$(ESCALATION_FALLBACK_CREW=my-mayor   escalation_topic_to_crew '')
eq "override fallback crew" "$got" "my-mayor"

# ── 3. escalation_route — dry-run end-to-end ─────────────────────────────────
echo ""
echo "── 3. escalation_route dry-run (DRY_RUN=1, gc not called) ──"

# Stub gc to detect any accidental live call in dry-run mode
gc() { echo "STUB_GC_CALLED"; return 99; }

DRY_RUN=1

result=$(escalation_route "chip warming failed" "oracle socket hung" 2>/dev/null)
eq "warming → oracle-wa" "$result" "ROUTED:warming:oracle-wa"

result=$(escalation_route "scraper timeout on motherduck" "ITBI fetch error" 2>/dev/null)
eq "property → batista-ps" "$result" "ROUTED:property:batista-ps"

result=$(escalation_route "painel kanban filter broken" "column disappeared" 2>/dev/null)
eq "wa → mila-wa" "$result" "ROUTED:wa:mila-wa"

result=$(escalation_route "phone-proxy pool saturated" "no relay slots" 2>/dev/null)
eq "phone-proxy → digo-wa" "$result" "ROUTED:phone-proxy:digo-wa"

result=$(escalation_route "ArcGIS layer missing" "zoneamento query" 2>/dev/null)
eq "geo → peter-wa" "$result" "ROUTED:geo:peter-wa"

result=$(escalation_route "gate dispatcher hung" "refino stalled" 2>/dev/null)
eq "infra → mayor" "$result" "ROUTED:infra:mayor"

result=$(escalation_route "daemon restart needed" "unknown failure" 2>/dev/null)
eq "no-topic → mayor fallback" "$result" "ROUTED:none:mayor"

result=$(escalation_route "chip problem" "body" "property" 2>/dev/null)
eq "explicit topic override ignores text" "$result" "ROUTED:property:batista-ps"

DRY_RUN=0

# ── 4. file structure guards ─────────────────────────────────────────────────
echo ""
echo "── 4. file structure ──"
[ -f "$ROUTER" ]                              && ok "router file exists"          || bad "router missing: $ROUTER"
grep -q 'escalation_classify_topic'  "$ROUTER" && ok "classify fn defined"         || bad "classify fn missing"
grep -q 'escalation_topic_to_crew'   "$ROUTER" && ok "map fn defined"              || bad "map fn missing"
grep -q 'escalation_route'           "$ROUTER" && ok "route fn defined"            || bad "route fn missing"
grep -q '\-\-lib'                    "$ROUTER" && ok "lib-mode guard present"      || bad "lib-mode guard missing"
grep -q 'ESCALATION_FALLBACK_CREW'   "$ROUTER" && ok "fallback env var present"    || bad "fallback env var missing"
grep -q 'DRY_RUN'                    "$ROUTER" && ok "dry-run env var present"     || bad "dry-run env var missing"
grep -q 'batista-ps'                 "$ROUTER" && ok "property crew wired"         || bad "property crew missing"
grep -q 'mila-wa'                    "$ROUTER" && ok "wa crew wired"               || bad "wa crew missing"
grep -q 'oracle-wa'                  "$ROUTER" && ok "warming crew wired"          || bad "warming crew missing"
grep -q 'digo-wa'                    "$ROUTER" && ok "phone crew wired"            || bad "phone crew missing"
grep -q 'peter-wa'                   "$ROUTER" && ok "geo crew wired"              || bad "geo crew missing"

# ── result ────────────────────────────────────────────────────────────────────
echo ""
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
