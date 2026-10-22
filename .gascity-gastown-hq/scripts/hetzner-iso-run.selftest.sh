#!/usr/bin/env bash
# hetzner-iso-run.selftest.sh — hermético: sudo e o helper de root são stubs; a sonda roda com um `socket` de mentira; nada sai para a rede (ga-9p6pte).
#
# ## Contents
#   Casos · Controles negativos · O que este teste NÃO prova
#
# CASOS: canário isolado / vazou (nao-isolado) / sem veredito / sonda com rc≠0 / sem contador / contador zerado / helper que falhou na montagem (98) / helper ausente →
#   o comando só roda quando o veredito é `isolado` e sai com o rc dele, com o ambiente certo (workers, semente de hash, PYTHONPATH do plugin) · veredito da PRÓPRIA sonda
#   (TCP, UDP, DNS, interface extra, variável com cara de segredo) com um `socket` de mentira.
# CONTROLES NEGATIVOS: mutantes W1-W6 (wrapper) e P1-P5 (sonda) têm de ser REPROVADOS pelo caso correspondente (o caso falha no mutante).
# O QUE NÃO PROVA: que o helper de root isola de verdade num kernel real. Isso só o canário prova, no nó, depois que o root instalar o helper (`gt-iso-run --canary`).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT0="$HERE/hetzner-iso-run.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/hzn-iso-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/home"; OUT="$T/out"; CALLS="$T/calls"; : > "$CALLS"
printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$T/bin/sudo"
cat > "$T/helper-stub.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -- ] && shift
case "$*" in
  */usr/bin/python3\ -I\ -c*)
    case "${PROBE_MODE:-isolated}" in
      isolated) echo "GTN-PROBE: isolated"; echo "GTN-EGRESS: attempts=${CNT:-6}" >&2; exit 0 ;;
      leak) echo "GTN-PROBE: leak tcp:1.1.1.1:53 dns"; exit 1 ;;
      garbage) echo "Traceback: boom"; exit 1 ;;
      rc3) echo "GTN-PROBE: isolated"; echo "GTN-EGRESS: attempts=6" >&2; exit 3 ;;
      nocnt) echo "GTN-PROBE: isolated"; exit 0 ;;
      setup) echo "GTN-ISO: setup-falhou:nft" >&2; exit 98 ;;
    esac ;;
  *) printf 'CMD: %s\n' "$*" >> "$CALLS"; exit "${CMD_RC:-0}" ;;
esac
EOF
cat > "$T/probe-drv.py" <<'EOF'
import os, socket, sys
mode, path = sys.argv[1], sys.argv[2]
os.environ.clear()
if mode == "env": os.environ["GITHUB_TOKEN"] = "x"
class FS:
    def __init__(self, fam=2, kind=1, *a): self.kind = kind
    def settimeout(self, t): pass
    def connect(self, addr):
        if self.kind == socket.SOCK_DGRAM or addr[0] == "127.0.0.1" or (mode == "tcp" and addr[0] == "8.8.8.8"): return
        raise OSError("bloqueado")
    def send(self, b): pass
    def recv(self, n):
        if mode == "udp": return b"x"
        raise OSError("timeout")
    def close(self): pass
    def bind(self, a): pass
    def listen(self, n): pass
    def getsockname(self): return ("127.0.0.1", 1)
socket.socket = FS
socket.create_connection = lambda a, t=None: FS()
def gai(*a, **k):
    if mode == "dns": return [1]
    raise OSError("sem dns")
socket.getaddrinfo = gai
real = os.listdir
os.listdir = lambda p: (["lo", "gtn0"] + (["eth0"] if mode == "if" else [])) if p == "/sys/class/net" else real(p)
exec(compile(open(path).read(), "probe", "exec"), {"__name__": "__main__"})
EOF
chmod +x "$T/helper-stub.sh" "$T/bin/sudo"
export PATH="$T/bin:$PATH" GT_NETNS_HELPER="$T/helper-stub.sh" CALLS HOME="$T/home"
n=0; fails=0; BAD=0; QUIET=0
ck() { local l=$1; shift; [ "$QUIET" = 1 ] || n=$((n+1)); if "$@"; then [ "$QUIET" = 1 ] || echo "ok   $l"; else [ "$QUIET" = 1 ] || { echo "FAIL $l"; fails=$((fails+1)); }; BAD=1; fi; }
rcis() { [ "$RC" = "$1" ]; }
has() { grep -q -E -- "$2" "$1"; }
hasnt() { ! grep -q -E -- "$2" "$1"; }
nocalls() { [ ! -s "$CALLS" ]; }
go() { local s=$1; shift; : > "$CALLS"; "$s" "$@" > "$OUT" 2> "$T/err"; RC=$?; }
extract() { sed -n "/^PROBE='/,/^'\$/p" "$1" | sed '1d;$d'; }

