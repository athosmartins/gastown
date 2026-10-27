#!/usr/bin/env bash
# hetzner-occupancy-watch.selftest.sh — hermético: gc e ssh são stubs; a cidade, o HOME, o arquivo do Pilot e o /proc/stat são sintéticos; nada fala com o servidor, o Pilot nem o mail de verdade. (ga-2hd02v.1.12)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS (grupos, na ordem): cfg (configuração em vigor, plist, gramática do Python 3.9) · sess (sessões remotas: 3 estados, MBP fora) · cpu (/proc/stat por ssh: baseline, janela, recuo de contador,
#   ssh que cai ou trava) · fila (arquivo do Pilot: ausente/velho/futuro/ilegível NÃO é zero; lojas) · estado (ocupado / ocioso / desconhecido: a tabela inteira) · alarme (sequência de 30 min, jitter, cooldown,
#   mail que falha, modo foco, chave de ligar, vigia cego) · baixa (aviso de CPU baixa, ga-2hd02v.6: CPU média < 85 % por 30 min, sem olhar fila, sessão nem foco; vigia cego para a CPU; o número por dia é a média de CPU) · saida (JSONL, número por dia, arquivos corrompidos, --dry-run, instância única, crash e falha de gravação, nada fora de .gc).
# CONTROLE NEGATIVO: cada mutante (um trecho literal do script trocado, que tem de existir UMA vez) TEM de reprovar o grupo que o pega; mutante que passa = teste que não pega o bug. Só roda sem argumento e com o script de verdade.
#   Cada mutante roda em segundo plano com o PRÓPRIO diretório temporário e para no 1º caso que reprova (o resto do grupo não diz nada de novo): sem isso eram ~80 grupos inteiros em série, mais de 10 min.
#   EQUIVALENTE (ga-u6ueg0q): `universal_newlines=True` no Popen de run_cmd não tem caso que o separe do False: com `errors="replace"` o subprocess já abre os canais em texto e traduz a quebra de linha,
#   então as duas formas devolvem a mesma saída.
# COMO RODAR: hetzner-occupancy-watch.selftest.sh [grupo ...]   (sem argumento: todos os grupos e o controle negativo). HETZNER_OCC_UNDER_TEST=<script> roda a suíte contra outra cópia.
#   HOCC_JOBS=N mutantes ao mesmo tempo (padrão 4; 1 = em série) · HOCC_NO_MUTANTS=1 pula o controle negativo (290 dos 370 casos, ~40 s no Linux) · HOCC_SLOW_START=N faz o python do vigia levar N s para subir, como o mini sob carga (com HOCC_NO_MUTANTS=1).
#   Tudo: ~140 s no Linux; no mini, sob carga, a fatia 1 sozinha (238 verificações; hoje são 370) levou ~7 min (medido pelo gate em 19/10). RELÓGIO: nenhum caso mede o tempo de parede do vigia (no mini sob carga só subir o python já passou de 1 s, 19/10): a ordem das duas instâncias é por EVENTO (await) e o único prazo, o do run_cmd, é medido dentro do python.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="${HETZNER_OCC_UNDER_TEST:-$HERE/hetzner-occupancy-watch.py}"
PLIST="$HERE/com.gascity.hetzner-occupancy-watch.plist"
FOCUS_LIB="$HERE/../packs/town-deltas/assets/scripts/gate-focus-lib.sh"
[ -f "$WATCH" ] || { echo "FATAL: $WATCH não existe — não há o que testar" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/hocc-selftest.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/stub" "$T/tmp" "$T/mut" "$T/m" "$T/mutres"
PYC="$T/pycache"   # cache de bytecode do python que o W() sobe: fora do HOME falso, aquecido uma vez e dividido com os mutantes (a T deles muda; esta variável não)

fails=0; n=0; QUIET=0
ok()  { n=$((n+1)); [ "$QUIET" = 1 ] || echo "ok   $1"; }
bad() { n=$((n+1)); fails=$((fails+1)); [ "$QUIET" = 1 ] || echo "FAIL $1"; }
check() { if [ "$2" = 1 ]; then ok "$1"; else bad "$1"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: esperado '$2', veio '$3'"; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: '$2' ausente em: $(printf '%s' "$3" | head -c 300)" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1: '$2' presente" ;; *) ok "$1" ;; esac; }

# jv <arquivo> <caminho.pontuado> → o valor (bool em minúscula, null = "null", objeto/lista = JSON); arquivo ilegível ou caminho ausente → "<ilegivel>"/"null"
jv() { python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    for k in sys.argv[2].split("."):
        d = d[int(k)] if isinstance(d, list) else (d.get(k) if isinstance(d, dict) else None)
except Exception:
    print("<ilegivel>"); sys.exit(0)
print(json.dumps(d, ensure_ascii=False) if isinstance(d, (dict, list)) else "null" if d is None else str(d).lower() if isinstance(d, bool) else d)
' "$1" "$2"; }
# last_line <jsonl> → a última linha num arquivo à parte (para o jv)
last_line() { tail -n 1 "$1" > "$T/last.json" 2>/dev/null; }

# ---- stubs ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
cat > "$T/bin/gc" <<'EOF'
#!/usr/bin/env bash
# gc de mentira: `session list --json` devolve $STUB_GC_FILE (ou falha com $STUB_GC_RC; com $STUB_OUTFAIL imprime o JSON COMPLETO antes de falhar; com $STUB_GC_HOLD fica PRESO, avisando em hold.in, até o teste criar hold.go); `mail send` grava o mail; o resto é PROIBIDO (rc 99, marcado)
echo "gc $*" >> "$STUB_DIR/gc.calls"
args=("$@")
if [ "${args[0]:-}" = "--city" ]; then args=("${args[@]:2}"); fi
case "${args[0]:-} ${args[1]:-}" in
  "session list")
    [ -n "${STUB_GC_SLEEP:-}" ] && sleep "$STUB_GC_SLEEP"
    [ -n "${STUB_GC_HOLD:-}" ] && { echo in > "$STUB_DIR/hold.in"; i=0; while [ ! -e "$STUB_DIR/hold.go" ] && [ "$i" -lt 900 ]; do sleep 0.1; i=$((i+1)); done; }   # o teto (~90 s) só impede um teste morto de deixar isto vivo
    if [ "${STUB_GC_RC:-0}" != 0 ]; then echo "gc: erro injetado" >&2; [ -n "${STUB_OUTFAIL:-}" ] && [ -n "${STUB_GC_FILE:-}" ] && cat "$STUB_GC_FILE"; exit "$STUB_GC_RC"; fi
    [ -n "${STUB_GC_FILE:-}" ] && cat "$STUB_GC_FILE"
    exit 0 ;;
  "mail send")
    c=$(( $(cat "$STUB_DIR/mail.count" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$STUB_DIR/mail.count"
    to="${args[2]:-}"; subj=""; body=""; i=3
    while [ $i -lt ${#args[@]} ]; do
      case "${args[$i]}" in -s) subj="${args[$((i+1))]}"; i=$((i+2)) ;; -m) body="${args[$((i+1))]}"; i=$((i+2)) ;; *) i=$((i+1)) ;; esac
    done
    printf '%s' "$to" > "$STUB_DIR/mail.$c.to"; printf '%s' "$subj" > "$STUB_DIR/mail.$c.subj"; printf '%s' "$body" > "$STUB_DIR/mail.$c.body"
    echo "${STUB_MAIL_RC:-0}" > "$STUB_DIR/mail.$c.rc"
    [ -n "${STUB_STATE_FILE:-}" ] && [ -f "$STUB_STATE_FILE" ] && cp "$STUB_STATE_FILE" "$STUB_DIR/mail.$c.state"
    exit "${STUB_MAIL_RC:-0}" ;;
  *) echo "FORBIDDEN gc $*" >> "$STUB_DIR/forbidden.calls"; exit 99 ;;
esac
EOF
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# ssh de mentira: grava os argumentos; devolve $STUB_SSH_FILE (a saída que o servidor daria), ou falha com $STUB_SSH_RC (com $STUB_OUTFAIL imprime a saída COMPLETA antes de falhar), ou trava $STUB_SSH_SLEEP s
echo "$*" >> "$STUB_DIR/ssh.calls"
[ -n "${STUB_SSH_SLEEP:-}" ] && sleep "$STUB_SSH_SLEEP"
if [ "${STUB_SSH_RC:-0}" != 0 ]; then echo "ssh: erro injetado" >&2; [ -n "${STUB_OUTFAIL:-}" ] && [ -n "${STUB_SSH_FILE:-}" ] && cat "$STUB_SSH_FILE"; exit "$STUB_SSH_RC"; fi
[ -n "${STUB_SSH_FILE:-}" ] && cat "$STUB_SSH_FILE"
exit 0
EOF
cat > "$T/bin/bd" <<'EOF'
#!/usr/bin/env bash
# bd de mentira: a ÚNICA forma permitida é a leitura de quem segura bead (`-C <cidade> list --status in_progress --json --limit 0`): devolve $STUB_BD_FILE (ou falha com $STUB_BD_RC; com $STUB_OUTFAIL imprime o JSON COMPLETO antes de falhar; com $STUB_BD_SLEEP trava esses segundos); qualquer outra forma é PROIBIDA (rc 99, marcada)
echo "bd $*" >> "$STUB_DIR/bd.calls"
if [ "$#" -ne 8 ] || [ "$1" != "-C" ] || [ "$3 $4 $5 $6 $7 $8" != "list --status in_progress --json --limit 0" ]; then echo "FORBIDDEN bd $*" >> "$STUB_DIR/forbidden.calls"; exit 99; fi
[ -n "${STUB_BD_SLEEP:-}" ] && sleep "$STUB_BD_SLEEP"
if [ "${STUB_BD_RC:-0}" != 0 ]; then echo "bd: erro injetado" >&2; [ -n "${STUB_OUTFAIL:-}" ] && [ -n "${STUB_BD_FILE:-}" ] && cat "$STUB_BD_FILE"; exit "$STUB_BD_RC"; fi
[ -n "${STUB_BD_FILE:-}" ] && cat "$STUB_BD_FILE"
exit 0
EOF
for b in dolt notify; do   # o vigia NUNCA deve chamar dolt nem notify; o bd só na forma acima (uma leitura, nunca uma escrita)
  printf '#!/usr/bin/env bash\necho "FORBIDDEN %s $*" >> "$STUB_DIR/forbidden.calls"\nexit 99\n' "$b" > "$T/bin/$b"
done
# python3 de mentira (só o W() o vê: o PATH dele começa em $T/bin). O python do sistema do macOS (CLT 3.9) grava o bytecode em $HOME/Library/Caches/com.apple.python se o ambiente não manda parar; o do Linux não grava em HOME nenhum.
# Foi por isso que a suíte passava no Linux e reprovava no mini (gate ga-ztz9yn, "e nada no HOME"): este reproduz o padrão do macOS em qualquer sistema, e o controle no fim do grupo saida prova que ele suja o HOME.
# HOCC_SLOW_START=N: o wrapper dorme N s antes de subir o python, como o mini sob carga (load ~50 em 10 núcleos): prova que nenhum caso depende de o vigia subir rápido. Com os mutantes demora; use HOCC_NO_MUTANTS=1 ou um grupo.
SLOW="${HOCC_SLOW_START:-0}"; case "$SLOW" in ''|*[!0-9]*) echo "HOCC_SLOW_START inválido: '$SLOW' (segundos inteiros)" >&2; exit 2 ;; esac
printf '#!/usr/bin/env bash\n%s: "${PYTHONPYCACHEPREFIX=$HOME/Library/Caches/com.apple.python}"; export PYTHONPYCACHEPREFIX\nexec %q "$@"\n' "$([ "$SLOW" = 0 ] || echo "sleep $SLOW; ")" "$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin sh -c 'command -v python3')" > "$T/bin/python3"
chmod +x "$T/bin/"*

# ---- ambiente do cenário -------------------------------------------------------------------------------------------------------------------------------------------------------
TZNAME=America/Sao_Paulo
epoch_of() { python3 -I -c 'import datetime,sys; print(int(datetime.datetime(*[int(x) for x in sys.argv[1:7]], tzinfo=datetime.timezone(datetime.timedelta(hours=-3))).timestamp()))' "$@"; }
NOW0=$(epoch_of 2026 10 19 12 0 0)      # 19/10 12:00 em São Paulo (UTC-3, sem horário de verão)
NCPU=16

SJ_NONE='{"sessions":[{"id":"s1","session_name":"mayor","template":"mayor","state":"active"},{"id":"s2","session_name":"gastown.dog-1","template":"gastown.dog","state":"active"},{"id":"s3","session_name":"dog-remote-velha","template":"dog-remote","state":"asleep"}]}'
SJ_REMOTE='{"sessions":[{"id":"s9","session_name":"dog-remote-gapxi4ls","template":"dog-remote","state":"active"}]}'
BJ_REMOTE='[{"id":"ga-b1","status":"in_progress","assignee":"dog-remote-gapxi4ls"},{"id":"ga-x","status":"in_progress","assignee":"gastown.dog-2"},{"id":"ga-y","status":"in_progress"}]'   # a bead da SJ_REMOTE (no nome da sessão) + ruído: bead de outro dono e bead sem dono
# o 20/10 (Mayor): 2 dog-remote vivas e paradas, as beads delas (ga-z5311j, ga-xpswpd.1) já fechadas; o gc as lista com alias de pool
SJ_ZOMBIES='{"sessions":[{"id":"z1","session_name":"dog-remote-gawispdiod4","alias":"dog-remote-2","template":"dog-remote","state":"active","closed":false},{"id":"z2","session_name":"dog-remote-gawispnjwl1","alias":"dog-remote-1","template":"dog-remote","state":"awake","closed":false}]}'
sessions_are() { printf '%s' "$1" > "$T/sessions.json"; STUB_GC_FILE="$T/sessions.json"; }
beads_are() { printf '%s' "$1" > "$T/beads.json"; STUB_BD_FILE="$T/beads.json"; }   # o que o `bd list --status in_progress --json` devolve

fresh() {   # cidade, HOME, stubs e relógio novos; sessões = nenhuma remota; fila = 3 itens do hq; foco desligado; chave .on posta (os casos de aviso a pressupõem)
  C="$T/city"; HM="$T/home"
  find "$C" "$HM" "$T/stub" "$T/tmp" -mindepth 1 -delete 2>/dev/null
  mkdir -p "$C/.gc/logs" "$HM/.gc" "$T/stub" "$T/tmp"; : > "$C/.gc/hetzner-occupancy-alarm.on"
  NOW=${1:-$NOW0}; CB=0; CI=0; NCPU=16; RC=0; TENV=()
  STUB_GC_RC=0; STUB_GC_SLEEP=""; STUB_SSH_RC=0; STUB_SSH_SLEEP=""; STUB_MAIL_RC=0; STUB_SSH_FILE=""; STUB_OUTFAIL=""; STUB_BD_RC=0; STUB_BD_SLEEP=""
  PILOT_HQ=3; PILOT_WA=0; FOCUS=off; WOUT="$T/out.json"; WERR="$T/err"
  # o aviso de CPU baixa (ga-2hd02v.6) nasce DESLIGADO aqui (régua 0 = nenhuma janela é baixa): os grupos antigos usam CPU de 0,3 % como "ocioso" e contam mails, e o de CPU baixa viria junto em todos.
  # Quem testa o aviso novo (grupo baixa) e a configuração padrão (cfg) pede o padrão de verdade com fresh_lp.
  LOWPCT="HETZNER_OCC_LOW_PCT=0"
  sessions_are "$SJ_NONE"; beads_are "$BJ_REMOTE"
}
fresh_lp() { fresh "$@"; LOWPCT=; }   # como o fresh, mas com o padrão de verdade do aviso de CPU baixa (85 %, 30 min, 3 h)
W() {   # W [VAR=valor ...] [-- args do vigia] : roda o vigia no ambiente do cenário. stdout → $WOUT, stderr → $WERR, rc → $RC
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  # PYTHONDONTWRITEBYTECODE=1: o python NÃO grava bytecode em lugar nenhum, então o HOME falso fica vazio em qualquer python (o grupo saida confere). PYTHONPYCACHEPREFIX=$PYC: de onde ele LÊ o bytecode, aquecido uma vez no fim deste arquivo;
  # sem isso cada rodada recompilaria a stdlib (medido no Linux com o python de mentira: 2x o tempo, ~3x a CPU).
  env -i HOME="$HM" PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX="$PYC" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$T/tmp" TZ="$TZNAME" \
    GC_CITY_PATH="$C" GC_BIN="$T/bin/gc" BD_BIN="$T/bin/bd" SSH_BIN="$T/bin/ssh" HETZNER_OCC_NOW="$NOW" \
    STUB_BD_FILE="${STUB_BD_FILE:-}" STUB_BD_RC="${STUB_BD_RC:-0}" STUB_BD_SLEEP="${STUB_BD_SLEEP:-}" \
    STUB_DIR="$T/stub" STUB_STATE_FILE="$C/.gc/hetzner-occupancy.state.json" STUB_GC_FILE="${STUB_GC_FILE:-}" STUB_GC_RC="${STUB_GC_RC:-0}" STUB_GC_SLEEP="${STUB_GC_SLEEP:-}" \
    STUB_SSH_FILE="${STUB_SSH_FILE:-}" STUB_SSH_RC="${STUB_SSH_RC:-0}" STUB_SSH_SLEEP="${STUB_SSH_SLEEP:-}" STUB_MAIL_RC="${STUB_MAIL_RC:-0}" STUB_OUTFAIL="${STUB_OUTFAIL:-}" \
    ${LOWPCT:+"$LOWPCT"} "${extra[@]+"${extra[@]}"}" python3 "$WATCH" "$@" >"$WOUT" 2>"$WERR"
  RC=$?
}
statfile() {   # statfile <arquivo> <busy> <idle> <ncpu> : o que `grep '^cpu' /proc/stat` devolve entre os marcadores (com ruído de .bashrc antes, que o vigia tem de ignorar)
  { echo "ruído do .bashrc do servidor"; echo "@@OCC-BEGIN@@"
    echo "cpu  $2 0 0 $3 0 0 0 0 0 0"
    local i=0; while [ "$i" -lt "$4" ]; do echo "cpu$i  $(( $2 / $4 )) 0 0 $(( $3 / $4 )) 0 0 0 0 0 0"; i=$((i+1)); done
    echo "@@OCC-END@@"; } > "$1"
}
rawstat() {   # rawstat <arquivo> <user> <nice> <system> <idle> <iowait> <irq> <softirq> <steal> <guest> <guest_nice> : as 10 colunas do /proc/stat, à mão, para 16 núcleos
  { echo "@@OCC-BEGIN@@"; echo "cpu  $2 $3 $4 $5 $6 $7 $8 $9 ${10} ${11}"
    local i=0; while [ "$i" -lt 16 ]; do echo "cpu$i 0 0 0 0 0 0 0 0 0 0"; i=$((i+1)); done
    echo "@@OCC-END@@"; } > "$1"
}
pilot() {   # pilot <idade_s> <ttl> <n_hq> <n_wa> : grava o pilot-dispatchable.json como o Pilot grava (geração = NOW - idade)
  python3 -I - "$HM/.gc/pilot-dispatchable.json" "$((NOW - $1))" "$2" "$3" "$4" <<'PY'
import datetime, json, sys
path, gen, ttl, n_hq, n_wa = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
items = [{"id": "ga-hq%d" % i, "title": "t", "type": "task", "rig": "", "priority": 2, "created_at": "2026-10-18T00:00:00Z", "assignee": "", "store": "hq"} for i in range(n_hq)]
items += [{"id": "wa-x%d" % i, "title": "t", "type": "bug", "rig": "whatsapp_automation", "priority": 1, "created_at": "2026-10-18T00:00:00Z", "assignee": "", "store": "whatsapp_automation"} for i in range(n_wa)]
json.dump({"generated_at": datetime.datetime.fromtimestamp(gen, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "ttl_seconds": ttl, "count": len(items), "items": items}, open(path, "w"))
PY
}
focus_is() {   # focus_is on|off|stale|future|corrupt|badflag|badat|missing : o gate-focus.state como o gate-focus-mode.sh grava (at = NOW)
  local f="$C/.gc/gate-focus.state"
  case "$1" in
    on)      printf 'active=1\nat=%s\ndepth=20\n' "$NOW" > "$f" ;;
    off)     printf 'active=0\nat=%s\ndepth=3\n' "$NOW" > "$f" ;;
    stale)   printf 'active=1\nat=%s\n' "$((NOW - 9000))" > "$f" ;;
    future)  printf 'active=1\nat=%s\n' "$((NOW + 600))" > "$f" ;;
    corrupt) printf 'isto não é um estado\n' > "$f" ;;
    badflag) printf 'active=2\nat=%s\n' "$NOW" > "$f" ;;
    badat)   printf 'active=1\nat=abc\n' > "$f" ;;
    missing) rm -f "$f" ;;
  esac
}
tick() {   # tick <segundos> <centinúcleos> : avança o relógio, "gasta" CPU nesse intervalo (contadores acumulados, 100 ticks/s por núcleo), renova fila e foco, e roda o vigia com --print (TENV = variáveis extras)
  NOW=$((NOW + $1)); CB=$((CB + $2 * $1)); CI=$((CI + (NCPU * 100 - $2) * $1))
  statfile "$T/stat.txt" "$CB" "$CI" "$NCPU"; STUB_SSH_FILE="$T/stat.txt"
  [ "$PILOT_HQ" != none ] && pilot 60 1800 "$PILOT_HQ" "$PILOT_WA"
  focus_is "$FOCUS"
  W "${TENV[@]+"${TENV[@]}"}" -- --print
}
mails() { cat "$T/stub/mail.count" 2>/dev/null || echo 0; }
mailfield() { cat "$T/stub/mail.$1.$2" 2>/dev/null; }
reading() { jv "$WOUT" "$1"; }          # campo da leitura que o --print acabou de imprimir
state_f() { jv "$C/.gc/hetzner-occupancy.state.json" "$1"; }
await() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done; [ -s "$1" ]; }   # espera o arquivo ter conteúdo: rc 0 no 1º instante em que o evento acontece; ~30 s é só a paciência do teste (chegar lá já é a falha), não um prazo que o vigia tenha de cumprir

