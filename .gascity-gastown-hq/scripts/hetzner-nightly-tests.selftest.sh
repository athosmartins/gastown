#!/usr/bin/env bash
# hetzner-nightly-tests.selftest.sh — hermético: mbp-run, ssh e e-mail são stubs; nada toca o nó, o Mayor nem o live (ga-9p6pte).
#
# ## Contents
#   Casos · Controles negativos
#
# IDS REPROVADOS: vêm do plugin (linhas `GTN-FAIL: <id em JSON>` + `GTN-FAILED: n=.. reports=..`), nunca da linha humana `FAILED <id> - <msg>` (id de parametrize pode ter " - "). A saída de
#   mentira traz AS DUAS formas, como o pytest de verdade, com ids que têm " - " dentro.
# CASOS: 1ª noite COMPLETO (linha de base, argumentos do mbp-run, árvore só do versionado, scratch apagado) · 2ª noite (novas/corrigidas) · sem falhas e depois
#   falha contra baseline vazio · xfailed/xpassed/error contados à parte · INERTE (inerte e nao-isolado: nada divulgado, baseline intacta) · rc 97 sem linha de
#   isolamento é FALHOU · PULADO (rc 99, sem e-mail) · prazo (124) · pytest abortado · terminou SEM prova de isolamento · sem resumo · total implausível ·
#   lock vivo (PULADO) e lock de dono morto (toma) · baseline ilegível (nunca "0 novas") · e-mail que falha · contador do nft (0 / N / ilegível) · ssh que falha ·
#   origin/main ilegível · relatório velho do mesmo dia nunca vira o e-mail de hoje · resumo com falhas mas sem ids FAILED (comparação indisponível, baseline intacta) ·
#   duração ilegível sai "?" (não 0h0min) · ids com " - " ficam distintos (irmãos de parametrize) · lista parcial / sem a linha GTN-FAILED / contagem que não bate / linha que não é JSON =
#   comparação INDISPONÍVEL com a baseline intacta · fetch que falha aparece no relatório · lock velho com pid reaproveitado é tomado · PULADO por lock deixa linha no jsonl ·
#   a limpeza de 14 dias não apaga a baseline · nao-isolado (vazamento medido) é FALHOU, não INERTE · o nó do mbp-run é o mesmo do instalador · o que foi ao nó fica no relatório.
# CONTROLES NEGATIVOS: cada mutante do script (M1-M31, mais M0 neutro) tem de ser REPROVADO pelo caso correspondente (o caso falha quando roda no mutante). Antes deles, um mutante NEUTRO (cópia que só muda
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
git init -q -b main "$T/wa" && ( cd "$T/wa" && echo hi > marker.txt && git add marker.txt && git -c user.name=t -c user.email=t@t commit -qm m && git update-ref refs/remotes/origin/main HEAD && echo wip > untracked.txt )
cat > "$T/run-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$STUB_CALLS"; echo "ENV: ISOLATE=${HETZNER_ISOLATE:-} TIMEOUT=${MBP_RUN_TIMEOUT_S:-} NODE=${HETZNER_NODE_HOST:-}" >> "$STUB_CALLS"
d=""; while [ $# -gt 0 ]; do [ "$1" = --dir ] && d=$2; shift; done
[ -n "$(find "$LOCK_PATH" -maxdepth 0 -mmin +5 2>/dev/null)" ] && echo "lock-velho-durante-a-rodada" >> "$STUB_CALLS"
[ -f "$d/marker.txt" ] && echo "tree-ok" >> "$STUB_CALLS"; [ -e "$d/untracked.txt" ] && echo "untracked-leaked" >> "$STUB_CALLS"
echo "$d" > "$STUB_DIR_SEEN"; cat "$STUB_OUT" 2>/dev/null; exit "${STUB_RC:-0}"
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
cp "$HERE/hetzner-iso-run.sh" "$HERE/gtn_stable_ids.py" "$T/"   # o script lê os dois do diretório DELE ($HERE): o mutante, que mora em $T, precisa deles ao lado
export MBP_CITY="$C" HZN_RUN="$T/run-stub.sh" HZN_WA_REPO="$T/wa" HZN_MAIL_CMD="$T/mail-stub.sh" HZN_SSH="$T/ssh-stub.sh" HZN_NODE_HOST=stub-node HZN_NO_FETCH=1
export LOCK_PATH="$LOCK" MAIL_LOG STUB_CALLS="$CALLS" STUB_OUT STUB_DIR_SEEN="$T/dirseen" SSH_LOG="$T/ssh.log"
n=0; fails=0; BAD=0; QUIET=0
reset() { find "$LOGDIR" -mindepth 1 -delete 2>/dev/null; : > "$JSONL"; : > "$MAIL_LOG"; : > "$CALLS"; : > "$SSH_LOG"; rm -f "$STUB_OUT"; chmod -R u+rwx "$LOCK" 2>/dev/null
          find "$LOCK" -mindepth 1 -delete 2>/dev/null; rmdir "$LOCK" 2>/dev/null; mkdir -p "$LOGDIR"; unset STUB_RC MAIL_RC SSH_RC HZN_MIN_TOTAL; export HZN_WA_REPO="$T/wa"; }
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
  { [ -z "$iso" ] || echo "GTN-ISO: $iso"; echo "collected ..."; for l in "$@"; do echo "$l"; done; [ -z "$sum" ] || echo "$sum"; [ -z "$eg" ] || echo "GTN-EGRESS: attempts=$eg"; } > "$STUB_OUT"; }
