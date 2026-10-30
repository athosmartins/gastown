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
#   gui (ga-w7qwl1.1.8) — o tmux do MBP nasce num LaunchAgent POR SESSÃO do domínio gráfico (launchd/claude falsos em $T/extra): o plist fica em <raiz>/run (nunca em ~/Library/LaunchAgents), o label tem o prefixo
#   fixo, o tmux server nasce no domínio gráfico e o claude da sessão enxerga o login, o claude só roda `auth status` e o Keychain não é tocado; o stop faz bootout, apaga e PROVA a ausência (print rc 113; 112 = sem
#   o domínio; rc 1 ou label ainda carregado = o stop FALHA e a sessão fica no registro); o start recusa (exit 1, com a causa, nada aberto/carregado/em run/, evento 'refused') sem sessão gráfica, com o claude
#   deslogado, ilegível, contraditório, travado, com plutil/bootstrap/tmux do agente falhando; varre antes de criar o novo as órfãs do prefixo (só arquivos, só no domínio, carregada+arquivos), poupa a de sessão
#   viva e o que não é nosso, e se não prova a ausência de uma órfã não cria o agente novo; teto, nome repetido, sessão que morre logo e a regra de presença vêm antes/limpam; config de gui_agent/gui_wait_s/gui_proof_s.
#   prep (ga-2hd02v.1.5.9) — o start grava a identidade git POR worktree e a confiança da pasta em ~/.claude.json do host, e qualquer falha derruba o start sem abrir nada: espelho BARE (sem
#   extensions.worktreeConfig: o core.bare sai do config compartilhado e o commit do worktree continua funcionando, autor = a sessão), modo 600 e o resto do arquivo preservados, idempotente, uma identidade por
#   worktree; pasta ausente / comum, ~/.claude.json ausente / ilegível (intacto, byte a byte) / com forma estranha, config.worktree travado, identidade que o git não lê de volta → exit 1 com o motivo, nenhum
#   lançador, a pasta ausente não vira diretório; dry-run mostra o `prepare`; worktree_prepare explícito nos dois sentidos, padrão LIGADO no servidor e DESLIGADO no host de presença (notebook), não-booleano recusa sem ssh.
#   wt (ga-2hd02v.1.7 e 1.8) — o start cria o worktree da sessão (wt-add) e o stop o recolhe (wt-rm) SÓ quando nada se perde: papel mapeado em `worktree_rigs` abre DENTRO do worktree do wt-add (com identidade e
#   confiança), o guarda de clone olha o worktree JÁ criado, wt-add / preparo / guarda que falham deixam o host como estava, teto e 'já existe' recusam ANTES de criar; o stop recolhe o limpo e publicado e MANTÉM
#   o sujo, o não publicado e o que o git não consegue ler (e nunca muda o rc do stop); papel sem mapa e host sem a chave = como antes; nomes que o engine gera (dog-remote-<cauda>, dog-remote-adhoc-<10>) não são
#   pedido de host (host fora da config no meio do nome segue recusando); o identity_pattern do runbook casa com eles e só com eles; contrato com o hetzner-remote-git.sh de verdade (caminhos e formatos).
#   lr (ga-it7qiq.5) — cache de TTL curto do list-running: a 2ª chamada dentro do prazo não faz ssh e o prefixo filtra a lista guardada; start e stop invalidam (o start antes E depois do ssh dele, e uma resposta lida
#   antes de um start que só chega depois dele não é guardada: ssh falso que SEGURA a resposta); erro, ssh fora e resposta cortada continuam erro e nada fica guardado, e cache vencido + host fora do ar é erro, não a lista
#   velha; cache vencido, do futuro, vazio, ilegível ou de forma errada pergunta ao host; [] é resposta; geração ilegível = sem cache; dry-run não usa nem altera; list_cache_s (0 desliga, padrão 10, 0-120, o resto recusa a
#   config); só o host com cache é poupado; lista do cache não mexe no registro de sessões; falha ao invalidar não derruba o start. A base de cfg()/cfgm() fixa list_cache_s=0 em todo host: os outros grupos esperam um ssh por list-running.
#   lrd (ga-sml4tqk) — host FORA do ar: o fato "o host não respondeu" (só ssh 255 / tempo esgotado) também é guardado por list_down_cache_s s (30 por padrão, 0 desliga, teto 60; list_cache_s 0 desliga os dois) e devolve ERRO rápido sem ssh, nunca
#   lista, nem vazia: 20 list-running seguidos com o ssh levando 1 s para falhar = 1 ssh, todos rc 1, bem abaixo de 20 s; resposta cortada/sem marcadores NÃO é guardada; vence o prazo = pergunta de novo; host de volta, start e stop apagam o
#   fato; arquivo torto/ilegível/vazio/de outra geração/do futuro = pergunta ao host (nunca um "fora" inventado); dry-run não usa; list_down_cache_s validada (o resto recusa a config).
#   abort (ga-0k82lw) — o start que o mini ABANDONOU (prazo do provider estourado; provider morto com kill -9 na parte lenta) não deixa tmux no host, com o ssh falso dos dois jeitos: plain (fecha o canal ao matar o provider) e orphan (deixa o
#   script do host gravável, como o sshd com ControlMaster); o stop que chega na parte lenta do start com o provider vivo faz o start desistir dizendo que foi abandonado; controles: start lento dentro do prazo abre, stop e depois start novo do mesmo nome abre.
# CONTROLE NEGATIVO: cada guarda é removida do script (sed numa cópia) e o grupo que a cobre TEM que passar a falhar: teto do host, nome
#   exato (sessão, is-running, start), alvo de painel =nome:, guarda de /Users/, filtro de env, exit 2 das desconhecidas, marcador de fim,
#   erro de ssh, flock, "tmux sem acesso" tolerado como "sem servidor", o `has` que engole o erro do tmux, melhor esforço da sessão
#   ausente, o stop que não confere que a sessão sumiu, e o portão (sem a liberação, liberação de qualquer tipo, nome de teste frouxo ou sem
#   âncora, sem conferir o sha do guarda, sem rodar o --selfcheck, script do host que sai 0, guarda irmão ilegível), e a regra de presença do MBP (grupo mbp: guarda de /Users/, validação da config, recusa/pausa/slot_cap, vigia, PATH extra,
#   registro de sessões do list-running); 170 mutantes no total (33 do grupo gui: bootout/arquivos/prova de ausência do stop e da recusa, a varredura de órfãs e a ordem dela, o veredito do `auth status` (ilegível, rc, contraditório), plist fora de run/, label sem prefixo, KeepAlive, Aqua, validação da config, e os do start em duas chamadas: o piso da 2ª chamada, o rc 14 do abandonado contra o 15 do gui_agent, as funções do agente na 2ª; 5 do grupo abort: a marca <nome>.stop do stop, ga-0k82lw — o stop não a grava, o preparo do start não a apaga, a 2ª chamada não olha para ela, o stop não poda as marcas antigas (> 24 h), a poda sem limite de idade leva a marca recém-gravada; 20 do grupo lr: o cache nunca lido, start sem invalidar antes / depois, stop sem invalidar, gravação sem conferir a geração, prazo e relógio, geração e forma do arquivo, dry-run, list_cache_s em cinco formas, geração ilegível ou ausente, registro acertado com lista do cache, falha ao invalidar derrubando o start; 26 do grupo wt: wt-add/wt-rm do provider, o guarda DEPOIS do wt-add, o recolhimento só do que não perde trabalho e os nomes do engine; 9 do ambiente limpo da sessão, grupo mbp: session_env, ZDOTDIR, PATH explícito e claude absoluto, ga-w7qwl1.1.5).
#   Mais: contra um stub que só sai 0, quase tudo falha.
# VARIÁVEIS: GCSSH_UNDER_TEST (script a testar) · GCSSH_ONLY (grupos separados por vírgula) · GCSSH_NO_MUTANTS=1 · GCSSH_MUTANTS_ONLY=<grupo> (pula os casos e roda só os mutantes desse grupo) · GCSSH_SHARD=K/N (pula os casos e roda só os mutantes de ordem ≡ K mod N; K e N decimais sem sinal nem zero à esquerda, N de 1 a 9999, K de 0 a N-1, senão exit 2; o stub só no K=0: a campanha de mutantes em N processos). Rodar ZERO casos e ZERO mutantes (grupo que não existe em GCSSH_ONLY/GCSSH_MUTANTS_ONLY, fatia K/N sem mutante nenhum) FALHA com 'NADA RODOU' (exit 1), nunca sai como '0/0 ok'; o grupo `shard` prova isso
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${GCSSH_UNDER_TEST:-$HERE/gc-session-ssh}"
for v in $(env | sed -n 's/^\(GC_[A-Za-z0-9_]*\)=.*/\1/p') TMUX TMUX_PANE GC_SSH_HOST GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do unset "$v"; done  # + a identidade git do ambiente: o runner do nó exporta GIT_AUTHOR_*=gt, que vence o config do worktree e fazia o teste 'autor certo' do grupo prep reprovar no Linux (medido 18/10)  # o "servidor" é esta máquina: nada do ambiente de quem roda (ex.: GC_INSTANCE_TOKEN) pode vazar para as sessões de teste
T=$(cd "$(mktemp -d /tmp/gcs.XXXXXX)" && pwd -P)  # curto: o caminho do socket do tmux tem limite de ~100 caracteres
SOCK="gct$$"
export TMUX_TMPDIR="$T/tmux"; mkdir -p "$TMUX_TMPDIR" "$T/bin" "$T/home" "$T/remote/home" "$T/state"
cleanup() { for f in "$T"/lc/loaded/*.pid; do [ -e "$f" ] && kill -s TERM -- "-$(cat "$f")" 2>/dev/null; done; for s in "$SOCK" "${SOCK}b" "${SOCK}m"; do tmux -L "$s" kill-server 2>/dev/null; done; chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
RR="$T/remote/gt-remote/bundle"; RH="$T/remote/home"; CITY=/Users/test/gt/.city

cat > "$T/bin/ssh" <<'EOF'
#!/bin/sh
# ssh falso: registra, simula falhas (FAKE_SSH_*) e roda o comando remoto aqui mesmo (sem as opções -o/-t, sem o destino)
[ -z "${FAKE_SSH_LOG:-}" ] || printf '%s\n' "ssh $*" >> "$FAKE_SSH_LOG"
[ -z "${FAKE_SSH_FAIL:-}" ] || { [ -z "${FAKE_SSH_FAIL_AFTER:-}" ] || sleep "$FAKE_SSH_FAIL_AFTER"; echo "ssh: connect to host fakehost port 22: Connection timed out" >&2; exit 255; }  # FAKE_SSH_FAIL_AFTER=N: o host fora leva N s para falhar (o ConnectTimeout de verdade)
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
if [ -n "${FAKE_SSH_ORPHAN:-}" ]; then  # script do host solto dos canais do chamador (escrever em stdout/stderr nunca falha): o sshd com ControlMaster segue drenando os pipes do filho depois da morte do cliente (ga-0k82lw)
  o=$(mktemp -d); cat > "$o/in"; sh -c "$*" < "$o/in" > "$o/out" 2> "$o/err"; rc=$?; cat "$o/out"; cat "$o/err" >&2; rm -rf "$o"; exit $rc
fi
sh -c "$*"; rc=$?
[ -z "${FAKE_SSH_AFTER_MARK:-}" ] || : > "$FAKE_SSH_AFTER_MARK"  # o comando já rodou no "host" e a resposta ainda não voltou (o teste do cache espera por este arquivo)
[ -z "${FAKE_SSH_DELAY_AFTER:-}" ] || sleep "$FAKE_SSH_DELAY_AFTER"  # resposta lenta: a lista é lida AGORA e só chega ao chamador N s depois
[ -z "${FAKE_SSH_TIMES:-}" ] || echo "E $$ $(python3 -c 'import time;print(time.time())')" >> "$FAKE_SSH_TIMES"
exit $rc
EOF
chmod +x "$T/bin/ssh"

cfg() {  # cfg CAP [TIMEOUT] [EXTRA-JSON-do-host-a]  → $T/cfg.json (host a: socket $SOCK; host b: socket ${SOCK}b, teto 1)
  jq -n --argjson cap "$1" --argjson to "${2:-25}" --argjson extra "${3:-{\}}" --arg rr "$RR" --arg rh "$RH" --arg s "$SOCK" \
    '{default_host:"a", hosts:{a:({ssh:"fakehost",cap:$cap,remote_root:$rr,remote_home:$rh,socket:$s,mini_home:"/Users/test",timeout:$to,start_timeout:$to,real_sessions_released_by:"selftest",worktree_prepare:false}+$extra),
      b:{ssh:"fakehost",cap:1,remote_root:$rr,remote_home:$rh,socket:($s+"b"),mini_home:"/Users/test",real_sessions_released_by:"selftest",worktree_prepare:false}}} | .hosts |= map_values({list_cache_s:0} + .)' > "$T/cfg.json"  # list_cache_s:0 em todos os hosts: os grupos (menos lr) esperam um ssh por list-running; quem liga o cache passa list_cache_s no EXTRA
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
  # ga-2hd02v.11: saída SEM input tem de contar como atividade (session_activity só anda com input; o engine dormia a sessão no meio do trabalho)
  pv start live-out < <(req "sh -c 'sleep 3; echo saida-sem-input; exec cat'"); t0=$(date +%s); sleep 4.5
  pv get-last-activity live-out </dev/null; la=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(cat "$T/out")" +%s 2>/dev/null || date -u -d "$(cat "$T/out")" +%s 2>/dev/null)
  [ -n "$la" ] && [ "$la" -ge $((t0 + 2)) ]; ok $? "live: get-last-activity anda com a SAÍDA da sessão, sem input (t0=$t0 la=${la:-?})"
  pv stop live-out </dev/null
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
         gate_cmd:[$chk],presence_lib:$lib,path_extra:[$ex],session_env:{path:[$sb,"/usr/bin","/bin"],claude:$cl},gui_agent:true,real_sessions_released_by:"selftest"}+$extra),
      h:{ssh:"fakehost",cap:1,remote_root:"/Users/athos/gt-remote/bundle",remote_home:"/Users/athos",socket:($s+"h"),mini_home:"/Users/test",real_sessions_released_by:"selftest",worktree_prepare:false}}} | .hosts |= map_values({list_cache_s:0} + .)' > "$T/cfg.json"
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
  setup_gui
}
# ---- o domínio gráfico falso (ga-w7qwl1.1.8): tudo em $T/extra, que é o path_extra do host m (vem ANTES do PATH do sistema) ----
# launchctl: `print gui/<uid>` = a lista de serviços (rc 112 sem o domínio), `print gui/<uid>/<label>` (113 = ausente), `bootstrap` LANÇA o ProgramArguments do plist num grupo de processos próprio e com ambiente limpo
# (como o launchd: sem PATH do usuário, FAKE_LAUNCHD=1 marca "nasceu no gui"; só o TMUX_TMPDIR passa, para o tmux de teste cair na pasta de teste), `bootout` mata o grupo e esquece o label.
# lc.mode: stuck (bootout não remove), printfail (print do label dá rc 1: "não sei"), nogui (sem o domínio), bootfail (bootstrap falha).
setup_gui() {
  mkdir -p "$T/extra"; local py rt; py=$(command -v python3); rt=$(command -v tmux)
  cat > "$T/extra/launchctl" <<'EOF'
#!/bin/sh
LC=@T@/lc; MODE=$(cat @T@/lc.mode 2>/dev/null)
printf '%s\n' "launchctl $*" >> @T@/lc.log
case "$1" in
print)
  case "$2" in
    gui/*/*) [ "$MODE" != nogui ] || exit 112; [ "$MODE" != printfail ] || exit 1; [ -e "$LC/loaded/${2#gui/*/}" ] || exit 113; exit 0;;
    gui/*) { [ "$MODE" != nogui ] && [ -d "$LC/gui" ]; } || { echo "Bad request." >&2; exit 112; }
      printf 'gui/501 = {\n\ttype = login\n\tservices = {\n'
      for f in "$LC"/loaded/*; do case "$f" in *.pid) continue;; esac; [ -e "$f" ] || continue; printf '\t\t%6s  0  \t%s\n' "$(cat "$f.pid" 2>/dev/null || echo -)" "$(basename "$f")"; done
      printf '\t}\n\tdisabled services = {\n\t\t"com.gascity.remote-session.decoy" => disabled\n\t}\n}\n'; exit 0;;
  esac;;
bootstrap)
  [ "$MODE" != bootfail ] || { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
  { [ "$MODE" != nogui ] && [ -d "$LC/gui" ]; } || exit 112
  [ -f "$3" ] || { echo "Bootstrap failed: 2: No such file or directory" >&2; exit 2; }
  json=$(@PY@ -c 'import plistlib,sys,json;print(json.dumps(plistlib.load(open(sys.argv[1],"rb"))))' "$3") || exit 133
  label=$(printf '%s' "$json" | jq -r .Label); a1=$(printf '%s' "$json" | jq -r '.ProgramArguments[0]'); a2=$(printf '%s' "$json" | jq -r '.ProgramArguments[1]')
  [ ! -e "$LC/loaded/$label" ] || { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
  mkdir -p "$LC/loaded"; echo "$3" > "$LC/loaded/$label"
  if [ "$(printf '%s' "$json" | jq -r .RunAtLoad)" = true ]; then
    env -i HOME="$HOME" PATH=/usr/bin:/bin TMUX_TMPDIR="$TMUX_TMPDIR" FAKE_LAUNCHD=1 @PY@ -c 'import os,sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' "$a1" "$a2" </dev/null >/dev/null 2>&1 &
    echo $! > "$LC/loaded/$label.pid"
  fi
  exit 0;;
bootout)
  l=${2#gui/*/}; [ -e "$LC/loaded/$l" ] || exit 113
  [ "$MODE" != stuck ] || exit 0
  pid=$(cat "$LC/loaded/$l.pid" 2>/dev/null); [ -z "$pid" ] || kill -s TERM -- "-$pid" 2>/dev/null
  rm -f "$LC/loaded/$l" "$LC/loaded/$l.pid"; exit 0;;
esac
exit 64
EOF
  cat > "$T/claude" <<'EOF'
