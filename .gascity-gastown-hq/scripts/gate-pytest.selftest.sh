#!/usr/bin/env bash
# gate-pytest.selftest.sh — hermético: mbp-run.sh e o python3 são stubs; nada toca o MBP, o live nem o city real.
#
# Contents
#   Casos · Controle negativo
#
# CASOS: verde no MBP (não roda aqui) · MBP indisponível 96..99 → roda aqui o comando de hoje · chave off · vermelho do MBP → os
#   node ids rodam aqui primeiro e o rc DAQUI vale (confirmou / passou isolado → o comando inteiro roda aqui, com -x e com pulado /
#   ids ilegíveis / sem ids / muitos) · pulados no MBP → os arquivos que pularam rodam aqui · sem resumo + -r do revisor → roda aqui · rc estranho do MBP → roda aqui · alvo que lê shared/data, lista
#   force-local, diretório, sem alvo, flag de disco local, repo sem espelho, caminho fora do worktree → rodam aqui sem chamar o MBP ·
#   divisão por alvo (o que fica aqui não arrasta os outros; rc das duas partes se combinam) · caminho absoluto dentro do worktree vira relativo · valor de flag com espaço chega inteiro · rc nunca 96..99 · uso errado = 4 · log.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GP="$HERE/gate-pytest.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/gate-pytest-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/city/.gc/logs" "$T/wt/tests" "$T/wt/tests/sub" "$T/other"
: > "$T/wt/tests/test_a.py"; : > "$T/wt/tests/test_b.py"; : > "$T/wt/tests/sub/test_c.py"
printf 'DB = "shared/data/x.db"\n' > "$T/wt/tests/test_db.py"
printf '# so cita shared/data num comentario\n    # (idem, indentado)\ndef test_x(): pass\n' > "$T/wt/tests/test_coment.py"
: > "$T/other/test_out.py"
: > "$T/wt/tests/helpers.py"   # módulo de apoio que EXISTE no worktree: é de onde um pytest.skip() de helper é reportado

# stub do mbp-run: registra os argumentos (um por linha) e devolve o que o caso mandou.
cat > "$T/bin/mbp-run" <<'EOF'
#!/usr/bin/env bash
{ echo "MBP_CALL"; for a in "$@"; do echo "  arg:$a"; done; } >> "$STUB_LOG"
[ -n "${STUB_MBP_OUT:-}" ] && cat "$STUB_MBP_OUT"
exit "${STUB_MBP_RC:-0}"
EOF
# stub do python3: `python3 -m pytest -p no:cacheprovider <args>`; rc por chamada em STUB_LOCAL_RCS ("4 0" = 1ª chamada 4, 2ª 0).
cat > "$T/bin/py" <<'EOF'
#!/usr/bin/env bash
{ echo "LOCAL_CALL cwd=$(pwd -P)"; for a in "$@"; do echo "  arg:$a"; done; } >> "$STUB_LOG"
n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STUB_COUNT"
rc=$(printf '%s' "${STUB_LOCAL_RCS:-0}" | awk -v n=$n '{ if (n <= NF) print $n; else print $NF }')
echo "stub-local-run n=$n rc=$rc"
exit "$rc"
EOF
chmod +x "$T/bin/mbp-run" "$T/bin/py"
export GATE_PYTEST_CITY="$T/city" GATE_PYTEST_MBP_RUN="$T/bin/mbp-run" GATE_PYTEST_PY="$T/bin/py"
export GATE_PYTEST_FORCE_LOCAL_LIST="$T/force-local.txt" STUB_LOG="$T/stub.log" STUB_COUNT="$T/count"
unset GC_SESSION_NAME
: > "$T/force-local.txt"
fails=0; n=0
reset() { : > "$STUB_LOG"; rm -f "$STUB_COUNT" "$T/city/.gc/logs/gate-pytest.jsonl" "$T/city/.gc/gate-pytest.off"; : > "$T/force-local.txt"
  unset STUB_MBP_RC STUB_MBP_OUT STUB_LOCAL_RCS; }
