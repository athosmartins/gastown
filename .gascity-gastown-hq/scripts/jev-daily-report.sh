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

if ! python3 "$REPORT" --date "$DAY" >"$OUT_DIR/$DAY.txt" 2>&1; then
  notify -t "Jev: relatório de $DAY falhou" "Detalhe em $OUT_DIR/$DAY.txt"
  exit 1
fi

if ! RESUMO=$(python3 "$REPORT" --date "$DAY" --resumo-pt 2>&1); then
  notify -t "Jev: resumo de $DAY falhou" "$RESUMO"
  exit 1
fi

# Last command: a failed ntfy makes the job's exit status non-zero (visible in
# `launchctl list`), instead of a report that silently never reached the phone.
notify -t "Jev — fim do dia $DAY (UTC)" "$RESUMO"
