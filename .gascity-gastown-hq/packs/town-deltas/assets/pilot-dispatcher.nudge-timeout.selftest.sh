#!/usr/bin/env bash
# pilot-dispatcher.nudge-timeout.selftest.sh — ga-2hd02v.3.24 (o prazo do aviso à sessão deixa de ser 15 s fixo)
#
# O Pilot entrega a bead a uma sessão com `gc session nudge` (e, no REUSE de crew, `gc session submit`), sob `timeout`. Eram 15 s fixos; com o mini a load ~70 o nudge leva ~40 s
# (medido 30/10: 'gc session nudge wa-worker-remote-3' = 40,7 s) → rc=124 → "o aviso falhou" → o desfazer devolvia a bead ao mini (13x em 30/10; o Hetzner ficou com 1-2 workers e 7 vagas).
# Agora o prazo é PILOT_NODE_NUDGE_TIMEOUT (padrão 60). Este arquivo prova o prazo em TODOS os pontos de aviso, não só no citado.
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# O QUE PROVA: (1) a linha de configuração: sem a variável ou vazia = 60; inteiro de 1 a 9999 passa como veio; ilegível (letras, negativo, decimal, com sufixo, com espaço, mais de 4 dígitos) e "0"
#   (no `timeout`, 0 é SEM prazo e penduraria a passada) caem em 60 — nunca em 0, nunca em "sem prazo" · (2) nenhum `gc --city "$GC_CITY" session nudge|submit` do dispatcher ficou com prazo fixo
#   ou sem prazo: todos leem `${PILOT_NODE_NUDGE_TIMEOUT:-60}`, e há pelo menos 6 (a varredura não pode passar vazia) · (3) cada um dos 6 pontos, executado VERBATIM contra um `gc` falso que
#   demora 3 s: com prazo 1 o aviso é cortado (a variável é honrada), com prazo 9 chega · (4) o critério da bead (ga-2hd02v.3.24), por `_pilot_node_first_dispatch` de verdade: com o padrão
#   (variável ausente → linha de configuração) um nudge de 20 s CHEGA e a bead vai ao nó; com o prazo 15 (o valor antigo) o mesmo nudge estoura (rc=124), o despacho é desfeito e a bead
#   volta ao mini aberta e sem dono; valor ilegível ("abc") não quebra o aviso (vale 60), em vez de virar `timeout abc` (rc=125 em todo aviso) · (5) cada ponto, com o padrão e um nudge de 20 s, chega.
#   `session wake` (16390, REUSE de crew) fica de fora de propósito: a falha dele é não-fatal e o submit seguinte acorda a sessão.
# COMO RODA: as funções saem VERBATIM do dispatcher (awk) e rodam num shell filho sob `set -euo pipefail`, com `gc` e `bd` FALSOS num PATH sem os reais (selftest-sandbox-path.lib.sh). As
#   rodadas lentas correm em paralelo, cada uma na sua pasta (NT_RUN): ~25 s no total. Contra um dispatcher sem a linha de configuração o arquivo se recusa a começar (exit 2) — o vermelho honesto.
# CONTROLE NEGATIVO: um ponto de aviso de volta a `timeout 15` · o submit do REUSE de volta a 15 · um ponto que ignora a variável · padrão 10 · sem a validação · zero aceito · letras aceitas · mais de
#   4 dígitos aceito, cada um numa cópia do dispatcher.
# Variáveis: PILOT_DISPATCHER_PATH · NT_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${NT_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${NT_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
# a linha de configuração e o `case` que a valida, VERBATIM — sem eles o arquivo se recusa a começar (ga-2hd02v.3.24 não aplicado)
CFG_LINE="$(grep -E '^PILOT_NODE_NUDGE_TIMEOUT="' "$DISPATCHER" | head -1)"
CFG_CASE="$(grep -E '^case "\$PILOT_NODE_NUDGE_TIMEOUT" in' "$DISPATCHER" | head -1)"
[ -n "$CFG_LINE" ] && [ -n "$CFG_CASE" ] || { echo "FATAL: PILOT_NODE_NUDGE_TIMEOUT config lines not found in $DISPATCHER (ga-2hd02v.3.24 not applied)" >&2; exit 2; }
FUNCS=""
for f in gc_json_or_unknown _pilot_slow_spawn_budget_spent _pilot_note_spawn_timing _pilot_node_pick_alias _pilot_node_first_rollback _pilot_node_first_dispatch; do
  src="$(fn_src "$f")"
  [ -n "$src" ] || { echo "FATAL: $f() not found in $DISPATCHER (ga-2hd02v.1.14 not applied)" >&2; exit 2; }
  FUNCS="$FUNCS
