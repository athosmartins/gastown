#!/usr/bin/env bash
# escalation-router.sh — topic-based escalation routing for Gas Town (ga-qw3p.1).
#
# WHY: every daemon that hits a blocker today hard-codes `gc mail send mayor`.
# The Mayor becomes the single inbox for ALL escalations — property-data issues,
# WA painel bugs, warming-chip problems — even though each domain has an expert
# crew (batista-ps, mila-wa, oracle-wa, …) who can resolve it faster and without
# blocking the Mayor's attention.
#
# WHAT (Layer 1 of 4 — ga-qw3p):
# Classify the escalation's TOPIC from the combined subject+body text, then route
# to the DOMAIN OWNER. Fall back to Mayor for unrecognised topics (zero regression
# — every caller that hard-codes `gc mail send mayor` still works if it skips this
# router entirely; the router only ADDS faster routes).
#
# Topic → crew map (Mayor's proposal, 2026-06-23, story:approved):
#   property    → batista-ps      (scrapers/ITBI/CNPJ/cadastro/RFB/PBH)
#   wa          → mila-wa         (painel/kanban/pipedrive/whapi/WA integration)
#   warming     → oracle-wa       (chip warming / on-device / ban-prevention)
#   phone-proxy → digo-wa         (phone-proxy / WAP / IP pool / relay)
#   geo         → peter-wa        (ArcGIS / zoneamento / geocod / incorporação)
#   infra       → mayor           (gate / refino / dolt / framework / supervisor)
#   (no match)  → mayor           (fallback — zero regression)
#
# USAGE (standalone CLI):
#   escalation-router.sh -s "Subject" -m "Body"
#   escalation-router.sh -s "Subject" -m "Body" --topic property   # explicit override
#   DRY_RUN=1 escalation-router.sh -s "test" -m "body"            # prints target, no mail
#
# USAGE (library — source from another daemon):
#   source /path/to/escalation-router.sh --lib
#   topic=$(escalation_classify_topic "$subject $body")
#   crew=$(escalation_topic_to_crew "$topic")
#   gc mail send "$crew" -s "$subject" -m "$body"
#
# CONFIGURATION (all env-overridable):
#   ESCALATION_CITY            city path (default: $GC_CITY)
#   ESCALATION_PROPERTY_CREW   default batista-ps
#   ESCALATION_WA_CREW         default mila-wa
#   ESCALATION_WARMING_CREW    default oracle-wa
#   ESCALATION_PHONE_CREW      default digo-wa
#   ESCALATION_GEO_CREW        default peter-wa
#   ESCALATION_INFRA_CREW      default mayor
#   ESCALATION_FALLBACK_CREW   default mayor
#   DRY_RUN                    1 = classify + log, no mail (default 0)
#
# RIG-ORIGIN ROUTING (secondary signal, used when content classification returns ""):
#   Pass --rig <rig-name> (CLI) or escalation_route subject body "" rig (library).
#   Rig patterns: wa-* → wa | property-*/ps-* → property | geo-* → geo |
#                 phone-*/proxy-* → phone-proxy | oracle-*/warming-* → warming |
#                 gastown/gascity → infra | unknown/missing → fallback to content
#
# LOGGING: appends to $GC_CITY/.gc/logs/escalation-router.jsonl

set -uo pipefail

# ── config ────────────────────────────────────────────────────────────────────
CITY="${ESCALATION_CITY:-${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}}"
LOG_DIR="$CITY/.gc/logs"
JSONL="$LOG_DIR/escalation-router.jsonl"
DRY_RUN="${DRY_RUN:-0}"


# ── library guard ─────────────────────────────────────────────────────────────
# When sourced with --lib, only define functions; skip CLI main().
_ESCALATION_LIB_ONLY=0
if [ "${1:-}" = "--lib" ]; then _ESCALATION_LIB_ONLY=1; fi

# ── logging ───────────────────────────────────────────────────────────────────
_er_log() {
  local level="$1" msg="$2" ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >&2
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '{"ts":"%s","level":"%s","msg":%s}\n' "$ts" "$level" \
    "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$msg")" \
    >> "$JSONL" 2>/dev/null || true
}

