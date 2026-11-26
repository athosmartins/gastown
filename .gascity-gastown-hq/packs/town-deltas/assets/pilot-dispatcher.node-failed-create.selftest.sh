#!/usr/bin/env bash
# pilot-dispatcher.node-failed-create.selftest.sh — testes da vigia do failed-create do Pilot (ga-dzexg3i.1, filha de ga-dzexg3i).
#
# O problema: `gc session new` só enfileira a abertura; o `start` roda depois, no reconciliador do motor, e quando falha a bead da SESSÃO vira state=failed-create (com pending_create_rollback_reason) minutos
# depois. O Pilot descartava a saída do `session new`, e a bead do nó ficava dona do alias, «avisada», até o TTL de 25 min. Agora o _pilot_node_remote_open guarda o session_id na bead (pilot.node_session) e o
# _pilot_node_failed_create_pass, uma vez por varredura, lê a bead da sessão: failed-create → WARN alto + solta a bead (confirma relendo) + esfria a rota do MBP; ativa/viva → nada; ilegível → nada.
#
# As funções são as REAIS (extraídas palavra por palavra do pilot-dispatcher.sh); bd (com estado) e gc são falsos. A parte do `session new --json` (guardar o id) e os ganchos do esfriamento no
# _pilot_mbp_stamped_gate e no _pilot_mbp_node_decide têm os casos nos selftests wa-node-spawn, mbp-stamped e mbp-node.
#   A. o veredito: failed-create (e fechada sem nunca ter nascido) solta a bead e avisa com o motivo; viva, criando, dormindo, ativa que fechou depois e failed-create COM creation_complete_at não tocam em nada.
#   B. nunca por «não sei»: bead da sessão que não lê (rc, vazio, lixo, id outro, tipo outro, purgada), lista que falha ou não é array → nada escrito, e o resumo conta como ilegível.
#   C. a cara da bead do nó: alias que não é de nó, marca ≠ dono, id de sessão fora da forma → ignorada; a bead que mudou entre a lista e a leitura (stale) → nada; o teto por varredura.
#   D. modos: PILOT_NODE_FAILED_CREATE=off|warn|valor ruim, DRY_RUN; o desfazer que não se confirma (held), a corrida que o --if-assignee barra; o comentário que não grava.
#   E. o resfriamento da rota do MBP: _pilot_mbp_cooling e _pilot_mbp_cool_set de três estados; só o alias do MBP esfria; nunca encurta.
#   F. a fiação: a vigia roda UMA vez na varredura, depois das pistas e antes do resumo da carimbada; nunca fecha sessão (nenhuma chamada ao gc).
#   G. mutantes: cada quebra tem de derrubar este selftest. Cada um roda o arquivo inteiro e para no 1º FAIL.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.node-failed-create.selftest.sh
# Exit 0 iff tudo passa. Saída: linhas ok/FAIL, "N/N ok", "SELFTEST OK". Bash 3.2 (macOS) basta.

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
DISPATCHER="${FC_SELFTEST_FILE:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()   { echo "  ok   $*"; PASS=$((PASS+1)); }
# Rodando como mutante (FC_SELFTEST_FILE) o primeiro FAIL já diz "morto": sai na hora.
fail() { echo "  FAIL $*"; FAIL=$((FAIL+1)); [ -z "${FC_SELFTEST_FILE:-}" ] || exit 1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 — obtido '$2', esperado '$3'"; fi; }   # eq <descrição> <obtido> <esperado>

[ -f "$DISPATCHER" ] || { echo "FATAL: $DISPATCHER não existe" >&2; exit 2; }
fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\)"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
FNS=""
for _f in _pilot_node_failed_create_pass _pilot_node_failed_create_one _pilot_mbp_cooling _pilot_mbp_cool_set _pilot_node_remote_rollback _pilot_bead_home_store; do
  _b="$(fn_of "$_f")"
  [ -n "$_b" ] || { echo "FATAL: $_f() não está em $DISPATCHER" >&2; exit 2; }
  FNS="$FNS"$'\n'"$_b"
done

T="$(mktemp -d "${TMPDIR:-/tmp}/node-fc.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/city/.beads" "$T/city/.gc" "$T/wa_store" "$T/ps_store" "$T/bin" "$T/beads" "$T/over"
printf '%s\n' '{"prefix":"ga","path":"."}' '{"prefix":"ps","path":"../ps_store"}' '{"prefix":"wa","path":"../wa_store"}' > "$T/city/.beads/routes.jsonl"
WA_ST="$(cd "$T/wa_store" && pwd -P)"
PS_ST="$(cd "$T/ps_store" && pwd -P)"
CITY="$T/city"
export FAKE_DIR="$T/beads" FAKE_OVER="$T/over" FAKE_BD_LOG="$T/bdcalls" FAKE_GC_LOG="$T/gccalls" FAKE_COMMENTS="$T/comments" FAKE_RACE="$T/race"
COOL="$T/cool"