$src"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-nudgetimeout-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# gc FALSO: `gc --city C session <sub> ...`. Cada rodada tem a sua pasta ($NT_RUN). list → sessions.json; new|wake|close → ok; nudge|submit → registra "started", DORME nudge.sleep s e só então
# registra "delivered" (um `timeout` que mata o processo antes impede o "delivered": é assim que o corte aparece).
cat > "$WORK/bin/gc" <<'EOF'
#!/bin/sh
D="${NT_RUN:?}"
echo "gc $*" >> "$D/calls.log"
[ "$1" = "--city" ] && [ "$3" = "session" ] || exit 99
case "$4" in
  list) if [ -f "$D/sessions.json" ]; then cat "$D/sessions.json"; else echo '{"sessions":[]}'; fi; exit 0 ;;
  new|wake|close) exit 0 ;;
  nudge|submit) echo started >> "$D/nudge.started"; sleep "$(cat "$D/nudge.sleep" 2>/dev/null || echo 0)"; echo delivered >> "$D/nudge.delivered"; exit 0 ;;
esac
exit 98
EOF
# bd FALSO: um repositório de UMA bead (assignee/status em arquivo). Honra --if-assignee (exit 13 se o dono não é o esperado).
cat > "$WORK/bin/bd" <<'EOF'
#!/bin/sh
D="${NT_RUN:?}"
echo "bd $*" >> "$D/calls.log"
[ "$1" = "-C" ] || exit 99
cur() { if [ -f "$D/bead.assignee" ]; then cat "$D/bead.assignee"; fi; }
case "$3" in
  update)
    shift 4; have_a=0; a_new=""; st=""; have_ifa=0; ifa=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --assignee) have_a=1; a_new="$2"; shift 2 ;;
        --status) st="$2"; shift 2 ;;
        --if-assignee) have_ifa=1; ifa="$2"; shift 2 ;;
        --set-metadata|--unset-metadata) shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$have_ifa" = 1 ] && [ "$(cur)" != "$ifa" ]; then exit 13; fi
    if [ "$have_a" = 1 ]; then printf '%s' "$a_new" > "$D/bead.assignee"; if [ -n "$st" ]; then printf '%s' "$st" > "$D/bead.status"; fi; fi
    exit 0 ;;
  show) s=open; [ ! -f "$D/bead.status" ] || s=$(cat "$D/bead.status")
        printf '[{"id":"%s","assignee":"%s","status":"%s"}]\n' "$4" "$(cur)" "$s"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/gc" "$WORK/bin/bd"
sandbox_path_init "$WORK" jq date timeout mkdir dirname cat sleep || exit 2

# ── (1) a linha de configuração ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# cfg <valor|@unset> — o que PILOT_NODE_NUDGE_TIMEOUT vale depois das duas linhas do dispatcher, sob `set -euo pipefail`. Se a linha abortar, o valor impresso não é um número e o caso reprova.
cfg() {
  ( set -euo pipefail
    if [ "$1" = "@unset" ]; then unset PILOT_NODE_NUDGE_TIMEOUT; else PILOT_NODE_NUDGE_TIMEOUT="$1"; fi
    eval "$CFG_LINE"; eval "$CFG_CASE"
    printf '%s' "$PILOT_NODE_NUDGE_TIMEOUT" ) 2>&1
}
echo "── a linha de configuração: padrão 60; ilegível e zero caem em 60"
for pair in "@unset=60" "=60" "60=60" "90=90" "1=1" "9999=9999" "abc=60" "0=60" "00=60" "0000=60" "-5=60" "1.5=60" "15s=60" "12345=60" "99999999999999999999=60" " 20=60" "20 =60"; do
  v="${pair%=*}"; want="${pair##*=}"; got="$(cfg "$v")"
  [ "$got" = "$want" ] && ok "'$v' → $want" || bad "'$v' deu '$got', esperava $want"
