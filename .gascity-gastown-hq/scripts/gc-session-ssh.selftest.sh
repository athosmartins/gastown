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
#   teste (remote-e2e-<x>, remote-test-<x>, e só ela) abre sempre; o dry-run diz qual é qual; o resto dos grupos roda COM o portão ligado e satisfeito ·
#   mbp (ga-w7qwl1) — host de presença (notebook que dorme): `presence_gate`/`sleeps`/`path_extra` validados na config; start só abre com a regra de
#   presença livre (pausa, bandeira, slot_cap e vigia de prioridade), a política local do guarda de clone vale ANTES dela; list-running tolera host
#   que dorme e mantém o registro de sessões; recusa clara do host limpa o registro; /Users/ de outro home recusa.
#   prep (ga-2hd02v.1.5.9) — o start grava a identidade git POR worktree e a confiança da pasta em ~/.claude.json do host, e qualquer falha derruba o start sem abrir nada: espelho BARE (sem
#   extensions.worktreeConfig: o core.bare sai do config compartilhado e o commit do worktree continua funcionando, autor = a sessão), modo 600 e o resto do arquivo preservados, idempotente, uma identidade por
#   worktree; pasta ausente / comum, ~/.claude.json ausente / ilegível (intacto, byte a byte) / com forma estranha, config.worktree travado, identidade que o git não lê de volta → exit 1 com o motivo, nenhum
#   lançador, a pasta ausente não vira diretório; dry-run mostra o `prepare`; worktree_prepare explícito nos dois sentidos, padrão LIGADO no servidor e DESLIGADO no host de presença (notebook), não-booleano recusa sem ssh.
#   wt (ga-2hd02v.1.7 e 1.8) — o start cria o worktree da sessão (wt-add) e o stop o recolhe (wt-rm) SÓ quando nada se perde: papel mapeado em `worktree_rigs` abre DENTRO do worktree do wt-add (com identidade e
#   confiança), o guarda de clone olha o worktree JÁ criado, wt-add / preparo / guarda que falham deixam o host como estava, teto e 'já existe' recusam ANTES de criar; o stop recolhe o limpo e publicado e MANTÉM
#   o sujo, o não publicado e o que o git não consegue ler (e nunca muda o rc do stop); papel sem mapa e host sem a chave = como antes; nomes que o engine gera (dog-remote-<cauda>, dog-remote-adhoc-<10>) não são
#   pedido de host (host fora da config no meio do nome segue recusando); o identity_pattern do runbook casa com eles e só com eles; contrato com o hetzner-remote-git.sh de verdade (caminhos e formatos).
# CONTROLE NEGATIVO: cada guarda é removida do script (sed numa cópia) e o grupo que a cobre TEM que passar a falhar: teto do host, nome
#   exato (sessão, is-running, start), alvo de painel =nome:, guarda de /Users/, filtro de env, exit 2 das desconhecidas, marcador de fim,
#   erro de ssh, flock, "tmux sem acesso" tolerado como "sem servidor", o `has` que engole o erro do tmux, melhor esforço da sessão
#   ausente, o stop que não confere que a sessão sumiu, e o portão (sem a liberação, liberação de qualquer tipo, nome de teste frouxo ou sem
#   âncora, sem conferir o sha do guarda, sem rodar o --selfcheck, script do host que sai 0, guarda irmão ilegível), e a regra de presença do MBP (grupo mbp: guarda de /Users/, validação da config, recusa/pausa/slot_cap, vigia, PATH extra,
#   registro de sessões do list-running); 99 mutantes no total (26 do grupo wt: wt-add/wt-rm do provider, o guarda DEPOIS do wt-add, o recolhimento só do que não perde trabalho e os nomes do engine; 9 do ambiente limpo da sessão, grupo mbp: session_env, ZDOTDIR, PATH explícito e claude absoluto, ga-w7qwl1.1.5).
#   Mais: contra um stub que só sai 0, quase tudo falha.
# VARIÁVEIS: GCSSH_UNDER_TEST (script a testar) · GCSSH_ONLY (grupos separados por vírgula) · GCSSH_NO_MUTANTS=1
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${GCSSH_UNDER_TEST:-$HERE/gc-session-ssh}"
for v in $(env | sed -n 's/^\(GC_[A-Za-z0-9_]*\)=.*/\1/p') TMUX TMUX_PANE GC_SSH_HOST GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do unset "$v"; done  # + a identidade git do ambiente: o runner do nó exporta GIT_AUTHOR_*=gt, que vence o config do worktree e fazia o teste 'autor certo' do grupo prep reprovar no Linux (medido 18/10)  # o "servidor" é esta máquina: nada do ambiente de quem roda (ex.: GC_INSTANCE_TOKEN) pode vazar para as sessões de teste
T=$(cd "$(mktemp -d /tmp/gcs.XXXXXX)" && pwd -P)  # curto: o caminho do socket do tmux tem limite de ~100 caracteres
SOCK="gct$$"
export TMUX_TMPDIR="$T/tmux"; mkdir -p "$TMUX_TMPDIR" "$T/bin" "$T/home" "$T/remote/home" "$T/state"
cleanup() { for s in "$SOCK" "${SOCK}b" "${SOCK}m"; do tmux -L "$s" kill-server 2>/dev/null; done; chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
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
[ -z "${FAKE_SSH_FAIL_HOST:-}" ] || [ "$FAKE_SSH_FAIL_HOST" != "$1" ] || { echo "ssh: connect to host $1 port 22: Operation timed out" >&2; exit 255; }
[ -z "${FAKE_SSH_CUT_HOST:-}" ] || [ "$FAKE_SSH_CUT_HOST" != "$1" ] || FAKE_SSH_CUT=1
shift
[ -z "${FAKE_SSH_NOISE:-}" ] || echo "bashrc: bem-vindo ao servidor"
[ -z "${FAKE_SSH_DELAY:-}" ] || sleep "$FAKE_SSH_DELAY"  # ssh lento: o comando só roda depois de N s
if [ -n "${FAKE_SSH_JUNK:-}" ]; then cat >/dev/null; echo "saida sem marcadores"; exit 0; fi
[ -z "${FAKE_SSH_TIMES:-}" ] || echo "B $$ $(python3 -c 'import time;print(time.time())')" >> "$FAKE_SSH_TIMES"
if [ -n "${FAKE_SSH_CUT:-}" ]; then sh -c "$*" | grep -v '@@GC-END@@'; exit 0; fi
if [ -n "${FAKE_SSH_RAN_255:-}" ]; then sh -c "$*" >/dev/null 2>&1; echo "Connection reset by peer" >&2; exit 255; fi  # o script RODOU no host, a conexão caiu depois
sh -c "$*"; rc=$?
[ -z "${FAKE_SSH_TIMES:-}" ] || echo "E $$ $(python3 -c 'import time;print(time.time())')" >> "$FAKE_SSH_TIMES"
exit $rc
EOF
chmod +x "$T/bin/ssh"

cfg() {  # cfg CAP [TIMEOUT] [EXTRA-JSON-do-host-a]  → $T/cfg.json (host a: socket $SOCK; host b: socket ${SOCK}b, teto 1)
  jq -n --argjson cap "$1" --argjson to "${2:-25}" --argjson extra "${3:-{\}}" --arg rr "$RR" --arg rh "$RH" --arg s "$SOCK" \
    '{default_host:"a", hosts:{a:({ssh:"fakehost",cap:$cap,remote_root:$rr,remote_home:$rh,socket:$s,mini_home:"/Users/test",timeout:$to,start_timeout:$to,real_sessions_released_by:"selftest",worktree_prepare:false}+$extra),
      b:{ssh:"fakehost",cap:1,remote_root:$rr,remote_home:$rh,socket:($s+"b"),mini_home:"/Users/test",real_sessions_released_by:"selftest",worktree_prepare:false}}}' > "$T/cfg.json"
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
  local wpool="claude --settings '{\"remoteControlAtStartup\":false}' --model sonnet --strict-mcp-config --dangerously-skip-permissions --effort xhigh --settings $RR/city/settings.json --session-id 1a9a7c40-03ef-4caa-8412-df9368f6a538"
  local crew="claude --remote-control --model opus --dangerously-skip-permissions --effort high --settings $CITY/.gc/settings.json --session-id 77d574bf-bb7f-4ae1-be33-6f72cf73b68a"
  local wcrew="claude --remote-control --model opus --dangerously-skip-permissions --effort high --settings $RR/city/settings.json --session-id 77d574bf-bb7f-4ae1-be33-6f72cf73b68a"
  fresh; pv --dry-run start dog-1 < <(req "$pool"); local got; got=$(jq -r .command "$T/out" 2>/dev/null)
  [ $RC = 0 ] && [ "$got" = "$wpool" ]; ok $? "dry: comando do pool = o local com a cidade e o --settings reescritos (mesmos itens, mesma ordem), e o lançador do mini vira claude no host"
  has "$T/out" '--dangerously-skip-permissions' && has "$T/out" '--model sonnet' && has "$T/out" 'remoteControlAtStartup'; ok $? "dry: --dangerously-skip-permissions, --model e o --settings inline do pool presentes"
  ! echo "$got" | grep -q -- '--remote-control'; ok $? "dry: pool não ganha --remote-control que não pediu"
  fresh; pv --dry-run start dog-1 < <(req "$CITY/packs/town-deltas/assets/scripts/claude-lowprio.sh --x"); [ "$(jq -r .command "$T/out")" = "claude --x" ]; ok $? "dry: o lançador claude-lowprio.sh também vira claude no host"
  for c in "$CITY/packs/town-deltas/assets/scripts/claude-ctxcap-ab.sh.bak --x|$RR/city/packs/town-deltas/assets/scripts/claude-ctxcap-ab.sh.bak --x" \
           "$CITY/packs/outro/assets/scripts/claude-ctxcap-ab.sh --x|$RR/city/packs/outro/assets/scripts/claude-ctxcap-ab.sh --x" \
           "env X=1 $CITY/packs/town-deltas/assets/scripts/claude-ctxcap-ab.sh --x|env X=1 $RR/city/packs/town-deltas/assets/scripts/claude-ctxcap-ab.sh --x"; do
    fresh; pv --dry-run start dog-1 < <(req "${c%%|*}"); [ "$(jq -r .command "$T/out")" = "${c##*|}" ]; ok $? "dry: parecido com o lançador, mas não é: fica como veio (${c%%|*})"
  done
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
  # o dry-run diz o que o start de verdade faria com a recusa de política: sessão real sem liberação NÃO pode parecer que abriria (gate ga-iczduy)
  pv --dry-run start dog-1 < <(req claude); [ "$(jq -r .would_refuse "$T/out")" = null ]; ok $? "dry: sessão real liberada → would_refuse null"
  jq 'del(.hosts.a.real_sessions_released_by)' "$T/cfg.json" > "$T/cfg2.json" && mv "$T/cfg2.json" "$T/cfg.json"
  pv --dry-run start dog-1 < <(req claude); [ $RC = 0 ] && jq -e '.would_refuse | strings | test("real_sessions_released_by")' "$T/out" >/dev/null; ok $? "dry: sessão real SEM liberação → would_refuse diz a chave que falta (rc=$RC)"
  pv --dry-run start remote-e2e-1 < <(req claude); [ "$(jq -r .would_refuse "$T/out")" = null ]; ok $? "dry: sessão de teste sem liberação → would_refuse null (ela abre)"
  pv start dog-1 < <(req claude); [ $RC = 1 ]; ok $? "dry: (controle) o start de verdade dessa mesma sessão recusa (rc=$RC)"; cfg 3
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


