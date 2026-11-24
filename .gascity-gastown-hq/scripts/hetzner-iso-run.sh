#!/bin/bash
# hetzner-iso-run.sh — o lado do `runner` no nó Linux: prova o isolamento de rede e só então roda o comando (ga-9p6pte). Vai para ~/gt-remote/bin/gt-iso-run.
#
# ## Contents
#   Uso · Veredito do canário · Teto de memória e workers · Pistas · Códigos de saída
#
# USO: gt-iso-run --canary            só o canário (é como se confere a instalação do helper de root: deve imprimir `GTN-ISO: isolado`)
#      gt-iso-run -- <comando> [args]  canário e, se isolado, o comando dentro do helper (sudo -n gt-netns-run), com ambiente limpo
#      gt-iso-run --lanes N -- <comando> [args]  o mesmo, como UMA de até N pistas simultâneas da noturna (ver PISTAS); N=1 é igual a não passar --lanes
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
# PISTAS (ga-282sl1d; só com `--lanes N`, N >= 2, e sem GTN_WORKERS): a noturna roda até N lotes AO MESMO TEMPO, cada um num `gt-iso-run` próprio. Medido em 22-24/11: o tempo do lote quase não depende
#   do nº de workers (5 workers levaram 998 s, 14 levaram 1631 s) e cada lote gasta 30-450 s em overhead fixo; então duas pistas de ~6 workers rendem mais que uma de 14. Quem garante que as pistas
#   não somem mais memória do que o nó tem é um registro em ~/gt-remote/iso-lanes (uma linha `pid início-do-processo teto` por pista viva), lido e escrito dentro de um lock (mkdir):
#       orçamento = MemAvailable − reserva − o que as OUTRAS pistas vivas ainda podem crescer (teto delas − o que o cgroup delas usa agora; cgroup ilegível = o teto inteiro, o lado seguro);
#       teto da pista = min(orçamento, 10 GiB); workers = min((teto − base) / por-worker, (nproc − 2) / N). Pista que já existe e some = pid morto OU início do processo diferente (pid reaproveitado).
#   A 1ª pista (nenhuma outra viva) mantém o piso de sempre (base + 1 worker; sem isso = INERTE, rc 97) e leva o teto de 10 GiB e os (nproc − 2) / N workers das pistas. Uma pista que chega com OUTRA viva é EXTRA e só entra se (a) o orçamento der pelo menos base + 3 workers
#   (GTN_LANE_MIN_WORKERS) e (b) o nó não estiver disputando CPU: /proc/pressure/cpu `some avg60` <= 50 (GTN_LANE_PSI_MAX; o lastro sozinho dá ~15). PSI ilegível = não entra. Não entrar NÃO é falha:
#   `GTN-CAP: sem-espaco <porquê>`, rc 95, o comando não roda, e quem chamou espera a outra pista soltar memória e tenta de novo (nunca conta como lote que não rodou). Uma linha `GTN-LANE: ...` diz o que foi lido.
# CÓDIGOS: o do comando (via helper) · 95 sem espaço/CPU para uma pista EXTRA agora (o comando NÃO rodou; tente de novo mais tarde) · 97 canário não deu `isolado` OU o teto/MemAvailable não pôde ser lido/provado (o comando NÃO rodou: quem chamou trata como "bateria não rodou", nunca como teste)
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
num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
LANES=1; LANES_RAW=""
if [ "${1:-}" = --lanes ]; then   # validado depois do canário (a ordem das linhas GTN-ISO, GTN-CAP não muda); `--lanes -- cmd` (sem valor) vira "vazio" e o INERTE diz isso
  if [ $# -lt 2 ] || [ "$2" = -- ]; then LANES_RAW=vazio; shift; else LANES_RAW=$2; shift 2; fi
fi
case "${1:-}" in
  --canary) canary; exit 0 ;;
  --) shift ;;
  *) echo "uso: $0 --canary | [--lanes N] -- <comando>" >&2; exit 97 ;;
