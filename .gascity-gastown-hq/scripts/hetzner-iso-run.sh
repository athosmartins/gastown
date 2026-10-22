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
# CÓDIGOS: o do comando (via helper) · 97 canário não deu `isolado` (o comando NÃO rodou: quem chamou trata como "bateria não rodou", nunca como teste)
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
# WA_PYTEST_MAX_WORKERS: sem ele o conftest do WA limita o xdist a 2 workers (wa-9c620); 14 x ~1 GB cabem nos 30 GB do nó.
# PYTHONHASHSEED=0: a ordem de parametrização por set é a mesma em todos os workers (medido: com semente aleatória duas coletas diferem na ordem de um teste de launchd).
# PYTHONPATH: onde está o plugin gtn_stable_ids (ids com relógio dentro; o pytest o carrega com `-p gtn_stable_ids`, passado por quem chama).
# NODE_PATH (ga-yoyyj1): onde o hetzner-nodejs.sh põe o jsdom. O mbp-run.sh a exporta no job, mas o sudo e o env -i do helper a descartariam; sem repassá-la, teste que chama o node sem NODE_PATH não acha o módulo na bateria noturna.
exec sudo -n "$HELPER" -- WA_PYTEST_MAX_WORKERS="${GTN_WORKERS:-14}" PYTHONHASHSEED=0 PYTHONPATH="$HOME/gt-remote/bin" PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" NODE_PATH="$HOME/.local/share/cdp-drive/node_modules" "$@"