expect() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; else echo "FAIL $1: esperado rc=$2, veio $3"; fails=$((fails+1)); fi; }
has()   { n=$((n+1)); if grep -q -E -e "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: '$3' ausente em $2"; fails=$((fails+1)); fi; }
hasnt() { n=$((n+1)); if grep -q -E -e "$3" "$2"; then echo "FAIL $1: '$3' presente em $2"; fails=$((fails+1)); else echo "ok   $1"; fi; }
# has_local: o padrão tem de aparecer numa chamada LOCAL (o stub do MBP registra os mesmos alvos, então `has` no log inteiro passaria mesmo sem nada rodar aqui)
has_local() { n=$((n+1)); sed -n '/^LOCAL_CALL/,$p' "$2" > "$T/has-local.log"; if grep -q -E -e "$3" "$T/has-local.log"; then echo "ok   $1"; else echo "FAIL $1: '$3' ausente na parte LOCAL de $2"; fails=$((fails+1)); fi; }
count() { n=$((n+1)); c=$(grep -c -E -e "$3" "$2"); if [ "$c" = "$4" ]; then echo "ok   $1 ($c)"; else echo "FAIL $1: esperado $4 de '$3', vieram $c"; fails=$((fails+1)); fi; }
run() { "$GP" --repo wa --dir "$T/wt" "$@" >"$T/out" 2>"$T/err"; echo $?; }
mbp_out() { printf '%s\n' "$@" > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out"; }
LOG="$T/city/.gc/logs/gate-pytest.jsonl"

# 1 verde no MBP: não roda aqui
reset; mbp_out "..." "2 passed in 1.20s"
rc=$(run -- tests/test_a.py -x -q); expect "verde no MBP" 0 "$rc"
hasnt "verde: não chama o python local" "$STUB_LOG" 'LOCAL_CALL'; has "verde: chamou o MBP com --repo wa" "$STUB_LOG" 'arg:wa'
has "verde: linha final ran=mbp" "$T/out" 'gate-pytest: ran=mbp rc=0'; has "verde: log jsonl ran=mbp" "$LOG" '"ran":"mbp","rc":0'
has "verde: -rfEs vai primeiro, flags do revisor depois" "$STUB_LOG" 'arg:-rfEs'

# 2 MBP indisponível: 96..99 → roda aqui o MESMO comando, e o rc é o daqui
for code in 96 97 98 99; do
  reset; STUB_MBP_RC=$code STUB_LOCAL_RCS=3 run -- tests/test_a.py -x -q >/dev/null; rc=$(STUB_MBP_RC=$code STUB_LOCAL_RCS=3 run -- tests/test_a.py -x -q)
  expect "mbp rc=$code roda aqui e devolve o rc daqui" 3 "$rc"
done
reset; export STUB_MBP_RC=98; rc=$(run -- tests/test_a.py -x -q); unset STUB_MBP_RC
expect "98 + local verde = 0 (nunca 98)" 0 "$rc"; has "98: ran=local" "$T/out" 'ran=local rc=0'
has "98: o comando local é o de hoje (-p no:cacheprovider + os args do revisor)" "$STUB_LOG" 'arg:-p'; has "98: roda no worktree" "$STUB_LOG" "LOCAL_CALL cwd=.*wt"
has "98: motivo no log" "$LOG" 'mbp-rc=98'

# 3 chave off: nem chama o MBP
reset; touch "$T/city/.gc/gate-pytest.off"; rc=$(run -- tests/test_a.py -q); expect "chave gate-pytest.off" 0 "$rc"
hasnt "off: não chama o MBP" "$STUB_LOG" 'MBP_CALL'; has "off: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "off: motivo" "$LOG" 'chave-gate-pytest-off'

# 4 vermelho do MBP: os node ids rodam aqui primeiro; vale o rc DAQUI (se eles passam isolados, o comando inteiro roda aqui)
mbp_red() { mbp_out "FAILED tests/test_a.py::test_x - AssertionError: boom" "ERROR tests/test_b.py - ImportError: nope" "1 failed, 1 error in 0.9s"; export STUB_MBP_RC=1; }
reset; mbp_red; STUB_LOCAL_RCS=1 rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -x -q); expect "vermelho confirmado aqui" 1 "$rc"
has "vermelho: só os ids rodam aqui" "$STUB_LOG" 'arg:tests/test_a.py::test_x'; has_local "vermelho: o erro de coleta roda aqui" "$STUB_LOG" 'arg:tests/test_b.py$'
count "vermelho: UMA chamada local" "$STUB_LOG" 'LOCAL_CALL' 1; has "vermelho: motivo local-confirmou" "$LOG" 'local-confirmou'
has "vermelho: flags do revisor mantidas na confirmação" "$STUB_LOG" 'arg:-x'
# Os ids que reprovaram no MBP PASSAREM isolados aqui NÃO prova que o vermelho é do ambiente: sob -x/--maxfail o MBP parou no 1º vermelho e o que
# vinha depois nunca rodou em lugar nenhum; uma falha que depende de ordem ou um flake também passa isolado. "Não sei" não vira verde:
# o comando inteiro roda aqui (o que o revisor rodava antes) e o rc DELE é o que vale.
reset; mbp_red; rc=$(STUB_LOCAL_RCS="0 0" run -- tests/test_a.py tests/test_b.py -q); expect "ids passam isolados e o comando inteiro também → 0" 0 "$rc"
has "isolado-passou: AVISO dito" "$T/out" 'AVISO: 2 teste\(s\) reprovaram no MBP e passaram aqui isolados'; has "isolado-passou: no log" "$LOG" 'isolado-passou;inteiro-rc=0'
count "isolado-passou: duas chamadas locais (ids + comando inteiro)" "$STUB_LOG" 'LOCAL_CALL' 2; hasnt "isolado-passou: não afirma que a diferença é de ambiente" "$T/out" 'a diferença é de ambiente'
# 4a o -x do revisor (o exemplo canônico do prompt): o vermelho de ambiente vem ANTES de um bug real; o bug só aparece no comando inteiro aqui
reset; mbp_red; rc=$(STUB_LOCAL_RCS="0 1" run -- tests/test_a.py tests/test_b.py -x -q); expect "vermelho sob -x, id passa isolado, o resto reprova aqui → 1 (nunca 0)" 1 "$rc"
count "-x: duas chamadas locais" "$STUB_LOG" 'LOCAL_CALL' 2; awk '/^LOCAL_CALL/{c++} c==2' "$STUB_LOG" > "$T/second.log"
has "-x: a 2ª chamada é o comando inteiro (o -x do revisor)" "$T/second.log" 'arg:-x'; has "-x: a 2ª chamada traz os dois arquivos" "$T/second.log" 'arg:tests/test_b.py$'
hasnt "-x: a 2ª chamada não é a dos ids" "$T/second.log" 'arg:tests/test_a.py::test_x'; has "-x: o log diz o rc do comando inteiro" "$LOG" 'isolado-passou;inteiro-rc=1'
# 4b vermelho + pulado na mesma execução (no MBP faltam dado e .env: vermelho e pulado andam juntos): o arquivo que pulou também roda aqui
reset; mbp_out "FAILED tests/test_a.py::test_x - boom" "SKIPPED [1] tests/test_b.py:9: sem dado no MBP" "1 failed, 1 skipped in 0.9s"; export STUB_MBP_RC=1
rc=$(STUB_LOCAL_RCS="0 1" run -- tests/test_a.py tests/test_b.py -q); expect "vermelho + pulado: o id passa aqui, o arquivo que pulou reprova aqui → 1" 1 "$rc"
awk '/^LOCAL_CALL/{c++} c==2' "$STUB_LOG" > "$T/second.log"; has "vermelho + pulado: o arquivo que pulou roda aqui" "$T/second.log" 'arg:tests/test_b.py$'
# o comando inteiro aqui terminou com rc que não é verde (2 interrompido): vale esse rc, não vira 0
reset; mbp_red; rc=$(STUB_LOCAL_RCS="0 2" run -- tests/test_a.py tests/test_b.py -q); expect "comando inteiro aqui com rc 2 vale" 2 "$rc"
# com divisão: o comando inteiro da parte do MBP roda SEM o alvo que fica aqui (esse roda uma vez só, separado)
reset; mbp_out "FAILED tests/test_a.py::test_x - boom" "1 failed in 0.9s"; export STUB_MBP_RC=1
rc=$(STUB_LOCAL_RCS="0 1 0" run -- tests/test_a.py tests/test_db.py -q); expect "divisão + vermelho que passa isolado: o comando inteiro da parte do MBP reprova → 1" 1 "$rc"
count "divisão + isolado-passou: três chamadas locais (ids, parte do MBP inteira, parte local)" "$STUB_LOG" 'LOCAL_CALL' 3
sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" > "$T/local-part.log"; count "divisão + isolado-passou: test_db roda uma vez só" "$T/local-part.log" 'arg:tests/test_db.py$' 1
reset; mbp_red; rc=$(STUB_LOCAL_RCS="4 1" run -- tests/test_a.py tests/test_b.py -q); expect "ids ilegíveis aqui (rc 4) → comando inteiro" 1 "$rc"
count "ilegíveis: duas chamadas locais" "$STUB_LOG" 'LOCAL_CALL' 2; has "ilegíveis: no log" "$LOG" 'ids-ilegiveis'
reset; mbp_out "1 failed in 0.5s"; export STUB_MBP_RC=1; rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py -q); expect "rc 1 sem linhas FAILED → comando inteiro aqui" 1 "$rc"
has "sem ids: no log" "$LOG" 'sem-ids'; has_local "sem ids: o comando inteiro (arquivo de teste)" "$STUB_LOG" 'arg:tests/test_a.py'
reset; { for i in $(seq 1 51); do echo "FAILED tests/test_a.py::t$i - x"; done; echo "51 failed in 1s"; } > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out" STUB_MBP_RC=1
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py -q); expect "51 reprovados → comando inteiro aqui" 1 "$rc"; has "muitos: no log" "$LOG" 'muitos'; hasnt "muitos: não manda 51 ids" "$STUB_LOG" 'test_a.py::t3'
# 4c um id que o MBP reprovou e que NÃO é de nenhum alvo pedido (conftest/plugin que coleta outro arquivo, ou leitura errada): não sei o que rodar → o comando inteiro aqui,
#    sem rodar o id estranho isolado (rodá-lo isolado e ver passar nada prova sobre o que o revisor pediu)
reset; mbp_out "FAILED tests/outro.py::test_x - boom" "1 failed in 0.9s"; export STUB_MBP_RC=1
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -q); expect "id fora dos alvos → comando inteiro aqui (rc daqui)" 1 "$rc"
count "id fora dos alvos: UMA chamada local" "$STUB_LOG" 'LOCAL_CALL' 1; hasnt "id fora dos alvos: o id estranho não roda" "$STUB_LOG" 'arg:tests/outro.py'
has_local "id fora dos alvos: o comando inteiro (test_a)" "$STUB_LOG" 'arg:tests/test_a.py$'; has_local "id fora dos alvos: o comando inteiro (test_b)" "$STUB_LOG" 'arg:tests/test_b.py$'; has "id fora dos alvos: no log" "$LOG" 'ids-fora-dos-alvos'
reset; mbp_out "FAILED tests/outro.py::test_x - boom" "1 failed in 0.9s"; export STUB_MBP_RC=1
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "id fora dos alvos e o comando inteiro passa aqui → 0 (o rc do comando inteiro vale)" 0 "$rc"
reset; mbp_out "FAILED tests/test_a.py::test_x - boom" "FAILED tests/outro.py::test_y - boom" "2 failed in 0.9s"; export STUB_MBP_RC=1
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -q); expect "um id é alvo e outro não → comando inteiro aqui" 1 "$rc"
count "id misto: UMA chamada local (sem confirmação isolada)" "$STUB_LOG" 'LOCAL_CALL' 1; hasnt "id misto: nenhum node id vai isolado" "$STUB_LOG" 'arg:tests/test_a.py::test_x'
# o id de um alvo dado como node id (tests/test_a.py::test_x pedido) conta como contido
reset; mbp_out "FAILED tests/test_a.py::test_x - boom" "1 failed in 0.9s"; export STUB_MBP_RC=1
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py::test_x -q); expect "alvo pedido como node id: o id reprovado é contido" 1 "$rc"; has "node id pedido: confirmado aqui" "$LOG" 'local-confirmou'

