#!/bin/bash
# hetzner-claude.selftest.sh — hermético e em LOOPBACK: o "servidor" é uma pasta (mktemp) e o ssh falso roda o comando DE VERDADE nela,
# com HOME apontando para lá. O claude do servidor é falso (lê arquivos em $FAKE). Nada toca a rede, o servidor
# real nem a credencial do mini. Os textos de erro de COTA e de login EXPIRADO são sintéticos (só o de "deslogado" foi medido em
# 14/10): estes casos provam o classificador, não o texto real do claude — isso só se mede depois do login.
# HETZNER_CLAUDE_UNDER_TEST=<arquivo> roda o mesmo selftest contra uma cópia alterada (mutante); HZC_FAILFAST=1 para na 1ª falha.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=${HETZNER_CLAUDE_UNDER_TEST:-$HERE/hetzner-claude.py}
T=$(mktemp -d "${TMPDIR:-/tmp}/hzc-selftest.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap 'case "$T" in */hzc-selftest.*) chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T";; esac' EXIT
SRV=$T/srv
mkdir -p "$T/bin" "$T/state" "$T/fake" "$T/home" "$T/city" "$SRV/.local/bin"
export FAKE=$T/fake SRV HETZNER_STATE_DIR=$T/state GC_CITY_PATH=$T/city HOME=$T/home HETZNER_REMOTE_HOME=$SRV \
  HETZNER_REMOTE_ROOT=$SRV/gt-remote/bundle PATH="$T/bin:$PATH"
STATE=$T/state; SF=$STATE/hetzner-claude.state.json; RROOT=$HETZNER_REMOTE_ROOT
cat >"$T/bin/ssh" <<'EOF'
#!/bin/sh
[ -f "$FAKE/ssh.stdin.on" ] && wc -c >>"$FAKE/ssh.stdin"
[ -f "$FAKE/sleep" ] && sleep "$(cat "$FAKE/sleep")"
[ -f "$FAKE/ssh.rc" ] && { echo "ssh: Could not resolve hostname" >&2; exit "$(cat "$FAKE/ssh.rc")"; }
while [ "$1" = "-o" ]; do shift 2; done
shift
HOME=$SRV exec sh -c "$*"
EOF
printf '#!/bin/sh\necho "$*" >>"$FAKE/notify.log"\n' >"$T/bin/notify"
printf '#!/bin/sh\necho "$*" >>"$FAKE/security.args"\n[ -f "$FAKE/mdat" ] || exit 44\nprintf "    \\"mdat\\"<timedate>=0x00  \\"%%s\\\\000\\"\\n" "$(cat "$FAKE/mdat")"\n' >"$T/bin/security"
cat >"$SRV/.local/bin/claude" <<'EOF'
#!/bin/bash
F=$FAKE
rd() { cat "$F/$1" 2>/dev/null; }
case "$1 $2 $3" in
  "auth status "*) echo auth >>"$F/calls"; rd auth.out; exit "$(rd auth.rc)";;
esac
case "$1" in
  -p) echo probe >>"$F/calls"; echo "$*" >>"$F/probe.args"; { printf '<%s>' "$@"; echo; } >>"$F/probe.argv"; pwd >>"$F/probe.pwd"; rd probe.out; exit "$(rd probe.rc)";;
