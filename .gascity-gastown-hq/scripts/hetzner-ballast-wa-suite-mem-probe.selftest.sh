#!/usr/bin/env bash
# hetzner-ballast-wa-suite-mem-probe.selftest.sh — hermético (ga-weaih6): a sonda de memória do wa-suite (scripts/hetzner-ballast-wa-suite-mem-probe.py) contra um HOME de brinquedo.
# Sem rede, sem root, sem nó. O que NÃO cabe aqui: a rodada de verdade (pytest do WA sob o gt-iso-run real, medindo RSS/PSS) — essa só se prova no nó (docs/runbooks/hetzner-ballast.md, "Medido", 24/10);
# aqui se prova a trava de segurança da sonda: sem o isolamento PROVADO ela não lança nada.
#
# Contents
#   Casos · Variáveis
#
# CASOS: sintaxe · sem gt-iso-run → rc 3 · canário `nao-isolado` → rc 3 · canário sem linha GTN-ISO (vazio) → rc 3 · em nenhum deles o espelho (hetzner-remote-git.sh) é chamado: o stub grava uma marca se rodar ·
#        canário `isolado` mas o `wt-add` falha (rc 1) → rc 3 · `wt-add` rc 0 sem árvore (tests/ ausente) → rc 3 (vale o efeito, não o rc) · em todos o gt-iso-run só foi chamado com --canary: o pytest nunca foi lançado.
#        A LINHA que seria lançada (ga-gvhoi10): `pytest_argv` importada do script, com o HOME de brinquedo — o `env NODE_PATH=<HOME>/.local/share/cdp-drive/node_modules` tem de vir DEPOIS do `--` do gt-iso-run (a jaula descarta o ambiente de fora dela, então a variável posta antes morre: sem ela todo teste
#        de jsdom do WA reprova na sonda) e o resto da linha tem de seguir igual; mais os mutantes dessa linha (cada um tem de mudar a impressão).
# VARIÁVEIS: HMP_UNDER_TEST (script a testar) · HMP_PY (padrão /usr/bin/python3)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${HMP_UNDER_TEST:-$HERE/hetzner-ballast-wa-suite-mem-probe.py}"
PY="${HMP_PY:-/usr/bin/python3}"
T=$(cd "$(mktemp -d /tmp/hmp.XXXXXX)" && pwd -P)
cleanup() { find "$T" -mindepth 1 -delete 2> /dev/null; rmdir "$T" 2> /dev/null; }
trap cleanup EXIT
fails=0; n=0
check() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (esperado '$2', veio '$3')"; fails=$((fails+1)); fi; }

# probe CORPO_DO_CANARIO|- [RC_DO_WT_ADD=0] — HOME de brinquedo com um gt-iso-run que imprime CORPO (ou nenhum, com `-`) e anota em iso.args com que argumentos foi chamado, e um hetzner-remote-git.sh que grava uma marca
# se for chamado e sai com RC_DO_WT_ADD (sem criar árvore nenhuma: o stub nunca cria o tests/); devolve o rc da sonda em $RC
probe() {
  local H="$T/home.$n"; mkdir -p "$H/gt-remote/bin"
  printf '#!/bin/sh\ntouch "%s/rg.chamado"\nexit %s\n' "$T" "${2:-0}" > "$H/gt-remote/bin/hetzner-remote-git.sh"; chmod +x "$H/gt-remote/bin/hetzner-remote-git.sh"
  if [ "$1" != "-" ]; then printf '#!/bin/sh\necho "$*" >> "%s/iso.args"\necho "%s"\nexit 0\n' "$T" "$1" > "$H/gt-remote/bin/gt-iso-run"; chmod +x "$H/gt-remote/bin/gt-iso-run"; fi
  OUT=$(HOME="$H" GT_REMOTE_GIT="$H/gt-remote/git" "$PY" -I "$SCRIPT" "$T/out.$n" 2 30 2>&1); RC=$?
}

