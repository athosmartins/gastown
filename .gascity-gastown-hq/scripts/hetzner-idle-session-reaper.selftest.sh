#!/usr/bin/env bash
# hetzner-idle-session-reaper.selftest.sh — ga-mu9k7m. Sessões e beads de MENTIRA: o gc e o bd aqui são scripts que leem arquivos; nada toca o gc, o bd nem o launchd de verdade.
# Uso: bash hetzner-idle-session-reaper.selftest.sh        (EXE_UNDER_TEST=<py> troca o executável, para provar o vermelho numa cópia)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
EXE=${EXE_UNDER_TEST:-$HERE/hetzner-idle-session-reaper.py}
T=$(mktemp -d "${TMPDIR:-/tmp}/idle-reaper-st.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check() { # check <nome> <esperado> <obtido>
  if [ "$2" = "$3" ]; then ok; else bad "$1: esperava [$2], veio [$3]"; fi
}

mkdir -p "$T/bin"
cat > "$T/bin/gc" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_DIR/gc.argv"
if [ "$3" = "session" ] && [ "$4" = "list" ]; then
  [ -f "$FAKE_DIR/gc.list.rc" ] && exit "$(cat "$FAKE_DIR/gc.list.rc")"
  cat "$FAKE_DIR/sessions.json"
  exit 0
fi
if [ "$3" = "session" ] && [ "$4" = "close" ]; then
  [ -f "$FAKE_DIR/gc.close.rc" ] && exit "$(cat "$FAKE_DIR/gc.close.rc")"
  echo "$5" >> "$FAKE_DIR/closed.log"
  exit 0
