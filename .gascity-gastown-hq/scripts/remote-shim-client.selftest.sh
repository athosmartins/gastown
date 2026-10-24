#!/usr/bin/env bash
# remote-shim-client.selftest.sh — hermético: o lado do SERVIDOR do atalho (remote-shim.py, ga-2hd02v.1.2.2) e a cadeia inteira até o wrapper do
# mini (remote-shim-wrapper.py, ga-2hd02v.1.2.1, testado à parte em remote-shim.selftest.sh). Cidade, rigs, bd/gc/gate-done e ssh são FALSOS em
# mktemp; só a seção "sshd de verdade" usa o ssh e um sshd sem privilégio em 127.0.0.1 de verdade (e some no fim); se ele não subir, a seção diz
# SKIP e o resumo conta quantos casos ficaram sem rodar — não conta como passou.
#
# Contents
#   Casos · Mutantes (como rodar)
#
# SHIM (servidor → ssh falso → wrapper): as opções de segurança do ssh, o último argumento é `rs1 <base64>` e decodifica para o pedido, só
#   as variáveis de FORWARD_ENV são enviadas (um segredo plantado no ambiente NÃO vai), config ausente/ruim → 78 e nenhum ssh, FORWARD_ENV
#   == nomes do wrapper, install (dry-run não grava; --apply liga os 3 nomes; não sobrescreve um `gc` alheio), código de saída, stderr e stdin
#   passam, texto com $(), crase e aspas chega inteiro
# CONTRATO COM A FATIA 1: o builder do bundle, rodado sobre os 4 hooks reais, devolve shim_needs; TODOS passam pela lista
# CADEIA DE VERDADE: shim → ssh → sshd → forced-command → wrapper → bd falso, e o ControlMaster cria o socket de multiplexação
# MUTANTES: SHIM_UNDER_TEST=<cópia do shim com UMA guarda apagada> FAILFAST=1 bash remote-shim-client.selftest.sh (FAILFAST para no 1º caso
#   que reprova: o mutante morreu). A campanha inteira é `python3 -I scripts/remote-shim.mutants.py`.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/remote-shim.selftest.lib.sh"
printf 'texto vindo do stdin' > "$T/stdin.txt"   # (o selftest do lado do mini cria o mesmo arquivo na sua seção; aqui o shim precisa dele)

