#!/usr/bin/env bash
# gc-session-ssh.selftest.sh — hermético: o "ssh" é um falso que roda o comando no próprio mini, o tmux usa um TMUX_TMPDIR de mktemp
# (nunca toca o tmux de verdade), cidade/home/config são fixtures. Nada conecta em servidor nenhum.
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS (grupos, na ordem): proto — operação desconhecida/não suportada sai 2 sem ssh · dry — o comando de start leva os MESMOS itens do
#   local (--settings da cidade reescrito para o do bundle, --dangerously-skip-permissions, --model, --remote-control só quando pedido, o
#   --settings inline do pool), prompt com/sem flag, env filtrado (GC_* sim; token/PATH não; env_allow traz o token de volta), campos
#   ignorados listados, nenhum /Users/ no que sairia, nenhuma conexão · live — sessão de verdade num tmux de teste: start, is-running,
#   list-running (prefixo), nudge→peek, send-keys, interrupt, process-alive, get-last-activity, clear-scrollback, stop idempotente,
#   cwd e env no host, prompt de 40 KB com aspas/$()/crase chega íntegro e sem executar nada, lançador some, nome EXATO (pfx-a ≠ pfx-ab),
#   comando que não existe / que morre → start falha dizendo por quê e não deixa sessão · cap — teto do host (N+1 recusa), existente
#   recusa, parar libera, outro host conta à parte, 4 starts em paralelo com teto 2 abrem 2, e as execuções remotas não se sobrepõem
#   (flock) · down — ssh fora do ar/mudo/sem marcadores/com ruído: start recusa dizendo o host, list-running é ERRO (nunca lista vazia),
#   nada pela metade, meta continua funcionando · meta — set/get/remove/stop, chave inválida, nada no "servidor" · conf — config
#   ausente, cap ausente/0/string, host desconhecido, destino ssh com '-', raiz com espaço, nome de sessão inválido: exit 1, sem ssh ·
#   guard — caminho do mini que sobra no comando/env/workdir recusa e nada abre · terr — o tmux do host existe mas não consegue olhar
#   (socket sem permissão): is-running, list-running, process-alive, start, stop, interrupt, nudge, send-keys, peek, clear-scrollback e
#   get-last-activity dão ERRO com o motivo, nunca "false"/"vazio"/"há vaga"/"parou"; já a sessão AUSENTE (tmux respondeu) dá rc 0 nas
#   operações de melhor esforço (grupo live), e stop só diz que parou se a sessão sumiu (tmux falso que não derruba, grupo live) ·
#   gate (ga-2hd02v.1.5) — sessão REAL só abre com `real_sessions_released_by` (texto não vazio) E com o remote-clone-guard.py do host idêntico ao do
#   repositório E o --selfcheck dele aprovando as settings do host; sem isso exit 1 dizendo o motivo, nada aberto, nada pela metade; a sessão mínima de
#   teste (remote-e2e-<x>, remote-test-<x>, e só ela) abre sempre; o dry-run diz qual é qual; o resto dos grupos roda COM o portão ligado e satisfeito.
# CONTROLE NEGATIVO: cada guarda é removida do script (sed numa cópia) e o grupo que a cobre TEM que passar a falhar: teto do host, nome
#   exato (sessão, is-running, start), alvo de painel =nome:, guarda de /Users/, filtro de env, exit 2 das desconhecidas, marcador de fim,
#   erro de ssh, flock, "tmux sem acesso" tolerado como "sem servidor", o `has` que engole o erro do tmux, melhor esforço da sessão
#   ausente, o stop que não confere que a sessão sumiu, e o portão (sem a liberação, liberação de qualquer tipo, nome de teste frouxo ou sem
#   âncora, sem conferir o sha do guarda, sem rodar o --selfcheck, script do host que sai 0, guarda irmão ilegível; 24 mutantes).
#   Mais: contra um stub que só sai 0, quase tudo falha.
# VARIÁVEIS: GCSSH_UNDER_TEST (script a testar) · GCSSH_ONLY (grupos separados por vírgula) · GCSSH_NO_MUTANTS=1
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${GCSSH_UNDER_TEST:-$HERE/gc-session-ssh}"
for v in $(env | sed -n 's/^\(GC_[A-Za-z0-9_]*\)=.*/\1/p') TMUX TMUX_PANE GC_SSH_HOST; do unset "$v"; done  # o "servidor" é esta máquina: nada do ambiente de quem roda (ex.: GC_INSTANCE_TOKEN) pode vazar para as sessões de teste
T=$(cd "$(mktemp -d /tmp/gcs.XXXXXX)" && pwd -P)  # curto: o caminho do socket do tmux tem limite de ~100 caracteres
SOCK="gct$$"
export TMUX_TMPDIR="$T/tmux"; mkdir -p "$TMUX_TMPDIR" "$T/bin" "$T/home" "$T/remote/home" "$T/state"
cleanup() { for s in "$SOCK" "${SOCK}b"; do tmux -L "$s" kill-server 2>/dev/null; done; chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
RR="$T/remote/gt-remote/bundle"; RH="$T/remote/home"; CITY=/Users/test/gt/.city

cat > "$T/bin/ssh" <<'EOF'
#!/bin/sh
# ssh falso: registra, simula falhas (FAKE_SSH_*) e roda o comando remoto aqui mesmo (sem as opções -o/-t, sem o destino)
[ -z "${FAKE_SSH_LOG:-}" ] || printf '%s\n' "ssh $*" >> "$FAKE_SSH_LOG"
[ -z "${FAKE_SSH_FAIL:-}" ] || { echo "ssh: connect to host fakehost port 22: Connection timed out" >&2; exit 255; }
[ -z "${FAKE_SSH_HANG:-}" ] || exec sleep 30
while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; -*) shift;; *) break;; esac; done
shift
[ -z "${FAKE_SSH_NOISE:-}" ] || echo "bashrc: bem-vindo ao servidor"
if [ -n "${FAKE_SSH_JUNK:-}" ]; then cat >/dev/null; echo "saida sem marcadores"; exit 0; fi
[ -z "${FAKE_SSH_TIMES:-}" ] || echo "B $$ $(python3 -c 'import time;print(time.time())')" >> "$FAKE_SSH_TIMES"
if [ -n "${FAKE_SSH_CUT:-}" ]; then sh -c "$*" | grep -v '@@GC-END@@'; exit 0; fi
sh -c "$*"; rc=$?
[ -z "${FAKE_SSH_TIMES:-}" ] || echo "E $$ $(python3 -c 'import time;print(time.time())')" >> "$FAKE_SSH_TIMES"
exit $rc
EOF
chmod +x "$T/bin/ssh"