ISO_OK="isolado (sonda barrou 5 tentativas)"; SUM1="3 failed, 1200 passed, 2 skipped in 4000.12s (1:06:40)"
seed_prev() { local i; for i in "$@"; do jq -cn --arg i "$i" '$i'; done | LC_ALL=C sort -u > "$PREV"; echo "2026-01-01 @abc" > "$LOGDIR/last-complete.meta"; }
# o que o plugin imprime: fl <reports> <id>... → uma linha GTN-FAIL por id (JSON ASCII) e a linha GTN-FAILED (n = nº de ids, reports = falhas+erros que o pytest contou)
fl() { local r=$1 i; shift; for i in "$@"; do printf 'GTN-FAIL: %s\n' "$(jq -cn --arg i "$i" '$i')"; done; printf 'GTN-FAILED: n=%s reports=%s' "${FL_N:-$#}" "$r"; }   # FL_N: o n que o plugin AFIRMA (diferente do nº de linhas = lista parcial)
decoded() { jq -r . "$1"; }

case_first() { reset; mkout "$ISO_OK" 7 "$SUM1" "FAILED tests/a.py::t1 - AssertionError: x" "FAILED tests/c.py::t3 - y" "ERROR tests/b.py::t2 - ValueError" "$(fl 3 tests/a.py::t1 tests/b.py::t2 tests/c.py::t3)"; STUB_RC=1 go "$1"
  ck "1ª noite: exit 0 e veredito COMPLETO" rcis 0; ck "1ª noite: COMPLETO na última linha e no jsonl" vd COMPLETO; ck "1ª noite: 1 e-mail" mailn 1
  ck "1ª noite: assunto diz primeira rodada" has "$MAIL_LOG" 'COMPLETO: 1205 testes, 3 falhas, 0 erros \(primeira rodada\)'
  ck "1ª noite: relatório com a linha de base" has "$REPORT" 'primeira rodada completa.*as 3 falhas de hoje viram a linha de base'
  ck "1ª noite: totais" has "$REPORT" 'total: 1205 \(1200 passaram, 3 falharam, 0 erros, 2 pulados'; ck "1ª noite: duração e meta de 2 h" has "$REPORT" 'pytest 1h6min.*meta de 2 h: ATINGIDA'
  ck "1ª noite: contador do nft no relatório" has "$REPORT" '7 tentativa\(s\) de saída barradas pelo nft'
  ck "1ª noite: mbp-run com o isolamento ligado, o prazo e o MESMO nó do instalador" has "$CALLS" 'ENV: ISOLATE=1 TIMEOUT=7200 NODE=stub-node'
  ck "1ª noite: mbp-run no nó linux, pytest -n 14 com o plugin" has "$CALLS" 'ARGS: --host linux --repo wa --dir .*-- tests/ -n 14 -p gtn_stable_ids'
  ck "1ª noite: árvore do origin/main chegou" has "$CALLS" '^tree-ok$'; ck "1ª noite: untracked NÃO chegou" hasnt "$CALLS" 'untracked-leaked'
  ck "1ª noite: scratch apagado" empty_dir "$C/.gc/run"; ck "1ª noite: baseline gravada (ids em JSON)" has "$PREV" '^"tests/b.py::t2"$'; ck "1ª noite: o wrapper e o plugin foram ao nó" has "$T/ssh.log" 'gtn_stable_ids.py'; }