# 5 pulados no MBP
reset; mbp_out "SKIPPED [2] tests/test_b.py:9: sem dado" "3 passed, 2 skipped in 1.0s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "pulados no MBP" 0 "$rc"
count "pulados: UMA chamada local" "$STUB_LOG" 'LOCAL_CALL' 1; has_local "pulados: só o arquivo que pulou" "$STUB_LOG" 'arg:tests/test_b.py$'; sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" > "$T/local-only.log"; hasnt "pulados: o arquivo que não pulou não volta aqui" "$T/local-only.log" 'arg:tests/test_a.py$'
has "pulados: no log" "$LOG" 'skips-no-mbp'
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: sem dado" "1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_b.py -q); expect "pulado que falha aqui devolve o rc daqui" 1 "$rc"
# 5a o skip sai de um HELPER (pytest.skip() dentro de um módulo de apoio): o pytest reporta o caminho do HELPER, não o do teste que pulou.
#    Rodar o helper não coleta nada; o teste que pulou nunca rodava aqui (falso verde medido com pytest real). Caminho que não é alvo → TODOS os alvos aqui.
reset; mbp_out "SKIPPED [2] tests/helpers.py:3: sem dado" "2 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -q); expect "skip vindo de helper: o rc daqui vale (1)" 1 "$rc"
count "helper: UMA chamada local" "$STUB_LOG" 'LOCAL_CALL' 1; has_local "helper: o alvo test_a roda aqui" "$STUB_LOG" 'arg:tests/test_a.py$'; has_local "helper: o alvo test_b roda aqui" "$STUB_LOG" 'arg:tests/test_b.py$'
hasnt "helper: o helper não é alvo da rerun" "$STUB_LOG" 'arg:tests/helpers.py'; has "helper: motivo no log" "$LOG" 'skips-fora-dos-alvos'
reset; mbp_out "SKIPPED [1] tests/helpers.py:3: sem dado" "1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py -q); expect "skip de helper, alvo único: roda o ALVO (nunca 5 por rodar o helper)" 0 "$rc"
has_local "helper alvo único: o alvo roda aqui" "$STUB_LOG" 'arg:tests/test_a.py$'; hasnt "helper alvo único: o helper não roda" "$STUB_LOG" 'arg:tests/helpers.py'
# um skip mapeado + um de helper: o mapeado NÃO basta (o outro nunca rodou aqui) → todos os alvos, inclusive o que nem pulou
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: sem dado" "SKIPPED [1] tests/helpers.py:3: sem dado" "2 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -q); expect "skip mapeado + skip de helper → todos os alvos aqui" 1 "$rc"
has_local "misto: test_a (que não pulou no relato) roda aqui" "$STUB_LOG" 'arg:tests/test_a.py$'; has "misto: motivo no log" "$LOG" 'skips-fora-dos-alvos'
# linha SKIPPED que não dá para ler (sem caminho): a contagem fecha só com ela contada → não sei de quem é → todos os alvos
reset; mbp_out "SKIPPED [1] algo ilegivel sem caminho" "SKIPPED [1] tests/test_b.py:9: sem dado" "2 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -q); expect "linha SKIPPED ilegível → todos os alvos aqui" 1 "$rc"; has_local "ilegível: test_a roda aqui" "$STUB_LOG" 'arg:tests/test_a.py$'
# skip sem número de linha (módulo inteiro pulado): o caminho ainda é lido
reset; mbp_out "SKIPPED [1] tests/test_b.py: modulo pulado" "1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "skip sem linha, caminho é alvo" 0 "$rc"
sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" > "$T/local-only.log"; has "sem linha: o arquivo que pulou roda aqui" "$T/local-only.log" 'arg:tests/test_b.py$'; hasnt "sem linha: o que não pulou não volta" "$T/local-only.log" 'arg:tests/test_a.py$'
# o resumo diz mais pulados do que as linhas SKIPPED listam: há skip sem dono → todos os alvos
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: sem dado" "3 passed, 3 skipped in 1.0s"
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -q); expect "resumo diz 3 pulados, só 1 listado → todos os alvos aqui" 1 "$rc"
has_local "resumo > lista: test_a roda aqui" "$STUB_LOG" 'arg:tests/test_a.py$'; has "resumo > lista: motivo no log" "$LOG" 'skips-nao-contados'
# controle de que o caminho preciso segue valendo: vários grupos de skip do MESMO arquivo, contagem fecha → só esse arquivo
reset; mbp_out "SKIPPED [2] tests/test_b.py:9: a" "SKIPPED [1] tests/test_b.py:20: b" "3 skipped, 1 passed in 1.0s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "vários grupos do mesmo arquivo, contagem fecha" 0 "$rc"
sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" > "$T/local-only.log"; has "grupos: o arquivo que pulou roda" "$T/local-only.log" 'arg:tests/test_b.py$'; hasnt "grupos: o que não pulou não volta" "$T/local-only.log" 'arg:tests/test_a.py$'
has "grupos: motivo preciso no log" "$LOG" 'skips-no-mbp:3'
# alvo pedido como node id: a rerun é o node id que o revisor pediu, não o arquivo inteiro (o arquivo inteiro traria testes que ele nem pediu)
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: sem dado" "1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py::test_y -q); expect "alvo node id que pulou" 0 "$rc"
sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" > "$T/local-only.log"; has "node id: roda o node id pedido" "$T/local-only.log" 'arg:tests/test_b.py::test_y$'; hasnt "node id: não roda o arquivo inteiro" "$T/local-only.log" 'arg:tests/test_b.py$'
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: sem dado" "1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_b.py::test_y tests/test_b.py::test_z -q); expect "dois node ids do mesmo arquivo que pulou" 0 "$rc"
has_local "dois ids: o 1º roda" "$STUB_LOG" 'arg:tests/test_b.py::test_y$'; has_local "dois ids: o 2º roda" "$STUB_LOG" 'arg:tests/test_b.py::test_z$'
# sem pulados + sem resumo (-qq) e sem -r do revisor = nada pulou
reset; mbp_out "."; rc=$(run -- tests/test_a.py -qq); expect "sem resumo, sem -r do revisor, rc 0" 0 "$rc"; hasnt "-qq: não roda aqui" "$STUB_LOG" 'LOCAL_CALL'
# sem resumo + -r do revisor = não sei se pulou → aqui
reset; mbp_out "."; rc=$(run -- tests/test_a.py -qq -ra); expect "sem resumo + -ra do revisor" 0 "$rc"; has "sem resumo + -r: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "no log: skips-ilegiveis" "$LOG" 'skips-ilegiveis'
# o -r do revisor pode vir DENTRO de um grupo de flags curtas (-qqxrf = -q -q -x -r f): argparse o lê, então o wrapper também tem de ler
for grp in -qqxrf -xrf -qqrfE -vrs; do
  reset; mbp_out "."; rc=$(run -- tests/test_a.py $grp); expect "grupo $grp traz um -r: sem resumo, não sei se pulou" 0 "$rc"
  has "grupo $grp: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "grupo $grp: skips-ilegiveis no log" "$LOG" 'skips-ilegiveis'
