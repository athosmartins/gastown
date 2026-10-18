#!/usr/bin/env bash
# hetzner-proof.selftest.sh — hermético: o "ssh" é um falso que roda o comando no próprio mini com OUTRO HOME (o "servidor"), o provider, o gate,
# bd, gc e o hetzner-remote-git.sh são falsos, a cidade e o origin são fixtures. Nada conecta em servidor, GitHub ou Dolt de verdade.
#
# Contents
#   Grupos · Controle negativo · Variáveis
#
# GRUPOS: unit — pct (posto mais próximo) e judge (IGUAL só se os dois lados rodaram e concordam) · hooks — os 6 hooks de verdade nos dois HOMEs: igual;
#   ambiente que muda a resposta (jq falso no "servidor") = DIFERENTE; arquivo de hook diferente = não comparável; hook ausente / ssh fora = 3; caso que
#   não exercita o ramo = CASO-RUIM (pula sem os 6 hooks em ~/.claude/hooks, p.ex. no nó Linux) · lat — hooks em paralelo, piso, controle local, hook que
#   falha ou estoura o prazo, ssh fora, o hook rápido medido por si (não herda o tempo do lento) · e2e — sessão de ponta a ponta contra um provider falso com modos de falha (sem push, sem comentário, sem handoff,
#   sha diferente, identidade de outro autor, transcrição sem os hooks gc, hook com erro, hook gc cancelado pelo prazo do claude, linha ilegível, erro no meio, diálogo, sessão que morre, que trava), sem gate, sem atalho, sem worktree, pull do espelho com erro, --bead/--model com cara de comando, sessão velha: cada prova reprova sozinha, o diálogo NUNCA é
#   respondido e a sessão é parada em todo caminho
#   ga-2hd02v.1.5.9 (no grupo e2e): o PREPARE do driver só cria o worktree e o provider falso GRAVA a identidade e a confiança no start (como o de verdade) — o driver as CONFERE por fora (modos notrust, noident, prepfail);
#   o claude do servidor não pode mudar de versão nem de .last-update-result.json durante a sessão (modo autoupdate; versão ilegível antes = não começa); --prompts N manda N prompts à mesma sessão e prova que todos
#   foram respondidos, que cada um deixou o seu registro de hook (sem registro não há como dizer que nenhum foi cancelado) e que nenhum hook gc de UserPromptSubmit foi cancelado ou saiu ≠ 0 (modos pcancel, pfail, pnoreply, pnudgefail, pnorows, pmissone; --prompts fora de 0..100 = uso); leituras que FALHAM nunca viram "gravado"/"nenhum cancelado": ~/.claude.json ilegível/ausente depois do start (badjson, nojson) e transcrição ilegível ANTES/DEPOIS dos prompts (FAKE_HOOKLOG_FAIL_FROM=2/3) → a prova reprova "não consegui ler".
# CONTROLE NEGATIVO: cada guarda é apagada do script (sed numa cópia) e o grupo que a cobre TEM que passar a falhar.
# VARIÁVEIS: HPROOF_UNDER_TEST (script a testar) · HPROOF_ONLY (grupos separados por vírgula; ou o argumento --only=a,b) · HPROOF_NO_MUTANTS=1 (ou --no-mutants) · HPROOF_DEBUG=1 (ou --debug: mostra a saída do driver em cada caso do e2e) · HPROOF_REAL_HOOKS (padrão ~/.claude/hooks)
set -u
for a in "$@"; do case "$a" in --no-mutants) HPROOF_NO_MUTANTS=1;; --debug) HPROOF_DEBUG=1;; --only=*) HPROOF_ONLY="${a#--only=}";; esac; done  # (o nó Linux repassa argumentos, não ambiente)
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${HPROOF_UNDER_TEST:-$HERE/hetzner-proof.py}"
REAL_HOME="$HOME"; RH="${HPROOF_REAL_HOOKS:-$HOME/.claude/hooks}"
for v in $(env | sed -n 's/^\(GC_[A-Za-z0-9_]*\)=.*/\1/p') HETZNER_SSH_HOST HETZNER_REMOTE_HOME HETZNER_PROOF_ALIAS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR GIT_WORK_TREE; do unset "$v"; done  # (o nó Linux exporta GIT_AUTHOR_NAME=gt: ele passaria por cima da identidade do worktree)
T=$(mktemp -d "${TMPDIR:-/tmp}/hproof.XXXXXX") || exit 2
trap 'find "$T" -delete 2>/dev/null' EXIT
n=0; fails=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
group() { [ -z "${HPROOF_ONLY:-}" ] || case ",$HPROOF_ONLY," in *",$1,"*) return 0;; *) return 1;; esac; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
py() { python3 -I -c 'import importlib.machinery as m,sys; M=m.SourceFileLoader("hp",sys.argv[1]).load_module(); '"$1" "$P"; }
HOOKS="enforce-multiple-choice-question.sh enforce-mail-mcq-on-send.sh filter-bash-output.sh filter-test-output.sh filter-scraper-output.sh log-token-usage.sh"

