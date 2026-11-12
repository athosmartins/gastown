#!/bin/bash
# hetzner-dados-prove.sh — a PROVA da trava 1, do lado do `runner` no nó (ga-qg1dw5z.1): o que o runner NÃO consegue, e um build sintético que roda e some. Rode no nó, como runner (sem root).
#
# ## Contents
#   Itens · Códigos de saída
#
# ITENS (uma linha `GTD-PROVE: <item> ok|FALHOU|nao-consegui`): home-negado (ls /home/dados → Permission denied) · stage-negado · sem-grupo-dados (id) · sudo-como-dados-recusado (sudo -n -u dados true) ·
#   fora-da-lista-recusado (sudo -n gt-dados-run <nome que não existe>) · build-sintetico (sudo -n gt-dados-run synth: rc 0, `synth: ok`, `GTD-WIPE: ok`, `GTD-EGRESS: attempts=` ≥ 1: 0 = a sonda não chegou ao netns).
#   "Permission denied" é o ÚNICO jeito de ok: diretório que não existe (`No such file`) = trava não instalada = nao-consegui, nunca ok. A conferência do staging VAZIO por root é a linha `GTD-WIPE: ok` do wrapper (ele lê como root) e `hetzner-dados-install.sh --check`.
# CÓDIGOS: 0 todos ok · 1 algum FALHOU · 2 algum nao-consegui (e nenhum FALHOU)
set -u
PATH=/usr/bin:/bin
RUN=/usr/local/sbin/gt-dados-run
BAD=0; CANT=0
item() { echo "GTD-PROVE: $1 $2${3:+ ($3)}"; case $2 in FALHOU) BAD=1 ;; nao-consegui) CANT=1 ;; esac; }
denied() { local out rc; out=$(ls -A "$2" 2>&1); rc=$?
  case $out in *"Permission denied"*) [ $rc -ne 0 ] && item "$1" ok || item "$1" FALHOU "rc=0 com Permission denied?" ;; *"No such file"*) item "$1" nao-consegui "$2 não existe: não instalado" ;; *) [ $rc -eq 0 ] && item "$1" FALHOU "o runner LEU $2" || item "$1" nao-consegui "$(printf '%s' "$out" | cut -c1-100)" ;; esac; }
denied home-negado /home/dados
denied stage-negado /srv/gtdados/in
G=$(id -nG) || G="?"
case " $G " in *" dados "*) item sem-grupo-dados FALHOU "runner está no grupo dados" ;; *"?"*) item sem-grupo-dados nao-consegui "id falhou" ;; *) item sem-grupo-dados ok ;; esac
out=$(sudo -n -u dados true 2>&1); rc=$?
[ $rc -ne 0 ] && item sudo-como-dados-recusado ok || item sudo-como-dados-recusado FALHOU "o runner virou dados"
out=$(sudo -n "$RUN" __fora-da-lista__ 2>&1); rc=$?
case $out in *"GTD-RUN: ok"*) item fora-da-lista-recusado FALHOU "rodou" ;; *) [ $rc -ne 0 ] && item fora-da-lista-recusado ok || item fora-da-lista-recusado FALHOU "rc=0" ;; esac
out=$(sudo -n "$RUN" synth 2>&1); rc=$?
# a sonda de rede do synth SEMPRE tenta ao menos uma conexão: attempts=0 quer dizer que ela nunca chegou à regra de rejeição do netns (ex.: bash sem /dev/tcp acha que está "isolado") → não prova isolamento
if [ $rc -eq 0 ] && [[ $out == *"synth: ok"* && $out == *"GTD-WIPE: ok"* && $out =~ GTD-EGRESS:\ attempts=[1-9][0-9]* ]]; then item build-sintetico ok
elif [ $rc -eq 0 ] && [[ $out =~ GTD-EGRESS:\ attempts=0($|[^0-9]) ]]; then item build-sintetico FALHOU "attempts=0: a sonda de rede não chegou ao netns, isolamento não provado"
else item build-sintetico FALHOU "rc=$rc: $(printf '%s' "$out" | tail -n 1 | cut -c1-160)"; fi
[ $BAD -eq 0 ] && [ $CANT -eq 0 ] && { echo "GTD-PROVE: resultado ok"; exit 0; }
[ $BAD -eq 1 ] && { echo "GTD-PROVE: resultado FALHOU"; exit 1; }
echo "GTD-PROVE: resultado nao-consegui"; exit 2
