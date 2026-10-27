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
  [ -f "$FAKE_DIR/gc.list.hang" ] && { echo $$ > "$FAKE_DIR/gc.pid"; exec sleep 20; }
  [ -f "$FAKE_DIR/gc.list.rc" ] && exit "$(cat "$FAKE_DIR/gc.list.rc")"
  cat "$FAKE_DIR/sessions.json"
  exit 0
fi
if [ "$3" = "session" ] && [ "$4" = "close" ]; then
  [ -f "$FAKE_DIR/gc.close.err" ] && cat "$FAKE_DIR/gc.close.err" >&2
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
[ -f "$FAKE_DIR/bd.err" ] && cat "$FAKE_DIR/bd.err" >&2
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
  env -i PATH="/usr/bin:/bin" HOME="$W" GC_CITY_PATH="$CITY" GC_BIN="$T/bin/gc" BD_BIN="$T/bin/bd" FAKE_DIR="$FAKE" HETZNER_REAP_NOW="$now" $REAP_X python3 -I "$EXE" "$@" > "$W/out" 2> "$W/err"
  RC=$?
}
closed() { tr '\n' ' ' < "$FAKE/closed.log" | sed 's/ $//'; }
sum() { if [ -f "$1" ]; then cksum < "$1"; else echo ausente; fi; }
T0=1000000
REAP_X=""  # VAR=valor (sem espaço no valor) a mais no ambiente da próxima rodada; quem usa zera depois

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

# 1b. kimi-worker-remote (ga-do1ixn.5) está nos templates padrão: o zumbi dele fecha como o do dog; o wa-worker-remote continua de fora
new_world kimi
sessions "$(row ga-kkk kimi-worker-remote-1 kimi-worker-remote active)" "$(row ga-www wa-worker-remote-1 wa-worker-remote active)"
reap $T0; reap $((T0+600)); reap $((T0+1200))
check "kimi: o zumbi kimi-worker-remote fecha com o padrão de templates (o wa-worker-remote não)" "ga-kkk" "$(closed)"

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
before=$(sum "$STATE")
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
check "gc ilegível: estado intacto até o fim" "$before" "$(sum "$STATE")"

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
check "estado corrompido: sai 0" 0 "$RC"
check "estado corrompido: não fecha" "" "$(closed)"
check "estado corrompido: a cópia fica" 1 "$(ls "$CITY/.gc" | grep -c 'hetzner-idle-reaper.state.json.corrupt-')"
reap $((T0+600))
reap $((T0+1200))
check "estado corrompido: recomeça do zero e fecha na 3ª leitura" "ga-aaa" "$(closed)"

# 18. a sessão que sumiu da lista sai do estado (sem acumular lixo)
new_world sumiu
seed ga-velha 1 9
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
reap $T0
check "sumiu: a sessão que não está mais na lista sai do estado" 0 "$(grep -c -F 'ga-velha' "$STATE")"

# 19. nenhuma sessão dos nossos templates: o bd nem é chamado (o Dolt fora do ar não atrapalha)
new_world semNossa
sessions "$(row ga-c1 crew-x crew active)"
reap $T0
check "sem sessão nossa: sai 0" 0 "$RC"
check "sem sessão nossa: o bd não é chamado" ausente "$(sum "$FAKE/bd.calls")"

# 20-28. o que o hq-mutants achou sem teste (ga-lwbl088): um token trocado no reaper e nenhuma bateria acima reprovava. Cada caso abaixo nasceu de um mutante e reprova nele.
# Fora daqui de propósito, por serem equivalentes (nada que um chamador consiga ler muda): o `0` de `return None, 0, <motivo>` em read_sessions. O 2º item da tupla (ilegiveis)
# só é lido quando o 3º (motivo) vem vazio; com motivo, run() imprime e sai antes de usá-lo. Trocar esse 0 por 1 não muda saída, estado nem código de saída.
# Também equivalentes (ga-u6ueg0q): o universal_newlines=True do Popen em run_cmd (com errors= dado, o Popen já abre em modo texto e traduz a quebra de linha do mesmo jeito); os 5 s do
# communicate que espera o cano fechar depois do SIGKILL (só um neto que sai do grupo e segura o cano faria 5 e 6 diferirem, e isso é segundo de relógio, não resultado); o `is not None`
# do elif de run() que arma held (rows só é None junto com um motivo, e aí a rodada já saiu; com rows vazio o laço não roda e held não é lido); e o `<=` do relógio que recuou
# (com desde == agora os dois lados dão agora).

