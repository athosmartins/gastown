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
# PISTAS (ga-282sl1d): `--lanes N` registra a pista em GTN_LANES_DIR, soma o que as outras vivas ainda podem crescer (teto − uso do cgroup delas), limita a pista a 10 GiB e a (nproc−2)/N workers; pista EXTRA sem
#   espaço (memória, CPU/PSI, PSI ilegível) sai com rc 95 e o comando NÃO roda; pid morto ou reaproveitado some do registro; linha ilegível conta como viva com o teto inteiro; lock tomado de dono morto;
#   --lanes inválido = INERTE; sem --lanes (ou 1) nada muda e nenhum registro nasce.
# CONTROLES NEGATIVOS: mutantes W1-W7 (wrapper), P1-P5 (sonda), C1-C8 (teto/workers) e L1-L15 (pistas) têm de ser REPROVADOS pelo caso correspondente (o caso falha no mutante).
# O QUE NÃO PROVA: que o helper de root isola de verdade num kernel real. Isso só o canário prova, no nó, depois que o root instalar o helper (`gt-iso-run --canary`).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT0="$HERE/hetzner-iso-run.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/hzn-iso-selftest.XXXXXX")
FAKEPIDS=""
trap '[ -z "$FAKEPIDS" ] || kill $FAKEPIDS 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
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
  *) printf 'CMD: %s\n' "$*" >> "$CALLS"; [ -z "${LANE_PROBE:-}" ] || printf 'LANEFILE: %s pid=%s\n' "$(cd "$GTN_LANES_DIR" 2>/dev/null && cat lane.* 2>/dev/null | tr '\n' ';')" "$$" >> "$CALLS"; exit "${CMD_RC:-0}" ;;
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

# ---- pistas: um "outro" vivo é um `sleep` com /proc/<pid>/stat e cgroup de mentira -----------------------------------------------------------------------------------------------------------
mkother() { # nome ceil início usado_mb → cria o registro de uma pista viva (processo de verdade + /proc e cgroup falsos); o pid fica em OTHERPID
  sleep 300 & OTHERPID=$!; FAKEPIDS="$FAKEPIDS $OTHERPID"
  mkdir -p "$GTN_LANES_DIR" "$GTN_PROC/$OTHERPID" "$GTN_CGROOT/fake.slice/$1.scope"
  printf '%s (sleep) S 1 1 1 0 -1 4194304 100 0 0 0 0 0 0 0 20 0 1 0 %s 1000 100 18446744073709551615\n' "$OTHERPID" "${3:-5555}" > "$GTN_PROC/$OTHERPID/stat"
  printf '0::/fake.slice/%s.scope\n' "$1" > "$GTN_PROC/$OTHERPID/cgroup"; echo $(( ${4:-0} * 1048576 )) > "$GTN_CGROOT/fake.slice/$1.scope/memory.current"
  printf '%s %s %s\n' "$OTHERPID" "${3:-5555}" "$2" > "$GTN_LANES_DIR/lane.$OTHERPID"; }
lreset() { find "$T/lanes" "$T/lanes.lock" "$T/proc" "$T/cg" "$T/psi" "$T/arquivo" -delete 2>/dev/null; mkdir -p "$T/proc" "$T/cg"
           printf 'some avg10=10.00 avg60=15.20 avg300=14.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$T/psi"
           export GTN_LANES_DIR="$T/lanes" GTN_PROC="$T/proc" GTN_CGROOT="$T/cg" GTN_PSI_FILE="$T/psi"; unset GTN_LANE_LOCK_TRIES; }
