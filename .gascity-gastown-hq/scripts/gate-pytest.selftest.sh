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
#   Round 3 do gate: assinatura de shared/data achada em arquivo GRANDE (10 execuções: é uma corrida de SIGPIPE), na última linha, com byte NUL · só alguns alvos pularam → a nota de
#   verde do MBP sai (os irmãos foram aceitos sem reconferir) · opções do plugin de cache rodam aqui e o comando daqui não leva -p no:cacheprovider (stub que recusa como o pytest;
#   e o pytest de verdade quando existe) · lista force-local ausente/ilegível → nada vai ao MBP, com AVISO · repo vem do git-common-dir, não do nome do diretório do worktree.
#   Gate round 1 do ga-xm1jfl.1 (a classe "não consegui gravar/ler lido como nada pulou"): `tee` que falha (registro vazio ou cortado; com divisão, com MBP vermelho, com MBP fora 96..99) · saída vazia ·
#   fora de -qq sem a linha-resumo (lista SKIPPED parcial incluída) e as grafias de -qq · grep que lê a saída e falha (a contagem de SKIPPED e a linha-resumo).
#   Controles negativos A-I: cada mutante (sem a confirmação local, sem o desvio 96..99, regra antiga do skip, sem a contenção dos ids, leitura antiga da assinatura, -p no:cacheprovider de volta,
#   sem o status do tee, sem a exigência do resumo, leitura antiga que ignora o rc do grep) tem de ser pego.
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
# Fixtures GRANDES: a leitura `grep -v ... | grep -q` sob pipefail morria de SIGPIPE quando o arquivo passava de ~64 KB (capacidade do pipe) e "não consegui saber"
# virava "não cita shared/data": o arquivo ia ao MBP. Um fixture de 47 bytes (o test_db acima) nunca enxerga isso. 4000 linhas ≈ 200 KB.
pad() { awk 'BEGIN{for(i=0;i<4000;i++) printf "value_%d = %d  # padding padding padding padding\n", i, i}'; }
{ printf 'DB = "shared/data/x.db"\n'; pad; } > "$T/wt/tests/test_big.py"                 # assinatura na LINHA 1 de um arquivo grande
{ pad; printf 'DB = "shared/data/x.db"\n'; } > "$T/wt/tests/test_bigend.py"                # e na ÚLTIMA linha
{ printf '# so cita shared/data num comentario\n'; pad; } > "$T/wt/tests/test_bigcoment.py"   # grande, mas a única citação é comentário: continua indo ao MBP
printf 'DB = "shared/data/x.db"\n\000\n' > "$T/wt/tests/test_nul.py"                         # byte NUL (medido no grep do macOS): sem `grep -a` ele responde "Binary file matches" no lugar das linhas
printf 'DB = "shared/data/x.db"\nx = "caf\351"\n' > "$T/wt/tests/test_latin.py"            # byte que não é UTF-8: o grep do macOS o lê como texto (controle: continua achando a assinatura)

# stub do mbp-run: registra os argumentos (um por linha) e devolve o que o caso mandou.
cat > "$T/bin/mbp-run" <<'EOF'
#!/usr/bin/env bash
{ echo "MBP_CALL"; for a in "$@"; do echo "  arg:$a"; done; } >> "$STUB_LOG"
[ -n "${STUB_MBP_OUT:-}" ] && cat "$STUB_MBP_OUT"
exit "${STUB_MBP_RC:-0}"
EOF
# stub do python3: `python3 -m pytest <args>`; rc por chamada em STUB_LOCAL_RCS ("4 0" = 1ª chamada 4, 2ª 0).
# Como o pytest de verdade (9.0.3, medido): com `-p no:cacheprovider` as opções do plugin de cache (--lf --ff --nf --sw --cache-clear...) não
# existem e o pytest sai com rc 4 "unrecognized arguments". O stub reproduz isso, senão ele esconde a regressão (gate round 3).
cat > "$T/bin/py" <<'EOF'
#!/usr/bin/env bash
{ echo "LOCAL_CALL cwd=$(pwd -P)"; for a in "$@"; do echo "  arg:$a"; done; } >> "$STUB_LOG"
nocache=0; prev=""
for a in "$@"; do { [ "$prev" = "-p" ] && [ "$a" = "no:cacheprovider" ]; } && nocache=1; prev="$a"; done
if [ $nocache -eq 1 ]; then
  for a in "$@"; do
    case "$a" in --lf|--last-failed|--ff|--failed-first|--nf|--new-first|--sw|--stepwise|--sw-skip|--stepwise-skip|--sw-reset|--stepwise-reset|--cache-clear|--cache-show|--cache-show=*|--lfnf|--last-failed-no-failures|--lfnf=*|--last-failed-no-failures=*)
      echo "ERROR: unrecognized arguments: $a"; exit 4 ;; esac
  done