# ============================================================================================================================================================================
g_cfg() {
  echo "--- cfg: configuração em vigor, plist, gramática"
  fresh
  W -- --print-config
  eq "print-config sai 0" 0 "$RC"
  eq "intervalo padrão = 900 s" 900 "$(reading interval_s)"
  eq "régua padrão = 0.5 núcleo" 0.5 "$(reading busy_cores)"
  eq "loja elegível padrão = só hq" '["hq"]' "$(reading stores)"
  fresh_lp; W -- --print-config
  eq "aviso de CPU baixa: régua padrão = 85 % (Athos 20/10: o nó pago tem de ficar perto de 100 %)" 85.0 "$(reading low_pct)"
  eq "... por 30 min" 1800 "$(reading low_after_s)"; eq "... cooldown de 3 h" 10800 "$(reading low_cooldown_s)"
  W HETZNER_OCC_LOW_PCT=70 HETZNER_OCC_LOW_AFTER_S=3600 HETZNER_OCC_LOW_COOLDOWN_S=60 -- --print-config
  eq "env muda a régua de CPU baixa" 70.0 "$(reading low_pct)"; eq "env muda o prazo" 3600 "$(reading low_after_s)"; eq "env muda o cooldown" 60 "$(reading low_cooldown_s)"
  W HETZNER_OCC_IDLE_COOLDOWN_S=0 -- --print-config; eq "cooldown do aviso de ocioso 0 é aceito (sem espera entre um aviso e o seguinte)" 0 "$(reading idle_cooldown_s)"
  W HETZNER_OCC_LOW_PCT=0 -- --print-config; eq "régua 0 é aceita (desliga o aviso de CPU baixa)" 0.0 "$(reading low_pct)"
  W HETZNER_OCC_LOW_PCT=100 -- --print-config; eq "régua 100 é aceita" 100.0 "$(reading low_pct)"
  local bad_pct
  for bad_pct in 101 -1 nan inf abc ""; do
    W HETZNER_OCC_LOW_PCT="$bad_pct" -- --print-config
    check "HETZNER_OCC_LOW_PCT='$bad_pct' inválido: o vigia recusa (rc != 0, nunca vira uma régua que avisa o tempo todo)" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
  done
  fresh
  W -- --print-config
  eq "com a chave .on posta, o aviso está ligado" true "$(reading alarm)"
  rm -f "$C/.gc/hetzner-occupancy-alarm.on"; W -- --print-config
  eq "sem a chave .on o aviso está DESLIGADO (inerte por padrão)" false "$(reading alarm)"; : > "$C/.gc/hetzner-occupancy-alarm.on"
  W HETZNER_OCC_BUSY_CORES=1.5 HETZNER_OCC_STORES=hq,whatsapp_automation -- --print-config
  eq "env muda a régua" 1.5 "$(reading busy_cores)"
  eq "env muda as lojas" '["hq", "whatsapp_automation"]' "$(reading stores)"
  W HETZNER_SSH_HOST='-oProxyCommand=x' -- --print-config
  check "host ssh com cara de opção (-o...): recusado, e o ssh nem é chamado" "$([ "$RC" -ne 0 ] && [ ! -s "$T/stub/ssh.calls" ] && echo 1 || echo 0)"
  local interval; W -- --print-config; interval=$(reading interval_s)
  if [ -f "$PLIST" ]; then
    python3 -I - "$PLIST" "$interval" > "$T/plist.out" 2>&1 <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
interval = int(sys.argv[2])
env = p.get("EnvironmentVariables", {})
checks = [
    ("Label", p.get("Label") == "com.gascity.hetzner-occupancy-watch"),
    ("python do sistema", p.get("ProgramArguments", [None])[0] == "/usr/bin/python3"),
    ("aponta o script", len(p.get("ProgramArguments", [])) == 2 and p["ProgramArguments"][1].endswith("/scripts/hetzner-occupancy-watch.py")),
    ("StartInterval = intervalo do script", p.get("StartInterval") == interval),
    ("RunAtLoad (a 1ª leitura semeia o baseline logo)", p.get("RunAtLoad") is True),
    ("log de erro em .gc/logs", "/.gc/logs/hetzner-occupancy-watch" in str(p.get("StandardErrorPath", ""))),
    ("PATH acha o gc e os utilitários do usuário","/Users/athos/go/bin" in env.get("PATH", "") and "/Users/athos/.local/bin" in env.get("PATH", "")),
    ("HOME (ssh_config e ~/.gc/pilot-dispatchable.json)", env.get("HOME") == "/Users/athos"),
    ("GC_CITY_PATH", env.get("GC_CITY_PATH") == "/Users/athos/gt/.gascity-gastown-hq"),
    ("o plist NÃO mexe no aviso (quem liga é a chave .on)", "HETZNER_OCC_ALARM" not in env),
    ("prioridade baixa como os vigias novos", p.get("Nice") == 10 and p.get("LowPriorityIO") is True),
]
for name, good in checks:
    print(("ok   " if good else "FAIL ") + "plist: " + name)
PY
    while IFS= read -r line; do case "$line" in "ok   "*) ok "${line#ok   }" ;; *) bad "${line#FAIL }" ;; esac; done < "$T/plist.out"
  else
    bad "plist: $PLIST não existe"
  fi
  if python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), feature_version=(3, 9))' "$WATCH" 2>"$T/ast.err"; then ok "o script compila com a gramática do Python 3.9 (o /usr/bin/python3 do mini)"; else bad "gramática do 3.9: $(head -c 200 "$T/ast.err")"; fi
}