esac
[ $# -gt 0 ] || { echo "uso: $0 -- <comando>" >&2; exit 97; }
canary
# vazio → ver acima (GTN_WORKERS ausente = AUTO); falhou/ilegível → INERTE. GTN_MEMINFO/GTN_RESERVE_MB/GTN_CEIL_MAX_MB/GTN_BASE_MB/GTN_PERWORKER_MB existem para o selftest e para medir de novo.
cap_inert() { echo "GTN-CAP: inerte $*"; exit 97; }

# ── pistas (ga-282sl1d): só com --lanes N >= 2. Tudo aqui vale PELO REGISTRO e pelo lock; sem eles duas pistas somariam memória acima do que o nó tem ─────────────────────────────────────────
lane_lock() { # diretório-do-registro → 0 com o lock (mkdir atômico, dono = pid); dono morto ou lock sem dono há mais de 1 min → toma; 1 se não conseguiu em ~30 s (o chamador fica INERTE)
  local d=$1.lock i=0 op
  while [ "$i" -lt 150 ]; do
    if mkdir "$d" 2>/dev/null; then echo $$ > "$d/pid" 2>/dev/null; return 0; fi
    op=$(cat "$d/pid" 2>/dev/null)
    if num "$op"; then
      if ! kill -0 "$op" 2>/dev/null; then rm -f "$d/pid"; rmdir "$d" 2>/dev/null; continue; fi
    elif [ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -f "$d/pid"; rmdir "$d" 2>/dev/null; continue; fi
    i=$((i+1)); sleep 0.2
  done
  return 1
}
lane_unlock() { rm -f "$1.lock/pid"; rmdir "$1.lock" 2>/dev/null; return 0; }
lane_start() { # pid → início do processo (campo 22 de /proc/<pid>/stat, que vem depois do "(comando)"); vazio = ilegível (nunca um número inventado)
  local t; t=$(sed -n 's/^.*) //p' "${GTN_PROC:-/proc}/$1/stat" 2>/dev/null | awk '{ print $20; exit }')
  num "$t" && echo "$t"; return 0
}
lane_admit() { # lê o registro das outras pistas e decide o teto desta; muda CEIL, OTHERS, CPUDIV; sai com 95 (sem espaço para uma pista EXTRA) ou 97 (INERTE) sem rodar o comando
  local LD=${GTN_LANES_DIR:-$HOME/gt-remote/iso-lanes} PROC=${GTN_PROC:-/proc} CGR=${GTN_CGROOT:-/sys/fs/cgroup} PSIF=${GTN_PSI_FILE:-/proc/pressure/cpu}
  local LCEIL=${GTN_LANE_CEIL_MAX_MB:-10240} LMINW=${GTN_LANE_MIN_WORKERS:-3} PSIMAX=${GTN_LANE_PSI_MAX:-50}
  local v f pid st ceil cur cg used unspent=0 budget psi="-" why="" self
  for v in "$LCEIL" "$LMINW" "$PSIMAX"; do num "$v" && [ "$v" -ge 1 ] || cap_inert "constante-invalida-pistas (teto-da-pista=$LCEIL min-workers=$LMINW psi-max=$PSIMAX)"; done
  mkdir -p "$LD" 2>/dev/null || cap_inert "pistas-sem-registro (não criei $LD)"
  lane_lock "$LD" || cap_inert "pistas-sem-lock (não consegui o lock de $LD em 30 s; sem ele duas pistas podem somar memória acima do que o nó tem)"
  OTHERS=0
  for f in "$LD"/lane.*; do
    [ -e "$f" ] || continue
    # linha ilegível/estranha NÃO é pista morta: conta como viva com o teto inteiro reservado (o lado seguro); só pid morto ou pid reaproveitado some do registro
    if read -r pid st ceil < "$f" 2>/dev/null && num "$pid" && num "$ceil"; then
      if ! kill -0 "$pid" 2>/dev/null; then rm -f "$f"; continue; fi
      cur=$(lane_start "$pid")
      if [ "$st" != "?" ] && [ -n "$cur" ] && [ "$cur" != "$st" ]; then rm -f "$f"; continue; fi
    else pid=""; ceil=$LCEIL; fi
    OTHERS=$((OTHERS+1)); used=0
    if [ -n "$pid" ]; then
      cg=$(sed -n 's/^0:://p' "$PROC/$pid/cgroup" 2>/dev/null | head -n 1)
      if [ -n "$cg" ]; then cur=$(cat "$CGR$cg/memory.current" 2>/dev/null); num "$cur" && used=$(( cur / 1048576 )); fi
    fi
    [ "$used" -lt "$ceil" ] && unspent=$(( unspent + ceil - used ))
  done
  budget=$(( AVAIL_MB - RESERVE - unspent ))
  CEIL=$budget; [ "$CEIL" -le "$LCEIL" ] || CEIL=$LCEIL; [ "$CEIL" -le "$CEILMAX" ] || CEIL=$CEILMAX
  if [ "$OTHERS" -gt 0 ]; then
    [ "$CEIL" -ge $(( BASE + LMINW * PER )) ] || why="memoria (orçamento ${budget}M = MemAvailable ${AVAIL_MB}M − reserva ${RESERVE}M − ${unspent}M que as $OTHERS outra(s) pista(s) ainda podem usar; uma pista extra precisa de base ${BASE}M + $LMINW workers de ${PER}M)"
    if [ -z "$why" ]; then
      psi=$(sed -n -E 's/^some .*avg60=([0-9]+)(\.[0-9]*)?.*$/\1/p' "$PSIF" 2>/dev/null | head -n 1)
      if ! num "$psi"; then why="cpu-ilegivel (sem leitura de $PSIF não sei se o nó está disputando CPU; a pista extra não entra)"; psi="-"
      elif [ "$psi" -gt "$PSIMAX" ]; then why="cpu (o nó está disputando CPU: some avg60=${psi}% > ${PSIMAX}%)"; fi
    fi
  fi
  if [ -n "$why" ]; then
    lane_unlock "$LD"
    echo "GTN-LANE: pistas=$LANES outras-vivas=$OTHERS reservado-pelas-outras=${unspent}M orcamento=${budget}M psi60=$psi"
    echo "GTN-CAP: sem-espaco $why"; exit 95
  fi
  # o registro entra ANTES de soltar o lock e antes do exec (o pid e o início do processo continuam os mesmos depois do exec); falhou ao gravar → INERTE: pista que as outras não enxergam estoura a soma
  self=$(lane_start $$)
  if ! { printf '%s %s %s\n' "$$" "${self:-?}" "$CEIL" > "$LD/.lane.$$.tmp" && mv -f "$LD/.lane.$$.tmp" "$LD/lane.$$"; } 2>/dev/null; then lane_unlock "$LD"; cap_inert "pistas-sem-registro (não gravei $LD/lane.$$)"; fi
  lane_unlock "$LD"
  CPUDIV=$LANES
  echo "GTN-LANE: pistas=$LANES outras-vivas=$OTHERS reservado-pelas-outras=${unspent}M orcamento=${budget}M teto-da-pista=${CEIL}M psi60=$psi"
}
CAP=()
if [ -n "${GTN_WORKERS:-}" ]; then
  WORKERS=$GTN_WORKERS
  echo "GTN-CAP: sem-teto (GTN_WORKERS=$WORKERS explícito: o governo de quem chamou decide a memória)"
else
  RESERVE=${GTN_RESERVE_MB:-6144}; CEILMAX=${GTN_CEIL_MAX_MB:-20480}; BASE=${GTN_BASE_MB:-2048}; PER=${GTN_PERWORKER_MB:-1200}
  for v in "$RESERVE" "$CEILMAX" "$BASE" "$PER"; do num "$v" && [ "$v" -ge 1 ] || cap_inert "constante-invalida (reserva=$RESERVE teto-max=$CEILMAX base=$BASE por-worker=$PER)"; done
  # --lanes: vazio/ilegível/0/mais de 8 → INERTE (nunca cai em "1 pista" calado: quem pediu pistas e não as teve precisa saber)
  if [ -n "$LANES_RAW" ]; then num "$LANES_RAW" && [ "$LANES_RAW" -ge 1 ] && [ "$LANES_RAW" -le 8 ] || cap_inert "lanes-invalido (--lanes '$LANES_RAW': precisa ser um inteiro de 1 a 8)"; LANES=$LANES_RAW; fi
  MEMINFO=${GTN_MEMINFO:-/proc/meminfo}
  AVAIL_KB=$(awk '/^MemAvailable:/ { print $2; exit }' "$MEMINFO" 2>/dev/null)
  num "$AVAIL_KB" && [ "$AVAIL_KB" -gt 0 ] || cap_inert "memavailable-ilegivel (MemAvailable em $MEMINFO: '${AVAIL_KB:-vazio}'; sem leitura não há quanto de memória usar)"
  NCPU=$(nproc 2>/dev/null)
  num "$NCPU" && [ "$NCPU" -ge 1 ] || cap_inert "nproc-ilegivel ('${NCPU:-vazio}')"
  AVAIL_MB=$(( AVAIL_KB / 1024 ))
  CEIL=$(( AVAIL_MB - RESERVE )); [ "$CEIL" -le "$CEILMAX" ] || CEIL=$CEILMAX
  CPUDIV=1; OTHERS=0
  [ "$LANES" -le 1 ] || lane_admit
  [ "$CEIL" -ge $(( BASE + PER )) ] || cap_inert "memoria-insuficiente (MemAvailable=${AVAIL_MB}M − reserva ${RESERVE}M = ${CEIL}M; um worker precisa de ${BASE}M de base + ${PER}M)"
  WORKERS=$(( (CEIL - BASE) / PER )); CPUMAX=$(( (NCPU - 2) / CPUDIV )); [ "$CPUMAX" -ge 1 ] || CPUMAX=1; [ "$WORKERS" -le "$CPUMAX" ] || WORKERS=$CPUMAX
  CAP=(systemd-run --user --scope --quiet --collect -p "MemoryMax=${CEIL}M" -p MemorySwapMax=0)
  # a prova do teto: um escopo igual, que lê o PRÓPRIO memory.max. vazio/`max`/outro valor/falhou (sem o controlador de memória delegado, sem barramento de usuário) → INERTE
  GOT=$("${CAP[@]}" -- sh -c 'cat "/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max"' 2>/dev/null)
  [ "$GOT" = "$(( CEIL * 1048576 ))" ] || cap_inert "teto-nao-provado (pedi MemoryMax=${CEIL}M = $(( CEIL * 1048576 )) bytes; o cgroup do escopo diz '${GOT:-vazio}'; o comando NAO roda sem teto)"
  echo "GTN-CAP: MemoryMax=${CEIL}M MemorySwapMax=0 workers=$WORKERS (MemAvailable=${AVAIL_MB}M reserva=${RESERVE}M base=${BASE}M por-worker=${PER}M cpus=$NCPU)"
fi
# WA_PYTEST_MAX_WORKERS: sem ele o conftest do WA limita o xdist a 2 workers (wa-9c620). O número é o de cima (AUTO: o que cabe na memória lida AGORA; explícito: o do chamador). NÃO é verdade que 14 workers
# cabem no nó: medido em ga-2hd02v.5.8/5.9 cada worker nasce com ~2 GB (coleta a árvore inteira) e cresce sem platô; quem segura o estouro é o lote (poucos arquivos por pytest) e o teto acima.
# Medido em ga-84gkpab (15/11, lote de 554 arquivos / ~8000 testes, 7 workers): pico do escopo ≈ 5,8 GB (~0,9 GB de base + 0,7–0,8 GB por worker) — daí base 2048 e por-worker 1200 (folga de ~50% sobre o medido), no lugar dos alvos 4096/1800.
# PYTHONHASHSEED=0: a ordem de parametrização por set é a mesma em todos os workers (medido: com semente aleatória duas coletas diferem na ordem de um teste de launchd).
# PYTHONPATH: onde está o plugin gtn_stable_ids (ids com relógio dentro; o pytest o carrega com `-p gtn_stable_ids`, passado por quem chama).
# NODE_PATH (ga-yoyyj1): onde o hetzner-nodejs.sh põe o jsdom. O mbp-run.sh a exporta no job, mas o sudo e o env -i do helper a descartariam; sem repassá-la, teste que chama o node sem NODE_PATH não acha o módulo na bateria noturna.
exec ${CAP[@]+"${CAP[@]}" --} sudo -n "$HELPER" -- WA_PYTEST_MAX_WORKERS="$WORKERS" PYTHONHASHSEED=0 PYTHONPATH="$HOME/gt-remote/bin" PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" NODE_PATH="$HOME/.local/share/cdp-drive/node_modules" "$@"