#!/bin/sh
# claude falso: só entende `auth status`, e o login depende de ONDE roda (FAKE_LAUNCHD=1 = dentro do launchd gui), como o do MBP (medido 19/10: pelo ssh loggedIn false, no gui true)
printf '%s FAKE_LAUNCHD=%s\n' "$*" "${FAKE_LAUNCHD:-0}" >> @T@/claude.log
[ "$1 $2" = "auth status" ] || exit 64
m=$(cat @T@/auth.mode 2>/dev/null); [ -n "$m" ] || m=in
case "$m" in
  in)      if [ "${FAKE_LAUNCHD:-}" = 1 ]; then printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n'; exit 0; else printf '{\n  "loggedIn": false\n}\n'; exit 1; fi;;
  out)     printf '{\n  "loggedIn": false\n}\n'; exit 1;;
  out0)    printf '{\n  "loggedIn": false\n}\n'; exit 0;;
  truerc)  printf '{\n  "loggedIn": true\n}\n'; exit 1;;
  garbage) echo banana; exit 0;;
  both)    printf '"loggedIn": true\n"loggedIn": false\n'; exit 0;;
  crash)   exit 2;;
  hang)    exec sleep 60;;
  slow)    sleep 7; printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n'; exit 0;;
esac
exit 0
EOF
  printf '#!/bin/sh\ncase " $* " in *" new-session "*) [ ! -e @T@/tmux.fail ] || { echo "create session failed: boom" >&2; exit 1; };; esac\nexec @RT@ "$@"\n' > "$T/extra/tmux"
  printf '#!/bin/sh\n[ ! -e @T@/plutil.fail ] || { echo "plist: Invalid" >&2; exit 1; }\n[ -x /usr/bin/plutil ] || exit 0\nexec /usr/bin/plutil "$@"\n' > "$T/extra/plutil"
  printf '#!/bin/sh\necho "security $*" >> @T@/security.log\nexit 1\n' > "$T/extra/security"
  sed -i.bak -e "s|@T@|$T|g" -e "s|@PY@|$py|g" -e "s|@RT@|$rt|g" "$T/extra/launchctl" "$T/claude" "$T/extra/tmux" "$T/extra/plutil" "$T/extra/security"; rm -f "$T"/extra/*.bak "$T"/claude.bak
  chmod +x "$T/extra/launchctl" "$T/claude" "$T/extra/tmux" "$T/extra/plutil" "$T/extra/security"; lcreset
}
lcreset() {  # o domínio gráfico existe e está vazio (agentes de antes são mortos); claude logado; nenhuma falha ligada
  local f; for f in "$T"/lc/loaded/*.pid; do [ -e "$f" ] && kill -s TERM -- "-$(cat "$f")" 2>/dev/null; done
  find "$T/lc" -mindepth 1 -delete 2>/dev/null; mkdir -p "$T/lc/gui" "$T/lc/loaded"; : > "$T/lc.log"; : > "$T/claude.log"; : > "$T/security.log"; echo in > "$T/auth.mode"; rm -f "$T/lc.mode" "$T/tmux.fail" "$T/plutil.fail"
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
  # sozinho o caso acima não separa o `isdigit`: a regra de cauda (o número no FIM do nome não pede host) devolve o mesmo default_host. Com sufixo só o `isdigit` salva.
  pv --dry-run start dog-remote-1-2 < <(req cat); [ $RC = 0 ] && [ "$(jq -r .host "$T/out")" = a ]; ok $? "mbp: um número nunca é host, nem com sufixo (<papel>-remote-<n>-<m> vai ao default_host, não recusa 'host 1') (rc=$RC $(head -c 120 "$T/err"))"
  jq 'del(.default_host)' "$T/cfg.json" > "$T/cfg.nd" && mv "$T/cfg.nd" "$T/cfg.json"
  pv start w-remote-m-1 < <(req cat); pv list-running w- </dev/null; [ $RC = 0 ] && has "$T/out" w-remote-m-1; ok $? "mbp: sem default_host o list-running ainda junta os hosts (rc=$RC $(head -c 120 "$T/err"))"
  pv stop w-remote-m-1 </dev/null
  cfg 3
}

# ---------- gui: o tmux do MBP nasce num LaunchAgent do domínio gráfico (ga-w7qwl1.1.8) — as 7 condições do Mayor (19/10) viram casos ----------
nload() { ls "$T/lc/loaded" 2>/dev/null | grep -vc '\.pid$'; }  # quantos labels o launchd falso tem carregados
nrun() { ls "$RR/run" 2>/dev/null | grep -c '^com\.gascity\.remote-session\.'; }  # quantos arquivos de agente sobram em <raiz>/run
evt() { jq -e --arg e "$1" --arg s "$2" 'select(.event==$e and .session==$s)' "$T/state/m/events.jsonl" >/dev/null 2>&1; }
lcline() { grep -n "$1" "$T/lc.log" | tail -1 | cut -d: -f1; }  # número da ÚLTIMA linha do log do launchctl que casa (vazio = nunca)
gui_refuse() {  # gui_refuse DESCRIÇÃO FRAGMENTO-DO-ERRO [auth.mode [lc.mode [arquivo-de-falha]]] — start recusado: exit 1 com a causa, nada aberto, nada carregado, nada em run/, evento 'refused', Keychain intocado, claude só 'auth status' no gui
  lcreset; [ -z "${3:-}" ] || echo "$3" > "$T/auth.mode"; [ -z "${4:-}" ] || echo "$4" > "$T/lc.mode"; [ -z "${5:-}" ] || : > "$T/$5"
  mkdir -p "$T/state/m"; : > "$T/state/m/events.jsonl"; fresh
  pv start w-remote-m-9 < <(req cat)
  [ $RC = 1 ] && has "$T/err" "$2" && [ "$(count x "${SOCK}m")" = 0 ] && [ "$(nload)" = 0 ] && [ "$(nrun)" = 0 ] && [ ! -e "$T/state/m/running/w-remote-m-9" ] && [ ! -s "$T/security.log" ] \
    && ! grep -qv '^auth status FAKE_LAUNCHD=1$' "$T/claude.log" && jq -e 'select(.event=="refused" and .session=="w-remote-m-9" and (.reason|startswith("gui_agent:")))' "$T/state/m/events.jsonl" >/dev/null 2>&1
  ok $? "gui: $1 → start recusado (exit 1) com a causa, nada aberto/carregado/em run/, evento 'refused' (rc=$RC $(head -c 140 "$T/err"))"
}

g_gui() {
  setup_mbp; cfgm '{"gui_proof_s":2}'; mode livre; fresh; local L=com.gascity.remote-session. b p o bn i v k rc
  mkdir -p "$T/state/m/running"; find "$T/state/m/running" -mindepth 1 -delete; : > "$T/state/m/events.jsonl"; : > "$T/state/m/session-ssh.log"  # o grupo mbp usa os mesmos nomes (w-remote-m-N): evento, registro e log dele não podem valer aqui
  # --- dry-run: o desenho (1: plist em <raiz>/run · 2: label de prefixo fixo · 5: o único comando do claude é `auth status`) ---
  pv --dry-run start w-remote-m-0 < <(req "claude --x")
  [ $RC = 0 ] && [ "$(jq -r .gui_agent.label "$T/out")" = "${L}w-remote-m-0" ] && [ "$(jq -r .gui_agent.plist "$T/out")" = "$RR/run/${L}w-remote-m-0.plist" ]; ok $? "gui: o dry-run mostra o agente: label com o prefixo fixo e o plist em <raiz>/run (rc=$RC)"
  ! grep -q 'LaunchAgents' "$T/out"; ok $? "gui: nada aponta para ~/Library/LaunchAgents (um agente que sobrevive a logout/reboot reabriria sessão sozinho)"
  jq -r '.gui_agent.plist_xml[]' "$T/out" > "$T/plist.out"
  grep -q '<key>RunAtLoad</key><true/>' "$T/plist.out" && grep -q '<key>KeepAlive</key><false/>' "$T/plist.out" && grep -q '<string>Aqua</string>' "$T/plist.out"; ok $? "gui: o plist roda ao carregar, NÃO se reergue sozinho (KeepAlive false) e só carrega na sessão Aqua"
  [ "$(jq -r '.gui_agent.bootstrap | join(" ")' "$T/out")" = "launchctl bootstrap gui/<uid> $RR/run/${L}w-remote-m-0.plist" ]; ok $? "gui: o carregamento é um bootstrap no domínio gui/<uid> do plist que está em run/"
  jq -r '.gui_agent.script[]' "$T/out" > "$T/agent.out"
  [ "$(grep -cF "$T/claude" "$T/agent.out")" = 1 ] && grep -qF "$T/claude auth status " "$T/agent.out" && ! grep -qiE 'security|keychain|setup-token|add-generic|logout|auth login|api[_-]?key|token' "$T/agent.out"; ok $? "gui: o agente chama o claude uma vez, só para 'auth status', e não toca Keychain nem credencial (5)"
  grep -qF "new-session -d -s w-remote-m-0" "$T/agent.out" && grep -qF "sh $RR/run/w-remote-m-0.sh" "$T/agent.out" && jq -r '.launcher[]' "$T/out" | grep -q 'taskpolicy -b -p'; ok $? "gui: a sessão que o agente abre é o MESMO lançador, com o vigia de prioridade (o agente não contorna a regra do MBP) (7)"
  nossh; ok $? "gui: o dry-run não conecta"
  pv --dry-run start w-1 < <(req "claude --x"); [ $RC = 0 ] && [ "$(jq -r .gui_agent "$T/out")" = null ]; ok $? "gui: host sem gui_agent (o servidor Linux) não ganha agente"
  # --- start: o tmux nasce no domínio gráfico, o claude da sessão enxerga o login, nada fora de run/, Keychain intocado ---
  lcreset; fresh; rm -f "$T/inside.out"
  pv start w-remote-m-1 < <(req "sh -c '$T/claude auth status > $T/inside.out 2>&1; exec cat'"); ok $RC "gui: sessão gráfica + claude logado → o start abre (rc=$RC $(head -c 200 "$T/err"))"
  for i in $(seq 1 20); do [ -s "$T/inside.out" ] && break; sleep 0.5; done
  [ "$(count x "${SOCK}m")" = 1 ] && [ "$(tmux -L "${SOCK}m" show-environment -g FAKE_LAUNCHD 2>&1)" = FAKE_LAUNCHD=1 ]; ok $? "gui: o tmux server nasceu DENTRO do domínio gráfico (o ambiente dele é o do launchd, não o do ssh)"
  grep -q '"loggedIn": true' "$T/inside.out" 2>/dev/null; ok $? "gui: o claude de dentro da sessão enxerga o login (o que pelo ssh sozinho dá false)"
  [ -e "$T/lc/loaded/${L}w-remote-m-1" ] && [ -f "$RR/run/${L}w-remote-m-1.plist" ] && [ -f "$RR/run/${L}w-remote-m-1.agent.sh" ]; ok $? "gui: o agente está carregado e o plist e o script ficam em <raiz>/run"
  grep -qx "launchctl bootstrap gui/$(id -u) $RR/run/${L}w-remote-m-1.plist" "$T/lc.log"; ok $? "gui: o bootstrap foi no domínio gui/<uid> com o plist de run/"
  [ ! -e "$RH/Library/LaunchAgents" ] && [ -z "$(find "$T" -name "${L}*" -not -path "$T/lc/*" -not -path "$RR/run/*" 2>/dev/null)" ]; ok $? "gui: nada foi gravado em ~/Library/LaunchAgents nem fora de run/ (1)"
  [ -s "$T/claude.log" ] && ! grep -qv '^auth status FAKE_LAUNCHD=1$' "$T/claude.log" && [ ! -s "$T/security.log" ]; ok $? "gui: o claude só rodou 'auth status', sempre dentro do domínio gráfico, e o Keychain não foi tocado (5)"
  [ "$(cat "$RR/run/${L}w-remote-m-1.agent.res" 2>/dev/null)" = ok ] && ! grep -rqs authMethod "$RR/run" "$T/state" "$T/err"; ok $? "gui: a saída do 'auth status' (e-mail, organização) não é gravada em lugar nenhum: só o veredito 'ok'"
  evt started w-remote-m-1; ok $? "gui: o start deixa a linha 'started' no events.jsonl"
  # --- 3: o stop faz bootout, apaga e PROVA a ausência ---
  : > "$T/lc.log"; pv stop w-remote-m-1 </dev/null; rc=$RC
  b=$(lcline "^launchctl bootout .*${L}w-remote-m-1\$"); p=$(lcline "^launchctl print gui/[0-9]*/${L}w-remote-m-1\$")
  [ $rc = 0 ] && [ -n "$b" ] && [ -n "$p" ] && [ "$p" -gt "$b" ]; ok $? "gui: o stop faz bootout e DEPOIS confere pelo launchctl print que o label sumiu (3) (rc=$rc bootout@${b:-nunca} print@${p:-nunca})"
  [ "$(nload)" = 0 ] && [ "$(nrun)" = 0 ] && [ "$(count x "${SOCK}m")" = 0 ]; ok $? "gui: depois do stop não sobra agente carregado, plist, script nem veredito em run/ (3)"
  evt stopped w-remote-m-1 && [ ! -e "$T/state/m/running/w-remote-m-1" ]; ok $? "gui: stop completo → linha 'stopped' e a sessão sai do registro"
  pv start w-remote-m-1 < <(req cat); ok $RC "gui: depois do stop o mesmo nome abre de novo (o label foi liberado de verdade) (rc=$RC $(head -c 160 "$T/err"))"; pv stop w-remote-m-1 </dev/null
  # --- 3: sem prova, o stop FALHA (e o registro da sessão fica): bootout que não removeu · launchctl print que não deu para ler ---
  pv start w-remote-m-2 < <(req cat); echo stuck > "$T/lc.mode"; : > "$T/state/m/events.jsonl"; pv stop w-remote-m-2 </dev/null
  [ $RC = 1 ] && has "$T/err" 'a ausência NÃO foi provada' && [ -e "$T/lc/loaded/${L}w-remote-m-2" ] && [ -e "$T/state/m/running/w-remote-m-2" ] && ! evt stopped w-remote-m-2; ok $? "gui: bootout que não removeu o label → o stop FALHA ('ausência NÃO foi provada'), mantém o registro e não anuncia 'stopped' (3) (rc=$RC $(head -c 140 "$T/err"))"
  rm -f "$T/lc.mode"; pv stop w-remote-m-2 </dev/null; [ $RC = 0 ] && [ "$(nload)" = 0 ] && evt stopped w-remote-m-2 && [ ! -e "$T/state/m/running/w-remote-m-2" ]; ok $? "gui: com o launchd de volta ao normal o mesmo stop termina e limpa (rc=$RC)"
  pv start w-remote-m-2 < <(req cat); echo printfail > "$T/lc.mode"; : > "$T/state/m/events.jsonl"; pv stop w-remote-m-2 </dev/null  # eventos zerados: o 'stopped' do mesmo nome, do caso acima, não pode valer aqui
  [ $RC = 1 ] && has "$T/err" 'launchctl print rc=1' && [ -e "$T/state/m/running/w-remote-m-2" ] && ! evt stopped w-remote-m-2 && [ "$(nload)" = 0 ]; ok $? "gui: launchctl print que não deu para ler (rc 1) NÃO vale como ausência, mesmo com o label de fato removido: o stop falha (3) (rc=$RC $(head -c 140 "$T/err"))"
  rm -f "$T/lc.mode"; pv stop w-remote-m-2 </dev/null; [ $RC = 0 ] && evt stopped w-remote-m-2; ok $? "gui: ...e lido de novo (113) o stop termina (rc=$RC)"
  pv start w-remote-m-2 < <(req cat); echo nogui > "$T/lc.mode"; : > "$T/state/m/events.jsonl"; pv stop w-remote-m-2 </dev/null
  [ $RC = 0 ] && evt stopped w-remote-m-2; ok $? "gui: sem o domínio gui (print rc 112) nada vive nele: conta como ausência provada — decisão de projeto, o Mayor escreveu 113 (rc=$RC $(head -c 140 "$T/err"))"
  # --- 6: sem sessão gráfica, ou com o claude deslogado/ilegível no domínio gráfico, o start RECUSA (exit != 0, com o motivo) ---
  gui_refuse "sem sessão gráfica (o claude não alcançaria o Keychain)" 'não há sessão gráfica' "" nogui; ! grep -q ' bootstrap ' "$T/lc.log"; ok $? "gui: ...e sem sessão gráfica nada chegou a ser carregado"
  gui_refuse "claude deslogado no domínio gráfico (loggedIn false, rc 1)" 'DESLOGADO' out
  gui_refuse "claude deslogado no domínio gráfico (loggedIn false, rc 0)" 'DESLOGADO' out0
  gui_refuse "auth status ilegível (rc 0 e sem loggedIn)" 'não consegui ler o login' garbage; ! grep -rqs banana "$T/err" "$T/state"; ok $? "gui: ...e a saída ilegível do claude não vai para a mensagem nem para o estado"
  gui_refuse "auth status que quebra (rc 2, sem saída)" 'não consegui ler o login' crash
  gui_refuse "loggedIn true com rc 1 (sinal em que não se confia)" 'não consegui ler o login' truerc
  gui_refuse "true e false na mesma saída (contraditória)" 'não consegui ler o login' both
  cfgm '{"gui_proof_s":2,"gui_wait_s":2}'; gui_refuse "auth status que trava" 'não respondeu em 2s' hang; cfgm '{"gui_proof_s":2}'
  gui_refuse "plutil reprova o plist" 'plutil -lint' "" "" plutil.fail
  gui_refuse "launchctl bootstrap que falha" 'launchctl bootstrap do agente' "" bootfail
  gui_refuse "tmux do agente que não abre a sessão" 'o tmux do agente não abriu a sessão' "" "" tmux.fail; has "$T/err" boom; ok $? "gui: ...e a causa do tmux vem na mensagem"
  lcreset; echo out > "$T/auth.mode"; echo stuck > "$T/lc.mode"; : > "$T/state/m/events.jsonl"; pv start w-remote-m-9 < <(req cat)
  [ $RC = 1 ] && has "$T/err" 'DESLOGADO' && has "$T/err" 'a ausência NÃO foi provada' && [ -e "$T/lc/loaded/${L}w-remote-m-9" ]; ok $? "gui: recusa cujo agente não se conseguiu remover diz as DUAS coisas (a causa e que o agente ficou) — nunca 'limpo' calado (rc=$RC)"
  # --- 4: o start varre os agentes órfãos do prefixo ANTES de criar o novo (o w-remote-m-9 acima já é uma: só no domínio, sem arquivos) ---
  rm -f "$T/lc.mode"; echo in > "$T/auth.mode"
  pv start w-remote-m-2 < <(req cat); pv start w-remote-m-1 < <(req cat)
  tmux -L "${SOCK}m" kill-session -t =w-remote-m-1  # a sessão some por fora: o agente fica carregado e os arquivos em run/ (o stop nunca rodou)
  printf x > "$RR/run/${L}w-remote-m-5.plist"; printf x > "$RR/run/${L}w-remote-m-5.agent.sh"  # só arquivos (start que morreu no meio)
  echo "$RR/run/${L}w-remote-m-6.plist" > "$T/lc/loaded/${L}w-remote-m-6"  # só no domínio (stop que apagou os arquivos mas não derrubou)
  echo x > "$T/lc/loaded/com.apple.fake"; printf x > "$RR/run/outro.plist"; printf x > "$RR/run/${L}w-remote-m-7.plist.bak"  # NÃO são nossos: outro prefixo, outro nome, outro sufixo
  [ -e "$T/lc/loaded/${L}w-remote-m-1" ] && [ -f "$RR/run/${L}w-remote-m-1.plist" ] && [ -f "$RR/run/${L}w-remote-m-1.agent.sh" ] && [ -f "$RR/run/${L}w-remote-m-5.plist" ] && [ -e "$T/lc/loaded/${L}w-remote-m-6" ] && [ -e "$T/lc/loaded/com.apple.fake" ]; ok $? "gui: precondição da varredura — as órfãs (1 carregada+arquivos, 5 só arquivos, 6 só no domínio) e o que não é nosso estão montados ANTES do start; sem isso os casos abaixo passariam no vazio"
  : > "$T/lc.log"; pv start w-remote-m-3 < <(req cat); ok $RC "gui: start com órfãs pendentes abre (rc=$RC $(head -c 200 "$T/err"))"
  [ ! -e "$T/lc/loaded/${L}w-remote-m-9" ]; ok $? "gui: a sobra da recusa acima (carregada, sem arquivos) também foi varrida, já pelo start seguinte (4)"
  [ ! -e "$T/lc/loaded/${L}w-remote-m-1" ] && [ ! -e "$RR/run/${L}w-remote-m-1.plist" ] && [ ! -e "$RR/run/${L}w-remote-m-1.agent.sh" ] && [ ! -e "$RR/run/${L}w-remote-m-1.agent.res" ]; ok $? "gui: órfã de sessão que sumiu por fora (carregada + arquivos) é varrida (4)"
  [ ! -e "$RR/run/${L}w-remote-m-5.plist" ] && [ ! -e "$RR/run/${L}w-remote-m-5.agent.sh" ]; ok $? "gui: órfã que só tem arquivos em run/ é varrida (4)"
  [ ! -e "$T/lc/loaded/${L}w-remote-m-6" ]; ok $? "gui: órfã que só está carregada no domínio é varrida (4)"
  [ -e "$T/lc/loaded/${L}w-remote-m-2" ] && [ -f "$RR/run/${L}w-remote-m-2.plist" ] && ! grep -q "^launchctl bootout .*${L}w-remote-m-2\$" "$T/lc.log"; ok $? "gui: o agente de uma sessão VIVA não é tocado pela varredura (4)"
  [ -e "$T/lc/loaded/com.apple.fake" ] && [ -f "$RR/run/outro.plist" ] && [ -e "$RR/run/${L}w-remote-m-7.plist.bak" ] && ! grep -q 'decoy' "$T/lc.log"; ok $? "gui: o que não é do prefixo (ou não tem a forma de agente nosso) fica: a varredura não é faxina geral (4)"
  o=$(lcline "^launchctl bootout .*${L}w-remote-m-1\$"); bn=$(lcline "^launchctl bootstrap .*${L}w-remote-m-3.plist\$")
  [ -n "$o" ] && [ -n "$bn" ] && [ "$o" -lt "$bn" ]; ok $? "gui: a varredura vem ANTES de criar o agente novo (bootout@${o:-nunca} < bootstrap@${bn:-nunca}) (4)"
  has "$T/state/m/session-ssh.log" "start w-remote-m-3: gui_agent: varreu o agente órfão ${L}w-remote-m-1" && has "$T/state/m/session-ssh.log" "gui_agent: varreu o agente órfão ${L}w-remote-m-5" && has "$T/state/m/session-ssh.log" "gui_agent: varreu o agente órfão ${L}w-remote-m-6"; ok $? "gui: cada órfã varrida fica no log do provider"
  pv stop w-remote-m-2 </dev/null; pv stop w-remote-m-3 </dev/null; rm -f "$RR/run/outro.plist" "$RR/run/${L}w-remote-m-7.plist.bak"
  lcreset; echo "$RR/run/${L}w-remote-m-6.plist" > "$T/lc/loaded/${L}w-remote-m-6"; echo stuck > "$T/lc.mode"; : > "$T/state/m/events.jsonl"; : > "$T/lc.log"
  pv start w-remote-m-4 < <(req cat)
  [ $RC = 1 ] && has "$T/err" 'a ausência NÃO foi provada' && ! grep -q "^launchctl bootstrap .*${L}w-remote-m-4" "$T/lc.log" && [ "$(count x "${SOCK}m")" = 0 ] && [ ! -e "$T/state/m/running/w-remote-m-4" ] && [ "$(nrun)" = 0 ] \
    && jq -e 'select(.event=="refused" and .session=="w-remote-m-4" and (.reason|startswith("gui_agent:")))' "$T/state/m/events.jsonl" >/dev/null 2>&1; ok $? "gui: órfã que a varredura não consegue provar ausente → o start recusa e NÃO cria o agente novo (4) (rc=$RC $(head -c 140 "$T/err"))"
  rm -f "$T/lc.mode"; pv start w-remote-m-4 < <(req cat); [ $RC = 0 ] && [ ! -e "$T/lc/loaded/${L}w-remote-m-6" ] && [ -e "$T/lc/loaded/${L}w-remote-m-4" ]; ok $? "gui: ...e com o launchd de volta ao normal o mesmo start varre a órfã e abre (rc=$RC)"
  pv stop w-remote-m-4 </dev/null
  # --- o resto do start: teto, nome repetido, sessão que morre logo, regra de presença antes de tudo (7) ---
  lcreset; pv start w-remote-m-1 < <(req cat); pv start w-remote-m-2 < <(req cat); : > "$T/lc.log"
  pv start w-remote-m-3 < <(req cat); [ $RC = 1 ] && has "$T/err" 'teto' && [ ! -s "$T/lc.log" ] && [ ! -e "$RR/run/${L}w-remote-m-3.plist" ]; ok $? "gui: host no teto → recusa antes de tocar no launchd (nenhum launchctl, nenhum arquivo) (rc=$RC)"
  pv start w-remote-m-1 < <(req cat); [ $RC != 0 ] && ! grep -q '^launchctl bootstrap' "$T/lc.log" && [ "$(count x "${SOCK}m")" = 2 ]; ok $? "gui: nome que já existe → não cria um segundo agente para ele (rc=$RC)"
  pv stop w-remote-m-1 </dev/null; pv stop w-remote-m-2 </dev/null
  lcreset; pv start w-remote-m-9 < <(req "sh -c 'exit 3'"); [ $RC = 1 ] && has "$T/err" 'terminou logo após abrir' && [ "$(nload)" = 0 ] && [ "$(nrun)" = 0 ]; ok $? "gui: sessão que morre logo depois de abrir leva o agente junto, provado — não deixa órfão (rc=$RC $(head -c 140 "$T/err"))"
  lcreset; mode uso; fresh; pv start w-remote-m-9 < <(req cat); [ $RC = 1 ] && has "$T/err" 'Athos está no MBP' && [ ! -s "$T/lc.log" ] && [ "$(nrun)" = 0 ] && nossh; ok $? "gui: Athos usando o MBP → o start recusa ANTES de tocar no launchd: a regra de presença vem primeiro e o agente não a contorna (7) (rc=$RC)"
  mode livre
  # --- o start são DUAS chamadas ssh (ga-0k82lw): o que a 1.8 põe dentro delas tem que caber nas regras desse desenho ---
  # a 2ª chamada carrega o agente e espera o veredito do login (até gui_wait_s): com o prazo do start já gasto, o piso dela tem que cobrir essa espera, senão o ssh é cortado com o agente ainda subindo
  lcreset; echo slow > "$T/auth.mode"; cfgm '{"gui_proof_s":2,"start_timeout":3}'; fresh
  pv start w-remote-m-8 < <(req cat); [ $RC = 0 ] && [ "$(count x "${SOCK}m")" = 1 ] && [ -e "$T/lc/loaded/${L}w-remote-m-8" ]; ok $? "gui: 'auth status' de 7 s com start_timeout 3 → a 2ª chamada tem o piso do veredito (OPEN_MIN + gui_wait_s) e o start abre (rc=$RC $(head -c 140 "$T/err"))"
  pv stop w-remote-m-8 </dev/null; echo in > "$T/auth.mode"; cfgm '{"gui_proof_s":2}'
  # o stop chega na parte lenta do start: a 2ª chamada desiste ANTES de carregar o agente (a 1ª só LEU o launchd, na varredura) — e é o rc 14 ('abandonado'), não o 15 da recusa do domínio gráfico (um evento 'refused' de gui_agent para um start que o mini abandonou seria mentira)
  lcreset; : > "$T/state/m/events.jsonl"; fresh; rm -f "$T/slow.mark"
  printf '#!/bin/sh\n: > "%s"\nsleep 4\nexec "%s" "$@"\n' "$T/slow.mark" "$(command -v sha256sum)" > "$T/extra/sha256sum"; chmod +x "$T/extra/sha256sum"  # a sessão w-remote-* é REAL: o portão roda sha256sum no host, na 1ª chamada
  env HOME="$T/home" GC_SSH_CONFIG="$T/cfg.json" GC_SSH_BIN="$T/bin/ssh" GC_EXEC_STATE_DIR="$T/state" "$P" start w-remote-m-9 < <(req cat) >"$T/out.bg" 2>"$T/err.bg" & i=$!
  waitfor "$T/slow.mark"; pv stop w-remote-m-9 </dev/null; rc=$RC; wait $i; k=$?; rm -f "$T/extra/sha256sum"
  [ -e "$T/slow.mark" ] && [ $rc = 0 ] && [ $k = 1 ] && has "$T/err.bg" 'abandonado' && ! grep -q ' bootstrap ' "$T/lc.log" && [ "$(nload)" = 0 ] && [ "$(nrun)" = 0 ] && [ "$(count x "${SOCK}m")" = 0 ] \
    && ! jq -e 'select(.event=="refused" and .session=="w-remote-m-9")' "$T/state/m/events.jsonl" >/dev/null 2>&1; ok $? "gui: stop no meio da parte lenta do start → o start desiste ('abandonado') sem carregar agente e sem evento 'refused' de gui_agent (stop rc=$rc, start rc=$k: $(head -c 120 "$T/err.bg"))"
  rm -f "$T/state/m/running/w-remote-m-9"
  # --- config: gui_agent é decisão explícita; no notebook é obrigatória; o agente precisa do claude que confere o login ---
  for v in '"true"' 1 null; do cfgm '{"gui_agent":'"$v"'}'; fresh; pv --dry-run start w-remote-m-0 < <(req cat); [ $RC = 1 ] && has "$T/err" "'gui_agent'" && nossh; ok $? "gui: gui_agent=$v (não é true/false) recusa a config, sem ssh (rc=$RC)"; done
  cfgm '{"gui_agent":false}'; fresh; pv --dry-run start w-remote-m-0 < <(req cat); [ $RC = 1 ] && has "$T/err" "'gui_agent' é obrigatório" && nossh; ok $? "gui: notebook (sleeps) sem gui_agent recusa a config — senão o tmux nasceria no ssh e a sessão, deslogada (rc=$RC)"
  cfgm; jq '.hosts.a.gui_agent=true' "$T/cfg.json" > "$T/cfg.nd" && mv "$T/cfg.nd" "$T/cfg.json"; fresh; pv --dry-run start w-1 < <(req cat); [ $RC = 1 ] && has "$T/err" "session_env.claude" && nossh; ok $? "gui: gui_agent num host sem session_env.claude recusa a config (o agente não teria como conferir o login) (rc=$RC)"
  for k in gui_wait_s gui_proof_s; do for v in 0 601 '"x"'; do cfgm '{"'$k'":'"$v"'}'; fresh; pv --dry-run start w-remote-m-0 < <(req cat); [ $RC = 1 ] && has "$T/err" "$k" && nossh; ok $? "gui: $k=$v recusa a config, sem ssh (rc=$RC)"; done; done
  lcreset; cfg 3
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
  python3 -I - "$rx" <<'PY'; ok $? "wt: o identity_pattern casa com alias/template/sessão que o engine gera (dog-remote-1, dog-remote, dog-remote-gapxi4ls, dog-remote-adhoc-…, e o kimi-worker-remote da ga-do1ixn.5) e recusa os locais, os de outro papel e as misturas"
