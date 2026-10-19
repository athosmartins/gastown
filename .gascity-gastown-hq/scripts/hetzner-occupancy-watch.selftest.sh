#!/usr/bin/env bash
# hetzner-occupancy-watch.selftest.sh — hermético: gc e ssh são stubs; a cidade, o HOME e o /proc/stat são sintéticos; nada fala com o servidor nem com o mail de verdade. (ga-2hd02v.1.12)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS (grupos, na ordem): cfg (configuração em vigor, plist, gramática do Python 3.9) · sess (sessões remotas: 3 estados, MBP fora) · cpu (/proc/stat por ssh: baseline, janela, recuo de contador,
#   ssh que cai ou trava) · estado (ocupado / ocioso / desconhecido: a tabela inteira) · saida (JSONL, número por dia, arquivos corrompidos, --dry-run, instância única, falha de gravação, nada fora de .gc, nenhum mail).
# CONTROLE NEGATIVO: cada mutante (um trecho literal do script trocado, que tem de existir UMA vez) TEM de reprovar o grupo que o pega; mutante que passa = teste que não pega o bug. Só roda sem argumento e com o script de verdade.
#   Cada mutante roda em segundo plano com o PRÓPRIO diretório temporário e para no 1º caso que reprova (o resto do grupo não diz nada de novo): sem isso eram ~80 grupos inteiros em série, mais de 10 min.
# COMO RODAR: hetzner-occupancy-watch.selftest.sh [grupo ...]   (sem argumento: todos os grupos e o controle negativo). HETZNER_OCC_UNDER_TEST=<script> roda a suíte contra outra cópia.
#   HOCC_JOBS=N mutantes ao mesmo tempo (padrão 4; 1 = em série) · HOCC_NO_MUTANTS=1 pula o controle negativo (183 dos 238 casos, ~20 s no Linux) · HOCC_SLOW_START=N faz o python do vigia levar N s para subir, como o mini sob carga (com HOCC_NO_MUTANTS=1).
#   Tudo: ~80 s no Linux (carga ~12; ~115 s a carga ~20); no mini, sob carga, ~7 min (medido pelo gate em 19/10). RELÓGIO: nenhum caso mede o tempo de parede do vigia (no mini sob carga só subir o python leva segundos): a ordem das duas instâncias é por EVENTO (await) e o único prazo, o do run_cmd, é medido dentro do python.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="${HETZNER_OCC_UNDER_TEST:-$HERE/hetzner-occupancy-watch.py}"
PLIST="$HERE/com.gascity.hetzner-occupancy-watch.plist"
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
# gc de mentira: `session list --json` devolve $STUB_GC_FILE (ou falha com $STUB_GC_RC; com $STUB_OUTFAIL imprime o JSON COMPLETO antes de falhar; com $STUB_GC_HOLD fica PRESO, avisando em hold.in, até o teste criar hold.go); o resto (`mail send` inclusive: esta fatia não manda mail) é PROIBIDO (rc 99, marcado)
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
for b in bd dolt; do   # o vigia NUNCA deve chamar bd nem dolt (só gc session list / ssh de leitura)
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
sessions_are() { printf '%s' "$1" > "$T/sessions.json"; STUB_GC_FILE="$T/sessions.json"; }

