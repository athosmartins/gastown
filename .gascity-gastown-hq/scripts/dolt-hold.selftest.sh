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

# Componente ACIMA da pasta-mãe. `[ -e pasta ]` dá falso para ENOENT, mas TAMBÉM para EACCES/ENOTDIR num ancestral
# (o Go, com os.Open, segura nos dois): "a pasta-mãe não existe" só vale se o ancestral existente mais próximo é uma
# pasta com permissão de busca. Quem faria estes casos falharem: voltar a tratar `[ ! -e pasta ]` como "sem hold".
# anc_case <nome> <caminho do hold> <segura:1|0>: a mensagem acompanha o veredito (quem segura explica, quem solta cala)
anc_case() {
  local name="$1" path="$2" want="$3" rc msg
  GC_DOLT_HOLD_FILE="$path" dolt_hold_blocks; rc=$?; msg="$DOLT_HOLD_MESSAGE"
  if { [ "$want" = 1 ] && [ "$rc" = 0 ] && [ -n "$msg" ]; } || { [ "$want" = 0 ] && [ "$rc" = 1 ] && [ -z "$msg" ]; }; then
    ok "$name -> $([ "$want" = 1 ] && echo SEGURA || echo SOLTA)"
  else
    bad "$name: esperava $([ "$want" = 1 ] && echo SEGURA || echo SOLTA), veio rc=$rc msg='$msg'"
  fi
}
if [ "$(id -u)" != "0" ]; then
  rm -rf "$T/anc"; mkdir -p "$T/anc/a/b"; chmod 000 "$T/anc/a"
  anc_case "ancestral SEM busca acima da pasta-mãe (a pasta-mãe nem aparece)" "$T/anc/a/b/c/dolt-hold" 1
  anc_case "ancestral SEM busca, o hold a dois níveis" "$T/anc/a/b/dolt-hold" 1
  chmod 755 "$T/anc/a"
else
  skip "ancestral sem busca: rodando como root (chmod não bloqueia)"
fi
rm -rf "$T/anc"; mkdir -p "$T/anc"; : > "$T/anc/a"
anc_case "arquivo comum no lugar de um ancestral (ENOTDIR acima da pasta-mãe)" "$T/anc/a/b/dolt-hold" 1
rm -rf "$T/anc"; mkdir -p "$T/anc"; ln -s "$T/anc/nada" "$T/anc/elo"
anc_case "ancestral é um elo para lugar nenhum" "$T/anc/elo/b/dolt-hold" 1
rm -rf "$T/anc"; mkdir -p "$T/anc"
anc_case "vários componentes inexistentes, tudo acessível acima" "$T/anc/a/b/c/dolt-hold" 0
( cd "$T/anc" && GC_DOLT_HOLD_FILE="x/y/dolt-hold" dolt_hold_blocks ) && bad "caminho relativo com pasta inexistente segurou" || ok "caminho relativo com pasta inexistente -> SOLTA"
# dirname falhando: sem saber qual é a pasta-mãe não há como dizer "sem hold" (vazio e falhou não podem dar o mesmo valor)
mkdir -p "$T/shimd"; printf '#!/bin/sh\nexit 1\n' > "$T/shimd/dirname"; chmod +x "$T/shimd/dirname"
( PATH="$T/shimd:$PATH"; GC_DOLT_HOLD_FILE="$T/anc/a/dolt-hold" dolt_hold_blocks && [ -n "$DOLT_HOLD_MESSAGE" ] ) && ok "dirname falhou -> SEGURA (com mensagem)" || bad "dirname falhando soltou o hold"
rm -rf "$T/anc" "$T/shimd"

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
# run_fresh: como run_tool, mas parte SEM hold — um caso que falha e deixa um hold não pode mascarar o seguinte
run_fresh() { rm -rf "$T/tool"; bash "$TOOL" "$@" 2>&1; }
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
out=$(run_tool on --reason x --ttl-secs 0043201); rc=$?
[ "$rc" = 2 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ] && ok "on --ttl-secs 0043201 (decimal 43201, acima do teto) -> exit 2" || bad "ttl com zeros acima do teto passou (rc=$rc)"
out=$(run_tool on --reason x --ttl-secs 000); rc=$?
[ "$rc" = 2 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ] && ok "on --ttl-secs 000 -> exit 2 (zero, mesmo com zeros)" || bad "ttl 000 passou (rc=$rc)"

