#!/usr/bin/env bash
# hetzner-nightly-tests.selftest.sh — hermético: mbp-run, ssh e e-mail são stubs; nada toca o nó, o Mayor nem o live (ga-9p6pte).
#
# ## Contents
#   Casos · Controles negativos
#
# IDS REPROVADOS: vêm do plugin (linhas `GTN-FAIL: <id em JSON>` + `GTN-FAILED: n=.. reports=..`), nunca da linha humana `FAILED <id> - <msg>` (id de parametrize pode ter " - "). A saída de
#   mentira traz AS DUAS formas, como o pytest de verdade, com ids que têm " - " dentro.
# LOTES (ga-84gkpab): a suíte roda em lotes por arquivo (um mbp-run + um pytest NOVO por lote). O WA de mentira tem 5 arquivos de teste de verdade em tests/ (23 `def test_`) e 6 que a poda tem de
#   ignorar (venv, .hidden, crew, archive, node_modules, helper.py). Com HZN_BATCH_DEFS=10 dá 3 lotes; o stub devolve uma saída e um rc POR CHAMADA (STUB_OUT.<n>, STUB_RC_<n>).
#   Casos de lote: batches (soma, união de ids, poda, 3 chamadas) · batch_list (lista de um lote inconsistente = comparação indisponível) · overbudget (lote que não coube no orçamento NÃO RODOU) ·
#   batch_killed (rc 137) · crash (worker do xdist caiu) · nocap (sem a prova do teto) · cap_inert / cap_retry / cap_late (teto inerte: INERTE no 1º lote, retry, não rodou nos outros) ·
#   leak_mid (vazamento no meio para tudo) · flag_mid · badconst · notests · nobatch (não montou os lotes: a noite AINDA grava a linha do jsonl) · escudo (GTN-ESCUDO somado no relatório e no jsonl; ilegível = "?"/null).
# CASOS: 1ª noite COMPLETO (linha de base, argumentos do mbp-run, árvore só do versionado, scratch apagado) · 2ª noite (novas/corrigidas) · sem falhas e depois
#   falha contra baseline vazio · xfailed/xpassed/error contados à parte · INERTE (inerte e nao-isolado: nada divulgado, baseline intacta) · rc 97 sem linha de
#   isolamento é FALHOU · PULADO (rc 99, sem e-mail) · prazo (124) · pytest abortado · terminou SEM prova de isolamento · sem resumo · total implausível ·
#   lock vivo (PULADO) e lock de dono morto (toma) · baseline ilegível (nunca "0 novas") · e-mail que falha · contador do nft (0 / N / ilegível) · ssh que falha ·
#   origin/main ilegível · relatório velho do mesmo dia nunca vira o e-mail de hoje · resumo com falhas mas sem ids FAILED (comparação indisponível, baseline intacta) ·
#   duração ilegível sai "?" (não 0h0min) · ids com " - " ficam distintos (irmãos de parametrize) · lista parcial / sem a linha GTN-FAILED / contagem que não bate / linha que não é JSON =
#   comparação INDISPONÍVEL com a baseline intacta · fetch que falha aparece no relatório · lock velho com pid reaproveitado é tomado · PULADO por lock deixa linha no jsonl ·
#   a limpeza de 14 dias não apaga a baseline · nao-isolado (vazamento medido) é FALHOU, não INERTE · o nó do mbp-run é o mesmo do instalador · o que foi ao nó fica no relatório.
# CONTROLES NEGATIVOS: cada mutante do script (M1-M89, mais M0 neutro) tem de ser REPROVADO pelo caso correspondente (o caso falha quando roda no mutante). Antes deles, um mutante NEUTRO (cópia que só muda
#   um comentário) tem de PASSAR: sem isso o controle não prova nada (a falta dos arquivos irmãos no diretório do mutante reprovava TODO caso, qualquer que fosse a mutação).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT0="$HERE/hetzner-nightly-tests.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/hzn-selftest.XXXXXX")
trap 'chmod -R u+rwx "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
C="$T/city"; mkdir -p "$C/.gc/logs" "$C/.gc/run"
LOGDIR="$C/.gc/logs/hetzner-nightly"; JSONL="$C/.gc/logs/hetzner-nightly.jsonl"; LOCK="$C/.gc/hetzner-nightly.lock"
DAY=$(date +%Y-%m-%d); REPORT="$LOGDIR/$DAY.md"; PREV="$LOGDIR/last-complete.failed"
MAIL_LOG="$T/mail.log"; CALLS="$T/calls"; STUB_OUT="$T/pytest.out"; OUT="$T/out"
# o WA de mentira: um arquivo versionado em origin/main e um untracked que NÃO pode chegar ao nó
mkdefs() { local f=$1 k=$2 i; mkdir -p "$(dirname "$f")"; : > "$f"; for ((i=1;i<=k;i++)); do printf 'def test_%s():\n    pass\n' "$i" >> "$f"; done; }
git init -q -b main "$T/wa" && ( cd "$T/wa" && echo hi > marker.txt
  mkdefs tests/a_test.py 4; mkdefs tests/sub/test_c.py 6; mkdefs tests/test_a.py 6; mkdefs tests/test_zero.py 0
  mkdefs tests/test_b.py 5; printf 'class T:\n    def test_m(self):\n        pass\nasync def test_y():\n    pass\n' >> tests/test_b.py
  # o que a poda (norecursedirs do pytest.ini) e o padrão de nome têm de deixar de fora
  mkdefs tests/test_mac_launchd.py 3; mkdefs tests/mac/test_x.py 2   # os da lista mac-only (abaixo): ficam FORA da rodada, o mbp-run mandaria a bateria inteira ao Mac (rc 98)
  # lista de CPFs (forma de CPF, valores de mentira): o hetzner-pii-scan.py retém (>=3) e o nó NUNCA recebe; o alvo que não chega ao nó faz o pytest abortar o lote inteiro (rc 4/5)
  printf 'CPFS = ["123.456.789-09", "987.654.321-00", "111.222.333-96"]\ndef test_p1():\n    pass\ndef test_p2():\n    pass\n' > tests/test_pii_lista.py
  for d in venv .hidden crew archive node_modules; do mkdefs "tests/$d/test_x.py" 3; done; mkdefs tests/helper.py 3; echo "def test_n" > tests/test_notes.txt
  git add -A && git -c user.name=t -c user.email=t@t commit -qm m && git update-ref refs/remotes/origin/main HEAD && echo wip > untracked.txt )
