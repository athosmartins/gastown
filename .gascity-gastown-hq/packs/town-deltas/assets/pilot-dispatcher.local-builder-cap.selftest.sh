#!/usr/bin/env bash
# pilot-dispatcher.local-builder-cap.selftest.sh — ga-2hd02v.17 (teto de construtores LOCAIS: "Construtores todos no Hetzner")
#
# Decisão do Athos (19/11 ~12:10, AskUserQuestion na sessão do Mayor): dogs e construtores do WA rodam no nó Hetzner; no mini fica UMA vaga de construtor. Causa (ga-1p1i5jr.13/.14): 16 GB do mini não
# comportam ~16 sessões Claude + Dolt + Chrome + painéis; cada GB acima vira swapfile permanente e o piso de disco pausa o mini. O teto por pool (PILOT_WA_WORKER_MAX, o max do gastown.dog) não basta:
# 1 wa-worker + 1 ps-worker + 1 dog são 3 sessões, e o teto por pool não vê o dog. Este arquivo prova o teto COMBINADO (wa-worker + ps-worker + gastown.dog; dog-remote, wa-worker-remote e
# ps-worker-remote são do nó e não contam) e a ligação dele em todo ponto em que o Pilot abre sessão local.
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# O QUE PROVA: o botão PILOT_LOCAL_BUILDER_MAX (vazio = sem teto, inteiro 0-999 = o teto, qualquer outra coisa = 1) · a contagem soma só os três templates do mini e só as sessões vivas (active, creating,
#   start-pending) · cabe / cheio / não consegui ler (o terceiro estado nunca vira "cabe": quem vai abrir sessão não abre) · `fresh` lê de novo e `cached` reaproveita a leitura da varredura, que um spawn
#   desta varredura sobe · o pulo pré-claim só vale para bead que o Pilot SABE que abriria sessão local, com o teto positivamente cheio e sem o nó querer a bead · o top-up de pool respeita o teto e o
#   recontaa depois de cada spawn · o empréstimo ao dog respeita o teto · os pontos de ligação existem em dispatch_lane, nos dois braços de pool, no sling ao dog e no top-up, na ordem certa.
# COMO RODA: as funções saem VERBATIM do dispatcher (awk) e rodam num shell filho; o `gc` é um executável de verdade no PATH do filho (o `timeout` dá exec no argumento, então uma função não serviria),
#   sem `gc`/`bd` reais (selftest-sandbox-path.lib.sh). Contra um dispatcher sem as funções o arquivo se recusa a começar — o vermelho honesto.
# CONTROLE NEGATIVO: cada guarda desligada numa cópia do dispatcher (LBC_NO_MUTANTS=1 pula) tem que reprovar este arquivo.
# Variáveis: PILOT_DISPATCHER_PATH · LBC_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${LBC_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${LBC_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
need_fn() { local s; s="$(fn_src "$1")"; [ -n "$s" ] || { echo "FATAL: $1() not found in $DISPATCHER (ga-2hd02v.17 not applied)" >&2; exit 2; }; printf '%s' "$s"; }
FUNC_JSON="$(need_fn gc_json_or_unknown)"
FUNC_LIVE="$(need_fn _pilot_live_session_count)"
FUNC_MAX="$(need_fn _pilot_local_builder_max)"
FUNC_GATE="$(need_fn _pilot_local_builder_gate)"
FUNC_NOTE="$(need_fn _pilot_local_builder_note_spawn)"
FUNC_PRE="$(need_fn _pilot_local_builder_full_pre)"
FUNC_HQG="$(need_fn _pilot_local_builder_hq_generic)"
FUNC_CRIG="$(need_fn bead_content_rig)"
FUNC_ARM="$(need_fn _pilot_local_builder_arm)"
FUNC_LEND="$(need_fn _pilot_dog_lend_dog_free)"
FUNC_VSC="$(need_fn _pilot_variable_session_count)"
FUNC_GVSC="$(need_fn gc_variable_session_count)"
FUNC_SLOW="$(need_fn _pilot_slow_spawn_budget_spent)"
FUNC_TIMING="$(need_fn _pilot_note_spawn_timing)"
FUNC_TOPSPAWN="$(need_fn _pilot_topup_spawn)"
FUNC_TOPUP="$(need_fn _pilot_pool_topup)"
PLB_INIT="$(grep -E '^_PLB_(N|MAX|LIVE|RC|DOG_FULL)=' "$DISPATCHER")"
[ "$(printf '%s\n' "$PLB_INIT" | grep -c .)" = 5 ] || { echo "FATAL: _PLB_* initialisers (N, MAX, LIVE, RC, DOG_FULL) not found in $DISPATCHER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-lbc-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# gc falso (executável de verdade): `session list` devolve $WORK/sl.json, conta as chamadas e falha/dá envelope de erro conforme o arquivo; `session new` grava o argv
cat > "$WORK/bin/gc" <<'EOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
case "$*" in
  *"session list"*)
    echo x >> "$W/list.calls"
    if [ -f "$W/sl.fail" ]; then echo "boom" >&2; exit 1; fi
    if [ -f "$W/sl.envelope" ]; then printf '{"ok":false,"error":{"code":"native_store_unavailable"}}'; exit 0; fi
    cat "$W/sl.json"; exit 0 ;;
  *"session new"*) echo "$*" >> "$W/new.log"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/gc"
sandbox_path_init "$WORK" jq timeout mkdir dirname cat date grep sed || exit 2

reset() { rm -f "$WORK"/list.calls "$WORK"/new.log "$WORK"/sl.* "$WORK"/lines.txt "$WORK"/bound.yes "$WORK"/node.yes; }
roster() { # roster template:state ... -> $WORK/sl.json
  local _first=1 _s _i=0
  { printf '{"sessions":['
    for _s in "$@"; do
      [ "$_first" = 1 ] || printf ','
      _first=0; _i=$((_i+1))
      printf '{"id":"s%d","template":"%s","state":"%s"}' "$_i" "${_s%%:*}" "${_s##*:}"
    done
    printf ']}'; } > "$WORK/sl.json"
}
list_calls() { [ -f "$WORK/list.calls" ] && wc -l < "$WORK/list.calls" | tr -d ' ' || echo 0; }
spawns() { [ -f "$WORK/new.log" ] && wc -l < "$WORK/new.log" | tr -d ' ' || echo 0; }
logged() { grep -qF -- "$1" "$WORK/lines.txt" 2>/dev/null; }