echo "== shim (servidor): bd/gc/gate-done → ssh → wrapper"
SRV="$T/srv"; mkdir -p "$SRV/fakebin" "$SRV/bin"
python3 -I "$S" install --bin-dir "$SRV/bin" > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && has "$T/out" "[dry-run]" && [ ! -e "$SRV/bin/gc" ] && [ ! -e "$SRV/bin/remote-shim" ]; ok $? "install sem --apply: só mostra o plano, não grava nada"
printf '#!/bin/sh\necho "gc alheio"\n' > "$SRV/bin/gc"; chmod +x "$SRV/bin/gc"
python3 -I "$S" install --bin-dir "$SRV/bin" --apply > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 3 ] && has "$T/err" "não sobrescrevo" && [ ! -e "$SRV/bin/bd" ] && [ "$("$SRV/bin/gc")" = "gc alheio" ]; ok $? "install: não sobrescreve um gc que já existe e não é o nosso (nada é ligado)"
rm -f "$SRV/bin/gc"
python3 -I "$S" install --bin-dir "$SRV/bin" --apply > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && [ -x "$SRV/bin/remote-shim" ] && [ "$(readlink "$SRV/bin/bd")" = remote-shim ] && [ "$(readlink "$SRV/bin/gc")" = remote-shim ] && [ "$(readlink "$SRV/bin/gate-done")" = remote-shim ]; ok $? "install --apply: copia o shim e liga bd, gc e gate-done a ele"
python3 -I "$S" install --bin-dir "$SRV/bin" --apply >/dev/null 2>&1; ok $? "install --apply de novo é idempotente"
cat > "$SRV/fakebin/ssh" <<EOF
#!/bin/bash
D="\$(cd "\$(dirname "\$0")" && pwd)"
printf '%s\n' "\$@" > "\$D/ssh_args.txt"
cmd="\${@: -1}"
exec env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin SSH_CLIENT="198.51.100.7 4000 22" SSH_ORIGINAL_COMMAND="\$cmd" python3 -I "$W" serve --config "$CONF"
EOF
chmod +x "$SRV/fakebin/ssh"
printf 'chave-falsa\n' > "$SRV/key"; printf '[127.0.0.1]:22 ssh-ed25519 AAAAfalsa\n' > "$SRV/kh"
printf '{"host":"127.0.0.1","user":"%s","identity_file":"%s/key","known_hosts_file":"%s/kh","control_dir":"%s"}' "$USER" "$SRV" "$SRV" "$CM" > "$SRV/shim.json"
shim() {  # shim TOOL ARG... → RC, $T/out, $T/err (ambiente do servidor: PATH com o ssh falso, identidade da sessão e um segredo plantado)
  local tool=$1; shift
  env -i HOME="$HOME" USER="$USER" PATH="$SRV/fakebin:/usr/bin:/bin" REMOTE_SHIM_CONF="${SHIM_CONF:-$SRV/shim.json}" GC_ALIAS=gastown.dog-1 GC_AGENT=gastown.dog-1 \
    GC_SESSION_NAME=dog-gavycydh GC_SESSION_ID=ga-vycydh GC_CITY_PATH=/home/runner/gt-remote/city AWS_SECRET_ACCESS_KEY=SEGREDO-PLANTADO-9 "$SRV/bin/$tool" "$@" > "$T/out" 2> "$T/err" < "${STDIN_FILE:-/dev/null}"
  RC=$?
}
b=$(calls); shim bd show ga-1 --json; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && has "$T/out" "FAKE-bd-OUT" && lastis "argv=[show][ga-1][--json]" && lastis "actor=gastown.dog-1"; ok $? "bd show pelo shim: chega ao bd falso, com o argv e o ator"
b=$(calls); shim gc prime --hook; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && lastis "argv=[prime][--hook]"; ok $? "gc prime --hook pelo shim"
shim gc nudge drain --inject; [ "$RC" = 0 ] && lastis "argv=[nudge][drain][--inject]"; ok $? "gc nudge drain --inject pelo shim"
shim gc handoff --auto "context cycle"; [ "$RC" = 0 ] && lastis "argv=[handoff][--auto][context cycle]"; ok $? 'gc handoff --auto "context cycle" pelo shim (aspas e espaço intactos)'
shim gate-done; [ "$RC" = 0 ] && lastis "gatedone	cwd=$CITY"; ok $? "gate-done pelo shim"
b=$(calls); shim bd update ga-1 --if-assignee gastown.dog-1 --if-status in_progress --assignee '' --status open --add-label node:never --remove-label pilot:dispatched; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && lastis "argv=[update][ga-1][--if-assignee][gastown.dog-1][--if-status][in_progress][--assignee][][--status][open][--add-label][node:never][--remove-label][pilot:dispatched]"; ok $? "devolver a bead pelo shim (ga-dxszii): o dono vazio chega como argumento VAZIO ao bd falso, na ordem do cliente"
b=$(calls); shim bd update ga-1 --if-assignee gastown.dog-2 --if-status in_progress --assignee '' --status open --add-label node:never; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "só se devolve a PRÓPRIA bead"; ok $? "devolver com o alias de OUTRO dog pelo shim: 77, o bd falso não é chamado (o alias é o do ambiente da sessão, não o que o comando diz)"
shim bd close ga-1 --reason FAIL7; [ "$RC" = 7 ] && has "$T/err" "fake-err"; ok $? "código de saída e stderr do comando remoto passam pelo shim"
STDIN_FILE="$T/stdin.txt" shim bd comment ga-1 --stdin; has "$T/out" "STDIN<texto vindo do stdin>"; ok $? "stdin passa pelo shim (hook que lê o JSON da sessão)"
b=$(calls); shim bd sql "select 1"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "RECUSADO"; ok $? "bd sql pelo shim: 77 e o bd falso não é chamado"
b=$(calls); shim gc prime; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ]; ok $? "gc prime (sem --hook) pelo shim: recusado"
shim bd comment ga-1 $'linha1\n$(touch '"$T"'/PWNED-shell) `touch '"$T"'/PWNED-shell2` "aspas" \\ fim'; [ "$RC" = 0 ] && lastis 'linha1\n$(touch' && [ ! -e "$T/PWNED-shell" ] && [ ! -e "$T/PWNED-shell2" ]; ok $? "texto com \$(), crase, aspas e barra chega INTEIRO e nada é executado"
shim bd comment ga-1 "$(python3 -I -c 'print("ção ✓ ñ " * 40)')"; [ "$RC" = 0 ] && lastis "ção ✓ ñ"; ok $? "texto UTF-8 chega inteiro"
a=$(cat "$SRV/fakebin/ssh_args.txt"); last_arg=$(tail -1 "$SRV/fakebin/ssh_args.txt")
for opt in BatchMode=yes IdentitiesOnly=yes IdentityAgent=none PasswordAuthentication=no StrictHostKeyChecking=yes "UserKnownHostsFile=$SRV/kh" GlobalKnownHostsFile=/dev/null \
           ForwardAgent=no ForwardX11=no ClearAllForwardings=yes PermitLocalCommand=no ControlMaster=auto "ControlPath=$CM/cm-%C" ConnectTimeout=10; do
  printf '%s\n' "$a" | grep -qxF -- "$opt"; ok $? "  ssh sobe com -o $opt"
