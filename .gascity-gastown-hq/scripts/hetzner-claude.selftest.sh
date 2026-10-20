#!/bin/bash
# hetzner-claude.selftest.sh — hermético e em LOOPBACK: o "servidor" é uma pasta (mktemp) e o ssh falso roda o comando DE VERDADE nela,
# com HOME apontando para lá; o shell, o python e o rsync do caminho de instalação EXECUTAM no teste (o rascunho anterior casava o
# TEXTO do comando e nunca rodava a conferência). O claude do servidor é falso (lê arquivos em $FAKE). Nada toca a rede, o servidor
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
  HETZNER_REMOTE_ROOT=$SRV/gt-remote/bundle HETZNER_BUILDER=$T/builder.py PATH="$T/bin:$PATH"
STATE=$T/state; SF=$STATE/hetzner-claude.state.json; RROOT=$HETZNER_REMOTE_ROOT
cat >"$T/bin/ssh" <<'EOF'
#!/bin/sh
[ -f "$FAKE/ssh.stdin.on" ] && wc -c >>"$FAKE/ssh.stdin"
[ -f "$FAKE/ssh.argv.on" ] && printf '%s\n' "$*" >>"$FAKE/ssh.argv"
[ -f "$FAKE/sleep" ] && sleep "$(cat "$FAKE/sleep")"
if [ -f "$FAKE/ssh.rc" ]; then  # ssh.rc.only (opcional): só falha o comando que contém este texto; sem ele, falha todos
  if [ ! -f "$FAKE/ssh.rc.only" ] || case "$*" in *"$(cat "$FAKE/ssh.rc.only")"*) true;; *) false;; esac; then
    echo "ssh: Could not resolve hostname" >&2; exit "$(cat "$FAKE/ssh.rc")"
  fi
fi
while [ "$1" = "-o" ]; do shift 2; done
shift
HOME=$SRV exec sh -c "$*"
EOF
cat >"$T/bin/rsync" <<'EOF'
#!/bin/sh
case "$(cat "$FAKE/rsync.mode" 2>/dev/null)" in
  fail) echo "rsync: connection unexpectedly closed" >&2; exit 23;;
  noop) exit 0;;
  corrupt) /usr/bin/rsync "$@" || exit $?
           for last; do :; done; d=${last#*:}
           f=$(find "$d" -type f -name a.sh | head -1); [ -n "$f" ] && printf 'X' >>"$f"; exit 0;;
esac
exec /usr/bin/rsync "$@"
EOF
printf '#!/bin/sh\necho "$*" >>"$FAKE/notify.log"\n' >"$T/bin/notify"
printf '#!/bin/sh\n[ "$1" = "--version" ] && { echo "2.1.300 (Claude Code)"; exit 0; }\nexit 99\n' >"$T/bin/claude"
printf '#!/bin/sh\necho "$*" >>"$FAKE/security.args"\n[ -f "$FAKE/mdat" ] || exit 44\nprintf "    \\"mdat\\"<timedate>=0x00  \\"%%s\\\\000\\"\\n" "$(cat "$FAKE/mdat")"\n' >"$T/bin/security"
cat >"$SRV/.local/bin/claude" <<'EOF'
#!/bin/bash
F=$FAKE
rd() { cat "$F/$1" 2>/dev/null; }
case "$1 $2 $3" in
  "auth status "*) echo auth >>"$F/calls"; echo "auth:${CLAUDE_CODE_OAUTH_TOKEN-UNSET}" >>"$F/env.seen"
    # MEDIDO 21/10 com chave FALSA (claude 2.1.302): com CLAUDE_CODE_OAUTH_TOKEN o auth status diz loggedIn true e authMethod oauth_token, mesmo com outro login guardado; auth.ignores.env simula um claude que ignora a env
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -f "$F/auth.ignores.env" ]; then echo '{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}'; exit 0; fi
    rd auth.out; exit "$(rd auth.rc)";;
  "plugin marketplace list") rd mk.out; exit 0;;
  "plugin marketplace add") echo "$4" >>"$F/mk.added"; [ -f "$F/mk.addfail" ] && exit 1; echo '[{"name":"claude-plugins-official"}]' >"$F/mk.out"; exit 0;;
  "plugin install "*) grep -qx -- "$3" "$F/failinstall" 2>/dev/null && exit 1; echo "$3" >>"$F/installed.ids"; exit 0;;
  "plugin list --json") if [ -f "$F/list.garble" ] && [ -f "$F/installed.ids" ]; then echo garbage; exit 0; fi  # só a leitura DEPOIS de instalar
    python3 -I - "$F" <<'PY'
import json, os, sys
f = sys.argv[1]
ids = [l.strip() for l in open(f + "/installed.ids")] if os.path.exists(f + "/installed.ids") else []
off = [l.strip() for l in open(f + "/disabled")] if os.path.exists(f + "/disabled") else []
print(json.dumps([{"id": i, "version": "1", "enabled": i not in off} for i in ids]))
PY
    exit 0;;
