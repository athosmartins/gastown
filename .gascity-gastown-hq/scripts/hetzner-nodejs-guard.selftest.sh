#!/usr/bin/env bash
# hetzner-nodejs-guard.selftest.sh — hermético: o `hetzner-nodejs.sh check` é um stub que registra a chamada e sai com o rc escolhido; a lista mac-only é um arquivo temporário. (ga-2hd02v.4.11)
#
# Contents
#   Casos · Mutantes
#
# CASOS (com um repositório do PS de mentira, para a DERIVAÇÃO; ga-2hd02v.4.14): os testes na lista = não se aplica (rc 0) e o check NÃO é chamado · fora da lista + check rc 0 = ok · fora da lista + check rc 1 = FALHA rc 1 que diz como consertar · fora da lista + check rc 2, 3,
#   124 (prazo), 127 (script ausente) ou qualquer outro = NÃO SEI rc 2, nunca verde · UM só dos 5 fora da lista basta para exigir o Node · lista ilegível, ausente ou sem nenhum glob = rc 2 sem chamar o check
#   · a lista cobre por GLOB (`tests/test_blow_*.py`), como o classificador, então não exige o Node · caminho parecido mas diferente na lista (`...py.bak`) NÃO cobre · linha com espaço no fim ainda cobre.
#   NOVOS (.4.14): arquivo que chama o node e NÃO está no retrato, fora da lista e sem Node = FALHA que o NOMEIA (prova que o conjunto é derivado) · repositório do PS ilegível ou ref inexistente = só o retrato:
#   todos cobertos = rc 2 (não afirmo que nada novo precisa do node), fora da lista + Node ok = rc 0, + sem Node = rc 1 (sempre com a nota "conjunto = retrato") · derivação que não acha NENHUM teste = rc 2 ·
#   globs indentados (o classificador faz strip dos dois lados) cobrem · sem subcomando, uso do guarda não muda.
#   ga-u6ueg0q: a última linha da lista SEM quebra de linha no fim (editor que não grava o \n) ainda conta como glob.
#   ga-iu0fvlo: SEM argumentos, a lista mac-only e o script do check vêm de AO LADO do guarda (HERE, derivado do $0 e não do cwd): copia o guarda para uma pasta com os dois e roda de OUTRO diretório.
# MUTANTES: cada um troca UM trecho do guarda por uma versão frouxa (python3, substring exata e única); o caso apontado tem de FALHAR.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
G="$HERE/hetzner-nodejs-guard.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/hnjg-selftest.XXXXXX") || exit 2; T=$(cd "$T" && pwd -P)
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1 ($3)" || bad "$1: esperado '$2', veio '$3'"; }
has() { grep -q -E -e "$3" "$2" 2>/dev/null && ok "$1" || bad "$1: '$3' ausente em $2"; }
hasnt() { grep -q -E -e "$3" "$2" 2>/dev/null && bad "$1: '$3' presente em $2" || ok "$1"; }

