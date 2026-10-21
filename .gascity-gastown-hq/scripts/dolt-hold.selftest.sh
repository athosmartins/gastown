#!/bin/bash
# dolt-hold.selftest.sh (ga-3risy2) — testa dolt-hold-lib.sh (a leitura do hold) e dolt-hold.sh
# (a ferramenta que põe/tira/consulta). Nunca toca no Dolt, no hold da cidade nem em `gc`: todo
# arquivo de hold mora num scratch (GC_DOLT_HOLD_FILE / GC_PACK_STATE_DIR apontados para lá).
#
# ## Contents
# - A tabela de estados · Resolução do caminho · Paridade com o patch do engine · A ferramenta
#
# Uso: bash scripts/dolt-hold.selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/dolt-hold-lib.sh"
TOOL="$HERE/dolt-hold.sh"
PATCH="$HERE/../docs/pending-engine-window/ga-3risy2-dolt-hold.patch"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  BAD  $*"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP $*"; }

# O ambiente da sessão que roda o selftest pode apontar para o runtime REAL da cidade.
unset GC_PACK_STATE_DIR GC_CITY_RUNTIME_DIR GC_DOLT_HOLD_FILE GC_CITY GC_CITY_PATH CITY PACK_STATE_DIR

T="$(mktemp -d /tmp/dolt-hold-selftest.XXXXXX)"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
# shellcheck source=dolt-hold-lib.sh
. "$LIB"

H="$T/state/dolt-hold"
now=$(date +%s)

# case_blocks <nome> <conteudo|@ausente> <segura:1|0>
case_blocks() {
  local name="$1" content="$2" want="$3" rc msg
  rm -rf "$T/state"; mkdir -p "$T/state"
  [ "$content" = "@ausente" ] || printf '%s' "$content" > "$H"
  GC_DOLT_HOLD_FILE="$H" dolt_hold_blocks; rc=$?; msg="$DOLT_HOLD_MESSAGE"
  if { [ "$want" = 1 ] && [ "$rc" = 0 ]; } || { [ "$want" = 0 ] && [ "$rc" = 1 ]; }; then
    ok "$name -> $([ "$want" = 1 ] && echo SEGURA || echo SOLTA)"
  else
    bad "$name: esperava $([ "$want" = 1 ] && echo SEGURA || echo SOLTA), veio rc=$rc ($msg)"
  fi
  # quem segura TEM de explicar; quem solta não pode deixar mensagem velha (a mensagem é lida por quem decide)
  if [ "$rc" = 0 ] && [ -z "$msg" ]; then bad "$name: segurou sem mensagem"; fi
  if [ "$rc" = 1 ] && [ -n "$msg" ]; then bad "$name: soltou mas deixou mensagem '$msg'"; fi
}

echo "== a tabela de estados (mesma do Go: cmd/gc/dolt_hold_test.go) =="
case_blocks "arquivo ausente"                       "@ausente"                                         0
case_blocks "touch (vazio) segura até apagar"       ""                                                 1
case_blocks "owner e reason"                        $'owner=mayor\nreason=troca do hq\n'               1
case_blocks "validade futura"                       "expires_at=$((now + 3600))"$'\n'                  1
case_blocks "validade == agora solta"               "expires_at=$now"$'\n'                             0
case_blocks "validade vencida solta"                "expires_at=$((now - 3600))"$'\n'                  0
case_blocks "comentários, brancos, chave solta"     $'# a mão\n\n  modo = troca \nnão é par\nexpires_at = '"$((now + 3600))"$'\n' 1
case_blocks "dois expires_at: vale o 1º (futuro)"   "expires_at=$((now + 3600))"$'\nexpires_at='"$((now - 3600))"$'\n' 1
case_blocks "dois expires_at: vale o 1º (vencido)"  "expires_at=$((now - 3600))"$'\nexpires_at='"$((now + 3600))"$'\n' 0
case_blocks "CRLF"                                  $'owner=a\r\nexpires_at='"$((now + 3600))"$'\r\n'   1
case_blocks "expires_at em branco é ilegível"       $'expires_at=\n'                                   1
case_blocks "expires_at texto é ilegível"           $'expires_at=amanhã\n'                             1
case_blocks "expires_at com + é ilegível"           "expires_at=+$((now + 3600))"$'\n'                 1
case_blocks "expires_at negativo é ilegível"        $'expires_at=-5\n'                                 1
case_blocks "expires_at zero é ilegível"            $'expires_at=0\n'                                  1
case_blocks "expires_at estourado é ilegível"       $'expires_at=99999999999999999999999\n'            1

