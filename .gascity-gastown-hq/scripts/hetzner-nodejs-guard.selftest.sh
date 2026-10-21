#!/usr/bin/env bash
# hetzner-nodejs-guard.selftest.sh — hermético: o `hetzner-nodejs.sh check` é um stub que registra a chamada e sai com o rc escolhido; a lista mac-only é um arquivo temporário. (ga-2hd02v.4.11)
#
# Contents
#   Casos · Mutantes
#
# CASOS: os 5 arquivos na lista = não se aplica (rc 0) e o check NÃO é chamado · fora da lista + check rc 0 = ok · fora da lista + check rc 1 = FALHA rc 1 que diz como consertar · fora da lista + check rc 2, 3,
#   124 (prazo), 127 (script ausente) ou qualquer outro = NÃO SEI rc 2, nunca verde · UM só dos 5 fora da lista basta para exigir o Node · lista ilegível, ausente ou sem nenhum glob = rc 2 sem chamar o check
#   · a lista cobre por GLOB (`tests/test_blow_*.py`), como o classificador, então não exige o Node · caminho parecido mas diferente na lista (`...py.bak`) NÃO cobre · linha com espaço no fim ainda cobre.
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
FIVE='tests/test_blow_rate_limit.py tests/test_blow_budget.py tests/test_blow_property_ids.py tests/test_blow_scraper_ids_wiring.py tests/test_scraper_status_blow_probe.py'
printf '#!/usr/bin/env bash\necho "chamado: $*" >> "%s"\necho "NODEJS stub"\nexit "${STUB_CHECK_RC:-0}"\n' "$CALLS" > "$CHK"
mklist() { { printf '# lista de teste\ntests/test_rodada_state.py\n'; for f in "$@"; do printf '%s\n' "$f"; done; } > "$LIST"; }
reset() { : > "$CALLS"; unset STUB_CHECK_RC; mklist; }
run() { ( cd "$T" && bash "${SCRIPT:-$G}" "${1:-$LIST}" "${2:-$CHK}" > "$T/out" 2>&1 ); echo $?; }
called() { [ -s "$CALLS" ] && echo sim || echo nao; }