case_canary() { local m
  PROBE_MODE=isolated go "$1" --canary; ck "canário isolado: rc 0 e conta as tentativas" has "$OUT" '^GTN-ISO: isolado \(sonda barrou 6 tentativas\)$'; ck "canário isolado: rc 0" rcis 0
  PROBE_MODE=leak go "$1" --canary; ck "vazou: nao-isolado com o que vazou" has "$OUT" '^GTN-ISO: nao-isolado tcp:1.1.1.1:53 dns$'; ck "vazou: rc 97" rcis 97
  PROBE_MODE=garbage go "$1" --canary; ck "sonda quebrada: inerte sem-veredito" has "$OUT" '^GTN-ISO: inerte sem-veredito'; ck "sonda quebrada: rc 97" rcis 97
  PROBE_MODE=rc3 go "$1" --canary; ck "sonda isolated mas rc≠0: inerte" has "$OUT" '^GTN-ISO: inerte probe-rc=3'
  PROBE_MODE=nocnt go "$1" --canary; ck "sem contador: inerte" has "$OUT" '^GTN-ISO: inerte contador-ilegivel'
  CNT=0 go "$1" --canary; ck "contador zerado: inerte (a regra não viu a sonda)" has "$OUT" '^GTN-ISO: inerte contador-zerado'
  PROBE_MODE=setup go "$1" --canary; ck "helper que não montou o isolamento: inerte" has "$OUT" '^GTN-ISO: inerte sem-veredito rc=98.*setup-falhou:nft'
  GT_NETNS_HELPER="$T/nao-existe" go "$1" --canary; ck "helper ausente: inerte helper-ausente" has "$OUT" '^GTN-ISO: inerte helper-ausente'; ck "helper ausente: rc 97" rcis 97; }
case_run() { CMD_RC=5 go "$1" -- python -m pytest tests/ -n 14
  ck "isolado: o comando roda e o rc dele é o do wrapper" rcis 5; ck "isolado: ambiente do comando (workers, semente, plugin)" has "$CALLS" "^CMD: WA_PYTEST_MAX_WORKERS=14 PYTHONHASHSEED=0 PYTHONPATH=$T/home/gt-remote/bin PATH=.* python -m pytest tests/ -n 14$"
  ck "isolado: o NODE_PATH do jsdom do nó chega ao comando (ga-yoyyj1)" has "$CALLS" "^CMD: .* NODE_PATH=$T/home/.local/share/cdp-drive/node_modules python -m pytest"
  GTN_WORKERS=4 go "$1" -- true; ck "GTN_WORKERS troca o número de workers" has "$CALLS" 'WA_PYTEST_MAX_WORKERS=4 '
  PROBE_MODE=leak go "$1" -- touch /tmp/NUNCA; ck "vazou: o comando NÃO roda" nocalls; ck "vazou: rc 97" rcis 97
  CNT=0 go "$1" -- true; ck "contador zerado: o comando NÃO roda" nocalls
  GT_NETNS_HELPER="$T/nao-existe" go "$1" -- true; ck "helper ausente: o comando NÃO roda" nocalls
  go "$1"; ck "sem argumentos: rc 97 e uso" rcis 97; go "$1" --; ck "-- sem comando: rc 97" rcis 97; }
case_probe() { extract "$1" > "$T/probe.py"; local m exp
  for m in "ok:isolated" "tcp:leak tcp:8.8.8.8:443" "udp:leak udp:1.1.1.1:53" "dns:leak dns" "if:leak if:eth0" "env:leak env:GITHUB_TOKEN"; do
    python3 -I "$T/probe-drv.py" "${m%%:*}" "$T/probe.py" > "$OUT" 2>&1; RC=$?; exp=${m#*:}
    ck "sonda ($m): veredito" has "$OUT" "^GTN-PROBE: $exp"; [ "${m%%:*}" = ok ] && ck "sonda (ok): sem vazamento e rc 0" rcis 0 || ck "sonda (${m%%:*}): rc 1" rcis 1; done; }

for c in canary run probe; do "case_$c" "$SUT0"; done

M=0
mutant() { # nome expr-sed caso
  local f="$T/m-$1.sh"; sed "$2" "$SUT0" > "$f"; chmod +x "$f"; n=$((n+1)); M=$((M+1))
  if cmp -s "$SUT0" "$f"; then echo "FAIL $1: o sed não casou (mutante igual ao original)"; fails=$((fails+1)); return; fi
  bash -n "$f" 2>/dev/null && extract "$f" | python3 -c 'import sys; compile(sys.stdin.read(), "p", "exec")' 2>/dev/null || { echo "FAIL $1: mutante com erro de sintaxe (a prova seria vazia)"; fails=$((fails+1)); return; }
  BAD=0; QUIET=1; "case_$3" "$f"; QUIET=0
  if [ "$BAD" = 1 ]; then echo "ok   $1 (o caso '$3' reprova o mutante)"; else echo "FAIL $1: o caso '$3' NÃO reprovou o mutante"; fails=$((fails+1)); fi; }
mutant W1-contador-zerado-aceito 's/^  \[ "\$n" -ge 1 \] || inert.*$/  true/' canary
mutant W2-vazou-vira-inerte 's/\*"GTN-PROBE: leak"\*)/*"GTN-PROBE: nunca"*)/' canary
mutant W3-rc-da-sonda-ignorado 's/^  \[ \$rc -eq 0 \] || inert.*$/  true/' canary
mutant W4-helper-ausente-nao-checado 's/^  \[ -x "\$HELPER" \] || inert.*$/  true/' canary
mutant W5-comando-sem-canario 's/^canary$/true/' run
mutant W6-sem-semente-de-hash 's/ PYTHONHASHSEED=0//' run
mutant W7-sem-node-path 's/ NODE_PATH="\$HOME\/\.local\/share\/cdp-drive\/node_modules"//' run
mutant P1-sonda-sem-segredo 's/^if sec: leak.append.*$/pass/' probe
mutant P2-sonda-sem-dns 's/; leak.append("dns")/; pass/' probe
mutant P3-sonda-sem-interface 's/^if bad: leak.append.*$/pass/' probe
mutant P4-sonda-sem-udp 's/; leak.append("udp:1.1.1.1:53")/; pass/' probe
mutant P5-sonda-sem-8888 's/ ("8.8.8.8", 443),//' probe
echo "---"; echo "$((n-fails))/$n ok ($M mutantes)"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