# run_lb '<código>' — roda o código num filho sob `set -uo pipefail` (a varredura real roda com -e: os pontos de chamada abaixo só usam `if`/`||`), depois das definições; imprime a última linha que
# ele echo-ar. Env: LBC_MAX (PILOT_LOCAL_BUILDER_MAX; ausente = não definida) · LBC_COUNT (a semente PILOT_TEST_LOCAL_BUILDER_COUNT).
run_lb() {
  (
    set -uo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log()  { echo "LOG $*" >> "$WORK/lines.txt"; }
    warn() { echo "WARN $*" >> "$WORK/lines.txt"; }
    GC_CITY="$WORK/city"; DRY_RUN=0
    PILOT_SESSION_LIST_TIMEOUT_SECS=5
    unset PILOT_LOCAL_BUILDER_MAX PILOT_TEST_LOCAL_BUILDER_COUNT GC_VARIABLE_SESSION_COUNT_OVERRIDE
    if [ "${LBC_MAX+x}" = x ]; then PILOT_LOCAL_BUILDER_MAX="$LBC_MAX"; export PILOT_LOCAL_BUILDER_MAX; fi
    if [ -n "${LBC_COUNT:-}" ]; then PILOT_TEST_LOCAL_BUILDER_COUNT="$LBC_COUNT"; export PILOT_TEST_LOCAL_BUILDER_COUNT; fi
    eval "$PLB_INIT"
    eval "$FUNC_JSON"; eval "$FUNC_LIVE"; eval "$FUNC_MAX"; eval "$FUNC_GATE"; eval "$FUNC_NOTE"; eval "$FUNC_PRE"; eval "$FUNC_HQG"; eval "$FUNC_CRIG"; eval "$FUNC_ARM"; eval "$FUNC_LEND"
    # o resto do que _pilot_local_builder_full_pre e _pilot_local_builder_arm chamam: só os pontos de decisão, controlados por arquivo
    _pilot_priority_pool_bound_pre() { [ -f "$WORK/bound.yes" ]; }
    _pilot_priority_node_exempt_pre() { [ -f "$WORK/node.yes" ]; }
    _pilot_release_pool_cap_queued() { echo "RELEASE-QUEUED $*" >> "$WORK/lines.txt"; return 0; }
    _pilot_release_count_unreadable() { echo "RELEASE-UNREADABLE $*" >> "$WORK/lines.txt"; return 0; }
    eval "$1"
  ) 2>&1 | tail -1
}

echo "── PILOT_LOCAL_BUILDER_MAX: vazio = sem teto · 0-999 = o teto · qualquer outra coisa = 1"
for tc in "unset|" "empty|" "one|1" "two|2" "zero|0" "lead0|007" "p999|999" "alpha|abc" "neg|-1" "dot|1.5" "sp|1 " "sp2| 1" "four|1000" "plus|+1"; do
  nm="${tc%%|*}"; val="${tc#*|}"
  case "$nm" in unset) r=$(run_lb 'echo "[$(_pilot_local_builder_max)]"') ;; *) r=$(LBC_MAX="$val" run_lb 'echo "[$(_pilot_local_builder_max)]"') ;; esac
  case "$nm" in
    unset|empty) want="[]" ;; one) want="[1]" ;; two) want="[2]" ;; zero) want="[0]" ;; lead0) want="[7]" ;; p999) want="[999]" ;;
    *) want="[1]" ;;
  esac
  [ "$r" = "$want" ] && ok "max '$val' ($nm) -> $r" || bad "max '$val' ($nm): esperado $want, deu $r"
done