cfg() {  # cfg CAP [TIMEOUT] [EXTRA-JSON-do-host-a]  → $T/cfg.json (host a: socket $SOCK; host b: socket ${SOCK}b, teto 1)
  jq -n --argjson cap "$1" --argjson to "${2:-25}" --argjson extra "${3:-{\}}" --arg rr "$RR" --arg rh "$RH" --arg s "$SOCK" \
    '{default_host:"a", hosts:{a:({ssh:"fakehost",cap:$cap,remote_root:$rr,remote_home:$rh,socket:$s,mini_home:"/Users/test",timeout:$to,start_timeout:$to,real_sessions_released_by:"selftest"}+$extra),
      b:{ssh:"fakehost",cap:1,remote_root:$rr,remote_home:$rh,socket:($s+"b"),mini_home:"/Users/test",real_sessions_released_by:"selftest"}}}' > "$T/cfg.json"
}
pv() {  # pv ARGS... < entrada  → RC, $T/out, $T/err
  env HOME="$T/home" GC_SSH_CONFIG="$T/cfg.json" GC_SSH_BIN="$T/bin/ssh" GC_EXEC_STATE_DIR="$T/state" FAKE_SSH_LOG="$T/ssh.log" \
    "$P" "$@" >"$T/out" 2>"$T/err"; RC=$?
}
nossh() { [ ! -s "$T/ssh.log" ]; }
fresh() { : > "$T/ssh.log"; }
req() {  # req COMMAND [WORKDIR] [EXTRA-JSON] → JSON do start
  jq -n --arg c "$1" --arg w "${2:-$CITY/.gc/agents/dog}" --argjson x "${3:-{\}}" \
    '{work_dir:$w, command:$c, env:{GC_CITY:"'"$CITY"'", GC_AGENT:"dog-1", GC_DIR:($w)}} + $x'
}
GUARDF=remote-clone-guard.py
install_host() {  # o guarda e as settings do "servidor" ($RH/.claude), como o bundle os instala; o guarda é o IRMÃO do script em teste (o que o provider confere)
  local src; src="$(dirname "$P")/$GUARDF"; [ -f "$src" ] || src="$HERE/$GUARDF"
  mkdir -p "$RH/.claude/hooks"; cp "$src" "$RH/.claude/hooks/$GUARDF"
  jq -n --arg c "python3 -I $RH/.claude/hooks/$GUARDF || exit 2" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c}]},{matcher:"Edit|Write|MultiEdit|NotebookEdit",hooks:[{type:"command",command:$c}]}]}}' > "$RH/.claude/settings.json"
}
count() { tmux -L "${2:-$SOCK}" list-sessions 2>/dev/null | grep -c . ; }
group() { [ -z "${GCSSH_ONLY:-}" ] || case ",$GCSSH_ONLY," in *",$1,"*) return 0;; *) return 1;; esac; }
cfg 3; install_host

g_proto() {
  fresh; pv frobnicate x </dev/null; [ $RC = 2 ] && [ ! -s "$T/out" ] && nossh; ok $? "proto: operação desconhecida sai 2, sem saída e sem ssh"
  for op in copy-to check-image watch-startup run-live; do fresh; pv $op x a b </dev/null; [ $RC = 2 ] && nossh; ok $? "proto: $op (conhecida, não suportada) sai 2 sem ssh"; done
  fresh; pv </dev/null; [ $RC = 2 ] && nossh; ok $? "proto: sem argumentos sai 2"
}