done
# controles: o r que NÃO é a opção -r (valor de -k, de -n, de -p...) e grupos sem r não disparam
for grp in -qqx -xkr -knot_r -n4 -vv; do
  reset; mbp_out "."; rc=$(run -- tests/test_a.py $grp); expect "grupo $grp (sem -r): nada pulou, não roda aqui" 0 "$rc"; hasnt "grupo $grp: sem chamada local" "$STUB_LOG" 'LOCAL_CALL'
done
# --no-summary (pytest 9 medido): tira as linhas SKIPPED que o meu -rs pede e, junto com -qq, tira também a linha-resumo — um skip fica invisível
# e o rc 0 do MBP seria aceito. Sem resumo + --no-summary = não sei se pulou → aqui, como o -r do revisor.
reset; mbp_out "."; rc=$(run -- tests/test_a.py -qq --no-summary); expect "-qq --no-summary: sem resumo e sem SKIPPED" 0 "$rc"
has "-qq --no-summary: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "-qq --no-summary: skips-ilegiveis no log" "$LOG" 'skips-ilegiveis'; hasnt "-qq --no-summary: sem a nota de verde do MBP" "$T/out" 'nota: verde do MBP'
# controles: --no-summary COM a linha-resumo legível (sem -qq) — o resumo diz quantos pularam, e não há linha SKIPPED para casar → todos aqui;
# e o mesmo --no-summary com resumo "1 passed" = nada pulou, o verde do MBP vale
reset; mbp_out "= 1 passed, 1 skipped in 0.1s ="; rc=$(run -- tests/test_a.py --no-summary); expect "--no-summary com resumo que diz 1 skipped" 0 "$rc"
has "--no-summary + resumo skipped: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "--no-summary + resumo skipped: skips-nao-contados" "$LOG" 'skips-nao-contados'
reset; mbp_out "= 1 passed in 0.1s ="; rc=$(run -- tests/test_a.py --no-summary); expect "--no-summary com resumo sem skip" 0 "$rc"
hasnt "--no-summary + resumo sem skip: não roda aqui" "$STUB_LOG" 'LOCAL_CALL'
# verde do MBP aceito: o MBP não tem shared/data nem .env — um teste que lê dado por um caminho que o wrapper não enxerga pode passar VAZIO lá.
# O wrapper não consegue saber, então DIZ (fail-open visível), só quando um verde do MBP foi aceito.
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_a.py -q); expect "verde do MBP" 0 "$rc"; has "verde do MBP: a nota de verde vazio sai" "$T/out" 'nota: verde do MBP.*VAZIO'
reset; export STUB_MBP_RC=98; rc=$(run -- tests/test_a.py -q); unset STUB_MBP_RC; hasnt "rodou só aqui: sem a nota de verde do MBP" "$T/out" 'nota: verde do MBP'
reset; mbp_red; rc=$(STUB_LOCAL_RCS="0 0" run -- tests/test_a.py tests/test_b.py -q); hasnt "vermelho que virou verde aqui: sem a nota (não houve verde do MBP)" "$T/out" 'nota: verde do MBP'
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: sem dado" "1 skipped in 0.1s"; rc=$(STUB_LOCAL_RCS=1 run -- tests/test_b.py -q); expect "pulou no MBP e reprova aqui" 1 "$rc"
hasnt "pulou no MBP (o aqui decidiu): sem a nota de verde do MBP" "$T/out" 'nota: verde do MBP'
reset; mbp_out "1 passed in 0.1s"; rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_db.py -q); expect "verde do MBP + parte local vermelha" 1 "$rc"
hasnt "rc final 1: a nota de verde do MBP não sai (o veredito é vermelho)" "$T/out" 'nota: verde do MBP'
reset; mbp_out "1 passed in 0.1s"; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_db.py -q); expect "verde do MBP + parte local verde" 0 "$rc"
has "divisão verde: a nota sai (a parte do MBP foi aceita como veio)" "$T/out" 'nota: verde do MBP.*VAZIO'
# a nota vem ANTES da linha final: o revisor copia a ÚLTIMA linha no veredito
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_a.py -q); tail -1 "$T/out" > "$T/lastline"; has "a última linha continua sendo ran=..." "$T/lastline" '^gate-pytest: ran=mbp rc=0'