# 20. o teto padrão (HETZNER_REAP_GRACE_S, 900 s) vale no segundo exato: com 900 s ainda não fecha, com 901 s fecha
new_world teto
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa $T0 9
reap $((T0+900))
check "teto: 900 s sem bead ainda não fecha" "" "$(closed)"
reap $((T0+901))
check "teto: 901 s sem bead fecha" "ga-aaa" "$(closed)"

# 21. os padrões e os mínimos da configuração, lidos do módulo: o teto de 60 s do gc e do bd não se mede esperando 60 s, mede-se o que run_cmd entrega ao communicate
# vazio → o python não imprime nada e o check falha; falhou/ilegível → idem (nada aqui lê arquivo além do próprio módulo sob teste)
cfg=$(python3 -I - "$EXE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("reaper_sob_teste", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
tetos = []
class Popen:  # no lugar do subprocesso: só anota o teto que run_cmd passa ao communicate
    returncode = 0
    def __init__(self, argv, **kw):
        pass
    def communicate(self, timeout=None):
        tetos.append(timeout)
        return "[]", ""
m.subprocess.Popen = Popen
c = m.load_config({"GC_CITY_PATH": "/nao/existe"})
m.read_sessions(c)
m.read_holders(c)
print("tetos", *tetos)
def aceita(chave, v):
    try:
        m.load_config({"GC_CITY_PATH": "/nao/existe", chave: v})
        return "aceita"
    except ValueError:
        return "recusa"
for chave, minimo in (("HETZNER_REAP_GRACE_S", 60), ("HETZNER_REAP_MIN_LIVE_RUNS", 1), ("HETZNER_REAP_GC_TIMEOUT_S", 1), ("HETZNER_REAP_BD_TIMEOUT_S", 1)):
    print(chave, minimo - 1, aceita(chave, str(minimo - 1)), minimo, aceita(chave, str(minimo)))
PY
)
want=$(printf '%s\n' "tetos 60 60" "HETZNER_REAP_GRACE_S 59 recusa 60 aceita" "HETZNER_REAP_MIN_LIVE_RUNS 0 recusa 1 aceita" "HETZNER_REAP_GC_TIMEOUT_S 0 recusa 1 aceita" "HETZNER_REAP_BD_TIMEOUT_S 0 recusa 1 aceita")
check "config: gc e bd rodam com teto de 60 s; cada variável aceita o mínimo e recusa um a menos" "$want" "$cfg"

# 22. o texto do erro que vai para o log e para a mensagem é cortado em 160 (gc close) e 80 (bd) caracteres, nem um a mais
new_world corte
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
head -c 300 /dev/zero | tr '\0' x > "$FAKE/gc.close.err"
echo 1 > "$FAKE/gc.close.rc"
reap $T0
# vazio/ausente → 0 linhas e o check falha; ilegível → grep sai 2 sem contar, o $(…) vira vazio e o check falha
check "close que falha: o detalhe do erro tem 160 caracteres" 1 "$(grep -c -E '"detalhe":"x{160}"' "$CITY/.gc/hetzner-idle-reaper.jsonl" 2>/dev/null)"
new_world corteBd
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
head -c 300 /dev/zero | tr '\0' x > "$FAKE/bd.err"
echo 1 > "$FAKE/bd.rc"
reap $T0
check "bd que falha: o erro na mensagem tem 80 caracteres" 1 "$(grep -c -E 'bd-falhou x{80} \(' "$W/out")"

# 23. entrada torta no estado (valor que não é inteiro >= 0, entrada sem campo, entrada que nem objeto é) é descartada: o relógio dela recomeça, ninguém fecha e a rodada não cai
new_world estadoTorto
sessions "$(row ga-t1 dog-remote-1 dog-remote active)" "$(row ga-t2 dog-remote-2 dog-remote active)" "$(row ga-t3 dog-remote-3 dog-remote active)" "$(row ga-t4 dog-remote-4 dog-remote active)" "$(row ga-t5 dog-remote-5 dog-remote active)" "$(row ga-t6 dog-remote-6 dog-remote active)" "$(row ga-t7 dog-remote-7 dog-remote active)" "$(row ga-t8 dog-remote-8 dog-remote active)" "$(row ga-t9 dog-remote-9 dog-remote active)"
cat > "$STATE" <<'EOF'
{"versao":1,"atualizado_em":1,"sessoes":{
 "ga-t1":{"desde":-5,"vivas_seguidas":9},
 "ga-t2":{"desde":true,"vivas_seguidas":9},
 "ga-t3":{"desde":"1","vivas_seguidas":9},
 "ga-t4":{"desde":1.0,"vivas_seguidas":9},
 "ga-t5":{"desde":1,"vivas_seguidas":true},
 "ga-t6":{"vivas_seguidas":9},
 "ga-t7":{"desde":1},
 "ga-t8":5,
 "ga-t9":null}}