g_dry() {
  local pool="$CITY/packs/town-deltas/assets/scripts/claude-ctxcap-ab.sh --settings '{\"remoteControlAtStartup\":false}' --model sonnet --strict-mcp-config --dangerously-skip-permissions --effort xhigh --settings $CITY/.gc/settings.json --session-id 1a9a7c40-03ef-4caa-8412-df9368f6a538"
  local wpool="$RR/city/packs/town-deltas/assets/scripts/claude-ctxcap-ab.sh --settings '{\"remoteControlAtStartup\":false}' --model sonnet --strict-mcp-config --dangerously-skip-permissions --effort xhigh --settings $RR/city/settings.json --session-id 1a9a7c40-03ef-4caa-8412-df9368f6a538"
  local crew="claude --remote-control --model opus --dangerously-skip-permissions --effort high --settings $CITY/.gc/settings.json --session-id 77d574bf-bb7f-4ae1-be33-6f72cf73b68a"
  local wcrew="claude --remote-control --model opus --dangerously-skip-permissions --effort high --settings $RR/city/settings.json --session-id 77d574bf-bb7f-4ae1-be33-6f72cf73b68a"
  fresh; pv --dry-run start dog-1 < <(req "$pool"); local got; got=$(jq -r .command "$T/out" 2>/dev/null)
  [ $RC = 0 ] && [ "$got" = "$wpool" ]; ok $? "dry: comando do pool = o local com a cidade e o --settings reescritos (mesmos itens, mesma ordem)"
  has "$T/out" '--dangerously-skip-permissions' && has "$T/out" '--model sonnet' && has "$T/out" 'remoteControlAtStartup'; ok $? "dry: --dangerously-skip-permissions, --model e o --settings inline do pool presentes"
  ! echo "$got" | grep -q -- '--remote-control'; ok $? "dry: pool não ganha --remote-control que não pediu"
  fresh; pv --dry-run start thies-wa < <(req "$crew"); got=$(jq -r .command "$T/out")
  [ "$got" = "$wcrew" ] && echo "$got" | grep -q -- '--remote-control'; ok $? "dry: sessão com --remote-control leva --remote-control"
  echo "$got" | grep -q -- "--settings $RR/city/settings.json"; ok $? "dry: --settings aponta para o arquivo que o bundle instala ($RR/city/settings.json)"
  ! grep -q '/Users/' "$T/out"; ok $? "dry: nenhum /Users/ no que sairia para o host"
  nossh; ok $? "dry: não conectou"
  pv --dry-run start dog-1 < <(req "claude --x" "$CITY/.gc/agents/dog" '{"prompt_suffix":"'"'"'olá mundo'"'"'","prompt_flag":"--prompt"}')
  [ "$(jq -r .command "$T/out")" = "claude --x --prompt 'olá mundo'" ]; ok $? "dry: prompt_flag + prompt_suffix entram depois do comando, como no tmux local"
  pv --dry-run start dog-1 < <(req "claude --x" "$CITY/.gc/agents/dog" '{"prompt_suffix":"'"'"'olá'"'"'"}')
  [ "$(jq -r .command "$T/out")" = "claude --x 'olá'" ]; ok $? "dry: prompt_suffix sem flag entra como argumento posicional"
  pv --dry-run start dog-1 < <(req "claude" "$CITY/.gc/agents/dog" '{"env":{"GC_CITY":"'"$CITY"'","GC_DIR":"'"$CITY"'/.gc/agents/dog","GC_HOME":"/Users/test/.gc","GC_INSTANCE_TOKEN":"segredo","PATH":"/x","ANTHROPIC_API_KEY":"k","LANG":"C","pre_start":"x"},"pre_start":["mkdir /x"],"copy_files":[{"src":"/a","rel_dst":"b"}]}')
  [ "$(jq -r .env.GC_CITY "$T/out")" = "$RR/city" ] && [ "$(jq -r .env.GC_DIR "$T/out")" = "$RR/city/.gc/agents/dog" ] && [ "$(jq -r .env.GC_HOME "$T/out")" = "$RH/.gc" ]; ok $? "dry: env GC_CITY/GC_DIR/GC_HOME reescritos para o host"
  [ "$(jq -r '.env | has("GC_INSTANCE_TOKEN") or has("PATH") or has("ANTHROPIC_API_KEY")' "$T/out")" = false ] && [ "$(jq -r .env.LANG "$T/out")" = C ]; ok $? "dry: token, PATH e chave de API NÃO vão; LANG vai"
  [ "$(jq -r '.env_dropped | join(",")' "$T/out")" = "ANTHROPIC_API_KEY,GC_INSTANCE_TOKEN,PATH,pre_start" ]; ok $? "dry: o que foi descartado vem listado (só os nomes)"
  [ "$(jq -r '.ignored | join(",")' "$T/out")" = "pre_start,copy_files" ]; ok $? "dry: campos que o provider não executa vêm listados como ignored"
  ! grep -q segredo "$T/out"; ok $? "dry: o valor do token não aparece na saída"
  cfg 3 25 '{"env_allow":["GC_INSTANCE_TOKEN"]}'; pv --dry-run start dog-1 < <(req "claude" | jq '.env.GC_INSTANCE_TOKEN="t0k"')
  [ "$(jq -r .env.GC_INSTANCE_TOKEN "$T/out")" = t0k ]; ok $? "dry: env_allow na config traz o token de volta (decisão explícita, não padrão)"
  cfg 3
  pv --dry-run start remote-e2e-1 < <(req claude); [ "$(jq -r .session_kind "$T/out")" = teste ]; ok $? "dry: remote-e2e-1 é sessão de teste"
  pv --dry-run start dog-1 < <(req claude); [ "$(jq -r .session_kind "$T/out")" = real ]; ok $? "dry: dog-1 é sessão real"
}