LIST="$T/mac-only.txt"; CHK="$T/check.sh"; CALLS="$T/calls.log"
FILES6='tests/test_blow_cycle.py tests/test_blow_rate_limit.py tests/test_blow_budget.py tests/test_blow_property_ids.py tests/test_blow_scraper_ids_wiring.py tests/test_scraper_status_blow_probe.py'
PSFIX="$T/ps"
printf '#!/usr/bin/env bash\necho "chamado: $*" >> "%s"\necho "NODEJS stub"\nexit "${STUB_CHECK_RC:-0}"\n' "$CALLS" > "$CHK"
mklist() { { printf '# lista de teste\ntests/test_rodada_state.py\n'; for f in "$@"; do printf '%s\n' "$f"; done; } > "$LIST"; }
# repositório do PS de mentira (branch main) com os 6 testes que chamam which("node") e uma isca que não chama; argumentos = arquivos extras que chamam o node
mkps() {
  find "$PSFIX" -mindepth 1 -delete 2>/dev/null; mkdir -p "$PSFIX/tests" "$PSFIX/lib/tests"
  local f; for f in $FILES6 "$@"; do mkdir -p "$PSFIX/$(dirname "$f")"; printf 'import shutil\nNODE = shutil.which("node")\n' > "$PSFIX/$f"; done
  printf 'def test_isca():\n    assert True\n' > "$PSFIX/tests/test_sem_node.py"
  git -C "$PSFIX" init -q && git -C "$PSFIX" symbolic-ref HEAD refs/heads/main && git -C "$PSFIX" add -A && git -C "$PSFIX" -c user.name=t -c user.email=t@t commit -q -m fixture || { echo "FAIL: não montei o repositório do PS de mentira"; exit 2; }
}
# repositório do PS que NÃO tem nenhum teste chamando o node (só a isca)
mkps_vazio() { find "$PSFIX" -mindepth 1 -delete 2>/dev/null; mkdir -p "$PSFIX/tests"; printf 'def test_isca():\n    assert True\n' > "$PSFIX/tests/test_sem_node.py"; git -C "$PSFIX" init -q && git -C "$PSFIX" symbolic-ref HEAD refs/heads/main && git -C "$PSFIX" add -A && git -C "$PSFIX" -c user.name=t -c user.email=t@t commit -q -m fixture; }
reset() { : > "$CALLS"; unset STUB_CHECK_RC PS_GIT_DIR PS_REF; mklist; mkps; }
run() { ( cd "$T" && PS_GIT_DIR="${PS_GIT_DIR:-$PSFIX/.git}" PS_REF="${PS_REF:-main}" bash "${SCRIPT:-$G}" "${1:-$LIST}" "${2:-$CHK}" > "$T/out" 2>&1 ); echo $?; }
called() { [ -s "$CALLS" ] && echo sim || echo nao; }