SRV="$T/srv"; MINI="$T/mini"; CITY="$T/city"; export SRV CITY FAKE_STATE="$T/state"
mkdir -p "$T/bin" "$SRV/.local/bin" "$SRV/.claude" "$SRV/gt-remote/bin" "$SRV/gt-remote/bundle/city" "$MINI" "$CITY/.gc/logs" "$CITY/.gc/hetzner-mirror/repos" "$FAKE_STATE"
cat > "$T/bin/ssh" <<'EOF'
#!/bin/sh
[ -z "${FAKE_SSH_DEAD:-}" ] || { echo "ssh: connect to host fake port 22: Connection refused" >&2; exit 255; }
while [ "${1#-}" != "$1" ]; do case $1 in -o) shift 2;; *) shift;; esac; done
shift
# FAKE_HOOKLOG_FAIL_FROM=N: a leitura da transcrição (o script HOOKLOG, o único que traz a palavra "unreadable") falha da N-ésima chamada em diante (1 = a do evidence, 2 = a de ANTES dos prompts, 3 = a de DEPOIS).
# O driver manda o script pela ENTRADA (não pelos argumentos): só com a variável posta a entrada é lida inteira, olhada e devolvida ao comando por um arquivo (sem ela, nada muda: a entrada segue direto).
if [ -n "${FAKE_HOOKLOG_FAIL_FROM:-}" ]; then
  in=$(cat); printf '%s\n' "$in" > "$FAKE_STATE/ssh.in"
  case "$in" in *unreadable*) n=$(cat "$FAKE_STATE/hooklog.n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$FAKE_STATE/hooklog.n"
    [ "$n" -lt "$FAKE_HOOKLOG_FAIL_FROM" ] || { echo "ssh: falha falsa na leitura da transcrição (chamada $n)" >&2; exit 255; };; esac
  exec < "$FAKE_STATE/ssh.in"
fi
[ -z "${FAKE_JQ_BAD:-}" ] || PATH="$FAKE_JQ_BAD:$PATH"
HOME="$SRV" PATH="$SRV/.local/bin:$PATH" exec sh -c "$1"
EOF
cat > "$T/bin/bd" <<'EOF'
#!/bin/sh
[ -z "${FAKE_BD_FAIL:-}" ] || { echo "bd: falha falsa" >&2; exit 1; }
case "$1" in
  show) printf '[\n  {"id": "%s", "title": "falsa"}\n]\n' "$2";;
  comment) shift; shift; printf '%s\n' "$*" >> "$FAKE_STATE/comments";;
  comments) printf '['; sep=; while IFS= read -r l; do printf '%s{"text":"%s"}' "$sep" "$l"; sep=,; done < "$FAKE_STATE/comments" 2>/dev/null; printf ']\n';;
  query) printf '['; sep=; while IFS= read -r l; do ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); case $l in "OLD "*) l=${l#OLD }; ts=2020-01-01T00:00:00Z;; esac; printf '%s{"id":"ga-wisp-falso","title":"%s","labels":["gc:auto-handoff"],"created_at":"%s"}' "$sep" "$l" "$ts"; sep=,; done < "$FAKE_STATE/mail" 2>/dev/null; printf ']\n';;
esac
EOF
cat > "$T/bin/gc" <<'EOF'
#!/bin/sh
case "$1" in
  prime) sleep 0.2; exit 77;;
  handoff) echo "context cycle" >> "$FAKE_STATE/mail";;
  mail) echo "$*" >> "$FAKE_STATE/gcmail";;
esac
EOF
cat > "$SRV/gt-remote/bin/hetzner-remote-git.sh" <<'EOF'
#!/bin/sh
R="$HOME/gt-remote/git/gascity"
case "$1" in
  wt-add) [ -z "${FAKE_WT_FAIL:-}" ] || { echo "hetzner-remote-git: worktree add falhou" >&2; exit 3; }
          git -C "$R/repo.git" worktree add -q -b "worker/$3" "$R/wt/$3" >/dev/null 2>&1 || exit 3
          printf '{"rig":"gascity","bead":"%s","pull":"%s"}\n' "$3" "${FAKE_WT_PULL:-ok}";;
  wt-rm) git -C "$R/repo.git" worktree remove --force "$R/wt/$3" && echo "wt-rm: $3 removido";;