# ---------- mbp: o MBP como host (ga-w7qwl1) — regra de presença no start, host pelo nome da sessão, vigia de prioridade, eventos ----------
cfgm() {  # cfgm [EXTRA-JSON-do-host-m]  → $T/cfg.json com a (padrão, sem regra), m (o "MBP": presença, PATH extra, dorme) e h (home em /Users, só dry-run)
  mkdir -p "$T/extra" "$T/lib"
  jq -n --argjson extra "${1:-{\}}" --arg rr "$RR" --arg rh "$RH" --arg s "$SOCK" --arg chk "$T/bin/fake-check" --arg lib "$T/lib/presence.sh" --arg ex "$T/extra" --arg sb "$T/shim-bin" --arg cl "$T/claude" \
    '{default_host:"a", hosts:{a:{ssh:"fakehost",cap:3,remote_root:$rr,remote_home:$rh,socket:$s,mini_home:"/Users/test",real_sessions_released_by:"selftest",worktree_prepare:false},
      m:({ssh:"fakembp",cap:2,remote_root:$rr,remote_home:$rh,socket:($s+"m"),mini_home:"/Users/test",presence_gate:true,sleeps:true,watch_s:1,
         gate_cmd:[$chk],presence_lib:$lib,path_extra:[$ex],session_env:{path:[$sb,"/usr/bin","/bin"],claude:$cl},real_sessions_released_by:"selftest"}+$extra),
      h:{ssh:"fakehost",cap:1,remote_root:"/Users/athos/gt-remote/bundle",remote_home:"/Users/athos",socket:($s+"h"),mini_home:"/Users/test",real_sessions_released_by:"selftest",worktree_prepare:false}}}' > "$T/cfg.json"
}
setup_mbp() {
  mkdir -p "$T/lib" "$T/extra"
  cat > "$T/bin/fake-check" <<EOF
#!/bin/sh
# falso do \`mbp-run.sh --check\`: a resposta vem do arquivo $T/chk.mode
case "\$(cat "$T/chk.mode" 2>/dev/null)" in
  livre)    printf 'presence=livre\npresence_why=bloqueada\npaused=0\npaused_local=0\noffload_flag=on\nslot_cap=%s\n' "\${SLOT:-3}"; exit 0 ;;
  slot1)    printf 'presence=livre\npresence_why=bloqueada\npaused=0\npaused_local=0\noffload_flag=on\nslot_cap=1\n'; exit 0 ;;
  uso)      printf 'presence=uso\npresence_why=input_recente\npaused=0\npaused_local=0\noffload_flag=on\nslot_cap=3\n'; exit 0 ;;
  pausado)  printf 'presence=livre\npaused=1\npaused_local=0\noffload_flag=on\nslot_cap=3\n'; exit 99 ;;
  semsaude) printf 'presence=livre\npaused=0\npaused_local=0\noffload_flag=on\nslot_cap=3\n'; exit 98 ;;
  pausalocal) printf 'presence=livre\npaused=0\npaused_local=1\noffload_flag=on\nslot_cap=3\n'; exit 0 ;;
  flagoff)  printf 'presence=livre\npaused=0\npaused_local=0\noffload_flag=off\nslot_cap=3\n'; exit 0 ;;
  semcap)   printf 'presence=livre\npaused=0\npaused_local=0\noffload_flag=on\n'; exit 0 ;;
  cap0)     printf 'presence=livre\npaused=0\npaused_local=0\noffload_flag=on\nslot_cap=0\n'; exit 0 ;;
  sempresenca) printf 'paused=0\npaused_local=0\noffload_flag=on\nslot_cap=3\n'; exit 0 ;;
  lixo)     echo banana; exit 0 ;;
  *)        exit 0 ;;   # vazio: saiu 0 sem dizer nada
esac
EOF
  chmod +x "$T/bin/fake-check"
  # biblioteca de presença falsa (o modo vem de $T/pres.mode, a pausa de $T/pres.pause): as mesmas variáveis da mbp-presence.sh de verdade
  printf 'presence_eval() { PR_MODE=$(cat "%s/pres.mode" 2>/dev/null || echo uso); PR_PAUSED=0; [ -e "%s/pres.pause" ] && PR_PAUSED=1; return 0; }\n' "$T" "$T" > "$T/lib/presence.sh"
  echo livre > "$T/pres.mode"; rm -f "$T/pres.pause"
  zdot_put "$T/shim-bin:/usr/bin:/bin"
}
zdot_put() {  # zdot_put PATH — os 4 arquivos que o remote-bundle-build.py --session-path instala em <raiz>/zdot (a linha do PATH é a que o provider confere)
  mkdir -p "$RR/zdot" "$T/shim-bin"; for f in .zshenv .zprofile .zshrc env.sh; do printf "export PATH='%s'\n" "$1" > "$RR/zdot/$f"; done
}
mode() { echo "$1" > "$T/chk.mode"; }
nicen() { ps -o nice= -p "$1" 2>/dev/null | tr -d ' '; }
wait_nice() {  # wait_nice PID MIN SEGUNDOS → 0 se o nice de PID chegou a MIN
  local i n; for i in $(seq 1 $(( $3 * 4 ))); do n=$(nicen "$1"); [ -n "$n" ] && [ "$n" -ge "$2" ] 2>/dev/null && return 0; sleep 0.25; done; return 1
}