# diretório no lugar do arquivo; arquivo no lugar da pasta-mãe; sem caminho nenhum
rm -rf "$T/state"; mkdir -p "$H"
GC_DOLT_HOLD_FILE="$H" dolt_hold_blocks && ok "diretório onde devia estar o arquivo -> SEGURA" || bad "diretório no lugar do arquivo soltou o hold"
rm -rf "$T/state"; : > "$T/state"
GC_DOLT_HOLD_FILE="$H" dolt_hold_blocks && ok "arquivo onde devia estar a pasta-mãe -> SEGURA (ENOTDIR não é 'sem hold')" || bad "ENOTDIR soltou o hold"
rm -rf "$T/state"
GC_DOLT_HOLD_FILE="$T/nao/existe/dolt-hold" dolt_hold_blocks && bad "pasta-mãe inexistente segurou" || ok "pasta-mãe inexistente -> SOLTA (ninguém pôs hold ali)"
( unset GC_DOLT_HOLD_FILE PACK_STATE_DIR; dolt_hold_blocks ) && ok "sem caminho nenhum -> SEGURA ('não sei' não é 'sem hold')" || bad "sem caminho nenhum soltou o hold"
if [ "$(id -u)" != "0" ]; then
  mkdir -p "$T/state"; printf 'owner=x\n' > "$H"; chmod 000 "$H"
  GC_DOLT_HOLD_FILE="$H" dolt_hold_blocks && ok "arquivo sem permissão de leitura -> SEGURA" || bad "arquivo ilegível soltou o hold"
  chmod 644 "$H"
  chmod 000 "$T/state"
  GC_DOLT_HOLD_FILE="$H" dolt_hold_blocks && ok "pasta-mãe sem permissão de busca -> SEGURA" || bad "pasta-mãe inacessível soltou o hold"
  chmod 755 "$T/state"
else
  skip "permissões: rodando como root (chmod não bloqueia leitura)"
fi
rm -rf "$T/state"

echo "== a mensagem diz quem, por quê e até quando =="
mkdir -p "$T/state"; printf 'owner=mayor\nreason=troca do hq\nexpires_at=%s\n' "$((now + 3600))" > "$H"
GC_DOLT_HOLD_FILE="$H" dolt_hold_blocks
for want in "$H" "mayor" "troca do hq" "expires" "remove the file"; do
  case "$DOLT_HOLD_MESSAGE" in *"$want"*) ok "mensagem traz '$want'" ;; *) bad "mensagem sem '$want': $DOLT_HOLD_MESSAGE" ;; esac
done

echo "== de onde vem o caminho (mesma conta do engine) =="
rm -rf "$T/state" "$T/rt" "$T/city"; mkdir -p "$T/city/.gc/runtime/packs/dolt" "$T/rt/packs/dolt" "$T/ps"
touch "$T/city/.gc/runtime/packs/dolt/dolt-hold"
dolt_hold_city_blocks "$T/city" && ok "cidade sem env: <cidade>/.gc/runtime/packs/dolt/dolt-hold" || bad "não achou o hold no caminho padrão da cidade"
[ "$(dolt_hold_city_path "$T/city")" = "$T/city/.gc/runtime/packs/dolt/dolt-hold" ] && ok "dolt_hold_city_path devolve o caminho padrão" || bad "dolt_hold_city_path errado: $(dolt_hold_city_path "$T/city")"
( export GC_CITY_RUNTIME_DIR="$T/rt"; dolt_hold_city_blocks "$T/city" ) && bad "GC_CITY_RUNTIME_DIR ignorado (olhou a cidade)" || ok "GC_CITY_RUNTIME_DIR vence a cidade (e lá não há hold)"
touch "$T/rt/packs/dolt/dolt-hold"
( export GC_CITY_RUNTIME_DIR="$T/rt"; dolt_hold_city_blocks "$T/city" ) && ok "GC_CITY_RUNTIME_DIR/packs/dolt/dolt-hold é lido" || bad "não leu o hold de GC_CITY_RUNTIME_DIR"
( export GC_CITY_RUNTIME_DIR="$T/rt" GC_PACK_STATE_DIR="$T/ps"; dolt_hold_city_blocks "$T/city" ) && bad "GC_PACK_STATE_DIR não venceu GC_CITY_RUNTIME_DIR" || ok "GC_PACK_STATE_DIR vence GC_CITY_RUNTIME_DIR"
( export GC_DOLT_HOLD_FILE="$T/city/.gc/runtime/packs/dolt/dolt-hold" GC_PACK_STATE_DIR="$T/ps"; dolt_hold_city_blocks "$T/nada" ) && ok "GC_DOLT_HOLD_FILE vence tudo" || bad "GC_DOLT_HOLD_FILE não venceu"
( dolt_hold_city_blocks "" ) && ok "sem cidade nenhuma -> SEGURA" || bad "sem cidade nenhuma soltou o hold"