# 6 rc estranho do MBP (2, 5, 124...) → comando inteiro aqui
for code in 2 3 4 5 124; do reset; export STUB_MBP_RC=$code; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py -q); unset STUB_MBP_RC
  expect "mbp rc=$code → roda aqui" 0 "$rc"; has "mbp rc=$code: motivo no log" "$LOG" "mbp-rc=$code"; done

# 7 alvos que ficam aqui, sem chamar o MBP
reset; rc=$(run -- tests/test_db.py -q); expect "lê shared/data" 0 "$rc"; hasnt "shared/data: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "shared/data: motivo" "$LOG" 'le-shared-data:tests/test_db.py'
reset; echo 'tests/test_b.py' > "$T/force-local.txt"; rc=$(run -- tests/test_b.py -q); expect "lista force-local" 0 "$rc"
hasnt "lista: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "lista: motivo" "$LOG" 'lista-local:tests/test_b.py'
reset; printf '# comentário\n\ntests/sub/*\n' > "$T/force-local.txt"; rc=$(run -- tests/sub/test_c.py -q); expect "glob da lista" 0 "$rc"; has "glob: motivo" "$LOG" 'lista-local:tests/sub/\*'
# a lista é O remédio do verde vazio (runbook): salva sem newline no fim, com CRLF ou com espaço sobrando, ela NÃO pode virar letra morta em silêncio
reset; printf 'tests/test_b.py' > "$T/force-local.txt"; rc=$(run -- tests/test_b.py -q); expect "lista: última linha sem newline final" 0 "$rc"
hasnt "lista sem newline final: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "lista sem newline final: motivo" "$LOG" 'lista-local:tests/test_b.py'
reset; printf '# c\r\ntests/test_b.py\r\n' > "$T/force-local.txt"; rc=$(run -- tests/test_b.py -q); expect "lista: linhas CRLF" 0 "$rc"; hasnt "lista CRLF: sem MBP" "$STUB_LOG" 'MBP_CALL'
reset; printf '   tests/test_b.py  \n' > "$T/force-local.txt"; rc=$(run -- tests/test_b.py -q); expect "lista: espaço sobrando em volta" 0 "$rc"; hasnt "lista com espaço: sem MBP" "$STUB_LOG" 'MBP_CALL'
reset; printf 'tests/test_a.py\ntests/test_zzz.py' > "$T/force-local.txt"; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_b.py -q); expect "lista sem newline: o que não casa continua indo ao MBP" 0 "$rc"; has "lista sem newline: o outro alvo vai ao MBP" "$STUB_LOG" 'MBP_CALL'
reset; rc=$(run -- tests -q); expect "diretório como alvo" 0 "$rc"; hasnt "diretório: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "diretório: motivo" "$LOG" 'alvo-diretorio'
reset; rc=$(run -- -q); expect "sem alvo" 0 "$rc"; has "sem alvo: motivo" "$LOG" 'sem-alvo-arquivo'
reset; rc=$(run -- tests/test_a.py --junitxml=/tmp/x.xml); expect "flag de disco local" 0 "$rc"; has "junitxml: motivo" "$LOG" 'flag-local:--junitxml'
reset; rc=$(run -- tests/test_a.py --lf); expect "--lf (cache daqui)" 0 "$rc"; hasnt "--lf: sem MBP" "$STUB_LOG" 'MBP_CALL'
reset; rc=$(run -- "$T/other/test_out.py" -q); expect "caminho absoluto fora do worktree" 0 "$rc"; hasnt "fora: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "fora: motivo" "$LOG" 'alvo-fora-do-worktree'
reset; rc=$(run -- tests/nao_existe.py -q); expect "alvo inexistente" 0 "$rc"; has "inexistente: motivo" "$LOG" 'alvo-ilegivel'
reset; rc=$("$GP" --dir "$T/wt" -- tests/test_a.py -q >"$T/out" 2>"$T/err"; echo $?); expect "repo sem espelho (nem wa nem ps)" 0 "$rc"
has "sem espelho: motivo" "$LOG" 'repo-sem-espelho'; hasnt "sem espelho: sem MBP" "$STUB_LOG" 'MBP_CALL'