# Zero à esquerda é DECIMAL para quem valida (`[ -gt ]`) e era OCTAL para quem grava ($((now + ttl))):
# "07200" virava 3712 s (a validade vencia cedo e os guards religavam o Dolt sobre a pasta em troca) e
# "08"/"09" estouravam ("value too great for base", rc 1, temporário esquecido). O que se grava tem de
# ser o que se validou: expires_at - created_at == o ttl pedido, lido como decimal.
for pair in 07200:7200 0010:10 08:8 09:9 0900:900 00300:300 000000000000000000000000000007200:7200; do
  ttl_in="${pair%%:*}"; ttl_want="${pair##*:}"
  rm -rf "$T/tool"
  out=$(run_tool on --reason x --ttl-secs "$ttl_in"); rc=$?
  c_at=$(sed -n 's/^created_at=//p' "$GC_DOLT_HOLD_FILE" 2>/dev/null); e_at=$(sed -n 's/^expires_at=//p' "$GC_DOLT_HOLD_FILE" 2>/dev/null)
  if [ "$rc" = 0 ] && [ -n "$c_at" ] && [ -n "$e_at" ] && [ $((e_at - c_at)) -eq "$ttl_want" ]; then
    ok "on --ttl-secs $ttl_in -> validade = created_at + $ttl_want s (decimal)"
  else
    bad "on --ttl-secs $ttl_in: rc=$rc, validade-created_at=$([ -n "$c_at" ] && [ -n "$e_at" ] && echo $((e_at - c_at)) || echo '?') (esperava $ttl_want): $out"
  fi
  ls -A "$T/tool" 2>/dev/null | grep -q '^\.dolt-hold\.' && bad "on --ttl-secs $ttl_in deixou temporário em $T/tool"
done
rm -rf "$T/tool"

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

# TERCEIRO ESTADO no `off`: pasta-mãe sem permissão de busca. `[ -e arquivo ]` dá falso para um arquivo
# que EXISTE (o lib trata isto como "não consegui saber -> SEGURA", e o status acerta); o off dizia
# "sem hold; nada a tirar" (rc 0) com o hold ainda segurando. Tem de recusar (rc 4) e dizer que segura.
if [ "$(id -u)" != "0" ]; then
  rm -rf "$T/tool"; mkdir -p "$T/tool"; printf 'owner=x\nreason=y\n' > "$GC_DOLT_HOLD_FILE"; chmod 000 "$T/tool"
  out=$(run_tool status); rc=$?
  st_rc=$rc
  out=$(run_tool off); rc=$?
  chmod 755 "$T/tool"
  if [ "$rc" = 4 ] && [ -f "$GC_DOLT_HOLD_FILE" ]; then
    case "$out" in *"continua em vigor"*) ok "off com a pasta-mãe sem busca -> exit 4, o hold continua e o off DIZ que continua (status=$st_rc)" ;; *) bad "off recusou (rc 4) mas não disse que o hold continua: $out" ;; esac
  else
    bad "off com a pasta-mãe sem busca: rc=$rc (esperava 4), hold $([ -f "$GC_DOLT_HOLD_FILE" ] && echo continua || echo sumiu): $out"
  fi
  case "$out" in *"nada a tirar"*) bad "off disse 'nada a tirar' com o hold ainda em vigor: $out" ;; esac
  rm -rf "$T/tool"
else
  skip "off com pasta-mãe sem busca: rodando como root (chmod não bloqueia)"
fi