done
case "$CFG_LINE" in *':-60}"'*) ok "a linha de configuração diz :-60" ;; *) bad "o padrão da linha de configuração não é 60: $CFG_LINE" ;; esac

# ── (2) nenhum ponto de aviso ficou com prazo fixo ou sem prazo ───────────────────────────────────────────────────────────────────────────────────────────────────
echo "── todos os pontos de aviso leem a variável"
# vazio → lista vazia e o teste reprova (a varredura não pode passar vazia); falhou → idem
SITES="$(grep -nE 'gc --city "\$GC_CITY" session (nudge|submit) ' "$DISPATCHER" | grep -vE '^[0-9]+:[[:space:]]*#')"
NSITES=$(printf '%s\n' "$SITES" | grep -c . || true)
[ "$NSITES" -ge 6 ] && ok "achei $NSITES pontos de aviso (nudge/submit) no dispatcher" || bad "só achei $NSITES pontos de aviso — a varredura está cega ou um ponto sumiu"
BADSITES="$(printf '%s\n' "$SITES" | grep -vE 'timeout "\$\{PILOT_NODE_NUDGE_TIMEOUT:-60\}" gc --city' | grep . || true)"
[ -z "$BADSITES" ] && ok "todos os $NSITES usam timeout \"\${PILOT_NODE_NUDGE_TIMEOUT:-60}\"" || bad "ponto(s) de aviso sem a variável: $(printf '%s' "$BADSITES" | cut -c1-110 | tr '\n' '|')"

# ── (3) cada ponto, executado VERBATIM ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# site_stmt <nº da linha> — o comando inteiro a partir da linha (continua enquanto a linha termina em barra invertida)
site_stmt() { awk -v n="$1" 'NR==n{f=1} f{print} f&&!/\\$/{exit}' "$DISPATCHER"; }
# run_site <tag> <nº da linha> <valor|@unset> <sleep> — o comando do ponto contra o gc falso; resultado em $WORK/run.<tag>
run_site() {
  local run="$WORK/run.$1" stmt; mkdir -p "$run/city"; printf '%s' "$4" > "$run/nudge.sleep"; stmt="$(site_stmt "$2")"
  (
    PATH="$SANDBOX_PATH"; NT_RUN="$run"; export NT_RUN
    if [ "$3" = "@unset" ]; then unset PILOT_NODE_NUDGE_TIMEOUT; else PILOT_NODE_NUDGE_TIMEOUT="$3"; export PILOT_NODE_NUDGE_TIMEOUT; fi
    warn() { echo warn >> "$run/warn"; }; log() { :; }
    _pilot_unsuppress_sling() { echo unsup >> "$run/unsup"; }
    GC_CITY="$run/city"; _SLING_TARGET=crew; DISPATCH_TASK=tarefa; _DISPATCH_SESS_REF=ref; SLING_BEAD_ID=b-1
    _nd_alias=a; _nd_msg=m; _nd_rc=0; _kd_alias=a; _kd_msg=m; _kd_rc=0; _ro_alias=a; _ro_msg=m; _ro_rc=0
    eval "$stmt"
  ) > "$run/out" 2>&1
}
# site_state <tag> — delivered (o aviso chegou) | dropped (o gc falso começou e o prazo o cortou) | no-call (o gc falso nem foi chamado: o ponto quebrou antes)
site_state() {
  local r="$WORK/run.$1"
  if [ -f "$r/nudge.delivered" ]; then echo delivered; elif [ -f "$r/nudge.started" ]; then echo dropped; else echo no-call; fi
}
SITE_LINES="$(printf '%s\n' "$SITES" | cut -d: -f1)"

echo "── cada ponto honra a variável (gc falso de 3 s: prazo 1 corta, prazo 9 entrega)"
for ln in $SITE_LINES; do
  run_site "s$ln.tight" "$ln" 1 3 &
  run_site "s$ln.loose" "$ln" 9 3 &
