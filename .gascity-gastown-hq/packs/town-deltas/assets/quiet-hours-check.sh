# quiet-hours-check.sh — shared "is the city in quiet hours" READ-side helper
# (ga-dxyvxr).
#
# ⚠️ CURRENT STATE — read this before anything else in this file: the
# night-window mechanism is OFF today, permanently, by Athos's own request.
# Timeline: 2026-08-16 Athos turned it ON (next paragraph describes that
# decision, still accurate as DESIGN INTENT); 2026-08-20 Athos turned it back
# OFF (`launchctl bootout` of com.gascity.city-night-window, commit
# 38ebc51ed) and it has not been re-enabled since. With no writer running,
# QUIET_HOURS_LEVEL_FILE never gets (re)written, every function below
# fail-opens (never blocks dispatch), and this file's only live effect today
# is staying SILENT about that absence instead of logging spurious
# "UNREADABLE" noise every sweep forever (ga-w8kbf — see
# _quiet_hours_unreadable below). If the mechanism is ever re-enabled, THIS
# paragraph is what needs updating — don't rely on a reader making it 50
# lines down to _quiet_hours_unreadable's comment to learn the current state
# (ga-311q7: that gap already produced one false bug report, ga-ka2c2).
#
# Athos, 2026-08-16: 00h-08h "todo mundo dorme" — the city pauses
# ADMISSION of new work to stop burning token overnight, without killing
# anything already in flight. "gc suspend" (scripts/city-night-window.sh)
# already covers the reconciler (pool dogs, min_active_sessions, wake-reason
# wakes) but NOT the launchd dispatchers (Pilot, quality-gate, auto-refino,
# refino-gate), which spawn sessions directly and would keep dispatching all
# night. This file is the read side every dispatcher sources; the write side
# is scripts/city-night-window.sh, which already runs every 10min and already
# computes the exact same window+override logic — it just also stamps this
# signal now, so nobody has a second copy of the window math.
#
# Mirrors the RAM-pressure-monitor.level pattern already proven in
# pilot-dispatcher.sh (_pilot_ram_pressure_blocks/_level/_unreadable): same
# 2-line file shape ("<STATE>\n<unix_ts>\n"), same staleness+override
# semantics, same 3-function split (decision / raw-value-for-logging /
# explicitly-unreadable-for-logging) so a caller can log "confirmed OPEN" and
# "couldn't tell, proceeding anyway" as the visibly DIFFERENT states they are
# — collapsing them into the same silence is exactly the third-state defect
# class this city's own gate-done self-audit exists to catch.
#
# FAIL-OPEN is the correct direction here, same reasoning as RAM-pressure:
# a missing/stale signal usually just means city-night-window.sh has not run
# yet (job not loaded, first boot, clock skew) — not evidence the city
# actually needs to go quiet. This fix must never be able to freeze dispatch
# harder than the problem it closes.
#
# Sourced by: pilot-dispatcher.sh, quality-gate-dispatcher.sh,
# auto-refino-dispatcher.sh, refino-gate-dispatcher.sh, and
# context-check-dispatcher.sh — 5 consumers, not 4 (ga-w8kbf: this list
# itself was stale, missing context-check-dispatcher.sh, until that bead's
# fix corrected it here alongside the actual bug).

QUIET_HOURS_LEVEL_FILE="${QUIET_HOURS_LEVEL_FILE:-${HOME}/.gastown/run/city-quiet-hours.level}"
# city-night-window.sh runs every 10min; 1800s (30min = 3 missed cycles) gives
# real slack for a single missed/delayed run without the signal going stale
# under normal jitter, while still catching a genuinely dead writer well
# inside one quiet-hours window.
QUIET_HOURS_MAX_AGE_SECS="${QUIET_HOURS_MAX_AGE_SECS:-1800}"
# Mirrors city-night-window.sh's own NIGHT_START_HOUR/NIGHT_END_HOUR defaults
# (00h-08h local, end exclusive) — the calendar-overlap math below needs the
# same boundary the writer uses, or a caller could discount a range the writer
# never actually paused.
NIGHT_START_HOUR="${NIGHT_START_HOUR:-0}"
NIGHT_END_HOUR="${NIGHT_END_HOUR:-8}"