done
for flag in -T -a -x -F /dev/null "$SRV/key" -- "$USER@127.0.0.1"; do printf '%s\n' "$a" | grep -qxF -- "$flag"; ok $? "  ssh sobe com $flag"; done
case "$last_arg" in "rs1 "*) true;; *) false;; esac; ok $? "  o último argumento é o pedido 'rs1 <base64>'"
python3 -I -c 'import sys,json,base64
c=sys.argv[1].split(" ")[1]; d=json.loads(base64.urlsafe_b64decode(c+"="*(-len(c)%4)))
assert d["tool"]=="bd" and d["argv"][0]=="comment" and set(d["env"])<={"GC_ALIAS","GC_AGENT","GC_SESSION_NAME"}, d' "$last_arg"; ok $? "  o pedido decodifica para {tool, argv, env} e o env tem só identidade"
! printf '%s' "$last_arg" | grep -q SEGREDO-PLANTADO; ok $? "  o segredo plantado no ambiente do servidor NÃO vai no pedido"
python3 -I -c 'import sys,base64; c=sys.argv[1].split(" ")[1]; assert b"SEGREDO-PLANTADO" not in base64.urlsafe_b64decode(c+"="*(-len(c)%4)); assert b"GC_CITY_PATH" not in base64.urlsafe_b64decode(c+"="*(-len(c)%4))' "$last_arg"; ok $? "  nem GC_CITY_PATH do servidor"
[ "$(python3 -I "$S" forward-env | sort | tr '\n' ' ')" = "$(python3 -I "$W" list | sed -n 's/^env //p' | sort | tr '\n' ' ')" ]; ok $? "FORWARD_ENV do shim == variáveis que o wrapper aceita"
rm -f "$SRV/fakebin/ssh_args.txt"
for bad in '{x' '[]' '{"host":"h","user":"u"}' "{\"host\":\"127.0.0.1\",\"user\":\"u\",\"identity_file\":\"$SRV/nao\",\"known_hosts_file\":\"$SRV/kh\"}" \
           "{\"host\":\"127.0.0.1\",\"user\":\"u\",\"identity_file\":\"$SRV/key\",\"known_hosts_file\":\"$SRV/kh\",\"extra\":1}" \
           "{\"host\":\"h h\",\"user\":\"u\",\"identity_file\":\"$SRV/key\",\"known_hosts_file\":\"$SRV/kh\"}" \
           "{\"host\":\"-oProxyCommand=x\",\"user\":\"u\",\"identity_file\":\"$SRV/key\",\"known_hosts_file\":\"$SRV/kh\"}"; do
  printf '%s' "$bad" > "$SRV/bad.json"; SHIM_CONF="$SRV/bad.json" shim bd show ga-1
  [ "$RC" = 78 ] && [ ! -e "$SRV/fakebin/ssh_args.txt" ] && has "$T/err" "Não vou chamar o mini"; ok $? "config do shim ruim ($(printf '%s' "$bad" | cut -c1-40)): 78 e NENHUM ssh"