case_lanes() { local f
  lreset; LANE_PROBE=1 go "$1" --lanes 2 -- python -m pytest
  ck "pista sozinha: roda (rc 0)" rcis 0; ck "pista sozinha: teto de 10 GiB por pista (MemAvailable dava 13387M) e 6 workers" has "$OUT" '^GTN-CAP: MemoryMax=10240M MemorySwapMax=0 workers=6 '
  ck "pista sozinha: a linha GTN-LANE diz que não há outra viva e o teto" has "$OUT" '^GTN-LANE: pistas=2 outras-vivas=0 reservado-pelas-outras=0M orcamento=13387M teto-da-pista=10240M psi60=-$'
  ck "pista sozinha: o comando leva os 6 workers" has "$CALLS" '^CMD: WA_PYTEST_MAX_WORKERS=6 '
  ck "pista sozinha: o registro tem a pista (pid do próprio gt-iso-run, início, teto) ANTES do comando rodar" has "$CALLS" '^LANEFILE: ([0-9]+) [0-9?]+ 10240;? pid=\1$'
  # sem --lanes e com --lanes 1: igual a antes (teto 13387M, 9 workers) e NENHUM registro
  lreset; go "$1" -- true; ck "sem --lanes: o de sempre (13387M, 9 workers)" has "$OUT" '^GTN-CAP: MemoryMax=13387M MemorySwapMax=0 workers=9 '; ck "sem --lanes: nenhum registro nasce" test ! -e "$GTN_LANES_DIR"
  go "$1" --lanes 1 -- true; ck "--lanes 1: o de sempre" has "$OUT" '^GTN-CAP: MemoryMax=13387M MemorySwapMax=0 workers=9 '; ck "--lanes 1: nenhum registro nasce" test ! -e "$GTN_LANES_DIR"
  # a CPU divide por pistas: muita memória e teto de pista alto → (16−2)/2 = 7 workers (sem a divisão seriam 14)
  lreset; printf 'MemAvailable:   40000000 kB\n' > "$T/meminfo.l"; GTN_MEMINFO="$T/meminfo.l" GTN_LANE_CEIL_MAX_MB=20480 go "$1" --lanes 2 -- true
  ck "CPU dividida por pistas: 7 workers (14 / 2)" has "$OUT" '^GTN-CAP: MemoryMax=20480M MemorySwapMax=0 workers=7 '
  # pista EXTRA com a outra usando pouco: ela ainda pode crescer 8192M → orçamento 19531−6144−8192 = 5195M < 2048+3×1200 → sem espaço, rc 95, o comando NÃO roda
  lreset; mkother a 10240 5555 2048; go "$1" --lanes 2 -- touch /tmp/NUNCA
  ck "extra sem memória: rc 95" rcis 95; ck "extra sem memória: diz sem-espaco e o motivo (memoria, o que a outra ainda pode usar)" has "$OUT" '^GTN-CAP: sem-espaco memoria \(orçamento 5195M = MemAvailable 19531M − reserva 6144M − 8192M que as 1 outra'
  ck "extra sem memória: o comando NÃO roda" nocalls; ck "extra sem memória: não deixa registro próprio (só a pista de mentira)" test "$(ls "$GTN_LANES_DIR" | grep -c '^lane\.')" = 1
  ck "extra sem memória: a linha GTN-LANE mostra o que leu" has "$OUT" '^GTN-LANE: pistas=2 outras-vivas=1 reservado-pelas-outras=8192M orcamento=5195M psi60=-$'
  # a outra já usa 6144M do teto de 10240M: ainda pode crescer 4096M → orçamento 9291M: a extra entra com 6 workers
  lreset; mkother a 10240 5555 6144; LANE_PROBE=1 go "$1" --lanes 2 -- true
  ck "extra com espaço: roda" rcis 0; ck "extra com espaço: teto 9291M e 6 workers" has "$OUT" '^GTN-CAP: MemoryMax=9291M MemorySwapMax=0 workers=6 '; ck "extra com espaço: GTN-LANE mostra a outra e o PSI lido" has "$OUT" '^GTN-LANE: pistas=2 outras-vivas=1 reservado-pelas-outras=4096M orcamento=9291M teto-da-pista=9291M psi60=15$'
  ck "extra com espaço: o registro tem as DUAS pistas" has "$CALLS" '^LANEFILE: .*;.* pid='
  # CPU disputada: PSI acima do piso (50) → sem espaço (cpu); PSI ilegível → sem espaço (não entra); PSI no limite (50) entra
  lreset; mkother a 10240 5555 6144; printf 'some avg10=90.00 avg60=70.30 avg300=40.00 total=1\n' > "$T/psi"; go "$1" --lanes 2 -- touch /tmp/NUNCA
  ck "extra com CPU disputada: rc 95 e diz cpu" has "$OUT" '^GTN-CAP: sem-espaco cpu \(o nó está disputando CPU: some avg60=70% > 50%\)'; ck "extra com CPU disputada: rc" rcis 95; ck "extra com CPU disputada: o comando NÃO roda" nocalls
  lreset; mkother a 10240 5555 6144; GTN_PSI_FILE="$T/psi-nao-existe" go "$1" --lanes 2 -- touch /tmp/NUNCA; ck "PSI ilegível: extra não entra (cpu-ilegivel)" has "$OUT" '^GTN-CAP: sem-espaco cpu-ilegivel'; ck "PSI ilegível: rc 95" rcis 95
  lreset; mkother a 10240 5555 6144; printf 'some avg10=1.00 avg60=50.00 avg300=1.00 total=1\n' > "$T/psi"; go "$1" --lanes 2 -- true; ck "PSI no limite (50): entra" rcis 0
  # a pista que chega SOZINHA não olha o PSI (é a 1ª: as regras de sempre)
  lreset; GTN_PSI_FILE="$T/psi-nao-existe" go "$1" --lanes 2 -- true; ck "sozinha com PSI ilegível: roda (o PSI só vale para a EXTRA)" rcis 0
  # pista morta some do registro e não conta; pid reaproveitado (início do processo diferente) também
  lreset; mkother a 10240 5555 0; kill "$OTHERPID" 2>/dev/null; wait "$OTHERPID" 2>/dev/null; go "$1" --lanes 2 -- true
  ck "outra morta: não conta (outras-vivas=0)" has "$OUT" '^GTN-LANE: pistas=2 outras-vivas=0 '; ck "outra morta: sai do registro" test ! -e "$GTN_LANES_DIR/lane.$OTHERPID"
  lreset; mkother a 10240 5555 0; printf '%s (sleep) S 1 1 1 0 -1 4194304 100 0 0 0 0 0 0 0 20 0 1 0 7777 1000 100 18446744073709551615\n' "$OTHERPID" > "$GTN_PROC/$OTHERPID/stat"; go "$1" --lanes 2 -- true
  ck "pid reaproveitado (início diferente): não conta" has "$OUT" '^GTN-LANE: pistas=2 outras-vivas=0 '; ck "pid reaproveitado: sai do registro" test ! -e "$GTN_LANES_DIR/lane.$OTHERPID"
  # cgroup da outra ilegível: conta o teto INTEIRO como ainda por usar (o lado seguro) → 19531−6144−10240 = 3147M: sem espaço
  lreset; mkother a 10240 5555 0; printf '0::/fake.slice/inexistente.scope\n' > "$GTN_PROC/$OTHERPID/cgroup"; go "$1" --lanes 2 -- touch /tmp/NUNCA; ck "cgroup da outra ilegível: teto inteiro reservado (orçamento 3147M, sem espaço)" has "$OUT" '^GTN-CAP: sem-espaco memoria \(orçamento 3147M '
  # linha do registro ilegível NÃO é pista morta: conta como viva com o teto inteiro (e continua lá)
  lreset; mkdir -p "$GTN_LANES_DIR"; echo "lixo" > "$GTN_LANES_DIR/lane.999999"; go "$1" --lanes 2 -- touch /tmp/NUNCA
  ck "registro ilegível: conta como viva (outras-vivas=1, 10240M reservados)" has "$OUT" '^GTN-LANE: pistas=2 outras-vivas=1 reservado-pelas-outras=10240M '; ck "registro ilegível: rc 95" rcis 95; ck "registro ilegível: a linha continua lá (nada foi apagado às cegas)" test -e "$GTN_LANES_DIR/lane.999999"
  # --lanes inválido = INERTE, nunca "1 pista" calado
  for f in abc 0 9 -1 vazio; do lreset; if [ "$f" = vazio ]; then go "$1" --lanes -- touch /tmp/NUNCA; else go "$1" --lanes "$f" -- touch /tmp/NUNCA; fi
    ck "--lanes '$f': INERTE rc 97" rcis 97; ck "--lanes '$f': diz lanes-invalido" has "$OUT" '^GTN-CAP: inerte lanes-invalido'; done
  # constante das pistas inválida = INERTE
  lreset; GTN_LANE_MIN_WORKERS=abc go "$1" --lanes 2 -- touch /tmp/NUNCA; ck "constante das pistas inválida: INERTE rc 97" rcis 97; ck "constante das pistas inválida: diz constante-invalida-pistas" has "$OUT" '^GTN-CAP: inerte constante-invalida-pistas'
  # GTN_WORKERS explícito (o lastro) ignora as pistas: nada de registro
  lreset; GTN_WORKERS=3 go "$1" --lanes 2 -- true; ck "GTN_WORKERS com --lanes: segue sem teto" has "$OUT" '^GTN-CAP: sem-teto \(GTN_WORKERS=3'; ck "GTN_WORKERS com --lanes: nenhum registro" test ! -e "$GTN_LANES_DIR"
  # lock: dono vivo segura (INERTE depois das tentativas); dono morto é tomado
  lreset; mkdir -p "$GTN_LANES_DIR.lock"; sleep 300 & FAKEPIDS="$FAKEPIDS $!"; echo $! > "$GTN_LANES_DIR.lock/pid"; GTN_LANE_LOCK_TRIES=2 go "$1" --lanes 2 -- touch /tmp/NUNCA
  ck "lock com dono vivo: INERTE rc 97 (sem o lock a soma de memória não é segura)" rcis 97; ck "lock com dono vivo: diz pistas-sem-lock" has "$OUT" '^GTN-CAP: inerte pistas-sem-lock'; ck "lock com dono vivo: o comando NÃO roda" nocalls
  lreset; mkdir -p "$GTN_LANES_DIR.lock"; ( exit 0 ) & f=$!; echo "$f" > "$GTN_LANES_DIR.lock/pid"; wait "$f"; go "$1" --lanes 2 -- true; ck "lock com dono morto: tomado, a pista roda" rcis 0; ck "lock com dono morto: o lock é solto no fim" test ! -e "$GTN_LANES_DIR.lock"
  # o registro não pode ser criado: INERTE (pista que as outras não enxergam estoura a soma)
  lreset; : > "$T/arquivo"; GTN_LANES_DIR="$T/arquivo/dentro" go "$1" --lanes 2 -- touch /tmp/NUNCA; ck "registro impossível de criar: INERTE rc 97" rcis 97; ck "registro impossível de criar: diz pistas-sem-registro" has "$OUT" '^GTN-CAP: inerte pistas-sem-registro'
  # vazou: o canário vence (nada de pista)
  lreset; PROBE_MODE=leak go "$1" --lanes 2 -- true; ck "vazou com --lanes: nenhum registro e nenhuma linha GTN-LANE" test ! -e "$GTN_LANES_DIR" -a "$(grep -c '^GTN-LANE' "$OUT")" = 0; }

