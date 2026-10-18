#!/usr/bin/env bash
# mbp-proof.selftest.sh — hermético: o "MBP" é uma pasta ($SRV) e o "ssh" é um falso que roda o comando no próprio mini com OUTRO HOME e um PATH limpo; o provider,
# o tmux, o claude, o puxador, o cliente do atalho e o bd do mini são falsos; o origin é um repositório bare local com um arquivo de "lead" de isca. O builder é o
# DE VERDADE (a CLI que o mbp-proof usa tem que casar com ele). Nada conecta em MBP, servidor, GitHub ou Dolt.
#
# Contents
#   Grupos · Controle negativo · Variáveis · O que NÃO prova
#
# GRUPOS: unit — judge_tree (todo processo com folga tem de ser rebaixado, e ao menos um tinha folga), PAUSE/CLEAN/SWEEP rodados de verdade, pedido de start, identidade, padrões de segredo ·
#   cli — argumento com cara de comando, sessão real, install sem --apply (nada conecta), plan contra o dry-run do provider (pula sem scripts/gc-session-ssh, p.ex. no nó Linux) ·
#   install — instalação com o builder real: bundle conferido LÁ, run/ preservada, cliente + links + config, spool 0700, nada em ~/.claude nem ~/.ssh, config do wrapper diferente = não sobrescreve, transferência adulterada = reprova sem trocar, ssh fora / MBP não livre = 3 ·
#   e2e — a prova inteira (a–e) contra o MBP falso, com modos de falha: cada prova reprova sozinha, o diálogo NUNCA é respondido, a sessão é parada em todo caminho, a pausa do Athos nunca é removida por nós, e o MBP volta ao que era (arquivos, ~/.claude.json, ~/.ssh, spool, bundle)
# CONTROLE NEGATIVO: cada guarda é trocada numa cópia (python, uma ocorrência exata) e os casos que a cobrem TÊM que passar a falhar.
# VARIÁVEIS: MBPT_UNDER_TEST (script a testar) · MBPT_ONLY (grupos separados por vírgula; ou --only=a,b) · MBPT_CASES (casos; ou --cases=a,b) · MBPT_NO_MUTANTS=1 (ou --no-mutants) · MBPT_DEBUG=1 (ou --debug: mostra a saída do driver em cada e2e)
# O QUE NÃO PROVA: o MBP de verdade (macOS, tmux, claude, a biblioteca de presença, o git/ssh com a credencial dele) — isso é o `e2e` ao vivo. Aqui o vigia falso olha o arquivo PAUSE e dá `renice`; a árvore de processos, o ps, o nice e o julgamento são reais.
set -u
for a in "$@"; do case "$a" in --no-mutants) MBPT_NO_MUTANTS=1;; --debug) MBPT_DEBUG=1;; --only=*) MBPT_ONLY="${a#--only=}";; --cases=*) MBPT_CASES="${a#--cases=}";; esac; done  # (o nó Linux repassa argumentos, não ambiente)
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${MBPT_UNDER_TEST:-$HERE/mbp-proof.py}"
BUILDER="$HERE/remote-bundle-build.py"
for v in $(env | sed -n 's/^\(GC_[A-Za-z0-9_]*\|MBP_PROOF_[A-Za-z0-9_]*\|FAKE_[A-Za-z0-9_]*\)=.*/\1/p') GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR GIT_WORK_TREE TMUX_TMPDIR; do unset "$v"; done
if [ -n "${MBPT_T:-}" ]; then T=$MBPT_T; OWNER=0; else T=$(mktemp -d "${TMPDIR:-/tmp}/mbpt.XXXXXX") || exit 2; T=$(cd "$T" && pwd -P); OWNER=1; fi  # (o controle negativo reaproveita o mundo do pai)
kill_leftovers() { pkill -f -- "$T/srv/gt-remote" > /dev/null 2>&1; pkill -f -- 'sleep 6007' > /dev/null 2>&1; return 0; }
trap 'if [ "$OWNER" = 1 ]; then kill_leftovers; find "$T" -delete 2>/dev/null; fi' EXIT  # (sem `exit`: o trap não pode trocar o código de saída do teste)
n=0; fails=0; skipped=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
skip() { skipped=$((skipped+1)); echo "SKIP $1"; }
group() { [ -z "${MBPT_ONLY:-}" ] || case ",$MBPT_ONLY," in *",$1,"*) return 0;; *) return 1;; esac; }
c() { [ -z "${MBPT_CASES:-}" ] || case ",$MBPT_CASES," in *",$1,"*) return 0;; *) return 1;; esac; }  # c NOME — o caso roda?
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
sha() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
dsig() {  # dsig DIR... — assinatura de nomes (relativos à raiz) e conteúdo (nada muda sem mudar isto)
  python3 -I -c '
import hashlib, os, sys
h = hashlib.sha256()
for root in sys.argv[1:]:
    for d, dirs, names in sorted(os.walk(root)):
        dirs.sort()
        h.update(("D" + os.path.relpath(d, root)).encode())  # relativo à raiz: a cópia de referência (GOLD) e o mundo vivo (SRV) ficam em caminhos diferentes
        for x in sorted(names):
            p = os.path.join(d, x)
            h.update(os.path.relpath(p, root).encode())
            if not os.path.islink(p):
                h.update(open(p, "rb").read())
print(h.hexdigest())' "$@"
}
py() { python3 -I -c 'import importlib.machinery as m,sys; M=m.SourceFileLoader("mp",sys.argv[1]).load_module(); '"$1" "$P"; }

SRV="$T/srv"; MINI="$T/mini"; CITY="$T/city"; GOLD="$T/golden"; export SRV CITY FAKE_STATE="$T/state" T
ROLE="$CITY/.gc/agents/dogs/gastown.dog-1"
export HOME="$MINI" GC_CITY_PATH="$CITY" GC_SSH_BIN="$T/bin/ssh" MBP_PROOF_HOME="$SRV" MBP_PROOF_SSH="fake@mbp" MBP_PROOF_POLL=0.2 MBP_PROOF_SHIM_WAIT=3 MBP_PROOF_WATCH_CYCLE=0.3 \
  MBP_PROOF_PROV="$T/fakeprov" MBP_PROOF_PUMP="$T/fakepump.py" MBP_PROOF_SHIM_CLIENT="$T/fake-remote-shim.py" MBP_PROOF_BUILDER="$BUILDER" \
  MBP_PROOF_PATHX="$SRV/gt-remote/shim-bin:$SRV/fakebin"

if [ -z "${MBPT_T:-}" ]; then
mkdir -p "$T/bin" "$T/seed" "$MINI/.claude/hooks" "$CITY/.gc/agents/dogs/gastown.dog-1/.claude" "$FAKE_STATE"
cat > "$T/bin/ssh" <<'EOF'
#!/bin/sh
echo x >> "$FAKE_STATE/sshcalls"
[ -z "${FAKE_SSH_DEAD:-}" ] || { echo "ssh: connect to host fake port 22: Connection refused" >&2; exit 255; }
while [ "${1#-}" != "$1" ]; do case $1 in -o) shift 2;; *) shift;; esac; done
shift
cmd=$1
if [ -n "${FAKE_UPLOAD_FAIL:-}" ]; then case $cmd in *"cat > "*"remote-bundle-build.py"*) cat > /dev/null; echo "cat: cannot write: Read-only file system" >&2; exit 1;; esac; fi
if [ "${FAKE_MODE:-}" = snapfail ]; then case $cmd in *proofs_new*) touch "$FAKE_STATE/cleaned";; *'"plib"'*) [ ! -e "$FAKE_STATE/cleaned" ] || { cat > /dev/null; echo "snap: boom" >&2; exit 1; };; esac; fi  # a leitura DEPOIS da limpeza falha
HOME="$SRV" TMUX_TMPDIR="$SRV/tmp" ON_MBP=1 PATH="$SRV/fakebin:/usr/bin:/bin" sh -c "$cmd"; rc=$?
if [ -n "${FAKE_TAMPER:-}" ]; then case $cmd in *"; tar -C "*" -xf -") d=${cmd##*tar -C }; d=${d% -xf -}; echo adulterado > "$d/injetado.txt";; esac; fi
exit $rc
EOF
cat > "$T/bin/bd" <<'EOF'
#!/bin/sh
case "$1" in
  comments) printf '['; sep=; while IFS= read -r l; do printf '%s{"text":"%s"}' "$sep" "$l"; sep=,; done < "$FAKE_STATE/comments" 2>/dev/null; printf ']\n';;
esac
EOF
cat > "$T/fakepump.py" <<'EOF'
import os, sys
open(os.environ["FAKE_STATE"] + "/pumpcalls", "a").write(" ".join(sys.argv[1:]) + "\n")
if os.environ.get("FAKE_PUMP_FAIL") and sys.argv[1] == "ensure":
    print("pump: falhou"); sys.exit(1)
print("ok")
EOF
cat > "$T/fake-remote-shim.py" <<'EOF'
#!/usr/bin/env python3
import os, shutil, sys
me = os.path.basename(sys.argv[0])
if sys.argv[1:2] == ["install"]:
    if "--apply" not in sys.argv:
        print("plano"); sys.exit(0)
    d = sys.argv[sys.argv.index("--bin-dir") + 1]
    os.makedirs(d, exist_ok=True)
    dst = os.path.join(d, "remote-shim")
    shutil.copyfile(sys.argv[0], dst); os.chmod(dst, 0o755)
    for n in ("bd", "gc", "gate-done"):
        p = os.path.join(d, n)
        if os.path.lexists(p):
            os.unlink(p)
        os.symlink("remote-shim", p)
    print("instalado"); sys.exit(0)
if not os.environ.get("GC_SESSION_NAME", "").startswith("remote-test-remote-mbp-"):
    sys.stderr.write("remote-shim: recusado: identidade fora do padrão\n"); sys.exit(77)
if os.environ.get("FAKE_SHIM_DEAD"):
    sys.stderr.write("remote-shim: o mini não está puxando pedidos\n"); sys.exit(75)