g_mbp() {
  setup_mbp; cfgm; fresh; local pid i m
  # --- dry-run: o que o start do MBP leva ---
  mode livre; pv --dry-run start w-remote-m-0 < <(req "claude --x"); [ $RC = 0 ] && [ "$(jq -r .host "$T/out")" = m ]; ok $? "mbp: o nome w-remote-m-0 escolhe o host m (dry-run)"
  [ "$(jq -r '.gate[0]' "$T/out")" = "$T/bin/fake-check" ] && [ "$(jq -r '.path_extra[0]' "$T/out")" = "$T/extra" ]; ok $? "mbp: o dry-run mostra a checagem de presença e o PATH extra do host"
  jq -r '.launcher[]' "$T/out" | grep -q '^nice -n 10 sh -c '; ok $? "mbp: a sessão do MBP nasce em nice 10"
  jq -r '.launcher[]' "$T/out" | grep -q 'taskpolicy -b -p'; ok $? "mbp: o lançador leva o vigia que rebaixa a árvore (renice 19 + taskpolicy -b)"
  nossh; ok $? "mbp: dry-run não conecta nem consulta a presença"
  [ "$(jq -r '.session_env | "\(.path) \(.claude) \(.zdot)"' "$T/out")" = "$T/shim-bin:/usr/bin:/bin $T/claude $RR/zdot" ] && [ "$(jq -r .command "$T/out")" = "$T/claude --x" ]
  ok $? "mbp: o dry-run mostra a session_env e o claude do comando vira o caminho absoluto"
  L=$(jq -r '.launcher[]' "$T/out"); w=$(printf '%s\n' "$L" | grep -n '^bash -c' | cut -d: -f1); e=$(printf '%s\n' "$L" | grep -n '^export PATH=' | cut -d: -f1); r=$(printf '%s\n' "$L" | grep -n '^nice -n 10 sh -c' | cut -d: -f1)
  printf '%s\n' "$L" | grep -qxF "export ZDOTDIR=$RR/zdot" && printf '%s\n' "$L" | grep -qxF "export CLAUDE_ENV_FILE=$RR/zdot/env.sh" && printf '%s\n' "$L" | grep -qxF "export PATH=$T/shim-bin:/usr/bin:/bin" && [ "${w:-9}" -lt "${e:-0}" ] && [ "${e:-9}" -lt "${r:-0}" ]
  ok $? "mbp: o lançador exporta ZDOTDIR, CLAUDE_ENV_FILE e o PATH explícito DEPOIS do vigia (que usa o PATH do host) e ANTES do comando"
  pv --dry-run start w-1 < <(req "claude --x"); [ "$(jq -r .host "$T/out")" = a ] && [ "$(jq -r .gate "$T/out")" = null ] && ! jq -r '.launcher[]' "$T/out" | grep -q 'taskpolicy\|^nice '; ok $? "mbp: nome sem -remote- continua no host padrão, sem regra de presença nem vigia (o servidor Linux não muda)"
  pv --dry-run start w-remote-zz-1 < <(req "claude"); [ $RC = 1 ] && has "$T/err" "'zz'" && nossh; ok $? "mbp: nome que pede um host que a config não tem recusa dizendo qual, sem ssh"
  GC_SSH_HOST=a pv --dry-run start w-remote-m-1 < <(req "claude"); [ "$(jq -r .host "$T/out")" = a ]; ok $? "mbp: \$GC_SSH_HOST (decisão explícita de quem opera) vale mais que o nome"
  # --- /Users/ no home do próprio host: o do MBP vale, o de outro usuário não ---
  GC_SSH_HOST=h pv --dry-run start x-1 < <(req "claude --d /Users/test/trab" "$CITY/.gc/agents/dog" '{"env":{"GC_CITY":"'"$CITY"'","GC_HOME":"/Users/test/.gc"}}')
  [ $RC = 0 ] && [ "$(jq -r .env.GC_HOME "$T/out")" = /Users/athos/.gc ] && jq -r .command "$T/out" | grep -q -- '--d /Users/athos/trab'; ok $? "mbp: com home /Users/athos no host, o caminho do mini vira o do MBP e passa (rc=$RC $(head -c 150 "$T/err"))"
  GC_SSH_HOST=h pv --dry-run start x-2 < <(req "claude --d /Users/outro/trab"); [ $RC = 1 ] && has "$T/err" 'caminho do mini'; ok $? "mbp: /Users/ de OUTRO usuário continua recusado mesmo num host cujo home é /Users/..."
  # --- gate: só evidência positiva de "Athos fora e MBP saudável" abre sessão ---
  fresh; mode livre; pv start w-remote-m-1 < <(req cat); ok $RC "mbp: Athos fora e MBP saudável → o start abre (rc=$RC $(head -c 200 "$T/err"))"
  [ "$(count x "${SOCK}m")" = 1 ] && [ "$(count)" = 0 ]; ok $? "mbp: a sessão está no socket do host m, não no do padrão"
  jq -e 'select(.event=="started" and .host=="m" and .session=="w-remote-m-1")' "$T/state/m/events.jsonl" >/dev/null 2>&1; ok $? "mbp: o start deixa uma linha 'started' em <estado>/m/events.jsonl (insumo do placar)"
  [ -e "$T/state/m/running/w-remote-m-1" ]; ok $? "mbp: ...e registra a sessão como aberta por nós"
  for m in uso pausado semsaude pausalocal flagoff semcap cap0 sempresenca lixo vazio; do
    mode $m; fresh; pv start w-remote-m-9 < <(req cat); [ $RC = 1 ] && has "$T/err" 'não abro sessão nova' && nossh && [ "$(count x "${SOCK}m")" = 1 ]
    ok $? "mbp: checagem '$m' → start recusado, sem ssh e sem sessão nova (rc=$RC $(head -c 120 "$T/err"))"
  done
  mode uso; pv start w-remote-m-9 < <(req cat); has "$T/err" 'Athos está no MBP' && has "$T/err" 'input_recente'; ok $? "mbp: a recusa por uso diz que o Athos está no MBP e por quê"
  mode pausado; pv start w-remote-m-9 < <(req cat); has "$T/err" 'pausado'; ok $? "mbp: a recusa por pausa/bandeira (rc 99) diz isso"
  mode semsaude; pv start w-remote-m-9 < <(req cat); has "$T/err" 'sem saúde'; ok $? "mbp: a recusa por MBP sem saúde (rc 98) diz isso"
  jq -e 'select(.event=="refused" and .host=="m" and (.reason|test("Athos está no MBP")))' "$T/state/m/events.jsonl" >/dev/null 2>&1; ok $? "mbp: cada recusa vira linha 'refused' com o motivo no events.jsonl"
  mkdir -p "$T/noexec"; cfgm '{"gate_cmd":["'"$T"'/noexec/nao-existe"]}'; mode livre; fresh; pv start w-remote-m-9 < <(req cat); [ $RC = 1 ] && has "$T/err" 'não consegui rodar a checagem' && nossh; ok $? "mbp: checagem que não roda → recusa (não abre 'por falta de resposta')"
  cfgm; mode livre; pv start w-remote-m-2 < <(req cat); ok $RC "mbp: com tudo de volta ao normal, o próximo start abre sozinho"
  # --- o teto é o menor entre o do host e o slot_cap da checagem ---
  pv stop w-remote-m-2 </dev/null; pv stop w-remote-m-1 </dev/null; mode slot1; pv start w-remote-m-1 < <(req cat); pv start w-remote-m-2 < <(req cat)
  [ $RC = 1 ] && has "$T/err" 'teto' && [ "$(count x "${SOCK}m")" = 1 ]; ok $? "mbp: cap 2 no host, slot_cap 1 na checagem → a 2ª sessão não abre (vale o menor)"
  [ ! -e "$T/state/m/running/w-remote-m-2" ]; ok $? "mbp: start que o host recusou com clareza (teto) não fica no registro de sessões nossas"
  # --- gate <host>: o veredito de um start agora, sem abrir nada ---
  mode livre; fresh; pv gate m </dev/null; [ $RC = 0 ] && [ "$(jq -r .ok "$T/out")" = true ] && [ "$(jq -r .slot_cap "$T/out")" = 3 ] && [ "$(jq -r .cap "$T/out")" = 2 ]; ok $? "mbp: gate m com o Athos fora → ok, exit 0, com o slot_cap e o cap"
  mode uso; pv gate m </dev/null; [ $RC = 1 ] && [ "$(jq -r .ok "$T/out")" = false ] && jq -r .reason "$T/out" | grep -q 'Athos está no MBP'; ok $? "mbp: gate m com o Athos usando → exit 1 e o motivo"
  pv gate a </dev/null; [ $RC = 0 ] && jq -r .reason "$T/out" | grep -q 'não tem regra de presença'; ok $? "mbp: gate de um host sem regra de presença → ok (o servidor Linux não depende do Athos)"
  pv gate zz </dev/null; [ $RC = 1 ]; ok $? "mbp: gate de host desconhecido → exit 1"
  pv gate "" </dev/null; [ $RC = 2 ] && has "$T/err" 'falta o host'; ok $? "mbp: gate com host VAZIO → exit 2 (uso), não o veredito do default_host (gate ga-ie7fcr)"
  mode livre; pv --dry-run gate m </dev/null; [ $RC = 2 ] && [ "$(jq -r .ok "$T/out")" = null ]; ok $? "mbp: gate em dry-run num host com presença → exit 2 e ok=null (não 'libera')"
  mode livre; GC_SSH_DRYRUN=1 pv gate m </dev/null; [ $RC = 2 ]; ok $? "mbp: GC_SSH_DRYRUN=1 vazado → gate exit 2, não 'sempre libera'"
  [ "$(count x "${SOCK}m")" = 1 ]; ok $? "mbp: gate não abre nem fecha nenhuma sessão"
  # --- list-running: todos os hosts; o notebook dormindo não derruba a lista ---
  pv stop w-remote-m-1 </dev/null; pv start w-a-1 < <(req cat); mode livre; pv start w-remote-m-3 < <(req cat)
  pv list-running w- </dev/null; [ $RC = 0 ] && has "$T/out" w-a-1 && has "$T/out" w-remote-m-3; ok $? "mbp: list-running junta as sessões de todos os hosts"
  GC_SSH_HOST=m pv list-running w- </dev/null; [ "$(cat "$T/out")" = w-remote-m-3 ]; ok $? "mbp: \$GC_SSH_HOST fixa o list-running num host só"
  FAKE_SSH_FAIL_HOST=fakembp pv list-running w- </dev/null; [ $RC = 1 ] && has "$T/err" fakembp; ok $? "mbp: notebook fora do ar COM sessão nossa registrada → list-running é erro (não sei o que há lá)"
  pv stop w-remote-m-3 </dev/null; FAKE_SSH_FAIL_HOST=fakembp pv list-running w- </dev/null; [ $RC = 0 ] && has "$T/out" w-a-1 && has "$T/state/m/session-ssh.log" 'não conta'; ok $? "mbp: notebook fora do ar SEM sessão nossa → só ele sai da lista (a do servidor continua), e o log diz"
  pv stop w-a-1 </dev/null
  FAKE_SSH_FAIL_HOST=fakehost pv list-running w- </dev/null; [ $RC = 1 ] && has "$T/err" fakehost; ok $? "mbp: o host que NÃO dorme, fora do ar e sem sessão registrada, continua sendo erro (nunca lista vazia)"
  mode livre; pv start w-remote-m-4 < <(req cat); tmux -L "${SOCK}m" kill-session -t =w-remote-m-4 2>/dev/null; pv list-running w- </dev/null; [ ! -e "$T/state/m/running/w-remote-m-4" ]; ok $? "mbp: sessão que o host já não tem sai do registro quando o host responde (o registro se corrige sozinho)"
  touch -t 203001010000 "$T/state/m/running/w-remote-m-7"; pv list-running w- </dev/null; [ -e "$T/state/m/running/w-remote-m-7" ]; ok $? "mbp: registro mais novo que a pergunta (start em curso) não é apagado pelo list-running"
  rm -f "$T/state/m/running/w-remote-m-7"
  FAKE_SSH_CUT_HOST=fakembp pv list-running w- </dev/null; [ $RC = 1 ] && has "$T/err" 'sem marcadores'; ok $? "mbp: notebook que RESPONDEU cortado, mesmo sem sessão registrada, é erro (só 'não respondeu' sai da lista) (rc=$RC)"
  mode livre; FAKE_SSH_RAN_255=1 pv start w-remote-m-6 < <(req cat); [ $RC = 1 ] && [ -e "$T/state/m/running/w-remote-m-6" ]; ok $? "mbp: start ambíguo (o script rodou, o ssh caiu depois) fica no registro (rc=$RC)"
  FAKE_SSH_FAIL_HOST=fakembp pv list-running w- </dev/null; [ $RC = 1 ]; ok $? "mbp: ...e com o notebook fora do ar o list-running diz 'não sei' (erro), não 'nada nosso lá'"
  pv stop w-remote-m-6 </dev/null
  # --- PATH extra do host ---
  pv start w-remote-m-5 < <(req "sh -c 'echo \$PATH > $T/path.out; echo \$ZDOTDIR \$CLAUDE_ENV_FILE > $T/zd.out; exec cat'"); sleep 0.5
  [ "$(cat "$T/path.out" 2>/dev/null)" = "$T/shim-bin:/usr/bin:/bin" ]; ok $? "mbp: o PATH da sessão é EXATAMENTE o da session_env (atalho + pastas do sistema), sem o PATH do ssh nem ~/.local/bin"
  [ "$(cat "$T/zd.out" 2>/dev/null)" = "$RR/zdot $RR/zdot/env.sh" ]; ok $? "mbp: a sessão leva ZDOTDIR=<raiz>/zdot e CLAUDE_ENV_FILE=<raiz>/zdot/env.sh"
  case "$(tmux -L "${SOCK}m" show-environment -g PATH 2>&1)" in "PATH=$T/extra:"*) true;; *) false;; esac; ok $? "mbp: o PATH do HOST (tmux, ps, renice) segue começando pelo path_extra (Homebrew do MBP)"
  pv stop w-remote-m-5 </dev/null
  # --- vigia: o Athos volta (ou pausa) com a sessão rodando → a árvore cai para prioridade de fundo, uma vez, e a sessão NÃO é morta ---
  # `renice`/`taskpolicy` falsos no PATH do "host" só registram o pid: o nice real não serve de prova aqui (quem roda o teste pode já
  # estar em prioridade de fundo — o `ps` do mini mostra 20 até para `nice -n 10`); o que vale é QUEM foi rebaixado e QUANDO.
  mkdir -p "$T/home/.local/bin"; : > "$T/demote.log"
  for t in renice taskpolicy; do printf '#!/bin/sh\necho "%s $*" >> "%s/demote.log"\n' "$t" "$T" > "$T/home/.local/bin/$t"; chmod +x "$T/home/.local/bin/$t"; done
  echo livre > "$T/pres.mode"; rm -f "$T/pres.pause" "$T/wpid.out"
  pv start w-remote-m-6 < <(req "sh -c 'echo \$\$ > $T/wpid.out; exec sleep 300'"); ok $RC "mbp: (preparo) sessão de longa duração (rc=$RC $(head -c 150 "$T/err"))"; sleep 3; pid=$(cat "$T/wpid.out" 2>/dev/null)
  [ -n "$pid" ] && [ ! -s "$T/demote.log" ]; ok $? "mbp: com o Athos fora, ninguém é rebaixado (pid=$pid, $(wc -l < "$T/demote.log") chamadas)"
  echo uso > "$T/pres.mode"; for i in $(seq 1 40); do grep -q "^taskpolicy -b -p $pid\$" "$T/demote.log" && break; sleep 0.25; done
  grep -q "^renice -n 19 -p $pid\$" "$T/demote.log" && grep -q "^taskpolicy -b -p $pid\$" "$T/demote.log"; ok $? "mbp: o Athos voltou → o processo da sessão (pid $pid) leva renice 19 + taskpolicy -b em poucos segundos"
  m=$(wc -l < "$T/demote.log"); echo livre > "$T/pres.mode"; sleep 3
  ! grep -vE '^(renice -n 19 -p [0-9]+|taskpolicy -b -p [0-9]+)$' "$T/demote.log" | grep -q .; ok $? "mbp: ...e quando ele sai de novo nada sobe a prioridade (só há chamadas de rebaixamento)"
  pv is-running w-remote-m-6 </dev/null; [ "$(cat "$T/out")" = true ] && kill -0 "$pid" 2>/dev/null; ok $? "mbp: a sessão em curso NÃO é morta (termina o que estava fazendo)"
  # vazio (pgrep rc 1) → passa; falhou/ilegível (rc 2/3) → FAIL, nunca "nenhum sobrou". Casa o caminho da biblioteca falsa, que é argumento do vigia e único por bateria ($T vem do mktemp): o 'PRESENCE_LIB_ONLY=1' de antes casava também o vigia de OUTRA bateria rodando em paralelo (revisor/dog no mini) e reprovava à toa (ga-3gaf8g)
  pv stop w-remote-m-6 </dev/null; sleep 2; pgrep -f "$T/lib/presence.sh" >/dev/null; [ $? = 1 ]; ok $? "mbp: o vigia termina junto com a sessão (nenhum sobrou DESTA bateria; o de outra rodando em paralelo não conta)"
  : > "$T/demote.log"; rm -f "$T/wpid.out"; : > "$T/pres.pause"; echo livre > "$T/pres.mode"
  pv start w-remote-m-7 < <(req "sh -c 'echo \$\$ > $T/wpid.out; exec sleep 300'"); sleep 1; pid=$(cat "$T/wpid.out" 2>/dev/null)
  for i in $(seq 1 40); do grep -q "^taskpolicy -b -p $pid\$" "$T/demote.log" && break; sleep 0.25; done
  grep -q "^taskpolicy -b -p $pid\$" "$T/demote.log"; ok $? "mbp: a pausa do Athos (arquivo de pausa) também rebaixa a sessão em curso"
  pv stop w-remote-m-7 </dev/null; rm -f "$T/pres.pause" "$T/home/.local/bin/renice" "$T/home/.local/bin/taskpolicy"
  # --- o ambiente da sessão é do bundle: sem ele (ou de outro PATH) a sessão NÃO abre; e o comando tem que existir no PATH da SESSÃO ---
  mode livre; mv "$RR/zdot" "$RR/zdot.off"; fresh; pv start w-remote-m-9 < <(req cat); [ $RC = 1 ] && has "$T/err" 'zdot ausente ou com PATH diferente' && [ "$(count x "${SOCK}m")" = 0 ]
  ok $? "mbp: sem o zdot do bundle no host o start recusa dizendo por quê e nada fica aberto (rc=$RC)"
  mv "$RR/zdot.off" "$RR/zdot"; zdot_put "/usr/local/bin:/usr/bin:/bin"; pv start w-remote-m-9 < <(req cat); [ $RC = 1 ] && has "$T/err" 'zdot ausente ou com PATH diferente' && [ "$(count x "${SOCK}m")" = 0 ]
  ok $? "mbp: zdot com PATH diferente do da session_env (bundle de outra lista) → recusa, nada aberto (rc=$RC)"
  zdot_put "$T/shim-bin:/usr/bin:/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/extra/so-no-host"; chmod +x "$T/extra/so-no-host"
  pv start w-remote-m-9 < <(req so-no-host); [ $RC = 1 ] && has "$T/err" 'comando não encontrado' && [ "$(count x "${SOCK}m")" = 0 ]
  ok $? "mbp: comando que só existe no PATH do host (path_extra) não existe para a sessão: 127, nada aberto (rc=$RC)"
  # --- sem a biblioteca de presença no host não há vigia, então não há sessão ---
  mv "$T/lib/presence.sh" "$T/lib/presence.sh.off"; fresh; pv start w-remote-m-8 < <(req cat); [ $RC = 1 ] && has "$T/err" 'biblioteca de presença' && [ "$(count x "${SOCK}m")" = 0 ]; ok $? "mbp: sem a biblioteca de presença no host o start recusa (uma sessão sem vigia não abre) (rc=$RC)"
  mv "$T/lib/presence.sh.off" "$T/lib/presence.sh"
  # --- nada de segredo novo no MBP: o env é o mesmo filtro do servidor ---
  pv --dry-run start w-remote-m-0 < <(req claude '' '{"env":{"GC_CITY":"'"$CITY"'","GC_INSTANCE_TOKEN":"x","ANTHROPIC_API_KEY":"k","GITHUB_TOKEN":"g","LANG":"C"}}' | jq '.work_dir="'"$CITY"'/.gc/agents/dog"')
  [ "$(jq -r '.env | has("GC_INSTANCE_TOKEN") or has("ANTHROPIC_API_KEY") or has("GITHUB_TOKEN")' "$T/out")" = false ]; ok $? "mbp: token, chave de API e credencial do GitHub NÃO vão para o MBP"
  jq -r .work_dir "$T/out" | grep -q "^$RR/"; ok $? "mbp: o diretório de trabalho fica dentro da raiz do bundle (gt-remote), nunca no resto do home do Athos"
  # --- config: a regra de presença não pode ser desligada por engano, e sem default_host o host vem do nome ---
  for v in '"true"' 1 null '"sim"'; do
    cfgm '{"presence_gate":'"$v"'}'; fresh; pv --dry-run start w-remote-m-0 < <(req cat); [ $RC = 1 ] && has "$T/err" "'presence_gate'" && nossh; ok $? "mbp: presence_gate=$v (não é true/false) recusa a config, sem ssh (rc=$RC)"
  done
  cfgm '{"sleeps":"talvez"}'; pv --dry-run start w-remote-m-0 < <(req cat); [ $RC = 1 ] && has "$T/err" "'sleeps'"; ok $? "mbp: sleeps que não é booleano recusa a config"
  cfgm '{"presence_gate":false}'; pv --dry-run start w-remote-m-0 < <(req cat); [ $RC = 1 ] && has "$T/err" 'exige presence_gate'; ok $? "mbp: notebook (sleeps) sem a regra de presença recusa a config"
  cfgm '{"session_env":null}'; pv --dry-run start w-remote-m-0 < <(req cat); [ $RC = 1 ] && has "$T/err" "'session_env' é obrigatório" && nossh; ok $? "mbp: notebook (sleeps) sem session_env recusa a config, sem ssh (rc=$RC)"
  for v in '"/usr/bin"' '{}' '{"path":[],"claude":"/c"}' '{"path":["/usr/bin"]}' '{"path":["/usr/bin"],"claude":"c"}' '{"path":["/usr/bin","/usr/bin"],"claude":"/c"}' \
           '{"path":["/home/x/.local/bin"],"claude":"/c"}' '{"path":["/a/../b"],"claude":"/c"}' '{"path":["bin"],"claude":"/c"}' '{"path":["/usr/bin"],"claude":"/c","extra":1}' '{"path":"/usr/bin","claude":"/c"}'; do
    cfgm '{"session_env":'"$v"'}'; fresh; pv --dry-run start w-remote-m-0 < <(req cat); [ $RC = 1 ] && has "$T/err" "session_env" && nossh; ok $? "mbp: session_env $v recusa a config (nunca vira 'sem ambiente'), sem ssh (rc=$RC)"
  done
  cfgm; pv --dry-run start w-1 < <(req cat); [ $RC = 0 ] && [ "$(jq -r .session_env "$T/out")" = null ]; ok $? "mbp: host que NÃO dorme segue sem session_env (nada muda para o servidor) (rc=$RC)"
  cfgm '{"gate_cmd":"mbp-run.sh --check"}'; pv --dry-run start w-remote-m-0 < <(req cat); [ $RC = 1 ] && has "$T/err" "'gate_cmd'"; ok $? "mbp: gate_cmd em texto (não lista) recusa a config"
  cfgm; jq 'del(.default_host)' "$T/cfg.json" > "$T/cfg.nd" && mv "$T/cfg.nd" "$T/cfg.json"; setup_mbp; mode livre
  pv --dry-run start w-remote-m-0 < <(req cat); [ $RC = 0 ] && [ "$(jq -r .host "$T/out")" = m ]; ok $? "mbp: sem default_host o nome da sessão ainda escolhe o host (rc=$RC $(head -c 120 "$T/err"))"
  cfgm; pv --dry-run start dog-remote-1 < <(req cat); [ $RC = 0 ] && [ "$(jq -r .host "$T/out")" = a ]; ok $? "mbp: <papel>-remote-<n> (número do pool, a forma do patch do engine) vai ao default_host, não pede o host '1' (rc=$RC $(head -c 120 "$T/err"))"
  jq 'del(.default_host)' "$T/cfg.json" > "$T/cfg.nd" && mv "$T/cfg.nd" "$T/cfg.json"
  pv start w-remote-m-1 < <(req cat); pv list-running w- </dev/null; [ $RC = 0 ] && has "$T/out" w-remote-m-1; ok $? "mbp: sem default_host o list-running ainda junta os hosts (rc=$RC $(head -c 120 "$T/err"))"
  pv stop w-remote-m-1 </dev/null
  cfg 3
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
  # (`my_remote-e2e-1` e não `my-remote-e2e-1`: o `-remote-<x>` com hífen o host_of lê como host `<x>` e recusa ANTES do guarda — ver o caso abaixo)
  for nm in remote-e2e- remote-e2e1 my_remote-e2e-1 remote-e2e remote-testing-1 Remote-E2E-1 remote-test remote_e2e-1 dog_remote-test-1; do
    fresh; pv start $nm < <(req cat); [ $RC = 1 ] && has "$T/err" 'real_sessions_released_by' && nossh; ok $? "gate: '$nm' NÃO é sessão de teste (nome exato remote-e2e-<x> / remote-test-<x>) e recusa (rc=$RC)"
  done
  # com hífen antes do `remote-`, duas regras recusam (o host_of do ga-w7qwl1 e o guarda de clone): basta que ALGUMA recuse, sem ssh e sem abrir nada
  for nm in my-remote-e2e-1 dog-remote-test-1; do
    fresh; pv start $nm < <(req cat); [ $RC = 1 ] && { has "$T/err" 'real_sessions_released_by' || has "$T/err" 'o nome pede o host'; } && nossh && [ "$(count)" = 0 ]; ok $? "gate: '$nm' (prefixo com hífen) recusa, por qualquer das duas regras, sem ssh e sem abrir (rc=$RC)"
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