esac
case "$1" in
  -p) echo probe >>"$F/calls"; echo "$*" >>"$F/probe.args"; { printf '<%s>' "$@"; echo; } >>"$F/probe.argv"; pwd >>"$F/probe.pwd"; echo "probe:${CLAUDE_CODE_OAUTH_TOKEN-UNSET}" >>"$F/env.seen"
     k=${CLAUDE_CODE_OAUTH_TOKEN:-}; if [ -n "$k" ] && [ -f "$F/probe.out.$k" ]; then rd "probe.out.$k"; exit "$(rd "probe.rc.$k")"; fi  # resposta POR CHAVE: cada conta do pool tem a sua cota
     rd probe.out; exit "$(rd probe.rc)";;
  --version) if [ -f "$F/version" ]; then cat "$F/version"; exit 0; fi; echo "claude: not found" >&2; exit 127;;
esac
exit 98
EOF
cat >"$T/builder.py" <<'EOF'
import hashlib, json, os, shutil, sys
F, a = os.environ["FAKE"], sys.argv
def rd(n, d=None):
    try:
        return open(F + "/" + n).read().strip()
    except OSError:
        return d
def sha(b):
    return hashlib.sha256(b).hexdigest()
def bh(files):
    return sha(json.dumps(files, sort_keys=True).encode())
if a[1] == "verify":
    side = "server" if os.environ.get("HOME", "").startswith(os.environ["SRV"]) else "mini"
    forced = rd("verify.rc." + side)
    if forced:
        sys.exit(int(forced))
    d = a[2]
    m = json.load(open(d + "/manifest.json"))
    for rel, info in m["files"].items():
        if sha(open(d + "/" + rel, "rb").read()) != info["sha256"]:
            print("diferente:", rel)
            sys.exit(4)
    sys.exit(0 if m.get("bundle_hash") == bh(m["files"]) else 4)
out = a[a.index("--out") + 1]
content = {"city/settings.json": ('{"city": 1}', False), "home/.claude/settings.json": (rd("home_settings", '{"permissions": {}}'), False),
           "home/.claude/hooks/a.sh": ("#!/bin/sh\n", True), "role/dog/.claude/settings.json": ("{}", False)}
if rd("drop_hook"):
    content.pop("home/.claude/hooks/a.sh")
for extra in (rd("extra_file", "") or "").split():
    content[extra] = ("x", False)
if os.path.isdir(out):
    shutil.rmtree(out)
files = {}
for rel, (txt, ex) in content.items():
    p = out + "/" + rel
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(txt)
    os.chmod(p, 0o755 if ex else 0o644)
    files[rel] = {"sha256": sha(txt.encode()), "exec": ex}
if rd("bad_dest"):  # entrada só no manifesto (sem arquivo): só passa se o verify for forçado a passar
    files[rd("bad_dest")] = {"sha256": sha(b""), "exec": False}
json.dump({"version": 1, "bundle_hash": bh(files), "files": files}, open(out + "/manifest.json", "w"))
EOF
chmod +x "$T/bin/"* "$SRV/.local/bin/claude"
pass=0; fail=0; skip=0
ok() { pass=$((pass + 1)); }
skipped() { skip=$((skip + 1)); echo "SKIP: $1"; }  # caso que não pôde rodar aqui: aparece e conta à parte, nunca como ok
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -z "${HZC_FAILFAST:-}" ] || exit 1; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1 (obtido '$2', esperado '$3')"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok; else bad "$1 (não achei '$3' em: $2)"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (achei '$3')"; else ok; fi; }
yes() { if [ -e "$2" ]; then ok; else bad "$1 (não existe: $2)"; fi; }
no() { if [ -e "$2" ] || [ -L "$2" ]; then bad "$1 (existe: $2)"; else ok; fi; }
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

echo "== conta do pool do mini (ga-2hd02v.7.1): a sonda usa a MESMA chave que a sessão do nó, e o veredito é POR CONTA"
KA=sk-ant-FAKEalfa-0123456789abcdef; KB=sk-ant-FAKEbeta-0123456789abcdef; mkdir -p "$T/vault"; : >"$T/secret.log"
printf '%s\n' "$KA" >"$T/vault/claude-oauth-token-alfa@example.test"; printf '%s\n' "$KB" >"$T/vault/claude-oauth-token-beta@example.test"
cat >"$T/bin/secret" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_SECRET_LOG:-/dev/null}"
case "${FAKE_SECRET_MODE:-}" in
  locked) echo "sk-ant-DECOYOUT0000000000000000"; echo "vault is locked" >&2; exit 1;;
  notfound) echo "Not found: $1" >&2; exit 4;;