esac
EOF
cat > "$T/fakegate.py" <<'EOF'
import os, sys
print("ok" if os.environ.get("FAKE_GATE_RC", "0") == "0" else "blocked: logged-out: falso")
sys.exit(int(os.environ.get("FAKE_GATE_RC", "0")))
EOF
cat > "$T/fakeprov" <<'EOF'
#!/bin/bash
S="$FAKE_STATE"; echo "$*" >> "$S/provcalls"; op=$1; shift
session() {  # a "sessão" do servidor: os 7 passos do prompt, com o modo de falha pedido
  cd "$1" || return; run=$2; mode=${FAKE_MODE:-ok}; export HOME="$SRV"
  case $mode in
    dialog) echo "Is this a project you created or one you trust? Yes, I trust this folder" > "$S/pane"; return;;
    die) rm -f "$S/running"; echo "claude: morreu" > "$S/pane"; return;;
    hang) echo "pensando..." > "$S/pane"; return;;
  esac
  bd show ga-x --json > /dev/null; [ $mode = nocomment ] || bd comment ga-x "remote-e2e-1: sessao remota minima $run leu esta bead"
  idopt=; [ $mode != wrongid ] || idopt="-c user.name=outro -c user.email=outro@x.invalid"
  [ $mode != noident ] || idopt="-c user.name=remote-e2e-1 -c user.email=remote-e2e-1@gastown.invalid"  # (o start não gravou a identidade: a sessão comita com -c, o autor sai certo mas NADA ficou no worktree)
  [ $mode != autoupdate ] || { echo 2.1.303 > "$HOME/.claude-version"; printf '{"outcome":"success","to":"2.1.303"}\n' > "$HOME/.claude/.last-update-result.json"; }
  mkdir -p e2e; echo "remote-e2e $run" > "e2e/$run.txt"; git add "e2e/$run.txt"; git $idopt commit -q -m "chore(remote-e2e): $run" || { echo "commit falhou" > "$S/pane"; return; }
  [ $mode = nopush ] || git push -q origin HEAD 2>/dev/null
  [ $mode != shamismatch ] || git commit -q --amend -m "outra mensagem"
  if [ $mode = nohandoff ]; then echo "OLD context cycle" >> "$S/mail"; else gc handoff --auto "context cycle"; fi  # (nohandoff deixa um handoff VELHO: não pode contar)
  [ $mode = noanalytics ] || echo '{}' >> "$HOME/.claude/usage-analytics.jsonl"
  d="$HOME/.claude/projects/-fake-$run"; mkdir -p "$d"; t="$d/s.jsonl"
  hk() { printf '{"attachment":{"type":"hook_success","hookEvent":"%s","command":"%s","durationMs":%s,"exitCode":%s}}\n' "$1" "$2" "$3" "$4" >> "$t"; }
  [ $mode != gctimeout ] || echo '{"attachment":{"type":"hook_cancelled","hookEvent":"UserPromptSubmit","command":"export PATH=x && gc mail check --inject","durationMs":30512,"timedOut":true,"timeoutMs":30000}}' >> "$t"
  [ $mode != gcfail ] || hk UserPromptSubmit 'export PATH=x && gc mail check --inject' 700 1
  [ $mode = nogchooks ] || { hk SessionStart 'export PATH=x && GC_MANAGED_SESSION_HOOK=1 gc prime --hook --hook-format codex' 2100 0; hk UserPromptSubmit 'export PATH=x && gc nudge drain --inject' 900 0; }
  hk PreToolUse '~/.claude/hooks/filter-bash-output.sh' 40 $([ $mode = hookerr ] && echo 1 || echo 0)
  echo '{"type":"system","subtype":"stop_hook_summary","hookInfos":[{"command":"~/.claude/hooks/enforce-multiple-choice-question.sh","durationMs":46}],"hookErrors":[]}' >> "$t"
  [ $mode != badline ] || echo 'isto nao e json' >> "$t"
  [ $mode != rmcity ] || mv "$CITY" "$CITY.gone"
  echo "E2E-42-OK" >> "$S/pane"
}
case "$op" in
  list-running) [ ! -f "$S/running" ] || echo remote-e2e-1;;
  is-running) [ -f "$S/running" ] && echo true || echo false;;
  peek) cat "$S/pane" 2>/dev/null;;
  stop) rm -f "$S/running";;
  start) req=$(cat); : > "$S/pane"
         wt=$(printf '%s' "$req" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["work_dir"])')
         [ "${FAKE_MODE:-}" != prepfail ] || { echo "preparo da sessão remote-e2e-1 recusado: falso" >&2; exit 1; }
         # o START do provider de verdade grava a identidade git do worktree e a confiança da pasta ANTES de abrir a sessão (ga-2hd02v.1.5.9)
         [ "${FAKE_MODE:-}" = noident ] || { git -C "$wt" config user.name remote-e2e-1; git -C "$wt" config user.email remote-e2e-1@gastown.invalid; }
         # (notrust: a entrada da pasta existe mas SEM a confiança — é o que o driver tem de pegar pelo valor, não só pela entrada que falta; o claude consome hasCompletedProjectOnboarding sozinho, por isso a fake grava só hasTrustDialogAccepted)
         HOME="$SRV" python3 -I -c 'import json,os,sys; p=os.path.expanduser("~/.claude.json"); d=json.load(open(p)); d.setdefault("projects",{})[sys.argv[1]]={"hasTrustDialogAccepted":sys.argv[2]=="1","allowedTools":[]}; json.dump(d,open(p,"w"))' "$wt" "$([ "${FAKE_MODE:-}" = notrust ] && echo 0 || echo 1)"
         # badjson / nojson: o ~/.claude.json do servidor fica ILEGÍVEL / AUSENTE depois do start (o claude também o regrava): o driver não pode dar a confiança por gravada
         [ "${FAKE_MODE:-}" != badjson ] || printf '{ isto nao e json' > "$SRV/.claude.json"
         [ "${FAKE_MODE:-}" != nojson ] || rm -f "$SRV/.claude.json"
         [ "${FAKE_MODE:-}" != noperm ] || chmod 000 "$SRV/.claude.json"  # existe mas sem permissão de leitura (quem é root lê tudo: o caso é pulado lá)
         touch "$S/running"
         ( session "$wt" "$(basename "$wt")" ) > /dev/null 2>&1 &;;
  nudge) txt=$(cat); i=$(printf '%s' "$txt" | sed -n 's/.*Compute 1000+\([0-9]*\) .*/\1/p')
         [ "${FAKE_MODE:-}" != pnudgefail ] || { echo "nudge: falha falsa" >&2; exit 1; }
         [ "${FAKE_MODE:-}" = pnoreply ] && [ "$i" = 2 ] && exit 0  # o 3º prompt (i = 2) nunca é respondido
         echo "PONG$((1000+i))" >> "$S/pane"
         for t in "$SRV"/.claude/projects/-fake-*/s.jsonl; do :; done
         row() { printf '{"attachment":{"type":"%s","hookEvent":"UserPromptSubmit","command":"export PATH=x && gc nudge drain --inject","durationMs":%s,"exitCode":%s%s}}\n' "$1" "$2" "$3" "$4" >> "$t"; }
         if [ "${FAKE_MODE:-}" = pcancel ] && [ "$i" = 1 ]; then row hook_cancelled 30500 null ',"timedOut":true,"timeoutMs":30000'
         elif [ "${FAKE_MODE:-}" = pfail ] && [ "$i" = 1 ]; then row hook_success 700 1 ''
         elif [ "${FAKE_MODE:-}" = pnorows ] || { [ "${FAKE_MODE:-}" = pmissone ] && [ "$i" = 1 ]; }; then :  # a sessão RESPONDEU, mas o prompt não deixou registro de hook (os hooks podem nem ter rodado)
         else row hook_success 900 0 ''; fi;;
esac
EOF
chmod +x "$T/bin/"* "$SRV/gt-remote/bin/hetzner-remote-git.sh" "$T/fakeprov"; cat > "$SRV/.local/bin/claude" <<'EOF'
#!/bin/sh
[ -z "${FAKE_CLAUDE_FAIL:-}" ] || { echo "claude: falha falsa" >&2; exit 1; }
echo "$(cat "$HOME/.claude-version" 2>/dev/null) (Claude Code)"
EOF
chmod +x "$SRV/.local/bin/claude"
cp "$T/bin/bd" "$T/bin/gc" "$SRV/.local/bin/"
export PATH="$T/bin:$PATH"

# ---------------------------------------------------------------- unit
g_unit() {
  py 'assert M.pct(list(range(1, 21)), .95) == 19 and M.pct(list(range(1, 21)), .5) == 10 and M.pct([5], .95) == 5 and M.pct([3, 1, 2], .5) == 2'; ok $? "unit: pct = posto mais próximo (p95 de 20 é o 19º; a mediana de 20 é o 10º; ordem da entrada não importa)"
  py 'a={"rc":2,"out":"x","err":"m","log":""}; assert M.judge(a,dict(a),0)==("IGUAL","")'; ok $? "unit: judge igual"
  py 'a={"rc":2,"out":"x","err":"m","log":""}; assert M.judge(a,dict(a,rc=0),0)[0]=="DIFERENTE"'; ok $? "unit: judge — código de saída diferente = DIFERENTE"
  py 'a={"rc":0,"out":"x","err":"","log":""}; assert M.judge(a,dict(a,out="y"),0)[0]=="DIFERENTE"'; ok $? "unit: judge — saída padrão diferente = DIFERENTE"
  py 'a={"rc":2,"out":"","err":"m","log":""}; assert M.judge(a,dict(a,err="outra"),0)[0]=="DIFERENTE"'; ok $? "unit: judge — mensagem diferente quando o hook bloqueia (2) = DIFERENTE"
  py 'a={"rc":0,"out":"","err":"jq 1.7","log":""}; r=M.judge(a,dict(a,err="jq 1.8"),0); assert r[0]=="IGUAL" and "stderr" in r[1]'; ok $? "unit: judge — stderr diferente com código 0 é só nota, não diferença"
  py 'a={"rc":0,"out":"","err":"","log":""}; assert M.judge(a,{"fail":"X"},0)[0]=="NAO-RODOU" and M.judge({"fail":"X"},{"fail":"Y"},0)[0]=="NAO-RODOU" and M.judge(a,{},0)[0]=="NAO-RODOU"'; ok $? "unit: judge — lado que não rodou (ou sem código) nunca vira IGUAL"
}