fi
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
has "98: o comando local é o de hoje (os args do revisor, nada além)" "$STUB_LOG" 'arg:-x'; hasnt "98: sem -p no:cacheprovider (o revisor de hoje não o usa)" "$STUB_LOG" 'no:cacheprovider'
has "98: roda no worktree" "$STUB_LOG" "LOCAL_CALL cwd=.*wt"
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
# 5-nota só ALGUNS alvos pularam: os que pularam rodam aqui, mas os IRMÃOS que não pularam foram aceitos como vieram do MBP, sem reconferir. A nota de verde
#   vazio sai também aqui (a forma mais comum: o MBP sem dado faz alguns arquivos pularem e os outros passam). Sem a nota, a ausência dela lê como "conferido".
has "parcial: a nota de verde do MBP sai (test_a foi aceito sem reconferir)" "$T/out" 'nota: verde do MBP.*VAZIO'
has "parcial: a nota diz que vale SÓ para os alvos que não pularam" "$T/out" 'nota: verde do MBP aceito como veio SÓ para os alvos que não pularam'
has "parcial: a última linha continua sendo ran=..." "$T/out" 'gate-pytest: ran=mbp\+local rc=0'; tail -1 "$T/out" > "$T/lastline"; has "parcial: a nota vem ANTES da linha final" "$T/lastline" '^gate-pytest: ran='
# a nota completa (verde sem pulados) NÃO leva a ressalva "SÓ para os que não pularam"
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_a.py tests/test_b.py -q); hasnt "verde sem pulados: a nota não leva a ressalva de parcial" "$T/out" 'SÓ para os alvos'
# TODOS os alvos pularam: nada foi aceito do MBP → sem nota (o que vale é o rc daqui)
reset; mbp_out "SKIPPED [1] tests/test_a.py:9: x" "SKIPPED [1] tests/test_b.py:9: y" "2 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "todos os alvos pularam" 0 "$rc"; hasnt "todos pularam: sem a nota (nada foi aceito do MBP)" "$T/out" 'nota: verde do MBP'
# skip sem dono (helper): TODOS os alvos rodam aqui → nada aceito do MBP → sem nota
reset; mbp_out "SKIPPED [1] tests/helpers.py:3: x" "2 passed, 1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "skip de helper, todos os alvos aqui" 0 "$rc"; hasnt "helper: sem a nota" "$T/out" 'nota: verde do MBP'
# parcial e o rerun daqui reprova → o veredito é vermelho: sem nota
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: x" "1 passed, 1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -q); expect "parcial e o rerun reprova" 1 "$rc"; hasnt "parcial vermelho: sem a nota" "$T/out" 'nota: verde do MBP'
# parcial com node ids: tests/test_b.py::test_y pulou, o irmão tests/test_a.py foi aceito
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: x" "1 passed, 1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py::test_y -q); expect "parcial com node id" 0 "$rc"; has "parcial com node id: a nota sai" "$T/out" 'nota: verde do MBP aceito como veio SÓ para os alvos que não pularam'
# dois node ids do MESMO arquivo que pulou: nenhum irmão foi aceito → sem nota
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: x" "1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_b.py::test_y tests/test_b.py::test_z -q); expect "dois ids do arquivo que pulou" 0 "$rc"; hasnt "dois ids: sem a nota" "$T/out" 'nota: verde do MBP'
# parcial + divisão (test_db fica aqui, test_b pulou, test_a foi aceito)
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: x" "1 passed, 1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS="0 0" run -- tests/test_a.py tests/test_b.py tests/test_db.py -q); expect "parcial + divisão" 0 "$rc"; has "parcial + divisão: a nota sai" "$T/out" 'nota: verde do MBP aceito como veio SÓ para os alvos que não pularam'
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
# o -r do revisor pode vir DENTRO de um grupo de flags curtas (-qqxrf = -q -q -x -r f): argparse o lê, então o wrapper também tem de ler.
# Só sob -qq a linha-resumo some (fora dele o pytest SEMPRE a imprime, e a falta dela é saída ilegível: caso 5b), então é sob -qq que o -r do revisor decide algo.
for grp in -qqxrf "-qq -xrf" -qqrfE; do
  reset; mbp_out "."; rc=$(run -- tests/test_a.py $grp); expect "grupo $grp traz um -r: sem resumo, não sei se pulou" 0 "$rc"
  has "grupo $grp: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "grupo $grp: skips-ilegiveis no log" "$LOG" 'skips-ilegiveis'
done
# controles: o r que NÃO é a opção -r (valor de -k, de -n, de -p...) e grupos sem r não disparam (sob -qq, a saída "." sem resumo é a legítima)
for grp in -qqx -qqxkr -qqknot_r "-qq -n4"; do
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

# 5b SAÍDA DO MBP QUE NÃO SE SABE LER (gate round 1 do ga-xm1jfl.1: "não consegui gravar/ler" lido como "nada pulou"). São TRÊS estados: li e nada pulou · li e pulou · não consegui ler.
#    O terceiro nunca pode dar o resultado do primeiro: o comando inteiro roda aqui, nada do MBP vale, e a nota de verde do MBP não sai.
# 5b-1 a linha-resumo "N passed in Xs" o pytest SEMPRE imprime, exceto sob -qq. Sem ela (fora de -qq) a saída está cortada ou ilegível.
for fl in "-q" "" "-x -q" "-v"; do
  reset; mbp_out "."; rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py $fl); expect "sem resumo fora de -qq [$fl]: o rc daqui vale (1), não o verde do MBP" 1 "$rc"
  has "sem resumo [$fl]: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "sem resumo [$fl]: saida-sem-resumo no log" "$LOG" 'saida-sem-resumo'; hasnt "sem resumo [$fl]: sem a nota de verde do MBP" "$T/out" 'nota: verde do MBP'
done
has "sem resumo: a saída diz que a linha-resumo faltou" "$T/out" 'não imprimiu a linha-resumo'
# lista SKIPPED PARCIAL sem resumo: o skip perdido é do test_a e o relato só traz o do test_b; sem a linha-resumo não há contagem para desconfiar → TODOS os alvos rodam aqui
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: sem dado"
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -q); expect "lista SKIPPED parcial sem resumo: o rc daqui vale (1)" 1 "$rc"
has_local "parcial sem resumo: o test_a (irmão do skip que se perdeu) roda aqui" "$STUB_LOG" 'arg:tests/test_a.py$'; has_local "parcial sem resumo: o test_b roda aqui" "$STUB_LOG" 'arg:tests/test_b.py$'
count "parcial sem resumo: UMA chamada local" "$STUB_LOG" 'LOCAL_CALL' 1; has "parcial sem resumo: no log" "$LOG" 'saida-sem-resumo'
# 5b-2 quando a falta do resumo é NORMAL (-qq, em qualquer grafia) e quando não é
for fl in -qq -qqq "-q -q" "--quiet --quiet" -xqq -qxq "-q --quiet"; do
  reset; mbp_out "."; rc=$(run -- tests/test_a.py $fl); expect "-qq [$fl]: a falta do resumo é normal" 0 "$rc"; hasnt "-qq [$fl]: não roda aqui" "$STUB_LOG" 'LOCAL_CALL'
done
for fl in -q -qv "-qq -v" "-q -v" -kqq "-n qq" "-p qq"; do   # um só q; -qq misturado com -v não se lê com segurança; o qq é valor de -k / -n / -p
  reset; mbp_out "."; rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py $fl); expect "sem -qq [$fl]: sem resumo é saída ilegível, o rc daqui vale (1)" 1 "$rc"; has "sem -qq [$fl]: saida-sem-resumo no log" "$LOG" 'saida-sem-resumo'
done
# 5b-3 rc 0 sem UMA linha de saída: a saída se perdeu (nem sob -qq o pytest imprime nada; sempre há a linha de progresso)
reset; rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py -qq); expect "saída vazia do MBP (rc 0): o rc daqui vale (1)" 1 "$rc"
has "saída vazia: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "saída vazia: mbp-saida-vazia no log" "$LOG" 'mbp-saida-vazia'; hasnt "saída vazia: sem a nota de verde do MBP" "$T/out" 'nota: verde do MBP'
# 5b-4 o `tee` que grava a saída FALHA (disco cheio; o gate reproduziu com o tee de verdade e `ulimit -f`; aqui um tee de PATH que se comporta igual: repassa tudo ao stdout, grava
#      nada (none) ou só a 1ª linha (first) no arquivo, e sai com 1). O registro fica vazio ou cortado e o pytest imprimiu um SKIPPED que se perdeu.
mkdir -p "$T/shadow-tee" "$T/shadow-grep"
cat > "$T/shadow-tee/tee" <<'EOF'
#!/usr/bin/env bash
f="$1"; : > "$f"; k=0
while IFS= read -r l || [ -n "$l" ]; do
  printf '%s\n' "$l"
  if [ "${STUB_TEE_KEEP:-none}" = first ] && [ $k -eq 0 ]; then printf '%s\n' "$l" > "$f"; fi
  k=$((k+1))