# --no-expiry grava sem validade; reason com quebra de linha não injeta chave
out=$(run_tool on --reason "x" --no-expiry); rc=$?
{ [ "$rc" = 0 ] && ! grep -q '^expires_at=' "$GC_DOLT_HOLD_FILE"; } && ok "--no-expiry -> sem expires_at" || bad "--no-expiry gravou validade (rc=$rc)"
run_tool off >/dev/null
out=$(run_tool on --reason $'x\nexpires_at=1\nowner=outro'); rc=$?
n_exp=$(grep -c '^expires_at=' "$GC_DOLT_HOLD_FILE" 2>/dev/null)
{ [ "$rc" = 0 ] && [ "$n_exp" = 1 ] && ! grep -qx 'expires_at=1' "$GC_DOLT_HOLD_FILE" && [ "$(grep -c '^owner=' "$GC_DOLT_HOLD_FILE")" = 1 ]; } \
  && ok "reason com quebra de linha NÃO injeta chave (1 expires_at, 1 owner)" || bad "reason injetou chave no arquivo: $(tr '\n' '|' < "$GC_DOLT_HOLD_FILE")"
run_tool off >/dev/null
# CR+LF também (um leitor que apara o \r leria "expires_at=1" como outra linha); o texto vai para uma linha só
out=$(run_fresh on --reason $'a\r\nexpires_at=1' --owner $'o\r\nowner=outro'); rc=$?
n_exp=$(grep -c '^expires_at=' "$GC_DOLT_HOLD_FILE" 2>/dev/null); n_own=$(grep -c '^owner=' "$GC_DOLT_HOLD_FILE" 2>/dev/null)
{ [ "$rc" = 0 ] && [ "$n_exp" = 1 ] && [ "$n_own" = 1 ] && ! grep -qx 'expires_at=1' "$GC_DOLT_HOLD_FILE" && ! grep -q $'\r' "$GC_DOLT_HOLD_FILE"; } \
  && ok "reason e owner com CR+LF NÃO injetam chave e não deixam \\r no arquivo" || bad "CR+LF injetou chave ou deixou \\r (rc=$rc): $(tr '\n\r' '|~' < "$GC_DOLT_HOLD_FILE")"
run_tool off >/dev/null

# hold VENCIDO e hold ILEGÍVEL: o `on` recusa os dois (ele nunca apaga arquivo de ninguém: quem tira é o `off`)
mkdir -p "$T/tool"; printf 'owner=velho\nexpires_at=%s\n' "$((now - 60))" > "$GC_DOLT_HOLD_FILE"
out=$(run_tool status); rc=$?
[ "$rc" = 1 ] && case "$out" in *VENCIDO*) true ;; *) false ;; esac && ok "status de hold vencido -> exit 1 e diz VENCIDO" || bad "status de hold vencido: rc=$rc $out"
before=$(cat "$GC_DOLT_HOLD_FILE")
out=$(run_tool on --reason novo --owner eu); rc=$?
if [ "$rc" = 3 ] && [ "$(cat "$GC_DOLT_HOLD_FILE")" = "$before" ]; then
  case "$out" in *"dolt-hold.sh off"*) ok "on por cima de hold VENCIDO -> exit 3, o arquivo fica intacto e a mensagem manda rodar 'off'" ;; *) bad "on recusou o vencido mas não mandou rodar 'off': $out" ;; esac
else
  bad "on por cima de hold vencido: rc=$rc (esperava 3 sem tocar no arquivo): $out"
fi
run_tool off >/dev/null
out=$(run_tool on --reason novo --owner eu); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'owner=eu' "$GC_DOLT_HOLD_FILE"; } && ok "depois do 'off', o on põe o hold novo" || bad "on depois do off falhou (rc=$rc): $out"
run_tool off >/dev/null
printf 'expires_at=amanha\n' > "$GC_DOLT_HOLD_FILE"
out=$(run_tool on --reason x); rc=$?
[ "$rc" = 3 ] && ok "on sobre hold ilegível -> exit 3 (ilegível SEGURA, não se sobrescreve às cegas)" || bad "on sobre hold ilegível deu rc=$rc"
out=$(run_tool off); rc=$?
[ "$rc" = 0 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ] && ok "off remove hold ilegível" || bad "off não removeu o hold ilegível (rc=$rc)"
# nenhum temporário sobra ao lado do hold
ls -A "$T/tool" 2>/dev/null | grep -q '^\.dolt-hold\.' && bad "sobrou arquivo temporário em $T/tool: $(ls -A "$T/tool")" || ok "nenhum temporário sobra ao lado do hold"
bash "$TOOL" 2>/dev/null; [ "$?" = 2 ] && ok "sem subcomando -> exit 2 (uso)" || bad "sem subcomando não deu exit 2"