import re, sys
rx = re.compile(sys.argv[1])  # vazio ou inválido → o programa cai (rc ≠ 0) e o teste reprova
yes = ["remote-e2e-1", "kimi-worker-remote", "kimi-worker-remote-1", "kimi-worker-remote-gawispabc12", "kimi-worker-remote-adhoc-0fc28155dd", "dog-remote", "dog-remote-1", "dog-remote-gapxi4ls", "dog-remote-adhoc-0fc28155dd", "gate-reviewer-remote-2", "gate-reviewer-remote-adhoc-48ac5cece9", "wa-worker-remote-adhoc-1254849098", "wa-worker-remote-gawisp79e1", "ps-worker-remote", "ps-worker-remote-1", "ps-worker-remote-gaabc1234", "ps-worker-remote-adhoc-1254849098"]
no = ["kimi-worker-1", "kimi-remote-1", "kimi-worker-remote-", "kimi-worker-remote-adhoc-", "gastown.dog-4", "dog-gapxi4ls", "gastown.mayor", "dog", "mayor-remote-1", "dog-remote-", "dog-remote-a", "dog-remote-adhoc-", "dog-remote-adhoc-12345678901", "dog-remote-gapxi4ls-x", "dog-remote/../x", "x-dog-remote-1", "remote-e2e-2", "ps-worker-1", "ps-worker", "ps-remote-1", "ps-worker-remote-", "ps-worker-remote-adhoc-"]
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
  garbage) echo "naoeumachave-0123456789abcdef"; exit 0;;
  rc4other) echo "erro qualquer" >&2; exit 4;;
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
  jq -r '.launcher[]' "$T/out" | grep -qE "^CLAUDE_CODE_OAUTH_TOKEN='<chave da conta atual do pool: não lida no dry-run>' sh -c " && ! has "$T/out" 'export CLAUDE_CODE_OAUTH_TOKEN'; ok $? "acct: a chave entra como prefixo do comando final do lançador (só o claude a herda), não como export"
  fresh; TMPDIR="$T/tmp" pv start remote-test-ac1 < <(req "claude $T/ac1.out"); ok $RC "acct: start de sessão claude abre (rc=$RC $(head -c 200 "$T/err"))"
  [ "$(cat "$T/ac1.out" 2>/dev/null)" = "$KA" ]; ok $? "acct: a sessão do host nasce com CLAUDE_CODE_OAUTH_TOKEN = a chave da conta current do pool (alfa)"
  [ "$(grep -c . "$sl")" = 1 ] && has "$sl" "claude-oauth-token-alfa@example.test"; ok $? "acct: o cofre foi lido UMA vez, pelo item da conta atual"
  ! leaks "$KA"; ok $? "acct: a chave não aparece no argv do ssh, na saída, no estado/log do mini, no disco do host, no ps, no scrollback nem no ambiente do tmux"
  printf '%s' "$KA" > "$T/tmp/controle"; leaks "$KA"; r1=$?; rm -f "$T/tmp/controle"; ok $r1 "acct: (controle positivo) a varredura de vazamento acusa a chave quando ela está de fato no disco do host"
  setpool beta@example.test; fresh; TMPDIR="$T/tmp" pv start remote-test-ac2 < <(req "claude $T/ac2.out"); r1=$RC
  [ $r1 = 0 ] && [ "$(cat "$T/ac2.out" 2>/dev/null)" = "$KB" ]; ok $? "acct: o pool do mini trocou de conta → a sessão NOVA nasce com a chave da conta nova (beta) (rc=$r1)"
  ! leaks "$KB"; ok $? "acct: ...e a chave da conta nova também não vaza"
  for mode in locked notfound garbage spaced rc4other; do
    : > "$sl"; fresh; FAKE_SECRET_MODE=$mode pv start remote-test-ac3 < <(req "claude $T/ac3.out"); r1=$RC
    [ $r1 = 1 ] && nossh && has "$T/err" 'gc-session-ssh start: ' && [ ! -e "$T/ac3.out" ] && [ "$(count)" = 2 ] && ! has "$T/err" DECOY && ! has "$T/out" DECOY && ! ls "$RR/run" 2>/dev/null | grep -q ac3; ok $? "acct: secret '$mode' → o start RECUSA (rc 1) sem ssh, sem sessão, sem lançador, sem repetir o que o secret escreveu, e NÃO cai no login fixo do nó (rc=$r1)"
  done
  FAKE_SECRET_MODE=notfound pv start remote-test-ac3 < <(req "claude $T/ac3.out"); has "$T/err" 'sem chave cadastrada' && has "$T/err" beta@example.test; ok $? "acct: conta atual SEM item no cofre → o motivo diz 'sem chave cadastrada' e a conta (não é cofre ilegível)"
  FAKE_SECRET_MODE=locked pv start remote-test-ac3 < <(req "claude $T/ac3.out"); has "$T/err" 'ilegível' && has "$T/err" beta@example.test; ok $? "acct: cofre fechado → o motivo diz 'ilegível' e a conta"
  FAKE_SECRET_MODE=rc4other pv start remote-test-ac3 < <(req "claude $T/ac3.out"); has "$T/err" 'ilegível' && ! has "$T/err" 'sem chave cadastrada'; ok $? "acct: rc 4 SEM 'Not found' no stderr não é 'sem chave cadastrada': é cofre ilegível"
  grep -q '"event": "refused"' "$T/state/a/events.jsonl" && grep -q 'chave da conta Claude beta@example.test' "$T/state/a/events.jsonl" && [ ! -e "$T/state/a/running/remote-test-ac3" ]; ok $? "acct: a recusa vira evento refused (placar do host) com a conta, e a sessão não fica registrada como aberta"
  for bad in AUSENTE '{' '[]' '{}' '{"current":""}' '{"current":5}' '{"current":"a b@x.test"}' '{"current":"-x@y.test"}' '{"current":"x@y.test\nz"}' '{"current":"nao-e-email"}'; do
    if [ "$bad" = AUSENTE ]; then rm -f "$pool"; else printf '%s\n' "$bad" > "$pool"; fi
    : > "$sl"; fresh; pv start remote-test-ac4 < <(req "claude $T/ac4.out"); r1=$RC
    [ $r1 = 1 ] && nossh && [ ! -s "$sl" ] && [ ! -e "$T/ac4.out" ] && has "$T/err" 'conta atual'; ok $? "acct: arquivo do pool $bad → recusa (rc 1) dizendo que não sabe a conta atual, sem ssh e sem tocar no cofre (rc=$r1)"
  done
  setpool alfa@example.test; : > "$sl"; FAKE_SECRET_MODE=locked pv start acct-cl2 < <(req "claudette x"); [ ! -s "$sl" ]; ok $? "acct: comando que só COMEÇA com 'claude' (claudette) não é o claude: o cofre não é tocado"
  jq 'del(.hosts.a.real_sessions_released_by)' "$T/cfg.json" > "$T/cfg2.json" && mv "$T/cfg2.json" "$T/cfg.json"; : > "$sl"; FAKE_SECRET_MODE=locked pv start acct-real < <(req "claude x"); r1=$RC
  [ $r1 = 1 ] && has "$T/err" real_sessions_released_by && [ ! -s "$sl" ]; ok $? "acct: a política local (sessão real sem liberação) vale ANTES do cofre: recusa pela política e o cofre não é tocado (rc=$r1)"; cfg 3 25 "$extra"
  : > "$sl"; FAKE_SECRET_MODE=locked pv start acct-cat < <(req "cat"); r1=$RC
  [ $r1 = 0 ] && [ ! -s "$sl" ]; ok $? "acct: sessão que NÃO é claude não toca no cofre (nem com ele fechado) e abre normalmente (rc=$r1)"; pv stop acct-cat </dev/null
  cfg 3; : > "$sl"; fresh; pv start remote-test-ac5 < <(req "claude $T/ac5.out"); r1=$RC
  [ $r1 = 0 ] && [ "$(cat "$T/ac5.out" 2>/dev/null)" = UNSET ] && [ ! -s "$sl" ]; ok $? "acct: host SEM o bloco claude_account = como antes: nenhuma env nova e o cofre não é tocado (rc=$r1)"
  for bad in '"texto"' '[]' '{}' '{"current_file":"relativo.json"}' '{"current_file":"/x/p.json","extra":1}' '{"current_file":5}' '{"current_file":"/x/p.json","secret":"relativo"}'; do
    cfg 3 25 "{\"claude_account\":$bad}"; fresh; pv start remote-test-ac6 < <(req "claude $T/ac6.out"); r1=$RC
    [ $r1 = 1 ] && nossh && has "$T/err" 'gc-session-ssh start: host a: ' && has "$T/err" claude_account; ok $? "acct: claude_account mal formado ($bad) recusa a config nomeando a chave, sem ssh (rc=$r1)"
  done
  for x in remote-test-ac1 remote-test-ac2 remote-test-ac5; do pv stop $x </dev/null; done
  rm -f "$T/home/.local/bin/claude" "$T/bin/secret"; unset FAKE_VAULT FAKE_SECRET_LOG; cfg 3
}