# ---------------------------------------------------------------- hooks
hooks_ready() { for h in $HOOKS; do [ -r "$RH/$h" ] || return 1; done; command -v jq > /dev/null && command -v python3 > /dev/null; }
mk_hooks() { mkdir -p "$1/.claude/hooks"; for h in $HOOKS; do cp "$RH/$h" "$1/.claude/hooks/$h"; done; }
hp() { HOME="$MINI" python3 -I "$P" hooks --only s04,s09,f01,f02,m04,l01 "$@" > "$T/out" 2> "$T/err"; RC=$?; }
g_hooks() {
  if ! hooks_ready; then echo "SKIP hooks: faltam os 6 hooks em $RH (ou jq/python3)"; return; fi
  mk_hooks "$MINI"; mk_hooks "$SRV"
  hp; [ $RC = 0 ] && has "$T/out" "12 execuções: 12 iguais, 0 diferentes/mal escritas, 0 não rodaram"; ok $? "hooks: mesmos hooks nos dois HOMEs → 12 de 12 iguais, saída 0 (rc=$RC)"
  has "$T/out" "ferramenta jq"; ok $? "hooks: a tabela registra as ferramentas de cada lado (versão do grep/jq/awk)"
  FAKE_JQ_BAD="$T/badjq"; mkdir -p "$T/badjq"; printf '#!/bin/sh\nexit 0\n' > "$T/badjq/jq"; chmod +x "$T/badjq/jq"; export FAKE_JQ_BAD
  hp; [ $RC = 1 ] && has "$T/out" "DIFERENTE"; ok $? "hooks: mesmo arquivo, mas o ambiente do servidor muda a resposta (jq que não devolve nada) → DIFERENTE, saída 1 (rc=$RC)"
  unset FAKE_JQ_BAD
  echo "# a mais" >> "$SRV/.claude/hooks/filter-bash-output.sh"
  hp; [ $RC = 3 ] && has "$T/err" "NAO-COMPARAVEL"; ok $? "hooks: arquivo de hook diferente entre os lados → NAO-COMPARAVEL, saída 3 (rc=$RC)"
  cp "$RH/filter-bash-output.sh" "$SRV/.claude/hooks/"
  find "$SRV/.claude/hooks" -name 'log-token-usage.sh' -delete
  hp; [ $RC = 3 ]; ok $? "hooks: hook ausente no servidor → o lado não rodou, saída 3 e nunca 'igual' (rc=$RC)"
  cp "$RH/log-token-usage.sh" "$SRV/.claude/hooks/"
  FAKE_SSH_DEAD=1 hp; [ $RC = 3 ] && has "$T/err" "NAO CONSEGUI RODAR"; ok $? "hooks: ssh fora → NAO CONSEGUI RODAR, saída 3 (rc=$RC)"
  for d in "$MINI" "$SRV"; do printf '#!/bin/bash\nexit 0\n' > "$d/.claude/hooks/enforce-multiple-choice-question.sh"; done
  hp; [ $RC = 1 ] && has "$T/out" "CASO-RUIM"; ok $? "hooks: hook que não bloqueia onde o caso espera bloquear, igual nos dois lados → CASO-RUIM (a tabela de casos não exercita o ramo), saída 1 (rc=$RC)"
  mk_hooks "$MINI"; mk_hooks "$SRV"
  hp --only zzz; [ $RC = 2 ]; ok $? "hooks: --only que não casa nenhum caso → uso, saída 2 (rc=$RC)"
}

# ---------------------------------------------------------------- latency
lp() { HOME="$MINI" GC_CITY_PATH="$CITY" python3 -I "$P" latency "$@" > "$T/out" 2> "$T/err"; RC=$?; }
settings() { printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"%s"},{"command":"%s"}]}]}}\n' "$1" "$2" > "$SRV/gt-remote/bundle/city/settings.json"; cp "$SRV/gt-remote/bundle/city/settings.json" "$CITY/.gc/settings.json"; }
g_lat() {
  settings "sleep 1" "sleep 1.5"
  lp --prompts 3 --control 0 --timeout 20; [ $RC = 0 ] && has "$T/out" "3 prompts" && has "$T/out" "piso do atalho"; ok $? "lat: 3 prompts medidos, com o piso do atalho, saída 0 (rc=$RC)"
  w=$(grep -o 'parede *[0-9.]*' "$T/out" | awk '{print ($2 < 2.45) ? "ok" : "lento"}' | sort -u | tr '\n' ' ')
  [ "$w" = "ok " ]; ok $? "lat: os dois hooks rodam AO MESMO TEMPO (a parede é a do mais lento, ~1,5 s, não a soma, 2,5 s): $w"
  has "$T/out" "mediana"; ok $? "lat: a tabela traz mediana, p95 e máximo"
  settings "sleep 2" "sleep 0.2"
  lp --prompts 1 --control 0 --timeout 20; h=$(grep -o 'hooks \[[0-9., ]*\]' "$T/out" | head -1 | tr -d 'hooks []' | cut -d, -f2)
  awk -v h="${h:-99}" 'BEGIN {exit !(h < 1.0)}'; ok $? "lat: o hook RÁPIDO é medido por si (${h:-?} s, não os ~2 s do lento que o antecede: esperar um a um inflava o 2º)"
  settings "sleep 1" "sleep 1.5"
  lp --prompts 2 --control 2 --timeout 20; [ $RC = 0 ] && has "$T/out" "controle (mesmos hooks direto no mini, sem atalho)" && grep -q '^controle ' "$T/out"; ok $? "lat: o controle roda os mesmos hooks direto no mini e sai numa 2ª tabela (rc=$RC)"
  settings "exit 3" "sleep 0.2"
  lp --prompts 2 --control 0 --timeout 20; [ $RC = 1 ] && has "$T/out" "hooks com saída ≠ 0 ou timeout: 2"; ok $? "lat: hook que sai ≠ 0 conta como falha, saída 1 (rc=$RC)"
  settings "sleep 6" "sleep 0.1"
  lp --prompts 1 --control 0 --timeout 1; [ $RC = 1 ] && has "$T/out" "timeout"; ok $? "lat: hook que estoura o prazo aparece como timeout, saída 1 (rc=$RC)"
  settings "sleep 0.1" "sleep 0.1"
  FAKE_SSH_DEAD=1 lp --prompts 1 --control 0; [ $RC = 3 ] && has "$T/err" "NAO CONSEGUI MEDIR"; ok $? "lat: ssh fora → NAO CONSEGUI MEDIR, saída 3 (rc=$RC)"
  find "$SRV/gt-remote/bundle/city" -name settings.json -delete
  lp --prompts 1 --control 0; [ $RC = 3 ]; ok $? "lat: bundle sem settings no servidor → não medi, saída 3, nunca números inventados (rc=$RC)"
  lp --prompts 0; [ $RC = 2 ]; ok $? "lat: --prompts 0 → uso, saída 2 (rc=$RC)"
}