EOF
reap $T0
check "estado com entradas tortas: sai 0" 0 "$RC"
check "estado com entradas tortas: nenhuma fecha (o relógio de cada uma recomeça)" "" "$(closed)"

# 24. o aviso de estado corrompido diz a verdade sobre a cópia: a rodada de verdade a guarda ("ficou em"), o --dry-run só diz que iria ("iria para") e não mexe no arquivo
# vazio/ausente → grep conta 0 e os checks que esperam 1 falham; falhou/ilegível → o grep não conta, o $(…) vem vazio e eles falham do mesmo jeito. O que espera 0 (nenhuma cópia) só vale
# se o diretório foi lido de fato: o check anterior prova que o `ls` listou o estado.
new_world corrompidoReal
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
echo '{"versao":1,"sessoes":' > "$STATE"
reap $T0
check "estado corrompido: o aviso diz onde a cópia ficou" 1 "$(grep -c -F 'a cópia ficou em' "$W/err")"
new_world corrompidoSeco
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
echo '{"versao":1,"sessoes":' > "$STATE"
reap $T0 --dry-run
check "dry-run com estado corrompido: o aviso diz que a cópia IRIA" 1 "$(grep -c -F '(--dry-run) a cópia iria para' "$W/err")"
check "dry-run com estado corrompido: o diretório foi lido (o estado está na listagem)" 1 "$(ls "$CITY/.gc" | grep -c -x -F 'hetzner-idle-reaper.state.json')"
check "dry-run com estado corrompido: nenhuma cópia é feita" 0 "$(ls "$CITY/.gc" | grep -c 'corrupt-')"
check "dry-run com estado corrompido: o arquivo fica onde estava" 1 "$(grep -c -F '"sessoes":' "$STATE")"

# 25. o bd que devolve elemento de forma errada (não-objeto; assignee que não é texto) é "forma desconhecida": nada fecha, o estado não anda e a rodada não cai
new_world bdTorto
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
before=$(sum "$STATE")
echo '[5]' > "$FAKE/beads.json"
reap $T0
check "bd com elemento que não é objeto: sai 0" 0 "$RC"
check "bd com elemento que não é objeto: não fecha" "" "$(closed)"
echo '[{"id":"ga-b1","status":"open","assignee":5}]' > "$FAKE/beads.json"
reap $((T0+600))
check "bd com assignee que não é texto: sai 0" 0 "$RC"
check "bd com assignee que não é texto: não fecha" "" "$(closed)"
check "bd torto: estado intacto" "$before" "$(sum "$STATE")"

# 26. o nome mostrado da sessão: name, senão session_name, senão alias, senão "?" (lido do --dry-run, que lista "fecharia: <id> (<nome>)")
new_world nome
sessions '{"id":"ga-n1","name":"n-name","session_name":"n-sess","alias":"n-alias","template":"dog-remote","state":"active","closed":false}' \
         '{"id":"ga-n2","session_name":"n-sess","alias":"n-alias","template":"dog-remote","state":"active","closed":false}' \
         '{"id":"ga-n3","alias":"n-alias","template":"dog-remote","state":"active","closed":false}' \
         '{"id":"ga-n4","template":"dog-remote","state":"active","closed":false}'
printf '{"versao":1,"sessoes":{"ga-n1":{"desde":1,"vivas_seguidas":9},"ga-n2":{"desde":1,"vivas_seguidas":9},"ga-n3":{"desde":1,"vivas_seguidas":9},"ga-n4":{"desde":1,"vivas_seguidas":9}},"atualizado_em":1}\n' > "$STATE"
reap $T0 --dry-run
# vazio → nenhuma linha "fecharia" e o check falha; falhou/ilegível → idem
check "nome: name, depois session_name, depois alias, depois '?'" "ga-n1 (n-name) ga-n2 (n-sess) ga-n3 (n-alias) ga-n4 (?)" "$(sed -n 's/^  fecharia: //p' "$W/out" | sed 's/ sem bead .*//' | tr '\n' ' ' | sed 's/ $//')"

# 27. o resumo da rodada conta a sessão que segura bead
new_world resumo
sessions "$(row ga-aaa dog-remote-1 dog-remote active)" "$(row ga-bbb dog-remote-2 dog-remote active)"
bead dog-remote-1
reap $T0
check "resumo: 2 sessões, 1 com bead, nada fechado" "sessoes=2 com_bead=1 fechadas=0 falhas=0 ilegiveis=0" "$(sed 's/^[^ ]* //' "$W/out")"

