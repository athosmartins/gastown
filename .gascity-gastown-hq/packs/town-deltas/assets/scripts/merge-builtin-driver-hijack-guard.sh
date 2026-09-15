#!/usr/bin/env bash
# merge-builtin-driver-hijack-guard.sh (ga-grg42n)
#
# WHY (child of gt-ymqjj, closed incident): merge.union.driver=true was
# broken local config in whatsapp_automation/.repo.git, hijacking git's
# BUILT-IN "union" merge algorithm with a no-op ("true") command -- it
# silently discarded the "theirs" side of every merge/rebase touching a
# union-attributed path, with NO conflict, NO error, NO log (git's own
# design: a REGISTERED driver, even a broken one, is trusted over the
# built-in). Cost: 20 gate refusals, 4 branches stuck on human decision,
# ~2h investigation. This guard prevents recurrence: a scheduled scan of
# git config across the city, not "someone remembers to check."
#
# MECHANISM (distinct from gt-4zk4b/ga-dqfw10 -- see below): this catches a
# merge.<builtin-name>.driver entry existing AT ALL, regardless of whether
# .git and .repo.git AGREE. gt-4zk4b/ga-dqfw10 catches DIVERGENCE between
# .git and .repo.git for a legitimate CUSTOM driver (e.g. deploydeps) that
# exists on one side and not the other. Both are "merge driver sanity", but
# agreement is not enough here -- if BOTH sides define merge.union.driver,
# that is still a hijack of a name git already resolves natively, just a
# consistently-broken one instead of a divergent one. Don't conflate: this
# script never compares two git-dirs against each other, it flags any
# single git-dir that defines a driver for a name git already builds in.
#
# BUILTIN NAMES -- confirmed against the authoritative source
# (https://git-scm.com/docs/gitattributes, fetched 2026-09-15), not
# assumed: exactly three merge-attribute STRING values resolve to a
# built-in driver without any merge.<name>.driver config --
#   text   -- "the built-in 3-way merge driver can be explicitly specified
#              by asking for the 'text' driver"
#   binary -- "the built-in 'take the current branch' driver can be
#              requested with 'binary'"
#   union  -- "run 3-way file level merge for text files, but take lines
#              from both versions" (the confirmed, historically-hit case)
# "ours" is a common attribute-driver NAME in the wild but is explicitly
# NOT a git built-in -- it is the well-known idiom for a user-defined
# driver (canonical setup literally is `git config merge.ours.driver
# true`, straight from git's own docs example). A repo with
# merge.ours.driver configured is doing exactly what git expects; flagging
# it would be a false positive on every legitimate "ours" repo. Verified,
# not assumed, per this bead's own instruction.
#
# WHAT THIS GUARD DOES NOT DO: it never writes git config anywhere.
# Touching merge driver config is what caused the original incident, and
# the fix belongs to whoever has fresh context on the specific driver (same
# caution gt-4zk4b registered) -- this only ALARMS, citing rig + git-dir +
# key + value, via escalation-router.sh (topic "infra" -> mayor).
#
# SCOPE / DEDUP: discovers distinct git-COMMON-dirs across every rig `gc
# rig list --json` reports (suspended rigs included -- a landmine there is
# still a landmine for whenever it's un-suspended) plus each rig's sibling
# .repo.git when it is a genuinely distinct git-dir. Measured live in this
# city on 2026-09-15 (git -C <path> rev-parse --git-common-dir against
# every rig path) -- worth recording here because it is easy to get
# silently wrong: /Users/athos/gt/gastown and .../deacon have NO .git of
# their own and resolve UPWARD to the shared /Users/athos/gt/.git (the
# "gascity" rig's own repo) -- so a naive per-rig-path scan would
# double/triple-count the SAME config and could alarm the same entry once
# per rig name. Crew/polecat worktrees share their container's .git the
# same way, which is why the bead text says "basta checar uma vez por
# git-dir distinto" -- scanning from each rig ROOT already captures
# everything every worktree of that repo shares; ephemeral worktree paths
# (crew/, gate's /private/tmp/gc-gate-*) are never visited directly.
# property_scrapers/lexbh go the OTHER way: their ".git" is a FILE
# (gitlink) pointing AT .repo.git -- one identity, not two. gastown itself
# is the case that needs BOTH probes: shared upward-resolved .git (no
# divergence risk with gascity/deacon) PLUS its own genuinely-distinct
# .repo.git. Dedup is therefore keyed on the RESOLVED ABSOLUTE common-dir,
# never on the rig name or the probed path.
#
# ERRO != VAZIO: if rig discovery itself fails (gc rig list --json errors,
# or the process/Dolt is unreachable), this exits 2 with an explicit ERRO
# on stderr. It never lets a failed scan collapse into "0 findings" --
# that would be the exact "erro e vazio produzindo o mesmo valor" failure
# family this city's own doctrine names repeatedly.
#
# Self-locks via flock before any work (ga-y0g5x: an unlocked guard
# stacking instances took down the city's bd once already) and alarms are
# cooldown-deduped per (git-dir, key) so a persisting, not-yet-fixed
# finding does not repeat-mail (ga-2uz59: 85 identical mails in 10h from an
# unthrottled guard). Deliberately wired as a `gc order` (fresh exec per
# tick, cooldown trigger) rather than a raw launchd plist, matching
# engine-window-backlog-guard.sh's own rationale: this guard can then never
# itself become a member of the multi-instance bug class it would otherwise
# risk joining.
#
# Uso: bash merge-builtin-driver-hijack-guard.sh [--json]
# Uso (biblioteca, para selftest): . merge-builtin-driver-hijack-guard.sh --lib
set -uo pipefail