g_live() {
  local op real r1
  cfg 3; mkdir -p "$RH"; fresh
  pv start live-1 < <(req "cat"); ok $RC "live: start abre a sessão (rc=$RC $(head -c 200 "$T/err"))"
  pv is-running live-1 </dev/null; [ "$(cat "$T/out")" = true ]; ok $? "live: is-running true"
  pv list-running live </dev/null; [ "$(cat "$T/out")" = live-1 ]; ok $? "live: list-running por prefixo lista a sessão"
  pv list-running outro </dev/null; [ $RC = 0 ] && [ ! -s "$T/out" ]; ok $? "live: list-running com outro prefixo não lista"
  pv nudge live-1 < <(printf 'ola mundo'); ok $RC "live: nudge rc 0"; sleep 0.5
  pv peek live-1 20 </dev/null; has "$T/out" 'ola mundo'; ok $? "live: peek mostra o que o nudge digitou"
  pv send-keys live-1 x y z </dev/null; sleep 0.3; pv peek live-1 20 </dev/null; has "$T/out" 'xyz'; ok $? "live: send-keys envia cada tecla"
  pv process-alive live-1 < <(printf 'cat\n'); [ "$(cat "$T/out")" = true ]; ok $? "live: process-alive cat → true"
  pv process-alive live-1 < <(printf 'nao-existe-xyz\n'); [ "$(cat "$T/out")" = false ]; ok $? "live: process-alive de processo que não roda → false"
  pv get-last-activity live-1 </dev/null; grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$T/out"; ok $? "live: get-last-activity em RFC3339"
  pv clear-scrollback live-1 </dev/null; ok $RC "live: clear-scrollback rc 0"
  pv start live-int < <(req "sh -c 'trap \"echo GOT-INT\" INT; while :; do sleep 0.2; done'"); pv interrupt live-int </dev/null; sleep 0.5; pv peek live-int 20 </dev/null
  has "$T/out" 'GOT-INT'; ok $? "live: interrupt chega à sessão (Ctrl-C)"
  pv stop live-int </dev/null; pv stop live-1 </dev/null; ok $RC "live: stop rc 0"
  pv is-running live-1 </dev/null; [ "$(cat "$T/out")" = false ]; ok $? "live: depois do stop, is-running false"
  pv list-running live </dev/null; [ ! -s "$T/out" ]; ok $? "live: depois do stop, fora do list-running"
  pv stop live-1 </dev/null; [ $RC = 0 ]; ok $? "live: stop de sessão que não existe é idempotente"
  pv stop nunca-existiu </dev/null; [ $RC = 0 ]; ok $? "live: stop de nome desconhecido rc 0"
  for op in interrupt clear-scrollback get-last-activity; do pv $op nunca-existiu </dev/null; [ $RC = 0 ] && [ ! -s "$T/out" ]; ok $? "live: $op de sessão que não existe: rc 0 e nada na saída (melhor esforço, como manda o contrato do exec)"; done
  pv nudge nunca-existiu < <(printf x); [ $RC = 0 ]; ok $? "live: nudge de sessão que não existe: rc 0 (melhor esforço)"
  pv send-keys nunca-existiu k </dev/null; [ $RC = 0 ]; ok $? "live: send-keys de sessão que não existe: rc 0 (melhor esforço)"
  pv start live-env < <(req "sh -c 'pwd > $T/pwd.out; echo \"\$GC_AGENT:\${GC_INSTANCE_TOKEN:-sem}\" > $T/env.out; exec cat'" | jq '.env.GC_INSTANCE_TOKEN="x"')
  [ "$(cat "$T/pwd.out" 2>/dev/null)" = "$(cd "$RR/city/.gc/agents/dog" && pwd -P)" ]; ok $? "live: a sessão roda no work_dir reescrito (e ele foi criado)"
  [ "$(cat "$T/env.out" 2>/dev/null)" = "dog-1:sem" ]; ok $? "live: env chega (GC_AGENT) e o token não"
  ls "$RR/run" 2>/dev/null | grep -q '\.sh$'; [ $? != 0 ]; ok $? "live: o lançador se apagou ao rodar (prompt/env não ficam em disco)"
  pv stop live-env </dev/null
  local prompt; prompt=$(python3 -c "
import sys
sys.stdout.write('linha1 \$(touch $T/PWNED) \`touch $T/PWNED2\` \'aspas\' \"dq\"\nlinha2 $CITY/x\n' + 'abc ' * 10000)")
  local want="${prompt//$CITY/$RR/city}"
  pv start live-pr < <(req "sh -c 'printf %s \"\$1\" > $T/prompt.out; exec cat' sh" "$CITY/.gc/agents/dog" "$(jq -n --arg s "$(python3 -c "import shlex,sys;print(shlex.quote(sys.argv[1]))" "$prompt")" '{prompt_suffix:$s}')")
  [ "$(cat "$T/prompt.out" 2>/dev/null)" = "$want" ]; ok $? "live: prompt de 40 KB com aspas, \$() e crase chega íntegro (e com o caminho da cidade reescrito)"
  [ ! -e "$T/PWNED" ] && [ ! -e "$T/PWNED2" ]; ok $? "live: nada do prompt foi executado"
  pv stop live-pr </dev/null
  pv start live-nf < <(req "nao-existe-xyz --x"); [ $RC = 1 ] && has "$T/err" 'comando não encontrado'; ok $? "live: comando que não existe → start falha dizendo qual"
  pv is-running live-nf </dev/null; [ "$(cat "$T/out")" = false ]; ok $? "live: ...e não deixa sessão"
  pv start live-die < <(req "sh -c 'exit 3'"); [ $RC = 1 ] && has "$T/err" 'saiu com 3'; ok $? "live: comando que morre logo → start falha com o código de saída"
  pv start pfx-ab < <(req "cat"); pv start pfx-a < <(req "cat"); ok $RC "live: nome EXATO: pfx-a abre com pfx-ab já aberto (não é 'already exists' por prefixo; rc=$RC)"; pv stop pfx-a </dev/null
  pv is-running pfx-ab </dev/null; [ "$(cat "$T/out")" = true ]; ok $? "live: nome EXATO: parar pfx-a não toca em pfx-ab"
  pv is-running pfx-a </dev/null; [ "$(cat "$T/out")" = false ]; ok $? "live: nome EXATO: is-running pfx-a não casa pfx-ab por prefixo"
  pv stop pfx-a </dev/null; pv is-running pfx-ab </dev/null; [ "$(cat "$T/out")" = true ]; ok $? "live: nome EXATO: stop de pfx-a que já não existe NÃO derruba pfx-ab (o tmux casaria por prefixo)"
  pv stop pfx-ab </dev/null
  # stop só diz que parou se a sessão sumiu: um tmux que não derruba (um falso na frente do verdadeiro no PATH do "host") é erro
  real=$(command -v tmux); mkdir -p "$T/home/.local/bin"
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in kill-session|list-panes) exit 1;; esac; done\nexec %s "$@"\n' "$real" > "$T/home/.local/bin/tmux"; chmod +x "$T/home/.local/bin/tmux"
  pv start live-st < <(req "cat"); pv stop live-st </dev/null; r1=$RC
  [ $r1 = 1 ] && has "$T/err" 'continua aberta' && [ "$(count)" = 1 ]; ok $? "live: stop de uma sessão que o tmux não derruba é ERRO e a sessão segue lá, não 'parou' (rc=$r1)"
  rm -f "$T/home/.local/bin/tmux"; pv stop live-st </dev/null; [ $RC = 0 ] && [ "$(count)" = 0 ]; ok $? "live: ...e com o tmux de verdade o mesmo stop derruba"
}

