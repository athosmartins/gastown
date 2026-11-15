#!/usr/bin/env bash
# hetzner-iso-run.selftest.sh — hermético: sudo e o helper de root são stubs; a sonda roda com um `socket` de mentira; nada sai para a rede (ga-9p6pte).
#
# ## Contents
#   Casos · Controles negativos · O que este teste NÃO prova
#
# CASOS: canário isolado / vazou (nao-isolado) / sem veredito / sonda com rc≠0 / sem contador / contador zerado / helper que falhou na montagem (98) / helper ausente →
#   o comando só roda quando o veredito é `isolado` e sai com o rc dele, com o ambiente certo (workers, semente de hash, PYTHONPATH do plugin) · veredito da PRÓPRIA sonda
#   (TCP, UDP, DNS, interface extra, variável com cara de segredo) com um `socket` de mentira.
# TETO DE MEMÓRIA E WORKERS (ga-84gkpab): sem GTN_WORKERS os workers saem do MemAvailable lido na hora (teto de 20 GiB, reserva de 6 GiB, nproc−2), o comando roda DENTRO do escopo
#   systemd-run com MemoryMax e MemorySwapMax=0, e o teto só vale com a prova (o escopo lê o próprio memory.max); MemAvailable ilegível/zero, memória que não cabe um worker, escopo recusado
#   ou teto que não aparece no cgroup = INERTE (rc 97, o comando NÃO roda). Com GTN_WORKERS (o lastro) nada muda.
# CONTROLES NEGATIVOS: mutantes W1-W7 (wrapper), P1-P5 (sonda) e C1-C8 (teto/workers) têm de ser REPROVADOS pelo caso correspondente (o caso falha no mutante).
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
cat > "$T/bin/nproc" <<'EOF'
#!/usr/bin/env bash
[ "${NPROC:-16}" = vazio ] || echo "${NPROC:-16}"
EOF
# systemd-run de mentira: `--user --scope --quiet -p MemoryMax=XM -p MemorySwapMax=0 -- cmd`. A prova do teto (o comando que lê memory.max) devolve o valor pedido em bytes (SD_MODE=ok), `max` (nocap) ou nada (empty);
# `refuse` recusa o escopo; qualquer outro comando é registrado em CALLS (SCOPE: ...) e executado
cat > "$T/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
mm=""; swap=""; col=0
while [ $# -gt 0 ]; do case "$1" in -p) case "$2" in MemoryMax=*) mm=${2#MemoryMax=} ;; MemorySwapMax=*) swap=${2#MemorySwapMax=} ;; esac; shift 2 ;; --collect) col=1; shift ;; --) shift; break ;; *) shift ;; esac; done
[ "${SD_MODE:-ok}" != refuse ] || { echo "Failed to connect to bus: No medium found" >&2; exit 1; }
case "$*" in *memory.max*) case "${SD_MODE:-ok}" in ok) echo $(( ${mm%M} * 1048576 )) ;; nocap) echo max ;; empty) ;; esac; exit 0 ;; esac
printf 'SCOPE: MemoryMax=%s MemorySwapMax=%s\n' "$mm" "$swap" >> "$CALLS"
printf 'COLLECT: %s\n' "$col" >> "$CALLS"
exec "$@"
EOF
chmod +x "$T/helper-stub.sh" "$T/bin/sudo" "$T/bin/nproc" "$T/bin/systemd-run"
printf 'MemTotal:       32020516 kB\nMemFree:         1000000 kB\nMemAvailable:   20000000 kB\nSwapTotal:             0 kB\n' > "$T/meminfo"
export PATH="$T/bin:$PATH" GT_NETNS_HELPER="$T/helper-stub.sh" CALLS HOME="$T/home" GTN_MEMINFO="$T/meminfo"
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
case_run() { CMD_RC=5 go "$1" -- python -m pytest tests/ -n auto
  ck "isolado: o comando roda e o rc dele é o do wrapper" rcis 5; ck "isolado: ambiente do comando (workers lidos do nó, semente, plugin)" has "$CALLS" "^CMD: WA_PYTEST_MAX_WORKERS=9 PYTHONHASHSEED=0 PYTHONPATH=$T/home/gt-remote/bin PATH=.* python -m pytest tests/ -n auto$"
  ck "isolado: o NODE_PATH do jsdom do nó chega ao comando (ga-yoyyj1)" has "$CALLS" "^CMD: .* NODE_PATH=$T/home/.local/share/cdp-drive/node_modules python -m pytest"
  GTN_WORKERS=4 go "$1" -- true; ck "GTN_WORKERS troca o número de workers" has "$CALLS" 'WA_PYTEST_MAX_WORKERS=4 '
  PROBE_MODE=leak go "$1" -- touch /tmp/NUNCA; ck "vazou: o comando NÃO roda" nocalls; ck "vazou: rc 97" rcis 97
  CNT=0 go "$1" -- true; ck "contador zerado: o comando NÃO roda" nocalls
  GT_NETNS_HELPER="$T/nao-existe" go "$1" -- true; ck "helper ausente: o comando NÃO roda" nocalls
  go "$1"; ck "sem argumentos: rc 97 e uso" rcis 97; go "$1" --; ck "-- sem comando: rc 97" rcis 97; }