# ============================================================================================================================================================================
g_sess() {
  echo "--- sess: sessões remotas ativas (3 estados)"
  fresh; tick 900 5 >/dev/null     # semeia o baseline de CPU: dali em diante a CPU é lida e baixa
  sessions_are "$SJ_REMOTE"; tick 900 5
  eq "1 sessão remota ativa: lida" true "$(reading sessoes.lido)"; eq "1 sessão remota ativa: conta 1" 1 "$(reading sessoes.ativas)"
  eq "1 sessão remota ativa COM bead (o fresh dá a da SJ_REMOTE) + CPU baixa = ocupado" ocupado "$(reading estado)"
  eq "... e ela conta como ocupada" 1 "$(reading sessoes.ocupadas)"
  eq "nomes das sessões vão na leitura" '["dog-remote-gapxi4ls"]' "$(reading sessoes.nomes)"

  fresh; sessions_are "$SJ_REMOTE"; tick 900 5
  eq "sessão remota ativa com bead prova ocupado mesmo SEM leitura de CPU (1ª leitura, sem baseline)" ocupado "$(reading estado)"

  fresh; tick 900 5 >/dev/null; tick 900 5
  eq "nenhuma remota (só a local gastown.dog-1 e uma remota dormindo): lido" true "$(reading sessoes.lido)"; eq "... conta 0" 0 "$(reading sessoes.ativas)"
  eq "0 sessões + CPU baixa = ocioso" ocioso "$(reading estado)"

  fresh; tick 900 5 >/dev/null; STUB_GC_RC=1; tick 900 5
  eq "gc falhou: sessoes NÃO lida" false "$(reading sessoes.lido)"; eq "gc falhou: ativas = null (não 0)" null "$(reading sessoes.ativas)"
  eq "gc falhou: motivo" gc-falhou "$(reading sessoes.motivo)"
  eq "gc falhou + CPU baixa = DESCONHECIDO (nunca ocioso)" desconhecido "$(reading estado)"
  STUB_GC_RC=0; tick 900 200
  eq "gc ok + CPU alta (2 núcleos) = ocupado" ocupado "$(reading estado)"
  STUB_GC_RC=1; tick 900 200
  eq "gc falhou + CPU alta = ocupado (a CPU prova)" ocupado "$(reading estado)"

  fresh; tick 900 5 >/dev/null
  sessions_are 'isto não é json'; tick 900 5
  eq "saída que não é JSON: não lida" false "$(reading sessoes.lido)"; eq "... motivo" json-ilegivel "$(reading sessoes.motivo)"; eq "... estado desconhecido" desconhecido "$(reading estado)"
  sessions_are '{"outra":[]}'; tick 900 5
  eq "JSON sem a lista sessions: não lida" false "$(reading sessoes.lido)"; eq "... motivo" sem-lista-sessions "$(reading sessoes.motivo)"
  sessions_are ''; tick 900 5
  eq "saída vazia com rc 0: não lida (vazio não é zero)" false "$(reading sessoes.lido)"
  sessions_are '{"sessions":[]}'; tick 900 5
  eq "lista vazia de verdade: lida" true "$(reading sessoes.lido)"; eq "... 0 ativas" 0 "$(reading sessoes.ativas)"; eq "... estado ocioso" ocioso "$(reading estado)"
  sessions_are '{"ok":true,"sessions":[]}'; tick 900 5
  eq "envelope com ok=true e lista vazia: lida, 0" 0 "$(reading sessoes.ativas)"
  sessions_are '{"ok":false,"sessions":[]}'; tick 900 5      # o envelope de erro que o worktree-reaper e o dolt-disk-floor-guard já tratam como "não deu para ler"
  eq "envelope ok=false com lista vazia: NÃO lida (erro não é lista vazia)" false "$(reading sessoes.lido)"; eq "... motivo" ok-falso "$(reading sessoes.motivo)"; eq "... estado desconhecido, nunca ocioso" desconhecido "$(reading estado)"
  sessions_are '{"ok":null,"sessions":[]}'; tick 900 5
  eq "ok presente mas não é true (null): NÃO lida" false "$(reading sessoes.lido)"

  fresh; tick 900 5 >/dev/null
  sessions_are '{"sessions":[{"session_name":"wa-worker-remote-mbp-1","template":"wa-worker-remote","state":"active"},{"session_name":"remote-test-remote-mbp-2","state":"active"},{"session_name":"x-remote-mbp","state":"active"}]}'; tick 900 5
  eq "sessões do MBP (-remote-mbp-...) NÃO contam como ocupação do Hetzner" 0 "$(reading sessoes.ativas)"; eq "... logo ocioso" ocioso "$(reading estado)"
  sessions_are '{"sessions":[{"session_name":"dog-remote-aaa","state":"awake"},{"session_name":"dog-remote-bbb","state":"active","closed":true},{"session_name":"dog-remote-ccc","state":"drained"},{"session_name":"dog-remote-adhoc-0fc28155dd","state":"active"},{"name":"wa-worker-remote-9","state":"active"}]}'; tick 900 5
  eq "awake conta, closed não, drained não, adhoc conta, só 'name' também serve" 3 "$(reading sessoes.ativas)"
  sessions_are '{"sessions":[{"session_name":"dog-remote-aaa","state":"active"},"lixo"]}'; beads_are '[{"id":"ga-b9","status":"in_progress","assignee":"dog-remote-aaa"}]'; tick 900 5
  eq "entrada ilegível MAS há sessão com bead provada: lida, ocupado" ocupado "$(reading estado)"
  beads_are '[]'; tick 900 5
  eq "entrada ilegível e nenhuma sessão com bead provada: NÃO lida (a ilegível pode ser a que trabalha)" false "$(reading sessoes.lido)"; eq "... motivo" entrada-ilegivel "$(reading sessoes.motivo)"; eq "... estado desconhecido, nunca ocioso" desconhecido "$(reading estado)"
  sessions_are '{"sessions":["lixo"]}'; tick 900 5
  eq "entrada que não é objeto, sem prova de sessão ativa: NÃO lida" false "$(reading sessoes.lido)"; eq "... motivo" entrada-ilegivel "$(reading sessoes.motivo)"
  sessions_are '{"sessions":[{"session_name":"dog-remote-aaa","state":"start-pending"}]}'; tick 900 5
  eq "remota em start-pending (fora do vocabulário vivo/dormente): NÃO lida" false "$(reading sessoes.lido)"; eq "... motivo" estado-ilegivel "$(reading sessoes.motivo)"
  sessions_are '{"sessions":[{"session_name":"dog-remote-aaa","state":["x"]}]}'; tick 900 5
  eq "state que não é texto: NÃO lida, e o vigia não cai (rc 0)" 0 "$RC"; eq "... lido" false "$(reading sessoes.lido)"
  sessions_are '{"sessions":[{"session_name":"mayor","template":"mayor"}]}'; tick 900 5
  eq "sessão claramente local sem state não atrapalha: lida, 0" 0 "$(reading sessoes.ativas)"
  sessions_are '{"sessions":[{"template":"dog-remote","state":"active"}]}'; tick 900 5
  eq "entrada só com o template do pool remoto (sem nome): conta" 1 "$(reading sessoes.ativas)"

  fresh; tick 900 5 >/dev/null; sessions_are "$SJ_REMOTE"; STUB_GC_RC=1; STUB_OUTFAIL=1; tick 900 5
  eq "gc sai com erro MAS já imprimiu o JSON completo: NÃO lida (o rc sozinho recusa)" false "$(reading sessoes.lido)"; eq "... motivo" gc-falhou "$(reading sessoes.motivo)"
  fresh; tick 900 5 >/dev/null; STUB_GC_SLEEP=6
  NOW=$((NOW + 900)); W HETZNER_OCC_GC_TIMEOUT_S=1 -- --print
  eq "gc que trava: NÃO lida" false "$(reading sessoes.lido)"; eq "... motivo" gc-timeout "$(reading sessoes.motivo)"
  STUB_GC_SLEEP=""
  # run_cmd mata o GRUPO inteiro e volta logo, sem esperar o neto que segura o pipe. Era o "voltou em < 5 s" dos casos de gc e ssh que travam, que contava também a subida do python (no mini sob carga só subir o python já passou de 1 s, 19/10); aqui o relógio fica DENTRO do python, só ao redor da chamada: com o killpg ~1 s, sem ele 1 s + os 5 do communicate = 6 s, corte em 4 s.
  eq "run_cmd: o timeout mata o grupo e volta logo (sem o killpg leva 6 s)" ok "$(python3 -I -c 'import importlib.util as u, sys, time
sys.dont_write_bytecode = True
s = u.spec_from_file_location("occ", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
t = time.monotonic(); r = m.run_cmd(["bash", "-c", "sleep 8 & wait"], 1); d = time.monotonic() - t
print("ok" if r[3] == "timeout" and d < 4 else "FALHOU: %r em %.1f s" % (r, d))' "$WATCH" 2>&1 | tail -n 1)"
  # o vocabulário de estados (= bead_state.LIVE/DEAD_SESSION_STATES), 1 sessão em cada: só active e awake contam, e nenhum estado dormente vira "ilegível"
  fresh; tick 900 5 >/dev/null; sessions_are '{"sessions":[{"session_name":"dog-remote-a","state":"active"},{"session_name":"dog-remote-b","state":"awake"},{"session_name":"dog-remote-c","state":"asleep"},{"session_name":"dog-remote-d","state":"drained"},{"session_name":"dog-remote-e","state":"closed"},{"session_name":"dog-remote-f","state":"archived"},{"session_name":"dog-remote-g","state":"quarantined"},{"session_name":"dog-remote-h","state":"failed-create"}]}'; tick 900 5
  eq "os 8 estados do vocabulário: só active e awake contam" 2 "$(reading sessoes.ativas)"; eq "... e nenhum estado dormente vira ilegível" null "$(reading sessoes.ilegiveis)"
  # LIVE/DEAD do vigia são CÓPIA do vocabulário de sessões do bead_state.py: se um mudar sem o outro, este caso reprova (bead_state.py ausente também reprova)
  eq "LIVE/DEAD = os de bead_state.py" same "$(python3 -I -c 'import importlib.util as u, sys
sys.dont_write_bytecode = True
def L(p, n):
    s = u.spec_from_file_location(n, p); m = u.module_from_spec(s); s.loader.exec_module(m); return m
a, b = L(sys.argv[1], "bead_state"), L(sys.argv[2], "occ")
print("same" if (set(a.LIVE_SESSION_STATES), set(a.DEAD_SESSION_STATES)) == (set(b.LIVE), set(b.DEAD)) else "DRIFT")' "$HERE/bead_state.py" "$WATCH" 2>&1 | tail -n 1)"
}

# ============================================================================================================================================================================
g_bead() {
  echo "--- bead: sessão VIVA não é sessão OCUPADA (ga-l9q18u): só conta a que segura bead in_progress no alias ou no nome"
  # a leitura real de 20/10 (Mayor): 2 dog-remote vivas, as beads delas fechadas, CPU 1,6 % (0,26 núcleo de 16). Antes: 'ocupado' (26 de 26 leituras do dia); agora: ocioso
  fresh; tick 900 5 >/dev/null; sessions_are "$SJ_ZOMBIES"; beads_are '[{"id":"ga-x","status":"in_progress","assignee":"gastown.dog-2"}]'; tick 900 26
  eq "20/10: 2 dog-remote vivas, nenhuma bead in_progress delas, CPU 1,6 % = OCIOSO" ocioso "$(reading estado)"
  eq "... as 2 estão vivas" 2 "$(reading sessoes.ativas)"; eq "... nenhuma segura bead" 0 "$(reading sessoes.ocupadas)"; eq "... lida" true "$(reading sessoes.lido)"; eq "... CPU 1,6 %" 1.6 "$(reading cpu.pct)"
  beads_are '[{"id":"ga-b1","status":"in_progress","assignee":"dog-remote-2"}]'; tick 900 26
  eq "bead in_progress no ALIAS de uma delas: ocupado" ocupado "$(reading estado)"; eq "... só essa conta (1 de 2)" 1 "$(reading sessoes.ocupadas)"; eq "... qual" '["dog-remote-gawispdiod4"]' "$(reading sessoes.nomes_ocupadas)"
  beads_are '[{"id":"ga-b1","status":"in_progress","assignee":"dog-remote-gawispnjwl1"}]'; tick 900 26
  eq "bead no NOME da sessão (não no alias): ocupado" ocupado "$(reading estado)"; eq "... qual" '["dog-remote-gawispnjwl1"]' "$(reading sessoes.nomes_ocupadas)"
  beads_are '[{"id":"ga-x","status":"in_progress","assignee":"gastown.dog-2"},{"id":"ga-y","status":"in_progress"},{"id":"ga-z","status":"in_progress","assignee":null},{"id":"ga-w","status":"in_progress","assignee":""}]'; tick 900 26
  eq "beads de outro dono, sem dono, com dono null e com dono vazio não contam: ocioso" ocioso "$(reading estado)"
  beads_are '[{"id":"ga-b1","status":"in_progress","assignee":"dog-remote-2"}]'; tick 900 200
  eq "bead + CPU alta: ocupado" ocupado "$(reading estado)"
  fresh; sessions_are "$SJ_ZOMBIES"; beads_are '[]'; tick 900 5 >/dev/null
  eq "1ª leitura (sem baseline de CPU), sessões vivas sem bead: DESCONHECIDO (a CPU ainda não foi lida; nunca ocupado só por estar viva)" desconhecido "$(reading estado)"
  eq "... e é a semente do baseline, não leitura cega" 0 "$(reading cegas_seguidas)"

  echo "--- bead: o bd falhou ou veio ilegível = não sei quem trabalha (nunca ocioso, nunca ocupado pela sessão)"
  fresh; sessions_are "$SJ_ZOMBIES"; tick 900 5 >/dev/null; STUB_BD_RC=1; tick 900 5
  eq "bd falhou + sessões vivas + CPU baixa = DESCONHECIDO" desconhecido "$(reading estado)"; eq "... sessoes.lido false" false "$(reading sessoes.lido)"; eq "... motivo" bd-falhou "$(reading sessoes.motivo)"
  eq "... ocupadas = null (não 0)" null "$(reading sessoes.ocupadas)"; eq "... mas as vivas continuam contadas (o gc leu)" 2 "$(reading sessoes.ativas)"; has "... o stderr do bd vai no detalhe" "erro injetado" "$(reading sessoes.detalhe)"
  eq "... e não é leitura de aquecimento: conta como cega" 1 "$(reading cegas_seguidas)"
  tick 900 200; eq "bd falhou + CPU alta = ocupado (a CPU prova)" ocupado "$(reading estado)"
  STUB_OUTFAIL=1; beads_are '[{"id":"ga-b1","status":"in_progress","assignee":"dog-remote-2"}]'; tick 900 5
  eq "bd sai com erro MAS já imprimiu a lista completa: NÃO lida (o rc sozinho recusa)" desconhecido "$(reading estado)"; eq "... motivo" bd-falhou "$(reading sessoes.motivo)"; STUB_OUTFAIL=""; STUB_BD_RC=0
  beads_are 'isto não é json'; tick 900 5
  eq "bd com saída que não é JSON: NÃO lida" desconhecido "$(reading estado)"; eq "... motivo" json-ilegivel "$(reading sessoes.motivo)"
  beads_are ''; tick 900 5
  eq "bd com saída vazia e rc 0: NÃO lida (vazio não é 'ninguém segura bead')" desconhecido "$(reading estado)"; eq "... motivo" saida-vazia "$(reading sessoes.motivo)"
  beads_are '{"issues":[]}'; tick 900 5; eq "bd com JSON que não é lista: NÃO lida" forma-desconhecida "$(reading sessoes.motivo)"
  beads_are 'null'; tick 900 5; eq "bd com JSON null: NÃO lida" forma-desconhecida "$(reading sessoes.motivo)"
  beads_are '["lixo"]'; tick 900 5; eq "bd com item que não é objeto: NÃO lida" forma-desconhecida "$(reading sessoes.motivo)"
  beads_are '[{"id":"ga-1","assignee":7}]'; tick 900 5; eq "bd com assignee que não é texto: NÃO lida" forma-desconhecida "$(reading sessoes.motivo)"
  beads_are '[]'; tick 900 5; eq "bd com lista vazia de verdade: lida, ninguém segura bead = ocioso" ocioso "$(reading estado)"
  beads_are '[{"id":"ga-b1","status":"in_progress","assignee":"dog-remote-2"}]'; STUB_BD_SLEEP=6; TENV=(HETZNER_OCC_BD_TIMEOUT_S=1); tick 900 5
  eq "bd que trava: NÃO lida" desconhecido "$(reading estado)"; eq "... motivo" bd-timeout "$(reading sessoes.motivo)"; STUB_BD_SLEEP=""; TENV=()
  fresh; sessions_are "$SJ_ZOMBIES"; tick 900 5 >/dev/null; rm -f "$T/stub/bd.calls"; STUB_BD_RC=1; STUB_GC_RC=1; tick 900 5
  eq "gc E bd falharam: o motivo é o do gc (o bd nem é chamado depois que o gc falha)" gc-falhou "$(reading sessoes.motivo)"; eq "... bd não chamado" 0 "$(cat "$T/stub/bd.calls" 2>/dev/null | wc -l | tr -d ' ')"

  echo "--- bead: sem sessão viva o bd nem é chamado (e o Dolt fora não atrapalha); forma exata da chamada"
  fresh; tick 900 5 >/dev/null; STUB_BD_RC=1; tick 900 5
  eq "nenhuma sessão remota viva: o bd NÃO é chamado" 0 "$(cat "$T/stub/bd.calls" 2>/dev/null | wc -l | tr -d ' ')"; eq "... e o bd fora do ar não atrapalha: ocioso" ocioso "$(reading estado)"; eq "... ocupadas = 0" 0 "$(reading sessoes.ocupadas)"
  fresh; sessions_are "$SJ_ZOMBIES"; tick 900 5 >/dev/null
  eq "bd: uma chamada por leitura, na forma exata (-C da cidade, só in_progress, --json, --limit 0: sem o limite o bd corta em 50)" "bd -C $C list --status in_progress --json --limit 0" "$(cat "$T/stub/bd.calls")"
  fresh; W HETZNER_OCC_BD_TIMEOUT_S=45 -- --print-config; eq "HETZNER_OCC_BD_TIMEOUT_S muda o prazo do bd" 45 "$(reading bd_timeout_s)"

  echo "--- bead: sessão sem nome nem alias, e o que prova ocupado ao lado dela"
  fresh; tick 900 5 >/dev/null; sessions_are '{"sessions":[{"template":"dog-remote","state":"active"}]}'; beads_are '[]'; tick 900 5
  eq "sessão viva sem session_name, alias nem name (só template): não dá para casar com bead, NÃO lida" false "$(reading sessoes.lido)"; eq "... motivo" sessao-sem-dono "$(reading sessoes.motivo)"; eq "... desconhecido, nunca ocioso" desconhecido "$(reading estado)"
  sessions_are '{"sessions":[{"template":"dog-remote","state":"active"},{"session_name":"dog-remote-aaa","alias":"dog-remote-4","state":"active"}]}'; beads_are '[{"id":"ga-b9","status":"in_progress","assignee":"dog-remote-4"}]'; tick 900 5
  eq "... mas uma sessão com bead provada ao lado basta: ocupado" ocupado "$(reading estado)"; eq "... 2 vivas, 1 ocupada" "2/1" "$(reading sessoes.ativas)/$(reading sessoes.ocupadas)"
  sessions_are '{"sessions":[{"template":"dog-remote","state":"active"},{"session_name":"dog-remote-aaa","alias":"dog-remote-4","state":"active"}]}'; beads_are '[]'; tick 900 5
  eq "... e sem bead nenhuma, a sem nome mantém tudo desconhecido (a outra seria ociosa)" desconhecido "$(reading estado)"
}

# ============================================================================================================================================================================
g_cpu() {
  echo "--- cpu: /proc/stat por ssh (baseline, janela, contador, ssh)"
  fresh; tick 900 5
  eq "1ª leitura (sem baseline): CPU NÃO lida" false "$(reading cpu.lido)"; eq "... motivo" sem-leitura-anterior "$(reading cpu.motivo)"
  eq "1ª leitura sem sessão: DESCONHECIDO (não ocioso, não ocupado)" desconhecido "$(reading estado)"
  eq "o baseline foi guardado (epoch = agora)" "$NOW" "$(state_f cpu.epoch)"
  tick 900 5
  eq "2ª leitura: CPU lida" true "$(reading cpu.lido)"; eq "... núcleos ocupados (0,05 de 16)" 0.05 "$(reading cpu.nucleos)"; eq "... ncpu lido do /proc/stat" 16 "$(reading cpu.ncpu)"
  eq "... janela" 900 "$(reading cpu.janela_s)"; eq "... pct" 0.3 "$(reading cpu.pct)"; eq "... estado ocioso" ocioso "$(reading estado)"
  tick 900 200
  eq "2 núcleos ocupados na janela = ocupado" ocupado "$(reading estado)"; eq "... núcleos" 2.0 "$(reading cpu.nucleos)"
  tick 900 49; eq "0,49 núcleo = ainda ocioso (abaixo da régua)" ocioso "$(reading estado)"
  tick 900 50; eq "0,50 núcleo = ocupado (a régua é >=)" ocupado "$(reading estado)"

  echo "--- cpu: falhas de leitura nunca viram ocioso"
  fresh; tick 900 5 >/dev/null; tick 900 5 >/dev/null
  local base_epoch; base_epoch=$(state_f cpu.epoch)
  STUB_SSH_RC=255; tick 900 5
  eq "ssh caiu (rc 255): CPU NÃO lida" false "$(reading cpu.lido)"; eq "... cpu.nucleos = null (não 0)" null "$(reading cpu.nucleos)"; eq "... motivo" ssh-falhou "$(reading cpu.motivo)"
  eq "... sem prova de sessão = DESCONHECIDO" desconhecido "$(reading estado)"
  eq "... o baseline anterior NÃO foi apagado pela falha" "$base_epoch" "$(state_f cpu.epoch)"
  STUB_SSH_RC=0; tick 900 5
  eq "ssh voltou: a janela cobre o buraco (1800 s) e a leitura é válida" 1800 "$(reading cpu.janela_s)"; eq "... lida" true "$(reading cpu.lido)"
  sessions_are "$SJ_REMOTE"; STUB_SSH_RC=255; tick 900 5
  eq "ssh caiu + sessão remota ativa com bead = ocupado (a sessão prova)" ocupado "$(reading estado)"

  fresh; tick 900 5 >/dev/null
  printf 'Permission denied (publickey).\n' > "$T/junk.txt"; STUB_SSH_FILE="$T/junk.txt"; W -- --print
  eq "saída sem marcadores: NÃO lida" false "$(reading cpu.lido)"; eq "... motivo" sem-marcador "$(reading cpu.motivo)"
  printf '@@OCC-BEGIN@@\ncpu  100 0 50\ncpu0 100 0 50\n@@OCC-END@@\n' > "$T/junk.txt"; W -- --print
  eq "linha cpu truncada (3 campos): NÃO lida" false "$(reading cpu.lido)"; eq "... motivo" linha-cpu-ilegivel "$(reading cpu.motivo)"
  printf '@@OCC-BEGIN@@\ncpu  100 0 5x 900 0 0 0 0 0 0\ncpu0 100 0 50 900 0 0 0 0 0 0\n@@OCC-END@@\n' > "$T/junk.txt"; W -- --print
  eq "campo não numérico: NÃO lida" false "$(reading cpu.lido)"
  printf '@@OCC-BEGIN@@\ncpu  100 0 50 900 0 0 0 0 0 0\n@@OCC-END@@\n' > "$T/junk.txt"; W -- --print
  eq "sem linhas por núcleo: NÃO lida (não sei dividir em núcleos)" false "$(reading cpu.lido)"; eq "... motivo" sem-nucleos "$(reading cpu.motivo)"
  : > "$T/junk.txt"; W -- --print
  eq "saída vazia com rc 0: NÃO lida (vazio não é zero)" false "$(reading cpu.lido)"
  fresh; tick 900 5 >/dev/null; STUB_SSH_RC=255; STUB_OUTFAIL=1; tick 900 5
  eq "ssh sai com erro MAS já imprimiu o /proc/stat completo: NÃO lida (o rc sozinho recusa)" false "$(reading cpu.lido)"; eq "... motivo" ssh-falhou "$(reading cpu.motivo)"

  echo "--- cpu: janela e contadores"
  fresh; tick 900 5 >/dev/null; local e1; e1=$(state_f cpu.epoch)
  tick 30 5
  eq "2ª leitura 30 s depois (janela curta): NÃO lida" false "$(reading cpu.lido)"; eq "... motivo" janela-curta "$(reading cpu.motivo)"; eq "... baseline mantido (não é trocado por uma janela curta)" "$e1" "$(state_f cpu.epoch)"
  tick 89 5; eq "119 s desde o baseline (um a menos que o piso de 120 s): ainda NÃO lida" janela-curta "$(reading cpu.motivo)"
  tick 1 5; eq "120 s exatos (o piso da janela): lida" true "$(reading cpu.lido)"; eq "... janela de 120 s" 120 "$(reading cpu.janela_s)"
  tick 3000 5
  eq "janela de 50 min (> 3 intervalos): NÃO lida" false "$(reading cpu.lido)"; eq "... motivo" leitura-anterior-velha "$(reading cpu.motivo)"; eq "... baseline REPOSTO (a próxima já mede)" "$NOW" "$(state_f cpu.epoch)"
  tick 900 5; eq "... e a seguinte volta a ser lida" true "$(reading cpu.lido)"
  CB=500; CI=500; statfile "$T/stat.txt" "$CB" "$CI" 16; NOW=$((NOW + 900)); STUB_SSH_FILE="$T/stat.txt"; W -- --print
  eq "contadores recuaram (reinício do servidor): NÃO lida" false "$(reading cpu.lido)"; eq "... motivo" contador-recuou "$(reading cpu.motivo)"; eq "... baseline reposto" "$NOW" "$(state_f cpu.epoch)"
  tick 900 5; eq "... e depois do reinício a leitura volta" true "$(reading cpu.lido)"
  STUB_SSH_FILE="$T/stat.txt"; NOW=$((NOW + 900)); W -- --print
  eq "contadores iguais (nenhum tick na janela): NÃO lida" false "$(reading cpu.lido)"; eq "... motivo" sem-tick "$(reading cpu.motivo)"

  fresh; tick 900 5 >/dev/null
  NOW=$((NOW - 600)); statfile "$T/stat.txt" "$((CB + 1000))" "$((CI + 1000))" 16; STUB_SSH_FILE="$T/stat.txt"; W -- --print
  eq "relógio recuou (baseline no futuro): NÃO lida" false "$(reading cpu.lido)"; eq "... motivo" relogio-recuou "$(reading cpu.motivo)"; eq "... baseline reposto no relógio novo" "$NOW" "$(state_f cpu.epoch)"

  echo "--- cpu: a fórmula de 'ocupado' (user+nice+system+irq+softirq contam; idle, iowait, steal não; guest já está em user)"
  # janela de 900 s x 16 núcleos x 100 ticks = 1.440.000 ticks; 60.000 ticks de UMA coluna = 0,67 núcleo (acima da régua de 0,5)
  _raw() {   # _raw <as 10 colunas do /proc/stat>: semeia um baseline zerado, avança 900 s e lê estes contadores (sem sessão remota)
    fresh; rawstat "$T/stat.txt" 0 0 0 0 0 0 0 0 0 0; STUB_SSH_FILE="$T/stat.txt"; NOW=$((NOW + 900)); W -- --print
    rawstat "$T/stat.txt" "$@"; NOW=$((NOW + 900)); W -- --print
  }
  local spec
  for spec in "user|60000 0 0 1380000 0 0 0 0 0 0" "nice|0 60000 0 1380000 0 0 0 0 0 0" "system|0 0 60000 1380000 0 0 0 0 0 0" "irq|0 0 0 1380000 0 60000 0 0 0 0" "softirq|0 0 0 1380000 0 0 60000 0 0 0"; do
    _raw ${spec#*|}; eq "só ${spec%%|*} (0,67 núcleo): CPU lida e ocupado" ocupado "$(reading estado)"
  done
  for spec in "idle|0 0 0 1440000 0 0 0 0 0 0" "iowait|0 0 0 0 1440000 0 0 0 0 0" "steal|0 0 0 0 0 0 0 1440000 0 0" "guest e guest_nice (já contados em user)|0 0 0 1440000 0 0 0 0 720000 720000"; do
    _raw ${spec#*|}; eq "só ${spec%%|*}: 0 núcleo ocupado, ocioso" ocioso "$(reading estado)"; eq "... núcleos" 0.0 "$(reading cpu.nucleos)"
  done

  echo "--- cpu: ssh trava / forma da chamada"
  fresh; tick 900 5 >/dev/null; STUB_SSH_SLEEP=6
  NOW=$((NOW + 900)); W HETZNER_OCC_SSH_TIMEOUT_S=1 -- --print
  eq "ssh que trava: NÃO lida" false "$(reading cpu.lido)"; eq "... motivo" ssh-timeout "$(reading cpu.motivo)"
  STUB_SSH_SLEEP=""
  fresh; tick 900 5 >/dev/null
  local call; call=$(tail -n 1 "$T/stub/ssh.calls")
  has "ssh: BatchMode (nunca fica esperando senha)" "BatchMode=yes" "$call"
  has "ssh: ConnectTimeout" "ConnectTimeout=" "$call"
  has "ssh: host padrão" "hetzner-teste" "$call"
  has "ssh: só lê o /proc/stat" "/proc/stat" "$call"
  eq "uma chamada de ssh por leitura" 1 "$(wc -l < "$T/stub/ssh.calls" | tr -d ' ')"
  fresh; STUB_SSH_FILE=""; W HETZNER_SSH_HOST=outro-host -- --print
  has "HETZNER_SSH_HOST troca o host" "outro-host" "$(tail -n 1 "$T/stub/ssh.calls")"
}

# ============================================================================================================================================================================
g_fila() {
  echo "--- fila: pilot-dispatchable.json (ausente/velho/futuro/ilegível ≠ 0)"
  fresh; PILOT_HQ=3; PILOT_WA=2; tick 900 5
  eq "3 do hq + 2 do wa: só o hq conta (a loja que o servidor pode pegar)" 3 "$(reading fila.n)"; eq "... lida" true "$(reading fila.lido)"
  eq "... ids de amostra" '["ga-hq0", "ga-hq1", "ga-hq2"]' "$(reading fila.ids)"
  W HETZNER_OCC_STORES=hq,whatsapp_automation -- --print; eq "HETZNER_OCC_STORES inclui outra loja" 5 "$(reading fila.n)"
  fresh; PILOT_HQ=0; PILOT_WA=0; tick 900 5
  eq "arquivo fresco com 0 itens: lido, n = 0 (fila vazia de verdade)" 0 "$(reading fila.n)"; eq "... lido" true "$(reading fila.lido)"
  fresh; PILOT_HQ=0; PILOT_WA=2; tick 900 5
  eq "só itens de outra loja: lido, n = 0 para o hq" 0 "$(reading fila.n)"
  fresh; PILOT_HQ=none; tick 900 5
  eq "arquivo ausente: NÃO lida" false "$(reading fila.lido)"; eq "... n = null (não 0)" null "$(reading fila.n)"; eq "... motivo" arquivo-ausente "$(reading fila.motivo)"
  printf '{"generated_at": "2026-10' > "$HM/.gc/pilot-dispatchable.json"; W -- --print
  eq "JSON cortado: NÃO lida" false "$(reading fila.lido)"; eq "... motivo" arquivo-ilegivel "$(reading fila.motivo)"
  : > "$HM/.gc/pilot-dispatchable.json"; W -- --print; eq "arquivo vazio: NÃO lida" false "$(reading fila.lido)"
  echo '[1,2]' > "$HM/.gc/pilot-dispatchable.json"; W -- --print; eq "JSON que não é objeto: NÃO lida" false "$(reading fila.lido)"; eq "... motivo" forma-desconhecida "$(reading fila.motivo)"
  echo '{"generated_at":"2026-10-19T14:59:00Z","ttl_seconds":1800,"items":"x"}' > "$HM/.gc/pilot-dispatchable.json"; W -- --print; eq "items que não é lista: NÃO lida" false "$(reading fila.lido)"
  echo '{"generated_at":"2026-10-19T14:59:00Z","ttl_seconds":1800,"items":[1]}' > "$HM/.gc/pilot-dispatchable.json"; W -- --print; eq "item que não é objeto: NÃO lida" false "$(reading fila.lido)"
  echo '{"generated_at":"ontem","ttl_seconds":1800,"items":[]}' > "$HM/.gc/pilot-dispatchable.json"; W -- --print; eq "generated_at ilegível: NÃO lida" false "$(reading fila.lido)"
  echo '{"generated_at":"2026-10-19T14:59:00Z","items":[]}' > "$HM/.gc/pilot-dispatchable.json"; W -- --print; eq "sem ttl_seconds: NÃO lida" false "$(reading fila.lido)"
  pilot 1801 1800 3 0; W -- --print; eq "mais velho que o próprio ttl (1801 s > 1800): NÃO lida" false "$(reading fila.lido)"; eq "... motivo" velho "$(reading fila.motivo)"
  pilot 1800 1800 3 0; W -- --print; eq "exatamente no ttl: ainda vale (só passa do ttl é velho, como no reconciler)" true "$(reading fila.lido)"
  pilot -120 1800 3 0; W -- --print; eq "carimbado 2 min no futuro (relógio fora do lugar): NÃO lida" false "$(reading fila.lido)"; eq "... motivo" no-futuro "$(reading fila.motivo)"
  pilot -30 1800 3 0; W -- --print; eq "30 s no futuro cabe na tolerância (60 s)" true "$(reading fila.lido)"
}

# ============================================================================================================================================================================
g_estado() {
  echo "--- estado: tabela completa (sessões × CPU)"
  # (sessão, CPU) → estado. "?" = não lida. Sessão: 1 = viva COM bead · s = viva SEM bead (o 20/10) · b = viva, mas o bd não leu · 0 = nenhuma viva. Cada linha prepara um cenário próprio.
  local row sess cpu want
  for row in "1 baixa ocupado" "1 alta ocupado" "1 ? ocupado" "s baixa ocioso" "s alta ocupado" "s ? desconhecido" "b baixa desconhecido" "b alta ocupado" "b ? desconhecido" "0 baixa ocioso" "0 alta ocupado" "0 ? desconhecido" "? baixa desconhecido" "? alta ocupado" "? ? desconhecido"; do
    sess=${row%% *}; cpu=${row#* }; cpu=${cpu%% *}; want=${row##* }   # expansão de parâmetro: `set -- $row` globava o "?" contra os arquivos do cwd (um arquivo "x" lá e o grupo reprovava sem motivo); não é here-string porque no bash 3.2 ela vira arquivo temporário
    fresh; tick 900 5 >/dev/null
    case "$sess" in 1) sessions_are "$SJ_REMOTE" ;; s) sessions_are "$SJ_REMOTE"; beads_are '[]' ;; b) sessions_are "$SJ_REMOTE"; STUB_BD_RC=1 ;; 0) sessions_are "$SJ_NONE" ;; "?") STUB_GC_RC=1 ;; esac
    case "$cpu" in
      baixa) tick 900 5 ;;
      alta)  tick 900 200 ;;
      "?")   STUB_SSH_RC=255; tick 900 5 ;;
    esac
    eq "sessões=$sess CPU=$cpu → $want" "$want" "$(reading estado)"
  done
}

