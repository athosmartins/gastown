#!/usr/bin/env bash
# gate-pytest.selftest.sh — hermético: mbp-run.sh e o python3 são stubs; nada toca o MBP, o live nem o city real.
#
# Contents
#   Casos · Controle negativo
#
# CASOS: verde no MBP (não roda aqui) · MBP indisponível 96..99 → roda aqui o comando de hoje · chave off · vermelho do MBP → só os
#   node ids rodam aqui e o rc de LÁ vale (confirmou / não confirmou / ids ilegíveis / sem ids / muitos) · pulados no MBP → os arquivos
#   que pularam rodam aqui · sem resumo + -r do revisor → roda aqui · rc estranho do MBP → roda aqui · alvo que lê shared/data, lista
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

# 2 MBP indisponível: 96..99 → roda aqui o MESMO comando, rc de lá
for code in 96 97 98 99; do
  reset; STUB_MBP_RC=$code STUB_LOCAL_RCS=3 run -- tests/test_a.py -x -q >/dev/null; rc=$(STUB_MBP_RC=$code STUB_LOCAL_RCS=3 run -- tests/test_a.py -x -q)
  expect "mbp rc=$code roda aqui e devolve o rc de lá" 3 "$rc"
done
reset; export STUB_MBP_RC=98; rc=$(run -- tests/test_a.py -x -q); unset STUB_MBP_RC
expect "98 + local verde = 0 (nunca 98)" 0 "$rc"; has "98: ran=local" "$T/out" 'ran=local rc=0'
has "98: o comando local é o de hoje (-p no:cacheprovider + os args do revisor)" "$STUB_LOG" 'arg:-p'; has "98: roda no worktree" "$STUB_LOG" "LOCAL_CALL cwd=.*wt"
has "98: motivo no log" "$LOG" 'mbp-rc=98'

# 3 chave off: nem chama o MBP
reset; touch "$T/city/.gc/gate-pytest.off"; rc=$(run -- tests/test_a.py -q); expect "chave gate-pytest.off" 0 "$rc"
hasnt "off: não chama o MBP" "$STUB_LOG" 'MBP_CALL'; has "off: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "off: motivo" "$LOG" 'chave-gate-pytest-off'

# 4 vermelho do MBP: só os node ids rodam aqui; vale o rc de LÁ
mbp_red() { mbp_out "FAILED tests/test_a.py::test_x - AssertionError: boom" "ERROR tests/test_b.py - ImportError: nope" "1 failed, 1 error in 0.9s"; export STUB_MBP_RC=1; }
reset; mbp_red; STUB_LOCAL_RCS=1 rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py tests/test_b.py -x -q); expect "vermelho confirmado aqui" 1 "$rc"
has "vermelho: só os ids rodam aqui" "$STUB_LOG" 'arg:tests/test_a.py::test_x'; has "vermelho: o erro de coleta roda aqui" "$STUB_LOG" 'arg:tests/test_b.py$'
count "vermelho: UMA chamada local" "$STUB_LOG" 'LOCAL_CALL' 1; has "vermelho: motivo local-confirmou" "$LOG" 'local-confirmou'
has "vermelho: flags do revisor mantidas na confirmação" "$STUB_LOG" 'arg:-x'
reset; mbp_red; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "vermelho do MBP que passa aqui vale o daqui" 0 "$rc"
has "não-confirmou: AVISO dito" "$T/out" 'AVISO: 2 teste\(s\) reprovaram no MBP e PASSARAM aqui'; has "não-confirmou: no log" "$LOG" 'local-NAO-confirmou'
reset; mbp_red; rc=$(STUB_LOCAL_RCS="4 1" run -- tests/test_a.py tests/test_b.py -q); expect "ids ilegíveis aqui (rc 4) → comando inteiro" 1 "$rc"
count "ilegíveis: duas chamadas locais" "$STUB_LOG" 'LOCAL_CALL' 2; has "ilegíveis: no log" "$LOG" 'ids-ilegiveis'
reset; mbp_out "1 failed in 0.5s"; export STUB_MBP_RC=1; rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py -q); expect "rc 1 sem linhas FAILED → comando inteiro aqui" 1 "$rc"
has "sem ids: no log" "$LOG" 'sem-ids'; has "sem ids: o comando inteiro (arquivo de teste)" "$STUB_LOG" 'arg:tests/test_a.py'
reset; { for i in $(seq 1 51); do echo "FAILED tests/test_a.py::t$i - x"; done; echo "51 failed in 1s"; } > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out" STUB_MBP_RC=1
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_a.py -q); expect "51 reprovados → comando inteiro aqui" 1 "$rc"; has "muitos: no log" "$LOG" 'muitos'; hasnt "muitos: não manda 51 ids" "$STUB_LOG" 'test_a.py::t3'