done
wait
for ln in $SITE_LINES; do
  t="$(site_state "s$ln.tight")"; l="$(site_state "s$ln.loose")"
  [ "$t" = dropped ] && [ "$l" = delivered ] && ok "linha $ln: prazo 1 → cortado, prazo 9 → entregue" || bad "linha $ln: prazo 1 → $t (esperava dropped), prazo 9 → $l (esperava delivered) — $(head -c 200 "$WORK/run.s$ln.tight/out" 2>/dev/null | tr '\n' ' ')"
done

# ── (4)+(5) o critério da bead, por _pilot_node_first_dispatch de verdade, e o padrão em cada ponto ─────────────────────────────────────────────────────────────────
# run_dispatch <tag> <valor|@unset> <sleep> — uma chamada de _pilot_node_first_dispatch com o aviso demorando <sleep> s; resultado em $WORK/run.<tag>/out
run_dispatch() {
  local run="$WORK/run.$1"; mkdir -p "$run/city"; echo '{"sessions":[]}' > "$run/sessions.json"; echo open > "$run/bead.status"; printf '%s' "$3" > "$run/nudge.sleep"
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; NT_RUN="$run"; export NT_RUN
    log()  { echo "LOG $*" >> "$run/lines.txt"; }
    warn() { echo "WARN $*" >> "$run/lines.txt"; }
    GC_CITY="$run/city"; PILOT_SPAWN_TIMEOUT_SECS=20; _PILOT_SLOW_SPAWN_SEEN=0
    if [ "$2" = "@unset" ]; then unset PILOT_NODE_NUDGE_TIMEOUT; else PILOT_NODE_NUDGE_TIMEOUT="$2"; fi
    eval "$CFG_LINE"; eval "$CFG_CASE"
    eval "$FUNCS"
    # BARE: a função devolve 0 sempre; um comando que aborta sob errexit derruba este filho e a saída fica sem "res=".
    _pilot_node_first_dispatch "story-1" "$run/city" "Título da bead" 3
    echo "res=${_PNF_RESULT-?} alias=${_PNF_ALIAS-?}"
  ) > "$run/out" 2>&1
}
echo "── o aviso demora 20 s: com o padrão chega; com 15 (o valor antigo) a bead volta ao mini"
run_dispatch dflt @unset 20 &
run_dispatch old15 15 20 &
run_dispatch junk abc 20 &
for ln in $SITE_LINES; do run_site "s$ln.dflt" "$ln" @unset 20 & done
wait
r="$(tail -1 "$WORK/run.dflt/out" 2>/dev/null)"
[ "$r" = "res=node alias=dog-remote-1" ] && [ -f "$WORK/run.dflt/nudge.delivered" ] && ok "padrão (variável ausente → 60) + aviso de 20 s: a bead vai ao nó (dog-remote-1) e o aviso chegou" || bad "padrão + aviso de 20 s: '$r' delivered=$([ -f "$WORK/run.dflt/nudge.delivered" ] && echo sim || echo não) — $(head -c 300 "$WORK/run.dflt/lines.txt" 2>/dev/null | tr '\n' ' ')"
r="$(tail -1 "$WORK/run.old15/out" 2>/dev/null)"
[ "$r" = "res=mini alias=" ] && [ ! -f "$WORK/run.old15/nudge.delivered" ] && grep -q 'o aviso falhou (rc=124)' "$WORK/run.old15/lines.txt" 2>/dev/null \
  && ok "prazo 15 + aviso de 20 s: estoura (rc=124) e a bead segue no mini — o defeito que a bead descreve" || bad "prazo 15 + aviso de 20 s: '$r' (esperava res=mini com 'o aviso falhou (rc=124)')"