echo "── a contagem soma SÓ wa-worker, ps-worker e gastown.dog, e só as vivas"
reset; roster wa-worker:active ps-worker:creating gastown.dog:start-pending dog-remote:active wa-worker-remote:active ps-worker-remote:active gate-reviewer:active mila-wa:active wa-worker:asleep gastown.dog:closed ps-worker:stopped
r=$(LBC_MAX=4 run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=$_PLB_N max=$_PLB_MAX"')
[ "$r" = "rc=0 n=3 max=4" ] && ok "3 vivas do mini (wa-worker, ps-worker, gastown.dog) e nada mais, teto 4: cabe — $r" || bad "contagem errada com teto 4: $r"
r=$(LBC_MAX=3 run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=$_PLB_N max=$_PLB_MAX"')
[ "$r" = "rc=1 n=3 max=3" ] && ok "as mesmas 3 com teto 3: CHEIO (rc 1) — dog-remote, wa-worker-remote, ps-worker-remote, revisor, crew, dormindo e fechada não contam" || bad "contagem errada com teto 3: $r"
reset; roster dog-remote:active wa-worker-remote:active ps-worker-remote:active gate-reviewer:active
r=$(LBC_MAX=1 run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=$_PLB_N"')
[ "$r" = "rc=0 n=0" ] && ok "só sessões do nó e revisores vivos: 0 construtores locais, cabe" || bad "sessão do nó contou como local: $r"

echo "── três estados: cabe / cheio / não consegui ler"
reset; roster
r=$(LBC_MAX=1 run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=$_PLB_N"')
[ "$r" = "rc=0 n=0" ] && ok "0 vivos, teto 1: cabe" || bad "0 vivos não coube: $r"
reset; roster gastown.dog:active
r=$(LBC_MAX=1 run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=$_PLB_N"')
[ "$r" = "rc=1 n=1" ] && ok "1 dog vivo, teto 1: CHEIO — o dog segura a vaga que o wa-worker pediria" || bad "dog vivo não encheu o teto: $r"
reset; roster
r=$(LBC_MAX=0 run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=$_PLB_N"')
[ "$r" = "rc=1 n=0" ] && ok "teto 0 com 0 vivos: cheio (0 = o mini não abre construtor)" || bad "teto 0 deixou abrir: $r"
reset; roster; : > "$WORK/sl.fail"
r=$(LBC_MAX=1 run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=[$_PLB_N]"')
[ "$r" = "rc=2 n=[]" ] && ok "gc session list falha: rc 2 e contagem vazia — leitura que falhou nunca vira 0" || bad "falha de leitura virou outra coisa: $r"
reset; : > "$WORK/sl.envelope"
r=$(LBC_MAX=1 run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=[$_PLB_N]"')
[ "$r" = "rc=2 n=[]" ] && ok "envelope de erro (JSON válido, ok:false, sem .sessions): rc 2, não 'zero sessões'" || bad "envelope de erro lido como contagem: $r"
reset; printf '{"sessions":"não é lista"}' > "$WORK/sl.json"
r=$(LBC_MAX=1 run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=[$_PLB_N]"')
[ "$r" = "rc=2 n=[]" ] && ok ".sessions que não é lista: rc 2" || bad ".sessions ilegível virou contagem: $r"
reset; roster wa-worker:active
r=$(LBC_MAX=1 LBC_COUNT=abc run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=[$_PLB_N]"')
[ "$r" = "rc=2 n=[]" ] && ok "semente de contagem que não é inteiro: rc 2" || bad "semente ilegível virou contagem: $r"
reset; roster gastown.dog:active
r=$(run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc max=[$_PLB_MAX]"')
[ "$r" = "rc=0 max=[]" ] && [ "$(list_calls)" = 0 ] && ok "sem PILOT_LOCAL_BUILDER_MAX: cabe e NEM lê as sessões (o Pilot de antes, byte a byte)" || bad "sem teto o gate leu sessões ou barrou: $r calls=$(list_calls)"
reset
r=$(LBC_MAX=1 LBC_COUNT=1 run_lb 'rc=0; _pilot_local_builder_gate fresh || rc=$?; echo "rc=$rc n=$_PLB_N"')
[ "$r" = "rc=1 n=1" ] && [ "$(list_calls)" = 0 ] && ok "semente PILOT_TEST_LOCAL_BUILDER_COUNT=1: cheio sem chamar o gc" || bad "a semente não valeu: $r calls=$(list_calls)"

echo "── fresh lê de novo; cached reaproveita a leitura da varredura; um spawn sobe o número"
reset; roster
r=$(LBC_MAX=1 run_lb 'a=0; _pilot_local_builder_gate fresh || a=$?; b=0; _pilot_local_builder_gate cached || b=$?; c=0; _pilot_local_builder_gate cached || c=$?; echo "a=$a b=$b c=$c"')
[ "$r" = "a=0 b=0 c=0" ] && [ "$(list_calls)" = 1 ] && ok "fresh + 2 cached com roster vazio: cabem e o gc foi consultado UMA vez" || bad "cache de varredura não reaproveitado: $r calls=$(list_calls)"
reset; roster
r=$(LBC_MAX=1 run_lb 'a=0; _pilot_local_builder_gate fresh || a=$?; _pilot_local_builder_note_spawn; b=0; _pilot_local_builder_gate cached || b=$?; echo "a=$a b=$b n=$_PLB_N"')
[ "$r" = "a=0 b=1 n=1" ] && [ "$(list_calls)" = 1 ] && ok "depois de UM spawn desta varredura o cached já diz cheio (n=1), sem reler o gc" || bad "o spawn não subiu a contagem da varredura: $r calls=$(list_calls)"
reset; roster
r=$(LBC_MAX=1 run_lb 'a=0; _pilot_local_builder_gate fresh || a=$?; _pilot_local_builder_note_spawn; b=0; _pilot_local_builder_gate fresh || b=$?; echo "a=$a b=$b"')
[ "$r" = "a=0 b=0" ] && [ "$(list_calls)" = 2 ] && ok "fresh NÃO confia no cache: relê o gc (2 leituras) e vê o que o gc mostra" || bad "fresh reaproveitou o cache: $r calls=$(list_calls)"
reset; roster
r=$(LBC_MAX=1 run_lb '_pilot_local_builder_note_spawn; echo "live=[$_PLB_LIVE]"')
[ "$r" = "live=[]" ] && ok "spawn antes de qualquer leitura: nada a subir, o cache segue vazio (a 1ª leitura já verá a sessão)" || bad "note_spawn inventou uma contagem: $r"

echo "── pulo pré-claim: só bead que ABRIRIA sessão local, teto positivamente cheio, nó sem querê-la"
reset; roster gastown.dog:active; touch "$WORK/bound.yes"
r=$(LBC_MAX=1 run_lb 'x=0; _pilot_local_builder_full_pre "{\"id\":\"ga-1\"}" || x=$?; echo "skip=$x"')
[ "$r" = "skip=0" ] && ok "presa a pool + teto cheio + nó não quer: PULA (rc 0)" || bad "não pulou a bead que esperaria o teto: $r"
r=$(LBC_MAX=1 run_lb 'x=0; _pilot_local_builder_full_pre "{}" || x=$?; echo "skip=$x"')
[ "$r" = "skip=0" ] && ok "a decisão é só do teto e do alvo: o JSON da bead é de quem chama" || bad "pré-claim leu o JSON: $r"
reset; roster gastown.dog:active; touch "$WORK/bound.yes" "$WORK/node.yes"
r=$(LBC_MAX=1 run_lb 'x=0; _pilot_local_builder_full_pre "{}" || x=$?; echo "skip=$x"')
[ "$r" = "skip=1" ] && ok "o nó quer a bead (oráculo node com vaga): NÃO pula — vai à claim e ao nó" || bad "pulou bead que o nó levaria: $r"
reset; roster gastown.dog:active
r=$(LBC_MAX=1 run_lb 'x=0; _pilot_local_builder_full_pre "{}" || x=$?; echo "skip=$x"')
[ "$r" = "skip=1" ] && ok "bead que o Pilot NÃO sabe presa a pool (1ª vez, pode ir a uma crew): não pula" || bad "pulou bead que talvez vá a uma crew: $r"
reset; roster; touch "$WORK/bound.yes"
r=$(LBC_MAX=1 run_lb 'x=0; _pilot_local_builder_full_pre "{}" || x=$?; echo "skip=$x"')
[ "$r" = "skip=1" ] && ok "teto com vaga: não pula" || bad "pulou com vaga no teto: $r"
reset; roster gastown.dog:active; touch "$WORK/bound.yes"
r=$(run_lb 'x=0; _pilot_local_builder_full_pre "{}" || x=$?; echo "skip=$x"')
[ "$r" = "skip=1" ] && [ "$(list_calls)" = 0 ] && ok "sem PILOT_LOCAL_BUILDER_MAX: nunca pula e nem lê as sessões" || bad "pulou com o teto desligado: $r calls=$(list_calls)"
reset; : > "$WORK/sl.fail"; touch "$WORK/bound.yes"
r=$(LBC_MAX=1 run_lb 'x=0; _pilot_local_builder_full_pre "{}" || x=$?; echo "skip=$x"')
[ "$r" = "skip=1" ] && ok "contagem que não leu: NÃO pula por palpite (o gate dos braços é que fecha, fail-closed)" || bad "pulou sem leitura positiva: $r"

echo "── bead genérica do HQ (sem rota, sem story.rig): só entra no pulo pré-claim depois de o braço do dog dizer 'cheio' nesta varredura"
hqg() { # $1 = JSON da bead -> rc de _pilot_local_builder_hq_generic
  run_lb 'x=0; _pilot_local_builder_hq_generic '"$(printf '%q' "$1")"' || x=$?; echo "hqg=$x"'
}
J_GEN='{"id":"ga-g1","title":"Ajustar o reconciliador de filas","description":"detalhe de infraestrutura","labels":["story:approved"],"metadata":{}}'
[ "$(hqg "$J_GEN")" = "hqg=0" ] && ok "ga-* sem rota, sem story.rig e texto sem domínio: é a genérica do HQ (vai ao dog)" || bad "a bead genérica do HQ não foi reconhecida"
[ "$(hqg '{"id":"ga-g2","title":"x","metadata":{"gc.routed_to":"gastown.dog"}}')" = "hqg=1" ] && ok "com rota: já é de quem a pré-claim de pool pega, não desta classe" || bad "bead com rota entrou na classe genérica"
[ "$(hqg '{"id":"ga-g3","title":"x","metadata":{"story.rig":"gascity"}}')" = "hqg=1" ] && ok "com story.rig: idem" || bad "bead com story.rig entrou na classe genérica"
[ "$(hqg '{"id":"wa-g4","title":"x","metadata":{}}')" = "hqg=1" ] && ok "prefixo que não é do HQ (wa-): fora" || bad "bead de outro store entrou na classe genérica"
[ "$(hqg '{"id":"ga-","title":"x","metadata":{}}')" = "hqg=1" ] && ok "id 'ga-' sem nada depois: fora" || bad "id vazio depois do prefixo entrou"
[ "$(hqg '{"id":"ga-g5","title":"Ajustar o painel do pipedrive","description":"kanban de leads","metadata":{}}')" = "hqg=1" ] && ok "o texto aponta o domínio do WA (painel, pipedrive): vai a crew, não ao dog — fora" || bad "bead de domínio entrou na classe genérica"
[ "$(hqg '{"title":"sem id","metadata":{}}')" = "hqg=1" ] && ok "sem id: fora" || bad "bead sem id entrou"
[ "$(hqg 'isto não é json')" = "hqg=1" ] && ok "JSON que o jq não lê: fora — nunca nasce de um palpite" || bad "JSON ilegível entrou na classe genérica"
reset; roster gastown.dog:active
r=$(LBC_MAX=1 run_lb 'x=0; _pilot_local_builder_full_pre '"$(printf '%q' "$J_GEN")"' || x=$?; echo "skip=$x"')
[ "$r" = "skip=1" ] && ok "genérica do HQ com o teto cheio, mas NENHUM braço de dog disse 'cheio' ainda: NÃO pula (a classe ainda não foi provada)" || bad "pulou a genérica antes de o braço provar a classe: $r"
reset; roster gastown.dog:active
r=$(LBC_MAX=1 run_lb '_PLB_DOG_FULL=1; x=0; _pilot_local_builder_full_pre '"$(printf '%q' "$J_GEN")"' || x=$?; echo "skip=$x"')
[ "$r" = "skip=0" ] && ok "depois de o braço do dog dizer 'cheio': a genérica do HQ é PULADA antes da claim (a 1ª pagou a claim, as outras não)" || bad "não pulou a genérica depois da prova do braço: $r"
reset; roster gastown.dog:active; touch "$WORK/node.yes"
r=$(LBC_MAX=1 run_lb '_PLB_DOG_FULL=1; x=0; _pilot_local_builder_full_pre '"$(printf '%q' "$J_GEN")"' || x=$?; echo "skip=$x"')
[ "$r" = "skip=1" ] && ok "...mas a que o nó quer continua indo à claim" || bad "pulou genérica que o nó levaria: $r"
reset; roster
r=$(LBC_MAX=1 run_lb '_PLB_DOG_FULL=1; x=0; _pilot_local_builder_full_pre '"$(printf '%q' "$J_GEN")"' || x=$?; echo "skip=$x"')
[ "$r" = "skip=1" ] && ok "...e com vaga no teto local não pula, mesmo com a bandeira" || bad "pulou a genérica com vaga no teto: $r"
reset; roster gastown.dog:active
r=$(LBC_MAX=1 run_lb '_PLB_DOG_FULL=0; DISPATCH_RESULT=""; _pilot_local_builder_arm ga-1 /city gastown.dog "a gastown.dog session" || true; echo "flag=$_PLB_DOG_FULL"')
[ "$r" = "flag=1" ] && ok "o braço do dog cheio levanta a bandeira da varredura" || bad "o braço do dog não levantou a bandeira: $r"
reset; roster gastown.dog:active
r=$(LBC_MAX=1 run_lb '_PLB_DOG_FULL=0; DISPATCH_RESULT=""; _pilot_local_builder_arm wa-1 /rig wa-worker-2 "a wa-worker session" || true; echo "flag=$_PLB_DOG_FULL"')
[ "$r" = "flag=0" ] && ok "o braço do wa-worker cheio NÃO levanta a bandeira do dog (a classe provada é a do sling ao dog)" || bad "o braço do wa-worker levantou a bandeira do dog: $r"

echo "── braço de dispatch_one (wa-worker, ps-worker, sling ao dog): fecha, enfileira ou não abre"
reset; roster
r=$(LBC_MAX=1 run_lb 'DISPATCH_RESULT=""; x=0; _pilot_local_builder_arm ga-1 /city gastown.dog "a gastown.dog session" || x=$?; echo "rc=$x res=[${DISPATCH_RESULT}]"')
[ "$r" = "rc=0 res=[]" ] && ! logged "RELEASE" && ok "cabe: rc 0, nada liberado, DISPATCH_RESULT intocado" || bad "o braço mexeu na bead com vaga: $r"
reset; roster gastown.dog:active
r=$(LBC_MAX=1 run_lb 'DISPATCH_RESULT=""; x=0; _pilot_local_builder_arm wa-1 /rig wa-worker-2 "a wa-worker session" || x=$?; echo "rc=$x res=[${DISPATCH_RESULT}]"')
[ "$r" = "rc=1 res=[local_builder_cap_queued]" ] && logged "RELEASE-QUEUED wa-1 /rig wa-worker-2" && logged "local builder cap hit (1/1" \
  && ok "cheio: rc 1, claim liberada COMO FILA (a mesma contabilidade do teto por pool), resultado local_builder_cap_queued, e o motivo no log" || bad "braço cheio errado: $r"
reset; roster; : > "$WORK/sl.fail"
r=$(LBC_MAX=1 run_lb 'DISPATCH_RESULT=""; x=0; _pilot_local_builder_arm wa-1 /rig wa-worker-2 "a wa-worker session" || x=$?; echo "rc=$x res=[${DISPATCH_RESULT}]"')
[ "$r" = "rc=1 res=[rig_native_pool_count_unreadable]" ] && logged "RELEASE-UNREADABLE wa-1 /rig wa-worker-2" && ! logged "RELEASE-QUEUED" \
  && ok "contagem ilegível: rc 1, liberada como FALHA (não como fila) e com o nome que o dispatch_lane já trata (para a fase de despacho)" || bad "braço ilegível errado: $r"
reset; roster gastown.dog:active
r=$(run_lb 'DISPATCH_RESULT=""; x=0; _pilot_local_builder_arm wa-1 /rig wa-worker-2 "a wa-worker session" || x=$?; echo "rc=$x res=[${DISPATCH_RESULT}]"')
[ "$r" = "rc=0 res=[]" ] && ok "sem PILOT_LOCAL_BUILDER_MAX o braço deixa passar" || bad "o braço barrou com o teto desligado: $r"

reset; roster
r=$(LBC_MAX=1 run_lb 'DISPATCH_RESULT=""; a=0; _pilot_local_builder_arm ga-1 /city gastown.dog "a gastown.dog session" || a=$?; _pilot_local_builder_note_spawn; b=0; _pilot_local_builder_arm ga-2 /city gastown.dog "a gastown.dog session" || b=$?; echo "a=$a b=$b res=[${DISPATCH_RESULT}]"')
[ "$r" = "a=0 b=1 res=[local_builder_cap_queued]" ] && [ "$(list_calls)" = 1 ] \
  && ok "o sling ao dog da própria varredura conta: a 1ª cabe, depois do spawn a 2ª é fila — com o gc ainda mostrando 0 (o controller só cria o dog depois do sling) e UMA leitura de sessões" || bad "dois slings ao dog na mesma varredura passaram o teto 1: $r calls=$(list_calls)"

echo "── top-up de pool: respeita o teto e recontaa depois de cada spawn"
run_topup() { # $1 = teto local (vazio = sem teto) · $2 = max do pool · $3.. = pools
  local _lmax="$1" _max="$2"; shift 2
  (
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    GC_CITY="test-city"; DRY_RUN=0; GC_VARIABLE_SESSION_MAX=9
    PILOT_DOLT_SATURATED_AT_START=0; PILOT_SPAWN_TIMEOUT_SECS=5; PILOT_TOPUP_RETRY_DELAY_SECS=0; PILOT_SESSION_LIST_TIMEOUT_SECS=5
    PILOT_TEST_WA_WORKER_TOPUP_PENDING="wa-pend1"; PILOT_TEST_PS_WORKER_TOPUP_PENDING="ps-pend1"
    unset GC_VARIABLE_SESSION_COUNT_OVERRIDE PILOT_TEST_WA_WORKER_LIVE_COUNT PILOT_TEST_PS_WORKER_LIVE_COUNT PILOT_TEST_LOCAL_BUILDER_COUNT PILOT_LOCAL_BUILDER_MAX
    if [ -n "$_lmax" ]; then PILOT_LOCAL_BUILDER_MAX="$_lmax"; export PILOT_LOCAL_BUILDER_MAX; fi
    log()  { echo "LOG $*" >> "$WORK/lines.txt"; }
    warn() { echo "WARN $*" >> "$WORK/lines.txt"; }
    eval "$PLB_INIT"
    for _f in "$FUNC_JSON" "$FUNC_LIVE" "$FUNC_MAX" "$FUNC_GATE" "$FUNC_NOTE" "$FUNC_VSC" "$FUNC_GVSC" "$FUNC_SLOW" "$FUNC_TIMING" "$FUNC_TOPSPAWN" "$FUNC_TOPUP"; do eval "$_f"; done
    # o bind real tira a bead claimada da consulta: a próxima "pendente" é OUTRA bead (sem isto o freio ga-qnarixf de "uma sessão por bead por passada" para o laço sozinho)
    _PN=1
    _topup_bind_after_spawn() { _PN=$((_PN + 1)); PILOT_TEST_WA_WORKER_TOPUP_PENDING="wa-pend$_PN"; PILOT_TEST_PS_WORKER_TOPUP_PENDING="ps-pend$_PN"; return 0; }
    local _p
    for _p in "$@"; do _pilot_pool_topup "$_p" "$_max"; done
    echo "END" >> "$WORK/lines.txt"
  ) >/dev/null 2>&1
}
reset; roster gastown.dog:active
run_topup 1 2 wa-worker
[ "$(spawns)" = 0 ] && logged "local builder" && ok "1 dog vivo e teto local 1: o top-up NÃO abre o wa-worker (o pool tem vaga, o mini não) e diz por quê" || bad "top-up abriu sessão com o teto local cheio ($(spawns) spawns)"
reset; roster
run_topup 1 2 wa-worker
[ "$(spawns)" = 1 ] && ok "controle: roster vazio e teto 1: o top-up abre UMA (o harness chega ao spawn)" || bad "controle do top-up: esperava 1 spawn, deu $(spawns)"
reset; roster
run_topup 1 2 wa-worker ps-worker
[ "$(spawns)" = 1 ] && ok "dois pools, teto 1: o 1º spawn enche o teto e o 2º pool NÃO abre (a contagem é recontada entre os pools)" || bad "o 2º pool abriu sobre o teto já cheio ($(spawns) spawns)"
reset; roster
run_topup 2 2 wa-worker ps-worker
[ "$(spawns)" = 2 ] && ok "dois pools, teto 2: abrem os dois" || bad "teto 2 deveria deixar abrir os dois, abriu $(spawns)"
reset; roster
run_topup 1 3 wa-worker
[ "$(spawns)" = 1 ] && ok "UM pool com 3 vagas e beads de sobra, teto local 1: o laço abre UMA e para (a 2ª bead pendente não ganha sessão)" || bad "o laço do top-up passou o teto local: $(spawns) spawns com teto 1"
reset; roster
run_topup 3 3 wa-worker
[ "$(spawns)" = 3 ] && ok "controle: o mesmo pool com teto local 3 abre as 3 (a bead pendente muda a cada spawn, o laço roda)" || bad "controle do laço do top-up: esperava 3 spawns com teto 3, deu $(spawns)"
reset; roster gastown.dog:active
run_topup "" 2 wa-worker
[ "$(spawns)" = 2 ] && ok "sem PILOT_LOCAL_BUILDER_MAX: o top-up é o de antes (enche o pool de 2 mesmo com um dog vivo)" || bad "sem teto o top-up barrou ($(spawns) spawns, esperava 2)"
reset; roster; : > "$WORK/sl.fail"
run_topup 1 2 wa-worker
[ "$(spawns)" = 0 ] && ok "sessões que não se leem: nenhum spawn (já era assim: fail-closed do teto por pool)" || bad "top-up abriu sem leitura ($(spawns) spawns)"

echo "── empréstimo ao dog (dog-lend): vaga de dog E vaga local"
run_lend() { # $1 = teto local · $2 = PILOT_DOG_LEND_DOG_MAX · $3 = emprestadas nesta varredura
  local _lmax="$1" _dmax="$2" _lent="$3"
  LBC_MAX="$_lmax" run_lb 'PILOT_DOG_LEND_DOG_MAX="'"$_dmax"'"; _PDL_LENT='"$_lent"'; _PDL_WHY=""; _PDL_DOG_LIVE=""
    x=0; _pilot_dog_lend_dog_free || x=$?; echo "rc=$x why=[${_PDL_WHY}]"'
}
reset; roster
r=$(run_lend 1 3 0)
[ "$r" = "rc=0 why=[]" ] && ok "0 vivos, teto local 1, vaga de dog 3: há vaga" || bad "empréstimo sem vaga com tudo livre: $r"
reset; roster wa-worker:active
r=$(run_lend 1 3 0)
case "$r" in "rc=1 why=[no-free-local-builder"*) ok "1 wa-worker vivo, teto local 1: sem vaga (o dog emprestado seria o 2º construtor local) — $r" ;; *) bad "o empréstimo ignorou o teto local: $r" ;; esac
reset; roster
r=$(run_lend 1 3 1)
case "$r" in "rc=1 why=[no-free-local-builder"*) ok "0 vivos mas 1 emprestado nesta varredura: sem vaga (o que a varredura já emprestou conta)" ;; *) bad "o empréstimo da varredura não contou no teto local: $r" ;; esac
reset; roster wa-worker:active
r=$(run_lend "" 3 0)
[ "$r" = "rc=0 why=[]" ] && ok "sem teto local: o empréstimo é o de antes (vaga de dog 3 de 6)" || bad "sem teto local o empréstimo mudou: $r"
reset; roster; : > "$WORK/sl.fail"
r=$(run_lend 1 3 0)
case "$r" in "rc=2 why=[dog-count-unreadable]"*) ok "sessões que não se leem: rc 2 (já era assim)" ;; *) bad "leitura ilegível do empréstimo mudou: $r" ;; esac

echo "── os pontos de ligação no dispatcher (existem, na ordem certa)"
L_MAXVAR=$(grep -n '^_pilot_local_builder_max()' "$DISPATCHER" | head -1 | cut -d: -f1)
L_COUNTFN=$(grep -n '^_pilot_live_session_count()' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_MAXVAR" ] && [ -n "$L_COUNTFN" ] && [ "$L_COUNTFN" -lt "$L_MAXVAR" ] && ok "o gate é definido DEPOIS do leitor de sessões vivas que ele chama (linhas $L_COUNTFN < $L_MAXVAR)" || bad "ordem das definições errada"
L_POOLCAP=$(grep -n 'if \[ "\$_mbp_pass" != 1 \] && _pilot_pool_cap_full_for "\$pick"; then' "$DISPATCHER" | head -1 | cut -d: -f1)
L_LBPRE=$(grep -n 'if \[ "\$_mbp_pass" != 1 \] && _pilot_local_builder_full_pre "\$pick"; then' "$DISPATCHER" | head -1 | cut -d: -f1)
L_UNREAD=$(grep -n 'if \[ "\$_mbp_pass" != 1 \] && \[ -n "\${_PCAP_COUNT_UNREADABLE:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_POOLCAP" ] && [ -n "$L_LBPRE" ] && [ -n "$L_UNREAD" ] && [ "$L_POOLCAP" -lt "$L_LBPRE" ] && [ "$L_LBPRE" -lt "$L_UNREAD" ] \
  && ok "dispatch_lane: pulo pré-claim do teto local (linha $L_LBPRE) DEPOIS do teto por pool ($L_POOLCAP) e ANTES da parada por contagem ilegível ($L_UNREAD)" || bad "dispatch_lane: pulo pré-claim ausente ou fora de ordem (pool=$L_POOLCAP local=$L_LBPRE unread=$L_UNREAD)"
sed -n "$L_LBPRE,$((L_LBPRE+12))p" "$DISPATCHER" | grep -q '_pilot_sweep_note "\$pick_id" 1 "local_builder_cap_queued"' \
  && sed -n "$L_LBPRE,$((L_LBPRE+12))p" "$DISPATCHER" | grep -q '_pilot_note_pool_cap_queued "\$pick_id"' \
  && ok "o pulo pré-claim anota a fila de capacidade (saturação, não parada) e o resultado local_builder_cap_queued, sem escrever na bead" || bad "o pulo pré-claim não anota a fila ou o resultado"
N_ARMS=$(grep -c '_pilot_local_builder_arm "\$STORY_ID" "\$STORY_BEAD_CITY"' "$DISPATCHER")
[ "$N_ARMS" = 3 ] && ok "dispatch_one chama o braço 3 vezes (wa-worker, ps-worker e sling ao dog)" || bad "esperava 3 chamadas do braço em dispatch_one, achei $N_ARMS"
L_WA_ARM=$(grep -n '_pilot_local_builder_arm "\$STORY_ID" "\$STORY_BEAD_CITY" "\$BUILDER_TARGET" "a wa-worker session"' "$DISPATCHER" | head -1 | cut -d: -f1)
L_WA_GLOBAL=$(grep -n 'if \[ "\${_gc_variable_count:-0}" -ge "\$GC_VARIABLE_SESSION_MAX" \] 2>/dev/null; then' "$DISPATCHER" | head -1 | cut -d: -f1)
L_WA_POOL=$(grep -n 'if \[ "\${_live_wa_count:-0}" -ge "\${PILOT_WA_WORKER_MAX:-4}" \] 2>/dev/null; then' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_WA_ARM" ] && [ -n "$L_WA_GLOBAL" ] && [ -n "$L_WA_POOL" ] && [ "$L_WA_GLOBAL" -lt "$L_WA_ARM" ] && [ "$L_WA_ARM" -lt "$L_WA_POOL" ] \
  && ok "wa-worker: teto local (linha $L_WA_ARM) entre o teto global ($L_WA_GLOBAL) e o do pool ($L_WA_POOL)" || bad "wa-worker: braço do teto local ausente ou fora de ordem (global=$L_WA_GLOBAL local=$L_WA_ARM pool=$L_WA_POOL)"
L_PS_ARM=$(grep -n '_pilot_local_builder_arm "\$STORY_ID" "\$STORY_BEAD_CITY" "\$BUILDER_TARGET" "a ps-worker session"' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_PS_ARM" ] && [ "$L_PS_ARM" -gt "$L_WA_POOL" ] && ok "ps-worker: o braço do teto local existe, depois do do wa-worker (linha $L_PS_ARM)" || bad "ps-worker: braço do teto local ausente"
L_DOG_ARM=$(grep -n '_pilot_local_builder_arm "\$STORY_ID" "\$STORY_BEAD_CITY" "\$BUILDER_TARGET" "a gastown.dog session"' "$DISPATCHER" | head -1 | cut -d: -f1)
L_DOG_NODE=$(grep -n '\[ "\${_PNY_EXEMPT_THIS:-0}" = "1" \] && \[ "\${_PNF_RESULT:-}" != "node" \]' "$DISPATCHER" | head -1 | cut -d: -f1)
L_DOG_SLING=$(grep -n 'Dispatch via gc sling (HQ beads)' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_DOG_ARM" ] && [ "$L_DOG_NODE" -lt "$L_DOG_ARM" ] && [ "$L_DOG_ARM" -lt "$L_DOG_SLING" ] \
  && ok "sling ao dog: o teto local (linha $L_DOG_ARM) vem DEPOIS de o nó ter tido a bead ($L_DOG_NODE) e ANTES do sling ao mini ($L_DOG_SLING)" || bad "sling ao dog: braço ausente ou fora de ordem (nó=$L_DOG_NODE local=$L_DOG_ARM sling=$L_DOG_SLING)"
sed -n "$((L_DOG_ARM-3)),$((L_DOG_ARM+1))p" "$DISPATCHER" | grep -q '"\$DRY_RUN" != "1"' \
  && sed -n "$((L_DOG_ARM-3)),$((L_DOG_ARM+1))p" "$DISPATCHER" | grep -q '"\${_PNF_RESULT:-}" != "node"' \
  && sed -n "$((L_DOG_ARM-3)),$((L_DOG_ARM+1))p" "$DISPATCHER" | grep -q '"\$_IS_RIG_NATIVE" != "1"' \
  && ok "o braço do dog só vale fora do DRY_RUN, para bead do HQ e quando o nó NÃO ficou com ela" || bad "o braço do dog não fecha DRY_RUN / rig-native / nó"
N_NOTE=$(grep -v '^[[:space:]]*#' "$DISPATCHER" | grep -v '^_pilot_local_builder_note_spawn()' | grep -c '_pilot_local_builder_note_spawn')
[ "$N_NOTE" -ge 4 ] && ok "o spawn sobe a contagem da varredura nos 4 pontos que abrem sessão (wa-worker, ps-worker, top-up, sling ao dog): $N_NOTE chamadas" || bad "só $N_NOTE chamadas de _pilot_local_builder_note_spawn (esperava >= 4)"
L_TOP_GATE=$(grep -n 'top-up gate — local builder cap' "$DISPATCHER" | head -1 | cut -d: -f1)
L_TOP_WHILE=$(grep -n 'while \[ "\$_live" -lt "\$_max" \] && \[ "\$_global" -lt "\$GC_VARIABLE_SESSION_MAX" \]; do' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_TOP_GATE" ] && [ -n "$L_TOP_WHILE" ] && [ "$L_TOP_GATE" -lt "$L_TOP_WHILE" ] && ok "top-up: o teto local é consultado antes do laço (linha $L_TOP_GATE < $L_TOP_WHILE), e a linha do laço ficou intacta" || bad "top-up: portão do teto local ausente ou depois do laço"
grep -q '"local_builder_cap_queued"' <(sed -n "$(grep -n '^_pilot_sweep_emit()' "$DISPATCHER" | head -1 | cut -d: -f1),+30p" "$DISPATCHER") \
  && ok "_pilot_sweep_emit classifica local_builder_cap_queued (fila de capacidade, não falha)" || bad "_pilot_sweep_emit não classifica local_builder_cap_queued — cairia em failed_other"

if [ -z "${LBC_MUTANT:-}" ] && [ -z "${LBC_NO_MUTANTS:-}" ]; then
  echo "── controle negativo: cada guarda desligada numa cópia do dispatcher tem que reprovar este arquivo"
  nm=0
  mutant() {
    nm=$((nm+1)); local m="$WORK/disp.mut$nm.sh"
    python3 -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
if s.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$DISPATCHER" "$2" "$3" "$m" 2>/dev/null \
      || { bad "mutante '$1': a âncora não casa exatamente 1 vez"; return; }
    local r; r=$(LBC_MUTANT=1 PILOT_DISPATCHER_PATH="$m" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) bad "mutante '$1' NÃO foi pego ($r)" ;; "RESULT "*) ok "mutante '$1' pego ($r)" ;; *) bad "mutante '$1': sem resultado ($r)" ;; esac
  }
  # Cada mutante desliga UMA guarda; o arquivo (em LBC_MUTANT=1) reprova no primeiro ✗. Âncora que não casa exatamente 1 vez no dispatcher reprova o próprio mutante.
  mutant "a contagem só vê o wa-worker" '  elif _pilot_live_session_count wa-worker ps-worker gastown.dog; then' '  elif _pilot_live_session_count wa-worker; then'
  mutant "a contagem soma sessões do nó" '  elif _pilot_live_session_count wa-worker ps-worker gastown.dog; then' '  elif _pilot_live_session_count wa-worker ps-worker gastown.dog dog-remote wa-worker-remote ps-worker-remote; then'
  mutant "contagem que falha lê como cabe" $'  else\n    return 2\n  fi\n  case "$_n" in' $'  else\n    return 0\n  fi\n  case "$_n" in'
  mutant "valor ilegível desliga o teto" $'    *[!0-9]*|????*) printf \'1\' ;;' $'    *[!0-9]*|????*) : ;;'
  mutant "cheio só com contagem maior que o teto" '  [ "$_n" -lt "$_PLB_MAX" ] && return 0' '  [ "$_n" -le "$_PLB_MAX" ] && return 0'
  mutant "cached não usa o número da varredura" '  elif [ "$_mode" = "cached" ] && [ -n "${_PLB_LIVE:-}" ]; then' '  elif false; then'
  mutant "o spawn não sobe o número da varredura" '  case "${_PLB_LIVE:-}" in '"''"'|*[!0-9]*) ;; *) _PLB_LIVE=$(( _PLB_LIVE + 1 )) ;; esac' '  :'
  mutant "pré-claim pula bead que talvez vá a uma crew" $'  if ! _pilot_priority_pool_bound_pre "$_b"; then\n    [ "${_PLB_DOG_FULL:-0}" = 1 ] || return 1\n    _pilot_local_builder_hq_generic "$_b" || return 1\n  fi' '  :'
  mutant "pré-claim ignora o nó" '  if _pilot_priority_node_exempt_pre "$_b"; then return 1; fi' '  :'
  mutant "pré-claim pula por contagem que não leu" $'  [ "$_rc" = 1 ] || return 1\n  if _pilot_priority_node_exempt_pre' $'  [ "$_rc" != 0 ] || return 1\n  if _pilot_priority_node_exempt_pre'
  mutant "braço: contagem ilegível sai como fila" $'       _pilot_release_count_unreadable "$_id" "$_city" "$_bt"\n       DISPATCH_RESULT="rig_native_pool_count_unreadable"' $'       _pilot_release_count_unreadable "$_id" "$_city" "$_bt"\n       DISPATCH_RESULT="local_builder_cap_queued"'
  mutant "braço: cheio não conta como fila de capacidade" '       _pilot_release_pool_cap_queued "$_id" "$_city" "$_bt"' '       _pilot_release_count_unreadable "$_id" "$_city" "$_bt"'
  mutant "braço: cheio deixa abrir" $'       case "$_bt" in gastown.dog|gastown.dog-*) _PLB_DOG_FULL=1 ;; esac\n       return 1 ;;\n  esac' $'       case "$_bt" in gastown.dog|gastown.dog-*) _PLB_DOG_FULL=1 ;; esac\n       return 0 ;;\n  esac'
  mutant "top-up ignora o teto antes do laço" '  elif [ "$_PLB_RC" = 1 ]; then' '  elif false; then'
  mutant "top-up não para quando o spawn enche o teto" '      [ "$_PLB_RC" = 0 ] || break' '      :'
  mutant "empréstimo ignora o teto local" '    if [ -z "${_PLB_MAX:-}" ] || [ $(( _PLB_N + ${_PDL_LENT:-0} )) -lt "$_PLB_MAX" ]; then return 0; fi' '    return 0'
  mutant "empréstimo não conta o que a varredura emprestou" '[ $(( _PLB_N + ${_PDL_LENT:-0} )) -lt "$_PLB_MAX" ]; then return 0; fi' '[ "$_PLB_N" -lt "$_PLB_MAX" ]; then return 0; fi'
  mutant "sem o pulo pré-claim em dispatch_lane" 'if [ "$_mbp_pass" != 1 ] && _pilot_local_builder_full_pre "$pick"; then' 'if false; then'
  mutant "o braço do dog roda no DRY_RUN" $'      if [ "$DRY_RUN" != "1" ] && [ "$_IS_RIG_NATIVE" != "1" ] && [ "${_PNF_RESULT:-}" != "node" ] \\' $'      if [ "$_IS_RIG_NATIVE" != "1" ] && [ "${_PNF_RESULT:-}" != "node" ] \\'
  mutant "o sling ao dog não sobe o número da varredura" '    case "$_SLING_TARGET" in gastown.dog|gastown.dog-*) _pilot_local_builder_note_spawn ;; esac' '    :'
  mutant "a genérica pula sem o braço do dog ter provado a classe" $'    [ "${_PLB_DOG_FULL:-0}" = 1 ] || return 1\n    _pilot_local_builder_hq_generic "$_b" || return 1' $'    _pilot_local_builder_hq_generic "$_b" || return 1'
  mutant "a genérica aceita bead com rota ou story.rig" '  [ -z "$_rt" ] && [ -z "$_rig" ] || return 1' '  :'
  mutant "a genérica ignora o domínio do texto" '  [ -z "$(bead_content_rig "$_b")" ]' '  true'
  mutant "a genérica aceita qualquer prefixo" '  case "$_id" in ga-?*) ;; *) return 1 ;; esac' '  case "$_id" in *) ;; esac'
  mutant "o braço do dog não levanta a bandeira" '       case "$_bt" in gastown.dog|gastown.dog-*) _PLB_DOG_FULL=1 ;; esac' '       :'
  mutant "o braço do wa-worker levanta a bandeira do dog" '       case "$_bt" in gastown.dog|gastown.dog-*) _PLB_DOG_FULL=1 ;; esac' '       _PLB_DOG_FULL=1'
  mutant "a fila local cai em failed_other" 'elif $o.r == "rig_native_global_session_cap_queued" or $o.r == "local_builder_cap_queued" then "queued_global_cap"' 'elif $o.r == "rig_native_global_session_cap_queued" then "queued_global_cap"'
fi
echo "── $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