fresh() {   # cidade, HOME, stubs e relógio novos; sessões = nenhuma remota
  C="$T/city"; HM="$T/home"
  find "$C" "$HM" "$T/stub" "$T/tmp" -mindepth 1 -delete 2>/dev/null
  mkdir -p "$C/.gc/logs" "$HM" "$T/stub" "$T/tmp"
  NOW=${1:-$NOW0}; CB=0; CI=0; NCPU=16; RC=0; TENV=()
  STUB_GC_RC=0; STUB_GC_SLEEP=""; STUB_SSH_RC=0; STUB_SSH_SLEEP=""; STUB_SSH_FILE=""; STUB_OUTFAIL=""
  WOUT="$T/out.json"; WERR="$T/err"
  sessions_are "$SJ_NONE"
}
W() {   # W [VAR=valor ...] [-- args do vigia] : roda o vigia no ambiente do cenário. stdout → $WOUT, stderr → $WERR, rc → $RC
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  # PYTHONDONTWRITEBYTECODE=1: o python NÃO grava bytecode em lugar nenhum, então o HOME falso fica vazio em qualquer python (o grupo saida confere). PYTHONPYCACHEPREFIX=$PYC: de onde ele LÊ o bytecode, aquecido uma vez no fim deste arquivo;
  # sem isso cada rodada recompilaria a stdlib (medido no Linux com o python de mentira: 2x o tempo, ~3x a CPU).
  env -i HOME="$HM" PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX="$PYC" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$T/tmp" TZ="$TZNAME" \
    GC_CITY_PATH="$C" GC_BIN="$T/bin/gc" SSH_BIN="$T/bin/ssh" HETZNER_OCC_NOW="$NOW" \
    STUB_DIR="$T/stub" STUB_GC_FILE="${STUB_GC_FILE:-}" STUB_GC_RC="${STUB_GC_RC:-0}" STUB_GC_SLEEP="${STUB_GC_SLEEP:-}" \
    STUB_SSH_FILE="${STUB_SSH_FILE:-}" STUB_SSH_RC="${STUB_SSH_RC:-0}" STUB_SSH_SLEEP="${STUB_SSH_SLEEP:-}" STUB_OUTFAIL="${STUB_OUTFAIL:-}" \
    "${extra[@]+"${extra[@]}"}" python3 "$WATCH" "$@" >"$WOUT" 2>"$WERR"
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
tick() {   # tick <segundos> <centinúcleos> : avança o relógio, "gasta" CPU nesse intervalo (contadores acumulados, 100 ticks/s por núcleo), e roda o vigia com --print (TENV = variáveis extras)
  NOW=$((NOW + $1)); CB=$((CB + $2 * $1)); CI=$((CI + (NCPU * 100 - $2) * $1))
  statfile "$T/stat.txt" "$CB" "$CI" "$NCPU"; STUB_SSH_FILE="$T/stat.txt"
  W "${TENV[@]+"${TENV[@]}"}" -- --print
}
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
  W HETZNER_OCC_BUSY_CORES=1.5 -- --print-config
  eq "env muda a régua" 1.5 "$(reading busy_cores)"
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
    ("PATH acha o gc e os utilitários do usuário", "/Users/athos/go/bin" in env.get("PATH", "") and "/Users/athos/.local/bin" in env.get("PATH", "")),
    ("HOME (o ssh_config do usuário tem o alias do servidor)", env.get("HOME") == "/Users/athos"),
    ("GC_CITY_PATH", env.get("GC_CITY_PATH") == "/Users/athos/gt/.gascity-gastown-hq"),
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
  eq "1 sessão remota ativa + CPU baixa = ocupado" ocupado "$(reading estado)"
  eq "nomes das sessões vão na leitura" '["dog-remote-gapxi4ls"]' "$(reading sessoes.nomes)"

  fresh; sessions_are "$SJ_REMOTE"; tick 900 5
  eq "sessão remota ativa prova ocupado mesmo SEM leitura de CPU (1ª leitura, sem baseline)" ocupado "$(reading estado)"

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
  sessions_are '{"sessions":[{"session_name":"dog-remote-aaa","state":"active"},"lixo"]}'; tick 900 5
  eq "entrada ilegível MAS há sessão ativa provada: lida, ocupado" ocupado "$(reading estado)"
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
  # run_cmd mata o GRUPO inteiro e volta logo, sem esperar o neto que segura o pipe. Era o "voltou em < 5 s" dos casos de gc e ssh que travam, que contava também a subida do python (no mini sob carga ela sozinha passa de 4 s); aqui o relógio fica DENTRO do python, só ao redor da chamada: com o killpg ~1 s, sem ele 1 s + os 5 do communicate = 6 s, corte em 4 s.
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
  eq "ssh caiu + sessão remota ativa = ocupado (a sessão prova)" ocupado "$(reading estado)"

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
g_estado() {
  echo "--- estado: tabela completa (sessões × CPU)"
  # (sessão, CPU) → estado. "?" = não lida. Cada linha prepara um cenário próprio.
  local row sess cpu want
  for row in "1 baixa ocupado" "1 alta ocupado" "1 ? ocupado" "0 baixa ocioso" "0 alta ocupado" "0 ? desconhecido" "? baixa desconhecido" "? alta ocupado" "? ? desconhecido"; do
    sess=${row%% *}; cpu=${row#* }; cpu=${cpu%% *}; want=${row##* }   # expansão de parâmetro: `set -- $row` globava o "?" contra os arquivos do cwd (um arquivo "x" lá e o grupo reprovava sem motivo); não é here-string porque no bash 3.2 ela vira arquivo temporário
    fresh; tick 900 5 >/dev/null
    case "$sess" in 1) sessions_are "$SJ_REMOTE" ;; 0) sessions_are "$SJ_NONE" ;; "?") STUB_GC_RC=1 ;; esac
    case "$cpu" in
      baixa) tick 900 5 ;;
      alta)  tick 900 200 ;;
      "?")   STUB_SSH_RC=255; tick 900 5 ;;
    esac
    eq "sessões=$sess CPU=$cpu → $want" "$want" "$(reading estado)"
  done
}

