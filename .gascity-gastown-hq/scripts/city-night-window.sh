#!/bin/bash
# city-night-window.sh — janela noturna da cidade (Athos, 2026-08-16).
#
# ⚠️ ESTADO ATUAL — leia isto antes do resto do cabecalho: o mecanismo esta
# DESLIGADO hoje, de forma permanente, a pedido do proprio Athos. Linha do
# tempo: 16/08 o Athos LIGOU (paragrafo abaixo descreve essa decisao, ainda
# valida como INTENCAO DE DESIGN); 20/08 o Athos DESLIGOU de novo
# (`launchctl bootout` de com.gascity.city-night-window, commit 38ebc51ed) e
# nao foi reativado desde entao. Sem este job carregado no launchd, este
# script simplesmente NAO RODA — nem suspende a cidade, nem escreve
# ~/.gastown/run/city-quiet-hours.level (ver
# packs/town-deltas/assets/quiet-hours-check.sh, lado leitor, para o efeito
# disso nos despachantes). Se o mecanismo for reativado, ESTE paragrafo e o
# que precisa ser atualizado — nao deixe essa informacao existir so num
# commit message ou numa bead fechada (ga-311q7: exatamente esse gap no
# arquivo irmao ja gerou um falso achado de bug, ga-ka2c2).
#
# DECISAO DO ATHOS (escolha guiada, 16/08): de 00h00 as 07h59 "todo mundo dorme"
# — a cidade inteira para; das 08h00 as 23h59 opera normal. O ponto e nao queimar
# token de madrugada. Medido antes da decisao (transcripts tocados entre 01h e
# 08h): 14/08 ~140 sessoes, 15/08 ~175 — a maior parte dogs do HQ.
#
# POR QUE UM UNICO JOB RODANDO A CADA 10min, e nao dois jobs de calendario:
# um par suspend@00:00 / resume@08:00 e fragil nos dois sentidos — se a maquina
# estiver dormindo/desligada na hora exata, ou se o resume falhar, a cidade fica
# morta o dia inteiro. E exatamente o modo de falha que custou 20h em 15-16/08
# (ga-n1rv9l): ninguem percebe "parado" ate alguem olhar. Este script e
# idempotente e se auto-cura: toda execucao RE-AFIRMA o estado correto da janela.
#
# ⚠️ NAO DESFAZ SUSPENSAO ALHEIA. Se a cidade estiver suspensa durante o DIA e
# NAO tiver sido este script que suspendeu (marker abaixo ausente), ele NAO
# retoma — so alerta. Suspender a cidade de dia e uma acao deliberada de alguem
# (emergencia, manutencao); um self-heal que a desfaz sozinho e a familia de bug
# "orphan-sweep desfaz release deliberado". Quem suspendeu, retoma.
#
# ESCAPE PARA TRABALHAR DE MADRUGADA: crie o arquivo de override com um unix ts
# no futuro; enquanto now < ts, a janela noturna nao suspende nada.
#   date -v+6H +%s > ~/.gastown/run/city-night-window.override
#
# COBERTURA (ga-dxyvxr, 2026-08-16 — fechou a lacuna descrita abaixo): "gc
# suspend" para o reconciler/controller — dogs de pool, min_active_sessions,
# wakes por wake-reason. Isso sozinho NAO para os despachantes launchd (pilot,
# quality-gate-dispatcher, auto-refino, refino-gate, context-check, e o sweep
# de refino do WhatsApp), que spawnam sessao direto e continuariam despachando
# de madrugada. Nao da pra simplesmente tirar esses jobs do launchd: o
# daemon-presence-watchdog (a cada 291s) re-bootstrapa qualquer daemon critico
# ausente e ainda alerta — booto-los seria uma briga barulhenta. O conserto:
# este script agora TAMBEM grava um sinal compartilhado (QUIET_LEVEL_FILE,
# mesmo formato de 2 linhas que ram-pressure-monitor.level ja usa) que cada
# despachante consulta antes de admitir trabalho NOVO — ver
# packs/town-deltas/assets/quiet-hours-check.sh (bash) para o lado leitor.
# Trabalho ja em andamento na virada da janela nao e afetado; so a admissao de
# trabalho novo pausa.
set -uo pipefail

GC="${GC_BIN:-/opt/homebrew/bin/gc}"
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
NOTIFY="${CNW_NOTIFY:-${HOME}/.local/bin/notify}"
RUN_DIR="${CNW_RUN_DIR:-${HOME}/.gastown/run}"
LOG="${CNW_LOG:-${CITY}/.gc/logs/city-night-window.log}"

# Marker: existe SOMENTE quando foi ESTE script que suspendeu a cidade.
# E a unica coisa que autoriza o ramo diurno a retomar.
MARKER="${RUN_DIR}/city-night-window.suspended-by-me"
OVERRIDE="${RUN_DIR}/city-night-window.override"
# Anti-spam do alerta "suspensa por outro": no maximo 1 por dia.
ALERT_STAMP="${RUN_DIR}/city-night-window.foreign-alert"
# ga-dxyvxr: sinal compartilhado de admissao — 2 linhas, "<QUIET|OPEN>\n<unix_ts>\n",
# mesmo formato/semantica de staleness que ram-pressure-monitor.level. Escrita
# atomica (tmp + mv) para nenhum leitor concorrente ver um arquivo pela metade.
QUIET_LEVEL_FILE="${CNW_QUIET_LEVEL_FILE:-${RUN_DIR}/city-quiet-hours.level}"

