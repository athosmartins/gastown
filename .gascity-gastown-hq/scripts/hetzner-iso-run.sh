#!/bin/bash
# hetzner-iso-run.sh — o lado do `runner` no nó Linux: prova o isolamento de rede e só então roda o comando (ga-9p6pte). Vai para ~/gt-remote/bin/gt-iso-run.
#
# ## Contents
#   Uso · Veredito do canário · Códigos de saída
#
# USO: gt-iso-run --canary            só o canário (é como se confere a instalação do helper de root: deve imprimir `GTN-ISO: isolado`)
#      gt-iso-run -- <comando> [args]  canário e, se isolado, o comando dentro do helper (sudo -n gt-netns-run), com ambiente limpo
# VEREDITO DO CANÁRIO (uma linha `GTN-ISO: ...`; o código de retorno do helper NÃO é prova — `systemd-run -p PrivateNetwork=yes` voltou 0 sem isolar):
#   isolado       a sonda DENTRO do helper tentou TCP/UDP/DNS para fora e nada passou, só `lo`/`gtn0` existem, nenhuma variável de ambiente com
#                 cara de segredo, loopback funciona, e o contador do nft SUBIU (a regra enxerga o tráfego; sonda que falha por outro motivo não conta)
#   nao-isolado   a sonda saiu pela rede ou achou interface/variável de segredo: o comando NÃO roda, o relatório diz o que vazou
#   inerte        não deu para saber (helper ausente, sudo recusou, sonda que quebrou ou não imprimiu veredito, contador zerado): o comando NÃO roda
# TETO DE MEMÓRIA E WORKERS (ga-84gkpab), depois do canário e antes do comando — uma linha `GTN-CAP: ...`:
#   GTN_WORKERS definido  (o `wa-suite` do lastro: o governo dele já decide núcleos e RSS) → o número é o do chamador e NADA muda: sem escopo, sem teto novo. `GTN-CAP: sem-teto (...)`.
#   GTN_WORKERS ausente   (a bateria noturna, em lotes por arquivo) → AUTO, lido do nó no instante em que o lote vai começar, nunca um número fixo:
#       MemAvailable (/proc/meminfo) − reserva (6 GiB para o resto do nó: lastro, sessões, kernel) = teto do lote, no máximo 20 GiB;
#       workers = min((teto − base) / por-worker, nproc − 2), base e por-worker em MB (constantes abaixo, medidas em ga-84gkpab). `-n` do chamador só limita por cima: o conftest do WA
#       corta qualquer `-n N`/`-n auto` em WA_PYTEST_MAX_WORKERS, que é o número calculado aqui.
#       O comando roda dentro de `systemd-run --user --scope -p MemoryMax=<teto> -p MemorySwapMax=0`: o OOM do kernel fica DENTRO do escopo (15/11: 14 workers sem teto esgotaram os 31 GB do
#       nó em 8 min e o OOM matou workers e controlador juntos). O teto só vale se PROVADO: um escopo de teste lê o próprio memory.max e tem de dizer exatamente o valor pedido.
#   INERTE (rc 97, `GTN-CAP: inerte <porquê>`, o comando NÃO roda): MemAvailable vazio/ilegível/zero, nproc ilegível, memória que não cabe nem um worker, systemd-run que recusa o escopo,
#       ou memory.max que não é o pedido. Falhou a leitura → não roda; nunca um número padrão no lugar.
# CÓDIGOS: o do comando (via helper) · 97 canário não deu `isolado` OU o teto/MemAvailable não pôde ser lido/provado (o comando NÃO rodou: quem chamou trata como "bateria não rodou", nunca como teste)
set -u
HELPER=${GT_NETNS_HELPER:-/usr/local/sbin/gt-netns-run}
PROBE='
import os, re, socket, sys
leak = []
for ip, port in (("1.1.1.1", 53), ("8.8.8.8", 443), ("9.9.9.9", 443)):
    s = socket.socket(); s.settimeout(3)
    try: s.connect((ip, port)); leak.append("tcp:%s:%d" % (ip, port))
    except OSError: pass
    s.close()
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(3)
try: u.connect(("1.1.1.1", 53)); u.send(b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01"); u.recv(512); leak.append("udp:1.1.1.1:53")
except OSError: pass
try: socket.getaddrinfo("example.com", 443); leak.append("dns")
except OSError: pass
# vazio → só lo/gtn0 existem; falhou/ilegível (sem /sys/class/net) → exceção, nenhuma linha GTN-PROBE → o canário sai inerte (nunca isolado)
bad = sorted(set(os.listdir("/sys/class/net")) - {"lo", "gtn0"})
if bad: leak.append("if:" + ",".join(bad))
sec = sorted(k for k in os.environ if re.search("TOKEN|SECRET|PASS|KEY|CRED|AUTH|SMTP", k, re.I))
if sec: leak.append("env:" + ",".join(sec))
# falhou (loopback não funciona) → exceção, nenhuma linha GTN-PROBE → inerte: um netns sem lo funcional não prova nada sobre o resto
l = socket.socket(); l.bind(("127.0.0.1", 0)); l.listen(1); socket.create_connection(l.getsockname(), 3).close()
print("GTN-PROBE: " + ("leak " + " ".join(leak) if leak else "isolated")); sys.exit(1 if leak else 0)
'
inert() { echo "GTN-ISO: inerte $*"; exit 97; }
canary() {
  [ -x "$HELPER" ] || inert "helper-ausente ($HELPER: o root ainda não o instalou)"
  local out rc n
  out=$(sudo -n "$HELPER" -- /usr/bin/python3 -I -c "$PROBE" 2>&1); rc=$?
  # vazio/falhou/ilegível (sem a linha GTN-PROBE, ou sem contador numérico) → inerte; só `isolated` + rc 0 + contador > 0 chega a "isolado"
  case "$out" in
    *"GTN-PROBE: leak"*) echo "GTN-ISO: nao-isolado $(printf '%s\n' "$out" | sed -n 's/^GTN-PROBE: leak //p' | head -n 1)"; exit 97 ;;
    *"GTN-PROBE: isolated"*) ;;
    *) inert "sem-veredito rc=$rc: $(printf '%s\n' "$out" | grep . | tail -n 1 | cut -c1-160)" ;;
  esac
  [ $rc -eq 0 ] || inert "probe-rc=$rc"
  n=$(printf '%s\n' "$out" | sed -n 's/^GTN-EGRESS: attempts=//p' | head -n 1)
  case "$n" in ''|*[!0-9]*) inert "contador-ilegivel (attempts=${n:-vazio})" ;; esac
  [ "$n" -ge 1 ] || inert "contador-zerado (a sonda tentou sair e o nft não viu nada: a regra não está no caminho)"
  echo "GTN-ISO: isolado (sonda barrou $n tentativas)"
}
case "${1:-}" in
  --canary) canary; exit 0 ;;
  --) shift ;;
  *) echo "uso: $0 --canary | -- <comando>" >&2; exit 97 ;;