done
printf '{"host":"127.0.0.1","user":"u","identity_file":"%s/key","known_hosts_file":"%s/nao"}' "$SRV" "$SRV" > "$SRV/bad.json"; SHIM_CONF="$SRV/bad.json" shim bd show ga-1
[ "$RC" = 78 ] && [ ! -e "$SRV/fakebin/ssh_args.txt" ]; ok $? "known_hosts_file ausente: 78 e NENHUM ssh (sem confiar na primeira vez)"
SHIM_CONF="$SRV/nao-existe.json" shim bd show ga-1; [ "$RC" = 78 ] && [ ! -e "$SRV/fakebin/ssh_args.txt" ]; ok $? "config do shim ausente: 78 e NENHUM ssh"
mkdir -p "$SRV/ro"; chmod 500 "$SRV/ro"
if [ ! -w "$SRV/ro" ]; then
  printf '{"host":"127.0.0.1","user":"u","identity_file":"%s/key","known_hosts_file":"%s/kh","control_dir":"%s/ro/sub"}' "$SRV" "$SRV" "$SRV" > "$SRV/bad.json"
  SHIM_CONF="$SRV/bad.json" shim bd show ga-1
  [ "$RC" = 78 ] && [ ! -e "$SRV/fakebin/ssh_args.txt" ] && has "$T/err" "pasta da conexão"; ok $? "pasta da conexão que não dá para criar: 78 e NENHUM ssh (não o 1 de um crash, que o gc mail check também usa para 'caixa vazia')"
else skip "pasta não protegida (rodando como root: chmod não impede)"; fi
chmod 700 "$SRV/ro"

echo "== dolt recusado (ga-w7qwl1.1.5): o atalho que ocupa o nome no PATH da sessão do MBP"
[ ! -e "$SRV/bin/dolt" ] && [ ! -L "$SRV/bin/dolt" ]; ok $? "install sem --refuse-dolt NÃO liga o dolt (o servidor não muda)"
python3 -I "$S" install --bin-dir "$SRV/bin" --refuse-dolt > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && has "$T/out" "/dolt -> remote-shim" && [ ! -L "$SRV/bin/dolt" ]; ok $? "install --refuse-dolt sem --apply: o plano mostra o dolt e nada é gravado"
python3 -I "$S" install --bin-dir "$SRV/bin" --refuse-dolt --apply > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && [ "$(readlink "$SRV/bin/dolt")" = remote-shim ] && [ "$(readlink "$SRV/bin/bd")" = remote-shim ]; ok $? "install --refuse-dolt --apply liga também o dolt ao shim"
python3 -I "$S" install --bin-dir "$SRV/bin" --refuse-dolt --apply >/dev/null 2>&1; ok $? "  ...e de novo é idempotente"
mkdir -p "$SRV/bin2"; printf '#!/bin/sh\necho "dolt alheio"\n' > "$SRV/bin2/dolt"; chmod +x "$SRV/bin2/dolt"
python3 -I "$S" install --bin-dir "$SRV/bin2" --refuse-dolt --apply > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 3 ] && has "$T/err" "não sobrescrevo" && [ ! -e "$SRV/bin2/bd" ] && [ ! -e "$SRV/bin2/remote-shim" ] && [ "$("$SRV/bin2/dolt")" = "dolt alheio" ]; ok $? "install --refuse-dolt: não sobrescreve um dolt alheio (nada é ligado)"
rm -f "$SRV/fakebin/ssh_args.txt"
b=$(calls); shim dolt sql -q "select 1"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && [ ! -e "$SRV/fakebin/ssh_args.txt" ] && has "$T/err" "não existe nesta sessão"; ok $? "dolt pelo shim: 77, nenhum ssh e nenhum comando no mini"
SHIM_CONF="$SRV/nao-existe.json" shim dolt version; [ "$RC" = 77 ] && [ ! -e "$SRV/fakebin/ssh_args.txt" ]; ok $? "dolt recusa sem ler a config do shim (config ausente não vira 78: o dolt nunca fala com o mini)"
STDIN_FILE="$T/stdin.txt" shim dolt sql; [ "$RC" = 77 ] && [ ! -e "$SRV/fakebin/ssh_args.txt" ]; ok $? "dolt com entrada padrão: também 77 sem ssh (nada do stdin sai da máquina)"

echo "== contrato com a fatia 1: todo shim_needs do bundle passa pela lista"
BD="$T/bundle"; mkdir -p "$BD/city/.gc" "$BD/home/.claude" "$BD/role/.claude"
printf '{}' > "$BD/home/.claude/settings.json"; printf '{}' > "$BD/role/.claude/settings.json"
python3 -I - "$BD/city/.gc/settings.json" <<'EOF'
import json, sys
P = 'export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH" && '  # as quatro linhas são as strings REAIS de <cidade>/.gc/settings.json (medido em 14/10)
h = lambda c: [{"hooks": [{"type": "command", "command": c}]}]
json.dump({"hooks": {"PreCompact": h(P + 'gc handoff --auto "context cycle"'),
                     "SessionStart": h(P + "GC_MANAGED_SESSION_HOOK=1 GC_HOOK_EVENT_NAME=SessionStart gc prime --hook --hook-format codex"),
                     "UserPromptSubmit": h(P + "gc nudge drain --inject") + h(P + "gc mail check --inject")}}, open(sys.argv[1], "w"))