# _quiet_hours_blocks → "1" iff the level file says QUIET and is fresh, else
# "0" (covers OPEN, missing, stale, and corrupt — all fail open the same way).
# Honors QUIET_HOURS_OVERRIDE (test seam, mirrors PILOT_RAM_PRESSURE_OVERRIDE)
# — set to "QUIET" to force the blocked path, anything else to force open.
_quiet_hours_blocks() {
  if [ -n "${QUIET_HOURS_OVERRIDE:-}" ]; then
    case "$QUIET_HOURS_OVERRIDE" in
      QUIET) printf '1'; return 0 ;;
      *) printf '0'; return 0 ;;
    esac
  fi
  [ -f "$QUIET_HOURS_LEVEL_FILE" ] || { printf '0'; return 0; }
  local _state _ts _now
  _state=$(sed -n '1p' "$QUIET_HOURS_LEVEL_FILE" 2>/dev/null | tr -d '[:space:]')
  _ts=$(sed -n '2p' "$QUIET_HOURS_LEVEL_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$_ts" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  _now=$(date +%s)
  [ $(( _now - _ts )) -gt "$QUIET_HOURS_MAX_AGE_SECS" ] && { printf '0'; return 0; }
  if [ "$_state" = "QUIET" ]; then printf '1'; else printf '0'; fi
}

# _quiet_hours_state → raw state string ("QUIET"/"OPEN"/"") for LOGGING only —
# deliberately skips the staleness/override short-circuiting _quiet_hours_blocks
# applies to its decision, so a caller can log what the file literally says
# even on the fail-open path.
_quiet_hours_state() {
  [ -n "${QUIET_HOURS_OVERRIDE:-}" ] && { printf '%s' "$QUIET_HOURS_OVERRIDE"; return 0; }
  [ -f "$QUIET_HOURS_LEVEL_FILE" ] || { printf ''; return 0; }
  sed -n '1p' "$QUIET_HOURS_LEVEL_FILE" 2>/dev/null | tr -d '[:space:]'
}

# _quiet_hours_unreadable → "1" iff the signal is STALE or CORRUPT (the
# fail-open path — dispatch proceeds either way; this is purely a LOGGING
# signal, distinct from the dispatch decision _quiet_hours_blocks already
# makes correctly for every case), "0" iff a genuine QUIET/OPEN reading was
# read (confirmed, not assumed) OR the file is simply ABSENT.
#
# ga-w8kbf: ABSENT is not the same third state as STALE/CORRUPT, and
# collapsing them here was the bug — a missing file is the SILENT, EXPECTED
# shape when the night-window mechanism itself is disabled (no writer
# running by design, e.g. after `launchctl bootout` of
# com.gascity.city-night-window — see scripts/city-night-window.sh), while
# a file that EXISTS but carries a stale timestamp or an unparseable one
# means a writer that WAS running has since broken or hung: a real anomaly
# worth a log line. Before this fix both produced "1", so 4 dispatchers
# (pilot, quality-gate, auto-refino, refino-gate) logged "UNREADABLE
# (missing/stale/corrupt)" every single sweep, forever, for a state that is
# both permanent and correct — training the reader to ignore the message,
# which is exactly the day a REAL stale/corrupt writer would also go
# unnoticed. Absence now returns "0": nothing to report, matches
# _quiet_hours_blocks' own (already-correct) treatment of "no file" as
# "not blocking, not an anomaly". Stale/corrupt still return "1" — this fix
# must not blind the genuine-anomaly case, only the deliberately-off one.
_quiet_hours_unreadable() {
  [ -n "${QUIET_HOURS_OVERRIDE:-}" ] && { printf '0'; return 0; }
  [ -f "$QUIET_HOURS_LEVEL_FILE" ] || { printf '0'; return 0; }
  local _ts _now
  _ts=$(sed -n '2p' "$QUIET_HOURS_LEVEL_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$_ts" in ''|*[!0-9]*) printf '1'; return 0 ;; esac
  _now=$(date +%s)
  if [ $(( _now - _ts )) -gt "$QUIET_HOURS_MAX_AGE_SECS" ]; then printf '1'; return 0; fi
  printf '0'
}

# ── elapsed-clock adjustment (ga-lda92s) ────────────────────────────────────
# The three functions above answer "is it quiet RIGHT NOW" — the admission
# gate's only question. A STALL WATCHDOG asks a different question: "how much
# of [event_ts, now] was the city actually expected to be flowing?" A watchdog
# that just calls _quiet_hours_blocks and silences itself for the WHOLE window
# trades a false-positive for a false-negative (a real stall starting 00h30
# would go unseen for 7h30 — see ga-lda92s). The fix is to discount ONLY the
# quiet portion of the elapsed clock, not the whole verdict.