case_cap() {
  # AUTO (sem GTN_WORKERS): 20000000 kB = 19531 MB − reserva 6144 = 13387 (abaixo do teto de 20480); (13387 − 2048) / 1200 = 9 workers; nproc 16 → no máximo 14
  CMD_RC=0 go "$1" -- python -m pytest -n auto
  ck "AUTO: linha GTN-CAP diz o teto, os workers e o que foi lido" has "$OUT" '^GTN-CAP: MemoryMax=13387M MemorySwapMax=0 workers=9 \(MemAvailable=19531M reserva=6144M base=2048M por-worker=1200M cpus=16\)$'
  ck "AUTO: o comando roda DENTRO do escopo com o teto e sem swap" has "$CALLS" '^SCOPE: MemoryMax=13387M MemorySwapMax=0$'; ck "AUTO: o escopo vem antes do comando (o comando roda no escopo)" test "$(sed -n 1p "$CALLS")" = "SCOPE: MemoryMax=13387M MemorySwapMax=0"
  ck "AUTO: o escopo leva --collect (sem ele, todo lote com rc != 0 deixa um escopo 'failed' listado no nó até alguém rodar reset-failed)" has "$CALLS" '^COLLECT: 1$'
  ck "AUTO: o número de workers do comando é o calculado" has "$CALLS" '^CMD: WA_PYTEST_MAX_WORKERS=9 '; ck "AUTO: o canário sai primeiro (a linha GTN-ISO vem antes da GTN-CAP)" test "$(grep -n -E '^GTN-(ISO|CAP):' "$OUT" | cut -d: -f2 | head -n 2 | tr '\n' ' ')" = "GTN-ISO GTN-CAP "
  # MemAvailable maior que o teto: 28000000 kB = 27343 − 6144 = 21199 → teto de 20480; (20480 − 2048) / 1200 = 15 → nproc 16 limita a 14
  printf 'MemAvailable:   28000000 kB\n' > "$T/meminfo.e"; GTN_MEMINFO="$T/meminfo.e" go "$1" -- python -m pytest; ck "AUTO com muita memória: o teto máximo (20480M) segura e a CPU limita a 14 workers" has "$OUT" '^GTN-CAP: MemoryMax=20480M MemorySwapMax=0 workers=14 '
  # MemAvailable menor: 16000000 kB = 15625 − 6144 = 9481 → (9481 − 2048) / 1200 = 6 workers
  printf 'MemAvailable:   16000000 kB\n' > "$T/meminfo.b"; GTN_MEMINFO="$T/meminfo.b" go "$1" -- python -m pytest; ck "AUTO com menos memória: teto 9481M e 6 workers" has "$OUT" '^GTN-CAP: MemoryMax=9481M MemorySwapMax=0 workers=6 '; ck "AUTO com menos memória: o comando leva 6" has "$CALLS" '^CMD: WA_PYTEST_MAX_WORKERS=6 '
  # CPU limita por cima: 4 núcleos → 2 workers (nproc − 2); 3 núcleos → 1
  NPROC=4 go "$1" -- true; ck "nproc 4: no máximo 2 workers" has "$OUT" 'workers=2 .*cpus=4\)'; NPROC=2 go "$1" -- true; ck "nproc 2: nunca 0 workers (1)" has "$OUT" 'workers=1 '
  # memória que não cabe nem um worker (base 2048 + 1200 = 3248): 9000000 kB = 8789 − 6144 = 2645
  printf 'MemAvailable:   9000000 kB\n' > "$T/meminfo.c"; GTN_MEMINFO="$T/meminfo.c" go "$1" -- touch /tmp/NUNCA; ck "memória que não cabe um worker: INERTE rc 97" rcis 97; ck "memória que não cabe um worker: diz o porquê" has "$OUT" '^GTN-CAP: inerte memoria-insuficiente \(MemAvailable=8789M'; ck "memória que não cabe um worker: o comando NÃO roda" nocalls
  # MemAvailable ilegível: sem a linha / vazio / não numérico / zero / arquivo ausente → INERTE, nunca um padrão
  local i
  for i in 'MemTotal: 1 kB' 'MemAvailable:' 'MemAvailable: abc kB' 'MemAvailable: 0 kB'; do
    printf '%s\n' "$i" > "$T/meminfo.d"; GTN_MEMINFO="$T/meminfo.d" go "$1" -- touch /tmp/NUNCA
    ck "MemAvailable ilegível ('$i'): INERTE rc 97" rcis 97; ck "MemAvailable ilegível ('$i'): diz memavailable-ilegivel" has "$OUT" '^GTN-CAP: inerte memavailable-ilegivel'; ck "MemAvailable ilegível ('$i'): o comando NÃO roda" nocalls; done
  GTN_MEMINFO="$T/nao-existe" go "$1" -- touch /tmp/NUNCA; ck "meminfo ausente: INERTE rc 97 e o comando NÃO roda" test "$RC" = 97 -a ! -s "$CALLS"
  NPROC=vazio go "$1" -- true; ck "nproc ilegível: INERTE rc 97" rcis 97; ck "nproc ilegível: diz nproc-ilegivel" has "$OUT" '^GTN-CAP: inerte nproc-ilegivel'
  GTN_PERWORKER_MB=abc go "$1" -- true; ck "constante inválida: INERTE (nunca cai no padrão)" has "$OUT" '^GTN-CAP: inerte constante-invalida'; ck "constante inválida: rc 97" rcis 97
  # o teto tem de ser PROVADO: escopo recusado / cgroup sem teto (`max`) / sem leitura → INERTE e o comando NÃO roda
  for i in refuse nocap empty; do SD_MODE=$i go "$1" -- touch /tmp/NUNCA; ck "teto sem prova ($i): INERTE rc 97" rcis 97; ck "teto sem prova ($i): diz teto-nao-provado" has "$OUT" '^GTN-CAP: inerte teto-nao-provado'; ck "teto sem prova ($i): o comando NÃO roda" nocalls; done
  # GTN_WORKERS explícito (o lastro): nada muda — sem escopo, sem leitura de MemAvailable (mesmo ilegível)
  GTN_MEMINFO="$T/nao-existe" GTN_WORKERS=4 go "$1" -- true; ck "GTN_WORKERS explícito: sem teto novo, diz que é do chamador" has "$OUT" '^GTN-CAP: sem-teto \(GTN_WORKERS=4 explícito'; ck "GTN_WORKERS explícito: o comando NÃO passa por escopo" hasnt "$CALLS" '^SCOPE:'; ck "GTN_WORKERS explícito: roda com 4" has "$CALLS" '^CMD: WA_PYTEST_MAX_WORKERS=4 '
  # vazou: o canário vence — nem MemAvailable é lido (a linha GTN-CAP não sai)
  PROBE_MODE=leak go "$1" -- true; ck "vazou: não há linha GTN-CAP (o canário vem primeiro)" hasnt "$OUT" '^GTN-CAP:'; }