# --- prep (ga-2hd02v.1.5.9): o start grava a identidade git e a confiança da pasta POR WORKTREE; qualquer falha = o start falha e nada abre ---
mkmirror() {  # mkmirror — espelho BARE do servidor (<home>/gt-remote/git/gascity/repo.git) com 1 commit e nenhum worktree; ~/.claude.json do host com a conta e um projeto alheio
  local g=$RH/gt-remote/git/gascity; find "$RH/gt-remote" -mindepth 1 -delete 2>/dev/null; find "$T/seed" -mindepth 1 -delete 2>/dev/null; mkdir -p "$g" "$T/seed"
  git init -q "$T/seed/s" && git -C "$T/seed/s" -c user.name=seed -c user.email=seed@x commit -q --allow-empty -m seed && git clone -q --bare "$T/seed/s" "$g/repo.git"
  printf '{"userID":"u-123","projects":{"/alheio":{"hasTrustDialogAccepted":false,"keep":1}}}' > "$RH/.claude.json"; chmod 600 "$RH/.claude.json"
}
wtadd() { git -C "$RH/gt-remote/git/gascity/repo.git" worktree add -q --detach "../wt/$1" >/dev/null 2>&1; }  # wtadd NOME → $RH/gt-remote/git/gascity/wt/NOME
WTD() { echo "$RH/gt-remote/git/gascity/wt/$1"; }
sess_zero() { [ "$(count)" = 0 ] && [ ! -e "$RR/run/$1.sh" ]; }  # nada aberto e nenhum lançador deixado
g_prep() {
  local nm=remote-e2e-1 w
  cfg 3 25 '{"worktree_prepare":true}'; install_host; mkmirror; wtadd s1; w=$(WTD s1); fresh
  pv start $nm < <(req cat "$w"); ok $RC "prep: start numa pasta que é worktree do espelho BARE abre (rc=$RC $(head -c 250 "$T/err"))"
  [ "$(git -C "$w" config --get user.name)" = "$nm" ] && [ "$(git -C "$w" config --get user.email)" = "$nm@gastown.invalid" ]; ok $? "prep: ...com a identidade git da sessão (user.name = o nome da sessão, e-mail @gastown.invalid) valendo no worktree"
  git -C "$w" commit -q --allow-empty -m "da sessão" 2>"$T/gerr"; [ "$(git -C "$w" log -1 --format='%an <%ae>')" = "$nm <$nm@gastown.invalid>" ]; ok $? "prep: ...e um commit feito DENTRO do worktree sai com o autor certo (o espelho bare não quebra o commit: $(head -c 120 "$T/gerr"))"
  jq -e --arg w "$w" '.projects[$w] == {"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true,"allowedTools":[]}' "$RH/.claude.json" >/dev/null; ok $? "prep: ...e a pasta pré-confiada em ~/.claude.json do host (sem diálogo de confiança)"
  jq -e '.userID == "u-123" and .projects["/alheio"] == {"hasTrustDialogAccepted":false,"keep":1}' "$RH/.claude.json" >/dev/null; ok $? "prep: ...sem mexer no resto do arquivo (conta, projeto alheio com a confiança dele)"
  [ "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$RH/.claude.json")" = 0o600 ]; ok $? "prep: ...e o modo 600 do ~/.claude.json se mantém (a troca atômica não afrouxa o arquivo da conta)"
  local rg=$RH/gt-remote/git/gascity/repo.git
  [ -z "$(git config --file "$rg/config" --get core.bare)" ] && [ "$(git config --file "$rg/config.worktree" --get core.bare)" = true ] && [ "$(git config --file "$rg/config" --get extensions.worktreeConfig)" = true ]; ok $? "prep: ...o core.bare do espelho saiu do config compartilhado e foi para o config.worktree (extensions.worktreeConfig ligado), senão o commit dos worktrees quebraria"
  pv is-running $nm </dev/null; [ "$(cat "$T/out")" = true ]; ok $? "prep: ...e a sessão está de pé"; pv stop $nm </dev/null
  # reinício: idempotente, não duplica nada
  fresh; pv start $nm < <(req cat "$w"); ok $RC "prep: segundo start do mesmo worktree (idempotente) abre (rc=$RC)"; pv stop $nm </dev/null
  jq -e --arg w "$w" '(.projects | length) == 2' "$RH/.claude.json" >/dev/null; ok $? "prep: ...e o ~/.claude.json não ganhou entrada duplicada"
  # a identidade é POR worktree: a segunda sessão não herda nem muda a primeira
  wtadd s2; fresh; pv start prep-two < <(req cat "$(WTD s2)"); ok $RC "prep: segunda sessão em OUTRO worktree abre (rc=$RC)"; pv stop prep-two </dev/null
  [ "$(git -C "$(WTD s2)" config --get user.name)" = prep-two ] && [ "$(git -C "$w" config --get user.name)" = "$nm" ]; ok $? "prep: ...cada worktree guarda a identidade da SUA sessão (a do s1 continua remote-e2e-1)"
  # --- falhas: o start falha, nada abre, nenhum lançador, e a mensagem diz o motivo ---
  fresh; pv start prep-no < <(req cat "$RH/gt-remote/git/gascity/wt/nao-existe"); [ $RC = 1 ] && has "$T/err" 'preparo da sessão prep-no recusado' && has "$T/err" 'não existe'; ok $? "prep: pasta que NÃO existe → start falha dizendo que tem de ser um worktree já criado (rc=$RC)"
  sess_zero prep-no; ok $? "prep: ...nada aberto e a pasta NÃO foi criada pelo start" ; [ ! -e "$RH/gt-remote/git/gascity/wt/nao-existe" ]; ok $? "prep: ...(a pasta ausente não vira diretório comum)"
  mkdir -p "$RH/plain"; fresh; pv start prep-pl < <(req cat "$RH/plain"); [ $RC = 1 ] && has "$T/err" 'não é um worktree git'; ok $? "prep: pasta comum (não git) → start falha: sessão não abre sem identidade (rc=$RC)"; sess_zero prep-pl; ok $? "prep: ...nada aberto"
  wtadd s3; mv "$RH/.claude.json" "$T/claude.bak"; fresh; pv start prep-nj < <(req cat "$(WTD s3)"); [ $RC = 1 ] && has "$T/err" 'confiança da pasta' && [ ! -e "$RH/.claude.json" ]; ok $? "prep: ~/.claude.json AUSENTE → start falha e NÃO cria um arquivo no lugar do login do claude (rc=$RC)"; sess_zero prep-nj; ok $? "prep: ...nada aberto"
  printf '{ isto não é json' > "$RH/.claude.json"; cp "$RH/.claude.json" "$T/claude.bad"; fresh; pv start prep-bj < <(req cat "$(WTD s3)"); [ $RC = 1 ] && has "$T/err" 'confiança da pasta' && cmp -s "$RH/.claude.json" "$T/claude.bad"; ok $? "prep: ~/.claude.json ILEGÍVEL → start falha e o arquivo fica byte a byte como estava (rc=$RC)"; sess_zero prep-bj; ok $? "prep: ...nada aberto"
  printf '{"projects":["x"]}' > "$RH/.claude.json"; fresh; pv start prep-bl < <(req cat "$(WTD s3)"); [ $RC = 1 ] && has "$T/err" 'confiança da pasta'; ok $? "prep: ~/.claude.json com forma que não conheço (projects como lista) → start falha (rc=$RC)"; sess_zero prep-bl; ok $? "prep: ...nada aberto"
  cp "$T/claude.bak" "$RH/.claude.json"
  wtadd s4; : > "$RH/gt-remote/git/gascity/repo.git/worktrees/s4/config.worktree.lock"; fresh; pv start prep-lk < <(req cat "$(WTD s4)"); [ $RC = 1 ] && has "$T/err" 'identidade git'; ok $? "prep: identidade que o git não consegue gravar (config.worktree travado) → start falha (rc=$RC)"; sess_zero prep-lk; ok $? "prep: ...nada aberto"
  jq -e --arg w "$(WTD s4)" '.projects[$w] == null' "$RH/.claude.json" >/dev/null; ok $? "prep: ...e a confiança NÃO foi gravada (a identidade vem antes: sem ela nada mais acontece)"
  # a identidade gravada tem que ser a que VALE: um git que lê outra coisa derruba o start
  wtadd s5; mkdir -p "$T/home/.local/bin"; real=$(command -v git)
  printf '#!/bin/sh\ncase "$*" in *"config --get user.name"*) echo outra-pessoa; exit 0;; esac\nexec %s "$@"\n' "$real" > "$T/home/.local/bin/git"; chmod +x "$T/home/.local/bin/git"
  fresh; pv start prep-ot < <(req cat "$(WTD s5)"); [ $RC = 1 ] && has "$T/err" 'não ficou valendo'; ok $? "prep: identidade gravada mas que não é a que o git LÊ (outra camada a sobrepõe) → start falha (rc=$RC)"; sess_zero prep-ot; ok $? "prep: ...nada aberto"
  find "$T/home/.local/bin" -name git -delete
  # --- dry-run e configuração ---
  fresh; pv --dry-run start $nm < <(req cat "$w"); [ $RC = 0 ] && jq -e --arg w "$w" --arg n "$nm" --arg tf "$RH/.claude.json" '.prepare == {"git_user":$n,"git_email":($n+"@gastown.invalid"),"trust_file":$tf,"work_dir":$w}' "$T/out" >/dev/null; ok $? "prep: dry-run diz o que gravaria (identidade, e-mail, arquivo de confiança, pasta)"; nossh; ok $? "prep: ...sem conectar"
  cfg 3 25 '{"worktree_prepare":false}'; fresh; pv start prep-off < <(req cat "$RH/plain"); ok $RC "prep: worktree_prepare=false → pasta comum abre (o notebook do Athos tem identidade e confiança dele) (rc=$RC)"; pv stop prep-off </dev/null
  [ "$(git -C "$RH/plain" config --get user.name 2>/dev/null)" != prep-off ]; ok $? "prep: ...e nenhuma identidade foi gravada"
  cfg 3; jq 'del(.hosts.a.worktree_prepare)' "$T/cfg.json" > "$T/cfg2.json" && mv "$T/cfg2.json" "$T/cfg.json"; fresh; pv start prep-df < <(req cat "$RH/plain"); [ $RC = 1 ] && has "$T/err" 'não é um worktree git'; ok $? "prep: SEM a chave num host sem regra de presença o preparo vale (padrão LIGADO: servidor nunca abre sem identidade) (rc=$RC)"
  setup_mbp; cfgm; fresh; pv --dry-run start w-remote-m-0 < <(req cat "$RH/plain"); [ $RC = 0 ] && [ "$(jq -r .host "$T/out")" = m ] && jq -e '.prepare == null' "$T/out" >/dev/null; ok $? "prep: SEM a chave num host de presença (notebook do Athos) o padrão é DESLIGADO (dry-run: prepare nulo)"
  cfgm '{"worktree_prepare":true}'; fresh; pv --dry-run start w-remote-m-0 < <(req cat "$RH/plain"); [ $RC = 0 ] && jq -e '.prepare != null' "$T/out" >/dev/null; ok $? "prep: ...e worktree_prepare=true no notebook liga (a chave explícita vale nos dois sentidos)"
  for v in '"false"' '"true"' '0' '1' 'null' '[]'; do
    cfg 3; jq ".hosts.a.worktree_prepare=$v" "$T/cfg.json" > "$T/cfg2.json" && mv "$T/cfg2.json" "$T/cfg.json"; fresh; pv start prep-cf < <(req cat "$RH/plain"); [ $RC = 1 ] && has "$T/err" "'worktree_prepare'" && nossh; ok $? "prep: worktree_prepare=$v não é true/false → config recusada dizendo a chave, sem ssh (rc=$RC)"
  done
  cfg 3; install_host
}

