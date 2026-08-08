#!/usr/bin/env bash
# routed-to-eraser-capture.sh — flagra o PADRAO 1 da apagadora de gc.routed_to no ato.
#
# POR QUE (ga-9tgos): o padrao 2 (remocao cirurgica) foi achado e consertado. O padrao 1 —
# metadata INTEIRO virando null — resiste porque os caminhos baratos ja foram esgotados:
#   · dolt_diff_issues / dolt_history_issues estouram por 'gc dolt sql' (2 tentativas,
#     minha e do gastown.dog-3);
#   · grep por '--metadata ' vs '--set-metadata' nao localizou o call site.
# O dog recusou com pool:refused:needs-live-capture — recusa CORRETA: nao construir fix
# que nao se consegue localizar. Falta o terceiro caminho: pegar no ato.
#
# COMO: tira snapshot do metadata dos beads ARMADOS e compara com o anterior. Quando um
# gc.routed_to some, grava a hora, o valor ANTERIOR e o metadata INTEIRO depois — que e o
# que distingue padrao 1 (tudo virou null) de padrao 2 (so a chave sumiu).
# O importante e o TIMESTAMP: com ele, o log de qualquer daemon que rodou na mesma janela
# vira suspeito, e a lista de suspeitos fica curta.
#
# CUSTO: uma consulta filtrada a cada 120s. Deliberadamente barato — hoje eu mesmo derrubei
# o bd da cidade com um watchdog que rodava mais que o proprio intervalo (ga-y0g5x).
# READ-ONLY: nao escreve em bead nenhum.
#
# Uso:  nohup bash routed-to-eraser-capture.sh &
# Log:  .gc/logs/routed-to-eraser-capture.log

set -uo pipefail
HQ="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
LOG="$HQ/.gc/logs/routed-to-eraser-capture.log"
PREV="/tmp/routed-to-eraser-capture.prev"
INTERVAL="${CAPTURE_INTERVAL:-120}"

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] capture iniciado (intervalo ${INTERVAL}s, read-only)" >> "$LOG"

while true; do
  # --limit 0 obrigatorio: bd list trunca em 50 sem sinal no JSON (ga-21kmp).
  #
  # ga-9tgos (Mayor, 08/08 01:5x): varre TAMBEM os rigs, nao so o HQ.
  # Escrevi esta captura quando a suspeita era HQ-only; o padrao-1 (metadata
  # INTEIRO virando null) apareceu no rig WA — wa-14w79 e wa-91agg com
  # `metadata: null`, sem label de veto, updated_at posterior ao roteamento.
  # Uma captura que so olha HQ nunca veria: e lacuna do INSTRUMENTO, nao ausencia
  # do fenomeno. O id ja carrega o prefixo do rig, entao o flagrante continua
  # identificavel sem marcar a loja separadamente.
  SNAP=""
  for _STORE in "$HQ" /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers; do
    [ -d "$_STORE" ] || continue
    _PART=$(bd -C "$_STORE" list --all --limit 0 --json 2>/dev/null \
      | jq -rc '.[] | select(.status=="open")
                | select([.labels[]?|select(.=="ctx:ready")]|length>0)
                | {id, m:(.metadata//{})}' 2>/dev/null)
    # Store que falha a leitura e PULADO, nao tratado como vazio — senao um
    # hiccup num rig viraria "todos os beads dele perderam a rota".
    [ -n "$_PART" ] && SNAP="${SNAP:+$SNAP$'\n'}$_PART"
  done

  # Falha de leitura NAO e "todos perderam a rota" — sem isso, um hiccup do Dolt viraria
  # um falso flagrante de apagadura em massa. Pula o ciclo e mantem o snapshot anterior.
  if [ -z "$SNAP" ]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] leitura VAZIA — pulando ciclo (nao e evidencia de apagadura)" >> "$LOG"
    sleep "$INTERVAL"; continue
  fi

  if [ -s "$PREV" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      ID=$(printf '%s' "$line" | jq -r '.id' 2>/dev/null)
      OLD=$(printf '%s' "$line" | jq -r '.m["gc.routed_to"] // ""' 2>/dev/null)
      [ -z "$OLD" ] && continue                      # nao tinha rota antes: nada a perder
      NEWLINE=$(grep -F "\"id\":\"$ID\"" <<<"$SNAP" | head -1)
      [ -z "$NEWLINE" ] && continue                  # sumiu da consulta (fechou/desarmou)
      NEW=$(printf '%s' "$NEWLINE" | jq -r '.m["gc.routed_to"] // ""' 2>/dev/null)
      if [ -z "$NEW" ]; then
        REST=$(printf '%s' "$NEWLINE" | jq -c '.m' 2>/dev/null)
        # DESPACHO NORMAL vs APAGADORA: o Pilot CONSOME gc.routed_to ao despachar, e isso
        # é comportamento correto — não é o bug que este script caça. O discriminador não
        # é "pilot.* sobreviveu" (sobrevive nos dois casos), é se dispatched_at MUDOU:
        #   despacho  -> dispatched_at NOVO + sling_bead novo, na mesma janela
        #   apagadora -> dispatched_at IGUAL ao anterior (ou ausente), rota some sozinha
        # Sem esta distinção o log enche de despacho legítimo e o caso real fica escondido
        # — medido: o 1º flagrante (ga-t14of, 04:39:14Z) era despacho com dispatched_at de
        # 9s antes, e teria sido lido como evidência da apagadora.
        DA_OLD=$(printf '%s' "$line"    | jq -r '.m["pilot.dispatched_at"] // ""' 2>/dev/null)
        DA_NEW=$(printf '%s' "$NEWLINE" | jq -r '.m["pilot.dispatched_at"] // ""' 2>/dev/null)
        if [ -n "$DA_NEW" ] && [ "$DA_NEW" != "$DA_OLD" ]; then
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] despacho normal $ID — rota '$OLD' consumida (dispatched_at $DA_OLD -> $DA_NEW). NAO e a apagadora." >> "$LOG"
          continue
        fi
        if [ "$REST" = "{}" ] || [ "$REST" = "null" ]; then P="PADRAO-1 (metadata inteiro vazio)"; else P="PADRAO-2 (cirurgico, pilot.* sobreviveu)"; fi
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FLAGRADO $ID — rota '$OLD' sumiu SEM despacho novo | $P | metadata agora: $REST" >> "$LOG"
      fi
    done <<<"$(cat "$PREV")"
  fi

  printf '%s\n' "$SNAP" > "$PREV"
  sleep "$INTERVAL"
done
