#!/usr/bin/env bash
# pilot-dispatcher.wa-node-route.selftest.sh — testes do gancho _pilot_wa_node_decide (ga-2hd02v.1.10).
#
# O gancho manda uma bead WA "código + teste sem banco real" ao nó Hetzner (wa-worker-remote) em vez do pool do mini. Regra do Athos
# (18/10): nenhum dado de lead/cliente no nó. O gancho nasce DESLIGADO (PILOT_WA_NODE_ROUTE=off|shadow|label|auto, padrão off) e só
# chama scripts/wa-node-dispatch.sh; quem classifica e escreve é esse script (selftest próprio).
#
# O que este arquivo prova:
#   A. comportamento da função extraída (palavra por palavra) do pilot-dispatcher.sh, contra um wa-node-dispatch.sh falso:
#      off (e qualquer valor que não seja um dos 4 modos) não chama nada · shadow só chama `check` e nunca devolve 0 ·
#      label/auto chamam `apply` com a base certa · só rc 0 vira "atribuída ao nó" · rc 13/124/137/143 e qualquer rc >= 128 (morto por sinal) = resultado desconhecido (2) ·
#      alvo que não é wa-worker, id que não é wa-*, script ausente, dry-run → nada escrito.
#   B. a fiação no despacho (grep no fonte): o ponto de chamada fica depois do guarda de posse e antes de "deixar sem dono"; o braço
#      `wa-worker-remote)` do spawn vem antes de `wa-worker*)` e não faz `gc session new` nem carimba gc.routed_to=wa-worker; o rc 2 solta a
#      claim e não despacha; a função só é chamada num lugar.
#   C. mutantes: cada quebra abaixo tem de derrubar este selftest.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.wa-node-route.selftest.sh
# Exit 0 iff tudo passa. Saída: linhas ok/FAIL, "N/N ok", "SELFTEST OK".

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
DISPATCHER="${WA_NODE_ROUTE_SELFTEST_FILE:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()   { echo "  ok   $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
check() { # check <descrição> <comando…>  — passa se o comando sai 0
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi
}

