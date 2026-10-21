#!/bin/bash
# queima.sh — item `filler` do lastro do nó Hetzner (ga-2hd02v.5): N laços de CPU pura, nada mais.
#
# Contents
#   O que é · Por que existe desligado · Termina sozinho · Contrato
#
# O QUE É: o último recurso para o nó não ficar abaixo de 100% quando NÃO há trabalho útil na fila (decisão do Athos, 20/10: "o que não pode é ficar menos do que 100% ocupado"; quem ocupa não
#   importa). Cada laço usa um núcleo; o governo (hetzner-ballast.py) o roda em nice 19 + SCHED_IDLE, então qualquer sessão toma a CPU na hora. Não lê nem escreve dado nenhum.
# POR QUE EXISTE DESLIGADO: queimar CPU sem trabalho é gasto de energia e uso sustentado do servidor alugado; o registro só o liga com a flag `burn.on` na pasta do lastro
#   (hetzner-ballast.sh burn on|off). O governo o mata quando um item `work` vai começar (os núcleos voltam para o trabalho útil).
# TERMINA SOZINHO, COM exit 0: o `timeout` do prazo do registro (3600 s) o mataria com rc 124, e o governo trata todo rc que não é 0 como falha (why "rc-124", cooldown de no mínimo 600 s): toda hora de
#   queima seria seguida de >= 10 min sem filler, e o fim normal ficaria igual a uma falha no results.jsonl. Com exit 0 o why é "ok" e vale o cooldown do registro (0): recomeça no tick seguinte.
#   O tempo (BALLAST_BURN_SECS, padrão 3300) fica ABAIXO do prazo do registro; o hetzner-ballast-items.selftest.sh confere essa folga contra a linha `queima` do registro. Só o relógio COMPLETO vale como fim
#   normal: se o `sleep` falha (rc ≠ 0) o script leva os laços e sai com 1.
# CONTRATO: BALLAST_CORES = quantos laços (inteiro >= 1, senão exit 2); BALLAST_BURN_SECS = por quanto tempo (inteiro >= 1, senão exit 2; passou, leva os laços e sai com 0); avisa o resumo na partida;
#   no TERM leva os laços junto (exit 143).
set -u
n=${BALLAST_CORES:-1}
secs=${BALLAST_BURN_SECS:-3300}
case "$n" in ''|*[!0-9]*|0) echo "queima: BALLAST_CORES inválido ($n): preciso de um inteiro >= 1" >&2; exit 2 ;; esac
case "$secs" in ''|*[!0-9]*|0) echo "queima: BALLAST_BURN_SECS inválido ($secs): preciso de um inteiro >= 1" >&2; exit 2 ;; esac
printf 'BALLAST-SUMMARY: {"kind": "queima", "cores": %s, "secs": %s}\n' "$n" "$secs"
pids=""
trap 'kill $pids 2>/dev/null; exit 143' TERM INT
i=0
while [ "$i" -lt "$n" ]; do
  ( while :; do :; done ) &
  pids="$pids $!"
  i=$((i + 1))
done
sleep "$secs" &
sp=$!
pids="$pids $sp"
wait "$sp"; rc=$?   # só o relógio: um `wait` sem argumento esperaria os laços, que não têm fim
kill $pids 2>/dev/null
# o relógio que NÃO completou (sleep ausente, morto por outro sinal) não é o fim normal: exit 0 aqui o faria passar por "ok" e o governo o recomeçaria a cada tick, sem queimar nada
[ "$rc" -eq 0 ] || { echo "queima: o relógio (sleep $secs) saiu com rc $rc antes da hora: não é um fim normal" >&2; exit 1; }
exit 0