esac
[ -f "$FAKE_VAULT/$1" ] || { echo "Not found: $1" >&2; exit 4; }
cat "$FAKE_VAULT/$1"
EOF
chmod +x "$T/bin/secret"
export FAKE_VAULT=$T/vault FAKE_SECRET_LOG=$T/secret.log HETZNER_SESSION_SSH=$HERE/gc-session-ssh
setpool() { printf '{"current":"%s","since":"2026-10-20T20:00:00Z","reason":"selftest"}\n' "$1" >"$T/pool.json"; }
cfgprov() { printf '{"default_host":"a","hosts":{"a":{"ssh":"hetzner-teste","cap":2,"remote_root":"%s","remote_home":"%s"%s}}}\n' "$RROOT" "$SRV" "$1" >"$2"; }
cfgprov ",\"claude_account\":{\"current_file\":\"$T/pool.json\",\"secret\":\"$T/bin/secret\"}" "$T/session-ssh.json"
seen() { sort -u "$FAKE/env.seen" 2>/dev/null | tr '\n' ' '; }
nocalls() { eq "$1" "$(calls auth)$(calls probe)" 00; }
export GC_SSH_CONFIG=$T/session-ssh.json
reset; setpool alfa@example.test; : >"$T/secret.log"; : >"$FAKE/ssh.argv.on"
g "host que segue o pool: ok com a chave da conta atual" 0 ok
eq "o claude do nó recebeu a chave de alfa (login e chamada de modelo)" "$(seen)" "auth:$KA probe:$KA "
has "o estado diz de qual conta é a medida" "$(cat "$SF")" '"account": "alfa@example.test"'
if grep -rqF -- "$KA" "$STATE" "$FAKE/ssh.argv" || printf '%s' "$GOUT" | grep -qF -- "$KA"; then bad "a chave apareceu no argv do ssh, no estado, no log ou na saída do gate"; else ok; fi
printf '%s' "$KA" >"$STATE/controle"; if grep -rqF -- "$KA" "$STATE"; then ok; else bad "controle positivo da varredura de vazamento"; fi; rm -f "$STATE/controle"
reset; setpool alfa@example.test; : >"$T/secret.log"; g . 0 ok; g "mesma conta dentro do TTL usa o cache" 0 ok
eq "o cofre foi lido UMA vez (só quem mede pergunta a ele)" "$(grep -c . "$T/secret.log")" 1
reset; setpool alfa@example.test; printf '%s' "$P_QUOTA" >"$FAKE/probe.out.$KA"; echo 1 >"$FAKE/probe.rc.$KA"; printf '%s' "$P_OK" >"$FAKE/probe.out.$KB"; echo 0 >"$FAKE/probe.rc.$KB"
g "alfa sem cota: bloqueado" 1 quota; has "diz de qual conta" "$GOUT" "alfa@example.test"
setpool beta@example.test; g "o pool trocou para beta: mede beta AGORA, sem esperar o TTL nem o retry de 15 min" 0 ok
eq "e a chamada de modelo de beta usou a chave de beta" "$(grep -c "probe:$KB" "$FAKE/env.seen")" 1
setpool alfa@example.test; g "voltou a alfa: não herda o veredito de beta, mede alfa de novo" 1 quota
reset; setpool alfa@example.test; : >"$T/secret.log"; FAKE_SECRET_MODE=locked g "cofre fechado: bloqueado (unknown)" 1 unknown; nocalls "...sem falar com o claude do nó"; hasnt "...e sem repetir o que o secret escreveu" "$GOUT" DECOY
reset; setpool beta@example.test; FAKE_SECRET_MODE=notfound g "conta atual sem chave no cofre: logged-out" 1 logged-out; has "diz sem chave cadastrada" "$GOUT" "sem chave cadastrada"; nocalls "...sem falar com o claude do nó"
reset; rm -f "$T/pool.json"; : >"$T/secret.log"; g "arquivo do pool ausente: unknown" 1 unknown; has "diz que não sabe a conta atual" "$GOUT" "conta atual"; nocalls "...sem falar com o claude do nó"; eq "...e sem tocar no cofre" "$(grep -c . "$T/secret.log")" 0
reset; setpool alfa@example.test; : >"$FAKE/auth.ignores.env"; g "claude do nó que ignora a env (authMethod != oauth_token): a medida não seria da conta do pool" 1 unknown; has "diz por quê" "$GOUT" "não usou a chave do pool"
unset GC_SSH_CONFIG; reset; : >"$T/secret.log"
g "sem config do provider: como sempre (login do próprio nó)" 0 ok; eq "o claude do nó não recebeu env nenhuma" "$(seen)" "auth:UNSET probe:UNSET "; eq "e o cofre não foi tocado" "$(grep -c . "$T/secret.log")" 0
cfgprov "" "$T/session-ssh2.json"; reset; GC_SSH_CONFIG=$T/session-ssh2.json g "host da config SEM claude_account: como sempre" 0 ok; eq "...sem env" "$(seen)" "auth:UNSET probe:UNSET "
echo '{' >"$T/session-ssh3.json"; reset; GC_SSH_CONFIG=$T/session-ssh3.json g "config do provider que existe e não lê: bloqueia, não vira 'não segue'" 1 unknown; nocalls "...sem falar com o claude do nó"
printf '{"default_host":"a","hosts":{"a":{"ssh":"outro-alias","cap":2,"remote_root":"%s","remote_home":"%s","claude_account":{"current_file":"%s","secret":"%s"}}}}\n' "$RROOT" "$SRV" "$T/pool.json" "$T/bin/secret" >"$T/session-ssh4.json"
reset; setpool alfa@example.test; : >"$T/secret.log"; GC_SSH_CONFIG=$T/session-ssh4.json g "claude_account é de OUTRO host (outro alias de ssh): este nó segue como sempre" 0 ok; eq "...sem env" "$(seen)" "auth:UNSET probe:UNSET "; eq "...e sem tocar no cofre" "$(grep -c . "$T/secret.log")" 0
reset; setpool alfa@example.test; HETZNER_SESSION_SSH=$T/nao-existe GC_SSH_CONFIG=$T/session-ssh.json g "provider que não carrega: bloqueia, não vira 'não segue'" 1 unknown; has "diz que não carregou" "$GOUT" "não consegui carregar o provider"; nocalls "...sem falar com o claude do nó"
mkdir -p "$T/city/.gc"; cp "$T/session-ssh.json" "$T/city/.gc/session-ssh.json"; reset; setpool alfa@example.test
g "config no caminho padrão da cidade, sem GC_SSH_CONFIG: o gate e o provider leem a MESMA" 0 ok; eq "...e segue o pool" "$(seen)" "auth:$KA probe:$KA "; rm -f "$T/city/.gc/session-ssh.json"
reset; setpool alfa@example.test; printf '{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key: %s (revoked)"}' "$KA" >"$FAKE/probe.out.$KA"; echo 1 >"$FAKE/probe.rc.$KA"
GC_SSH_CONFIG=$T/session-ssh.json g "erro de modelo que repete a chave: bloqueia (unknown)" 1 unknown; hasnt "...e o motivo não a repete" "$GOUT" "$KA"; if grep -rqF -- "$KA" "$STATE"; then bad "a chave que o servidor repetiu foi para o estado gravado"; else ok; fi
export GC_SSH_CONFIG=$T/session-ssh.json
reset; setpool alfa@example.test; g . 0 ok; age checked -1000; g "mesma conta, estado vencido, janela de 1 h aberta: não repete a chamada de modelo" 0 ok; eq "...a chamada de modelo gasta cota: foi 1 só" "$(calls probe)" 1
unset GC_SSH_CONFIG
unset FAKE_VAULT FAKE_SECRET_LOG
echo "== cota: o texto REAL do limite semanal / de sessão e o horário em que renova (ga-2hd02v.7)"
# MEDIDO 20/10: a conta do nó bateu o limite semanal e o gate dizia "blocked: unknown: erro de modelo não reconhecido: You've hit your weekly limit" (QUOTA_RE só
# conhecia "usage limit"). O texto veio da transcrição do revisor remoto (isApiErrorMessage, error rate_limit); "session limit" e o fuso com NOME são os que o mini mede
# (claude-quota-check.selftest.sh). O formato do `result` do `claude -p` para o limite NÃO foi medido aqui: assume-se o mesmo texto da tela.
P_WEEKLY="{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"You've hit your weekly limit · resets Oct 22, 4pm (UTC)\"}"
P_SESSION="{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"You've hit your session limit · resets 1:00pm (America/Sao_Paulo)\"}"
reset; setprobe "$P_WEEKLY" 1; g "MEDIDO 20/10: o limite semanal é quota, não 'unknown'" 1 "blocked: quota"; has "o texto do claude fica no motivo" "$GOUT" "resets Oct 22, 4pm (UTC)"
reset; setprobe "$P_SESSION" 1; g "o limite de sessão (5 h) também é quota" 1 "blocked: quota"
reset; setprobe "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"You've hit your Opus limit · resets 9am (UTC)\"}" 1; g "limite de modelo ('hit your Opus limit') é quota" 1 "blocked: quota"
reset; setprobe "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"Something else broke · resets soon\"}" 1; g "erro que cita 'resets' sem falar de limite continua 'unknown'" 1 "blocked: unknown"
reset; g . 0 ok; setprobe "$P_WEEKLY" 1; age checked -1000; age probe -5000; g . 1 quota; eq "o limite semanal também não avisa o celular (regra da cidade: nada de aviso de cota)" "$(notifys)" 0
# parse_reset(texto, agora) -> época do horário em que renova, ou None quando não dá para saber. O fuso entre parênteses MANDA (o mini assume São Paulo; aqui o texto diz qual é).
# vazio → sem "resets" no texto: None; falhou/ilegível → fuso ausente, inventado ou que não é nome de zona, data impossível, hora fora de 1-12: None (nunca uma hora chutada)
pr() { python3 -I - "$S" "$1" "$2" <<'PY'
import datetime as d, importlib.machinery as im, importlib.util as iu, sys
ldr = im.SourceFileLoader("hzc", sys.argv[1]); spec = iu.spec_from_loader("hzc", ldr); m = iu.module_from_spec(spec); ldr.exec_module(m)
now = int(d.datetime.strptime(sys.argv[3], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp())
r = m.parse_reset(sys.argv[2], now)
print("None" if r is None else d.datetime.fromtimestamp(r, d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}
N=2026-10-20T22:30:00Z
eq "reset: o texto MEDIDO (data + hora + UTC)" "$(pr "You've hit your weekly limit · resets Oct 22, 4pm (UTC)" $N)" 2026-10-22T16:00:00Z
eq "reset: só a hora, com fuso de nome; já passou hoje -> amanhã" "$(pr "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" $N)" 2026-10-21T16:00:00Z
eq "reset: só a hora, ainda não passou hoje -> hoje" "$(pr "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" 2026-10-20T14:00:00Z)" 2026-10-20T16:00:00Z
eq "reset: 'Jun 12 at 8pm' (formato do mini)" "$(pr "You've hit your weekly limit · resets Jun 12 at 8pm (America/Sao_Paulo)" 2026-06-10T15:00:00Z)" 2026-06-12T23:00:00Z
eq "reset: dezembro lendo janeiro -> o ano que vem" "$(pr "You've hit your weekly limit · resets Jan 3 at 8pm (America/Sao_Paulo)" 2026-12-30T12:00:00Z)" 2027-01-03T23:00:00Z
eq "reset: 12am é meia-noite" "$(pr "resets 12am (UTC)" $N)" 2026-10-21T00:00:00Z
eq "reset: 12pm é meio-dia" "$(pr "resets 12pm (UTC)" $N)" 2026-10-21T12:00:00Z
eq "reset: com minutos" "$(pr "resets 4:30pm (UTC)" $N)" 2026-10-21T16:30:00Z
eq "reset: sem fuso -> None (o fuso do cliente não é o do texto)" "$(pr "You've hit your weekly limit · resets Oct 22, 4pm" $N)" None
eq "reset: fuso inventado -> None" "$(pr "resets 4pm (Mars/Olympus)" $N)" None
eq "reset: o 'fuso' é um prazo relativo -> None" "$(pr "resets 3:00pm (in 45min)" $N)" None
eq "reset: data impossível -> None" "$(pr "resets Feb 30, 4pm (UTC)" $N)" None
eq "reset: hora fora de 1-12 -> None" "$(pr "resets 13pm (UTC)" $N)" None
eq "reset: sem a palavra resets -> None" "$(pr "You've hit your weekly limit" $N)" None
eq "reset: fuso que é caminho -> None" "$(pr "resets 4pm (../../etc/passwd)" $N)" None
# no gate de verdade: o estado guarda o horário e o gate diz quando renova (texto montado do relógio de agora, para não depender do dia em que o teste roda)
read -r RTXT RE REISO < <(python3 -I -c 'import datetime as d
t = (d.datetime.now(d.timezone.utc) + d.timedelta(days=2)).replace(hour=16, minute=0, second=0, microsecond=0)
print("%s_%d" % (["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][t.month - 1], t.day), int(t.timestamp()), t.strftime("%Y-%m-%dT%H:%M:%SZ"))')
P_FUT="{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"You've hit your weekly limit · resets ${RTXT/_/ }, 4pm (UTC)\"}"
reset; setprobe "$P_FUT" 1; g "gate: quota com horário" 1 "blocked: quota"; has "o gate diz quando renova" "$GOUT" "$REISO"
eq "o estado guarda reset_at (época)" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reset_at"))' "$SF")" "$RE"
reset; setprobe "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"You've hit your weekly limit · resets Oct 22, 4pm\"}" 1; g "sem fuso no texto: continua quota" 1 "blocked: quota"
hasnt "e não inventa um horário" "$GOUT" "renova em"; eq "nem grava reset_at" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reset_at"))' "$SF")" None
# quota com horário JÁ VENCIDO: não espera os 15 min da janela de retry, mede de novo (voltar quando a conta renovar); horário no futuro: segue a janela
setreset() { python3 -I - "$SF" "$1" <<'PY'
import json, sys, time
p, secs = sys.argv[1], float(sys.argv[2])
d = json.load(open(p)); r = int(time.time() + secs); d["reset_at"] = r; d["probe"]["reset_at"] = r
json.dump(d, open(p, "w"))
PY
}
reset; setprobe "$P_FUT" 1; g . 1 quota; setreset -10; age checked -1000; age probe -100; g "reset vencido, dentro da janela de retry: mede de novo" 1 quota; eq "2 chamadas de modelo" "$(calls probe)" 2
reset; setprobe "$P_FUT" 1; g . 1 quota; setreset 3600; age checked -1000; age probe -100; g "reset no futuro, dentro da janela: não repete" 1 quota; eq "continua 1 chamada" "$(calls probe)" 1
reset; setprobe "$P_FUT" 1; g . 1 quota; setreset -10; age checked -1000; age probe -100; setprobe "$P_OK" 0; g "renovou: volta a ok na primeira medição depois do horário" 0 ok; eq "e não guarda o horário velho" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reset_at"))' "$SF")" None

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
if [ "$(id -u)" = 0 ]; then skipped "root ignora chmod: aviso com a gravação falhando"; else
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

echo "== push-bundle (loopback: o install roda de verdade)"
HOOK=$SRV/.claude/hooks/a.sh; CITYF=$RROOT/city/settings.json
srv_reset() { case "$SRV" in */hzc-selftest.*/srv) rm -rf "$SRV/gt-remote" "$SRV/.claude" "$T/out" "$T/elsewhere";; *) echo "srv_reset recusado"; exit 2;; esac
  rm -f "$FAKE"/{drop_hook,extra_file,bad_dest,home_settings,rsync.mode,verify.rc.mini,verify.rc.server}; mkdir -p "$SRV/.claude/hooks" "$RROOT/work"
  echo '{"enabledPlugins":{"x@y":true},"extraKnownMarketplaces":{}}' >"$SRV/.claude/settings.json"; echo k >"$RROOT/work/keep.txt"; echo f >"$SRV/.claude/hooks/foreign.sh"; }
pb() { PBOUT=$(python3 -I "$S" push-bundle --role dog --role-dir "$T/role" --out "$T/out" 2>&1); PBRC=$?; }
reset; srv_reset; pb; eq "caminho feliz" $PBRC 0; has "msg" "$PBOUT" "no servidor"
yes "hook instalado" "$HOOK"; [ -x "$HOOK" ] && ok || bad "hook sem bit de execução"
[ -x "$SRV/.claude/settings.json" ] && bad "settings.json executável" || ok
yes "city/settings.json no RROOT" "$CITYF"
yes "role fica em bundle-out" "$SRV/gt-remote/bundle-out/role/dog/.claude/settings.json"; no "role não vai ao RROOT" "$RROOT/role"
yes "arquivo alheio no RROOT sobrevive" "$RROOT/work/keep.txt"; yes "hook alheio sobrevive" "$SRV/.claude/hooks/foreign.sh"
SJ=$(cat "$SRV/.claude/settings.json"); has "settings tem a chave do bundle" "$SJ" '"permissions"'; has "plugin no settings" "$SJ" "superpowers@claude-plugins-official"
hasnt "github fora" "$SJ" "github@"; hasnt "playwright fora" "$SJ" "playwright"; hasnt "a chave velha do servidor foi trocada pelas do bundle" "$SJ" "x@y"
eq "settings instalado = o mesclado enviado" "$(cmp -s "$SRV/.claude/settings.json" "$SRV/gt-remote/home-settings.merged.json" && echo sim)" sim
echo "== push-bundle: atualização que tira um hook"
echo 1 >"$FAKE/drop_hook"; pb; eq "2º push" $PBRC 0; has "conta o removido" "$PBOUT" "1 removidos"
no "hook que o bundle tirou sumiu" "$HOOK"; yes "hook alheio continua" "$SRV/.claude/hooks/foreign.sh"; yes "work continua" "$RROOT/work/keep.txt"
yes "settings do bundle continua" "$SRV/.claude/settings.json"; yes "city continua" "$CITYF"
echo "== push-bundle: registro anterior ilegível = não remove nada"
srv_reset; pb; echo garbage >"$SRV/gt-remote/bundle-installed.json"; echo 1 >"$FAKE/drop_hook"; pb; eq "push" $PBRC 0; has "avisa" "$PBOUT" "nada removido"; yes "hook fica" "$HOOK"
echo "== push-bundle: o registro anterior não manda apagar fora das raízes"
srv_reset; pb; echo keep >"$T/outside.txt"
python3 -I -c 'import json,sys; json.dump(json.load(open(sys.argv[1])) + [sys.argv[2]], open(sys.argv[1], "w"))' "$SRV/gt-remote/bundle-installed.json" "$T/outside.txt"
echo 1 >"$FAKE/drop_hook"; pb; eq "push" $PBRC 0; yes "arquivo fora das raízes sobrevive" "$T/outside.txt"; no "e o hook que o bundle tirou sumiu" "$HOOK"
has "o que ficou sem remover é contado, não calado" "$PBOUT" "1 NAO removidos"
echo "== push-bundle: o registro anterior não manda apagar através de um symlink no caminho"
srv_reset; pb; rm -rf "$SRV/.claude/hooks"; mkdir -p "$T/elsewhere"; echo keep >"$T/elsewhere/a.sh"; ln -s "$T/elsewhere" "$SRV/.claude/hooks"
echo 1 >"$FAKE/drop_hook"; pb; eq "push" $PBRC 0; yes "o arquivo do outro lado do symlink sobrevive" "$T/elsewhere/a.sh"; has "e é contado" "$PBOUT" "1 NAO removidos"
echo "== push-bundle: as chaves que o próprio claude grava (tema, notificação) sobrevivem; chave alheia de verdade continua recusando"
srv_reset; echo '{"theme":"dark","agentPushNotifEnabled":true,"enabledPlugins":{"x@y":true}}' >"$SRV/.claude/settings.json"; pb; eq "tema e notificação do claude não travam o push" $PBRC 0
SJ=$(cat "$SRV/.claude/settings.json"); has "tema mantido" "$SJ" '"theme": "dark"'; has "notificação mantida" "$SJ" '"agentPushNotifEnabled": true'
has "o bundle continua mandando" "$SJ" '"permissions"'; hasnt "e a chave velha dos plugins foi trocada" "$SJ" "x@y"
srv_reset; echo '{"theme":"dark","model":"opus"}' >"$SRV/.claude/settings.json"; pb; eq "tema + chave alheia de verdade" $PBRC 1; has "msg diz a alheia" "$PBOUT" "(model)"; no "nada instalado" "$HOOK"
echo "== push-bundle: recusas (nada pela metade)"
srv_reset; echo '{"model":"opus"}' >"$SRV/.claude/settings.json"; pb; eq "settings do servidor com chave alheia" $PBRC 1; has "msg" "$PBOUT" "nao conhece"
no "nada instalado" "$HOOK"; no "nem o city" "$CITYF"
srv_reset; rm -rf "$SRV/.claude/hooks"; mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$SRV/.claude/hooks"; pb; eq "hooks é symlink" $PBRC 1; has "msg" "$PBOUT" "symlink no destino"
no "nada no destino do link" "$T/elsewhere/a.sh"; no "city não foi escrito antes da recusa" "$CITYF"
srv_reset; echo other/x >"$FAKE/extra_file"; pb; eq "camada desconhecida" $PBRC 1; has "msg" "$PBOUT" "camada desconhecida"; no "nada instalado" "$HOOK"
srv_reset; echo "home/.claude/../evil" >"$FAKE/extra_file"; pb; eq "caminho com .." $PBRC 1; has "msg" "$PBOUT" "com .."; no "nada instalado" "$HOOK"
srv_reset; echo "home/.claude/" >"$FAKE/bad_dest"; echo 0 >"$FAKE/verify.rc.mini"; echo 0 >"$FAKE/verify.rc.server"; pb
eq "destino fora das raízes, mesmo com o verify forçado a passar (o verify é guarda de deriva, não de adversário)" $PBRC 1; has "msg" "$PBOUT" "destino fora das raizes"; no "nada instalado" "$HOOK"; no "nem o city" "$CITYF"
srv_reset; echo corrupt >"$FAKE/rsync.mode"; pb; eq "bundle corrompido na viagem" $PBRC 1; has "msg" "$PBOUT" "verify NO SERVIDOR"; no "nada instalado" "$HOOK"
srv_reset; pb; echo '{"permissions":{"x":1}}' >"$FAKE/home_settings"; echo noop >"$FAKE/rsync.mode"; pb
eq "stage velho e coerente, hash diferente" $PBRC 1; has "msg" "$PBOUT" "bundle_hash do servidor"
srv_reset; echo fail >"$FAKE/rsync.mode"; pb; eq "rsync falha" $PBRC 1; has "msg" "$PBOUT" "rsync do bundle"
srv_reset; echo 4 >"$FAKE/verify.rc.mini"; pb; eq "verify no mini falha" $PBRC 1; has "msg" "$PBOUT" "verify (mini)"; no "nada foi staged no servidor" "$SRV/gt-remote/bundle-out"
srv_reset; echo 4 >"$FAKE/verify.rc.server"; pb; eq "verify no servidor falha" $PBRC 1; has "msg" "$PBOUT" "verify NO SERVIDOR"; no "nada instalado" "$HOOK"
srv_reset; echo '{"enabledPlugins":{}}' >"$FAKE/home_settings"; pb; eq "bundle já traz enabledPlugins" $PBRC 3; has "msg" "$PBOUT" "já traz"
echo "== push-bundle: ler o settings do servidor — ausente é vazio; não conseguir ler NÃO é vazio (gate ga-iczduy)"
# o install troca o settings.json do servidor: se a leitura falhou e o push seguir como se o arquivo não existisse, o tema/notificação do claude somem sem aviso
for rc in 255 1 7; do
  reset; srv_reset; echo '{"theme":"dark","enabledPlugins":{"x@y":true}}' >"$SRV/.claude/settings.json"; echo "$rc" >"$FAKE/ssh.rc"; echo ".claude/settings.json" >"$FAKE/ssh.rc.only"; pb
  eq "leitura do settings do servidor sai $rc → recusa" $PBRC 1; has "msg diz que não leu" "$PBOUT" "settings.json do servidor"; no "nada instalado" "$HOOK"
  eq "e o settings do servidor ficou como estava" "$(cat "$SRV/.claude/settings.json")" '{"theme":"dark","enabledPlugins":{"x@y":true}}'
done
reset; srv_reset; chmod 000 "$SRV/.claude/settings.json"
if [ -r "$SRV/.claude/settings.json" ]; then skipped "chmod 000 não tirou a leitura (root?): settings ilegível no servidor"; else  # o instalador do servidor também recusa um settings ilegível — só que DEPOIS do rsync; aqui a recusa tem que vir antes de mandar qualquer coisa
  pb; eq "settings que existe mas o cat não lê → recusa (não é 'ausente')" $PBRC 1; has "msg" "$PBOUT" "settings.json do servidor"; no "nada instalado" "$HOOK"
  no "e nada foi mandado ao servidor (a recusa vem antes do rsync)" "$SRV/gt-remote/bundle-out"
fi
chmod 644 "$SRV/.claude/settings.json"
reset; srv_reset; rm -f "$SRV/.claude/settings.json"; pb; eq "settings ausente no servidor (1º push) = vazio, instala" $PBRC 0; yes "hook instalado" "$HOOK"
# gate-fix 4 (third-state): texto que não é JSON não é "vazio" — nem no servidor, nem no bundle
reset; srv_reset; printf 'notjson garbage {' >"$SRV/.claude/settings.json"; pb
eq "settings do servidor existe mas não é JSON → recusa (não vira {})" $PBRC 1; has "msg" "$PBOUT" "não é JSON"; no "nada instalado" "$HOOK"
eq "e o settings do servidor ficou como estava" "$(cat "$SRV/.claude/settings.json")" 'notjson garbage {'
reset; srv_reset; printf 'notjson garbage {' >"$FAKE/home_settings"; pb
[ "$PBRC" != 0 ]; eq "home settings do bundle não é JSON → não instala (rc=$PBRC)" $? 0; no "nada instalado" "$HOOK"

echo "== install-claude (loopback)"
printf '#!/bin/bash\necho "$@" >"$FAKE/installer.args"\n[ -f "$FAKE/installer.noop" ] || echo "$1 (Claude Code)" >"$FAKE/version"\n' >"$T/installer.sh"
SHA=$(shasum -a 256 "$T/installer.sh" | cut -d' ' -f1); export HETZNER_INSTALLER_URL=file://$T/installer.sh
ic() { ICOUT=$(python3 -I "$S" install-claude --installer-sha256 "$1" ${2:+--version "$2"} 2>&1); ICRC=$?; }
reset; echo "2.1.300 (Claude Code)" >"$FAKE/version"; ic "$SHA" 2.1.300; eq "já instalado" $ICRC 0; no "não reinstala" "$FAKE/installer.args"
reset; echo "2.1.299 (Claude Code)" >"$FAKE/version"; ic "$(printf 'c%.0s' $(seq 64))" 2.1.300; eq "hash diferente" $ICRC 3; has "msg" "$ICOUT" "mudou"; no "nada rodou" "$FAKE/installer.args"
reset; ic "$SHA" 2.1.300; eq "instala" $ICRC 0; eq "recebeu a versão" "$(cat "$FAKE/installer.args" 2>/dev/null)" "2.1.300"
reset; ic "$SHA"; eq "sem --version usa a do mini" $ICRC 0; eq "versão do mini" "$(cat "$FAKE/installer.args" 2>/dev/null)" "2.1.300"
reset; echo "2.1.299 (Claude Code)" >"$FAKE/version"; : >"$FAKE/installer.noop"; ic "$SHA" 2.1.300; eq "versão não muda = falha" $ICRC 1; has "msg" "$ICOUT" "esperado 2.1.300"
reset; ic "$SHA" '2.1.3;x'; eq "versão inválida" $ICRC 2
reset; ic "abc" 2.1.300; eq "sha inválido" $ICRC 2
unset HETZNER_INSTALLER_URL

echo "== plugins (loopback)"
pl() { PLOUT=$(python3 -I "$S" plugins 2>&1); PLRC=$?; }
reset; echo '[]' >"$FAKE/mk.out"; pl; eq "do zero" $PLRC 0; eq "marketplace adicionado 1 vez" "$(wc -l <"$FAKE/mk.added" | tr -d ' ')" 1
eq "3 plugins" "$(wc -l <"$FAKE/installed.ids" | tr -d ' ')" 3; hasnt "sem github" "$(cat "$FAKE/installed.ids")" github; hasnt "sem playwright" "$(cat "$FAKE/installed.ids")" playwright
pl; eq "de novo" $PLRC 0; eq "não reinstala" "$(wc -l <"$FAKE/installed.ids" | tr -d ' ')" 3
reset; echo '[{"name":"claude-plugins-official"}]' >"$FAKE/mk.out"; pl; eq "marketplace presente" $PLRC 0; no "não adiciona de novo" "$FAKE/mk.added"
reset; echo garbage >"$FAKE/mk.out"; pl; eq "lista ilegível não é lista vazia" $PLRC 1; has "msg" "$PLOUT" "não consegui listar"
reset; echo '{"error":"x"}' >"$FAKE/mk.out"; pl; eq "JSON que não é lista não é lista vazia" $PLRC 1; has "msg" "$PLOUT" "não consegui listar"; no "e nada foi adicionado" "$FAKE/mk.added"
reset; echo '[]' >"$FAKE/mk.out"; echo superpowers@claude-plugins-official >"$FAKE/failinstall"; pl; eq "install falha" $PLRC 1; has "msg" "$PLOUT" "install superpowers"
reset; echo '[]' >"$FAKE/mk.out"; echo security-guidance@claude-plugins-official >"$FAKE/disabled"; pl; eq "plugin desligado" $PLRC 1; has "msg" "$PLOUT" "desligados"
reset; echo '[]' >"$FAKE/mk.out"; : >"$FAKE/mk.addfail"; pl; eq "marketplace add falha" $PLRC 1
reset; echo '[]' >"$FAKE/mk.out"; : >"$FAKE/list.garble"; pl; eq "a lista de DEPOIS de instalar ilegível" $PLRC 1; has "diz que não conseguiu reler" "$PLOUT" "não consegui reler"; hasnt "e não finge que faltam" "$PLOUT" "faltam"

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
else skipped "só o macOS tem Keychain: mdat que anda sozinho, keychain ilegível, nunca pedir o segredo (-g/-w)"; fi
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
echo "hetzner-claude.selftest: $pass ok, $fail falhas, $skip pulados"
[ "$fail" = 0 ]