# ── library guard (mirrors escalation-router.sh's own --lib convention) ──
_MBDHG_LIB_ONLY=0
[ "${1:-}" = "--lib" ] && _MBDHG_LIB_ONLY=1

GIT_BIN="${GIT_BIN:-git}"
GC_BIN="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-.}}"
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/maintenance}"
LOCK_FILE="${MBDHG_LOCK:-$CITY/.gc/runtime/merge-builtin-driver-hijack-guard.lock}"

# Confirmed builtin merge-attribute names -- see header comment for the
# citation. Deliberately NOT "ours" (legitimate custom-driver idiom).
MBDHG_BUILTIN_NAMES="text binary union"

mbdhg_is_builtin_name() {
  local name="$1" b
  [ -z "$name" ] && return 1
  for b in $MBDHG_BUILTIN_NAMES; do
    [ "$name" = "$b" ] && return 0
  done
  return 1
}

# mbdhg_scan_git_dir <git-common-dir-abs-path>
# Prints "<name>\t<value>" for every merge.<builtin-name>.driver entry
# found in that git-dir's config. Read-only: `git config --get-regexp`
# never mutates anything.
#
# Returns 0 on a successful read (whether or not anything matched) and 2
# if the read itself failed (corrupt/unreadable config -- confirmed
# empirically: `git config --get-regexp` exits 1 for "no matching lines",
# its normal/expected empty-result signal per git-config(1), and something
# else, e.g. 128, for a genuine failure like a corrupt config file). The
# caller must NOT treat rc=2 the same as "scanned, found nothing" -- that
# collapse (erro == vazio) is exactly the defect class this bead's own
# self-audit flagged in this function on first draft. Deliberately doesn't
# pipe git's stdout directly into the parsing loop: piping would let
# `set -o pipefail` smuggle git's raw exit code out through the loop's own
# status, making the rc=0/1/other distinction below unreliable.
mbdhg_scan_git_dir() {
  local gitdir="$1" key val name out rc
  out=$("$GIT_BIN" --git-dir="$gitdir" config --get-regexp '^merge\..*\.driver$' 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    return 2
  fi
  if [ -n "$out" ]; then
    while IFS=' ' read -r key val; do
      [ -n "$key" ] || continue
      name="${key#merge.}"; name="${name%.driver}"
      if mbdhg_is_builtin_name "$name"; then
        printf '%s\t%s\n' "$name" "$val"
      fi
    done <<< "$out"
  fi
  return 0
}

# mbdhg_discover_git_dirs <rig-root-path> [<rig-root-path> ...]
# For each candidate root: resolves its git-common-dir (git itself handles
# gitlinks and upward resolution transparently) AND, if a sibling
# .repo.git exists, that git-dir's common-dir too. Prints each distinct
# ABSOLUTE common-dir at most once, first-seen order.
#
# NOTE on scope: a root whose git-dir cannot be resolved at all (rc!=0
# here) is silently skipped, same as a root that legitimately isn't a git
# repo. Verified empirically (not assumed) that this is the right
# boundary: a config file corrupt enough to break `git config
# --get-regexp` (mbdhg_scan_git_dir's rc=2 case) ALSO breaks `git
# rev-parse --git-common-dir` in this git version -- they read the same
# file -- so such a rig never reaches the scan step regardless. That
# failure mode is not a narrow guard-only blind spot: every other git
# operation against that rig (Pilot dispatch, the gate, any crew work)
# would fail identically and loudly within minutes, so this guard does
# not separately alarm on it. mbdhg_scan_git_dir's rc=2 still matters for
# the real in-scope case: config becoming unreadable in the TOCTOU window
# AFTER discovery already resolved the git-dir but BEFORE this guard's own
# scan reaches it -- realistic here since other agents mutate these exact
# repos concurrently.
mbdhg_discover_git_dirs() {
  local root cd1 cd2 seen=""
  for root in "$@"; do
    [ -n "$root" ] || continue
    [ -d "$root" ] || continue
    cd1=$("$GIT_BIN" -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || cd1=""
    if [ -n "$cd1" ]; then
      case " $seen " in
        *" $cd1 "*) ;;
        *) seen="$seen $cd1"; printf '%s\n' "$cd1" ;;
      esac
    fi
    if [ -e "$root/.repo.git" ]; then
      cd2=$("$GIT_BIN" --git-dir="$root/.repo.git" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || cd2=""
      if [ -n "$cd2" ]; then
        case " $seen " in
          *" $cd2 "*) ;;
          *) seen="$seen $cd2"; printf '%s\n' "$cd2" ;;
        esac
      fi
    fi
  done
}