# 7a comentário que só cita shared/data NÃO manda o arquivo para cá (medido: falso positivo que jogava fora o ganho)
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_coment.py -q); expect "comentário com shared/data" 0 "$rc"
has "comentário: vai ao MBP" "$STUB_LOG" 'MBP_CALL'; hasnt "comentário: não roda aqui" "$STUB_LOG" 'LOCAL_CALL'

# 7b divisão por alvo: o que fica aqui NÃO arrasta os outros para cá
reset; mbp_out "2 passed in 1.0s"; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_db.py -x -q); expect "divisão: a no MBP, db aqui" 0 "$rc"
sed -n '/^MBP_CALL/,/^LOCAL_CALL/p' "$STUB_LOG" > "$T/mbp-part.log"; sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" > "$T/local-part.log"
has "divisão: o MBP recebe o test_a" "$T/mbp-part.log" 'arg:tests/test_a.py$'; hasnt "divisão: o MBP NÃO recebe o que lê shared/data" "$T/mbp-part.log" 'test_db'
has "divisão: aqui roda o test_db" "$T/local-part.log" 'arg:tests/test_db.py$'; hasnt "divisão: aqui NÃO roda o test_a" "$T/local-part.log" 'arg:tests/test_a.py$'
has "divisão: flags valem nas duas partes" "$T/local-part.log" 'arg:-x'; count "divisão: UMA chamada local" "$STUB_LOG" 'LOCAL_CALL' 1
has "divisão: linha final mbp+local" "$T/out" 'ran=mbp\+local'; has "divisão: motivo no log" "$LOG" 'split:le-shared-data:tests/test_db.py'
has "divisão: o aviso diz o que ficou aqui" "$T/out" 'ficam aqui \(não vão ao MBP\): le-shared-data:tests/test_db.py'
# o rc de cada parte conta: parte local vermelha = vermelho; MBP verde não apaga isso
reset; mbp_out "1 passed in 1.0s"; rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_db.py -q); expect "divisão: parte local vermelha → 1" 1 "$rc"
# MBP vermelho confirmado aqui + parte local verde → 1 (o vermelho confirmado conta)
reset; mbp_red; rc=$(STUB_LOCAL_RCS="1 0" run -- tests/test_a.py tests/test_b.py tests/test_db.py -q); expect "divisão: MBP vermelho confirmado + local verde → 1" 1 "$rc"
count "divisão: duas chamadas locais (ids + parte local)" "$STUB_LOG" 'LOCAL_CALL' 2
# MBP indisponível + divisão: a parte do MBP roda aqui SEM a parte local (que roda uma vez só, separada)
reset; export STUB_MBP_RC=98; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_db.py -q); unset STUB_MBP_RC; expect "divisão + MBP fora" 0 "$rc"
count "divisão + MBP fora: duas chamadas locais" "$STUB_LOG" 'LOCAL_CALL' 2; sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" > "$T/local-part.log"
count "divisão + MBP fora: test_db roda uma vez só" "$T/local-part.log" 'arg:tests/test_db.py$' 1; count "divisão + MBP fora: test_a roda uma vez só" "$T/local-part.log" 'arg:tests/test_a.py$' 1
# tudo local por lista: sem MBP e o comando é o de hoje
reset; printf 'tests/test_a.py\ntests/test_b.py\n' > "$T/force-local.txt"; rc=$(run -- tests/test_a.py tests/test_b.py -q); expect "todos os alvos na lista" 0 "$rc"
hasnt "todos na lista: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "todos na lista: motivo" "$LOG" 'todos-ficam-aqui'; count "todos na lista: UMA chamada local" "$STUB_LOG" 'LOCAL_CALL' 1