g_prof() {  # perfil de modelo por papel (ga-do1ixn.2): a sessão <papel>-remote-* do papel listado nasce apontada para o fornecedor do perfil, com a chave DELE e nunca a da conta do pool
  local KO=sk-or-v1-FAKEkimi0123456789abcdef KA=sk-ant-FAKEalfa-0123456789abcdef pool="$T/pool.json" vault="$T/vault" sl="$T/secret.log" prof extra mode bad r1 f
  prof='{"kimi-worker":{"base_url":"https://openrouter.ai/api","secret":"openrouter-api-key","key_prefix":"sk-or-","model":"moonshotai/kimi-k3.1-pro","small_model":"moonshotai/kimi-k2.7-code"}}'
  extra=$(jq -n --arg f "$pool" --arg s "$T/bin/secret" --argjson mp "$prof" '{claude_account:{current_file:$f,secret:$s}, model_profiles:$mp}')
  mkdir -p "$vault" "$T/tmp" "$T/home/.local/bin"; : > "$sl"
  printf '%s\n' "$KO" > "$vault/openrouter-api-key"; printf '%s\n' "$KA" > "$vault/claude-oauth-token-alfa@example.test"
  printf '{"current":"alfa@example.test","since":"2026-10-26T20:00:00Z","reason":"selftest"}\n' > "$pool"
  cat > "$T/bin/secret" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_SECRET_LOG:-/dev/null}"
case "${FAKE_SECRET_MODE:-}" in
  locked) echo "sk-or-DECOYOUT0000000000000000"; echo "Error: vault is locked sk-or-DECOYERR0000000000000000" >&2; exit 1;;
  notfound) echo "Not found: $1" >&2; exit 4;;
  noprefix) echo "sk-ant-FAKEwrongkind0123456789"; exit 0;;
  spaced) echo "sk-or-FAKEspaced 0123456789abcdef"; exit 0;;
esac
[ -f "$FAKE_VAULT/$1" ] || { echo "Not found: $1" >&2; exit 4; }
cat "$FAKE_VAULT/$1"
EOF
  chmod +x "$T/bin/secret"
  # o claude do "host": grava o que recebeu (UNSET ≠ vazio: o perfil manda OAUTH e API_KEY VAZIOS de propósito)
  cat > "$T/home/.local/bin/claude" <<'EOF'
#!/bin/sh
for v in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL; do
  eval "printf '%s=%s\n' $v \"\${$v-UNSET}\""
done > "$1"
exec cat
EOF
  chmod +x "$T/home/.local/bin/claude"
  export FAKE_VAULT="$vault" FAKE_SECRET_LOG="$sl"
  envis() { grep -qxF "$2" "$1" 2>/dev/null; }  # envis ARQUIVO LINHA
  pleaks() {  # 0 = a chave $1 apareceu onde não pode (argv do ssh, saída, estado do mini, disco do host, ps, scrollback, ambiente do tmux)
    local k="$1" s found=1
    for s in "$T/ssh.log" "$T/out" "$T/err" "$sl"; do has "$s" "$k" && found=0; done
    grep -rqF "$k" "$T/state" "$RR" "$RH" "$T/tmp" 2>/dev/null && found=0
    ps -eo args= | grep -F "$k" | grep -vF grep | grep -q . && found=0
    for s in $(tmux -L "$SOCK" list-sessions -F '#{session_name}' 2>/dev/null); do tmux -L "$SOCK" capture-pane -p -S - -t "=$s:" 2>/dev/null | grep -qF "$k" && found=0; done
    tmux -L "$SOCK" show-environment -g 2>/dev/null | grep -qF "$k" && found=0
    return $found
  }
  cfg 12 25 "$extra"; fresh
  pv --dry-run start kimi-worker-remote-p1 < <(req "claude $T/p1.out"); r1=$RC
  [ $r1 = 0 ] && [ "$(jq -r '.model_profile.model' "$T/out")" = moonshotai/kimi-k3.1-pro ] && [ "$(jq -r '.claude_account' "$T/out")" = null ] && [ ! -s "$sl" ] && ! has "$T/out" "$KO" && nossh; ok $? "prof: dry-run mostra o perfil do papel, NÃO lê o cofre, não mostra a chave e não abre ssh (rc=$r1)"
  f=$(jq -r '.launcher[]' "$T/out" | grep -E ' sh -c ')
  printf '%s' "$f" | grep -qF "ANTHROPIC_BASE_URL=https://openrouter.ai/api " && printf '%s' "$f" | grep -qF "CLAUDE_CODE_OAUTH_TOKEN='' " && printf '%s' "$f" | grep -qF "ANTHROPIC_API_KEY='' " && printf '%s' "$f" | grep -qF "ANTHROPIC_AUTH_TOKEN='<chave do perfil" && ! has "$T/out" 'export ANTHROPIC'; ok $? "prof: fornecedor, chave e os dois vazios entram como PREFIXO do comando final, não como export"
  fresh; TMPDIR="$T/tmp" pv start kimi-worker-remote-p1 < <(req "claude $T/p1.out"); ok $RC "prof: start da sessão do papel com perfil abre (rc=$RC $(head -c 200 "$T/err"))"
  envis "$T/p1.out" "ANTHROPIC_AUTH_TOKEN=$KO" && envis "$T/p1.out" ANTHROPIC_BASE_URL=https://openrouter.ai/api; ok $? "prof: a sessão nasce com a chave do perfil e o endereço do fornecedor"
  envis "$T/p1.out" CLAUDE_CODE_OAUTH_TOKEN= && envis "$T/p1.out" ANTHROPIC_API_KEY= && ! has "$T/p1.out" "$KA"; ok $? "prof: CLAUDE_CODE_OAUTH_TOKEN e ANTHROPIC_API_KEY chegam VAZIOS (não UNSET) e a chave da conta do pool não está em lugar nenhum da sessão"
  envis "$T/p1.out" ANTHROPIC_MODEL=moonshotai/kimi-k3.1-pro && envis "$T/p1.out" ANTHROPIC_DEFAULT_SONNET_MODEL=moonshotai/kimi-k3.1-pro && envis "$T/p1.out" ANTHROPIC_DEFAULT_OPUS_MODEL=moonshotai/kimi-k3.1-pro && envis "$T/p1.out" CLAUDE_CODE_SUBAGENT_MODEL=moonshotai/kimi-k3.1-pro && envis "$T/p1.out" ANTHROPIC_DEFAULT_HAIKU_MODEL=moonshotai/kimi-k2.7-code && envis "$T/p1.out" ANTHROPIC_SMALL_FAST_MODEL=moonshotai/kimi-k2.7-code; ok $? "prof: os slots de modelo (principal, sonnet, opus, subagente = model; haiku e small-fast = small_model)"
  [ "$(grep -c . "$sl")" = 1 ] && has "$sl" openrouter-api-key && ! has "$sl" claude-oauth-token; ok $? "prof: o cofre foi lido UMA vez, pelo item do perfil — a conta do pool nem foi consultada"
  ! pleaks "$KO"; ok $? "prof: a chave do perfil não aparece no argv do ssh, na saída, no estado do mini, no disco do host, no ps, no scrollback nem no ambiente do tmux"
  printf '%s' "$KO" > "$T/tmp/controle"; pleaks "$KO"; r1=$?; rm -f "$T/tmp/controle"; ok $r1 "prof: (controle positivo) a varredura acusa a chave quando ela está de fato no disco do host"
  for mode in locked notfound noprefix spaced; do
    : > "$sl"; fresh; FAKE_SECRET_MODE=$mode pv start kimi-worker-remote-p2 < <(req "claude $T/p2.out"); r1=$RC
    [ $r1 = 1 ] && nossh && [ ! -e "$T/p2.out" ] && ! has "$T/err" DECOY && ! has "$sl" claude-oauth-token && has "$T/err" 'NÃO cai na conta do pool' && ! ls "$RR/run" 2>/dev/null | grep -q p2; ok $? "prof: secret '$mode' → o start RECUSA (rc 1) sem ssh, sem sessão, sem repetir o que o secret escreveu, e NÃO cai na conta do pool (rc=$r1)"
  done
  grep -q 'chave do perfil openrouter-api-key' "$T/state/a/events.jsonl" && [ ! -e "$T/state/a/running/kimi-worker-remote-p2" ]; ok $? "prof: a recusa vira evento refused com o item, e a sessão não fica registrada como aberta"
  : > "$sl"; fresh; TMPDIR="$T/tmp" pv start dog-remote-p3 < <(req "claude $T/p3.out"); r1=$RC
  [ $r1 = 0 ] && envis "$T/p3.out" "CLAUDE_CODE_OAUTH_TOKEN=$KA" && envis "$T/p3.out" ANTHROPIC_BASE_URL=UNSET && ! has "$sl" openrouter-api-key; ok $? "prof: papel FORA do mapa (dog) segue na conta do pool, sem nada do perfil (rc=$r1)"
  : > "$sl"; FAKE_SECRET_MODE=locked pv start kimi-worker-remote-p4 < <(req "cat"); r1=$RC
  [ $r1 = 0 ] && [ ! -s "$sl" ]; ok $? "prof: sessão do papel que NÃO é claude não toca no cofre e abre normalmente (rc=$r1)"; pv stop kimi-worker-remote-p4 </dev/null
  cfg 12 25 "$(jq -n --arg f "$pool" --arg s "$T/bin/secret" '{claude_account:{current_file:$f,secret:$s}}')"; : > "$sl"; fresh; TMPDIR="$T/tmp" pv start kimi-worker-remote-p5 < <(req "claude $T/p5.out"); r1=$RC
  [ $r1 = 0 ] && envis "$T/p5.out" "CLAUDE_CODE_OAUTH_TOKEN=$KA" && envis "$T/p5.out" ANTHROPIC_BASE_URL=UNSET; ok $? "prof: host SEM model_profiles = como antes, até para o nome do papel (rc=$r1)"
  cfg 12 25 "{\"model_profiles\":$prof}"; : > "$sl"; fresh; pv start kimi-worker-remote-p6 < <(req "claude $T/p6.out"); r1=$RC
  [ $r1 = 1 ] && nossh && [ ! -e "$T/p6.out" ] && has "$T/err" 'chave do perfil'; ok $? "prof: perfil sem claude_account usa o secret de <mini_home>; secret que não roda = recusa, sem ssh (rc=$r1)"
  for bad in '"texto"' '[]' '{"Kimi":{}}' '{"kimi-worker":{}}' \
      '{"kimi-worker":{"base_url":"https://openrouter.ai/api","secret":"openrouter-api-key","key_prefix":"sk-or-","model":"m"}}' \
      '{"kimi-worker":{"base_url":"https://openrouter.ai/api","secret":"openrouter-api-key","key_prefix":"sk-or-","model":"m","small_model":"s","extra":1}}' \
      '{"kimi-worker":{"base_url":"http://openrouter.ai/api","secret":"openrouter-api-key","key_prefix":"sk-or-","model":"m","small_model":"s"}}' \
      '{"kimi-worker":{"base_url":"https://openrouter.ai/api","secret":"-x","key_prefix":"sk-or-","model":"m","small_model":"s"}}' \
      '{"kimi-worker":{"base_url":"https://openrouter.ai/api","secret":"openrouter-api-key","key_prefix":"sk-or-","model":"a b","small_model":"s"}}' \
      '{"kimi-worker":{"base_url":"https://openrouter.ai/api","secret":"openrouter-api-key","key_prefix":"","model":"m","small_model":"s"}}' \
      '{"kimi-worker":{"base_url":"https://openrouter.ai/api","secret":"openrouter-api-key","key_prefix":"sk-or-","model":5,"small_model":"s"}}'; do
    cfg 12 25 "{\"model_profiles\":$bad}"; fresh; pv start kimi-worker-remote-p7 < <(req "claude $T/p7.out"); r1=$RC
    [ $r1 = 1 ] && nossh && has "$T/err" model_profiles; ok $? "prof: model_profiles mal formado ($(printf '%s' "$bad" | head -c 60)…) recusa a config nomeando a chave, sem ssh (rc=$r1)"
  done
  cfg 12 25 "$extra"; for x in kimi-worker-remote-p1 dog-remote-p3 kimi-worker-remote-p5; do pv stop $x </dev/null; done
  rm -f "$T/home/.local/bin/claude" "$T/bin/secret"; unset FAKE_VAULT FAKE_SECRET_LOG; cfg 3
}