# _quiet_window_overlap_seconds <start_ts> <end_ts> — PURE calendar math: total
# seconds of [start_ts, end_ts) that fall within local
# [NIGHT_START_HOUR:00, NIGHT_END_HOUR:00) on any day. No file I/O, no live
# state — deterministic and safe to unit-test directly with constructed
# timestamps. Does NOT know about a live override; see
# _quiet_elapsed_adjustment below for the safety wrapper that does.
_quiet_window_overlap_seconds() {
  local start_ts="${1:-}" end_ts="${2:-}"
  case "$start_ts" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  case "$end_ts" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  [ "$end_ts" -le "$start_ts" ] 2>/dev/null && { printf '0'; return 0; }

  local nsh="${NIGHT_START_HOUR:-0}" neh="${NIGHT_END_HOUR:-8}"
  local day day_str total=0 iterations=0
  day_str="$(date -j -f "%s" "$start_ts" "+%Y-%m-%d" 2>/dev/null)"
  [ -z "$day_str" ] && { printf '0'; return 0; }
  day="$(date -j -f "%Y-%m-%d %H:%M:%S" "${day_str} 00:00:00" +%s 2>/dev/null)"
  [ -z "$day" ] && { printf '0'; return 0; }

  # Bounded to 32 days (real callers span at most a few hours) — defensive,
  # never meant to trip, just a hard stop against a date-arithmetic bug
  # turning into an infinite loop.
  while [ "$day" -lt "$end_ts" ] && [ "$iterations" -lt 32 ]; do
    local win_start=$(( day + nsh * 3600 ))
    local win_end=$(( day + neh * 3600 ))
    local ov_start=$(( start_ts > win_start ? start_ts : win_start ))
    local ov_end=$(( end_ts < win_end ? end_ts : win_end ))
    [ "$ov_end" -gt "$ov_start" ] && total=$(( total + (ov_end - ov_start) ))
    day=$(( day + 86400 ))
    iterations=$(( iterations + 1 ))
  done
  printf '%s' "$total"
}

# _quiet_elapsed_adjustment <start_ts> <end_ts> — seconds to SUBTRACT from a
# raw (end_ts - start_ts) elapsed duration to discount legitimate quiet-hours
# pause. Composes the pure calendar overlap above with a live-signal safety
# check: if end_ts's own calendar day says "still in tonight's window" but the
# LIVE signal disagrees (a human override is active — see
# city-night-window.sh's ESCAPE PARA TRABALHAR DE MADRUGADA — or the writer is
# stale/down), we cannot confirm TODAY's portion was actually enforced, so we
# don't discount it — only prior days (if the range spans more than one
# night) stay discounted. Errs toward NOT discounting, i.e. toward the
# wall-clock elapsed a real stall would need anyway — never toward silence.
_quiet_elapsed_adjustment() {
  local start_ts="${1:-}" end_ts="${2:-}"
  local raw; raw="$(_quiet_window_overlap_seconds "$start_ts" "$end_ts")"
  case "$raw" in ''|0) printf '0'; return 0 ;; esac

  local nsh="${NIGHT_START_HOUR:-0}" neh="${NIGHT_END_HOUR:-8}"
  local day_str end_midnight
  day_str="$(date -j -f "%s" "$end_ts" "+%Y-%m-%d" 2>/dev/null)"
  [ -z "$day_str" ] && { printf '%s' "$raw"; return 0; }
  end_midnight="$(date -j -f "%Y-%m-%d %H:%M:%S" "${day_str} 00:00:00" +%s 2>/dev/null)"
  [ -z "$end_midnight" ] && { printf '%s' "$raw"; return 0; }

  local win_start=$(( end_midnight + nsh * 3600 ))
  local win_end=$(( end_midnight + neh * 3600 ))
  if [ "$end_ts" -ge "$win_start" ] && [ "$end_ts" -lt "$win_end" ] && [ "$(_quiet_hours_blocks)" != "1" ]; then
    if [ "$win_start" -gt "$start_ts" ] 2>/dev/null; then
      raw="$(_quiet_window_overlap_seconds "$start_ts" "$win_start")"
    else
      raw=0
    fi
  fi
  printf '%s' "$raw"
}