c_todos_na_lista() { reset; mklist $FILES6; local rc; rc=$(run); eq "os 6 na lista (conjunto derivado): rc 0 (não se aplica)" 0 "$rc"; has "…diz que o Node não é exigido" "$T/out" 'derivados do repositório.*não é exigido'; eq "…e o check NÃO é chamado" nao "$(called)"; }
c_fora_check_ok() { reset; STUB_CHECK_RC=0; export STUB_CHECK_RC; local rc; rc=$(run); eq "todos fora da lista + check rc 0: rc 0" 0 "$rc"; has "…diz ok" "$T/out" 'ok: 6 teste\(s\) fora da lista'; eq "…o check foi chamado" sim "$(called)"; has "…como 'check'" "$CALLS" 'chamado: check'; }
c_fora_check_falha() { reset; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "todos fora da lista + check rc 1 (sem Node): rc 1" 1 "$rc"; has "…FALHA" "$T/out" 'FALHA'; has "…diz como consertar (install ou recolocar na lista)" "$T/out" 'hetzner-nodejs.sh install.*recoloque ESTES'; has "…e NOMEIA o teste que precisa do node, incluindo o sexto" "$T/out" 'tests/test_blow_cycle.py'; }
c_fora_check_nao_sei() { reset; local rc code; for code in 2 3 124 127 9; do STUB_CHECK_RC=$code; export STUB_CHECK_RC; rc=$(run); eq "check rc $code: rc 2 (NÃO SEI, nunca verde)" 2 "$rc"; done; has "…NAO-SEI" "$T/out" 'NAO-SEI'; hasnt "…não diz ok" "$T/out" '^NODEJS-GUARD ok'; }
c_um_so_fora() { reset; mklist tests/test_blow_cycle.py tests/test_blow_rate_limit.py tests/test_blow_budget.py tests/test_blow_property_ids.py tests/test_blow_scraper_ids_wiring.py; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "só 1 dos 6 fora da lista + sem Node: rc 1" 1 "$rc"; has "…conta 1 teste" "$T/out" 'FALHA: 1 teste'; }
c_script_ausente() { reset; local rc; rc=$(run "$LIST" "$T/nao-existe.sh"); eq "script do check ausente: rc 2 (127 do bash, NÃO SEI)" 2 "$rc"; }
c_lista_ausente() { reset; local rc; rc=$(run "$T/nao-existe.txt"); eq "lista ausente: rc 2" 2 "$rc"; eq "…sem chamar o check" nao "$(called)"; has "…NAO-SEI" "$T/out" 'NAO-SEI'; has "…e o diagnóstico é 'ilegível ou ausente' (não 'sem glob')" "$T/out" 'ilegível ou ausente'; hasnt "…sem confundir com lista vazia" "$T/out" 'nenhum glob'; }
c_lista_sem_glob() { reset; printf '# só comentário\n\n# outro\n' > "$LIST"; local rc; rc=$(run); eq "lista sem nenhum glob: rc 2 (não 'todos fora')" 2 "$rc"; eq "…sem chamar o check" nao "$(called)"; has "…diz que não sabe o que ela cobre" "$T/out" 'nenhum glob'; }
c_cobre_por_glob() { reset; mklist 'tests/test_blow_*.py' tests/test_scraper_status_blow_probe.py; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "a lista cobre por glob (tests/test_blow_*.py): rc 0 mesmo com o check em rc 1" 0 "$rc"; eq "…e o check não é chamado" nao "$(called)"; }
c_parecido_nao_cobre() { reset; mklist tests/test_blow_rate_limit.py.bak tests/test_blow_budget.py.bak tests/test_blow_property_ids.pyc tests/test_blow_scraper_ids_wiring.py.old tests/test_scraper_status_blow_probe.py.orig; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "caminhos parecidos (.bak/.pyc/.old/.orig) NÃO cobrem: rc 1" 1 "$rc"; }
c_espaco_no_fim() { reset; { printf '# lista\n'; for f in $FILES6; do printf '%s   \n' "$f"; done; } > "$LIST"; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "linha com espaços no fim ainda cobre: rc 0" 0 "$rc"; }
c_deriva_arquivo_novo() { reset; mkps tests/test_new_needs_node.py; mklist $FILES6; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "arquivo NOVO que chama o node (fora do retrato), fora da lista, sem Node: rc 1" 1 "$rc"; has "…e o aviso NOMEIA o arquivo novo" "$T/out" 'tests/test_new_needs_node.py'; hasnt "…sem a nota de retrato (o conjunto foi derivado)" "$T/out" 'conjunto = retrato'; }
c_retrato_cobertos() { reset; PS_GIT_DIR="$T/nao-existe"; export PS_GIT_DIR; mklist $FILES6; local rc; rc=$(run); eq "todos cobertos mas o PS está ilegível (só o retrato): rc 2" 2 "$rc"; has "…diz que é o retrato e que não leu o PS" "$T/out" 'retrato.*não consegui ler o repositório do PS'; eq "…sem chamar o check" nao "$(called)"; }
c_retrato_fora_ok() { reset; PS_GIT_DIR="$T/nao-existe"; STUB_CHECK_RC=0; export PS_GIT_DIR STUB_CHECK_RC; local rc; rc=$(run); eq "PS ilegível, fora da lista, o nó TEM o Node: rc 0 (com o Node tudo passa)" 0 "$rc"; has "…e diz que o conjunto é o retrato" "$T/out" 'conjunto = retrato'; }
c_retrato_fora_falha() { reset; PS_GIT_DIR="$T/nao-existe"; STUB_CHECK_RC=1; export PS_GIT_DIR STUB_CHECK_RC; local rc; rc=$(run); eq "PS ilegível, fora da lista, sem Node: rc 1" 1 "$rc"; has "…com a nota de retrato" "$T/out" 'conjunto = retrato'; has "…e o retrato inclui o sexto arquivo" "$T/out" 'tests/test_blow_cycle.py'; }
c_ref_inexistente() { reset; PS_REF=nao-existe; export PS_REF; mklist $FILES6; local rc; rc=$(run); eq "ref inexistente: cai no retrato, e com tudo coberto é rc 2" 2 "$rc"; has "…diz que não leu o PS" "$T/out" 'não consegui ler o repositório do PS'; }
c_deriva_vazia() { reset; mkps_vazio; mklist $FILES6; local rc; rc=$(run); eq "derivação que não acha NENHUM teste: rc 2 (não 'não se aplica')" 2 "$rc"; has "…diz que contradiz o retrato" "$T/out" 'NENHUM teste.*contradiz o retrato'; eq "…sem chamar o check" nao "$(called)"; }
c_glob_indentado() { reset; printf '# lista\n   tests/test_blow_*.py\n\t tests/test_scraper_status_blow_probe.py  \n' > "$LIST"; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "globs indentados (o classificador faz strip dos dois lados) cobrem: rc 0" 0 "$rc"; eq "…e o check não é chamado" nao "$(called)"; }
# a lista termina no meio de uma linha (sem \n): o `read` devolve rc 1 com o glob lido, e esse glob tem de valer — senão o último arquivo da lista volta a exigir o Node
c_sem_quebra_final() { reset; printf '# lista\ntests/test_blow_*.py\ntests/test_scraper_status_blow_probe.py' > "$LIST"; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "última linha da lista sem quebra de linha ainda cobre: rc 0" 0 "$rc"; eq "…e o check não é chamado" nao "$(called)"; }
# sem argumentos o guarda lê a lista e chama o check de AO LADO de si mesmo: HERE sai do $0 (não do cwd). Se HERE ficasse vazio, a lista viraria /hetzner-mac-only.ps.txt (ausente) e o check /hetzner-nodejs.sh (ausente)
c_defaults_ao_lado() {
  reset; local L="$T/lado" rc; rm -rf "$L"; mkdir -p "$L"; cp "${SCRIPT:-$G}" "$L/hetzner-nodejs-guard.sh"; cp "$CHK" "$L/hetzner-nodejs.sh"
  mklist $FILES6; cp "$LIST" "$L/hetzner-mac-only.ps.txt"
  rc=$( ( cd "$T" && PS_GIT_DIR="$PSFIX/.git" PS_REF=main bash "$L/hetzner-nodejs-guard.sh" > "$T/out" 2>&1 ); echo $? )
  eq "sem argumentos, a lista ao lado cobre os 6: rc 0 (lido de HERE, rodando de outro cwd)" 0 "$rc"; has "…e é a lista ao lado que decide" "$T/out" 'derivados do repositório.*não é exigido'; eq "…sem chamar o check" nao "$(called)"
  mklist; cp "$LIST" "$L/hetzner-mac-only.ps.txt"; : > "$CALLS"
  rc=$( ( cd "$T" && STUB_CHECK_RC=1 PS_GIT_DIR="$PSFIX/.git" PS_REF=main bash "$L/hetzner-nodejs-guard.sh" > "$T/out" 2>&1 ); echo $? )
  eq "sem argumentos, lista ao lado sem os 6 e o check ao lado em rc 1: rc 1" 1 "$rc"; eq "…o check AO LADO foi chamado" sim "$(called)"
}
CASES="c_todos_na_lista c_fora_check_ok c_fora_check_falha c_fora_check_nao_sei c_um_so_fora c_script_ausente c_lista_ausente c_lista_sem_glob c_cobre_por_glob c_parecido_nao_cobre c_espaco_no_fim c_deriva_arquivo_novo c_retrato_cobertos c_retrato_fora_ok c_retrato_fora_falha c_ref_inexistente c_deriva_vazia c_glob_indentado c_sem_quebra_final c_defaults_ao_lado"
for c in $CASES; do echo "== $c"; $c; done