if me == "bd" and sys.argv[1:2] == ["show"]:
    print('[{"id": "%s", "title": "falsa"}]' % sys.argv[2])
elif me == "bd" and sys.argv[1:2] == ["comment"]:
    open(os.environ["FAKE_STATE"] + "/comments", "a").write(" ".join(sys.argv[3:]) + "\n")
EOF
cat > "$T/watch.body" <<'EOF'
export PRESENCE_LIB_ONLY=1; me=$1; pause=$2; nowatch=$3; killcore=$4
desc() { ps -axo pid=,ppid= | awk -v r="$me" -v w="$$" '{pp[$1]=$2} END{for(i in pp){q=i;n=0;while(q>1&&n<64){if(q==r&&i!=w){print i;break};q=pp[q];n++}}}'; }
while :; do
  if [ -e "$pause" ] && [ -z "$nowatch" ]; then
    for p in $(desc); do
      if [ -n "$killcore" ]; then case "$(ps -o args= -p "$p" 2>/dev/null)" in *--settings*) kill "$p" 2>/dev/null; continue;; esac; fi
      renice -n 19 -p "$p" >/dev/null 2>&1
    done
  fi
  sleep 0.3
done
EOF
cat > "$T/fakeprov" <<'EOF'
#!/bin/bash
S="$FAKE_STATE"; echo "$*" >> "$S/provcalls"; op=${1:-}; shift
NAME=remote-test-remote-mbp-1; G="$SRV/gt-remote"; BUNDLE="$G/bundle"; PAUSE="$G/PAUSE"; SOCK="$SRV/tmp/tmux-$(id -u)/gc-remote"; mode=${FAKE_MODE:-ok}
kids() { ps -axo pid=,ppid= | awk -v r="$1" '{p[$1]=$2} END{for(i in p){q=i;n=0;while(q>1&&n<64){if(q==r){print i;break};q=p[q];n++}}}'; }
killtree() { local k; k=$(kids "$1"); [ -n "$k" ] || return 0; kill -TERM $k 2>/dev/null; sleep 0.3; kill -KILL $k 2>/dev/null; return 0; }
agent() {  # a "sessão": os 6 passos do prompt, com o modo de falha pedido
  local wd=$1 run=$2 idopt= d t
  cd "$wd" || return
  export HOME="$SRV" PATH="$G/shim-bin:$SRV/fakebin:/usr/bin:/bin" GC_ALIAS=$NAME GC_AGENT=$NAME GC_SESSION_NAME=$NAME GC_TEMPLATE=$NAME
  sleep "${FAKE_DELAY:-0.5}"
  case $mode in
    dialog) echo "Is this a project you created or one you trust? Yes, I trust this folder" > "$S/screen"; return;;
    die) echo "claude: morreu" > "$S/screen"; killtree "$(cat "$S/panepid")"; return;;
    hang) echo "pensando..." > "$S/screen"; return;;
  esac
  { echo '$ command -v bd gc'; command -v bd gc; } >> "$S/screen"
  bd show ga-x --json > /dev/null
  [ $mode = nocomment ] || bd comment ga-x "$NAME: sessao remota no MBP $run leu esta bead"
  [ $mode != wrongid ] || idopt="-c user.name=outro -c user.email=outro@x.invalid"
  mkdir -p mbp-proof
  if [ $mode = wrongcontent ]; then echo "outro conteudo" > "mbp-proof/$run.txt"; else echo "mbp-proof $run" > "mbp-proof/$run.txt"; fi
  git add "mbp-proof/$run.txt"
  git $idopt commit -q -m "chore(mbp-proof): $run (sem dado, descartavel)" || { echo "commit falhou" >> "$S/screen"; return; }
  [ $mode != evilpush ] || git push -q origin HEAD:refs/heads/evil 2>> "$S/pusherr"
  [ $mode = nopush ] || git push -q origin "HEAD:refs/heads/worker/$run" 2>> "$S/pusherr"
  [ $mode != shamismatch ] || git commit -q --amend -m "outra mensagem"
  case $mode in
    secret) printf 'token ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$G/shim/vazou.txt";;
    leadfile) echo "joao@example.com" > "$wd/leads.csv";;
    bigfile) head -c 3100000 /dev/zero > "$wd/grande.bin";;
    credleak) echo "https://u:pppppppp@github.com" > "$SRV/.git-credentials";;
    sshkey) echo "chave" > "$SRV/.ssh/id_ed25519";;
    transcriptsecret) mkdir -p "$SRV/.claude/projects/-fake-$run"; printf 'ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$SRV/.claude/projects/-fake-$run/vazou.txt";;
  esac
  d="$SRV/.claude/projects/-fake-$run"; mkdir -p "$d"; t="$d/s.jsonl"
  hk() { printf '{"attachment":{"type":"hook_success","hookEvent":"%s","command":"%s","durationMs":%s,"exitCode":%s}}\n' "$1" "$2" "$3" "$4" >> "$t"; }
  [ $mode != gctimeout ] || echo '{"attachment":{"type":"hook_cancelled","hookEvent":"UserPromptSubmit","command":"export PATH=x && gc mail check --inject","durationMs":30512,"timedOut":true,"timeoutMs":30000}}' >> "$t"
  [ $mode != gcfail ] || hk UserPromptSubmit 'export PATH=x && gc mail check --inject' 700 1
  [ $mode = nogchooks ] || { hk SessionStart 'export PATH=x && GC_MANAGED_SESSION_HOOK=1 gc prime --hook' 2100 0; hk UserPromptSubmit 'export PATH=x && gc nudge drain --inject' 900 0; }
  [ $mode != badline ] || echo 'isto nao e json' >> "$t"
  [ $mode != foreignpause ] || echo "origem=athos desde=2026-10-18T10:00:00" > "$PAUSE"
  echo "E2E-42-OK" >> "$S/screen"
}
case "$op" in
  gate)
    if [ -e "$PAUSE" ]; then
      [ $mode != swappause ] || [ -f "$S/swapped" ] || { echo "origem=athos desde=2026-10-18T10:00:00" > "$PAUSE"; touch "$S/swapped"; }   # o Athos pausa de verdade, por cima da marca da prova
      echo '{"ok":false,"reason":"pausa do Athos ativa"}'; exit 1
    fi
    g=${FAKE_GATE:-free}; [ ! -f "$S/started" ] || [ -z "${FAKE_GATE_AFTER_START:-}" ] || g=$FAKE_GATE_AFTER_START
    case $g in
      free) echo '{"ok":true,"reason":"livre","cap":2,"slot_cap":2}';;
      athos) echo '{"ok":false,"reason":"Athos está no MBP (presença=mbp)"}'; exit 1;;
      health) echo '{"ok":false,"reason":"MBP sem saúde ou fora do ar (rc 98)"}'; exit 1;;
      flag) echo '{"ok":false,"reason":"bandeira mbp-offload desligada"}'; exit 1;;
      garbage) echo 'not-json {{{'; exit 0;;
      nodict) echo '[1]'; exit 0;;
    esac;;
  start)
    req=$(cat); [ $mode != startfail ] || { echo "gc-session-ssh: start recusado: falha falsa" >&2; exit 1; }
    printf '%s' "$req" > "$S/startreq"
    wd=$(printf '%s' "$req" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["work_dir"])')
    mkdir -p "$BUNDLE/run" "$(dirname "$SOCK")"; : > "$SOCK"; : > "$S/screen"; touch "$S/running" "$S/started"
    L="$BUNDLE/run/$NAME.sh"; nw=${FAKE_NOWATCH:-}; kc=${FAKE_KILLCORE:-}   # os modos do vigia vêm do MODO do caso (fail1 só define FAKE_MODE)
    [ $mode != nowatch ] || nw=1; [ $mode != killcore ] || kc=1
    cat > "$L" <<EOS
#!/bin/bash
bash -c "\$(cat '$T/watch.body')" _ \$\$ '$PAUSE' '$nw' '$kc' &
nice -n 10 sh -c 'sleep 6007; : --settings $BUNDLE/city/settings.json' &
wait
EOS
    nohup bash "$L" > /dev/null 2>&1 < /dev/null &
    echo $! > "$S/panepid"
    ( agent "$wd" "$(basename "$wd")" ) > /dev/null 2>&1 < /dev/null &
    ;;
  peek) cat "$S/screen" 2>/dev/null;;
  nudge) cat > "$S/nudged"; [ $mode != nonudge ] || { echo "nudge: falha falsa" >&2; exit 1; }
         [ $mode = nonudgeanswer ] || { ( sleep 0.4; echo "NUDGE-25-OK" >> "$S/screen" ) > /dev/null 2>&1 < /dev/null & };;
  is-running) if [ -f "$S/running" ] && kill -0 "$(cat "$S/panepid")" 2>/dev/null; then echo true; else echo false; fi;;
  list-running) [ ! -f "$S/running" ] || echo "$NAME";;
  stop) [ $mode != stopfail ] || { echo "stop: falha falsa" >&2; exit 1; }
        if [ -f "$S/panepid" ] && [ $mode != leaveproc ] && [ $mode != stopfail ]; then killtree "$(cat "$S/panepid")"; fi
        [ $mode = leavefile ] || rm -f "$BUNDLE/run/$NAME.sh"
        [ $mode = leavesocket ] || rm -f "$SOCK"
        rm -f "$S/running";;
esac
exit 0
EOF
mkdir -p "$T/fake"
cat > "$T/fake/tmux" <<'EOF'
#!/bin/sh
S="$FAKE_STATE"
[ "$1" != -L ] || shift 2
case "$1" in
  list-sessions)
    case "${FAKE_TMUX:-}" in mismatch) echo "protocol version mismatch (client 8, server 7)" >&2; exit 1;; nosock) echo "error connecting to /tmp/tmux-501/gc-remote (No such file or directory)" >&2; exit 1;; esac
    if [ -f "$S/running" ]; then echo remote-test-remote-mbp-1; exit 0; fi; echo "no server running" >&2; exit 1;;
  list-panes) if [ -f "$S/running" ]; then cat "$S/panepid"; exit 0; fi; echo "can't find session" >&2; exit 1;;