# ============================================================================================================================================================================
idle_run() {   # idle_run <n> [segundos] : n leituras ociosas seguidas (a CPU baixa, a cada <segundos> = 900)
  local k=0; while [ "$k" -lt "$1" ]; do tick "${2:-900}" 5; k=$((k+1)); done
}
g_alarme() {
  echo "--- alarme: ocioso ≥ 30 min COM fila"
  fresh; tick 900 5 >/dev/null     # semeia
  eq "a 1ª leitura só semeia o baseline de CPU: não conta como leitura cega" 0 "$(reading cegas_seguidas)"
  tick 900 5; eq "leitura ociosa 1: sem aviso" 0 "$(mails)"; eq "... seguidas" 1 "$(reading ociosas_seguidas)"
  tick 900 5; eq "leitura ociosa 2 (15 min): sem aviso" 0 "$(mails)"; eq "... alarme.ocioso = nao" nao "$(reading alarme.ocioso)"
  tick 900 5; eq "leitura ociosa 3 (30 min): 1 mail ao Mayor" 1 "$(mails)"; eq "... alarme.ocioso = enviado" enviado "$(reading alarme.ocioso)"
  eq "... destinatário" mayor "$(mailfield 1 to)"
  has "... assunto diz o estado do mundo" "Hetzner ocioso" "$(mailfield 1 subj)"; has "... assunto traz a fila" "3 bead(s)" "$(mailfield 1 subj)"
  has "... corpo cita a sequência" "3 leituras seguidas" "$(mailfield 1 body)"; has "... corpo cita ids da fila" "ga-hq0" "$(mailfield 1 body)"
  has "... corpo diz que o vigia não atribui nada" "não atribui" "$(mailfield 1 body)"; has "... corpo diz o foco" "foco do gate: desligado" "$(mailfield 1 body)"
  has "... corpo avisa que a fila pode ter vetadas" "vetad" "$(mailfield 1 body)"
  eq "... o cooldown já estava GRAVADO quando o mail saiu (se não der para gravar, o mail nem sai)" "$NOW" "$(jv "$T/stub/mail.1.state" alarme_ocioso_em)"
  tick 900 5; eq "continua ocioso: cooldown (nada de mail repetido)" 1 "$(mails)"; eq "... alarme.ocioso = cooldown" cooldown "$(reading alarme.ocioso)"
  idle_run 10; eq "10 leituras depois (2h30 após o aviso): ainda em cooldown" 1 "$(mails)"
  tick 900 5; eq "3 h depois do aviso: o 2º aviso sai" 2 "$(mails)"

  echo "--- alarme: sessão viva sem bead NÃO cala o aviso (o 20/10: 2 dog-remote paradas, 26 de 26 leituras 'ocupado', o aviso nunca saiu)"
  fresh; sessions_are "$SJ_ZOMBIES"; beads_are '[]'; tick 900 5 >/dev/null; idle_run 3
  eq "2 sessões vivas sem bead + CPU baixa + fila: ocioso há 30 min = 1 mail" 1 "$(mails)"
  has "... o corpo diz quantas estão vivas" "vivas: 2" "$(mailfield 1 body)"; has "... e quantas seguram bead" "segurando bead: 0" "$(mailfield 1 body)"
  fresh; sessions_are "$SJ_ZOMBIES"; beads_are '[{"id":"ga-b1","status":"in_progress","assignee":"dog-remote-2"}]'; tick 900 5 >/dev/null; idle_run 3
  eq "as mesmas 2 vivas, uma COM bead: ocupado, nenhum aviso" 0 "$(mails)"

  echo "--- alarme: tolerância do launchd (jitter) e leitura espaçada"
  fresh; tick 890 5 >/dev/null; idle_run 3 890; eq "leituras a cada 890 s: o 3º ocioso (1780 s desde o 1º) já avisa (tolerância de 2 min)" 1 "$(mails)"
  fresh; tick 800 5 >/dev/null; idle_run 3 800; eq "leituras a cada 800 s: o 3º ocioso (1600 s desde o 1º) AINDA não avisa" 0 "$(mails)"
  idle_run 1 800;                                   eq "... o 4º (2400 s desde o 1º) avisa" 1 "$(mails)"

  echo "--- alarme: sem fila / fila desconhecida / o resto interrompe a sequência"
  fresh; PILOT_HQ=0; tick 900 5 >/dev/null; idle_run 5
  eq "ocioso com fila VAZIA: nenhum aviso (ocioso certo é ocioso)" 0 "$(mails)"; eq "... alarme.ocioso = nao" nao "$(reading alarme.ocioso)"
  fresh; PILOT_HQ=none; tick 900 5 >/dev/null; idle_run 3
  eq "ocioso com fila ILEGÍVEL: nenhum aviso de ocioso (não sei se há fila)" 0 "$(mails)"; eq "... mas conta como leitura sem decisão" 3 "$(reading cegas_seguidas)"
  fresh; tick 900 5 >/dev/null; idle_run 2; tick 900 200; idle_run 2
  eq "ocioso, ocioso, OCUPADO, ocioso, ocioso: sem aviso (a sequência recomeçou)" 0 "$(mails)"; eq "... seguidas = 2" 2 "$(reading ociosas_seguidas)"
  idle_run 1; eq "... o 3º ocioso depois do ocupado avisa" 1 "$(mails)"
  fresh; tick 900 5 >/dev/null; idle_run 2; STUB_SSH_RC=255; tick 900 5; STUB_SSH_RC=0; idle_run 2
  eq "ocioso, ocioso, DESCONHECIDO, ocioso, ocioso: sem aviso (desconhecido quebra a sequência)" 0 "$(mails)"
  idle_run 1; eq "... o 3º ocioso seguido depois do desconhecido avisa" 1 "$(mails)"

  echo "--- alarme: mail que falha não consome o cooldown"
  fresh; tick 900 5 >/dev/null; idle_run 2; STUB_MAIL_RC=1; tick 900 5
  eq "mail falhou: tentou 1 vez" 1 "$(mails)"; eq "... alarme.ocioso = falhou" falhou "$(reading alarme.ocioso)"; eq "... nada de cooldown gravado" null "$(state_f alarme_ocioso_em)"
  STUB_MAIL_RC=0; tick 900 5
  eq "próxima leitura tenta DE NOVO e passa" 2 "$(mails)"; eq "... enviado" enviado "$(reading alarme.ocioso)"
  tick 900 5; eq "e agora sim o cooldown vale" 2 "$(mails)"

  echo "--- alarme: modo foco do gate"
  fresh; FOCUS=on; tick 900 5 >/dev/null; idle_run 3
  eq "foco LIGADO + ocioso + fila: sem aviso (só conserto é despachado)" 0 "$(mails)"; eq "... alarme.ocioso = foco" foco "$(reading alarme.ocioso)"; eq "... a leitura registra o foco" ligado "$(reading foco)"
  FOCUS=off; tick 900 5; eq "foco desligou: o aviso sai na hora (a sequência de ocioso foi contada)" 1 "$(mails)"
  fresh; FOCUS=missing; tick 900 5 >/dev/null; idle_run 3
  eq "foco ILEGÍVEL (arquivo ausente) é tratado como desligado: avisa" 1 "$(mails)"; eq "... a leitura diz desconhecido" desconhecido "$(reading foco)"
  has "... e o mail diz que não sabe do foco" "foco do gate: desconhecido" "$(mailfield 1 body)"
  # a regra de 3 estados do foco é a da gate-focus-lib.sh: a leitura do vigia tem de concordar com a da lib em cada estado
  if [ -f "$FOCUS_LIB" ]; then
    local mode lib want got
    for mode in on off stale future corrupt badflag badat missing; do
      fresh; focus_is "$mode"; W -- --dry-run --print; got=$(reading foco)
      lib=$(bash -c '. "$1"; GATE_FOCUS_STATE_FILE="$2" GATE_FOCUS_NOW="$3" gate_focus_active' _ "$FOCUS_LIB" "$C/.gc/gate-focus.state" "$NOW")
      case "$lib" in 1) want=ligado ;; 0) want=desligado ;; *) want=desconhecido ;; esac
      eq "foco '$mode': o vigia lê como a gate-focus-lib.sh ($lib)" "$want" "$got"
    done
  else
    bad "gate-focus-lib.sh não achada em $FOCUS_LIB: sem ela não dá para provar que a leitura do foco concorda"
  fi

  echo "--- alarme: a chave .on liga o aviso (sem ela é só-medir, inerte)"
  fresh; rm -f "$C/.gc/hetzner-occupancy-alarm.on"; tick 900 5 >/dev/null; idle_run 4
  eq "sem a chave .on: nenhum mail" 0 "$(mails)"; eq "... alarme.ocioso = desligado" desligado "$(reading alarme.ocioso)"
  check "... a medição continua gravando (5 leituras no JSONL)" "$([ "$(wc -l < "$C/.gc/hetzner-occupancy.jsonl" | tr -d ' ')" = 5 ] && echo 1 || echo 0)"
  : > "$C/.gc/hetzner-occupancy-alarm.on"; tick 900 5; eq "pôs a chave: o aviso sai (a sequência continuou)" 1 "$(mails)"
  fresh; tick 900 5 >/dev/null; idle_run 2; TENV=(HETZNER_OCC_ALARM=0); tick 900 5
  eq "HETZNER_OCC_ALARM=0 desliga o aviso MESMO com a chave (3º ocioso, com fila)" 0 "$(mails)"; eq "... alarme.ocioso = desligado" desligado "$(reading alarme.ocioso)"
  W HETZNER_OCC_ALARM=0 -- --print-config; eq "... e a configuração em vigor diz alarm = false" false "$(reading alarm)"

  echo "--- alarme: vigia cego (não consigo medir)"
  fresh; STUB_GC_RC=1; tick 900 5 >/dev/null; idle_run 3
  eq "cego há 45 min (4 leituras): sem aviso ainda" 0 "$(mails)"
  tick 900 5; eq "cego há 60 min (5 leituras): 1 mail" 1 "$(mails)"; eq "... alarme.cego = enviado" enviado "$(reading alarme.cego)"
  has "... assunto" "CEGO" "$(mailfield 1 subj)"; has "... corpo diz por quê (motivo da sessão)" "gc-falhou" "$(mailfield 1 body)"; eq "... destinatário" mayor "$(mailfield 1 to)"
  tick 900 5; eq "continua cego: cooldown, sem repetir" 1 "$(mails)"
  fresh; STUB_GC_RC=1; tick 900 5 >/dev/null; idle_run 2; STUB_GC_RC=0; idle_run 1; eq "uma leitura que decide zera a contagem de cego" 0 "$(reading cegas_seguidas)"
  STUB_GC_RC=1; idle_run 3; eq "cego, cego, cego depois de uma boa: não chega a 1 h" 0 "$(mails)"
  fresh; STUB_GC_RC=1; tick 890 5 >/dev/null; idle_run 4 890; eq "cego, leituras a cada 890 s: o 5º (3560 s desde o 1º) já avisa (tolerância de 2 min)" 1 "$(mails)"
  fresh; STUB_GC_RC=1; tick 800 5 >/dev/null; idle_run 4 800; eq "cego, leituras a cada 800 s: o 5º (3200 s) AINDA não avisa" 0 "$(mails)"
  fresh; PILOT_HQ=none; tick 900 5 >/dev/null; idle_run 4
  eq "ocioso + fila ilegível por 1 h também é cego" 1 "$(mails)"; has "... o corpo cita a fila" "fila" "$(mailfield 1 body)"
  fresh; tick 900 5 >/dev/null; idle_run 6 ; eq "ocupado/ocioso decidíveis nunca avisam cego" 0 "$(reading cegas_seguidas)"
}