# 5 pulados no MBP
reset; mbp_out "SKIPPED [2] tests/test_b.py:9: sem dado" "3 passed, 2 skipped in 1.0s"
rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py tests/test_b.py -q); expect "pulados no MBP" 0 "$rc"
count "pulados: UMA chamada local" "$STUB_LOG" 'LOCAL_CALL' 1; has "pulados: só o arquivo que pulou" "$STUB_LOG" 'arg:tests/test_b.py$'; sed -n '/^LOCAL_CALL/,$p' "$STUB_LOG" > "$T/local-only.log"; hasnt "pulados: o arquivo que não pulou não volta aqui" "$T/local-only.log" 'arg:tests/test_a.py$'
has "pulados: no log" "$LOG" 'skips-no-mbp'
reset; mbp_out "SKIPPED [1] tests/test_b.py:9: sem dado" "1 skipped in 0.1s"
rc=$(STUB_LOCAL_RCS=1 run -- tests/test_b.py -q); expect "pulado que falha aqui devolve o rc de lá" 1 "$rc"
# sem pulados + sem resumo (-qq) e sem -r do revisor = nada pulou
reset; mbp_out "."; rc=$(run -- tests/test_a.py -qq); expect "sem resumo, sem -r do revisor, rc 0" 0 "$rc"; hasnt "-qq: não roda aqui" "$STUB_LOG" 'LOCAL_CALL'
# sem resumo + -r do revisor = não sei se pulou → aqui
reset; mbp_out "."; rc=$(run -- tests/test_a.py -qq -ra); expect "sem resumo + -ra do revisor" 0 "$rc"; has "sem resumo + -r: roda aqui" "$STUB_LOG" 'LOCAL_CALL'; has "no log: skips-ilegiveis" "$LOG" 'skips-ilegiveis'

# 6 rc estranho do MBP (2, 5, 124...) → comando inteiro aqui
for code in 2 3 4 5 124; do reset; export STUB_MBP_RC=$code; rc=$(STUB_LOCAL_RCS=0 run -- tests/test_a.py -q); unset STUB_MBP_RC
  expect "mbp rc=$code → roda aqui" 0 "$rc"; has "mbp rc=$code: motivo no log" "$LOG" "mbp-rc=$code"; done

# 7 alvos que ficam aqui, sem chamar o MBP
reset; rc=$(run -- tests/test_db.py -q); expect "lê shared/data" 0 "$rc"; hasnt "shared/data: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "shared/data: motivo" "$LOG" 'le-shared-data:tests/test_db.py'
reset; echo 'tests/test_b.py' > "$T/force-local.txt"; rc=$(run -- tests/test_b.py -q); expect "lista force-local" 0 "$rc"
hasnt "lista: sem MBP" "$STUB_LOG" 'MBP_CALL'; has "lista: motivo" "$LOG" 'lista-local:tests/test_b.py'
reset; printf '# comentário\n\ntests/sub/*\n' > "$T/force-local.txt"; rc=$(run -- tests/sub/test_c.py -q); expect "glob da lista" 0 "$rc"; has "glob: motivo" "$LOG" 'lista-local:tests/sub/\*'
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

# 10 sessão no log
reset; mbp_out "1 passed in 0.1s"; GC_SESSION_NAME=gate-reviewer-xyz run -- tests/test_a.py -q >/dev/null
rc=$(GC_SESSION_NAME=gate-reviewer-xyz run -- tests/test_a.py -q); has "log traz a sessão do revisor" "$LOG" '"session":"gate-reviewer-xyz"'

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

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