echo "== paridade com o patch do engine =="
if [ -r "$PATCH" ]; then
  # as linhas '+' do arquivo NOVO examples/bd/assets/scripts/dolt-hold.sh dentro do patch
  eng_fn="$(awk '/^diff --git a\/examples\/bd\/assets\/scripts\/dolt-hold\.sh /{f=1; next} f && /^diff --git /{f=0} f && /^\+/ && !/^\+\+\+/{print substr($0,2)}' "$PATCH" | sed -n '/^# dolt_hold_blocks returns 0/,/^}/p')"
  lib_fn="$(sed -n '/^# dolt_hold_blocks returns 0/,/^}/p' "$LIB")"
  if [ -z "$eng_fn" ]; then
    bad "não achei a função no patch do engine ($PATCH) — o extrator quebrou, a paridade não foi checada"
  elif [ "$eng_fn" = "$lib_fn" ]; then
    ok "dolt_hold_blocks da cidade é IDÊNTICA à do engine ($(printf '%s\n' "$lib_fn" | wc -l | tr -d ' ') linhas)"
  else
    bad "dolt_hold_blocks da cidade DIVERGE da do engine (diff abaixo) — mexeu numa, mexa na outra"
    diff <(printf '%s\n' "$eng_fn") <(printf '%s\n' "$lib_fn") | head -20
  fi
else
  skip "patch do engine não está em $PATCH (já aplicado e renomeado?) — paridade NÃO checada; compare à mão com examples/bd/assets/scripts/dolt-hold.sh do engine"
fi

echo "== a ferramenta dolt-hold.sh =="
export GC_DOLT_HOLD_FILE="$T/tool/dolt-hold" GC_CITY_PATH="$T/toolcity"
rm -rf "$T/tool"
run_tool() { bash "$TOOL" "$@" 2>&1; }
out=$(run_tool status); rc=$?
[ "$rc" = 1 ] && ok "status sem hold -> exit 1 ('$out')" || bad "status sem hold deu rc=$rc: $out"
out=$(run_tool on); rc=$?
[ "$rc" = 2 ] && ok "on sem --reason -> exit 2 (quem vê o hold precisa saber o porquê)" || bad "on sem --reason deu rc=$rc"
out=$(run_tool on --reason x --ttl-secs 0); rc=$?
[ "$rc" = 2 ] && ok "on --ttl-secs 0 -> exit 2" || bad "ttl 0 deu rc=$rc"
out=$(run_tool on --reason x --ttl-secs abc); rc=$?
[ "$rc" = 2 ] && ok "on --ttl-secs abc -> exit 2" || bad "ttl texto deu rc=$rc"
out=$(run_tool on --reason x --ttl-secs 43201); rc=$?
[ "$rc" = 2 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ] && ok "on --ttl-secs acima do teto de 12 h -> exit 2 e nada gravado" || bad "ttl acima do teto passou (rc=$rc)"