done
echo "tee: $f: No space left on device" >&2
exit 1
EOF
# grep que falha (rc 2, sem imprimir nada) quando os argumentos citam STUB_GREP_FAIL; senão é o grep de verdade
cat > "$T/shadow-grep/grep" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_GREP_FAIL:-}" ]; then case "$*" in *"$STUB_GREP_FAIL"*) exit 2 ;; esac; fi
exec "$REAL_GREP" "$@"
EOF
chmod +x "$T/shadow-tee/tee" "$T/shadow-grep/grep"; REAL_GREP=$(command -v grep); export REAL_GREP
tee_mbp_out() { mbp_out ".s" "=== short test summary info ===" "SKIPPED [1] tests/test_b.py:9: no data on the MBP"; }
# registro CORTADO depois da 1ª linha (".s"): sob -qq não há linha-resumo para desconfiar, e sem o SKIPPED o verde seria aceito — o falso verde que o gate reproduziu
reset; tee_mbp_out; rc=$(PATH="$T/shadow-tee:$PATH" STUB_TEE_KEEP=first STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -qq)
expect "tee falhou, registro cortado (-qq): o rc daqui vale (1), nunca o verde do MBP" 1 "$rc"
has_local "tee falhou: o test_a roda aqui" "$STUB_LOG" 'arg:tests/test_a.py$'; has_local "tee falhou: o test_b (o do skip perdido) roda aqui" "$STUB_LOG" 'arg:tests/test_b.py$'
count "tee falhou: UMA chamada local, com o comando inteiro" "$STUB_LOG" 'LOCAL_CALL' 1; has "tee falhou: mbp-saida-nao-gravada no log" "$LOG" 'mbp-saida-nao-gravada;tee-rc=1'
has "tee falhou: a saída DIZ que não gravou" "$T/out" 'não consegui gravar a saída do MBP'; hasnt "tee falhou: sem a nota de verde do MBP (nada do MBP foi aceito)" "$T/out" 'nota: verde do MBP'
has "tee falhou: ran=mbp+local" "$T/out" 'gate-pytest: ran=mbp\+local rc=1'
# registro VAZIO, fora de -qq, e o rerun daqui passa: o rc 0 é o do rerun, mas o rerun aconteceu
reset; tee_mbp_out; rc=$(PATH="$T/shadow-tee:$PATH" STUB_TEE_KEEP=none STUB_LOCAL_RCS=0 run -- tests/test_a.py -q); expect "tee falhou, registro vazio: o rerun daqui decide (0)" 0 "$rc"
has "tee vazio: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "tee vazio: mbp-saida-nao-gravada no log" "$LOG" 'mbp-saida-nao-gravada'; hasnt "tee vazio: sem a nota de verde do MBP" "$T/out" 'nota: verde do MBP'
# MBP vermelho (rc 1) e o tee falhou: não há ids confiáveis para confirmar isolado → o comando inteiro roda aqui
reset; mbp_red; rc=$(PATH="$T/shadow-tee:$PATH" STUB_TEE_KEEP=first STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -q); expect "tee falhou + MBP vermelho: o rc daqui vale (1)" 1 "$rc"
count "tee falhou + vermelho: UMA chamada local (o comando inteiro)" "$STUB_LOG" 'LOCAL_CALL' 1; hasnt "tee falhou + vermelho: nenhum id roda isolado" "$STUB_LOG" 'arg:tests/test_a.py::test_x'; has "tee falhou + vermelho: no log" "$LOG" 'mbp-saida-nao-gravada;tee-rc=1;mbp-rc=1'
# MBP indisponível (96..99) + tee falho: o MBP nem rodou, o comando daqui já é o de hoje — ran=local, sem alegar que o MBP rodou
reset; export STUB_MBP_RC=98; rc=$(PATH="$T/shadow-tee:$PATH" STUB_TEE_KEEP=none STUB_LOCAL_RCS=0 run -- tests/test_a.py -q); unset STUB_MBP_RC
expect "MBP fora (98) + tee falho" 0 "$rc"; has "98 + tee falho: ran=local" "$T/out" 'gate-pytest: ran=local rc=0'; hasnt "98 + tee falho: não alega saída não gravada" "$LOG" 'mbp-saida-nao-gravada'
# com divisão: a parte do MBP roda aqui inteira e a parte local roda uma vez só
reset; tee_mbp_out; rc=$(PATH="$T/shadow-tee:$PATH" STUB_TEE_KEEP=first STUB_LOCAL_RCS="0 0" run -- tests/test_a.py tests/test_db.py -qq); expect "tee falhou + divisão" 0 "$rc"
count "tee falhou + divisão: duas chamadas locais" "$STUB_LOG" 'LOCAL_CALL' 2; sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" > "$T/local-part.log"
count "tee falhou + divisão: test_a roda uma vez só" "$T/local-part.log" 'arg:tests/test_a.py$' 1; count "tee falhou + divisão: test_db roda uma vez só" "$T/local-part.log" 'arg:tests/test_db.py$' 1
# controle: com o tee BOM o mesmo MBP segue o caminho preciso (só o test_b, que pulou, volta aqui; o test_a foi aceito)
reset; tee_mbp_out; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -qq); expect "tee bom, mesmo MBP: o caminho preciso segue valendo" 0 "$rc"
has_local "tee bom: o test_b (pulou) roda aqui" "$STUB_LOG" 'arg:tests/test_b.py$'; sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" > "$T/local-only.log"; hasnt "tee bom: o test_a não volta" "$T/local-only.log" 'arg:tests/test_a.py$'
hasnt "tee bom: sem mbp-saida-nao-gravada" "$LOG" 'mbp-saida-nao-gravada'
# 5b-5 um grep que LÊ a saída falha (rc 2, sem imprimir nada): `grep -c` falho não imprime 0, imprime NADA, e ${sk_lines:-0} o leria como zero; `grep | tail` esconderia o rc do grep
reset; mbp_out ".s" "SKIPPED [1] tests/test_b.py:9: no data on the MBP"
rc=$(PATH="$T/shadow-grep:$PATH" STUB_GREP_FAIL='^SKIPPED' STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -qq); expect "grep -c dos SKIPPED falhou: o rc daqui vale (1), não o verde do MBP" 1 "$rc"
has_local "grep -c falhou: o test_a roda aqui" "$STUB_LOG" 'arg:tests/test_a.py$'; has "grep -c falhou: mbp-saida-ilegivel no log" "$LOG" 'mbp-saida-ilegivel'; hasnt "grep -c falhou: sem a nota de verde do MBP" "$T/out" 'nota: verde do MBP'
reset; mbp_out ".s" "SKIPPED [1] tests/test_b.py:9: no data on the MBP"
rc=$(PATH="$T/shadow-grep:$PATH" STUB_GREP_FAIL=' in [0-9.]+s' STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -qq); expect "grep da linha-resumo falhou: o rc daqui vale (1)" 1 "$rc"
has_local "grep do resumo falhou: o test_a roda aqui" "$STUB_LOG" 'arg:tests/test_a.py$'; has "grep do resumo falhou: mbp-saida-ilegivel no log" "$LOG" 'mbp-saida-ilegivel'
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
# a lista é O remédio do verde vazio: lista AUSENTE ou ilegível não é "lista vazia". Não dá para saber o que deveria ficar aqui → nada vai ao MBP, e a falta é DITA.
reset; mbp_out "1 passed in 0.1s"; rc=$(GATE_PYTEST_FORCE_LOCAL_LIST="$T/nao-existe.txt" run -- tests/test_a.py -q); expect "lista force-local ausente: roda aqui" 0 "$rc"
hasnt "lista ausente: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "lista ausente: motivo no log" "$LOG" 'lista-force-local-ilegivel'; has "lista ausente: o AVISO diz qual lista" "$T/out" 'AVISO: .*force-local.*nao-existe.txt'
reset; mbp_out "1 passed in 0.1s"; rc=$(GATE_PYTEST_FORCE_LOCAL_LIST="$T" run -- tests/test_a.py -q); expect "lista force-local que é um diretório: roda aqui" 0 "$rc"
hasnt "lista diretório: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "lista diretório: motivo no log" "$LOG" 'lista-force-local-ilegivel'
if [ "$(id -u)" != 0 ]; then
  : > "$T/force-noread.txt"; chmod 000 "$T/force-noread.txt"
  reset; mbp_out "1 passed in 0.1s"; rc=$(GATE_PYTEST_FORCE_LOCAL_LIST="$T/force-noread.txt" run -- tests/test_a.py -q); expect "lista force-local sem permissão: roda aqui" 0 "$rc"
  hasnt "lista sem permissão: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "lista sem permissão: motivo no log" "$LOG" 'lista-force-local-ilegivel'; chmod 644 "$T/force-noread.txt"
