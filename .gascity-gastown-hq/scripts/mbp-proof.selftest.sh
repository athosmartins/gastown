#!/usr/bin/env bash
# mbp-proof.selftest.sh — hermético: o "MBP" é uma pasta ($SRV) e o "ssh" é um falso que roda o comando no próprio mini com OUTRO HOME e um PATH limpo; o provider,
# o tmux, o claude, o puxador, o cliente do atalho e o bd do mini são falsos; o origin é um repositório bare local com um arquivo de "lead" de isca. O builder é o
# DE VERDADE (a CLI que o mbp-proof usa tem que casar com ele). Nada conecta em MBP, servidor, GitHub ou Dolt.
#
# Contents
#   Grupos · Controle negativo · Variáveis · O que NÃO prova
#
# GRUPOS: unit — pedido de start, bloco do host, identidade do wrapper ·
#   cli — install sem --apply (nada conecta), plan contra o dry-run do provider (pula sem scripts/gc-session-ssh, p.ex. no nó Linux) ·
#   install — instalação com o builder real: bundle conferido LÁ, run/ preservada, cliente + links + config, spool 0700, nada em ~/.claude nem ~/.ssh, config do wrapper
#   diferente = não sobrescreve, transferência adulterada = reprova sem trocar, ssh fora / MBP não livre = 3
# CONTROLE NEGATIVO: cada guarda é trocada numa cópia (python, uma ocorrência exata) e os casos que a cobrem TÊM que passar a falhar.
# VARIÁVEIS: MBPT_UNDER_TEST (script a testar) · MBPT_ONLY (grupos separados por vírgula; ou --only=a,b) · MBPT_CASES (casos; ou --cases=a,b) · MBPT_NO_MUTANTS=1 (ou --no-mutants) ·
#   MBPT_DEBUG=1 (ou --debug: mostra a saída do driver em cada install)
# O QUE NÃO PROVA: o MBP de verdade (macOS, tmux, claude, a biblioteca de presença, o git/ssh com a credencial dele).
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
export HOME="$MINI" GC_CITY_PATH="$CITY" GC_SSH_BIN="$T/bin/ssh" MBP_PROOF_HOME="$SRV" MBP_PROOF_SSH="fake@mbp" \
  MBP_PROOF_PROV="$T/fakeprov" MBP_PROOF_SHIM_CLIENT="$T/fake-remote-shim.py" MBP_PROOF_BUILDER="$BUILDER" \
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
HOME="$SRV" TMUX_TMPDIR="$SRV/tmp" ON_MBP=1 PATH="$SRV/fakebin:/usr/bin:/bin" sh -c "$cmd"; rc=$?
if [ -n "${FAKE_TAMPER:-}" ]; then case $cmd in *"; tar -C "*" -xf -") d=${cmd##*tar -C }; d=${d% -xf -}; echo adulterado > "$d/injetado.txt";; esac; fi
exit $rc
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
EOF
cat > "$T/fakeprov" <<'EOF'
#!/bin/bash
S="$FAKE_STATE"; echo "$*" >> "$S/provcalls"; op=${1:-}; shift
NAME=remote-test-remote-mbp-1; G="$SRV/gt-remote"; BUNDLE="$G/bundle"; PAUSE="$G/PAUSE"; SOCK="$SRV/tmp/tmux-$(id -u)/gc-remote"; mode=${FAKE_MODE:-ok}
case "$op" in
  gate)
    if [ -e "$PAUSE" ]; then
      echo '{"ok":false,"reason":"pausa do Athos ativa"}'; exit 1
    fi
    g=${FAKE_GATE:-free}
    case $g in
      free) echo '{"ok":true,"reason":"livre","cap":2,"slot_cap":2}';;
      athos) echo '{"ok":false,"reason":"Athos está no MBP (presença=mbp)"}'; exit 1;;
      health) echo '{"ok":false,"reason":"MBP sem saúde ou fora do ar (rc 98)"}'; exit 1;;
      flag) echo '{"ok":false,"reason":"bandeira mbp-offload desligada"}'; exit 1;;
      garbage) echo 'not-json {{{'; exit 0;;
      nodict) echo '[1]'; exit 0;;
    esac;;
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
proof() { python3 -I "$P" "$@"; }
inst() { world_reset; proof install --apply > "$T/out" 2> "$T/err"; RC=$?; [ -z "${MBPT_DEBUG:-}" ] || cat "$T/out" "$T/err" >&2; }
mkgold() {  # a instalação de referência (feita pelo próprio script sob teste): cada e2e parte de uma cópia dela
  [ -d "$GOLD" ] && return 0
  srv_skeleton; inst; [ $RC = 0 ] || { echo "FAIL a instalação de referência não saiu (rc=$RC): $(tail -3 "$T/out")"; return 1; }
  cp -a "$SRV" "$GOLD"
}

# ---------------------------------------------------------------- unit
g_unit() {
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
}

# ---------------------------------------------------------------- cli
g_cli() {
  world_reset
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

all() { group unit && g_unit; group cli && g_cli; group install && g_install; }
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
  echo "== final: $((n-fails))/$n ok, $skipped sem rodar =="
}
[ "$fails" = 0 ]
