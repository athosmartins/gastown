#!/usr/bin/env bash
# disk-recovery-swap-cut.mutants.selftest.sh — porta de entrada do controle negativo do degrau de swap (ga-yh41v0e) para o nó Linux.
#
# O `mbp-run.sh --repo hq` só aceita um `*.selftest.sh` como alvo; o controle negativo de verdade é scripts/disk-recovery-swap-cut.mutants.py (cada guarda do degrau desligada numa
# cópia, o disk-recovery-swap-cut.selftest.sh tem de reprovar: 17 mutantes × o selftest inteiro, minutos de CPU). Por isso é OPT-IN: sem `--run` este arquivo só diz isso e sai 0, para
# o gate e o `for x in *.selftest.sh` não pagarem os minutos toda vez (a prova que o gate lê é o disk-recovery-swap-cut.selftest.sh).
#
#   no nó:  scripts/mbp-run.sh --repo hq --dir <worktree>/.gascity-gastown-hq -- scripts/disk-recovery-swap-cut.mutants.selftest.sh --run
#   direto: bash scripts/disk-recovery-swap-cut.mutants.selftest.sh --run      (este arquivo NÃO chama o heavy-guard: no mini, rode-o assim: "$GC_CITY_PATH/scripts/heavy-guard.sh" --what selftest-mutantes -- bash scripts/disk-recovery-swap-cut.mutants.selftest.sh --run; prefira o nó)
# Saída: a do .py (`MUTANTES: <mortos>/<total> mortos`); exit 0 só com todos mortos.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" != "--run" ]; then
  echo "PULADO: os mutantes do degrau de swap só rodam com --run (17 x o selftest inteiro; rode no nó, veja o cabeçalho). Nada foi provado por este arquivo nesta chamada."
  exit 0
fi
exec python3 -I "$HERE/disk-recovery-swap-cut.mutants.py"