# --- wt (ga-2hd02v.1.7): o start cria o worktree da sessão (wt-add) e o stop o recolhe (wt-rm) SÓ quando nada se perde; nomes de sessão que o ENGINE gera ---
RGBIN="$RH/gt-remote/bin/hetzner-remote-git.sh"; RGREPO="$RH/gt-remote/git/gascity/repo.git"; export FAKE_RG_LOG="$T/rg.log"
install_rg() {  # um hetzner-remote-git.sh falso com o contrato do verdadeiro (GT_REMOTE_GIT + <sub> <rig> <bead>; branch worker/<bead> sobre origin/main), sem pull nem espelho; FAKE_RG_FAIL=add|rm faz falhar
  mkdir -p "$RH/gt-remote/bin"
  cat > "$RGBIN" <<'EOF'
#!/bin/sh
[ -n "${GT_REMOTE_GIT:-}" ] || { echo "fake hetzner-remote-git: GT_REMOTE_GIT não veio" >&2; exit 3; }
sub=${1:-}; rig=${2:-}; bead=${3:-}; r="$GT_REMOTE_GIT/$rig/repo.git"; p="$GT_REMOTE_GIT/$rig/wt/$bead"
echo "$sub $rig $bead GR=$GT_REMOTE_GIT" >> "${FAKE_RG_LOG:-/dev/null}"
case "$sub" in
  wt-add) if [ "${FAKE_RG_FAIL:-}" = addpartial ]; then  # o worktree sai criado e o checkout esparso morre (como o die 3 do script verdadeiro)
            git -C "$r" worktree add -q --no-checkout -b "worker/$bead" "$p" refs/remotes/origin/main >&2; echo "hetzner-remote-git: checkout esparso falhou em $p (de propósito)" >&2; exit 3; fi
          [ "${FAKE_RG_FAIL:-}" != add ] || { echo "hetzner-remote-git: wt-add falhou (de propósito)" >&2; exit 3; }
          [ ! -e "$p" ] || { echo "wt-add: $p já existe"; exit 0; }
          git -C "$r" worktree add -q -b "worker/$bead" "$p" refs/remotes/origin/main >&2 || exit 3
          echo "{\"bead\":\"$bead\",\"pull\":\"ok\"}";;
  wt-rm)  [ "${FAKE_RG_FAIL:-}" != rm ] || { echo "hetzner-remote-git: não removi (de propósito)" >&2; exit 3; }
          git -C "$r" worktree remove --force "$p" >&2 && git -C "$r" worktree prune && echo "wt-rm: $bead removido";;
  *) exit 2;;
