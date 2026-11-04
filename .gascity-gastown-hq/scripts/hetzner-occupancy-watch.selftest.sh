#!/usr/bin/env bash
# hetzner-occupancy-watch.selftest.sh — hermético: gc e ssh são stubs; a cidade, o HOME, o arquivo do Pilot e o /proc/stat são sintéticos; nada fala com o servidor, o Pilot nem o mail de verdade. (ga-2hd02v.1.12)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS (grupos, na ordem): cfg (configuração em vigor, plist, gramática do Python 3.9) · sess (sessões remotas: 3 estados, MBP fora) · cpu (/proc/stat por ssh: baseline, janela, recuo de contador,
#   ssh que cai ou trava) · fila (arquivo do Pilot: ausente/velho/futuro/ilegível NÃO é zero; lojas) · estado (ocupado / ocioso / desconhecido: a tabela inteira) · alarme (sequência de 30 min, jitter, cooldown,
#   mail que falha, modo foco, chave de ligar, vigia cego) · baixa (aviso de CPU baixa, ga-2hd02v.6: CPU média < 85 % por 30 min, sem olhar fila, sessão nem foco; vigia cego para a CPU; o número por dia é a média de CPU) · saida (JSONL, número por dia, arquivos corrompidos, --dry-run, instância única, crash e falha de gravação, nada fora de .gc) · lastro (rodízio de 03/11, ga-59jrj3d: as funções puras no valor exato, importadas como módulo, e o formato dos arquivos que o vigia grava; roda sozinho em ~5 s: `lastro`).
# CONTROLE NEGATIVO: cada mutante (um trecho literal do script trocado, que tem de existir UMA vez) TEM de reprovar o grupo que o pega; mutante que passa = teste que não pega o bug. Só roda sem argumento e com o script de verdade.
#   Cada mutante roda em segundo plano com o PRÓPRIO diretório temporário e para no 1º caso que reprova (o resto do grupo não diz nada de novo): sem isso eram ~80 grupos inteiros em série, mais de 10 min.
#   EQUIVALENTE (ga-u6ueg0q): `universal_newlines=True` no Popen de run_cmd não tem caso que o separe do False: com `errors="replace"` o subprocess já abre os canais em texto e traduz a quebra de linha,
#   então as duas formas devolvem a mesma saída (id 06d87b11fa).
#   EQUIVALENTES do rodízio de 03/11 (ga-59jrj3d, lidos no código; o (a) também por diferencial: 60000 blocos aleatórios contra cada um dos 2 mutantes, 0 divergências): (a) parse_stat, `lines[i + 1:lines.index(END, i + 1)]` com `i + 0` (ids 4fac5408e3 e c2c527c4eb): o corpo passa a incluir a linha
#   do marcador BEGIN, que não começa por `cpu` e é ignorada, e `lines.index(END, i)` acha o mesmo END porque a linha i é o BEGIN; (b) `ensure_ascii=False` -> `True` nas duas gravações do ESTADO (ids f7961235bf e c91b413c99): o `new_st` só tem chaves fixas em ASCII e valores
#   inteiros, decimais ou null (o baseline passa por `_baseline_ok`), então o JSON sai igual; nas gravações do diário e do JSONL, que carregam texto de fora, o `ensure_ascii` é coberto no grupo lastro.
# COMO RODAR: hetzner-occupancy-watch.selftest.sh [grupo ...]   (sem argumento: todos os grupos e o controle negativo). HETZNER_OCC_UNDER_TEST=<script> roda a suíte contra outra cópia.
#   HOCC_JOBS=N mutantes ao mesmo tempo (padrão 4; 1 = em série) · HOCC_NO_MUTANTS=1 pula o controle negativo (290 dos 370 casos, ~40 s no Linux) · HOCC_SLOW_START=N faz o python do vigia levar N s para subir, como o mini sob carga (com HOCC_NO_MUTANTS=1).
#   Tudo: ~140 s no Linux; no mini, sob carga, a fatia 1 sozinha (238 verificações; hoje são 370) levou ~7 min (medido pelo gate em 19/10). RELÓGIO: nenhum caso mede o tempo de parede do vigia (no mini sob carga só subir o python já passou de 1 s, 19/10): a ordem das duas instâncias é por EVENTO (await) e o único prazo, o do run_cmd, é medido dentro do python.
# EQUIVALENT 06d87b11fa: `universal_newlines=True` no Popen de run_cmd: com `errors="replace"` o subprocess ja abre os canais em texto, as duas formas devolvem a mesma saida
# EQUIVALENT 4fac5408e3 c2c527c4eb: parse_stat `lines[i + 1:lines.index(END, i + 1)]` com `i + 0` (no corte ou no index): o corpo passa a incluir a linha BEGIN, que nao comeca por `cpu` e e ignorada, e `lines.index(END, i)` acha o mesmo END (60000 blocos aleatorios, 0 divergencias)
# EQUIVALENT c91b413c99 f7961235bf: `ensure_ascii=False` -> `True` nas duas gravacoes do ESTADO (antes do mail e depois de um mail que falha): new_st so leva inteiros, null e o baseline de CPU que _baseline_ok aceitou ({epoch,busy,total}, o unico que o vigia grava), entao o JSON sai igual; so um baseline editado a mao com chave extra nao-ASCII os separaria
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
# gc de mentira: `rig list --json` devolve $STUB_DIR/rig.json (ou o padrão: o hq + os rigs wa e ps em <cidade>/rigs; falha com o rc que estiver em $STUB_DIR/rig.rc); `session list --json` devolve $STUB_GC_FILE (ou falha com $STUB_GC_RC; com $STUB_OUTFAIL imprime o JSON COMPLETO antes de falhar; com $STUB_GC_HOLD fica PRESO, avisando em hold.in, até o teste criar hold.go); `mail send` grava o mail; o resto é PROIBIDO (rc 99, marcado)
echo "gc $*" >> "$STUB_DIR/gc.calls"
args=("$@")
CITY_ARG=""; if [ "${args[0]:-}" = "--city" ]; then CITY_ARG="${args[1]:-}"; args=("${args[@]:2}"); fi
case "${args[0]:-} ${args[1]:-}" in
  "session list")
    [ -n "${STUB_GC_SLEEP:-}" ] && sleep "$STUB_GC_SLEEP"
    [ -n "${STUB_GC_HOLD:-}" ] && { echo in > "$STUB_DIR/hold.in"; i=0; while [ ! -e "$STUB_DIR/hold.go" ] && [ "$i" -lt 900 ]; do sleep 0.1; i=$((i+1)); done; }   # o teto (~90 s) só impede um teste morto de deixar isto vivo
    if [ "${STUB_GC_RC:-0}" != 0 ]; then echo "gc: erro injetado" >&2; [ -n "${STUB_OUTFAIL:-}" ] && [ -n "${STUB_GC_FILE:-}" ] && cat "$STUB_GC_FILE"; exit "$STUB_GC_RC"; fi
    [ -n "${STUB_GC_FILE:-}" ] && cat "$STUB_GC_FILE"
    exit 0 ;;
  "rig list")
    [ -f "$STUB_DIR/rig.rc" ] && { echo "gc: erro injetado (rig list)" >&2; exit "$(cat "$STUB_DIR/rig.rc")"; }
    if [ -f "$STUB_DIR/rig.json" ]; then cat "$STUB_DIR/rig.json"; exit 0; fi
    cty="${CITY_ARG:-}"; printf '{"city_path":"%s","ok":true,"rigs":[{"name":"gascity","path":"%s","hq":true},{"name":"wa","path":"%s/rigs/wa"},{"name":"ps","path":"%s/rigs/ps"}]}\n' "$cty" "$cty" "$cty" "$cty"; exit 0 ;;
  "mail send")
    c=$(( $(cat "$STUB_DIR/mail.count" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$STUB_DIR/mail.count"
    to="${args[2]:-}"; subj=""; body=""; i=3
    while [ $i -lt ${#args[@]} ]; do
      case "${args[$i]}" in -s) subj="${args[$((i+1))]}"; i=$((i+2)) ;; -m) body="${args[$((i+1))]}"; i=$((i+2)) ;; *) i=$((i+1)) ;; esac
    done
    printf '%s' "$to" > "$STUB_DIR/mail.$c.to"; printf '%s' "$subj" > "$STUB_DIR/mail.$c.subj"; printf '%s' "$body" > "$STUB_DIR/mail.$c.body"
    echo "${STUB_MAIL_RC:-0}" > "$STUB_DIR/mail.$c.rc"
    [ -n "${STUB_STATE_FILE:-}" ] && [ -f "$STUB_STATE_FILE" ] && cp "$STUB_STATE_FILE" "$STUB_DIR/mail.$c.state"
    [ -n "${STUB_MAIL_SABOTAGE:-}" ] && [ -n "${STUB_STATE_FILE:-}" ] && { rm -f "$STUB_STATE_FILE"; mkdir "$STUB_STATE_FILE"; }   # $STUB_MAIL_SABOTAGE: o arquivo de estado vira PASTA entre a gravação e o fim do mail (qualquer gravação nova nele falha)
    exit "${STUB_MAIL_RC:-0}" ;;
  *) echo "FORBIDDEN gc $*" >> "$STUB_DIR/forbidden.calls"; exit 99 ;;
esac
EOF
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# ssh de mentira: grava os argumentos; devolve $STUB_SSH_FILE (a saída que o servidor daria), ou falha com $STUB_SSH_RC (com $STUB_OUTFAIL imprime a saída COMPLETA antes de falhar), ou trava $STUB_SSH_SLEEP s
echo "$*" >> "$STUB_DIR/ssh.calls"
# AÇÃO no nó (ga-2hd02v.5.10: matar sessão, gravar o pedido de lastro): a chamada que NÃO é a leitura (a leitura leva o marcador @@OCC-BEGIN@@). Vai também para ssh.act; o último argumento é o script que o servidor rodaria.
# $STUB_ACT_RC falha a chamada; $STUB_ACT_SLEEP a trava; $STUB_ACT_OUT força o veredito (a palavra que o script diria). Sem nenhum, o script RODA DE VERDADE (bash local) contra o "nó" de mentira: tmux e date falsos em $STUB_NODEBIN
# (as sessões em $STUB_DIR/node.tmux, linhas nome|session_activity|window_activity: o D1 só mata o que está quieto nas DUAS; o relógio em node.now) e HOME em $STUB_NODE_HOME. Isso confere o shell do vigia (aspas, $(), a ordem do mata-depois-de-conferir), não só o texto dele.
case "$*" in
  *@@OCC-BEGIN@@*) ;;
  *)
    echo "$*" >> "$STUB_DIR/ssh.act"
    [ -n "${STUB_STATE_FILE:-}" ] && [ -f "$STUB_STATE_FILE" ] && cp "$STUB_STATE_FILE" "$STUB_DIR/act.state"   # o estado como estava NA HORA da ação (a tentativa já tem de estar gravada)
    [ -n "${STUB_ACT_SLEEP:-}" ] && sleep "$STUB_ACT_SLEEP"
    if [ "${STUB_ACT_RC:-0}" != 0 ]; then echo "ssh: erro injetado (ação)" >&2; exit "$STUB_ACT_RC"; fi
    if [ -n "${STUB_ACT_OUT:-}" ]; then echo "$STUB_ACT_OUT"; exit 0; fi
    exec env -i PATH="$STUB_NODEBIN:/usr/bin:/bin" HOME="$STUB_NODE_HOME" STUB_DIR="$STUB_DIR" STUB_TMUX_ACT_BAD="${STUB_TMUX_ACT_BAD:-}" STUB_TMUX_KILL_FAIL="${STUB_TMUX_KILL_FAIL:-}" bash -c "${@: -1}" ;;
esac
[ -n "${STUB_SSH_SLEEP:-}" ] && sleep "$STUB_SSH_SLEEP"
if [ "${STUB_SSH_RC:-0}" != 0 ]; then echo "ssh: erro injetado" >&2; [ -n "${STUB_OUTFAIL:-}" ] && [ -n "${STUB_SSH_FILE:-}" ] && cat "$STUB_SSH_FILE"; exit "$STUB_SSH_RC"; fi
[ -n "${STUB_SSH_FILE:-}" ] && cat "$STUB_SSH_FILE"
# $STUB_DIR/after-read.sh (se existir) roda DEPOIS de a leitura sair e some: é o que muda no nó entre a leitura e a ação (a janela do TOCTOU)
[ -f "$STUB_DIR/after-read.sh" ] && { bash "$STUB_DIR/after-read.sh"; rm -f "$STUB_DIR/after-read.sh"; }
exit 0
EOF
cat > "$T/bin/bd" <<'EOF'
#!/usr/bin/env bash
# bd de mentira: duas formas permitidas. (1) a leitura de quem segura bead (`-C <cidade> list --status in_progress --json --limit 0`): devolve $STUB_BD_FILE (ou falha com $STUB_BD_RC; com $STUB_OUTFAIL imprime o JSON COMPLETO antes de falhar;
# com $STUB_BD_SLEEP trava esses segundos). (2) a bead do aviso D4 (`-C <cidade> create --silent -t task -p 2 -l area:infra,hetzner-ocupacao --title <t> -d <d>`, 14 argumentos, a forma EXATA): grava create.N.title/.desc, imprime
# $STUB_BD_CREATE_ID (padrão ga-d4test; VAZIO = não imprime nada) e sai com $STUB_BD_CREATE_RC. Qualquer outra forma é PROIBIDA (rc 99, marcada).
# A forma (1) com -C <cidade>/rigs/<rig> lê a loja de um RIG: devolve $STUB_DIR/bd.rig.<rig> (padrão: []), ou falha se $STUB_DIR/bd.rig.<rig>.rc existir.
echo "bd $*" >> "$STUB_DIR/bd.calls"
if [ "$#" -eq 14 ] && [ "$1" = "-C" ] && [ "$3 $4 $5 $6 $7 $8 $9 ${10} ${11}" = "create --silent -t task -p 2 -l area:infra,hetzner-ocupacao --title" ] && [ "${13}" = "-d" ]; then
  c=$(( $(cat "$STUB_DIR/create.count" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$STUB_DIR/create.count"
  printf '%s' "${12}" > "$STUB_DIR/create.$c.title"; printf '%s' "${14}" > "$STUB_DIR/create.$c.desc"
  [ "${STUB_BD_CREATE_RC:-0}" != 0 ] && { echo "bd: erro injetado (create)" >&2; exit "$STUB_BD_CREATE_RC"; }
  case "${STUB_BD_CREATE_ID:-}" in VAZIO) ;; "") echo ga-d4test ;; *) echo "$STUB_BD_CREATE_ID" ;; esac; exit 0