[ -f "$DISPATCHER" ] || { echo "FATAL: $DISPATCHER não existe" >&2; exit 2; }
FN="$(awk '/^_pilot_wa_node_decide\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
[ -n "$FN" ] || { echo "FATAL: _pilot_wa_node_decide() não está em $DISPATCHER" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wa-node-route.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/city"

# wa-node-dispatch.sh falso: anota os argumentos, devolve FAKE_RC e FAKE_OUT.
cat > "$T/scripts/wa-node-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
echo "${FAKE_OUT:-fake}"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/scripts/wa-node-dispatch.sh"

PRELUDE='warn(){ echo "WARN $*" >&2; }
log(){ echo "LOG $*" >&2; }
timeout(){ shift; "$@"; }'

# bd falso do gancho (ga-9636op, gate-fix 1): só entende `bd -C <loja> show <id> --json`; anota a chamada em $FAKE_BD_LOG e devolve o conteúdo de
# $FAKE_BEAD, ou falha com $FAKE_BD_RC. Qualquer outro verbo é um erro do teste: o gancho só LÊ a bead.
mkdir -p "$T/bin"
cat > "$T/bin/bd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_BD_LOG:-/dev/null}"
[ "${FAKE_BD_RC:-0}" = 0 ] || exit "$FAKE_BD_RC"
[ "$3" = show ] || { echo "bd falso: verbo inesperado '$3' (o gancho só lê)" >&2; exit 64; }
[ -n "${FAKE_BEAD:-}" ] && [ -f "$FAKE_BEAD" ] && cat "$FAKE_BEAD"
exit 0
EOF
chmod +x "$T/bin/bd"
export PATH="$T/bin:$PATH" FAKE_BD_LOG="$T/bdcalls"
# bead <arquivo> <status> <assignee> <rota> [id] — grava o JSON da bead falsa (o formato de `bd show --json`: um array com um objeto)
bead() {
  jq -cn --arg id "${5:-$ID}" --arg s "$2" --arg a "$3" --arg r "$4" '[{id:$id,status:$s,assignee:$a,metadata:(if $r=="" then {} else {"gc.routed_to":$r} end)}]' > "$1"
}
ID=wa-abc12
bead "$T/bead.free.json" open "" ""
export FAKE_BEAD="$T/bead.free.json"     # padrão: bead livre (nada do nó); os casos da bead do nó trocam FAKE_BEAD

# decide <modo|-> <id> <store> <alvo> [rc] [dry]  → imprime o rc da função; deixa FAKE_LOG, FAKE_BD_LOG e o jsonl em $T
decide() {
  local mode="$1" id="$2" store="$3" tgt="$4" rc="${5:-0}" dry="${6:-0}"
  : > "$T/calls"; : > "$T/bdcalls"; : > "$T/err"; rm -f "$T/city/.gc/wa-node-route.jsonl"
  if [ "$mode" = "-" ]; then
    env -u PILOT_WA_NODE_ROUTE GC_CITY="$T/city" PILOT_WA_NODE_SCRIPTS="${SCRIPTS_DIR:-$T/scripts}" FAKE_LOG="$T/calls" FAKE_RC="$rc" DRY_RUN="$dry" \
      bash -c "$PRELUDE"$'\n'"$FN"$'\n''_pilot_wa_node_decide "$@"; echo "rc=$?"' _ "$id" "$store" "$tgt" 2>"$T/err" | tail -1
  else
    PILOT_WA_NODE_ROUTE="$mode" GC_CITY="$T/city" PILOT_WA_NODE_SCRIPTS="${SCRIPTS_DIR:-$T/scripts}" FAKE_LOG="$T/calls" FAKE_RC="$rc" DRY_RUN="$dry" \
      bash -c "$PRELUDE"$'\n'"$FN"$'\n''_pilot_wa_node_decide "$@"; echo "rc=$?"' _ "$id" "$store" "$tgt" 2>"$T/err" | tail -1
  fi
}
calls() { cat "$T/calls"; }
ncalls() { wc -l < "$T/calls" | tr -d ' '; }

ID=wa-abc12
ST=/x/whatsapp_automation

echo "pilot-dispatcher.wa-node-route.selftest — ga-2hd02v.1.10"
echo
echo "=== A. a função ==="

# --- desligado: nada roda ---
r=$(decide - $ID $ST wa-worker 0); [ "$r" = "rc=1" ] && [ "$(ncalls)" = 0 ] && [ ! -e "$T/city/.gc/wa-node-route.jsonl" ] \
  && ok "variável ausente (padrão off): rc 1, o script não é chamado, nada é gravado" || fail "variável ausente: $r calls=$(ncalls)"
for m in off OFF Auto AUTO on 1 true "" " auto" "auto " label2 shadow2; do
  r=$(decide "$m" $ID $ST wa-worker 0)
  [ "$r" = "rc=1" ] && [ "$(ncalls)" = 0 ] && ok "valor '$m' não é um dos 4 modos: rc 1, não chama nada" || fail "valor '$m': $r calls=$(ncalls)"
done

# --- shadow ---
r=$(decide shadow $ID $ST wa-worker 0)
[ "$r" = "rc=1" ] && ok "shadow com o script dizendo 0: a função devolve 1 (não muda o despacho)" || fail "shadow rc=0 → $r"
[ "$(ncalls)" = 1 ] && calls | grep -q "^check $ID --store $ST\$" && ok "shadow chama só 'check <id> --store <loja>'" || fail "shadow args: $(calls)"
calls | grep -q 'apply' && fail "shadow chamou apply" || ok "shadow nunca chama apply"
check "shadow grava uma linha de sombra com modo e rc" bash -c "jq -e 'select(.event==\"pilot-node-route\" and .bead==\"$ID\" and .mode==\"shadow\" and .rc==0 and (.ts|length>0))' '$T/city/.gc/wa-node-route.jsonl'"
for c in 10 11 12 13 124; do r=$(decide shadow $ID $ST wa-worker $c); [ "$r" = "rc=1" ] && ok "shadow com rc $c do script: ainda rc 1 (sombra não bloqueia o despacho nem pede para esperar)" || fail "shadow rc=$c → $r"; done

# --- label / auto: a base ---
r=$(decide label $ID $ST wa-worker 0)
[ "$r" = "rc=0" ] && ok "label com rc 0 do script: a bead foi para o nó (rc 0)" || fail "label rc=0 → $r"
[ "$(ncalls)" = 1 ] && calls | grep -q "^apply $ID --store $ST --basis label\$" && ok "label chama 'apply … --basis label'" || fail "label args: $(calls)"
r=$(decide auto $ID $ST wa-worker 0)
[ "$r" = "rc=0" ] && ok "auto com rc 0: foi para o nó" || fail "auto rc=0 → $r"
calls | grep -q "^apply $ID --store $ST --basis any\$" && ok "auto chama 'apply … --basis any'" || fail "auto args: $(calls)"
check "a linha gravada tem modo auto, rc 0 e a saída do script" bash -c "jq -e 'select(.mode==\"auto\" and .rc==0 and .out==\"fake\")' '$T/city/.gc/wa-node-route.jsonl'"

# --- só o rc 0 é "foi para o nó"; escrita incerta é 2 ---
for m in label auto; do
  for c in 10 11 12 2 1 3 99 125 126 127; do
    r=$(decide $m $ID $ST wa-worker $c); [ "$r" = "rc=1" ] && ok "$m: rc $c do script → 1 (fica no mini; nada foi escrito)" || fail "$m rc=$c → $r"
  done
  for c in 13 124 137 143; do
    r=$(decide $m $ID $ST wa-worker $c); [ "$r" = "rc=2" ] && ok "$m: rc $c do script → 2 (a escrita pode ter acontecido: não despacha)" || fail "$m rc=$c → $r"
  done
  # morto por outro sinal (128+n) depois da escrita não pode parecer "nada foi escrito": a bead ficaria nas duas filas
  for c in 128 129 130 131 134 139 141 255; do
    r=$(decide $m $ID $ST wa-worker $c); [ "$r" = "rc=2" ] && ok "$m: rc $c do script (morto por sinal) → 2 (a escrita pode ter acontecido: não despacha)" || fail "$m rc=$c → $r"
  done
done

# --- o que nunca é do nó ---
for t in ps-worker wa-worker-remote gastown.dog mila-wa "" wa-worker-1; do
  r=$(decide auto $ID $ST "$t" 0); [ "$r" = "rc=1" ] && [ "$(ncalls)" = 0 ] && ok "alvo '$t' não é o pool wa-worker: rc 1, não chama" || fail "alvo '$t' → $r calls=$(ncalls)"
done
for i in ga-abc12 gt-1 ps-9 abc "" "wa"; do
  r=$(decide auto "$i" $ST wa-worker 0); [ "$r" = "rc=1" ] && [ "$(ncalls)" = 0 ] && ok "id '$i' não é bead wa-*: rc 1, não chama" || fail "id '$i' → $r calls=$(ncalls)"
done

# --- script ausente / sem permissão ---
# (sem $(...) em volta de decide para o $T/err sobreviver: r vem de um arquivo)
SCRIPTS_DIR="$T/nada"; decide auto $ID $ST wa-worker 0 > "$T/r"; r=$(cat "$T/r")
[ "$r" = "rc=1" ] && grep -q 'não está executável' "$T/err" && ok "script ausente: rc 1 (fica no mini) e o aviso diz por quê" || fail "script ausente → $r / $(cat "$T/err")"
mkdir -p "$T/semx"; cp "$T/scripts/wa-node-dispatch.sh" "$T/semx/"; chmod -x "$T/semx/wa-node-dispatch.sh"
SCRIPTS_DIR="$T/semx"; decide auto $ID $ST wa-worker 0 > "$T/r"; r=$(cat "$T/r")
[ "$r" = "rc=1" ] && grep -q 'não está executável' "$T/err" && ok "script sem permissão de execução: rc 1 e o aviso" || fail "script sem x → $r / $(cat "$T/err")"
SCRIPTS_DIR=""

# --- ga-9636op (gate-fix 1): bead que JÁ é do nó nunca segue o caminho do pool do mini ---
# O apply sai 12 ("não está livre") para a bead que já é do nó, e 12 lido como "nada escrito" fazia o despacho carimbar gc.routed_to=wa-worker por cima da rota do nó e
# criar sessão do mini: a bead nas duas filas, uma varredura depois. O gancho lê a bead ele mesmo (três estados) ANTES de chamar o script, qualquer que seja o rc dele:
# do nó → 2 (segura); não consegui ler → 2; lida e não é do nó → segue como antes. Em shadow e off nada muda.
bead "$T/bead.node-both.json"  in_progress wa-worker-remote-1 wa-worker-remote
bead "$T/bead.node-asg.json"   in_progress wa-worker-remote-1 ""
bead "$T/bead.node-asg-open.json" open wa-worker-remote-1 ""
bead "$T/bead.node-route.json" open "" wa-worker-remote
bead "$T/bead.pool-route.json" open "" wa-worker
bead "$T/bead.crew.json"       in_progress mila-wa ""
bead "$T/bead.pool-sess.json"  in_progress wa-worker-1 wa-worker
bead "$T/bead.outro-id.json"   in_progress wa-worker-remote-1 wa-worker-remote wa-zzzzz
: > "$T/bead.vazio.json"; echo 'isto não é json' > "$T/bead.lixo.json"; echo '[]' > "$T/bead.lista-vazia.json"; echo 'null' > "$T/bead.null.json"
for m in label auto; do
  for f in node-both node-asg node-asg-open node-route; do
    export FAKE_BEAD="$T/bead.$f.json"
    for c in 12 0 1 10 11 13 126 127; do
      r=$(decide $m $ID $ST wa-worker $c)
      [ "$r" = "rc=2" ] && [ "$(ncalls)" = 0 ] && ok "$m: bead $f (já é do nó), rc $c do script → 2 (segura) e o script nem roda" || fail "$m bead $f rc=$c → $r calls=$(ncalls)"
    done
    grep -q 'já é do nó' "$T/err" && ok "$m: bead $f: o aviso diz que a bead já é do nó" || fail "$m bead $f: aviso: $(cat "$T/err")"
  done
  # não consegui ler = não sei se é do nó = segura (2); nunca "livre"
  export FAKE_BD_RC=1; r=$(decide $m $ID $ST wa-worker 12); unset FAKE_BD_RC
  [ "$r" = "rc=2" ] && [ "$(ncalls)" = 0 ] && grep -q 'não consegui reler' "$T/err" && ok "$m: bd falhou na leitura → 2 (segura), o script não roda e o aviso diz por quê" || fail "$m bd falha → $r calls=$(ncalls) err=$(cat "$T/err")"
  for f in vazio lixo lista-vazia null outro-id; do
    export FAKE_BEAD="$T/bead.$f.json"; r=$(decide $m $ID $ST wa-worker 12)
    [ "$r" = "rc=2" ] && [ "$(ncalls)" = 0 ] && ok "$m: leitura '$f' não é a bead pedida → 2 (segura), nunca 'livre'" || fail "$m leitura $f → $r calls=$(ncalls)"
  done
  # lida e que NÃO é do nó: o caminho de sempre (o script roda e o rc dele manda); inclui as parecidas que não podem ser tomadas por do nó
  for f in free pool-route crew pool-sess; do
    export FAKE_BEAD="$T/bead.$f.json"
    r=$(decide $m $ID $ST wa-worker 12); [ "$r" = "rc=1" ] && [ "$(ncalls)" = 1 ] && ok "$m: bead $f (não é do nó), rc 12 do script → 1 (fica no mini) e o script rodou" || fail "$m bead $f rc=12 → $r calls=$(ncalls)"
    r=$(decide $m $ID $ST wa-worker 0);  [ "$r" = "rc=0" ] && ok "$m: bead $f (não é do nó), rc 0 do script → 0 (foi para o nó)" || fail "$m bead $f rc=0 → $r"
    r=$(decide $m $ID $ST wa-worker 13); [ "$r" = "rc=2" ] && ok "$m: bead $f (não é do nó), rc 13 do script → 2 (escrita incerta)" || fail "$m bead $f rc=13 → $r"
  done
  export FAKE_BEAD="$T/bead.free.json"
  decide $m $ID $ST wa-worker 0 >/dev/null
  grep -q "^-C $ST show $ID --json\$" "$T/bdcalls" && [ "$(wc -l < "$T/bdcalls" | tr -d ' ')" = 1 ] && ok "$m: o gancho lê a bead UMA vez, na loja certa" || fail "$m: leituras: $(cat "$T/bdcalls")"
done
# shadow nunca muda o despacho, nem para a bead do nó; off não lê nada
export FAKE_BEAD="$T/bead.node-both.json"
r=$(decide shadow $ID $ST wa-worker 12); [ "$r" = "rc=1" ] && [ "$(ncalls)" = 1 ] && calls | grep -q '^check ' && ok "shadow com bead do nó: ainda rc 1 e só 'check' (a sombra não segura nada)" || fail "shadow bead do nó → $r / $(calls)"
r=$(decide - $ID $ST wa-worker 12); [ "$r" = "rc=1" ] && [ "$(ncalls)" = 0 ] && [ ! -s "$T/bdcalls" ] && ok "off com bead do nó: rc 1, nada chamado e nenhuma leitura" || fail "off bead do nó → $r calls=$(ncalls) bd=$(cat "$T/bdcalls")"
export FAKE_BEAD="$T/bead.free.json"
# script ausente + bead do nó: a bead do nó é segurada MESMO assim (o script ausente dizia 1 = mini)
export FAKE_BEAD="$T/bead.node-both.json"; SCRIPTS_DIR="$T/nada"; decide auto $ID $ST wa-worker 0 > "$T/r"; r=$(cat "$T/r"); SCRIPTS_DIR=""
[ "$r" = "rc=2" ] && ok "script ausente + bead do nó: 2 (segura), não 1 (o caminho do pool carimbaria o mini por cima)" || fail "script ausente + bead do nó → $r"
export FAKE_BEAD="$T/bead.free.json"

# --- dry-run: nunca escreve ---
r=$(decide auto $ID $ST wa-worker 0 1)
[ "$r" = "rc=1" ] && calls | grep -q "^apply $ID --store $ST --basis any --dry-run\$" && ok "DRY_RUN=1: 'apply … --dry-run' e rc 1 (nada vai ao nó)" || fail "dry-run: $r / $(calls)"
r=$(decide shadow $ID $ST wa-worker 0 1); [ "$r" = "rc=1" ] && calls | grep -q '^check ' && ok "DRY_RUN=1 em shadow: ainda só 'check'" || fail "dry shadow: $r / $(calls)"

echo
echo "=== B. a fiação no despacho ==="

ln_of() { grep -n -m1 -- "$1" "$DISPATCHER" | cut -d: -f1; }
CALLSITE=$(grep -n '_pilot_wa_node_decide "\$STORY_ID"' "$DISPATCHER" | cut -d: -f1 | head -1)
POOL_ARM=$(grep -n '^      wa-worker\*|ps-worker\*)' "$DISPATCHER" | cut -d: -f1 | head -1)
GUARD=$(awk -v a="${POOL_ARM:-0}" 'NR>a && /_ownership_guard_should_refuse "\$STORY_ID"/ {print NR; exit}' "$DISPATCHER")
LEAVE=$(ln_of ': # pool: leave UNASSIGNED + open so RoutedPoolQuery')
ARM_REMOTE=$(grep -n '^      wa-worker-remote)' "$DISPATCHER" | cut -d: -f1 | head -1)
ARM_WA=$(grep -n '^      wa-worker\*)' "$DISPATCHER" | cut -d: -f1 | head -1)
CASE_SPAWN=$(grep -n 'case "\$_SLING_TARGET" in' "$DISPATCHER" | awk -F: -v a="${ARM_REMOTE:-0}" '$1<a{l=$1} END{print l}')

[ "$(grep -c '_pilot_wa_node_decide "' "$DISPATCHER")" = 1 ] && ok "a função é chamada em um lugar só" || fail "chamadas: $(grep -c '_pilot_wa_node_decide "' "$DISPATCHER")"
[ -n "$CALLSITE" ] && [ -n "$POOL_ARM" ] && [ -n "$GUARD" ] && [ -n "$LEAVE" ] && [ "$POOL_ARM" -lt "$GUARD" ] && [ "$GUARD" -lt "$CALLSITE" ] && [ "$CALLSITE" -lt "$LEAVE" ] \
  && ok "o ponto de chamada vem depois do guarda de posse e antes de deixar a bead sem dono" || fail "ordem braço=$POOL_ARM guarda=$GUARD chamada=$CALLSITE deixar=$LEAVE"
[ -n "$ARM_REMOTE" ] && [ -n "$ARM_WA" ] && [ "$ARM_REMOTE" -lt "$ARM_WA" ] && [ -n "$CASE_SPAWN" ] \
  && ok "o braço wa-worker-remote) do spawn vem antes de wa-worker*) (senão o glob o engoliria)" || fail "braços remote=$ARM_REMOTE wa=$ARM_WA"
ARM_TEXT=$(awk -v s="${ARM_REMOTE:-0}" 'NR>=s{print} NR>s&&/^        ;;/{exit}' "$DISPATCHER")
printf '%s' "$ARM_TEXT" | grep -v '^ *#' | grep -q 'gc.*session new' && fail "o braço do nó faz gc session new (duas sessões; o dedup mata uma)" || ok "o braço do nó não cria sessão (o pool a cria)"
printf '%s' "$ARM_TEXT" | grep -v '^ *#' | grep -q 'gc.routed_to' && fail "o braço do nó mexe em gc.routed_to (já está certo; carimbar wa-worker põe a bead nas duas filas)" || ok "o braço do nó não carimba gc.routed_to"
SITE_TEXT=$(sed -n "${CALLSITE:-1},$((${CALLSITE:-1}+14))p" "$DISPATCHER")
printf '%s' "$SITE_TEXT" | grep -q '_SLING_TARGET="wa-worker-remote"' && ok "rc 0 troca o alvo para wa-worker-remote" || fail "troca de alvo ausente"
printf '%s' "$SITE_TEXT" | grep -q 'elif \[ "\$_RP_NODE_RC" = 2 \]; then' && printf '%s' "$SITE_TEXT" | grep -q 'label remove "\$STORY_ID" "pilot:dispatching"' && printf '%s' "$SITE_TEXT" | grep -q 'DISPATCH_RESULT="wa_node_unknown"' && printf '%s' "$SITE_TEXT" | grep -q 'return 1' \
  && ok "rc 2 solta a claim do Pilot e não despacha" || fail "rc 2: solta/DISPATCH_RESULT/return ausentes"
printf '%s' "$FN" | grep -q 'PILOT_WA_NODE_ROUTE:-off' && ok "o padrão da função é off" || fail "padrão não é off"
bash -n "$DISPATCHER" && ok "bash -n do pilot-dispatcher.sh" || fail "bash -n do pilot-dispatcher.sh"

# --- mutantes (só quando rodando o arquivo de verdade, para não recursar) ---
if [ -z "${WA_NODE_ROUTE_SELFTEST_FILE:-}" ]; then
  echo
  echo "=== C. mutantes (cada um tem de derrubar o selftest) ==="
  mutate() { # mutate <nome> <python: s = ...>
    local n="$1" code="$2"
    cp "$DISPATCHER" "$T/mut.$n.sh"
    MUT_FILE="$T/mut.$n.sh" python3 -I -c '
import os
p = os.environ["MUT_FILE"]
s = open(p, encoding="utf-8").read()
o = s
'"$code"'
assert s != o, "mutante não mudou nada"
open(p, "w", encoding="utf-8").write(s)
' || { fail "mutante $n: não consegui aplicar"; return; }
    if WA_NODE_ROUTE_SELFTEST_FILE="$T/mut.$n.sh" bash "$SELF" >/dev/null 2>&1; then fail "mutante $n SOBREVIVEU"; else ok "mutante $n morto"; fi
  }
  mutate padrao-auto      's = s.replace("PILOT_WA_NODE_ROUTE:-off", "PILOT_WA_NODE_ROUTE:-auto", 1)'
  mutate modo-livre       's = s.replace("case \"$_mode\" in shadow|label|auto) ;; *) return 1 ;; esac", "case \"$_mode\" in shadow|label|auto) ;; *) ;; esac", 1)'
  mutate shadow-devolve-0 's = s.replace("[ \"$_mode\" = shadow ] && return 1", "[ \"$_mode\" = shadow ] && return 0", 1)'
  mutate shadow-aplica    's = s.replace("\"$_dir/wa-node-dispatch.sh\" check \"$_id\"", "\"$_dir/wa-node-dispatch.sh\" apply \"$_id\" --basis any", 1)'
  mutate rc13-vira-mini   's = s.replace("13|124|137|143)", "124|137|143)", 1)'
  mutate timeout-vira-mini 's = s.replace("13|124|137|143)", "13)", 1)'
  mutate sinal-vira-mini  's = s.replace("12[89]|1[3-9][0-9]|2[0-4][0-9]|25[0-5])", "99999)", 1)'
  mutate sinal-largo-demais 's = s.replace("12[89]|1[3-9][0-9]|", "12[5-9]|1[3-9][0-9]|", 1)'
  mutate qualquer-rc-vale 's = s.replace("    *) return 1 ;;\n  esac\n  log \"  ga-2hd02v.1.10: $_id assigned", "    *) ;;\n  esac\n  log \"  ga-2hd02v.1.10: $_id assigned", 1)'
  mutate sem-filtro-alvo  's = s.replace("  [ \"$_tgt\" = \"wa-worker\" ] || return 1\n", "", 1)'
  mutate sem-filtro-id    's = s.replace("  case \"$_id\" in wa-*) ;; *) return 1 ;; esac\n", "", 1)'
  mutate label-vira-any   's = s.replace("  [ \"$_mode\" = label ] && _basis=label\n", "", 1)'
  mutate dry-escreve      's = s.replace(" --basis \"$_basis\" --dry-run", " --basis \"$_basis\"", 1)'
  mutate dry-devolve-0    's = s.replace("(rc=$_rc, dry-run: nothing written)\"\n    return 1", "(rc=$_rc, dry-run: nothing written)\"\n    return 0", 1)'
  mutate sem-script       's = s.replace("  if [ ! -x \"$_dir/wa-node-dispatch.sh\" ]; then", "  if false; then", 1)'
  mutate braco-fora-de-ordem 's = s.replace("      wa-worker-remote)\n", "      wa-worker-remoteX)\n", 1)'
  mutate braco-cria-sessao 's = s.replace("no spawn here, the pool creates the session\"\n", "no spawn here, the pool creates the session\"\n        gc --city \"$GC_CITY\" session new wa-worker-remote --no-attach\n", 1)'
  mutate braco-carimba-rota 's = s.replace("no spawn here, the pool creates the session\"\n", "no spawn here, the pool creates the session\"\n        bd -C \"$STORY_BEAD_CITY\" update \"$STORY_ID\" --set-metadata \"gc.routed_to=wa-worker\" -q\n", 1)'
  mutate rc2-nao-solta    's = s.replace("elif [ \"$_RP_NODE_RC\" = 2 ]; then", "elif false; then", 1)'
  mutate chamada-antes-do-guarda 'a = s.index("        # ── ga-2hd02v.1.10: Hetzner node, DEFAULT OFF"); b = s.index("        : # pool: leave UNASSIGNED"); blk = s[a:b]; s = s[:a] + s[b:]; k = s.index("        if [ \"${PILOT_OWNERSHIP_GUARD:-1}\" = \"1\" ]; then", s.index("      wa-worker*|ps-worker*)")); s = s[:k] + blk + s[k:]'
fi

echo
TOTAL=$((PASS+FAIL))
echo "$PASS/$TOTAL ok"
if [ "$FAIL" = 0 ]; then echo "SELFTEST OK"; exit 0; fi
echo "SELFTEST FAIL ($FAIL)"
exit 1