# ── drain window (ga-a2v0bz) ────────────────────────────────────────────────
# O reboot noturno nao acontecia ha 13 noites: a cidade nunca para de trabalhar
# de madrugada, entao sempre havia um construtor/revisor vivo quando o guard
# olhava. Desenho (Athos opcao (a), 01/10): das 23:00 ate o reboot (23:40) a
# cidade DRENA — os despachantes deixam de ADMITIR trabalho novo, e o que ja
# esta em voo termina (ou e morto e retomado no reboot).
#
# O sinal e GRAVADO por scripts/nightly-reboot.sh (LaunchDaemon root) e LIDO
# aqui, pelos mesmos 5 despachantes que ja fazem `source` deste arquivo. Nao e o
# sinal de quiet-hours (city-quiet-hours.level) de proposito: aquele pertence ao
# city-night-window.sh (hoje DESLIGADO), diz "00h-08h, retoma as 08h", e quem o
# reativasse sobrescreveria o dreno. Dois escritores, dois arquivos.
#
# Arquivo, 4 linhas:  DRAIN | <epoch gravado> | <boot-epoch> | <epoch limite>
#
# FAIL-OPEN, mesmo motivo do quiet-hours: um dreno que trava a cidade por engano
# e pior que um reboot que pula uma noite. So drena quando TUDO abaixo vale:
#   - o arquivo existe, tem 4 campos legiveis e a linha 1 e DRAIN;
#   - foi gravado ha <= DRAIN_WINDOW_MAX_AGE_SECS (escritor vivo; o nightly
#     regrava a cada <= 5min — um escritor morto solta a cidade em 30min);
#   - agora < epoch limite (teto duro, o escritor nunca o estende);
#   - o boot-epoch gravado == o boot-epoch atual. ESTE e o ponto central: o
#     reboot invalida o dreno sozinho. Nao ha passo "limpar a flag no pos-boot"
#     que possa falhar e deixar a cidade drenada de manha.
# Terceiro estado: um arquivo ILEGIVEL (ou valido mas sem como provar o boot)
# nao drena E _drain_window_unreadable devolve "1" — o log do despachante diz
# "nao consegui ler", nunca o mesmo silencio de "nao ha dreno".
#
# Quem precisar soltar a cidade a mao: `rm ~/.gastown/run/city-drain.level`
# (o arquivo e gravado por root, mas o diretorio e do athos — remover funciona).
DRAIN_WINDOW_FILE="${DRAIN_WINDOW_FILE:-${HOME}/.gastown/run/city-drain.level}"
DRAIN_WINDOW_MAX_AGE_SECS="${DRAIN_WINDOW_MAX_AGE_SECS:-1800}"
DRAIN_WINDOW_CLOCK_SKEW_SECS="${DRAIN_WINDOW_CLOCK_SKEW_SECS:-300}"

# _drain_window_boot_epoch -> epoch do boot atual, ou NADA se nao der pra ler.
# Token EXATO de `sec`, nunca regex guloso: `sysctl -n kern.boottime` imprime
#   { sec = 1789579812, usec = 958892 } Wed Sep 16 14:30:12 2026
# e `.*sec = ([0-9]+)` casa com o "sec" de **u**sec e devolve os microssegundos.
# Mesmo bug do ram-pressure-monitor (ga-rc7tz) e do Guard 4 do nightly
# (ga-ljncyt) — terceira vez, por isso a comparacao e por token.
_drain_window_boot_epoch() {
  local v
  if [ -n "${DRAIN_WINDOW_BOOT_EPOCH_OVERRIDE:-}" ]; then
    v="$DRAIN_WINDOW_BOOT_EPOCH_OVERRIDE"
  else
    v=$(sysctl -n kern.boottime 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "sec") { v = $(i+2); gsub(/[^0-9]/, "", v); print v; exit } }')
  fi
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$v"
}