fi
if [ "$#" -ne 8 ] || [ "$1" != "-C" ] || [ "$3 $4 $5 $6 $7 $8" != "list --status in_progress --json --limit 0" ]; then echo "FORBIDDEN bd $*" >> "$STUB_DIR/forbidden.calls"; exit 99; fi
case "$2" in */rigs/*)
  rig=$(basename "$2"); [ -f "$STUB_DIR/bd.rig.$rig.rc" ] && { echo "bd: erro injetado (rig $rig)" >&2; exit 1; }
  if [ -f "$STUB_DIR/bd.rig.$rig" ]; then cat "$STUB_DIR/bd.rig.$rig"; else echo "[]"; fi; exit 0 ;;
esac
[ -n "${STUB_BD_SLEEP:-}" ] && sleep "$STUB_BD_SLEEP"
if [ "${STUB_BD_RC:-0}" != 0 ]; then echo "bd: erro injetado" >&2; [ -n "${STUB_OUTFAIL:-}" ] && [ -n "${STUB_BD_FILE:-}" ] && cat "$STUB_BD_FILE"; exit "$STUB_BD_RC"; fi
[ -n "${STUB_BD_FILE:-}" ] && cat "$STUB_BD_FILE"
exit 0
EOF
printf '#!/usr/bin/env bash\necho "FORBIDDEN dolt $*" >> "$STUB_DIR/forbidden.calls"\nexit 99\n' > "$T/bin/dolt"   # o vigia NUNCA chama dolt
cat > "$T/bin/notify" <<'EOF'
#!/usr/bin/env bash
# notify de mentira (o do Athos de verdade manda push): grava a chamada (argumentos e as 2 variáveis que o vigia põe), conta e sai com $STUB_NOTIFY_RC (padrão 0); $STUB_NOTIFY_SLEEP o trava.
c=$(( $(cat "$STUB_DIR/notify.count" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$STUB_DIR/notify.count"
echo "notify $*" >> "$STUB_DIR/notify.calls"
printf '%s' "${NOTIFY_STRICT_EXIT:-}/${NOTIFY_FORCE_PUSH:-}" > "$STUB_DIR/notify.$c.env"
if [ "$#" -eq 3 ] && [ "$1" = "-t" ]; then printf '%s' "$2" > "$STUB_DIR/notify.$c.title"; printf '%s' "$3" > "$STUB_DIR/notify.$c.text"; else echo "FORBIDDEN notify $*" >> "$STUB_DIR/forbidden.calls"; exit 99; fi
[ -n "${STUB_NOTIFY_SLEEP:-}" ] && sleep "$STUB_NOTIFY_SLEEP"
exit "${STUB_NOTIFY_RC:-0}"
EOF
# o "nó" para as ações do ssh (ver o ssh de mentira): tmux e date falsos, longe do PATH do vigia ($T/bin/node não está nele)
mkdir -p "$T/bin/node"
cat > "$T/bin/node/tmux" <<'EOF'
#!/usr/bin/env bash
# tmux do nó: só o que o script de matar usa (-L gc-remote has-session / list-windows -t -F / kill-session), sobre $STUB_DIR/node.tmux (uma linha por janela: nome|session_activity|window_activity); o -F é respeitado (só os campos pedidos saem).
# $STUB_TMUX_ACT_BAD: a atividade vem ilegível (1 = "xx", 2 = só um espaço); $STUB_TMUX_KILL_FAIL: o kill falha
f="$STUB_DIR/node.tmux"
[ "$1" = "-L" ] && [ "$2" = "gc-remote" ] || { echo "tmux falso: esperava -L gc-remote: $*" >&2; exit 2; }
shift 2
name=""; [ "$2" = "-t" ] && name="${3#=}"; name="${name%:}"
case "$1" in
  has-session) grep -q "^${name}|" "$f" ;;
  list-windows) case "${STUB_TMUX_ACT_BAD:-}" in 1) echo "xx"; exit 0;; 2) echo " "; exit 0;; esac
    # o tmux de verdade imprime SÓ o que o -F pede: quem pede só session_activity não recebe a saída (window_activity)
    fmt=""; while [ $# -gt 0 ]; do [ "$1" = "-F" ] && fmt="$2"; shift; done
    [ -n "$fmt" ] || { echo "tmux falso: list-windows sem -F" >&2; exit 2; }
    grep "^${name}|" "$f" | while IFS='|' read -r _n sa wa; do printf '%s\n' "$fmt" | sed "s/#{session_activity}/$sa/; s/#{window_activity}/$wa/"; done ;;
  kill-session) [ -n "${STUB_TMUX_KILL_FAIL:-}" ] && exit 1; grep -q "^${name}|" "$f" || exit 1; grep -v "^${name}|" "$f" > "$f.new"; mv "$f.new" "$f"; echo "$name" >> "$STUB_DIR/node.killed" ;;
  *) echo "tmux falso: subcomando $1" >&2; exit 2 ;;
esac
EOF
printf '#!/usr/bin/env bash\n[ "$1" = "+%%s" ] && { cat "$STUB_DIR/node.now"; echo; exit 0; }\nexec /bin/date "$@"\n' > "$T/bin/node/date"
chmod +x "$T/bin/node/tmux" "$T/bin/node/date"
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
  # a escada (ga-2hd02v.5.10): o que as ações, o notify, o bd create e o "nó" de mentira devolvem, e os contadores/menu da leitura completa (xtick)
  STUB_ACT_RC=0; STUB_ACT_SLEEP=""; STUB_ACT_OUT=""; STUB_TMUX_ACT_BAD=""; STUB_TMUX_KILL_FAIL=""; STUB_BD_CREATE_ID=""; STUB_BD_CREATE_RC=0; STUB_NOTIFY_RC=0; STUB_NOTIFY_SLEEP=""
  XU=0; XL=0; CW=0; X_OMIT=""; X_RAM_MB=20000; X_TMUX=lista
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
    NOTIFY_BIN="$T/bin/notify" STUB_NODEBIN="$T/bin/node" STUB_NODE_HOME="$T/stub/nodehome" STUB_ACT_RC="${STUB_ACT_RC:-0}" STUB_ACT_SLEEP="${STUB_ACT_SLEEP:-}" STUB_ACT_OUT="${STUB_ACT_OUT:-}" \
    STUB_TMUX_ACT_BAD="${STUB_TMUX_ACT_BAD:-}" STUB_TMUX_KILL_FAIL="${STUB_TMUX_KILL_FAIL:-}" STUB_BD_CREATE_ID="${STUB_BD_CREATE_ID:-}" STUB_BD_CREATE_RC="${STUB_BD_CREATE_RC:-0}" \
    STUB_NOTIFY_RC="${STUB_NOTIFY_RC:-0}" STUB_NOTIFY_SLEEP="${STUB_NOTIFY_SLEEP:-}" \
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

# ---- a leitura COMPLETA do nó, para os grupos da causa, da escada e dos avisos (ga-2hd02v.5.10) --------------------------------------------------------------------------------
GHOST=gate-reviewer-remote-adhoc-033f7bd5c1   # o caso real de 04/11: sessão do tmux do nó, 4 h parada, que a cidade não conhecia
LOWW="200 30 50 150"   # sessões 2,0 · lastro 0,3 · sistema 0,5 · espera de disco 1,5 núcleos (em centinúcleos): CPU a 17,5 %, 11,7 núcleos livres
xwrite() {   # xwrite <arquivo>: a saída COMPLETA da ssh de leitura (/proc/stat com ruído de .bashrc antes + cgroup + RAM + tmux + relógio do nó). X_OMIT = o que falta (cg m u l mem tmux now); X_TMUX = lista|semservidor|falha|lixo|semrc
  local i=0 o=" $X_OMIT "
  { echo "ruído do .bashrc do servidor"; echo "@@OCC-BEGIN@@"
    echo "cpu  $CB 0 0 $CI $CW 0 0 0 0 0"
    while [ "$i" -lt "$NCPU" ]; do echo "cpu$i 0 0 0 0 0 0 0 0 0 0"; i=$((i+1)); done
    case "$o" in *" cg "*) ;; *) echo "@@OCC-CG@@"
      case "$o" in *" m "*) ;; *) echo "m 1" ;; esac
      case "$o" in *" u "*) ;; *) echo "u $XU" ;; esac
      case "$o" in *" l "*) ;; *) echo "l $XL" ;; esac ;; esac
    case "$o" in *" mem "*) ;; *) echo "@@OCC-MEM@@"; echo "MemTotal:       32768000 kB"; echo "MemAvailable:   $((X_RAM_MB * 1024)) kB" ;; esac
    case "$o" in *" tmux "*) ;; *) echo "@@OCC-TMUX@@"
      case "$X_TMUX" in
        lista) echo "rc=0"; cat "$T/stub/node.tmux" ;;
        semservidor) echo "rc=1"; echo "no server running on /tmp/tmux-1000/gc-remote" ;;
        falha) echo "rc=1"; echo "server exited unexpectedly" ;;
        lixo) echo "rc=0"; echo "linha sem barra" ;;
        semrc) cat "$T/stub/node.tmux" ;;
      esac ;; esac
    case "$o" in *" now "*) ;; *) echo "@@OCC-NOW@@"; echo "$NOW" ;; esac
    echo "@@OCC-END@@"; } > "$1"
}
xtick() {   # xtick <segundos> <sessões> <lastro> <sistema> <espera> : como o tick, com a leitura COMPLETA; as 4 partes em centinúcleos médios na janela (100 = 1 núcleo; sessões+lastro = o user slice). XARGS troca os argumentos do vigia (padrão --print)
  local s=$1 se=$2 la=$3 sy=$4 io=$5
  NOW=$((NOW + s)); CB=$((CB + (se + la + sy) * s)); CW=$((CW + io * s)); CI=$((CI + (NCPU * 100 - se - la - sy - io) * s))
  XU=$((XU + (se + la) * s * 10000)); XL=$((XL + la * s * 10000))   # 100 centinúcleos x 1 s = 1 000 000 us de cgroup
  xwrite "$T/stat.txt"; STUB_SSH_FILE="$T/stat.txt"; printf '%s' "$NOW" > "$T/stub/node.now"
  [ "$PILOT_HQ" != none ] && pilot 60 1800 "$PILOT_HQ" "$PILOT_WA"
  focus_is "$FOCUS"
  W "${TENV[@]+"${TENV[@]}"}" -- ${XARGS---print}
}
xone() { xtick 900 "$@" >/dev/null; xtick 900 "$@"; }   # xone <4 partes>: a semente do baseline e UMA janela lida (a que o teste examina)
xdue() { xtick 900 "$@" >/dev/null; xtick 900 "$@" >/dev/null; xtick 900 "$@"; }   # a semente, a 1ª janela baixa e a 2ª (30 min medidos): a 1ª leitura em que a escada pode agir
node_add() { printf '%s|%s|%s\n' "$1" "$((NOW + ${3:-1800} - $2))" "$((NOW + ${3:-1800} - ${4:-$2}))" >> "$T/stub/node.tmux"; }   # node_add <nome> <parada_há_s> [segundos_até_a_leitura=1800] [janela_parada_há_s=igual]: uma janela de uma sessão no tmux do nó, com input parado há <parada_há_s> (session_activity) e saída parada há <janela_parada_há_s> (window_activity) NO MOMENTO DA LEITURA (a atividade é fixa e o relógio corre: 1800 s = o xone, 2700 s = o xdue). Repetir o nome = outra janela da mesma sessão
after_read() { printf '%s\n' "$1" > "$T/stub/after-read.sh"; }   # after_read <comando>: roda no nó DEPOIS da próxima leitura (a janela entre achar e agir); $STUB_DIR e o relógio em $STUB_DIR/node.now
node_has() { grep -q "^$1|" "$T/stub/node.tmux" && echo 1 || echo 0; }
keys_on() { local k; for k in "$@"; do : > "$C/.gc/hetzner-occupancy-$k.on"; done; }
state_set() {   # state_set <chave>=<json> ...: regrava chaves do estado que o vigia deixou (chave sem valor = apaga), como quem o editou à mão
  python3 -I -c 'import json, sys
p = sys.argv[1]
d = json.load(open(p))
for kv in sys.argv[2:]:
  k, _, v = kv.partition("=")
  if v == "":
      d.pop(k, None)
  else:
      d[k] = json.loads(v)
json.dump(d, open(p, "w"))' "$C/.gc/hetzner-occupancy.state.json" "$@"
}
acts() { cat "$T/stub/ssh.act" 2>/dev/null | wc -l | tr -d ' '; }   # quantas ações o vigia mandou ao nó
notifies() { cat "$T/stub/notify.count" 2>/dev/null || echo 0; }
creates() { cat "$T/stub/create.count" 2>/dev/null || echo 0; }
xfresh() {   # xfresh [epoch]: o fresh_lp com o aviso ANTIGO desligado (o mail dele não entra na conta de quem testa a escada), nenhuma chave da escada e o nó de mentira de pé (pasta do lastro, tmux vazio, relógio)
  fresh_lp "$@"; rm -f "$C/.gc/hetzner-occupancy-alarm.on"; unset XARGS
  NODE="$T/stub/nodehome"; mkdir -p "$NODE/gt-remote/ballast"; : > "$T/stub/node.tmux"; printf '%s' "$NOW" > "$T/stub/node.now"
}

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
  check "... e nada sai por notify, bd create, ação ao nó, dolt nem mail (a chave .on está posta)" "$([ ! -s "$T/stub/forbidden.calls" ] && [ "$(mails)" = 0 ] && [ "$(notifies)" = 0 ] && [ "$(creates)" = 0 ] && [ "$(acts)" = 0 ] && echo 1 || echo 0)"
  fresh; rm -f "$C/.gc/hetzner-occupancy-alarm.on"; rmdir "$C/.gc/logs" "$C/.gc"; : > "$C/.gc"     # .gc virou ARQUIVO: nenhuma gravação é possível, para qualquer usuário (inclusive root)
  tick 900 5
  eq "não consegui gravar: rc 3" 3 "$RC"; has "... diz 'não consegui gravar'" "não consegui gravar" "$(cat "$WERR")"
  check "... e nada sai por notify, bd create, ação ao nó, dolt nem mail" "$([ ! -s "$T/stub/forbidden.calls" ] && [ "$(mails)" = 0 ] && [ "$(notifies)" = 0 ] && [ "$(creates)" = 0 ] && [ "$(acts)" = 0 ] && echo 1 || echo 0)"

  echo "--- saida: só LÊ o mundo (do bd, só a lista de in_progress; nada de dolt nem notify, nem outro subcomando do gc)"
  fresh; sessions_are "$SJ_ZOMBIES"; beads_are '[]'; tick 900 5 >/dev/null; idle_run 3
  check "nenhuma chamada proibida (bd fora da leitura de in_progress, dolt, outro subcomando do gc) e, sem as chaves da escada, nenhum notify, bd create nem ação ao nó" "$([ ! -s "$T/stub/forbidden.calls" ] && [ "$(notifies)" = 0 ] && [ "$(creates)" = 0 ] && [ "$(acts)" = 0 ] && echo 1 || echo 0)"
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
# lastro hq-mutants (ga-59jrj3d): o que o rodízio de 03/11 achou vivo. Duas metades: um programa Python que IMPORTA o vigia e confere as funções puras no valor exato (configuração e seus pisos, prazo da morte do processo, cópia do arquivo corrompido,
# /proc/stat, baseline, fila, foco, sequência de CPU baixa, migração do diário, texto dos três e-mails) e casos de ponta a ponta (formato dos arquivos que o vigia grava, estado editado à mão, contas que só o estado de ontem mostra).
g_lastro() {
  local l dj sj
  echo "--- lastro: funções puras no valor exato (o vigia importado como módulo)"
  mkdir -p "$T/lastro"
  cat > "$T/lastro.py" <<'PY'
import contextlib, importlib.util, io, json, os, sys, time
sys.dont_write_bytecode = True
sys.stdout.reconfigure(encoding="utf-8")
spec = importlib.util.spec_from_file_location("hoc_watch", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
WORK = sys.argv[2]
EXPECT = 53
ran = [0]


def chk(name, got, want):
    ran[0] += 1
    try:
        g = got() if callable(got) else got
    except Exception as e:   # uma exceção é o caso reprovado, não o fim do programa
        print("FAIL %s :: levantou %s: %s" % (name, type(e).__name__, e))
        return
    print("ok %s" % name if g == want else "FAIL %s :: obtido=%r esperado=%r" % (name, g, want))


# ---- configuração: o padrão, o piso que vale e o logo abaixo que é recusado ----------------------------------------------------------------
def cfg(**kw):
    env = {"GC_CITY_PATH": WORK + "/city", "HOME": WORK + "/home"}
    env.update(kw)
    return m.load_config(env)


def rejects(**kw):
    try:
        cfg(**kw)
    except ValueError:
        return True
    return False


for key, attr, dflt, lo in (("HETZNER_OCC_INTERVAL_S", "interval_s", 900, 60), ("HETZNER_OCC_IDLE_AFTER_S", "idle_after_s", 1800, 60), ("HETZNER_OCC_BLIND_AFTER_S", "blind_after_s", 3600, 60),
                            ("HETZNER_OCC_IDLE_COOLDOWN_S", "idle_cooldown_s", 10800, 0), ("HETZNER_OCC_BLIND_COOLDOWN_S", "blind_cooldown_s", 21600, 0),
                            ("HETZNER_OCC_LOW_AFTER_S", "low_after_s", 1800, 60), ("HETZNER_OCC_LOW_COOLDOWN_S", "low_cooldown_s", 10800, 0),
                            ("HETZNER_OCC_SSH_TIMEOUT_S", "ssh_timeout_s", 30, 1), ("HETZNER_OCC_GC_TIMEOUT_S", "gc_timeout_s", 60, 1),
                            ("HETZNER_OCC_BD_TIMEOUT_S", "bd_timeout_s", 60, 1), ("GATE_FOCUS_STALE_S", "focus_stale_s", 7200, 1)):
    chk("cfg %s: o padrão é %d, o piso %d vale e %d é recusado" % (key, dflt, lo, lo - 1),
        lambda key=key, attr=attr, lo=lo: (getattr(cfg(), attr), getattr(cfg(**{key: str(lo)}), attr), rejects(**{key: str(lo - 1)})), (dflt, lo, True))
chk("cfg: STORES vazio é recusado, OTHER_HOSTS vazio vale 'nenhum' e os padrões são hq e mbp",
    lambda: (rejects(HETZNER_OCC_STORES=""), rejects(HETZNER_OCC_STORES=" , "), cfg(HETZNER_OCC_OTHER_HOSTS="").other_hosts, cfg().other_hosts, cfg().stores), (True, True, [], ["mbp"], ["hq"]))
chk("cfg: a folga do launchd é 120 s e a tolerância de relógio da fila é 60 s", lambda: (cfg().slack_s, cfg().future_tol_s), (120, 60))
chk("cfg: o arquivo do Pilot vem do HOME do ambiente; sem HOME no ambiente, do ~ do processo",
    lambda: (cfg().pilot_file, m.load_config({"GC_CITY_PATH": WORK + "/city"}).pilot_file),
    (WORK + "/home/.gc/pilot-dispatchable.json", os.path.join(os.path.expanduser("~"), ".gc", "pilot-dispatchable.json")))


# ---- processos e arquivos ---------------------------------------------------------------------------------------------------------------------
class FakeProc:
    pid = 424242

    def communicate(self, timeout=None):
        waits.append(timeout)
        if len(waits) == 1:
            raise m.subprocess.TimeoutExpired("fake", timeout)
        return "", ""


waits = []
real_popen, real_killpg, real_run = m.subprocess.Popen, m.os.killpg, m.run_cmd
m.subprocess.Popen, m.os.killpg = (lambda *a, **k: FakeProc()), (lambda pid, sig: None)
try:
    got = m.run_cmd(["fake"], 7)
except Exception as e:
    got = "levantou %s: %s" % (type(e).__name__, e)
finally:
    m.subprocess.Popen, m.os.killpg = real_popen, real_killpg
chk("run_cmd: prazo estourado devolve (None, '', '', 'timeout') e, depois de matar, espera 5 s o que sobrou", (got, waits), ((None, "", "", "timeout"), [7, 5]))
chk("_oneline: junta os espaços, corta em 160 e aceita None", (len(m._oneline("x " * 400)), m._oneline("  a \n b\t c  "), m._oneline(None)), (160, "a b c", ""))
dj = WORK + "/daily.json"


def corrupto(dry):
    with open(dj, "w") as fh:
        fh.write("lixo{")
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            r = m.load_json(dj, lambda o: isinstance(o, dict), 1000, dry)
    except Exception as e:
        r = "levantou %s: %s" % (type(e).__name__, e)
    return r, err.getvalue()


r1, e1 = corrupto(False)
chk("load_json: arquivo corrompido vira <arquivo>.corrupt-<epoch> e o original sai do lugar", (r1, os.path.exists(dj + ".corrupt-1000"), os.path.exists(dj)), (None, True, False))
chk("load_json: o aviso diz que a cópia FICOU em <arquivo>.corrupt-1000", ("a cópia ficou em " + dj + ".corrupt-1000" in e1, "--dry-run" in e1), (True, False))
r2, e2 = corrupto(True)
chk("load_json --dry-run com o nome já usado: diz que a cópia IRIA para .corrupt-<epoch>-2 e não move nada", (r2, "(--dry-run) a cópia iria para " + dj + ".corrupt-1000-2" in e2, "ficou em" in e2, os.path.exists(dj)), (None, True, False, True))
r3, e3 = corrupto(False)
chk("load_json: nome já usado vira .corrupt-<epoch>-2 (o 2, não o 1)", (os.path.exists(dj + ".corrupt-1000-2"), os.path.exists(dj + ".corrupt-1000-1")), (True, False))

# ---- /proc/stat, baseline e a janela de CPU -------------------------------------------------------------------------------------------------
B, E = m.BEGIN, m.END
blk = "\n".join(["ruído do .bashrc", B, "cpu  10 0 5 80 3 1 2 4 0 0", "cpu0 1 0 0 1 0 0 0 0 0 0", "", "intr 5 6 7", "cpu1 1 0 0 1 0 0 0 0 0 0", "  ", "ctxt 9", E, "depois"])
chk("parse_stat: linha vazia e linha que não é cpuN dentro do bloco não contam como núcleo", lambda: m.parse_stat(blk), ((18, 105, 2), None))
for nome, b, want in (("válido", {"epoch": 1, "busy": 2, "total": 3}, True), ("zeros valem", {"epoch": 0, "busy": 0, "total": 0}, True), ("falta o total", {"epoch": 1, "busy": 2}, False),
                      ("valor booleano", {"epoch": 1, "busy": True, "total": 3}, False), ("valor negativo", {"epoch": 1, "busy": -2, "total": 3}, False),
                      ("valor decimal", {"epoch": 1, "busy": 2.5, "total": 3}, False), ("valor em texto", {"epoch": 1, "busy": "2", "total": 3}, False),
                      ("None", None, False), ("lista", [1, 2, 3], False)):
    chk("_baseline_ok: %s" % nome, lambda b=b: m._baseline_ok(b), want)
def lido():
    m.run_cmd = lambda argv, t: (0, "\n".join([B, "cpu  1 0 0 6 0 0 0 0 0 0", "cpu0 0 0 0 0 0 0 0 0 0 0", E]), "", None)
    try:
        cpu, nb, cores = m.read_cpu(cfg(), {"epoch": 1000, "busy": 0, "total": 0}, 1900)
    finally:
        m.run_cmd = real_run
    return cpu["lido"], cpu["nucleos"], cpu["pct"], cpu["janela_s"], nb, cores


chk("read_cpu: 1/7 de núcleo em 900 s sai como 0.14 núcleo (2 casas), 14.3 % e o novo baseline", lido, (True, 0.14, 14.3, 900, {"epoch": 1900, "busy": 1, "total": 7}, 1 / 7))

# ---- fila do Pilot e foco do gate -------------------------------------------------------------------------------------------------------------
qf, T0 = WORK + "/pilot.json", 1_700_000_000


def fila(gen, n_hq):
    its = [{"id": "ga-%d" % i, "store": "hq"} for i in range(n_hq)] + [{"id": "wa-9", "store": "whatsapp_automation"}]
    with open(qf, "w") as fh:
        json.dump({"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(gen)), "ttl_seconds": 1800, "items": its}, fh)
    return m.read_queue(cfg(HETZNER_OCC_PILOT_FILE=qf), T0)


chk("read_queue: 7 elegíveis dão n = 7 e só os 5 primeiros ids", lambda: [(r["lido"], r["n"], r["ids"]) for r in [fila(T0 - 10, 7)]][0], (True, 7, ["ga-0", "ga-1", "ga-2", "ga-3", "ga-4"]))
chk("read_queue: gerada 60 s no futuro (a tolerância) ainda vale; 61 s é 'no-futuro'", lambda: (fila(T0 + 60, 1)["lido"], fila(T0 + 61, 1)["motivo"]), (True, "no-futuro"))
cf = cfg()
os.makedirs(cf.gc_dir, exist_ok=True)
with open(os.path.join(cf.gc_dir, "gate-focus.state"), "w") as fh:
    fh.write("active=1\nat=%d\nactive=0\nat=1\nsem igual\n" % T0)
chk("read_focus: chave repetida vale a 1ª (ligado) e linha sem '=' não vira chave", lambda: m.read_focus(cf, T0), "ligado")

# ---- números do estado, sequência de CPU baixa e diário ---------------------------------------------------------------------------------------
chk("_int: 0 vale (>= 0); negativo, bool, texto e decimal vão para o padrão", (m._int(0, 9), m._int(5), m._int(-1, 9), m._int(True, 9), m._int("3", 9), m._int(2.0, 9), m._int(None)), (0, 5, 9, 9, 9, 9, None))
chk("_flt: 0 vale (>= 0); negativo, bool, infinito, NaN e texto vão para o padrão; inteiro vira decimal",
    (m._flt(0, 9.0), m._flt(0.5), m._flt(3), m._flt(-0.1, 9.0), m._flt(True, 9.0), m._flt(float("inf"), 9.0), m._flt(float("nan"), 9.0), m._flt("1", 9.0), m._flt(None)),
    (0.0, 0.5, 3.0, 9.0, 9.0, 9.0, 9.0, 9.0, None))
cpu = {"lido": True, "pct": 10.0, "janela_s": 900, "ncpu": 16}
win_n, win_c = 1.6 * 900, 16 * 900
novo = {"n": 1, "desde": T0 - 900, "nucleos_s": win_n, "cap_s": win_c}
resto = {"baixa_desde": T0 - 5000, "baixa_nucleos_s": 7.0, "baixa_capacidade_s": 70.0}
chk("low_streak: estado sem baixas_seguidas recomeça a sequência (n = 1, desde = o início desta janela)", lambda: m.low_streak(cfg(), dict(resto), cpu, 1.6, T0), novo)
chk("low_streak: baixas_seguidas = 0 também recomeça; com 2 continua (n + 1, desde antigo, acumuladores somados)",
    lambda: (m.low_streak(cfg(), dict(resto, baixas_seguidas=0), cpu, 1.6, T0), m.low_streak(cfg(), dict(resto, baixas_seguidas=2), cpu, 1.6, T0)),
    (novo, {"n": 3, "desde": T0 - 5000, "nucleos_s": 7.0 + win_n, "cap_s": 70.0 + win_c}))
dias = {"dias": {"2026-10-01": {"ocupado": 3}, "2026-10-02": {"ocupacao_pct": 80.0}, "2026-10-03": {"ocupacao_pct": 50.0, "ocupacao_sessao_pct": 70.0},
                 "2026-10-04": {"cpu_janelas": 2, "ocupacao_pct": 12.0}, "2026-10-05": "não é um dia"}}
cpu0 = {"ocupacao_pct": None, "cpu_janelas": 0, "cpu_nucleos_s": 0.0, "cpu_capacidade_s": 0}
chk("migrate_daily: não levanta com dia sem número nenhum nem com dia que não é objeto", lambda: m.migrate_daily(dias), None)
chk("migrate_daily: dia sem número nenhum só ganha os campos de CPU", dias["dias"]["2026-10-01"], dict(cpu0, ocupado=3))
chk("migrate_daily: o ocupacao_pct antigo vira ocupacao_sessao_pct e o de CPU fica null", dias["dias"]["2026-10-02"], dict(cpu0, ocupacao_sessao_pct=80.0))
chk("migrate_daily: quem já tem ocupacao_sessao_pct a mantém", dias["dias"]["2026-10-03"], dict(cpu0, ocupacao_sessao_pct=70.0))
chk("migrate_daily: dia que já tem cpu_janelas não muda", (dias["dias"]["2026-10-04"], dias["dias"]["2026-10-05"]), ({"cpu_janelas": 2, "ocupacao_pct": 12.0}, "não é um dia"))

# ---- o texto dos três e-mails e o prazo do gc mail send --------------------------------------------------------------------------------------
cm = cfg()
RD = {"epoch": T0, "foco": "desligado", "ociosas_seguidas": 3, "cegas_seguidas": 5, "cpu_cegas_seguidas": 4,
      "fila": {"lido": True, "n": 4, "ids": ["ga-1", "ga-2"], "motivo": None}, "sessoes": {"ativas": 2, "ocupadas": 0, "motivo": None},
      "cpu": {"nucleos": 0.3, "ncpu": 16, "janela_s": 900, "pct": 1.9, "motivo": None}}


def rd(foco="desligado", sess_motivo=None, sess_det=None, cpu_det=None, fila_motivo=None):
    r = json.loads(json.dumps(RD))
    r["foco"], r["sessoes"]["motivo"], r["fila"]["motivo"] = foco, sess_motivo, fila_motivo
    if sess_det is not None:
        r["sessoes"]["detalhe"] = sess_det
    if cpu_det is not None:
        r["cpu"]["detalhe"] = cpu_det
    return r


def lin(b, p):
    return [x for x in b.split("\n") if x.startswith(p)]


def corpo(fn, *a):
    try:
        return fn(*a)[1]
    except Exception as e:
        return "levantou %s: %s" % (type(e).__name__, e)


LOW = {"desde": T0 - 1800, "n": 2, "nucleos_s": 100.0, "cap_s": 200.0}
b = corpo(m.idle_mail, cm, rd("desconhecido"), 1800)
chk("idle_mail: foco desconhecido sai como 'desconhecido (tratado como desligado)'", "• foco do gate: desconhecido (tratado como desligado)\n" in b, True)
chk("idle_mail: o cooldown de 10800 s sai como 'no mínimo 3 h'", "Próximo aviso deste tipo em no mínimo 3 h. " in b, True)
b = corpo(m.idle_mail, cm, rd("ligado"), 1800)
chk("idle_mail: foco ligado sai sem o sufixo", ("• foco do gate: ligado\n" in b, "tratado" in b), (True, False))
b = corpo(m.low_mail, cm, rd("desconhecido"), LOW)
chk("low_mail: foco desconhecido sai como 'tratado como desligado' e o cooldown como 'no mínimo 3 h'", ("foco do gate: desconhecido (tratado como desligado)" in b, "em no mínimo 3 h. " in b), (True, True))
b = corpo(m.low_mail, cm, rd("desligado"), LOW)
chk("low_mail: foco desligado sai sem o sufixo", ("foco do gate: desligado" in b, "tratado" in b), (True, False))
b = corpo(m.blind_mail, cm, rd(sess_motivo="gc-falhou", sess_det="boom", cpu_det="x", fila_motivo="arquivo-ausente"), 3600)
chk("blind_mail: a linha de motivos traz o de cada leitura (o da fila também) e o detalhe junta sessão e CPU", (lin(b, "• sessões:"), lin(b, "• detalhe:")),
    (["• sessões: gc-falhou · CPU: ok · fila: arquivo-ausente"], ["• detalhe: boom x"]))
b = corpo(m.blind_mail, cm, rd(sess_motivo="gc-falhou"), 3600)
chk("blind_mail: sem motivo na fila nem detalhe saem 'fila: ok' e '• detalhe: -'", (lin(b, "• sessões:"), lin(b, "• detalhe:")), (["• sessões: gc-falhou · CPU: ok · fila: ok"], ["• detalhe: -"]))
b = corpo(m.blind_mail, cm, rd(sess_motivo="gc-falhou", sess_det="a" * 300), 3600)
chk("blind_mail: o detalhe é cortado em 200 caracteres", lin(b, "• detalhe:"), ["• detalhe: " + "a" * 200])
chk("blind_mail: o cooldown de 21600 s sai como 'no mínimo 6 h'", "em no mínimo 6 h." in b, True)
seen = []
m.run_cmd = lambda argv, t: (seen.append(t), (0, "", "", None))[1]
try:
    sent = m.send_mail(cm, "assunto", "corpo")
except Exception as e:
    sent = "levantou %s: %s" % (type(e).__name__, e)
finally:
    m.run_cmd = real_run
chk("send_mail: o prazo do gc mail send é 45 s", (sent, seen), (True, [45]))
print("ok o programa rodou até o fim (%d verificações)" % ran[0] if ran[0] == EXPECT else "FAIL o programa rodou %d verificações, esperava %d" % (ran[0], EXPECT))
PY
  python3 -I "$T/lastro.py" "$WATCH" "$T/lastro" > "$T/lastro.out" 2>&1
  while IFS= read -r l; do case "$l" in "ok "*) ok "${l#ok }" ;; *) bad "$l" ;; esac; done < "$T/lastro.out"

  echo "--- lastro: o que o vigia imprime e grava (recuo, ordem das chaves, acento) e as contas que só o estado de ontem mostra"
  fresh; W GC_CITY_PATH="$T/çidade" -- --print-config
  eq "print-config: recuo de 2 espaços e acento sem escape (ensure_ascii=False)" 1 "$(grep -c '^  "city": ".*çidade",$' "$WOUT" | tr -d ' ')"
  fresh; sessions_are '{"sessions":[{"session_name":"dog-remote-ação","alias":"dog-remote-ação","state":"active"}]}'; beads_are '[{"id":"ga-b1","status":"in_progress","assignee":"dog-remote-ação"}]'
  dj="$C/.gc/hetzner-occupancy-daily.json"; sj="$C/.gc/hetzner-occupancy.state.json"
  printf '{"dias":{},"nota":"ação"}' > "$dj"; tick 900 5
  eq "--print: recuo de 2 espaços e acento sem escape (o nome sai nas duas listas, nomes e nomes_ocupadas)" "1/2" "$(grep -c '^  "estado": "ocupado",$' "$WOUT" | tr -d ' ')/$(grep -c 'dog-remote-ação' "$WOUT" | tr -d ' ')"
  eq "JSONL: o acento fica como está (ensure_ascii=False)" 1 "$(grep -c '"nomes":\["dog-remote-ação"\]' "$C/.gc/hetzner-occupancy.jsonl" | tr -d ' ')"
  eq "diário: recuo de 1 espaço, chaves do dia em ordem (a 1ª é cpu_capacidade_s) e o campo extra com acento fica como está" '{| "dias": {|  "2026-10-19": {|   "cpu_capacidade_s": 0,|1' "$(sed -n 1,4p "$dj" | tr '\n' '|')$(grep -c '"nota": "ação"' "$dj" | tr -d ' ')"
  eq "estado: recuo de 1 espaço, chaves em ordem (a 1ª é alarme_baixa_em) e versao 1" '{| "alarme_baixa_em": null,|1' "$(sed -n 1,2p "$sj" | tr '\n' '|')$(state_f versao)"
  fresh; tick 900 5 >/dev/null; idle_run 2; STUB_MAIL_RC=1; tick 900 5
  eq "mail que falha: o estado regravado segue com recuo de 1 espaço e chaves em ordem" '{| "alarme_baixa_em": null,|' "$(sed -n 1,2p "$sj" | tr '\n' '|')"
  fresh; tick 900 5 >/dev/null; idle_run 2; TENV=(STUB_MAIL_SABOTAGE=1); tick 900 5
  eq "o arquivo de estado vira pasta durante o mail: sem mail que falhou não há 2ª gravação (rc 0, mail enviado)" "0/enviado" "$RC/$(reading alarme.ocioso)"
  fresh; tick 900 5 >/dev/null; W -- --dry-run --print
  eq "--dry-run --print: a leitura traz dry_run = true" true "$(reading dry_run)"
  fresh_lp; pilot 60 1800 3 0; statfile "$T/stat.txt" 100000 900000 16; STUB_SSH_FILE="$T/stat.txt"; W -- --print
  NOW=$((NOW + 900)); pilot 60 1800 3 0; statfile "$T/stat.txt" 101000 906000 16; W -- --print
  eq "baixa: 1000/7000 de 16 núcleos em 900 s = 2057.142... núcleo-s, gravados com 2 casas" 2057.14 "$(state_f baixa_nucleos_s)"
  fresh; STUB_GC_RC=1; tick 900 5
  eq "1ª leitura com o gc caindo: já conta 1 leitura cega (a CPU só semeia, mas a sessão não leu)" 1 "$(reading cegas_seguidas)"
  fresh; tick 900 5 >/dev/null; state_set ociosas_seguidas=; tick 900 5
  eq "estado sem ociosas_seguidas: a contagem de ocioso recomeça de 0 (a 1ª leitura ociosa é a 1ª)" 1 "$(reading ociosas_seguidas)"
  fresh; printf '{"versao":1,"cegas_seguidas":0,"decidida_em":%s}' "$((NOW + 900 - 4000))" > "$sj"; tick 900 5
  eq "aquecimento da CPU (sem baseline) com a última decisão há 66 min: não é leitura cega, nenhum aviso de cego" "nao/0" "$(reading alarme.cego)/$(mails)"
  fresh; tick 900 5 >/dev/null; state_set cegas_seguidas=0 "decidida_em=$((NOW + 900 - 4000))"; STUB_GC_RC=1; tick 900 5
  eq "a 1ª leitura cega depois de uma decisão há 66 min já avisa (cegas = 1 basta)" "enviado/1" "$(reading alarme.cego)/$(mails)"
  fresh; tick 900 5 >/dev/null; printf '{"foo":1}' > "$dj"; tick 900 5
  eq "diário que é objeto mas sem 'dias': a cópia fica guardada ao lado e o vigia segue (rc 0)" "0/1" "$RC/$(ls "$C/.gc" | grep -c '^hetzner-occupancy-daily.json.corrupt-' | tr -d ' ')"
  eq "... e o diário novo tem a leitura de agora" 1 "$(jv "$dj" dias.2026-10-19.leituras)"
  fresh; tick 900 5 >/dev/null; printf '[1,2]' > "$dj"; tick 900 5
  eq "diário que é uma lista: o mesmo" "0/1" "$RC/$(ls "$C/.gc" | grep -c '^hetzner-occupancy-daily.json.corrupt-' | tr -d ' ')"
}

# ============================================================================================================================================================================
g_causa() {
  echo "--- causa: de onde vem o número (núcleos por parte), UMA causa por leitura abaixo da régua, e o que NÃO é lido nunca vira causa (ga-2hd02v.5.10)"
  local dj a0; fresh_lp; xfresh; dj="$C/.gc/hetzner-occupancy-daily.json"
  xtick 900 $LOWW >/dev/null
  eq "1ª leitura: a CPU só semeou o baseline, então não há núcleos por parte (motivo dito)" "false/sem-leitura-anterior" "$(reading nucleos.lido)/$(reading nucleos.motivo)"
  eq "... e a causa é 'cego' (nunca um chute)" cego "$(reading causa)"
  xtick 900 $LOWW
  eq "a janela lida: 2,0 núcleos em sessões" 2.0 "$(reading nucleos.sessoes)"; eq "... 0,3 no lastro" 0.3 "$(reading nucleos.lastro)"; eq "... 0,5 de sistema (CPU total menos o user slice)" 0.5 "$(reading nucleos.sistema)"
  eq "... 1,5 esperando disco (iowait)" 1.5 "$(reading nucleos.espera)"; eq "... 11,7 livres (16 - 2,8 ocupados - 1,5 de espera)" 11.7 "$(reading nucleos.livres)"; eq "... na janela de 900 s" 900 "$(reading nucleos.janela_s)"
  eq "a CPU da mesma leitura: 17,5 % (2,8 de 16)" 17.5 "$(reading cpu.pct)"; eq "a RAM livre do nó vai na leitura" 20000 "$(reading ram_mb)"
  eq "a causa: sobram núcleos e a RAM comporta mais lastro = lastro-sem-trabalho" lastro-sem-trabalho "$(reading causa)"
  eq "o lixo foi LIDO e não há (tmux do nó vazio)" "true/0" "$(reading lixo.lido)/$(reading lixo.n)"
  eq "o diário do dia conta a causa" 1 "$(jv "$dj" dias.2026-10-19.causas.lastro-sem-trabalho)"; eq "... e a 1ª leitura (cego) NÃO entrou na conta de causas" 1 "$(jv "$dj" dias.2026-10-19.causas | python3 -I -c 'import json,sys; print(sum(json.load(sys.stdin).values()))')"
  eq "o diário soma os núcleos-segundo de cada parte (sessões 2,0 x 900 s)" 1800.0 "$(jv "$dj" dias.2026-10-19.decomp_s.sessoes)"; eq "... os livres (11,7 x 900)" 10530.0 "$(jv "$dj" dias.2026-10-19.decomp_s.livres)"
  eq "... e as janelas que entraram na decomposição" 900 "$(jv "$dj" dias.2026-10-19.decomp_win_s)"
  XARGS= xtick 900 $LOWW; has "a linha-resumo termina com a causa" " causa=lastro-sem-trabalho" "$(cat "$WOUT")"
  eq "a CPU média do diário (o número de sempre) continua sendo a de CPU, não mudou" 17.5 "$(jv "$dj" dias.2026-10-19.ocupacao_pct)"

  # ---- a régua: acima dela não há o que explicar; a causa só existe com a CPU lida E abaixo --------------------------------------------------------------------------------
  xfresh; xone 1300 30 30 0 >/dev/null; eq "CPU em 85,0 % (13,6 núcleos): na meta, sem causa" "85.0/null" "$(reading cpu.pct)/$(reading causa)"
  xfresh; xone 1299 30 30 0 >/dev/null; eq "CPU em 84,9 %: abaixo da meta, tem causa (os núcleos livres são 2,4 e a RAM sobra)" "84.9/lastro-sem-trabalho" "$(reading cpu.pct)/$(reading causa)"
  xfresh; xone 1400 30 50 0 >/dev/null; eq "CPU em 92,5 %: sem causa" null "$(reading causa)"
  eq "... e sem causa o diário não conta causa nenhuma" null "$(jv "$dj" dias.2026-10-19.causas)"
  xfresh; xone 1400 30 50 0 >/dev/null; eq "... mas a decomposição vai para o diário mesmo assim (é medida, não causa)" 14.0 "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["dias"]["2026-10-19"]["decomp_s"]["sessoes"]/900)' "$dj")"

  # ---- a RAM decide se o lastro cabe: piso de partida 14336 MB + 1 slot de 1024 -------------------------------------------------------------------------------------------
  xfresh; X_RAM_MB=15359; xone $LOWW >/dev/null; eq "RAM 15359 MB (1 MB abaixo do piso + 1 slot): causa RAM" RAM "$(reading causa)"
  xfresh; X_RAM_MB=15360; xone $LOWW >/dev/null; eq "RAM 15360 MB: já cabe um slot" lastro-sem-trabalho "$(reading causa)"
  xfresh; X_OMIT="mem"; xone $LOWW >/dev/null; eq "RAM não lida com núcleos sobrando: cego (não sei se o lastro cabe), e o JSONL diz ram_mb null" "cego/null" "$(reading causa)/$(reading ram_mb)"
  xfresh; X_RAM_MB=8000; node_add "$GHOST" 14400; xone $LOWW >/dev/null; eq "o lixo vem ANTES da RAM na prioridade (a sessão sem dono se resolve sem lastro)" lixo "$(reading causa)"

  # ---- fila sem elegível: só quando os núcleos NÃO sobram (iowait os come) e a fila foi LIDA e vazia ----------------------------------------------------------------------------
  xfresh; PILOT_HQ=0; xone 600 30 50 800 >/dev/null; eq "sem núcleo sobrando (livres 1,2) e a fila lida vazia: fila-sem-elegível" "1.2/fila-sem-elegível" "$(reading nucleos.livres)/$(reading causa)"
  xfresh; PILOT_HQ=3; xone 600 30 50 800 >/dev/null; eq "sem núcleo sobrando e a fila TEM item: nada das quatro explica = cego (não inventa causa)" cego "$(reading causa)"
  xfresh; PILOT_HQ=none; xone 600 30 50 800 >/dev/null; eq "sem núcleo sobrando e a fila não lida (arquivo do Pilot ausente): cego, nunca 'fila vazia'" cego "$(reading causa)"
  xfresh; PILOT_HQ=0; xone 600 30 50 720 >/dev/null; eq "livres EXATAMENTE 2,0 contam como sobra (a régua é >=)" "2.0/lastro-sem-trabalho" "$(reading nucleos.livres)/$(reading causa)"
  xfresh; PILOT_HQ=0; xone 600 30 50 730 >/dev/null; eq "livres 1,9: a fila vazia decide" "1.9/fila-sem-elegível" "$(reading nucleos.livres)/$(reading causa)"

  # ---- o lixo: sessão do tmux do nó que a cidade não conhece, não segura bead e está quieta há >= 30 min ----------------------------------------------------------------------------
  xfresh; node_add "$GHOST" 14400; xone $LOWW >/dev/null
  eq "o caso real de 04/11 (a gate-reviewer-remote-adhoc parada há 4 h, fora da cidade): causa lixo" lixo "$(reading causa)"; eq "... n e o nome na leitura" "1/[\"$GHOST\"]" "$(reading lixo.n)/$(reading lixo.nomes)"; eq "... e há quanto tempo está parada" 14400 "$(reading lixo.ocioso_max_s)"
  check "o alvo interno (_alvos) NÃO vai ao JSONL" "$(grep -q '_alvos\|_reconhecidas\|_donos' "$WOUT" && echo 0 || echo 1)"
  xfresh; node_add "$GHOST" 1799; xone $LOWW >/dev/null; eq "quieta há 1799 s: ainda não é lixo" "0/lastro-sem-trabalho" "$(reading lixo.n)/$(reading causa)"
  xfresh; node_add "$GHOST" 1800; xone $LOWW >/dev/null; eq "quieta há 1800 s: é" "1/lixo" "$(reading lixo.n)/$(reading causa)"
  xfresh; W HETZNER_OCC_D1_IDLE_S=7200 -- --print-config; eq "o prazo do lixo é configurável (D1_IDLE_S)" 7200 "$(reading d1_idle_s)"
  xfresh; node_add dog-remote-velha 14400; xone $LOWW >/dev/null; eq "sessão que a cidade lista (mesmo dormindo, 'asleep') NÃO é lixo" 0 "$(reading lixo.n)"
  xfresh; node_add dog-remote-gapxi4ls 14400; sessions_are "$SJ_REMOTE"; xone $LOWW >/dev/null; eq "sessão viva que a cidade lista: não é lixo" 0 "$(reading lixo.n)"
  xfresh; node_add dog-remote-2 14400; sessions_are "$SJ_ZOMBIES"; xone $LOWW >/dev/null; eq "o ALIAS do pool também reconhece (dog-remote-2): não é lixo" 0 "$(reading lixo.n)"
  xfresh; node_add "$GHOST" 14400; beads_are "[{\"id\":\"ga-b9\",\"status\":\"in_progress\",\"assignee\":\"$GHOST\"}]"; xone $LOWW >/dev/null
  eq "sessão que SEGURA uma bead in_progress nunca é lixo, mesmo fora da lista da cidade e parada" "0/lastro-sem-trabalho" "$(reading lixo.n)/$(reading causa)"
  xfresh; node_add gate-reviewer-remote-mbp-ab12 14400; xone $LOWW >/dev/null; eq "sessão de outro host (-remote-mbp-) não é do nó: não é lixo" 0 "$(reading lixo.n)"
  xfresh; node_add worker-abc 14400; node_add 'evil;touch-remote-x' 14400; xone $LOWW >/dev/null; eq "nome sem -remote- e nome com caractere perigoso: nunca candidatos" 0 "$(reading lixo.n)"
  xfresh; node_add gate-reviewer-remote-young 600; xone $LOWW >/dev/null; eq "sessão sem dono parada há só 10 min (< 30): ainda pode estar trabalhando, não é lixo" "0/true" "$(reading lixo.n)/$(reading lixo.lido)"
  xfresh; node_add "$GHOST" 14400; node_add "gate-reviewer-remote-b" 20000; node_add "gate-reviewer-remote-c" 9000; xone $LOWW >/dev/null
  eq "3 candidatas: n=3, as mais quietas primeiro" "3/[\"gate-reviewer-remote-b\", \"$GHOST\", \"gate-reviewer-remote-c\"]" "$(reading lixo.n)/$(reading lixo.nomes)"
  xfresh; node_add "$GHOST" 14400; sessions_are '{"sessions":[{"id":"s1"}]}'; xone $LOWW >/dev/null
  eq "a cidade com entrada sem nome: não sei o que ela conhece, então NÃO há lixo (lido false, motivo dito)" "false/cidade-ilegivel/lastro-sem-trabalho" "$(reading lixo.lido)/$(reading lixo.motivo)/$(reading causa)"
  xfresh; node_add "$GHOST" 14400; STUB_GC_RC=1; xone $LOWW >/dev/null; eq "gc que falha: lixo não lido (o mesmo)" "false/cidade-ilegivel" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; node_add "$GHOST" 14400; STUB_BD_RC=1; sessions_are "$SJ_REMOTE"; xone $LOWW >/dev/null; eq "bd que falha com a cidade com sessão viva: não sei quem segura bead, então o lixo NÃO é lido" "false/donos-ilegivel:bd-falhou" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; node_add "$GHOST" 14400; STUB_BD_RC=1; xone $LOWW >/dev/null; eq "cidade sem sessão viva (o gc não chamou o bd) e o bd fora: o vigia lê os donos ele mesmo; falhou, então o lixo NÃO é lido" "false/donos-ilegivel:bd-falhou" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; node_add "$GHOST" 14400; X_OMIT="now"; xone $LOWW >/dev/null; eq "sem o relógio do nó não sei há quanto a sessão está parada: lixo não lido" "false/sem-relogio-do-no" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; node_add "$GHOST" 14400; X_TMUX=falha; xone $LOWW >/dev/null; eq "tmux que falha por outro motivo (rc 1, não é 'sem servidor'): NÃO é lista vazia" "false/tmux-ilegivel:tmux-rc-1" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; X_TMUX=semservidor; xone $LOWW >/dev/null; eq "tmux sem servidor no nó: lista vazia, lida" "true/0" "$(reading lixo.lido)/$(reading lixo.n)"
  xfresh; X_TMUX=lixo; xone $LOWW >/dev/null; eq "linha do tmux que não é nome|atividade: lista ilegível inteira" "false/tmux-ilegivel:linha-ilegivel" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; X_TMUX=semrc; xone $LOWW >/dev/null; eq "tmux sem o rc= antes da lista: ilegível" "false/tmux-ilegivel:rc-ausente" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; X_OMIT="tmux"; xone $LOWW >/dev/null; eq "seção do tmux ausente (a ssh cortou): ilegível, não vazia" "false/tmux-ilegivel:sem-secao" "$(reading lixo.lido)/$(reading lixo.motivo)"

  # ---- "quieta" é a MAIOR entre a atividade de input e a de saída, de todas as janelas (nó, 04/11: dog-remote-gawispvtzl0 com input de 2 h 23 atrás e saída de agora) -----------------------------
  xfresh; node_add "$GHOST" 14400 1800 60; xone $LOWW >/dev/null; eq "input parado há 4 h mas a SAÍDA (window_activity) mexeu há 1 min: a sessão trabalha, não é lixo" "0/true" "$(reading lixo.n)/$(reading lixo.lido)"
  xfresh; node_add "$GHOST" 60 1800 14400; xone $LOWW >/dev/null; eq "o contrário, input há 1 min e saída parada há 4 h: também não é lixo (vale a mais recente)" 0 "$(reading lixo.n)"
  xfresh; node_add "$GHOST" 14400 1800 60; node_add "$GHOST" 14400; xone $LOWW >/dev/null; eq "duas janelas da mesma sessão, a 1ª recente e a 2ª parada: vale a mais recente de TODAS (não a última linha)" 0 "$(reading lixo.n)"
  xfresh; node_add "$GHOST" 14400 1800 12000; node_add "$GHOST" 14400 1800 9000; xone $LOWW >/dev/null; eq "tudo parado (janelas de 12000 s e 9000 s, input de 14400 s): é lixo, parado há 9000 s (a atividade mais recente)" "1/9000" "$(reading lixo.n)/$(reading lixo.ocioso_max_s)"
  xfresh; node_add "$GHOST" 14400; sessions_are '{"sessions":[{"id":"s1","template":"dog-remote","state":"asleep"}]}'; xone $LOWW >/dev/null
  eq "a cidade com uma entrada só com template (sem session_name, name nem alias): não sei com que nome o tmux a conhece, então NÃO há lixo" "false/cidade-ilegivel" "$(reading lixo.lido)/$(reading lixo.motivo)"

  # ---- quem segura bead é lido em TODAS as lojas (hq e rigs): o `bd list` da cidade só traz as beads ga- ------------------------------------------------------------------------------------
  xfresh; node_add "$GHOST" 14400; printf '[{"id":"wa-1","status":"in_progress","assignee":"%s"}]' "$GHOST" > "$T/stub/bd.rig.wa"; xone $LOWW >/dev/null
  eq "sessão fora da lista da cidade que segura bead de um RIG (wa), parada há 4 h: não é lixo" "0/true" "$(reading lixo.n)/$(reading lixo.lido)"
  xfresh; node_add "$GHOST" 14400; xone $LOWW >/dev/null; eq "... e sem bead em loja nenhuma é lixo (o mesmo cenário sem o dono)" "1/true" "$(reading lixo.n)/$(reading lixo.lido)"
  xfresh; node_add "$GHOST" 14400; : > "$T/stub/bd.rig.ps.rc"; xone $LOWW >/dev/null; eq "a loja de UM rig ilegível (bd falha): não sei quem segura bead lá, então o lixo NÃO é lido" "false/donos-ilegivel:loja-ilegivel:ps:bd-falhou" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; node_add "$GHOST" 14400; echo 3 > "$T/stub/rig.rc"; xone $LOWW >/dev/null; eq "gc rig list que falha: não sei quais lojas existem, lixo NÃO lido" "false/donos-ilegivel:rigs-gc-falhou" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; node_add "$GHOST" 14400; printf '{"city_path":"x","ok":true,"rigs":[]}' > "$T/stub/rig.json"; xone $LOWW >/dev/null; eq "lista de rigs vazia (o próprio hq é um rig): leitura que falhou, não 'cidade sem rig'" "false/donos-ilegivel:rigs-forma-desconhecida" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; node_add "$GHOST" 14400; printf '{"ok":false,"rigs":[{"name":"wa","path":"x/rigs/wa"}]}' > "$T/stub/rig.json"; xone $LOWW >/dev/null; eq "envelope de erro do gc rig list (ok false): a lista que vier junto não vale" "false/donos-ilegivel:rigs-forma-desconhecida" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; node_add "$GHOST" 14400; printf 'isto nao e json' > "$T/stub/rig.json"; xone $LOWW >/dev/null; eq "gc rig list que não é JSON: ilegível" "false/donos-ilegivel:rigs-json-ilegivel" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; node_add "$GHOST" 14400; printf '{"ok":true,"rigs":[{"name":"wa"}]}' > "$T/stub/rig.json"; xone $LOWW >/dev/null; eq "rig sem caminho: não sei onde está a loja dele, lixo NÃO lido" "false/donos-ilegivel:rigs-forma-desconhecida" "$(reading lixo.lido)/$(reading lixo.motivo)"
  xfresh; node_add gate-reviewer-remote-young 600; xone $LOWW >/dev/null; check "sem candidata (parada há só 10 min) as lojas dos rigs nem são lidas" "$([ "$(cat "$T/stub/bd.calls" 2>/dev/null | grep -c 'rigs/')" = 0 ] && [ "$(cat "$T/stub/gc.calls" 2>/dev/null | grep -c 'rig list')" = 0 ] && [ "$(reading lixo.lido)" = true ] && echo 1 || echo 0)"

  # ---- o que não foi lido nunca vira causa: cego, sem degrau, sem ação -------------------------------------------------------------------------------------------------------
  local why
  for why in "cg:cgroup-ilegivel" "u:cgroup-ilegivel" "m l:sem-gerenciador-de-usuario"; do
    xfresh; X_OMIT="${why%%:*}"; xone $LOWW >/dev/null
    eq "sem '${why%%:*}' na leitura: núcleos não lidos (${why#*:}), a CPU segue lida e a causa é cego" "false/${why#*:}/cego" "$(reading nucleos.lido)/$(reading nucleos.motivo)/$(reading causa)"
  done
  xfresh; X_OMIT="m"; xone $LOWW >/dev/null; eq "sem o 'm 1' mas com o l lido: dá para ler (o lastro existe)" true "$(reading nucleos.lido)"
  xfresh; X_OMIT="l"; xone $LOWW >/dev/null; eq "sem o l com o gerenciador de pé, nas duas pontas: lastro 0 (nada do lastro rodou) e as sessões ficam com o user slice todo" "0.0/2.3" "$(reading nucleos.lastro)/$(reading nucleos.sessoes)"
  xfresh; xtick 900 $LOWW >/dev/null; X_OMIT="l"; xtick 900 $LOWW; eq "o l SUMIU entre as duas pontas: a fatia foi recriada, não sei o quanto rodou (não lido)" "false/lastro-sumiu/cego" "$(reading nucleos.lido)/$(reading nucleos.motivo)/$(reading causa)"
  xtick 900 $LOWW; eq "... e na leitura seguinte (ausente nas duas pontas) volta a ser lastro 0" "true/0.0" "$(reading nucleos.lido)/$(reading nucleos.lastro)"
  xfresh; X_OMIT="l"; xtick 900 $LOWW >/dev/null; X_OMIT=""; xtick 900 $LOWW; eq "fatia do lastro NASCIDA na janela conta desde zero" 0.6 "$(reading nucleos.lastro)"
  xfresh; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; XL=0; xtick 900 $LOWW; eq "contador do lastro que recuou: não lido (contador-recuou)" "false/contador-recuou" "$(reading nucleos.lido)/$(reading nucleos.motivo)"
  xfresh; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; XU=0; xtick 900 $LOWW; eq "contador do user slice que recuou: o mesmo" "false/contador-recuou" "$(reading nucleos.lido)/$(reading nucleos.motivo)"
  xfresh; xtick 900 $LOWW >/dev/null; XU=$((XU + 20000000000)); xtick 900 $LOWW; eq "o cgroup diz mais núcleos (22) do que o nó tem (16): implausível, não lido" "false/contador-implausivel/cego" "$(reading nucleos.lido)/$(reading nucleos.motivo)/$(reading causa)"
  xfresh; xtick 900 $LOWW >/dev/null; xtick 60 $LOWW; eq "janela de 60 s: curta demais, núcleos não lidos" "false/janela-curta" "$(reading nucleos.lido)/$(reading nucleos.motivo)"
  xfresh; xtick 900 $LOWW >/dev/null; xtick 2701 $LOWW; eq "janela de 2701 s (mais de 3 intervalos): a leitura anterior é velha demais" "false/leitura-anterior-velha" "$(reading nucleos.lido)/$(reading nucleos.motivo)"
  # o relógio que recuou e os contadores que não andaram: a leitura é a mesma de uma janela curta/estourada de longe (lido false), então só o MOTIVO e o baseline dizem qual guarda agiu
  xparado() {   # xparado <delta_s>: o relógio anda <delta_s> (pode ser negativo) e os contadores NÃO andam: a mesma leitura completa do nó, só com outra hora
    NOW=$((NOW + $1)); xwrite "$T/stat.txt"; STUB_SSH_FILE="$T/stat.txt"; printf '%s' "$NOW" > "$T/stub/node.now"
    [ "$PILOT_HQ" != none ] && pilot 60 1800 "$PILOT_HQ" "$PILOT_WA"
    focus_is "$FOCUS"
    W "${TENV[@]+"${TENV[@]}"}" -- ${XARGS---print}
  }
  xfresh; xtick 900 $LOWW >/dev/null; a0=$NOW; CB=$((CB + 1000)); CI=$((CI + 1000)); xparado -300
  eq "relógio do nó recuou (baseline no futuro): núcleos não lidos, com o motivo certo (não 'janela-curta')" "false/relogio-recuou" "$(reading nucleos.lido)/$(reading nucleos.motivo)"
  eq "... e o baseline dos núcleos é REPOSTO no relógio novo (a próxima janela já mede)" "$NOW" "$(state_f cpu_extra.epoch)"
  xfresh; xtick 900 $LOWW >/dev/null; a0=$NOW; xparado 900
  eq "contadores iguais nas duas pontas (nenhum tick na janela): núcleos não lidos, sem dividir por zero" "0/false/sem-tick" "$RC/$(reading nucleos.lido)/$(reading nucleos.motivo)"
  eq "... e o baseline dos núcleos fica onde estava (nada foi medido: não é trocado)" "$a0" "$(state_f cpu_extra.epoch)"
  xfresh; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; STUB_SSH_RC=1; xtick 900 $LOWW; eq "ssh que cai: CPU não lida, núcleos não lidos (sem-leitura-cpu) e a causa é cego" "false/false/sem-leitura-cpu/cego" "$(reading cpu.lido)/$(reading nucleos.lido)/$(reading nucleos.motivo)/$(reading causa)"
  eq "... e não vai ação nenhuma ao nó numa leitura cega" 0 "$(acts)"
  xfresh; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; STUB_SSH_RC=1; xtick 900 $LOWW >/dev/null; STUB_SSH_RC=0; xtick 900 $LOWW; eq "o baseline antigo sobrevive à ssh que caiu: a janela seguinte é de 1800 s (2 intervalos) e é lida" "true/1800" "$(reading nucleos.lido)/$(reading nucleos.janela_s)"
  xfresh; xone 200 30 50 0 >/dev/null; check "o JSONL tem os campos da causa (nucleos, ram_mb, lixo, memo_unknown, causa, degrau, acao, efeito)" "$(python3 -I -c 'import json,sys; d=json.loads(open(sys.argv[1]).read().splitlines()[-1]); print(int(all(k in d for k in ("nucleos","ram_mb","lixo","memo_unknown","causa","degrau","acao","efeito"))))' "$C/.gc/hetzner-occupancy.jsonl")"
}

# ============================================================================================================================================================================
g_escada() {
  echo "--- escada: configuração, chaves, um degrau por leitura, o que cada degrau faz no nó e o efeito medido na leitura seguinte (ga-2hd02v.5.10)"
  local dj kj MEMO R v bad_h a0
  xfresh; dj="$C/.gc/hetzner-occupancy-daily.json"; kj="$NODE/gt-remote/ballast/lastro-pedido.json"; MEMO="$C/.gc/wa-node-pass-memo.tsv"
  ghost3() { xfresh; if [ $# -eq 0 ]; then keys_on d1 d2 d3; else keys_on "$@"; fi; node_add "$GHOST" 14400 2700; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; }   # a semente e a 1ª janela baixa; a 3ª leitura (que o teste faz) é a 1ª com 30 min medidos
  verd() { echo "$(reading acao.0.ok)/$(reading acao.0.detalhe)/$(reading degrau.d1)/$(state_f degraus.d1.tentativas)/$(state_f pendentes)"; }
  memo_put() { printf '%s\t%s\t%s\t%s\n' "$@" >> "$MEMO"; }
  fixture_memo() { R=$((NOW + 2700)); : > "$MEMO"
    memo_put $((R-100)) wa-1 u1 unknown; memo_put $((R-50)) wa-1 u1 unknown; memo_put $((R-5000)) wa-2 u2 unknown; memo_put $((R-100)) wa-3 u3 mini
    memo_put $((R-900)) wa-4 u4 unknown; memo_put $((R-100)) wa-4 u4 mini; memo_put $((R-100)) wa-5 u5 unknown; memo_put $((R-100)) wa-5 u6 mini
    memo_put $((R-3599)) wa-6 u6 unknown; memo_put $((R-3600)) wa-7 u7 unknown; printf 'linha ruim sem tabs\n3 campos\ta\tb\n' >> "$MEMO"; }

  # ---- configuração em vigor ---------------------------------------------------------------------------------------------------------------------------------------------------
  W -- --print-config
  eq "padrão: lixo = parado há 30 min, no máximo 2 por leitura" "1800/2" "$(reading d1_idle_s)/$(reading d1_max)"; eq "padrão: 30 min entre ações, 2 tentativas por degrau" "1800/2" "$(reading act_cooldown_s)/$(reading act_tries)"
  eq "padrão: o D4 só depois de 6 h" 21600 "$(reading d4_after_s)"; eq "padrão: notify de novo a cada 1 h e 60 s de paciência" "3600/60" "$(reading notify_retry_s)/$(reading notify_timeout_s)"
  eq "padrão: pisos de RAM do lastro (partida 14336 MB, slot 1024 MB) e 2 núcleos livres" "14336/1024/2.0" "$(reading ram_start_mb)/$(reading ram_slot_mb)/$(reading min_free_cores)"
  eq "padrão: o dia precisa de 48 janelas lidas para ter número; a pasta do lastro; a memória dos vereditos 'unknown' dura 1 h" "48/~/gt-remote/ballast/3600" "$(reading day_min_windows)/$(reading ballast_home)/$(reading memo_unknown_ttl_s)"
  eq "sem nenhuma chave: nenhum degrau liga (INERTE por padrão)" '{"d1": false, "d2": false, "d3": false, "d4": false, "dia": false}' "$(reading on)"
  keys_on d1 dia; W -- --print-config; eq "a chave .on liga só o degrau dela" '{"d1": true, "d2": false, "d3": false, "d4": false, "dia": true}' "$(reading on)"
  W HETZNER_OCC_ACT=0 -- --print-config; eq "HETZNER_OCC_ACT=0 desliga TODAS as chaves de uma vez" '{"d1": false, "d2": false, "d3": false, "d4": false, "dia": false}' "$(reading on)"
  : > "$C/.gc/hetzner-occupancy-alarm.on"; W HETZNER_OCC_ACT=0 -- --print-config; eq "... mas não mexe na chave do aviso antigo (alarm)" true "$(reading alarm)"; rm -f "$C/.gc/hetzner-occupancy-alarm.on"
  for bad_h in 'HETZNER_OCC_D4_AFTER_S=30' 'HETZNER_OCC_D1_IDLE_S=30' 'HETZNER_OCC_D1_MAX=0' 'HETZNER_OCC_ACT_TRIES=0' 'HETZNER_OCC_NOTIFY_TIMEOUT_S=0' 'HETZNER_OCC_DAY_MIN_WINDOWS=0' 'HETZNER_OCC_MIN_FREE_CORES=0' 'HETZNER_OCC_BALLAST_HOME=/x;rm' 'HETZNER_OCC_BALLAST_HOME=../x' 'HETZNER_OCC_BALLAST_HOME=a b' "HETZNER_OCC_BALLAST_HOME=x'y"; do
    W "$bad_h" -- --print-config; check "$bad_h: recusado (rc != 0), nunca vira um comando no nó" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
  done
  W HETZNER_OCC_ACT_COOLDOWN_S=0 -- --print-config; eq "intervalo entre ações 0 é aceito" 0 "$(reading act_cooldown_s)"

  # ---- sem a chave nada age; antes de 30 min medidos nada é devido ---------------------------------------------------------------------------------------------------------------
  xfresh; node_add "$GHOST" 14400 2700; xdue $LOWW
  eq "sem NENHUMA chave: só mede (d1 e d2 aplicam mas estão desligados, d3 não tem o que fazer) e nada vai ao nó" "desligado/desligado/nao-aplica/0" "$(reading degrau.d1)/$(reading degrau.d2)/$(reading degrau.d3)/$(acts)"
  eq "... a causa está dita e a sessão segue de pé" "lixo/1" "$(reading causa)/$(node_has "$GHOST")"; eq "... e nenhuma tentativa foi gasta" "null/[]" "$(state_f degraus.d1.tentativas)/$(state_f pendentes)"
  xfresh; keys_on d1 d2 d3; node_add "$GHOST" 14400; xone $LOWW
  eq "com as chaves e a causa, mas só 15 min medidos: nada é devido (nem ação)" "nao-devido/nao-devido/nao-devido/0" "$(reading degrau.d1)/$(reading degrau.d2)/$(reading degrau.d3)/$(acts)"
  xfresh; keys_on d1 d2 d3; node_add "$GHOST" 14400 2700; TENV=(HETZNER_OCC_ACT=0); xdue $LOWW; eq "HETZNER_OCC_ACT=0 com as chaves postas: nada age" "desligado/0/1" "$(reading degrau.d1)/$(acts)/$(node_has "$GHOST")"

  # ---- leitura cega: a CPU baixa há 30 min, as 3 chaves postas e o lixo lá, mas o cgroup não veio: não sei a causa, então nada age -----------------------------------------------------
  xfresh; keys_on d1 d2 d3; node_add "$GHOST" 14400 2700; X_OMIT="cg"; xdue $LOWW
  eq "leitura cega (cgroup ilegível) com CPU baixa há 30 min: a causa é cego, NENHUM degrau age e a sessão-lixo segue de pé" "cego/cego/cego/cego/0/1" "$(reading causa)/$(reading degrau.d1)/$(reading degrau.d2)/$(reading degrau.d3)/$(acts)/$(node_has "$GHOST")"
  eq "... e nenhuma tentativa é gasta nem fica efeito pendente" "null/[]" "$(state_f degraus.d1.tentativas)/$(state_f pendentes)"

  # ---- D1: o caso real de 04/11 --------------------------------------------------------------------------------------------------------------------------------------------------
  ghost3; xtick 900 $LOWW
  eq "D1 com a chave e 30 min medidos: mata a sessão sem dono" "agiu/aguarda/nao-aplica" "$(reading degrau.d1)/$(reading degrau.d2)/$(reading degrau.d3)"
  eq "... UM degrau por leitura (o d2 espera a vez), uma chamada ao nó" "1" "$(acts)"; eq "... a ação diz o que fez e o veredito do nó" "true/matou 1 sessão(ões) sem dono: $GHOST/$GHOST=morta" "$(reading acao.0.ok)/$(reading acao.0.o_que)/$(reading acao.0.detalhe)"
  eq "... a sessão saiu do tmux do nó (de verdade, pelo script remoto)" "0/$GHOST" "$(node_has "$GHOST")/$(cat "$T/stub/node.killed")"
  has "o comando ao nó mata pelo nome exato" "kill-session -t \"=\$S\"" "$(cat "$T/stub/ssh.act")"; has "... e o nome vai no comando" "S=$GHOST;" "$(cat "$T/stub/ssh.act")"
  has "o ssh de ação também: BatchMode (nunca espera senha), ConnectTimeout e o host" "BatchMode=yes -o ConnectTimeout=10 hetzner-teste" "$(cat "$T/stub/ssh.act")"
  eq "a tentativa e o relógio da ação JÁ estavam gravados quando o ssh de ação rodou (processo que morre no meio não repete sem conta)" "1/$NOW" "$(jv "$T/stub/act.state" degraus.d1.tentativas)/$(jv "$T/stub/act.state" ultima_acao_em)"
  eq "o estado fica com a tentativa e o relógio" "1/$NOW" "$(state_f degraus.d1.tentativas)/$(state_f ultima_acao_em)"
  eq "... e a ação pendente de medir: o antes (CPU 17,5 %, 2,8 núcleos, lastro 0,3, 11,7 livres)" "d1/17.5/2.8/0.3/11.7" "$(state_f pendentes.0.degrau)/$(state_f pendentes.0.antes.pct)/$(state_f pendentes.0.antes.nucleos)/$(state_f pendentes.0.antes.lastro)/$(state_f pendentes.0.antes.livres)"
  eq "o diário conta a ação do dia" 1 "$(jv "$dj" dias.2026-10-19.acoes)"
  xtick 900 255 30 50 150
  eq "leitura seguinte, ainda no intervalo de 30 min: o d1 não tem mais lixo (fora) e o d2 espera o intervalo (cooldown)" "fora/cooldown/nao-aplica/0/1" "$(reading degrau.d1)/$(reading degrau.d2)/$(reading degrau.d3)/$(reading acao | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')/$(acts)"
  eq "... e o EFEITO da ação anterior, medido: de 2,8 para 3,35 núcleos = +0,55" "d1/2.8/3.35/0.55" "$(reading efeito.0.degrau)/$(reading efeito.0.nucleos_antes)/$(reading efeito.0.nucleos_depois)/$(reading efeito.0.ganho_nucleos)"
  eq "... a CPU antes e depois, e o lastro e os livres antes e depois" "17.5/20.9/0.3/0.3/11.7/11.15" "$(reading efeito.0.pct_antes)/$(reading efeito.0.pct_depois)/$(reading efeito.0.lastro_antes)/$(reading efeito.0.lastro_depois)/$(reading efeito.0.livres_antes)/$(reading efeito.0.livres_depois)"
  eq "... guardado no degrau (o aviso do D4 o cita) e a pendência some" "0.55/[]" "$(state_f degraus.d1.ganho_nucleos)/$(state_f pendentes)"
  xtick 900 255 30 50 150
  eq "30 min depois da ação o intervalo acabou: sem lixo, a causa é o lastro e o D2 pede mais slots" "lastro-sem-trabalho/agiu/2" "$(reading causa)/$(reading degrau.d2)/$(acts)"
  eq "... o pedido de lastro: v1, +4 slots (livres 11, RAM comporta 5, teto 4), de quem, com a RAM" "1/4/hetzner-occupancy-watch/20000" "$(jv "$kj" v)/$(jv "$kj" slots_extra)/$(jv "$kj" quem)/$(jv "$kj" ram_mb)"
  eq "... vale por 2 leituras (ate = epoch + 1800) e o epoch é o da ação" "1800/$NOW" "$(( $(jv "$kj" ate) - $(jv "$kj" epoch) ))/$(jv "$kj" epoch)"
  eq "... e a pasta do lastro só tem o pedido (o tmp foi movido, não ficou)" "lastro-pedido.json" "$(ls -A "$NODE/gt-remote/ballast")"
  eq "... a ação diz o que pediu" "true/pediu +4 slot(s) de lastro/gravado" "$(reading acao.0.ok)/$(reading acao.0.o_que)/$(reading acao.0.detalhe)"
  xtick 900 255 30 50 150; eq "o efeito do D2 também é medido na leitura seguinte (aqui a CPU não mudou: ganho 0)" "d2/0.0" "$(reading efeito.0.degrau)/$(reading efeito.0.ganho_nucleos)"
  check "NUNCA liga a queima: nenhum comando ao nó cita burn e nenhum arquivo burn* nasce na cidade nem no nó" "$([ "$(cat "$T/stub/ssh.act" "$T/stub/ssh.calls" | grep -ci burn)" = 0 ] && [ -z "$(find "$C" "$NODE" -iname '*burn*')" ] && echo 1 || echo 0)"
  eq "o diário: 2 ações no dia (d1 e d2)" 2 "$(jv "$dj" dias.2026-10-19.acoes)"

  # ---- D1: só o que a cidade não conhece e ninguém segura; o nó re-confere na hora de matar --------------------------------------------------------------------------------------------
  ghost3; node_add dog-remote-gapxi4ls 20000 2700; sessions_are "$SJ_REMOTE"; xtick 900 $LOWW
  eq "uma sessão que a cidade conhece e segura bead, parada há 5 h, NÃO morre; só o lixo morre" "$GHOST/1" "$(cat "$T/stub/node.killed")/$(node_has dog-remote-gapxi4ls)"
  ghost3; node_add gate-reviewer-remote-b 20000 2700; node_add gate-reviewer-remote-c 9000 2700; xtick 900 $LOWW
  eq "3 sem dono e d1_max=2: matou as 2 mais quietas, a mais nova fica" "2/gate-reviewer-remote-b $GHOST/1" "$(wc -l < "$T/stub/node.killed" | tr -d ' ')/$(tr '\n' ' ' < "$T/stub/node.killed" | sed 's/ $//')/$(node_has gate-reviewer-remote-c)"
  eq "... a ação lista as 2 e o veredito de cada" "matou 2 sessão(ões) sem dono: gate-reviewer-remote-b, $GHOST/gate-reviewer-remote-b=morta, $GHOST=morta" "$(reading acao.0.o_que)/$(reading acao.0.detalhe)"
  ghost3; node_add gate-reviewer-remote-b 20000 2700; TENV=(HETZNER_OCC_D1_MAX=1); xtick 900 $LOWW; eq "D1_MAX=1: só a mais quieta" "1/gate-reviewer-remote-b" "$(wc -l < "$T/stub/node.killed" | tr -d ' ')/$(cat "$T/stub/node.killed")"
  ghost3; after_read ': > "$STUB_DIR/node.tmux"'; xtick 900 $LOWW
  eq "a sessão SUMIU entre a leitura e a ação: o nó diz 'ausente', nada é morto, a tentativa gasta a vez e não há efeito a medir" "false/$GHOST=ausente/falhou/1/[]" "$(verd)"
  ghost3; after_read 'n=$(cat "$STUB_DIR/node.now"); printf "%s|%s|%s\n" '"$GHOST"' "$n" "$n" > "$STUB_DIR/node.tmux"'; xtick 900 $LOWW
  eq "a sessão VOLTOU a trabalhar entre a leitura e a ação: o nó diz 'ativa' e ela não morre" "false/$GHOST=ativa/falhou/1/[]/1" "$(verd)/$(node_has "$GHOST")"
  ghost3; after_read 'n=$(cat "$STUB_DIR/node.now"); printf "%s|1|%s\n" '"$GHOST"' "$n" > "$STUB_DIR/node.tmux"'; xtick 900 $LOWW
  eq "a SAÍDA voltou entre a leitura e a ação (input parado, window_activity de agora): o nó diz 'ativa' e ela não morre" "false/$GHOST=ativa/falhou/1/[]/1" "$(verd)/$(node_has "$GHOST")"
  ghost3; after_read 'n=$(cat "$STUB_DIR/node.now"); printf "%s|1|1\n%s|1|%s\n" '"$GHOST $GHOST"' "$n" > "$STUB_DIR/node.tmux"'; xtick 900 $LOWW
  eq "duas janelas no nó, só a 2ª mexeu: vale a mais recente de todas e a sessão não morre" "false/$GHOST=ativa/falhou/1/[]/1" "$(verd)/$(node_has "$GHOST")"
  xfresh; X_OMIT="tmux"; xone $LOWW >/dev/null; eq "seção do tmux ausente (a ssh cortou): ilegível, não vazia" "false/tmux-ilegivel:sem-secao" "$(reading lixo.lido)/$(reading lixo.motivo)"
  ghost3; STUB_TMUX_ACT_BAD=2; xtick 900 $LOWW; eq "atividade que vem só em branco: 'ilegivel' (nunca uma conta com número vazio), não mata" "false/$GHOST=ilegivel/falhou/1/[]/1" "$(verd)/$(node_has "$GHOST")"
  ghost3; STUB_TMUX_KILL_FAIL=1; xtick 900 $LOWW; eq "o tmux recusa o kill: 'falhou'" "false/$GHOST=falhou/falhou/1/[]" "$(verd)"
  ghost3; STUB_ACT_RC=255; xtick 900 $LOWW; eq "ssh de ação que cai (rc 255): 'rc-255' e não há sucesso" "false/$GHOST=rc-255/falhou/1/[]" "$(verd)"
  ghost3; STUB_ACT_SLEEP=8; TENV=(HETZNER_OCC_SSH_TIMEOUT_S=3); xtick 900 $LOWW; eq "ssh de ação que trava além do prazo: 'timeout'" "false/$GHOST=timeout/falhou/1/[]" "$(verd)"
  ghost3; STUB_ACT_OUT=" "; xtick 900 $LOWW; eq "ssh de ação sem palavra nenhuma na saída: 'sem-saida', nunca sucesso" "false/$GHOST=sem-saida/falhou/1/[]" "$(verd)"
  ghost3; STUB_ACT_OUT="morta falhou"; xtick 900 $LOWW; eq "vale a ÚLTIMA palavra do veredito" "false/$GHOST=falhou/falhou/1/[]" "$(verd)"
  ghost3; STUB_ACT_OUT="morta"; xtick 900 $LOWW; eq "só 'morta' com rc 0 é sucesso (e então há efeito a medir)" "true/$GHOST=morta/agiu/1/1" "$(reading acao.0.ok)/$(reading acao.0.detalhe)/$(reading degrau.d1)/$(state_f degraus.d1.tentativas)/$(state_f pendentes | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  a0=$(acts)
  python3 -I - "$WATCH" <<'PY' > "$T/unit.out" 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hoc_watch", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c = m.load_config({"GC_CITY_PATH": "/nonexistent", "HOME": "/nonexistent"})
for name in ("worker-1", "a b-remote-x", "x;touch-remote-y", "-remote-$(id)", "", "gateremote-x"):
    print(name, m.kill_idle_session(c, name))
PY
  eq "a função que mata recusa nome sem -remote- ou com caractere de shell, sem chamar o ssh" "worker-1 (False, 'nome-recusado')|a b-remote-x (False, 'nome-recusado')|x;touch-remote-y (False, 'nome-recusado')|-remote-\$(id) (False, 'nome-recusado')| (False, 'nome-recusado')|gateremote-x (False, 'nome-recusado')" "$(tr '\n' '|' < "$T/unit.out" | sed 's/|$//')"
  eq "... (o ssh de verdade nem foi chamado)" "$a0" "$(acts)"

  # ---- tentativas, intervalo e a escada que desce ----------------------------------------------------------------------------------------------------------------------------------
  # a data da última ação no FUTURO (relógio que recuou, estado editado à mão) esfria como uma ação recente: sob dúvida o degrau não age (gate-fix 1, ga-2hd02v.5.10)
  ghost3; TENV=(HETZNER_OCC_ACT_COOLDOWN_S=600); xtick 900 $LOWW >/dev/null; xtick 900 255 30 50 150
  eq "(controle) 15 min depois da ação, com o intervalo de 10 min já cumprido: o d2 age (2 chamadas ao nó no total)" "agiu/2" "$(reading degrau.d2)/$(acts)"
  ghost3; TENV=(HETZNER_OCC_ACT_COOLDOWN_S=600); xtick 900 $LOWW >/dev/null; state_set "ultima_acao_em=$((NOW + 7200))"; xtick 900 255 30 50 150
  eq "a mesma leitura com a data da última ação 2 h no FUTURO: o d2 espera ('cooldown') e nada novo vai ao nó" "cooldown/1" "$(reading degrau.d2)/$(acts)"
  ghost3; STUB_TMUX_KILL_FAIL=1; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW; eq "ação que falhou: o intervalo de 30 min vale mesmo assim (d1 e d2 em cooldown)" "cooldown/cooldown/1" "$(reading degrau.d1)/$(reading degrau.d2)/$(acts)"
  xtick 900 $LOWW; eq "30 min depois: a 2ª tentativa do d1 (também falha)" "falhou/2" "$(reading degrau.d1)/$(state_f degraus.d1.tentativas)"
  xtick 900 $LOWW >/dev/null; xtick 900 $LOWW; eq "tentativas gastas: o d1 está esgotado e a escada DESCE para o d2, que age" "esgotado/agiu/3" "$(reading degrau.d1)/$(reading degrau.d2)/$(acts)"
  xfresh; keys_on d2; TENV=(HETZNER_OCC_ACT_COOLDOWN_S=0); xdue $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW
  eq "sem intervalo e com a chave só do d2: tentativa 1, 2 e então 'esgotado'" "fora/esgotado/nao-aplica/2" "$(reading degrau.d1)/$(reading degrau.d2)/$(reading degrau.d3)/$(state_f degraus.d2.tentativas)"
  eq "... d4 ainda não é devido (a sequência tem 45 min, não 6 h)" nao "$(reading d4)"
  xtick 900 1400 30 50 0; eq "a CPU volta à meta: a sequência acaba e as tentativas zeram (estado limpo)" "null/0/{}" "$(reading causa)/$(state_f baixas_seguidas)/$(state_f degraus)"
  xtick 900 $LOWW >/dev/null; xtick 900 $LOWW; eq "nova sequência baixa de 30 min: o d2 tem tentativas de novo" "agiu/1" "$(reading degrau.d2)/$(state_f degraus.d2.tentativas)"
  ghost3 d1; xtick 900 $LOWW; STUB_SSH_RC=1; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null
  eq "CPU não lida logo depois da ação: a pendência espera (leituras 2)" "d1/2" "$(state_f pendentes.0.degrau)/$(state_f pendentes.0.leituras)"
  xtick 900 $LOWW; eq "na 3ª leitura sem CPU o efeito vira 'cpu-nao-lida' (dito, nunca inventado) e a pendência some" "d1/cpu-nao-lida/[]" "$(reading efeito.0.degrau)/$(reading efeito.0.motivo)/$(state_f pendentes)"
  ghost3 d1; XARGS="--print --dry-run" xtick 900 $LOWW; eq "--dry-run: diz 'agiria' e NÃO age, não grava estado nem JSONL" "agiria/0/1/null/2" "$(reading degrau.d1)/$(acts)/$(node_has "$GHOST")/$(state_f ultima_acao_em)/$(wc -l < "$C/.gc/hetzner-occupancy.jsonl" | tr -d ' ')"

  # ---- D2: o pedido de lastro e os pisos de RAM ------------------------------------------------------------------------------------------------------------------------------------
  xfresh; keys_on d2; X_RAM_MB=16500; xdue $LOWW >/dev/null; eq "RAM 16500 MB (2 slots acima do piso de 14336): pede +2" 2 "$(jv "$kj" slots_extra)"
  xfresh; keys_on d2; X_RAM_MB=15360; xdue $LOWW >/dev/null; eq "RAM 15360 MB: pede +1" 1 "$(jv "$kj" slots_extra)"
  xfresh; keys_on d2; xdue 1000 30 50 300 >/dev/null; eq "só 2,2 núcleos livres: pede +2 (a parte inteira dos livres)" "2.2/2" "$(reading nucleos.livres)/$(jv "$kj" slots_extra)"
  xfresh; keys_on d1 d2 d3; X_RAM_MB=15000; xdue $LOWW; eq "RAM abaixo do piso de partida + 1 slot: a causa é RAM, NENHUM degrau age (nada cabe; a pasta do lastro segue vazia)" "RAM/ram/ram/ram/0/0" "$(reading causa)/$(reading degrau.d1)/$(reading degrau.d2)/$(reading degrau.d3)/$(acts)/$(ls -A "$NODE/gt-remote/ballast" | wc -l | tr -d ' ')"
  xfresh; keys_on d2; rm -rf "$NODE/gt-remote"; xdue $LOWW; eq "sem a pasta do lastro no nó: 'sem-lastro', não cria nada e a tentativa gasta a vez" "false/sem-lastro/falhou/0" "$(reading acao.0.ok)/$(reading acao.0.detalhe)/$(reading degrau.d2)/$([ -e "$NODE/gt-remote" ] && echo 1 || echo 0)"
  xfresh; keys_on d2; mkdir -p "$NODE/gt-remote/outro"; TENV=(HETZNER_OCC_BALLAST_HOME='~/gt-remote/outro'); xdue $LOWW >/dev/null; eq "a pasta do lastro é configurável" "1/0" "$([ -f "$NODE/gt-remote/outro/lastro-pedido.json" ] && echo 1 || echo 0)/$([ -e "$kj" ] && echo 1 || echo 0)"
  xfresh; keys_on d2; STUB_ACT_RC=1; xdue $LOWW; eq "ssh que falha no D2: não é sucesso e não há efeito a medir" "false/rc-1/falhou/[]" "$(reading acao.0.ok)/$(reading acao.0.detalhe)/$(reading degrau.d2)/$(state_f pendentes)"

  # ---- D3: a memória de vereditos 'unknown' do Pilot ------------------------------------------------------------------------------------------------------------------------------
  xfresh; keys_on d3; PILOT_HQ=0; fixture_memo; xdue 600 30 50 800
  eq "sem núcleo sobrando e fila vazia: a causa é a fila e o D3 age (d1 e d2 ficam fora)" "fila-sem-elegível/fora/fora/agiu" "$(reading causa)/$(reading degrau.d1)/$(reading degrau.d2)/$(reading degrau.d3)"
  eq "a leitura conta as beads 'unknown' frescas (a última linha da bead vale; vencida não conta)" 3 "$(reading memo_unknown)"
  has "o D3 diz quantas tirou" "tirou 3 bead(s)" "$(reading acao.0.o_que)"
  printf '%s\t%s\t%s\t%s\n' $((R-5000)) wa-2 u2 unknown $((R-100)) wa-3 u3 mini $((R-900)) wa-4 u4 unknown $((R-100)) wa-4 u4 mini $((R-100)) wa-5 u6 mini $((R-3600)) wa-7 u7 unknown > "$T/memo.expect"; printf 'linha ruim sem tabs\n3 campos\ta\tb\n' >> "$T/memo.expect"
  check "a memória fica SÓ sem as 3 beads 'unknown' frescas (todas as linhas delas); as vencidas, as de outro veredito e as linhas que não são de 4 campos ficam, na ordem" "$(cmp -s "$MEMO" "$T/memo.expect" && echo 1 || echo 0)"
  eq "... e não sobra tmp ao lado" "wa-node-pass-memo.tsv" "$(ls -A "$C/.gc" | grep memo | tr '\n' ' ' | sed 's/ $//')"
  xfresh; keys_on d3; PILOT_HQ=0; fixture_memo; cp "$MEMO" "$T/memo.before"; XARGS="--print --dry-run" xdue 600 30 50 800 >/dev/null; check "--dry-run: a memória do Pilot NÃO é tocada" "$(cmp -s "$MEMO" "$T/memo.before" && echo 1 || echo 0)"
  xfresh; keys_on d3; PILOT_HQ=0; xdue 600 30 50 800; eq "memória ausente = vazia (lida): d3 não tem o que fazer e o vigia não cria o arquivo" "0/nao-aplica/0" "$(reading memo_unknown)/$(reading degrau.d3)/$([ -e "$MEMO" ] && echo 1 || echo 0)"
  xfresh; keys_on d3; PILOT_HQ=0; mkdir -p "$MEMO"; xdue 600 30 50 800; eq "memória que não abre: NÃO lida (null) e o d3 diz 'cego', nunca 'nada a fazer'" "null/cego/0" "$(reading memo_unknown)/$(reading degrau.d3)/$(acts)"
  xfresh; keys_on d3; PILOT_HQ=0; W HETZNER_OCC_WA_MEMO="$T/outra-memoria.tsv" -- --print-config; eq "o caminho da memória é configurável" "$T/outra-memoria.tsv" "$(reading wa_memo)"
  xfresh; keys_on d2 d3; fixture_memo; TENV=(HETZNER_OCC_ACT_TRIES=1 HETZNER_OCC_ACT_COOLDOWN_S=0); xdue $LOWW >/dev/null; xtick 900 $LOWW
  eq "causa lastro: o d2 gasta a única tentativa e a escada desce ao d3 (que tira as 'unknown'; 15 min depois a de 3599 s já venceu, sobram 2)" "esgotado/agiu/tirou 2 bead(s)" "$(reading degrau.d2)/$(reading degrau.d3)/$(reading acao.0.o_que | sed 's/ `unknown`.*//')"
  eq "... e o D3 mediu o efeito do D2 na mesma leitura" d2 "$(reading efeito.0.degrau)"

  # ---- o aviso antigo e a escada convivem: o mail de CPU baixa leva os números e a causa -------------------------------------------------------------------------------------------------
  ghost3; : > "$C/.gc/hetzner-occupancy-alarm.on"; xtick 900 $LOWW
  eq "com o aviso antigo ligado: o mail de CPU baixa sai UMA vez e a escada age na mesma leitura" "1/agiu" "$(mails)/$(reading degrau.d1)"
  has "o mail diz de onde vem o número (as partes e a causa)" "de onde vem o número (núcleos médios na janela): sessões 2.0 · lastro 0.3 · sistema 0.5 · espera de disco 1.5 · livres 11.7 · causa: lixo" "$(mailfield 1 body)"
  has "... e o fecho do mail não diz que o vigia só mede" "só nos degraus cuja chave .on existe, age" "$(mailfield 1 body)"
}