case_probe() { extract "$1" > "$T/probe.py"; local m exp
  for m in "ok:isolated" "tcp:leak tcp:8.8.8.8:443" "udp:leak udp:1.1.1.1:53" "dns:leak dns" "if:leak if:eth0" "env:leak env:GITHUB_TOKEN"; do
    python3 -I "$T/probe-drv.py" "${m%%:*}" "$T/probe.py" > "$OUT" 2>&1; RC=$?; exp=${m#*:}
    ck "sonda ($m): veredito" has "$OUT" "^GTN-PROBE: $exp"; [ "${m%%:*}" = ok ] && ck "sonda (ok): sem vazamento e rc 0" rcis 0 || ck "sonda (${m%%:*}): rc 1" rcis 1; done; }

for c in canary run cap probe; do "case_$c" "$SUT0"; done

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
mutant C1-memavailable-ilegivel-vira-padrao 's/^  num "\$AVAIL_KB" \&\& \[ "\$AVAIL_KB" -gt 0 \] || cap_inert.*$/  AVAIL_KB=${AVAIL_KB:-30000000}; [ "$AVAIL_KB" -gt 0 ] || AVAIL_KB=30000000/' cap
mutant C2-teto-nao-provado-aceito 's/^  \[ "\$GOT" = .*$/  true/' cap
mutant C3-comando-fora-do-escopo 's/^exec \${CAP\[@\]+"\${CAP\[@\]}" --} sudo/exec sudo/' cap
mutant C4-memoria-que-nao-cabe-aceita 's/^  \[ "\$CEIL" -ge \$(( BASE + PER )) \] || cap_inert.*$/  [ "$CEIL" -ge 1 ] || CEIL=1/' cap
mutant C5-cpu-nao-limita 's/; \[ "\$WORKERS" -le "\$CPUMAX" \] || WORKERS=\$CPUMAX//' cap
mutant C6-sem-limite-de-swap 's/ -p MemorySwapMax=0)/)/' cap
mutant C7-reserva-ignorada 's/^  CEIL=\$(( AVAIL_MB - RESERVE ))/  CEIL=$(( AVAIL_MB ))/' cap
mutant C8-workers-explicitos-ignorados 's/^if \[ -n "\${GTN_WORKERS:-}" \]; then/if false; then/' cap
mutant P1-sonda-sem-segredo 's/^if sec: leak.append.*$/pass/' probe
mutant P2-sonda-sem-dns 's/; leak.append("dns")/; pass/' probe
mutant P3-sonda-sem-interface 's/^if bad: leak.append.*$/pass/' probe
mutant P4-sonda-sem-udp 's/; leak.append("udp:1.1.1.1:53")/; pass/' probe
mutant P5-sonda-sem-8888 's/ ("8.8.8.8", 443),//' probe
echo "---"; echo "$((n-fails))/$n ok ($M mutantes)"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