# ============================================================================================================================================================================
g_baixa() {
  local d before after m0
  echo "--- baixa: CPU média < 85% por 30 min avisa o Mayor, mesmo com sessão segurando bead (a madrugada de 20/10: 7 h com 0–15 % de CPU e 'ocupado' em todas as leituras, zero aviso)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null
  tick 900 5
  eq "1ª janela abaixo de 85 %: sem aviso" 0 "$(mails)"; eq "... seguidas" 1 "$(reading baixas_seguidas)"; eq "... alarme.cpu_baixa = nao" nao "$(reading alarme.cpu_baixa)"
  eq "... o estado é 'ocupado' (a sessão segura bead): o aviso não depende do estado" ocupado "$(reading estado)"
  tick 900 5
  eq "2ª janela (30 min de CPU medida): 1 mail ao Mayor" 1 "$(mails)"; eq "... destinatário" mayor "$(mailfield 1 to)"
  eq "... alarme.cpu_baixa = enviado" enviado "$(reading alarme.cpu_baixa)"; eq "... e o estado segue 'ocupado' (nenhum aviso de ocioso nem de cego)" ocupado "$(reading estado)"
  has "... assunto diz a CPU média" "CPU média de 0.3%" "$(mailfield 1 subj)"; has "... e o tempo" "30 min" "$(mailfield 1 subj)"
  has "... corpo cita a régua" "abaixo de 85%" "$(mailfield 1 body)"; has "... e a sequência" "2 janelas seguidas" "$(mailfield 1 body)"
  has "... corpo cita a CPU da última janela" "0.05 núcleo(s) de 16" "$(mailfield 1 body)"
  has "... corpo dá o contexto: sessões vivas" "sessões remotas vivas: 1" "$(mailfield 1 body)"; has "... e quantas seguram bead" "segurando bead: 1" "$(mailfield 1 body)"
  has "... e a fila do Pilot" "fila do Pilot (hq): 3" "$(mailfield 1 body)"; has "... e o foco" "foco do gate: desligado" "$(mailfield 1 body)"
  has "... corpo diz que não depende de fila nem de sessão" "NÃO depende de fila nem de sessão" "$(mailfield 1 body)"
  has "... corpo diz que o vigia não atribui nada" "não atribui" "$(mailfield 1 body)"
  eq "... o cooldown já estava GRAVADO quando o mail saiu (se não der para gravar, o mail nem sai)" "$NOW" "$(jv "$T/stub/mail.1.state" alarme_baixa_em)"
  tick 900 5; eq "continua baixa: cooldown, sem mail repetido" 1 "$(mails)"; eq "... alarme.cpu_baixa = cooldown" cooldown "$(reading alarme.cpu_baixa)"
  idle_run 10; eq "11 janelas depois (2h45 após o aviso): ainda em cooldown" 1 "$(mails)"
  tick 900 5; eq "3 h depois do aviso: o 2º aviso sai" 2 "$(mails)"

  echo "--- baixa: a régua é 85 % (< e não <=); janela alta zera a sequência; leitura ilegível nunca conta como baixa"
  fresh_lp; tick 900 5 >/dev/null; tick 900 1360
  eq "janela de exatamente 85.0 %: não é baixa" 85.0 "$(reading cpu.pct)"; eq "... seguidas = 0" 0 "$(reading baixas_seguidas)"
  tick 900 1359; eq "janela de 84.9 %: é baixa" 84.9 "$(reading cpu.pct)"; eq "... seguidas = 1" 1 "$(reading baixas_seguidas)"
  fresh_lp; tick 900 5 >/dev/null; tick 900 5; tick 900 1500; tick 900 5
  eq "baixa, ALTA (93.8 %), baixa: sem aviso (a sequência recomeçou)" 0 "$(mails)"; eq "... seguidas = 1" 1 "$(reading baixas_seguidas)"
  tick 900 5; eq "... a 2ª baixa depois da alta avisa" 1 "$(mails)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null; STUB_SSH_RC=255; idle_run 3
  eq "ssh fora por 45 min (3 leituras): nenhum mail (leitura que falha NÃO é CPU baixa)" 0 "$(mails)"; eq "... seguidas = 0" 0 "$(reading baixas_seguidas)"; eq "... alarme.cpu_baixa = nao" nao "$(reading alarme.cpu_baixa)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null; tick 900 5; STUB_SSH_RC=255; tick 900 5
  eq "baixa, ssh caiu: a sequência zera (a leitura que falha não vale como baixa)" 0 "$(reading baixas_seguidas)"
  STUB_SSH_RC=0; tick 900 5
  eq "ssh voltou: a janela cobre o buraco (30 min, medidos pelos contadores) e é baixa: avisa" 1 "$(mails)"; eq "... janela de 1800 s" 1800 "$(reading cpu.janela_s)"

  echo "--- baixa: independe de fila, de sessão e do foco do gate"
  fresh_lp; PILOT_HQ=0; tick 900 5 >/dev/null; tick 900 5; tick 900 5
  eq "fila VAZIA (o aviso de ocioso exige fila): a CPU baixa avisa do mesmo jeito" 1 "$(mails)"; has "... assunto é o da CPU" "CPU média" "$(mailfield 1 subj)"
  fresh_lp; PILOT_HQ=none; tick 900 5 >/dev/null; tick 900 5; tick 900 5
  eq "fila ILEGÍVEL: avisa" 1 "$(mails)"; has "... e o corpo não inventa um número de fila" "fila do Pilot (hq): não lida" "$(mailfield 1 body)"
  fresh_lp; STUB_GC_RC=1; tick 900 5 >/dev/null; tick 900 5; tick 900 5
  eq "sessões ILEGÍVEIS (o gc falha): avisa" 1 "$(mails)"; has "... e o corpo não inventa contagem de sessão" "sessões remotas vivas: não lido" "$(mailfield 1 body)"
  fresh_lp; FOCUS=on; tick 900 5 >/dev/null; tick 900 5; tick 900 5
  eq "foco do gate LIGADO (cala o aviso de ocioso): a CPU baixa avisa do mesmo jeito" 1 "$(mails)"; has "... e o corpo diz o foco" "foco do gate: ligado" "$(mailfield 1 body)"
  fresh_lp; tick 900 5 >/dev/null; tick 900 5; tick 900 5
  eq "sem sessão e com fila: a CPU baixa avisa na 2ª janela (30 min medidos)" 1 "$(mails)"; has "... é o aviso de CPU" "CPU média" "$(mailfield 1 subj)"
  tick 900 5; eq "o aviso de ocioso, que conta leituras seguidas, sai na seguinte: 2 mails, cada um no seu tempo" 2 "$(mails)"; has "... o 2º é o de ocioso" "Hetzner ocioso" "$(mailfield 2 subj)"
  eq "... alarme.ocioso = enviado" enviado "$(reading alarme.ocioso)"; eq "... e o de CPU baixa segue em cooldown" cooldown "$(reading alarme.cpu_baixa)"

  echo "--- baixa: a chave .on, o HETZNER_OCC_ALARM e o --dry-run valem para o aviso novo"
  fresh_lp; sessions_are "$SJ_REMOTE"; rm -f "$C/.gc/hetzner-occupancy-alarm.on"; tick 900 5 >/dev/null; idle_run 3
  eq "sem a chave .on: nenhum mail" 0 "$(mails)"; eq "... alarme.cpu_baixa = desligado" desligado "$(reading alarme.cpu_baixa)"
  : > "$C/.gc/hetzner-occupancy-alarm.on"; tick 900 5; eq "pôs a chave: o aviso sai (a sequência continuou)" 1 "$(mails)"
  fresh_lp; sessions_are "$SJ_REMOTE"; TENV=(HETZNER_OCC_ALARM=0); tick 900 5 >/dev/null; idle_run 3
  eq "HETZNER_OCC_ALARM=0 desliga o aviso MESMO com a chave" 0 "$(mails)"; eq "... alarme.cpu_baixa = desligado" desligado "$(reading alarme.cpu_baixa)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null; tick 900 5
  before=$(cksum "$C/.gc/"hetzner-occupancy* | sort); m0=$(mails)
  NOW=$((NOW + 900)); CB=$((CB + 5 * 900)); CI=$((CI + (NCPU * 100 - 5) * 900)); statfile "$T/stat.txt" "$CB" "$CI" "$NCPU"; STUB_SSH_FILE="$T/stat.txt"; pilot 60 1800 3 0; focus_is off
  W -- --dry-run --print
  after=$(cksum "$C/.gc/"hetzner-occupancy* | sort)
  eq "dry-run: diz que ENVIARIA o aviso de CPU baixa" enviaria "$(reading alarme.cpu_baixa)"; eq "... nenhum arquivo mudou" "$before" "$after"; eq "... nenhum mail" "$m0" "$(mails)"

  echo "--- baixa: régua, prazo e tolerância do launchd"
  fresh_lp; TENV=(HETZNER_OCC_LOW_PCT=50); tick 900 5 >/dev/null; tick 900 1000; tick 900 1000
  eq "régua em 50 %: duas janelas de 62.5 % não são baixas" 0 "$(mails)"
  tick 900 700; tick 900 700; eq "... duas de 43.8 % são" 1 "$(mails)"
  fresh_lp; sessions_are "$SJ_REMOTE"; TENV=(HETZNER_OCC_LOW_AFTER_S=3600); tick 900 5 >/dev/null; idle_run 3
  eq "prazo de 1 h: 3 janelas (45 min) ainda não avisam" 0 "$(mails)"; tick 900 5; eq "... a 4ª (60 min medidos) avisa" 1 "$(mails)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 890 5 >/dev/null; tick 890 5; tick 890 5
  eq "janelas de 890 s: a 2ª (1780 s medidos) já avisa (tolerância de 2 min do launchd)" 1 "$(mails)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 800 5 >/dev/null; tick 800 5; tick 800 5
  eq "janelas de 800 s: a 2ª (1600 s medidos) AINDA não avisa" 0 "$(mails)"; tick 800 5; eq "... a 3ª (2400 s) avisa" 1 "$(mails)"
  fresh_lp; sessions_are "$SJ_REMOTE"; TENV=(HETZNER_OCC_LOW_PCT=0); tick 900 5 >/dev/null; idle_run 6
  eq "HETZNER_OCC_LOW_PCT=0 desliga o aviso de CPU baixa" 0 "$(mails)"; eq "... seguidas = 0" 0 "$(reading baixas_seguidas)"

  echo "--- baixa: mail que falha não consome o cooldown"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null; tick 900 5; STUB_MAIL_RC=1; tick 900 5
  eq "mail falhou: tentou 1 vez" 1 "$(mails)"; eq "... alarme.cpu_baixa = falhou" falhou "$(reading alarme.cpu_baixa)"; eq "... nada de cooldown gravado" null "$(state_f alarme_baixa_em)"
  STUB_MAIL_RC=0; tick 900 5; eq "próxima leitura tenta DE NOVO e passa" 2 "$(mails)"; eq "... enviado" enviado "$(reading alarme.cpu_baixa)"
  tick 900 5; eq "e agora sim o cooldown vale" 2 "$(mails)"

  echo "--- baixa: estado guardado ilegível recomeça a sequência (nunca avisa por conta de número que não confere)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null; tick 900 5
  python3 -I - "$C/.gc/hetzner-occupancy.state.json" "$((NOW + 99999))" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s.update(baixas_seguidas=5, baixa_desde=int(sys.argv[2]))   # sequência "longa", mas o início está no futuro
json.dump(s, open(p, "w"))
PY
  tick 900 5; eq "baixa_desde no futuro (relógio recuou): a sequência recomeça em 1" 1 "$(reading baixas_seguidas)"; eq "... e nenhum aviso sai por ela" 0 "$(mails)"
  python3 -I - "$C/.gc/hetzner-occupancy.state.json" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s.update(baixas_seguidas=5, baixa_nucleos_s="x")
json.dump(s, open(p, "w"))
PY
  tick 900 5; eq "acumulador que não é número: a sequência recomeça em 1" 1 "$(reading baixas_seguidas)"; eq "... e nenhum aviso sai por ela" 0 "$(mails)"; eq "... o vigia segue (rc 0)" 0 "$RC"

  echo "--- baixa: CPU ilegível por 1 h = vigia CEGO para a CPU, mesmo com a sessão provando 'ocupado' (sem isso o aviso novo morre em silêncio)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null
  eq "a 1ª leitura só semeia o baseline: não conta como CPU cega" 0 "$(reading cpu_cegas_seguidas)"
  STUB_SSH_RC=255; idle_run 3
  eq "ssh fora há 45 min: sem aviso ainda" 0 "$(mails)"; eq "... 3 leituras de CPU cega" 3 "$(reading cpu_cegas_seguidas)"
  eq "... o estado segue 'ocupado' e o cego de estado NÃO acende (a sessão prova)" 0 "$(reading cegas_seguidas)"
  tick 900 5; eq "ssh fora há 60 min: 1 mail 'CEGO'" 1 "$(mails)"; has "... assunto" "CEGO" "$(mailfield 1 subj)"; eq "... alarme.cego = enviado" enviado "$(reading alarme.cego)"
  has "... corpo diz que é a CPU" "não consegue ler a CPU" "$(mailfield 1 body)"; has "... diz por quê" "ssh-falhou" "$(mailfield 1 body)"; has "... e que o aviso de CPU baixa não sai" "aviso de CPU baixa NÃO sai" "$(mailfield 1 body)"
  hasnt "... e não diz que o ESTADO está cego (o estado é lido)" "ocioso ou ocupado" "$(mailfield 1 body)"
  tick 900 5; eq "continua cego: cooldown (6 h), sem repetir" 1 "$(mails)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null; tick 3000 5
  eq "janela velha demais (50 min): repor o baseline NÃO conta como CPU cega" 0 "$(reading cpu_cegas_seguidas)"; eq "... motivo" leitura-anterior-velha "$(reading cpu.motivo)"
  # CPU alta (15 núcleos) em todos os ticks: a janela de 45 min da leitura que volta não é baixa, então só a contagem de CPU cega está em jogo
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 900 1500 >/dev/null; STUB_SSH_RC=255; tick 900 1500; tick 900 1500; STUB_SSH_RC=0; tick 900 1500
  eq "uma leitura de CPU que decide zera a contagem de CPU cega" 0 "$(reading cpu_cegas_seguidas)"
  STUB_SSH_RC=255; tick 900 1500; tick 900 1500; tick 900 1500; eq "cega, cega, cega depois de uma boa: não chega a 1 h" 0 "$(mails)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 890 5 >/dev/null; STUB_SSH_RC=255; idle_run 4 890
  eq "CPU cega, leituras a cada 890 s: a 4ª (3560 s desde a última boa) já avisa (tolerância de 2 min)" 1 "$(mails)"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 800 5 >/dev/null; STUB_SSH_RC=255; idle_run 4 800
  eq "CPU cega, leituras a cada 800 s: a 4ª (3200 s) AINDA não avisa" 0 "$(mails)"
  fresh_lp; PILOT_HQ=none; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null; idle_run 6
  eq "CPU lida, fila ilegível, sessão provando ocupado: nada cego (o estado decide e a CPU está lida)" 0 "$(reading cpu_cegas_seguidas)"

  echo "--- baixa: o número por dia (ocupacao_pct) é a média de CPU do nó, ponderada pela janela; o número de sessão mudou de nome"
  fresh_lp; d="$C/.gc/hetzner-occupancy-daily.json"; tick 900 5 >/dev/null; tick 300 1600; tick 900 0
  eq "ocupacao_pct: 300 s a 100 % + 900 s a 0 % = 25.0 (a média simples das janelas daria 50.0)" 25.0 "$(jv "$d" dias.2026-10-19.ocupacao_pct)"
  eq "... 2 janelas de CPU somadas" 2 "$(jv "$d" dias.2026-10-19.cpu_janelas)"; eq "... núcleos-segundo ocupados" 4800.0 "$(jv "$d" dias.2026-10-19.cpu_nucleos_s)"
  eq "... capacidade em núcleos-segundo (16 núcleos x 1200 s)" 19200 "$(jv "$d" dias.2026-10-19.cpu_capacidade_s)"
  eq "ocupacao_sessao_pct = o número antigo, ocupado/(ocupado+ocioso): 1 ocupado e 1 ocioso" 50.0 "$(jv "$d" dias.2026-10-19.ocupacao_sessao_pct)"
  fresh_lp; d="$C/.gc/hetzner-occupancy-daily.json"; tick 900 5 >/dev/null
  eq "só a 1ª leitura (nenhuma janela de CPU): ocupacao_pct null, nunca 0 %" null "$(jv "$d" dias.2026-10-19.ocupacao_pct)"; eq "... cpu_janelas = 0" 0 "$(jv "$d" dias.2026-10-19.cpu_janelas)"
  fresh_lp; d="$C/.gc/hetzner-occupancy-daily.json"; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null; STUB_SSH_RC=255; idle_run 3
  eq "ssh fora o dia todo com sessão segurando bead: o número de sessão diz 100.0" 100.0 "$(jv "$d" dias.2026-10-19.ocupacao_sessao_pct)"
  eq "... mas a CPU nunca foi lida: ocupacao_pct null (era o buraco: 'ocupado' o dia todo com a CPU parada)" null "$(jv "$d" dias.2026-10-19.ocupacao_pct)"
  fresh_lp; d="$C/.gc/hetzner-occupancy-daily.json"
  printf '%s' '{"dias":{"2026-10-18":{"desconhecido":0,"leituras":38,"ocioso":0,"ocupacao_pct":100.0,"ocupado":38},"2026-10-19":{"desconhecido":1,"leituras":3,"ocioso":0,"ocupacao_pct":100.0,"ocupado":2}},"intervalo_s":900}' > "$d"
  tick 900 5 >/dev/null; tick 900 5
  eq "dia gravado pela versão antiga (18/10): o número de sessão ganhou o nome novo" 100.0 "$(jv "$d" dias.2026-10-18.ocupacao_sessao_pct)"
  eq "... e ocupacao_pct é null: a CPU desse dia nunca foi somada (nada de número de sessão com cara de CPU)" null "$(jv "$d" dias.2026-10-18.ocupacao_pct)"; eq "... cpu_janelas = 0" 0 "$(jv "$d" dias.2026-10-18.cpu_janelas)"
  eq "hoje (19/10, que a versão antiga já tinha começado): o número de sessão segue de onde parou (2 ocupado + 1 ocioso)" 66.7 "$(jv "$d" dias.2026-10-19.ocupacao_sessao_pct)"
  eq "... e a média de CPU é só das janelas lidas desde a mudança (1)" 1 "$(jv "$d" dias.2026-10-19.cpu_janelas)"; eq "... ocupacao_pct" 0.3 "$(jv "$d" dias.2026-10-19.ocupacao_pct)"
  tick 900 5
  eq "2ª passada: o dia antigo não é migrado de novo (o número de sessão segue 100.0)" 100.0 "$(jv "$d" dias.2026-10-18.ocupacao_sessao_pct)"; eq "... e ocupacao_pct segue null" null "$(jv "$d" dias.2026-10-18.ocupacao_pct)"
  eq "... e hoje acumula a 2ª janela" 2 "$(jv "$d" dias.2026-10-19.cpu_janelas)"

  echo "--- baixa: a linha-resumo e o JSONL trazem os três avisos"
  fresh_lp; sessions_are "$SJ_REMOTE"; tick 900 5 >/dev/null; tick 900 5
  NOW=$((NOW + 900)); CB=$((CB + 5 * 900)); CI=$((CI + (NCPU * 100 - 5) * 900)); statfile "$T/stat.txt" "$CB" "$CI" "$NCPU"; STUB_SSH_FILE="$T/stat.txt"; pilot 60 1800 3 0; focus_is off
  W --
  has "linha-resumo: ocioso/cego/cpu_baixa" "alarme=nao/nao/enviado" "$(cat "$WOUT")"
  last_line "$C/.gc/hetzner-occupancy.jsonl"; eq "JSONL: alarme.cpu_baixa da última leitura" enviado "$(jv "$T/last.json" alarme.cpu_baixa)"; eq "JSONL: baixas_seguidas" 2 "$(jv "$T/last.json" baixas_seguidas)"
}

