#!/usr/bin/env bash
# render_primes.sh (ga-kp9vbf): renderiza o `gc prime` de cada papel para ./primes/<papel>.md.
# O TD_ROLE de cada papel vem da config do agente (agent.toml / patches do city.toml), não do shell:
# `gc prime` já devolve a versão por papel. Rode com o ambiente do papel que quer medir só se o seu
# GC_ALIAS não importar (ele vaza em 2-3 linhas "Working directory / Mail identity" — não muda tamanho).
set -u
cd "$(dirname "$0")" || exit 1
mkdir -p primes
render() { gc prime "$2" > "primes/$1.md" 2>/dev/null; }
render dog gastown.dog
render wa-worker wa-worker
render ps-worker ps-worker
render gate-reviewer gate-reviewer
render refino-gate-reviewer refino-gate-reviewer
render context-check-reviewer context-check-reviewer
render auto-refiner auto-refiner
render mayor gastown.mayor
render peter-wa peter-wa          # os outros crews (batista/mila/oracle/thies/digo) estão suspended: prime vazio
for f in primes/*.md; do printf '%-34s %8d bytes\n' "$f" "$(wc -c < "$f")"; done