esac
EOF
  chmod +x "$RGBIN"
}
wtmirror() {  # wtmirror [CONTEÚDO de .claude/settings.json no commit] → o espelho do servidor com refs/remotes/origin/main (de onde o wt-add verdadeiro parte) + o script falso
  mkmirror; local br g=$RGREPO
  if [ -n "${1:-}" ]; then
    mkdir -p "$T/seed/s/.claude"; printf '%s' "$1" > "$T/seed/s/.claude/settings.json"; br=$(git -C "$T/seed/s" symbolic-ref --short HEAD)
    git -C "$T/seed/s" add -A && git -C "$T/seed/s" -c user.name=seed -c user.email=seed@x commit -q -m cfg && git -C "$T/seed/s" push -q "$g" "HEAD:refs/heads/$br"
  fi
  git -C "$g" update-ref refs/remotes/origin/main "$(git -C "$g" rev-parse HEAD)"; install_rg; : > "$T/rg.log"
}
g_wt() {
  local n1=dog-remote-gapxi4ls n2=dog-remote-adhoc-0fc28155dd n3=dog-remote-gabroken1 n4=dog-remote-gawtrmfail w nm v ev="$T/state/a/events.jsonl" eng="$CITY/.gc/agents/dogs/dog-remote-1"
  local base='{"worktree_prepare":true,"worktree_rigs":{"dog":"gascity"}}'
  evwt() { jq -e -s --arg s "$1" --arg v "$2" 'map(select(.session==$s and .event=="stopped")) | last | .worktree | startswith($v)' "$ev" >/dev/null 2>&1; }  # evwt SESSÃO removed|kept|none: o último 'stopped' dela diz o que houve com o worktree
  tmux -L "$SOCK" kill-server 2>/dev/null; cfg 3 25 "$base"; install_host; wtmirror
  # --- dry-run ---
  fresh; pv --dry-run start $n1 < <(req cat "$eng"); w=$(WTD $n1)
  [ $RC = 0 ] && [ "$(jq -r .work_dir "$T/out")" = "$w" ] && jq -e --arg w "$w" '.worktree.rig == "gascity" and .worktree.path == $w and (.worktree.add | endswith("wt-add gascity '$n1'"))' "$T/out" >/dev/null; ok $? "wt: dry-run de sessão de pool (dog-remote-<cauda>) mostra o wt-add, o rig e a pasta do wt-add — e ignora o work_dir do template"
  nossh; ok $? "wt: ...sem conectar"
  [ "$(jq -r .worktree.start_timeout "$T/out")" = 150 ]; ok $? "wt: ...e o prazo do start sobe ao piso de 150 s (a config pedia 25 s: o wt-add puxa o espelho antes de criar)"
  cfg 3 400 "$base"; fresh; pv --dry-run start $n1 < <(req cat "$eng"); [ "$(jq -r .worktree.start_timeout "$T/out")" = 400 ]; ok $? "wt: ...e prazo de config MAIOR que o piso vale (400 s)"; cfg 3 25 "$base"
  fresh; pv --dry-run start wa-worker-remote-gaabc12 < <(req cat "$eng"); [ $RC = 0 ] && jq -e 'has("worktree") | not' "$T/out" >/dev/null && [ "$(jq -r .work_dir "$T/out")" = "$RR/city/.gc/agents/dogs/dog-remote-1" ]; ok $? "wt: dry-run de papel SEM mapa não traz 'worktree' e mantém o work_dir de sempre"
  # --- start: cria o worktree, abre dentro dele ---
  fresh; pv start $n1 < <(req cat "$eng"); ok $RC "wt: start de sessão de pool com papel mapeado abre (rc=$RC $(head -c 250 "$T/err"))"
  [ "$(git -C "$w" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] && has "$T/rg.log" "wt-add gascity $n1 GR=$RH/gt-remote/git"; ok $? "wt: ...o worktree veio do wt-add, em <home>/gt-remote/git/<rig>/wt/<sessão>, com GT_REMOTE_GIT apontando o mesmo lugar"
  v=$(tmux -L "$SOCK" display-message -p -t "=$n1:" '#{pane_current_path}' 2>/dev/null); [ -n "$v" ] && [ "$v" = "$(cd "$w" 2>/dev/null && pwd -P)" ]; ok $? "wt: ...e a sessão abriu DENTRO dele (não no work_dir do template)"
  [ "$(count)" = 1 ] && [ ! -e "$RR/city/.gc/agents/dogs/dog-remote-1" ]; ok $? "wt: ...e a pasta do template não virou diretório no host"
  [ "$(git -C "$w" config --get user.name)" = "$n1" ] && jq -e --arg w "$w" '.projects[$w].hasTrustDialogAccepted == true' "$RH/.claude.json" >/dev/null; ok $? "wt: ...com a identidade git e a confiança da pasta gravadas (o preparo roda DEPOIS do wt-add)"
  : > "$T/rg.log"; fresh; pv start $n1 < <(req cat "$eng"); [ $RC = 1 ] && has "$T/err" 'already exists' && [ -d "$w" ] && [ ! -s "$T/rg.log" ]; ok $? "wt: start de sessão que já existe é recusado SEM chamar o wt-add nem o wt-rm: o worktree dela fica (rc=$RC)"
  # --- stop: limpo e sem nada a publicar → recolhe ---
  v=$(git -C "$RGREPO" rev-parse -q --verify "refs/heads/worker/$n1" 2>/dev/null); [ -n "$v" ]; ok $? "wt: (antes do stop o branch worker/<sessão> existe)"
  : > "$T/rg.log"; pv stop $n1 </dev/null; [ $RC = 0 ] && [ "$(count)" = 0 ] && [ -d "$RH/gt-remote/git/gascity/wt" ] && [ ! -e "$w" ]; ok $? "wt: stop com o worktree limpo e sem nada a publicar derruba a sessão e recolhe o worktree (rc=$RC)"
  has "$T/rg.log" "wt-rm gascity $n1" && evwt $n1 removed; ok $? "wt: ...pelo wt-rm, e o evento 'stopped' diz worktree=removed"
  [ -z "$(git -C "$RGREPO" rev-parse -q --verify "refs/heads/worker/$n1" 2>/dev/null)" ]; ok $? "wt: ...e o branch worker/<sessão> (nada nele que o origin não tenha) sai junto"
  # --- stop: onde há risco de perder trabalho, MANTÉM ---
  pv start $n2 < <(req cat "$eng"); ok $RC "wt: (segunda sessão, nome adhoc do engine) abre (rc=$RC $(head -c 200 "$T/err"))"; w=$(WTD $n2); echo x > "$w/novo.txt"
  : > "$T/rg.log"; pv stop $n2 </dev/null; [ $RC = 0 ] && [ "$(count)" = 0 ] && [ -f "$w/novo.txt" ] && ! has "$T/rg.log" wt-rm && evwt $n2 kept; ok $? "wt: stop com arquivo novo no worktree derruba a sessão e MANTÉM o worktree (sem wt-rm; o arquivo continua) (rc=$RC)"
  rm -f "$w/novo.txt"; git -C "$w" commit -q --allow-empty -m wip; : > "$T/rg.log"; pv stop $n2 </dev/null
  [ $RC = 0 ] && [ -d "$w" ] && ! has "$T/rg.log" wt-rm && evwt $n2 kept; ok $? "wt: stop com commit que o origin não tem MANTÉM o worktree (rc=$RC)"
  git -C "$RGREPO" update-ref "refs/remotes/origin/worker/$n2" "$(git -C "$w" rev-parse HEAD)"; : > "$T/rg.log"; pv stop $n2 </dev/null
  [ $RC = 0 ] && [ ! -e "$w" ] && has "$T/rg.log" "wt-rm gascity $n2" && evwt $n2 removed; ok $? "wt: ...e depois que o origin tem o commit, o MESMO stop (repetido: idempotente) recolhe o worktree (rc=$RC)"
  pv start $n3 < <(req cat "$eng"); w=$(WTD $n3); printf 'gitdir: /nao/existe\n' > "$w/.git"; : > "$T/rg.log"; pv stop $n3 </dev/null
  [ $RC = 0 ] && [ -d "$w" ] && ! has "$T/rg.log" wt-rm && evwt $n3 kept; ok $? "wt: git que NÃO consegue ler o worktree → MANTÉM (não consegui saber nunca vira 'limpo') (rc=$RC)"
  pv start $n4 < <(req cat "$eng"); w=$(WTD $n4); : > "$T/rg.log"; FAKE_RG_FAIL=rm pv stop $n4 </dev/null
  [ $RC = 0 ] && [ "$(count)" = 0 ] && [ -d "$w" ] && evwt $n4 kept; ok $? "wt: wt-rm que falha NÃO derruba o stop: a sessão parou, o worktree fica e o evento diz kept (rc=$RC $(head -c 200 "$T/err"))"
  pv stop dog-remote-gaghost0 </dev/null; [ $RC = 0 ] && evwt dog-remote-gaghost0 none; ok $? "wt: stop de sessão que nunca teve worktree sai 0 e o evento diz none (rc=$RC)"
  : > "$T/rg.log"; pv stop wa-worker-remote-gaabc12 </dev/null; [ $RC = 0 ] && [ ! -s "$T/rg.log" ]; ok $? "wt: stop de papel SEM mapa não toca no wt-rm (como antes) (rc=$RC)"
  pv --dry-run stop wa-worker-remote-gaabc12 </dev/null; ! has "$T/out" wtclean; ok $? "wt: ...e o script do stop dele não leva o recolhimento"
  # --- start que falha depois de criar o worktree: desfaz; antes de criar: não cria ---
  wtmirror; w=$(WTD dog-remote-gaaddfail); FAKE_RG_FAIL=add pv start dog-remote-gaaddfail < <(req cat "$eng"); [ $RC = 1 ] && has "$T/err" 'wt-add' && sess_zero dog-remote-gaaddfail && [ ! -e "$w" ]; ok $? "wt: wt-add que falha derruba o start dizendo qual: nada aberto, nenhum worktree (rc=$RC)"
  cfg 3 25 '{"worktree_prepare":false,"worktree_rigs":{"dog":"gascity"}}'; wtmirror; w=$(WTD dog-remote-gaaddfail2); FAKE_RG_FAIL=add pv start dog-remote-gaaddfail2 < <(req cat "$eng")
  [ $RC = 1 ] && has "$T/err" 'wt-add' && sess_zero dog-remote-gaaddfail2 && [ ! -e "$w" ]; ok $? "wt: ...e MESMO sem o preparo (worktree_prepare=false, onde nada mais confere a pasta) o wt-add que falha derruba o start: a pasta não vira um diretório comum com a sessão dentro (rc=$RC)"; cfg 3 25 "$base"
  wtmirror '{"disableAllHooks":true}'; w=$(WTD dog-remote-gaguard01); pv start dog-remote-gaguard01 < <(req cat "$eng"); [ $RC = 1 ] && has "$T/err" 'disableAllHooks' && sess_zero dog-remote-gaguard01; ok $? "wt: o guarda de clone olha o worktree JÁ criado: disableAllHooks que vem no checkout recusa a sessão real (rc=$RC $(head -c 200 "$T/err"))"
  [ ! -e "$w" ] && has "$T/rg.log" "wt-rm gascity dog-remote-gaguard01"; ok $? "wt: ...e o worktree que o start tinha criado é desfeito (wt-rm)"
  wtmirror; w=$(WTD dog-remote-gaprep001); cp "$RH/.claude.json" "$T/claude.ok"; printf '{ nao e json' > "$RH/.claude.json"; pv start dog-remote-gaprep001 < <(req cat "$eng")
  [ $RC = 1 ] && has "$T/err" 'confiança da pasta' && sess_zero dog-remote-gaprep001 && [ ! -e "$w" ] && has "$T/rg.log" "wt-rm gascity dog-remote-gaprep001"; ok $? "wt: preparo que falha depois do wt-add (confiança da pasta) derruba o start e desfaz o worktree (rc=$RC)"; cp "$T/claude.ok" "$RH/.claude.json"
  cfg 1 25 "$base"; wtmirror; pv start dog-remote-gacap0001 < <(req cat "$eng"); ok $RC "wt: (teto 1) primeira sessão abre"; : > "$T/rg.log"; pv start dog-remote-gacap0002 < <(req cat "$eng")
  [ $RC = 1 ] && has "$T/err" 'no teto' && ! has "$T/rg.log" "dog-remote-gacap0002" && [ ! -e "$(WTD dog-remote-gacap0002)" ]; ok $? "wt: host no teto recusa ANTES de criar o worktree (nenhum wt-add) (rc=$RC)"; pv stop dog-remote-gacap0001 </dev/null
  # --- sem a chave / papel sem mapa / nome impróprio / chave inválida: como hoje, ou recusa sem ssh ---
  cfg 3 25 '{"worktree_prepare":true}'; wtmirror; pv start dog-remote-gaplain01 < <(req cat "$eng"); [ $RC = 1 ] && has "$T/err" 'não existe' && ! has "$T/rg.log" wt-add; ok $? "wt: SEM worktree_rigs o start é o de hoje (a pasta tem que existir) e não chama o wt-add (rc=$RC)"
  cfg 3 25 "$base"; pv start wa-worker-remote-gaplain02 < <(req cat "$eng"); [ $RC = 1 ] && has "$T/err" 'não existe' && ! has "$T/rg.log" wt-add; ok $? "wt: papel que não está no mapa (wa-worker) também é o de hoje (rc=$RC)"
  fresh; pv start dog-remote-GAUP < <(req cat "$eng"); [ $RC = 1 ] && has "$T/err" 'worktree' && nossh; ok $? "wt: nome que não serve de nome de worktree (maiúscula) recusa SEM ssh (rc=$RC)"
  for v in '{"dog":"Bad Rig"}' '["dog"]' '{"dog":1}' '"dog"' '{"Dog":"gascity"}' '{"dog":"gascity/x"}'; do
    cfg 3 25 "$base"; jq ".hosts.a.worktree_rigs=$v" "$T/cfg.json" > "$T/cfg2.json" && mv "$T/cfg2.json" "$T/cfg.json"; fresh; pv start dog-remote-gacf0001 < <(req cat "$eng"); [ $RC = 1 ] && has "$T/err" "'worktree_rigs'" && nossh; ok $? "wt: worktree_rigs=$v → config recusada dizendo a chave, sem ssh (rc=$RC)"
  done
  # --- nomes que o ENGINE gera: <modelo>-<cauda-da-bead> e <modelo>-adhoc-<10>; o pedido de host continua recusando host desconhecido ---
  cfg 3 25 "$base"
  for nm in dog-remote-gapxi4ls dog-remote-adhoc-0fc28155dd dog-remote-1 w-remote-zzz; do fresh; pv --dry-run start $nm < <(req cat "$eng"); [ $RC = 0 ] && [ "$(jq -r .host "$T/out")" = a ]; ok $? "wt: nome '$nm' → host padrão (cauda de bead / adhoc / número / fim de nome), não pedido de host (rc=$RC $(head -c 160 "$T/err"))"; done
  fresh; pv --dry-run start w-remote-zzz-1 < <(req cat "$eng"); [ $RC = 1 ] && has "$T/err" 'zzz' && nossh; ok $? "wt: 'w-remote-zzz-1' (host pedido fora da config) continua recusando (rc=$RC)"
  fresh; pv --dry-run start w-remote-b-1 < <(req cat "$eng"); [ $RC = 0 ] && [ "$(jq -r .host "$T/out")" = b ]; ok $? "wt: 'w-remote-b-1' (host da config) continua indo para esse host (rc=$RC)"
  # --- identidade do atalho: o identity_pattern do runbook casa com o que o engine gera para o dog-remote, e só com isso ---
  local doc="$HERE/../docs/runbooks/gc-session-ssh.md" rx; rx=$(sed -n 's/^IDENTITY_PATTERN=//p' "$doc" 2>/dev/null)
  [ "$(printf '%s\n' "$rx" | grep -c .)" = 1 ]; ok $? "wt: o runbook traz UM identity_pattern canônico (linha IDENTITY_PATTERN=…)"
  python3 -I - "$rx" <<'PY'; ok $? "wt: o identity_pattern casa com alias/template/sessão que o engine gera (dog-remote-1, dog-remote, dog-remote-gapxi4ls, dog-remote-adhoc-…) e recusa os locais, os de outro papel e as misturas"
import re, sys
rx = re.compile(sys.argv[1])  # vazio ou inválido → o programa cai (rc ≠ 0) e o teste reprova
yes = ["remote-e2e-1", "dog-remote", "dog-remote-1", "dog-remote-gapxi4ls", "dog-remote-adhoc-0fc28155dd", "gate-reviewer-remote-2", "gate-reviewer-remote-adhoc-48ac5cece9", "wa-worker-remote-adhoc-1254849098", "wa-worker-remote-gawisp79e1", "ps-worker-remote", "ps-worker-remote-1", "ps-worker-remote-gaabc1234", "ps-worker-remote-adhoc-1254849098"]
no = ["gastown.dog-4", "dog-gapxi4ls", "gastown.mayor", "dog", "mayor-remote-1", "dog-remote-", "dog-remote-a", "dog-remote-adhoc-", "dog-remote-adhoc-12345678901", "dog-remote-gapxi4ls-x", "dog-remote/../x", "x-dog-remote-1", "remote-e2e-2", "ps-worker-1", "ps-worker", "ps-remote-1", "ps-worker-remote-", "ps-worker-remote-adhoc-"]
bad = [x for x in yes if not rx.fullmatch(x)] + [x for x in no if rx.fullmatch(x)]
print("fora do esperado:", bad, file=sys.stderr) if bad else None
sys.exit(1 if bad else 0)
PY
  # --- 1.8: acabamentos do veredito do gate da 1.7 ---
  cfg 3 2 "$base"; wtmirror; pv start dog-remote-gafloor01 < <(req cat "$eng"); ok $RC "wt: (1.8) start com prazo de config 2 s abre (vale o piso de 150 s) (rc=$RC $(head -c 160 "$T/err"))"
  FAKE_SSH_DELAY=4 pv stop dog-remote-gafloor01 </dev/null; [ $RC = 0 ] && [ "$(count)" = 0 ] && evwt dog-remote-gafloor01 removed; ok $? "wt: ...e o stop de sessão com worktree também leva piso de prazo: ssh lento (4 s) com prazo de config 2 s ainda termina, recolhe e sai 0 (rc=$RC $(head -c 160 "$T/err"))"
  FAKE_SSH_DELAY=4 pv stop wa-worker-remote-gafloor02 </dev/null; [ $RC = 1 ] && has "$T/err" 'não respondeu'; ok $? "wt: ...e o stop de papel SEM worktree segue com o prazo da config (estoura em 2 s e diz o host): o piso é só de quem recolhe worktree (rc=$RC)"
  cfg 3 25 '{"worktree_prepare":false}'; mkdir -p "$RH/plain"; pv start dog-remote-UPPER1 < <(req cat "$RH/plain"); ok $RC "wt: (sessão aberta ANTES de existir o mapa, com nome que não serve de nome de worktree) abre (rc=$RC)"
  cfg 3 25 "$base"; pv stop dog-remote-UPPER1 </dev/null; [ $RC = 0 ] && [ "$(count)" = 0 ] && has "$T/state/a/session-ssh.log" 'stop dog-remote-UPPER1' && has "$T/state/a/session-ssh.log" 'sem recolhimento'; ok $? "wt: ...com o mapa ligado, o stop dela DERRUBA a sessão do mesmo jeito (sem recolher worktree) e o log diz por quê — nome impróprio nunca impede o stop (rc=$RC $(head -c 160 "$T/err"))"
  wtmirror; w=$(WTD dog-remote-gapartial1); FAKE_RG_FAIL=addpartial pv start dog-remote-gapartial1 < <(req cat "$eng")
  [ $RC = 1 ] && sess_zero dog-remote-gapartial1 && [ ! -e "$w" ] && [ -z "$(git -C "$RGREPO" rev-parse -q --verify refs/heads/worker/dog-remote-gapartial1 2>/dev/null)" ]; ok $? "wt: wt-add que morre DEPOIS de criar o worktree (checkout esparso) → o start desfaz o que criou: nem pasta nem branch sobram, e o retry da mesma bead não bate em 'incompleto' (rc=$RC)"
  wtmirror; w=$(WTD dog-remote-gapre0001); git -C "$RGREPO" worktree add -q -b worker/dog-remote-gapre0001 "$w" refs/remotes/origin/main; echo guardado > "$w/precioso.txt"; FAKE_RG_FAIL=add pv start dog-remote-gapre0001 < <(req cat "$eng")
  [ $RC = 1 ] && [ -f "$w/precioso.txt" ] && [ -n "$(git -C "$RGREPO" rev-parse -q --verify refs/heads/worker/dog-remote-gapre0001 2>/dev/null)" ]; ok $? "wt: wt-add que falha numa pasta que JÁ existia antes do start NÃO a desfaz (o desfazer é só do que este start criou) (rc=$RC)"
  wtmirror; pv start dog-remote-gawarn001 < <(req cat "$eng"); ok $RC "wt: (sessão para o aviso do git) abre (rc=$RC)"; w=$(WTD dog-remote-gawarn001); mkdir -p "$T/home/.local/bin"; v=$(command -v git)
  printf '#!/bin/sh\ncase "$*" in *"status --porcelain"*) echo "warning: aviso inofensivo do git" >&2;; esac\nexec %s "$@"\n' "$v" > "$T/home/.local/bin/git"; chmod +x "$T/home/.local/bin/git"
  : > "$T/rg.log"; pv stop dog-remote-gawarn001 </dev/null; [ $RC = 0 ] && [ -d "$w" ] && ! has "$T/rg.log" wt-rm && evwt dog-remote-gawarn001 kept && has "$ev" 'avisou'; ok $? "wt: git que AVISA em stderr ao ler o worktree (rc 0: pode não ter olhado parte da árvore) → o worktree é MANTIDO, com o motivo 'avisou' e não 'alteração': 'não consegui saber' nunca vira 'limpo' (rc=$RC)"
  find "$T/home/.local/bin" -name git -delete; pv stop dog-remote-gawarn001 </dev/null; [ $RC = 0 ] && [ ! -e "$w" ] && evwt dog-remote-gawarn001 removed; ok $? "wt: ...e sem o aviso o MESMO stop (repetido) recolhe o worktree limpo (rc=$RC)"
  [ -n "$(sed -n 's/.*\(gracefulStopAll\).*/\1/p' "$HERE/../docs/runbooks/hetzner-hardening.md" | head -1)" ] && [ -n "$(sed -n 's/.*\(gracefulStopAll\).*/\1/p' "$doc" | head -1)" ]; ok $? "wt: os dois runbooks avisam que trocar [session] provider para hybrid derruba TODAS as sessões em execução (gracefulStopAll) — não existe 'recarga suave' para elas"
  # --- contrato com o script de verdade: o caminho que o provider calcula é o que o hetzner-remote-git.sh monta ---
  grep -qF 'GR=${GT_REMOTE_GIT:-$HOME/gt-remote/git}' "$HERE/hetzner-remote-git.sh" && grep -qF 'path="$GR/$RIG/wt/$bead"' "$HERE/hetzner-remote-git.sh" && grep -qF 'g() { git -C "$GR/$RIG/repo.git" "$@"; }' "$HERE/hetzner-remote-git.sh"; ok $? "wt: contrato: <git>/<rig>/wt/<sessão> e <git>/<rig>/repo.git são o que o hetzner-remote-git.sh monta"
  grep -qF "RE_RIG='^[a-z][a-z0-9_-]{0,40}\$'; RE_BEAD='^[a-z0-9][a-z0-9._-]{0,60}\$'" "$HERE/hetzner-remote-git.sh"; ok $? "wt: contrato: os formatos de rig e de nome de worktree que o provider valida são os do script"
  cfg 3; install_host
}

g_acct() {  # a sessão claude do host nasce na conta 'current' do pool do mini (ga-2hd02v.7.1): a chave é lida NO MINI pelo `secret` e vai só pela entrada padrão do ssh
  local KA=sk-ant-FAKEalfa-0123456789abcdef KB=sk-ant-FAKEbeta-0123456789abcdef pool="$T/pool.json" vault="$T/vault" sl="$T/secret.log" extra mode bad x r1
  extra=$(jq -n --arg f "$pool" --arg s "$T/bin/secret" '{claude_account:{current_file:$f,secret:$s}}')
  mkdir -p "$vault" "$T/tmp" "$T/home/.local/bin"; : > "$sl"
  printf '%s\n' "$KA" > "$vault/claude-oauth-token-alfa@example.test"; printf '%s\n' "$KB" > "$vault/claude-oauth-token-beta@example.test"
  # o "secret" do cofre: um arquivo por item em $FAKE_VAULT; FAKE_SECRET_MODE simula cofre fechado (rc 1, com chaves-isca em stdout e stderr), item ausente (rc 4) e saída sem forma de chave
  cat > "$T/bin/secret" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_SECRET_LOG:-/dev/null}"
case "${FAKE_SECRET_MODE:-}" in
  locked) echo "sk-ant-DECOYOUT0000000000000000"; echo "Error: vault is locked sk-ant-DECOYERR0000000000000000" >&2; exit 1;;
  notfound) echo "Not found: $1" >&2; exit 4;;
  garbage) echo "isto nao e uma chave"; exit 0;;
  spaced) echo "sk-ant-FAKEspaced 0123456789abcdef"; exit 0;;