NIGHT_START_HOUR="${CNW_NIGHT_START_HOUR:-0}"   # inclusive
NIGHT_END_HOUR="${CNW_NIGHT_END_HOUR:-8}"       # exclusive

mkdir -p "${RUN_DIR}" "$(dirname "${LOG}")" 2>/dev/null
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [city-night-window] $*" >> "${LOG}"; }
alert() { "${NOTIFY}" -t "$1" -p "${3:-4}" "$2" >/dev/null 2>&1 || true; }

# Le workspace.suspended do city.toml. Fonte da verdade e o arquivo que o
# proprio "gc suspend/resume" escreve — nao um cache nosso.
city_is_suspended() {
  awk '
    /^\[/ { in_ws = ($0 == "[workspace]") ? 1 : 0 }
    in_ws && /^[[:space:]]*suspended[[:space:]]*=/ {
      if ($0 ~ /true/) { print "yes"; exit }
    }
  ' "${CITY}/city.toml" 2>/dev/null | grep -q yes
}

in_night_window() {
  local h; h=$(date +%H); h=${h#0}; h=${h:-0}
  [ "${h}" -ge "${NIGHT_START_HOUR}" ] && [ "${h}" -lt "${NIGHT_END_HOUR}" ]
}

override_active() {
  [ -f "${OVERRIDE}" ] || return 1
  local until_ts now
  until_ts=$(tr -dc '0-9' < "${OVERRIDE}" | head -c 12)
  [ -n "${until_ts}" ] || return 1
  now=$(date +%s)
  [ "${now}" -lt "${until_ts}" ]
}

# ga-dxyvxr: escreve o sinal compartilhado de admissao — QUIET sse dentro da
# janela E sem override ativo, senao OPEN. Roda em TODA execucao (chamada
# antes dos ramos NOITE/DIA abaixo), independente do resultado de gc
# suspend/resume — mesmo que gc suspend falhe, os despachantes ainda devem
# parar de admitir trabalho novo; a janela em si e o gatilho, nao o sucesso
# do comando gc.
write_quiet_hours_signal() {
  local state
  if in_night_window && ! override_active; then
    state="QUIET"
  else
    state="OPEN"
  fi
  printf '%s\n%s\n' "${state}" "$(date +%s)" > "${QUIET_LEVEL_FILE}.tmp" \
    && mv -f "${QUIET_LEVEL_FILE}.tmp" "${QUIET_LEVEL_FILE}"
}
write_quiet_hours_signal

# ── ramo NOITE ────────────────────────────────────────────────────────────────
if in_night_window; then
  if override_active; then
    log "NOITE, mas override ativo (${OVERRIDE}) — nao suspendendo."
    exit 0
  fi
  if city_is_suspended; then
    exit 0   # ja no estado certo, silencio (roda a cada 10min)
  fi
  log "NOITE: cidade acordada — suspendendo (gc suspend)."
  if out=$("${GC}" suspend --city "${CITY}" 2>&1); then
    : > "${MARKER}"
    log "  gc suspend OK: ${out}"
  else
    log "  ERRO no gc suspend: ${out}"
    alert "Janela noturna: falha ao suspender a cidade" \
          "gc suspend falhou as $(date '+%H:%M'). A cidade segue acordada e vai queimar token a noite. Saida: ${out}"
  fi
  exit 0
fi

# ── ramo DIA ─────────────────────────────────────────────────────────────────
if ! city_is_suspended; then
  [ -f "${MARKER}" ] && rm -f "${MARKER}"
  [ -f "${ALERT_STAMP}" ] && rm -f "${ALERT_STAMP}"
  exit 0   # ja no estado certo
fi

if [ ! -f "${MARKER}" ]; then
  # Suspensa de dia por OUTRA pessoa/agente. Nao mexer — so avisar 1x/dia.
  today=$(date +%F)
  if [ "$(cat "${ALERT_STAMP}" 2>/dev/null)" != "${today}" ]; then
    echo "${today}" > "${ALERT_STAMP}"
    log "DIA: cidade suspensa, mas NAO fui eu (sem marker) — deixando como esta e alertando."
    alert "Cidade suspensa de dia (nao foi a janela noturna)" \
          "workspace.suspended=true as $(date '+%H:%M'), fora da janela 00h-08h, e sem o marker da janela noturna. Alguem suspendeu de proposito — nao vou retomar sozinho. Se foi engano: gc resume --city ${CITY}" 4
  fi
  exit 0
fi

log "DIA: retomando a cidade (suspensa pela janela noturna)."
if out=$("${GC}" resume --city "${CITY}" 2>&1); then
  rm -f "${MARKER}"
  log "  gc resume OK: ${out}"
else
  log "  ERRO no gc resume: ${out}"
  alert "Janela noturna: falha ao RETOMAR a cidade" \
        "gc resume falhou as $(date '+%H:%M'). A cidade esta PARADA e nada vai andar hoje ate isso ser resolvido. Saida: ${out}" 5
fi
exit 0