# _drain_window_read: preenche _DW_* e _DW_PARSE (absent|ok|bad). Chamado dentro
# de cada funcao publica — elas rodam em $(...), entao nada vaza entre chamadas.
_drain_window_read() {
  local f v
  _DW_STATE=""; _DW_WRITTEN=""; _DW_BOOT=""; _DW_UNTIL=""
  f="$DRAIN_WINDOW_FILE"
  [ -f "$f" ] || { _DW_PARSE="absent"; return 0; }
  _DW_STATE=$(sed -n '1p' "$f" 2>/dev/null | tr -d '[:space:]')
  _DW_WRITTEN=$(sed -n '2p' "$f" 2>/dev/null | tr -d '[:space:]')
  _DW_BOOT=$(sed -n '3p' "$f" 2>/dev/null | tr -d '[:space:]')
  _DW_UNTIL=$(sed -n '4p' "$f" 2>/dev/null | tr -d '[:space:]')
  _DW_PARSE="ok"
  case "$_DW_STATE" in DRAIN|OPEN) ;; *) _DW_PARSE="bad"; return 0 ;; esac
  for v in "$_DW_WRITTEN" "$_DW_BOOT" "$_DW_UNTIL"; do
    case "$v" in ''|*[!0-9]*) _DW_PARSE="bad"; return 0 ;; esac
  done
}

# _drain_window_blocks -> "1" sse a cidade deve DRENAR agora, senao "0".
# Costura de teste: DRAIN_WINDOW_OVERRIDE=DRAIN forca "1", qualquer outro valor "0".
_drain_window_blocks() {
  if [ -n "${DRAIN_WINDOW_OVERRIDE:-}" ]; then
    case "$DRAIN_WINDOW_OVERRIDE" in DRAIN) printf '1' ;; *) printf '0' ;; esac
    return 0
  fi
  _drain_window_read
  [ "$_DW_PARSE" = "ok" ] && [ "$_DW_STATE" = "DRAIN" ] || { printf '0'; return 0; }
  local now cur
  now=$(date +%s)
  [ $(( now - 10#$_DW_WRITTEN )) -gt "$DRAIN_WINDOW_MAX_AGE_SECS" ] && { printf '0'; return 0; }
  [ $(( 10#$_DW_WRITTEN - now )) -gt "$DRAIN_WINDOW_CLOCK_SKEW_SECS" ] && { printf '0'; return 0; }
  [ "$now" -lt $(( 10#$_DW_UNTIL )) ] || { printf '0'; return 0; }
  cur=$(_drain_window_boot_epoch)
  [ -n "$cur" ] || { printf '0'; return 0; }
  [ "$cur" = "$(( 10#$_DW_BOOT ))" ] || { printf '0'; return 0; }
  printf '1'
}

# _drain_window_state -> estado cru ("DRAIN"/"OPEN"/"") so p/ LOG; nao decide nada.
_drain_window_state() {
  [ -n "${DRAIN_WINDOW_OVERRIDE:-}" ] && { printf '%s' "$DRAIN_WINDOW_OVERRIDE"; return 0; }
  [ -f "$DRAIN_WINDOW_FILE" ] || { printf ''; return 0; }
  sed -n '1p' "$DRAIN_WINDOW_FILE" 2>/dev/null | tr -d '[:space:]'
}

# _drain_window_unreadable -> "1" sse o sinal EXISTE mas nao da pra confiar nele
# (lixo, campos faltando, ou um DRAIN valido sem como provar de que boot e).
# "0" para ausente (estado normal fora da janela), legivel-e-expirado
# (velho / outro boot — esperado: o arquivo sobrevive ao reboot) e legivel-ativo.
# So LOG: a decisao de drenar e _drain_window_blocks, que ja falha aberto.
_drain_window_unreadable() {
  [ -n "${DRAIN_WINDOW_OVERRIDE:-}" ] && { printf '0'; return 0; }
  _drain_window_read
  case "$_DW_PARSE" in
    absent) printf '0' ;;
    bad) printf '1' ;;
    *)
      if [ "$_DW_STATE" = "DRAIN" ] && [ -z "$(_drain_window_boot_epoch)" ]; then printf '1'; else printf '0'; fi
      ;;
  esac
}

# _drain_window_detail -> frase curta p/ o LOG do despachante ("ate 23:59, gravado ha 3min").
# Nunca decide nada.
_drain_window_detail() {
  _drain_window_read
  if [ "$_DW_PARSE" != "ok" ]; then printf 'sinal %s' "$_DW_PARSE"; return 0; fi
  local now until_hm
  now=$(date +%s)
  until_hm=$(date -r "$(( 10#$_DW_UNTIL ))" +%H:%M 2>/dev/null)
  printf 'ate %s, gravado ha %smin' "${until_hm:-?}" "$(( (now - 10#$_DW_WRITTEN) / 60 ))"
}