g_cap() {
  cfg 2; fresh
  pv start c-1 < <(req cat); pv start c-2 < <(req cat); pv start c-3 < <(req cat)
  [ $RC = 1 ] && has "$T/err" 'teto' && has "$T/err" 'host a'; ok $? "cap: com teto 2, a 3ª sessão NÃO abre e o erro diz o teto (rc=$RC)"
  [ "$(count)" = 2 ]; ok $? "cap: o host tem exatamente 2 sessões"
  pv start c-1 < <(req cat); [ $RC = 1 ] && has "$T/err" 'already exists'; ok $? "cap: nome que já existe → 'already exists' (vira ErrSessionExists no engine)"
  pv stop c-1 </dev/null; pv start c-3 < <(req cat); ok $RC "cap: parar libera a vaga"
  GC_SSH_HOST=b pv start b-1 < <(req cat); [ $RC = 0 ]; ok $? "cap: o teto é POR host — o host b conta à parte (rc=$RC)"
  GC_SSH_HOST=b pv start b-2 < <(req cat); [ $RC = 1 ] && has "$T/err" 'teto'; ok $? "cap: host b com teto 1 recusa a 2ª"
  [ "$(count)" = 2 ] && [ "$(count x "${SOCK}b")" = 1 ]; ok $? "cap: contagens separadas (a=2, b=1)"
  for s in c-2 c-3; do pv stop $s </dev/null; done; GC_SSH_HOST=b pv stop b-1 </dev/null
  cfg 2; rm -f "$T/times"; : > "$T/times"
  for i in 1 2 3 4; do (FAKE_SSH_TIMES="$T/times" env HOME="$T/home" GC_SSH_CONFIG="$T/cfg.json" GC_SSH_BIN="$T/bin/ssh" GC_EXEC_STATE_DIR="$T/state" FAKE_SSH_TIMES="$T/times" "$P" start par-$i < <(req cat) >/dev/null 2>&1; echo $? >> "$T/par.rc") & done; wait
  [ "$(count)" = 2 ] && [ "$(grep -c '^0$' "$T/par.rc")" = 2 ]; ok $? "cap: 4 starts em paralelo com teto 2 abrem exatamente 2 (abriu $(count))"
  python3 - "$T/times" <<'EOF'
import sys
ev = sorted((float(l.split()[2]), l.split()[0]) for l in open(sys.argv[1]) if len(l.split()) == 3)
depth = peak = 0
for _, k in ev:
    depth += 1 if k == "B" else -1
    peak = max(peak, depth)
sys.exit(0 if peak == 1 else 1)
EOF
  ok $? "cap: as execuções remotas dos starts não se sobrepõem (flock no mini)"
  for i in 1 2 3 4; do pv stop par-$i </dev/null; done
}

g_down() {
  cfg 3; fresh
  FAKE_SSH_FAIL=1 pv start d-1 < <(req cat); [ $RC = 1 ] && has "$T/err" 'host a' && has "$T/err" 'Connection timed out'; ok $? "down: ssh fora do ar → start recusa e a mensagem diz o host e o motivo (rc=$RC)"
  FAKE_SSH_FAIL=1 pv list-running d </dev/null; [ $RC = 1 ] && [ ! -s "$T/out" ]; ok $? "down: list-running com ssh fora é ERRO, não lista vazia"
  FAKE_SSH_FAIL=1 pv is-running d-1 </dev/null; [ $RC = 1 ]; ok $? "down: is-running com ssh fora é erro"
  FAKE_SSH_FAIL=1 pv stop d-1 </dev/null; [ $RC = 1 ]; ok $? "down: stop com ssh fora é erro (não finge ter parado)"
  has "$T/state/a/session-ssh.log" 'start d-1 FALHOU'; ok $? "down: o erro fica registrado em <estado>/session-ssh.log"
  [ "$(count)" = 0 ] && [ ! -e "$RR/run/d-1.sh" ]; ok $? "down: nada pela metade (sem sessão, sem lançador)"
  FAKE_SSH_FAIL=1 pv set-meta d-1 k < <(printf v) && FAKE_SSH_FAIL=1 pv get-meta d-1 k </dev/null; [ "$(cat "$T/out")" = v ]; ok $? "down: meta (no mini) segue funcionando com o servidor fora"
  cfg 3 2; FAKE_SSH_HANG=1 pv start d-2 < <(req cat); [ $RC = 1 ] && has "$T/err" 'não respondeu'; ok $? "down: ssh mudo → start desiste no prazo e diz que o host não respondeu"
  cfg 3; FAKE_SSH_JUNK=1 pv is-running d-1 </dev/null; [ $RC = 1 ] && has "$T/err" 'sem marcadores'; ok $? "down: resposta sem marcadores é erro (não vira 'false')"
  FAKE_SSH_CUT=1 pv list-running d </dev/null; [ $RC = 1 ] && has "$T/err" 'sem marcadores'; ok $? "down: resposta cortada (sem o marcador de fim) é erro"
  pv start d-3 < <(req cat); FAKE_SSH_NOISE=1 pv is-running d-3 </dev/null; [ "$(cat "$T/out")" = true ]; ok $? "down: ruído de .bashrc antes da resposta não vira dado"
  pv stop d-3 </dev/null
  pv list-running d </dev/null; [ $RC = 0 ] && [ ! -s "$T/out" ]; ok $? "down: com o ssh de volta, a lista está limpa"
}

g_meta() {
  cfg 3
  pv set-meta m-1 chave.um < <(printf 'valor 1'); ok $RC "meta: set-meta"
  pv get-meta m-1 chave.um </dev/null; [ "$(cat "$T/out")" = 'valor 1' ]; ok $? "meta: get-meta devolve o valor"
  pv get-meta m-1 outra </dev/null; [ $RC = 0 ] && [ ! -s "$T/out" ]; ok $? "meta: chave ausente = vazio, rc 0"
  pv remove-meta m-1 chave.um </dev/null; pv get-meta m-1 chave.um </dev/null; [ ! -s "$T/out" ]; ok $? "meta: remove-meta"
  pv get-meta m-1 '../x' </dev/null; [ $RC = 1 ]; ok $? "meta: chave com '..' ou '/' recusa"
  pv set-meta m-2 k < <(printf 'v'); pv stop m-2 </dev/null; pv get-meta m-2 k </dev/null; [ ! -s "$T/out" ]; ok $? "meta: stop limpa o meta da sessão"
  pv set-meta m-3 k < <(printf 'SEGREDO-DO-META'); ! grep -rq 'SEGREDO-DO-META' "$T/remote" 2>/dev/null; ok $? "meta: o valor fica no mini, não no 'servidor'"
}