esac
[ $# -gt 0 ] || { echo "uso: $0 -- <comando>" >&2; exit 97; }
canary
# vazio → ver acima (GTN_WORKERS ausente = AUTO); falhou/ilegível → INERTE. GTN_MEMINFO/GTN_RESERVE_MB/GTN_CEIL_MAX_MB/GTN_BASE_MB/GTN_PERWORKER_MB existem para o selftest e para medir de novo.
num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
cap_inert() { echo "GTN-CAP: inerte $*"; exit 97; }
CAP=()
if [ -n "${GTN_WORKERS:-}" ]; then
  WORKERS=$GTN_WORKERS
  echo "GTN-CAP: sem-teto (GTN_WORKERS=$WORKERS explícito: o governo de quem chamou decide a memória)"
else
  RESERVE=${GTN_RESERVE_MB:-6144}; CEILMAX=${GTN_CEIL_MAX_MB:-20480}; BASE=${GTN_BASE_MB:-4096}; PER=${GTN_PERWORKER_MB:-1800}
  for v in "$RESERVE" "$CEILMAX" "$BASE" "$PER"; do num "$v" && [ "$v" -ge 1 ] || cap_inert "constante-invalida (reserva=$RESERVE teto-max=$CEILMAX base=$BASE por-worker=$PER)"; done
  MEMINFO=${GTN_MEMINFO:-/proc/meminfo}
  AVAIL_KB=$(awk '/^MemAvailable:/ { print $2; exit }' "$MEMINFO" 2>/dev/null)
  num "$AVAIL_KB" && [ "$AVAIL_KB" -gt 0 ] || cap_inert "memavailable-ilegivel (MemAvailable em $MEMINFO: '${AVAIL_KB:-vazio}'; sem leitura não há quanto de memória usar)"
  NCPU=$(nproc 2>/dev/null)
  num "$NCPU" && [ "$NCPU" -ge 1 ] || cap_inert "nproc-ilegivel ('${NCPU:-vazio}')"
  AVAIL_MB=$(( AVAIL_KB / 1024 ))
  CEIL=$(( AVAIL_MB - RESERVE )); [ "$CEIL" -le "$CEILMAX" ] || CEIL=$CEILMAX
  [ "$CEIL" -ge $(( BASE + PER )) ] || cap_inert "memoria-insuficiente (MemAvailable=${AVAIL_MB}M − reserva ${RESERVE}M = ${CEIL}M; um worker precisa de ${BASE}M de base + ${PER}M)"
  WORKERS=$(( (CEIL - BASE) / PER )); CPUMAX=$(( NCPU - 2 )); [ "$CPUMAX" -ge 1 ] || CPUMAX=1; [ "$WORKERS" -le "$CPUMAX" ] || WORKERS=$CPUMAX
  CAP=(systemd-run --user --scope --quiet -p "MemoryMax=${CEIL}M" -p MemorySwapMax=0)
  # a prova do teto: um escopo igual, que lê o PRÓPRIO memory.max. vazio/`max`/outro valor/falhou (sem o controlador de memória delegado, sem barramento de usuário) → INERTE
  GOT=$("${CAP[@]}" -- sh -c 'cat "/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max"' 2>/dev/null)
  [ "$GOT" = "$(( CEIL * 1048576 ))" ] || cap_inert "teto-nao-provado (pedi MemoryMax=${CEIL}M = $(( CEIL * 1048576 )) bytes; o cgroup do escopo diz '${GOT:-vazio}'; o comando NAO roda sem teto)"
  echo "GTN-CAP: MemoryMax=${CEIL}M MemorySwapMax=0 workers=$WORKERS (MemAvailable=${AVAIL_MB}M reserva=${RESERVE}M base=${BASE}M por-worker=${PER}M cpus=$NCPU)"
fi
# WA_PYTEST_MAX_WORKERS: sem ele o conftest do WA limita o xdist a 2 workers (wa-9c620). O número é o de cima (AUTO: o que cabe na memória lida AGORA; explícito: o do chamador). NÃO é verdade que 14 workers
# cabem no nó: medido em ga-2hd02v.5.8/5.9 cada worker nasce com ~2 GB (coleta a árvore inteira) e cresce sem platô; quem segura o estouro é o lote (poucos arquivos por pytest) e o teto acima.
# PYTHONHASHSEED=0: a ordem de parametrização por set é a mesma em todos os workers (medido: com semente aleatória duas coletas diferem na ordem de um teste de launchd).
# PYTHONPATH: onde está o plugin gtn_stable_ids (ids com relógio dentro; o pytest o carrega com `-p gtn_stable_ids`, passado por quem chama).
# NODE_PATH (ga-yoyyj1): onde o hetzner-nodejs.sh põe o jsdom. O mbp-run.sh a exporta no job, mas o sudo e o env -i do helper a descartariam; sem repassá-la, teste que chama o node sem NODE_PATH não acha o módulo na bateria noturna.
exec ${CAP[@]+"${CAP[@]}" --} sudo -n "$HELPER" -- WA_PYTEST_MAX_WORKERS="$WORKERS" PYTHONHASHSEED=0 PYTHONPATH="$HOME/gt-remote/bin" PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" NODE_PATH="$HOME/.local/share/cdp-drive/node_modules" "$@"