# Injeção de falha: comandos de mentira no PATH (SHIM_*) que agem ANTES do ln/mv/date de verdade, para
# provocar o que não dá para provocar de fora — outro `on` no meio da gravação, o arquivo gravado com
# outra validade, o relógio ilegível.
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ln" <<'SHIM_EOF'
#!/bin/bash
# Um arquivo só, copiado como ln / mv / date / mktemp / wc / head: o nome com que foi chamado decide o papel.
case "${0##*/}" in
  date) [ -n "${SHIM_NODATE:-}" ] && exit 1; exec "$SHIM_REAL_DATE" "$@" ;;
  wc)   [ -n "${SHIM_NOWC:-}" ] && exit 1; exec "$SHIM_REAL_WC" "$@" ;;
  head) [ -n "${SHIM_NOHEAD:-}" ] && exit 1; exec "$SHIM_REAL_HEAD" "$@" ;;
  mktemp) # o hold VÁLIDO de outro operador aparece enquanto este `on` prepara o dele: DEPOIS da leitura
          # "sem hold" (primeira checagem) e ANTES de publicar — a janela larga, que o `ln` abaixo não cobre
    if [ "${SHIM_MODE:-}" = early ] && [ ! -e "$SHIM_HOLD" ]; then
      printf 'owner=outro\nreason=posto no meio\nexpires_at=%s\n' "$SHIM_COMPETING_EXP" > "$SHIM_HOLD"
    fi
    if [ "${SHIM_MODE:-}" = early_expired ] && [ ! -e "$SHIM_HOLD" ]; then
      printf 'owner=velho\nexpires_at=%s\n' "$SHIM_COMPETING_EXP" > "$SHIM_HOLD"
    fi
    exec "$SHIM_REAL_MKTEMP" "$@" ;;
esac
case "${SHIM_MODE:-}" in
  race) # outro operador publica o hold dele depois da checagem do `on` e antes da gravação
    [ -e "$SHIM_HOLD" ] || printf 'owner=outro\nreason=posto no meio\n' > "$SHIM_HOLD" ;;
  rewrite) # o arquivo vai para o destino com OUTRA validade (ainda no futuro: lê-se como hold em vigor)
    src=""; for a in "$@"; do case "$a" in --|-f) ;; *) src="$a"; break ;; esac; done
    sed "s/^expires_at=.*/expires_at=$SHIM_NEWEXP/" "$src" > "$src.x" && "$SHIM_REAL_MV" -f "$src.x" "$src" ;;
  pad) # o arquivo vai para o destino com 5000 bytes ANTES da validade: ela fica além dos 4 KiB que os leitores leem
    src=""; for a in "$@"; do case "$a" in --|-f) ;; *) src="$a"; break ;; esac; done
    { printf '# '; "$SHIM_REAL_HEAD" -c 5000 /dev/zero | tr '\0' x; printf '\n'; cat "$src"; } > "$src.x" && "$SHIM_REAL_MV" -f "$src.x" "$src" ;;
  hang) # segura o `on` entre o mktemp e o ln o bastante para um sinal chegar; depois falha (nada é publicado)
    sleep 2; exit 1 ;;
esac
case "${0##*/}" in
  mv) exec "$SHIM_REAL_MV" "$@" ;;
  *)  exec "$SHIM_REAL_LN" "$@" ;;