# ---------------------------------------------------------------- e2e
e2e_fixture() {  # estado limpo a cada caso: sessão, comentários, mail, origin, worktrees do "servidor"
  find "$FAKE_STATE" -mindepth 1 -delete; find "$T/origin.git" "$SRV/gt-remote/git" "$CITY/.gc/hetzner-mirror/repos" -delete 2> /dev/null
  git init -q "$T/seed" 2> /dev/null; git -C "$T/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed 2> /dev/null
  mkdir -p "$SRV/gt-remote/git/gascity/wt" "$CITY/.gc/hetzner-mirror/repos"
  git clone -q --bare "$T/seed" "$T/origin.git"; git clone -q --bare "$T/seed" "$SRV/gt-remote/git/gascity/repo.git"
  git -C "$SRV/gt-remote/git/gascity/repo.git" remote set-url origin "$T/origin.git"
  git init -q --bare "$CITY/.gc/hetzner-mirror/repos/gascity.git"; git -C "$CITY/.gc/hetzner-mirror/repos/gascity.git" config remote.origin.url "$T/origin.git"
  printf '{"projects":{}}\n' > "$SRV/.claude.json"; printf '{}\n{}\n' > "$SRV/.claude/usage-analytics.jsonl"
  echo 2.1.302 > "$SRV/.claude-version"; printf '{"outcome":"success"}\n' > "$SRV/.claude/.last-update-result.json"
}
ep() { sleep 1; e2e_fixture; HOME="$MINI" GC_CITY_PATH="$CITY" HETZNER_PROOF_PROV="$T/fakeprov" HETZNER_PROOF_GATE="$T/fakegate.py" HETZNER_REMOTE_HOME="$SRV" HETZNER_PROOF_POLL=0.3 python3 -I "$P" e2e --timeout "${TMO:-30}" "$@" > "$T/out" 2> "$T/err"; RC=$?; [ -z "${HPROOF_DEBUG:-}" ] || { cat "$T/out" "$T/err" >&2; }; }
calls() { grep -c "^$1" "$FAKE_STATE/provcalls" 2> /dev/null || true; }
g_e2e() {
  FAKE_MODE=ok ep; [ $RC = 0 ] && has "$T/out" "E2E PASSOU: 12 de 12 provas"; ok $? "e2e: sessão completa → 12 de 12 provas, saída 0 (rc=$RC)"
  has "$T/out" "PASS a branch chegou ao origin, com o mesmo sha do servidor"; ok $? "e2e: o sha da branch no origin é o do commit do servidor"
  [ "$(calls stop)" -ge 1 ] && [ ! -e "$FAKE_STATE/running" ]; ok $? "e2e: a sessão foi parada pelo provider no fim"
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); p=[k for k,v in d["projects"].items() if v.get("hasTrustDialogAccepted")]; assert len(p)==1 and "/wt/remote-e2e-" in p[0]' "$SRV/.claude.json"; ok $? "e2e: a pasta do worktree foi pré-confiada em ~/.claude.json pelo START (e só ela)"
  [ ! -d "$SRV/gt-remote/git/gascity/wt" ] || [ -z "$(ls "$SRV/gt-remote/git/gascity/wt")" ]; ok $? "e2e: o worktree é removido no fim"
  FAKE_MODE=ok ep --keep; [ -n "$(ls "$SRV/gt-remote/git/gascity/wt")" ]; ok $? "e2e: --keep deixa o worktree"
  FAKE_MODE=nopush ep; [ $RC = 1 ] && has "$T/out" "FAIL a branch chegou ao origin"; ok $? "e2e: sem push → a prova da branch reprova, saída 1 (rc=$RC)"
  FAKE_MODE=shamismatch ep; [ $RC = 1 ] && has "$T/out" "FAIL a branch chegou ao origin"; ok $? "e2e: branch no origin com sha diferente do servidor → reprova (rc=$RC)"
  FAKE_MODE=wrongid ep; [ $RC = 1 ] && has "$T/out" "FAIL commit no worktree do servidor, com a identidade da sessão"; ok $? "e2e: commit com a identidade de OUTRO autor → a prova do commit reprova (rc=$RC)"
  FAKE_MODE=nocomment ep; [ $RC = 1 ] && has "$T/out" "FAIL comentário da sessão na bead"; ok $? "e2e: sem comentário na bead → reprova (rc=$RC)"
  FAKE_MODE=nohandoff ep; [ $RC = 1 ] && has "$T/out" "FAIL handoff registrado no mini"; ok $? "e2e: sem mail de handoff → reprova (rc=$RC)"
  FAKE_MODE=noanalytics ep; [ $RC = 1 ] && has "$T/out" "FAIL hook de log"; ok $? "e2e: hook de log (PostToolUse) sem rodar → reprova (rc=$RC)"
  FAKE_MODE=nogchooks ep; [ $RC = 1 ] && has "$T/out" "FAIL hooks gc do city carregaram e dispararam"; ok $? "e2e: transcrição SEM os hooks gc do city (o --settings do city não carregou) → reprova (rc=$RC)"
  FAKE_MODE=hookerr ep; [ $RC = 1 ] && has "$T/out" "FAIL hooks keep rodaram na sessão real"; ok $? "e2e: hook keep com saída ≠ 0 na sessão real → reprova (rc=$RC)"
  FAKE_MODE=ok ep; grep -q 'mail archive ga-wisp-falso' "$FAKE_STATE/gcmail"; ok $? "e2e: o mail de handoff de teste é arquivado no fim"
  FAKE_MODE=ok ep --bead 'ga-x; touch /tmp/hproof-pwned'; [ $RC = 2 ] && has "$T/err" "id de bead inválido" && [ ! -e "$FAKE_STATE/provcalls" ] && [ ! -e /tmp/hproof-pwned ]; ok $? "e2e: --bead com cara de comando (; touch …) → erro de uso 2 antes de tocar no servidor ou no provider (rc=$RC)"
  FAKE_MODE=ok ep --model 'haiku --allow-all'; [ $RC = 2 ] && has "$T/err" "modelo inválido" && [ ! -e "$FAKE_STATE/provcalls" ]; ok $? "e2e: --model com espaço/flag extra → erro de uso 2 (rc=$RC)"
  FAKE_MODE=gctimeout ep; [ $RC = 0 ] && has "$T/out" "cancelado pelo prazo de 30000 ms" && has "$T/out" "ATENÇÃO: 1 hook(s) gc CANCELADO"; ok $? "e2e: hook gc cancelado pelo prazo do claude (30 s) NÃO derruba o pipeline, mas aparece dito à parte e com ATENÇÃO (rc=$RC)"
  FAKE_MODE=gcfail ep; [ $RC = 1 ] && has "$T/out" "FAIL hooks gc do city carregaram e dispararam" && has "$T/out" "FALHOU"; ok $? "e2e: hook gc que sai ≠ 0 na sessão real → reprova (rc=$RC)"
  FAKE_MODE=badline ep; [ $RC = 1 ] && has "$T/out" "FAIL hooks keep rodaram na sessão real" && has "$T/out" "1 linhas ilegíveis"; ok $? "e2e: linha ilegível na transcrição → a prova dos hooks reprova (uma linha perdida pode ser o hook que falhou) (rc=$RC)"
  FAKE_MODE=rmcity ep; [ -d "$CITY.gone" ] && mv "$CITY.gone" "$CITY"; [ $RC = 1 ] && has "$T/out" "FAIL execução até o fim sem interrupção" && has "$T/out" "E2E FALHOU" && [ "$(calls stop)" -ge 1 ]; ok $? "e2e: erro de execução no meio (a cidade some: bd/gc levantam OSError) → vira prova que reprova, o resumo sai e a sessão é parada (rc=$RC)"
  FAKE_MODE=dialog ep; [ $RC = 1 ] && has "$T/out" "FAIL sessão andou sem diálogo de primeira execução"; ok $? "e2e: diálogo de primeira execução → reprova mostrando a tela (rc=$RC)"
  [ "$(calls send-keys)" = 0 ] && [ "$(calls nudge)" = 0 ] && [ "$(calls stop)" -ge 1 ]; ok $? "e2e: o diálogo NUNCA é respondido (nenhum send-keys/nudge) e a sessão é parada"
  FAKE_MODE=die ep; [ $RC = 1 ] && has "$T/out" "FAIL sessão ficou de pé até o fim"; ok $? "e2e: sessão que morre antes do fim → reprova com a tela (rc=$RC)"
  FAKE_MODE=hang TMO=3 ep; [ $RC = 1 ] && has "$T/out" "FAIL sessão terminou os 7 passos no prazo" && [ "$(calls stop)" -ge 1 ]; ok $? "e2e: sessão que trava → reprova no prazo e é parada (rc=$RC)"
  FAKE_GATE_RC=1 ep; [ $RC = 3 ] && [ "$(calls start)" = 0 ]; ok $? "e2e: login do claude no servidor não vale (gate ≠ 0) → não começa, saída 3, nenhuma sessão aberta (rc=$RC)"
  FAKE_BD_FAIL=1 ep; [ $RC = 3 ] && [ "$(calls start)" = 0 ]; ok $? "e2e: atalho bd do servidor falha → não começa, saída 3 (rc=$RC)"
  FAKE_WT_FAIL=1 ep; [ $RC = 3 ] && [ "$(calls start)" = 0 ]; ok $? "e2e: worktree que não saiu → não começa, saída 3 (rc=$RC)"
  FAKE_WT_PULL=erro ep; [ $RC = 3 ] && [ "$(calls start)" = 0 ]; ok $? "e2e: o pull do espelho falhou (worktree sairia de um main velho) → não começa, saída 3 (rc=$RC)"
  FAKE_SSH_DEAD=1 ep; [ $RC = 3 ] && [ "$(calls start)" = 0 ]; ok $? "e2e: ssh fora → não começa, saída 3 (rc=$RC)"
  FAKE_MODE=ok ep
  has "$T/out" "PASS o START gravou a identidade git do worktree e a confiança da pasta" && has "$T/out" "PASS claude do servidor NÃO se atualizou durante a sessão"; ok $? "e2e: o driver CONFERE por fora o que o start gravou e que a versão do claude não mudou"
  has "$T/out" "worktree criado (identidade git e pasta pré-confiada ficam para o START do provider)"; ok $? "e2e: o PREPARE do driver só cria o worktree (a identidade e a confiança não são mais dele)"
  FAKE_MODE=notrust ep; [ $RC = 1 ] && has "$T/out" "FAIL o START gravou a identidade git do worktree e a confiança da pasta"; ok $? "e2e: o start NÃO gravou a confiança da pasta → a prova reprova (rc=$RC)"
  FAKE_MODE=noident ep; [ $RC = 1 ] && has "$T/out" "FAIL o START gravou a identidade git do worktree e a confiança da pasta" && has "$T/out" "PASS commit no worktree do servidor, com a identidade da sessão"; ok $? "e2e: o start NÃO gravou a identidade (a sessão comitou com -c, autor certo mas nada no worktree) → só a prova do start reprova (rc=$RC)"
  FAKE_MODE=prepfail ep; [ $RC = 1 ] && has "$T/out" "FAIL start pelo provider" && has "$T/out" "preparo da sessão remote-e2e-1 recusado"; ok $? "e2e: o start recusa o preparo → a prova do start reprova com a mensagem do provider e nada roda (rc=$RC)"
  FAKE_MODE=autoupdate ep; [ $RC = 1 ] && has "$T/out" "FAIL claude do servidor NÃO se atualizou durante a sessão" && has "$T/out" "2.1.302"; ok $? "e2e: o claude do servidor se atualiza no meio da sessão → a prova da versão reprova dizendo antes e depois (rc=$RC)"
  FAKE_CLAUDE_FAIL=1 ep; [ $RC = 3 ] && [ "$(calls start)" = 0 ]; ok $? "e2e: não consigo ler a versão do claude ANTES → não começa, saída 3 (versão desconhecida não vira 'estável') (rc=$RC)"
  FAKE_MODE=ok ep --prompts 3 --prompt-timeout 5; [ $RC = 0 ] && has "$T/out" "E2E PASSOU: 14 de 14 provas" && has "$T/out" "PASS 3 prompts respondidos pela sessão remota" && [ "$(calls nudge)" = 3 ]; ok $? "e2e: --prompts 3 → 3 nudges, 3 respostas, 14 de 14 provas (rc=$RC)"
  has "$T/out" "PASS 3 prompts: nenhum hook gc de UserPromptSubmit cancelado pelo prazo nem com erro"; ok $? "e2e: ...e nenhum hook gc de UserPromptSubmit cancelado nem com erro nos 3 prompts"
  FAKE_MODE=pcancel ep --prompts 3 --prompt-timeout 5; [ $RC = 1 ] && has "$T/out" "FAIL 3 prompts: nenhum hook gc de UserPromptSubmit cancelado pelo prazo nem com erro" && has "$T/out" "hook_cancelled"; ok $? "e2e: um hook gc cancelado pelo prazo num dos prompts → a prova reprova (os prompts foram respondidos, o hook não) (rc=$RC)"
  FAKE_MODE=pfail ep --prompts 3 --prompt-timeout 5; [ $RC = 1 ] && has "$T/out" "FAIL 3 prompts: nenhum hook gc de UserPromptSubmit cancelado pelo prazo nem com erro"; ok $? "e2e: um hook gc com saída ≠ 0 num dos prompts → reprova (rc=$RC)"
  FAKE_MODE=pnorows ep --prompts 3 --prompt-timeout 5; [ $RC = 1 ] && has "$T/out" "PASS 3 prompts respondidos pela sessão remota" && has "$T/out" "FAIL 3 prompts: nenhum hook gc de UserPromptSubmit cancelado pelo prazo nem com erro" && has "$T/out" "0 novos"; ok $? "e2e: os 3 prompts foram respondidos mas NENHUM deixou registro de hook → reprova (sem registro não há como dizer que nenhum foi cancelado) (rc=$RC)"
  FAKE_MODE=pmissone ep --prompts 3 --prompt-timeout 5; [ $RC = 1 ] && has "$T/out" "FAIL 3 prompts: nenhum hook gc de UserPromptSubmit cancelado pelo prazo nem com erro" && has "$T/out" "2 novos"; ok $? "e2e: um dos 3 prompts não deixou registro (2 novos de 3 esperados) → reprova (rc=$RC)"
  # leituras que FALHAM (ga-2hd02v.1.5.9): "não consegui ler" nunca vira "gravado" nem "nenhum cancelado" — a prova reprova
  FAKE_MODE=badjson ep; [ $RC = 1 ] && has "$T/out" "FAIL o START gravou a identidade git do worktree e a confiança da pasta"; ok $? "e2e: o ~/.claude.json do servidor está ILEGÍVEL depois do start → a prova do start reprova, não a dá por gravada (rc=$RC)"
  FAKE_MODE=nojson ep; [ $RC = 1 ] && has "$T/out" "FAIL o START gravou a identidade git do worktree e a confiança da pasta"; ok $? "e2e: o ~/.claude.json do servidor está AUSENTE depois do start → a prova do start reprova (rc=$RC)"
  if [ "$(id -u)" = 0 ]; then echo "SKIP  e2e: ~/.claude.json sem permissão de leitura: este usuário lê tudo (root)"; else
    FAKE_MODE=noperm ep; _rc=$RC; chmod 600 "$SRV/.claude.json" 2> /dev/null  # devolve a permissão ANTES de qualquer outro caso: o e2e_fixture regrava este arquivo
    [ $_rc = 1 ] && has "$T/out" "FAIL o START gravou a identidade git do worktree e a confiança da pasta"; ok $? "e2e: o ~/.claude.json do servidor existe mas NÃO pode ser lido (chmod 000) → a prova do start reprova (rc=$_rc)"
  fi
  FAKE_MODE=ok FAKE_HOOKLOG_FAIL_FROM=2 ep --prompts 3 --prompt-timeout 5; [ $RC = 1 ] && has "$T/out" "FAIL 3 prompts: hooks gc de UserPromptSubmit lidos na transcrição" && has "$T/out" "ANTES dos prompts" && [ "$(calls nudge)" = 0 ]; ok $? "e2e: a transcrição não pôde ser lida ANTES dos prompts → nenhum prompt é mandado e a prova reprova (rc=$RC, nudges=$(calls nudge))"
  FAKE_MODE=ok FAKE_HOOKLOG_FAIL_FROM=3 ep --prompts 3 --prompt-timeout 5; [ $RC = 1 ] && has "$T/out" "FAIL 3 prompts: hooks gc de UserPromptSubmit lidos na transcrição" && has "$T/out" "DEPOIS dos prompts" && [ "$(calls nudge)" = 3 ]; ok $? "e2e: a transcrição não pôde ser lida DEPOIS dos prompts → a prova reprova com 'não consegui ler', nunca 'nenhum cancelado' (rc=$RC)"
  FAKE_MODE=pnoreply ep --prompts 3 --prompt-timeout 2; [ $RC = 1 ] && has "$T/out" "FAIL 3 prompts respondidos pela sessão remota" && has "$T/out" "2 de 3"; ok $? "e2e: o 3º prompt não é respondido no prazo → para ali e reprova com a contagem (2 de 3) (rc=$RC)"
  FAKE_MODE=pnudgefail ep --prompts 3 --prompt-timeout 2; [ $RC = 1 ] && has "$T/out" "nudge falhou" && has "$T/out" "FAIL 3 prompts respondidos pela sessão remota"; ok $? "e2e: o nudge falha → o prompt NÃO conta como respondido e a prova reprova (rc=$RC)"
  FAKE_MODE=ok ep --prompts 101; [ $RC = 2 ] && [ ! -e "$FAKE_STATE/provcalls" ]; ok $? "e2e: --prompts 101 → erro de uso 2 antes de tocar no servidor (rc=$RC)"
  FAKE_MODE=ok ep --prompts -1; [ $RC = 2 ]; ok $? "e2e: --prompts -1 → erro de uso 2 (rc=$RC)"
  e2e_fixture; touch "$FAKE_STATE/running"; sleep 1
  HOME="$MINI" GC_CITY_PATH="$CITY" HETZNER_PROOF_PROV="$T/fakeprov" HETZNER_PROOF_GATE="$T/fakegate.py" HETZNER_REMOTE_HOME="$SRV" HETZNER_PROOF_POLL=0.3 FAKE_MODE=ok python3 -I "$P" e2e --timeout 30 > "$T/out" 2> "$T/err"; RC=$?
  [ $RC = 0 ] && [ "$(grep -n '^stop' "$FAKE_STATE/provcalls" | head -1 | cut -d: -f1)" -lt "$(grep -n '^start' "$FAKE_STATE/provcalls" | head -1 | cut -d: -f1)" ]; ok $? "e2e: sobra de sessão 'remote-e2e-1' é parada ANTES de abrir a nova (rc=$RC)"
}