esac
[ -f "$FAKE_VAULT/$1" ] || { echo "Not found: $1" >&2; exit 4; }
cat "$FAKE_VAULT/$1"
EOF
  chmod +x "$T/bin/secret"
  printf '#!/bin/sh\nprintf %%s "${CLAUDE_CODE_OAUTH_TOKEN-UNSET}" > "$1"\nexec cat\n' > "$T/home/.local/bin/claude"; chmod +x "$T/home/.local/bin/claude"  # o claude do "host": grava a env que recebeu
  export FAKE_VAULT="$vault" FAKE_SECRET_LOG="$sl"
  setpool() { printf '{"current":"%s","since":"2026-10-20T20:00:00Z","reason":"selftest"}\n' "$1" > "$pool"; }
  leaks() {  # 0 = a chave $1 apareceu em algum lugar por onde NÃO pode passar (argv do ssh, saída, estado/log do mini, disco do host, ps, scrollback, ambiente do tmux)
    local k="$1" s found=1
    for s in "$T/ssh.log" "$T/out" "$T/err" "$sl"; do has "$s" "$k" && found=0; done
    grep -rqF "$k" "$T/state" "$RR" "$RH" "$T/tmp" 2>/dev/null && found=0
    ps -eo args= | grep -F "$k" | grep -vF grep | grep -q . && found=0
    for s in $(tmux -L "$SOCK" list-sessions -F '#{session_name}' 2>/dev/null); do tmux -L "$SOCK" capture-pane -p -S - -t "=$s:" 2>/dev/null | grep -qF "$k" && found=0; done
    tmux -L "$SOCK" show-environment -g 2>/dev/null | grep -qF "$k" && found=0
    return $found
  }
  setpool alfa@example.test; cfg 3 25 "$extra"; fresh
  pv --dry-run start remote-test-ac1 < <(req "claude $T/ac1.out"); r1=$RC
  [ $r1 = 0 ] && [ "$(jq -r '.claude_account.current' "$T/out")" = alfa@example.test ] && [ ! -s "$sl" ] && ! has "$T/out" "$KA" && nossh; ok $? "acct: dry-run diz de qual conta seria a chave, NÃO lê o cofre e não mostra chave nenhuma (rc=$r1)"
  fresh; TMPDIR="$T/tmp" pv start remote-test-ac1 < <(req "claude $T/ac1.out"); ok $RC "acct: start de sessão claude abre (rc=$RC $(head -c 200 "$T/err"))"
  [ "$(cat "$T/ac1.out" 2>/dev/null)" = "$KA" ]; ok $? "acct: a sessão do host nasce com CLAUDE_CODE_OAUTH_TOKEN = a chave da conta current do pool (alfa)"
  [ "$(grep -c . "$sl")" = 1 ] && has "$sl" "claude-oauth-token-alfa@example.test"; ok $? "acct: o cofre foi lido UMA vez, pelo item da conta atual"
  ! leaks "$KA"; ok $? "acct: a chave não aparece no argv do ssh, na saída, no estado/log do mini, no disco do host, no ps, no scrollback nem no ambiente do tmux"
  printf '%s' "$KA" > "$T/tmp/controle"; leaks "$KA"; r1=$?; rm -f "$T/tmp/controle"; ok $r1 "acct: (controle positivo) a varredura de vazamento acusa a chave quando ela está de fato no disco do host"
  setpool beta@example.test; fresh; TMPDIR="$T/tmp" pv start remote-test-ac2 < <(req "claude $T/ac2.out"); r1=$RC
  [ $r1 = 0 ] && [ "$(cat "$T/ac2.out" 2>/dev/null)" = "$KB" ]; ok $? "acct: o pool do mini trocou de conta → a sessão NOVA nasce com a chave da conta nova (beta) (rc=$r1)"
  ! leaks "$KB"; ok $? "acct: ...e a chave da conta nova também não vaza"
  for mode in locked notfound garbage spaced; do
    : > "$sl"; fresh; FAKE_SECRET_MODE=$mode pv start remote-test-ac3 < <(req "claude $T/ac3.out"); r1=$RC
    [ $r1 = 1 ] && nossh && [ ! -e "$T/ac3.out" ] && [ "$(count)" = 2 ] && ! has "$T/err" DECOY && ! has "$T/out" DECOY && ! ls "$RR/run" 2>/dev/null | grep -q ac3; ok $? "acct: secret '$mode' → o start RECUSA (rc 1) sem ssh, sem sessão, sem lançador, sem repetir o que o secret escreveu, e NÃO cai no login fixo do nó (rc=$r1)"
  done
  FAKE_SECRET_MODE=notfound pv start remote-test-ac3 < <(req "claude $T/ac3.out"); has "$T/err" 'sem chave cadastrada' && has "$T/err" beta@example.test; ok $? "acct: conta atual SEM item no cofre → o motivo diz 'sem chave cadastrada' e a conta (não é cofre ilegível)"
  FAKE_SECRET_MODE=locked pv start remote-test-ac3 < <(req "claude $T/ac3.out"); has "$T/err" 'ilegível' && has "$T/err" beta@example.test; ok $? "acct: cofre fechado → o motivo diz 'ilegível' e a conta"
  for bad in AUSENTE '{' '[]' '{}' '{"current":""}' '{"current":5}' '{"current":"a b@x.test"}' '{"current":"-x@y.test"}' '{"current":"x@y.test\nz"}' '{"current":"nao-e-email"}'; do
    if [ "$bad" = AUSENTE ]; then rm -f "$pool"; else printf '%s\n' "$bad" > "$pool"; fi
    : > "$sl"; fresh; pv start remote-test-ac4 < <(req "claude $T/ac4.out"); r1=$RC
    [ $r1 = 1 ] && nossh && [ ! -s "$sl" ] && [ ! -e "$T/ac4.out" ] && has "$T/err" 'conta atual'; ok $? "acct: arquivo do pool $bad → recusa (rc 1) dizendo que não sabe a conta atual, sem ssh e sem tocar no cofre (rc=$r1)"
  done
  setpool alfa@example.test; : > "$sl"; FAKE_SECRET_MODE=locked pv start acct-cat < <(req "cat"); r1=$RC
  [ $r1 = 0 ] && [ ! -s "$sl" ]; ok $? "acct: sessão que NÃO é claude não toca no cofre (nem com ele fechado) e abre normalmente (rc=$r1)"; pv stop acct-cat </dev/null
  cfg 3; : > "$sl"; fresh; pv start remote-test-ac5 < <(req "claude $T/ac5.out"); r1=$RC
  [ $r1 = 0 ] && [ "$(cat "$T/ac5.out" 2>/dev/null)" = UNSET ] && [ ! -s "$sl" ]; ok $? "acct: host SEM o bloco claude_account = como antes: nenhuma env nova e o cofre não é tocado (rc=$r1)"
  for bad in '"texto"' '[]' '{}' '{"current_file":"relativo.json"}' '{"current_file":"/x/p.json","extra":1}' '{"current_file":5}' '{"current_file":"/x/p.json","secret":"relativo"}'; do
    cfg 3 25 "{\"claude_account\":$bad}"; fresh; pv start remote-test-ac6 < <(req "claude $T/ac6.out"); r1=$RC
    [ $r1 = 1 ] && nossh && has "$T/err" claude_account; ok $? "acct: claude_account mal formado ($bad) recusa a config nomeando a chave, sem ssh (rc=$r1)"
  done
  for x in remote-test-ac1 remote-test-ac2 remote-test-ac5; do pv stop $x </dev/null; done
  rm -f "$T/home/.local/bin/claude" "$T/bin/secret"; unset FAKE_VAULT FAKE_SECRET_LOG; cfg 3
}