esac
SHIM_EOF
chmod +x "$SHIM/ln"; for n in mv date mktemp wc head; do cp "$SHIM/ln" "$SHIM/$n"; done
# shim_tool <VAR=valor...> -- <args da ferramenta>: roda dolt-hold.sh com o PATH de mentira e as variáveis SHIM_*
shim_tool() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env PATH="$SHIM:$PATH" SHIM_REAL_LN="$(command -v ln)" SHIM_REAL_MV="$(command -v mv)" SHIM_REAL_DATE="$(command -v date)" \
      SHIM_REAL_MKTEMP="$(command -v mktemp)" SHIM_REAL_WC="$(command -v wc)" SHIM_REAL_HEAD="$(command -v head)" \
      SHIM_HOLD="$GC_DOLT_HOLD_FILE" ${envs[@]+"${envs[@]}"} bash "$TOOL" "$@" 2>&1
}

# (a) `on` com outro `on` no meio: não pode sobrescrever o hold do outro (exit 3), nem deixar temporário
rm -rf "$T/tool"
out=$(shim_tool SHIM_MODE=race -- on --reason meu); rc=$?
if [ "$rc" = 3 ] && grep -qx 'owner=outro' "$GC_DOLT_HOLD_FILE" 2>/dev/null && ! grep -q 'reason=meu' "$GC_DOLT_HOLD_FILE" 2>/dev/null; then
  ok "hold posto por outro DEPOIS da checagem do on -> exit 3 e o hold dele fica intacto"
else
  bad "on sobrescreveu o hold que apareceu no meio (rc=$rc): $(tr '\n' '|' < "$GC_DOLT_HOLD_FILE" 2>/dev/null) / $out"
fi
ls -A "$T/tool" 2>/dev/null | grep -q '^\.dolt-hold\.' && bad "a corrida deixou temporário em $T/tool: $(ls -A "$T/tool")" || ok "a corrida não deixa temporário"

# (b) o arquivo gravado tem OUTRA validade que a pedida: o post-write "é lido como hold em vigor" passa
# (a validade curta ainda segura), então só conferir o valor pega — foi o caso do octal
rm -rf "$T/tool"
newexp=$(( $(date +%s) + 60 ))
out=$(shim_tool SHIM_MODE=rewrite SHIM_NEWEXP="$newexp" -- on --reason x); rc=$?
case "$out" in *"HOLD posto"*) said_ok=1 ;; *) said_ok=0 ;; esac
if [ "$rc" = 4 ] && [ "$said_ok" = 0 ]; then
  ok "arquivo gravado com validade diferente da pedida -> exit 4 e NÃO diz 'HOLD posto'"
else
  bad "validade gravada diferente da pedida passou (rc=$rc): $out"
fi
rm -rf "$T/tool"

# (c) relógio ilegível: sem `now` não há created_at nem expires_at confiáveis -> recusa (exit 4), nada gravado
out=$(shim_tool SHIM_NODATE=1 -- on --reason x); rc=$?
{ [ "$rc" = 4 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ]; } && ok "relógio ilegível -> exit 4 e nada gravado" || bad "relógio ilegível: rc=$rc, hold $([ -e "$GC_DOLT_HOLD_FILE" ] && echo gravado || echo ausente): $out"
rm -rf "$T/tool"

