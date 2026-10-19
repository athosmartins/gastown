# remote-shim.selftest.lib.sh — harness comum dos selftests do atalho (ga-2hd02v.1.2.x), carregado (`.`) por remote-shim.selftest.sh (lado do mini) e por
# remote-shim-client.selftest.sh (servidor + cadeia); quem carrega faz `set -u` e define HERE. Tem: ambiente (tmp, cidade, falsos, config), funções, chaves, start_sshd.
W="${WRAPPER_UNDER_TEST:-$HERE/remote-shim-wrapper.py}"
S="${SHIM_UNDER_TEST:-$HERE/remote-shim.py}"
BUILD="$HERE/remote-bundle-build.py"
RUNBOOK="$HERE/../docs/runbooks/remote-shim.md"
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rshim-selftest.XXXXXX")" && pwd -P)
CM=$(mktemp -d /tmp/rshcm.XXXXXX)  # caminho curto: o ControlPath de socket unix tem teto de ~104 caracteres
SSHD_PID=""
cleanup() {
  [ -n "$SSHD_PID" ] && kill "$SSHD_PID" 2>/dev/null
  for s in "$CM"/cm-*; do [ -S "$s" ] && ssh -F /dev/null -O exit -o "ControlPath=$s" x >/dev/null 2>&1; done
  chmod -R u+rwX "$T" "$CM" 2>/dev/null; find "$T" "$CM" -mindepth 1 -delete 2>/dev/null; rmdir "$T" "$CM" 2>/dev/null
}
trap cleanup EXIT
fails=0; n=0; skipped=0
ok() {
  n=$((n+1))
  if [ "$1" = 0 ]; then echo "ok   $2"; return; fi
  echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/err" ] && echo "     (último stderr: $(head -c 300 "$T/err" | tr '\n' ' '))"
  # FAILFAST_IGNORE (regex, opcional): casos que reprovam por causa do AMBIENTE (no Linux do servidor: "pedido grande demais", "JSON aninhado fundo demais", "o log é 0600", "sem a separação"),
  # não do mutante, não param a campanha: sem isso o 1º FAIL de ambiente (linha ~209) mata toda rodada antes de ela chegar nos casos que o mutante deveria reprovar
  if [ -n "${FAILFAST:-}" ] && ! { [ -n "${FAILFAST_IGNORE:-}" ] && printf '%s' "$2" | grep -qE -- "$FAILFAST_IGNORE"; }; then echo "FAILFAST: parei no 1º caso que reprovou ($n casos rodados)"; exit 1; fi  # para a campanha de mutantes: reprovar UM caso já mata o mutante
}
skip() { skipped=$((skipped+1)); echo "SKIP $1"; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
tmo() { perl -e 'alarm shift; exec @ARGV' "$@"; }  # ssh que "funciona demais" (restrict apagado) ficaria pendurado: teto de tempo

CITY="$T/city"; WA="$T/wa_rig"; FB="$T/fakebin"; LOGF="$T/audit.log"; CONF="$T/conf.json"
mkdir -p "$CITY/.beads" "$WA" "$FB" "$FB/beads" "$T/evil"
printf '{"prefix":"ga","path":"."}\n{"prefix":"wa","path":"../wa_rig"}\n' > "$CITY/.beads/routes.jsonl"
printf 'touch "%s/PWNED-bashenv"\n' "$T" > "$T/planted.sh"
printf 'open("%s/PWNED-pythonpath","w")\n' "$T" > "$T/evil/json.py"
for tool in bd gc gatedone; do cat > "$FB/$tool" <<'EOF'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"; n=$(basename "$0")
# a leitura de estado que o atalho faz antes de bd comment/close (ga-2hd02v.1.16) roda com BD_READONLY=true, como o engine lê bead (internal/beads/database.go):
# ela vai para reads.log, e calls.log segue sendo "uma linha por pedido" (o que `calls`, `allowed` e `lastis` contam são os COMANDOS)
LOG="$D/calls.log"; [ "${BD_READONLY-}" = true ] && LOG="$D/reads.log"
{ printf '%s\tcwd=%s\tactor=%s\talias=%s\thook=%s/%s\tbashenv=%s\tld=%s\tcitypath=%s\tpypath=%s\tro=%s/%s\targv=' "$n" "$PWD" "${BEADS_ACTOR-UNSET}" \
    "${GC_ALIAS-UNSET}" "${GC_MANAGED_SESSION_HOOK-UNSET}" "${GC_HOOK_EVENT_NAME-UNSET}" "${BASH_ENV-UNSET}" "${LD_PRELOAD-UNSET}" \
    "${GC_CITY_PATH-UNSET}" "${PYTHONPATH-UNSET}" "${BD_READONLY-UNSET}" "${BD_DOLT_AUTO_COMMIT-UNSET}"
  for a in "$@"; do a=${a//$'\n'/\\n}; printf '[%s]' "$a"; done; printf '\n'; } >> "$LOG"
if [ "$n" = bd ] && [ "${1-}" = show ] && [ "${3-}" = --json ] && [ $# -eq 3 ]; then  # `bd show <id> --json`: responde o estado da bead (fixture $D/beads/<id>.*); sem fixture, uma bead COMUM de outro dono, sem rótulo de veredito
  b="$D/beads/$2"
  [ "${BD_READONLY-}" = true ] && cat > /dev/null  # a leitura de estado não herda o stdin do COMANDO: se herdasse, comeria o texto do bd comment --stdin (o mutante leitura-herda-stdin)
  [ -e "$b.noise" ] && echo "[mysql] 2026/10/19 13:40:39 packets.go:58 read tcp 127.0.0.1:59514->127.0.0.1:52756: i/o timeout" >&2  # o aviso do Dolt vai ao STDERR; o stdout segue JSON limpo
  if [ -e "$b.rc" ]; then [ -e "$b.json" ] && cat "$b.json"; echo "fake-bd: show falhou" >&2; exit "$(cat "$b.rc")"; fi  # rc≠0 com um JSON válido no stdout: o rc é quem manda
  if [ -e "$b.sleep" ]; then sleep 37 & echo $! > "$D/read-sleep.pid"; wait; exit 0; fi
  if [ -e "$b.raw" ]; then cat "$b.raw"; exit 0; fi
  if [ -e "$b.json" ]; then cat "$b.json"; exit 0; fi
  printf '[{"id":"%s","title":"FAKE-bd-OUT","status":"in_progress","assignee":"dono-qualquer","labels":["area:infra"]}]\n' "$2"; exit 0
fi
echo "FAKE-$n-OUT"
for a in "$@"; do case "$a" in --stdin) echo "STDIN<$(cat)>";; FAIL7) echo "fake-err" >&2; exit 7;; SLEEP) sleep 37 & echo $! > "$D/sleep.pid"; wait;; BREAKLOG) rm -f "$D/../audit.log"; mkdir "$D/../audit.log";; esac; done
exit 0
EOF
chmod +x "$FB/$tool"; done
cat > "$CONF" <<EOF
{"city": "$CITY", "identity_pattern": "(gastown\\\\.dog-[0-9]+|gastown\\\\.dog|dog-[a-z0-9]+|wa-worker-[a-z0-9-]+)", "nudge_pattern": "gastown\\\\.(mayor|deacon)", "gate_done_bin": "$FB/gatedone", "log": "$LOGF", "timeout_s": 120, "bin_dirs": ["$FB"]}
EOF
ID='{"GC_ALIAS":"gastown.dog-1","GC_AGENT":"gastown.dog-1","GC_SESSION_NAME":"dog-gavycydh"}'