all() { group proto && g_proto; group dry && g_dry; group live && g_live; group cap && g_cap; group down && g_down; group meta && g_meta; group conf && g_conf; group guard && g_guard; group terr && g_terr; group gate && g_gate; group prep && g_prep; group wt && g_wt; group mbp && g_mbp; group acct && g_acct; return 0; }

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
  mutant guard "guarda de /Users/ (nenhum /Users/ é recusado)" 's/if any(u != cfg.home for u in/if any(False for u in/'
  mutant mbp "guarda de /Users/ (qualquer /Users/ é recusado, até o home do host)" 's/if any(u != cfg.home for u in/if any(True for u in/'
  mutant mbp "presence_gate fora de true/false aceito" 's/if k in h and not isinstance(h\[k\], bool):/if False:/'
  mutant mbp "list-running exige default_host" 's/^    cfg_hosts = load_config()\[2\].get("hosts")$/    cfg_hosts = Cfg().names/'
  mutant mbp "sem regra de presença no start" 's/if cfg.gate and not dry:/if False:/'
  mutant mbp "gate com host vazio avalia o default_host" 's/        if op == "gate" and not arg:  #/        if False:  #/'
  mutant mbp "gate em dry-run libera" 's/    if cfg.gate and dry:/    if False:/'
  mutant mbp "presença ilegível passa (só 'uso' explícito recusa)" 's/if kv.get("presence") != "livre":/if kv.get("presence") == "uso":/'
  mutant mbp "pausa local ignorada" 's/if kv.get("paused") != "0" or kv.get("paused_local") != "0":/if kv.get("paused") != "0":/'
  mutant mbp "rc 99 (pausa/bandeira) não reconhecido" 's/if r.returncode == 99:/if False:/'
  mutant mbp "slot_cap da checagem ignorado" 's/cap = min(cap, g\["slot_cap"\])/pass/'
  mutant mbp "host pelo nome da sessão" 's/return m.group(1) if m else ""/return ""/'
  mutant mbp "sem vigia de prioridade" 's/^    if cfg.gate:  # o vigia nasce.*$/    if False:/'
  mutant mbp "sem conferir o zdot do bundle" 's/^    if cfg.spath:  # o zdot do bundle/    if False:  # o zdot do bundle/'
  mutant mbp "sem ZDOTDIR no lançador" 's/out += \[f"export ZDOTDIR={q(cfg.zdot)}", /out += [/'
  mutant mbp "sem CLAUDE_ENV_FILE no lançador" "s/f\"export CLAUDE_ENV_FILE={q(cfg.zdot + '\/env.sh')}\", //"
  mutant mbp "sem o PATH explícito no lançador" 's/, f"export PATH={q(cfg.spath)}"\]/]/'
  mutant mbp "claude sem o caminho absoluto" 's/^    if cfg.claude_bin:  #/    if False:  #/'
  mutant mbp "comando conferido no PATH do host, não no da sessão" 's/(PATH={q(cfg.spath)}; {look})" if cfg.spath else look/{look}" if cfg.spath else look/'
  mutant mbp "notebook sem session_env aceito" 's/^            if self.sleeps:$/            if False:/'
  mutant mbp "session_env com pasta oculta/repetida aceito" 's/if len(set(dirs)) != len(dirs) or any(c.startswith(".") for d in dirs for c in d.split("\/")):/if False:/'
  mutant mbp "session_env mal formado aceito" 's/if not isinstance(v, dict) or set(v) != {"path", "claude"} or not isinstance(v\["path"\], list) or not v\["path"\]:/if not isinstance(v, dict):/'
  mutant mbp "PATH extra do host" 's/"".join(d + ":" for d in cfg.path_extra)/""/'
  mutant mbp "host que dorme sempre ignorado no list-running" 's/if cfg.sleeps and not cfg.known():/if cfg.sleeps:/'
  mutant mbp "host que NÃO dorme também ignorado no list-running" 's/if cfg.sleeps and not cfg.known():/if not cfg.known():/'
  mutant mbp "registro de sessões nunca marcado" 's/^                open(f, "a").close()/                pass/'
  mutant mbp "list-running engole qualquer falha de host que dorme" 's/except Unreachable as e:  #/except Fail as e:  #/'
  mutant mbp "registro só depois do start confirmado" 's/^        cfg.mark(name, True)$/        pass/'
  mutant mbp "recusa clara do host não limpa o registro" 's/^            cfg.mark(name, False)$/            pass/'
  mutant mbp "list-running apaga registro mais novo que a pergunta" 's/ and os.stat(os.path.join(run_d, m)).st_mtime < t0//'
  mutant mbp "notebook sem regra de presença aceito" 's/if self.sleeps and not self.gate:/if False:/'
  mutant mbp "número do pool lido como host" 's/if m and m.group(1).isdigit():/if False:/'
  mutant dry "lançador de pool do mini não vira claude" 's/^    command = re.sub(.*$/    command = m.map(req.get("command") or "")/'
  mutant dry "lançador de pool: sem a âncora do começo (env X=1 <lançador> também vira)" 's/re.sub("^" + /re.sub("" + /'
  mutant dry "lançador de pool: sem a fronteira do fim (<lançador>.bak também vira)" 's/ + r"(?=\\s|\$)", "claude"/ + "", "claude"/'
  mutant dry "lançador de pool: de qualquer pasta de packs (packs/outro também vira)" 's#^POOL_WRAPPER = "/packs/town-deltas/assets/scripts/#POOL_WRAPPER = "/packs/[^ ]*/#'
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
  mutant gate "sem rodar o --selfcheck" 's/o=\$(python3 -I {g} --selfcheck {st} {q(work_dir)} 2>&1)/o=$(true)/'
  mutant gate "script do host que sai 0 (a recusa vira 'abriu')" 's/exit {EX_POLICY}/exit 0/g'
  mutant gate "guarda do repositório ilegível passa" 's/^        raise Fail(f"sessão real {name!r} recusada: não consegui ler.*$/        sha = ""/'
  mutant prep "sem o preparo no start" 's/\.replace("@PREP@", prepare_script(cfg))/.replace("@PREP@", "")/'
  mutant prep "sem gravar a identidade git" 's/^git -C "\$W" config --worktree user.name "\$N" \&\& git -C "\$W" config --worktree user.email "\$N@gastown.invalid" || pfail/true || pfail/'
  mutant prep "sem conferir que a identidade gravada é a que vale" 's/^\[ "\$(git -C "\$W" config --get user.name)" = "\$N" \] \&\& \[ "\$(git -C "\$W" config --get user.email)" = "\$N@gastown.invalid" \] || pfail/true || pfail/'
  mutant prep "core.bare não sai do config compartilhado (o commit do worktree quebra)" 's/ \&\& git -C "\$C" config --unset core.bare;/;/'
  mutant prep "sem conferir que a pasta é worktree git" 's/^\[ "\$(git -C "\$W" rev-parse --is-inside-work-tree 2>\/dev\/null)" = true \] || pfail/true || pfail/'
  mutant prep "pasta ausente não recusa (o mkdir do start a criaria)" 's/^\[ -d "\$W" \] || pfail/true || pfail/'
  mutant prep "sem gravar a confiança da pasta" 's/pr.update(hasTrustDialogAccepted=True, hasCompletedProjectOnboarding=True)/pr.update(hasCompletedProjectOnboarding=True)/;s/ and back\["hasTrustDialogAccepted"\] is True//'
  mutant prep "~/.claude.json ausente/ilegível vira {} e é regravado" 's/^    d = json.load(open(p))  #/    d = {}  #/'  # âncora no CÓDIGO, não no texto do comentário (reescrito, o padrão antigo deixou de casar e o mutante virou no-op)
  mutant prep "a recusa do preparo sai 0 (o start 'abriu' sem sessão)" 's/exit @EXPREP@/exit 0/'
  mutant prep "preparo desligado por padrão" 's/self.prepare = h.get("worktree_prepare", not self.gate)/self.prepare = h.get("worktree_prepare", False)/'
  mutant prep "preparo ligado por padrão também no notebook" 's/self.prepare = h.get("worktree_prepare", not self.gate)/self.prepare = h.get("worktree_prepare", True)/'
  mutant prep "worktree_prepare fora de true/false aceito" 's/if "worktree_prepare" in h and not isinstance(h\["worktree_prepare"\], bool):/if False:/'
  mutant prep "o dry-run não diz o preparo" 's/prepare=({"git_user": name,.*$/prepare=None,/'
  mutant dry "o dry-run não diz a recusa de política que o start daria" 's/            would_refuse = str(e)/            pass/'
  mutant dry "o dry-run diz 'teste' para tudo" 's/session_kind="teste" if TEST_RE.fullmatch(name) else "real"/session_kind="teste"/'
  mutant wt "o start não chama o wt-add" 's/\.replace("@WTADD@", wtadd_sh(wt, name) if wt else "")/.replace("@WTADD@", "")/'
  mutant wt "wt-add que falha não derruba o start" 's/; exit {EX_PREP}; }}\\n"/; true; }}\\n"/'
  mutant wt "wt-add sem GT_REMOTE_GIT (o script cairia no HOME dele)" 's/GT_REMOTE_GIT={q(wt\[.git.\])} {q(wt/{q(wt/'
  mutant wt "sem o piso do prazo do start" 's/start_timeout = max(cfg.start_timeout, WT_START_FLOOR) if wt else cfg.start_timeout/start_timeout = cfg.start_timeout/'
  mutant wt "o work_dir do template vale no lugar do worktree" 's/        p\["work_dir"\] = wt\["path"\].*$/        pass/'
  mutant wt "guarda de clone ANTES do wt-add (aprova a pasta ausente)" 's/replace("@GATE0@", "" if wt else gate).replace("@GATE1@", gate if wt else "")/replace("@GATE0@", gate).replace("@GATE1@", "")/'
  mutant wt "start que falha depois do wt-add não recolhe o worktree" 's/            + "trap .*$/            + "")/'
  mutant wt "stop recolhe mesmo com alteração não commitada" '/\[ -z "\$wst" \] ||/d'
  mutant wt "stop recolhe mesmo com commit que o origin não tem" 's/\[ "\$wpub" -eq 1 \] ||/true ||/'
  mutant wt "git que não lê o worktree vira 'limpo'" 's/wst=\$(git -C @WT@ status --porcelain 2>"\$wse") ||.*$/wst=$(git -C @WT@ status --porcelain 2>\/dev\/null) || :/;s/wh=\$(git -C @WT@ rev-parse HEAD 2>\/dev\/null) ||.*$/wh=$(git -C @WT@ rev-parse HEAD 2>\/dev\/null) || :/'
  mutant wt "wt-rm que falha derruba o stop" 's/wtclean\\nexit 0"/wtclean"/;s/echo "WT kept wt-rm falhou: \$(printf %s "\$wo" | tail -n 1)"; return 0;/exit 1;/'
  mutant wt "stop sem GT_REMOTE_GIT no wt-rm" 's/wo=\$(GT_REMOTE_GIT=@GR@ @BIN@ wt-rm/wo=$(@BIN@ wt-rm/'
  mutant wt "o branch publicado fica no repositório" '/\[ -z "\$wb" \] || git -C @REPO@ update-ref -d/d'
  mutant wt "papel fora do mapa também ganha worktree" 's/rig = cfg.wt_rigs.get(m.group(1)) if m else None/rig = next(iter(cfg.wt_rigs.values()), None) if m else None/'
  mutant wt "nome impróprio para worktree aceito" 's/    if not WT_NAME_RE.fullmatch(name):/    if False:/'
  mutant wt "worktree_rigs de qualquer forma aceito" 's/        if not isinstance(wr, dict) or not all(.*$/        if False:/'
  mutant wt "cauda de bead lida como pedido de host" 's/if m.group(2) == "" or m.group(1) == "adhoc":/if m.group(1) == "adhoc":/'
  mutant wt "adhoc lido como pedido de host" 's/if m.group(2) == "" or m.group(1) == "adhoc":/if m.group(2) == "":/'
  mutant wt "pedido de host no meio do nome vira cauda (host errado cai no padrão)" 's/if m.group(2) == "" or m.group(1) == "adhoc":/if True:/'
  mutant wt "stop com worktree sem o piso de prazo" 's/max(cfg.timeout, WT_STOP_FLOOR) if wt else 0)/0)/'
  mutant wt "stop com nome impróprio para worktree falha em vez de derrubar a sessão" 's/    except Fail as e:  # stop: nome/    except OSError as e:  # stop: nome/'
  mutant wt "wt-add que morre no meio não é desfeito" 's/ || wtundo; echo/ || true; echo/'
  mutant wt "o desfazer pega até a pasta que já existia antes do start" 's/\[ \\"\$wpre\\" -eq 1 \] || wtundo;/wtundo;/'
  mutant wt "o desfazer não tira o branch novo" 's/\[ "\$wub" = "\$wum" \] \&\& git/false \&\& git/'
  mutant wt "o desfazer não chama o wt-rm" 's/^  GT_REMOTE_GIT=@GR@ @BIN@ wt-rm @RIG@ @NAME@ >\/dev\/null 2>\&1$/  :/'
  mutant wt "aviso do git em stderr é jogado fora (parte da árvore não lida vira 'limpo')" 's/status --porcelain 2>"\$wse"/status --porcelain 2>\/dev\/null/'
  echo "-- contra um stub que só sai 0 (a versão 'anterior' não tinha provider nenhum)"
  printf '#!/bin/sh\nexit 0\n' > "$T/stub"; chmod +x "$T/stub"
  r=$(GCSSH_MUTANT=1 GCSSH_ONLY="proto,dry,cap,down,conf,guard,gate,prep,wt" GCSSH_UNDER_TEST="$T/stub" bash "$0" 2>&1 | tail -1); echo "stub: $r"
  case "$r" in "RESULT 0/"*|"") ok 1 "stub deveria falhar quase tudo ($r)";; *) ok 0 "stub falha os casos novos ($r)";; esac
  echo "== final: $((n-fails))/$n ok =="
}
[ "$fails" = 0 ]