# (d) O hold VÁLIDO de outro operador aparece CEDO: depois da leitura "sem hold" e antes de o `on` olhar o destino
# (a janela larga: mkdir, mktemp, date, escrita). O `on` achava que o destino existente era um hold VENCIDO
# (suposição que nunca reconferia), apagava o hold do outro e dizia "HOLD posto". O caso (a) acima injeta o hold
# DENTRO do `ln`, depois dessa checagem, e por isso nunca passou por aqui. Quem faria este teste falhar: o `on`
# voltar a apagar ou sobrescrever o destino (rm -f / mv -f antes do ln): ele só publica com `ln`, que não sobrescreve.
rm -rf "$T/tool"
cexp=$(( $(date +%s) + 3600 ))
out=$(shim_tool SHIM_MODE=early SHIM_COMPETING_EXP="$cexp" -- on --reason meu --owner eu); rc=$?
case "$out" in *"HOLD posto"*) said_ok=1 ;; *) said_ok=0 ;; esac
if [ "$rc" = 3 ] && [ "$said_ok" = 0 ] && grep -qx 'owner=outro' "$GC_DOLT_HOLD_FILE" 2>/dev/null && grep -qx "expires_at=$cexp" "$GC_DOLT_HOLD_FILE" 2>/dev/null && ! grep -q 'reason=meu' "$GC_DOLT_HOLD_FILE" 2>/dev/null; then
  ok "hold válido de outro aparece ANTES de o on olhar o destino -> exit 3, o hold dele fica intacto e o on não diz 'HOLD posto'"
else
  bad "o on apagou/sobrescreveu o hold válido de outro (rc=$rc, disse-ok=$said_ok): $(tr '\n' '|' < "$GC_DOLT_HOLD_FILE" 2>/dev/null) / $out"
fi
ls -A "$T/tool" 2>/dev/null | grep -q '^\.dolt-hold\.' && bad "a corrida cedo deixou temporário em $T/tool: $(ls -A "$T/tool")" || ok "a corrida cedo não deixa temporário"
rm -rf "$T/tool"

# (d2) O mesmo, mas o que aparece no destino é um hold VENCIDO: o `on` não o apaga (nem para pôr o dele); recusa e
# manda rodar `off`. Quem faria falhar: o `on` apagar o vencido e publicar por cima (o que ele fazia: com dois `on`
# juntos e um vencido no lugar, medido em 60 rodadas: 10 com as duas chamadas em exit 0 e 8 com exit 4).
cexp=$(( $(date +%s) - 120 ))
out=$(shim_tool SHIM_MODE=early_expired SHIM_COMPETING_EXP="$cexp" -- on --reason meu --owner eu); rc=$?
case "$out" in *"HOLD posto"*) said_ok=1 ;; *) said_ok=0 ;; esac
if [ "$rc" = 3 ] && [ "$said_ok" = 0 ] && grep -qx 'owner=velho' "$GC_DOLT_HOLD_FILE" 2>/dev/null && ! grep -q 'reason=meu' "$GC_DOLT_HOLD_FILE" 2>/dev/null; then
  case "$out" in *"dolt-hold.sh off"*) ok "hold VENCIDO aparece entre a leitura e a publicação -> exit 3, o arquivo fica e a mensagem manda rodar 'off'" ;; *) bad "recusou o vencido mas não mandou rodar 'off': $out" ;; esac
else
  bad "o on apagou/sobrescreveu o hold vencido que apareceu no meio (rc=$rc, disse-ok=$said_ok): $(tr '\n' '|' < "$GC_DOLT_HOLD_FILE" 2>/dev/null) / $out"
fi
ls -A "$T/tool" 2>/dev/null | grep -q '^\.dolt-hold\.' && bad "o vencido no meio deixou temporário: $(ls -A "$T/tool")" || ok "o vencido no meio não deixa temporário"
rm -rf "$T/tool"