c_todos_na_lista() { reset; mklist $FIVE; local rc; rc=$(run); eq "os 5 na lista: rc 0 (não se aplica)" 0 "$rc"; has "…diz que o Node não é exigido" "$T/out" 'ok: os 5 arquivos estão cobertos'; eq "…e o check NÃO é chamado" nao "$(called)"; }
c_fora_check_ok() { reset; STUB_CHECK_RC=0; export STUB_CHECK_RC; local rc; rc=$(run); eq "5 fora da lista + check rc 0: rc 0" 0 "$rc"; has "…diz ok" "$T/out" 'ok: 5 arquivo\(s\) fora da lista'; eq "…o check foi chamado" sim "$(called)"; has "…como 'check'" "$CALLS" 'chamado: check'; }
c_fora_check_falha() { reset; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "5 fora da lista + check rc 1 (sem Node): rc 1" 1 "$rc"; has "…FALHA" "$T/out" 'FALHA'; has "…diz como consertar (install ou recolocar na lista)" "$T/out" 'hetzner-nodejs.sh install.*recoloque'; }
c_fora_check_nao_sei() { reset; local rc code; for code in 2 3 124 127 9; do STUB_CHECK_RC=$code; export STUB_CHECK_RC; rc=$(run); eq "check rc $code: rc 2 (NÃO SEI, nunca verde)" 2 "$rc"; done; has "…NAO-SEI" "$T/out" 'NAO-SEI'; hasnt "…não diz ok" "$T/out" '^NODEJS-GUARD ok'; }
c_um_so_fora() { reset; mklist tests/test_blow_rate_limit.py tests/test_blow_budget.py tests/test_blow_property_ids.py tests/test_blow_scraper_ids_wiring.py; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "só 1 dos 5 fora da lista + sem Node: rc 1" 1 "$rc"; has "…conta 1 arquivo" "$T/out" 'FALHA: 1 arquivo'; }
c_script_ausente() { reset; local rc; rc=$(run "$LIST" "$T/nao-existe.sh"); eq "script do check ausente: rc 2 (127 do bash, NÃO SEI)" 2 "$rc"; }
c_lista_ausente() { reset; local rc; rc=$(run "$T/nao-existe.txt"); eq "lista ausente: rc 2" 2 "$rc"; eq "…sem chamar o check" nao "$(called)"; has "…NAO-SEI" "$T/out" 'NAO-SEI'; has "…e o diagnóstico é 'ilegível ou ausente' (não 'sem glob')" "$T/out" 'ilegível ou ausente'; hasnt "…sem confundir com lista vazia" "$T/out" 'nenhum glob'; }
c_lista_sem_glob() { reset; printf '# só comentário\n\n# outro\n' > "$LIST"; local rc; rc=$(run); eq "lista sem nenhum glob: rc 2 (não 'todos fora')" 2 "$rc"; eq "…sem chamar o check" nao "$(called)"; has "…diz que não sabe o que ela cobre" "$T/out" 'nenhum glob'; }
c_cobre_por_glob() { reset; mklist 'tests/test_blow_*.py' tests/test_scraper_status_blow_probe.py; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "a lista cobre por glob (tests/test_blow_*.py): rc 0 mesmo com o check em rc 1" 0 "$rc"; eq "…e o check não é chamado" nao "$(called)"; }
c_parecido_nao_cobre() { reset; mklist tests/test_blow_rate_limit.py.bak tests/test_blow_budget.py.bak tests/test_blow_property_ids.pyc tests/test_blow_scraper_ids_wiring.py.old tests/test_scraper_status_blow_probe.py.orig; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "caminhos parecidos (.bak/.pyc/.old/.orig) NÃO cobrem: rc 1" 1 "$rc"; }
c_espaco_no_fim() { reset; { printf '# lista\n'; for f in $FIVE; do printf '%s   \n' "$f"; done; } > "$LIST"; STUB_CHECK_RC=1; export STUB_CHECK_RC; local rc; rc=$(run); eq "linha com espaços no fim ainda cobre: rc 0" 0 "$rc"; }
CASES="c_todos_na_lista c_fora_check_ok c_fora_check_falha c_fora_check_nao_sei c_um_so_fora c_script_ausente c_lista_ausente c_lista_sem_glob c_cobre_por_glob c_parecido_nao_cobre c_espaco_no_fim"
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
mutant falha-cai-no-nao-sei   '  1) say "FALHA:' '  5) say "FALHA:' c_fora_check_falha
mutant falha-sai-0            '; exit 1 ;;' '; exit 0 ;;' c_fora_check_falha
mutant nao-sei-vira-ok        '; exit 2 ;;' '; exit 0 ;;' c_fora_check_nao_sei
mutant lista-ilegivel-segue   '[ -r "$LIST" ] || { say "NAO-SEI: lista ilegível ou ausente ($LIST)"; exit 2; }' ':' c_lista_ausente
mutant lista-sem-glob-segue   'grep -qE '"'"'^[^#[:space:]]'"'"' "$LIST" 2>/dev/null || {' 'true || {' c_lista_sem_glob
mutant sempre-exige-node      '[ "$out_of_list" -gt 0 ] || {' 'true || {' c_todos_na_lista
mutant igualdade-no-lugar-do-glob 'case "$1" in $g) return 0 ;; esac' '[ "$1" = "$g" ] && return 0' c_cobre_por_glob
mutant glob-casa-tudo         'case "$1" in $g) return 0 ;; esac' 'case "$1" in *) return 0 ;; esac' c_parecido_nao_cobre
mutant espaco-no-fim-fica     'g="${g%"${g##*[![:space:]]}"}"; ' '' c_espaco_no_fim
mutant um-fora-nao-basta      '[ "$out_of_list" -gt 0 ] || {' '[ "$out_of_list" -gt 1 ] || {' c_um_so_fora

echo
echo "$n verificações, $fails falha(s)"
[ "$fails" -eq 0 ]