case_second() { reset; seed_prev tests/a.py::t1 tests/old.py::gone; mkout "$ISO_OK" 0 "1 failed, 1 error, 1200 passed, 2 skipped in 4000.12s (1:06:40)" "FAILED tests/a.py::t1 - x" "ERROR tests/b.py::t2" "$(fl 2 tests/a.py::t1 tests/b.py::t2)"; STUB_RC=1 go "$1"
  ck "2ª noite: COMPLETO" vd COMPLETO; ck "2ª noite: 1 nova e 1 corrigida" has "$REPORT" '2026-01-01 @abc\): 1 falhas NOVAS, 1 corrigidas'; ck "2ª noite: a nova está na lista (decodificada, não em JSON)" has "$REPORT" '^  - tests/b.py::t2$'
  ck "2ª noite: a antiga não é listada como nova" hasnt "$REPORT" '^  - tests/a.py::t1$'; ck "2ª noite: assunto com (1 novas)" has "$MAIL_LOG" '\(1 novas\)'
  ck "2ª noite: baseline avançou" has "$PREV" '^"tests/b.py::t2"$'; ck "2ª noite: a corrigida saiu da baseline" hasnt "$PREV" 'old.py'; ck "2ª noite: 0 tentativas dito como lido" has "$REPORT" '0 tentativas de saída \(contador do nft lido\)'; }
case_cleanslate() { reset; seed_prev tests/a.py::t1 tests/old.py::gone; mkout "$ISO_OK" 1 "1500 passed in 3000.00s (0:50:00)" "$(fl 0)"; STUB_RC=0 go "$1"
  ck "sem falhas: COMPLETO, 0 novas e 2 corrigidas" has "$REPORT" '0 falhas NOVAS, 2 corrigidas'; ck "sem falhas: baseline vazia" empty_dir_file "$PREV"
  mkout "$ISO_OK" 1 "1 failed, 1499 passed in 3000.00s (0:50:00)" "FAILED tests/c.py::t3" "$(fl 1 tests/c.py::t3)"; STUB_RC=1 go "$1"
  ck "baseline vazia existe: toda falha é nova" has "$REPORT" '1 falhas NOVAS, 0 corrigidas'; }
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
  ck "prazo: exit 1 e FALHOU" rcis 1; ck "prazo: veredito" vd FALHOU; ck "prazo: diz que estourou" has "$MAIL_LOG" 'estourou o prazo de 7200s'; ck "prazo: baseline intacta" cmp -s "$PREV" "$T/prev.before"; }
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
case_egress() { reset; mkout "$ISO_OK" "?" "1500 passed in 3000.00s"; STUB_RC=0 go "$1"; ck "contador '?': não afirma zero" has "$REPORT" 'ILEGÍVEL — não afirmo zero'
  reset; mkout "$ISO_OK" "" "1500 passed in 3000.00s"; STUB_RC=0 go "$1"; ck "sem linha do contador: ILEGÍVEL" has "$REPORT" 'ILEGÍVEL'; ck "sem linha do contador: jsonl guarda ?" test "$(tail -n 1 "$JSONL" | jq -r .egress_attempts)" = "?"
  reset; mkout "$ISO_OK" 0 "1500 passed in 3000.00s"; STUB_RC=0 go "$1"; ck "contador 0: dito como lido" has "$REPORT" '0 tentativas de saída \(contador do nft lido\)'; }