# (e) O texto do hold tem de caber com folga nos 4 KiB que os DOIS leitores leem. Quem faria falhar: tirar o teto de
# bytes de --reason/--owner (o texto longo empurra a validade para fora do que o leitor vê: o hold nunca vence).
long5k=$(head -c 5000 /dev/zero | tr '\0' x)
out=$(run_fresh on --reason "$long5k"); rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ]; } && ok "on --reason de 5000 bytes -> exit 2 e nada gravado" || bad "reason de 5000 bytes passou (rc=$rc, hold $([ -e "$GC_DOLT_HOLD_FILE" ] && echo gravado || echo ausente))"
out=$(run_fresh on --reason x --owner "$long5k"); rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ]; } && ok "on --owner de 5000 bytes -> exit 2 e nada gravado" || bad "owner de 5000 bytes passou (rc=$rc)"
# o teto é em BYTES, não em caracteres: 600 'ã' são 600 caracteres e 1200 bytes
acute600=$(printf 'ã%.0s' $(seq 1 600))
out=$(run_fresh on --reason "$acute600"); rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ]; } && ok "on --reason de 600 'ã' (1200 bytes) -> exit 2: o teto conta bytes" || bad "reason de 1200 bytes (600 caracteres) passou (rc=$rc)"
# no teto exato ainda passa, e a validade continua LIDA pelo leitor (status mostra 'expires')
r1000=$(head -c 1000 /dev/zero | tr '\0' x)
out=$(run_fresh on --reason "$r1000" --owner "$(head -c 200 /dev/zero | tr '\0' o)"); rc=$?
size=$(wc -c < "$GC_DOLT_HOLD_FILE" 2>/dev/null | tr -d ' ')
st=$(run_tool status); st_rc=$?
if [ "$rc" = 0 ] && [ "${size:-9999}" -lt 2048 ] && [ "$st_rc" = 0 ]; then
  case "$st" in *"expires"*) ok "reason de 1000 bytes + owner de 200 no teto -> exit 0, arquivo de $size bytes e o leitor vê a validade" ;; *) bad "no teto o leitor não vê a validade: $st" ;; esac
else
  bad "reason de 1000 + owner de 200 bytes: rc=$rc, arquivo de ${size:-?} bytes, status rc=$st_rc: $out"
fi
run_tool off >/dev/null
# a validade vem ANTES do texto livre: mesmo um texto grande demais (mão, outra versão) não a empurra para fora da
# leitura. Quem faria falhar: gravar owner/reason antes de expires_at.
out=$(run_fresh on --reason "texto qualquer" --owner o); rc=$?
ln_exp=$(grep -n '^expires_at=' "$GC_DOLT_HOLD_FILE" | head -n 1 | cut -d: -f1); ln_rsn=$(grep -n '^reason=' "$GC_DOLT_HOLD_FILE" | head -n 1 | cut -d: -f1); ln_own=$(grep -n '^owner=' "$GC_DOLT_HOLD_FILE" | head -n 1 | cut -d: -f1)
{ [ -n "$ln_exp" ] && [ -n "$ln_rsn" ] && [ -n "$ln_own" ] && [ "$ln_exp" -lt "$ln_own" ] && [ "$ln_exp" -lt "$ln_rsn" ]; } && ok "expires_at é gravado ANTES de owner e reason (linha $ln_exp < $ln_own/$ln_rsn)" || bad "expires_at não vem antes de owner/reason (linhas exp=$ln_exp owner=$ln_own reason=$ln_rsn)"
run_tool off >/dev/null

# (f) A conferência depois de gravar lê os MESMOS bytes que o leitor (os 4096 primeiros). Um arquivo que chega ao
# destino com a validade além disso passa pela leitura do arquivo inteiro e o hold NUNCA venceria, com exit 0.
# Quem faria falhar: reler o arquivo todo (sed no arquivo) em vez dos 4096 primeiros bytes.
rm -rf "$T/tool"
out=$(shim_tool SHIM_MODE=pad -- on --reason x); rc=$?
case "$out" in *"HOLD posto"*) said_ok=1 ;; *) said_ok=0 ;; esac
if [ "$rc" = 4 ] && [ "$said_ok" = 0 ]; then
  ok "validade além dos 4096 bytes do leitor -> exit 4 e NÃO diz 'HOLD posto'"
else
  bad "validade fora do alcance do leitor passou (rc=$rc, disse-ok=$said_ok): $out"