git init -q -b main "$T/wa-notests" && ( cd "$T/wa-notests" && echo hi > marker.txt && git add -A && git -c user.name=t -c user.email=t@t commit -qm m && git update-ref refs/remotes/origin/main HEAD )
cat > "$T/run-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$STUB_CALLS"; echo "ENV: ISOLATE=${HETZNER_ISOLATE:-} TIMEOUT=${MBP_RUN_TIMEOUT_S:-} NODE=${HETZNER_NODE_HOST:-}" >> "$STUB_CALLS"
d=""; while [ $# -gt 0 ]; do [ "$1" = --dir ] && d=$2; shift; done
[ -n "$(find "$LOCK_PATH" -maxdepth 0 -mmin +5 2>/dev/null)" ] && echo "lock-velho-durante-a-rodada" >> "$STUB_CALLS"
[ -f "$d/marker.txt" ] && echo "tree-ok" >> "$STUB_CALLS"; [ -e "$d/untracked.txt" ] && echo "untracked-leaked" >> "$STUB_CALLS"
echo "$d" > "$STUB_DIR_SEEN"
# uma saída e um rc POR CHAMADA: STUB_OUT.<n> e STUB_RC_<n> (a n-ésima chamada); sem eles, STUB_OUT e STUB_RC valem para todas
c=$(cat "$STUB_CNT" 2>/dev/null || echo 0); c=$((c+1)); echo "$c" > "$STUB_CNT"; [ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
[ "${STUB_RM_BATCH:-}" != "$c" ] || rm -f "$(dirname "$d")/batch.$c"   # a lista de arquivos do lote some DEPOIS de o script a ter lido para montar a chamada
o="$STUB_OUT.$c"; [ -f "$o" ] || o="$STUB_OUT"; cat "$o" 2>/dev/null; v="STUB_RC_$c"; exit "${!v:-${STUB_RC:-0}}"
EOF
cat > "$T/mail-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "MAIL-CALL" >> "$MAIL_LOG"; printf '%s\n' "$*" >> "$MAIL_LOG"; exit "${MAIL_RC:-0}"
EOF
cat > "$T/ssh-stub.sh" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null; echo "ssh $*" >> "$SSH_LOG"; exit "${SSH_RC:-0}"
EOF
chmod +x "$T"/*-stub.sh
cp "$HERE/hetzner-iso-run.sh" "$HERE/gtn_stable_ids.py" "$HERE/hetzner-pii-scan.py" "$HERE/hetzner-rsync-filter.wa.txt" "$T/"   # o script lê os dois do diretório DELE ($HERE): o mutante, que mora em $T, precisa deles ao lado
export MBP_CITY="$C" HZN_RUN="$T/run-stub.sh" HZN_WA_REPO="$T/wa" HZN_MAIL_CMD="$T/mail-stub.sh" HZN_SSH="$T/ssh-stub.sh" HZN_NODE_HOST=stub-node HZN_NO_FETCH=1
printf '# filtro de mentira: barra tests/test_zero.py por nome\n- /tests/test_zero.py\n+ /tests/***\n+ /marker.txt\n- *\n' > "$T/filter-bar.txt"; printf '+ /marker.txt\n- *\n' > "$T/filter-none.txt"
printf '#!/bin/sh\nexit 3\n' > "$T/pii-fail.sh"; printf '#!/bin/sh\nprintf "marker.txt\\ntests/a_test.py\\n"; exit 23\n' > "$T/rsync-partial.sh"; printf '#!/bin/sh\nexit 0\n' > "$T/rsync-empty.sh"; chmod +x "$T/rsync-partial.sh" "$T/rsync-empty.sh"
printf '# comentário\n\n  tests/test_mac_*.py  \ntests/mac/*\n' > "$T/mac-only.txt"; export HETZNER_MAC_ONLY_LIST="$T/mac-only.txt"   # glob por linha, espaços e comentário como no mbp-run
export LOCK_PATH="$LOCK" MAIL_LOG STUB_CALLS="$CALLS" STUB_OUT STUB_DIR_SEEN="$T/dirseen" SSH_LOG="$T/ssh.log" STUB_CNT="$T/stub.cnt" HZN_RETRY_S=0 HZN_STOP_UTC=
n=0; fails=0; BAD=0; QUIET=0
reset() { find "$LOGDIR" -mindepth 1 -delete 2>/dev/null; : > "$JSONL"; : > "$MAIL_LOG"; : > "$CALLS"; : > "$SSH_LOG"; rm -f "$STUB_OUT" "$STUB_OUT".* "$STUB_CNT"; chmod -R u+rwx "$LOCK" 2>/dev/null
          find "$LOCK" -mindepth 1 -delete 2>/dev/null; rmdir "$LOCK" 2>/dev/null; mkdir -p "$LOGDIR"; unset STUB_RC MAIL_RC SSH_RC HZN_MIN_TOTAL STUB_SLEEP STUB_RC_1 STUB_RC_2 STUB_RC_3 STUB_RC_4 STUB_RM_BATCH HZN_COMM; export HZN_WA_REPO="$T/wa"; }
go() { "$1" > "$OUT" 2> "$T/err"; RC=$?; }
ck() { local l=$1; shift; [ "$QUIET" = 1 ] || n=$((n+1)); if "$@"; then [ "$QUIET" = 1 ] || echo "ok   $l"; else [ "$QUIET" = 1 ] || { echo "FAIL $l"; fails=$((fails+1)); }; BAD=1; fi; }
rcis() { [ "$RC" = "$1" ]; }
has() { grep -q -E -- "$2" "$1"; }
hasnt() { ! grep -q -E -- "$2" "$1"; }
vd() { [ "$(tail -n 1 "$OUT" | sed 's/^[^ ]* hetzner-nightly: //')" = "VEREDITO: $1" ] && [ "$(tail -n 1 "$JSONL" | jq -r .verdict)" = "$1" ]; }
mailn() { [ "$(grep -c '^MAIL-CALL' "$MAIL_LOG")" = "$1" ]; }
empty_dir() { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }
mkout() { # iso egress summary [linhas...] → saída do pytest de mentira
  local iso=$1 eg=$2 sum=$3; shift 3
  { [ -z "$iso" ] || echo "GTN-ISO: $iso"
    case "$iso" in isolado*) [ -z "${CAPLINE-$CAP_OK}" ] || echo "GTN-CAP: ${CAPLINE-$CAP_OK}" ;; esac   # CAPLINE="" omite a linha; CAPLINE=<texto> troca o texto (o iso-run imprime a do teto logo depois da do canário)
    echo "collected ..."; for l in "$@"; do echo "$l"; done; [ -z "$sum" ] || echo "$sum"; [ -z "$eg" ] || echo "GTN-EGRESS: attempts=$eg"; } > "${MK_TO:-$STUB_OUT}"; }
ISO_OK="isolado (sonda barrou 5 tentativas)"; CAP_OK="MemoryMax=20480M MemorySwapMax=0 workers=9 (MemAvailable=28125M reserva=6144M base=4096M por-worker=1800M cpus=16)"; SUM1="3 failed, 1200 passed, 2 skipped in 4000.12s (1:06:40)"
seed_prev() { local i; for i in "$@"; do jq -cn --arg i "$i" '$i'; done | LC_ALL=C sort -u > "$PREV"; echo "2026-01-01 @abc" > "$LOGDIR/last-complete.meta"; }
# o que o plugin imprime: fl <reports> <id>... → uma linha GTN-FAIL por id (JSON ASCII) e a linha GTN-FAILED (n = nº de ids, reports = falhas+erros que o pytest contou)
fl() { local r=$1 i; shift; for i in "$@"; do printf 'GTN-FAIL: %s\n' "$(jq -cn --arg i "$i" '$i')"; done; printf 'GTN-FAILED: n=%s reports=%s' "${FL_N:-$#}" "$r"; }   # FL_N: o n que o plugin AFIRMA (diferente do nº de linhas = lista parcial)
decoded() { jq -r . "$1"; }

case_first() { reset; mkout "$ISO_OK" 7 "$SUM1" "FAILED tests/a.py::t1 - AssertionError: x" "FAILED tests/c.py::t3 - y" "ERROR tests/b.py::t2 - ValueError" "$(fl 3 tests/a.py::t1 tests/b.py::t2 tests/c.py::t3)"; STUB_RC=1 go "$1"
  ck "1ª noite: exit 0 e veredito COMPLETO" rcis 0; ck "1ª noite: COMPLETO na última linha e no jsonl" vd COMPLETO; ck "1ª noite: 1 e-mail" mailn 1
  ck "1ª noite: assunto diz primeira rodada" has "$MAIL_LOG" 'COMPLETO: 1205 testes em 1 lotes, 3 falhas, 0 erros \(primeira rodada\)'
  ck "1ª noite: relatório com a linha de base" has "$REPORT" 'primeira rodada completa.*as 3 falhas de hoje viram a linha de base'
  ck "1ª noite: totais" has "$REPORT" 'total: 1205 \(1200 passaram, 3 falharam, 0 erros, 2 pulados'; ck "1ª noite: duração e meta de 225 min (o padrão de produção, HZN_TIMEOUT_S=13500)" has "$REPORT" 'pytest somado 1h6min.*meta de 225 min: ATINGIDA'
  ck "1ª noite: contador do nft no relatório" has "$REPORT" '7 tentativa\(s\) de saída barradas pelo nft'
  ck "1ª noite: mbp-run com o isolamento ligado, o prazo e o MESMO nó do instalador" has "$CALLS" 'ENV: ISOLATE=1 TIMEOUT=2400 NODE=stub-node'
  ck "1ª noite: mbp-run no nó linux, os arquivos do lote (ordem de caminho), -n auto e o plugin" has "$CALLS" 'ARGS: --host linux --repo wa --dir .*-- tests/a_test.py tests/sub/test_c.py tests/test_a.py tests/test_b.py tests/test_zero.py -n auto -p gtn_stable_ids --timeout=300'
  ck "1ª noite: a poda do pytest.ini (venv, .hidden, crew, archive, node_modules) e o que não é test_*.py ficam de fora" hasnt "$CALLS" 'venv|hidden|crew|archive|node_modules|helper\.py|notes'
  ck "1ª noite: os arquivos mac-only (lista do mbp-run) ficam FORA do lote" hasnt "$CALLS" 'test_mac_|tests/mac/'; ck "1ª noite: o jsonl conta 2 mac-only fora" test "$(tail -n 1 "$JSONL" | jq -c .mac_only_excluded)" = 2
  ck "1ª noite: o relatório diz que a bateria NÃO cobre os mac-only" has "$REPORT" 'fora da rodada por regra do nó: 2 arquivos mac-only .*NÃO os cobre'; ck "1ª noite: a lista dos excluídos fica em arquivo" has "$LOGDIR/$DAY.mac-only.lst" '^tests/mac/test_x.py$'
  ck "1ª noite: o arquivo com lista de CPFs (que o nó nunca recebe) fica FORA do lote" hasnt "$CALLS" 'test_pii_lista'; ck "1ª noite: o jsonl conta 1 arquivo que o nó não recebe" test "$(tail -n 1 "$JSONL" | jq -c .node_held_excluded)" = 1
  ck "1ª noite: o relatório diz que a bateria NÃO cobre o que o nó não recebe" has "$REPORT" 'fora da rodada porque o nó não os recebe: 1 arquivos \(0 barrados pelo filtro do rsync, 1 com lista de telefones/CPFs.*NÃO os cobre'; ck "1ª noite: a lista dos retidos fica em arquivo" has "$LOGDIR/$DAY.retidos.lst" '^tests/test_pii_lista\.py$'
  ck "1ª noite: UMA chamada do mbp-run (todos os arquivos cabem em 1 lote)" test "$(grep -c '^ARGS:' "$CALLS")" = 1; ck "1ª noite: o jsonl conta 1 lote, 1 rodou, 0 pulados" test "$(tail -n 1 "$JSONL" | jq -c '[.batches,.batches_ran,.batches_skipped]')" = '[1,1,0]'
  ck "1ª noite: o relatório diz o teto" has "$REPORT" 'teto \(lote 01\): `GTN-CAP: MemoryMax=20480M MemorySwapMax=0 workers=9'; ck "1ª noite: tabela com o lote 01 (5 arquivos, 23 defs, 9 workers)" has "$REPORT" '^\| 01 \| 5 \| 23 \| 9 \| '
  ck "1ª noite: a saída do lote fica em arquivo próprio" test -s "$LOGDIR/$DAY.b01.out"
  ck "1ª noite: árvore do origin/main chegou" has "$CALLS" '^tree-ok$'; ck "1ª noite: untracked NÃO chegou" hasnt "$CALLS" 'untracked-leaked'
  ck "1ª noite: scratch apagado" empty_dir "$C/.gc/run"; ck "1ª noite: baseline gravada (ids em JSON)" has "$PREV" '^"tests/b.py::t2"$'; ck "1ª noite: o wrapper e o plugin foram ao nó" has "$T/ssh.log" 'gtn_stable_ids.py'; }
case_second() { reset; seed_prev tests/a.py::t1 tests/old.py::gone; mkout "$ISO_OK" 0 "1 failed, 1 error, 1200 passed, 2 skipped in 4000.12s (1:06:40)" "FAILED tests/a.py::t1 - x" "ERROR tests/b.py::t2" "$(fl 2 tests/a.py::t1 tests/b.py::t2)"; STUB_RC=1 go "$1"
  ck "2ª noite: COMPLETO" vd COMPLETO; ck "2ª noite: 1 nova e 1 corrigida" has "$REPORT" '2026-01-01 @abc\): 1 falhas NOVAS, 1 corrigidas'; ck "2ª noite: a nova está na lista (decodificada, não em JSON)" has "$REPORT" '^  - tests/b.py::t2$'
  ck "2ª noite: a antiga não é listada como nova" hasnt "$REPORT" '^  - tests/a.py::t1$'; ck "2ª noite: assunto com (1 novas)" has "$MAIL_LOG" '\(1 novas\)'
  ck "2ª noite: baseline avançou" has "$PREV" '^"tests/b.py::t2"$'; ck "2ª noite: a corrigida saiu da baseline" hasnt "$PREV" 'old.py'; ck "2ª noite: 0 tentativas dito como lido" has "$REPORT" '0 tentativas de saída \(contador do nft lido em todos'; }
case_cleanslate() { reset; seed_prev tests/a.py::t1 tests/old.py::gone; mkout "$ISO_OK" 1 "1500 passed in 3000.00s (0:50:00)" "$(fl 0)"; STUB_RC=0 go "$1"
  ck "sem falhas: COMPLETO, 0 novas e 2 corrigidas" has "$REPORT" '0 falhas NOVAS, 2 corrigidas'; ck "sem falhas: baseline vazia" empty_dir_file "$PREV"
  mkout "$ISO_OK" 1 "1 failed, 1499 passed in 3000.00s (0:50:00)" "FAILED tests/c.py::t3" "$(fl 1 tests/c.py::t3)"; STUB_RC=1 go "$1"
  ck "baseline vazia existe: toda falha é nova" has "$REPORT" '1 falhas NOVAS, 0 corrigidas'; }
not_same() { ! cmp -s "$1" "$2"; }
empty_dir_file() { [ -e "$1" ] && [ ! -s "$1" ]; }
case_xfail() { reset; mkout "$ISO_OK" 1 "2 failed, 1000 passed, 1 error, 3 xfailed, 1 xpassed in 1500.50s (0:25:00)" "FAILED tests/a.py::t1" "$(fl 3 tests/a.py::t1 tests/a.py::t2 tests/a.py::t3)"; STUB_RC=1 go "$1"
  ck "categorias: failed não conta xfailed, error conta singular" has "$REPORT" 'total: 1007 \(1000 passaram, 2 falharam, 1 erros, 0 pulados, 3 xfail, 1 xpass\)'; }
case_inerte() { local iso
  for iso in "inerte helper-ausente (/usr/local/sbin/gt-netns-run: o root ainda não o instalou)"; do
    reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"; mkout "$iso" "" ""; STUB_RC=97 go "$1"
    ck "INERTE ($iso): exit 0 e veredito" rcis 0; ck "INERTE: veredito INERTE" vd INERTE; ck "INERTE: e-mail ao Mayor" mailn 1; ck "INERTE: relatório diz que o isolamento não foi provado" has "$REPORT" 'NÃO provado'; ck "INERTE: relatório diz o que fazer" has "$REPORT" 'Instalar o helper de root'
    ck "INERTE: nenhum total divulgado" hasnt "$REPORT" 'total:'; ck "INERTE: baseline intacta" cmp -s "$PREV" "$T/prev.before"; done; }
case_leak() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"; mkout "nao-isolado tcp:1.1.1.1:53" "" ""; STUB_RC=97 go "$1"
  ck "vazamento medido: exit 1 (não 0 como o helper ausente)" rcis 1; ck "vazamento medido: veredito FALHOU, não INERTE" vd FALHOU; ck "vazamento medido: e-mail ao Mayor" mailn 1
  ck "vazamento medido: o assunto diz VAZAMENTO e o que vazou" has "$MAIL_LOG" 'FALHOU: VAZAMENTO.*tcp:1\.1\.1\.1:53'; ck "vazamento medido: a suíte não rodou, nenhum total" hasnt "$REPORT" 'total:'; ck "vazamento medido: baseline intacta" cmp -s "$PREV" "$T/prev.before"; }
case_97_sem_iso() { reset; mkout "" "" "" "mbp-run: algo quebrou"; STUB_RC=97 go "$1"; ck "rc 97 sem linha GTN-ISO: FALHOU, exit 1" rcis 1; ck "rc 97 sem linha: veredito FALHOU, não INERTE" vd FALHOU; ck "rc 97 sem linha: diz que não rodou" has "$MAIL_LOG" 'não rodou a suíte \(rc=97\)'; }
case_pulado() { reset; mkout "" "" ""; STUB_RC=99 go "$1"; ck "PULADO: exit 0" rcis 0; ck "PULADO: veredito" vd PULADO; ck "PULADO: nenhum e-mail" mailn 0; }
case_timeout() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"; mkout "$ISO_OK" "" "" "...."; STUB_RC=124 go "$1"
  ck "prazo: exit 1 e FALHOU" rcis 1; ck "prazo: veredito" vd FALHOU; ck "prazo: o lote que estourou NÃO RODOU, com o prazo dele" has "$MAIL_LOG" 'NÃO RODOU.*estourou o prazo do lote \([0-9]+s\)'; ck "prazo: o assunto conta os lotes que não rodaram" has "$MAIL_LOG" '1 de 1 lotes NÃO RODARAM \(01\)'; ck "prazo: nada de COMPLETO" hasnt "$MAIL_LOG" 'COMPLETO'; ck "prazo: baseline intacta" cmp -s "$PREV" "$T/prev.before"; }
case_abort() { reset; mkout "$ISO_OK" "" "" "INTERNALERROR> boom"; STUB_RC=2 go "$1"; ck "pytest abortado: FALHOU com o rc" has "$MAIL_LOG" 'o pytest abortou \(rc=2\)'; ck "pytest abortado: exit 1" rcis 1; }
case_noiso() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"; mkout "" 7 "3 failed, 1200 passed in 100.00s" "FAILED tests/z.py::z"; STUB_RC=1 go "$1"
  ck "sem prova de isolamento: FALHOU" vd FALHOU; ck "sem prova: exit 1" rcis 1; ck "sem prova: aviso alto" has "$MAIL_LOG" 'ATENÇÃO.*SEM a linha de prova do isolamento'; ck "sem prova: o número não é divulgado" hasnt "$REPORT" '1203'; ck "sem prova: baseline intacta" cmp -s "$PREV" "$T/prev.before"; }
case_nosum() { reset; mkout "$ISO_OK" 1 "" "FAILED tests/a.py::t1"; STUB_RC=1 go "$1"; ck "sem resumo: FALHOU" has "$MAIL_LOG" 'sem linha de resumo do pytest'; }
case_implausible() { reset; mkout "$ISO_OK" 1 "5 passed in 1.00s"; STUB_RC=0 go "$1"; ck "total implausível: FALHOU" has "$MAIL_LOG" 'total implausível \(5 testes < 1000'; ck "total implausível: exit 1" rcis 1; }
case_lock() { reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s"; sleep 30 & local holder=$!; mkdir "$LOCK"; echo "$holder" > "$LOCK/pid"; go "$1"
  ck "lock vivo: PULADO, exit 0" rcis 0; ck "lock vivo: diz o pid" has "$OUT" "outra rodada em andamento \(pid $holder\)"; ck "lock vivo: não rodou nada" empty_dir_file "$CALLS"; ck "lock vivo: sem e-mail" mailn 0; ck "lock vivo: o lock do outro continua" test -d "$LOCK"
  ck "lock vivo: a noite PULADA deixa a linha no jsonl (uma por noite)" vd PULADO; ck "lock vivo: o jsonl diz o pid" test "$(tail -n 1 "$JSONL" | jq -r .reason)" = "outra rodada em andamento (pid $holder)"; ck "lock vivo: não escreveu o relatório do outro" test ! -e "$REPORT"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s"; ( exit 0 ) & local dead=$!; wait "$dead"; mkdir "$LOCK"; echo "$dead" > "$LOCK/pid"; go "$1"
  ck "lock de dono morto: toma e roda" vd COMPLETO; ck "lock de dono morto: avisa" has "$OUT" 'WARN: lock sem dono vivo'; ck "lock liberado ao fim" test ! -d "$LOCK"; }
case_prev_unreadable() { [ "$(id -u)" -ne 0 ] || return 0; reset; seed_prev tests/a.py::t1; chmod 000 "$PREV"; mkout "$ISO_OK" 1 "$SUM1" "FAILED tests/a.py::t1"; STUB_RC=1 go "$1"; chmod 644 "$PREV" 2>/dev/null
  ck "baseline ilegível: relatório diz INDISPONÍVEL" has "$REPORT" 'comparação INDISPONÍVEL'; ck "baseline ilegível: o assunto nunca diz 0 novas" hasnt "$MAIL_LOG" '0 novas'; ck "baseline ilegível: assunto diz sem comparação" has "$MAIL_LOG" '\(sem comparação\)'; }
case_mailfail() { reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s"; MAIL_RC=1 STUB_RC=0 go "$1"
  ck "e-mail falhou: exit 1" rcis 1; ck "e-mail falhou: o veredito continua COMPLETO" has "$OUT" 'VEREDITO: COMPLETO'; ck "e-mail falhou: jsonl diz mail_failed=1" test "$(tail -n 1 "$JSONL" | jq .mail_failed)" = 1; ck "e-mail falhou: relatório no disco" has "$REPORT" 'COMPLETO'; }
case_egress() { reset; mkout "$ISO_OK" "?" "1500 passed in 3000.00s"; STUB_RC=0 go "$1"; ck "contador '?': não afirma zero" has "$REPORT" 'ILEGÍVEL em algum lote — não afirmo zero'
  reset; mkout "$ISO_OK" "" "1500 passed in 3000.00s"; STUB_RC=0 go "$1"; ck "sem linha do contador: ILEGÍVEL" has "$REPORT" 'ILEGÍVEL'; ck "sem linha do contador: jsonl guarda ?" test "$(tail -n 1 "$JSONL" | jq -r .egress_attempts)" = "?"
  reset; mkout "$ISO_OK" 0 "1500 passed in 3000.00s"; STUB_RC=0 go "$1"; ck "contador 0: dito como lido" has "$REPORT" '0 tentativas de saída \(contador do nft lido em todos'; }
case_ssh() { reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s"; SSH_RC=255 go "$1"; ck "ssh falha: FALHOU, exit 1" rcis 1; ck "ssh falha: diz o que não instalou" has "$MAIL_LOG" 'não consegui instalar gt-iso-run em stub-node'; ck "ssh falha: o mbp-run não rodou" empty_dir_file "$CALLS"; }
case_no_origin() { reset; HZN_WA_REPO="$T/nowhere" go "$1"; ck "origin/main ilegível: FALHOU" has "$MAIL_LOG" 'origin/main do WA ilegível'; ck "origin/main ilegível: nada rodou" empty_dir_file "$CALLS"; }
case_stale_report() { reset; echo "RELATORIO-VELHO" > "$REPORT"; SSH_RC=1 go "$1"; ck "relatório velho do mesmo dia: não vira o e-mail de hoje" hasnt "$MAIL_LOG" 'RELATORIO-VELHO'; ck "relatório velho: o de hoje é FALHOU" has "$REPORT" 'FALHOU'; }
case_listfail() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"; echo "2026-01-01 @abc" > "$LOGDIR/last-complete.meta"
  # o resumo diz 3 falhas e o plugin não imprimiu nada (não rodou, ou falhou ao montar a lista)
  mkout "$ISO_OK" 1 "3 failed, 1500 passed in 3000.00s" "FAILED tests/a.py::t1 - x"; STUB_RC=1 go "$1"
  ck "sem a linha GTN-FAILED: segue COMPLETO" vd COMPLETO; ck "sem a linha GTN-FAILED: relatório diz INDISPONÍVEL e por quê" has "$REPORT" 'comparação INDISPONÍVEL: lote 01: o pytest não imprimiu a linha GTN-FAILED'
  ck "sem a linha GTN-FAILED: nunca 0 novas" hasnt "$MAIL_LOG" '0 novas'; ck "sem a linha GTN-FAILED: baseline intacta" cmp -s "$PREV" "$T/prev.before"; ck "sem a linha GTN-FAILED: avisa no log" has "$OUT" 'lista de falhas ilegível'
  ck "sem a linha GTN-FAILED: o jsonl diz compare=indisponivel" test "$(tail -n 1 "$JSONL" | jq -r .compare)" = indisponivel
  # SEM falhas no resumo e sem a linha do plugin: "zero falhas" não se distingue de "o plugin não rodou" → também INDISPONÍVEL, a baseline antiga não é zerada
  reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"; mkout "$ISO_OK" 1 "1500 passed in 3000.00s"; STUB_RC=0 go "$1"
  ck "sem falhas no resumo e sem a linha do plugin: INDISPONÍVEL (não zera a baseline)" has "$REPORT" 'comparação INDISPONÍVEL'; ck "sem falhas e sem a linha do plugin: baseline intacta" cmp -s "$PREV" "$T/prev.before"; }
case_prev_format() { reset; printf 'tests/a.py::t1\ntests/old.py::gone\n' > "$PREV"; echo "2026-01-01 @abc" > "$LOGDIR/last-complete.meta"
  mkout "$ISO_OK" 1 "1 failed, 1500 passed in 3000.00s" "FAILED tests/a.py::t1 - x" "$(fl 1 tests/a.py::t1)"; STUB_RC=1 go "$1"
  ck "baseline em outro formato (texto puro): INDISPONÍVEL, não 'tudo novo'" has "$REPORT" 'comparação INDISPONÍVEL: .*não pôde ser lido como lista de ids em JSON'; ck "baseline em outro formato: nunca 0 novas" hasnt "$MAIL_LOG" '0 novas'
  ck "baseline em outro formato: a de hoje (lista confiável) a substitui" has "$PREV" '^"tests/a.py::t1"$'; }
case_dash() { reset; seed_prev 'tests/t.py::test_dash[a - b]' 'tests/t.py::test_x'
  # 2 irmãos de parametrize cujo texto antes do 1º " - " é igual (`[a`), e um id com acento escapado pelo pytest; o resumo diz 4
  local A='tests/t.py::test_dash[a - b]' B='tests/t.py::test_dash[a - c]' C='tests/t.py::test_dash[n\xe3o - sim]' D='tests/t.py::test_y'
  mkout "$ISO_OK" 1 "3 failed, 1 error, 1500 passed in 3000.00s" "FAILED $A - AssertionError: assert False" "FAILED $B - AssertionError: assert False" "FAILED $C - AssertionError: x" "ERROR $D - RuntimeError: boom" "$(fl 4 "$A" "$B" "$C" "$D")"; STUB_RC=1 go "$1"
  ck "ids com ' - ': COMPLETO" vd COMPLETO; ck "ids com ' - ': os 2 irmãos continuam 2 linhas na lista de hoje" test "$(grep -c 'test_dash\[a - ' "$LOGDIR/$DAY.failed")" = 2
  ck "ids com ' - ': são 3 NOVAS e 1 corrigida (o irmão a - c não some atrás do a - b)" has "$REPORT" '3 falhas NOVAS, 1 corrigidas'; ck "ids com ' - ': o irmão novo está na lista, inteiro" has "$REPORT" '^  - tests/t.py::test_dash\[a - c\]$'
  ck "ids com ' - ': o irmão que já falhava NÃO é listado como novo" hasnt "$REPORT" '^  - tests/t.py::test_dash\[a - b\]$'; ck "ids com ' - ': o id com acento escapado sai inteiro" has "$REPORT" '^  - tests/t.py::test_dash\[n\\xe3o - sim\]$'
  ck "ids com ' - ': nenhum id cortado em '[a' ou '[n\\xe3o'" hasnt "$REPORT" 'test_dash\[a$|test_dash\[n\\xe3o$'; ck "ids com ' - ': baseline avançou com os 4 ids inteiros" test "$(decoded "$PREV" | grep -c '^tests/t.py::test_\(dash\|y\)')" = 4
  ck "ids com ' - ': o jsonl diz compare=ok" test "$(tail -n 1 "$JSONL" | jq -r .compare)" = ok; }
case_partial() { local A='tests/t.py::test_dash[a - b]' B='tests/t.py::test_dash[a - c]' C='tests/t.py::test_z' why
  # (1) lista parcial: o plugin diz 3 ids e só 2 linhas chegaram · (2) o plugin contou 3 e o resumo do pytest diz 4 · (3) duas linhas GTN-FAILED · (4) linha GTN-FAIL que não é JSON · (5) linha GTN-FAILED ilegível
  for why in 1 2 3 4 5; do
    reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"
    case $why in
      1) mkout "$ISO_OK" 1 "3 failed, 1500 passed in 3000.00s" "FAILED $A - x" "FAILED $B - x" "FAILED $C - x" "$(FL_N=3 fl 3 "$A" "$B")" ;;
      2) mkout "$ISO_OK" 1 "4 failed, 1500 passed in 3000.00s" "FAILED $A - x" "$(fl 3 "$A" "$B" "$C")" ;;
      3) mkout "$ISO_OK" 1 "3 failed, 1500 passed in 3000.00s" "$(fl 3 "$A" "$B" "$C")" "GTN-FAILED: n=3 reports=3" ;;
      4) mkout "$ISO_OK" 1 "3 failed, 1500 passed in 3000.00s" "$(fl 3 "$A" "$B" "$C")" "GTN-FAIL: tests/t.py::sem_aspas" ;;
      5) mkout "$ISO_OK" 1 "3 failed, 1500 passed in 3000.00s" "GTN-FAIL: \"$A\"" "GTN-FAIL: \"$B\"" "GTN-FAIL: \"$C\"" "GTN-FAILED: n=tres reports=3" ;;
    esac
    case $why in 1) STUB_RC=1 go "$1"; ck "lista parcial: INDISPONÍVEL e diz que é parcial" has "$REPORT" 'comparação INDISPONÍVEL: lote 01: o plugin diz 3 ids e 2 foram lidos \(lista parcial\)' ;;
      2) STUB_RC=1 go "$1"; ck "contagem do plugin x resumo: INDISPONÍVEL e diz os dois números" has "$REPORT" 'comparação INDISPONÍVEL: lote 01: o plugin contou 3 falhas/erros e o resumo do pytest diz 4' ;;
      3) STUB_RC=1 go "$1"; ck "duas linhas GTN-FAILED: INDISPONÍVEL" has "$REPORT" 'comparação INDISPONÍVEL: lote 01: a linha GTN-FAILED aparece 2 vezes' ;;
      4) STUB_RC=1 go "$1"; ck "linha GTN-FAIL que não é JSON: INDISPONÍVEL" has "$REPORT" 'comparação INDISPONÍVEL: lote 01: há linha GTN-FAIL que não é um id em JSON' ;;
      5) STUB_RC=1 go "$1"; ck "linha GTN-FAILED ilegível: INDISPONÍVEL" has "$REPORT" 'comparação INDISPONÍVEL: lote 01: a linha GTN-FAILED está ilegível' ;; esac
    ck "caso $why (lista não confiável): nunca 0 novas" hasnt "$MAIL_LOG" '0 novas'; ck "caso $why: baseline intacta" cmp -s "$PREV" "$T/prev.before"; ck "caso $why: segue COMPLETO (o número do pytest é dado)" vd COMPLETO
    ck "caso $why: o rodapé não chama a lista de ids reprovados confiável" has "$REPORT" 'lista de ids NÃO confiável'
  done; }
case_fetch() { local wa2="$T/wa-clone"
  # fetch que falha (o clone não tem remote): segue com o origin/main que tem, mas o relatório e o jsonl dizem que a árvore pode estar velha
  reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s" "$(fl 0)"; STUB_RC=0 HZN_NO_FETCH=0 go "$1"
  ck "fetch falhou: segue COMPLETO" vd COMPLETO; ck "fetch falhou: o relatório diz que a árvore pode estar desatualizada" has "$REPORT" 'fetch.*FALHOU.*desatualizada'; ck "fetch falhou: o jsonl diz fetch=falhou" test "$(tail -n 1 "$JSONL" | jq -r .fetch)" = falhou
  # fetch que funciona (clone de verdade, com origin): nada de aviso
  [ -d "$wa2/.git" ] || git clone -q "$T/wa" "$wa2" 2>/dev/null
  reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s" "$(fl 0)"; STUB_RC=0 HZN_NO_FETCH=0 HZN_WA_REPO="$wa2" go "$1"
  ck "fetch ok: COMPLETO sem aviso de árvore velha" hasnt "$REPORT" 'desatualizada'; ck "fetch ok: o jsonl diz fetch=ok" test "$(tail -n 1 "$JSONL" | jq -r .fetch)" = ok
  reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s" "$(fl 0)"; STUB_RC=0 go "$1"; ck "HZN_NO_FETCH=1: o jsonl diz fetch=pulado (não afirma ok)" test "$(tail -n 1 "$JSONL" | jq -r .fetch)" = pulado; }
case_lock_stale() { reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s" "$(fl 0)"; sleep 30 & local holder=$!; mkdir "$LOCK"; echo "$holder" > "$LOCK/pid"
  # o pid está VIVO (foi reaproveitado depois de uma queda) mas o lock é mais velho que prazo + margem: toma, avisa e roda
  touch -t 202001010000 "$LOCK"; STUB_RC=0 go "$1"
  ck "lock velho com pid vivo: toma e roda (COMPLETO)" vd COMPLETO; ck "lock tomado de um velho é renovado (durante a rodada não parece velho)" hasnt "$CALLS" 'lock-velho-durante-a-rodada'; ck "lock velho: avisa que é velho" has "$OUT" 'WARN: lock sem dono vivo.*com mais de [0-9]+ min'; ck "lock velho: não matou o processo do pid reaproveitado" kill -0 "$holder"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  # lock RECENTE com pid vivo continua valendo (o caso 'lock' cobre); aqui: a idade vem do mtime do diretório, e um lock tomado é renovado
  reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s" "$(fl 0)"; sleep 30 & holder=$!; mkdir "$LOCK"; echo "$holder" > "$LOCK/pid"; touch -t 202001010000 "$LOCK"; STUB_RC=0 HZN_TIMEOUT_S=999999999 go "$1"
  ck "lock com 'idade' menor que o prazo configurado: continua PULADO" vd PULADO; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; }
case_keep() { reset; seed_prev tests/a.py::t1
  # a limpeza de 14 dias apaga relatório velho e NÃO a linha de base (se apagasse, a próxima noite diria "primeira rodada" sem ser verdade)
  echo x > "$LOGDIR/2020-01-01.out"; echo x > "$LOGDIR/2020-01-01.md"; touch -t 202001010000 "$LOGDIR/2020-01-01.out" "$LOGDIR/2020-01-01.md" "$PREV" "$LOGDIR/last-complete.meta"
  mkout "inerte helper-ausente" "" ""; STUB_RC=97 go "$1"
  ck "limpeza: relatório velho apagado" test ! -e "$LOGDIR/2020-01-01.out"; ck "limpeza: a baseline de 20 dias fica" test -e "$PREV"; ck "limpeza: o meta da baseline fica" test -e "$LOGDIR/last-complete.meta"; }
case_provenance() { reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s" "$(fl 0)"; STUB_RC=0 go "$1"
  ck "relatório diz o que foi instalado no nó (com sha)" has "$REPORT" 'instalado no nó: gt-iso-run sha256:[0-9a-f]{12} \(.*\); gtn_stable_ids.py sha256:[0-9a-f]{12} \(.*\)'; ck "o estado git de quem foi ao nó nunca fica em branco" hasnt "$REPORT" 'sha256:[0-9a-f?]+ \(\)'; }
case_dur() { reset; mkout "$ISO_OK" 1 "1500 passed in 7s"; STUB_RC=0 go "$1"; ck "duração ilegível: o relatório diz ?" has "$REPORT" 'duração: pytest somado \? \(\? s\)'; ck "duração ilegível: nunca 0h0min" hasnt "$REPORT" '0h0min'; }

# ---- lotes (ga-84gkpab) ----------------------------------------------------------------------------------------------------------------------------------------------------------------
okb() { # n iso-resumo ids... → saída do lote n (n-ésima chamada) com o resumo dado e os ids que o plugin lista (FL_R = nº de falhas+erros do resumo)
  local n=$1 sum=$2 r=$3; shift 3; MK_TO="$STUB_OUT.$n" mkout "$ISO_OK" "${EG:-0}" "$sum" "$(fl "$r" "$@")"; }
case_batches() { reset; seed_prev tests/old.py::gone
  local A='tests/a_test.py::t1' B='tests/test_b.py::t2' C='tests/test_b.py::t3'
  EG=2 okb 1 "1 failed, 400 passed in 100.00s (0:01:40)" 1 "$A"
  okb 2 "500 passed, 1 skipped in 200.00s (0:03:20)" 0; EG=0 okb 3 "1 failed, 1 error, 300 passed in 50.00s" 2 "$B" "$C"
  STUB_RC_1=1 STUB_RC_2=0 STUB_RC_3=1 HZN_BATCH_DEFS=10 go "$1"
  ck "lotes: COMPLETO, exit 0" vd COMPLETO; ck "lotes: exit 0" rcis 0; ck "lotes: 1 e-mail" mailn 1
  ck "lotes: 3 chamadas do mbp-run, uma por lote" test "$(grep -c '^ARGS:' "$CALLS")" = 3
  ck "lotes: lote 1 = os dois primeiros arquivos (peso 4+6 cabe em 10)" has "$CALLS" '-- tests/a_test.py tests/sub/test_c.py -n auto -p gtn_stable_ids'
  ck "lotes: lote 2 = tests/test_a.py sozinho (o próximo, de peso 7, não cabe)" has "$CALLS" '-- tests/test_a.py -n auto -p gtn_stable_ids'
  ck "lotes: lote 3 = test_b e test_zero (peso mínimo 1 para arquivo sem def)" has "$CALLS" '-- tests/test_b.py tests/test_zero.py -n auto -p gtn_stable_ids'
  ck "lotes: nenhum arquivo em dois lotes e nenhum fora" test "$(grep '^ARGS:' "$CALLS" | grep -o 'tests/[A-Za-z_/]*\.py' | sort | tr '\n' ' ')" = 'tests/a_test.py tests/sub/test_c.py tests/test_a.py tests/test_b.py tests/test_zero.py '
  ck "lotes: cada lote com o prazo do lote (não o do script inteiro)" test "$(grep -c 'TIMEOUT=2400 ' "$CALLS")" = 3
  ck "lotes: totais SOMADOS dos 3 lotes" has "$REPORT" 'total: 1204 \(1200 passaram, 2 falharam, 1 erros, 1 pulados, 0 xfail, 0 xpass\); 3 de 3 lotes rodaram'
  ck "lotes: duração somada (100+200+50 s)" has "$REPORT" 'pytest somado 0h5min \(350 s\)'; ck "lotes: contador do nft somado (2+0+0)" has "$REPORT" '2 tentativa\(s\) de saída barradas pelo nft'
  ck "lotes: o assunto diz os 3 lotes" has "$MAIL_LOG" 'COMPLETO: 1204 testes em 3 lotes, 2 falhas, 1 erros'; ck "lotes: o jsonl diz 3/3/0" test "$(tail -n 1 "$JSONL" | jq -c '[.batches,.batches_ran,.batches_skipped]')" = '[3,3,0]'
  ck "lotes: ids dos 3 lotes na lista de hoje" test "$(wc -l < "$LOGDIR/$DAY.failed" | tr -d ' ')" = 3; ck "lotes: 3 novas e 1 corrigida contra a noite anterior" has "$REPORT" '3 falhas NOVAS, 1 corrigidas'
  ck "lotes: a baseline avançou com a união" test "$(decoded "$PREV" | grep -c 'a_test\|test_b')" = 3
  ck "lotes: a tabela tem os 3 lotes com arquivos, defs e workers" has "$REPORT" '^\| 01 \| 2 \| 10 \| 9 \| '; ck "lotes: lote 3" has "$REPORT" '^\| 03 \| 2 \| 7 \| 9 \| [0-9]+ \| rodou \| '
  ck "lotes: uma saída por lote" test -s "$LOGDIR/$DAY.b03.out"; ck "lotes: a junta tem os cabeçalhos" has "$LOGDIR/$DAY.out" '^=== lote 02: 1 arquivos, 6 def test_'; }
case_batch_list() { reset; seed_prev tests/old.py::gone; cp "$PREV" "$T/prev.before"
  okb 1 "1 failed, 400 passed in 100.00s" 1 tests/a_test.py::t1
  # o lote 2 diz 2 falhas e o plugin não imprimiu a lista dele: a comparação toda fica indisponível, a baseline não anda, mas o total continua dado do pytest
  MK_TO="$STUB_OUT.2" mkout "$ISO_OK" 0 "2 failed, 500 passed in 200.00s" "FAILED tests/test_a.py::x"
  okb 3 "300 passed in 50.00s" 0
  STUB_RC_1=1 STUB_RC_2=1 STUB_RC_3=0 HZN_BATCH_DEFS=10 go "$1"
  ck "lista de um lote inconsistente: segue COMPLETO (número do pytest é dado)" vd COMPLETO; ck "lista de um lote inconsistente: diz de que lote" has "$REPORT" 'comparação INDISPONÍVEL: lote 02: o pytest não imprimiu a linha GTN-FAILED'
  ck "lista de um lote inconsistente: baseline intacta" cmp -s "$PREV" "$T/prev.before"; ck "lista de um lote inconsistente: nunca 0 novas" hasnt "$MAIL_LOG" '0 novas'; ck "lista de um lote inconsistente: os 3 lotes somam" has "$REPORT" 'total: 1203 '; }
case_overbudget() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"
  okb 1 "1200 passed in 100.00s" 0
  # orçamento de 12 s − 2 s de margem; o lote 1 leva 6 s; sobram ~3 s (< 5 s de mínimo): os lotes 2 e 3 NÃO começam
  STUB_RC_1=0 STUB_SLEEP=6 HZN_BATCH_DEFS=10 HZN_TIMEOUT_S=12 HZN_FINAL_MARGIN_S=2 HZN_MIN_BATCH_S=5 go "$1"
  ck "orçamento esgotado: FALHOU, exit 1" rcis 1; ck "orçamento esgotado: veredito FALHOU (nunca COMPLETO)" vd FALHOU; ck "orçamento esgotado: o assunto diz quais lotes não rodaram" has "$MAIL_LOG" 'FALHOU: 2 de 3 lotes NÃO RODARAM \(02, 03\)'
  ck "orçamento esgotado: a tabela diz por quê" has "$REPORT" '^\| 02 \| 1 \| 6 \| .* NÃO RODOU \| orçamento esgotado: restam'; ck "orçamento esgotado: só 1 chamada ao mbp-run" test "$(grep -c '^ARGS:' "$CALLS")" = 1
  ck "orçamento esgotado: o 1º lote recebeu o que restava do orçamento, não 2400 s" has "$CALLS" 'TIMEOUT=(9|10) '; ck "orçamento esgotado: o parcial vem marcado como parcial" has "$REPORT" 'parcial, NÃO é o total da suíte'
  ck "orçamento esgotado: baseline intacta" cmp -s "$PREV" "$T/prev.before"; ck "orçamento esgotado: nunca 0 novas" hasnt "$MAIL_LOG" '0 novas'; ck "orçamento esgotado: o jsonl diz 3/1/2" test "$(tail -n 1 "$JSONL" | jq -c '[.batches,.batches_ran,.batches_skipped]')" = '[3,1,2]'; }
case_batch_killed() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"
  okb 1 "600 passed in 100.00s" 0; MK_TO="$STUB_OUT.2" mkout "$ISO_OK" 0 "" "Killed"; okb 3 "600 passed in 100.00s" 0
  STUB_RC_1=0 STUB_RC_2=137 STUB_RC_3=0 HZN_BATCH_DEFS=10 go "$1"
  ck "lote morto (137): FALHOU, exit 1" rcis 1; ck "lote morto: veredito FALHOU" vd FALHOU; ck "lote morto: só o 02 não rodou" has "$MAIL_LOG" '1 de 3 lotes NÃO RODARAM \(02\)'
  ck "lote morto: a tabela diz MORTO e o rc" has "$REPORT" 'NÃO RODOU \| o pytest foi MORTO \(rc=137'; ck "lote morto: os outros lotes rodaram (3 chamadas)" test "$(grep -c '^ARGS:' "$CALLS")" = 3
  ck "lote morto: parcial dos 2 que rodaram" has "$REPORT" 'só dos 2 lotes que rodaram.*1200 testes'; ck "lote morto: baseline intacta" cmp -s "$PREV" "$T/prev.before"; ck "lote morto: nunca 0 novas" hasnt "$MAIL_LOG" '0 novas'
  ck "lote morto: o jsonl diz 3/2/1" test "$(tail -n 1 "$JSONL" | jq -c '[.batches,.batches_ran,.batches_skipped]')" = '[3,2,1]'; }
case_crash() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"
  mkout "$ISO_OK" 0 "1 failed, 1500 passed in 3000.00s" "worker 'gw3' crashed while running 'tests/x.py::t'" "FAILED tests/x.py::t - worker 'gw3' crashed" "$(fl 1 tests/x.py::t)"; STUB_RC=1 go "$1"
  ck "worker caído: FALHOU, o lote NÃO RODOU" vd FALHOU; ck "worker caído: a tabela diz o motivo" has "$REPORT" 'worker do xdist caiu'; ck "worker caído: baseline intacta" cmp -s "$PREV" "$T/prev.before"; ck "worker caído: nenhum total divulgado como completo" hasnt "$REPORT" '— COMPLETO'; }
case_nocap() { local cl
  for cl in "" "sem-teto (GTN_WORKERS=5 explícito: o governo de quem chamou decide a memória)"; do
    reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"; CAPLINE="$cl" mkout "$ISO_OK" 0 "1500 passed in 3000.00s" "$(fl 0)"
    STUB_RC=0 HZN_BATCH_DEFS=10 go "$1"
    ck "sem prova do teto ('${cl:-vazio}'): FALHOU, exit 1" rcis 1; ck "sem prova do teto: veredito FALHOU" vd FALHOU; ck "sem prova do teto: aviso alto" has "$MAIL_LOG" 'ATENÇÃO.*SEM a linha de prova do teto de memória'
    ck "sem prova do teto: PARA no 1º lote (os outros iriam sem o teto também)" test "$(grep -c '^ARGS:' "$CALLS")" = 1; ck "sem prova do teto: baseline intacta" cmp -s "$PREV" "$T/prev.before"; ck "sem prova do teto: o número não é divulgado" hasnt "$REPORT" 'total:'
  done; }
case_cap_inert() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"
  CAPLINE="inerte memavailable-ilegivel (MemAvailable='' em /proc/meminfo)" mkout "$ISO_OK" "" ""
  STUB_RC=97 HZN_BATCH_DEFS=10 go "$1"
  ck "teto inerte no 1º lote: INERTE, exit 0" rcis 0; ck "teto inerte no 1º lote: veredito INERTE" vd INERTE; ck "teto inerte: e-mail ao Mayor" mailn 1; ck "teto inerte: relatório diz que o teto não foi provado" has "$REPORT" 'Teto de memória NÃO provado.*memavailable-ilegivel'
  ck "teto inerte: tentou 2 vezes o lote 1 e parou (não varreu os lotes seguintes)" test "$(grep -c '^ARGS:' "$CALLS")" = 2; ck "teto inerte: nenhum total divulgado" hasnt "$REPORT" 'total:'; ck "teto inerte: baseline intacta" cmp -s "$PREV" "$T/prev.before"
  ck "teto inerte: o jsonl diz 3 lotes, 0 rodaram, 0 pulados" test "$(tail -n 1 "$JSONL" | jq -c '[.batches,.batches_ran,.batches_skipped]')" = '[3,0,0]'; }
case_cap_retry() { reset
  CAPLINE="inerte memoria-insuficiente (MemAvailable=7000M)" MK_TO="$STUB_OUT.1" mkout "$ISO_OK" "" ""; mkout "$ISO_OK" 0 "1500 passed in 3000.00s" "$(fl 0)"
  STUB_RC_1=97 STUB_RC_2=0 go "$1"
  ck "teto inerte uma vez e bom na 2ª tentativa: COMPLETO" vd COMPLETO; ck "teto inerte uma vez: 2 chamadas" test "$(grep -c '^ARGS:' "$CALLS")" = 2; ck "teto inerte uma vez: o log diz a nova tentativa" has "$OUT" 'lote 01: teto de memória NÃO provado.*nova tentativa'; }
case_cap_late() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"
  okb 1 "600 passed in 100.00s" 0; okb 4 "600 passed in 100.00s" 0
  CAPLINE="inerte memoria-insuficiente (MemAvailable=7000M)" MK_TO="$STUB_OUT.2" mkout "$ISO_OK" "" ""; CAPLINE="inerte memoria-insuficiente (MemAvailable=7000M)" MK_TO="$STUB_OUT.3" mkout "$ISO_OK" "" ""
  STUB_RC_1=0 STUB_RC_2=97 STUB_RC_3=97 STUB_RC_4=0 HZN_BATCH_DEFS=10 go "$1"
  ck "teto inerte num lote que não é o 1º: NÃO é INERTE (já rodou coisa): FALHOU" vd FALHOU; ck "teto inerte tardio: o lote 02 NÃO RODOU e diz as tentativas" has "$REPORT" 'NÃO RODOU \| teto de memória NÃO provado.*\(após 2 tentativa\(s\)\)'
  ck "teto inerte tardio: o 3º lote ainda rodou (4 chamadas = 1 + 2 tentativas + 1)" test "$(grep -c '^ARGS:' "$CALLS")" = 4; ck "teto inerte tardio: assunto" has "$MAIL_LOG" '1 de 3 lotes NÃO RODARAM \(02\)'; ck "teto inerte tardio: baseline intacta" cmp -s "$PREV" "$T/prev.before"; }
case_leak_mid() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"
  okb 1 "600 passed in 100.00s" 0; MK_TO="$STUB_OUT.2" mkout "nao-isolado tcp:1.1.1.1:53" "" ""; okb 3 "600 passed in 100.00s" 0
  STUB_RC_1=0 STUB_RC_2=97 STUB_RC_3=0 HZN_BATCH_DEFS=10 go "$1"
  ck "vazamento no lote 2: FALHOU, exit 1" rcis 1; ck "vazamento no lote 2: veredito FALHOU" vd FALHOU; ck "vazamento no lote 2: o assunto diz VAZAMENTO, o que vazou e o lote" has "$MAIL_LOG" 'FALHOU: VAZAMENTO.*tcp:1\.1\.1\.1:53.*lote 02'
  ck "vazamento no lote 2: PARA (o lote 3 não roda)" test "$(grep -c '^ARGS:' "$CALLS")" = 2; ck "vazamento no lote 2: baseline intacta" cmp -s "$PREV" "$T/prev.before"; ck "vazamento no lote 2: nunca COMPLETO" hasnt "$MAIL_LOG" 'COMPLETO'; }
case_flag_mid() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"
  okb 1 "600 passed in 100.00s" 0; MK_TO="$STUB_OUT.2" mkout "" "" ""; okb 3 "600 passed in 100.00s" 0
  STUB_RC_1=0 STUB_RC_2=99 STUB_RC_3=0 HZN_BATCH_DEFS=10 go "$1"
  ck "nó desligado no meio: NÃO é PULADO (já rodou lote): FALHOU" vd FALHOU; ck "nó desligado no meio: diz que desligou no meio" has "$REPORT" 'o nó foi desligado no meio da rodada'; ck "nó desligado no meio: baseline intacta" cmp -s "$PREV" "$T/prev.before"; }
case_badconst() { reset; mkout "$ISO_OK" 0 "1500 passed in 3000.00s" "$(fl 0)"; STUB_RC=0 HZN_BATCH_DEFS=abc go "$1"
  ck "constante inválida: FALHOU, exit 1" rcis 1; ck "constante inválida: diz qual" has "$MAIL_LOG" 'constante inválida: BATCH_DEFS='; ck "constante inválida: nada rodou" empty_dir_file "$CALLS"
  reset; STUB_RC=0 HZN_BATCH_DEFS=0 go "$1"; ck "constante zero onde precisa >= 1: FALHOU" has "$MAIL_LOG" 'constante inválida: BATCH_DEFS=0'
  # as que só a 1ª checagem cobre (a 2ª só olha BATCH_DEFS/BATCH_T/TRIES/ARGS_MAX): sem ela, 'abc' entraria numa conta aritmética e viraria 0 em silêncio
  reset; mkout "$ISO_OK" 0 "1500 passed in 3000.00s" "$(fl 0)"; STUB_RC=0 HZN_FINAL_MARGIN_S=abc go "$1"; ck "margem não numérica: FALHOU, exit 1" rcis 1; ck "margem não numérica: diz qual" has "$MAIL_LOG" 'constante inválida: MARGIN='; ck "margem não numérica: nada rodou" empty_dir_file "$CALLS"; }
# ga-z6bc623 — lote que NÃO RODOU não apaga a comparação dos que rodaram: PARCIAL, só dos arquivos dos lotes que rodaram, contra a última noite COMPLETA; a baseline nunca anda
case_partial_cmp() { reset; seed_prev tests/a_test.py::t_fixed tests/sub/test_c.py::t_still tests/test_a.py::t_skip2 tests/test_b.py::t_gone3; cp "$PREV" "$T/prev.before"; cp "$LOGDIR/last-complete.meta" "$T/meta.before"
  # 3 lotes (HZN_BATCH_DEFS=10): [a_test, sub/test_c] [test_a] [test_b, test_zero]. O lote 2 é MORTO (rc 137): NÃO RODOU, sem depender de relógio. Os lotes 1 e 3 rodam.
  # Lote 1: t_new (nova) e t_still (já reprovava) reprovam; t_fixed saiu. Lote 3: t_new3 (nova) reprova; t_gone3 saiu. A baseline tem t_skip2 no arquivo do lote 2: NÃO pode virar "corrigida".
  pc_mk() { okb 1 "2 failed, 400 passed in 100.00s" 2 tests/a_test.py::t_new tests/sub/test_c.py::t_still; MK_TO="$STUB_OUT.2" mkout "$ISO_OK" 0 "" "Killed"; okb 3 "1 failed, 300 passed in 50.00s" 1 tests/test_b.py::t_new3; }
  pc_mk; STUB_RC_1=1 STUB_RC_2=137 STUB_RC_3=1 HZN_BATCH_DEFS=10 go "$1"
  ck "parcial: FALHOU, exit 1 (noite incompleta nunca é verde)" rcis 1; ck "parcial: veredito FALHOU" vd FALHOU; ck "parcial: só o lote 02 não rodou" has "$MAIL_LOG" '1 de 3 lotes NÃO RODARAM \(02\)'
  ck "parcial: compara SÓ os 4 arquivos dos 2 lotes que rodaram: 2 novas e 2 corrigidas (t_skip2, do lote que faltou, NÃO é corrigida)" has "$REPORT" 'comparação PARCIAL contra a última noite completa \(2026-01-01 @abc\), só dos 4 arquivos dos 2 lotes que rodaram: 2 falhas NOVAS, 2 corrigidas \(os arquivos dos lotes que não rodaram NÃO foram comparados\)'
  ck "parcial: a nova do lote 1 está listada (decodificada)" has "$REPORT" '^  - tests/a_test.py::t_new$'; ck "parcial: a nova do lote 3 (depois do lote morto) está listada" has "$REPORT" '^  - tests/test_b.py::t_new3$'; ck "parcial: a que já reprovava não é listada" hasnt "$REPORT" '^  - tests/sub/test_c.py::t_still$'
  ck "parcial: o arquivo .new guarda as 2 novas" test "$(wc -l < "$LOGDIR/$DAY.new" | tr -d ' ')" = 2; ck "parcial: o assunto diz a comparação parcial" has "$MAIL_LOG" '\(2 falhas novas nos arquivos que rodaram\)'
  ck "parcial: o jsonl diz compare=parcial" test "$(tail -n 1 "$JSONL" | jq -r .compare)" = parcial
  ck "parcial: a baseline NÃO avançou" cmp -s "$PREV" "$T/prev.before"; ck "parcial: a meta da baseline intacta" cmp -s "$LOGDIR/last-complete.meta" "$T/meta.before"
  ck "parcial: o relatório diz o ritmo medido (17 def test_ rodaram, de 23)" has "$REPORT" 'ritmo medido [0-9]+s para 17 def test_ \(~[0-9]+s para os 23 da árvore\)'
  ck "parcial: o relatório diz o orçamento e o limite que mandou (padrão: prazo de 13500 s, margem de 300 s)" has "$REPORT" 'orçamento da noite: 13500s \(13200s para os lotes, o resto é a margem do relatório\); limite: prazo HZN_TIMEOUT_S=13500s'
  ck "parcial: o relatório não diz mais que não há comparação" hasnt "$REPORT" 'não há comparação com a noite anterior'
  # sem noite completa anterior: nada a comparar (e não é "primeira rodada": a baseline não nasce de uma noite incompleta)
  reset; pc_mk; STUB_RC_1=1 STUB_RC_2=137 STUB_RC_3=1 HZN_BATCH_DEFS=10 go "$1"
  ck "parcial sem baseline: diz que não há noite completa anterior" has "$REPORT" 'comparação parcial: não há noite completa anterior para comparar'; ck "parcial sem baseline: compare='-'" test "$(tail -n 1 "$JSONL" | jq -r .compare)" = -
  ck "parcial sem baseline: nenhuma baseline nasce" test ! -e "$PREV"; ck "parcial sem baseline: o assunto não afirma nenhuma contagem de novas" hasnt "$MAIL_LOG" 'falhas novas nos arquivos'
  # baseline com duas strings JSON na MESMA linha: o jq lê 2 valores de 1 linha, a filtragem linha a linha não bate → INDISPONÍVEL (nunca "0 novas"), baseline intacta
  reset; printf '"tests/a_test.py::x" "tests/test_a.py::y"\n' > "$PREV"; echo "2026-01-01 @abc" > "$LOGDIR/last-complete.meta"; cp "$PREV" "$T/prev.before"; pc_mk
  STUB_RC_1=1 STUB_RC_2=137 STUB_RC_3=1 HZN_BATCH_DEFS=10 go "$1"
  ck "parcial com baseline ilegível: INDISPONÍVEL" has "$REPORT" 'comparação parcial INDISPONÍVEL: .* não pôde ser lido ou filtrado'; ck "parcial com baseline ilegível: compare=indisponivel" test "$(tail -n 1 "$JSONL" | jq -r .compare)" = indisponivel
  ck "parcial com baseline ilegível: baseline intacta" cmp -s "$PREV" "$T/prev.before"; ck "parcial com baseline ilegível: o assunto não afirma contagem" hasnt "$MAIL_LOG" 'falhas novas nos arquivos'
  # lista de ids de um lote que rodou inconsistente (o plugin não imprimiu a linha GTN-FAILED): INDISPONÍVEL, com o porquê
  reset; seed_prev tests/a_test.py::t_fixed; cp "$PREV" "$T/prev.before"; MK_TO="$STUB_OUT.1" mkout "$ISO_OK" 0 "1 failed, 400 passed in 100.00s" "FAILED tests/a_test.py::t_new"; MK_TO="$STUB_OUT.2" mkout "$ISO_OK" 0 "" "Killed"; okb 3 "300 passed in 50.00s" 0
  STUB_RC_1=1 STUB_RC_2=137 STUB_RC_3=0 HZN_BATCH_DEFS=10 go "$1"
  ck "parcial com lista de ids inconsistente: INDISPONÍVEL com o porquê" has "$REPORT" 'comparação parcial INDISPONÍVEL: lote 01: o pytest não imprimiu a linha GTN-FAILED'; ck "parcial com lista inconsistente: baseline intacta" cmp -s "$PREV" "$T/prev.before"
  # nenhum lote rodou (os 3 mortos): nada a comparar
  reset; seed_prev tests/a_test.py::t_fixed; cp "$PREV" "$T/prev.before"; for k in 1 2 3; do MK_TO="$STUB_OUT.$k" mkout "$ISO_OK" 0 "" "Killed"; done
  STUB_RC_1=137 STUB_RC_2=137 STUB_RC_3=137 HZN_BATCH_DEFS=10 go "$1"
  ck "nenhum lote rodou: FALHOU" vd FALHOU; ck "nenhum lote rodou: a comparação parcial diz que não foi feita" has "$REPORT" 'comparação parcial: não feita \(nenhum lote rodou\)'; ck "nenhum lote rodou: ritmo desconhecido, sem inventar" has "$REPORT" 'ritmo desconhecido'
  ck "nenhum lote rodou: compare='-'" test "$(tail -n 1 "$JSONL" | jq -r .compare)" = -; ck "nenhum lote rodou: baseline intacta" cmp -s "$PREV" "$T/prev.before";
  # falhou a lista de arquivos de um lote que RODOU (sumiu depois da chamada): sem ela não sei quais ids da baseline comparar → INDISPONÍVEL, nunca "o lote não tinha arquivos"
  reset; seed_prev tests/a_test.py::t_fixed tests/sub/test_c.py::t_still tests/test_a.py::t_skip2 tests/test_b.py::t_gone3; cp "$PREV" "$T/prev.before"; pc_mk
  STUB_RM_BATCH=1 STUB_RC_1=1 STUB_RC_2=137 STUB_RC_3=1 HZN_BATCH_DEFS=10 go "$1"
  ck "lista do lote que rodou ilegível: INDISPONÍVEL com o porquê" has "$REPORT" 'comparação parcial INDISPONÍVEL: a lista de arquivos de um lote que rodou não pôde ser lida'; ck "lista do lote ilegível: compare=indisponivel" test "$(tail -n 1 "$JSONL" | jq -r .compare)" = indisponivel
  ck "lista do lote ilegível: baseline intacta" cmp -s "$PREV" "$T/prev.before"; ck "lista do lote ilegível: o assunto não afirma contagem" hasnt "$MAIL_LOG" 'falhas novas nos arquivos'; ck "lista do lote ilegível: segue FALHOU" vd FALHOU
  # falhou o comando da comparação (rc != 0): NÃO é "0 novas" — INDISPONÍVEL, .new vazio, baseline intacta
  reset; seed_prev tests/a_test.py::t_fixed tests/sub/test_c.py::t_still tests/test_a.py::t_skip2 tests/test_b.py::t_gone3; cp "$PREV" "$T/prev.before"; pc_mk
  HZN_COMM=false STUB_RC_1=1 STUB_RC_2=137 STUB_RC_3=1 HZN_BATCH_DEFS=10 go "$1"
  ck "comparação que falha: INDISPONÍVEL com o comando que falhou" has "$REPORT" 'comparação parcial INDISPONÍVEL: o comando de comparação \(false\) falhou'; ck "comparação que falha: compare=indisponivel" test "$(tail -n 1 "$JSONL" | jq -r .compare)" = indisponivel
  ck "comparação que falha: nunca '0 falhas NOVAS'" hasnt "$REPORT" '0 falhas NOVAS'; ck "comparação que falha: o assunto não afirma contagem" hasnt "$MAIL_LOG" 'falhas novas nos arquivos'; ck "comparação que falha: .new vazio" test ! -s "$LOGDIR/$DAY.new"
  ck "comparação que falha: baseline intacta" cmp -s "$PREV" "$T/prev.before"; }
# ga-z6bc623 — o fim do orçamento é o MENOR entre o prazo (T0 + HZN_TIMEOUT_S) e o relógio (próxima HZN_STOP_UTC): a janela da noite termina no reseed do nó, não num número de lotes.
# HZN_NOW_S fixa "agora" só na conta do relógio. Epochs: 1699920000 = 00:00:00Z; 05:30 = 1699939800; 08:40 = 1699951200; 08:45 = 1699951500; 08:50 = 1699951800.
case_stop_clock() { reset; okb 1 "1200 passed in 100.00s" 0
  # (a) agora = 08:40Z, limite 08:45Z: sobram 300 s e a margem do relatório (300 s) consome tudo → o lote 1 NÃO começa (nunca roda por cima do reseed)
  HZN_STOP_UTC=08:45 HZN_NOW_S=1699951200 go "$1"
  ck "relógio: FALHOU, exit 1" rcis 1; ck "relógio: o lote não começou (nenhuma chamada ao mbp-run)" test "$(grep -c '^ARGS:' "$CALLS")" = 0; ck "relógio: a tabela diz orçamento esgotado" has "$REPORT" 'orçamento esgotado: restam -?[0-9]+s'
  ck "relógio: o log do início diz que o limite é o relógio" has "$OUT" 'limite: relógio 08:45 UTC'; ck "relógio: o relatório diz o limite" has "$REPORT" 'limite: relógio 08:45 UTC'
  # (b) agora = 05:30Z: até 08:45Z são 11700 s; menos 300 de margem = ~11400 s para os lotes, e a rodada normal roda inteira
  reset; okb 1 "1200 passed in 100.00s" 0; STUB_RC_1=0 HZN_STOP_UTC=08:45 HZN_NOW_S=1699939800 go "$1"
  ck "relógio 05:30Z: COMPLETO" vd COMPLETO; ck "relógio 05:30Z: o orçamento é o do relógio (~11400 s)" has "$OUT" 'orçamento 11[34][0-9]{2}s para os lotes, limite: relógio 08:45 UTC'
  # (c) agora = 08:50Z (depois do limite de hoje): a próxima ocorrência é amanhã, longe; vale o prazo
  reset; okb 1 "1200 passed in 100.00s" 0; STUB_RC_1=0 HZN_STOP_UTC=08:45 HZN_NOW_S=1699951800 go "$1"
  ck "relógio 08:50Z: vale o prazo (o limite é amanhã)" has "$OUT" 'orçamento 13[01][0-9]{2}s para os lotes, limite: prazo HZN_TIMEOUT_S=13500s'; ck "relógio 08:50Z: COMPLETO" vd COMPLETO
  # (d) agora = 08:45:00Z em ponto: delta 0 não é "agora": é a ocorrência de amanhã (não nasce sem orçamento)
  reset; okb 1 "1200 passed in 100.00s" 0; STUB_RC_1=0 HZN_STOP_UTC=08:45 HZN_NOW_S=1699951500 go "$1"
  ck "relógio 08:45:00Z em ponto: vale o prazo, a rodada roda" has "$OUT" 'limite: prazo HZN_TIMEOUT_S=13500s'; ck "relógio 08:45:00Z em ponto: COMPLETO" vd COMPLETO
  # (e) HZN_STOP_UTC vazio desliga o relógio (mesmo com "agora" = 08:40Z)
  reset; okb 1 "1200 passed in 100.00s" 0; STUB_RC_1=0 HZN_STOP_UTC= HZN_NOW_S=1699951200 go "$1"
  ck "relógio vazio: só o prazo vale" has "$OUT" 'limite: prazo HZN_TIMEOUT_S=13500s'; ck "relógio vazio: COMPLETO" vd COMPLETO
  # (f) o relógio é HH:MM de verdade; lixo → FALHOU antes de rodar qualquer coisa (nunca vira "sem limite" calado)
  reset; okb 1 "1200 passed in 100.00s" 0; HZN_STOP_UTC=25:99 go "$1"
  ck "relógio inválido: FALHOU, exit 1" rcis 1; ck "relógio inválido: diz qual" has "$MAIL_LOG" 'constante inválida: HZN_STOP_UTC='; ck "relógio inválido: nada rodou" empty_dir_file "$CALLS"
  reset; okb 1 "1200 passed in 100.00s" 0; HZN_STOP_UTC=8:45 go "$1"; ck "relógio sem o zero (8:45): FALHOU" has "$MAIL_LOG" 'constante inválida: HZN_STOP_UTC='
  # (g) o "agora" injetado também é inteiro ou nada
  reset; okb 1 "1200 passed in 100.00s" 0; HZN_STOP_UTC=08:45 HZN_NOW_S=abc go "$1"
  ck "agora ilegível: FALHOU, exit 1" rcis 1; ck "agora ilegível: diz qual" has "$MAIL_LOG" 'HZN_NOW_S='; ck "agora ilegível: nada rodou" empty_dir_file "$CALLS"; }
case_notests() { reset; HZN_WA_REPO="$T/wa-notests" go "$1"; ck "origin/main sem tests/: FALHOU, exit 1" rcis 1; ck "origin/main sem tests/: diz que não tem tests/" has "$MAIL_LOG" 'não tem tests/'; ck "origin/main sem tests/: nada rodou" empty_dir_file "$CALLS"; }

case_maconly() { reset; mkout "$ISO_OK" 0 "1500 passed in 3000.00s" "$(fl 0)"
  # lista aprendida pela sombra: lida junto da estática
  printf 'tests/sub/test_c.py\n' > "$C/.gc/hetzner-mac-only.learned"; STUB_RC=0 go "$1"; rm -f "$C/.gc/hetzner-mac-only.learned"
  ck "mac-only aprendido: exit 0 e COMPLETO" rcis 0; ck "mac-only aprendido: o arquivo aprendido fica fora do lote" hasnt "$CALLS" 'tests/sub/test_c.py'; ck "mac-only aprendido: sobram 4 arquivos (e 3 fora)" has "$REPORT" '^\| 01 \| 4 \| 17 \| '
  ck "mac-only aprendido: o relatório conta 3 fora" has "$REPORT" 'fora da rodada por regra do nó: 3 arquivos mac-only'
  # lista estática que não abre: sem ela não se sabe o que tem de ficar no Mac
  reset; STUB_RC=0 HETZNER_MAC_ONLY_LIST="$T/nao-existe.txt" go "$1"; ck "lista mac-only ilegível: FALHOU, exit 1" rcis 1; ck "lista mac-only ilegível: diz que não abre" has "$MAIL_LOG" 'lista mac-only .* não abre'; ck "lista mac-only ilegível: nada rodou" empty_dir_file "$CALLS"
  # tudo mac-only: nada a rodar no nó, nunca um verde vazio
  reset; printf 'tests/*\n' > "$T/mac-all.txt"; STUB_RC=0 HETZNER_MAC_ONLY_LIST="$T/mac-all.txt" go "$1"; ck "tudo mac-only: FALHOU, exit 1" rcis 1; ck "tudo mac-only: diz o porquê" has "$MAIL_LOG" 'ficam no mini \(mac-only'; ck "tudo mac-only: nada rodou" empty_dir_file "$CALLS"
  # lista só com comentário (nenhum glob): nada é excluído, como no mbp-run
  reset; mkout "$ISO_OK" 0 "1500 passed in 3000.00s" "$(fl 0)"; printf '# nada\n' > "$T/mac-none.txt"; STUB_RC=0 HETZNER_MAC_ONLY_LIST="$T/mac-none.txt" go "$1"; ck "lista sem globs: nada excluído (7 arquivos)" has "$REPORT" '^\| 01 \| 7 \| 28 \| '; }

case_retidos() { reset; mkout "$ISO_OK" 0 "1500 passed in 3000.00s" "$(fl 0)"
  # o filtro do rsync barra um arquivo por NOME (além do que a varredura de CPFs retém): os dois ficam fora, e a conta separa os dois motivos
  HETZNER_RSYNC_FILTER="$T/filter-bar.txt" STUB_RC=0 go "$1"
  ck "filtro barra 1 + varredura retém 1: exit 0 e COMPLETO" rcis 0; ck "filtro barra 1 + varredura retém 1: nenhum dos dois vai ao nó" hasnt "$CALLS" 'test_zero|test_pii_lista'
  ck "filtro barra 1 + varredura retém 1: o relatório separa os motivos" has "$REPORT" 'fora da rodada porque o nó não os recebe: 2 arquivos \(1 barrados pelo filtro do rsync, 1 com lista de telefones/CPFs'; ck "filtro barra 1 + varredura retém 1: sobram 4 arquivos" has "$REPORT" '^\| 01 \| 4 \| 23 \| '
  ck "filtro barra 1 + varredura retém 1: a lista dos retidos tem os dois" test "$(sort "$LOGDIR/$DAY.retidos.lst" | tr '\n' ' ')" = "tests/test_pii_lista.py tests/test_zero.py "
  # fecha-falha: sem saber o que o nó recebe, nada roda (nunca "recebe tudo")
  reset; STUB_RC=0 HETZNER_RSYNC_FILTER="$T/nao-existe.txt" go "$1"; ck "filtro do nó ilegível: FALHOU, exit 1" rcis 1; ck "filtro do nó ilegível: diz que não abre" has "$MAIL_LOG" 'filtro do rsync do nó .* não abre'; ck "filtro do nó ilegível: nada rodou" empty_dir_file "$CALLS"
  reset; STUB_RC=0 MBP_RSYNC="$T/rsync-partial.sh" go "$1"; ck "rsync -n sai com erro: FALHOU, exit 1" rcis 1; ck "rsync -n sai com erro: diz que não listou" has "$MAIL_LOG" 'rsync -n do filtro do nó .* não listou'; ck "rsync -n sai com erro: nada rodou" empty_dir_file "$CALLS"
  reset; STUB_RC=0 MBP_RSYNC="$T/rsync-empty.sh" go "$1"; ck "rsync -n sem lista: FALHOU, exit 1" rcis 1; ck "rsync -n sem lista: diz que não listou" has "$MAIL_LOG" 'rsync -n do filtro do nó .* não listou'; ck "rsync -n sem lista: nada rodou" empty_dir_file "$CALLS"
  reset; STUB_RC=0 HZN_PII_SCAN="$T/pii-fail.sh" go "$1"; ck "varredura de CPFs falha: FALHOU, exit 1" rcis 1; ck "varredura de CPFs falha: diz que não terminou" has "$MAIL_LOG" 'varredura de telefones/CPFs .* não terminou'; ck "varredura de CPFs falha: nada rodou" empty_dir_file "$CALLS"
  reset; STUB_RC=0 HZN_PII_SCAN="$T/nao-existe.py" go "$1"; ck "scanner de PII ausente: FALHOU, exit 1" rcis 1; ck "scanner de PII ausente: diz que não existe" has "$MAIL_LOG" 'scanner de PII .* não existe'; ck "scanner de PII ausente: nada rodou" empty_dir_file "$CALLS"
  # nada chega ao nó: nunca um verde vazio
  reset; STUB_RC=0 HETZNER_RSYNC_FILTER="$T/filter-none.txt" go "$1"; ck "o nó não recebe nenhum teste: FALHOU, exit 1" rcis 1; ck "o nó não recebe nenhum teste: diz o porquê" has "$MAIL_LOG" 'ficam no mini \(mac-only'; ck "o nó não recebe nenhum teste: nada rodou" empty_dir_file "$CALLS"; }

case_nobatch() { reset; mkout "$ISO_OK" 0 "1500 passed in 3000.00s" "$(fl 0)"
  # o awk que monta os lotes não consegue escrever o batch.meta (o diretório de destino não existe): NB vem VAZIO do wc; a noite FALHA e tem de gravar a linha do jsonl mesmo assim (NB vazio derrubava o jq do jline)
  # (o SUT põe /usr/bin na frente do PATH, então um shim de awk no PATH não pega: a cópia do SUT é que aponta o awk para um diretório que não existe)
  local X="$T/m-nobatch-run.sh"; sed 's|-v dir="\$SCR"|-v dir="$SCR/nao-existe"|' "$1" > "$X"; chmod +x "$X"
  ck "sem lotes montados: a cópia do SUT mudou a chamada do awk (senão o caso não prova nada)" not_same "$1" "$X"
  STUB_RC=0 go "$X"
  ck "sem lotes montados: FALHOU, exit 1" rcis 1; ck "sem lotes montados: diz que não montou" has "$MAIL_LOG" 'não montei os lotes'; ck "sem lotes montados: nada rodou" empty_dir_file "$CALLS"
  ck "sem lotes montados: o jsonl TEM a linha da noite (veredito FALHOU, 0 lotes)" test "$(tail -n 1 "$JSONL" | jq -c '[.verdict,.batches,.batches_ran]' 2>/dev/null)" = '["FALHOU",0,0]'
  ck "sem lotes montados: nenhum aviso de jsonl não gravado" hasnt "$OUT" 'não gravei'; ck "sem lotes montados: o escudo é null (nada rodou)" test "$(tail -n 1 "$JSONL" | jq -c .escudo_reports 2>/dev/null)" = null; }
case_escudo() { reset; local A='tests/a_test.py::t1'
  # lote 1 refez 2 relatórios, lote 2 nenhum (o plugin não imprime a linha com n=0), lote 3 refez 1: soma 3
  EG=0 okb 1 "1 failed, 400 passed in 100.00s" 1 "$A"; printf 'GTN-ESCUDO: n=2\n' >> "$STUB_OUT.1"
  okb 2 "500 passed in 200.00s" 0; okb 3 "300 passed in 50.00s" 0; printf 'GTN-ESCUDO: n=1\n' >> "$STUB_OUT.3"
  STUB_RC_1=1 STUB_RC_2=0 STUB_RC_3=0 HZN_BATCH_DEFS=10 go "$1"
  ck "escudo: COMPLETO, exit 0" vd COMPLETO; ck "escudo: o relatório soma os lotes (2+0+1 = 3)" has "$REPORT" 'escudo do relatório \(plugin gtn_stable_ids\): 3 relatório\(s\) refeito\(s\) sem o hook da suíte que quebrou'
  ck "escudo: o jsonl tem escudo_reports=3" test "$(tail -n 1 "$JSONL" | jq -c .escudo_reports)" = 3
  # sem nenhuma linha GTN-ESCUDO: lote que rodou = 0 (o plugin só imprime com n > 0)
  reset; mkout "$ISO_OK" 0 "1500 passed in 3000.00s" "$(fl 0)"; STUB_RC=0 go "$1"
  ck "escudo: sem a linha em lote que rodou = 0 no relatório" has "$REPORT" 'escudo do relatório \(plugin gtn_stable_ids\): 0 \(nenhum hook da suíte quebrou'; ck "escudo: sem a linha = 0 no jsonl (não null)" test "$(tail -n 1 "$JSONL" | jq -c .escudo_reports)" = 0
  # linha presente e ilegível = "?" e null, nunca 0
  reset; mkout "$ISO_OK" 0 "1500 passed in 3000.00s" "$(fl 0)"; printf 'GTN-ESCUDO: n=abc\n' >> "$STUB_OUT"; STUB_RC=0 go "$1"
  ck "escudo ilegível: segue COMPLETO (o escudo não muda o veredito)" vd COMPLETO; ck "escudo ilegível: o relatório diz ILEGÍVEL e não afirma zero" has "$REPORT" 'escudo do relatório \(plugin gtn_stable_ids\): contagem ILEGÍVEL'
  ck "escudo ilegível: o jsonl tem null (não 0)" test "$(tail -n 1 "$JSONL" | jq -c .escudo_reports)" = null; }
ALL="first second cleanslate xfail inerte leak 97_sem_iso pulado timeout abort noiso nosum implausible lock lock_stale prev_unreadable mailfail egress ssh no_origin stale_report listfail prev_format dash partial fetch keep provenance dur maconly retidos batches batch_list overbudget batch_killed crash nocap cap_inert cap_retry cap_late leak_mid flag_mid badconst notests nobatch escudo partial_cmp stop_clock"
for c in $ALL; do "case_$c" "$SUT0"; done

# ---- controles negativos: o caso correspondente tem de FALHAR quando roda no mutante -----------------------------------------
M=0
# o controle do controle: uma cópia NEUTRA (só um comentário a mais) tem de PASSAR todos os casos. Se reprovasse, todo mutante abaixo "morreria" por qualquer motivo e a prova seria vazia
# (foi assim até o gate 1: o mutante morava em $T sem os arquivos irmãos que o script lê de $HERE, e reprovava todo caso, qualquer que fosse a mutação).
f="$T/m-neutro.sh"; { cat "$SUT0"; echo "# neutro"; } > "$f"; chmod +x "$f"; n=$((n+1)); BAD=0; ZB=""; QUIET=1; for c in $ALL; do BAD=0; "case_$c" "$f"; [ "$BAD" = 0 ] || ZB="$ZB $c"; done; QUIET=0; BAD=0; [ -z "$ZB" ] || BAD=1
if [ "$BAD" = 0 ]; then echo "ok   M0-neutro (a cópia neutra passa TODOS os casos: os mutantes abaixo reprovam por causa da mutação)"; else echo "FAIL M0-neutro: a cópia NEUTRA reprovou o(s) caso(s)$ZB (o controle negativo seria vazio)"; fails=$((fails+1)); fi
mutant() { # nome expr-sed caso — cria o mutante, roda o caso em silêncio e exige que ele reprove
  local f="$T/m-$1.sh"; sed "$2" "$SUT0" > "$f"; chmod +x "$f"; n=$((n+1)); M=$((M+1))
  if cmp -s "$SUT0" "$f"; then echo "FAIL $1: o sed não casou (mutante igual ao original)"; fails=$((fails+1)); return; fi
  bash -n "$f" 2>/dev/null || { echo "FAIL $1: o mutante tem erro de sintaxe (a prova seria vazia)"; fails=$((fails+1)); return; }
  BAD=0; QUIET=1; "case_$3" "$f"; QUIET=0
  if [ "$BAD" = 1 ]; then echo "ok   $1 (o caso '$3' reprova o mutante)"; else echo "FAIL $1: o caso '$3' NÃO reprovou o mutante"; fails=$((fails+1)); fi; }
mutant M4-novas-lidas-como-comuns 's/comm -13 /comm -12 /' second
mutant M5-pulado-manda-email 's/if \[ "\$v" != PULADO \]; then/if true; then/' pulado
mutant M6-sem-comparacao-vira-0-novas 's/NEWTXT="sem comparação"/NEWTXT="0 novas"/' prev_unreadable
mutant M7-total-implausivel-aceito 's/^\[ "\$TOTAL" -ge "\$MIN_TOTAL" \] || finish.*$/true/' implausible
mutant M8-falha-de-email-ignorada 's/|| { MAILRC=1; .*$/|| true/' mailfail
mutant M9-relatorio-velho-nao-truncado 's/^: > "\$REPORT".*$/true/' stale_report
mutant M10-error-singular-nao-contado "s/cnt 'errors?'/cnt 'errors'/" xfail
mutant M11-lock-vivo-ignorado 's/if \[ -n "\$op" \] && \[ -z "\$old" \] && kill -0 "\$op" 2>\/dev\/null; then/if false; then/' lock
mutant M12-ssh-ignorado 's/if ! \$SSH /if false \&\& ! $SSH /' ssh
mutant M24-fetch-falho-sem-aviso 's/^else FETCHST=falhou; STALE_NOTE=/else FETCHST=falhou; STALE_X=/' fetch
mutant M25-lock-velho-ignorado 's/ \&\& \[ -z "\$old" \] \&\& kill -0/ \&\& kill -0/' lock_stale
mutant M26-pulado-por-lock-sem-jsonl 's/^    jline PULADO "outra rodada em andamento (pid \$op)"; say/    say/' lock
mutant M27-limpeza-apaga-a-baseline "s/ ! -name 'last-complete.\*'//" keep
mutant M28-vazamento-vira-inerte 's/finish FALHOU "VAZAMENTO MEDIDO/finish INERTE "VAZAMENTO MEDIDO/' leak
mutant M29-no-do-mbp-run-diferente-do-instalador 's/ HETZNER_NODE_HOST="\$NODE"//' first
mutant M30-procedencia-fora-do-relatorio 's/^  echo "- instalado no nó: \$DEPLOY"$/  true/' provenance
mutant M31-lock-tomado-nao-renovado 's/^touch "\$LOCK" 2>\/dev\/null.*$/true/' lock_stale
# mutantes por substituição LITERAL (sem regex): old → new, no arquivo inteiro
mutantl() { # nome caso old new [old new]... — cada par é uma troca literal no arquivo inteiro
  local f="$T/m-$1.sh" c nm=$1 cs=$2; c=$(cat "$SUT0"; echo x); c=${c%x}; shift 2
  while [ $# -ge 2 ]; do c=${c/"$1"/"$2"}; shift 2; done; printf '%s' "$c" > "$f"; chmod +x "$f"; n=$((n+1)); M=$((M+1)); set -- "$nm" "$cs"
  if cmp -s "$SUT0" "$f"; then echo "FAIL $1: o trecho não casou (mutante igual ao original)"; fails=$((fails+1)); return; fi
  bash -n "$f" 2>/dev/null || { echo "FAIL $1: o mutante tem erro de sintaxe (a prova seria vazia)"; fails=$((fails+1)); return; }
  BAD=0; QUIET=1; "case_$2" "$f"; QUIET=0
  if [ "$BAD" = 1 ]; then echo "ok   $1 (o caso '$2' reprova o mutante)"; else echo "FAIL $1: o caso '$2' NÃO reprovou o mutante"; fails=$((fails+1)); fi; }
mutantl M15-lista-parcial-vira-completa partial 'elif [ "$nids" -ne "$sn" ]; then' 'elif false; then'
mutantl M17-contagem-do-plugin-x-resumo-ignorada partial 'elif [ "$sr" -ne $(( FAILED + ERRORS )) ]; then' 'elif false; then'
mutantl M18-sem-linha-do-plugin-e-sem-falhas-vira-zero listfail 'if [ "$nsent" -eq 0 ]; then w=' 'if [ "$nsent" -eq 0 ] && [ $(( FAILED + ERRORS )) -eq 0 ]; then w=""
  elif [ "$nsent" -eq 0 ]; then w='
mutantl M19-id-lido-da-linha-humana-cortada-no-1o-traco dash "LC_ALL=C sed -n 's/^GTN-FAIL: //p' \"\$f\" 2>/dev/null |" "LC_ALL=C sed -n -E 's/^(FAILED|ERROR) (.*)\$/\\2/p' \"\$f\" 2>/dev/null | sed -E 's/ - .*\$//; s/^(.*)\$/\"\\1\"/' |"
mutantl M20-o-bug-original-sem-a-conferencia-de-n dash "LC_ALL=C sed -n 's/^GTN-FAIL: //p' \"\$f\" 2>/dev/null |" "LC_ALL=C sed -n -E 's/^(FAILED|ERROR) (.*)\$/\\2/p' \"\$f\" 2>/dev/null | sed -E 's/ - .*\$//; s/^(.*)\$/\"\\1\"/' |" 'elif [ "$nids" -ne "$sn" ]; then' 'elif false; then'
mutantl M21-json-nao-validado partial 'elif ! jq -en '"'"'[inputs | type == "string"] | all'"'"' "$SCR/ids.b" >/dev/null 2>&1; then' 'elif false; then'
mutantl M22-sentinela-duplicada-aceita partial 'elif [ "$nsent" -gt 1 ]; then w=' 'elif false; then w='
mutantl M23-baseline-de-outro-formato-aceita prev_format "jq -en '[inputs | type == \"string\"] | all' \"\$PREV\" >/dev/null 2>&1 && " ''
# mutantes do desenho em lotes (ga-84gkpab) e os que antes eram sed de uma linha que deixou de existir
mutantl M1-sem-prova-de-isolamento noiso '*) B_ST=sem-prova; B_WHY="ATENÇÃO: o lote terminou SEM a linha de prova do isolamento' 'nunca_casa) B_ST=sem-prova; B_WHY="ATENÇÃO: o lote terminou SEM a linha de prova do isolamento'
mutantl M2-prazo-124-ignorado timeout '124) B_WHY="estourou' 'nunca_casa) B_WHY="estourou'
mutantl M3-inerte-vira-falhou inerte 'inerte*) B_ST=inerte-iso;' 'nunca_casa) B_ST=inerte-iso;'
mutantl M13-contador-ilegivel-vira-0 egress 'if [ "$EGUNK" = 0 ] && [ "$EGSEEN" = 1 ]; then EGRESS=$EGSUM; else EGRESS="?"; fi' 'EGRESS=$EGSUM'
mutantl M14-pytest-abortado-segue abort '0|1) ;;' '0|1|2) ;;'
mutantl M16-duracao-ilegivel-vira-0h0min dur '[ "$PYUNK" = 0 ] || PYSECS=""; ' ''
mutantl M32-lotes-colapsados-em-um batches 'if (cnt>0 && (acc+w>max || bytes+length(f)+1>amax))' 'if (0)'
mutantl M33-lote-que-nao-rodou-vira-verde overbudget 'if [ "$NSKIP" -gt 0 ]; then' 'if false; then'
mutantl M34-orcamento-de-tempo-ignorado overbudget 'if [ "$left" -lt "$MIN_BATCH" ]; then' 'if false; then'
mutantl M35-teto-de-memoria-sem-prova-aceito nocap 'MemoryMax=*MemorySwapMax=0*) ;; *) B_ST=sem-prova;' '*) ;; nunca_casa) B_ST=sem-prova;'
mutantl M36-rc-137-aceito-como-rodou batch_killed '0|1) ;;' '0|1|137) ;;'
mutantl M37-worker-caido-ignorado crash 'if [ -n "$mk" ]; then B_WHY=' 'if false; then B_WHY='
mutantl M38-sem-retry-do-transitorio cap_retry 'if [ "$tries" -lt "$TRIES" ] &&' 'if false &&'
mutantl M39-teto-inerte-no-1o-lote-vira-falhou cap_inert 'finish INERTE "teto de memória não provado no nó' 'finish FALHOU "teto de memória não provado no nó'
mutantl M40-vazamento-no-meio-nao-para leak_mid 'B_ST=vazamento; B_WHY="o canário SAIU pela rede' 'B_ST=nao-rodou; B_WHY="o canário SAIU pela rede'
mutantl M41-ids-dos-lotes-nao-unidos batches 'cat "$SCR/ids.b" >> "$SCR/ids.all"' 'true'
mutantl M42-soma-so-do-ultimo-lote batches 'TP=$(( TP + PASSED ))' 'TP=$PASSED'
mutantl M43-lista-inconsistente-de-um-lote-ignorada batch_list 'if [ -n "$w" ]; then LISTOK=0;' 'if false; then LISTOK=0;'
mutantl M44-poda-do-pytest-ini-esquecida first '-o -name crew -o -name archive ' ''
mutantl M45-constante-invalida-aceita badconst "''|*[!0-9]*) finish FALHOU \"constante inválida: \$v='\$x'" "nunca_casa) finish FALHOU \"constante inválida: \$v='\$x'"
mutantl M46-nó-desligado-no-meio-vira-pulado flag_mid '[ "$i" -ne 1 ] || finish PULADO' 'finish PULADO'
mutantl M50-prazo-do-lote-ignora-o-que-resta overbudget 'bt=$BATCH_T; [ "$left" -ge "$bt" ] || bt=$left' 'bt=$BATCH_T'
mutantl M52-sem-prova-no-meio-nao-para nocap $'    sem-prova)\n      { echo "# Hetzner nightly $DAY — FALHOU: lote $nn sem prova' $'    nunca_casa)\n      { echo "# Hetzner nightly $DAY — FALHOU: lote $nn sem prova'
mutantl M53-mac-only-nao-excluido first 'if [ "$hit" = 1 ]; then ' 'if false; then '
mutantl M54-lista-mac-only-ilegivel-aceita maconly '|| finish FALHOU "a lista mac-only ($MACLIST) não abre' '|| : "a lista mac-only ($MACLIST) não abre'
mutantl M55-lista-aprendida-ignorada maconly 'done < <(cat "$MACLIST" "$MACLEARN" 2>/dev/null)' 'done < <(cat "$MACLIST" 2>/dev/null)'
mutantl M56-tudo-mac-only-aceito maconly '[ "$NFILES" -ge 1 ] || finish FALHOU "todos os arquivos' '[ "$NFILES" -ge 1 ] || : "todos os arquivos'
mutantl M57-glob-sem-aparar-espacos maconly 'g=${g#"${g%%[![:space:]]*}"}; g=${g%"${g##*[![:space:]]}"}' ':'
mutantl M58-arquivo-retido-pela-varredura-vai-ao-no first 'if [ "$NHELD" -gt 0 ]; then LC_ALL=C grep -vxF' 'if false; then LC_ALL=C grep -vxF'
mutantl M59-arquivo-barrado-pelo-filtro-vai-ao-no retidos 'LC_ALL=C grep -vxF -f "$SCR/pf.sent" "$FILES" > "$SCR/pf.nosend"' ':'
mutantl M60-varredura-que-nao-termina-aceita retidos '|| finish FALHOU "a varredura de telefones/CPFs' '|| : "a varredura de telefones/CPFs'
mutantl M61-rsync-com-erro-aceito retidos '{ [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$SCR/pf.sent" ]; }' '{ [ -s "$SCR/pf.sent" ]; }'
mutantl M62-lista-vazia-do-rsync-aceita retidos '{ [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$SCR/pf.sent" ]; }' '{ [ "${PIPESTATUS[0]}" -eq 0 ]; }'
mutantl M63-retidos-da-varredura-ignorados first 'if [ -s "$SCR/pf.hp" ]; then LC_ALL=C grep -xF' 'if false; then LC_ALL=C grep -xF'
mutantl M64-filtro-ilegivel-aceito retidos '|| finish FALHOU "o filtro do rsync do nó ($NFILTER) não abre' '|| : "o filtro do rsync do nó ($NFILTER) não abre'
mutantl M65-scanner-ausente-aceito retidos '[ -f "$PIISCAN" ] || finish FALHOU' '[ -f "$PIISCAN" ] || : '
mutantl M66-nb-lixo-derruba-a-linha-do-jsonl nobatch 'NBX=$(wc -l < "$SCR/batch.meta"' 'NB=$(wc -l < "$SCR/batch.meta"' 'case "$NBX" in' 'case "$NB" in' $'\nNB=$NBX\n' $'\n'
mutantl M67-escudo-nao-somado escudo 'ESCSUM=$(( ESCSUM + es ))' 'ESCSUM=$ESCSUM'
mutantl M68-escudo-ilegivel-vira-zero escudo '*[!0-9]*) ESCUNK=1 ;;' '*[!0-9]*) ;;'
mutantl M69-escudo-fora-do-relatorio escudo $'  echo "- escudo do relatório (plugin gtn_stable_ids): $ESCTXT"\n' ''
# ga-z6bc623: comparação parcial e limite do relógio
mutantl M70-parcial-sem-filtro-por-arquivo partial_cmp '($m[(split("::")[0])] // false)' 'true'
mutantl M71-parcial-novas-lidas-como-comuns partial_cmp 'LC_ALL=C comm -13 "$SCR/prev.partial" "$CUR" > "$NEW"' 'LC_ALL=C comm -12 "$SCR/prev.partial" "$CUR" > "$NEW"'
mutantl M72-parcial-avanca-a-baseline partial_cmp 'NEWTXT="$(wc -l < "$NEW" | tr -d '"'"' '"'"') falhas novas nos arquivos que rodaram"; CMPST=parcial' 'NEWTXT="$(wc -l < "$NEW" | tr -d '"'"' '"'"') falhas novas nos arquivos que rodaram"; CMPST=parcial; cp "$CUR" "$PREV"'
mutantl M73-parcial-ignora-lista-de-ids-inconsistente partial_cmp 'elif [ "$LISTOK" = 0 ]; then PCMP=' 'elif false; then PCMP='
mutantl M74-parcial-sem-baseline-vira-indisponivel partial_cmp 'elif [ ! -e "$PREV" ]; then PCMP=' 'elif false; then PCMP='
mutantl M75-parcial-aceita-filtragem-que-nao-bate-linha-a-linha partial_cmp '&& [ "$(wc -l < "$SCR/prev.flags" | tr -d '"'"' '"'"')" = "$(wc -l < "$PREV" | tr -d '"'"' '"'"')" ] \' '\'
mutantl M76-parcial-sem-nenhum-lote-vira-comparacao partial_cmp 'if [ "$NRAN" -eq 0 ]; then CMPST=-' 'if false; then CMPST=-'
mutantl M77-arquivos-dos-lotes-que-rodaram-nao-guardados partial_cmp 'cat "$SCR/batch.$i" >> "$SCR/ran.files"; ' ''
mutantl M78-parcial-fora-do-relatorio partial_cmp $'    echo "- $PCMP"\n' ''
mutantl M79-ritmo-fora-do-relatorio partial_cmp $'    echo "- $PACE"\n' ''
mutantl M80-relogio-ignorado stop_clock 'if [ $(( T0 + CLK_DELTA )) -lt "$BUDGET_END" ]; then' 'if false; then'
mutantl M81-relogio-zero-nao-vira-amanha stop_clock '[ "$CLK_DELTA" -gt 0 ] || CLK_DELTA=86400' ':'
mutantl M82-relogio-invalido-aceito stop_clock "''|[01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) finish FALHOU \"constante inválida: HZN_STOP_UTC" "*) ;; nunca_casa) finish FALHOU \"constante inválida: HZN_STOP_UTC"
mutantl M83-agora-ilegivel-aceito stop_clock "''|*[!0-9]*) finish FALHOU \"HZN_NOW_S=" "nunca_casa) finish FALHOU \"HZN_NOW_S="
mutantl M84-hora-com-zero-vira-octal stop_clock '10#${STOP_UTC%:*}' '${STOP_UTC%:*}'
mutantl M85-relogio-vazio-nao-desliga stop_clock 'STOP_UTC=${HZN_STOP_UTC-08:45}' 'STOP_UTC=${HZN_STOP_UTC:-08:45}'
mutantl M86-o-prazo-do-relogio-nao-aparece-no-aviso stop_clock 'BUDGET_BY="relógio ${STOP_UTC} UTC"' 'BUDGET_BY="prazo HZN_TIMEOUT_S=${TIMEOUT_S}s"'
mutantl M87-comparacao-que-falha-vira-0-novas partial_cmp $'if LC_ALL=C $COMM -13 "$SCR/prev.partial" "$CUR" > "$NEW" 2>/dev/null && FIXED=$(LC_ALL=C $COMM -23 "$SCR/prev.partial" "$CUR" | wc -l | tr -d \' \') && [ -n "$FIXED" ]; then' $'LC_ALL=C $COMM -13 "$SCR/prev.partial" "$CUR" > "$NEW" 2>/dev/null; FIXED=$(LC_ALL=C $COMM -23 "$SCR/prev.partial" "$CUR" | wc -l | tr -d \' \'); if true; then'
mutantl M88-lista-do-lote-ilegivel-ignorada partial_cmp 'cat "$SCR/batch.$i" >> "$SCR/ran.files" 2>/dev/null || RANFILES_BAD=1' 'cat "$SCR/batch.$i" >> "$SCR/ran.files" 2>/dev/null || true'
mutantl M89-lista-ilegivel-nao-vira-indisponivel partial_cmp 'elif [ "$RANFILES_BAD" = 1 ]; then PCMP=' 'elif false; then PCMP='
reset
echo "---"; echo "$((n-fails))/$n ok ($M mutantes)"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