esac
exit 98
EOF
chmod +x "$T/bin/"* "$SRV/.local/bin/claude"
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -z "${HZC_FAILFAST:-}" ] || exit 1; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1 (obtido '$2', esperado '$3')"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok; else bad "$1 (não achei '$3' em: $2)"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (achei '$3')"; else ok; fi; }
setauth() { printf '%s' "$1" >"$FAKE/auth.out"; echo "$2" >"$FAKE/auth.rc"; }
setprobe() { printf '%s' "$1" >"$FAKE/probe.out"; echo "$2" >"$FAKE/probe.rc"; }
reset() { rm -f "$STATE"/hetzner-claude.* "$FAKE"/*; : >"$FAKE/calls"; setauth "$AUTH_ON" 0; setprobe "$P_OK" 0; }
calls() { grep -c "^$1\$" "$FAKE/calls" || true; }
notifys() { if [ -f "$FAKE/notify.log" ]; then wc -l <"$FAKE/notify.log" | tr -d ' '; else echo 0; fi; }
age() { python3 -I - "$SF" "$1" "$2" <<'PY'
import json, sys
p, what, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
d = json.load(open(p))
if what == "checked": d["checked_at"] += secs
else: d["probe"]["at"] += secs
json.dump(d, open(p, "w"))
PY
}
g() { local out rc; out=$(python3 -I "$S" gate 2>&1); rc=$?; GOUT=$out
  if [ "$rc" = "$2" ] && printf '%s' "$out" | grep -qF -- "$3"; then ok; else bad "$1 (rc=$rc, queria $2; saída: $out)"; fi; }
AUTH_ON='{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'
AUTH_OFF='{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'
P_OK='{"type":"result","subtype":"success","is_error":false,"result":"OK"}'
P_LOGOUT='{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","result":"Not logged in · Please run /login"}'
P_QUOTA='{"type":"result","subtype":"success","is_error":true,"result":"You have hit your usage limit"}'

echo "== gate: três respostas, não duas"
reset; setauth "$AUTH_OFF" 1; g "deslogado" 1 "logged-out"; eq "deslogado não chama modelo" "$(calls probe)" 0
reset; g "ok exige login E chamada de modelo" 0 "ok"; eq "uma chamada de modelo" "$(calls probe)" 1
reset; setprobe "$P_LOGOUT" 1; g "MEDIDO 14/10: subtype success + is_error true NÃO é ok" 1 "expired"
reset; setprobe '{"type":"result","subtype":"success","result":"OK"}' 0; g "sem is_error" 1 "unknown"
reset; setprobe '{"type":"result","is_error":false,"result":"OK"}' 1; g "is_error false mas rc 1" 1 "unknown"
reset; setprobe 'not json' 0; g "modelo sem JSON" 1 "unknown"
reset; setauth '{"loggedIn":"true"}' 0; g "loggedIn string" 1 "unknown"
reset; setauth '{"authMethod":"x"}' 0; g "sem loggedIn" 1 "unknown"
reset; setauth "$AUTH_ON" 1; g "loggedIn true mas rc 1" 1 "unknown"
reset; setauth 'oops' 0; g "auth sem JSON" 1 "unknown"
reset; echo 255 >"$FAKE/ssh.rc"; g "ssh 255" 1 "unreachable"
reset; echo 3 >"$FAKE/sleep"; export HETZNER_SSH_TIMEOUT=1; g "ssh timeout" 1 "unreachable"; unset HETZNER_SSH_TIMEOUT

echo "== cache e relógio"
reset; g "mede" 0 ok; setauth "$AUTH_OFF" 1; g "dentro do TTL usa o cache" 0 ok; eq "sem ssh novo" "$(calls auth)" 1
age checked -1000; g "vencido mede de novo" 1 logged-out
reset; g "mede" 0 ok; setauth "$AUTH_OFF" 1; age checked 100000; g "data no futuro não é cache" 1 logged-out
reset; echo '{not json' >"$SF"; g "estado corrompido é medido de novo" 0 ok
reset; echo '{"state":"ok","reason":"","checked_at":"agora"}' >"$SF"; setauth "$AUTH_OFF" 1; g "checked_at de tipo errado não é cache" 1 logged-out
reset; echo '{"state":"ok","reason":"","checked_at":1}' >"$SF"; setauth "$AUTH_OFF" 1; g "ok antigo no disco não vale" 1 logged-out

echo "== janelas da chamada de modelo"
reset; g . 0 ok; age checked -1000; g "ok dentro da janela não repete a chamada" 0 ok; eq "ainda 1" "$(calls probe)" 1
age checked -1000; age probe -4000; g "ok vencido repete" 0 ok; eq "2 chamadas" "$(calls probe)" 2
reset; setprobe "$P_QUOTA" 1; g "sem cota" 1 quota; age checked -1000; g "quota dentro do retry não repete" 1 quota; eq "1 chamada" "$(calls probe)" 1
age checked -1000; age probe -1000; g "quota após o retry repete" 1 quota; eq "2 chamadas" "$(calls probe)" 2
reset; g . 0 ok; setauth "$AUTH_OFF" 1; age checked -1000; g "deslogou" 1 logged-out
setauth "$AUTH_ON" 0; age checked -1000; g "logou de novo: não herda o ok de antes" 0 ok; eq "mediu de novo" "$(calls probe)" 2

echo "== chamada de modelo sem resposta (login ok)"
reset; g . 0 ok; age checked -1000; age probe -5000; setprobe "" 255; g "ssh cai só na chamada de modelo" 1 unreachable
setprobe "$P_OK" 0; age checked -1000; g "volta a medir logo, sem esperar a janela de retry" 0 ok
reset; g . 0 ok
has "sonda não carrega o settings do usuário" "$(cat "$FAKE/probe.args")" "--setting-sources local"
has "sonda não grava transcrição" "$(cat "$FAKE/probe.args")" "--no-session-persistence"
reset; g . 0 ok; age checked -1000; age probe -5000; g . 0 ok; eq "2 chamadas" "$(calls probe)" 2
eq "a sonda roda sempre na mesma pasta (o claude cria um projeto por pasta: mktemp deixaria um novo por hora)" "$(sort -u "$FAKE/probe.pwd" | wc -l | tr -d ' ')" 1
eq "e é a pasta fixa" "$(sort -u "$FAKE/probe.pwd")" "$SRV/gt-remote/probe"

echo "== status"
reset; out=$(python3 -I "$S" status); eq "status ok" $? 0; has "json" "$out" '"state": "ok"'
reset; python3 -I "$S" status >/dev/null; python3 -I "$S" status --probe >/dev/null; eq "--probe força a chamada" "$(calls probe)" 2
reset; setauth "$AUTH_OFF" 1; out=$(python3 -I "$S" status); eq "status bloqueado sai 1" $? 1; has "estado" "$out" "logged-out"

echo "== aviso"
reset; setauth "$AUTH_OFF" 1; g . 1 logged-out; eq "primeiro estado deslogado não avisa" "$(notifys)" 0
reset; g . 0 ok; setauth "$AUTH_OFF" 1; age checked -1000; g . 1 logged-out; eq "ok -> logged-out avisa" "$(notifys)" 1
age checked -1000; g . 1 logged-out; eq "não repete" "$(notifys)" 1
reset; g . 0 ok; setprobe "$P_QUOTA" 1; age checked -1000; age probe -5000; g . 1 quota; eq "cota não avisa" "$(notifys)" 0
reset; g . 0 ok; setprobe "$P_LOGOUT" 1; age checked -1000; age probe -5000; g . 1 expired; eq "ok -> expired avisa" "$(notifys)" 1
reset; g . 0 ok; echo 255 >"$FAKE/ssh.rc"; age checked -1000; g . 1 unreachable; rm -f "$FAKE/ssh.rc"; setauth "$AUTH_OFF" 1; age checked -1000; g . 1 logged-out
eq "ok -> (ssh fora) -> logged-out avisa: 'não consegui saber' não apaga o ok que se sabia" "$(notifys)" 1
age checked -1000; g . 1 logged-out; eq "e não repete" "$(notifys)" 1
reset; g . 0 ok; echo 255 >"$FAKE/ssh.rc"; age checked -1000; g . 1 unreachable; rm -f "$FAKE/ssh.rc"; age checked -1000; g "ssh volta, login igual" 0 ok; eq "ok -> (ssh fora) -> ok não avisa" "$(notifys)" 0

echo "== bandeira, identidade, lock, erro interno"
reset; g . 0 ok; : >"$STATE/hetzner-claude.off"; g "bandeira .off segura mesmo com ok" 1 "bandeira"
reset; setauth '{"loggedIn":true,"authMethod":"claude.ai","email":"fulano@example.com","orgId":"org-123"}' 0; g . 0 ok
if grep -q "fulano\|org-123" "$SF"; then bad "estado guarda identidade"; else ok; fi
reset; g . 0 ok; age checked -1000
python3 -I -c 'import fcntl,sys,time; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(4)' "$STATE/hetzner-claude.lock" & lp=$!
sleep 0.5; export HETZNER_LOCK_WAIT=1; g "vencido + lock ocupado = bloqueado" 1 "outro processo"; unset HETZNER_LOCK_WAIT; wait $lp
eq "sem ssh novo" "$(calls auth)" 1
reset; : >"$T/afile"; export HETZNER_STATE_DIR=$T/afile; g "pasta de estado inutilizável (falha na trava, ANTES de medir) nunca é ok" 1 "erro interno"; eq "e nem mediu" "$(calls auth)" 0; export HETZNER_STATE_DIR=$T/state
# gravação que falha DEPOIS de medir (o caso acima falha na trava e não chega em write_state)
reset; mkdir "$SF"; g "gravação impossível (o arquivo de estado é uma pasta) nunca é ok" 1 "erro interno"; eq "mediu: a falha é na gravação, não na trava" "$(calls auth)" 1
eq "e não deixou .tmp para trás" "$(ls "$STATE" | grep -c '\.tmp$')" 0; rmdir "$SF"
# o aviso não pode depender de uma gravação que pode falhar: gravação falhando = nenhum aviso; ele sai na 1ª chamada que gravar
if [ "$(id -u)" = 0 ]; then echo "SKIP (root ignora chmod): aviso com a gravação falhando"; else
  reset; g . 0 ok; setauth "$AUTH_OFF" 1; age checked -1000; chmod 555 "$STATE"
  g "gravação falha: bloqueia" 1 "erro interno"; g "de novo" 1 "erro interno"; g "e de novo" 1 "erro interno"; chmod 755 "$STATE"
  eq "3 chamadas com a gravação falhando = 0 avisos" "$(notifys)" 0
  hasnt "nem linha de transição no log" "$(cat "$STATE/hetzner-claude.log" 2>/dev/null)" "ok -> logged-out"
  g "a gravação volta" 1 logged-out; eq "o aviso sai na primeira chamada que gravou" "$(notifys)" 1
fi
# quem esperou a trava herda a medida de quem a tinha, em vez de repetir o ssh
reset; g . 0 ok; setauth "$AUTH_OFF" 1; age checked -1000
python3 -I -c 'import fcntl,json,sys,time
f=open(sys.argv[1]+"/hetzner-claude.lock","a"); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(1.5)
json.dump({"state":"ok","reason":"","checked_at":time.time()},open(sys.argv[1]+"/hetzner-claude.state.json","w"))' "$STATE" & lp=$!
sleep 0.5; export HETZNER_LOCK_WAIT=6; g "vencido + lock ocupado + estado renovado por quem o tinha: usa o dele" 0 ok; unset HETZNER_LOCK_WAIT; wait $lp
eq "sem ssh novo" "$(calls auth)" 1
# o ssh não herda o stdin do chamador (um `while read` do provider perderia as linhas que sobram)
reset; : >"$FAKE/ssh.stdin.on"; printf 'a\nb\n' | python3 -I "$S" gate >/dev/null
eq "o ssh foi chamado" "$([ -s "$FAKE/ssh.stdin" ] && echo sim || echo nao)" sim
eq "e recebeu 0 bytes do stdin do chamador" "$(awk '{s+=$1} END{print s+0}' "$FAKE/ssh.stdin")" 0
HETZNER_STATE_TTL=abc python3 -I "$S" gate >/dev/null 2>&1; eq "TTL inválido" $? 2
HETZNER_REMOTE_HOME=/home python3 -I "$S" gate >/dev/null 2>&1; eq "HOME remoto raso demais" $? 2


echo "== canary"
reset; out=$(python3 -I "$S" canary); eq "canary ok" $? 0; has "usa o settings do city" "$(cat "$FAKE/probe.args")" "--settings $RROOT/city/settings.json"
has "como o provider" "$(cat "$FAKE/probe.args")" "--dangerously-skip-permissions"
has "mas sem ferramenta nenhuma (--tools com argumento vazio; revisão de segurança 14/10)" "$(cat "$FAKE/probe.argv")" "<--tools><>"
reset; g . 0 ok; hasnt "a sonda não usa --dangerously-skip-permissions" "$(cat "$FAKE/probe.args")" "--dangerously-skip-permissions"
reset; setprobe "$P_LOGOUT" 1; out=$(python3 -I "$S" canary); eq "canary deslogado" $? 1; has "msg" "$out" "expired"

echo "== fingerprint"
echo '{"oauthAccount":{"uuid":"u1"}}' >"$HOME/.claude.json"; reset; echo 20261014162918Z >"$FAKE/mdat"
python3 -I "$S" fingerprint --save "$T/fp" >/dev/null; python3 -I "$S" fingerprint --compare "$T/fp" >/dev/null; eq "igual" $? 0
echo '{"oauthAccount":{"uuid":"u2"}}' >"$HOME/.claude.json"; python3 -I "$S" fingerprint --compare "$T/fp" >/dev/null; eq "oauthAccount mudou" $? 1
echo '{"oauthAccount":{"uuid":"u1"}}' >"$HOME/.claude.json"
if [ "$(uname)" = Darwin ]; then
  echo 20261014170000Z >"$FAKE/mdat"; out=$(python3 -I "$S" fingerprint --compare "$T/fp"); eq "mdat mudou sozinho: não decide" $? 0; has "diz que só informa" "$out" "não decide"
  rm -f "$FAKE/mdat"; out=$(python3 -I "$S" fingerprint --compare "$T/fp"); eq "keychain ilegível: não decide" $? 0
  if grep -qE -- ' -[gw]( |$)' "$FAKE/security.args"; then bad "pediu o segredo ao Keychain (-g/-w)"; else ok; fi
else echo "SKIP (só o macOS tem Keychain): mdat que anda sozinho, keychain ilegível, nunca pedir o segredo (-g/-w)"; fi
echo '{bad' >"$HOME/.claude.json"; out=$(python3 -I "$S" fingerprint --compare "$T/fp"); eq "oauthAccount ilegível não é igual" $? 3; has "msg" "$out" "NÃO SEI"
python3 -I "$S" fingerprint --save "$T/fp2" >/dev/null 2>&1; eq "não grava um 'antes' desconhecido" $? 3
eq "e não deixa arquivo" "$([ -e "$T/fp2" ] && echo existe || echo nao)" nao
echo '{"oauthAccount_sha256_16":"unknown","keychain_mdat":"n/a"}' >"$T/fp2"; python3 -I "$S" fingerprint --compare "$T/fp2" >/dev/null; eq "desconhecido antes e depois não é igual" $? 3
echo '{"oauthAccount":{"uuid":"u1"}}' >"$HOME/.claude.json"
python3 -I "$S" fingerprint --compare "$T/nao-existe" >/dev/null 2>&1; eq "arquivo de comparação ausente" $? 3
echo '[1,2]' >"$T/fpl"; python3 -I "$S" fingerprint --compare "$T/fpl" >/dev/null 2>&1; eq "'antes' que é JSON mas não é objeto: 3, não o 1 de MUDOU" $? 3
python3 -I "$S" fingerprint --save "$T/nao/existe/fp" >/dev/null 2>&1; eq "gravar o 'antes' onde não dá: 3, não o 1 de MUDOU" $? 3

echo "== leak-scan: o que não foi lido nunca parece limpo"
mkdir -p "$T/scan/a" "$T/scan/clean" "$T/scan/empty" "$T/scan/lock" "$T/scan/link"; echo x >"$T/scan/lock/f"
printf 'x sk-ant-api03-%s y\n' "$(printf 'Z%.0s' $(seq 30))" >"$T/scan/a/f.txt"; echo hello >"$T/scan/clean/g.txt"; ln -s "$T/scan/a/f.txt" "$T/scan/link/l"
out=$(python3 -I "$S" leak-scan "$T/scan/a"); eq "acha token" $? 1; has "mostra o arquivo" "$out" "f.txt"; hasnt "NÃO mostra o texto achado" "$out" "ZZZZZZZZ"
echo '{"accessToken":"AAAAAAAAAAAAAAAAAAAAAA"}' >"$T/scan/a/c.json"; out=$(python3 -I "$S" leak-scan "$T/scan/a/c.json"); eq "acha accessToken" $? 1
python3 -I "$S" leak-scan "$T/scan/clean" >/dev/null; eq "limpo" $? 0
python3 -I "$S" leak-scan "$T/scan/empty" >/dev/null; eq "pasta vazia não é 'limpo'" $? 3
python3 -I "$S" leak-scan "$T/scan/clean" "$T/scan/empty" >/dev/null; eq "pasta vazia entre raízes com arquivo não é 'limpo'" $? 3
python3 -I "$S" leak-scan "$T/scan/nao-existe" >/dev/null 2>&1; eq "raiz inexistente não é 'limpo'" $? 3
out=$(python3 -I "$S" leak-scan "$T/scan/link"); eq "symlink para arquivo FORA do que foi varrido: não seguido não é 'limpo'" $? 3; has "conta o symlink" "$out" "1 symlinks"; has "diz que não leu" "$out" "NÃO CONSEGUI LER"
python3 -I "$S" leak-scan "$T/scan/link/l" >/dev/null; eq "arquivo dado na linha de comando é lido mesmo sendo symlink" $? 1
mkdir -p "$T/scan/dl/sub" "$T/scan/dl/real" "$T/scan/cov/real" "$T/scan/cov/sub" "$T/scan/fifo"
echo ok >"$T/scan/dl/sub/ok.txt"; printf 'sk-ant-api03-%s\n' "$(printf 'Z%.0s' $(seq 30))" >"$T/scan/dl/real/leak.txt"; ln -s ../real "$T/scan/dl/sub/dirlink"
out=$(python3 -I "$S" leak-scan "$T/scan/dl/sub"); eq "symlink para PASTA com token, fora da raiz: não é 'limpo' (revisão do gate, 15/10)" $? 3; has "diz qual" "$out" "dirlink"; has "e a contagem de symlinks é verdadeira" "$out" "1 symlinks"
python3 -I "$S" leak-scan "$T/scan/dl/real" >/dev/null; eq "controle: a mesma pasta varrida direto acha o token" $? 1
echo ok >"$T/scan/cov/real/g.txt"; ln -s ../real "$T/scan/cov/sub/dirlink"
out=$(python3 -I "$S" leak-scan "$T/scan/cov"); eq "symlink cujo alvo está dentro da raiz varrida já foi lido pelo walk: limpo" $? 0; has "mas conta" "$out" "1 symlinks"
mkfifo "$T/scan/fifo/p"; echo hi >"$T/scan/fifo/f"
hang() { python3 -I -c 'import subprocess,sys
try: r = subprocess.run(sys.argv[1:], capture_output=True, timeout=10, text=True)
except subprocess.TimeoutExpired: print("PENDUROU"); sys.exit(124)
print(r.stdout, end=""); sys.exit(r.returncode)' "$@"; }
out=$(hang python3 -I "$S" leak-scan "$T/scan/fifo"); eq "FIFO na árvore não pendura e não conta como lido" $? 3; has "diz o motivo" "$out" "não é arquivo comum"
chmod 000 "$T/scan/lock"; out=$(python3 -I "$S" leak-scan "$T/scan/lock"); eq "pasta ilegível não é 'limpo'" $? 3; has "msg" "$out" "NÃO CONSEGUI LER"; chmod 755 "$T/scan/lock"
echo "hetzner-claude.selftest: $pass ok, $fail falhas"
[ "$fail" = 0 ]