"$PY" -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$SCRIPT" 2> /dev/null; check "sintaxe do script" "0" "$?"
probe -;                                  check "sem gt-iso-run → rc 3 (não consegui provar o isolamento: nada roda)" "3" "$RC"
probe "GTN-ISO: nao-isolado (saiu pela rede)"; check "canário nao-isolado → rc 3" "3" "$RC"
probe "pytest 9.9";                       check "canário sem linha GTN-ISO → rc 3 (vazio não é isolado)" "3" "$RC"
check "em nenhum caso a sonda chamou o hetzner-remote-git.sh (nenhuma árvore criada)" "0" "$([ -e "$T/rg.chamado" ] && echo 1 || echo 0)"
probe "GTN-ISO: isolado (rede cortada)" 1; check "isolado mas o wt-add falha (rc 1) → rc 3, nada roda" "3" "$RC"
probe "GTN-ISO: isolado (rede cortada)" 0; check "isolado, wt-add rc 0 mas sem árvore (tests/ ausente) → rc 3 (vale o efeito, não o rc)" "3" "$RC"
# 4 sondas têm stub de gt-iso-run (nao-isolado, "pytest 9.9" e as 2 isoladas; a `probe -` não tem), cada uma o chama 1 vez e só com --canary. vazio (iso.args nunca escrito) → " " ≠ "4 0": não passa por "nenhuma chamada fora do canário"
check "o gt-iso-run só foi chamado com --canary (4 chamadas; o pytest nunca foi lançado)" "4 0" "$(grep -c . "$T/iso.args" 2> /dev/null) $(grep -vxc -e '--canary' "$T/iso.args" 2> /dev/null)"
# a linha lançada: o prazo e o gt-iso-run ANTES do `--`, o que vem DEPOIS dele (até o `-m`) e o miolo do pytest, com o HOME de brinquedo $T/hj: lida de dentro do script (não se lança o pytest aqui). Falhou (a função não existe, o script não importa) → vazio ≠ esperado
argv_of() {  # argv_of SCRIPT
  HOME="$T/hj" "$PY" -I -B - "$1" << 'PYX' 2> /dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hmp", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
a = m.pytest_argv(3, 600)
i = a.index("--")
print("antes=%s | dentro=%s | resto=%s" % (" ".join(a[i - 5:i]), " ".join(a[i + 1:i + 5]), " ".join(a[i + 5:])))
PYX
}
EXP_ARGV="antes=timeout -k 30 720 $T/hj/gt-remote/bin/gt-iso-run | dentro=env NODE_PATH=$T/hj/.local/share/cdp-drive/node_modules $T/hj/gt-remote/venv-wa/bin/python -m | resto=pytest -p no:cacheprovider tests/ -n 3 -p gtn_stable_ids --timeout=900 -q -rfE --tb=line --continue-on-collection-errors"
check "a linha lançada leva o env NODE_PATH DENTRO da jaula (depois do --), antes do python do venv, e o resto da linha não mudou" "$EXP_ARGV" "$(argv_of "$SCRIPT")"
# mutante NOME ANTIGO NOVO: copia o script, troca ANTIGO por NOVO (tem de casar exatamente 1 vez) e confere que a impressão MUDA (ou o script nem importa)
mutant() {
  local m="$T/mut.$1.py"
  "$PY" -I -B - "$SCRIPT" "$m" "$2" "$3" << 'PYX' || { n=$((n+1)); echo "FAIL mutante $1: INVÁLIDO (a âncora não casa exatamente 1 vez)"; fails=$((fails+1)); return; }
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
c = t.count(old)
if c != 1:
    print("âncora casa %d vezes" % c, file=sys.stderr); sys.exit(1)
open(dst, "w", encoding="utf-8").write(t.replace(old, new))
PYX
  n=$((n+1)); if [ "$(argv_of "$m")" != "$EXP_ARGV" ]; then echo "ok   mutante $1 morto"; else echo "FAIL mutante $1 SOBREVIVEU"; fails=$((fails+1)); fi
}
NPV='"NODE_PATH=" + HOME + "/.local/share/cdp-drive/node_modules"'
mutant sem-env          'ISO, "--", "env", '"$NPV"', PYV,' 'ISO, "--", PYV,'
mutant sem-node-path    '"env", '"$NPV"', PYV' '"env", PYV'
mutant env-antes-da-jaula 'ISO, "--", "env", '"$NPV"', PYV,' '"env", '"$NPV"', ISO, "--", PYV,'
mutant sem-node-modules '"/.local/share/cdp-drive/node_modules"' '"/.local/share/cdp-drive"'
mutant outra-pasta      '"/.local/share/cdp-drive/node_modules"' '"/.local/share/cdp-drive-jsdom/node_modules"'
mutant home-fixo        '"NODE_PATH=" + HOME + "/.local' '"NODE_PATH=/root/.local'
mutant nucleos-fixos    '"-n", str(cores),' '"-n", "8",'
mutant limite-fixo      'str(limit + 120),' '"1020",'
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
