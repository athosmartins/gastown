#!/bin/bash
# queima.sh — item `filler` do lastro do nó Hetzner (ga-2hd02v.5): N laços de CPU pura, nada mais.
#
# Contents
#   O que é · Por que existe desligado · Contrato
#
# O QUE É: o último recurso para o nó não ficar abaixo de 100% quando NÃO há trabalho útil na fila (decisão do Athos, 20/10: "o que não pode é ficar menos do que 100% ocupado"; quem ocupa não
#   importa). Cada laço usa um núcleo; o governo (hetzner-ballast.py) o roda em nice 19 + SCHED_IDLE, então qualquer sessão toma a CPU na hora. Não lê nem escreve dado nenhum.
# POR QUE EXISTE DESLIGADO: queimar CPU sem trabalho é gasto de energia e uso sustentado do servidor alugado; o registro só o liga com a flag `burn.on` na pasta do lastro
#   (hetzner-ballast.sh burn on|off). O governo o mata quando um item `work` vai começar (os núcleos voltam para o trabalho útil).
# CONTRATO: BALLAST_CORES = quantos laços (inteiro >= 1, senão exit 2); avisa o resumo na partida (não tem fim: quem o encerra é o prazo do registro ou o governo); no TERM leva os laços junto.
set -u
n=${BALLAST_CORES:-1}
case "$n" in ''|*[!0-9]*|0) echo "queima: BALLAST_CORES inválido ($n): preciso de um inteiro >= 1" >&2; exit 2 ;; esac
printf 'BALLAST-SUMMARY: {"kind": "queima", "cores": %s}\n' "$n"
pids=""
trap 'kill $pids 2>/dev/null; exit 143' TERM INT
i=0
while [ "$i" -lt "$n" ]; do
  ( while :; do :; done ) &
  pids="$pids $!"
  i=$((i + 1))
done
wait
