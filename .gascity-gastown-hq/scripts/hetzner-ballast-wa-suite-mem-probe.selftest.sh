#!/usr/bin/env bash
# hetzner-ballast-wa-suite-mem-probe.selftest.sh — hermético (ga-weaih6): a sonda de memória do wa-suite (scripts/hetzner-ballast-wa-suite-mem-probe.py) contra um HOME de brinquedo.
# Sem rede, sem root, sem nó. O que NÃO cabe aqui: a rodada de verdade (pytest do WA sob o gt-iso-run real, medindo RSS/PSS) — essa só se prova no nó (docs/runbooks/hetzner-ballast.md, "Medido", 24/10);
# aqui se prova a trava de segurança da sonda: sem o isolamento PROVADO ela não lança nada.
#
# Contents
#   Casos · Variáveis
#
# CASOS: sintaxe · sem gt-iso-run → rc 3 · canário `nao-isolado` → rc 3 · canário sem linha GTN-ISO (vazio) → rc 3 · em nenhum deles o espelho (hetzner-remote-git.sh) é chamado: o stub grava uma marca se rodar.
# VARIÁVEIS: HMP_UNDER_TEST (script a testar) · HMP_PY (padrão /usr/bin/python3)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${HMP_UNDER_TEST:-$HERE/hetzner-ballast-wa-suite-mem-probe.py}"
PY="${HMP_PY:-/usr/bin/python3}"
T=$(cd "$(mktemp -d /tmp/hmp.XXXXXX)" && pwd -P)
trap 'rm -rf "$T"' EXIT
fails=0; n=0
check() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (esperado '$2', veio '$3')"; fails=$((fails+1)); fi; }

# probe CORPO_DO_CANARIO|- — HOME de brinquedo com um gt-iso-run que imprime CORPO (ou nenhum, com `-`) e um hetzner-remote-git.sh que grava uma marca se for chamado; devolve o rc em $RC
probe() {
  local H="$T/home.$n"; mkdir -p "$H/gt-remote/bin"
  printf '#!/bin/sh\ntouch "%s/rg.chamado"\nexit 0\n' "$T" > "$H/gt-remote/bin/hetzner-remote-git.sh"; chmod +x "$H/gt-remote/bin/hetzner-remote-git.sh"
  if [ "$1" != "-" ]; then printf '#!/bin/sh\necho "%s"\nexit 0\n' "$1" > "$H/gt-remote/bin/gt-iso-run"; chmod +x "$H/gt-remote/bin/gt-iso-run"; fi
  OUT=$(HOME="$H" GT_REMOTE_GIT="$H/gt-remote/git" "$PY" -I "$SCRIPT" "$T/out.$n" 2 30 2>&1); RC=$?
}

"$PY" -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$SCRIPT" 2> /dev/null; check "sintaxe do script" "0" "$?"
probe -;                                  check "sem gt-iso-run → rc 3 (não consegui provar o isolamento: nada roda)" "3" "$RC"
probe "GTN-ISO: nao-isolado (saiu pela rede)"; check "canário nao-isolado → rc 3" "3" "$RC"
probe "pytest 9.9";                       check "canário sem linha GTN-ISO → rc 3 (vazio não é isolado)" "3" "$RC"
check "em nenhum caso a sonda chamou o hetzner-remote-git.sh (nenhuma árvore criada)" "0" "$([ -e "$T/rg.chamado" ] && echo 1 || echo 0)"
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