# bd falso COM ESTADO (um arquivo por bead em $FAKE_DIR): show <id> --json (rc 1 se a bead não existe; $FAKE_OVER/<id> troca a saída e <id>.rc o rc), list --status in_progress --has-metadata-key K --json --limit 0
# ($FAKE_OVER/__list__ e __list__.rc), update <id> [--if-assignee A] [--assignee X] [--status S] [--set-metadata K=V] [--unset-metadata K]... -q (rc 13 se o dono não é o esperado; FAKE_BD_UPDATE_MODE=noop sai 0 e não
# muda nada; o arquivo $FAKE_RACE faz o dono mudar para "intruso" no 1º update, antes da guarda), comments add <id> <texto>.
cat > "$T/bin/bd" <<'EOF'
#!/usr/bin/env bash
j=""; for x in "$@"; do j="$j|$x"; done
printf '%s\n' "$j" >> "$FAKE_BD_LOG"
[ "${1:-}" = -C ] || exit 64
verb="${3:-}"
over() { # over <nome>: se há saída trocada, imprime e sai com o rc dela
  if [ -e "$FAKE_OVER/$1" ]; then cat "$FAKE_OVER/$1"; r=0; [ -e "$FAKE_OVER/$1.rc" ] && r=$(cat "$FAKE_OVER/$1.rc"); exit "$r"; fi
  if [ -e "$FAKE_OVER/$1.rc" ]; then exit "$(cat "$FAKE_OVER/$1.rc")"; fi
}
case "$verb" in
  show)
    id="${4:-}"; over "$id"
    [ -f "$FAKE_DIR/$id.json" ] || exit 1
    printf '['; cat "$FAKE_DIR/$id.json"; printf ']\n'; exit 0 ;;
  list)
    case "$2" in */wa_store) over __list__ ;; esac   # a saída trocada vale só para a loja do WA (a do PS lista o estado real)
    k=""; prev=""; for x in "$@"; do [ "$prev" = --has-metadata-key ] && k="$x"; prev="$x"; done
    case "$2" in */wa_store) pfx=wa- ;; */ps_store) pfx=ps- ;; *) pfx="" ;; esac   # cada loja só tem as beads do seu prefixo
    ls "$FAKE_DIR"/*.json >/dev/null 2>&1 || { echo '[]'; exit 0; }
    jq -s --arg k "$k" --arg p "$pfx" '[.[] | select((.id | startswith($p)) and .status == "in_progress" and (.metadata | has($k)))]' "$FAKE_DIR"/*.json 2>/dev/null || exit 1
    exit 0 ;;
  update)
    id="${4:-}"; f="$FAKE_DIR/$id.json"
    [ "${FAKE_BD_UPDATE_MODE:-}" = noop ] && exit 0
    [ -f "$f" ] || exit 1
    if [ -e "$FAKE_RACE" ]; then rm -f "$FAKE_RACE"; jq '.assignee = "intruso"' "$f" > "$f.new" && mv "$f.new" "$f"; fi
    shift 4
    ifa="__none__"; asg="__keep__"; st=""; setm=""; unsets=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --if-assignee) ifa="$2"; shift 2 ;;
        --assignee) asg="$2"; shift 2 ;;
        --status) st="$2"; shift 2 ;;
        --set-metadata) setm="$2"; shift 2 ;;
        --unset-metadata) unsets="$unsets $2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cur=$(jq -r '.assignee // ""' "$f" 2>/dev/null) || exit 1
    if [ "$ifa" != "__none__" ] && [ "$cur" != "$ifa" ]; then exit 13; fi
    q='.'
    [ "$asg" != "__keep__" ] && q="$q | (if \$a == \"\" then del(.assignee) else .assignee = \$a end)"
    [ -n "$st" ] && q="$q | .status = \$s"
    [ -n "$setm" ] && q="$q | .metadata[(\$sm | split(\"=\")[0])] = (\$sm | split(\"=\")[1:] | join(\"=\"))"
    for u in $unsets; do q="$q | del(.metadata[\"$u\"])"; done
    jq --arg a "$asg" --arg s "$st" --arg sm "$setm" "$q" "$f" > "$f.new" && mv "$f.new" "$f"
    exit 0 ;;
  comments)
    printf '%s\n' "${5:-}|${6:-}" >> "$FAKE_COMMENTS"; exit "${FAKE_COMMENT_RC:-0}" ;;
esac
exit 64
EOF
chmod +x "$T/bin/bd"
# gc falso: só anota. A vigia NUNCA chama o gc (não fecha sessão); qualquer chamada aparece em gccalls.
cat > "$T/bin/gc" <<'EOF'
#!/usr/bin/env bash
j=""; for x in "$@"; do j="$j|$x"; done
printf '%s\n' "$j" >> "$FAKE_GC_LOG"
exit 0
EOF
chmod +x "$T/bin/gc"
export PATH="$T/bin:$PATH"

PRELUDE='warn(){ echo "WARN $*" >&2; }
log(){ echo "LOG $*" >&2; }
timeout(){ shift; "$@"; }'

NODE_MBP=wa-worker-remote-mbp-1
NODE_HZ=wa-worker-remote-2
NODE_PS=ps-worker-remote-1
# mkbead <id> <status> <dono> <marca> <id da sessão> — bead do nó no formato de `bd show` (omite dono, marca e sessão vazios)
mkbead() {
  jq -n --arg id "$1" --arg s "$2" --arg a "$3" --arg m "$4" --arg ss "$5" \
    '{id:$id,status:$s,issue_type:"task",title:"T",metadata:((if $m=="" then {} else {"pilot.wa_node_alias":$m} end) + (if $ss=="" then {} else {"pilot.node_session":$ss} end))} + (if $a=="" then {} else {assignee:$a} end)' > "$FAKE_DIR/$1.json"
}
# mksess <id> <state> <creation_complete_at> <last_woke_at> <status> <motivo> — bead de sessão no formato real (campos vazios chegam null, como o bd devolve)
mksess() {
  jq -n --arg id "$1" --arg st "$2" --arg cc "$3" --arg lw "$4" --arg s "$5" --arg r "$6" \
    '{id:$id,issue_type:"session",status:$s,close_reason:(if $s == "closed" then "session create failed: aborted before creation_complete" else null end),metadata:{state:$st,creation_complete_at:(if $cc == "" then null else $cc end),last_woke_at:(if $lw == "" then null else $lw end),pending_create_rollback_reason:(if $r == "" then null else $r end)}}' > "$FAKE_DIR/$1.json"
}
mkfail() { mksess "$1" failed-create "" "" closed "${2-lease expired and no live runtime}"; }   # mkfail <id> [motivo] — a forma real de ga-46b1pdb
mkactive() { mksess "$1" awake 2026-11-25T22:03:16Z 2026-11-25T22:03:07Z open ""; }

reset() {
  rm -f "$FAKE_DIR"/*.json "$FAKE_OVER"/* "$FAKE_RACE" "$COOL" "$COOL".* 2>/dev/null || true
  : > "$FAKE_BD_LOG"; : > "$FAKE_GC_LOG"; : > "$FAKE_COMMENTS"; : > "$T/err"
  unset FAKE_BD_UPDATE_MODE FAKE_COMMENT_RC PILOT_NODE_FAILED_CREATE DRY_RUN PILOT_NODE_FC_MAX PILOT_NODE_SESSION_KEY PILOT_MBP_COOL_SECS
}
# H <função> <args…> — roda a função REAL (extraída) num shell novo, com os falsos no PATH; imprime só "rc=N".
H() {
  GC_CITY="$CITY" PILOT_MBP_COOL_FILE="$COOL" \
    bash -c "$PRELUDE"$'\n'"$FNS"$'\n''"$@"; echo "rc=$?"' _ "$@" 2>>"$T/err" | tail -1
}
P() { H _pilot_node_failed_create_pass; }
stt()  { jq -r '[.status, (.assignee // "-"), (.metadata["pilot.wa_node_alias"] // "-"), (.metadata["pilot.node_session"] // "-")] | join(",")' "$FAKE_DIR/$1.json" 2>/dev/null; }
nupd() { grep -c '|update|' "$FAKE_BD_LOG" | tr -d ' '; }
nbd()  { wc -l < "$FAKE_BD_LOG" | tr -d ' '; }
ngc()  { wc -l < "$FAKE_GC_LOG" | tr -d ' '; }
ncom() { wc -l < "$FAKE_COMMENTS" | tr -d ' '; }
errhas() { grep -qF -- "$1" "$T/err"; }
cooled() { [ -s "$COOL" ] && echo cool || echo -; }
FREE="open,-,-,-"
nowts() { date +%s; }

echo "pilot-dispatcher.node-failed-create.selftest — ga-dzexg3i.1"

echo; echo "=== A. o veredito ==="
reset; mkbead wa-aaa1 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1 "lease expired and no live runtime"
r=$(P); eq "failed-create (a forma real: creation_complete_at/last_woke_at null): a vigia devolve 0" "$r" "rc=0"
eq "...a bead do nó foi SOLTA: open, sem dono, sem marca, sem id de sessão" "$(stt wa-aaa1)" "$FREE"
errhas "WARN ga-dzexg3i.1: wa-aaa1 foi ao nó (alias $NODE_MBP) mas a sessão ga-s1 NÃO nasceu: failed-create" && ok "o WARN diz a bead, o alias e a sessão" || fail "WARN: $(cat "$T/err")"
errhas "motivo: lease expired and no live runtime" && ok "...e o motivo (pending_create_rollback_reason)" || fail "motivo: $(cat "$T/err")"
eq "o desfazer foi UM update guardado (--if-assignee = o alias), com a chave da sessão e a marca saindo juntas" "$(grep '|update|' "$FAKE_BD_LOG" | tr -d '\n')" "|-C|$WA_ST|update|wa-aaa1|--if-assignee|$NODE_MBP|--assignee||--unset-metadata|pilot.node_session|--status|open|--unset-metadata|pilot.wa_node_alias|-q"
eq "o comentário na bead conta o que houve (1 linha, na loja da bead)" "$(ncom)" "1"
grep -qF "wa-aaa1|ga-dzexg3i.1: a sessão ga-s1 do alias $NODE_MBP virou failed-create" "$FAKE_COMMENTS" && ok "...e diz a sessão e o alias" || fail "comentário: $(cat "$FAKE_COMMENTS")"
grep -qF "|-C|$CITY|show|ga-s1|--json" "$FAKE_BD_LOG" && ok "a bead da sessão é lida na loja da CIDADE (onde moram as ga-*)" || fail "leitura da sessão: $(cat "$FAKE_BD_LOG")"
eq "a vigia não chamou o gc (nunca fecha sessão)" "$(ngc)" "0"
errhas "failed-create soltas=1" && errhas "vivas=0" && ok "o resumo conta 1 solta, 0 vivas" || fail "resumo: $(cat "$T/err")"
eq "o MBP esfriou (a sessão do MBP morreu ao nascer)" "$(cooled)" "cool"

reset; mkbead wa-aaa2 in_progress $NODE_MBP $NODE_MBP ga-s2; mkactive ga-s2
r=$(P); eq "sessão ATIVA (creation_complete_at, last_woke_at, awake): nada escrito, nada comentado, rota não esfria" "$r $(nupd) $(ncom) $(cooled) $(ngc)" "rc=0 0 0 - 0"
eq "...e a bead segue do nó" "$(stt wa-aaa2)" "in_progress,$NODE_MBP,$NODE_MBP,ga-s2"
errhas "NÃO nasceu" && fail "não devia avisar de sessão ativa" || ok "...sem WARN de failed-create"
errhas "vivas=1" && ok "o resumo conta 1 viva" || fail "resumo: $(cat "$T/err")"

for stt_name in creating pending asleep drained awake; do
  reset; mkbead wa-aaa3 in_progress $NODE_MBP $NODE_MBP ga-s3; mksess ga-s3 "$stt_name" "" "" open ""
  r=$(P); eq "sessão state=$stt_name (status open, sem fechar): é viva — nada escrito" "$r $(nupd) $(ncom) $(cooled)" "rc=0 0 0 -"
done
reset; mkbead wa-aaa4 in_progress $NODE_MBP $NODE_MBP ga-s4; mksess ga-s4 asleep 2026-11-25T20:00:00Z 2026-11-25T20:00:05Z open ""
r=$(P); eq "dormindo (já nasceu, creation_complete_at): nada escrito" "$r $(nupd) $(cooled)" "rc=0 0 -"
reset; mkbead wa-aaa5 in_progress $NODE_MBP $NODE_MBP ga-s5; mksess ga-s5 closed 2026-11-25T20:00:00Z 2026-11-25T20:00:05Z closed "idle"
r=$(P); eq "FECHADA DEPOIS de ter sido ativa (creation_complete_at + last_woke_at): nada escrito — quem fecha sessão que andou é o worker/ghost-release" "$r $(nupd) $(ncom) $(cooled)" "rc=0 0 0 -"
reset; mkbead wa-aaa5b in_progress $NODE_MBP $NODE_MBP ga-s5b; mksess ga-s5b closed "" 2026-11-25T20:00:05Z closed "idle"
r=$(P); eq "FECHADA com last_woke_at (acordou alguma vez) mesmo sem creation_complete_at: andou — nada escrito" "$r $(nupd) $(cooled) $(stt wa-aaa5b)" "rc=0 0 - in_progress,$NODE_MBP,$NODE_MBP,ga-s5b"
reset; mkbead wa-aaa6 in_progress $NODE_MBP $NODE_MBP ga-s6; mksess ga-s6 failed-create 2026-11-25T20:00:00Z "" closed "lease expired"
r=$(P); eq "state=failed-create MAS com creation_complete_at (a sessão chegou a nascer): é ativa — nada escrito (nunca fecha/solta o que andou)" "$r $(nupd) $(cooled)" "rc=0 0 -"
reset; mkbead wa-aaa7 in_progress $NODE_MBP $NODE_MBP ga-s7; mksess ga-s7 closed "" "" closed ""
r=$(P); eq "FECHADA sem nunca ter sido ativa (state closed, sem creation_complete_at nem last_woke_at): nasceu morta — solta" "$(stt wa-aaa7)" "$FREE"
errhas "motivo: session create failed: aborted before creation_complete" && ok "...sem pending_create_rollback_reason, o motivo cai no close_reason da bead da sessão" || fail "motivo reserva: $(cat "$T/err")"
reset; mkbead wa-aaa7b in_progress $NODE_MBP $NODE_MBP ga-s7b; mksess ga-s7b "" "" "" closed ""
r=$(P); eq "FECHADA sem state nenhum (nada prova que a metadata foi lida): «não sei» — nada escrito" "$r $(nupd) $(cooled) $(stt wa-aaa7b)" "rc=0 0 - in_progress,$NODE_MBP,$NODE_MBP,ga-s7b"
reset; mksess ga-s8 failed-create "" "" closed ""; mkbead wa-aaa8 in_progress $NODE_MBP $NODE_MBP ga-s8
jq '.close_reason = null' "$FAKE_DIR/ga-s8.json" > "$FAKE_DIR/ga-s8.json.n" && mv "$FAKE_DIR/ga-s8.json.n" "$FAKE_DIR/ga-s8.json"
r=$(P); errhas "motivo: a bead da sessão não diz" && ok "failed-create sem nenhum motivo: o WARN diz «a bead da sessão não diz»" || fail "sem motivo: $(cat "$T/err")"
reset; mkbead wa-aaa9 in_progress $NODE_MBP $NODE_MBP ga-s9; mkfail ga-s9 $'linha1\nlinha2|com barra'
r=$(P); errhas "motivo: linha1 linha2 com barra" && ok "o motivo com LF e '|' sai em UMA linha de WARN" || fail "motivo multilinha: $(cat "$T/err")"

reset; mkbead wa-bbb1 in_progress $NODE_HZ $NODE_HZ ga-h1; mkfail ga-h1
r=$(P); eq "alias do HETZNER, failed-create: solta a bead (o desfazer é o mesmo)" "$(stt wa-bbb1)" "$FREE"
eq "...mas a rota do MBP NÃO esfria (a bead não é do MBP)" "$(cooled)" "-"
reset; mkbead ps-ccc1 in_progress $NODE_PS $NODE_PS ga-p1; mkfail ga-p1
r=$(P); eq "alias do PS (ps-worker-remote-1), failed-create: solta, na loja do PS" "$(stt ps-ccc1) $(grep -c "|-C|$PS_ST|update|ps-ccc1|" "$FAKE_BD_LOG")" "$FREE 1"
eq "...e a rota do MBP não esfria" "$(cooled)" "-"

echo; echo "=== B. nunca por «não sei» ==="
HELD="in_progress,$NODE_MBP,$NODE_MBP,ga-sx"
reset; mkbead wa-ddd1 in_progress $NODE_MBP $NODE_MBP ga-sx; echo 1 > "$FAKE_OVER/ga-sx.rc"
r=$(P); eq "bd show da sessão falha (rc 1): NADA escrito" "$r $(nupd) $(ncom) $(cooled) $(stt wa-ddd1)" "rc=0 0 0 - $HELD"
errhas "ilegíveis=1" && ok "...o resumo conta 1 ilegível" || fail "resumo: $(cat "$T/err")"
errhas "NÃO nasceu" && fail "avisou failed-create sem ler" || ok "...e não avisa failed-create"
reset; mkbead wa-ddd2 in_progress $NODE_MBP $NODE_MBP ga-sx; : > "$FAKE_OVER/ga-sx"
r=$(P); eq "bd show da sessão sai 0 e VAZIO: nada escrito" "$r $(nupd) $(cooled) $(stt wa-ddd2)" "rc=0 0 - $HELD"
reset; mkbead wa-ddd3 in_progress $NODE_MBP $NODE_MBP ga-sx; echo 'isso não é json {' > "$FAKE_OVER/ga-sx"
r=$(P); eq "JSON ruim: nada escrito" "$r $(nupd) $(cooled) $(stt wa-ddd3)" "rc=0 0 - $HELD"
reset; mkbead wa-ddd4 in_progress $NODE_MBP $NODE_MBP ga-sx; mkfail ga-outra; cp "$FAKE_DIR/ga-outra.json" "$FAKE_OVER/ga-sx"
r=$(P); eq "o bd devolve a bead de OUTRO id (failed-create): não vale para esta sessão — nada escrito" "$r $(nupd) $(cooled) $(stt wa-ddd4)" "rc=0 0 - $HELD"
reset; mkbead wa-ddd5 in_progress $NODE_MBP $NODE_MBP ga-sx; mkfail ga-sx; jq '.issue_type = "task"' "$FAKE_DIR/ga-sx.json" > "$FAKE_OVER/ga-sx.n"; mv "$FAKE_OVER/ga-sx.n" "$FAKE_OVER/ga-sx"
r=$(P); eq "o id existe mas NÃO é bead de sessão (issue_type task): nada escrito" "$r $(nupd) $(cooled) $(stt wa-ddd5)" "rc=0 0 - $HELD"
reset; mkbead wa-ddd6 in_progress $NODE_MBP $NODE_MBP ga-sx
r=$(P); eq "a bead da sessão não existe (purgada): nada escrito" "$r $(nupd) $(cooled) $(stt wa-ddd6)" "rc=0 0 - $HELD"
reset; mkbead wa-ddd7 in_progress $NODE_MBP $NODE_MBP ga-sx; echo '[]' > "$FAKE_OVER/ga-sx"
r=$(P); eq "array vazio no lugar da bead: nada escrito" "$r $(nupd) $(cooled) $(stt wa-ddd7)" "rc=0 0 - $HELD"
reset; mkbead wa-ddd8 in_progress $NODE_MBP $NODE_MBP ga-sx; mkfail ga-sx; jq '.metadata = null' "$FAKE_DIR/ga-sx.json" > "$FAKE_OVER/ga-sx.n"; mv "$FAKE_OVER/ga-sx.n" "$FAKE_OVER/ga-sx"
r=$(P); eq "bead de sessão sem metadata (null): «não sei» — nada escrito" "$r $(nupd) $(cooled) $(stt wa-ddd8)" "rc=0 0 - $HELD"
reset; mkbead wa-ddd9 in_progress $NODE_MBP $NODE_MBP ga-sx; mkfail ga-sx; jq '.metadata.state = 7 | .metadata.creation_complete_at = 3' "$FAKE_DIR/ga-sx.json" > "$FAKE_OVER/ga-sx.n"; mv "$FAKE_OVER/ga-sx.n" "$FAKE_OVER/ga-sx"
r=$(P); eq "campos com tipo errado (state número, creation_complete_at número): é viva/ilegível — nada escrito" "$r $(nupd) $(cooled) $(stt wa-ddd9)" "rc=0 0 - $HELD"

reset; mkbead wa-eee1 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; echo 1 > "$FAKE_OVER/__list__.rc"
r=$(P); eq "bd list da loja falha: nada lido, nada escrito" "$r $(nupd) $(ncom) $(cooled) $(stt wa-eee1)" "rc=0 0 0 - in_progress,$NODE_MBP,$NODE_MBP,ga-s1"
errhas "ilegíveis=" && ok "...e o resumo conta a loja como ilegível" || fail "resumo: $(cat "$T/err")"
reset; mkbead wa-eee2 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; echo '{"nao":"array"}' > "$FAKE_OVER/__list__"
r=$(P); eq "bd list devolve um objeto, não array: nada escrito" "$r $(nupd) $(cooled)" "rc=0 0 -"
reset; mkbead wa-eee3 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; echo 'lixo' > "$FAKE_OVER/__list__"
r=$(P); eq "bd list devolve lixo: nada escrito" "$r $(nupd) $(cooled)" "rc=0 0 -"
reset; mkbead wa-eee4 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; : > "$FAKE_OVER/__list__"
r=$(P); eq "bd list sai 0 sem saída: nada escrito" "$r $(nupd) $(cooled)" "rc=0 0 -"
reset
r=$(P); eq "nenhuma bead com a chave (lista vazia): nada escrito" "$r $(nupd) $(ncom) $(cooled)" "rc=0 0 0 -"
errhas "vigia do failed-create" && fail "sem bead nenhuma não devia haver linha de resumo" || ok "...e nenhuma linha de resumo (vazio ≠ ilegível)"
rm -f "$T/city/.beads/routes.jsonl"
reset; mkbead wa-eee5 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1
r=$(P); eq "routes.jsonl ausente: não sei onde ficam as lojas — nada lido, nada escrito" "$r $(nupd) $(cooled) $(stt wa-eee5)" "rc=0 0 - in_progress,$NODE_MBP,$NODE_MBP,ga-s1"
errhas "ilegíveis=2" && ok "...e o resumo conta as DUAS lojas (wa e ps) como ilegíveis — alto, não em silêncio" || fail "resumo: $(cat "$T/err")"
printf '%s\n' '{"prefix":"ga","path":"."}' '{"prefix":"ps","path":"../ps_store"}' '{"prefix":"wa","path":"../wa_store"}' > "$T/city/.beads/routes.jsonl"

echo; echo "=== C. a cara da bead do nó ==="
for al in wa-worker mila-wa wa-worker-remote wa-worker-remote-mbp wa-worker-remote-mbp-x wa-worker-remote-9x ps-worker gastown.dog "" intruso; do
  reset; mkbead wa-fff1 in_progress "$al" "$al" ga-s1; mkfail ga-s1
  r=$(P); eq "dono '$al' não é alias de nó: a vigia ignora a bead (nem lê a sessão)" "$r $(nupd) $(cooled) $(grep -c 'show|ga-s1' "$FAKE_BD_LOG")" "rc=0 0 - 0"
done
reset; mkbead wa-fff2 in_progress $NODE_MBP "" ga-s1; mkfail ga-s1
r=$(P); eq "sem marca (o dono é de nó mas a bead não traz pilot.wa_node_alias): ignorada, a sessão nem é lida" "$r $(nupd) $(cooled) $(grep -c 'show|ga-s1' "$FAKE_BD_LOG")" "rc=0 0 - 0"
reset; mkbead wa-fff3 in_progress $NODE_MBP $NODE_HZ ga-s1; mkfail ga-s1
r=$(P); eq "marca ≠ dono: ignorada, a sessão nem é lida (o 2º freio, a releitura, nem chega a ser preciso)" "$r $(nupd) $(cooled) $(grep -c 'show|ga-s1' "$FAKE_BD_LOG")" "rc=0 0 - 0"
for sid in -x .x 'a b' 'a/b' 'a;b' '$(x)' ''; do
  reset; mkbead wa-fff4 in_progress $NODE_MBP $NODE_MBP "$sid"; mkfail ga-s1
  r=$(P); eq "id de sessão '$sid' fora da forma: ignorada, nada escrito" "$r $(nupd) $(cooled) $(grep -c '|show|' "$FAKE_BD_LOG")" "rc=0 0 - 0"
done
reset; mkbead wa-fff5 open "" "" ga-s1; mkfail ga-s1
r=$(P); eq "bead open (não in_progress) com a chave: a lista não a traz — nada" "$r $(nupd) $(cooled)" "rc=0 0 -"
reset; mkbead wa-fff6 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1
# a bead mudou ENTRE a lista e a releitura: a lista (sobrescrita) ainda a mostra do nó, o estado real já é de outro dono
jq -s '.' "$FAKE_DIR/wa-fff6.json" > "$FAKE_OVER/__list__"
jq '.assignee = "outro-dono"' "$FAKE_DIR/wa-fff6.json" > "$FAKE_DIR/x" && mv "$FAKE_DIR/x" "$FAKE_DIR/wa-fff6.json"
r=$(P); eq "a bead mudou de dono entre a lista e a releitura (stale): nada escrito" "$r $(nupd) $(cooled) $(stt wa-fff6)" "rc=0 0 - in_progress,outro-dono,$NODE_MBP,ga-s1"
errhas "mudaram=1" && ok "...o resumo conta 1 que mudou" || fail "resumo: $(cat "$T/err")"
reset; mkbead wa-fff7 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; jq -s '.' "$FAKE_DIR/wa-fff7.json" > "$FAKE_OVER/__list__"
jq '.metadata["pilot.node_session"] = "ga-outra-sessao"' "$FAKE_DIR/wa-fff7.json" > "$FAKE_DIR/x" && mv "$FAKE_DIR/x" "$FAKE_DIR/wa-fff7.json"
r=$(P); eq "a bead agora aponta para OUTRA sessão (reaberta no mesmo alias): a sessão velha não solta a bead nova" "$r $(nupd) $(cooled) $(stt wa-fff7)" "rc=0 0 - in_progress,$NODE_MBP,$NODE_MBP,ga-outra-sessao"
reset; mkbead wa-fff10 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; jq -s '.' "$FAKE_DIR/wa-fff10.json" > "$FAKE_OVER/__list__"
jq '.metadata["pilot.wa_node_alias"] = "wa-worker-remote-mbp-9"' "$FAKE_DIR/wa-fff10.json" > "$FAKE_DIR/x" && mv "$FAKE_DIR/x" "$FAKE_DIR/wa-fff10.json"
r=$(P); eq "a marca da bead mudou entre a lista e a releitura (dono e sessão iguais): não é mais a bead que a lista mostrou — nada escrito" "$r $(nupd) $(cooled)" "rc=0 0 -"
reset; mkbead wa-fff8 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; jq -s '.' "$FAKE_DIR/wa-fff8.json" > "$FAKE_OVER/__list__"
jq '.status = "closed"' "$FAKE_DIR/wa-fff8.json" > "$FAKE_DIR/x" && mv "$FAKE_DIR/x" "$FAKE_DIR/wa-fff8.json"
r=$(P); eq "a bead fechou entre a lista e a releitura: não se reabre — nada escrito" "$r $(nupd) $(cooled)" "rc=0 0 -"
reset; mkbead wa-fff9 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; jq -s '.' "$FAKE_DIR/wa-fff9.json" > "$FAKE_OVER/__list__"; echo 1 > "$FAKE_OVER/wa-fff9.rc"
r=$(P); eq "a releitura da bead do nó falha: nada escrito (o desfazer guardado seria o 2º freio, e nem chega a ser tentado)" "$r $(nupd) $(cooled)" "rc=0 0 -"

reset
for i in 1 2 3 4 5; do mkbead wa-ggg$i in_progress $NODE_MBP $NODE_MBP ga-g$i; mkfail ga-g$i; done
export PILOT_NODE_FC_MAX=2; r=$(P); unset PILOT_NODE_FC_MAX
n=0; for i in 1 2 3 4 5; do [ "$(stt wa-ggg$i)" = "$FREE" ] && n=$((n+1)); done
eq "PILOT_NODE_FC_MAX=2 com 5 beads failed-create: só 2 são soltas por varredura" "$n" "2"
reset
for i in 1 2 3 4 5 6 7 8; do mkbead wa-hhh$i in_progress $NODE_MBP $NODE_MBP ga-g$i; mkfail ga-g$i; done
r=$(P); n=0; for i in 1 2 3 4 5 6 7 8; do [ "$(stt wa-hhh$i)" = "$FREE" ] && n=$((n+1)); done
eq "teto padrão (6): 8 beads failed-create → 6 soltas" "$n" "6"
reset
for i in 1 2 3 4 5 6 7 8; do mkbead wa-iii$i in_progress $NODE_MBP $NODE_MBP ga-g$i; mkfail ga-g$i; done
export PILOT_NODE_FC_MAX=abc; r=$(P); unset PILOT_NODE_FC_MAX
n=0; for i in 1 2 3 4 5 6 7 8; do [ "$(stt wa-iii$i)" = "$FREE" ] && n=$((n+1)); done
eq "teto ilegível ('abc') vale o padrão (6): de 8 beads failed-create, 6 são soltas (não todas)" "$n" "6"
reset; mkbead wa-jjj1 in_progress $NODE_MBP $NODE_MBP ga-a1; mkfail ga-a1; mkbead wa-jjj2 in_progress $NODE_HZ $NODE_HZ ga-a2; mkactive ga-a2; mkbead ps-jjj3 in_progress $NODE_PS $NODE_PS ga-a3; mkfail ga-a3
r=$(P); eq "uma loja WA e uma PS na mesma varredura: soltas as duas failed-create, a ativa fica" "$(stt wa-jjj1) $(stt wa-jjj2) $(stt ps-jjj3)" "$FREE in_progress,$NODE_HZ,$NODE_HZ,ga-a2 $FREE"
reset; mkbead wa-jjj4 in_progress $NODE_MBP $NODE_MBP ga-a1; mkfail ga-a1
export PILOT_NODE_SESSION_KEY=pilot.outra_chave; r=$(P); unset PILOT_NODE_SESSION_KEY
eq "PILOT_NODE_SESSION_KEY troca a chave lida: a bead que guarda a chave padrão não aparece" "$r $(nupd) $(cooled)" "rc=0 0 -"

echo; echo "=== D. modos, o desfazer que não se confirma e a corrida ==="
reset; mkbead wa-kkk1 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1
export PILOT_NODE_FAILED_CREATE=off; r=$(P); unset PILOT_NODE_FAILED_CREATE
eq "PILOT_NODE_FAILED_CREATE=off: nenhuma chamada (bd 0, gc 0), nada escrito" "$r $(nbd) $(ngc) $(cooled)" "rc=0 0 0 -"
reset; mkbead wa-kkk2 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1
export PILOT_NODE_FAILED_CREATE=warn; r=$(P); unset PILOT_NODE_FAILED_CREATE
eq "warn: avisa, NÃO escreve (0 updates, 0 comentários), rota não esfria" "$r $(nupd) $(ncom) $(cooled) $(stt wa-kkk2)" "rc=0 0 0 - in_progress,$NODE_MBP,$NODE_MBP,ga-s1"
errhas "NÃO nasceu: failed-create" && ok "...mas o WARN sai" || fail "warn: $(cat "$T/err")"
errhas "vistas sem soltar=1" && ok "...o resumo conta 1 vista sem soltar" || fail "resumo: $(cat "$T/err")"
reset; mkbead wa-kkk3 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1
export PILOT_NODE_FAILED_CREATE=banana; r=$(P); unset PILOT_NODE_FAILED_CREATE
eq "valor ruim ('banana'): vale warn (o erro cai no que não escreve)" "$r $(nupd) $(cooled)" "rc=0 0 -"
errhas "'banana' não é on|warn|off" && ok "...e avisa do valor" || fail "valor ruim: $(cat "$T/err")"
reset; mkbead wa-kkk4 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1
export PILOT_NODE_FAILED_CREATE=""; r=$(P); unset PILOT_NODE_FAILED_CREATE
eq "valor vazio exportado: ':-on' → on (solta)" "$(stt wa-kkk4)" "$FREE"
reset; mkbead wa-kkk5 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1
export DRY_RUN=1; r=$(P); unset DRY_RUN
eq "DRY_RUN=1 (modo on): avisa, não escreve, não esfria" "$r $(nupd) $(ncom) $(cooled)" "rc=0 0 0 -"
errhas "WOULD soltar" && ok "...e o log diz WOULD" || fail "dry-run: $(cat "$T/err")"

reset; mkbead wa-lll1 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1
export FAKE_BD_UPDATE_MODE=noop; r=$(P); unset FAKE_BD_UPDATE_MODE
eq "o update sai 0 mas NÃO muda a bead (desfazer não confirma): a bead segue do nó, WARN alto, sem comentário" "$r $(stt wa-lll1) $(ncom)" "rc=0 in_progress,$NODE_MBP,$NODE_MBP,ga-s1 0"
errhas "o desfazer NÃO se confirmou" && ok "...o aviso diz que o desfazer não se confirmou" || fail "held: $(cat "$T/err")"
errhas "desfazer não confirmado=1" && ok "...o resumo conta 1 held" || fail "resumo: $(cat "$T/err")"
eq "...e a rota do MBP esfria MESMO ASSIM (a sessão morreu ao nascer; a próxima bead não vai ao mesmo nó)" "$(cooled)" "cool"
reset; mkbead wa-lll2 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; : > "$FAKE_RACE"
r=$(P); eq "corrida: o dono mudou entre a releitura e o update — o --if-assignee barra (rc 13): a bead do OUTRO dono NÃO é tocada" "$(stt wa-lll2)" "in_progress,intruso,$NODE_MBP,ga-s1"
errhas "o desfazer NÃO se confirmou" && ok "...e o desfazer não se confirma (held, WARN)" || fail "corrida: $(cat "$T/err")"
reset; mkbead wa-lll3 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1
export FAKE_COMMENT_RC=1; r=$(P); unset FAKE_COMMENT_RC
eq "o comentário não grava (rc 1): a bead JÁ está solta e confirmada — a vigia segue, rc 0" "$r $(stt wa-lll3)" "rc=0 $FREE"
reset; mkbead wa-lll4 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; mkbead wa-lll5 in_progress $NODE_MBP $NODE_MBP ga-s2; mkactive ga-s2
r=$(P); eq "um failed-create não atrapalha a vizinha ativa na mesma varredura" "$(stt wa-lll4) $(stt wa-lll5)" "$FREE in_progress,$NODE_MBP,$NODE_MBP,ga-s2"
reset; mkbead wa-lll6 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; P >/dev/null; : > "$FAKE_BD_LOG"; : > "$FAKE_COMMENTS"; r=$(P)
eq "2ª varredura depois de solta: a bead não tem mais a chave — nada lido, nada escrito (idempotente)" "$r $(nupd) $(ncom) $(grep -c '|show|' "$FAKE_BD_LOG")" "rc=0 0 0 0"

echo; echo "=== E. o resfriamento da rota do MBP ==="
cool() { H _pilot_mbp_cooling; }
reset; r=$(cool); eq "arquivo ausente: a rota NÃO está esfriando (1), sem aviso" "$r" "rc=1"; [ ! -s "$T/err" ] && ok "...e sem aviso nenhum" || fail "aviso à toa: $(cat "$T/err")"
reset; echo $(( $(nowts) + 600 )) > "$COOL"; r=$(cool); eq "fim no futuro: esfriando (0)" "$r" "rc=0"
reset; echo $(( $(nowts) - 5 )) > "$COOL"; r=$(cool); eq "fim no passado: não esfria (1)" "$r" "rc=1"
reset; echo $(( $(nowts) + 600 )) > "$COOL"; printf '%s' "$(( $(nowts) + 600 ))" > "$COOL"; r=$(cool); eq "sem LF no fim do arquivo: lê do mesmo jeito (0)" "$r" "rc=0"
reset; printf '0%s\n' "$(( $(nowts) + 600 ))" > "$COOL"; r=$(cool); eq "zero à esquerda é decimal (não octal): esfriando" "$r" "rc=0"
for bad in "abc" "-5" "12.5" "1e9" " " "9999999999999" "12 34"; do
  reset; printf '%s\n' "$bad" > "$COOL"; r=$(cool)
  eq "conteúdo ilegível '$bad': esfriando (0) — sem saber, o MBP fica FORA" "$r" "rc=0"
  errhas "não tem um inteiro legível" && ok "...com aviso que diz o que apagar" || fail "aviso: $(cat "$T/err")"
done
reset; : > "$COOL"; r=$(cool); eq "arquivo vazio: esfriando (0) com aviso" "$r" "rc=0"; errhas "não tem um inteiro legível" && ok "...com aviso" || fail "vazio sem aviso"
reset; mkdir -p "$COOL"; r=$(cool); eq "o caminho é uma PASTA (não lê): esfriando (0)" "$r" "rc=0"; rmdir "$COOL"
reset; echo garbage > "$COOL"; GC_CITY="$CITY" PILOT_MBP_COOL_FILE="$COOL" bash -c "$PRELUDE"$'\n'"$FNS"$'\n''_pilot_mbp_cooling; _pilot_mbp_cooling; _pilot_mbp_cooling' 2>>"$T/err" || true; n=$(grep -c 'não tem um inteiro legível' "$T/err")
eq "o aviso do arquivo ilegível sai UMA vez por varredura (3 consultas, 1 aviso)" "$n" "1"

setc() { H _pilot_mbp_cool_set "$@"; }
reset; r=$(setc 600); v=$(cat "$COOL" 2>/dev/null); d=$(( v - $(nowts) ))
{ [ "$r" = rc=0 ] && [ "$d" -ge 560 ] && [ "$d" -le 602 ]; } && ok "cool_set 600: grava agora+600 (folga de 40 s para a máquina carregada)" || fail "cool_set 600: $r d=$d"
r=$(cool); eq "...e _pilot_mbp_cooling o lê: esfriando" "$r" "rc=0"
ls "$COOL".* >/dev/null 2>&1 && fail "sobrou arquivo temporário: $(ls "$COOL".*)" || ok "...sem arquivo temporário sobrando (tmp + mv)"
reset; echo $(( $(nowts) + 5000 )) > "$COOL"; v1=$(cat "$COOL"); r=$(setc 60); eq "cool_set NUNCA encurta: 60 s não mexe num fim de +5000 s" "$(cat "$COOL") $r" "$v1 rc=0"
reset; echo $(( $(nowts) + 10 )) > "$COOL"; r=$(setc 600); v=$(cat "$COOL"); d=$(( v - $(nowts) ))
{ [ "$d" -ge 560 ] && [ "$d" -le 602 ]; } && ok "...mas ESTENDE um fim mais curto (+10 → +600)" || fail "estender: d=$d"
reset; echo lixo > "$COOL"; r=$(setc 600); v=$(cat "$COOL"); { [ "$r" = rc=0 ] && [ "$v" -gt "$(nowts)" ] 2>/dev/null; } && ok "arquivo atual ilegível: cool_set o troca pelo novo" || fail "troca de lixo: $r '$v'"
reset; r=$(setc 0); eq "cool_set 0: nada a gravar (0), nenhum arquivo" "$r $(cooled)" "rc=0 -"
for bad in "" abc -1 1.5 9999999999; do reset; r=$(setc "$bad"); eq "cool_set '$bad': 1, nenhum arquivo" "$r $(cooled)" "rc=1 -"; done
reset; PILOT_MBP_COOL_FILE=/dev/null/x/y r=$(GC_CITY="$CITY" PILOT_MBP_COOL_FILE=/dev/null/x/y bash -c "$PRELUDE"$'\n'"$FNS"$'\n''_pilot_mbp_cool_set 600; echo "rc=$?"' 2>>"$T/err" | tail -1)
eq "pasta que não se cria: cool_set devolve 1 com aviso" "$r" "rc=1"; errhas "NÃO foi esfriada" && ok "...o aviso diz que NÃO esfriou" || fail "aviso: $(cat "$T/err")"
# a escrita é tmp + mv: o arquivo que o leitor abre é SEMPRE inteiro. Prova: o inode muda (uma escrita direta por cima manteria o mesmo inode)
reset; echo $(( $(nowts) + 10 )) > "$COOL"; i1=$(ls -i "$COOL" | awk '{print $1}'); r=$(setc 600); i2=$(ls -i "$COOL" | awk '{print $1}')
{ [ "$r" = rc=0 ] && [ -n "$i1" ] && [ "$i1" != "$i2" ]; } && ok "cool_set troca o arquivo inteiro (tmp + mv: o inode muda, o leitor nunca vê meia escrita)" || fail "tmp+mv: $r inode $i1 → $i2"
# a pasta existe (o mkdir passa) mas não aceita escrita: o tmp não grava → devolve 1, com aviso, sem arquivo (rodando como root a permissão não vale: o teste se pula)
RO="$T/ro-cool"; rm -rf "$RO"; mkdir -p "$RO"; chmod 555 "$RO"
if [ -w "$RO" ]; then echo "  (pasta só-leitura gravável por este usuário — teste pulado)"; else
  reset; r=$(GC_CITY="$CITY" PILOT_MBP_COOL_FILE="$RO/cool" bash -c "$PRELUDE"$'\n'"$FNS"$'\n''_pilot_mbp_cool_set 600; echo "rc=$?"' 2>>"$T/err" | tail -1)
  eq "pasta sem permissão de escrita: cool_set devolve 1" "$r" "rc=1"
  errhas "não consegui gravar" && errhas "NÃO foi esfriada" && ok "...com o aviso de que NÃO esfriou" || fail "aviso: $(cat "$T/err")"
  ls "$RO"/cool* >/dev/null 2>&1 && fail "sobrou arquivo na pasta só-leitura: $(ls "$RO")" || ok "...e nenhum arquivo gravado"
fi
chmod 755 "$RO"; rm -rf "$RO"

reset; mkbead wa-mmm1 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; export PILOT_MBP_COOL_SECS=77; r=$(P); unset PILOT_MBP_COOL_SECS
d=$(( $(cat "$COOL" 2>/dev/null || echo 0) - $(nowts) )); { [ "$d" -ge 40 ] && [ "$d" -le 79 ]; } && ok "PILOT_MBP_COOL_SECS=77: a vigia esfria por 77 s" || fail "COOL_SECS: d=$d"
reset; mkbead wa-mmm2 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; export PILOT_MBP_COOL_SECS=abc; r=$(P); unset PILOT_MBP_COOL_SECS
d=$(( $(cat "$COOL" 2>/dev/null || echo 0) - $(nowts) )); { [ "$d" -ge 1760 ] && [ "$d" -le 1802 ]; } && ok "PILOT_MBP_COOL_SECS ilegível: vale o padrão (1800 s)" || fail "COOL_SECS ruim: d=$d"
reset; mkbead wa-mmm3 in_progress $NODE_MBP $NODE_MBP ga-s1; mkfail ga-s1; export PILOT_MBP_COOL_SECS=0; r=$(P); unset PILOT_MBP_COOL_SECS
eq "PILOT_MBP_COOL_SECS=0: a bead é solta e a rota NÃO esfria (0 desliga o resfriamento)" "$(stt wa-mmm3) $(cooled)" "$FREE -"

echo; echo "=== F. a fiação ==="
eq "a vigia é chamada em UM lugar do fluxo principal" "$(grep -c '^_pilot_node_failed_create_pass || true$' "$DISPATCHER")" "1"
w1=$(awk '$0 == "_pilot_node_failed_create_pass || true" {print NR; exit}' "$DISPATCHER"); s1=$(awk '$0 ~ /_pilot_mbp_stamped_summary; fi$/ {print NR; exit}' "$DISPATCHER"); e1=$(awk '$0 == "_pilot_sweep_emit" {print NR; exit}' "$DISPATCHER"); d1=$(awk '$0 ~ /^dispatch_lane\(\)/ {print NR; exit}' "$DISPATCHER")
{ [ -n "$w1" ] && [ -n "$s1" ] && [ -n "$e1" ] && [ -n "$d1" ] && [ "$d1" -lt "$w1" ] && [ "$w1" -lt "$s1" ] && [ "$s1" -lt "$e1" ]; } && ok "...depois das pistas (dispatch_lane), antes do resumo da carimbada e do evento agregado" || fail "ordem (dispatch_lane $d1, vigia $w1, resumo $s1, evento $e1)"
grep -qF -- '--json 2>/dev/null) || _ro_rc=$?' "$DISPATCHER" && ok "o _pilot_node_remote_open pede --json do session new e guarda a saída" || fail "session new --json ausente"
# o corpo da vigia nunca fecha sessão nem chama o gc
body="$(fn_of _pilot_node_failed_create_pass; fn_of _pilot_node_failed_create_one)"
printf '%s' "$body" | grep -qE '(^|[^a-z_])gc ' && fail "a vigia chama o gc" || ok "o código da vigia não chama o gc (nunca fecha sessão)"
printf '%s' "$body" | grep -q 'session close' && fail "a vigia fecha sessão" || ok "...nem fecha sessão"

# rodando como mutante: sem a seção G (o mutante que sobreviveu a A-F sai 0 e o pai diz SOBREVIVEU)
if [ -n "${FC_SELFTEST_FILE:-}" ] || [ -n "${FC_NO_MUT:-}" ]; then
  echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
  [ $FAIL -eq 0 ] && echo "SELFTEST OK (sem mutantes)" || { echo "SELFTEST FALHOU ($FAIL)"; exit 1; }
  exit 0
fi
echo; echo "=== G. mutantes ==="
# mut <nome> <função|-> <trecho original> <trecho novo> — troca a 1ª ocorrência DENTRO da função (ou do arquivo, com "-") numa cópia do pilot-dispatcher.sh e roda este arquivo contra ela; tem de reprovar
mut() {
  local name="$1" fn="$2" old="$3" new="$4" copy="$T/mut.sh"
  python3 -I - "$DISPATCHER" "$copy" "$fn" "$old" "$new" <<'EOF' || { fail "mutante $name: o trecho original não existe em $2 (o fonte mudou? atualize o mutante)"; return; }
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
fn, old, new = sys.argv[3], sys.argv[4], sys.argv[5]
lo, hi = 0, len(src)
if fn != "-":
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(fn), src, re.S | re.M)
    if not m: sys.exit(1)
    lo, hi = m.span()
if src.count(old, lo, hi) < 1: sys.exit(1)
i = src.find(old, lo, hi)
open(sys.argv[2], "w", encoding="utf-8").write(src[:i] + new + src[i + len(old):])
EOF
  if FC_SELFTEST_FILE="$copy" bash "$SELF" >/dev/null 2>&1; then fail "mutante $name SOBREVIVEU"; else ok "mutante $name morreu"; fi
}
PA=_pilot_node_failed_create_pass; ON=_pilot_node_failed_create_one; CL=_pilot_mbp_cooling; CS=_pilot_mbp_cool_set; RB=_pilot_node_remote_rollback
# o veredito
mut ver-sem-creation-complete $ON '(($m.creation_complete_at // "") == "") and ' ''
mut ver-so-failed-create      $ON ' or ((.status // "") == "closed" and ((($m.state // "") | type) == "string") and (($m.state // "") != "") and ($m.last_woke_at // "") == "")' ''
mut ver-fechada-vira-failed   $ON ' and ($m.last_woke_at // "") == "")' ' and true)'
mut ver-sem-state-no-fechada  $ON ' and ((($m.state // "") | type) == "string") and (($m.state // "") != "")' ''
mut ver-sem-tipo-sessao       $ON ' and .issue_type == "session"' ''
mut ver-sem-id                $ON ' and .id == $id and .issue_type == "session"' ' and .issue_type == "session"'
mut ver-ilegivel-vira-failed  $ON '*) return 0 ;;
  esac' '*) _fo_why=""; _fo_v="failed|" ;;
  esac'
mut ver-alive-vira-failed     $ON 'alive\|*) _FC_RESULT=alive; return 0 ;;' 'alive\|*) _FC_RESULT=alive ;;'
mut ver-read-fail-vira-failed $ON '--json 2>/dev/null) || _fo_sj=""' '--json 2>/dev/null) || _fo_sj=$(printf "[{\"id\":\"%s\",\"issue_type\":\"session\",\"status\":\"closed\",\"metadata\":{\"state\":\"failed-create\"}}]" "$_fo_sid")'
mut motivo-sem-pending        $ON '$m.pending_create_rollback_reason // .close_reason // ""' '.close_reason // ""'
mut motivo-sem-lf             $ON 'gsub("[\r\n|]"; " ")' 'gsub("[|]"; " ")'
# a releitura da bead do nó
mut stale-sem-dono            $ON '(.assignee // "") == $a and ' ''
mut stale-sem-marca           $ON '(.metadata["pilot.wa_node_alias"] // "") == $a and ' ''
mut stale-sem-sessao          $ON ' and (.metadata[$k] // "") == $s' ''
mut stale-sem-status          $ON '.status == "in_progress" and ' ''
mut stale-sem-releitura       $ON '_fo_ok=$(printf '"'"'%s'"'"' "$_fo_bj" | jq' '_fo_ok=ok; : $(printf '"'"'%s'"'"' "$_fo_bj" | jq'
mut stale-vira-ok             $ON 'if [ "$_fo_ok" != ok ]; then _FC_RESULT=stale; return 0; fi' ':'
# a escrita
mut warn-so-sem-escrever      $ON 'if [ "$_fo_mode" != on ] || [ "${DRY_RUN:-0}" = "1" ]; then' 'if false; then'
mut dry-run-escreve           $ON 'if [ "$_fo_mode" != on ] || [ "${DRY_RUN:-0}" = "1" ]; then' 'if [ "$_fo_mode" != on ]; then'
mut modo-warn-escreve         $ON 'if [ "$_fo_mode" != on ] || [ "${DRY_RUN:-0}" = "1" ]; then' 'if [ "${DRY_RUN:-0}" = "1" ]; then'
mut rollback-fecha-sessao     $ON '"$_fo_store" 0 pilot.wa_node_alias "$_fo_sk"' '"$_fo_store" 1 pilot.wa_node_alias "$_fo_sk"'
mut rollback-sem-chave-sessao $ON 'pilot.wa_node_alias "$_fo_sk"; then' 'pilot.wa_node_alias; then'
mut held-vira-released        $ON '_FC_RESULT=held' '_FC_RESULT=released'
mut sem-comentario            $ON 'timeout 15 bd -C "$_fo_store" comments add' 'timeout 15 true -C "$_fo_store" comments add'
mut sem-warn-failed-create    $ON 'NÃO nasceu: failed-create' 'nasceu: ok'
mut sem-motivo-no-warn        $ON '— motivo: ${_fo_why:-a bead da sessão não diz}"' '"'
mut esfria-hetzner            $ON 'wa-worker-remote-mbp-*)' '*)'
mut esfria-so-se-solta        $ON '  case "$_fo_alias" in
    wa-worker-remote-mbp-*)' '  case "$_fo_alias$_FC_RESULT" in
    wa-worker-remote-mbp-*released)'
mut cool-secs-ruim            $ON '_fo_cool="${PILOT_MBP_COOL_SECS:-1800}"; case "$_fo_cool" in '"''"'|*[!0-9]*) _fo_cool=1800 ;; esac' '_fo_cool="${PILOT_MBP_COOL_SECS:-1800}"'
# a varredura
mut pass-sem-modo-off         $PA '[ "$_fp_mode" != off ] || return 0' ':'
mut pass-modo-ruim-escreve    $PA '*) warn "ga-dzexg3i.1: PILOT_NODE_FAILED_CREATE='"'"'$_fp_mode'"'"' não é on|warn|off — uso warn (só avisa, não escreve)"; _fp_mode=warn ;;' '*) _fp_mode=on ;;'
mut pass-lista-ilegivel       $PA 'if ! printf '"'"'%s'"'"' "$_fp_lj" | jq -e '"'"'type == "array"'"'"' >/dev/null 2>&1; then _fp_unk=$((_fp_unk + 1)); continue; fi' ':'
mut pass-sem-regex-alias      $PA '| select($a | test("^(wa|ps)-worker-remote(-mbp)?-[0-9]+$"))' ''
mut pass-sem-marca-igual-dono $PA '| select($mk == $a)' ''
mut pass-sem-forma-sessao     $PA '| select(($s | type) == "string" and ($s | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))' ''
mut pass-sem-teto             $PA 'if [ "$_fp_n" -ge "$_fp_max" ]; then break; fi' ':'
mut pass-teto-ruim            $PA "case \"\$_fp_max\" in ''|*[!0-9]*) _fp_max=6 ;; esac" ':'
mut pass-sem-loja-ps          $PA 'for _fp_pfx in wa ps; do' 'for _fp_pfx in wa; do'
mut pass-loja-vazia-lida      $PA 'if [ -z "$_fp_st" ]; then _fp_unk=$((_fp_unk + 1)); continue; fi' ':'
# o resfriamento
mut cool-arquivo-ausente      $CL '[ -e "$_c_file" ] || return 1' ':'
mut cool-ilegivel-livre       $CL '  if [ -z "$_c_until" ]; then
    if [ "${_PMC_WARNED:-0}" != 1 ]; then' '  if [ -z "$_c_until" ]; then
    return 1
    if [ "${_PMC_WARNED:-0}" != 1 ]; then'
mut cool-sem-aviso            $CL 'warn "ga-dzexg3i.1: $_c_file existe' ': "ga-dzexg3i.1: $_c_file existe'
mut cool-aviso-repete         $CL '_PMC_WARNED=1' ':'
mut cool-passado-esfria       $CL '[ "$((10#$_c_until))" -gt "$_c_now" ]' '[ "$((10#$_c_until))" -le "$_c_now" ]'
mut cool-octal                $CL '[ "$((10#$_c_until))" -gt "$_c_now" ]' '[ "$((_c_until))" -gt "$_c_now" ]'
mut cool-sem-limite-digitos   $CL '*) if [ "${#_c_until}" -gt 12 ]; then _c_until=""; fi ;;' '*) ;;'
mut set-encurta               $CS 'if [ "${#_cur}" -le 12 ] && [ "$((10#$_cur))" -ge "$_until" ]; then return 0; fi' ':'
mut set-zero-grava            $CS '[ "$((10#$_s))" -gt 0 ] || return 0' ':'
mut set-arg-ruim              $CS "case \"\$_s\" in ''|*[!0-9]*) return 1 ;; esac" ':'
mut set-sem-mv-atomico        $CS 'printf '"'"'%s\n'"'"' "$_until" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_file" 2>/dev/null' 'printf '"'"'%s\n'"'"' "$_until" > "$_file" 2>/dev/null'
mut set-falha-devolve-0       $CS '  warn "ga-dzexg3i.1: não consegui gravar $_file — a rota do MBP NÃO foi esfriada"
  return 1' '  warn "ga-dzexg3i.1: não consegui gravar $_file — a rota do MBP NÃO foi esfriada"
  return 0'
# a fiação
mut fia-sem-chamada           - '_pilot_node_failed_create_pass || true' ':'
mut fia-depois-do-evento      - '_pilot_node_failed_create_pass || true
' ''
mut rb-sem-confirmar          $RB 'if [ -z "$_rb_asg" ] && [ "$_rb_st" = open ] && [ -z "$_rb_mk" ]; then return 0; fi' 'return 0'

echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
[ $FAIL -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($FAIL)"; exit 1; }