asg="$(cat "$WORK/run.old15/bead.assignee" 2>/dev/null || true)"; st="$(cat "$WORK/run.old15/bead.status" 2>/dev/null || true)"
[ -z "$asg" ] && [ "$st" = open ] && ok "o despacho desfeito deixa a bead aberta e sem dono (assignee='$asg' status='$st')" || bad "a bead não voltou ao estado de antes (assignee='$asg' status='$st')"
r="$(tail -1 "$WORK/run.junk/out" 2>/dev/null)"
[ "$r" = "res=node alias=dog-remote-1" ] && ok "valor ilegível ('abc') + aviso de 20 s: vale 60 e a bead vai ao nó (não vira 'timeout abc', rc=125 em todo aviso)" || bad "valor ilegível quebrou o aviso: '$r'"
for ln in $SITE_LINES; do
  s="$(site_state "s$ln.dflt")"
  [ "$s" = delivered ] && ok "linha $ln: padrão + aviso de 20 s → entregue" || bad "linha $ln: padrão + aviso de 20 s → $s (o prazo padrão está abaixo de 20 s?)"
done

if [ -n "${NT_MUTANT:-}" ]; then echo "RESULT $FAIL/$((PASS+FAIL))"; [ "$FAIL" = 0 ]; exit $?; fi
if [ -z "${NT_NO_MUTANTS:-}" ]; then
  echo "── controle negativo: cada mutante tem que reprovar a bateria"
  nm=0
  # mutant DESCRIÇÃO ANTES DEPOIS — troca UMA ocorrência exata (âncora que não casa 1 vez reprova a bateria: nunca um mutante que não mudou nada passa por "pego")
  mutant() {
    nm=$((nm+1)); local m="$WORK/disp.mut$nm.sh"
    python3 -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
if s.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$DISPATCHER" "$2" "$3" "$m" 2>/dev/null \
      || { bad "mutante '$1': a âncora não casa exatamente 1 vez"; return; }
    local r; r=$(NT_MUTANT=1 PILOT_DISPATCHER_PATH="$m" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) bad "mutante '$1' NÃO foi pego ($r)" ;; "RESULT "*) ok "mutante '$1' pego ($r)" ;; *) bad "mutante '$1': sem resultado ($r)" ;; esac
  }
  mutant "faixa Kimi de volta a 15 s" 'timeout "${PILOT_NODE_NUDGE_TIMEOUT:-60}" gc --city "$GC_CITY" session nudge "$_kd_alias"' 'timeout 15 gc --city "$GC_CITY" session nudge "$_kd_alias"'
  mutant "submit do REUSE de volta a 15 s" 'timeout "${PILOT_NODE_NUDGE_TIMEOUT:-60}" gc --city "$GC_CITY" session submit' 'timeout 15 gc --city "$GC_CITY" session submit'
  mutant "ponto do nó WA ignora a variável" 'timeout "${PILOT_NODE_NUDGE_TIMEOUT:-60}" gc --city "$GC_CITY" session nudge "$_ro_alias"' 'timeout 20 gc --city "$GC_CITY" session nudge "$_ro_alias"'
  mutant "ponto do nó primeiro sem prazo" 'timeout "${PILOT_NODE_NUDGE_TIMEOUT:-60}" gc --city "$GC_CITY" session nudge "$_nd_alias"' 'gc --city "$GC_CITY" session nudge "$_nd_alias"'
  mutant "padrão 10" 'PILOT_NODE_NUDGE_TIMEOUT="${PILOT_NODE_NUDGE_TIMEOUT:-60}"' 'PILOT_NODE_NUDGE_TIMEOUT="${PILOT_NODE_NUDGE_TIMEOUT:-10}"'
  mutant "sem validação" '*) [ "$((10#$PILOT_NODE_NUDGE_TIMEOUT))" -ge 1 ] || PILOT_NODE_NUDGE_TIMEOUT=60 ;; esac' '*) : ;; esac'
  mutant "zero aceito" '-ge 1 ] || PILOT_NODE_NUDGE_TIMEOUT=60' '-ge 0 ] || PILOT_NODE_NUDGE_TIMEOUT=60'
  mutant "letras aceitas" "''|*[!0-9]*|?????*) PILOT_NODE_NUDGE_TIMEOUT=60 ;;" "''|?????*) PILOT_NODE_NUDGE_TIMEOUT=60 ;;"
  mutant "mais de 4 dígitos aceito" "''|*[!0-9]*|?????*) PILOT_NODE_NUDGE_TIMEOUT=60 ;;" "''|*[!0-9]*) PILOT_NODE_NUDGE_TIMEOUT=60 ;;"
fi
echo "── $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