fi
# controle: lista VAZIA (legível, sem globs) é uma lista válida: o alvo vai ao MBP e nenhum aviso sai
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_a.py -q); expect "lista vazia é válida" 0 "$rc"; has "lista vazia: vai ao MBP" "$STUB_LOG" 'MBP_CALL'; hasnt "lista vazia: sem AVISO de lista" "$T/out" 'AVISO: .*force-local'
reset; rc=$(run -- tests -q); expect "diretório como alvo" 0 "$rc"; hasnt "diretório: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "diretório: motivo" "$LOG" 'alvo-diretorio'
reset; rc=$(run -- -q); expect "sem alvo" 0 "$rc"; has "sem alvo: motivo" "$LOG" 'sem-alvo-arquivo'
reset; rc=$(run -- tests/test_a.py --junitxml=/tmp/x.xml); expect "flag de disco local" 0 "$rc"; has "junitxml: motivo" "$LOG" 'flag-local:--junitxml'
reset; rc=$(run -- tests/test_a.py --lf); expect "--lf (cache daqui)" 0 "$rc"; hasnt "--lf: sem MBP" "$STUB_LOG" 'MBP_CALL'
# 7d as opções do plugin de CACHE dependem do cache DESTA máquina e só existem com o plugin ligado: rodam aqui, e o comando daqui NÃO leva -p no:cacheprovider
#    (o pytest recusa com rc 4 "unrecognized arguments"; sem o -p é o que o revisor rodava antes do wrapper). O stub rejeita a combinação como o pytest de verdade.
for fl in --lf --last-failed --ff --failed-first --nf --new-first --sw --stepwise --sw-skip --stepwise-skip --sw-reset --stepwise-reset --cache-clear --cache-show --cache-show=x --lfnf=none --last-failed-no-failures=all; do
  reset; rc=$(run -- tests/test_a.py "$fl" -q); expect "flag de cache $fl: roda aqui e o pytest não a recusa" 0 "$rc"
  hasnt "flag de cache $fl: sem MBP" "$STUB_LOG" 'MBP_CALL'; hasnt "flag de cache $fl: sem -p no:cacheprovider" "$STUB_LOG" 'no:cacheprovider'; has "flag de cache $fl: motivo no log" "$LOG" 'flag-local:'
done
# as de valor SEPARADO (--lfnf all): o valor não pode virar alvo
reset; rc=$(run -- tests/test_a.py --lfnf all -q); expect "--lfnf all (valor separado)" 0 "$rc"; hasnt "--lfnf all: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "--lfnf all: o motivo é a flag, não um alvo ilegível" "$LOG" 'flag-local:--lfnf'
reset; rc=$(run -- tests/test_a.py --last-failed-no-failures none -q); expect "--last-failed-no-failures none (valor separado)" 0 "$rc"; has "--last-failed-no-failures: o motivo é a flag" "$LOG" 'flag-local:--last-failed-no-failures'
reset; rc=$(run -- "$T/other/test_out.py" -q); expect "caminho absoluto fora do worktree" 0 "$rc"; hasnt "fora: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "fora: motivo" "$LOG" 'alvo-fora-do-worktree'
reset; rc=$(run -- tests/nao_existe.py -q); expect "alvo inexistente" 0 "$rc"; has "inexistente: motivo" "$LOG" 'alvo-ilegivel'
reset; rc=$("$GP" --dir "$T/wt" -- tests/test_a.py -q >"$T/out" 2>"$T/err"; echo $?); expect "repo sem espelho (nem wa nem ps)" 0 "$rc"
has "sem espelho: motivo" "$LOG" 'repo-sem-espelho'; hasnt "sem espelho: sem MBP" "$STUB_LOG" 'MBP_CALL'
# 7a0 o repo vem do repo do GIT (git-common-dir), nunca do NOME do diretório do worktree: um worktree do gascity cujo caminho cita "whatsapp_automation" NÃO é o WA
#     (rsync dele para o espelho do WA seria teste contra o código errado). Worktrees REAIS, sem --repo.
gitq() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@" 2>/dev/null; }
mkdir -p "$T/gr"
gitq init -q "$T/gr/gascity-repo"; gitq -C "$T/gr/gascity-repo" commit -q --allow-empty -m x
gitq -C "$T/gr/gascity-repo" worktree add -q "$T/gr/whatsapp_automation-lookalike" -b lookalike
gitq init -q "$T/gr/whatsapp_automation"; gitq -C "$T/gr/whatsapp_automation" commit -q --allow-empty -m x
gitq -C "$T/gr/whatsapp_automation" worktree add -q "$T/gr/wt-neutral" -b neutral
for w in whatsapp_automation-lookalike wt-neutral; do mkdir -p "$T/gr/$w/tests"; : > "$T/gr/$w/tests/test_a.py"; done
reset; mbp_out "1 passed in 0.1s"; rc=$("$GP" --dir "$T/gr/whatsapp_automation-lookalike" -- tests/test_a.py -q >"$T/out" 2>"$T/err"; echo $?); expect "worktree do gascity com 'whatsapp_automation' no NOME do diretório" 0 "$rc"
has "nome enganoso: motivo repo-sem-espelho" "$LOG" 'repo-sem-espelho'; hasnt "nome enganoso: sem MBP" "$STUB_LOG" 'MBP_CALL'
reset; mbp_out "1 passed in 0.1s"; rc=$("$GP" --dir "$T/gr/wt-neutral" -- tests/test_a.py -q >"$T/out" 2>"$T/err"; echo $?); expect "worktree do WA (git-common-dir) com nome neutro" 0 "$rc"
has "WA detectado pelo git: chamou o MBP com --repo wa" "$STUB_LOG" 'arg:wa'; has "WA detectado pelo git: ran=mbp" "$T/out" 'ran=mbp rc=0'