# mbdhg_get_rig_roots -- live rig discovery. Prints one path per line.
# Returns 2 (never 0-with-empty-output) if `gc rig list --json` fails or
# is unreadable -- see header's ERRO != VAZIO note. Not called by the
# selftest's unit-level assertions, which inject synthetic roots directly
# into mbdhg_discover_git_dirs; it IS exercised by the selftest's
# end-to-end assertions via a stubbed $GC_BIN.
mbdhg_get_rig_roots() {
  local raw rc out
  raw=$("$GC_BIN" rig list --json 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    return 2
  fi
  out=$(printf '%s' "$raw" | jq -r '.rigs[]?.path // empty' 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ]; then
    return 2
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# mbdhg_alarm_once_standalone <key> <subject> <body>
# Self-contained cooldown-deduped alarm: reads+writes its own seen-file
# each call (no in-memory state carried across calls) so it can be called
# standalone from a test or in a loop from main() identically. Returns 1
# (no-op, not an error) when the key is still within cooldown.
mbdhg_alarm_once_standalone() {
  local key="$1" subject="$2" body="$3"
  local seen_file router_bin escalate_after now last seen_json rc deliver_rc

  seen_file="${MBDHG_SEEN_FILE:-$STATE_DIR/merge-builtin-driver-hijack-guard-seen.json}"
  router_bin="${MBDHG_ROUTER:-$CITY/packs/town-deltas/assets/escalation-router.sh}"
  escalate_after="${MBDHG_ESCALATE_AFTER_S:-86400}"
  now=$(date +%s)

  mkdir -p "$(dirname "$seen_file")" 2>/dev/null || true
  [ -f "$seen_file" ] || echo '{}' > "$seen_file" 2>/dev/null || true
  seen_json=$(cat "$seen_file" 2>/dev/null || echo '{}')
  [ -n "$seen_json" ] || seen_json='{}'

  last=$(printf '%s' "$seen_json" | jq -r --arg k "$key" '.[$k] // 0' 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$last" != "0" ] && [ $(( now - last )) -lt "$escalate_after" ]; then
    return 1
  fi

  if [ -x "$router_bin" ]; then
    "$router_bin" -s "$subject" -m "$body" --topic infra >/dev/null 2>&1
    deliver_rc=$?
  else
    "$GC_BIN" mail send mayor -s "$subject" -m "$body" >/dev/null 2>&1
    deliver_rc=$?
  fi

  if [ "$deliver_rc" -ne 0 ]; then
    # DELIVERY FAILED -- a third, distinct state from "delivered" (rc=0) and
    # "still in cooldown" (rc=1). Never conflate an attempted send with a
    # confirmed one: persisting the cooldown timestamp here would silence
    # this alarm for the full escalate_after window (default 24h) even
    # though the guard re-detects the identical finding on every tick.
    # This is exactly the "erro == vazio" collapse this guard's own header
    # names -- an unconfirmed delivery must not be recorded as if it
    # succeeded. Logged distinctly (not silent) and left unpersisted so the
    # next run retries instead of going quiet.
    echo "merge-builtin-driver-hijack-guard: ALARM DELIVERY FAILED (rc=$deliver_rc) for key='$key' -- NOT recording as seen, will retry next run" >&2
    return 2
  fi

  seen_json=$(printf '%s' "$seen_json" | jq --arg k "$key" --argjson n "$now" '.[$k] = $n' 2>/dev/null)
  rc=$?
  [ $rc -eq 0 ] && [ -n "$seen_json" ] || seen_json='{}'
  printf '%s\n' "$seen_json" > "$seen_file" 2>/dev/null || true
  return 0
}

# ── library-only callers stop here ──────────────────────────────────────
[ "$_MBDHG_LIB_ONLY" = "1" ] && return 0 2>/dev/null

# ══════════════════════════════ CLI main ═══════════════════════════════
JSON_OUT=0
[ "${1:-}" = "--json" ] && JSON_OUT=1

[ -d "$CITY" ] || { echo "ERRO: CITY '$CITY' não existe -- não dá pra localizar o escalation-router nem o lock. Setei GC_CITY_PATH?" >&2; exit 2; }
CITY=$(cd "$CITY" && pwd) || { echo "ERRO: não consegui resolver CITY como caminho absoluto." >&2; exit 2; }

# ── lock de instância única (ga-y0g5x) -- antes de qualquer trabalho real ──
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
exec 9>"$LOCK_FILE" || { echo "merge-builtin-driver-hijack-guard: não consegui abrir $LOCK_FILE para lock -- saindo (fail-safe, não roda sem garantia de instância única)"; exit 0; }
flock -n 9 || { echo "merge-builtin-driver-hijack-guard: outra instância já rodando (lock $LOCK_FILE) -- saindo"; exit 0; }

RIG_ROOTS_RAW=$(mbdhg_get_rig_roots)
RIG_ROOTS_RC=$?
if [ "$RIG_ROOTS_RC" -ne 0 ]; then
  echo "ERRO: não consegui descobrir os rigs da cidade ('$GC_BIN rig list --json' falhou ou voltou vazio) -- isto é FALHA DE DESCOBERTA, não '0 rigs'. Não reporto 'nenhum achado' sobre um scan que não rodou de verdade." >&2
  exit 2
fi

mapfile -t _RAW_ROOT_ARR <<< "$RIG_ROOTS_RAW"
RIG_ROOT_ARR=()
for r in "${_RAW_ROOT_ARR[@]}"; do
  [ -n "$r" ] && RIG_ROOT_ARR+=("$r")
done

mapfile -t GIT_DIRS < <(mbdhg_discover_git_dirs "${RIG_ROOT_ARR[@]}")

TOTAL_DIRS=0
FINDINGS_TSV=""
FINDING_COUNT=0
UNREADABLE_COUNT=0
UNREADABLE_TSV=""

for gd in "${GIT_DIRS[@]}"; do
  [ -n "$gd" ] || continue
  TOTAL_DIRS=$((TOTAL_DIRS+1))
  scan_out=$(mbdhg_scan_git_dir "$gd")
  scan_rc=$?
  if [ "$scan_rc" -eq 2 ]; then
    # erro != vazio (pre-flight self-audit finding): an unreadable git-dir
    # is counted here, NEVER silently absorbed into "0 findings" for it --
    # see mbdhg_scan_git_dir's own header for why rc=2 is distinct from a
    # legitimately clean read.
    UNREADABLE_COUNT=$((UNREADABLE_COUNT+1))
    UNREADABLE_TSV="${UNREADABLE_TSV}${gd}
"
    continue
  fi
  while IFS=$'\t' read -r fname fval; do
    [ -n "$fname" ] || continue
    FINDING_COUNT=$((FINDING_COUNT+1))
    FINDINGS_TSV="${FINDINGS_TSV}${gd}	${fname}	${fval}
"
  done <<< "$scan_out"
done

if [ "$JSON_OUT" = "1" ]; then
  FINDINGS_JSON=$(printf '%s' "$FINDINGS_TSV" | jq -R -s -c '
    split("\n") | map(select(length>0)) | map(split("\t")) |
    map({git_dir: .[0], name: .[1], value: (.[2:] | join("\t"))})
  ')
  UNREADABLE_JSON=$(printf '%s' "$UNREADABLE_TSV" | jq -R -s -c 'split("\n") | map(select(length>0))')
  jq -n -c --argjson n "$TOTAL_DIRS" --argjson f "$FINDINGS_JSON" \
    --argjson u_count "$UNREADABLE_COUNT" --argjson u "$UNREADABLE_JSON" '
    {git_dirs_scanned: $n, finding_count: ($f|length), findings: $f,
     unreadable_count: $u_count, unreadable_git_dirs: $u}
  '
else
  echo "═══ merge-builtin-driver-hijack-guard ═══"
  echo "  git-dirs distintos varridos: $TOTAL_DIRS"
  echo "  achados (merge.<builtin>.driver espúrio): $FINDING_COUNT"
  echo "  ilegíveis (config não leu -- NÃO é 'limpo'): $UNREADABLE_COUNT"
  if [ "$FINDING_COUNT" -gt 0 ]; then
    echo
    printf '%s' "$FINDINGS_TSV" | awk -F'\t' 'NF>=3 {printf "    %s -- merge.%s.driver=%s\n", $1, $2, $3}'
  fi
  if [ "$UNREADABLE_COUNT" -gt 0 ]; then
    echo
    echo "  ILEGÍVEL:"
    printf '%s' "$UNREADABLE_TSV" | awk 'NF>0 {printf "    %s\n", $0}'
  fi
fi

ALARM_DELIVERY_FAILED_COUNT=0

if [ "$FINDING_COUNT" -gt 0 ]; then
  while IFS=$'\t' read -r gd fname fval; do
    [ -n "$gd" ] || continue
    key="${gd}|merge.${fname}.driver"
    subject="config:broken-merge-driver -- merge.${fname}.driver espúrio em ${gd}"
    body="Detectado merge.${fname}.driver=${fval} em ${gd}. '${fname}' é estratégia de merge EMBUTIDA do git (text/binary/union) -- não deveria ter driver custom registrado (mesmo mecanismo de gt-ymqjj: apagou conteúdo em silêncio, sem conflito, sem log). NÃO corrigido automaticamente por este guard -- mexer em merge driver foi o que causou aquele incidente; a correção é decisão de quem tiver contexto (ga-grg42n)."
    mbdhg_alarm_once_standalone "$key" "$subject" "$body"
    [ $? -eq 2 ] && ALARM_DELIVERY_FAILED_COUNT=$((ALARM_DELIVERY_FAILED_COUNT+1))
  done < <(printf '%s' "$FINDINGS_TSV" | awk -F'\t' 'NF>=3')
fi

if [ "$UNREADABLE_COUNT" -gt 0 ]; then
  while IFS= read -r gd; do
    [ -n "$gd" ] || continue
    key="${gd}|unreadable"
    subject="config:unreadable-merge-config -- não consegui ler git config em ${gd}"
    body="merge-builtin-driver-hijack-guard não conseguiu ler o git config de ${gd} (git config --get-regexp falhou com erro, não com 'sem match'). Não dá pra saber se há um merge.<builtin>.driver espúrio aí -- isto é ILEGÍVEL, não 'limpo'. Investigue o config desse git-dir (ga-grg42n)."
    mbdhg_alarm_once_standalone "$key" "$subject" "$body"
    [ $? -eq 2 ] && ALARM_DELIVERY_FAILED_COUNT=$((ALARM_DELIVERY_FAILED_COUNT+1))
  done <<< "$UNREADABLE_TSV"
fi

if [ "$ALARM_DELIVERY_FAILED_COUNT" -gt 0 ]; then
  echo "merge-builtin-driver-hijack-guard: AVISO -- $ALARM_DELIVERY_FAILED_COUNT alarme(s) NÃO entregue(s) nesta execução (router/mail falhou). Cooldown não foi persistido para eles; serão re-tentados na próxima execução." >&2
fi

exit 0