# 7c combinação dos rc na divisão: -k que não casa na parte local (rc 5) não apaga o verde do MBP; rc estranho (137) nunca vira 0
reset; mbp_out "1 passed in 1.0s"; rc=$(STUB_LOCAL_RCS=5 run -- tests/test_a.py tests/test_db.py -q); expect "divisão: MBP verde + local rc 5 → 0" 0 "$rc"
reset; mbp_out "1 passed in 1.0s"; rc=$(STUB_LOCAL_RCS=137 run -- tests/test_a.py tests/test_db.py -q); expect "divisão: local morto por sinal (137) NÃO vira 0" 137 "$rc"
reset; mbp_out "1 passed in 1.0s"; rc=$(STUB_LOCAL_RCS=2 run -- tests/test_a.py tests/test_db.py -q); expect "divisão: local interrompido (2) vale" 2 "$rc"
reset; export STUB_MBP_RC=2 STUB_LOCAL_RCS="5 5"; rc=$(run -- tests/test_a.py tests/test_db.py -q); unset STUB_MBP_RC STUB_LOCAL_RCS; expect "divisão: nenhuma parte coletou (5 e 5) → 5" 5 "$rc"
# sem arquivo temporário não há MBP: roda aqui como hoje
reset; rc=$(TMPDIR="$T/nao-existe" run -- tests/test_a.py -q); expect "mktemp falha → roda aqui" 0 "$rc"; hasnt "mktemp falha: não chama o MBP" "$STUB_LOG" 'MBP_CALL'; has "mktemp falha: motivo" "$LOG" 'mktemp-falhou'

# 8 argumentos chegam como o revisor escreveu
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- "$T/wt/tests/test_a.py" -k "foo and bar" -q); expect "caminho absoluto dentro do worktree" 0 "$rc"
has "absoluto vira relativo para o MBP" "$STUB_LOG" 'arg:tests/test_a.py$'; hasnt "o absoluto não vai ao MBP" "$STUB_LOG" 'arg:/.*test_a.py'
has "valor de flag com espaço chega inteiro" "$STUB_LOG" 'arg:foo and bar$'
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_a.py::TestX::test_y -q); expect "node id" 0 "$rc"; has "node id preservado" "$STUB_LOG" 'arg:tests/test_a.py::TestX::test_y$'

# 9 uso errado
reset; rc=$("$GP" --dir "$T/wt" >"$T/out" 2>"$T/err"; echo $?); expect "sem argumentos do pytest" 4 "$rc"
rc=$("$GP" --dir "$T/nao-existe" -- tests/test_a.py >"$T/out" 2>"$T/err"; echo $?); expect "--dir inexistente" 4 "$rc"
has "--dir inexistente: a mensagem diz QUAL diretório" "$T/out" 'nao-existe'
# --dir / --repo como ÚLTIMO argumento (sem valor): uso errado (4), não um laço sem fim que prende a chamada do revisor até o teto de 600 s
run_bounded() { "$@" >"$T/out" 2>"$T/err" & local p=$! i=0; while kill -0 $p 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 $p 2>/dev/null; then kill -9 $p 2>/dev/null; wait $p 2>/dev/null; echo 124; else wait $p; echo $?; fi; }
rc=$(run_bounded "$GP" --dir); expect "--dir sem valor: uso errado, não trava" 4 "$rc"
rc=$(run_bounded "$GP" --repo); expect "--repo sem valor: uso errado, não trava" 4 "$rc"
rc=$(run_bounded "$GP" --dir "$T/wt" --repo); expect "--repo sem valor depois de um --dir bom" 4 "$rc"

# 10 sessão no log
reset; mbp_out "1 passed in 0.1s"; GC_SESSION_NAME=gate-reviewer-xyz run -- tests/test_a.py -q >/dev/null
rc=$(GC_SESSION_NAME=gate-reviewer-xyz run -- tests/test_a.py -q); has "log traz a sessão do revisor" "$LOG" '"session":"gate-reviewer-xyz"'

# 11 log que não dá para gravar: o rc do revisor não muda, mas a falta é DITA (uma execução fora do log some do antes×depois)
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_a.py -q); hasnt "log gravável: nenhum AVISO de log" "$T/out" 'AVISO: não consegui gravar'
reset; rm -rf "$T/city/.gc/logs"; : > "$T/city/.gc/logs"; mbp_out "1 passed in 0.1s"
rc=$(run -- tests/test_a.py -q); expect "log não gravável: o rc continua o do teste" 0 "$rc"
has "log não gravável: o AVISO diz qual log" "$T/out" 'AVISO: não consegui gravar .*gate-pytest.jsonl'; has "log não gravável: a linha final sai mesmo assim" "$T/out" 'gate-pytest: ran=mbp rc=0'
rm -f "$T/city/.gc/logs"; mkdir -p "$T/city/.gc/logs"