esac
exit 1
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/fake/claude"
chmod +x "$T/bin/"* "$T/fakeprov" "$T/fake/"* "$T/fake-remote-shim.py"
# origin de isca: tem dado de "lead" que NUNCA pode aparecer no MBP
git init -q "$T/seed" 2>/dev/null; mkdir -p "$T/seed/data" "$T/seed/.beads"
echo "LEAD-DATA-9981,joao@example.com" > "$T/seed/data/leads.csv"; echo '{"id":"ga-x"}' > "$T/seed/.beads/issues.jsonl"; echo "# repo" > "$T/seed/README.md"
git -C "$T/seed" add -A; git -C "$T/seed" -c user.name=t -c user.email=t@t commit -q -m seed
# o mini: ~/.claude e a cidade com o mínimo que o builder de verdade exige
printf '#!/bin/sh\nexit 0\n' > "$MINI/.claude/hooks/ntfy-on-stop.sh"; chmod +x "$MINI/.claude/hooks/ntfy-on-stop.sh"
echo '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/ntfy-on-stop.sh"}]}]}}' > "$MINI/.claude/settings.json"
cat > "$CITY/.gc/settings.json" <<'EOF'
{"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "export PATH=\"$HOME/go/bin:$HOME/.local/bin:$PATH\" && GC_MANAGED_SESSION_HOOK=1 gc prime --hook"}]}],
 "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "export PATH=\"$HOME/go/bin:$HOME/.local/bin:$PATH\" && gc nudge drain --inject"}]}]}}
EOF
echo '{"autoMemoryEnabled": false}' > "$ROLE/.claude/settings.json"
fi
export PATH="$T/bin:$PATH"

srv_skeleton() {  # o "MBP" antes da instalação: o que o Athos já tem (claude, tmux, git, python3, a biblioteca de presença, ~/.ssh, ~/.claude.json)
  find "$SRV" -mindepth 1 -delete 2> /dev/null; mkdir -p "$SRV/fakebin" "$SRV/tmp" "$SRV/gt-remote/bin" "$SRV/.ssh" "$SRV/.claude"
  cp "$T/fake/tmux" "$T/fake/claude" "$SRV/fakebin/"
  for t in python3 git; do [ -x "/usr/bin/$t" ] || [ -x "/bin/$t" ] || ln -s "$(command -v $t)" "$SRV/fakebin/$t"; done
  printf '#!/bin/sh\n' > "$SRV/gt-remote/bin/mbp-presence.sh"
  printf '{"projects": {}, "numStartups": 3}\n' > "$SRV/.claude.json"
  echo "github.com ssh-ed25519 AAAAfake" > "$SRV/.ssh/known_hosts"; echo "ssh-ed25519 AAAAfake athos@mbp" > "$SRV/.ssh/authorized_keys"
}
world_reset() {
  find "$FAKE_STATE" -mindepth 1 -delete 2> /dev/null; find "$T/origin.git" "$CITY/.gc/runtime" "$CITY/.gc/logs" "$MINI/.gastown" -delete 2> /dev/null
  git clone -q --bare "$T/seed" "$T/origin.git"; git -C "$T/origin.git" config uploadpack.allowFilter true; git -C "$T/origin.git" config uploadpack.allowAnySHA1InWant true
  kill_leftovers
}
URL="file://$T/origin.git"
proof() { python3 -I "$P" "$@"; }
inst() { world_reset; proof install --apply > "$T/out" 2> "$T/err"; RC=$?; [ -z "${MBPT_DEBUG:-}" ] || cat "$T/out" "$T/err" >&2; }
calls() { grep -c "^$1" "$FAKE_STATE/provcalls" 2> /dev/null || true; }
mkgold() {  # a instalação de referência (feita pelo próprio script sob teste): cada e2e parte de uma cópia dela
  [ -d "$GOLD" ] && return 0
  srv_skeleton; inst; [ $RC = 0 ] || { echo "FAIL a instalação de referência não saiu (rc=$RC): $(tail -3 "$T/out")"; return 1; }
  cp -a "$SRV" "$GOLD"
}