# ============================================================================================================================================================================
g_saida() {
  echo "--- saida: JSONL, número por dia"
  fresh; tick 900 5 >/dev/null; tick 900 5; tick 900 200
  local jl="$C/.gc/hetzner-occupancy.jsonl"
  eq "uma linha por execução" 3 "$(wc -l < "$jl" | tr -d ' ')"
  last_line "$jl"
  eq "JSONL: estado da última" ocupado "$(jv "$T/last.json" estado)"; eq "JSONL: epoch" "$NOW" "$(jv "$T/last.json" epoch)"
  eq "JSONL: ts = a hora LOCAL do epoch com o deslocamento (12:45 em SP; hora UTC com sufixo local não passa)" "2026-10-19T12:45:00-0300" "$(jv "$T/last.json" ts)"

  fresh "$(epoch_of 2026 10 19 23 20 0)"
  tick 900 5 >/dev/null; tick 900 5; tick 900 200; tick 900 5; STUB_SSH_RC=255; tick 900 5; tick 86400 5
  local d="$C/.gc/hetzner-occupancy-daily.json"
  eq "dia 19: 1 ocioso" 1 "$(jv "$d" dias.2026-10-19.ocioso)"; eq "dia 19: 1 desconhecido (a 1ª leitura, sem baseline)" 1 "$(jv "$d" dias.2026-10-19.desconhecido)"; eq "dia 19: 0 ocupado" 0 "$(jv "$d" dias.2026-10-19.ocupado)"
  eq "dia 19: leituras" 2 "$(jv "$d" dias.2026-10-19.leituras)"; eq "dia 19: ocupação 0.0% (desconhecido não entra na conta)" 0.0 "$(jv "$d" dias.2026-10-19.ocupacao_pct)"
  eq "dia 20 (virou a meia-noite): 1 ocupado" 1 "$(jv "$d" dias.2026-10-20.ocupado)"; eq "dia 20: 1 ocioso" 1 "$(jv "$d" dias.2026-10-20.ocioso)"; eq "dia 20: 1 desconhecido" 1 "$(jv "$d" dias.2026-10-20.desconhecido)"
  eq "dia 20: ocupação 50.0%" 50.0 "$(jv "$d" dias.2026-10-20.ocupacao_pct)"
  eq "dia 21: só desconhecido → ocupação null (nunca 0%, nunca 100%)" null "$(jv "$d" dias.2026-10-21.ocupacao_pct)"; eq "dia 21: 1 leitura" 1 "$(jv "$d" dias.2026-10-21.leituras)"

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
  fresh; tick 900 5 >/dev/null; tick 900 5; tick 900 5
  local before after; before=$(cksum "$C/.gc/"hetzner-occupancy* | sort)
  NOW=$((NOW + 900)); CB=$((CB + 5 * 900)); CI=$((CI + (NCPU * 100 - 5) * 900)); statfile "$T/stat.txt" "$CB" "$CI" "$NCPU"; STUB_SSH_FILE="$T/stat.txt"
  W -- --dry-run --print
  after=$(cksum "$C/.gc/"hetzner-occupancy* | sort)
  eq "dry-run: nenhum arquivo mudou" "$before" "$after"
  eq "dry-run: a leitura sai no stdout" ocioso "$(reading estado)"; eq "dry-run: rc 0" 0 "$RC"

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

  echo "--- saida: crash e falha de gravação (traceback à vista, rc 3)"
  fresh; tick 900 5 >/dev/null
  W HETZNER_OCC_BUSY_CORES=nao-e-numero -- --print
  check "config inválida: sai com erro (rc != 0)" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"; has "... traceback à vista no stderr (não engolido)" "Traceback" "$(cat "$WERR")"
  fresh; rmdir "$C/.gc/logs" "$C/.gc"; : > "$C/.gc"     # .gc virou ARQUIVO: nenhuma gravação é possível, para qualquer usuário (inclusive root)
  tick 900 5
  eq "não consegui gravar: rc 3" 3 "$RC"; has "... diz 'não consegui gravar'" "não consegui gravar" "$(cat "$WERR")"

  echo "--- saida: só LÊ o mundo (nada de bd, dolt, mail, ou gc fora de session list)"
  fresh; tick 900 5 >/dev/null; tick 900 5; tick 900 5
  check "nenhuma chamada proibida (bd, dolt, mail send, outro subcomando do gc)" "$([ ! -s "$T/stub/forbidden.calls" ] && echo 1 || echo 0)"
  eq "gc só chamado para 'session list --json'" 0 "$(grep '^gc ' "$T/stub/gc.calls" | grep -v -e ' session list --json$' | wc -l | tr -d ' ')"
  eq "gc sempre com --city explícito (não depende do cwd do launchd)" 0 "$(grep '^gc ' "$T/stub/gc.calls" | grep -v "^gc --city $C " | wc -l | tr -d ' ')"
  eq "o que o vigia escreve em .gc (e nada além; os logs são do cenário)" "hetzner-occupancy-daily.json hetzner-occupancy.jsonl hetzner-occupancy.lock hetzner-occupancy.state.json" "$(ls "$C/.gc" | grep -v -e '^logs$' | tr '\n' ' ' | sed 's/ $//')"
  eq "e nada no HOME, nem o bytecode do python (o W() fixa como o python grava)" "" "$(ls -A "$HM" | tr '\n' ' ' | sed 's/ $//')"
  # controle da conferência acima: o python de mentira TEM de sujar o HOME quando o ambiente não diz como gravar bytecode; se deixar de sujar, a conferência passa por vazio no Linux (o buraco do gate ga-ztz9yn)
  fresh; env -i HOME="$HM" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" python3 -c 'import json, re' >/dev/null 2>&1
  check "controle: sem o ambiente do W(), o python de mentira escreve no HOME (a conferência acima não passa por vazio)" "$([ -n "$(ls -A "$HM")" ] && echo 1 || echo 0)"
  # a variável vista de dentro do processo: o HOME vazio sozinho passaria só pelo cache fora dele (no Linux, sem a variável, ainda passa); a que o revisor do gate mediu no mini é esta
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
  mutante rc-ignorado "sess cpu" $'return prefix + "-falhou" if (why or rc != 0) else None' $'return prefix + "-falhou" if why else None'
  mutante saida-vazia-vira-zero "sess" $'r["motivo"] = "json-ilegivel" if out.strip() else "saida-vazia"' $'r.update(lido=True, ativas=0)'
  mutante envelope-ok-falso-lido "sess" $'if isinstance(d, dict) and "ok" in d and d["ok"] is not True:' $'if False:'
  mutante sessao-do-mbp-conta "sess" $'elif "-remote-" not in "-%s-" % ident or (other and other.search(ident)):' $'elif "-remote-" not in "-%s-" % ident:'
  mutante sessao-closed-conta "sess" $'        elif s.get("closed"):\n            continue' $'        elif False:\n            continue'
  mutante estado-fora-do-vocabulario-ignorado "sess" $'bad_state += 1  #' $'pass  #'
  mutante entrada-ilegivel-ignorada "sess" $'bad_entry += 1' $'pass'
  mutante ilegivel-anula-sessao-ativa "sess" $'if active:  # uma sessão ativa provada basta' $'if active and not (bad_entry or bad_state):  # uma sessão ativa provada basta'
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
  mutante sessao-nao-prova-ocupado "estado" $'if (sess["lido"] and sess["ativas"]) or (cpu["lido"] and cores >= busy_cores):' $'if (cpu["lido"] and cores >= busy_cores):'
  mutante cpu-nao-prova-ocupado "estado" $'if (sess["lido"] and sess["ativas"]) or (cpu["lido"] and cores >= busy_cores):' $'if (sess["lido"] and sess["ativas"]):'
  mutante regua-sem-igual "estado cpu" $'(cpu["lido"] and cores >= busy_cores)' $'(cpu["lido"] and cores > busy_cores)'
  mutante diario-conta-desconhecido-na-taxa "saida" $'dec = day["ocupado"] + day["ocioso"]' $'dec = day["leituras"]'
  mutante diario-sem-decisao-vira-zero "saida" $'if dec else None' $'if dec else 0.0'
  mutante dia-em-utc "saida" $'time.strftime("%Y-%m-%d", time.localtime(now))' $'time.strftime("%Y-%m-%d", time.gmtime(now))'
  mutante ts-em-utc "saida" $'"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))' $'"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.gmtime(now))'
  # ts-em-utc sobreviveu no mini (Mayor, 19/10, 235/236): o caso só olhava o sufixo -0300. Se lá o %z de um gmtime sai com o deslocamento LOCAL, a hora em UTC passa com o sufixo certo; este mutante é essa forma, igual em qualquer sistema.
  mutante ts-hora-utc-sufixo-local "saida" $'"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))' $'"ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + time.strftime("%z", time.localtime(now))'
  mutante corrompido-nao-guarda-a-copia "saida" $'os.replace(path, dest)' $'pass'
  mutante sem-instancia-unica "saida" $'if not dry and take_lock(c.gc_dir) is None:' $'if False:'
  mutante dry-run-grava "saida" $'    if not dry:\n        write_atomic(state_path' $'    if True:\n        write_atomic(state_path'
  mutante falha-de-gravacao-sai-0 "saida" $'return e.rc' $'return 0'
  mutante crash-sem-traceback "saida" $'traceback.print_exc()' $'pass'
  mutantes_wait
}

GROUPS_ALL="cfg sess cpu estado saida"
run_groups() { local g; for g in "$@"; do "g_$g"; done; }

DEFAULT="$GROUPS_ALL mutantes"; [ -z "${HOCC_NO_MUTANTS:-}" ] || DEFAULT="$GROUPS_ALL"
wanted="${*:-$DEFAULT}"
for g in $wanted; do case " $GROUPS_ALL mutantes " in *" $g "*) ;; *) echo "grupo desconhecido: $g (grupos: $GROUPS_ALL mutantes)" >&2; exit 2 ;; esac; done
fresh; W PYTHONDONTWRITEBYTECODE= -- --print-config   # aquece o cache de bytecode (ver o W()): vazio = esta rodada grava, em $PYC e não no HOME; as seguintes e os mutantes só leem
run_groups $wanted

echo ""
echo "hetzner-occupancy-watch selftest: $((n - fails))/$n ok, $fails FAIL"
[ "$fails" -eq 0 ] && exit 0 || exit 1