# ── escalation_classify_rig_origin <rig> ─────────────────────────────────────
# Secondary routing signal: map the caller's rig name to a topic.
# Story spec (ga-qw3p.1): "reusa a classificação que o Pilot já tem
#   (conteúdo + rig de origem)" — this is the rig-de-origem part.
# Used as a fallback when content classification returns "".
# Prints one of: warming, phone-proxy, wa, geo, property, infra, ""
escalation_classify_rig_origin() {
  local rig="${1:-}"
  [ -z "$rig" ] && { echo ""; return 0; }
  case "$rig" in
    wa-*|wa_*|whatsapp*)        echo "wa"           ;;
    property-*|ps-*|scrapers*)  echo "property"     ;;
    geo-*|arcgis-*)             echo "geo"           ;;
    phone-*|proxy-*|wap-*)      echo "phone-proxy"   ;;
    oracle-*|warming-*)         echo "warming"       ;;
    gastown|gascity)            echo "infra"         ;;
    *)                          echo ""              ;;
  esac
}

# ── escalation_classify_topic <text> ─────────────────────────────────────────
# Classify escalation text into a topic string, or "" if no match.
# Order: most-specific first. Mirrors the logic in pilot-dispatcher.sh:bead_domain().
# Prints one of: warming, phone-proxy, wa, geo, property, infra, ""
escalation_classify_topic() {
  local text="$1"
  [ -z "$text" ] && { echo ""; return 0; }

  # warming / chip / on-device — most specific; must precede wa (warming uses WA stack)
  if printf '%s' "$text" | grep -iqE \
      'warming|warm-?up|aquecimento|\bchip(s)?\b|ban-?prevent|ban-?risk|on-?device[ _-]?send|group-?send|chip.?(ban|aquec)|aquec.*chip'; then
    echo "warming"; return 0
  fi

  # phone-proxy / WAP / IP-pool / relay — narrow signals that never appear in other topics
  if printf '%s' "$text" | grep -iqE \
      'phone-?proxy|phone.proxy|\bWAP\b|IP[ _-]?pool|relay[ _-]?IP|relay[ _-]?server|proxy[ _-]?pool|ban.*IP|IP.*ban|sms.?proxy|proxy.*slot'; then
    echo "phone-proxy"; return 0
  fi

  # wa-integration: painel / kanban / pipedrive / whapi / whatsapp — before geo/property
  # (WA features often mention imóvel/ITBI because painel shows deal data, so WA wins)
  if printf '%s' "$text" | grep -iqE \
      'pipedrive|whapi|\bwhatsapp\b|urblink_design_system|drive[_ ]bridge|\bpainel\b|painel\.urblink|\bkanban\b|filter[ -]?pills|frota|mila-?wa|wa-?painel|wa-?kanban|mila.crew|envio[ _-]?mensagem|disparo.*mensagem'; then
    echo "wa"; return 0
  fi

  # geo / ArcGIS / zoneamento / incorporação / quarteirão
  if printf '%s' "$text" | grep -iqE \
      'arcgis|zoneamento|geometria|geo-?match|quarteir[aã]o|incorpora[çc][aã]o|geocod|georreferenc|lat[ -/]?lon|point-in-polygon|[íi]ndice cadastral|indice cadastral|centroid'; then
    echo "geo"; return 0
  fi

  # property-scrapers: cadastro/ITBI/CNPJ/RFB/PBH/motherduck/scraper/terreno/lote
  if printf '%s' "$text" | grep -iqE \
      'scraper|scrape|\bcadastro\b|cadastr[ao]|\bITBI\b|\bRFB\b|receita federal|\bCNAE\b|\bCNPJ\b|\bPBH\b|motherduck|\bHex notebook\b|pesquisa_mercado|propriet[áa]ri|\bim[óo]vel\b|\bim[óo]veis\b|\blote\b|\blotes\b|\bterreno\b|cart[óo]rio|matr[íi]cula|mega.?data.?set|batista-?ps|property.?scrap'; then
    echo "property"; return 0
  fi

  # infra: gate / refino / dolt / framework / supervisor — goes to Mayor (explicit)
  if printf '%s' "$text" | grep -iqE \
      '\bgate\b|\bdolt\b|gate.?dispatcher|\breviewer\b|\bdispatcher\b|\bsupervisor\b|\bframework\b|headroom|\brefinery\b|refino|pilot.?dispatcher|launchd|launchctl|\bplist\b|daemon.presence'; then
    echo "infra"; return 0
  fi

  echo ""  # no match → caller should fallback to mayor
}