# ============================================================================================================================================================================
g_saida() {
  echo "--- saida: JSONL, número por dia"
  fresh; tick 900 5 >/dev/null; tick 900 5; tick 900 200
  local jl="$C/.gc/hetzner-occupancy.jsonl"
  eq "uma linha por execução" 3 "$(wc -l < "$jl" | tr -d ' ')"
  last_line "$jl"
  eq "JSONL: estado da última" ocupado "$(jv "$T/last.json" estado)"; eq "JSONL: epoch" "$NOW" "$(jv "$T/last.json" epoch)"
  eq "JSONL: a leitura diz a regra que a produziu (2 = ocupado é sessão COM bead; leitura sem o campo é da regra 1, em que sessão viva bastava)" 2 "$(jv "$T/last.json" regra)"; eq "JSONL: sessoes.ocupadas (nenhuma sessão viva)" 0 "$(jv "$T/last.json" sessoes.ocupadas)"
  eq "JSONL: ts = a hora LOCAL do epoch com o deslocamento (12:45 em SP; hora UTC com sufixo local não passa)" "2026-10-19T12:45:00-0300" "$(jv "$T/last.json" ts)"

  fresh "$(epoch_of 2026 10 19 23 20 0)"
  tick 900 5 >/dev/null; tick 900 5; tick 900 200; tick 900 5; STUB_SSH_RC=255; tick 900 5; tick 86400 5
  local d="$C/.gc/hetzner-occupancy-daily.json"
  eq "dia 19: 1 ocioso" 1 "$(jv "$d" dias.2026-10-19.ocioso)"; eq "dia 19: 1 desconhecido (a 1ª leitura, sem baseline)" 1 "$(jv "$d" dias.2026-10-19.desconhecido)"; eq "dia 19: 0 ocupado" 0 "$(jv "$d" dias.2026-10-19.ocupado)"
  eq "dia 19: leituras" 2 "$(jv "$d" dias.2026-10-19.leituras)"; eq "dia 19: ocupação de SESSÃO 0.0% (desconhecido não entra na conta; é o número antigo, com o nome novo)" 0.0 "$(jv "$d" dias.2026-10-19.ocupacao_sessao_pct)"
  eq "dia 20 (virou a meia-noite): 1 ocupado" 1 "$(jv "$d" dias.2026-10-20.ocupado)"; eq "dia 20: 1 ocioso" 1 "$(jv "$d" dias.2026-10-20.ocioso)"; eq "dia 20: 1 desconhecido" 1 "$(jv "$d" dias.2026-10-20.desconhecido)"
  eq "dia 20: ocupação de sessão 50.0%" 50.0 "$(jv "$d" dias.2026-10-20.ocupacao_sessao_pct)"
  eq "dia 21: só desconhecido → ocupação de sessão null (nunca 0%, nunca 100%)" null "$(jv "$d" dias.2026-10-21.ocupacao_sessao_pct)"; eq "dia 21: 1 leitura" 1 "$(jv "$d" dias.2026-10-21.leituras)"
  eq "dia 21: sem janela de CPU lida → ocupacao_pct (a média de CPU) null, nunca 0%" null "$(jv "$d" dias.2026-10-21.ocupacao_pct)"
  fresh "$(epoch_of 2026 10 20 3 0 0)"; sessions_are "$SJ_ZOMBIES"; beads_are '[]'; tick 900 5 >/dev/null; idle_run 3
  eq "o número de sessão do dia (20/10): 2 zumbis vivos + CPU baixa = 3 ocioso, 0 ocupado, 0.0 % (antes: 100 %)" "3/0/0.0" "$(jv "$d" dias.2026-10-20.ocioso)/$(jv "$d" dias.2026-10-20.ocupado)/$(jv "$d" dias.2026-10-20.ocupacao_sessao_pct)"

  echo "--- saida: arquivos corrompidos não somem em silêncio"
  fresh; tick 900 5 >/dev/null; printf 'lixo{' > "$C/.gc/hetzner-occupancy-daily.json"; tick 900 5
  eq "diário corrompido: o vigia segue (rc 0)" 0 "$RC"
  check "... a cópia corrompida fica guardada ao lado" "$(ls "$C/.gc" | grep -c '^hetzner-occupancy-daily.json.corrupt-' | tr -d ' ' | grep -q '^1$' && echo 1 || echo 0)"
  eq "... um diário novo foi criado, com a leitura de agora" 1 "$(jv "$C/.gc/hetzner-occupancy-daily.json" dias.2026-10-19.leituras)"
  has "... e o stderr avisa" "corromp" "$(cat "$WERR")"
  fresh; tick 900 5 >/dev/null; printf 'lixo{' > "$C/.gc/hetzner-occupancy.state.json"; tick 900 5
  eq "estado corrompido: o vigia segue (rc 0)" 0 "$RC"
  check "... a cópia corrompida do estado fica guardada" "$(ls "$C/.gc" | grep -c '^hetzner-occupancy.state.json.corrupt-' | tr -d ' ' | grep -q '^1$' && echo 1 || echo 0)"
  eq "... sem baseline, a CPU dessa leitura é desconhecida (não inventa)" false "$(reading cpu.lido)"

  echo "--- saida: --dry-run não grava nem avisa"
  fresh; tick 900 5 >/dev/null; idle_run 2
  local before after m0; before=$(cksum "$C/.gc/"hetzner-occupancy* | sort); m0=$(mails)
  NOW=$((NOW + 900)); CB=$((CB + 5 * 900)); CI=$((CI + (NCPU * 100 - 5) * 900)); statfile "$T/stat.txt" "$CB" "$CI" "$NCPU"; STUB_SSH_FILE="$T/stat.txt"; pilot 60 1800 3 0; focus_is off
  W -- --dry-run --print
  after=$(cksum "$C/.gc/"hetzner-occupancy* | sort)
  eq "dry-run: nenhum arquivo mudou" "$before" "$after"; eq "dry-run: nenhum mail" "$m0" "$(mails)"
  eq "dry-run: a leitura sai no stdout" ocioso "$(reading estado)"; eq "dry-run: diz que ENVIARIA o aviso" enviaria "$(reading alarme.ocioso)"; eq "dry-run: rc 0" 0 "$RC"

  echo "--- saida: instância única"
  fresh; tick 900 5 >/dev/null
  NOW=$((NOW + 900)); statfile "$T/stat.txt" "$((CB + 1000))" "$((CI + 1000))" 16; STUB_SSH_FILE="$T/stat.txt"
  # Por evento, sem relógio (o "sleep 1" e o "a 2ª volta em < 2 s" de antes reprovaram um vigia certo no mini sob carga, 19/10): a 1ª instância fica PRESA dentro do gc (já com o lock) até o teste soltá-la, e a 2ª só sobe depois que a 1ª avisou que está lá. Prova-se a ORDEM: a 2ª sai com a 1ª ainda presa.
  ( WOUT="$T/out1.json" WERR="$T/err1" W STUB_GC_HOLD=1 -- --print ) &
  local bg=$!; await "$T/stub/hold.in"; local in1=$?
  ( WOUT="$T/out2.json" WERR="$T/err2" W -- --print; echo "$RC" > "$T/stub/rc2" ) &   # rc2 e hold.* ficam em $T/stub, que o fresh() esvazia: um rc2 de uma rodada anterior faria o await passar sem a 2ª ter saído
  local bg2=$!; await "$T/stub/rc2"; local out2=$?
  : > "$T/stub/hold.go"; wait "$bg" "$bg2"   # solta a 1ª (e a 2ª, se um lock bloqueante a prendeu) ANTES de conferir: nada fica vivo se um caso reprovar
  check "1ª instância: chegou ao gc e ficou presa lá, com o lock" "$((in1 == 0))"
  check "2ª instância: saiu com a 1ª ainda presa (não esperou o lock)" "$((out2 == 0))"
  eq "... e sai 0" 0 "$(cat "$T/stub/rc2" 2>/dev/null)"
  has "... e diz por quê no stderr" "outra instância" "$(cat "$T/err2")"
  eq "só a 1ª gravou (2 linhas no JSONL: a semente e a 1ª)" 2 "$(wc -l < "$C/.gc/hetzner-occupancy.jsonl" | tr -d ' ')"

  echo "--- saida: crash e falha de gravação (traceback à vista, rc 3; o vigia não avisa ninguém: quem vê um vigia que cai é o DPW)"
  fresh; tick 900 5 >/dev/null
  W HETZNER_OCC_BUSY_CORES=nao-e-numero -- --print
  check "config inválida: sai com erro (rc != 0)" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"; has "... traceback à vista no stderr (não engolido)" "Traceback" "$(cat "$WERR")"
  check "... e nada sai por notify, bd, dolt nem mail (a chave .on está posta)" "$([ ! -s "$T/stub/forbidden.calls" ] && [ "$(mails)" = 0 ] && echo 1 || echo 0)"
  fresh; rm -f "$C/.gc/hetzner-occupancy-alarm.on"; rmdir "$C/.gc/logs" "$C/.gc"; : > "$C/.gc"     # .gc virou ARQUIVO: nenhuma gravação é possível, para qualquer usuário (inclusive root)
  tick 900 5
  eq "não consegui gravar: rc 3" 3 "$RC"; has "... diz 'não consegui gravar'" "não consegui gravar" "$(cat "$WERR")"
  check "... e nada sai por notify, bd, dolt nem mail" "$([ ! -s "$T/stub/forbidden.calls" ] && [ "$(mails)" = 0 ] && echo 1 || echo 0)"

  echo "--- saida: só LÊ o mundo (do bd, só a lista de in_progress; nada de dolt nem notify, nem outro subcomando do gc)"
  fresh; sessions_are "$SJ_ZOMBIES"; beads_are '[]'; tick 900 5 >/dev/null; idle_run 3
  check "nenhuma chamada proibida (bd fora da leitura de in_progress, dolt, notify, outro subcomando do gc)" "$([ ! -s "$T/stub/forbidden.calls" ] && echo 1 || echo 0)"
  check "... o bd foi mesmo chamado (há sessão viva) e sempre na forma da leitura" "$([ -s "$T/stub/bd.calls" ] && [ "$(grep -v -c "^bd -C $C list --status in_progress --json --limit 0$" "$T/stub/bd.calls")" = 0 ] && echo 1 || echo 0)"
  eq "gc só chamado para 'session list --json' e 'mail send mayor'" 0 "$(grep '^gc ' "$T/stub/gc.calls" | grep -v -e ' session list --json$' -e ' mail send mayor ' | wc -l | tr -d ' ')"
  eq "gc sempre com --city explícito (não depende do cwd do launchd)" 0 "$(grep '^gc ' "$T/stub/gc.calls" | grep -v "^gc --city $C " | wc -l | tr -d ' ')"
  eq "o que o vigia escreve em .gc (e nada além; gate-focus.state e logs são do cenário)" "hetzner-occupancy-daily.json hetzner-occupancy.jsonl hetzner-occupancy.lock hetzner-occupancy.state.json" "$(ls "$C/.gc" | grep -v -e '^gate-focus.state$' -e '^logs$' -e '^hetzner-occupancy-alarm.on$' | tr '\n' ' ' | sed 's/ $//')"
  eq "e nada no HOME além do arquivo do Pilot que ele LÊ (nem o bytecode do python: o W() fixa como o python grava)" ".gc" "$(ls -A "$HM" | tr '\n' ' ' | sed 's/ $//')"
  eq "... e a pasta .gc do HOME só tem o arquivo do Pilot" "pilot-dispatchable.json" "$(ls -A "$HM/.gc" | tr '\n' ' ' | sed 's/ $//')"
  # controle da conferência acima: o python de mentira TEM de sujar o HOME quando o ambiente não diz como gravar bytecode; se deixar de sujar, a conferência passa por vazio no Linux (o buraco do gate ga-ztz9yn). Com o arquivo do Pilot no HOME, "HOME não vazio" não prova nada: o controle olha a pasta Library, a que o python da Apple cria.
  fresh; env -i HOME="$HM" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" python3 -c 'import json, re' >/dev/null 2>&1
  check "controle: sem o ambiente do W(), o python de mentira escreve no HOME (Library; a conferência acima não passa por vazio)" "$([ -d "$HM/Library" ] && echo 1 || echo 0)"
  # a variável vista de dentro do processo: o HOME sem Library sozinho passaria só pelo cache fora dele (no Linux, sem a variável, ainda passa); a que o revisor do gate mediu no mini é esta
  printf 'import os; print(os.environ.get("PYTHONDONTWRITEBYTECODE", ""))\n' > "$T/envprobe.py"; ( WATCH="$T/envprobe.py"; W -- )
  eq "o W() entrega PYTHONDONTWRITEBYTECODE=1 ao python" 1 "$(cat "$WOUT")"
}