case_ssh() { reset; mkout "$ISO_OK" 1 "1500 passed in 3000.00s"; SSH_RC=255 go "$1"; ck "ssh falha: FALHOU, exit 1" rcis 1; ck "ssh falha: diz o que não instalou" has "$MAIL_LOG" 'não consegui instalar gt-iso-run em stub-node'; ck "ssh falha: o mbp-run não rodou" empty_dir_file "$CALLS"; }
case_no_origin() { reset; HZN_WA_REPO="$T/nowhere" go "$1"; ck "origin/main ilegível: FALHOU" has "$MAIL_LOG" 'origin/main do WA ilegível'; ck "origin/main ilegível: nada rodou" empty_dir_file "$CALLS"; }
case_stale_report() { reset; echo "RELATORIO-VELHO" > "$REPORT"; SSH_RC=1 go "$1"; ck "relatório velho do mesmo dia: não vira o e-mail de hoje" hasnt "$MAIL_LOG" 'RELATORIO-VELHO'; ck "relatório velho: o de hoje é FALHOU" has "$REPORT" 'FALHOU'; }
case_listfail() { reset; seed_prev tests/a.py::t1; cp "$PREV" "$T/prev.before"; echo "2026-01-01 @abc" > "$LOGDIR/last-complete.meta"
  # o resumo diz 3 falhas e o plugin não imprimiu nada (não rodou, ou falhou ao montar a lista)
  mkout "$ISO_OK" 1 "3 failed, 1500 passed in 3000.00s" "FAILED tests/a.py::t1 - x"; STUB_RC=1 go "$1"
  ck "sem a linha GTN-FAILED: segue COMPLETO" vd COMPLETO; ck "sem a linha GTN-FAILED: relatório diz INDISPONÍVEL e por quê" has "$REPORT" 'comparação INDISPONÍVEL: o pytest não imprimiu a linha GTN-FAILED'
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
    case $why in 1) STUB_RC=1 go "$1"; ck "lista parcial: INDISPONÍVEL e diz que é parcial" has "$REPORT" 'comparação INDISPONÍVEL: o plugin diz 3 ids e 2 foram lidos \(lista parcial\)' ;;
      2) STUB_RC=1 go "$1"; ck "contagem do plugin x resumo: INDISPONÍVEL e diz os dois números" has "$REPORT" 'comparação INDISPONÍVEL: o plugin contou 3 falhas/erros e o resumo do pytest diz 4' ;;
      3) STUB_RC=1 go "$1"; ck "duas linhas GTN-FAILED: INDISPONÍVEL" has "$REPORT" 'comparação INDISPONÍVEL: a linha GTN-FAILED aparece 2 vezes' ;;
      4) STUB_RC=1 go "$1"; ck "linha GTN-FAIL que não é JSON: INDISPONÍVEL" has "$REPORT" 'comparação INDISPONÍVEL: há linha GTN-FAIL que não é um id em JSON' ;;
      5) STUB_RC=1 go "$1"; ck "linha GTN-FAILED ilegível: INDISPONÍVEL" has "$REPORT" 'comparação INDISPONÍVEL: a linha GTN-FAILED está ilegível' ;; esac
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
case_dur() { reset; mkout "$ISO_OK" 1 "1500 passed in 7s"; STUB_RC=0 go "$1"; ck "duração ilegível: o relatório diz ?" has "$REPORT" 'duração: pytest \? \(\? s\)'; ck "duração ilegível: nunca 0h0min" hasnt "$REPORT" '0h0min'; }

ALL="first second cleanslate xfail inerte leak 97_sem_iso pulado timeout abort noiso nosum implausible lock lock_stale prev_unreadable mailfail egress ssh no_origin stale_report listfail prev_format dash partial fetch keep provenance dur"
for c in $ALL; do "case_$c" "$SUT0"; done

# ---- controles negativos: o caso correspondente tem de FALHAR quando roda no mutante -----------------------------------------
M=0
# o controle do controle: uma cópia NEUTRA (só um comentário a mais) tem de PASSAR todos os casos. Se reprovasse, todo mutante abaixo "morreria" por qualquer motivo e a prova seria vazia
# (foi assim até o gate 1: o mutante morava em $T sem os arquivos irmãos que o script lê de $HERE, e reprovava todo caso, qualquer que fosse a mutação).
f="$T/m-neutro.sh"; { cat "$SUT0"; echo "# neutro"; } > "$f"; chmod +x "$f"; n=$((n+1)); BAD=0; QUIET=1; for c in $ALL; do "case_$c" "$f"; done; QUIET=0
if [ "$BAD" = 0 ]; then echo "ok   M0-neutro (a cópia neutra passa TODOS os casos: os mutantes abaixo reprovam por causa da mutação)"; else echo "FAIL M0-neutro: a cópia NEUTRA reprovou algum caso (o controle negativo seria vazio)"; fails=$((fails+1)); fi
mutant() { # nome expr-sed caso — cria o mutante, roda o caso em silêncio e exige que ele reprove
  local f="$T/m-$1.sh"; sed "$2" "$SUT0" > "$f"; chmod +x "$f"; n=$((n+1)); M=$((M+1))
  if cmp -s "$SUT0" "$f"; then echo "FAIL $1: o sed não casou (mutante igual ao original)"; fails=$((fails+1)); return; fi
  bash -n "$f" 2>/dev/null || { echo "FAIL $1: o mutante tem erro de sintaxe (a prova seria vazia)"; fails=$((fails+1)); return; }
  BAD=0; QUIET=1; "case_$3" "$f"; QUIET=0
  if [ "$BAD" = 1 ]; then echo "ok   $1 (o caso '$3' reprova o mutante)"; else echo "FAIL $1: o caso '$3' NÃO reprovou o mutante"; fails=$((fails+1)); fi; }