# 12 vermelho do MBP e o rerun daqui MORRE (rc 3): o rc vale e o log NÃO diz que o aqui confirmou
reset; mbp_red; rc=$(STUB_LOCAL_RCS=3 run -- tests/test_a.py tests/test_b.py -q); expect "rerun daqui com rc 3 vale (não vira verde)" 3 "$rc"
has "rerun com rc 3: o log diz o rc daqui" "$LOG" 'local-rc=3'; hasnt "rerun com rc 3: o log NÃO diz que confirmou" "$LOG" 'local-confirmou'

# 13 --help mostra o cabeçalho inteiro (o corte era por número de linha e perdia as variáveis de ambiente)
"$GP" --help > "$T/help" 2>&1; has "--help traz as variáveis de ambiente" "$T/help" 'GATE_PYTEST_CITY'; hasnt "--help não vaza o código" "$T/help" 'set -o pipefail'
# o cabeçalho não promete o que o código não faz (ga-xm1jfl, gate round 1): rc fora de 0..5 existe (137 por sinal, 126/127 sem python3), "o resultado de lá"
# vale só quando é verde, e o verde do MBP pode ser vazio
hasnt "--help não promete rc só em 0..5" "$T/help" '\(0\.\.5\)'; hasnt "--help não diz que o resultado de lá vale" "$T/help" 'resultado de lá é o que vale'
has "--help diz que o verde do MBP pode passar vazio" "$T/help" 'passar VAZIO'; has "--help diz que o skip de helper manda TODOS os alvos para cá" "$T/help" 'TODOS os alvos'

# controle negativo A: sem a confirmação local, o caso "vermelho" PASSARIA pelo rc do MBP — o teste 4 tem de enxergar isso
reset; mbp_red
sed 's|run_local ${flags\[@\]+"${flags\[@\]}"} "${conf\[@\]}"; RC=\$?|RC=1|' "$GP" > "$T/mutA.sh"; chmod +x "$T/mutA.sh"
cmp -s "$GP" "$T/mutA.sh" && { n=$((n+1)); echo "FAIL controle A: o mutante é idêntico ao original (sed não casou)"; fails=$((fails+1)); } || {
  "$T/mutA.sh" --repo wa --dir "$T/wt" -- tests/test_a.py tests/test_b.py -q >/dev/null 2>&1
  n=$((n+1)); if grep -q 'LOCAL_CALL' "$STUB_LOG"; then echo "FAIL controle A: o mutante ainda confirmou aqui"; fails=$((fails+1)); else echo "ok   controle A (mutante sem a confirmação local não roda nada aqui — o teste 4 pegaria)"; fi; }
# controle negativo B: sem o desvio de 96..99, um MBP indisponível viraria rc 98 para o revisor
reset; export STUB_MBP_RC=98
sed 's/^    96|97|98|99)$/    96|97|98|99) exit "$MBP_RC" ;;\n    __morto__)/' "$GP" > "$T/mutB.sh"; chmod +x "$T/mutB.sh"
"$T/mutB.sh" --repo wa --dir "$T/wt" -- tests/test_a.py -q >/dev/null 2>&1; r=$?
n=$((n+1)); if [ "$r" = 98 ]; then echo "ok   controle B (mutante sem o desvio devolve 98 — o teste 2 pegaria)"; else echo "FAIL controle B: o mutante devolveu $r"; fails=$((fails+1)); fi

# controle negativo C: com a regra do round 1 (o caminho do SKIPPED só precisa EXISTIR no worktree), o skip de helper ao lado de um skip mapeado
# deixa o test_a sem rodar aqui — o caso 5a tem de enxergar isso
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: sem dado" "SKIPPED [1] tests/helpers.py:3: sem dado" "2 skipped in 0.1s"
sed 's|if is_target_file "\$skp"; then|if [ -f "\$dir/\$skp" ]; then|' "$GP" > "$T/mutC.sh"; chmod +x "$T/mutC.sh"
cmp -s "$GP" "$T/mutC.sh" && { n=$((n+1)); echo "FAIL controle C: o mutante é idêntico ao original (sed não casou)"; fails=$((fails+1)); } || {
  STUB_LOCAL_RCS=1 "$T/mutC.sh" --repo wa --dir "$T/wt" -- tests/test_a.py tests/test_b.py -q >/dev/null 2>&1
  n=$((n+1)); if sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" | grep -q 'arg:tests/test_a.py$'; then echo "FAIL controle C: o mutante ainda rodou o test_a aqui"; fails=$((fails+1)); else echo "ok   controle C (mutante com a regra do round 1 deixa o test_a sem rodar — o caso 5a pegaria)"; fi; }
# controle negativo D: sem a contenção dos ids, o id de outro arquivo roda isolado aqui e "passa" — o caso 4c tem de enxergar isso
reset; mbp_out "FAILED tests/outro.py::test_x - boom" "1 failed in 0.9s"; export STUB_MBP_RC=1
sed 's/is_target_file "\${id%%::\*}" || ids_fora=1/:/' "$GP" > "$T/mutD.sh"; chmod +x "$T/mutD.sh"
cmp -s "$GP" "$T/mutD.sh" && { n=$((n+1)); echo "FAIL controle D: o mutante é idêntico ao original (sed não casou)"; fails=$((fails+1)); } || {
  STUB_LOCAL_RCS=0 "$T/mutD.sh" --repo wa --dir "$T/wt" -- tests/test_a.py tests/test_b.py -q >/dev/null 2>&1
  n=$((n+1)); if grep -q 'arg:tests/outro.py' "$STUB_LOG"; then echo "ok   controle D (mutante sem a contenção roda o id estranho isolado — o caso 4c pegaria)"; else echo "FAIL controle D: o mutante também não rodou o id estranho"; fails=$((fails+1)); fi; }
unset STUB_MBP_RC

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