g_conf() {
  local good; cfg 3; good=$(cat "$T/cfg.json")
  rm -f "$T/cfg.json"; fresh; pv is-running x </dev/null; [ $RC = 1 ] && has "$T/err" 'sem configuração' && nossh; ok $? "conf: config ausente → exit 1 dizendo onde procurou, sem ssh"
  echo "$good" | jq 'del(.hosts.a.cap)' > "$T/cfg.json"; fresh; pv is-running x </dev/null; [ $RC = 1 ] && has "$T/err" "'cap'" && nossh; ok $? "conf: sem cap não abre nem consulta (não há teto padrão)"
  echo "$good" | jq '.hosts.a.cap=0' > "$T/cfg.json"; pv start c-0 < <(req cat); [ $RC = 1 ] && has "$T/err" "'cap'"; ok $? "conf: cap 0 recusa"
  echo "$good" | jq '.hosts.a.cap="3"' > "$T/cfg.json"; pv is-running x </dev/null; [ $RC = 1 ]; ok $? "conf: cap como texto recusa"
  echo "$good" | jq '.hosts.a.ssh="-oProxyCommand=x"' > "$T/cfg.json"; fresh; pv is-running x </dev/null; [ $RC = 1 ] && nossh; ok $? "conf: destino ssh começando com '-' recusa (injeção de opção)"
  echo "$good" | jq '.hosts.a.remote_root="/home/a b"' > "$T/cfg.json"; fresh; pv is-running x </dev/null; [ $RC = 1 ] && nossh; ok $? "conf: raiz remota com espaço recusa"
  echo "$good" > "$T/cfg.json"; GC_SSH_HOST=nao-existe pv is-running x </dev/null; [ $RC = 1 ] && has "$T/err" 'nao-existe'; ok $? "conf: host desconhecido recusa dizendo o nome"
  for bad in 'a;b' 'a b' '../x' '' 'a$(x)'; do fresh; pv is-running "$bad" </dev/null; [ $RC = 1 ] && nossh; ok $? "conf: nome de sessão inválido '$bad' recusa sem ssh"; done
}

g_guard() {
  cfg 3; fresh
  pv start g-1 < <(req "/Users/outro/bin/x --y"); [ $RC = 1 ] && has "$T/err" 'caminho do mini' && nossh; ok $? "guard: caminho do mini no comando recusa, sem ssh (rc=$RC)"
  pv start g-2 < <(req "claude" "/Users/outro/trab"); [ $RC = 1 ] && has "$T/err" 'work_dir' && nossh; ok $? "guard: work_dir fora das regras com /Users/ recusa"
  pv start g-3 < <(req "claude" | jq '.env.GC_X="/Users/outro/x"'); [ $RC = 1 ] && has "$T/err" 'env GC_X' && nossh; ok $? "guard: env com caminho do mini recusa"
  pv --dry-run start g-4 < <(req "claude" | jq '.env.GC_X="/Users/test/gt/.city/x"'); [ $RC = 0 ]; ok $? "guard: caminho que as regras sabem reescrever NÃO é recusado"
  [ "$(count)" = 0 ]; ok $? "guard: nenhuma sessão aberta"
}

g_terr() {  # o tmux do host responde mas não consegue olhar (socket sem permissão): "não sei" não vira "false", "lista vazia" nem "tem vaga"
  [ "$(id -u)" != 0 ] || { echo "skip terr: root ignora chmod"; return 0; }
  cfg 2; fresh; local sd="$TMUX_TMPDIR/tmux-$(id -u)" r1 op
  pv start te-1 < <(req cat); ok $RC "terr: (preparo) uma sessão aberta (rc=$RC)"
  chmod 000 "$sd"
  pv is-running te-1 </dev/null; r1=$RC; [ $r1 = 1 ] && [ ! -s "$T/out" ] && has "$T/err" 'Permission denied'; ok $? "terr: is-running com tmux sem acesso é ERRO dizendo o motivo, não 'false' (rc=$r1)"
  pv list-running te </dev/null; [ $RC = 1 ] && [ ! -s "$T/out" ]; ok $? "terr: list-running com tmux sem acesso é erro, não lista vazia"
  pv process-alive te-1 < <(printf 'cat\n'); [ $RC = 1 ] && [ ! -s "$T/out" ]; ok $? "terr: process-alive com tmux sem acesso é erro, não 'false'"
  pv start te-2 < <(req cat); [ $RC = 1 ] && has "$T/err" 'Permission denied'; ok $? "terr: start com tmux sem acesso recusa dizendo o motivo (não conta 0 sessões)"
  for op in interrupt clear-scrollback get-last-activity; do pv $op te-1 </dev/null; [ $RC = 1 ] && [ ! -s "$T/out" ]; ok $? "terr: $op com tmux sem acesso é erro (não finge ter feito)"; done
  pv nudge te-1 < <(printf x); [ $RC = 1 ]; ok $? "terr: nudge com tmux sem acesso é erro (não finge ter entregue)"
  pv send-keys te-1 k </dev/null; [ $RC = 1 ]; ok $? "terr: send-keys com tmux sem acesso é erro"
  pv peek te-1 5 </dev/null; [ $RC = 1 ] && [ ! -s "$T/out" ]; ok $? "terr: peek com tmux sem acesso é erro, não tela vazia"
  pv stop te-1 </dev/null; [ $RC = 1 ]; ok $? "terr: stop com tmux sem acesso é erro (não finge ter parado)"
  chmod 700 "$sd"
  [ "$(count)" = 1 ]; ok $? "terr: ...e nada foi aberto (só a sessão de antes)"
  pv is-running te-1 </dev/null; [ "$(cat "$T/out")" = true ]; ok $? "terr: com o acesso de volta, is-running volta a dizer true"
  pv stop te-1 </dev/null
}