# 7a comentário que só cita shared/data NÃO manda o arquivo para cá (medido: falso positivo que jogava fora o ganho)
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_coment.py -q); expect "comentário com shared/data" 0 "$rc"
has "comentário: vai ao MBP" "$STUB_LOG" 'MBP_CALL'; hasnt "comentário: não roda aqui" "$STUB_LOG" 'LOCAL_CALL'

# 7a2 a assinatura tem de ser achada em arquivo GRANDE (> 64 KB: a leitura `grep -v | grep -q` morria de SIGPIPE sob pipefail e o arquivo ia ao MBP, onde
#     passa VAZIO), na última linha (controle: já achava), com byte NUL (grep sem -a devolve "Binary file matches") e com byte não-UTF-8 (controle).
#     É uma corrida, então 10 execuções: UMA que escape reprova.
for f in test_big test_bigend test_nul test_latin; do
  stay=0
  for i in 1 2 3 4 5 6 7 8 9 10; do reset; mbp_out "1 passed in 0.1s"; run -- "tests/$f.py" -q >/dev/null; grep -q 'MBP_CALL' "$STUB_LOG" || stay=$((stay+1)); done
  n=$((n+1)); if [ "$stay" = 10 ]; then echo "ok   $f cita shared/data: ficou aqui nas 10 execuções"; else echo "FAIL $f cita shared/data: só ficou aqui $stay de 10 (a leitura da assinatura perdeu a corrida de SIGPIPE, ou tomou o arquivo por binário, e o alvo foi ao MBP)"; fails=$((fails+1)); fi
done
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_big.py -q); expect "arquivo grande que lê shared/data" 0 "$rc"; has "grande: o motivo diz qual arquivo" "$LOG" 'le-shared-data:tests/test_big.py'
# controle: grande mas a única citação é comentário → continua indo ao MBP (a correção não pode mandar tudo para cá)
reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_bigcoment.py -q); expect "arquivo grande que só cita num comentário" 0 "$rc"
has "grande só-comentário: vai ao MBP" "$STUB_LOG" 'MBP_CALL'; hasnt "grande só-comentário: não roda aqui" "$STUB_LOG" 'LOCAL_CALL'
# arquivo que o wrapper não consegue ler: fica AQUI (nunca vai ao MBP no escuro)
if [ "$(id -u)" != 0 ]; then
  : > "$T/wt/tests/test_noread.py"; chmod 000 "$T/wt/tests/test_noread.py"
  reset; mbp_out "1 passed in 0.1s"; rc=$(run -- tests/test_noread.py -q); expect "alvo ilegível (sem permissão)" 0 "$rc"
  hasnt "ilegível: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "ilegível: motivo" "$LOG" 'alvo-ilegivel:tests/test_noread.py'
  chmod 644 "$T/wt/tests/test_noread.py"
fi

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
# a saída do MBP que não se sabe ler (tee que falhou, vazia, sem resumo, grep com erro) tem os 4 motivos no cabeçalho, e o cabeçalho não promete uma ÚNICA coisa aceita como veio
for why in mbp-saida-nao-gravada mbp-saida-vazia mbp-saida-ilegivel saida-sem-resumo; do has "--help traz o motivo $why" "$T/help" "$why"; done
hasnt "--help não chama o verde sem pulados de ÚNICA coisa aceita (o caso parcial também aceita)" "$T/help" 'ÚNICA coisa aceita'

