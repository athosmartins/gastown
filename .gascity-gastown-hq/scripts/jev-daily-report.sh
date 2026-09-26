#!/bin/bash
# jev-daily-report.sh (wa-dln9g) — end-of-day result of the Jev A/B experiment, by ntfy.
#
# Athos asked for it on 22/09: "I would like to see a % of saved tokens for each end of
# day". jev_experiment_report.py existed since the first merge, but nothing ever ran it.
# The experiment log (.gc/logs/jev-experiment.jsonl) is stamped in UTC, so a "day" in the
# report is a UTC day — launchd (packs/town-deltas/assets/jev-daily-report.plist) runs
# this at 21:07 BRT = 00:07 UTC, right after that UTC day closes, and reports it.
# Optional arg: YYYY-MM-DD (UTC) to report another day by hand.
#
# Output: the full report (English, every number labeled MEASURED/ESTIMATED) goes to
# .gc/logs/jev-daily/<day>.txt; the ntfy carries the short Portuguese summary. A failing
# report also sends an ntfy — staying silent would look exactly like "no data today".
set -u

# ga-9wimr7: `notify` routes by an allowlist and its DEFAULT is the hourly digest, not the
# phone (wa-f53j6). No rule knows "Jev — fim do dia", so the first run (23/09 21:07) exited 0
# with "Logged for digest" — the report the Athos asked to SEE never reached him. This is a
# once-a-day report he explicitly requested, sent outside quiet hours: force the push.
export NOTIFY_FORCE_PUSH=1

HQ="${JEV_HQ:-/Users/athos/gt/.gascity-gastown-hq}"
REPORT="${JEV_REPORT:-$HQ/scripts/jev_experiment_report.py}"
OUT_DIR="${JEV_DAILY_OUT_DIR:-$HQ/.gc/logs/jev-daily}"
DAY="${1:-$(date -u -v-1d +%Y-%m-%d)}"

# An empty/garbled day must not reach the report: --date "" means "no filter", so the
# whole log would go out labeled as one day.
case "$DAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *)
    notify -t "Jev: relatório do dia falhou" "Dia inválido: '$DAY' (esperado YYYY-MM-DD, UTC)"
    exit 1
    ;;
esac

mkdir -p "$OUT_DIR"

# ga-aijm2v.3 (F5): best-effort join of new gate-verdict shadow predictions before the
# report runs, so today's numbers include them. NEVER allowed to block the report --
# a join failure (Dolt hiccup, unresolvable rig, git object pruned) just leaves that one
# gate run unmeasured, it says nothing about whether the report itself can run.
JOIN_SCRIPT="${JEV_GATE_VERDICT_JOIN:-$HQ/scripts/jev_gate_verdict_experiment.py}"
# Every individual git/bd call inside the join script now carries its own timeout, but
# this outer bound is the last line of defense: it guarantees the report below still
# runs today even if some future call site regresses that discipline. Overridable so
# the test suite can exercise a real hang without waiting 600s.
JOIN_TIMEOUT="${JEV_GATE_VERDICT_JOIN_TIMEOUT:-600}"
JOIN_RC=0
timeout "$JOIN_TIMEOUT" python3 "$JOIN_SCRIPT" run >>"$OUT_DIR/gate-verdict-join.log" 2>&1 || JOIN_RC=$?
if [ "$JOIN_RC" -eq 124 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) jev_gate_verdict_experiment.py run TIMED OUT after ${JOIN_TIMEOUT}s, see $OUT_DIR/gate-verdict-join.log" >>"$OUT_DIR/gate-verdict-join.log"
elif [ "$JOIN_RC" -ne 0 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) jev_gate_verdict_experiment.py run exited non-zero ($JOIN_RC), see $OUT_DIR/gate-verdict-join.log" >>"$OUT_DIR/gate-verdict-join.log"
fi

if ! python3 "$REPORT" --date "$DAY" >"$OUT_DIR/$DAY.txt" 2>&1; then
  notify -t "Jev: relatório de $DAY falhou" "Detalhe em $OUT_DIR/$DAY.txt"
  exit 1
fi