g_gate() {  # a sessão REAL só abre com a liberação E o guarda conferido no host; a de teste abre sempre
  local good rb nm h st
  cfg 3; good=$(cat "$T/cfg.json"); fresh
  # sem liberação e sem guarda no host: só a sessão de teste abre
  echo "$good" | jq 'del(.hosts.a.real_sessions_released_by)' > "$T/cfg.json"; find "$RH/.claude" -mindepth 1 -delete 2>/dev/null
  for nm in remote-e2e-1 remote-test-x_Y-2; do pv start $nm < <(req cat); ok $RC "gate: $nm (sessão mínima de teste) abre sem liberação e sem guarda no host (rc=$RC $(head -c 150 "$T/err"))"; pv stop $nm </dev/null; done
  # com o guarda bom no host, mas sem liberação: a real não abre
  install_host; fresh
  pv start g-real < <(req cat); [ $RC = 1 ] && has "$T/err" 'real_sessions_released_by' && has "$T/err" 'g-real' && nossh && [ "$(count)" = 0 ]; ok $? "gate: sessão real SEM a chave de liberação recusa dizendo a chave, sem ssh e sem abrir (rc=$RC)"
  for rb in '""' '"   "' 'true' '1' 'null' '[]' '{"a":1}'; do
    echo "$good" | jq ".hosts.a.real_sessions_released_by=$rb" > "$T/cfg.json"; fresh
    pv start g-real < <(req cat); [ $RC = 1 ] && has "$T/err" 'real_sessions_released_by' && nossh && [ "$(count)" = 0 ]; ok $? "gate: liberação $rb não é liberação (só texto não vazio), recusa sem ssh"
  done
  # nomes que PARECEM de teste mas não são
  echo "$good" | jq 'del(.hosts.a.real_sessions_released_by)' > "$T/cfg.json"
  for nm in remote-e2e- remote-e2e1 my-remote-e2e-1 remote-e2e remote-testing-1 Remote-E2E-1 remote-test remote_e2e-1 dog-remote-test-1; do
    fresh; pv start $nm < <(req cat); [ $RC = 1 ] && has "$T/err" 'real_sessions_released_by' && nossh; ok $? "gate: '$nm' NÃO é sessão de teste (nome exato remote-e2e-<x> / remote-test-<x>) e recusa (rc=$RC)"
  done
  # com a liberação, o host decide
  echo "$good" > "$T/cfg.json"
  fresh; pv start g-ok < <(req cat); ok $RC "gate: liberada + guarda idêntico + settings aprovadas → a sessão real abre (rc=$RC $(head -c 200 "$T/err"))"
  pv is-running g-ok </dev/null; [ "$(cat "$T/out")" = true ]; ok $? "gate: ...e está de pé"; pv stop g-ok </dev/null
  find "$RH/.claude/hooks" -name "$GUARDF" -delete
  fresh; pv start g-nog < <(req cat); [ $RC = 1 ] && has "$T/err" 'ausente ou diferente' && [ "$(count)" = 0 ] && [ ! -e "$RR/run/g-nog.sh" ]; ok $? "gate: guarda AUSENTE no host → recusa dizendo o guarda, nada aberto, nenhum lançador (rc=$RC)"
  install_host; printf '\n# adulterado\n' >> "$RH/.claude/hooks/$GUARDF"
  fresh; pv start g-dif < <(req cat); [ $RC = 1 ] && has "$T/err" 'ausente ou diferente' && [ "$(count)" = 0 ]; ok $? "gate: guarda do host DIFERENTE do repositório (1 linha a mais) → recusa (rc=$RC)"
  install_host; st="$RH/.claude/settings.json"; h=$(cat "$st")
  local mut='sem o || exit 2 (falha aberta)@@.hooks.PreToolUse|=map(.hooks|=map(.command|=sub(" \\|\\| exit 2$";"")))
sem o grupo de Edit/Write@@.hooks.PreToolUse|=map(select(.matcher=="Bash"))
sem o grupo de Bash@@.hooks.PreToolUse|=map(select(.matcher!="Bash"))
sem MultiEdit na lista@@.hooks.PreToolUse[1].matcher="Edit|Write|NotebookEdit"
com disableAllHooks@@.disableAllHooks=true
chamando outro guarda@@.hooks.PreToolUse|=map(.hooks|=map(.command|=sub("remote-clone-guard";"outro-guard")))
sem hooks nenhum@@del(.hooks)'
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue; d=${ln%%@@*}; expr=${ln#*@@}
    printf '%s' "$h" | jq "$expr" > "$st"; fresh
    pv start g-set < <(req cat); [ $RC = 1 ] && has "$T/err" 'selfcheck' && [ "$(count)" = 0 ]; ok $? "gate: settings do host $d → o --selfcheck reprova e nada abre (rc=$RC $(head -c 120 "$T/err"))"
  done <<< "$mut"
  printf '{ isto não é json' > "$st"; fresh; pv start g-set < <(req cat); [ $RC = 1 ] && has "$T/err" 'selfcheck' && [ "$(count)" = 0 ]; ok $? "gate: settings do host ilegíveis (JSON quebrado) → recusa"
  rm -f "$st"; fresh; pv start g-set < <(req cat); [ $RC = 1 ] && has "$T/err" 'selfcheck' && [ "$(count)" = 0 ]; ok $? "gate: settings do host AUSENTES → recusa"
  install_host
  # o provider precisa do guarda do repositório para conferir o do host; sem ele não há como conferir → recusa antes de qualquer ssh
  mkdir -p "$T/noguard"; cp "$P" "$T/noguard/gc-session-ssh"; chmod +x "$T/noguard/gc-session-ssh"; fresh
  ( P="$T/noguard/gc-session-ssh"; pv start g-nogi < <(req cat); [ $RC = 1 ] && has "$T/err" 'não consegui ler' && nossh && [ "$(count)" = 0 ] ); ok $? "gate: sem o guarda do repositório ao lado do provider, a real recusa antes de qualquer ssh"
  ( P="$T/noguard/gc-session-ssh"; pv start remote-e2e-9 < <(req cat); RCX=$RC; pv stop remote-e2e-9 </dev/null; exit $RCX ); ok $? "gate: ...mas a de teste abre (não depende do guarda)"
  find "$T/noguard" -mindepth 1 -delete; rmdir "$T/noguard"
  cfg 3; install_host
}

all() { group proto && g_proto; group dry && g_dry; group live && g_live; group cap && g_cap; group down && g_down; group meta && g_meta; group conf && g_conf; group guard && g_guard; group terr && g_terr; group gate && g_gate; return 0; }

if [ -n "${GCSSH_MUTANT:-}" ]; then all; echo "RESULT $fails/$n"; exit $((fails > 0)); fi
all
echo "== $((n-fails))/$n ok =="

[ -n "${GCSSH_NO_MUTANTS:-}" ] || [ -n "${GCSSH_ONLY:-}" ] || {
  echo "-- controle negativo: cada guarda removida TEM que fazer o grupo que a cobre falhar"
  mutant() {  # mutant GRUPOS DESCRIÇÃO SED-EXPR  (a cópia mutada tem que diferir do original, senão o mutante não testou nada)
    local m="$T/mut.$RANDOM"; mkdir -p "$m"; sed -e "$3" "$P" > "$m/gc-session-ssh"; chmod +x "$m/gc-session-ssh"; cp "$(dirname "$P")/$GUARDF" "$m/$GUARDF" 2>/dev/null
    if cmp -s "$P" "$m/gc-session-ssh"; then ok 1 "mutante '$2': o sed não mudou nada (o teste do mutante está errado)"; return; fi
    local r; r=$(GCSSH_MUTANT=1 GCSSH_ONLY="$1" GCSSH_UNDER_TEST="$m/gc-session-ssh" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$2' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$2' pego ($r)";; *) ok 1 "mutante '$2': execução sem resultado ($r)";; esac
  }
  mutant cap "teto do host" 's/\[ "\$n" -lt @CAP@ \]/true/'
  mutant live "nome exato (sessão)" 's/return q("=" + name)  # sessão/return q(name)  # sessão/'
  mutant live "nome exato no is-running (grep -x do has)" 's/grep -qxF -- "\$1"/grep -qF -- "$1"/'
  mutant live "nome exato no start (grep -x do 'já existe')" 's/grep -qxF -- @NAME@/grep -qF -- @NAME@/'
  mutant live "alvo de painel (=nome:)" 's/return q("=" + name + ":")/return q("=" + name)/'
  mutant guard "guarda de /Users/" 's/if "\/Users\/" in v:/if False:/'
  mutant dry "filtro de env" 's/ or (SECRETISH.search(k) and k not in cfg.env_allow)//;s/not ENV_OK.fullmatch(k)/False/'
  mutant proto "exit 2 das desconhecidas" 's/        return 2$/        return 0/'
  mutant down "marcador de fim" 's/if BEGIN not in lines or END not in lines:/if BEGIN not in lines:/'
  mutant down "erro de ssh (rc 255)" 's/if p.returncode == 255:/if False:/'
  mutant cap "flock no mini" 's/fcntl.flock(lf, fcntl.LOCK_EX)/pass/'
  mutant terr "tmux sem acesso tolerado como 'sem servidor'" 's/\*"error connecting to"\*"(No such file or directory)"\*/*"error connecting to"*/'
  mutant terr "has engole o erro do tmux (vira 'false')" 's/s=\$(sessions) || return 2;/s=$(sessions);/'
  mutant live "melhor esforço: sessão ausente passa a dar erro" 's/\[ "\$r" -ne 1 \] || exit 0;/true;/'
  mutant live "stop não confere que a sessão sumiu" 's/\[ \$? -eq 1 \] || { echo "sessão @NAME@ continua/true || { echo "sessão @NAME@ continua/'
  mutant gate "sem a chave de liberação" 's/    if not cfg.released:/    if False:/'
  mutant gate "liberação de qualquer tipo (str() em vez de só texto)" 's/rb.strip() if isinstance(rb, str) else ""/str(rb).strip() if rb is not None else ""/'
  mutant gate "nome de teste sem o hífen (remote-e2e1 vira teste)" 's/remote-(?:e2e|test)-\[A-Za-z0-9_-\]+/remote-(?:e2e|test)[A-Za-z0-9_-]*/'
  mutant gate "nome de teste sem âncora (my-remote-e2e-1 vira teste)" 's/if TEST_RE.fullmatch(name):/if TEST_RE.search(name):/'
  mutant gate "sem conferir o sha do guarda" 's/\[ "\$h" = {sha} \] ||/true ||/'
  mutant gate "sem rodar o --selfcheck" 's/o=\$(python3 -I {g} --selfcheck {st} 2>&1)/o=$(true)/'
  mutant gate "script do host que sai 0 (a recusa vira 'abriu')" 's/exit {EX_POLICY}/exit 0/g'
  mutant gate "guarda do repositório ilegível passa" 's/^        raise Fail(f"sessão real {name!r} recusada: não consegui ler.*$/        sha = ""/'
  mutant dry "o dry-run diz 'teste' para tudo" 's/session_kind="teste" if TEST_RE.fullmatch(name) else "real"/session_kind="teste"/'
  echo "-- contra um stub que só sai 0 (a versão 'anterior' não tinha provider nenhum)"
  printf '#!/bin/sh\nexit 0\n' > "$T/stub"; chmod +x "$T/stub"
  r=$(GCSSH_MUTANT=1 GCSSH_ONLY="proto,dry,cap,down,conf,guard,gate" GCSSH_UNDER_TEST="$T/stub" bash "$0" 2>&1 | tail -1); echo "stub: $r"
  case "$r" in "RESULT 0/"*|"") ok 1 "stub deveria falhar quase tudo ($r)";; *) ok 0 "stub falha os casos novos ($r)";; esac
  echo "== final: $((n-fails))/$n ok =="
}
[ "$fails" = 0 ]