for c in canary run cap probe lanes; do "case_$c" "$SUT0"; done

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
mutant L1-pista-extra-ignora-o-que-a-outra-ainda-cresce 's/^    \[ "\$used" -lt "\$ceil" \] && unspent=.*$/    :/' lanes
mutant L2-pista-extra-sem-piso-de-memoria 's/^    \[ "\$CEIL" -ge \$(( BASE + LMINW \* PER )) \] || why=.*$/    :/' lanes
mutant L3-pista-extra-ignora-o-psi 's/elif \[ "\$psi" -gt "\$PSIMAX" \]; then why=/elif false; then why=/' lanes
mutant L4-psi-ilegivel-vira-livre 's/if ! num "\$psi"; then why=/if false; then why=/' lanes
mutant L5-pista-morta-conta-como-viva 's/if ! kill -0 "\$pid" 2>\/dev\/null; then .*; continue; fi/:/' lanes
mutant L6-pid-reaproveitado-nao-detectado 's/if \[ "\$st" != "?" \] \&\& \[ -n "\$cur" \] \&\& \[ "\$cur" != "\$st" \]; then .*; continue; fi/:/' lanes
mutant L7-cgroup-ilegivel-vira-uso-total 's/num "\$cur" \&\& used=\$(( cur \/ 1048576 ))/used=$ceil/' lanes
mutant L8-cpu-nao-dividida-por-pistas 's/^  CPUDIV=\$LANES$/  CPUDIV=1/' lanes
mutant L9-pista-nao-registrada 's/printf .%s %s %s\\n. "\$\$" "\${self:-?}" "\$CEIL" > "\$LD\/\.lane\.\$\$\.tmp" \&\& mv -f "\$LD\/\.lane\.\$\$\.tmp" "\$LD\/lane\.\$\$"/:/' lanes
mutant L10-registro-ilegivel-vira-pista-morta 's/^    else pid=""; ceil=\$LCEIL; fi$/    else continue; fi/' lanes
mutant L11-lanes-invalido-aceito 's/num "\$LANES_RAW" \&\& \[ "\$LANES_RAW" -ge 1 \] \&\& \[ "\$LANES_RAW" -le 8 \] || cap_inert/true || cap_inert/' lanes
mutant L12-sem-espaco-vira-inerte 's/echo "GTN-CAP: sem-espaco \$why"; exit 95/echo "GTN-CAP: sem-espaco $why"; exit 97/' lanes
mutant L13-lock-ignorado 's/^  lane_lock "\$LD" || cap_inert.*$/  :/' lanes
mutant L14-teto-da-pista-ignorado 's/CEIL=\$budget; \[ "\$CEIL" -le "\$LCEIL" \] || CEIL=\$LCEIL;/CEIL=$budget;/' lanes
mutant L15-pista-sem-espaco-segue-rodando 's/^    echo "GTN-CAP: sem-espaco \$why"; exit 95$/    echo "GTN-CAP: sem-espaco $why"/' lanes
echo "---"; echo "$((n-fails))/$n ok ($M mutantes)"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