# ---------------------------------------------------------------- unit
g_unit() {
  J='b=[dict(pid=10,ppid=1,ni=0,pri=31,comm="pane"),dict(pid=11,ppid=10,ni=10,pri=41,comm="claude"),dict(pid=12,ppid=10,ni=0,pri=31,comm="PRESENCE_LIB_ONLY"),dict(pid=13,ppid=12,ni=0,pri=31,comm="sleep")]
a=[dict(r,ni=19 if r["pid"] in (10,11) else r["ni"]) for r in b]'
  c judge-ok && { py "$J"'
ok,rows,why=M.judge_tree(b,a,12); assert ok and [r[0] for r in rows]==[10,11] and why=="", (ok,rows,why)
assert M.judge_tree(b,a,0)[0] is False
b.append(dict(pid=14,ppid=10,ni=0,pri=31,comm="git")); assert M.judge_tree(b,a,12)[0] is True'; ok $? "unit: judge_tree — todos os processos comparáveis rebaixados (19 e acima do que eram); o vigia e o filho dele (sleep) ficam de fora; sem o vigia identificado não há o que julgar (reprova); processo passageiro que sumiu não conta contra (o chamador confere à parte que a sessão não morreu)"; }
  c judge-one && { py "$J"'
a[1]["ni"]=10
ok,rows,why=M.judge_tree(b,a,12); assert not ok and "11" in why, (ok,why)'; ok $? "unit: judge_tree — UM processo sem rebaixar reprova e é nomeado"; }
  c judge-floor && { py "$J"'
b[1]["ni"]=19
ok,rows,why=M.judge_tree(b,a,12); assert ok and why=="", (ok,why)'; ok $? "unit: judge_tree — processo que já estava em 19 (sem folga) e segue em 19 não reprova, desde que outro tinha folga e foi rebaixado"; }
  c judge-room && { py "$J"'
for r in b: r["ni"]=19
ok,rows,why=M.judge_tree(b,b,12); assert not ok and "folga" in why, (ok,why)'; ok $? "unit: judge_tree — ninguém tinha folga (todos já em 19): nada prova o vigia, reprova"; }
  c judge-up && { py "$J"'
b[1]["ni"]=19; a[1]["ni"]=5
ok,rows,why=M.judge_tree(b,a,12); assert not ok and "11" in why, (ok,why)'; ok $? "unit: judge_tree — processo que estava em 19 e voltou a prioridade maior reprova e é nomeado"; }
  c judge-none && { py "$J"'
a=[dict(r,pid=r["pid"]+100,ppid=r["ppid"]+100 if r["ppid"]>1 else 1) for r in a]
ok,rows,why=M.judge_tree(b,a,112); assert not ok and "nada a comparar" in why, (ok,why)'; ok $? "unit: judge_tree — nenhum processo existe antes e depois: nada a comparar (reprova, não passa em silêncio)"; }
  c family && { py 'r=[dict(pid=2,ppid=1),dict(pid=3,ppid=2),dict(pid=4,ppid=3),dict(pid=5,ppid=1)]
assert M.family(r,2)=={2,3,4}'; ok $? "unit: family — o processo e todos os descendentes, nada além"; }
  c startreq && { py 'r=M.start_request("ga-w7qwl1.1","haiku","mbp-20260101-000000","/w/x")
assert r["work_dir"]=="/w/x" and r["prompt_flag"]=="" and all(r["env"][k]==M.SESSION for k in ("GC_ALIAS","GC_AGENT","GC_SESSION_NAME","GC_TEMPLATE")), r["env"]
assert r["command"].rstrip().endswith("--settings "+M.CITY+"/.gc/settings.json") and "--model haiku" in r["command"]
assert "ga-w7qwl1.1" in r["prompt_suffix"] and "mbp-20260101-000000" in r["prompt_suffix"] and "E2E-$((6*7))-OK" in r["prompt_suffix"] and "E2E-42-OK" not in r["prompt_suffix"]'; ok $? "unit: o pedido de start — identidade da sessão de teste, o --settings do city por ÚLTIMO, e o prompt só tem a conta (o número só aparece se o comando rodou)"; }
  c hostblock && { py 'h=M.host_block(); assert h["shim"]["spool_dir"]==M.SPOOL and h["path_extra"][0]==M.SHIMBIN and h["remote_root"]==M.BUNDLE and h["remote_home"]==M.MHOME
assert M.client_config()=={"transport":"spool","spool_dir":M.SPOOL,"timeout_s":330}'; ok $? "unit: o bloco do host mbp — o atalho PRIMEIRO no PATH; a config do cliente é só a puxada (sem host, usuário nem chave)"; }
  c identity && { py 'import re
rx=re.compile(M.wrapper_config()["identity_pattern"])
assert rx.fullmatch("remote-test-remote-mbp-1") and rx.fullmatch("remote-test-remote-mbp-123")
assert not any(rx.fullmatch(x) for x in ("remote-test-remote-mbp-1234","remote-e2e-1","gastown.dog-1","remote-test-remote-mbp-1; x","remote-mbp-1","gastown.mayor"))
assert M.wrapper_config()["gate_done_bin"] is None'; ok $? "unit: a identidade do wrapper do MBP aceita SÓ a sessão de teste (sessão real é da fatia 3)"; }
  c tmuxstate && { py 'T=lambda rc,out="",err="": {"tmux":{"rc":rc,"out":out,"err":err}}
want={"livre":[T(1,"","no server running on /tmp/x"),T(1,"","error connecting to /tmp/x (No such file or directory)"),T(0,"")],
 "aberta":[T(0,"remote-test-remote-mbp-1")],
 "nao-sei":[T(1,"","protocol version mismatch"),T(1,"","error connecting to /tmp/x (Permission denied)"),T(127,"","[Errno 2] tmux"),T(1),{"_erro":"ssh"},{"tmux":None},{},{"tmux":{"rc":None,"out":"","err":""}}]}
for k,v in want.items():
    for s in v: assert M.tmux_state(s)==k,(k,s)'; ok $? "unit: tmux_state — só lista vazia ou \"sem servidor\"/\"sem socket\" é livre; falha de outro tipo, rc 127, erro do ssh e leitura sem forma são \"não sei\""; }
  c patterns && { py 'import re
S=[re.compile(x) for x in M.SECRET_RX]; F=[re.compile(x) for x in M.FORBIDDEN]
hit=lambda s: any(x.search(s) for x in S)
assert hit("ghp_"+"a"*36) and hit("-----BEGIN OPENSSH PRIVATE KEY-----") and hit("https://u:senha123@github.com/x") and hit("\"token\": \"abcdefgh1234\"")
assert not hit("tokenizer") and not hit("git@github.com:athosmartins/gastown.git") and not hit("mbp-proof mbp-20260101-000000")
bad=lambda n: any(x.fullmatch(n) for x in F)
assert all(bad(n) for n in (".env",".env.local","leads.csv","id_ed25519","x.sqlite3","dados.xlsx",".beads",".dolt","k.pem","credentials.json"))
assert not any(bad(n) for n in ("README.md","mbp-proof","mbp-20260101-000000.txt","settings.json","remote-shim"))'; ok $? "unit: padrões de segredo e de arquivo de dado/credencial — pega o que tem que pegar e não pega o que a prova grava"; }
  c defaulturls && { git init -q "$T/u-city" 2>/dev/null; git -C "$T/u-city" remote add origin https://github.com/x/y.git
    GC_CITY_PATH="$T/u-city" py 'assert M.Proof.default_urls()==["https://github.com/x/y.git","git@github.com:x/y.git"], M.Proof.default_urls()'; ok $? "unit: URLs do origin — https primeiro, ssh depois, a partir do remote da cidade"; }
  c pausepy && { mkdir -p "$T/u"; UD="$T/u" py 'import subprocess,json,os
p=os.environ["UD"]+"/gt/PAUSE"
def run(mode,mark): return json.loads(subprocess.run(["python3","-I","-",json.dumps({"pause":p,"mark":mark,"mode":mode})],input=M.PAUSE_PY.encode(),capture_output=True).stdout.decode().strip().split("\n")[-1])
assert run("on","origem=mbp-proof:A")["ok"] and open(p).readline().startswith("origem=mbp-proof:A")
assert not run("on","origem=mbp-proof:B")["ok"]
r=run("off","origem=mbp-proof:B"); assert not r["ok"] and os.path.exists(p) and open(p).readline().startswith("origem=mbp-proof:A")
assert run("off","origem=mbp-proof:A")["ok"] and not os.path.exists(p)
assert run("off","origem=mbp-proof:A")["ok"]
open(p,"w").write("origem=athos desde=x\n")
r=run("off","origem=mbp-proof:A"); assert not r["ok"] and os.path.exists(p) and "NÃO é desta rodada" in r["why"]
assert not run("on","origem=mbp-proof:A")["ok"] and open(p).readline().startswith("origem=athos")'; ok $? "unit: PAUSE — liga só se não houver pausa; desliga SÓ a que tem a marca desta rodada; a pausa do Athos nunca é removida nem sobrescrita"; }
  c cleanpy && { mkdir -p "$T/u2/gt-remote/proof/mbp-20260101-000000/.git" "$T/u2/gt-remote/bundle/run"; echo '{"projects": {"/x": {"a": 1}, "'"$T"'/u2/gt-remote/proof/mbp-20260101-000000": {"hasTrustDialogAccepted": true}}, "keep": 7}' > "$T/u2/.claude.json"
    UD="$T/u2" py 'import subprocess,json,os
U=os.environ["UD"]; wd=U+"/gt-remote/proof/mbp-20260101-000000"
def run(**kw):
    a={"workdir":wd,"proofs":U+"/gt-remote/proof","home":U,"bundle":U+"/gt-remote/bundle","socket":"gc-test-x","proofs_new":True,"run_new":True,"socket_new":False}; a.update(kw)
    return json.loads(subprocess.run(["python3","-I","-",json.dumps(a)],input=M.CLEAN.encode(),capture_output=True).stdout.decode().strip().split("\n")[-1])
r=run(workdir="/etc/passwd"); assert not r["ok"] and "fora do padrão" in r["why"]
r=run(workdir=U+"/gt-remote/proof/../x"); assert not r["ok"]
r=run(); assert r["ok"] and not os.path.exists(wd) and not os.path.exists(U+"/gt-remote/proof") and not os.path.exists(U+"/gt-remote/bundle/run"), r
cj=json.load(open(U+"/.claude.json")); assert cj=={"projects":{"/x":{"a":1}},"keep":7}, cj
r=run(); assert r["ok"]'; ok $? "unit: CLEAN — recusa pasta fora do padrão; apaga a pasta de teste e SÓ a chave dela no ~/.claude.json; remove só as pastas que a prova criou; repetir é inofensivo"; }
  c sweeppy && { mkdir -p "$T/u3/ok" "$T/u3/g/.git/objects/ab" "$T/u3/glob1"; echo "tudo limpo" > "$T/u3/ok/a.txt"; printf 'ghp_%s\n' "$(printf 'b%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36)" > "$T/u3/ok/leak.txt"
    echo x > "$T/u3/ok/.env"; echo ghp_cccccccccccccccccccccccccccccccccccccc > "$T/u3/g/.git/objects/ab/pack"; echo "-----BEGIN RSA PRIVATE KEY-----" > "$T/u3/glob1/t.jsonl"
    UD="$T/u3" py 'import subprocess,json,os
U=os.environ["UD"]
def run(roots,globs=[]): return json.loads(subprocess.run(["python3","-I","-",json.dumps({"roots":roots,"globs":globs,"secret_rx":M.SECRET_RX,"forbidden":M.FORBIDDEN})],input=M.SWEEP.encode(),capture_output=True).stdout.decode().strip().split("\n")[-1])
r=run([U+"/ok"]); assert len(r["hits"])==1 and r["hits"][0][0].endswith("leak.txt") and r["forbidden"]==[U+"/ok/.env"] and r["unverified"]==[], r
os.makedirs(U+"/big"); open(U+"/big/b.bin","wb").write(b"x"*3000001); r=run([U+"/big"]); assert r["unverified"][0]==U+"/big/b.bin (>3MB)", r
import socket; os.makedirs(U+"/sk"); os.chdir(U+"/sk"); open("a.txt","w").write("limpo"); socket.socket(socket.AF_UNIX).bind("x.sock"); r=run([U+"/sk"]); assert r["unverified"]==[U+"/sk/x.sock"], r
r=run([U+"/nao-existe"]); assert r["unverified"]==["nenhum arquivo lido"], r; r=run([U+"/ok/a.txt"]); assert r["unverified"][0]==U+"/ok/a.txt", r
r=run([U+"/g"]); assert r["hits"]==[] and r["forbidden"]==[], r
r=run([U+"/nao-existe"],[U+"/glob*"]); assert len(r["hits"])==1 and r["hits"][0][0].endswith("t.jsonl"), r
os.makedirs(U+"/m")
open(U+"/m/manifest.json","w").write("{\"hooks\": [{\"token\": \"bd-wrapper-guard\"}]}")
open(U+"/m/outro.json","w").write("{\"token\": \"bd-wrapper-guard\"}")
def runs(roots,skip): return json.loads(subprocess.run(["python3","-I","-",json.dumps({"roots":roots,"globs":[],"secret_rx":M.SECRET_RX,"forbidden":M.FORBIDDEN,"skip":skip})],input=M.SWEEP.encode(),capture_output=True).stdout.decode().strip().split("\n")[-1])
r=runs([U+"/m"],{}); assert sorted(h[0].rsplit("/",1)[1] for h in r["hits"])==["manifest.json","outro.json"], r
r=runs([U+"/m"],{U+"/m/manifest.json":[M.SECRET_KV]}); assert [h[0].rsplit("/",1)[1] for h in r["hits"]]==["outro.json"], r
open(U+"/m/manifest.json","w").write("{\"x\": \"ghp_"+"d"*36+"\"}")
r=runs([U+"/m"],{U+"/m/manifest.json":[M.SECRET_KV]}); assert "manifest.json" in [h[0].rsplit("/",1)[1] for h in r["hits"]], r'; ok $? "unit: SWEEP — acha segredo e arquivo proibido, lista o que não deu para ler (arquivo >3MB, socket, raiz que não é pasta, varredura vazia; pasta ausente não conta), não lê dentro de .git/objects, varre também a transcrição (glob), e só dispensa o padrão genérico \"token\": no manifest do bundle (um segredo de verdade nele ainda reprova)"; }
}

# ---------------------------------------------------------------- cli
g_cli() {
  world_reset
  c cli-bead && { proof e2e --bead 'ga-x; touch /tmp/mbpt-pwned' > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 2 ] && has "$T/err" "id de bead inválido" && [ ! -e /tmp/mbpt-pwned ] && [ ! -e "$FAKE_STATE/provcalls" ]; ok $? "cli: --bead com cara de comando → erro de uso 2 antes de tocar no MBP ou no provider (rc=$RC)"; }
  c cli-model && { proof e2e --model 'haiku --allow-all' > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 2 ] && has "$T/err" "modelo inválido" && [ ! -e "$FAKE_STATE/provcalls" ]; ok $? "cli: --model com espaço/flag extra → erro de uso 2 (rc=$RC)"; }
  c cli-url && { proof e2e --repo-url 'http://evil.example/x.git' > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 2 ] && has "$T/err" "url do origin inválido"; ok $? "cli: --repo-url que não é GitHub nem file:/// → erro de uso 2 (rc=$RC)"; }
  c cli-session && { MBP_PROOF_SESSION=remote-mbp-1 proof e2e > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 2 ] && has "$T/err" "MBP_PROOF_SESSION inválido" && [ ! -e "$FAKE_STATE/provcalls" ]; ok $? "cli: nome de sessão REAL (remote-mbp-1) → recusado, só remote-test-remote-mbp-<n> (rc=$RC)"; }
  c cli-timeout && { proof e2e --timeout 1 > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 2 ] && has "$T/err" "--timeout vai de 5 a 3600"; ok $? "cli: --timeout fora da faixa → 2 (rc=$RC)"; }
  c cli-dry && { srv_skeleton; before=$(dsig "$SRV"); proof install > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 0 ] && has "$T/out" "[dry-run]" && [ ! -e "$FAKE_STATE/sshcalls" ] && [ "$(dsig "$SRV")" = "$before" ] && [ ! -e "$MINI/.gastown/remote-shim-mbp.json" ]; ok $? "cli: install sem --apply só mostra o plano — nenhum ssh, nada gravado no MBP nem no mini (rc=$RC)"; }
  if c cli-plan; then
    if [ -x "$HERE/gc-session-ssh" ]; then
      # o provider acha a cidade pelo GC_CITY do pedido e as regras de caminho são em ordem: o "MBP" não pode ficar debaixo de dirname(cidade) (no real é gt-remote ao lado de gt)
      PD="$T/plan"; mkdir -p "$PD/gt/city/.gc" "$PD/mbp"
      GC_CITY_PATH="$PD/gt/city" MBP_PROOF_HOME="$PD/mbp" MBP_PROOF_PROV="$HERE/gc-session-ssh" proof plan > "$T/out" 2> "$T/err"; RC=$?
      [ $RC = 0 ] && has "$T/out" "--settings $PD/mbp/gt-remote/bundle/city/settings.json" && has "$T/out" "would_refuse None" && ! has "$T/out" "PROBLEMA"; ok $? "cli: plan contra o dry-run do provider de verdade — o --settings do city vira o do bundle do MBP, o provider não recusaria, nada conecta (rc=$RC)"
    else skip "cli-plan: scripts/gc-session-ssh ausente (o filtro do nó Linux não leva script sem extensão)"; fi
  fi
}

# ---------------------------------------------------------------- install
g_install() {
  c inst-ok && {
    srv_skeleton; mkdir -p "$SRV/gt-remote/bundle/run"; own=$(dsig "$SRV/.claude" "$SRV/.ssh"); inst
    [ $RC = 0 ] && has "$T/out" "INSTALAÇÃO OK" && ! has "$T/out" "FAIL"; ok $? "install: do zero, com o builder de verdade → INSTALAÇÃO OK, nenhuma prova reprovada (rc=$RC)"
    python3 -I "$SRV/gt-remote/bin/remote-bundle-build.py" verify "$SRV/gt-remote/bundle" > /dev/null 2>&1 && [ -f "$SRV/gt-remote/bundle/city/settings.json" ]; ok $? "install: o bundle em gt-remote/bundle é conferido LÁ pelo builder que foi junto (verify), com o city/settings.json"
    [ -d "$SRV/gt-remote/bundle/run" ] && [ -z "$(ls "$SRV/gt-remote/bundle/run")" ]; ok $? "install: a pasta run/ do provider foi preservada na troca"
    [ -z "$(ls "$SRV/gt-remote" | grep -E 'bundle\.(new|old)')" ]; ok $? "install: não sobra bundle.new.* nem bundle.old.* em gt-remote"
    [ "$(sha "$SRV/gt-remote/shim-bin/remote-shim")" = "$(sha "$T/fake-remote-shim.py")" ] && [ "$(readlink "$SRV/gt-remote/shim-bin/bd")" = remote-shim ] && [ "$(readlink "$SRV/gt-remote/shim-bin/gc")" = remote-shim ] && [ "$(readlink "$SRV/gt-remote/shim-bin/gate-done")" = remote-shim ]; ok $? "install: cliente do atalho igual ao do repositório e links bd/gc/gate-done em shim-bin"
    python3 -I -c 'import json,sys,os; d=json.load(open(sys.argv[1]+"/gt-remote/shim-bin/remote-shim.json")); assert d=={"transport":"spool","spool_dir":sys.argv[1]+"/gt-remote/shim","timeout_s":330}, d; assert oct(os.stat(sys.argv[1]+"/gt-remote/shim").st_mode&0o777)=="0o700"' "$SRV"; ok $? "install: remote-shim.json é só a puxada (sem host nem chave) e o spool é 0700"
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["identity_pattern"]=="^remote-test-remote-mbp-[0-9]{1,3}$" and d["gate_done_bin"] is None and d["city"]==sys.argv[2], d' "$MINI/.gastown/remote-shim-mbp.json" "$CITY"; ok $? "install: a config do wrapper no mini só aceita a sessão de teste e não tem gate-done"
    [ "$(dsig "$SRV/.claude" "$SRV/.ssh")" = "$own" ] && [ ! -e "$SRV/.config" ]; ok $? "install: nada em ~/.claude, ~/.ssh nem ~/.config do MBP"
    [ "$(sha "$SRV/gt-remote/bin/remote-bundle-build.py")" = "$(sha "$BUILDER")" ]; ok $? "install: o builder em gt-remote/bin é o do repositório"
    first=$(cat "$SRV/gt-remote/bundle/manifest.json"); proof install --apply > "$T/out" 2> "$T/err"; RC=$?
    [ $RC = 0 ] && [ "$(cat "$SRV/gt-remote/bundle/manifest.json")" = "$first" ] && [ -d "$SRV/gt-remote/bundle/run" ] && has "$T/out" "INSTALAÇÃO OK"; ok $? "install: repetir é inofensivo (mesmo bundle, run/ preservada) (rc=$RC)"
  }
  c inst-wrapper && { srv_skeleton; world_reset; mkdir -p "$MINI/.gastown"; echo '{"city": "outra"}' > "$MINI/.gastown/remote-shim-mbp.json"; before=$(dsig "$SRV"); proof install --apply > "$T/out" 2> "$T/err"; RC=$?
    [ $RC = 1 ] && has "$T/out" "NAO INSTALEI" && [ "$(dsig "$SRV")" = "$before" ] && [ "$(cat "$MINI/.gastown/remote-shim-mbp.json")" = '{"city": "outra"}' ]; ok $? "install: config do wrapper que já existe e é diferente → não sobrescreve e NÃO toca no MBP (rc=$RC)"; }
  c inst-tamper && { srv_skeleton; before=$(dsig "$SRV"); FAKE_TAMPER=1 inst
    [ $RC = 1 ] && has "$T/out" "verify NO MBP reprovou" && [ ! -e "$SRV/gt-remote/bundle" ] && [ -n "$(ls "$SRV/gt-remote" | grep 'bundle.new')" ] && [ ! -e "$MINI/.gastown/remote-shim-mbp.json" ]; ok $? "install: pacote adulterado na transferência → verify LÁ reprova, o bundle vivo não é trocado, a pasta fica para inspeção e o mini não é tocado (rc=$RC)"; }
  c inst-tamper-live && { cp -a "$GOLD/." /dev/null 2>/dev/null; mkgold && { find "$SRV" -mindepth 1 -delete; cp -a "$GOLD/." "$SRV/"; before=$(dsig "$SRV/gt-remote/bundle"); FAKE_TAMPER=1 inst
    [ $RC = 1 ] && [ "$(dsig "$SRV/gt-remote/bundle")" = "$before" ]; ok $? "install: pacote adulterado com um bundle JÁ instalado → o instalado segue intacto (rc=$RC)"; }; }
  c inst-dead && { srv_skeleton; FAKE_SSH_DEAD=1 inst; [ $RC = 3 ] && has "$T/out" "NAO INSTALEI" && [ ! -e "$MINI/.gastown/remote-shim-mbp.json" ]; ok $? "install: ssh fora → 3, nada gravado no mini (rc=$RC)"; }
  c inst-gate && { srv_skeleton; FAKE_GATE=athos inst; [ $RC = 3 ] && has "$T/out" "NÃO livre" && [ ! -e "$FAKE_STATE/sshcalls" ]; ok $? "install: o Athos está no MBP → 3 e NENHUM ssh foi feito (rc=$RC)"; }
  c inst-gate-garbage && { srv_skeleton; FAKE_GATE=garbage inst; r1=$RC; srv_skeleton; FAKE_GATE=nodict inst; r2=$RC
    [ $r1 = 3 ] && [ $r2 = 3 ] && has "$T/out" "veredito do gate ilegível" && [ ! -e "$MINI/.gastown/remote-shim-mbp.json" ]; ok $? "install: veredito do gate ilegível (not-json {{{ e uma lista, ambos com exit 0) → NÃO é livre: 3, nada gravado (rc=$r1/$r2)"; }
  c inst-upload && { srv_skeleton; FAKE_UPLOAD_FAIL=1 inst
    [ $RC = 1 ] && has "$T/out" "envio do builder" && [ ! -e "$SRV/gt-remote/bundle" ] && [ ! -e "$MINI/.gastown/remote-shim-mbp.json" ]; ok $? "install: o envio do builder ao MBP sai rc != 0 → 1, bundle não trocado, nada gravado no mini (rc=$RC)"; }
  c inst-wrapper-dir && { srv_skeleton; world_reset; mkdir -p "$MINI/.gastown/remote-shim-mbp.json"; before=$(dsig "$SRV"); proof install --apply > "$T/out" 2> "$T/err"; RC=$?
    [ $RC = 1 ] && has "$T/out" "não consigo ler" && ! has "$T/err" "Traceback" && [ "$(dsig "$SRV")" = "$before" ] && [ -d "$MINI/.gastown/remote-shim-mbp.json" ]; ok $? "install: config do wrapper ilegível (OSError: o caminho é uma pasta) → recusa sem Traceback, não toca no MBP (rc=$RC)"; }
  c inst-tmux-unknown && { srv_skeleton; world_reset; touch "$FAKE_STATE/running"; before=$(dsig "$SRV"); FAKE_TMUX=mismatch proof install --apply > "$T/out" 2> "$T/err"; RC=$?
    [ $RC = 3 ] && has "$T/out" "não consegui saber" && [ "$(dsig "$SRV")" = "$before" ] && [ ! -e "$MINI/.gastown/remote-shim-mbp.json" ]; ok $? "install: tmux que falha por outro motivo (versão do servidor ≠ cliente) com uma sessão ABERTA → 3, \"não sei\" não é \"sem sessão\", MBP e mini intactos (rc=$RC)"
    srv_skeleton; FAKE_TMUX=nosock inst; [ $RC = 0 ] && has "$T/out" "INSTALAÇÃO OK"; ok $? "install: socket que não existe (error connecting to … No such file or directory) é \"sem sessão\", como no provider: instala (rc=$RC)"; }
  c inst-session && { srv_skeleton; world_reset; touch "$FAKE_STATE/running"; proof install --apply > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 3 ] && has "$T/out" "sessão aberta"; ok $? "install: sessão aberta no socket do provider → 3 (rc=$RC)"; }
}

# ---------------------------------------------------------------- e2e
e2e_fixture() { mkgold || return 1; find "$SRV" -mindepth 1 -delete 2> /dev/null; cp -a "$GOLD/." "$SRV/"; world_reset; mkdir -p "$MINI/.gastown"; }
ep() {  # ep [args do e2e] — um e2e completo contra o MBP falso; RC, $T/out
  e2e_fixture || { RC=99; return; }
  python3 -I "$P" e2e --repo-url "$URL" --timeout "${TMO:-60}" "$@" > "$T/out" 2> "$T/err"; RC=$?; kill_leftovers
  [ -z "${MBPT_DEBUG:-}" ] || { cat "$T/out" "$T/err" >&2; }
}
fail1() {  # fail1 CASO MODO "FAIL ..." DESCRIÇÃO [args] — o modo reprova SÓ a prova nomeada, saída 1
  local name=$1 mode=$2 want=$3 desc=$4; shift 4
  c "$name" || return 0
  FAKE_MODE=$mode ep "$@"; [ $RC = 1 ] && has "$T/out" "$want" && [ "$(calls stop)" -ge 1 ]; ok $? "e2e: $desc (rc=$RC)"
}
g_e2e() {
  c ok && { FAKE_MODE=ok ep
    r=$(sed -n 's/.*MBP-PROOF PASSOU: \([0-9]*\) de \([0-9]*\) provas.*/\1 \2/p' "$T/out"); set -- $r
    [ $RC = 0 ] && [ -n "${1:-}" ] && [ "${1:-x}" = "${2:-y}" ] && [ "${1:-0}" -ge 20 ] && ! grep -q '^[0-9:]* FAIL' "$T/out"; ok $? "e2e: sessão completa → todas as provas passam (${1:-?} de ${2:-?}), nenhuma reprovada, saída 0 (rc=$RC)"
    for want in "PASS bundle instalado em gt-remote/bundle e conferido NO MBP" "PASS cliente do atalho instalado em shim-bin" "PASS atalho bd do MBP chega ao mini" "PASS clone sem dado" "PASS start pelo provider" \
      'PASS (e) a sessão rodou `claude` com o --settings do bundle' "PASS (c) na sessão, \`bd\` e \`gc\` resolvem para o atalho" "PASS (c) o comentário da sessão está na bead, no mini" "PASS (d) commit no MBP, com a identidade da sessão" \
      "PASS (d) clone continua sem dado depois do commit" "PASS (d) o branch chegou ao origin DIRETO do MBP" "PASS (d) o branch aparece no mini" "PASS (c) hooks gc do city" "PASS (a) peek mostra a tela" "PASS (a) nudge entregue" \
      "PASS (a) a sessão respondeu ao nudge" "PASS (b) o vigia (biblioteca de presença de verdade) está de pé" "PASS (b) pausa do Athos ligada" "PASS (b) com a pausa ligada o gate do provider recusa" \
      "PASS (b) o vigia rebaixou a árvore da sessão" "PASS (b) a sessão NÃO foi morta" "PASS (b) pausa desta rodada desligada" "PASS (b) sem a pausa o rebaixamento NÃO volta a subir" "PASS (a) sessão parada pelo provider" \
      "PASS (a) o stop deixa o MBP limpo" "PASS (d) varredura (antes de apagar a pasta de teste)" "PASS (a) pasta de teste, marca de confiança" "PASS (c)(d) varredura depois"; do
      has "$T/out" "$want"; ok $? "e2e: ${want#PASS }"
    done
    run=$(sed -n 's/.*mbp-proof \(mbp-[0-9]*-[0-9]*\) ·.*/\1/p' "$T/out" | head -1)
    sha=$(git -C "$T/origin.git" rev-parse "refs/heads/worker/$run" 2>/dev/null); [ -n "$sha" ] && [ "$(git -C "$T/origin.git" diff --name-only "$(git -C "$T/origin.git" rev-parse HEAD)" "$sha")" = "mbp-proof/$run.txt" ]; ok $? "e2e: no origin só existe o branch worker/<rodada> com UM arquivo novo, mbp-proof/<rodada>.txt (rodada ${run:-?})"
    [ -z "$(git -C "$T/origin.git" for-each-ref refs/heads/evil)" ]; ok $? "e2e: nenhum outro branch no origin"
    [ "$(calls start)" = 1 ] && [ "$(calls stop)" -ge 1 ] && [ ! -e "$FAKE_STATE/running" ] && [ "$(calls nudge)" = 1 ]; ok $? "e2e: um start, um nudge, e a sessão foi parada pelo provider no fim"
    grep -q '^ensure' "$FAKE_STATE/pumpcalls" && grep -q '^stop' "$FAKE_STATE/pumpcalls"; ok $? "e2e: o puxador do mini foi subido antes e parado no fim"
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "mbp-proof mbp-" in d["prompt_suffix"] and d["env"]["GC_SESSION_NAME"]=="remote-test-remote-mbp-1", d' "$FAKE_STATE/startreq"; ok $? "e2e: o provider recebeu o pedido com a identidade da sessão de teste e o prompt de partida"
    python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]+"/.claude.json"))==json.load(open(sys.argv[2]+"/.claude.json"))' "$SRV" "$GOLD"; ok $? "e2e: ~/.claude.json do MBP voltou ao que era (a marca de confiança da pasta de teste saiu)"
    [ ! -e "$SRV/gt-remote/PAUSE" ] && [ ! -e "$SRV/gt-remote/proof" ] && [ ! -e "$SRV/gt-remote/bundle/run" ] && [ ! -e "$SRV/tmp/tmux-$(id -u)/gc-remote" ]; ok $? "e2e: sem PAUSE, sem gt-remote/proof, sem bundle/run e sem socket do tmux depois"
    [ "$(cd "$SRV" && find . -type f -not -path './.claude/projects/*' | sort | cksum)" = "$(cd "$GOLD" && find . -type f | sort | cksum)" ]; ok $? "e2e: a lista de arquivos do MBP é a da instalação (a transcrição do claude é a única novidade)"
    [ "$(dsig "$SRV/.ssh")" = "$(dsig "$GOLD/.ssh")" ] && [ "$(dsig "$SRV/gt-remote/bundle" "$SRV/gt-remote/shim-bin")" = "$(dsig "$GOLD/gt-remote/bundle" "$GOLD/gt-remote/shim-bin")" ]; ok $? "e2e: ~/.ssh, o bundle e o atalho ficaram byte a byte iguais"
    ! grep -rq "LEAD-DATA-9981" "$SRV"; ok $? "e2e: o dado de lead do origin NÃO existe em lugar nenhum do MBP"
  }
  c keep && { FAKE_MODE=ok ep --keep; wd=$(ls -d "$SRV"/gt-remote/proof/mbp-* 2>/dev/null | head -1); [ $RC = 0 ] && has "$T/out" "--keep" && [ -d "$wd" ] && has "$SRV/.claude.json" "hasTrustDialogAccepted"; ok $? "e2e: --keep deixa a pasta de teste e a marca de confiança (e diz) (rc=$RC)"; }
  c delbranch && { FAKE_MODE=ok ep --delete-branch; [ $RC = 0 ] && [ -z "$(git -C "$T/origin.git" for-each-ref 'refs/heads/worker/*')" ] && has "$T/out" "apagado no origin: rc 0"; ok $? "e2e: --delete-branch apaga worker/<rodada> no origin (e só com ele) (rc=$RC)"; }
  c evilpush && { FAKE_MODE=evilpush ep; [ $RC = 0 ] && [ -z "$(git -C "$T/origin.git" for-each-ref refs/heads/evil)" ] && grep -q 'push recusado: refs/heads/evil' "$FAKE_STATE/pusherr" && [ -n "$(git -C "$T/origin.git" for-each-ref 'refs/heads/worker/*')" ]; ok $? "e2e: o hook de pre-push do clone de teste recusa qualquer ref que não seja worker/<rodada>, e o push certo passa (rc=$RC)"; }
  fail1 nopush nopush "FAIL (d) o branch chegou ao origin DIRETO" "sem push → a prova do branch reprova"
  fail1 shamismatch shamismatch "FAIL (d) o branch chegou ao origin DIRETO" "branch no origin com sha diferente do commit do MBP → reprova"
  fail1 wrongid wrongid "FAIL (d) commit no MBP, com a identidade da sessão" "commit com a identidade de OUTRO autor → reprova"
  fail1 wrongcontent wrongcontent "FAIL (d) o branch aparece no mini" "conteúdo do arquivo diferente do esperado (blob na árvore) → o fetch no mini reprova"
  fail1 nocomment nocomment "FAIL (c) o comentário da sessão está na bead" "sem comentário na bead → reprova"
  fail1 nogchooks nogchooks "FAIL (c) hooks gc do city" "transcrição SEM os hooks gc do city (o --settings do bundle não carregou) → reprova"
  fail1 gcfail gcfail "FAIL (c) hooks gc do city" "hook gc que sai ≠ 0 na sessão → reprova"
  fail1 badline badline "FAIL (c) hooks gc do city" "linha ilegível na transcrição → reprova (uma linha perdida pode ser o hook que falhou)"
  c gctimeout && { FAKE_MODE=gctimeout ep; [ $RC = 0 ] && has "$T/out" "PASS (c) hooks gc do city"; ok $? "e2e: hook gc cancelado pelo prazo do claude não derruba a prova (rc=$RC)"; }
  fail1 nonudge nonudge "FAIL (a) nudge entregue" "nudge que o provider não entrega → reprova"
  fail1 nonudgeanswer nonudgeanswer "FAIL (a) a sessão respondeu ao nudge" "nudge entregue mas a sessão não age → reprova no prazo (TMO)"
  fail1 nowatch nowatch "FAIL (b) o vigia rebaixou a árvore" "vigia que não rebaixa → (b) reprova"
  fail1 killcore killcore "FAIL (b) a sessão NÃO foi morta" "vigia que MATA o claude da sessão → (b) reprova nomeando os pids"
  fail1 leavesocket leavesocket "FAIL (a) o stop deixa o MBP limpo" "stop que deixa o socket do tmux → reprova"
  fail1 leavefile leavefile "FAIL (a) o stop deixa o MBP limpo" "stop que deixa o arquivo do lançador em run/ → reprova"
  fail1 leaveproc leaveproc "FAIL (a) o stop deixa o MBP limpo" "stop que deixa processos da sessão → reprova"
  fail1 stopfail stopfail "FAIL (a) sessão parada pelo provider" "stop que falha → reprova"
  fail1 secret secret "FAIL (d) varredura (antes de apagar a pasta de teste)" "segredo no spool → a varredura reprova"
  fail1 transcriptsecret transcriptsecret "FAIL (d) varredura (antes de apagar a pasta de teste)" "segredo na transcrição da sessão → a varredura reprova"
  fail1 leadfile leadfile "FAIL (d) varredura (antes de apagar a pasta de teste)" "arquivo de dado (leads.csv) no clone → a varredura reprova"
  fail1 bigfile bigfile "FAIL (d) varredura (antes de apagar a pasta de teste)" "arquivo de 3,1 MB no clone (grande demais para ler) → a varredura reprova em vez de passar sem olhar"
  fail1 credleak credleak "FAIL (c)(d) varredura depois" "credencial git nova em ~/.git-credentials → a comparação antes/depois reprova"
  fail1 sshkey sshkey "FAIL (c)(d) varredura depois" "chave nova em ~/.ssh → a comparação antes/depois reprova"
  fail1 snapfail snapfail "FAIL (c)(d) varredura depois: li o estado do MBP" "leitura do MBP que falha depois da limpeza → reprova (sem leitura não há \"nada novo\")"
  c dialog && { FAKE_MODE=dialog ep; [ $RC = 1 ] && has "$T/out" "FAIL (e) a sessão rodou" && has "$T/out" "trust this folder" && has "$T/out" "sessão andou sem diálogo" && [ "$(calls nudge)" = 0 ] && ! grep -q 'send-keys' "$FAKE_STATE/provcalls" && [ "$(calls stop)" -ge 1 ]; ok $? "e2e: diálogo de primeira execução → reprova mostrando a tela, NUNCA é respondido (nenhum nudge/send-keys) e a sessão é parada (rc=$RC)"; }
  fail1 die die "FAIL (e) a sessão rodou" "sessão que morre antes do fim → reprova com a tela"
  fail1 hang hang "FAIL (e) a sessão rodou" "sessão que trava → reprova no prazo e é parada" --timeout 5
  fail1 startfail startfail "FAIL start pelo provider" "start que o provider recusa → reprova, o stop roda mesmo assim"
  c athosback && { FAKE_DELAY=3 FAKE_GATE_AFTER_START=athos FAKE_MODE=ok ep; [ $RC = 4 ] && has "$T/out" "INTERROMPIDA" && has "$T/out" "Athos está no MBP" && [ "$(calls stop)" -ge 1 ] && [ ! -e "$SRV/gt-remote/proof" ] && ! grep -q '^[0-9:]* FAIL' "$T/out"; ok $? "e2e: o Athos volta ao MBP no meio → saída 4, nada mais medido, a sessão é parada e o MBP é limpo (rc=$RC)"; }
  c foreignpause && { FAKE_MODE=foreignpause ep; [ $RC = 4 ] && has "$T/out" "pausa do Athos ativa" && [ "$(calls stop)" -ge 1 ] && [ "$(cat "$SRV/gt-remote/PAUSE")" = "origem=athos desde=2026-10-18T10:00:00" ]; ok $? "e2e: o Athos liga a pausa dele no meio → saída 4 e a pausa DELE fica exatamente como estava (rc=$RC)"; }
  c healthwarn && { FAKE_GATE_AFTER_START=health FAKE_MODE=ok ep; [ $RC = 0 ] && has "$T/out" "aviso antes de" && has "$T/out" "MBP sem saúde"; ok $? "e2e: o MBP piora de saúde por causa da própria sessão → só avisa e segue (a saúde não aborta) (rc=$RC)"; }
  # ---- pré-condições: não começa, saída 3, NENHUMA sessão aberta
  c athos && { FAKE_GATE=athos ep; [ $RC = 3 ] && [ "$(calls start)" = 0 ] && has "$T/out" "NÃO livre"; ok $? "e2e: o Athos está no MBP → não começa, saída 3, nenhuma sessão aberta (rc=$RC)"; }
  c flag && { FAKE_GATE=flag ep; [ $RC = 3 ] && [ "$(calls start)" = 0 ]; ok $? "e2e: bandeira mbp-offload desligada → não começa (rc=$RC)"; }
  c sshdead && { FAKE_SSH_DEAD=1 ep; [ $RC = 3 ] && [ "$(calls start)" = 0 ] && has "$T/out" "não consegui ler o estado do MBP"; ok $? "e2e: ssh fora → não começa, saída 3 (rc=$RC)"; }
  c shimdead && { FAKE_SHIM_DEAD=1 ep; [ $RC = 3 ] && [ "$(calls start)" = 0 ] && has "$T/out" "NAO CONSEGUI começar: o atalho não chega ao mini"; ok $? "e2e: o atalho não chega ao mini → não começa, saída 3 (rc=$RC)"; }
  c shadow && { e2e_fixture; mkdir -p "$SRV/.local/bin"; printf '#!/bin/sh\n' > "$SRV/.local/bin/bd"; chmod +x "$SRV/.local/bin/bd"
    python3 -I "$P" e2e --repo-url "$URL" > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 3 ] && [ "$(calls start)" = 0 ] && has "$T/out" "esconderia o atalho"; ok $? "e2e: um bd REAL em ~/.local/bin esconderia o atalho nos hooks → não começa, saída 3 (rc=$RC)"; }
  c nopresence && { e2e_fixture; find "$SRV/gt-remote/bin/mbp-presence.sh" -delete; python3 -I "$P" e2e --repo-url "$URL" > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 3 ] && [ "$(calls start)" = 0 ] && has "$T/out" "sem a biblioteca de presença"; ok $? "e2e: sem a biblioteca de presença no MBP → não começa (rc=$RC)"; }
  c swappause && { FAKE_MODE=swappause ep; [ $RC = 1 ] && has "$T/out" "a pausa NÃO é desta rodada" && [ "$(cat "$SRV/gt-remote/PAUSE")" = "origem=athos desde=2026-10-18T10:00:00" ] && [ "$(calls stop)" -ge 1 ]; ok $? "e2e: o Athos troca a pausa por uma dele depois da da prova → a prova NÃO a remove (nem no fim), reprova (b) e a pausa DELE fica como estava (rc=$RC)"; }
  c badjson && { e2e_fixture; echo "isto nao e json" > "$SRV/.claude.json"; python3 -I "$P" e2e --repo-url "$URL" > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 3 ] && [ "$(calls start)" = 0 ] && has "$T/out" "nunca rodou aqui" && [ "$(cat "$SRV/.claude.json")" = "isto nao e json" ]; ok $? "e2e: ~/.claude.json ilegível → não começa e não o reescreve (rc=$RC)"; }
  c staleproof && { e2e_fixture; mkdir -p "$SRV/gt-remote/proof/velho"; python3 -I "$P" e2e --repo-url "$URL" > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 3 ] && [ "$(calls start)" = 0 ] && has "$T/out" "sobrou algo em gt-remote/proof" && [ -d "$SRV/gt-remote/proof/velho" ]; ok $? "e2e: sobra de uma rodada anterior em gt-remote/proof → não começa e não apaga o que não é dela (rc=$RC)"; }
  c stalesocket && { e2e_fixture; mkdir -p "$SRV/tmp/tmux-$(id -u)"; : > "$SRV/tmp/tmux-$(id -u)/gc-remote"; python3 -I "$P" e2e --repo-url "$URL" > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 3 ] && [ "$(calls start)" = 0 ] && has "$T/out" "sobrou um socket do tmux"; ok $? "e2e: socket do tmux sobrando sem servidor → não começa (a prova mede que o stop não deixa socket) (rc=$RC)"; }
  c foreignrun && { e2e_fixture; mkdir -p "$SRV/gt-remote/bundle/run"; echo x > "$SRV/gt-remote/bundle/run/outra.sh"; python3 -I "$P" e2e --repo-url "$URL" > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 3 ] && [ "$(calls start)" = 0 ] && [ -f "$SRV/gt-remote/bundle/run/outra.sh" ]; ok $? "e2e: run/ com arquivo de outra sessão → não começa (e o verify do bundle também reprova) e o arquivo fica (rc=$RC)"; }
  c badrepo && { e2e_fixture; python3 -I "$P" e2e --repo-url "file:///nao/existe/aqui.git" > "$T/out" 2> "$T/err"; RC=$?; [ $RC = 3 ] && [ "$(calls start)" = 0 ] && has "$T/out" "nenhuma URL do origin respondeu" && [ ! -e "$SRV/gt-remote/proof" ]; ok $? "e2e: o MBP não alcança o origin com a credencial que já tem → não começa, nada criado (rc=$RC)"; }
}