# ga-aijm2v.8: the "recomecar" section (Jev in shadow: when would a clean restart pay, and what would
# it have cost). Produced by its own script from rows the consumer order already wrote -- this only
# READS the log. Like the join above it is FAIL-OPEN: a broken or hung section must never take the
# whole daily report down, and it must never look like "no data" (a day that failed to compute says
# so, in the file and in the ntfy).
RECOMECAR="${JEV_RECOMECAR_REPORT:-$HQ/scripts/jev_recomecar_experiment.py}"
REC_TIMEOUT="${JEV_RECOMECAR_REPORT_TIMEOUT:-120}"
REC_FAIL_NOTE="Recomeçar (sombra): seção indisponível hoje (falhou ou passou de ${REC_TIMEOUT}s) — isto NÃO é 'sem dados'; detalhe em $OUT_DIR/$DAY.txt."
rec_run() {  # rec_run <label> <args...>: prints the script's output, or a visible FAILED line; never returns non-zero
  local label="$1"; shift
  local out rc
  out=$(timeout "$REC_TIMEOUT" python3 "$RECOMECAR" "$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then printf '%s\n' "$out"
  elif [ "$rc" -eq 124 ]; then printf '== recomecar (%s): section TIMED OUT after %ss ==\n' "$label" "$REC_TIMEOUT"
  else printf '== recomecar (%s): section FAILED (rc=%s) ==\n%s\n' "$label" "$rc" "$out"
  fi
  return 0
}
{
  echo ""
  rec_run "$DAY" report --date "$DAY"
  echo ""
  rec_run "7 days ending $DAY" report --date "$DAY" --days 7
} >>"$OUT_DIR/$DAY.txt"

if ! RESUMO=$(python3 "$REPORT" --date "$DAY" --resumo-pt 2>&1); then
  notify -t "Jev: resumo de $DAY falhou" "$RESUMO"
  exit 1
fi

# The recomecar block rides on the same ntfy: the day, then ONE line of the 7-day rollup (the phase-2
# decision rests on the rolling number; a single day is noisy at this volume).
if ! REC_DAY=$(timeout "$REC_TIMEOUT" python3 "$RECOMECAR" resumo-pt --date "$DAY" 2>/dev/null) || [ -z "$REC_DAY" ]; then
  REC_DAY="$REC_FAIL_NOTE"
fi
# The rollup is the number the phase-2 decision rests on, so it gets the same rule as the day line: a
# failed, hung OR empty answer is a visible "unavailable" line, never a silently missing one (the real
# section script always prints a line on success -- an empty window says "nada a medir" -- so empty
# output is a failure, same as the quem-pensa block below).
REC_7D_FAIL_NOTE="Recomeçar, acumulado 7 dias até $DAY: indisponível (falhou ou passou de ${REC_TIMEOUT}s) — NÃO é 'sem dados'; detalhe em $OUT_DIR/$DAY.txt."
REC_7D=$(timeout "$REC_TIMEOUT" python3 "$RECOMECAR" resumo-pt --date "$DAY" --days 7 --curto 2>/dev/null) || REC_7D=""
[ -n "$REC_7D" ] || REC_7D="$REC_7D_FAIL_NOTE"
RESUMO="$RESUMO"$'\n\n'"$REC_DAY"$'\n'"$REC_7D"
# ga-aijm2v.9: the quem-pensa (which-model) calibration table, cumulative to date. Its records
# come from the hourly jev-quem-pensa order, not from this script, so there is nothing to run
# first -- only to read. Best-effort like the join above: its own failure must never block the
# day's report or its ntfy, but it must not be SILENT either (a missing block would read exactly
# like "no data"), so a failed/empty report puts one visible line in the file and in the ntfy.
# The real report always prints at least one line, so empty output counts as a failure.
QP_REPORT="${JEV_QUEM_PENSA_REPORT:-$HQ/scripts/jev_quem_pensa_report.py}"
QP_TIMEOUT="${JEV_QUEM_PENSA_REPORT_TIMEOUT:-120}"
QP_LOG="$OUT_DIR/quem-pensa-report.log"
QP_FAIL="Quem pensa: relatório falhou — ver $QP_LOG"
QP_TXT=$(timeout "$QP_TIMEOUT" python3 "$QP_REPORT" 2>>"$QP_LOG") || QP_TXT=""
QP_PT=$(timeout "$QP_TIMEOUT" python3 "$QP_REPORT" --resumo-pt 2>>"$QP_LOG") || QP_PT=""
[ -n "$QP_TXT" ] || QP_TXT="$QP_FAIL"
[ -n "$QP_PT" ] || QP_PT="$QP_FAIL"
{ echo; echo "$QP_TXT"; } >>"$OUT_DIR/$DAY.txt"
RESUMO="$RESUMO"$'\n'"$QP_PT"

# ga-aijm2v.7: the preambulo (per-task doctrine diet, SHADOW) table, cumulative to date. Its records
# come from the hourly jev-preambulo order, so there is nothing to run first -- only to read. ONE
# invocation writes the full text to a file and prints the short Portuguese block (its rejection-
# reason lookups read bd, so they must not run twice). Best-effort like the blocks above and just
# as VISIBLE when it fails: the real report always prints at least one line, so empty output counts
# as a failure -- a missing block would read exactly like "no data".
PB_REPORT="${JEV_PREAMBULO_REPORT:-$HQ/scripts/jev_preambulo_report.py}"
PB_TIMEOUT="${JEV_PREAMBULO_REPORT_TIMEOUT:-300}"
PB_LOG="$OUT_DIR/preambulo-report.log"
PB_FULL="$OUT_DIR/preambulo-full.txt"
PB_FAIL="Preâmbulo: relatório falhou — ver $PB_LOG"
rm -f "$PB_FULL"
PB_PT=$(timeout "$PB_TIMEOUT" python3 "$PB_REPORT" --resumo-pt --full-to "$PB_FULL" 2>>"$PB_LOG") || PB_PT=""
PB_TXT=$(cat "$PB_FULL" 2>/dev/null) || PB_TXT=""
[ -n "$PB_TXT" ] || PB_TXT="$PB_FAIL"
[ -n "$PB_PT" ] || PB_PT="$PB_FAIL"
{ echo; echo "$PB_TXT"; } >>"$OUT_DIR/$DAY.txt"
RESUMO="$RESUMO"$'\n'"$PB_PT"

# Last command: a failed ntfy makes the job's exit status non-zero (visible in
# `launchctl list`), instead of a report that silently never reached the phone.
notify -t "Jev — fim do dia $DAY (UTC)" "$RESUMO"