fi
rm -rf "$T/tool"
# reler falhou (head) -> NÃO é 'sem validade': exit 4. Com --no-expiry o esperado é justamente "nenhum expires_at",
# então só a falha de leitura explícita separa "li e não há validade" de "não consegui ler" (com validade, o pipe
# que extrai o valor também falharia e esconderia a diferença). Quem faria falhar: tirar a checagem do status do head.
# E medir o texto falhou (wc) -> recusa, nada gravado.
out=$(shim_tool SHIM_NOHEAD=1 -- on --reason x --no-expiry); rc=$?
case "$out" in *"HOLD posto"*) said_ok=1 ;; *) said_ok=0 ;; esac
{ [ "$rc" = 4 ] && [ "$said_ok" = 0 ]; } && ok "não consegui reler o arquivo gravado -> exit 4 e NÃO diz 'HOLD posto'" || bad "releitura falha passou (rc=$rc, disse-ok=$said_ok): $out"
rm -rf "$T/tool"
out=$(shim_tool SHIM_NOWC=1 -- on --reason x); rc=$?
{ [ "$rc" = 4 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ]; } && ok "não consegui medir o texto (wc falhou) -> exit 4 e nada gravado" || bad "wc falhando passou (rc=$rc, hold $([ -e "$GC_DOLT_HOLD_FILE" ] && echo gravado || echo ausente)): $out"
rm -rf "$T/tool"

# (g) Opções que se contradizem ou se confundem não viram um hold diferente do pedido.
out=$(run_fresh on --reason x --ttl-secs 600 --no-expiry); rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ]; } && ok "--ttl-secs junto de --no-expiry -> exit 2 e nada gravado" || bad "--ttl-secs com --no-expiry passou (rc=$rc)"
out=$(run_fresh on --reason x --no-expiry --ttl-secs 600); rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ]; } && ok "--no-expiry junto de --ttl-secs (ordem inversa) -> exit 2" || bad "--no-expiry com --ttl-secs passou (rc=$rc)"
out=$(run_fresh on --reason --no-expiry); rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ]; } && ok "--reason seguido de outra opção -> exit 2 (não engole '--no-expiry' como texto)" || bad "--reason --no-expiry passou (rc=$rc): $(tr '\n' '|' < "$GC_DOLT_HOLD_FILE" 2>/dev/null)"
out=$(run_fresh on --reason x --owner --ttl-secs 5); rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$GC_DOLT_HOLD_FILE" ]; } && ok "--owner seguido de outra opção -> exit 2" || bad "--owner --ttl-secs passou (rc=$rc)"

# (h) Sinal entre o mktemp e o ln não deixa o temporário para trás. O shim segura o `on` 2 s nesse ponto e falha o
# ln (nada é publicado e o shim NÃO apaga o temporário); o TERM mata o bash enquanto ele espera esse filho, e é o
# trap de EXIT dele que apaga o temporário. Quem faria falhar: tirar o trap de EXIT do `on` (conferido por mutação
# no bash 5.3 e no /bin/bash 3.2: sem o trap sobra o .dolt-hold.XXXXXX).
rm -rf "$T/tool"
( shim_tool SHIM_MODE=hang -- on --reason x >/dev/null ) 2>/dev/null &   # 2>/dev/null: o aviso "Terminated" do filho morto de propósito sai do subshell
sub=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  ls -A "$T/tool" 2>/dev/null | grep -q '^\.dolt-hold\.' && break
  sleep 0.1
done
tool_pid=$(pgrep -f "bash $TOOL on --reason x" | head -n 1)
if [ -n "$tool_pid" ] && ls -A "$T/tool" 2>/dev/null | grep -q '^\.dolt-hold\.'; then
  kill -TERM "$tool_pid" 2>/dev/null
  wait "$sub" 2>/dev/null
  sleep 2.5   # o ln de mentira ainda está dormindo: espera ele acabar para não deixar rastro no scratch
  if ls -A "$T/tool" 2>/dev/null | grep -q '^\.dolt-hold\.'; then
    bad "TERM entre mktemp e ln deixou temporário: $(ls -A "$T/tool")"
  else
    ok "TERM entre o mktemp e o ln não deixa temporário"
  fi
else
  bad "não consegui parar o on entre mktemp e ln para testar o sinal (pid='${tool_pid:-}')"
  wait "$sub" 2>/dev/null
fi
rm -rf "$T/tool"

echo
echo "dolt-hold selftest: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