t0=$(date +%s)
out=$(run_tool on --reason "troca do hq" --owner mayor); rc=$?
t1=$(date +%s)
[ "$rc" = 0 ] && [ -f "$GC_DOLT_HOLD_FILE" ] && ok "on --reason -> exit 0 e o arquivo existe" || bad "on deu rc=$rc: $out"
exp=$(sed -n 's/^expires_at=//p' "$GC_DOLT_HOLD_FILE")
{ [ -n "$exp" ] && [ "$exp" -ge $((t0 + 7200)) ] && [ "$exp" -le $((t1 + 7200)) ]; } && ok "validade padrão = agora + 2 h ($exp)" || bad "validade padrão errada: '$exp' (esperava ~$((t0 + 7200)))"
grep -qx 'owner=mayor' "$GC_DOLT_HOLD_FILE" && grep -qx 'reason=troca do hq' "$GC_DOLT_HOLD_FILE" && ok "owner e reason gravados" || bad "owner/reason não gravados: $(tr '\n' '|' < "$GC_DOLT_HOLD_FILE")"
case "$out" in *"HOLD posto"*) ok "on diz 'HOLD posto' e a próxima ação" ;; *) bad "on não confirmou: $out" ;; esac
out=$(run_tool status); rc=$?
[ "$rc" = 0 ] && ok "status com hold -> exit 0 ('${out%%;*}...')" || bad "status com hold deu rc=$rc: $out"
before=$(cat "$GC_DOLT_HOLD_FILE")
out=$(run_tool on --reason "outro"); rc=$?
[ "$rc" = 3 ] && [ "$(cat "$GC_DOLT_HOLD_FILE")" = "$before" ] && ok "on com hold já em vigor -> exit 3 e o hold do outro fica intacto" || bad "on sobrescreveu ou não recusou (rc=$rc)"
out=$(run_tool off); rc=$?
[ "$rc" = 0 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ] && ok "off -> exit 0 e o arquivo sumiu" || bad "off deu rc=$rc e o arquivo ${GC_DOLT_HOLD_FILE##*/} $([ -e "$GC_DOLT_HOLD_FILE" ] && echo continua)"
case "$out" in *"NÃO foi iniciado"*) ok "off avisa que NÃO sobe o Dolt" ;; *) bad "off não avisou que não sobe o Dolt: $out" ;; esac
out=$(run_tool off); rc=$?
[ "$rc" = 0 ] && ok "off sem hold -> exit 0 (idempotente)" || bad "off sem hold deu rc=$rc"

# --no-expiry grava sem validade; reason com quebra de linha não injeta chave
out=$(run_tool on --reason "x" --no-expiry); rc=$?
{ [ "$rc" = 0 ] && ! grep -q '^expires_at=' "$GC_DOLT_HOLD_FILE"; } && ok "--no-expiry -> sem expires_at" || bad "--no-expiry gravou validade (rc=$rc)"
run_tool off >/dev/null
out=$(run_tool on --reason $'x\nexpires_at=1\nowner=outro'); rc=$?
n_exp=$(grep -c '^expires_at=' "$GC_DOLT_HOLD_FILE" 2>/dev/null)
{ [ "$rc" = 0 ] && [ "$n_exp" = 1 ] && ! grep -qx 'expires_at=1' "$GC_DOLT_HOLD_FILE" && [ "$(grep -c '^owner=' "$GC_DOLT_HOLD_FILE")" = 1 ]; } \
  && ok "reason com quebra de linha NÃO injeta chave (1 expires_at, 1 owner)" || bad "reason injetou chave no arquivo: $(tr '\n' '|' < "$GC_DOLT_HOLD_FILE")"
run_tool off >/dev/null

# hold VENCIDO não impede `on`; hold ILEGÍVEL impede (e `off` limpa)
mkdir -p "$T/tool"; printf 'owner=velho\nexpires_at=%s\n' "$((now - 60))" > "$GC_DOLT_HOLD_FILE"
out=$(run_tool status); rc=$?
[ "$rc" = 1 ] && case "$out" in *VENCIDO*) true ;; *) false ;; esac && ok "status de hold vencido -> exit 1 e diz VENCIDO" || bad "status de hold vencido: rc=$rc $out"
out=$(run_tool on --reason novo --owner eu); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'owner=eu' "$GC_DOLT_HOLD_FILE"; } && ok "on por cima de hold vencido -> substitui" || bad "on não substituiu o hold vencido (rc=$rc)"
run_tool off >/dev/null
printf 'expires_at=amanha\n' > "$GC_DOLT_HOLD_FILE"
out=$(run_tool on --reason x); rc=$?
[ "$rc" = 3 ] && ok "on sobre hold ilegível -> exit 3 (ilegível SEGURA, não se sobrescreve às cegas)" || bad "on sobre hold ilegível deu rc=$rc"
out=$(run_tool off); rc=$?
[ "$rc" = 0 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ] && ok "off remove hold ilegível" || bad "off não removeu o hold ilegível (rc=$rc)"
# nenhum temporário sobra ao lado do hold
ls -A "$T/tool" 2>/dev/null | grep -q '^\.dolt-hold\.' && bad "sobrou arquivo temporário em $T/tool: $(ls -A "$T/tool")" || ok "nenhum temporário sobra ao lado do hold"
bash "$TOOL" 2>/dev/null; [ "$?" = 2 ] && ok "sem subcomando -> exit 2 (uso)" || bad "sem subcomando não deu exit 2"

echo
echo "dolt-hold selftest: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