# 28. o que a rodada grava, byte a byte (chaves em ordem, JSON compacto nos logs, o estado com recuo de 1 espaço, acento sem escape): o estado, o log por sessão e a linha de ocupação
# (o ts é a hora local de quem roda: sai do texto antes de comparar)
new_world bytes
sessions "$(row ga-aaa dog-remote-é dog-remote active)" "$(row ga-bbé dog-remote-2 dog-remote active)"
seed ga-aaa 1 9
reap $T0
check "bytes: a rodada fechou só a ga-aaa" "ga-aaa" "$(closed)"
# vazio/ausente → o texto lido é vazio e não bate com o esperado: o check falha; ilegível → idem
want=$(printf '{\n "atualizado_em": %s,\n "sessoes": {\n  "ga-bbé": {\n   "desde": %s,\n   "vivas_seguidas": 1\n  }\n },\n "versao": 1\n}' $T0 $T0)
check "bytes: o estado gravado" "$want" "$(cat "$STATE" 2>/dev/null)"
want=$(printf '{"epoch":%s,"evento":"fechada","id":"ga-aaa","nome":"dog-remote-é","ocioso_s":%s,"ts":"T","vivas_seguidas":10}' $T0 $((T0-1)))
check "bytes: a linha do log por sessão" "$want" "$(sed 's/"ts":"[^"]*"/"ts":"T"/' "$CITY/.gc/hetzner-idle-reaper.jsonl" 2>/dev/null)"
want=$(printf '{"epoch":%s,"falhas":[],"fechadas":[{"id":"ga-aaa","nome":"dog-remote-é","ocioso_s":%s}],"tipo":"reaper","ts":"T"}' $T0 $((T0-1)))
check "bytes: a linha do hetzner-occupancy.jsonl" "$want" "$(sed 's/"ts":"[^"]*"/"ts":"T"/' "$CITY/.gc/hetzner-occupancy.jsonl" 2>/dev/null)"


# 29-34. o que o lastro ainda achou sem teste (ga-u6ueg0q): código de saída de cada falha, o gc que trava, a trava de instância, a cópia do estado corrompido, o prefixo do template e a contagem de ilegíveis

# 29. quem não consegue gravar ou ler a pasta de estado sai 3 (rodada de verdade e --dry-run); configuração inválida, e qualquer exceção solta, sai 1 com o traceback à vista
new_world semGravar
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
rm -rf "$CITY/.gc"; : > "$CITY/.gc"
reap $T0
check "pasta .gc que é um arquivo: a rodada de verdade sai 3" 3 "$RC"
check "pasta .gc que é um arquivo: diz que não conseguiu gravar" 1 "$(grep -c -F 'não consegui gravar em' "$W/err")"
reap $T0 --dry-run
check "pasta .gc que é um arquivo: o --dry-run sai 3 (não consegue ler o estado)" 3 "$RC"
check "pasta .gc que é um arquivo: o --dry-run diz que não conseguiu ler" 1 "$(grep -c -F 'não consegui ler' "$W/err")"
new_world configRuim
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
REAP_X="HETZNER_REAP_GRACE_S=59"; reap $T0; REAP_X=""
check "configuração abaixo do mínimo: sai 1" 1 "$RC"
check "configuração abaixo do mínimo: o traceback fica à vista, com a variável e o mínimo" 1 "$(grep -c -E '^ValueError: HETZNER_REAP_GRACE_S=59 abaixo do mínimo 60' "$W/err")"
check "configuração abaixo do mínimo: não fecha" "" "$(closed)"

# 30. outra instância com a trava: a rodada de verdade sai 0 sem ler nem fechar nada; o --dry-run não precisa da trava e lê mesmo assim; solta a trava, a rodada volta a fechar
new_world trava
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
before=$(sum "$STATE")
python3 -I -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").write("travada")
time.sleep(60)' "$CITY/.gc/hetzner-idle-reaper.lock" "$W/travada" &
HOLDER=$!
i=0; while [ ! -s "$W/travada" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
# vazio → a trava não foi tomada a tempo e a rodada abaixo fecharia a ga-aaa: os checks de "não fecha" falham
reap $T0
check "trava ocupada: sai 0" 0 "$RC"
check "trava ocupada: não fecha" "" "$(closed)"
check "trava ocupada: o estado não anda" "$before" "$(sum "$STATE")"
check "trava ocupada: diz que outra instância está rodando" 1 "$(grep -c -F 'outra instância ainda está rodando' "$W/err")"
check "trava ocupada: não lê nada" ausente "$(sum "$FAKE/gc.argv")"
reap $T0 --dry-run
check "dry-run com a trava ocupada: sai 0" 0 "$RC"
check "dry-run com a trava ocupada: não precisa dela e diz o que fecharia" 1 "$(grep -c -F 'fecharia: ga-aaa' "$W/out")"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
reap $T0
check "trava solta: a rodada fecha" "ga-aaa" "$(closed)"

# 31. dois estados corrompidos no mesmo segundo não pisam na cópia um do outro: a 1ª colisão vai para -2, a 2ª para -3
new_world corrompidoDuas
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
: > "$STATE.corrupt-$T0"
echo '{"versao":1,"sessoes":' > "$STATE"
reap $T0
check "cópia que já existe: a nova vai para -2" 1 "$(ls "$CITY/.gc" | grep -c -x -F "hetzner-idle-reaper.state.json.corrupt-$T0-2")"
check "cópia que já existe: a antiga fica como estava" 0 "$(wc -c < "$STATE.corrupt-$T0" | tr -d ' ')"
echo '{"versao":1,"sessoes":' > "$STATE"
reap $T0
check "duas cópias que já existem: a nova vai para -3" 1 "$(ls "$CITY/.gc" | grep -c -x -F "hetzner-idle-reaper.state.json.corrupt-$T0-3")"
check "duas cópias que já existem: a -2 não foi pisada" 1 "$(grep -c -F '"sessoes":' "$STATE.corrupt-$T0-2")"

# 32. o template aparece com prefixo de rig ou de pacote (<rig>/<template>, <pack>.<template>): é nosso; quem só TERMINA igual, sem o separador, ou só começa igual, não é
new_world templates
sessions "$(row ga-p1 dog-remote-1 gastown/dog-remote active)" "$(row ga-p2 dog-remote-2 core.dog-remote active)" "$(row ga-p3 dog-remote-3 xdog-remote active)" "$(row ga-p4 dog-remote-4 gastown/xdog-remote active)" "$(row ga-p5 dog-remote-5 dog-remote-x active)"
printf '{"versao":1,"sessoes":{"ga-p1":{"desde":1,"vivas_seguidas":9},"ga-p2":{"desde":1,"vivas_seguidas":9},"ga-p3":{"desde":1,"vivas_seguidas":9},"ga-p4":{"desde":1,"vivas_seguidas":9},"ga-p5":{"desde":1,"vivas_seguidas":9}},"atualizado_em":1}\n' > "$STATE"
reap $T0
check "templates: fecha <rig>/<template> e <pack>.<template>, e só eles" "ga-p1 ga-p2" "$(closed)"

# 33. entrada da lista de sessões que não é objeto é contada em ilegiveis e mais nada acontece com ela
new_world ilegiveis
printf '{"sessions":[5,"texto",null,%s]}\n' "$(row ga-aaa dog-remote-1 dog-remote active)" > "$FAKE/sessions.json"
reap $T0
check "lista com 3 entradas que não são objeto: sai 0" 0 "$RC"
check "lista com 3 entradas que não são objeto: o resumo conta 3 ilegíveis" "sessoes=1 com_bead=0 fechadas=0 falhas=0 ilegiveis=3" "$(sed 's/^[^ ]* //' "$W/out")"

# 34. o gc que trava: estoura o teto, a rodada diz gc-timeout e o PROCESSO morre (não fica pendurado por trás), com o estado intacto
new_world gcTrava
sessions "$(row ga-aaa dog-remote-1 dog-remote active)"
seed ga-aaa 1 9
before=$(sum "$STATE")
: > "$FAKE/gc.list.hang"
REAP_X="HETZNER_REAP_GC_TIMEOUT_S=1"; reap $T0; REAP_X=""
pid=$(cat "$FAKE/gc.pid" 2>/dev/null)
# vazio → o gc de mentira não chegou a rodar: vira "sem-pid" e o check falha
if [ -z "$pid" ]; then vivo=sem-pid; elif kill -0 "$pid" 2>/dev/null; then vivo=vivo; kill -9 "$pid" 2>/dev/null; else vivo=morto; fi
check "gc que trava: o processo foi morto ao estourar o teto" morto "$vivo"
check "gc que trava: a rodada diz gc-timeout e não fecha" 1 "$(grep -c -F 'gc-timeout' "$W/out")"
check "gc que trava: o estado não anda" "$before" "$(sum "$STATE")"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