# ============================================================================================================================================================================
g_aviso() {
  echo "--- aviso: o D4 (esgotou) avisa o Athos no máximo 1x por dia, com a bead da causa; o rc do notify vale; o número do dia (ga-2hd02v.5.10)"
  local dj rc_ok rc_bad
  dj() { echo "$C/.gc/hetzner-occupancy-daily.json"; }
  xrun() { local n=$1; shift; while [ "$n" -gt 1 ]; do xtick 900 "$@" >/dev/null; n=$((n-1)); done; xtick 900 "$@"; }   # xrun <n> <4 partes>: n leituras de 15 min; a última fica em $WOUT (a semente conta como a 1ª)
  # a sequência baixa precisa ter 6 h para o D4; com HETZNER_OCC_D4_AFTER_S=3600 são a semente + 4 janelas (a 5ª leitura: 3600 s medidos, 3480 s bastam)
  d4_setup() { xfresh; keys_on d2 d4; TENV=(HETZNER_OCC_D4_AFTER_S=3600 HETZNER_OCC_ACT_TRIES=1 HETZNER_OCC_ACT_COOLDOWN_S=0); }   # causa lastro: o d2 gasta a única tentativa e a escada esgota

  # ---- o D4: só com a chave, a sequência de 6 h e a escada esgotada ------------------------------------------------------------------------------------------------------------------
  d4_setup; xrun 4 $LOWW
  eq "a 4ª leitura (2700 s medidos): o D4 ainda não é devido (a escada já esgotou, falta o tempo)" "nao/esgotado/0/0" "$(reading d4)/$(reading degrau.d2)/$(notifies)/$(creates)"
  xtick 900 $LOWW
  eq "a 5ª (3600 s, o d4_after_s): avisa o Athos UMA vez e cria UMA bead" "enviado:entregue/1/1" "$(reading d4)/$(notifies)/$(creates)"
  eq "... a bead da causa vai no JSONL e no estado" "ga-d4test/ga-d4test" "$(reading d4_bead)/$(state_f d4_bead)"
  eq "... o notify roda com os 2 sinais certos (rc por desfecho e push forçado)" "1/1" "$(cut -d/ -f1 "$T/stub/notify.1.env")/$(cut -d/ -f2 "$T/stub/notify.1.env")"
  has "... o título é de produto: quanto, há quanto tempo e que o vigia esgotou" "Hetzner abaixo de 85% há 1 h: esgotei o que o vigia faz sozinho" "$(cat "$T/stub/notify.1.title")"
  has "... o texto diz quanto (17.5 % de CPU), a causa em português e os números de hoje" "CPU média em 17.5% há 1 h (meta 85%). Causa: sobram núcleos livres e o lastro não os usa. Hoje: 2.0 núcleos em sessões, 0.3 no lastro, 0.5 de sistema, 1.5 esperando disco, 11.7 livres." "$(cat "$T/stub/notify.1.text")"
  has "... diz o que tentou, com o ganho medido (o D2 não mexeu na CPU: +0.00)" "Tentei: pedir mais lastro 1x (ganho medido: +0.00 núcleo). Nada mais que o vigia possa fazer sozinho." "$(cat "$T/stub/notify.1.text")"
  has "... e a bead onde a causa fica registrada" "Bead: ga-d4test." "$(cat "$T/stub/notify.1.text")"
  eq "a bead leva o MESMO texto do aviso (sem a linha da bead) e o título" "$(cat "$T/stub/notify.1.title")" "$(cat "$T/stub/create.1.title")"
  has "... e a descrição da bead tem a causa" "Causa: sobram núcleos livres e o lastro não os usa." "$(cat "$T/stub/create.1.desc")"
  hasnt "... sem ids, caminhos de código nem jargão do vigia no texto ao Athos" "degrau" "$(cat "$T/stub/notify.1.text")"
  check "a bead nasce SEM story:approved nem exec:auto (nada a despacha sozinho; só registra)" "$(grep -q 'story:approved\|exec:auto' "$T/stub/bd.calls" && echo 0 || echo 1)"
  eq "o estado marca o dia do aviso (hoje) e não há falha pendente" "2026-10-19/null" "$(state_f d4_dia)/$(state_f d4_falha_em)"
  xtick 900 $LOWW; eq "a leitura seguinte, no mesmo dia: 'ja-avisou' (no máximo 1 por dia), nada novo sai" "ja-avisou/1/1" "$(reading d4)/$(notifies)/$(creates)"
  xrun 20 $LOWW; eq "... nem 5 h depois, no mesmo dia (e a bead é a mesma, não nasce outra)" "ja-avisou/1/1/ga-d4test" "$(reading d4)/$(notifies)/$(creates)/$(state_f d4_bead)"
  xtick 900 1400 30 50 0; eq "a CPU volta à meta: a sequência acaba e a bead guardada é esquecida (a próxima sequência abre outra)" "null/null" "$(state_f d4_bead)/$(reading causa)"
  # a virada do dia: começa às 22 h, o aviso sai às 23 h15 e a 1ª leitura depois da meia-noite avisa de novo, com a MESMA bead
  d4_setup; xfresh $((NOW0 + 36000)); keys_on d2 d4; TENV=(HETZNER_OCC_D4_AFTER_S=3600 HETZNER_OCC_ACT_TRIES=1 HETZNER_OCC_ACT_COOLDOWN_S=0); xrun 5 $LOWW
  eq "às 23 h15 de 19/10: o aviso do dia sai" "enviado:entregue/2026-10-19/1" "$(reading d4)/$(state_f d4_dia)/$(notifies)"
  xtick 900 $LOWW >/dev/null; xtick 900 $LOWW; eq "23 h30 e 23 h45 (ainda 19/10): nada novo" "ja-avisou/1" "$(reading d4)/$(notifies)"
  xtick 900 $LOWW; eq "00 h00 de 20/10: dia novo, escada esgotada e sequência de pé: avisa de novo (1 por dia), com a mesma bead, sem criar outra" "enviado:entregue/2026-10-20/2/1/ga-d4test" "$(reading d4)/$(state_f d4_dia)/$(notifies)/$(creates)/$(state_f d4_bead)"
  has "... e o texto do 2º dia cita a mesma bead" "Bead: ga-d4test." "$(cat "$T/stub/notify.2.text")"

  # ---- as portas do D4 ------------------------------------------------------------------------------------------------------------------------------------------------------------
  d4_setup; rm -f "$C/.gc/hetzner-occupancy-d4.on"; keys_on d2; xrun 5 $LOWW; eq "sem a chave do d4: só mede ('desligado'), nada sai e nenhuma bead nasce" "desligado/0/0" "$(reading d4)/$(notifies)/$(creates)"
  d4_setup; TENV+=(HETZNER_OCC_ACT=0); xrun 5 $LOWW; eq "HETZNER_OCC_ACT=0: os degraus ficam desligados (não esgotam: ninguém autorizou), o D4 nem é devido e nada sai" "nao/0/0" "$(reading d4)/$(notifies)/$(creates)"
  d4_setup; keys_on d4; rm -f "$C/.gc/hetzner-occupancy-d2.on"; xrun 5 $LOWW; eq "escada NÃO esgotada (o d2 aplica mas a chave dele está desligada: ninguém autorizou a tentar): o D4 não avisa" "desligado/nao/0/0" "$(reading degrau.d2)/$(reading d4)/$(notifies)/$(creates)"
  d4_setup; TENV+=(HETZNER_OCC_ACT_TRIES=3); xrun 5 $LOWW; eq "tentativa sobrando no d2 (3, gastou 3 só no 7º tick): não esgotou, não avisa" "nao/0/0" "$(reading d4)/$(notifies)/$(creates)"
  d4_setup; X_RAM_MB=15000; xrun 5 $LOWW; eq "causa RAM: nada cabe, a escada está esgotada de saída; o D4 avisa e diz que não tentou nada (a causa não tem degrau)" "enviado:entregue/1" "$(reading d4)/$(notifies)"
  has "... com a causa em português e 'nada' no que tentou" "Causa: pouca memória livre no nó: não cabe mais lastro." "$(cat "$T/stub/notify.1.text")"; has "... e que não tentou nada" "Tentei: nada (a causa não tem degrau que caiba)." "$(cat "$T/stub/notify.1.text")"
  # lixo NÃO lido nunca esgota a escada, qualquer que seja a causa: o D1 é o 1º degrau e o que libera RAM (gate-fix 1, ga-2hd02v.5.10)
  d4_setup; X_RAM_MB=15000; X_TMUX=falha; xrun 5 $LOWW
  eq "causa RAM com o LIXO ilegível (tmux falhou): não sei se o D1 tinha o que fazer, então a escada NÃO esgotou: o D4 não avisa nem cria bead, e o D1 aparece 'cego' (d2 e d3: 'ram')" "RAM/false/cego/ram/ram/nao/0/0" "$(reading causa)/$(reading lixo.lido)/$(reading degrau.d1)/$(reading degrau.d2)/$(reading degrau.d3)/$(reading d4)/$(notifies)/$(creates)"
  X_TMUX=lista; xtick 900 $LOWW; eq "... o tmux volta a ler (sem lixo): o D1 deixa de ser cego, a escada esgota e o D4 avisa (o lixo ilegível era o único que segurava)" "RAM/true/ram/enviado:entregue/1" "$(reading causa)/$(reading lixo.lido)/$(reading degrau.d1)/$(reading d4)/$(notifies)"
  d4_setup; X_RAM_MB=15000; X_OMIT="now"; xrun 5 $LOWW; eq "RAM com o relógio do nó ilegível (outro motivo de lixo não lido): idem, não esgota" "false/cego/nao/0" "$(reading lixo.lido)/$(reading degrau.d1)/$(reading d4)/$(notifies)"
  d4_setup; X_TMUX=falha; xrun 5 $LOWW
  eq "mesma classe, outra causa (lastro-sem-trabalho, o d2 gastou a tentativa) com o LIXO ilegível: a causa começa depois do D1, mas sem ler o lixo o D1 não está 'fora', está 'cego', e a escada NÃO esgota: sem aviso, sem bead" "lastro-sem-trabalho/false/cego/esgotado/nao/0/0" "$(reading causa)/$(reading lixo.lido)/$(reading degrau.d1)/$(reading degrau.d2)/$(reading d4)/$(notifies)/$(creates)"
  d4_setup; xrun 5 $LOWW >/dev/null; eq "(controle) o mesmo cenário com o lixo LIDO: o D1 é 'fora' (a causa começa no d2) e o D4 avisou" "fora/enviado:entregue" "$(reading degrau.d1)/$(reading d4)"
  d4_setup; X_OMIT="mem"; xrun 5 $LOWW; eq "RAM não lida com núcleo sobrando: a causa é cego, a escada nunca esgota e o D4 NÃO avisa (o cego não vira 'esgotei')" "cego/nao/0/0" "$(reading causa)/$(reading d4)/$(notifies)/$(creates)"
  d4_setup; xrun 4 $LOWW >/dev/null; STUB_SSH_RC=1; xtick 900 $LOWW; eq "CPU não lida na hora do aviso: não há sequência baixa lida, o D4 não é devido" "nao/0" "$(reading d4)/$(notifies)"
  d4_setup; xrun 4 $LOWW >/dev/null; cp "$C/.gc/hetzner-occupancy.state.json" "$T/state.before"; XARGS="--print --dry-run" xtick 900 $LOWW; eq "--dry-run: diz 'enviaria', não manda, não cria bead e não grava o estado" "enviaria/0/0/1" "$(reading d4)/$(notifies)/$(creates)/$(cmp -s "$C/.gc/hetzner-occupancy.state.json" "$T/state.before" && echo 1 || echo 0)"
  d4_setup; xrun 5 $LOWW; eq "(controle) o mesmo cenário, sem nenhuma das portas fechadas, avisa" "enviado:entregue" "$(reading d4)"

  # ---- o rc do notify: só 0, 10 e 11 são entregue; o resto NÃO saiu (04/11, ga-i4t0lzx: exit 12 e o Athos não soube) ------------------------------------------------------------
  for rc_ok in "0 entregue" "10 segurado-ate-7h" "11 ja-tinha-saido"; do
    d4_setup; STUB_NOTIFY_RC=${rc_ok%% *}; xrun 5 $LOWW; eq "notify rc ${rc_ok%% *}: conta como entregue (${rc_ok#* }), sem mail de reserva e sem tentar de novo" "enviado:${rc_ok#* }/1/0/null" "$(reading d4)/$(notifies)/$(mails)/$(state_f d4_falha_em)"
  done
  for rc_bad in 12 13 14 1 2 99 255; do
    d4_setup; STUB_NOTIFY_RC=$rc_bad; xrun 5 $LOWW
    eq "notify rc $rc_bad: NÃO saiu: o vigia diz 'falhou' (nunca 'enviado'), manda o mesmo texto UMA vez por mail ao Mayor e anota a hora da falha" "falhou:rc-$rc_bad/enviado/1/1/$NOW" "$(reading d4)/$(reading d4_mail)/$(notifies)/$(mails)/$(state_f d4_falha_em)"
    eq "... o aviso do dia NÃO é dado como feito (volta para tentar de novo)" "null" "$(state_f d4_dia)"
  done
  d4_setup; STUB_NOTIFY_RC=12; xrun 5 $LOWW; has "o mail de reserva leva o mesmo título, o mesmo texto e diz que o notify não saiu e quando tenta de novo" "O notify ao Athos não saiu: rc-12. Mando o mesmo texto aqui e tento o notify de novo em 60 min." "$(mailfield 1 body)"
  eq "... e o assunto do mail é o título do aviso" "$(cat "$T/stub/notify.1.title")" "$(mailfield 1 subj)"
  has "... com o texto do aviso inteiro" "$(cat "$T/stub/notify.1.text")" "$(mailfield 1 body)"
  xtick 900 $LOWW; eq "15 min depois: 'espera-retry' (o notify de novo só depois de 1 h), nada sai, o mail não se repete" "espera-retry/1/1" "$(reading d4)/$(notifies)/$(mails)"
  xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; STUB_NOTIFY_RC=12; xtick 900 $LOWW
  eq "1 h depois do aviso que falhou: tenta o notify de novo (falha de novo: 'falhou', mas SEM mail repetido — a reserva sai uma vez só)" "falhou:rc-12/2/1" "$(reading d4)/$(notifies)/$(mails)"
  eq "... e a bead continua a mesma (o retry não cria outra)" "1/ga-d4test" "$(creates)/$(state_f d4_bead)"
  STUB_NOTIFY_RC=0; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW
  eq "1 h depois, o notify volta a funcionar: 'enviado', o aviso do dia fica feito e a falha é limpa" "enviado:entregue/3/2026-10-19/null" "$(reading d4)/$(notifies)/$(state_f d4_dia)/$(state_f d4_falha_em)"
  xtick 900 $LOWW; eq "... e não repete no mesmo dia" "ja-avisou/3" "$(reading d4)/$(notifies)"
  d4_setup; STUB_NOTIFY_SLEEP=8; TENV+=(HETZNER_OCC_NOTIFY_TIMEOUT_S=2); xrun 5 $LOWW; eq "notify que trava (além do notify_timeout_s): 'timeout' = NÃO saiu, com o mail de reserva" "falhou:timeout/enviado/1" "$(reading d4)/$(reading d4_mail)/$(mails)"
  d4_setup; TENV+=(NOTIFY_BIN="$T/bin/nao-existe"); xrun 5 $LOWW; eq "notify que nem existe: 'nao-executou' = NÃO saiu, com o mail de reserva" "falhou:nao-executou/enviado" "$(reading d4)/$(reading d4_mail)"
  d4_setup; STUB_NOTIFY_RC=12; STUB_MAIL_RC=1; xrun 5 $LOWW; eq "notify e mail falham juntos: o vigia diz as DUAS falhas e continua tentando o notify" "falhou:rc-12/falhou/2026-10-19/null" "$(reading d4)/$(reading d4_mail)/2026-10-19/$(state_f d4_dia)"

  # ---- a falha do notify é de um EPISÓDIO (gate-fix 1, ga-2hd02v.5.10): o marcador só é limpo por um envio que DÁ CERTO, e a sequência baixa (ou o dia) acaba sem isso -------------------
  # o marcador velho, de uma sequência que já acabou, fazia o `deliver` achar que o mail de reserva da sequência NOVA já tinha saído: o Athos não era avisado e o Mayor também não
  d4_setup; STUB_NOTIFY_RC=12; xrun 5 $LOWW
  eq "1º episódio: o notify falha (rc 12), o mail de reserva sai e a falha anotada leva o episódio dela (a sequência baixa em curso)" "falhou:rc-12/enviado/1/1/1" "$(reading d4)/$(reading d4_mail)/$(notifies)/$(mails)/$([ "$(state_f d4_falha_ep)" = "$(state_f baixa_desde)" ] && [ "$(state_f d4_falha_ep)" != null ] && echo 1 || echo 0)"
  EP1=$(state_f d4_falha_ep)
  xtick 900 1400 30 50 0; eq "a CPU volta à meta: a sequência acaba SEM um envio que dê certo, e o marcador da falha (hora e episódio) fica no estado: é isto que não pode calar a próxima" "0/$EP1/1" "$(state_f baixas_seguidas)/$(state_f d4_falha_ep)/$([ "$(state_f d4_falha_em)" != null ] && echo 1 || echo 0)"
  xrun 4 $LOWW; eq "2º episódio (outra sequência baixa, 75 min depois): o notify falha de novo e o mail de reserva sai DE NOVO (o marcador do 1º episódio não vale para este)" "falhou:rc-12/enviado/2/2" "$(reading d4)/$(reading d4_mail)/$(notifies)/$(mails)"
  eq "... e a falha anotada passa a levar o episódio NOVO" 1 "$([ "$(state_f d4_falha_ep)" = "$(state_f baixa_desde)" ] && [ "$(state_f d4_falha_ep)" != "$EP1" ] && echo 1 || echo 0)"
  xtick 900 $LOWW; eq "dentro do mesmo episódio a regra antiga segue: 15 min depois é 'espera-retry' e o mail de reserva não se repete" "espera-retry/2/2" "$(reading d4)/$(notifies)/$(mails)"
  # o espelho do que o revisor reproduziu: marcador com UM DIA, sem episódio gravado (estado antigo), e o notify falha na 1ª tentativa desta sequência
  d4_setup; xrun 4 $LOWW >/dev/null; state_set "d4_falha_em=$((NOW - 86400))"; STUB_NOTIFY_RC=12; xtick 900 $LOWW
  eq "marcador de falha com 1 dia e sem episódio: é a 1ª falha DESTA sequência, então o mail de reserva SAI (marcador velho não cala)" "falhou:rc-12/enviado/1/1" "$(reading d4)/$(reading d4_mail)/$(notifies)/$(mails)"
  d4_setup; xrun 4 $LOWW >/dev/null; state_set "d4_falha_em=$((NOW - 86400))" "d4_falha_ep=12345"; STUB_NOTIFY_RC=12; xtick 900 $LOWW
  eq "idem com o marcador de OUTRA sequência gravada (episódio diferente do de agora): o mail de reserva sai" "falhou:rc-12/enviado/1/1" "$(reading d4)/$(reading d4_mail)/$(notifies)/$(mails)"
  d4_setup; xrun 4 $LOWW >/dev/null; state_set "d4_falha_em=$((NOW - 1800))" "d4_falha_ep=12345"; STUB_NOTIFY_RC=12; xtick 900 $LOWW
  eq "marcador de OUTRA sequência de 30 min atrás: ele também não prende o retry desta ('espera-retry' é do episódio de agora), então o notify é tentado já" "falhou:rc-12/1" "$(reading d4)/$(notifies)"

  # ---- a bead do D4 ---------------------------------------------------------------------------------------------------------------------------------------------------------------
  d4_setup; STUB_BD_CREATE_RC=1; xrun 5 $LOWW
  eq "bd create que falha: o aviso SAI mesmo assim (o Athos sabe) sem a linha da bead, e o JSONL diz por que não houve bead" "enviado:entregue/1/1/bd-falhou/null" "$(reading d4)/$(notifies)/$(creates)/$(reading d4_bead)/$(state_f d4_bead)"
  hasnt "... o texto não cita bead nenhuma" "Bead:" "$(cat "$T/stub/notify.1.text")"
  d4_setup; STUB_BD_CREATE_ID="id com espaço;rm"; xrun 5 $LOWW; eq "id que o bd devolve fora do formato: 'id-ilegivel', não vai no texto nem no estado" "id-ilegivel/null" "$(reading d4_bead)/$(state_f d4_bead)"
  d4_setup; STUB_BD_CREATE_ID=VAZIO; xrun 5 $LOWW; eq "bd sem id nenhum na saída: idem" "id-ilegivel" "$(reading d4_bead)"
  d4_setup; STUB_NOTIFY_RC=12; xrun 5 $LOWW >/dev/null; STUB_NOTIFY_RC=0; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW; eq "retry depois de 1 h reaproveita a bead (1 create só)" "1/enviado:entregue" "$(creates)/$(reading d4)"

  # ---- o que não li não esgota a escada ---------------------------------------------------------------------------------------------------------------------------------------------
  xfresh; keys_on d3 d4; PILOT_HQ=0; mkdir -p "$C/.gc/wa-node-pass-memo.tsv"; TENV=(HETZNER_OCC_D4_AFTER_S=3600); xrun 5 600 30 50 800
  eq "memória do Pilot que não abre: o D3 é 'cego' e a escada NÃO esgotou, então 1 h abaixo da régua não avisa nem cria bead" "fila-sem-elegível/cego/nao/0/0" "$(reading causa)/$(reading degrau.d3)/$(reading d4)/$(notifies)/$(creates)"
  xfresh; keys_on d3 d4; PILOT_HQ=0; TENV=(HETZNER_OCC_D4_AFTER_S=3600); xrun 5 600 30 50 800
  eq "... o controle: com a memória LIDA e sem 'unknown' (nada a reclassificar) a escada esgotou e o D4 avisa" "nao-aplica/enviado:entregue/1/1" "$(reading degrau.d3)/$(reading d4)/$(notifies)/$(creates)"

  # ---- o número do dia -------------------------------------------------------------------------------------------------------------------------------------------------------------
  numdia() { python3 -I - "$(dj)" "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
p, key, pct, wins, causas, acoes = sys.argv[1:7]
try:
    d = json.load(open(p))
except OSError:
    d = {"dias": {}}
day = {"ocupado": 0, "ocioso": 0, "desconhecido": 0, "leituras": int(wins), "ocupacao_pct": None if pct == "null" else float(pct), "ocupacao_sessao_pct": None,
       "cpu_janelas": int(wins), "cpu_nucleos_s": 0.0, "cpu_capacidade_s": 0}
if causas != "-":
    day["causas"] = json.loads(causas)
if acoes != "-":
    day["acoes"] = int(acoes)
d["dias"][key] = day
json.dump(d, open(p, "w"))
PY
  }
  # o dia 18/10 fechou em 60 % (abaixo): 40 leituras com a causa 'lastro' e 6 com 'lixo'; 3 ações
  xfresh; keys_on dia; numdia 2026-10-18 60.0 96 '{"lastro-sem-trabalho":40,"lixo":6}' 3; xtick 900 $LOWW
  eq "ontem fechou em 60 % (abaixo de 85): UM aviso ao Athos com o número e a causa principal" "enviado:entregue/1/0" "$(reading numero_do_dia)/$(notifies)/$(mails)"
  has "... o título tem a porcentagem e a meta" "Hetzner fechou ontem em 60.0% de CPU (meta 85%)" "$(cat "$T/stub/notify.1.title")"
  has "... o texto: o dia, o número, a causa principal com a conta, quantas vezes o vigia agiu e onde está o detalhe" "Ontem (18/10) o Hetzner pago fechou o dia com a CPU média em 60.0%; a meta é 85%. Causa principal: sobram núcleos livres e o lastro não os usa (40 de 46 leituras abaixo da meta). O vigia agiu 3 vez(es) no dia. Detalhe: $C/.gc/hetzner-occupancy.jsonl" "$(cat "$T/stub/notify.1.text")"
  eq "o notify do dia roda com os 2 sinais e o dia fica avaliado (hoje)" "1/1/2026-10-19" "$(cut -d/ -f1 "$T/stub/notify.1.env")/$(cut -d/ -f2 "$T/stub/notify.1.env")/$(state_f dia_avaliado)"
  xtick 900 $LOWW; eq "a leitura seguinte, no mesmo dia: 'ja-avaliado', nada mais" "ja-avaliado/1" "$(reading numero_do_dia)/$(notifies)"
  xfresh; keys_on dia; numdia 2026-10-18 85.0 96 '{"lixo":2}' 1; xtick 900 1000 30 50 150; eq "ontem fechou NA META (85,0 %, a régua é < e não <=): não avisa, não age e o dia fica avaliado" "na-meta/0/0/0/2026-10-19" "$(reading numero_do_dia)/$(notifies)/$(mails)/$(acts)/$(state_f dia_avaliado)"
  xfresh; keys_on dia; numdia 2026-10-18 84.9 96 '{"lixo":2}' -; xtick 900 $LOWW; eq "84,9 % é abaixo; sem 'acoes' no dia, o texto diz 0 vez(es)" "enviado:entregue" "$(reading numero_do_dia)"; has "... e diz 0 vez(es)" "O vigia agiu 0 vez(es) no dia." "$(cat "$T/stub/notify.1.text")"
  xfresh; keys_on dia; numdia 2026-10-18 60.0 47 '{"lixo":2}' 1; xtick 900 $LOWW; eq "dia com 47 janelas lidas (< 48): é dia cego, NÃO tem número: nem 'abaixo' nem 'na meta', sem aviso" "sem-numero/0/2026-10-19" "$(reading numero_do_dia)/$(notifies)/$(state_f dia_avaliado)"
  xfresh; keys_on dia; numdia 2026-10-18 60.0 48 '{"lixo":2}' 1; xtick 900 $LOWW; eq "48 janelas: já tem número" "enviado:entregue" "$(reading numero_do_dia)"
  xfresh; keys_on dia; numdia 2026-10-18 null 96 '{"lixo":2}' 1; xtick 900 $LOWW; eq "dia sem ocupacao_pct (nenhuma janela lida): sem número, sem aviso" "sem-numero/0" "$(reading numero_do_dia)/$(notifies)"
  xfresh; keys_on dia; xtick 900 $LOWW; eq "sem registro de ontem: 'sem-dia-anterior', sem aviso (o 1º dia do vigia)" "sem-dia-anterior/0/2026-10-19" "$(reading numero_do_dia)/$(notifies)/$(state_f dia_avaliado)"
  xfresh; keys_on dia; numdia 2026-10-17 40.0 96 '{"lixo":2}' 1; xtick 900 $LOWW; eq "só vale o dia de ONTEM (o de anteontem, a 40 %, não avisa)" "sem-dia-anterior/0" "$(reading numero_do_dia)/$(notifies)"
  xfresh; keys_on dia; numdia 2026-10-18 60.0 96 - -; xtick 900 $LOWW; eq "dia abaixo sem causa registrada: o aviso diz isso, sem inventar causa" "enviado:entregue" "$(reading numero_do_dia)"; has "... 'a causa não foi registrada nesse dia'" "A causa não foi registrada nesse dia." "$(cat "$T/stub/notify.1.text")"
  xfresh; keys_on dia; numdia 2026-10-18 60.0 96 '{"lixo":5,"RAM":5,"cego":30}' 2; xtick 900 $LOWW; eq "o 'cego' nunca é a causa principal; o empate entre causas vai para a de maior prioridade (lixo)" "enviado:entregue" "$(reading numero_do_dia)"; has "... lixo, 5 de 10" "Causa principal: sessão sem dono parada no nó (a cidade não a conhece) (5 de 10 leituras abaixo da meta)." "$(cat "$T/stub/notify.1.text")"
  # sem a chave
  xfresh; numdia 2026-10-18 60.0 96 '{"lixo":2}' 1; xtick 900 $LOWW; eq "sem a chave dia: só mede ('desligado'), nada sai e o dia NÃO fica avaliado (ligar a chave depois ainda avisa hoje)" "desligado/0/null" "$(reading numero_do_dia)/$(notifies)/$(state_f dia_avaliado)"
  xfresh; keys_on dia; numdia 2026-10-18 60.0 96 '{"lixo":2}' 1; TENV=(HETZNER_OCC_ACT=0); xtick 900 $LOWW; eq "HETZNER_OCC_ACT=0: idem" "desligado/0" "$(reading numero_do_dia)/$(notifies)"
  # --dry-run
  xfresh; keys_on dia; numdia 2026-10-18 60.0 96 '{"lixo":2}' 1; XARGS="--print --dry-run"; xtick 900 $LOWW; eq "--dry-run: 'enviaria' e nada sai nem é gravado (nem o estado nasce)" "enviaria/0/0" "$(reading numero_do_dia)/$(notifies)/$([ -e "$C/.gc/hetzner-occupancy.state.json" ] && echo 1 || echo 0)"
  # o dia do mês anterior: ontem = 31/10 quando hoje é 01/11
  xfresh $(date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-01 12:00:00' +%s 2>/dev/null || python3 -I -c 'import time; print(int(time.mktime((2026,11,1,12,0,0,0,0,-1))))'); keys_on dia; numdia 2026-10-31 60.0 96 '{"lixo":2}' 1; xtick 900 $LOWW; eq "virada de mês: hoje 01/11, ontem foi 31/10" "enviado:entregue" "$(reading numero_do_dia)"; has "... e o texto diz 31/10" "Ontem (31/10)" "$(cat "$T/stub/notify.1.text")"
  # falha do notify do dia
  xfresh; keys_on dia; numdia 2026-10-18 60.0 96 '{"lixo":2}' 1; STUB_NOTIFY_RC=12; xtick 900 $LOWW
  eq "notify do dia que falha (rc 12): 'falhou', mail de reserva uma vez, o dia NÃO fica avaliado e a falha é anotada" "falhou:rc-12/enviado/1/1/null/$NOW" "$(reading numero_do_dia)/$(reading numero_do_dia_mail)/$(notifies)/$(mails)/$(state_f dia_avaliado)/$(state_f dia_falha_em)"
  xtick 900 $LOWW; eq "15 min depois: 'espera-retry' (1 h entre tentativas), nada novo sai" "espera-retry/1/1" "$(reading numero_do_dia)/$(notifies)/$(mails)"
  STUB_NOTIFY_RC=0; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW >/dev/null; xtick 900 $LOWW
  eq "1 h depois o notify volta: 'enviado', o dia fica avaliado e a falha limpa; o mail de reserva não se repetiu" "enviado:entregue/2026-10-19/null/1" "$(reading numero_do_dia)/$(state_f dia_avaliado)/$(state_f dia_falha_em)/$(mails)"
  # a falha do notify do dia é do DIA julgado (gate-fix 1, ga-2hd02v.5.10): o marcador do número de 18/10, que nunca chegou a sair, não cala o mail do número de 19/10 nem prende o retry dele
  xfresh $((NOW0 + 36000)); keys_on dia; numdia 2026-10-18 60.0 96 '{"lixo":2}' 1; STUB_NOTIFY_RC=12; xtick 900 $LOWW
  eq "22h15 de 19/10, número de 18/10: o notify falha, o mail de reserva sai e a falha anotada leva o dia julgado" "falhou:rc-12/enviado/1/1/2026-10-18" "$(reading numero_do_dia)/$(reading numero_do_dia_mail)/$(notifies)/$(mails)/$(state_f dia_falha_ep)"
  numdia 2026-10-19 60.0 96 '{"lixo":2}' 1; for _ in 1 2 3 4 5 6; do xtick 900 $LOWW >/dev/null; done
  eq "23h45 de 19/10: o notify do número de 18/10 foi tentado de novo na hora seguinte (23h15: 2 notifies) SEM repetir o mail de reserva (1), a leitura de agora espera o retry e a falha segue sendo do dia 18/10" "espera-retry/2/1/2026-10-18" "$(reading numero_do_dia)/$(notifies)/$(mails)/$(state_f dia_falha_ep)"
  xtick 900 $LOWW; eq "00h00 de 20/10: o número agora é o de 19/10, OUTRO dia: não espera o retry do de 18/10 (a falha dele foi há 45 min) e o mail de reserva dele sai (o marcador do 18/10 não o cala); a falha anotada leva o dia novo" "falhou:rc-12/enviado/3/2/2026-10-19" "$(reading numero_do_dia)/$(reading numero_do_dia_mail)/$(notifies)/$(mails)/$(state_f dia_falha_ep)"
  # o espelho do que o revisor reproduziu: marcador com UM DIA e sem dia gravado (estado antigo), notify falhando na 1ª tentativa deste número
  xfresh; keys_on dia; numdia 2026-10-18 60.0 96 '{"lixo":2}' 1; STUB_NOTIFY_RC=12; xtick 900 $LOWW >/dev/null; state_set "dia_falha_em=$((NOW - 86400))" "dia_falha_ep="; xtick 900 $LOWW
  eq "marcador de falha com 1 dia e sem dia gravado: é a 1ª falha DESTE número, então o mail de reserva SAI de novo (marcador velho não cala)" "falhou:rc-12/enviado/2" "$(reading numero_do_dia)/$(reading numero_do_dia_mail)/$(mails)"
  xfresh; keys_on dia; numdia 2026-10-18 60.0 96 '{"lixo":2}' 1; STUB_NOTIFY_RC=12; xtick 900 $LOWW >/dev/null; state_set "dia_falha_em=$((NOW - 86400))" "dia_falha_ep=\"2026-10-17\""; xtick 900 $LOWW
  eq "idem com o marcador do dia 17/10 gravado (outro dia que o julgado agora, 18/10): o mail de reserva sai" "falhou:rc-12/enviado/2" "$(reading numero_do_dia)/$(reading numero_do_dia_mail)/$(mails)"
  xfresh; keys_on dia; numdia 2026-10-18 60.0 96 '{"lixo":2}' 1; STUB_NOTIFY_RC=12; xtick 900 $LOWW >/dev/null; state_set "dia_falha_em=$((NOW - 1800))" "dia_falha_ep=\"2026-10-17\""; xtick 900 $LOWW
  eq "marcador do dia 17/10 de 30 min atrás: não prende o retry do número de 18/10 ('espera-retry' é do dia de agora), o notify é tentado já" "falhou:rc-12/2" "$(reading numero_do_dia)/$(notifies)"
  # o número do dia e o D4 são avisos diferentes: o mesmo dia pode ter os dois
  d4_setup; keys_on dia; numdia 2026-10-18 60.0 96 '{"lixo":2}' 1; xrun 5 $LOWW
  eq "o D4 e o número do dia são independentes: 2 notifies (um de cada), cada um uma vez" "enviado:entregue/ja-avaliado/2" "$(reading d4)/$(reading numero_do_dia)/$(notifies)"
  # o diário guarda causas e ações do dia
  xfresh; keys_on d1; node_add "$GHOST" 14400 2700; xdue $LOWW >/dev/null
  eq "o diário do dia soma a causa (lixo, 2 leituras baixas com lixo: a 3ª leitura é a que agiu) e a ação" "lixo/1" "$(jv "$(dj)" dias.2026-10-19.causas | python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); print(max(d, key=d.get))')/$(jv "$(dj)" dias.2026-10-19.acoes)"
}

# ============================================================================================================================================================================
g_replay() {
  echo "--- replay: as 18 leituras reais de 04/11 (10h05-14h26, CPU 24-47 %, todas 'ocupado') devolvem a causa e o degrau esperados; o dia na meta e o vigia cego não agem nem avisam (ga-2hd02v.5.10)"
  # epoch, janela (s) e núcleos médios em centinúcleos das leituras REAIS de .gc/hetzner-occupancy.jsonl (16 vCPU), e quantas beads do hq a fila do Pilot tinha. Só o que o JSONL antigo não tinha (as partes dos núcleos)
  # é sintetizado: espera de disco 1,52, lastro 0,30 e sistema 0,50 por janela; o resto são as sessões. A sessão-lixo do caso real e uma sessão viva que a cidade conhece e que segura bead moram no tmux do nó.
  local ROWS="1793797501 967 664 0
1793798422 921 699 0
1793799344 922 754 0
1793800263 919 637 0
1793801185 922 431 0
1793802102 917 421 0
1793803021 919 560 0
1793803939 918 511 0
1793804862 923 447 1
1793805783 921 460 0
1793806713 930 517 1
1793807650 937 614 1
1793808594 944 640 0
1793809513 919 424 0
1793810433 920 631 0
1793811359 926 542 1
1793812271 912 391 1
1793813199 928 535 0"
  local SEED=1793796534 kj dj rp_e rp_j rp_c rp_f rp_s k
  replay_setup() {   # replay_setup <chaves…>: o nó do dia 04/11 às 09h48 (a semente do baseline) com o lixo parado há 4 h na 2ª leitura
    xfresh $((SEED - 900)); keys_on "$@"; sessions_are "$SJ_REMOTE"; beads_are "$BJ_REMOTE"
    xtick 900 200 30 50 152 >/dev/null
    node_add "$GHOST" 14400 1888; node_add dog-remote-gapxi4ls 60 0
    kj="$NODE/gt-remote/ballast/lastro-pedido.json"; dj="$C/.gc/hetzner-occupancy-daily.json"
  }
  replay_run() {   # replay_run <real|meta>: roda as 18 janelas e junta, por leitura, causa/d1/d2/d3/nº de ações/ganho medido
    local mode=$1
    RP=(); RPE=()
    while read -r rp_e rp_j rp_c rp_f <&3; do
      [ -n "$rp_e" ] || continue
      if [ "$mode" = real ]; then rp_s=$((rp_c - 80)); else rp_s=1300; fi   # meta: 13,8 núcleos = 86,2 % de 16
      PILOT_HQ=$rp_f xtick "$rp_j" "$rp_s" 30 50 152 >/dev/null
      [ "$NOW" = "$rp_e" ] || bad "o relógio do replay desencontrou: $NOW em vez de $rp_e"
      RP+=("$(reading causa)/$(reading degrau.d1)/$(reading degrau.d2)/$(reading degrau.d3)/$(reading acao | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')/$(reading efeito.0.ganho_nucleos | sed 's/^<ilegivel>$/-/')")
      RPE+=("$(reading estado)")
    done 3<<<"$ROWS"
  }
  rp_join() { local IFS='|'; echo "$*"; }

  # ---- o dia real: causa e degrau de cada leitura --------------------------------------------------------------------------------------------------------------------------------
  replay_setup d1 d2 d3 d4 dia; replay_run real
  eq "leitura 1 (CPU 41,5 %; só 15 min medidos na 1ª janela baixa): a causa é o lixo, o degrau ainda não é devido" "lixo/nao-devido/nao-devido/nao-devido/0/-" "${RP[0]}"
  eq "leitura 2 (a 1ª com 30 min, 1888 s): o D1 mata a sessão sem dono (o caso gate-reviewer-remote-adhoc-033f7bd5c1) e o d2 espera a vez" "lixo/agiu/aguarda/nao-aplica/1/-" "${RP[1]}"
  eq "leitura 3: sem lixo a causa vira lastro; o intervalo de 30 min segura o d2; o efeito do D1, medido: 6,99 → 7,54 núcleos (+0,55)" "lastro-sem-trabalho/fora/cooldown/nao-aplica/0/0.55" "${RP[2]}"
  eq "leitura 4 (+1841 s): o D2 pede lastro" "lastro-sem-trabalho/fora/agiu/nao-aplica/1/-" "${RP[3]}"
  eq "leitura 5: cooldown, e o efeito do D2 medido SEM maquiagem (a CPU caiu 2,06 núcleos: o pedido sozinho não provou nada)" "lastro-sem-trabalho/fora/cooldown/nao-aplica/0/-2.06" "${RP[4]}"
  eq "leitura 6: 2ª e última tentativa do D2" "lastro-sem-trabalho/fora/agiu/nao-aplica/1/-" "${RP[5]}"
  eq "leitura 7: as 2 tentativas do d2 já estão gastas (o esgotado vem antes do intervalo) e o efeito da 2ª, medido: +1,39" "lastro-sem-trabalho/fora/esgotado/nao-aplica/0/1.39" "${RP[6]}"
  eq "leitura 8: d2 esgotado, d3 sem o que fazer (memória do Pilot vazia), nada a medir" "lastro-sem-trabalho/fora/esgotado/nao-aplica/0/-" "${RP[7]}"
  eq "leituras 9 a 18: escada esgotada, nada mais age" "$(rp_join "${RP[@]:8}")" "$(rp_join $(for k in 1 2 3 4 5 6 7 8 9 10; do echo "lastro-sem-trabalho/fora/esgotado/nao-aplica/0/-"; done))"
  eq "o estado do vigia nas 18 leituras: 'ocupado' em todas (a sessão segura bead): o log antigo dizia 'ocupado' o dia inteiro com a CPU a 24-47 %" "18/ocupado" "$(printf '%s\n' "${RPE[@]}" | sort | uniq -c | awk '{print $1"/"$2}')"
  eq "no nó: só a sessão-lixo morreu (a sessão que a cidade conhece e segura bead segue de pé)" "$GHOST/1" "$(cat "$T/stub/node.killed")/$(node_has dog-remote-gapxi4ls)"
  eq "3 ações no dia (D1, D2, D2) e 3 chamadas de ação ao nó" "3/3" "$(jv "$dj" dias.2026-11-04.acoes)/$(acts)"
  eq "o pedido de lastro que ficou no nó é o da última tentativa: v1, +4 slots (livres 8, RAM 20000 comporta 5, teto 4), válido por 2 leituras (1800 s)" "1/4/1793802102/1800" "$(jv "$kj" v)/$(jv "$kj" slots_extra)/$(jv "$kj" epoch)/$(( $(jv "$kj" ate) - $(jv "$kj" epoch) ))"
  eq "o diário do dia: a causa principal é lastro (16 de 18) e o lixo 2; a média de CPU do dia é a do log (34,3 %)" "16/2/34.3" "$(jv "$dj" dias.2026-11-04.causas.lastro-sem-trabalho)/$(jv "$dj" dias.2026-11-04.causas.lixo)/$(jv "$dj" dias.2026-11-04.ocupacao_pct)"
  eq "o D4 não é devido (4 h36 de sequência baixa < 6 h): nenhum aviso, nenhuma bead" "nao/0/0/0" "$(reading d4)/$(notifies)/$(creates)/$(mails)"
  eq "o JSONL tem a semente e as 18 leituras" 19 "$(wc -l < "$C/.gc/hetzner-occupancy.jsonl" | tr -d ' ')"
  check "NUNCA liga a queima (nenhum comando ao nó cita burn; nenhum burn.on nasce)" "$([ "$(cat "$T/stub/ssh.act" "$T/stub/ssh.calls" | grep -ci burn)" = 0 ] && [ -z "$(find "$C" "$NODE" -iname '*burn*')" ] && echo 1 || echo 0)"
  # o dia seguinte: o número do dia, com as 18 janelas valendo como dia (o padrão exige 48 = 12 h; o log real de 04/11 só tem as 4 h da janela de 10h-14h)
  NOW=$((NOW + 40000)); TENV=(HETZNER_OCC_DAY_MIN_WINDOWS=10); xtick 900 $LOWW
  eq "05/11, 1ª leitura do dia: o número do dia sai ao Athos, UMA vez" "enviado:entregue/1" "$(reading numero_do_dia)/$(notifies)"
  has "... com a porcentagem e a meta no título" "Hetzner fechou ontem em 34.3% de CPU (meta 85%)" "$(cat "$T/stub/notify.1.title")"
  has "... e a causa principal e as ações no texto" "Ontem (04/11) o Hetzner pago fechou o dia com a CPU média em 34.3%; a meta é 85%. Causa principal: sobram núcleos livres e o lastro não os usa (16 de 18 leituras abaixo da meta). O vigia agiu 3 vez(es) no dia." "$(cat "$T/stub/notify.1.text")"
  xtick 900 $LOWW; eq "a leitura seguinte: já avaliado, não repete" "ja-avaliado/1" "$(reading numero_do_dia)/$(notifies)"

  # ---- controle negativo: as MESMAS 18 janelas, a CPU na meta (86,2 %), com a sessão-lixo no nó e todas as chaves ligadas ------------------------------------------------------
  replay_setup d1 d2 d3 d4 dia; replay_run meta
  eq "o dia na meta: nenhuma leitura tem causa e nenhum degrau é devido (nem com o lixo lá)" "18/null/nao-devido/nao-devido/nao-devido/0/-" "$(printf '%s\n' "${RP[@]}" | sort | uniq -c | awk '{print $1"/"$2}')"
  eq "... nada vai ao nó, a sessão-lixo continua lá, nenhum notify, mail nem bead" "0/1/0/0/0" "$(acts)/$(node_has "$GHOST")/$(notifies)/$(mails)/$(creates)"
  eq "... e o pedido de lastro não nasce" 0 "$([ -e "$NODE/gt-remote/ballast/lastro-pedido.json" ] && echo 1 || echo 0)"
  NOW=$((NOW + 40000)); TENV=(HETZNER_OCC_DAY_MIN_WINDOWS=10); xtick 900 $LOWW
  eq "05/11: o dia fechou na meta (86,2 %): 'na-meta', NÃO avisa, e o dia fica avaliado" "na-meta/0/0/$(state_f dia_avaliado)" "$(reading numero_do_dia)/$(notifies)/$(mails)/2026-11-05"

  # ---- vigia cego: o mesmo dia com o ssh caído --------------------------------------------------------------------------------------------------------------------------------
  xfresh $((SEED - 900)); keys_on d1 d2 d3 d4 dia; node_add "$GHOST" 14400 1888; STUB_SSH_RC=1; RP=(); RPE=()
  for k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    xtick 920 200 30 50 152 >/dev/null; RP+=("$(reading causa)/$(reading degrau.d1)/$(reading d4)"); RPE+=("$(reading estado)")
  done
  eq "ssh caído o dia inteiro: nenhuma leitura tem causa dita (todas 'cego') e nenhum degrau é devido" "18/cego/nao-devido/nao" "$(printf '%s\n' "${RP[@]}" | sort | uniq -c | awk '{print $1"/"$2}')"
  eq "... o estado é 'desconhecido' (nunca 'ocioso': não ler não é provar que está parado)" "18/desconhecido" "$(printf '%s\n' "${RPE[@]}" | sort | uniq -c | awk '{print $1"/"$2}')"
  eq "... e não age, não avisa, não cria bead" "0/1/0/0/0" "$(acts)/$(node_has "$GHOST")/$(notifies)/$(mails)/$(creates)"
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
  mutante janela-curta-lida "cpu" $'if win < c.min_window_s:\n        cpu["motivo"] = "janela-curta"' $'if False:\n        cpu["motivo"] = "janela-curta"'
  mutante janela-velha-lida "cpu" $'if win > c.max_window_s:\n        cpu["motivo"] = "leitura-anterior-velha"' $'if False:\n        cpu["motivo"] = "leitura-anterior-velha"'
  mutante relogio-recuou-lido "cpu" $'if win < 0:\n        cpu["motivo"] = "relogio-recuou"' $'if False:\n        cpu["motivo"] = "relogio-recuou"'
  mutante contador-recuou-lido "cpu" $'if db < 0 or dt < 0:' $'if False:'
  mutante sem-tick-lido "cpu" $'if dt == 0:\n        cpu["motivo"] = "sem-tick"' $'if False:\n        cpu["motivo"] = "sem-tick"'
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
  mutante sem-marcador-lido "cpu" $'if BEGIN not in lines or END not in lines[lines.index(BEGIN) + 1:]:\n        return None, "sem-marcador"' $'if False:\n        return None, "sem-marcador"'
  mutante ssh-sem-batchmode "cpu" $'argv = [c.ssh_bin, "-o", "BatchMode=yes", ' $'argv = [c.ssh_bin, '
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
  mutante dry-run-grava-e-avisa "saida" $'    if not dry:\n        if verdict in ("na-meta", "sem-numero", "sem-dia-anterior"):' $'    if True:\n        if verdict in ("na-meta", "sem-numero", "sem-dia-anterior"):'
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
  # ---- ga-2hd02v.5.10: a causa, a escada e o aviso. Cada trecho trocado abaixo é uma regra de SEGURANÇA ou de verdade do número; o grupo dito TEM de reprovar -----------------------------------
  # as cópias das guardas da CPU dentro da leitura dos núcleos (read_nucleos) e da leitura irmã (parse_extra): cada uma tem o seu mutante, senão uma delas poderia sumir sem ninguém ver
  mutante nuc-janela-curta-lida "causa" $'if win < c.min_window_s:\n        n["motivo"] = "janela-curta"' $'if False:\n        n["motivo"] = "janela-curta"'
  mutante nuc-janela-velha-lida "causa" $'if win > c.max_window_s:\n        n["motivo"] = "leitura-anterior-velha"' $'if False:\n        n["motivo"] = "leitura-anterior-velha"'
  mutante nuc-relogio-recuou-lido "causa" $'if win < 0:\n        n["motivo"] = "relogio-recuou"' $'if False:\n        n["motivo"] = "relogio-recuou"'
  mutante nuc-contador-recuou-lido "causa" $'if min(du, dio, db, dt) < 0:' $'if False:'
  mutante nuc-sem-tick-lido "causa" $'if dt == 0:\n        n["motivo"] = "sem-tick"' $'if False:\n        n["motivo"] = "sem-tick"'
  mutante extra-sem-marcador-lido "causa" $'if BEGIN not in lines or END not in lines[lines.index(BEGIN) + 1:]:\n        return ex' $'if False:\n        return ex'
  mutante acao-ssh-sem-batchmode "escada" $'return run_cmd([c.ssh_bin, "-o", "BatchMode=yes", ' $'return run_cmd([c.ssh_bin, '
  # a causa: o que não li nunca vira causa nem degrau
  mutante ram-ilegivel-pede-lastro "causa" $'if ram_mb is None:\n            return "cego"' $'if ram_mb is None:\n            return "lastro-sem-trabalho"'
  mutante sem-piso-de-ram "causa escada" $'if ram_mb < c.ram_start_mb + c.ram_slot_mb:\n            return "RAM"' $'if False:\n            return "RAM"'
  mutante nenhuma-causa-explica-vira-fila "causa" $'if fila["lido"] and fila["n"] == 0:\n        return "fila-sem-elegível"\n    return "cego"' $'return "fila-sem-elegível"'
  mutante fila-ilegivel-vira-vazia "causa" $'if fila["lido"] and fila["n"] == 0:' $'if fila["n"] in (0, None):'
  mutante cego-tem-degrau "escada" $'    if cause == "cego":\n        return {k: "cego" for k in RUNGS}, None, False' $'    if False:\n        return {k: "cego" for k in RUNGS}, None, False'
  # a escada: um degrau por vez, com intervalo, com tentativas contadas e sem esgotar o que não li ou ninguém autorizou
  mutante sem-intervalo-entre-acoes "escada" $'cooling = last is not None and now - last < c.act_cooldown_s' $'cooling = False'
  mutante acao-no-futuro-nao-esfria "escada" $'cooling = last is not None and now - last < c.act_cooldown_s' $'cooling = last is not None and 0 <= now - last < c.act_cooldown_s'
  mutante tentativas-sem-limite "escada" $'elif _tries(st, k) >= c.act_tries:' $'elif False:'
  mutante degrau-desligado-esgota "escada aviso" $'status[k], exhausted = "desligado", False' $'status[k] = "desligado"'
  mutante degrau-cego-esgota "escada aviso" $'status[k], exhausted = "cego", False' $'status[k] = "cego"'
  mutante dois-degraus-na-mesma-leitura "escada" $'elif chosen is None:\n                chosen, status[k] = k, "pronto"' $'else:\n                chosen, status[k] = k, "pronto"'
  mutante acao-sem-chave "escada" $'elif not c.on[k]:\n            status[k], exhausted = "desligado", False' $'elif False:\n            status[k], exhausted = "desligado", False'
  mutante tentativa-gravada-depois-da-acao "escada" $'        save()\n        if chosen:\n            ok, o_que, det = do_rung(' $'        if chosen:\n            ok, o_que, det = do_rung('
  mutante acao-falha-mede-efeito "escada" $'            if ok:  # só o que mudou algo tem efeito a medir' $'            if True:  # só o que mudou algo tem efeito a medir'
  # D1: nunca mata o que a cidade conhece, o que segura bead, nem o que não leu
  mutante d1-mata-sessao-da-cidade "causa escada" $'or name in known or (other and other.search(name)):' $'or (other and other.search(name)):'
  mutante d1-ignora-dono-de-bead "causa escada" $'cand = [(i, n) for i, n in cand if n not in donos]' $'cand = cand'
  mutante d1-sem-limite-de-quietude "causa escada" $'if idle >= c.d1_idle_s:' $'if True:'
  mutante d1-sem-reconferir-no-no "escada" $'[ $((n - a)) -lt %d ] && { echo ativa; exit 0; }' $'[ 0 -lt %d ] && { echo ativa; exit 0; }'
  mutante d1-nome-sem-remote "escada" $'if not SAFE_NAME.fullmatch(name) or "-remote-" not in "-%s-" % name:\n        return False, "nome-recusado"' $'if False:\n        return False, "nome-recusado"'
  mutante d1-morta-qualquer-palavra "escada" $'return (words[-1] == ok_word, words[-1]) if words else (False, "sem-saida")' $'return (True, words[-1]) if words else (False, "sem-saida")'
  mutante d1-rc-ignorado "escada" $'    if rc != 0:\n        return False, "rc-%s" % rc\n    return (words' $'    return (words'
  # D1, o sinal de "quieta" e o que prova que ninguém a segura (achados da revisão de segurança)
  mutante d1-so-session-activity "causa" $'by[f[0]] = max(by.get(f[0], 0), int(f[1]), int(f[2]))' $'by[f[0]] = max(by.get(f[0], 0), int(f[1]))'
  mutante d1-janela-ultima-vence "causa" $'by[f[0]] = max(by.get(f[0], 0), int(f[1]), int(f[2]))' $'by[f[0]] = max(0, int(f[1]), int(f[2]))'
  mutante d1-reconferencia-so-session "escada" $'-F "#{session_activity} #{window_activity}"' $'-F "#{session_activity}"'
  mutante d1-reconferencia-minimo "escada" $'sort -n | tail -n 1' $'sort -n | head -n 1'
  mutante d1-sem-guarda-numerica "escada" $'\'case "$a" in ""|*[!0-9]*) echo ilegivel; exit 0;; esac; \'' $'\'\''
  mutante d1-reconhecidas-sem-nome "causa" $'if not bad_entry and not unnamed:' $'if not bad_entry:'
  mutante d1-sem-donos-dos-rigs "causa escada" $'donos = donos | rig_donos' $'donos = donos'
  mutante d1-rig-ilegivel-segue "causa" $'if h is None:\n            return None, "loja-ilegivel:%s:%s" % (os.path.basename(path), why2)' $'if h is None:\n            continue'
  mutante d1-rigs-vazia-vale "causa" $'if not isinstance(rigs, list) or not rigs:' $'if not isinstance(rigs, list):'
  mutante d1-rigs-envelope-erro-vale "causa" $'if isinstance(d, dict) and d.get("ok") is True else None' $'if isinstance(d, dict) else None'
  # D2: o pedido vence e respeita os pisos
  mutante pedido-sem-validade "escada" $'"ate": now + 2 * c.interval_s' $'"ate": now + 2000 * c.interval_s'
  mutante pedido-sem-teto "escada" $'min(int(nuc["livres"]), (ram_mb - c.ram_start_mb) // c.ram_slot_mb, 4)' $'min(int(nuc["livres"]), (ram_mb - c.ram_start_mb) // c.ram_slot_mb, 400)'
  mutante pedido-ignora-a-ram "escada" $'min(int(nuc["livres"]), (ram_mb - c.ram_start_mb) // c.ram_slot_mb, 4)' $'min(int(nuc["livres"]), 4)'
  # D3: memória ilegível não é memória vazia; vence a última linha da bead
  mutante memoria-ilegivel-vira-vazia "escada" $'return None, None, "memo-ilegivel"' $'return set(), [], None'
  mutante memoria-vencida-conta "escada" $'if v == "unknown" and now - ep < c.memo_unknown_ttl_s}' $'if v == "unknown"}'
  # o notify: só o rc diz se saiu
  mutante notify-12-conta "aviso" $'ok = {0: "entregue", 10: "segurado-ate-7h", 11: "ja-tinha-saido"}' $'ok = {0: "entregue", 10: "segurado-ate-7h", 11: "ja-tinha-saido", 12: "digest"}'
  mutante notify-so-0-conta "aviso" $'ok = {0: "entregue", 10: "segurado-ate-7h", 11: "ja-tinha-saido"}' $'ok = {0: "entregue"}'
  mutante notify-sem-strict-exit "aviso" $'"NOTIFY_STRICT_EXIT": "1", ' $''
  mutante notify-sem-force-push "aviso" $', "NOTIFY_FORCE_PUSH": "1"' $''
  mutante notify-falho-vira-do-dia "aviso" $'new_st["d4_dia"] = st.get("d4_dia")  # não saiu' $'pass  # não saiu'
  mutante notify-falho-gasta-o-dia "aviso" $'new_st["dia_avaliado"] = st.get("dia_avaliado")' $'pass'
  mutante notify-falho-sem-mail "aviso" $'if falha_em is None else None' $'if False else None'
  # gate-fix 1 (ga-2hd02v.5.10): a falha do notify é de um EPISÓDIO; lixo não lido nunca esgota a escada
  mutante falha-de-outro-episodio-cala-o-mail "aviso" $'    if falha_em is None or ep is None or falha_ep != ep:\n        return None\n    return falha_em' $'    if falha_em is None:\n        return None\n    return falha_em'
  mutante falha-sem-dono-vale "aviso" $'or ep is None or falha_ep != ep:' $'or ep is None:'
  mutante d4-episodio-nao-gravado "aviso" $'(None if falha4 is None else d4_ep)' $'None'
  mutante dia-episodio-nao-gravado "aviso" $'(None if falhad is None else ykey)' $'None'
  mutante d4-marcador-de-qualquer-episodio "aviso" $'falha_do_episodio(new_st["d4_falha_em"], new_st["d4_falha_ep"], d4_ep)' $'falha_do_episodio(new_st["d4_falha_em"], new_st["d4_falha_ep"], new_st["d4_falha_ep"])'
  mutante dia-marcador-de-qualquer-dia "aviso" $'falha_do_episodio(new_st["dia_falha_em"], new_st["dia_falha_ep"], ykey)' $'falha_do_episodio(new_st["dia_falha_em"], new_st["dia_falha_ep"], new_st["dia_falha_ep"])'
  mutante d4-retry-prende-outro-episodio "aviso" $'plan_notice(c, "d4", d4_due, st.get("d4_dia") == today, d4_falha, now, dry)' $'plan_notice(c, "d4", d4_due, st.get("d4_dia") == today, new_st["d4_falha_em"], now, dry)'
  mutante dia-retry-prende-outro-dia "aviso" $'plan_notice(c, "dia", True, False, dia_falha, now, dry)' $'plan_notice(c, "dia", True, False, new_st["dia_falha_em"], now, dry)'
  mutante ram-lixo-cego-esgota "aviso" $', None, not d1_cego' $', None, True'
  mutante ram-d1-cego-sem-rotulo "aviso" $'d1="cego" if d1_cego else "ram"' $'d1="ram"'
  mutante lixo-cego-vira-fora "aviso" $'if k == "d1" and d1_cego:' $'if False:'
  mutante notify-sem-espera-do-retry "aviso" $'    if falha_em is not None and 0 <= now - falha_em < c.notify_retry_s:\n        return "espera-retry"' $'    if False:\n        return "espera-retry"'
  # D4: só depois de 6 h, só esgotado, uma vez por dia, e a bead é registro (nunca despachável)
  mutante d4-sem-esgotar "aviso" $'d4_due = low["n"] > 0 and exhausted and' $'d4_due = low["n"] > 0 and'
  mutante d4-sem-esperar-6h "aviso" $'now - low["desde"] >= c.d4_after_s - c.slack_s' $'now - low["desde"] >= 0'
  mutante d4-bead-despachavel "aviso" $'"area:infra,hetzner-ocupacao"' $'"area:infra,hetzner-ocupacao,story:approved,exec:auto"'
  mutante d4-bead-nao-guardada "aviso" $'                if bid:\n                    new_st["d4_bead"] = bid\n' $'                if bid:\n                    pass\n'
  mutante d4-dia-nao-gravado "aviso" $'            new_st["d4_dia"] = today\n            save()\n            ok4' $'            save()\n            ok4'
  # o número do dia: só dia com número, só abaixo da meta
  mutante dia-cego-vira-abaixo "aviso" $'if pct is None or wins < c.day_min_windows:' $'if pct is None:'
  mutante dia-na-meta-avisa "aviso replay" $'return ("abaixo" if pct < c.low_pct else "na-meta"), day, key' $'return "abaixo", day, key'
  mutante dia-sem-chave-avalia "aviso" $'    if not c.on["dia"]:\n        verdict = "desligado"' $'    if False:\n        verdict = "desligado"'
  mutante dia-avisa-duas-vezes "aviso" $'    elif st.get("dia_avaliado") == today:\n        verdict = "ja-avaliado"' $'    elif False:\n        verdict = "ja-avaliado"'
  mutante dia-causa-cega-conta "aviso" $'cnt = {k: t[k] for k in CAUSAS if k != "cego" and' $'cnt = {k: t[k] for k in CAUSAS if'
  mutantes_wait
}

GROUPS_ALL="cfg sess bead cpu fila estado alarme baixa saida lastro causa escada aviso replay"
run_groups() { local g; for g in "$@"; do "g_$g"; done; }

DEFAULT="$GROUPS_ALL mutantes"; [ -z "${HOCC_NO_MUTANTS:-}" ] || DEFAULT="$GROUPS_ALL"
wanted="${*:-$DEFAULT}"
for g in $wanted; do case " $GROUPS_ALL mutantes " in *" $g "*) ;; *) echo "grupo desconhecido: $g (grupos: $GROUPS_ALL mutantes)" >&2; exit 2 ;; esac; done
fresh; W PYTHONDONTWRITEBYTECODE= -- --print-config   # aquece o cache de bytecode (ver o W()): vazio = esta rodada grava, em $PYC e não no HOME; as seguintes e os mutantes só leem
run_groups $wanted

echo ""
echo "hetzner-occupancy-watch selftest: $((n - fails))/$n ok, $fails FAIL"
[ "$fails" -eq 0 ] && exit 0 || exit 1