# 15 OS IDS NO LOG (ga-kqg1gi): a linha mbp+local diz QUAIS testes reprovaram no MBP e passaram aqui (red_ids) e QUAIS pularam no MBP (skip). Sem isso o placar só sabe
#    CONTAR o vermelho falso e o pulo (52 e 64 corridas na semana de 11/10) e ninguém consegue dizer qual teste/fixture/pacote do nó é o culpado.
#    É telemetria: nenhum destes campos muda o rc nem o que roda aqui. Campo ausente = a linha não tem o que dizer (o motivo está em `detail`).
if command -v python3 >/dev/null 2>&1; then
  # a linha é JSON montado à mão no bash: o `has` vê texto, só o parser vê se o JSON é válido e o que cada campo vale (a ÚLTIMA linha do log)
  jvalid() { n=$((n+1)); if python3 -I -c 'import json,sys
for l in open(sys.argv[1]): json.loads(l)' "$2" 2>/dev/null; then echo "ok   $1"; else echo "FAIL $1: o log não é JSON válido ($2): $(tail -1 "$2" 2>/dev/null | cut -c1-300)"; fails=$((fails+1)); fi; }
  # o eval roda SÓ as expressões escritas neste arquivo (o 3º argumento do jpy); nada que veio do log ou da saída do MBP chega nele
  jpy() { n=$((n+1)); if python3 -I -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r=rows[-1]
sys.exit(0 if eval(sys.argv[2]) else 1)' "$2" "$3" 2>/dev/null; then echo "ok   $1"; else echo "FAIL $1: ($3) é falso em $2: $(tail -1 "$2" 2>/dev/null | cut -c1-300)"; fails=$((fails+1)); fi; }

  # 15a o vermelho do MBP que PASSA isolado aqui: os ids vão para o log, o detail segue igual
  reset; mbp_red; rc=$(STUB_LOCAL_RCS="0 0" run -- tests/test_a.py tests/test_b.py -q); expect "15a: vermelho que passa isolado e no comando inteiro" 0 "$rc"
  jvalid "15a: a linha do log é JSON válido" "$LOG"
  jpy "15a: red_ids traz os ids que reprovaram no MBP e passaram aqui" "$LOG" 'r["red_ids"]==["tests/test_a.py::test_x","tests/test_b.py"]'
  jpy "15a: red_n conta os ids" "$LOG" 'r["red_n"]==2'
  has "15a: o detail segue dizendo isolado-passou;inteiro-rc=0" "$LOG" 'isolado-passou;inteiro-rc=0'
  jpy "15a: sem pulados, sem campos de skip" "$LOG" '"skip" not in r and "skip_n" not in r'
  # 15b passou isolado mas o comando inteiro reprova aqui (ordem, -x): os ids são do mesmo jeito os que passaram isolados; o inteiro-rc fica no detail para quem cruza
  reset; mbp_red; rc=$(STUB_LOCAL_RCS="0 1" run -- tests/test_a.py tests/test_b.py -x -q); expect "15b: passa isolado, o inteiro reprova" 1 "$rc"
  jpy "15b: red_ids presente" "$LOG" 'r["red_ids"]==["tests/test_a.py::test_x","tests/test_b.py"] and r["red_n"]==2'; has "15b: o detail diz inteiro-rc=1" "$LOG" 'isolado-passou;inteiro-rc=1'
  # 15c o vermelho que o rerun daqui CONFIRMA não é vermelho falso: os ids não entram (não se sabe QUAL dos ids reprovou aqui, e é vermelho real)
  reset; mbp_red; rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -q); expect "15c: vermelho confirmado aqui" 1 "$rc"
  jpy "15c: confirmado → sem red_ids" "$LOG" '"red_ids" not in r and "red_n" not in r'; has "15c: o detail diz local-confirmou" "$LOG" 'local-confirmou'
  reset; mbp_red; rc=$(STUB_LOCAL_RCS=3 run -- tests/test_a.py tests/test_b.py -q); expect "15c: rerun daqui morre (rc 3)" 3 "$rc"; jpy "15c: rc 3 aqui → sem red_ids" "$LOG" '"red_ids" not in r'
  # 15d não sei quais passaram aqui (muitos, id fora dos alvos, ids que não se reconhecem, sem ids): nada é afirmado — o detail diz por quê
  reset; { for i in $(seq 1 51); do echo "FAILED tests/test_a.py::t$i - x"; done; echo "51 failed in 1s"; } > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out" STUB_MBP_RC=1
  rc=$(STUB_LOCAL_RCS="0" run -- tests/test_a.py -q); expect "15d: 51 reprovados" 0 "$rc"; jpy "15d: muitos → sem red_ids" "$LOG" '"red_ids" not in r and "red_n" not in r'; has "15d: muitos no detail" "$LOG" 'muitos'
  reset; mbp_out "FAILED tests/outro.py::test_x - boom" "1 failed in 0.9s"; export STUB_MBP_RC=1
  rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "15d: id fora dos alvos" 0 "$rc"; jpy "15d: fora dos alvos → sem red_ids" "$LOG" '"red_ids" not in r'; has "15d: ids-fora-dos-alvos no detail" "$LOG" 'ids-fora-dos-alvos'
  reset; mbp_red; rc=$(STUB_LOCAL_RCS="4 0" run -- tests/test_a.py tests/test_b.py -q); expect "15d: ids que não se reconhecem aqui (rc 4)" 0 "$rc"; jpy "15d: ids-ilegiveis → sem red_ids" "$LOG" '"red_ids" not in r'
  reset; mbp_out "1 failed in 0.5s"; export STUB_MBP_RC=1; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py -q); expect "15d: rc 1 sem linhas FAILED" 0 "$rc"; jpy "15d: sem-ids → sem red_ids" "$LOG" '"red_ids" not in r'
  # 15e lista longa: o log guarda no máximo 20 ids (a linha tem de caber numa gravação só) e red_n diz quantos eram de verdade
  reset; { for i in $(seq 1 25); do echo "FAILED tests/test_a.py::t$i - x"; done; echo "25 failed in 1s"; } > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out" STUB_MBP_RC=1
  rc=$(STUB_LOCAL_RCS="0 0" run -- tests/test_a.py -q); expect "15e: 25 reprovados passam isolados" 0 "$rc"
  jpy "15e: 20 ids no log" "$LOG" 'len(r["red_ids"])==20'; jpy "15e: red_n diz 25" "$LOG" 'r["red_n"]==25'; jvalid "15e: JSON válido" "$LOG"
  # 15f id enorme: cada id é cortado em 120 caracteres e a linha inteira fica abaixo de 4096 bytes (o limite de uma gravação do stdio)
  reset; { for i in $(seq 1 40); do printf 'FAILED tests/test_a.py::test_%s_%s - x\n' "$i" "$(awk 'BEGIN{for(i=0;i<300;i++) printf "z"}')"; done; echo "40 failed in 1s"; } > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out" STUB_MBP_RC=1
  rc=$(STUB_LOCAL_RCS="0 0" run -- tests/test_a.py -q); expect "15f: 40 ids de 300 caracteres" 0 "$rc"
  jpy "15f: cada id tem no máximo 120 caracteres" "$LOG" 'len(r["red_ids"])>0 and all(len(x)<=120 for x in r["red_ids"])'; jpy "15f: a linha cabe em 4096 bytes" "$LOG" 'len(open(sys.argv[1],"rb").read().splitlines()[-1])<4096'
  jpy "15f: red_n diz 40" "$LOG" 'r["red_n"]==40'
  # 15g aspas, barra, espaço e byte não-ASCII no id: o JSON continua válido (aspas e barra caem como no detail; o resto do id fica reconhecível)
  reset; mbp_out 'FAILED tests/test_a.py::test_q[a"b\c é d] - boom' "1 failed in 0.9s"; export STUB_MBP_RC=1
  rc=$(STUB_LOCAL_RCS="0 0" run -- tests/test_a.py -q); expect "15g: id com aspas, barra e acento" 0 "$rc"
  jvalid "15g: JSON válido" "$LOG"; jpy "15g: o id sai só com ASCII imprimível, sem aspas nem barra" "$LOG" 'r["red_ids"]==["tests/test_a.py::test_q[abc  d]"]'
  unset STUB_MBP_RC

  # 15h pulados no MBP: cada linha SKIPPED vai ao log como "[n] arquivo:linha: motivo", e skip_n é o total
  reset; mbp_out "SKIPPED [2] tests/test_b.py:9: sem dado" "3 passed, 2 skipped in 1.0s"
  rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "15h: pulados no MBP" 0 "$rc"
  jvalid "15h: JSON válido" "$LOG"; jpy "15h: skip traz a linha SKIPPED" "$LOG" 'r["skip"]==["[2] tests/test_b.py:9: sem dado"]'; jpy "15h: skip_n é 2" "$LOG" 'r["skip_n"]==2'
  has "15h: o detail segue dizendo skips-no-mbp:2" "$LOG" 'skips-no-mbp:2'; jpy "15h: sem red_ids" "$LOG" '"red_ids" not in r and "red_n" not in r'
  # 15i o MOTIVO vai junto: é ele que separa o pulo por desenho (só macOS) do que o nó resolve (pacote que falta). Ordem e texto do pytest, sem reescrever.
  reset; mbp_out "SKIPPED [1] tests/test_b.py:9: requires macOS (darwin only)" "SKIPPED [3] tests/test_a.py:4: could not import 'fitz': No module named 'fitz'" "5 passed, 4 skipped in 1.0s"
  rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "15i: dois motivos de pulo" 0 "$rc"
  jpy "15i: os dois motivos vão como o pytest os imprimiu" "$LOG" 'r["skip"]==["[1] tests/test_b.py:9: requires macOS (darwin only)","[3] tests/test_a.py:4: could not import '"'"'fitz'"'"': No module named '"'"'fitz'"'"'"]'
  jpy "15i: skip_n é o total do resumo (4)" "$LOG" 'r["skip_n"]==4'
  # 15j skip que vem de um helper (fora dos alvos): continua pulado no MBP, continua no log
  reset; mbp_out "SKIPPED [2] tests/helpers.py:3: sem dado" "2 skipped in 0.1s"; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "15j: skip de helper" 0 "$rc"
  jpy "15j: o skip do helper está no log" "$LOG" 'r["skip"]==["[2] tests/helpers.py:3: sem dado"] and r["skip_n"]==2'; has "15j: o detail diz skips-fora-dos-alvos" "$LOG" 'skips-fora-dos-alvos'
  # 15k sob -qq não há linha-resumo: skip_n vem da soma das linhas SKIPPED
  reset; mbp_out ".s" "SKIPPED [1] tests/test_b.py:9: x"; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -qq); expect "15k: -qq com um pulado" 0 "$rc"
  jpy "15k: skip_n vem da soma das linhas" "$LOG" 'r["skip_n"]==1 and r["skip"]==["[1] tests/test_b.py:9: x"]'
  # 15l o resumo diz que pulou e NÃO há linha para listar (--no-summary): o total é dito, a lista não é inventada
  reset; mbp_out "= 1 passed, 2 skipped in 0.1s ="; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py --no-summary); expect "15l: resumo sem linhas SKIPPED" 0 "$rc"
  jpy "15l: skip_n 2 e nenhuma lista" "$LOG" 'r["skip_n"]==2 and "skip" not in r'
  # 15m a leitura das linhas SKIPPED para o log FALHA (grep com erro) — só ela, a contagem do rc 0 continua lendo: o rc e o que roda aqui não mudam, o total sai, a lista não
  reset; mbp_out "SKIPPED [1] tests/test_b.py:9: x" "1 passed, 1 skipped in 0.1s"
  rc=$(PATH="$T/shadow-grep:$PATH" STUB_GREP_FAIL='[0-9]+\] ' STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "15m: grep da lista SKIPPED falhou" 0 "$rc"
  has_local "15m: o arquivo que pulou segue rodando aqui" "$STUB_LOG" 'arg:tests/test_b.py$'; has "15m: o detail segue skips-no-mbp:1" "$LOG" 'skips-no-mbp:1'
  jvalid "15m: JSON válido"  "$LOG"; jpy "15m: total sem lista (a falha de leitura não vira lista vazia nem inventada)" "$LOG" 'r["skip_n"]==1 and "skip" not in r'
  # 15n 25 linhas SKIPPED de 300 caracteres: no máximo 20 entradas de até 120 caracteres; skip_n diz 25
  reset; { for i in $(seq 1 25); do printf 'SKIPPED [1] tests/test_b.py:%s: %s\n' "$i" "$(awk 'BEGIN{for(i=0;i<300;i++) printf "m"}')"; done; echo "25 skipped in 1s"; } > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out"
  rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "15n: 25 pulados" 0 "$rc"
  jpy "15n: 20 entradas de até 120 caracteres" "$LOG" 'len(r["skip"])==20 and all(len(x)<=120 for x in r["skip"])'; jpy "15n: skip_n diz 25" "$LOG" 'r["skip_n"]==25'; jpy "15n: a linha cabe em 4096 bytes" "$LOG" 'len(open(sys.argv[1],"rb").read().splitlines()[-1])<4096'
  # 15o verde limpo: a linha é a de sempre, sem campo novo
  reset; mbp_out "2 passed in 1.0s"; rc=$(run -- tests/test_a.py tests/test_b.py -q); expect "15o: verde limpo" 0 "$rc"
  jpy "15o: nenhum campo novo" "$LOG" 'not ({"red_ids","red_n","skip","skip_n"} & set(r))'; has "15o: a linha segue terminando em ntargets" "$LOG" '"ntargets":2\}$'
  # 15p o cabeçalho (--help) diz os campos novos
  "$GP" --help > "$T/help" 2>&1; has "15p: --help traz red_ids" "$T/help" 'red_ids'; has "15p: --help traz skip_n" "$T/help" 'skip_n'
else
  echo "SKIP caso 15 (ids no log): este ambiente não tem python3 para ler o JSON — nada foi medido (os casos acima seguem valendo)"
fi

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
# controle negativo G: sem a checagem do status do tee, o registro cortado (".s", sem o SKIPPED) é lido como "nada pulou" → falso verde: rc 0 e NADA roda aqui — o caso 5b-4 tem de enxergar isso
sed 's|^  if \[ "\${PST\[1\]:-x}" != 0 \]; then$|  if false; then|' "$GP" > "$T/mutG.sh"; chmod +x "$T/mutG.sh"
cmp -s "$GP" "$T/mutG.sh" && { n=$((n+1)); echo "FAIL controle G: o mutante é idêntico ao original (sed não casou)"; fails=$((fails+1)); } || {
  reset; tee_mbp_out; PATH="$T/shadow-tee:$PATH" STUB_TEE_KEEP=first STUB_LOCAL_RCS=1 "$T/mutG.sh" --repo wa --dir "$T/wt" -- tests/test_a.py tests/test_b.py -qq >"$T/out" 2>&1; r=$?
  n=$((n+1)); if [ "$r" = 0 ] && ! grep -q 'LOCAL_CALL' "$STUB_LOG"; then echo "ok   controle G (mutante sem o status do tee aceita o verde cortado: rc 0 e nada roda aqui — o caso 5b-4 pegaria)"; else echo "FAIL controle G: o mutante não aceitou o verde cortado (rc=$r)"; fails=$((fails+1)); fi; }
# controle negativo H: sem a exigência da linha-resumo fora de -qq, uma lista SKIPPED parcial deixa o irmão do skip perdido (test_a) sem rodar aqui — o caso 5b-1 tem de enxergar isso
sed 's|^      elif \[ -z "\$summary" \] && ! user_qq; then$|      elif false; then|' "$GP" > "$T/mutH.sh"; chmod +x "$T/mutH.sh"
cmp -s "$GP" "$T/mutH.sh" && { n=$((n+1)); echo "FAIL controle H: o mutante é idêntico ao original (sed não casou)"; fails=$((fails+1)); } || {
  reset; mbp_out "SKIPPED [1] tests/test_b.py:9: sem dado"; STUB_LOCAL_RCS=1 "$T/mutH.sh" --repo wa --dir "$T/wt" -- tests/test_a.py tests/test_b.py -q >/dev/null 2>&1
  n=$((n+1)); if sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" | grep -q 'arg:tests/test_a.py$'; then echo "FAIL controle H: o mutante ainda rodou o test_a aqui"; fails=$((fails+1)); else echo "ok   controle H (mutante sem a exigência do resumo deixa o test_a sem rodar — o caso 5b-1 pegaria)"; fi; }
# controle negativo I: a leitura antiga (rc do grep ignorado, contagem vazia lida como 0) → um `grep -c` que falhou vira "nada pulou": falso verde — o caso 5b-5 tem de enxergar isso
sed -e 's/g_sum=\$?/g_sum=0/' -e 's/g_cnt=\$?/g_cnt=0/' -e 's/ rec_bad="mbp-saida-ilegivel" ;; esac$/ sk_lines=0 ;; esac/' "$GP" > "$T/mutI.sh"; chmod +x "$T/mutI.sh"
cmp -s "$GP" "$T/mutI.sh" && { n=$((n+1)); echo "FAIL controle I: o mutante é idêntico ao original (sed não casou)"; fails=$((fails+1)); } || {
  grep -q 'g_cnt=0' "$T/mutI.sh" && grep -q 'sk_lines=0 ;; esac' "$T/mutI.sh" || { n=$((n+1)); echo "FAIL controle I: o sed não trocou as duas leituras"; fails=$((fails+1)); }
  reset; mbp_out ".s" "SKIPPED [1] tests/test_b.py:9: no data on the MBP"; PATH="$T/shadow-grep:$PATH" STUB_GREP_FAIL='^SKIPPED' STUB_LOCAL_RCS=1 "$T/mutI.sh" --repo wa --dir "$T/wt" -- tests/test_a.py tests/test_b.py -qq >"$T/out" 2>&1; r=$?
  n=$((n+1)); if [ "$r" = 0 ] && ! grep -q 'LOCAL_CALL' "$STUB_LOG"; then echo "ok   controle I (mutante com a leitura antiga aceita o verde: rc 0 e nada roda aqui — o caso 5b-5 pegaria)"; else echo "FAIL controle I: o mutante não aceitou o verde (rc=$r)"; fails=$((fails+1)); fi; }

# controle negativo E: a leitura antiga da assinatura (`grep -v | grep -q` sob pipefail) volta → o arquivo grande vai ao MBP — o caso 7a2 tem de enxergar isso
sed 's@^  case "[$]body" in [*]shared/data[*]) return 0 ;; esac$@  if grep -v -E "^[[:space:]]*#" "$1" 2>/dev/null | grep -q shared/data; then return 0; fi@' "$GP" > "$T/mutE.sh"; chmod +x "$T/mutE.sh"
cmp -s "$GP" "$T/mutE.sh" && { n=$((n+1)); echo "FAIL controle E: o mutante é idêntico ao original (sed não casou)"; fails=$((fails+1)); } || {
  escaped=0; for i in 1 2 3 4 5 6 7 8 9 10; do reset; mbp_out "1 passed in 0.1s"; "$T/mutE.sh" --repo wa --dir "$T/wt" -- tests/test_big.py -q >/dev/null 2>&1; grep -q 'MBP_CALL' "$STUB_LOG" && escaped=$((escaped+1)); done
  n=$((n+1)); if [ "$escaped" -ge 1 ]; then echo "ok   controle E (mutante com a leitura antiga mandou o arquivo grande ao MBP em $escaped de 10 — o caso 7a2 pegaria)"; else echo "FAIL controle E: o mutante com a leitura antiga também manteve o arquivo grande aqui — o caso 7a2 não enxerga a corrida"; fails=$((fails+1)); fi; }
# controle negativo F: o -p no:cacheprovider volta ao comando daqui → as opções de cache voltam a ser recusadas (rc 4) — o caso 7d tem de enxergar isso
sed 's|exec "[$]PY" -m pytest "[$]@"|exec "$PY" -m pytest -p no:cacheprovider "$@"|' "$GP" > "$T/mutF.sh"; chmod +x "$T/mutF.sh"
cmp -s "$GP" "$T/mutF.sh" && { n=$((n+1)); echo "FAIL controle F: o mutante é idêntico ao original (sed não casou)"; fails=$((fails+1)); } || {
  reset; "$T/mutF.sh" --repo wa --dir "$T/wt" -- tests/test_a.py --lf -q >/dev/null 2>&1; r=$?
  n=$((n+1)); if [ "$r" = 4 ]; then echo "ok   controle F (mutante com -p no:cacheprovider devolve 4 em --lf — o caso 7d pegaria)"; else echo "FAIL controle F: o mutante devolveu $r"; fails=$((fails+1)); fi; }

# 14 pytest DE VERDADE (quando o python3 daqui o tem): o stub não prova que o pytest aceita o que o wrapper lhe passa. O rc do wrapper tem de ser o do pytest puro.
if python3 -c 'import pytest' 2>/dev/null; then
  mkdir -p "$T/real/tests"; printf 'def test_one():\n    assert True\n' > "$T/real/tests/test_one.py"
  for fl in --lf --last-failed --ff --nf --sw --sw-skip --sw-reset --cache-clear --cache-show; do
    plain=$(cd "$T/real" && python3 -m pytest tests/test_one.py "$fl" -q >/dev/null 2>&1; echo $?)
    reset; rc=$(GATE_PYTEST_PY=python3 "$GP" --repo wa --dir "$T/real" -- tests/test_one.py "$fl" -q >"$T/out" 2>"$T/err"; echo $?)
    expect "pytest DE VERDADE: o wrapper devolve o rc do pytest puro em $fl (puro=$plain)" "$plain" "$rc"
  done
  reset; rc=$(GATE_PYTEST_PY=python3 "$GP" --repo wa --dir "$T/real" -- tests/test_one.py --lfnf all -q >"$T/out" 2>"$T/err"; echo $?); expect "pytest DE VERDADE: --lfnf all (valor separado)" 0 "$rc"
else
  echo "SKIP pytest de verdade: este python3 não tem pytest — nada foi medido contra o pytest real (os casos com stub acima seguem valendo)"
fi

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