fi
exit 9
EOF
cat > "$T/bin/bd" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_DIR/bd.argv"
n=$(cat "$FAKE_DIR/bd.calls" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$FAKE_DIR/bd.calls"
[ -f "$FAKE_DIR/bd.rc" ] && exit "$(cat "$FAKE_DIR/bd.rc")"
if [ -f "$FAKE_DIR/beads.late.json" ] && [ "$n" -ge 2 ]; then cat "$FAKE_DIR/beads.late.json"; exit 0; fi
cat "$FAKE_DIR/beads.json"
EOF
chmod +x "$T/bin/gc" "$T/bin/bd"

new_world() { # new_world <nome>: uma cidade e um diretório de mentiras novos
  W="$T/$1"; CITY="$W/city"; FAKE="$W/fake"
  mkdir -p "$CITY/.gc" "$FAKE"
  echo '[]' > "$FAKE/beads.json"
  echo '{"sessions":[]}' > "$FAKE/sessions.json"
  : > "$FAKE/closed.log"
  STATE="$CITY/.gc/hetzner-idle-reaper.state.json"
}
row() { # row <id> <alias> <template> <state> [attached] [closed]
  printf '{"id":"%s","name":"%s","session_name":"%s-x","alias":"%s","template":"%s","state":"%s","attached":%s,"closed":%s}' "$1" "$2" "$2" "$2" "$3" "$4" "${5:-false}" "${6:-false}"
}
sessions() { # sessions <linha>...
  local out="" r
  for r in "$@"; do out="${out:+$out,}$r"; done
  printf '{"sessions":[%s]}\n' "$out" > "$FAKE/sessions.json"
}
bead() { # bead <assignee> [status]
  printf '[{"id":"ga-b1","status":"%s","assignee":"%s"}]\n' "${2:-in_progress}" "$1" > "$FAKE/beads.json"
}
seed() { # seed <id> <desde> <vivas_seguidas>: estado de uma rodada anterior
  printf '{"versao":1,"sessoes":{"%s":{"desde":%s,"vivas_seguidas":%s}},"atualizado_em":%s}\n' "$1" "$2" "$3" "$2" > "$STATE"
}
reap() { # reap <epoch> [args...]  -> RC; saída em $W/out e $W/err
  local now="$1"
  shift
  env -i PATH="/usr/bin:/bin" HOME="$W" GC_CITY_PATH="$CITY" GC_BIN="$T/bin/gc" BD_BIN="$T/bin/bd" FAKE_DIR="$FAKE" HETZNER_REAP_NOW="$now" python3 -I "$EXE" "$@" > "$W/out" 2> "$W/err"
  RC=$?
}
closed() { tr '\n' ' ' < "$FAKE/closed.log" | sed 's/ $//'; }
sum() { if [ -f "$1" ]; then cksum < "$1"; else echo ausente; fi; }
T0=1000000

# 1. o zumbi: sem bead, vivo. Fecha só quando o relógio passa de 15 min E o viu vivo em 2 rodadas (3ª leitura, 20 min depois)
new_world zumbi
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
reap $T0
check "zumbi: 1ª leitura sai 0" 0 "$RC"
check "zumbi: 1ª leitura não fecha" "" "$(closed)"
reap $((T0+600))
check "zumbi: 2ª leitura (10 min) não fecha" "" "$(closed)"
reap $((T0+1200))
check "zumbi: 3ª leitura (20 min) fecha a sessão certa" "ga-aaa" "$(closed)"
odd=$(grep -v -E -e "^--city $CITY session list --json$" -e "^--city $CITY session close ga-aaa$" "$FAKE/gc.argv" | wc -l | tr -d ' ')
check "zumbi: o gc só lista e fecha (nada de kill/nudge/mail)" 0 "$odd"
odd=$(grep -v -E -e "^-C $CITY list --include-infra --status open,in_progress --json --limit 0$" "$FAKE/bd.argv" | wc -l | tr -d ' ')
check "zumbi: o bd só lê, com a forma que a produção já usa" 0 "$odd"
check "zumbi: linha no hetzner-occupancy.jsonl" 1 "$(grep -c -F '"ga-aaa"' "$CITY/.gc/hetzner-occupancy.jsonl")"
check "zumbi: log por sessão" 1 "$(grep -c -F '"evento":"fechada"' "$CITY/.gc/hetzner-idle-reaper.jsonl")"
reap $((T0+1800))
check "zumbi: depois de fechada não fecha de novo" "ga-aaa" "$(closed)"

# 2. bead in_progress no alias: nunca fecha, nem depois de 40 min
new_world comBead
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
bead dog-remote-1
for d in 0 600 1200 2400; do reap $((T0+d)); done
check "bead in_progress no alias: não fecha" "" "$(closed)"

# 3. bead ABERTA no session_name também segura a sessão (a in_progress sozinha não basta)
new_world comBeadAberta
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
bead dog-remote-1-x open
for d in 0 600 1200 2400; do reap $((T0+d)); done
check "bead aberta no session_name: não fecha" "" "$(closed)"

# 4. o bd que falha, devolve lixo ou vem vazio nunca vira "sem bead": nada fecha e o estado não anda
new_world bdFalha
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
before=$(sum "$STATE")
echo 1 > "$FAKE/bd.rc"
reap $T0
check "bd rc 1: não fecha" "" "$(closed)"
check "bd rc 1: estado intacto" "$before" "$(sum "$STATE")"
rm -f "$FAKE/bd.rc"
echo 'isto nao e json' > "$FAKE/beads.json"
reap $((T0+600))
check "bd com lixo: não fecha" "" "$(closed)"
: > "$FAKE/beads.json"
reap $((T0+1200))
check "bd com saída vazia: não fecha" "" "$(closed)"
echo '{"erro":"x"}' > "$FAKE/beads.json"
reap $((T0+1800))
check "bd com forma desconhecida: não fecha" "" "$(closed)"
check "bd ilegível: estado intacto até o fim" "$before" "$(sum "$STATE")"

# 5. a lista de sessões ilegível: não fecha
new_world gcFalha
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
echo 1 > "$FAKE/gc.list.rc"
reap $T0
check "gc list rc 1: não fecha" "" "$(closed)"
rm -f "$FAKE/gc.list.rc"
echo 'lixo' > "$FAKE/sessions.json"
reap $((T0+600))
check "gc list com lixo: não fecha" "" "$(closed)"
: > "$FAKE/sessions.json"
reap $((T0+1200))
check "gc list vazio: não fecha" "" "$(closed)"
echo '{"ok":false,"sessions":[{"id":"ga-aaa","name":"dog-remote-1","alias":"dog-remote-1","template":"dog-remote","state":"active","closed":false}]}' > "$FAKE/sessions.json"
reap $((T0+1800))
check "gc list com envelope de erro: não fecha" "" "$(closed)"
echo '{"sessions":"nao-e-lista"}' > "$FAKE/sessions.json"
reap $((T0+2400))
check "gc list sem lista: não fecha" "" "$(closed)"

# 6. o arquivo .off desliga (com tudo pronto para fechar)
new_world desligado
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
touch "$CITY/.gc/hetzner-idle-reaper.off"
reap $T0
check "com .off: sai 0" 0 "$RC"
check "com .off: não fecha" "" "$(closed)"
check "com .off: não lê nada" "" "$(cat "$FAKE/bd.argv" "$FAKE/gc.argv" 2>/dev/null)"
rm -f "$CITY/.gc/hetzner-idle-reaper.off"
reap $((T0+600))
check "sem o .off volta a valer" "ga-aaa" "$(closed)"

# 7. sessão com gente anexada não fecha
new_world anexada
sessions "$(row ga-aaa dog-remote-1 dog-remote active true)"
seed ga-aaa 1 9
reap $T0
check "anexada: não fecha" "" "$(closed)"

# 8. outros templates nunca são tocados (crew, mayor, wa-worker-remote: a bead dela mora noutra loja)
new_world outros
sessions "$(row ga-c1 crew-x crew active)" "$(row ga-m1 mayor mayor active)" "$(row ga-w1 wa-worker-remote-1 wa-worker-remote active)" "$(row ga-aaa dog-remote-1 dog-remote active)"
bead dog-remote-1
for d in 0 600 1200 2400; do reap $((T0+d)); done
check "outros templates: nada fecha" "" "$(closed)"

# 9. gate-reviewer-remote também entra
new_world revisor
sessions "$(row ga-r1 gate-reviewer-remote-adhoc-1 gate-reviewer-remote active)"
seed ga-r1 1 9
reap $T0
check "gate-reviewer-remote sem bead: fecha" "ga-r1" "$(closed)"

# 10. a bead que chega entre a leitura e o fechamento (2ª leitura do bd, logo antes do close) salva a sessão
new_world corrida
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
bead dog-remote-1 > /dev/null
echo '[]' > "$FAKE/beads.json"
printf '[{"id":"ga-b1","status":"in_progress","assignee":"dog-remote-1"}]\n' > "$FAKE/beads.late.json"
reap $T0
check "corrida: bead que chega antes do close salva a sessão" "" "$(closed)"
check "corrida: o bd foi lido de novo antes de fechar" 2 "$(cat "$FAKE/bd.calls")"

# 11. dormindo/acordando (o laço do engine): o relógio corre pelas sestas, mas só fecha com 2 rodadas VIVAS seguidas
new_world sesta
seed ga-aaa $T0 1
sessions "$(row ga-aaa dog-remote-1 dog-remote asleep)"
reap $((T0+600))
check "sesta: dormindo não fecha" "" "$(closed)"
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
reap $((T0+1200))
check "sesta: acordou há 1 rodada, relógio velho: ainda não fecha" "" "$(closed)"
reap $((T0+1800))
check "sesta: viva em 2 rodadas seguidas, relógio velho: fecha" "ga-aaa" "$(closed)"

# 12. a bead que aparece zera o relógio
new_world zera
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
reap $T0
reap $((T0+600))
bead dog-remote-1
reap $((T0+1200))
echo '[]' > "$FAKE/beads.json"
reap $((T0+1800))
check "zera: 1ª leitura sem bead depois dela (o relógio velho já fecharia aqui): não fecha" "" "$(closed)"
reap $((T0+2400))
check "zera: 10 min depois da 1ª leitura sem bead: não fecha" "" "$(closed)"
reap $((T0+3000))
check "zera: 20 min depois da 1ª leitura sem bead: fecha" "ga-aaa" "$(closed)"

# 13. linha sem id (ou com "-") nunca vira `gc session close -`
new_world semId
sessions '{"name":"dog-remote-1","alias":"dog-remote-1","template":"dog-remote","state":"active","closed":false}' "$(row - dog-remote-2 dog-remote active)" "$(row '' dog-remote-3 dog-remote active)"
printf '{"versao":1,"sessoes":{"-":{"desde":1,"vivas_seguidas":9},"":{"desde":1,"vivas_seguidas":9}},"atualizado_em":1}\n' > "$STATE"
reap $T0
reap $((T0+600))
check "sem id: não fecha" "" "$(closed)"
check "sem id: nenhum session close" 0 "$(grep -c 'session close' "$FAKE/gc.argv")"

# 14. fechar que falha: registra, mantém o relógio e tenta de novo na rodada seguinte
new_world fechaFalha
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
echo 1 > "$FAKE/gc.close.rc"
reap $T0
check "close falhou: sai 0" 0 "$RC"
check "close falhou: nada na lista de fechadas" "" "$(closed)"
check "close falhou: log por sessão" 1 "$(grep -c -F '"evento":"fechar-falhou"' "$CITY/.gc/hetzner-idle-reaper.jsonl")"
rm -f "$FAKE/gc.close.rc"
reap $((T0+600))
check "close falhou: a rodada seguinte fecha" "ga-aaa" "$(closed)"

# 15. --dry-run mostra e não faz nem grava nada
new_world seco
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
before=$(sum "$STATE")
reap $T0 --dry-run
check "dry-run: sai 0" 0 "$RC"
check "dry-run: não fecha" "" "$(closed)"
check "dry-run: estado intacto" "$before" "$(sum "$STATE")"
check "dry-run: sem log" ausente "$(sum "$CITY/.gc/hetzner-idle-reaper.jsonl")"
check "dry-run: diz que fecharia" 1 "$(grep -c -F 'ga-aaa' "$W/out")"

# 16. sessão já fechada ou com `closed` ausente (estado desconhecido) não é fechada
new_world fechadaOuDuvida
sessions "$(row ga-aaa dog-remote-1 dog-remote active false true)" '{"id":"ga-bbb","name":"dog-remote-2","alias":"dog-remote-2","template":"dog-remote","state":"active"}'
printf '{"versao":1,"sessoes":{"ga-aaa":{"desde":1,"vivas_seguidas":9},"ga-bbb":{"desde":1,"vivas_seguidas":9}},"atualizado_em":1}\n' > "$STATE"
reap $T0
check "closed:true e closed ausente: não fecha" "" "$(closed)"

# 17. estado corrompido: recomeça do zero (não fecha de primeira) e guarda a cópia
new_world corrompido
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
echo '{"versao":1,"sessoes":' > "$STATE"
reap $T0
check "estado corrompido: não fecha" "" "$(closed)"
check "estado corrompido: a cópia fica" 1 "$(ls "$CITY/.gc" | grep -c 'hetzner-idle-reaper.state.json.corrupt-')"

# 18. a sessão que sumiu da lista sai do estado (sem acumular lixo)
new_world sumiu
seed ga-velha 1 9
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
reap $T0
check "sumiu: a sessão que não está mais na lista sai do estado" 0 "$(grep -c -F 'ga-velha' "$STATE")"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