# ── escalation_topic_to_crew <topic> ─────────────────────────────────────────
# Map a topic string to the owning crew address for `gc mail send`.
# Always returns a non-empty string (falls back to $ESCALATION_FALLBACK_CREW or mayor).
# Reads env vars at call time so callers can override per-invocation.
escalation_topic_to_crew() {
  local topic="${1:-}"
  case "$topic" in
    property)    echo "${ESCALATION_PROPERTY_CREW:-batista-ps}" ;;
    wa)          echo "${ESCALATION_WA_CREW:-mila-wa}"          ;;
    warming)     echo "${ESCALATION_WARMING_CREW:-oracle-wa}"   ;;
    phone-proxy) echo "${ESCALATION_PHONE_CREW:-digo-wa}"       ;;
    geo)         echo "${ESCALATION_GEO_CREW:-peter-wa}"        ;;
    infra)       echo "${ESCALATION_INFRA_CREW:-mayor}"         ;;
    "")          echo "${ESCALATION_FALLBACK_CREW:-mayor}"      ;;  # no topic → Mayor (zero regression)
    *)           echo "${ESCALATION_FALLBACK_CREW:-mayor}"      ;;  # unknown topic → Mayor
  esac
}

# ── escalation_route <subject> <body> [topic_override] [rig] ─────────────────
# High-level function: classify + map + (optionally) send mail.
# Returns 0 on success; prints "ROUTED:<topic>:<crew>" to stdout.
# Set DRY_RUN=1 to skip the actual mail send (classify + log only).
# $4 rig: caller's rig name for secondary rig-origin classification signal.
#   Used only when content classification and topic_override both return "".
escalation_route() {
  local subject="${1:-}" body="${2:-}" topic_override="${3:-}" rig="${4:-}"
  local topic crew combined

  combined="$subject $body"

  if [ -n "$topic_override" ]; then
    topic="$topic_override"
    _er_log "INFO" "escalation_route: topic override=$topic subject=${subject:0:60}"
  else
    topic=$(escalation_classify_topic "$combined")
    if [ -z "$topic" ] && [ -n "$rig" ]; then
      topic=$(escalation_classify_rig_origin "$rig")
      [ -n "$topic" ] && _er_log "INFO" "escalation_route: rig-origin match rig=$rig topic=$topic subject=${subject:0:60}"
    fi
    _er_log "INFO" "escalation_route: classified topic=${topic:-<none>} subject=${subject:0:60}"
  fi

  crew=$(escalation_topic_to_crew "$topic")

  printf 'ROUTED:%s:%s\n' "${topic:-none}" "$crew"

  if [ "$DRY_RUN" = "1" ]; then
    _er_log "DRY_RUN" "would send to $crew — subject: $subject"
    return 0
  fi

  gc --city "$CITY" mail send "$crew" -s "$subject" -m "$body" 2>&1 \
    && _er_log "INFO" "escalation sent → $crew (topic=${topic:-none}): $subject" \
    || { _er_log "WARN" "gc mail send $crew failed for '$subject' — falling back to mayor"; \
         gc --city "$CITY" mail send mayor -s "$subject" -m "$body" 2>/dev/null || true; }
}

# ── CLI main ──────────────────────────────────────────────────────────────────
[ "$_ESCALATION_LIB_ONLY" = "1" ] && return 0  # sourced as library — stop here

_cli_subject=""
_cli_body=""
_cli_topic=""
_cli_rig=""

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--subject) _cli_subject="$2"; shift 2 ;;
    -m|--message) _cli_body="$2"; shift 2 ;;
    -t|--topic)   _cli_topic="$2"; shift 2 ;;
    -r|--rig)     _cli_rig="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)
      grep '^# ' "$0" | head -40 | sed 's/^# //'
      exit 0 ;;
    *) shift ;;
  esac
done

if [ -z "$_cli_subject" ]; then
  printf 'Usage: escalation-router.sh -s SUBJECT -m BODY [-t TOPIC] [-r RIG] [--dry-run]\n' >&2
  exit 1
fi

escalation_route "$_cli_subject" "$_cli_body" "$_cli_topic" "$_cli_rig"