# ---------- lr: cache de TTL curto do list-running (ga-it7qiq.5) — só resposta BOA entra, start/stop invalidam, erro nunca vira lista ----------
calls() { wc -l < "$T/ssh.log" | tr -d ' '; }
lrv() { GC_SSH_HOST=a pv "$@"; }  # um host só: o número de linhas do ssh.log é o número de perguntas ao host
age() { jq ".ts -= $2" "$1" > "$1.x" && mv "$1.x" "$1"; }  # envelhece o cache em $2 s
waitfor() { local i; for i in $(seq 1 200); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
bgenv() {  # bgenv LOG-DO-SSH SAÍDA ARGS... → o provider em segundo plano com o ssh falso registrando em outro log (as variáveis FAKE_SSH_* vêm de quem chama)
  local lg="$1" out="$2"; shift 2
  GC_SSH_HOST=a env HOME="$T/home" GC_SSH_CONFIG="$T/cfg.json" GC_SSH_BIN="$T/bin/ssh" GC_EXEC_STATE_DIR="$T/state" FAKE_SSH_LOG="$lg" "$P" "$@" >"$out" 2>"$out.err"; echo $? > "$out.rc"
}
g_lr() {
  local LR="$T/state/a/lr" C="$T/state/a/lr/cache.json" bad x pid
  # os grupos de antes (acct, wt…) deixam sessões no socket do host a, e com cap 3 o 1º start deste grupo bateria no teto: parte de um socket e de um estado limpos (só o socket DE TESTE, em $TMUX_TMPDIR)
  tmux -L "$SOCK" kill-server 2>/dev/null
  cfg 3 25 '{"list_cache_s":30}'; rm -rf "$LR" "$T/state/a/running"; fresh
  [ "$(count)" = 0 ]; ok $? "lr: ponto de partida: nenhuma sessão no socket do host a"
  pv start lr-1 < <(req cat); ok $RC "lr: o start abre a sessão (rc=$RC $(head -c 150 "$T/err"))"
  [ ! -e "$C" ] && [ -s "$LR/gen" ]; ok $? "lr: o start troca a geração e deixa o cache vazio"
  fresh; lrv list-running lr </dev/null; [ $RC = 0 ] && [ "$(cat "$T/out")" = lr-1 ] && [ "$(calls)" = 1 ] && [ -s "$C" ]; ok $? "lr: 1ª chamada pergunta ao host (1 ssh), devolve a lista e guarda a resposta (rc=$RC)"
  fresh; lrv list-running lr </dev/null; [ $RC = 0 ] && [ "$(cat "$T/out")" = lr-1 ] && nossh; ok $? "lr: 2ª chamada dentro do prazo vem do cache: a mesma lista e nenhum ssh (rc=$RC)"
  fresh; lrv list-running outro </dev/null; [ $RC = 0 ] && [ ! -s "$T/out" ] && nossh; ok $? "lr: o cache guarda a lista inteira e o prefixo filtra na saída (outro prefixo → vazio, sem ssh)"
  fresh; lrv list-running "" </dev/null; [ "$(cat "$T/out")" = lr-1 ] && nossh; ok $? "lr: prefixo vazio lista tudo, também do cache"
  # --- start e stop invalidam ---
  pv start lr-2 < <(req cat); [ $RC = 0 ] && [ ! -e "$C" ]; ok $? "lr: start apaga o cache (rc=$RC)"
  fresh; lrv list-running lr </dev/null; [ "$(sort "$T/out" | tr '\n' ' ')" = "lr-1 lr-2 " ] && [ "$(calls)" = 1 ]; ok $? "lr: depois do start a lista inclui a sessão nova (pergunta ao host, não serve a de antes)"
  fresh; lrv list-running lr </dev/null; nossh; pv stop lr-2 </dev/null; [ $RC = 0 ] && [ ! -e "$C" ]; ok $? "lr: stop apaga o cache (rc=$RC)"
  fresh; lrv list-running lr </dev/null; [ "$(cat "$T/out")" = lr-1 ] && [ "$(calls)" = 1 ]; ok $? "lr: depois do stop a sessão sumiu da lista (pergunta ao host)"
  pv stop lr-nao-existe </dev/null; fresh; lrv list-running lr </dev/null; [ "$(calls)" = 1 ]; ok $? "lr: stop de sessão que não existe também invalida (não sei o que o host fez no meio)"
  # --- prazo, relógio e forma do arquivo ---
  fresh; lrv list-running lr </dev/null; nossh; age "$C" 100; fresh; lrv list-running lr </dev/null; [ "$(cat "$T/out")" = lr-1 ] && [ "$(calls)" = 1 ] && jq -e '.ts > (now - 20)' "$C" >/dev/null; ok $? "lr: cache vencido pergunta ao host de novo e renova o carimbo"
  age "$C" -1000; fresh; lrv list-running lr </dev/null; [ "$(cat "$T/out")" = lr-1 ] && [ "$(calls)" = 1 ]; ok $? "lr: carimbo no FUTURO (relógio que voltou) não prova frescor: pergunta ao host"
  for bad in '.live="lr-1"' '.live=[1,2]' '.live=null' '.gen="outra"' 'del(.gen)' 'del(.ts)' '.ts=true' '.ts="agora"' 'del(.live)'; do
    fresh; lrv list-running lr </dev/null; jq "$bad" "$C" > "$C.x" && mv "$C.x" "$C"; fresh; lrv list-running lr </dev/null
    [ $RC = 0 ] && [ "$(cat "$T/out")" = lr-1 ] && [ "$(calls)" = 1 ]; ok $? "lr: cache com a forma errada ($bad) é ignorado: pergunta ao host (rc=$RC)"
  done
  fresh; lrv list-running lr </dev/null; echo 'isto não é json' > "$C"; fresh; lrv list-running lr </dev/null; [ $RC = 0 ] && [ "$(cat "$T/out")" = lr-1 ] && [ "$(calls)" = 1 ] && jq -e '.live == ["lr-1"]' "$C" >/dev/null; ok $? "lr: cache ilegível é ignorado e reescrito (rc=$RC)"
  : > "$C"; fresh; lrv list-running lr </dev/null; [ "$(cat "$T/out")" = lr-1 ] && [ "$(calls)" = 1 ]; ok $? "lr: cache VAZIO (arquivo de 0 bytes) é ignorado, não lido como lista vazia"
  # --- erro nunca vira lista nem fica guardado ---
  cfg 3 25 '{"list_cache_s":30,"list_down_cache_s":0}'  # o fato 'host fora' (grupo lrd) fica DESLIGADO aqui: estes casos encadeiam falhas e cada uma tem que chegar ao host
  rm -f "$C"; fresh; FAKE_SSH_FAIL=1 lrv list-running lr </dev/null; [ $RC = 1 ] && [ ! -s "$T/out" ] && [ ! -e "$C" ]; ok $? "lr: host fora do ar = erro e NADA guardado (rc=$RC)"
  fresh; FAKE_SSH_CUT=1 lrv list-running lr </dev/null; [ $RC = 1 ] && has "$T/err" 'sem marcadores' && [ ! -e "$C" ]; ok $? "lr: resposta cortada = erro e NADA guardado (rc=$RC)"
  fresh; lrv list-running lr </dev/null; [ $RC = 0 ] && [ "$(cat "$T/out")" = lr-1 ] && [ "$(calls)" = 1 ]; ok $? "lr: com o host de volta a resposta é a de verdade (as falhas não deixaram lista nem 'vazio' guardados)"
  age "$C" 100; fresh; FAKE_SSH_FAIL=1 lrv list-running lr </dev/null; [ $RC = 1 ] && [ ! -s "$T/out" ]; ok $? "lr: cache VENCIDO + host fora do ar = erro (a lista velha não é servida no lugar do erro) (rc=$RC)"
  # --- resposta vazia é resposta; a geração vale ---
  pv stop lr-1 </dev/null; fresh; lrv list-running lr </dev/null; [ $RC = 0 ] && [ ! -s "$T/out" ] && [ "$(calls)" = 1 ] && jq -e '.live == []' "$C" >/dev/null; ok $? "lr: o host respondeu que não tem sessão nossa → [] guardado (rc=$RC)"
  fresh; lrv list-running lr </dev/null; [ $RC = 0 ] && [ ! -s "$T/out" ] && nossh; ok $? "lr: ...e [] vem do cache como resposta, sem ssh"
  pv start lr-1 < <(req cat); fresh; lrv list-running lr </dev/null; [ "$(cat "$T/out")" = lr-1 ] && [ "$(calls)" = 1 ]; ok $? "lr: start depois do [] guardado: a lista nova aparece (o [] não fica preso)"
  # --- o registro de sessões nossas só é acertado com resposta do host ---
  mkdir -p "$T/state/a/running"; touch -t 202001010000 "$T/state/a/running/fantasma1"; age "$C" 100; fresh; lrv list-running lr </dev/null
  [ ! -e "$T/state/a/running/fantasma1" ] && [ -e "$T/state/a/running/lr-1" ]; ok $? "lr: resposta do host acerta o registro (fantasma sai, sessão viva fica)"
  touch -t 202001010000 "$T/state/a/running/fantasma2"; fresh; lrv list-running lr </dev/null; nossh; [ -e "$T/state/a/running/fantasma2" ]; ok $? "lr: lista vinda do cache NÃO mexe no registro (o host não foi perguntado)"
  rm -f "$T/state/a/running/fantasma2"
  # --- dry-run, 0 e padrão ---
  fresh; cp "$C" "$T/c.before"; lrv --dry-run list-running lr </dev/null; [ $RC = 0 ] && has "$T/out" '"script"' && nossh && cmp -s "$C" "$T/c.before"; ok $? "lr: dry-run mostra o que rodaria, não usa nem altera o cache (rc=$RC)"
  cfg 3 25 '{"list_cache_s":0}'; rm -rf "$LR"; fresh; lrv list-running lr </dev/null; lrv list-running lr </dev/null; [ "$(calls)" = 2 ] && [ ! -e "$C" ]; ok $? "lr: list_cache_s 0 desliga: 2 chamadas, 2 ssh e nada guardado"
  cfg 3; jq 'del(.hosts.a.list_cache_s)' "$T/cfg.json" > "$T/cfg2.json" && mv "$T/cfg2.json" "$T/cfg.json"; fresh; lrv list-running lr </dev/null; lrv list-running lr </dev/null; [ "$(calls)" = 1 ] && [ -s "$C" ]; ok $? "lr: sem list_cache_s o padrão (10 s) vale: 2 chamadas, 1 ssh"
  for bad in '"10"' true false -1 121 1.5 null '[]' '{}'; do
    cfg 3 25 "{\"list_cache_s\":$bad}"; fresh; lrv list-running lr </dev/null; [ $RC = 1 ] && has "$T/err" "'list_cache_s'" && nossh; ok $? "lr: list_cache_s=$bad recusa a config nomeando a chave, sem ssh (rc=$RC)"
  done
  cfg 3 25 '{"list_cache_s":120}'; fresh; lrv list-running lr </dev/null; [ $RC = 0 ]; ok $? "lr: 120 (o teto) é aceito (rc=$RC)"
  # --- vários hosts: só o host com cache é poupado ---
  cfg 3 25 '{"list_cache_s":30}'; rm -rf "$LR"; fresh; pv list-running lr </dev/null; fresh; pv list-running lr </dev/null
  [ $RC = 0 ] && [ "$(cat "$T/out")" = lr-1 ] && [ "$(calls)" = 1 ]; ok $? "lr: sem \$GC_SSH_HOST junta os hosts; o host com cache é poupado e o sem cache (b) é perguntado (rc=$RC, ssh=$(calls))"
  # --- geração ilegível: sem cache nesta chamada, nem lido nem gravado ---
  rm -rf "$LR/gen" "$C"; mkdir -p "$LR/gen"; fresh; lrv list-running lr </dev/null; lrv list-running lr </dev/null; [ $RC = 0 ] && [ "$(calls)" = 2 ] && [ ! -e "$C" ]; ok $? "lr: geração que não consigo ler = não sei se o cache vale → pergunta ao host sempre e não grava (rc=$RC)"
  rmdir "$LR/gen"
  # --- invalidar não pode derrubar o start ---
  mkdir -p "$LR"; chmod 500 "$LR"; pv start lr-9 < <(req cat); x=$RC; chmod 700 "$LR"
  [ $x = 0 ] && has "$T/state/a/session-ssh.log" 'não consegui trocar a geração'; ok $? "lr: não conseguir invalidar o cache (pasta sem escrita) não derruba o start, e a falha vai para o log (rc=$x)"
  pv stop lr-9 </dev/null
  # --- corrida: um list-running que estava em curso durante um start ---
  cfg 3 25 '{"list_cache_s":30}'; rm -rf "$LR"; lrv list-running lr </dev/null; rm -f "$T/bg1.out"* "$T/ssh.bg1.log"
  ( FAKE_SSH_DELAY=3 bgenv "$T/ssh.bg1.log" "$T/bg1.out" start lr-5 < <(req cat) ) & pid=$!
  waitfor "$T/ssh.bg1.log"; fresh; lrv list-running lr </dev/null
  [ "$(calls)" = 1 ]; ok $? "lr: com um start EM CURSO o list-running não serve o cache de antes (pergunta ao host)"
  wait $pid; [ "$(cat "$T/bg1.out.rc" 2>/dev/null)" = 0 ]; ok $? "lr: ...e o start lento terminou bem (rc=$(cat "$T/bg1.out.rc" 2>/dev/null) $(head -c 150 "$T/bg1.out.err" 2>/dev/null))"
  fresh; lrv list-running lr </dev/null; [ "$(sort "$T/out" | tr '\n' ' ')" = "lr-1 lr-5 " ] && [ "$(calls)" = 1 ]; ok $? "lr: ...e depois dele a lista tem a sessão nova (a resposta de antes, guardada no meio, morreu com o fim do start)"
  rm -f "$C" "$T/bg2.out"* "$T/ssh.bg2.log" "$T/mark2"
  ( FAKE_SSH_AFTER_MARK="$T/mark2" FAKE_SSH_DELAY_AFTER=3 bgenv "$T/ssh.bg2.log" "$T/bg2.out" list-running lr </dev/null ) & pid=$!
  waitfor "$T/mark2"; pv start lr-6 < <(req cat); x=$RC
  wait $pid; [ $x = 0 ] && [ "$(cat "$T/bg2.out.rc" 2>/dev/null)" = 0 ] && [ ! -e "$C" ]; ok $? "lr: resposta lida ANTES de um start, que só chega depois dele, não é guardada (start rc=$x, list rc=$(cat "$T/bg2.out.rc" 2>/dev/null))"
  fresh; lrv list-running lr </dev/null; has "$T/out" lr-6 && [ "$(calls)" = 1 ]; ok $? "lr: ...e a lista seguinte tem a sessão do start (pergunta ao host)"
  for x in lr-1 lr-5 lr-6; do pv stop $x </dev/null; done; rm -f "$T/state/a/running/"* 2>/dev/null; cfg 3
}

# ---------- lrd: host FORA do ar — o fato "não respondeu" também é guardado por pouco tempo, e devolve ERRO rápido (ga-sml4tqk) ----------
g_lrd() {
  local LR="$T/state/a/lr" D="$T/state/a/lr/down.json" i s t0 bad x
  down() { rm -rf "$LR"; FAKE_SSH_FAIL=1 lrv list-running "" </dev/null; }  # estado limpo (sem lista guardada que esconda a falha) + o host fora visto uma vez: o fato 'fora' fica guardado
  cfg 3 25 '{"list_cache_s":30,"list_down_cache_s":30}'; rm -rf "$LR"; fresh
  t0=$SECONDS; bad=0
  for i in $(seq 1 20); do
    FAKE_SSH_FAIL=1 FAKE_SSH_FAIL_AFTER=1 lrv list-running "" </dev/null; [ $RC = 1 ] && [ ! -s "$T/out" ] || bad=$((bad+1))
  done
  s=$((SECONDS - t0))
  [ "$bad" = 0 ]; ok $? "lrd: host fora → 20 list-running seguidos dão ERRO (rc 1) e nenhum devolve lista, nem vazia (falhas=$bad)"
  [ "$(calls)" = 1 ]; ok $? "lrd: ...e só a 1ª chamada tenta o ssh (ssh=$(calls); sem o cache do host fora seriam 20)"
  [ "$s" -lt 12 ]; ok $? "lrd: ...as 20 chamadas levam ${s}s (sem o cache do host fora: 20 s ou mais, o ssh leva 1 s para falhar)"
  has "$T/err" 'Connection timed out' && has "$T/err" 'guardado'; ok $? "lrd: o erro rápido leva o motivo do ssh e diz que veio do que está guardado"
  [ ! -e "$LR/cache.json" ]; ok $? "lrd: o host fora não deixa LISTA guardada (cache.json ausente)"
  # --- vence o prazo: pergunta ao host de novo; o host de volta apaga o fato ---
  age "$D" 100; fresh; FAKE_SSH_FAIL=1 lrv list-running "" </dev/null; [ $RC = 1 ] && [ "$(calls)" = 1 ] && jq -e '.ts > (now - 20)' "$D" >/dev/null; ok $? "lrd: fato vencido pergunta ao host de novo e, ainda fora, renova o carimbo (rc=$RC)"
  age "$D" 100; fresh; lrv list-running "" </dev/null; [ $RC = 0 ] && [ ! -s "$T/out" ] && [ "$(calls)" = 1 ] && [ ! -e "$D" ] && [ -s "$LR/cache.json" ]; ok $? "lrd: host de volta = a resposta de verdade, o fato 'fora' some e a lista passa a ser guardada (rc=$RC)"
  # --- só "não respondeu" é guardado: resposta cortada e sem marcadores continuam erro de cada chamada ---
  rm -rf "$LR"
  fresh; FAKE_SSH_CUT=1 lrv list-running "" </dev/null; [ $RC = 1 ] && [ ! -e "$D" ] && [ ! -e "$LR/cache.json" ]; ok $? "lrd: resposta cortada (o host respondeu torto) = erro e NADA guardado: nem lista nem 'fora' (rc=$RC)"
  fresh; FAKE_SSH_JUNK=1 lrv list-running "" </dev/null; [ $RC = 1 ] && [ ! -e "$D" ] && [ ! -e "$LR/cache.json" ]; ok $? "lrd: resposta sem marcadores = erro e NADA guardado: nem lista nem 'fora' (rc=$RC)"
  # --- ssh mudo (tempo esgotado) também é "não respondeu" ---
  cfg 3 2 '{"list_cache_s":30,"list_down_cache_s":30}'; rm -rf "$LR"; fresh; FAKE_SSH_HANG=1 lrv list-running "" </dev/null; x=$RC
  fresh; FAKE_SSH_HANG=1 lrv list-running "" </dev/null; [ $x = 1 ] && [ $RC = 1 ] && nossh && has "$T/err" 'não respondeu'; ok $? "lrd: ssh mudo (tempo esgotado) vira o fato 'fora': a 2ª chamada é erro rápido, sem ssh (rc=$x/$RC)"
  # --- start e stop invalidam ---
  cfg 3 25 '{"list_cache_s":30,"list_down_cache_s":30}'; rm -rf "$LR"; FAKE_SSH_FAIL=1 lrv list-running "" </dev/null; [ -s "$D" ]; ok $? "lrd: ponto de partida: o fato 'fora' está guardado"
  pv stop lrd-x </dev/null; [ ! -e "$D" ]; ok $? "lrd: stop apaga o fato 'fora'"
  FAKE_SSH_FAIL=1 lrv list-running "" </dev/null; [ -s "$D" ]; FAKE_SSH_FAIL=1 pv start lrd-x < <(req cat); [ $RC = 1 ] && [ ! -e "$D" ]; ok $? "lrd: start (que também falha, com o host fora) apaga o fato 'fora' (rc=$RC)"
  # --- forma errada, carimbo do futuro, outra geração, arquivo ilegível: pergunta ao host, nunca erro inventado ---
  for bad in '.msg=1' '.msg=""' 'del(.msg)' '.gen="outra"' 'del(.gen)' 'del(.ts)' '.ts=true' '.ts="agora"'; do
    down; jq "$bad" "$D" > "$D.x" && mv "$D.x" "$D"; fresh; lrv list-running "" </dev/null
    [ $RC = 0 ] && [ "$(calls)" = 1 ]; ok $? "lrd: fato com a forma errada ($bad) é ignorado: pergunta ao host, que respondeu (rc=$RC)"
  done
  down; age "$D" -1000; fresh; lrv list-running "" </dev/null; [ $RC = 0 ] && [ "$(calls)" = 1 ]; ok $? "lrd: carimbo no FUTURO (relógio que voltou) não prova nada: pergunta ao host (rc=$RC)"
  for x in 'isto não é json' ''; do
    down; printf '%s' "$x" > "$D"; fresh; lrv list-running "" </dev/null; [ $RC = 0 ] && [ "$(calls)" = 1 ]; ok $? "lrd: arquivo do fato 'fora' ilegível/vazio ('${x:-vazio}') é ignorado: pergunta ao host (rc=$RC)"
  done
  # --- dry-run não usa, 0 desliga, list_cache_s 0 desliga tudo, validação da chave ---
  down; fresh; lrv --dry-run list-running "" </dev/null; [ $RC = 0 ] && has "$T/out" '"script"' && nossh; ok $? "lrd: dry-run não usa o fato 'fora' (mostra o que rodaria) (rc=$RC)"
  cfg 3 25 '{"list_cache_s":30,"list_down_cache_s":0}'; rm -rf "$LR"; fresh; FAKE_SSH_FAIL=1 lrv list-running "" </dev/null; FAKE_SSH_FAIL=1 lrv list-running "" </dev/null; [ "$(calls)" = 2 ] && [ ! -e "$D" ]; ok $? "lrd: list_down_cache_s 0 desliga: 2 chamadas, 2 ssh e nada guardado"
  cfg 3 25 '{"list_cache_s":0}'; rm -rf "$LR"; fresh; FAKE_SSH_FAIL=1 lrv list-running "" </dev/null; FAKE_SSH_FAIL=1 lrv list-running "" </dev/null; [ "$(calls)" = 2 ] && [ ! -e "$D" ]; ok $? "lrd: list_cache_s 0 desliga o cache do list-running INTEIRO, também o do host fora"
  cfg 3 25 '{"list_cache_s":30}'; rm -rf "$LR"; fresh; FAKE_SSH_FAIL=1 lrv list-running "" </dev/null; FAKE_SSH_FAIL=1 lrv list-running "" </dev/null; [ "$(calls)" = 1 ] && [ -s "$D" ]; ok $? "lrd: sem list_down_cache_s o padrão (30 s) vale: 2 chamadas, 1 ssh"
  for bad in '"30"' true false -1 61 1.5 null '[]' '{}'; do
    cfg 3 25 "{\"list_cache_s\":30,\"list_down_cache_s\":$bad}"; fresh; lrv list-running "" </dev/null; [ $RC = 1 ] && has "$T/err" "'list_down_cache_s'" && nossh; ok $? "lrd: list_down_cache_s=$bad recusa a config nomeando a chave, sem ssh (rc=$RC)"
  done
  cfg 3 25 '{"list_cache_s":30,"list_down_cache_s":60}'; rm -rf "$LR"; fresh; lrv list-running "" </dev/null; [ $RC = 0 ]; ok $? "lrd: 60 (o teto) é aceito (rc=$RC)"
  rm -rf "$LR" "$T/state/a/running"; cfg 3
}

g_abort() {  # ga-0k82lw: o start que o mini ABANDONOU (prazo do provider estourado, ou o engine mata o processo no meio) não pode deixar sessão no host: o script do host ainda roda e abriria a tmux "depois do close"
  local bin="$T/home/.local/bin" real i pid mode srt brc; real=$(command -v sha256sum); mkdir -p "$bin"
  slowhost() {  # passo lento ANTES do new-session: o portão de uma sessão real roda `sha256sum` no host (real_gate); o falso marca que começou, espera $1 s e chama o de verdade
    rm -f "$T/slow.mark"; printf '#!/bin/sh\n: > "%s"\nsleep %s\nexec "%s" "$@"\n' "$T/slow.mark" "$1" "$real" > "$bin/sha256sum"; chmod +x "$bin/sha256sum"
  }
  for mode in plain orphan; do  # orphan = o ssh falso solta o script do host dos canais do chamador (stdout/stderr em arquivo: escrever nunca falha), como o sshd com ControlMaster, que segue drenando os pipes do filho depois da morte do cliente (medido com ssh de verdade); sem ele o teste não separa "o host percebe o canal fechado" de "o start não abre nada na parte lenta"
    if [ $mode = orphan ]; then export FAKE_SSH_ORPHAN=1; else unset FAKE_SSH_ORPHAN; fi
    cfg 3 2; slowhost 5; fresh
    pv start abort-1-$mode < <(req cat); [ $RC = 1 ] && has "$T/err" 'não respondeu em 2s'; ok $? "abort/$mode: prazo do start estourado → o start falha dizendo o prazo (rc=$RC)"
    sleep 6   # o passo lento acaba aqui e o script do host (que ninguém espera mais) seguiria até o new-session
    [ "$(count)" = 0 ]; ok $? "abort/$mode: ...e o host NÃO ganha a sessão depois (o script abandonado não a abre) (tmux: $(count))"
    tmux -L "$SOCK" kill-server 2>/dev/null
    cfg 3; slowhost 5; fresh
    env HOME="$T/home" GC_SSH_CONFIG="$T/cfg.json" GC_SSH_BIN="$T/bin/ssh" GC_EXEC_STATE_DIR="$T/state" "$P" start abort-2-$mode < <(req cat) >"$T/out" 2>"$T/err" & pid=$!
    waitfor "$T/slow.mark"; kill -9 $pid; wait $pid 2>/dev/null   # o engine aborta o create e mata o processo do provider: nenhum handler roda, o ssh e o script do host ficam órfãos
    sleep 7
    [ "$(count)" = 0 ]; ok $? "abort/$mode: provider morto no meio do start (kill -9) → o host NÃO ganha a sessão (tmux: $(count))"
    tmux -L "$SOCK" kill-server 2>/dev/null
  done
  unset FAKE_SSH_ORPHAN
  cfg 3; slowhost 4; fresh  # o engine fecha a sessão com o provider do start VIVO na parte lenta (a 1ª chamada ainda não gravou o lançador): o stop não acha sessão e volta 0; o start não pode abrir a tmux depois
  env HOME="$T/home" GC_SSH_CONFIG="$T/cfg.json" GC_SSH_BIN="$T/bin/ssh" GC_EXEC_STATE_DIR="$T/state" "$P" start abort-4 < <(req cat) >"$T/out.bg" 2>"$T/err.bg" & pid=$!
  waitfor "$T/slow.mark"; pv stop abort-4 </dev/null; srt=$RC; wait $pid; brc=$?
  [ $srt = 0 ] && [ $brc != 0 ] && has "$T/err.bg" 'abandonado'; ok $? "abort: stop no meio da parte lenta do start → o start desiste dizendo que foi abandonado (stop rc=$srt, start rc=$brc: $(head -c 120 "$T/err.bg"))"
  [ "$(count)" = 0 ]; ok $? "abort: ...e o host NÃO ganha a sessão (tmux: $(count))"
  cfg 3; slowhost 0; fresh  # controle: um stop de ANTES de um start novo do mesmo nome (a marca ficou no host) não o impede: o preparo da 1ª chamada apaga a marca
  pv stop abort-4 </dev/null; pv start abort-4 < <(req cat); [ $RC = 0 ] && [ "$(count)" = 1 ]; ok $? "abort: (controle) stop e depois um start novo do mesmo nome abre a sessão (rc=$RC, tmux: $(count))"
  pv stop abort-4 </dev/null
  cfg 3; slowhost 0; fresh; mkdir -p "$RR/run"; : > "$RR/run/old-x.stop"; touch -t 202001010000 "$RR/run/old-x.stop"  # a marca de um stop de anos atrás: ninguém mais a apagaria
  pv stop abort-5 </dev/null; [ $RC = 0 ] && [ ! -e "$RR/run/old-x.stop" ] && [ -e "$RR/run/abort-5.stop" ]; ok $? "abort: o stop poda a marca .stop antiga (> 24 h) e mantém a que acabou de gravar (rc=$RC)"
  cfg 3; slowhost 2; fresh
  pv start abort-3 < <(req cat); ok $RC "abort: (controle) start lento mas dentro do prazo abre a sessão (rc=$RC $(head -c 160 "$T/err"))"
  [ "$(count)" = 1 ]; ok $? "abort: (controle) ...e ela está no host (tmux: $(count))"
  pv stop abort-3 </dev/null; rm -f "$bin/sha256sum" "$T/state/a/running/"* 2>/dev/null; cfg 3
}

g_scope() {  # ga-kgnjkt8 fatia 2: teto POR SESSÃO no start remoto. O claude e as ferramentas dele moram na árvore do lançador; foi lá que uma fork bomb sem teto parou o nó (29/10). O lançador passa a rodar o comando num escopo systemd do usuário (TasksMax/MemoryMax por sessão) e com o limite de tarefas do usuário baixado pelo prlimit
  local l="$T/scope.l.sh" xdg="$T/scope.xdg" noxdg="$T/scope.noxdg" sb="$T/scope.sb" sbn="$T/scope.sbn" sbp="$T/scope.sbp" x rc a b ra rb
  mkdir -p "$xdg" "$noxdg" "$sb" "$sbn" "$sbp" "$RR/run" "$RR/city/.gc/agents/dog"
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$xdg/bus"   # um socket de verdade: o lançador testa `[ -S .../bus ]`
  for t in sh id rm cat env sleep; do for d in "$sb" "$sbn" "$sbp"; do ln -sf "$(command -v $t)" "$d/$t"; done; done
  printf '#!/bin/sh\n: > "%s/scope.ran"\nexit "${SCOPE_RC:-0}"\n' "$T" > "$sb/claude"; cp "$sb/claude" "$sbn/claude"; cp "$sb/claude" "$sbp/claude"; chmod +x "$sb/claude" "$sbn/claude" "$sbp/claude"
  printf '#!/bin/sh\necho "$@" > "%s/scope.sdr"\nwhile [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n' "$T" > "$sb/systemd-run"; cp "$sb/systemd-run" "$sbp/systemd-run"; chmod +x "$sb/systemd-run" "$sbp/systemd-run"   # systemd-run de brinquedo: só $sb e $sbp
  printf '#!/bin/sh\ncase "$*" in *--noheadings*) echo "${FAKE_NPROC_SOFT:-unlimited}"; exit 0;; esac\necho "$1" > "%s/scope.nproc"\nshift\nexec "$@"\n' "$T" > "$sb/prlimit"; cp "$sb/prlimit" "$sbn/prlimit"; chmod +x "$sb/prlimit" "$sbn/prlimit"   # prlimit de brinquedo: em $sb e $sbn (o $sbp não tem); responde ao limite atual (FAKE_NPROC_SOFT) e anota o --nproc que recebeu
  # roda o lançador que o dry-run mostrou, numa areia de PATH ($1 = areia, $2 = pasta do runtime do usuário, resto = variáveis extras); rc em $rc
  runl() { local pa="$1" xd="$2"; shift 2; rm -f "$T/scope.ran" "$T/scope.nproc" "$T/scope.sdr" "$RR/run/dog-1.exit"; cp "$l" "$T/scope.l.run.sh"
    env -i PATH="$pa" XDG_RUNTIME_DIR="$xd" HOME="$T/home" "$@" sh "$T/scope.l.run.sh" >/dev/null 2>&1; rc=$?; }
  # --- o dry-run mostra o lançador com o teto; host SEM session_scope fica como sempre foi
  cfg 3; fresh; pv --dry-run start dog-1 < <(req claude); jq -r '.launcher[]' "$T/out" > "$l"
  ! grep -q -e systemd-run -e prlimit -e ulimit "$l"; ok $? "scope: host sem session_scope → o lançador não tem systemd-run nem prlimit (tudo como antes)"
  [ "$(jq -r .session_scope "$T/out")" = null ]; ok $? "scope: ...e o dry-run diz session_scope null"
  cfg 3 25 '{"session_scope":{"tasks_max":2048,"memory_max":"6G","nproc_soft":8192}}'; fresh; pv --dry-run start dog-1 < <(req claude); jq -r '.launcher[]' "$T/out" > "$l"
  grep -qF -e '--nproc=8192:' "$l" && ! grep -q 'ulimit' "$l"; ok $? "scope: o limite de tarefas do usuário vai pelo prlimit (o ulimit -u do dash, o sh do nó, NÃO existe), só o soft: --nproc=8192:"
  grep -qE '"\$SDR" --user --scope --quiet --collect --unit=gc-session-dog-1-\$\$ -p TasksMax=2048 -p MemoryMax=6G -p MemorySwapMax=0 -- \$RL sh -c ' "$l"; ok $? "scope: o comando da sessão roda em systemd-run --user --scope (unidade gc-session-<sessão>-<pid>) com TasksMax=2048, MemoryMax=6G e sem swap, e o prlimit entra DENTRO do escopo"
  [ "$(jq -c .session_scope "$T/out")" = '{"memory_max":"6G","nproc_soft":8192,"tasks_max":2048}' ]; ok $? "scope: o dry-run diz o teto que valeu"
  cfg 3 25 '{"session_scope":{}}'; fresh; pv --dry-run start dog-1 < <(req claude)
  [ "$(jq -c .session_scope "$T/out")" = '{"memory_max":"6G","nproc_soft":8192,"tasks_max":2048}' ]; ok $? "scope: session_scope {} liga com os padrões (2048 tarefas, 6G, nproc 8192): objeto vazio NÃO é 'desligado'"
  cfg 3 25 '{"session_scope":{"nproc_soft":0}}'; fresh; pv --dry-run start dog-1 < <(req claude); jq -r '.launcher[]' "$T/out" > "$l"
  ! grep -q -e prlimit -e '\$RL' "$l" && grep -q -F 'TasksMax=2048' "$l"; ok $? "scope: nproc_soft 0 = sem prlimit (o escopo continua)"
  # --- config inválida recusa (exit 1, sem ssh, dizendo a chave): nunca liga um teto diferente do pedido em silêncio
  for x in '"sim"' 'true' 'false' '[]' '5' '{"tasks_max":0}' '{"tasks_max":63}' '{"tasks_max":"2048"}' '{"tasks_max":true}' '{"tasks_max":1.5}' '{"tasks_max":1000001}' '{"memory_max":"6 GB"}' '{"memory_max":"0"}' '{"memory_max":"-1G"}' '{"memory_max":6}' '{"memory_max":"6GB"}' '{"memory_max":""}' '{"memory_max":"1000000G"}' '{"memory_max":"6144"}' '{"memory_max":"1K"}' '{"memory_max":"255M"}' '{"nproc_soft":-1}' '{"nproc_soft":"8192"}' '{"nproc_soft":true}' '{"nproc_soft":255}' '{"bogus":1}'; do
    cfg 3 25 "{\"session_scope\":$x}"; fresh; pv --dry-run start dog-1 < <(req claude); [ $RC = 1 ] && has "$T/err" "'session_scope'" && ! has "$T/err" Traceback && nossh; ok $? "scope: session_scope=$x recusa a config com a mensagem do provider (exit 1, cita 'session_scope', SEM traceback, sem ssh) (rc=$RC)"
  done
  for x in '{"tasks_max":64}' '{"tasks_max":1000000}' '{"memory_max":"512M"}' '{"memory_max":"256M"}' '{"memory_max":"1T"}' '{"memory_max":"262144K"}' '{"nproc_soft":256}' '{"nproc_soft":1000000}' '{"nproc_soft":0}' 'null'; do
    cfg 3 25 "{\"session_scope\":$x}"; fresh; pv --dry-run start dog-1 < <(req claude); [ $RC = 0 ]; ok $? "scope: session_scope=$x é aceito (rc=$RC)"
  done
  cfg 3 25 '{"presence_gate":true}'; fresh; pv --dry-run start dog-1 < <(req claude); [ $RC = 0 ]; ok $? "scope: (controle) host de presença sozinho é aceito (rc=$RC)"
  cfg 3 25 '{"session_scope":{},"presence_gate":true}'; fresh; pv --dry-run start dog-1 < <(req claude); [ $RC = 1 ] && has "$T/err" "'session_scope' é do host Linux" && nossh; ok $? "scope: session_scope num host macOS (presença/gui) recusa dizendo que o escopo é do host Linux com systemd (rc=$RC)"
  # --- o lançador gerado, EXECUTADO numa areia de PATH (nada de systemd de verdade aqui)
  cfg 3 25 '{"session_scope":{"tasks_max":2048,"memory_max":"6G","nproc_soft":8192}}'; fresh; pv --dry-run start dog-1 < <(req claude); jq -r '.launcher[]' "$T/out" > "$l"
  runl "$sbn" "$xdg"; [ $rc = 126 ] && [ ! -e "$T/scope.ran" ] && grep -q 'sem systemd --user' "$RR/run/dog-1.exit"; ok $? "scope: sem systemd-run no host (e com prlimit e barramento) o lançador RECUSA (rc 126, 'sem systemd --user' no .exit) e o comando NÃO roda sem teto (rc=$rc)"
  runl "$sb" "$noxdg"; [ $rc = 126 ] && [ ! -e "$T/scope.ran" ] && grep -q 'sem systemd --user' "$RR/run/dog-1.exit"; ok $? "scope: sem o barramento do usuário (sem gerenciador; com systemd-run e prlimit) recusa do mesmo jeito (rc=$rc)"
  runl "$sbp" "$xdg"; [ $rc = 126 ] && [ ! -e "$T/scope.ran" ] && grep -q 'sem prlimit' "$RR/run/dog-1.exit"; ok $? "scope: com nproc_soft ligado e SEM prlimit no host recusa (rc 126, 'sem prlimit'), nunca roda calado só com o escopo (rc=$rc)"
  runl "$sb" "$xdg" FAKE_NPROC_SOFT=lixo; [ $rc = 126 ] && [ ! -e "$T/scope.ran" ] && grep -q 'não consegui ler o limite' "$RR/run/dog-1.exit"; ok $? "scope: limite atual de tarefas ilegível (o prlimit respondeu lixo) recusa, não 'sem limite' (rc=$rc)"
  runl "$sb" "$xdg"; [ $rc = 0 ] && [ -e "$T/scope.ran" ] && [ ! -e "$RR/run/dog-1.exit" ]; ok $? "scope: com systemd-run, prlimit e barramento o comando roda (rc=$rc) e o .exit não aparece"
  grep -qE -e '--user --scope --quiet --collect --unit=gc-session-dog-1-[0-9]+ -p TasksMax=2048 -p MemoryMax=6G -p MemorySwapMax=0 -- [^ ]*prlimit --nproc=8192: sh -c' "$T/scope.sdr"; ok $? "scope: o systemd-run recebeu o teto, uma unidade com o pid do lançador (única mesmo se o nome da sessão voltar) e o prlimit --nproc=8192: antes do comando"
  [ "$(cat "$T/scope.nproc" 2>/dev/null)" = '--nproc=8192:' ]; ok $? "scope: o prlimit pôs só o soft (--nproc=8192:)"
  runl "$sb" "$xdg" FAKE_NPROC_SOFT=4096; [ $rc = 0 ] && [ -e "$T/scope.ran" ] && [ ! -e "$T/scope.nproc" ]; ok $? "scope: o limite só BAIXA: um que já era menor (4096) não é mexido (nem sobe para 8192) e o comando roda (rc=$rc)"
  runl "$sb" "$xdg" SCOPE_RC=7; [ $rc = 7 ] && grep -q 'saiu com 7' "$RR/run/dog-1.exit"; ok $? "scope: o rc do comando atravessa o escopo (7) e o .exit diz 'saiu com 7' (rc=$rc)"
  # --- o kernel de verdade (Linux com systemd --user; senão skip, que NÃO conta como passou), com o sh do nó: duas sessões, uma bate no teto e a outra segue criando processos; e o limite de tarefas visto de DENTRO
  if [ "$(uname -s)" = Linux ] && command -v systemd-run >/dev/null 2>&1 && command -v prlimit >/dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ] && systemd-run --user --scope --quiet --collect -p TasksMax=16 true >/dev/null 2>&1; then
    printf 'import os, sys, time\ntag, want = sys.argv[1], int(sys.argv[2])\nn = 0\nfor _ in range(want):\n    try:\n        pid = os.fork()\n    except OSError:\n        continue\n    if pid == 0:\n        time.sleep(20)\n        os._exit(0)\n    n += 1\nopen("%s/scope.n." + tag, "w").write(str(n))\ntime.sleep(8)\n' "$T" > "$T/scope.fork.py"
    printf 'import resource, sys\nopen("%s/scope.lim." + sys.argv[1], "w").write(str(resource.getrlimit(resource.RLIMIT_NPROC)[0]))\n' "$T" > "$T/scope.lim.py"
    a="scp$$a"; b="scp$$b"; rm -f "$T/scope.n.a" "$T/scope.n.b" "$T/scope.lim.u" "$T/scope.lim.l"
    cfg 3 25 '{"session_scope":{"tasks_max":64,"memory_max":"1G","nproc_soft":0}}'
    fresh; pv --dry-run start "$a" < <(req "python3 -I $T/scope.fork.py a 300") ; jq -r '.launcher[]' "$T/out" > "$T/scope.la.sh"
    fresh; pv --dry-run start "$b" < <(req "python3 -I $T/scope.fork.py b 20") ; jq -r '.launcher[]' "$T/out" > "$T/scope.lb.sh"
    ( env PATH="$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" HOME="$T/home" sh "$T/scope.la.sh" >/dev/null 2>&1 & ); ( env PATH="$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" HOME="$T/home" sh "$T/scope.lb.sh" >/dev/null 2>&1 & )
    ra=0; rb=0; for _ in $(seq 1 60); do ra=$(cat "$T/scope.n.a" 2>/dev/null || echo 0); rb=$(cat "$T/scope.n.b" 2>/dev/null || echo 0); [ "$ra" != 0 ] && [ "$rb" != 0 ] && break; sleep 0.25; done
    [ "$ra" -ge 10 ] && [ "$ra" -le 64 ]; ok $? "scope: a sessão que tenta criar 300 filhos com tasks_max=64 consegue entre 10 e 64 (sem teto seriam 300; criou $ra)"
    [ "$rb" = 20 ]; ok $? "scope: ...e a OUTRA sessão, no mesmo instante, cria os 20 filhos dela (o teto é por sessão: criou $rb)"
    systemctl --user stop "gc-session-$a-*" "gc-session-$b-*" >/dev/null 2>&1
    cfg 3 25 '{"session_scope":{"nproc_soft":8192}}'; fresh; pv --dry-run start "$a" < <(req "python3 -I $T/scope.lim.py u"); jq -r '.launcher[]' "$T/out" > "$T/scope.lu.sh"
    fresh; pv --dry-run start "$b" < <(req "python3 -I $T/scope.lim.py l"); jq -r '.launcher[]' "$T/out" > "$T/scope.ll.sh"
    env PATH="$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" HOME="$T/home" sh "$T/scope.lu.sh" >/dev/null 2>&1
    env PATH="$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" HOME="$T/home" prlimit --nproc=4096: sh "$T/scope.ll.sh" >/dev/null 2>&1
    [ "$(cat "$T/scope.lim.u" 2>/dev/null)" = 8192 ]; ok $? "scope: com o sh do nó (dash) o comando da sessão nasce com RLIMIT_NPROC 8192 (visto de dentro: $(cat "$T/scope.lim.u" 2>/dev/null))"
    [ "$(cat "$T/scope.lim.l" 2>/dev/null)" = 4096 ]; ok $? "scope: ...e um limite que já era 4096 continua 4096 (só baixa; visto de dentro: $(cat "$T/scope.lim.l" 2>/dev/null))"
  else echo "skip scope: sem systemd-run --user e prlimit utilizáveis aqui (Linux com gerenciador de usuário): os casos do kernel de verdade NÃO rodaram"; fi
}