rq() {  # rq TOOL ENVJSON ARG... → a linha `rs1 <base64url>` que o shim mandaria
  local tool=$1 envj=$2; shift 2
  python3 -I -c 'import sys, json, base64
tool, envj, *args = sys.argv[1:]
p = json.dumps({"tool": tool, "argv": args, "env": json.loads(envj)}, separators=(",", ":"))
print("rs1 " + base64.urlsafe_b64encode(p.encode()).decode().rstrip("="), end="")' "$tool" "$envj" "$@"
}
raw() {  # raw JSON → `rs1 <base64url>` (para fabricar pedido torto)
  python3 -I -c 'import sys, base64; print("rs1 " + base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip("="), end="")' "$1"
}
wrap() {  # wrap "<SSH_ORIGINAL_COMMAND>" [arquivo-de-stdin] → RC, $T/out, $T/err (o ambiente é o que um sshd hostil poderia deixar)
  env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin SSH_CLIENT="203.0.113.9 5555 22" BASH_ENV="$T/planted.sh" LD_PRELOAD=/nonexistent/x.so \
    PYTHONPATH="$T/evil" GC_CITY_PATH=/nonexistent SSH_ORIGINAL_COMMAND="$1" python3 -I "$W" serve --config "${CONF_OVERRIDE:-$CONF}" \
    > "$T/out" 2> "$T/err" < "${2:-/dev/null}"
  RC=$?
}
call() { wrap "$(rq "$1" "$ID" "${@:2}")" "${STDIN_FILE:-}"; }  # call TOOL ARG...
calls() { [ -e "$FB/calls.log" ] || { echo 0; return; }; local c; c=$(wc -l < "$FB/calls.log") || c=-1; echo $((c)); }  # sem arquivo = nenhuma chamada ainda; arquivo que existe e não lê = -1, nunca 0 (wc do macOS enche de espaço: normaliza)
last() { tail -1 "$FB/calls.log"; }
lastis() { last | grep -qF -- "$1"; }
allowed() {  # allowed "descrição" TOOL ARG... → sai 0 e UMA chamada nova ao falso
  local d=$1 b; b=$(calls); shift; call "$@"; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ]; ok $? "$d"
}
denied() {  # denied "descrição" "trecho do motivo" TOOL ARG... → 77, mensagem, e o falso NÃO foi chamado
  local d=$1 why=$2 b; b=$(calls); shift 2; call "$@"
  [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "RECUSADO" && has "$T/err" "$why"; ok $? "$d  [$why]"
}
REQ_OK="$(rq bd "$ID" show ga-1)"
badreq() {  # badreq "descrição" "motivo" "<SSH_ORIGINAL_COMMAND>"
  local b; b=$(calls); wrap "$3"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "$2"; ok $? "$1  [$2]"
}

KD="$T/keys"; mkdir -p "$KD"
ssh-keygen -q -t ed25519 -N '' -f "$KD/user_key" -C "alguem@servidor"
ssh-keygen -q -t ed25519 -N '' -f "$KD/other" -C "outra@maquina"  # uma chave VÁLIDA que não está no authorized_keys: a "chave não listada" de verdade

start_sshd() {  # sobe um sshd sem privilégio em 127.0.0.1 numa porta livre, com a linha de authorized_keys que o wrapper em teste gera para $KD/user_key; 0 = subiu
SSHD=$(command -v sshd || ls /usr/sbin/sshd 2>/dev/null | head -1)
PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
SD="$T/sshd"; mkdir -p "$SD"
if [ -n "$SSHD" ] && ssh-keygen -q -t ed25519 -N '' -f "$SD/host_key" && python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/user_key.pub" --from 127.0.0.1 > "$SD/authorized_keys"; then
  cat > "$SD/sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $PORT
HostKey $SD/host_key
PidFile $SD/sshd.pid
AuthorizedKeysFile $SD/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
LogLevel ERROR
EOF
  "$SSHD" -f "$SD/sshd_config" -D -e > "$SD/sshd.log" 2>&1 &
  SSHD_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do python3 -I -c "import socket;socket.create_connection(('127.0.0.1',$PORT),0.3)" 2>/dev/null && break; sleep 0.25; done
fi
  [ -n "$SSHD_PID" ] && kill -0 "$SSHD_PID" 2>/dev/null && python3 -I -c "import socket;socket.create_connection(('127.0.0.1',$PORT),1)" 2>/dev/null
}