mutant() {   # nome · trecho original · trecho frouxo · caso que tem de pegar
  local name=$1 old=$2 new=$3 case_fn=$4 res
  if ! python3 - "$G" "$old" "$new" > "$T/mut.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if src.count(sys.argv[2]) != 1:
    sys.exit(3)
sys.stdout.write(src.replace(sys.argv[2], sys.argv[3]))
PY
  then bad "mutante $name: o trecho original não aparece exatamente uma vez no guarda (o guarda mudou?)"; return; fi
  res=$( ( SCRIPT="$T/mut.sh"; $case_fn ) 2>&1 )
  if printf '%s\n' "$res" | grep -q '^FAIL'; then ok "mutante $name morto por $case_fn"; else bad "mutante $name SOBREVIVEU a $case_fn"; fi
}
echo "== mutantes"
mutant deriva-ignorada        '0) while IFS= read -r f; do [ -n "$f" ] && FILES+=("${f#"$PS_REF":}"); done <<EOF_D' '0) FILES=("${NODE_FILES[@]}"); while IFS= read -r f; do [ -n "$f" ] && :; done <<EOF_D' c_deriva_arquivo_novo
mutant retrato-coberto-vira-ok 'não afirmo que nenhum teste novo precise do node"; exit 2' 'não afirmo que nenhum teste novo precise do node"; exit 0' c_retrato_cobertos
mutant deriva-vazia-vira-ok   'não afirmo que nada precisa do node"; exit 2 ;;' 'não afirmo que nada precisa do node"; exit 0 ;;' c_deriva_vazia
mutant strip-so-do-fim        'g="${g#"${g%%[![:space:]]*}"}"; ' '' c_glob_indentado
mutant retrato-sem-nota       '[ "$SRC" = retrato ] && NOTE=" [conjunto = retrato; repositório do PS ilegível, deriva não conferida]" || NOTE=""' 'NOTE=""' c_retrato_fora_ok
mutant falha-cai-no-nao-sei   '  1) say "FALHA:' '  5) say "FALHA:' c_fora_check_falha
mutant falha-sai-0            '; exit 1 ;;' '; exit 0 ;;' c_fora_check_falha
mutant nao-sei-vira-ok        'rc $rc: $out)$NOTE"; exit 2 ;;' 'rc $rc: $out)$NOTE"; exit 0 ;;' c_fora_check_nao_sei
mutant lista-ilegivel-segue   '[ -r "$LIST" ] || { say "NAO-SEI: lista ilegível ou ausente ($LIST)"; exit 2; }' ':' c_lista_ausente
mutant lista-sem-glob-segue   'grep -qE '"'"'^[[:space:]]*[^#[:space:]]'"'"' "$LIST" 2>/dev/null || {' 'true || {' c_lista_sem_glob
mutant pre-checagem-estrita   'grep -qE '"'"'^[[:space:]]*[^#[:space:]]'"'"' "$LIST" 2>/dev/null || {' 'grep -qE '"'"'^[^#[:space:]]'"'"' "$LIST" 2>/dev/null || {' c_glob_indentado
mutant sempre-exige-node      'if [ "${#OUT[@]}" -eq 0 ]; then' 'if false; then' c_todos_na_lista
mutant igualdade-no-lugar-do-glob 'case "$1" in $g) return 0 ;; esac' '[ "$1" = "$g" ] && return 0' c_cobre_por_glob
mutant glob-casa-tudo         'case "$1" in $g) return 0 ;; esac' 'case "$1" in *) return 0 ;; esac' c_parecido_nao_cobre
mutant espaco-no-fim-fica     'g="${g%"${g##*[![:space:]]}"}"; ' '' c_espaco_no_fim
mutant um-fora-nao-basta      'if [ "${#OUT[@]}" -eq 0 ]; then' 'if [ "${#OUT[@]}" -le 1 ]; then' c_um_so_fora
mutant ultima-linha-perdida   'while IFS= read -r g || [ -n "$g" ]; do' 'while IFS= read -r g && [ -n "$g" ]; do' c_sem_quebra_final
mutant here-vazio-sem-pwd    'HERE=$(cd "$(dirname "$0")" && pwd)' 'HERE=$(cd "$(dirname "$0")" || pwd)' c_defaults_ao_lado
mutant default-do-check-no-cwd 'CHECK=${2:-$HERE/hetzner-nodejs.sh}' 'CHECK=${2:-./hetzner-nodejs.sh}' c_defaults_ao_lado

echo
echo "$n verificações, $fails falha(s)"
[ "$fails" -eq 0 ]