g_shard() {  # o filtro do PRÓPRIO selftest (GCSSH_SHARD, GCSSH_ONLY, GCSSH_MUTANTS_ONLY): fatia inválida, ou filtro que não pega nada, não pode sair verde (gate de 23/10 da ga-w7qwl1.1.8: GCSSH_SHARD=10/10 rodava zero e saía 0)
  # cada filho é ESTE arquivo com um filtro; os de recusa levam GCSSH_NO_MUTANTS=1: se a validação voltar a deixar passar, o filho roda "zero casos" e não a campanha de mutantes
  local s oo rr
  shard_child() { env -u GCSSH_ONLY -u GCSSH_NO_MUTANTS -u GCSSH_MUTANTS_ONLY -u GCSSH_SHARD -u GCSSH_MUTANT GCSSH_UNDER_TEST="$P" "$@" bash "$0" 2>&1; }  # o filho NÃO herda os filtros de quem roda este grupo (GCSSH_ONLY=shard pulava o bloco de mutantes do controle positivo)
  for s in 10/10 3/3 0/0 5 /3 3/ 1x/2 1/2x 1/2/3 -1/3 1/-3 ' 1/3' '1/ 3' '1 /3' '1/3 ' 08/10 00/10 0/00 1/0 1/010 1.5/3 12345/99999 99999999999999999999/100000000000000000001; do
    oo=$(shard_child GCSSH_NO_MUTANTS=1 GCSSH_SHARD="$s"); rr=$?
    [ $rr = 2 ] && [ "$(printf '%s\n' "$oo" | grep -c 'GCSSH_SHARD tem que ser K/N')" = 1 ]; ok $? "shard: GCSSH_SHARD='$s' é recusada com exit 2 e a causa (rc=$rr: $(printf '%s' "$oo" | head -c 90))"
  done
  # fatia VÁLIDA que não pega nada: passa pela validação (não é exit 2) e a falha é a de "nada rodou" (exit 1), nunca um 0/0 verde
  for s in 0/1 0/2 1/2 9/10 0/9999 9998/9999; do
    oo=$(shard_child GCSSH_NO_MUTANTS=1 GCSSH_SHARD="$s"); rr=$?
    [ $rr = 1 ] && printf '%s\n' "$oo" | grep -q 'NADA RODOU'; ok $? "shard: GCSSH_SHARD='$s' é aceita, e sem nada para rodar o selftest falha com 'NADA RODOU' (rc=$rr: $(printf '%s' "$oo" | head -c 90))"
  done
  oo=$(shard_child GCSSH_SHARD=9998/9999); rr=$?
  [ $rr = 1 ] && printf '%s\n' "$oo" | grep -q 'NADA RODOU' && ! printf '%s\n' "$oo" | grep -q 'mutante '; ok $? "shard: fatia válida que cai em ZERO mutantes (9998/9999, mutantes ligados) falha em vez de '0/0 ok' (rc=$rr: $(printf '%s' "$oo" | tail -c 90))"
  oo=$(shard_child GCSSH_NO_MUTANTS=1 GCSSH_ONLY=grupo-que-nao-existe); rr=$?
  [ $rr = 1 ] && printf '%s\n' "$oo" | grep -q 'NADA RODOU'; ok $? "shard: GCSSH_ONLY com grupo que não existe (erro de digitação) falha em vez de '0/0 ok' (rc=$rr: $(printf '%s' "$oo" | tail -c 90))"
  oo=$(shard_child GCSSH_MUTANTS_ONLY=grupo-que-nao-existe); rr=$?
  [ $rr = 1 ] && printf '%s\n' "$oo" | grep -q 'NADA RODOU'; ok $? "shard: GCSSH_MUTANTS_ONLY com grupo que não existe falha em vez de '0/0 ok' (rc=$rr: $(printf '%s' "$oo" | tail -c 90))"
  # controle positivo: fatia válida que PEGA um mutante roda exatamente esse e sai 0 (a ordem 1 é o primeiro mutante do arquivo; N=9999 > o total, então só a ordem K cai na fatia)
  oo=$(shard_child GCSSH_SHARD=1/9999); rr=$?
  [ $rr = 0 ] && [ "$(printf '%s\n' "$oo" | grep -c '^ok   mutante .* pego')" = 1 ] && printf '%s\n' "$oo" | grep -q '^== final: 1/1 ok ==$' && ! printf '%s\n' "$oo" | grep -q 'NADA RODOU'; ok $? "shard: (controle) GCSSH_SHARD=1/9999 roda exatamente 1 mutante, pego, e sai 0 (rc=$rr: $(printf '%s' "$oo" | tail -c 110))"
}