mutant M1-sem-prova-de-isolamento 's/^case "\$ISO_LINE" in isolado\*) ;; \*) finish FALHOU.*$/true/' noiso
mutant M2-prazo-124-ignorado 's/^  124) finish FALHOU.*$/  124) ;;/' timeout
mutant M3-inerte-vira-falhou 's/^      inerte\*) /      nunca_casa) /' inerte
mutant M4-novas-lidas-como-comuns 's/comm -13 /comm -12 /' second
mutant M5-pulado-manda-email 's/if \[ "\$v" != PULADO \]; then/if true; then/' pulado
mutant M6-sem-comparacao-vira-0-novas 's/NEWTXT="sem comparação"/NEWTXT="0 novas"/' prev_unreadable
mutant M7-total-implausivel-aceito 's/^\[ "\$TOTAL" -ge "\$MIN_TOTAL" \] || finish.*$/true/' implausible
mutant M8-falha-de-email-ignorada 's/|| { MAILRC=1; .*$/|| true/' mailfail
mutant M9-relatorio-velho-nao-truncado 's/^: > "\$REPORT".*$/true/' stale_report
mutant M10-error-singular-nao-contado "s/cnt 'errors?'/cnt 'errors'/" xfail
mutant M11-lock-vivo-ignorado 's/if \[ -n "\$op" \] && \[ -z "\$old" \] && kill -0 "\$op" 2>\/dev\/null; then/if false; then/' lock
mutant M12-ssh-ignorado 's/if ! \$SSH /if false \&\& ! $SSH /' ssh
mutant M13-contador-ilegivel-vira-0 's/\[ -n "\$EGRESS" \] || EGRESS="?"/EGRESS=${EGRESS:-0}/' egress
mutant M14-pytest-abortado-segue 's/^  \*) finish FALHOU "o pytest abortou.*$/  *) ;;/' abort
mutant M16-duracao-ilegivel-vira-0h0min 's/^DUR="?"; \[ -z "\$PYSECS" \] || /true; /' dur
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
mutantl M15-lista-parcial-vira-completa partial 'elif [ "$NIDS" -ne "$SN" ]; then' 'elif false; then'
mutantl M17-contagem-do-plugin-x-resumo-ignorada partial 'elif [ "$SR" -ne $(( FAILED + ERRORS )) ]; then' 'elif false; then'
mutantl M18-sem-linha-do-plugin-e-sem-falhas-vira-zero listfail 'if [ "$NSENT" -eq 0 ]; then LISTWHY=' 'if [ "$NSENT" -eq 0 ] && [ $(( FAILED + ERRORS )) -eq 0 ]; then LISTOK=1
elif [ "$NSENT" -eq 0 ]; then LISTWHY='
mutantl M19-id-lido-da-linha-humana-cortada-no-1o-traco dash "LC_ALL=C sed -n 's/^GTN-FAIL: //p' \"\$OUT\" 2>/dev/null |" "LC_ALL=C sed -n -E 's/^(FAILED|ERROR) (.*)\$/\\2/p' \"\$OUT\" 2>/dev/null | sed -E 's/ - .*\$//; s/^(.*)\$/\"\\1\"/' |"
mutantl M20-o-bug-original-sem-a-conferencia-de-n dash "LC_ALL=C sed -n 's/^GTN-FAIL: //p' \"\$OUT\" 2>/dev/null |" "LC_ALL=C sed -n -E 's/^(FAILED|ERROR) (.*)\$/\\2/p' \"\$OUT\" 2>/dev/null | sed -E 's/ - .*\$//; s/^(.*)\$/\"\\1\"/' |" 'elif [ "$NIDS" -ne "$SN" ]; then' 'elif false; then'
mutantl M21-json-nao-validado partial 'elif ! jq -en '"'"'[inputs | type == "string"] | all'"'"' "$CUR" >/dev/null 2>&1; then' 'elif false; then'
mutantl M22-sentinela-duplicada-aceita partial 'elif [ "$NSENT" -gt 1 ]; then LISTWHY=' 'elif false; then LISTWHY='
mutantl M23-baseline-de-outro-formato-aceita prev_format "jq -en '[inputs | type == \"string\"] | all' \"\$PREV\" >/dev/null 2>&1 && " ''
reset
echo "---"; echo "$((n-fails))/$n ok ($M mutantes)"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