all() { group unit && g_unit; group cli && g_cli; group install && g_install; group e2e && g_e2e; }
if [ -n "${MBPT_MUTANT:-}" ]; then all; echo "RESULT $fails/$n"; exit $((fails > 0)); fi
all
echo "== $((n-fails))/$n ok, $skipped sem rodar =="

[ -n "${MBPT_NO_MUTANTS:-}" ] || {
  echo "-- controle negativo: cada guarda trocada TEM que fazer os casos que a cobrem falharem"
  mutate() {  # mutate OLD NEW OUT — troca EXATAMENTE uma ocorrência (senão o teste do mutante está errado)
    python3 -I -c '
import sys
s = open(sys.argv[1]).read(); old, new = sys.argv[2], sys.argv[3]
if s.count(old) != 1:
    sys.exit("a troca casou %d vezes (esperado 1): %r" % (s.count(old), old[:70]))
open(sys.argv[4], "w").write(s.replace(old, new))' "$P" "$1" "$2" "$3"
  }
  mutant() {  # mutant GRUPO CASOS DESCRIÇÃO OLD NEW
    group "$1" || return 0
    local m="$T/mut.$RANDOM" r; mkdir -p "$m"
    if ! mutate "$4" "$5" "$m/mbp-proof.py" 2> "$T/muterr"; then ok 1 "mutante '$3': $(cat "$T/muterr")"; return; fi
    r=$(MBPT_MUTANT=1 MBPT_T="$T" MBPT_ONLY="$1" MBPT_CASES="$2" MBPT_UNDER_TEST="$m/mbp-proof.py" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/0") ok 1 "mutante '$3': nenhum caso rodou ($r)";; "RESULT 0/"*) ok 1 "mutante '$3' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$3' pego ($r)";; *) ok 1 "mutante '$3': execução sem resultado ($r)";; esac
  }
  mutant unit judge-one "judge_tree aceita processo sem rebaixar" 'if (x["ni"] < 19 and y["ni"] < 19) or y["ni"] < x["ni"]:' 'if False:'
  mutant unit judge-up "judge_tree deixa a prioridade ser devolvida" 'if (x["ni"] < 19 and y["ni"] < 19) or y["ni"] < x["ni"]:' 'if x["ni"] < 19 and y["ni"] < 19:'
  mutant unit judge-room "judge_tree passa sem ninguém ter folga" '    if not room:' '    if False:'
  mutant unit judge-none "judge_tree passa sem nada a comparar" 'return False, rows, "nenhum processo da sessão existe antes e depois (nada a comparar)"' 'return True, rows, ""'
  mutant unit pausepy "PAUSE remove pausa que não é desta rodada" 'elif f1.startswith(mark):' 'elif True:'
  mutant unit cleanpy "CLEAN apaga pasta fora do padrão" 'if not re.fullmatch(re.escape(C["proofs"]) + r"/mbp-[0-9]{8}-[0-9]{6}", wd):' 'if False:'
  mutant unit sweeppy "SWEEP não varre a transcrição (glob)" '    roots += sorted(glob.glob(g))' '    pass'
  mutant cli cli-bead "argumentos que vão ao shell remoto sem validar" '        if not re.fullmatch(rx, v):' '        if False:'
  mutant unit tmuxstate "tmux_state devolve livre para a falha que não conhece" '        return "livre"
    return "nao-sei"' '        return "livre"
    return "livre"'
  mutant cli cli-dry "install sem --apply conecta" '    if not a.apply:
        print("[dry-run] nada foi gravado' '    if False:
        print("[dry-run] nada foi gravado'
  mutant install inst-tmux-unknown "tmux que falha vira \"sem sessão\"" '    if ts != "livre":' '    if ts == "aberta":'
  mutant install inst-wrapper "config do wrapper diferente é sobrescrita" 'if have is not None and have != wc:' 'if False:'
  mutant install inst-wrapper-dir "config do wrapper ilegível estoura em vez de recusar" 'have = open(WRAPPER_CFG).read() if os.path.exists(WRAPPER_CFG) else None
    except OSError as e:' 'have = open(WRAPPER_CFG).read() if os.path.exists(WRAPPER_CFG) else None
    except KeyError as e:'
  mutant install inst-gate-garbage "veredito ilegível vira livre" 'if not isinstance(v, dict):' 'if False:'
  mutant install inst-upload "envio do builder sem conferir o rc" '    if r.returncode != 0:  # senão um builder velho' '    if False:  # senão um builder velho'
  mutant install inst-tamper "verify no MBP ignorado" 'if v.returncode != 0 or got != want:' 'if False:'
  mutant install inst-ok "a troca perde run/" '[ ! -d "$B/run" ] || mv "$B/run" "$N/run"\n' ''
  mutant install inst-ok "o spool não vira 0700" ' && chmod 700 {q(SPOOL)}' ''
  mutant e2e athos "o gate do MBP é ignorado" '        g = self.prov("gate", HOST, timeout=90)
        try:
            v = json.loads' '        return True, "livre"
        g = self.prov("gate", HOST, timeout=90)
        try:
            v = json.loads'
  mutant e2e athosback "still_free nunca aborta" '        raise Aborted(f"antes de {stage}: {why}")' '        return'
  mutant e2e ok "o clone traz blobs" '"--no-checkout", "--depth", "1", "--filter=blob:none", ' '"--no-checkout", "--depth", "1", '
  mutant e2e evilpush "o hook de pre-push deixa passar qualquer ref" '[ "$rref" = "refs/heads/worker/%s" ] ||' 'true ||'
  mutant e2e shamismatch "o sha do origin não é comparado" 'bool(sha) and got == sha and g["remote_sha"] == sha,' 'bool(got),'
  mutant e2e wrongcontent "o conteúdo do arquivo no mini não é conferido" 'and bool(want) and blob == want,' 'and True,'
  mutant e2e nocomment "o comentário da bead não é conferido" 'and self.run in c.stdout.decode("utf-8", "replace")' 'and True'
  mutant e2e nogchooks "os hooks gc não precisam ter disparado" 'bool(prime) and any("nudge drain" in r["cmd"] for r in ups)' 'True'
  mutant e2e badline "linha ilegível da transcrição não conta" ' and unreadable == 0' ''
  mutant e2e nowatch "o vigia que não rebaixa passa" 'ok, rows, why = judge_tree(rows0, last.get("rows") or [], t0["watcher"])
        for pid' 'ok, rows, why = True, [], ""
        for pid'
  mutant e2e killcore "sessão morta pelo vigia passa" 'and bool(core) and not gone,' 'and True,'
  mutant e2e nonudgeanswer "a resposta ao nudge não é conferida" '(rodou o comando pedido)", NMARK in seen)' '(rodou o comando pedido)", True)'
  mutant e2e leavesocket "o socket sobrando não conta" ' and not s["tmux_socket"] and s["run_dir"]' ' and s["run_dir"]'
  mutant e2e leavefile "o arquivo do lançador sobrando não conta" 'and s["run_dir"] in (None, []) and s["procs"] == [])' 'and s["procs"] == [])'
  mutant e2e leaveproc "processo sobrando não conta" ' and s["procs"] == [])' ')'
  mutant unit sweeppy "arquivo grande demais some da varredura" 'unv.append(p + " (>3MB)")' 'pass'
  mutant unit sweeppy "arquivo que não abre some da varredura" '                unv.append(p)' '                pass'
  mutant unit sweeppy "erro ao descer na pasta some da varredura" 'e.errno == errno.ENOENT or unv.append(e.filename)' 'True'
  mutant unit sweeppy "varredura vazia passa" 'if not scanned:' 'if False:'
  mutant unit sweeppy "o manifest do bundle dispensa TODOS os padrões" 'x.pattern not in C.get("skip", {}).get(p, [])' 'p not in C.get("skip", {})'
  mutant e2e ok "a varredura reprova o manifest do bundle (campo token do hook)" '"skip": {f"{BUNDLE}/manifest.json": [SECRET_KV]}})' '"skip": {}})'
  mutant e2e snapfail "estado ilegível depois da limpeza passa em branco" 'else self.check("(c)(d) varredura depois: li o estado do MBP", False, post["_erro"])' 'else None'
  mutant e2e bigfile "o veredito ignora o que não deu para ler" ' and not sw["unverified"], f"' ', f"'
  mutant e2e secret "a varredura não olha segredo" '"_erro" not in sw and not sw["hits"] and not sw["forbidden"]' '"_erro" not in sw and not sw["forbidden"]'
  mutant e2e sshkey "a comparação antes/depois ignora ~/.ssh e credenciais" 'for k in ("ssh_dir", "creds", "links", "client_conf", "shim_sha"):' 'for k in ("links", "client_conf", "shim_sha"):'
  mutant e2e dialog "o diálogo é ignorado" '            if any(d in seen for d in DIALOGS):' '            if False:'
  mutant e2e ok "a sessão não é parada no fim" '        if self.started:
            try:' '        if False:
            try:'
  mutant e2e swappause "a pausa é removida sem conferir de quem é" 'self.rpy(PAUSE_PY, {"pause": PAUSE, "mark": f"origem=mbp-proof:{self.run}", "mode": "off"})' 'self.rpy(PAUSE_PY, {"pause": PAUSE, "mark": "origem=", "mode": "off"})'
  mutant e2e shadow "um bd real escondendo o atalho passa" '        if shadow:' '        if False:'
  mutant e2e badjson "~/.claude.json ilegível passa" '        if not s["claude_json"]["ok"]:' '        if False:'
  echo "== final: $((n-fails))/$n ok, $skipped sem rodar =="
}
[ "$fails" = 0 ]