# ============================================================================================================================================================================
# ---- CONTROLE NEGATIVO -----------------------------------------------------------------------------------------------------------------------------------------------------------
# mutante <nome> <grupos> <trecho> <troca>: troca UM trecho literal do script (tem de aparecer exatamente 1 vez), roda só os grupos que deveriam pegar e exige reprovação. Padrão que não existe = erro.
# O padrão é conferido aqui, em série; a suíte do mutante roda num subshell em segundo plano (no máximo HOCC_JOBS) e o resultado vai para um arquivo, lido em ordem por mutantes_wait
# (nada de `wait <pid>` depois de `jobs`: o que o bash lembra de um filho já colhido muda entre versões, e o mini pode estar no 3.2 do macOS).
JOBS="${HOCC_JOBS:-4}"
case "$JOBS" in ''|*[!0-9]*|0) echo "HOCC_JOBS inválido: '$JOBS' (inteiro >= 1)" >&2; exit 2 ;; esac
MUTANTS=0; SURVIVED=0; MUT_CAUGHT=42; MUT_NAMES=(); MUT_GROUPS=(); MUT_EXPECT=()
mutante_run() {   # só dentro do subshell do mutante: T, WATCH e bad() são trocados AQUI, e o 1º caso que reprova sai com $MUT_CAUGHT
  local d="$T/m/$1"
  mkdir -p "$d/stub" "$d/tmp" "$d/mut" && ln -s "$T/bin" "$d/bin" || exit 1
  T="$d"; WATCH="$3"; QUIET=1
  bad() { exit "$MUT_CAUGHT"; }
  run_groups $2 >/dev/null 2>&1
  exit 0
}
mutante() {
  local name="$1" groups="$2" mut="$T/mut/$1.py" seq
  if ! python3 -I -c 'import sys
src = open(sys.argv[1], encoding="utf-8").read()
if src.count(sys.argv[3]) != 1:
    sys.stderr.write("o trecho aparece %d vez(es), tem de ser 1" % src.count(sys.argv[3])); sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4]))' "$WATCH" "$mut" "$3" "$4" 2>"$T/mut/err"; then bad "mutante $name: $(cat "$T/mut/err") (padrão desatualizado)"; return; fi
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.2; done
  MUTANTS=$((MUTANTS+1)); seq=$MUTANTS; MUT_NAMES[$seq]="$name"; MUT_GROUPS[$seq]="$groups"; MUT_EXPECT[$seq]="${5:-reprova}"
  { ( mutante_run "$name" "$groups" "$mut" ); echo "$?" > "$T/mutres/$seq"; } &
}
mutantes_wait() {
  wait
  local i=1 rc
  while [ "$i" -le "$MUTANTS" ]; do
    rc=$(cat "$T/mutres/$i" 2>/dev/null)
    case "$rc:${MUT_EXPECT[$i]}" in
      "$MUT_CAUGHT:reprova") ok "mutante ${MUT_NAMES[$i]} reprovado" ;;
      0:reprova) bad "mutante ${MUT_NAMES[$i]} SOBREVIVEU — nenhum caso do(s) grupo(s) '${MUT_GROUPS[$i]}' pega isto"; SURVIVED=$((SURVIVED+1)) ;;
      0:passa) ok "controle ${MUT_NAMES[$i]}: o script SEM mutação passa em todos os grupos sob este esquema (os 'reprovado' acima valem)" ;;
      "$MUT_CAUGHT:passa") bad "controle ${MUT_NAMES[$i]}: o script SEM mutação REPROVOU sob o esquema dos mutantes — o isolamento/paralelismo está quebrado e nenhum 'reprovado' acima prova nada" ;;
      *) bad "mutante ${MUT_NAMES[$i]}: a suíte quebrou (rc='${rc:-sem resultado}') em vez de reprovar o mutante" ;;
    esac
    i=$((i+1))
  done
}
g_mutantes() {
  echo "--- controle negativo: mutantes (até $JOBS ao mesmo tempo)"
  [ -z "${HETZNER_OCC_UNDER_TEST:-}" ] || { bad "controle negativo: só roda contra o script de verdade (HETZNER_OCC_UNDER_TEST está definido)"; return; }
  # o controle do controle: troca um trecho por ELE MESMO (script igual) e roda TODOS os grupos sob o mesmo esquema (subshell, diretório próprio, bad() que sai). Tem de PASSAR; vai primeiro por ser o mais longo.
  mutante identidade "$GROUPS_ALL" $'LIVE = frozenset({"active", "awake"})' $'LIVE = frozenset({"active", "awake"})' passa
  # o lock bloqueante prende a 2ª instância até a paciência do teste acabar (~30 s, ver await): sai cedo para esses 30 s correrem junto com os outros mutantes e não no fim
  mutante lock-bloqueante "saida" $'fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)' $'fcntl.flock(fd, fcntl.LOCK_EX)'
  mutante gc-falha-vira-zero "sess" $'r["detalhe"] = _oneline(err)\n        return r' $'r["detalhe"] = _oneline(err)\n        r.update(lido=True, ativas=0)\n        return r'
  mutante rc-ignorado "sess cpu bead" $'return prefix + "-falhou" if (why or rc != 0) else None' $'return prefix + "-falhou" if why else None'
  mutante saida-vazia-vira-zero "sess" $'r["motivo"] = "json-ilegivel" if out.strip() else "saida-vazia"' $'r.update(lido=True, ativas=0)'
  mutante envelope-ok-falso-lido "sess" $'if isinstance(d, dict) and "ok" in d and d["ok"] is not True:' $'if False:'
  mutante sessao-do-mbp-conta "sess" $'elif "-remote-" not in "-%s-" % ident or (other and other.search(ident)):' $'elif "-remote-" not in "-%s-" % ident:'
  mutante sessao-closed-conta "sess" $'        elif s.get("closed"):\n            continue' $'        elif False:\n            continue'
  mutante estado-fora-do-vocabulario-ignorado "sess" $'bad_state += 1  #' $'pass  #'
  mutante entrada-ilegivel-ignorada "sess" $'bad_entry += 1' $'pass'
  mutante ilegivel-anula-sessao-ativa "sess" $'if mine:  # uma sessão que segura bead provada basta' $'if mine and not (bad_entry or bad_state):  # uma sessão que segura bead provada basta'
  mutante awake-nao-conta "sess" $'LIVE = frozenset({"active", "awake"})' $'LIVE = frozenset({"active"})'
  mutante drained-vira-ilegivel "sess" $'"asleep", "drained", "closed"' $'"asleep", "closed"'
  mutante vocabulario-deriva-do-bead-state "sess" $'"quarantined", "failed-create"})' $'"quarantined", "failed-create", "paused"})'
  mutante template-sozinho-nao-conta "sess" $'for k in ("session_name", "name", "template"):' $'for k in ("session_name", "name"):'
  mutante gc-sem-timeout "sess" $'run_cmd([c.gc_bin, "--city", c.city, "session", "list", "--json"], c.gc_timeout_s)' $'run_cmd([c.gc_bin, "--city", c.city, "session", "list", "--json"], 600)'
  mutante sem-killpg "sess" $'os.killpg(p.pid, signal.SIGKILL)' $'p.kill()'
  mutante gc-sem-city "saida" $'[c.gc_bin, "--city", c.city, "session", "list", "--json"]' $'[c.gc_bin, "session", "list", "--json"]'
  mutante falha-apaga-o-baseline "cpu" $'"cpu": new_base or (st.get("cpu") if _baseline_ok(st.get("cpu")) else None),' $'"cpu": new_base,'
  mutante janela-curta-troca-o-baseline "cpu" $'cpu["motivo"] = "janela-curta"\n        return cpu, None, None' $'cpu["motivo"] = "janela-curta"\n        return cpu, now_b, None'
  mutante janela-curta-lida "cpu" $'if win < c.min_window_s:' $'if False:'
  mutante janela-velha-lida "cpu" $'if win > c.max_window_s:' $'if False:'
  mutante relogio-recuou-lido "cpu" $'if win < 0:' $'if False:'
  mutante contador-recuou-lido "cpu" $'if db < 0 or dt < 0:' $'if False:'
  mutante sem-tick-lido "cpu" $'if dt == 0:' $'if False:'
  mutante ncpu-ignorado "cpu" $'cores = db * ncpu / dt' $'cores = db / dt'
  mutante iowait-conta-como-ocupado "cpu" $'return (total - v[3] - v[4] - v[7], total, ncpu), None' $'return (total - v[3] - v[7], total, ncpu), None'
  mutante steal-conta-como-ocupado "cpu" $'return (total - v[3] - v[4] - v[7], total, ncpu), None' $'return (total - v[3] - v[4], total, ncpu), None'
  mutante idle-conta-como-ocupado "cpu" $'return (total - v[3] - v[4] - v[7], total, ncpu), None' $'return (total - v[4] - v[7], total, ncpu), None'
  mutante user-nao-conta "cpu" $'return (total - v[3] - v[4] - v[7], total, ncpu), None' $'return (total - v[3] - v[4] - v[7] - v[0], total, ncpu), None'
  mutante nice-nao-conta "cpu" $'return (total - v[3] - v[4] - v[7], total, ncpu), None' $'return (total - v[3] - v[4] - v[7] - v[1], total, ncpu), None'
  mutante system-nao-conta "cpu" $'return (total - v[3] - v[4] - v[7], total, ncpu), None' $'return (total - v[3] - v[4] - v[7] - v[2], total, ncpu), None'
  mutante irq-nao-conta "cpu" $'return (total - v[3] - v[4] - v[7], total, ncpu), None' $'return (total - v[3] - v[4] - v[7] - v[5], total, ncpu), None'
  mutante softirq-nao-conta "cpu" $'return (total - v[3] - v[4] - v[7], total, ncpu), None' $'return (total - v[3] - v[4] - v[7] - v[6], total, ncpu), None'
  mutante guest-conta-em-dobro "cpu" $'v = [int(x) for x in agg[1:9]] if agg else []' $'v = [int(x) for x in agg[1:11]] if agg else []'
  mutante linha-cpu-curta-lida "cpu" $'if len(v) < 8 or min(v) < 0:' $'if min(v, default=0) < 0:'
  mutante sem-nucleos-lido "cpu" $'if ncpu == 0:' $'if False:'
  mutante sem-marcador-lido "cpu" $'if BEGIN not in lines or END not in lines[lines.index(BEGIN) + 1:]:' $'if False:'
  mutante ssh-sem-batchmode "cpu" $'"-o", "BatchMode=yes", ' $''
  mutante ssh-sem-timeout "cpu" $'rc, out, err, why = run_cmd(argv, c.ssh_timeout_s)' $'rc, out, err, why = run_cmd(argv, 600)'
  mutante host-ssh-sem-validacao "cfg" $'if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@-]*", c.ssh_host):' $'if False:'
  mutante ocioso-com-uma-leitura-so "estado" $'if sess["lido"] and cpu["lido"]:' $'if sess["lido"] or cpu["lido"]:'
  mutante sessao-nao-prova-ocupado "estado" $'if (sess["lido"] and sess["ocupadas"]) or (cpu["lido"] and cores >= busy_cores):' $'if (cpu["lido"] and cores >= busy_cores):'
  mutante cpu-nao-prova-ocupado "estado" $'if (sess["lido"] and sess["ocupadas"]) or (cpu["lido"] and cores >= busy_cores):' $'if (sess["lido"] and sess["ocupadas"]):'
  mutante regua-sem-igual "estado cpu" $'(cpu["lido"] and cores >= busy_cores)' $'(cpu["lido"] and cores > busy_cores)'
  mutante fila-ausente-vira-zero "fila" $'except FileNotFoundError:\n        r["motivo"] = "arquivo-ausente"\n        return r' $'except FileNotFoundError:\n        r.update(lido=True, n=0)\n        return r'
  mutante fila-velha-vale "fila" $'elif now - gen > ttl:' $'elif False:'
  mutante ttl-exato-ja-e-velho "fila" $'elif now - gen > ttl:' $'elif now - gen >= ttl:'
  mutante fila-no-futuro-vale "fila" $'elif now - gen < -c.future_tol_s:' $'elif False:'
  mutante fila-conta-todas-as-lojas "fila" $'if it["store"] in c.stores]' $'if True]'
  mutante item-que-nao-e-objeto "fila" $'elif not all(isinstance(it, dict) and isinstance(it.get("store"), str) for it in items):' $'elif False:'
  mutante fila-sem-ttl-vale "fila" $'elif isinstance(ttl, bool) or not isinstance(ttl, (int, float)):' $'elif False:'
  mutante foco-velho-vale "alarme" $'if now - int(at) > c.focus_stale_s or int(at) > now + 60:' $'if False:'
  mutante foco-ligado-nao-cala "alarme" $'"foco" if foco == "ligado" else None' $'None'
  mutante foco-ilegivel-cala "alarme" $'"foco" if foco == "ligado" else None' $'"foco" if foco != "desligado" else None'
  mutante ocioso-sem-tolerancia-do-launchd "alarme" $'now - ocio_desde >= c.idle_after_s - c.slack_s' $'now - ocio_desde >= c.idle_after_s'
  mutante aviso-sem-fila "alarme" $'fila["lido"] and fila["n"] > 0 and' $'fila["lido"] and'
  mutante fila-ilegivel-decide "alarme" $'decided = est == "ocupado" or (est == "ocioso" and fila["lido"])' $'decided = est != "desconhecido"'
  mutante sem-cooldown "alarme" $'if last_at is not None and 0 <= now - last_at < cooldown_s:' $'if False:'
  mutante mail-que-falha-gasta-o-cooldown "alarme" $'new_st[key], failed = old, True' $'failed = True'
  mutante cooldown-nao-gravado "alarme" $'new_st[key] = now  # o cooldown' $'pass  # o cooldown'
  mutante sequencia-de-ocioso-nao-zera "alarme" $'ocio = prev_ocio + 1 if est == "ocioso" else 0' $'ocio = prev_ocio + 1'
  mutante ocioso-desde-sempre-agora "alarme" $'ocio_desde = (_int(st.get("ocioso_desde"), now) if prev_ocio > 0 else now) if est == "ocioso" else None' $'ocio_desde = now if est == "ocioso" else None'
  mutante cego-sem-tolerancia-do-launchd "alarme" $'now - decidida_em >= c.blind_after_s - c.slack_s' $'now - decidida_em >= c.blind_after_s'
  mutante cego-tolerancia-enorme "alarme" $'now - decidida_em >= c.blind_after_s - c.slack_s' $'now - decidida_em >= c.blind_after_s - 3000'
  mutante 1a-leitura-conta-como-cega "alarme" $'cegas = 0 if decided else _int(st.get("cegas_seguidas"), 0) + (0 if warm else 1)' $'cegas = 0 if decided else _int(st.get("cegas_seguidas"), 0) + 1'
  mutante chave-on-ignorada "cfg alarme" $'c.alarm = env.get("HETZNER_OCC_ALARM") != "0" and os.path.exists(c.alarm_key)' $'c.alarm = env.get("HETZNER_OCC_ALARM") != "0"'
  mutante env-alarm-0-ignorado "alarme" $'c.alarm = env.get("HETZNER_OCC_ALARM") != "0" and os.path.exists(c.alarm_key)' $'c.alarm = os.path.exists(c.alarm_key)'
  mutante mail-para-outro-destinatario "alarme" $'"mail", "send", "mayor", "-s", subj, "-m", body' $'"mail", "send", "deacon", "-s", subj, "-m", body'
  mutante diario-conta-desconhecido-na-taxa "saida" $'dec = day["ocupado"] + day["ocioso"]' $'dec = day["leituras"]'
  mutante diario-sem-decisao-vira-zero "saida" $'if dec else None' $'if dec else 0.0'
  mutante dia-em-utc "saida" $'time.strftime("%Y-%m-%d", time.localtime(now))' $'time.strftime("%Y-%m-%d", time.gmtime(now))'
  mutante ts-em-utc "saida" $'"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))' $'"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.gmtime(now))'
  # ts-em-utc sobreviveu no mini (Mayor, 19/10, 235/236): o caso só olhava o sufixo -0300. Se lá o %z de um gmtime sai com o deslocamento LOCAL, a hora em UTC passa com o sufixo certo; este mutante é essa forma, igual em qualquer sistema.
  mutante ts-hora-utc-sufixo-local "saida" $'"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))' $'"ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + time.strftime("%z", time.localtime(now))'
  mutante corrompido-nao-guarda-a-copia "saida" $'os.replace(path, dest)' $'pass'
  mutante sem-instancia-unica "saida" $'if not dry and take_lock(c.gc_dir) is None:' $'if False:'
  mutante dry-run-grava-e-avisa "saida" $'    if not dry:\n        for key, _old, _k, _s, _b in sends:' $'    if True:\n        for key, _old, _k, _s, _b in sends:'
  mutante falha-de-gravacao-sai-0 "saida" $'return e.rc' $'return 0'
  mutante crash-sem-traceback "saida" $'traceback.print_exc()' $'pass'
  mutante crash-avisa-pelo-notify "saida" $'    except Exception:  # inclui configuração inválida: o traceback fica à vista no log do launchd\n        traceback.print_exc()' $'    except Exception:\n        traceback.print_exc(); subprocess.run(["notify", "caiu"])'
  # ga-l9q18u: sessão viva não é sessão ocupada
  mutante sessao-viva-sem-bead-prova-ocupado "bead estado alarme saida" $'if (sess["lido"] and sess["ocupadas"]) or (cpu["lido"] and cores >= busy_cores):' $'if (sess["lido"] and sess["ativas"]) or (cpu["lido"] and cores >= busy_cores):'
  mutante bd-falhou-vira-ninguem-segura "bead" $'    if motivo:\n        return None, motivo, _oneline(err)' $'    if motivo:\n        return set(), None, None'
  mutante bd-sem-limit-0 "bead" $'"--json", "--limit", "0"], c.bd_timeout_s)' $'"--json"], c.bd_timeout_s)'
  mutante bd-sem-timeout "bead" $'"--limit", "0"], c.bd_timeout_s)' $'"--limit", "0"], 600)'
  mutante bd-chamado-sem-sessao-viva "bead" $'    if not active:\n        if bad_entry or bad_state:' $'    if False:\n        if bad_entry or bad_state:'
  mutante sem-dono-vira-lida "bead" $'    elif any(not owners for _i, owners in live):' $'    elif False:'
  mutante alias-nao-casa "bead" $'for k in ("session_name", "name", "alias")' $'for k in ("session_name", "name")'
  mutante session-name-nao-casa "bead" $'for k in ("session_name", "name", "alias")' $'for k in ("name", "alias")'
  mutante assignee-que-nao-e-texto-vale "bead" $'(b.get("assignee") is None or isinstance(b["assignee"], str))' $'True'
  mutante lista-do-bd-ilegivel-vale "bead" $'    if not isinstance(lst, list) or not all(' $'    if False and not all('
  mutante detalhe-do-bd-some "bead" $'r["motivo"], r["detalhe"] = why, detail' $'r["motivo"] = why'
  mutante regra-nao-gravada "saida" $'"epoch": now, "regra": RULE, ' $'"epoch": now, '
  # ga-2hd02v.6: o aviso de CPU baixa (CPU média < 85 % por 30 min, sem olhar fila, sessão nem foco), a CPU cega e o número por dia
  mutante baixa-regua-com-igual "baixa" $'cpu["pct"] < c.low_pct):' $'cpu["pct"] <= c.low_pct):'
  mutante baixa-ilegivel-estende-a-sequencia "baixa" $'    if not (cpu["lido"] and cpu["pct"] < c.low_pct):\n        return {"n": 0, "desde": None, "nucleos_s": None, "cap_s": None}' $'    if cpu["lido"] and not cpu["pct"] < c.low_pct:\n        return {"n": 0, "desde": None, "nucleos_s": None, "cap_s": None}\n    if not cpu["lido"]:\n        return {"n": _int(st.get("baixas_seguidas"), 0) + 1, "desde": _int(st.get("baixa_desde"), now - 900), "nucleos_s": 0.0, "cap_s": 1.0}'
  mutante baixa-janela-alta-nao-zera "baixa" $'    if not (cpu["lido"] and cpu["pct"] < c.low_pct):\n        return {"n": 0, "desde": None, "nucleos_s": None, "cap_s": None}' $'    if not (cpu["lido"] and cpu["pct"] < c.low_pct):\n        return {"n": _int(st.get("baixas_seguidas"), 0), "desde": _int(st.get("baixa_desde")), "nucleos_s": _flt(st.get("baixa_nucleos_s")), "cap_s": _flt(st.get("baixa_capacidade_s"))}'
  mutante baixa-desde-o-fim-da-janela "baixa" $'"desde": now - cpu["janela_s"], "nucleos_s": win_n, "cap_s": win_c}' $'"desde": now, "nucleos_s": win_n, "cap_s": win_c}'
  mutante baixa-sem-tolerancia-do-launchd "baixa" $'now - low["desde"] >= c.low_after_s - c.slack_s' $'now - low["desde"] >= c.low_after_s'
  mutante baixa-tolerancia-enorme "baixa" $'now - low["desde"] >= c.low_after_s - c.slack_s' $'now - low["desde"] >= c.low_after_s - 1000'
  mutante baixa-sem-cooldown "baixa" $'a_low = _plan(c, low_due, last_low, c.low_cooldown_s, now, dry)' $'a_low = _plan(c, low_due, None, c.low_cooldown_s, now, dry)'
  mutante baixa-calada-pelo-foco "baixa" $'a_low = _plan(c, low_due, last_low, c.low_cooldown_s, now, dry)' $'a_low = _plan(c, low_due, last_low, c.low_cooldown_s, now, dry, "foco" if foco == "ligado" else None)'
  mutante baixa-depende-da-fila "baixa" $'low_due = low["n"] > 0 and' $'low_due = fila["lido"] and fila["n"] > 0 and low["n"] > 0 and'
  mutante baixa-depende-do-estado "baixa" $'low_due = low["n"] > 0 and' $'low_due = est != "ocupado" and low["n"] > 0 and'
  mutante baixa-depende-da-sessao-lida "baixa" $'low_due = low["n"] > 0 and' $'low_due = sess["lido"] and low["n"] > 0 and'
  mutante baixa-sequencia-nao-gravada "baixa" $'"baixas_seguidas": low["n"], "baixa_desde": low["desde"],' $'"baixas_seguidas": 0, "baixa_desde": None,'
  mutante baixa-desde-no-futuro-vale "baixa" $'since <= now and' $'True and'
  mutante baixa-acumulador-ilegivel-vale "baixa" $'acc_n is not None and acc_c is not None:' $'True:'
  mutante baixa-regua-sem-teto "cfg" $'if c.low_pct > 100:' $'if False:'
  mutante baixa-regua-negativa "cfg" $'"HETZNER_OCC_LOW_PCT", 85, float, 0)' $'"HETZNER_OCC_LOW_PCT", 85, float, -1000)'
  mutante cpu-cega-nao-avisa "baixa" $'blind_cpu_due = cpu_cegas > 0 and now - cpu_lida_em >= c.blind_after_s - c.slack_s' $'blind_cpu_due = False'
  mutante cpu-cega-sem-tolerancia-do-launchd "baixa" $'now - cpu_lida_em >= c.blind_after_s - c.slack_s' $'now - cpu_lida_em >= c.blind_after_s'
  mutante cpu-cega-1a-leitura-conta "baixa" $'(0 if cpu_warm else 1)' $'1'
  mutante cpu-cega-nao-zera "baixa" $'cpu_cegas = 0 if cpu["lido"] else ' $'cpu_cegas = '
  mutante cpu-cega-sem-texto-da-cpu "baixa" $'if cpu_span is not None:' $'if False:'
  mutante diario-cpu-sem-ponderar-pela-janela "baixa" $'day["cpu_nucleos_s"] = round(day["cpu_nucleos_s"] + cores * cpu["janela_s"], 2)' $'day["cpu_nucleos_s"] = round(day["cpu_nucleos_s"] + cores * 900, 2)'
  mutante diario-cpu-capacidade-sem-ponderar "baixa" $'day["cpu_capacidade_s"] += cpu["ncpu"] * cpu["janela_s"]' $'day["cpu_capacidade_s"] += cpu["ncpu"] * 900'
  mutante diario-cpu-sem-leitura-vira-zero "baixa" $'round(100.0 * nucleos_s / capacidade_s, 1) if capacidade_s else None' $'round(100.0 * nucleos_s / capacidade_s, 1) if capacidade_s else 0.0'
  mutante diario-cpu-conta-janela-nao-lida "baixa" $'        if cpu["lido"]:  # só janela LIDA' $'        if True:  # só janela LIDA'
  mutante diario-antigo-perde-o-numero-de-sessao "baixa" $'day["ocupacao_sessao_pct"] = day["ocupacao_pct"]' $'day["ocupacao_sessao_pct"] = None'
  mutante diario-antigo-fica-com-cara-de-cpu "baixa" $'day.update(ocupacao_pct=None, cpu_janelas=0' $'day.update(cpu_janelas=0'
  mutante diario-migra-a-cada-rodada "baixa" $'if isinstance(day, dict) and "cpu_janelas" not in day:' $'if isinstance(day, dict):'
  mutantes_wait
}

GROUPS_ALL="cfg sess bead cpu fila estado alarme baixa saida"
run_groups() { local g; for g in "$@"; do "g_$g"; done; }

DEFAULT="$GROUPS_ALL mutantes"; [ -z "${HOCC_NO_MUTANTS:-}" ] || DEFAULT="$GROUPS_ALL"
wanted="${*:-$DEFAULT}"
for g in $wanted; do case " $GROUPS_ALL mutantes " in *" $g "*) ;; *) echo "grupo desconhecido: $g (grupos: $GROUPS_ALL mutantes)" >&2; exit 2 ;; esac; done
fresh; W PYTHONDONTWRITEBYTECODE= -- --print-config   # aquece o cache de bytecode (ver o W()): vazio = esta rodada grava, em $PYC e não no HOME; as seguintes e os mutantes só leem
run_groups $wanted

echo ""
echo "hetzner-occupancy-watch selftest: $((n - fails))/$n ok, $fails FAIL"
[ "$fails" -eq 0 ] && exit 0 || exit 1