all() { group unit && g_unit; group hooks && g_hooks; group lat && g_lat; group e2e && g_e2e; }
if [ -n "${HPROOF_MUTANT:-}" ]; then all; echo "RESULT $fails/$n"; exit $((fails > 0)); fi
all
echo "== $((n-fails))/$n ok =="

[ -n "${HPROOF_NO_MUTANTS:-}" ] || {
  echo "-- controle negativo: cada guarda removida TEM que fazer o grupo que a cobre falhar"
  mutant() {  # mutant GRUPOS DESCRIÇÃO SED-EXPR  (a cópia mutada tem que diferir do original)
    group "$1" || return 0
    [ "$1" != hooks ] || hooks_ready || { echo "SKIP mutante '$2': sem os 6 hooks"; return 0; }
    local m="$T/mut.$RANDOM"; mkdir -p "$m"; sed -e "$3" "$P" > "$m/hetzner-proof.py"
    if cmp -s "$P" "$m/hetzner-proof.py"; then ok 1 "mutante '$2': o sed não mudou nada (o teste do mutante está errado)"; return; fi
    local r; r=$(HPROOF_MUTANT=1 HPROOF_ONLY="$1" HPROOF_UNDER_TEST="$m/hetzner-proof.py" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$2' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$2' pego ($r)";; *) ok 1 "mutante '$2': execução sem resultado ($r)";; esac
  }
  mutant unit "pct com o índice deslocado" 's/math.ceil(p \* len(s)) - 1/math.ceil(p * len(s)) - 2/'
  mutant unit "judge ignora o código de saída" 's/a\["rc"\] != b\["rc"\] or //'
  mutant unit "judge ignora a saída padrão" 's/ or a\["out"\] != b\["out"\]//'
  mutant unit "judge: lado sem resultado vira IGUAL" 's/if "fail" in a or "fail" in b or "rc" not in a or "rc" not in b:/if False:/'
  mutant e2e "gate do login ignorado" 's/return g.returncode == 0 and rc == 0/return rc == 0/'
  mutant e2e "branch sem comparar o sha" 's/got == sha, /bool(got), /'
  mutant e2e "comentário sem conferir o run" 's/ and self.run in txt//'
  mutant e2e "handoff conta mail de antes da rodada" 's/x.get("created_at", "") >= self.t0/True/'
  mutant e2e "hook de log sem comparar a contagem" 's/int(n.group(1)) > self.analytics0/True/'
  mutant e2e "diálogo ignorado" 's/if any(d in seen for d in DIALOGS):/if False:/'
  mutant e2e "o driver não confere o que o start gravou (confiança)" "s/ and '\"trust\": true' in o2//"
  mutant e2e "o driver não confere o que o start gravou (identidade)" 's/ident = o2.splitlines()\[:2\] == \[ALIAS, f"{ALIAS}@gastown.invalid"\]/ident = True/'
  mutant e2e "versão do claude depois não é comparada com a de antes" 's/ver1 is not None and ver1 == self.ver0,/True,/'
  mutant e2e "versão do claude desconhecida antes da sessão não impede de começar" 's/ and self.ver0 is not None//'
  mutant e2e "prompt contado como respondido sem ver a resposta" 's/                got = want in self.out(self.prov("peek", ALIAS, "250"))/                got = True/'
  mutant e2e "hook gc cancelado/com erro nos prompts não reprova" 's/        broke = \[r for r in ups if not (r\["kind"\] == "hook_success" and r\["rc"\] == 0)\]/        broke = []/'
  mutant e2e "nudge que falha segue como se tivesse ido" 's/            if p.returncode != 0:/            if False:/'
  mutant e2e "--prompts sem limite" 's/    if a.cmd == "e2e" and not 0 <= a.prompts <= 100:/    if False:/'
  mutant e2e "prompt respondido sem registro de hook passa (só 'nenhum cancelado')" 's/ and new >= answered,$/,/'
  mutant e2e "registros novos contados sem descontar os que já existiam (o da partida cobre o que falta)" 's/new = len(ups) - len(before\[0\])/new = len(ups)/'
  mutant e2e "leitura da transcrição que falha vira lista vazia (0 registros) em vez de 'não consegui ler'" '/não consegui ler os hooks da transcrição/{n;s/return None/return [], 0/;}'
  mutant e2e "hook gc cancelado pelo prazo vira 'ok' em silêncio" 's/f"cancelado pelo prazo de {r\[.timeout.\]} ms" if r\["timeout"\] else "ok"/"ok" if True else "ok"/'
  mutant e2e "hook gc com erro passa como cancelado" 's/all(out(r) == "ok" or r\["timeout"\] for r in gc)/True/'
  mutant e2e "argumentos que vão ao shell remoto sem validar" 's/        if not re.fullmatch(rx, v):/        if False:/'
  mutant e2e "linha ilegível da transcrição não conta" 's/ and unreadable == 0//'
  mutant e2e "erro de execução derruba o driver em vez de virar prova" 's/        except (OSError, subprocess.SubprocessError) as e:  # ssh\/provider/        except ZeroDivisionError as e:  # ssh\/provider/'
  mutant e2e "sessão não é parada no fim" 's/        if self.started:/        if False:/'
  mutant e2e "sessão que morre não é notada" 's/            if run != "true":/            if False:/'
  mutant e2e "sobra de sessão não é parada" 's/        if ALIAS in left.split():/        if False:/'
  mutant e2e "prepare sem exigir o pull ok" "s/ and '\"pull\":\"ok\"' in o//"
  mutant e2e "commit sem conferir a identidade" 's/ and f"|{ALIAS}|" in o//'
  mutant lat "hooks em fila, não em paralelo" 's/^    return subprocess.Popen(\(.*\))$/    q = subprocess.Popen(\1); q.wait(); return q/'
  mutant lat "espera os hooks um a um (o mais rápido herda o tempo do lento que o antecede)" 's/                rc = p.poll()/                rc = p.wait()/'
  mutant lat "hook que falha não conta" 's/if h\["rc"\] != 0\]/if False]/'
  mutant lat "timeout vira sucesso" 's/rc = "timeout"/rc = 0/'
  mutant hooks "CASO-RUIM não reprova" 's/v == "IGUAL" and c\["expect"\] is not None and m.get("rc") != c\["expect"\]/False/'
  mutant hooks "arquivos de hook diferentes passam" 's/    if not same_files:/    if False:/'
  echo "== final: $((n-fails))/$n ok =="
}
[ "$fails" = 0 ]