EOF
python3 -I "$BUILD" build --city "$BD/city" --claude-home "$BD/home/.claude" --role dog --role-dir "$BD/role" --remote-root /home/runner/gt-remote/bundle \
  --remote-home /home/runner --mini-home "$BD/home" --out "$BD/OUT" > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 0 ]; ok $? "o builder da fatia 1 monta o bundle com os 4 hooks reais (exit 0)"
NEEDS=$(jq -r '.shim_needs[]' "$BD/OUT/manifest.json" 2>/dev/null); [ "$(printf '%s\n' "$NEEDS" | wc -l | tr -d ' ')" = 4 ]; ok $? "shim_needs tem 4 entradas"
while IFS= read -r need; do
  [ -z "$need" ] && continue
  eval "set -- $need"   # a string é o argv exato que o shell do hook montaria (aspas e tudo)
  b=$(calls); shim gc "$@"; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ]; ok $? "  shim_needs \`gc $need\` passa pelo shim e roda"
done <<< "$NEEDS"

echo "== sshd de verdade (sem privilégio, 127.0.0.1, porta livre): shim → ssh → sshd → forced-command → wrapper"
if start_sshd; then
  printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1,2 "$SD/host_key.pub")" > "$SRV/kh"
  cp "$KD/user_key" "$SRV/key"; chmod 600 "$SRV/key"
  printf '{"host":"127.0.0.1","port":%s,"user":"%s","identity_file":"%s/key","known_hosts_file":"%s/kh","control_dir":"%s","connect_timeout":5}' "$PORT" "$USER" "$SRV" "$SRV" "$CM" > "$SRV/shim-real.json"
  realshim() {  # o shim com o ssh DE VERDADE (sem o ssh falso no PATH)
    local tool=$1; shift
    tmo 30 env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin REMOTE_SHIM_CONF="$SRV/shim-real.json" GC_ALIAS=gastown.dog-1 GC_AGENT=gastown.dog-1 GC_SESSION_NAME=dog-gavycydh \
      "$SRV/bin/$tool" "$@" > "$T/out" 2> "$T/err" < /dev/null
    RC=$?
  }
  b=$(calls); realshim bd show ga-1 --json; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && has "$T/out" "FAKE-bd-OUT" && lastis "argv=[show][ga-1][--json]"; ok $? "cadeia inteira: shim → ssh → sshd → forced-command → wrapper → bd falso"
  b=$(calls); realshim gc prime --hook; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && lastis "argv=[prime][--hook]"; ok $? "  gc prime --hook pela cadeia real"
  realshim gc handoff --auto "context cycle"; [ "$RC" = 0 ] && lastis "argv=[handoff][--auto][context cycle]"; ok $? '  gc handoff --auto "context cycle" pela cadeia real'
  b=$(calls); realshim bd update ga-1 --if-assignee gastown.dog-1 --if-status in_progress --assignee '' --status open --add-label node:never; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && lastis "argv=[update][ga-1][--if-assignee][gastown.dog-1][--if-status][in_progress][--assignee][][--status][open][--add-label][node:never]"; ok $? "  devolver a bead (ga-dxszii) pela cadeia real: o argumento vazio atravessa o ssh, o sshd e o shell de login"
  b=$(calls); realshim bd sql "select 1"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "RECUSADO"; ok $? "  bd sql pela cadeia real: 77 e nada executa no mini"
  ls "$CM"/cm-* >/dev/null 2>&1; ok $? "  o ControlMaster criou o socket de multiplexação"
else
  skip "sshd de verdade: não subiu (sshd=${SSHD:-ausente}) — 6 casos da cadeia inteira ficaram SEM rodar; os casos com ssh falso acima NÃO provam que o pedido atravessa um sshd de verdade"
  skipped=$((skipped+5))
fi

echo
if [ "$skipped" -gt 0 ]; then echo "AVISO: $skipped caso(s) NÃO rodaram (SKIP acima) — não contam como passou"; fi
echo "$((n-fails))/$n ok, $fails falharam, $skipped pulados"
exit $((fails > 0))