all() { group proto && g_proto; group dry && g_dry; group live && g_live; group cap && g_cap; group down && g_down; group meta && g_meta; group conf && g_conf; group guard && g_guard; group terr && g_terr; group gate && g_gate; group prep && g_prep; group wt && g_wt; group mbp && g_mbp; group gui && g_gui; group acct && g_acct; group prof && g_prof; group lr && g_lr; group lrd && g_lrd; group abort && g_abort; group scope && g_scope; group shard && g_shard; return 0; }

if [ -n "${GCSSH_MUTANT:-}" ]; then all; echo "RESULT $fails/$n"; exit $((fails > 0)); fi
# GCSSH_SHARD=K/N: dois decimais canônicos (sem sinal, sem espaço, sem zero à esquerda: `[ 3 = 03 ]` é falso e $((mn % 010)) é octal, então a fatia ficaria vazia ou trocada sem aviso), N de 1 a 9999 e K de 0 a N-1
# vazio → vale 0/1 (todos os mutantes); qualquer outra forma, ou K >= N → exit 2 e nada roda (nunca um "0/0 ok" verde: o gate de 23/10 reproduziu GCSSH_SHARD=10/10 saindo 0 sem rodar nada)
shard_bad() { echo "GCSSH_SHARD tem que ser K/N (decimais sem sinal nem zero à esquerda, N de 1 a 9999, K de 0 a N-1): '${GCSSH_SHARD}'"; exit 2; }
shv=${GCSSH_SHARD:-0/1}
case "$shv" in */*/*|*[!0123456789/]*|/*|*/) shard_bad;; */*) ;; *) shard_bad;; esac
shk=${shv%/*}; shn=${shv#*/}
case "$shk" in 0|[1-9]*) ;; *) shard_bad;; esac
case "$shn" in [1-9]*) ;; *) shard_bad;; esac
[ ${#shk} -le 4 ] && [ ${#shn} -le 4 ] && [ "$shk" -lt "$shn" ] || shard_bad
[ -n "${GCSSH_MUTANTS_ONLY:-}${GCSSH_SHARD:-}" ] || { all; echo "== $((n-fails))/$n ok =="; }  # GCSSH_MUTANTS_ONLY=grupo ou GCSSH_SHARD=K/N: pula os casos e roda só os mutantes (do grupo / da fatia K de N)

[ -n "${GCSSH_NO_MUTANTS:-}" ] || [ -n "${GCSSH_ONLY:-}" ] || {
  echo "-- controle negativo: cada guarda removida TEM que fazer o grupo que a cobre falhar"
  mn=0; : "${GCSSH_SHARD:=0/1}"
  mutant() {  # mutant GRUPOS DESCRIÇÃO SED-EXPR  (a cópia mutada tem que diferir do original, senão o mutante não testou nada)
    mn=$((mn+1)); [ $((mn % ${GCSSH_SHARD#*/})) = "${GCSSH_SHARD%/*}" ] || return  # GCSSH_SHARD=K/N: só o mutante de ordem ≡ K (mod N); a ordem conta TODOS, de qualquer grupo
    [ -z "${GCSSH_MUTANTS_ONLY:-}" ] || case ",$1," in *",$GCSSH_MUTANTS_ONLY,"*) ;; *) return;; esac
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
  mutant acct "claude_account nunca lido (a sessão nunca ganha a chave)" 's/^        if ca is not None:$/        if False:/'
  mutant acct "claude_account de qualquer forma aceito" 's/            if not isinstance(ca, dict) or set(ca) - {"current_file", "secret"}:/            if False:/'
  mutant acct "sessão que não é claude também ganha a chave (e toca no cofre)" 's/^    elif cfg.acct and runs_claude(p\["command"\]):$/    elif cfg.acct:/'
  mutant acct "claudette lido como claude (sem a fronteira do fim)" '/^CLAUDE_CMD = /s/(?=\\s|\$)//'
  mutant acct "o dry-run lê o cofre e imprime a chave" 's/^            secrets\[OAUTH_ENV\] = "<chave da conta atual do pool: não lida no dry-run>"$/            secrets[OAUTH_ENV] = acct_key(cfg, acct_view["current"] or "x@y.z")/'
  mutant acct "e-mail da conta de qualquer forma (vai para o argv do secret)" 's/^ACCT_EMAIL = re.compile(.*$/ACCT_EMAIL = re.compile(r".+")/'
  mutant acct "saída do secret com rc != 0 aceita como chave" 's/    if r.returncode == 0 and tok.startswith("sk-ant-")/    if tok.startswith("sk-ant-")/'
  mutant acct "saída sem sk-ant- aceita como chave" 's/ and tok.startswith("sk-ant-") and len(tok) > 16//'
  mutant acct "chave com espaço no meio aceita" 's/ and not any(c.isspace() for c in tok)//'
  mutant acct "rc 4 sem 'Not found' lido como conta sem chave" 's/ and "not found" in r.stderr.decode("utf-8", "replace").lower()//'
  mutant acct "recusa da chave sem evento refused" 's/^                cfg.event("refused", name, reason=f"chave da conta Claude {email} indisponível")$/                pass/'
  mutant acct "chave como export (o vigia e o resto do lançador a herdam)" 's/    assign = "".join(f"{k}={q(v)} " for k, v in (secrets or {}).items())/    assign = "".join(f"export {k}={q(v)}; " for k, v in (secrets or {}).items())/'
  mutant acct "mensagem de recusa repete o que o secret escreveu" 's/ilegível (cofre fechado ou secret falhou, rc={r.returncode}/ilegível (cofre fechado ou secret falhou, rc={r.returncode} saída={tok}/'
  mutant lr "cache nunca lido" 's/^        if hit is not None:$/        if False:/'
  mutant lr "start não invalida ANTES do ssh" 's/^        lr_invalidate(cfg)  # o list-running guardado deixa.*$/        pass/'
  mutant lr "start não invalida DEPOIS do ssh" 's/^            lr_invalidate(cfg)  # depois do ssh do start$/            pass/'
  mutant lr "stop não invalida" 's/^            lr_invalidate(cfg)  # stop, depois.*$/            pass/'
  mutant lr "resposta lida antes de um start/stop é gravada mesmo assim" 's/^    if gen is not None and lr_gen(cfg) == gen:/    if gen is not None:/'
  mutant lr "prazo ignorado (cache vale para sempre)" 's/return live if 0 <= time.time() - ts < cfg.list_ttl else None/return live/'
  mutant lr "relógio que voltou (idade negativa) vale" 's/return live if 0 <= time.time() - ts < cfg.list_ttl/return live if time.time() - ts < cfg.list_ttl/'
  mutant lr "geração gravada no arquivo ignorada" 's/if c.get("gen") != gen or not isinstance(ts, (int, float))/if not isinstance(ts, (int, float))/'
  mutant lr "forma da lista não conferida" 's/ or not isinstance(live, list) or not all(isinstance(x, str) for x in live)//'
  mutant lr "dry-run usa o cache" 's/    gen = None if dry or not cfg.list_ttl else lr_gen(cfg)/    gen = None if not cfg.list_ttl else lr_gen(cfg)/'
  mutant lr "list_cache_s 0 ainda grava" 's/    gen = None if dry or not cfg.list_ttl else lr_gen(cfg)/    gen = None if dry else lr_gen(cfg)/'
  mutant lr "list_cache_s de qualquer forma aceito" 's/        if not isinstance(self.list_ttl, int) or isinstance(self.list_ttl, bool) or not 0 <= self.list_ttl <= LIST_TTL_MAX:/        if False:/'
  mutant lr "list_cache_s booleano aceito" 's/ or isinstance(self.list_ttl, bool)//'
  mutant lr "list_cache_s negativo aceito" 's/or not 0 <= self.list_ttl <= LIST_TTL_MAX:/or not -9 <= self.list_ttl <= LIST_TTL_MAX:/'
  mutant lr "list_cache_s sem teto" 's/or not 0 <= self.list_ttl <= LIST_TTL_MAX:/or not 0 <= self.list_ttl:/'
  mutant lr "sem list_cache_s o cache fica desligado" 's/h.get("list_cache_s", LIST_TTL)/h.get("list_cache_s", 0)/'
  mutant lr "geração ilegível vale como 'sem invalidação'" '/ValueError = bytes que não são texto/{n;s/return None/return ""/;}'
  mutant lr "geração ausente conta como ilegível (cache nunca liga antes do 1º start)" '/^def lr_gen/,/^def lr_invalidate/s/^        return ""$/        return None/'
  mutant lr "lista do cache reconcilia o registro de sessões" 's/if not dry and t0 is not None:/if not dry:/'
  mutant lr "falha ao invalidar derruba o start" 's/^        cfg.log(f"list-running: não consegui trocar a geração do cache.*$/        raise/'
  # lrd (ga-sml4tqk): o fato "o host não respondeu" — cada guarda do cache negativo removida TEM que reprovar o grupo
  mutant lrd "fato 'fora' nunca lido (cada chamada paga o ssh)" 's/^        down = lr_down_read(cfg, gen) if cfg.down_ttl else None$/        down = None/'
  mutant lrd "prazo do fato 'fora' ignorado (vale para sempre)" 's/return (msg, int(age)) if 0 <= age < cfg.down_ttl else None/return (msg, int(age))/'
  mutant lrd "relógio que voltou (idade negativa) vale como 'fora'" 's/return (msg, int(age)) if 0 <= age < cfg.down_ttl/return (msg, int(age)) if age < cfg.down_ttl/'
  mutant lrd "geração gravada no fato 'fora' ignorada" 's/    if c.get("gen") != gen or not isinstance(ts, (int, float)) or not isinstance(msg, str) or not msg:/    if not isinstance(ts, (int, float)) or not isinstance(msg, str) or not msg:/'
  mutant lrd "motivo vazio no fato 'fora' aceito" 's/ or not isinstance(msg, str) or not msg:/ or not isinstance(msg, str):/'
  mutant lrd "resposta cortada também vira 'fora' (só o ssh que não respondeu pode)" 's/^    except Unreachable as e:  # só "não respondeu"/    except Fail as e:  # só "não respondeu"/'
  mutant lrd "start e stop não apagam o fato 'fora'" 's/(("cache.json", cfg.list_ttl), ("down.json", cfg.down_ttl))/(("cache.json", cfg.list_ttl),)/'
  mutant lrd "host de volta não apaga o fato 'fora'" 's/^            os.unlink(lr_path(cfg, "down.json"))  # o host respondeu.*$/            pass/'
  mutant lrd "list_down_cache_s de qualquer forma aceito" 's/^        if not isinstance(self.down_ttl, int) or isinstance(self.down_ttl, bool) or not 0 <= self.down_ttl <= LIST_DOWN_TTL_MAX:/        if False:/'
  mutant lrd "list_down_cache_s sem teto" 's/or not 0 <= self.down_ttl <= LIST_DOWN_TTL_MAX:/or not 0 <= self.down_ttl:/'
  mutant lrd "list_down_cache_s booleano aceito" 's/ or isinstance(self.down_ttl, bool)//'
  mutant lrd "sem list_down_cache_s o fato 'fora' fica desligado" 's/h.get("list_down_cache_s", LIST_DOWN_TTL)/h.get("list_down_cache_s", 0)/'
  mutant lrd "list_cache_s 0 ainda guarda o fato 'fora'" 's/    gen = None if dry or not cfg.list_ttl else lr_gen(cfg)/    gen = None if dry else lr_gen(cfg)/'
  mutant lrd "dry-run usa o fato 'fora'" 's/    gen = None if dry or not cfg.list_ttl else lr_gen(cfg)/    gen = None if not cfg.list_ttl else lr_gen(cfg)/'
  mutant abort "stop não grava a marca <nome>.stop" 's/mkdir -p @RUN@ && : > @RUN@\/@NAME@\.stop/true/'
  mutant abort "1ª chamada do start não apaga a marca (um stop antigo trava o start novo)" 's/^    prep_body = """rm -f @STOPF@$/    prep_body = """true/'
  mutant abort "2ª chamada do start não olha a marca (abre depois do stop)" 's/^\[ ! -e @STOPF@ \] || .*$/true/'
  mutant abort "stop não poda as marcas .stop antigas (elas se acumulam para sempre)" 's/^find @RUN@ -maxdepth 1 -name .*\.stop. -mmin +1440 .*$/true/'
  mutant abort "a poda não tem limite de idade (leva a marca que o stop acabou de gravar)" 's/ -mmin +1440//'
  # gui (ga-w7qwl1.1.8): (3) o stop prova a ausência · (4) o start varre as órfãs · (6) recusa sem gui/deslogado/ilegível · (1)(2) onde e com que nome o agente nasce
  mutant gui "stop sem bootout (o label continua carregado)" 's/^  launchctl bootout "gui\/\$U\/\$1" >\/dev\/null 2>&1$/  :/'
  mutant gui "agent_down não apaga os arquivos do agente" 's/^  rm -f -- @RUN@\/"\$1"\.plist .*$/  :/'
  mutant gui "agent_down não prova a ausência" 's/^  agent_gone "\$1" || return 1$/  :/'
  mutant gui "prova de ausência aceita qualquer resposta (até 'ainda carregado')" 's/case \$gr in 113|112) return 0;; esac/case $gr in *) return 0;; esac/'
  mutant gui "prova de ausência aceita 'não deu para ver' (rc 1)" 's/case \$gr in 113|112) return 0;; esac/case $gr in 113|112|1) return 0;; esac/'
  mutant gui "domínio gui inexistente (rc 112) não vale como ausência" 's/case \$gr in 113|112) return 0;; esac/case $gr in 113) return 0;; esac/'
  mutant gui "stop não chama o agent_down" 's/ + "agent_down " + q(gui_files(cfg, name)\["label"\]) + " || exit 1"/ + ":"/'
  mutant gui "stop que não provou a ausência termina assim mesmo" 's/" || exit 1"$/" || true"/'
  mutant gui "start sem varredura de órfãs" 's/^agent_sweep || exit 15$/:/'
  mutant gui "varredura depois de criar o agente novo (apaga o próprio agente)" 's/prep_body\.replace("@AGENT0@", agent0)/prep_body.replace("@AGENT0@", "")/;s/\.replace("@NEWSESS@", newsess)/.replace("@NEWSESS@", newsess + agent0)/'
  mutant gui "varredura apaga também o agente de sessão viva" '/grep -qxF -- "\${gl#@PFX@}" && continue/d'
  mutant gui "varredura sem o filtro do prefixo (apaga o que não é nosso)" "s/grep -E '^@PFXRE@\[A-Za-z0-9_-\]+\\\$' | sort -u/grep -E '.' | sort -u/"
  mutant gui "varredura só olha os arquivos de run/ (não o domínio)" "s/; printf '%s\\\\n' \"\\\$gd\" | awk -v p=@PFX@ 'index(\\\$NF,p)==1{print \\\$NF}'; }/; }/"
  mutant gui "varredura só olha o domínio (não os arquivos de run/)" 's/{ ls @RUN@ 2>\/dev\/null | sed -n/{ : | sed -n/'
  mutant gui "órfã que não se conseguiu remover não impede o start" 's/^    agent_down "\$gl" || return 1$/    agent_down "$gl" || true/'
  mutant gui "recusa do start deixa o agente carregado" 's/rm -f @LAUNCH@; agent_down @LABEL@; exit 15; }/rm -f @LAUNCH@; exit 15; }/g'
  mutant gui "start aceita qualquer veredito do agente" 's/^\[ "\$gv" = ok \] || {/true || {/'
  mutant gui "login ilegível passa" 's/^if \[ "\$rc" -ne 0 \] || \[ "\$lt" -eq 0 \] || \[ "\$lf" -ge 1 \]; then say "ilegivel rc=\$rc"; exit 0; fi$/:/'
  mutant gui "rc do auth status ignorado (true com rc 1 passa)" 's/if \[ "\$rc" -ne 0 \] || \[ "\$lt" -eq 0 \]/if [ "$lt" -eq 0 ]/'
  mutant gui "true e false juntos na saída passam" 's/ || \[ "\$lf" -ge 1 \]; then say "ilegivel/; then say "ilegivel/'
  mutant gui "plist em ~/Library/LaunchAgents" 's/^    base = f"{cfg.root}\/run\/{label}"$/    base = f"{cfg.home}\/Library\/LaunchAgents\/{label}"/'
  mutant gui "label sem o prefixo fixo" 's/^    label = AGENT_PFX + name$/    label = name/'
  mutant gui "agente que se reergue sozinho (KeepAlive true)" 's/<key>KeepAlive<\/key><false\/>/<key>KeepAlive<\/key><true\/>/'
  mutant gui "agente que carrega fora da sessão gráfica (sem LimitLoadToSessionType)" '/<key>LimitLoadToSessionType<\/key>/d'
  mutant gui "notebook sem gui_agent aceito" 's/^        if self.sleeps and not self.gui:$/        if False:/'
  mutant prof "model_profiles nunca lido (o papel cai na conta do pool)" 's/^        mp = h.get("model_profiles", {})$/        mp = {}/'
  mutant prof "model_profiles de qualquer forma aceito" 's/        if not isinstance(mp, dict) or not all(isinstance(k, str) and ROLE_RE.*$/        if False:/'
  mutant prof "campo do perfil sem validação" 's/                if not isinstance(v\[k\], str) or not rx.fullmatch(v\[k\]) or v\[k\].startswith("-"):/                if False:/'
  mutant prof "chave do perfil ilegível vira chave vazia (a sessão abre sem chave)" 's/^    raise Fail(f"chave do perfil ({item}) ilegível (rc=.*$/    return ""/'
  mutant prof "perfil não esvazia o OAuth (a Anthropic fica de reserva calada)" 's/"ANTHROPIC_API_KEY": "", OAUTH_ENV: "",/"ANTHROPIC_API_KEY": "",/'
  mutant prof "perfil não esvazia a ANTHROPIC_API_KEY" 's/"ANTHROPIC_API_KEY": "", OAUTH_ENV: "",/OAUTH_ENV: "",/'
  mutant prof "perfil e conta do pool juntos (o elif vira if)" 's/^    elif cfg.acct and runs_claude(p\["command"\]):$/    if cfg.acct and runs_claude(p["command"]):/'
  mutant prof "qualquer papel ganha o perfil" 's/    return cfg.profiles.get(m.group(1)) if m else None/    return next(iter(cfg.profiles.values()), None) if m else None/'
  mutant prof "chave sem o key_prefix aceita" 's/ and tok.startswith(prof\["key_prefix"\]) and len(tok) > 16//'
  mutant prof "chave do perfil com rc != 0 aceita" 's/    if r.returncode == 0 and tok.startswith(prof/    if tok.startswith(prof/'
  mutant prof "slot haiku com o modelo grande" 's/"ANTHROPIC_DEFAULT_HAIKU_MODEL": small/"ANTHROPIC_DEFAULT_HAIKU_MODEL": big/'
  mutant prof "o dry-run lê o cofre do perfil" 's/^            secrets.update(profile_env(prof, f"<chave do perfil.*$/            secrets.update(profile_env(prof, profile_key(cfg, prof)))/'
  mutant gui "gui_agent fora de true/false aceito" 's/if "gui_agent" in h and not isinstance(h\["gui_agent"\], bool):/if False:/'
  mutant gui "gui_agent sem o claude da session_env aceito" 's/if self.gui and not self.claude_bin:/if False:/'
  mutant gui "sessão que morre logo depois de abrir deixa o agente" 's/\.replace("@ADOWN@", adown)/.replace("@ADOWN@", "")/'
  mutant gui "recusa do domínio gráfico sem a linha 'refused'" 's/^        if rc == EX_GUI:$/        if False:/'
  mutant gui "órfã varrida não vai para o log" 's/if ln.startswith("gui_agent: varreu"):/if False:/'
  mutant gui "2ª chamada sem o piso do veredito do agente (o ssh é cortado com o agente subindo)" 's/max(OPEN_MIN + (cfg.gui_wait if cfg.gui else 0), int(/max(OPEN_MIN, int(/'
  mutant gui "start abandonado lido como recusa do domínio gráfico (o rc 14 vira o do gui_agent)" 's/^EX_GUI = 15/EX_GUI = 14/;s/exit 15/exit 14/g'
  mutant gui "2ª chamada sem as funções do agente (agent_down e o U do gui/<uid> não existem lá)" 's/\.replace("@AGENT1@", agent1)/.replace("@AGENT1@", "")/'
  mutant scope "o comando da sessão roda sem o escopo (o scope_pre some do run_cmd)" 's/{scope_pre}sh -c/sh -c/'
  mutant scope "o escopo perde o TasksMax" 's/ -p TasksMax={sc\["tasks_max"\]}//'
  mutant scope "o escopo perde o MemoryMax" 's/ -p MemoryMax={sc\["memory_max"\]}//'
  mutant scope "o escopo perde o MemorySwapMax=0" 's/ -p MemorySwapMax=0 -- / -- /'
  mutant scope "o escopo deixa de ser --collect" 's/--quiet --collect --unit=/--quiet --unit=/'
  mutant scope "a unidade perde o pid do lançador (nome repetido colide)" 's/--unit=gc-session-{name}-\$\$/--unit=gc-session-{name}/'
  mutant scope "sem systemd-run o lançador segue sem teto (não recusa)" 's/\[ -n "\$SDR" \] && //'
  mutant scope "sem o barramento do usuário o lançador segue sem teto" 's/ && \[ -S "\$XDG_RUNTIME_DIR\/bus" \]//'
  mutant scope "a recusa do lançador sai com 0 em vez de 126" 's/exit 126/exit 0/g'
  mutant scope "sem prlimit o lançador segue só com o escopo (calado)" '/sem prlimit (util-linux) no host/d'
  mutant scope "limite atual ilegível vira 'sem limite' em vez de recusar" 's/""|\*\[!0-9\]\*) echo "teto da sessão: não consegui ler o limite de tarefas (prlimit): a sessão não abre sem teto" >{q(exitf)}; exit 126 ;;/""|*[!0-9]*) RL= ;;/'
  mutant scope "o prlimit sobe um limite que já era menor" 's/\[ "\$lim" -gt {n} \]/true/'
  mutant scope "nproc_soft 0 liga o prlimit mesmo assim" 's/        if sc\["nproc_soft"\]:  # o `ulimit/        if True:  # o `ulimit/'
  mutant scope "o prlimit sai da linha do comando" 's/ + ("\$RL " if sc\["nproc_soft"\] else "")//'
  mutant scope "o prlimit põe o hard também" 's/RL="\$PRL --nproc={n}:"/RL="$PRL --nproc={n}:{n}"/g'
  mutant scope "tasks_max sem faixa" 's/64 <= out\["tasks_max"\] <= 1000000/True/'
  mutant scope "memory_max sem o piso de 256M" 's/< SCOPE_MEM_MIN_MB/< 0/'
  mutant scope "memory_max aceita número sem sufixo (bytes)" 's/(\[1-9\]\[0-9\]{0,5})(\[KMGT\])/([1-9][0-9]{0,5})([KMGT]?)/'
  mutant scope "chave desconhecida do session_scope é aceita" 's/ or set(sc) - set(SCOPE_KEYS)//'
  mutant scope "forma errada (texto, booleano) do session_scope é aceita" 's/not isinstance(sc, dict) or //'
  mutant scope "objeto vazio desliga o teto" 's/        if sc is None:/        if not sc:/'
  mutant scope "nproc_soft sem faixa" 's/(out\["nproc_soft"\] == 0 or 256 <= out\["nproc_soft"\] <= 1000000)/True/'
  mutant scope "host macOS aceita o escopo" 's/if self.scope and (self.gui or self.gate):/if False:/'
  mutant scope "o dry-run não diz o teto" 's/ session_scope=cfg.scope,//'
  mutant scope "o padrão de tasks_max muda" 's/"tasks_max": 2048, "memory_max"/"tasks_max": 4096, "memory_max"/'
  mutant scope "o padrão de memory_max muda" 's/"memory_max": "6G", "nproc_soft": 8192}/"memory_max": "8G", "nproc_soft": 8192}/'
  mutant scope "o padrão de nproc_soft muda" 's/"nproc_soft": 8192}/"nproc_soft": 16384}/'
  [ -n "${GCSSH_MUTANTS_ONLY:-}" ] || [ "${GCSSH_SHARD%/*}" != 0 ] || {
  echo "-- contra um stub que só sai 0 (a versão 'anterior' não tinha provider nenhum)"
  printf '#!/bin/sh\nexit 0\n' > "$T/stub"; chmod +x "$T/stub"
  r=$(GCSSH_MUTANT=1 GCSSH_ONLY="proto,dry,cap,down,conf,guard,gate,prep,wt,gui,acct,prof,scope" GCSSH_UNDER_TEST="$T/stub" bash "$0" 2>&1 | tail -1); echo "stub: $r"
  case "$r" in "RESULT 0/"*|"") ok 1 "stub deveria falhar quase tudo ($r)";; *) ok 0 "stub falha os casos novos ($r)";; esac
  }
  echo "== final: $((n-fails))/$n ok =="
}
# rodar ZERO casos e ZERO mutantes não é sucesso: GCSSH_ONLY / GCSSH_MUTANTS_ONLY com grupo que não existe, GCSSH_NO_MUTANTS junto de outro filtro, ou uma fatia K/N sem nenhum mutante. n é o contador de ok() deste processo (não uma leitura de fora).
[ "$n" -gt 0 ] || { echo "== NADA RODOU: 0 casos e 0 mutantes (GCSSH_ONLY='${GCSSH_ONLY:-}' GCSSH_MUTANTS_ONLY='${GCSSH_MUTANTS_ONLY:-}' GCSSH_SHARD='${GCSSH_SHARD:-}' GCSSH_NO_MUTANTS='${GCSSH_NO_MUTANTS:-}': algum filtro aponta para um grupo ou uma fatia vazia) =="; exit 1; }
[ "$fails" = 0 ]
