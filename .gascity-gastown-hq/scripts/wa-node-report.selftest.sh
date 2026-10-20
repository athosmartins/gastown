#!/usr/bin/env bash
# wa-node-report.selftest.sh — hermético: o relatório lê fixtures de uma pasta temporária (rota, ocupação, log do Pilot, fila), com a hora fixada em WA_NODE_REPORT_NOW e o fuso em TZ. (ga-2hd02v.3)
#
# Contents
#   Casos · Controle negativo · O que não cobre · Como rodar
#
# CASOS (cada um é uma função chk_*; passa contra o script real e tem de REPROVAR contra os mutantes designados):
#   ROTA: veredito = o ÚLTIMO da bead na janela, ordenado pela hora e não pela ordem do arquivo · dry-run (sombra) nunca conta como entrega ao nó · capacidade (sem vaga) ≠ não elegível ≠ não li ≠ não sei ·
#     as que mudaram de veredito (em qualquer sentido) · a lista "para conferir" com a base e as razões (só de linha do Pilot com rc 0, no máximo 6, nunca de texto que não é lista) · linha de apply ilegível
#     (rc bool/texto, sem detalhe, sem bead) contada · linhas que não são objeto JSON contadas e avisadas · a janela é fechada nas duas pontas, o futuro não entra · cobertura em horas · modos do Pilot · soltas · leituras que falharam.
#   PRONTIDÃO: mecânica (horas e beads); igual ao mínimo basta, um a menos não; nunca diz "aprovado".
#   OCUPAÇÃO: CPU por hora em UTC (qualquer TZ) · CPU não lida (lido=false, ausente, bool, fora de 0..100, NaN) NUNCA vira 0%, e 0% de verdade aparece como 0,0 · média da janela sobre as LIDAS · "perto de 100%" é >= · sessões
#     wa-worker-remote (não o wa-worker do mini) · sessões não lidas não viram "0 sessões" · linhas sem epoch contadas · bordas da janela · a tabela de texto mostra as últimas 72 horas e avisa.
#   FUNIL (log do Pilot): cedidas/teto/claim/mini por linha e por bead (só id wa-…) · a hora do log é do fuso de quem roda (TZ=BRT3 dá o mesmo que UTC) · a janela · rodadas · o id não leva o ponto final da frase ·
#     pararam antes do gancho = (cedidas ∪ teto) sem decisão na rota · rota ausente/ilegível = "não sei" (null), nunca "0" nem "todas".
#   FILA: bead de WA por prioridade, idade, VENCIDA acima do ttl, hora no futuro ou ausente = "sem hora legível", JSON que não é o objeto com items = ilegível.
#   ESTADOS: ausente ≠ vazio ≠ ilegível (lixo, pasta no lugar do arquivo) · rc 3 só quando NENHUM dos dois logs serve (e JSON mesmo assim) · rc 2 em uso errado (inclui "010" = dez, nunca octal) · só leitura (nada novo, nada alterado) ·
#     --json é UMA linha de JSON com as seis chaves.
# CONTROLE NEGATIVO: cada mutante troca UMA trecho do script numa cópia (e FALHA se o trecho sumiu ou se repete: o script mudou, atualize o mutante) e a função designada tem de reprovar; mutante que sobrevive reprova esta bateria.
#   O piso (MIN_MUT) impede que apagar mutantes passe por "todos mortos".
# O QUE NÃO COBRE: o formato exato de cada linha que o Pilot e o despachante gravam hoje além dos padrões fixados aqui (se eles mudarem o texto, o funil vira zeros: o relatório lê o log como ele é, e o prod-test roda este
#   selftest contra a árvore viva); a saída em locale não-UTF-8 (o script fixa UTF-8 na saída, sem mutante); o log vivo de verdade.
# COMO RODAR: bash scripts/wa-node-report.selftest.sh   (macOS /bin/bash 3.2 e Linux; precisa de jq e python3; ~90 s no nó, mais de 2 min no mini carregado)
#   WA_NODE_REPORT_ST_NOMUT=1 roda só os casos, sem os mutantes (o prod-test usa assim; os mutantes são a evidência do gate).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="$HERE/wa-node-report.py"
MIN_MUT=70
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-node-report.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0; MUTANTS=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
command -v jq >/dev/null 2>&1 || { echo "jq ausente"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 ausente"; exit 2; }
[ -f "$REAL" ] || { echo "FALTA $REAL"; exit 2; }
NOW=$(python3 -I -c 'import calendar; print(calendar.timegm((2026, 10, 20, 12, 0, 0)))')
FX="$T/fx"; mkdir -p "$FX"

# ---- os fixtures: um gerador só (as horas são relativas a NOW, em segundos)
cat > "$T/fx.py" <<'PYEOF'
import json, os, sys, time

T, NOW = sys.argv[1], int(sys.argv[2])
H = 3600


def iso(off):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW + off))


def city(name):
    d = os.path.join(T, name)
    os.makedirs(os.path.join(d, ".gc", "logs"), exist_ok=True)
    return d


def jl(path, items):
    with open(path, "wb") as f:
        for it in items:
            f.write(it if isinstance(it, bytes) else json.dumps(it, ensure_ascii=False).encode("utf-8"))
            f.write(b"\n")


def ap(bead, off, rc, detail, ev="apply"):
    return {"ts": iso(off), "event": ev, "bead": bead, "rc": rc, "detail": detail}


def pr(bead, off, mode, rc, out, spawn="pool", slots="1"):
    return {"ts": iso(off), "event": "pilot-node-route", "bead": bead, "mode": mode, "rc": rc, "out": out, "spawn": spawn, "slots": slots}


def occ(off, cpu, sess):
    r = {"ts": iso(off), "epoch": NOW + off, "estado": "ok"}
    if cpu is not None:
        r["cpu"] = cpu
    if sess is not None:
        r["sessoes"] = sess
    return r


def cpu(pct, lido=True, nuc=16):
    return {"lido": lido, "nucleos": nuc, "ncpu": nuc, "janela_s": 900, "pct": pct}


def ses(nomes, lido=True):
    return {"lido": lido, "ativas": len(nomes), "ocupadas": 0, "nomes": nomes}


# ---- rota: 16 beads com decisão na janela
RAZ8 = json.dumps({"verdict": "node", "reasons": ["r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8"]})
rota = [
    ap("wa-edge-in", -24 * H, 10, "classificador:mini test-toca-banco"),                       # exatamente a borda de baixo: ENTRA
    ap("wa-edge-out", -24 * H - 1, 0, "dry-run: iria para wa-worker-remote-1 (code)"),         # um segundo antes: fora
    ap("wa-old", -30 * H, 0, "despachada para wa-worker-remote-1 (label)"),                    # fora
    ap("wa-n1", -20 * H, 0, "dry-run: iria para wa-worker-remote-1 (label)"),
    pr("wa-n1", -20 * H, "shadow", 0, json.dumps({"verdict": "node", "reasons": ["code", "test-sem-dado"]})),
    ap("wa-n2", -10 * H, 0, "despachada para wa-worker-remote-1 (label)"),
    pr("wa-n2", -10 * H, "label", 0, ""),
    {"ts": iso(-9 * H), "event": "release", "bead": "wa-n2", "rc": 0, "detail": "solta"},
    {"ts": iso(-9 * H + 60), "event": "release", "bead": "wa-n2", "rc": 13, "detail": "escrita-falhou"},
    ap("wa-n3", -8 * H, 12, "slot-ocupado bead(s)=1"),
    ap("wa-n4", -7 * H, 12, "oraculo-local:node_full"),
    ap("wa-n5", -7 * H + 60, 12, "oraculo-sem-vaga free=1 pendentes=1"),
    ap("wa-n6", -6 * H, 12, "nao-elegivel status=in_progress assignee=x rota="),
    pr("wa-n6", -6 * H + 30, 5, 0, ""),                                                        # modo que não é texto → "?"
    ap("wa-n7", -6 * H + 60, 12, "perdeu-a-corrida"),
    ap("wa-m1", -5 * H, 10, "classificador:mini test-toca-banco"),
    ap("wa-s1", -5 * H + 60, 11, "classificador:unknown sem-arquivo"),
    ap("wa-s2", -5 * H + 120, 11, "slot-ilegivel"),
    ap("wa-e1", -4 * H, 10, "base=code, modo exige etiqueta"),
    pr("wa-e1", -4 * H, "label", 10, json.dumps({"verdict": "node", "reasons": ["code"]})),   # rc 10: as razões NÃO entram
    ap("wa-u1", -6 * H, 0, "dry-run: iria para wa-worker-remote-1 (code)"),
    pr("wa-u1", -6 * H + 30, "shadow", 0, "texto que nao e json"),
    ap("wa-u1", -3 * H, 10, "classificador:mini test-toca-banco"),
    ap("wa-u2", -6 * H, 0, "dry-run: iria para wa-worker-remote-1 (code)"),
    pr("wa-u2", -6 * H + 30, "shadow", 0, json.dumps({"reasons": "nao-lista"})),
    ap("wa-u2", -3 * H, 11, "classificador:unknown sem-arquivo"),
    ap("wa-w1", -2 * H, 0, "dry-run: iria para wa-worker-remote-1 (doc)"),                    # o MAIS NOVO vem ANTES no arquivo
    ap("wa-w1", -5 * H, 10, "classificador:mini test-toca-banco"),
    pr("wa-w1", -1 * H, "shadow", 0, RAZ8, spawn="pilot", slots="3"),                          # a última linha do Pilot por hora
    {"ts": iso(-12 * H), "event": "apply", "bead": "wa-bool", "rc": False, "detail": "dry-run: iria para wa-worker-remote-1 (code)"},
    {"ts": iso(-12 * H), "event": "apply", "bead": "wa-str", "rc": "0", "detail": "dry-run: iria para wa-worker-remote-1 (code)"},
    {"ts": iso(-12 * H), "event": "apply", "bead": "wa-nodet", "rc": 0, "detail": None},
    {"ts": iso(-12 * H), "event": "apply", "rc": 0, "detail": "dry-run: iria para wa-worker-remote-1 (code)"},
    {"ts": iso(-12 * H), "event": "read", "bead": "wa-r1", "rc": 11, "detail": "bead-ilegivel"},
    {"ts": iso(-12 * H), "event": "classify", "bead": "wa-r2", "rc": 11, "detail": "classificador-incoerente"},
    {"event": "apply", "bead": "wa-nots", "rc": 0, "detail": "dry-run: iria para wa-worker-remote-1 (code)"},
    {"ts": "ontem", "event": "apply", "bead": "wa-tsruim", "rc": 0, "detail": "dry-run: iria para wa-worker-remote-1 (code)"},
    ap("wa-future", 1, 0, "dry-run: iria para wa-worker-remote-1 (code)"),                    # um segundo depois de agora: fora
    ap("wa-now", 0, 10, "classificador:mini test-toca-banco"),                                 # exatamente agora: ENTRA
    b"isto nao e json",
    b"[1, 2]",
    b"\xff\xfe nao e utf-8",
]
jl(os.path.join(city("rota"), ".gc", "wa-node-route.jsonl"), rota)

# ---- ocupação: 13 leituras na janela
ocup = [
    occ(-24 * H, cpu(50.0), ses([])),                                                   # borda de baixo: entra
    occ(-25 * H, cpu(100.0), ses(["wa-worker-remote-1"])),                              # fora
    occ(-4 * H, cpu(0.0, lido=False), ses([], lido=False)),                             # 08Z: nada lido
    occ(-4 * H + 900, cpu(0.0, lido=False), ses([], lido=False)),
    occ(-3 * H, cpu(100.0), ses(["wa-worker-remote-1", "dog-remote-1"])),               # 09Z
    occ(-3 * H + 900, cpu(80.0), ses(["wa-worker-1", "ps-worker-remote-1"])),           # wa-worker-1 é do MINI: não conta
    occ(-3 * H + 1800, cpu(0.0, lido=False), ses([], lido=False)),
    occ(-3 * H + 2700, cpu(100.5), ses(["wa-worker-remote-2", "wa-worker-remote-3"])),  # 100,5% não existe: sem CPU lida
    occ(-2 * H, cpu(0.0), ses([])),                                                     # 10Z: um 0% DE VERDADE
    occ(-2 * H + 900, None, None),
    occ(-2 * H + 1800, cpu(True), ses([], lido=False)),                                 # pct bool: sem CPU lida
    occ(-1 * H, cpu(95.0), ses([1])),                                                   # 11Z: nome que não é texto → sessões não lidas
    occ(-1 * H + 900, cpu(90.0), ses(["wa-worker-remote-1"])),                          # exatamente 90: conta como perto de 100%
    occ(0, cpu(100.0), ses([])),                                                        # exatamente agora: entra
    occ(1, cpu(100.0), ses([])),                                                        # um segundo depois: fora
    {"ts": iso(-5 * H), "estado": "ok", "cpu": cpu(100.0)},                             # sem epoch
    {"ts": iso(-5 * H), "epoch": str(NOW - 5 * H), "cpu": cpu(100.0)},                  # epoch em texto
    b'{"ts": "x", "epoch": NaN, "cpu": {"lido": true, "nucleos": 16, "pct": 100.0}}',   # epoch NaN
]
jl(os.path.join(city("ocup"), ".gc", "hetzner-occupancy.jsonl"), ocup)

# ---- 80 horas de ocupação, uma leitura por hora
jl(os.path.join(city("muitas"), ".gc", "hetzner-occupancy.jsonl"), [occ(-k * H, cpu(50.0), ses([])) for k in range(80)])

# ---- a ocupação pequena que as cidades de estado usam
pequena = [occ(-1 * H, cpu(60.0), ses([])), occ(-1 * H + 900, cpu(70.0), ses([]))]
for nome in ("sr", "lr", "dr"):
    jl(os.path.join(city(nome), ".gc", "hetzner-occupancy.jsonl"), pequena)

# ---- estados da rota: ausente (nada), vazio, só lixo, pasta no lugar do arquivo
city("na")
open(os.path.join(city("vz"), ".gc", "wa-node-route.jsonl"), "wb").close()
for nome in ("lx", "lr"):
    with open(os.path.join(city(nome), ".gc", "wa-node-route.jsonl"), "wb") as f:
        f.write(b"lixo\n[1]\n")
with open(os.path.join(city("lx"), ".gc", "hetzner-occupancy.jsonl"), "wb") as f:
    f.write(b"{nao: json}\n")
os.makedirs(os.path.join(city("dr"), ".gc", "wa-node-route.jsonl"), exist_ok=True)
os.makedirs(os.path.join(city("dn"), ".gc", "wa-node-route.jsonl"), exist_ok=True)

# ---- o funil: o log do Pilot (hora local, sem fuso) em UTC e em BRT (UTC-3)
WA = "wa-hut4l5.4"


def cedida(b):
    return "ga-5fn5p3: %s P2 cedida a P0/P1 de whatsapp_automation (P1 %s waits behind wa-worker 3/2) — not claimed, no writes this sweep; stays story:approved and is re-evaluated every sweep." % (b, WA)


def teto1(b):
    return "ga-in9ebr: %s QUEUED — routed to wa-worker, pool at session cap (3 active/creating >= 2 max); not claimed, no writes this sweep (the ga-93yxc pool top-up opens a session once a slot frees)." % b


def teto2(b):
    return "  ga-in9ebr: wa-worker pool at session cap (3 active/creating >= 2 max) — QUEUED %s: claim released, story:approved + gc.routed_to=wa-worker kept, NOT marked in-flight/dispatched (ga-93yxc pool top-up opens a session once a slot frees)." % b


SWEEP = "=== Pilot sweep start (DRY_RUN=0) ==="


def mini(b, alvo="wa-worker (slot=wa-worker-1)"):
    return "  RIG-NATIVE dispatch (ga-mfeip): assigning %s → %s in /Users/athos/gt/whatsapp_automation" % (b, alvo)


def pilot_log(path, tzoff):
    L = []

    def a(off, msg):
        L.append("[%s] [pilot-dispatcher] %s" % (time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(NOW + off + tzoff)), msg))
    a(-25 * H, SWEEP)
    a(-25 * H, cedida("wa-old1"))
    a(-25 * H, "Claim acquired on wa-old2.")
    a(-23 * H, cedida("wa-c1"))
    a(-23 * H + 60, cedida("wa-c1"))
    for off in (-20 * H, -10 * H, -5 * H):
        a(off, SWEEP)
    for off in (-20 * H, -10 * H, -5 * H):
        a(off + 5, cedida("wa-c2"))
    a(-5 * H, cedida("wa-c3"))
    a(-5 * H, "ga-5fn5p3: ga-xyz P2 cedida a P0/P1 de gascity (P1 ga-abc waits behind x 3/2) — not claimed")
    a(-5 * H, teto1(WA))
    a(-4 * H, teto1(WA))
    a(-4 * H, teto2("wa-t2"))
    a(-4 * H, teto1("wa-c3"))
    a(-3 * H, "Claim acquired on wa-k1.")
    a(-2 * H, "Claim acquired on wa-k1.")
    a(-2 * H, "Claim acquired on %s." % WA)
    a(-2 * H, "Claim acquired on ga-dzzqvw.1.")
    a(-1 * H, mini("wa-qp98sy"))
    a(-1 * H, mini("wa-c2"))
    a(-1 * H, mini("ga-zz", "gate-reviewer (slot=1)"))
    a(-1 * H, mini("wa-nodeline", "wa-worker-remote (slot=wa-worker-remote-1)"))
    L.append("    Claim acquired on wa-zz.")                                               # continuação sem hora
    L.append("[2026-13-45 99:99:99] [pilot-dispatcher] Claim acquired on wa-bad.")         # hora impossível
    a(60, SWEEP)                                                                          # no futuro
    a(60, "Claim acquired on wa-fut.")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")


pilot_log(os.path.join(T, "pilot-utc.log"), 0)
pilot_log(os.path.join(T, "pilot-brt.log"), -3 * H)
open(os.path.join(T, "pilot-vazio.log"), "wb").close()
os.makedirs(os.path.join(T, "pilot-dir.log"), exist_ok=True)
jl(os.path.join(city("funil"), ".gc", "wa-node-route.jsonl"), [ap("wa-c2", -1 * H, 10, "classificador:mini test-toca-banco"), ap("wa-qp98sy", -1 * H, 10, "classificador:mini test-toca-banco")])

# ---- a fila despachável
itens = [{"id": "wa-a", "store": "whatsapp_automation", "priority": 0}, {"id": "wa-b", "store": "whatsapp_automation", "priority": 1},
         {"id": "wa-c", "store": "whatsapp_automation", "priority": 1}, {"id": "wa-d", "store": "whatsapp_automation", "priority": 2},
         {"id": "wa-e", "store": "whatsapp_automation", "priority": "3"}, {"id": "wa-f", "store": "whatsapp_automation"},
         {"id": "ga-g", "store": "gascity", "priority": 0}, {"id": "ga-h", "store": "gascity", "priority": 1}, "lixo"]


def fila(nome, gen, extra=None):
    o = {"count": len(itens), "ttl_seconds": 1800, "items": itens}
    if gen is not None:
        o["generated_at"] = iso(gen)
    with open(os.path.join(T, nome), "w", encoding="utf-8") as f:
        json.dump(extra if extra is not None else o, f)


fila("fila-ok.json", -2400)
fila("fila-fresca.json", -100)
fila("fila-futura.json", 600)
fila("fila-sem-hora.json", None)
fila("fila-itens-texto.json", 0, extra={"items": "x", "ttl_seconds": 1800})
fila("fila-lista.json", 0, extra=[])
with open(os.path.join(T, "fila-lixo.json"), "w") as f:
    f.write("isto nao e json")
os.makedirs(os.path.join(T, "fila-dir.json"), exist_ok=True)
PYEOF
python3 -I "$T/fx.py" "$FX" "$NOW" || { echo "o gerador de fixtures falhou"; exit 2; }
# os arquivos soltos (logs do Pilot, filas) moram em $FX; as cidades também
RT="$FX/rota"; OC="$FX/ocup"; MU="$FX/muitas"; FU="$FX/funil"; SR="$FX/sr"; LR="$FX/lr"; DR="$FX/dr"; NA="$FX/na"; VZ="$FX/vz"; LX="$FX/lx"; DN="$FX/dn"
PLU="$FX/pilot-utc.log"; PLB="$FX/pilot-brt.log"; NOPILOT="$FX/nao-existe.log"; NOFILA="$FX/nao-existe.json"

# ---- a ferramenta de mutante: troca UM trecho (ou mais, em pares) e FALHA se algum sumiu ou se repete
cat > "$T/mut.py" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
pares = sys.argv[3:]
s = open(src, encoding="utf-8").read()
for i in range(0, len(pares), 2):
    old, new = pares[i], pares[i + 1]
    c = s.count(old)
    if c != 1:
        sys.stderr.write("trecho %s (%d vezes): %s\n" % ("ausente" if c == 0 else "repetido", c, old[:90]))
        sys.exit(3)
    s = s.replace(old, new, 1)
open(dst, "w", encoding="utf-8").write(s)
PYEOF

SCRIPT="$REAL"; VERBOSE=0; OUT=""; RC=0; J=""
# run <TZ> <args…>: roda o relatório (SCRIPT) com a hora fixa; $OUT = stdout, $RC = rc. NOWENV (se definida, mesmo vazia) troca a hora fixa
run() { local tz=$1; shift; OUT=$(WA_NODE_REPORT_NOW="${NOWENV-$NOW}" TZ="$tz" python3 -I "$SCRIPT" "$@" 2>"$T/err"); RC=$?; }
# jrun <TZ> <cidade> [args…]: --json, com o log do Pilot e a fila ausentes (um --pilot-log/--dispatchable depois vale por último)
jrun() { local tz=$1 city=$2; shift 2; run "$tz" --city "$city" --pilot-log "$NOPILOT" --dispatchable "$NOFILA" --json "$@"; J=$OUT; }
trun() { local tz=$1 city=$2; shift 2; run "$tz" --city "$city" --pilot-log "$NOPILOT" --dispatchable "$NOFILA" "$@"; }
jf() { printf '%s' "$J" | jq -r "$1" 2>/dev/null; }
# eq <atual> <esperado> <rótulo>: no caso real (VERBOSE=1) diz o que veio; no mutante fica quieto
# Número compara como número: o jq 1.7 devolve 24.0 como veio do Python e o 1.6 devolve 24 — o selftest não pode depender da versão do jq.
# Texto compara como texto (inclui "null", "true", ids e horas).
eq() {
  [ "$1" = "$2" ] && return 0
  case "$1$2" in *[!0-9.-]*) ;; *) awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && b != "" && a + 0 == b + 0) }' && return 0 ;; esac
  [ "$VERBOSE" = 1 ] && printf '      %s: esperado [%s] veio [%s]\n' "$3" "$2" "$1" >&2
  return 1
}
has() { printf '%s' "$1" | grep -qF -- "$2" && return 0; [ "$VERBOSE" = 1 ] && printf '      faltou no texto: %s\n' "$2" >&2; return 1; }
hasnt() { printf '%s' "$1" | grep -qF -- "$2" || return 0; [ "$VERBOSE" = 1 ] && printf '      não podia estar no texto: %s\n' "$2" >&2; return 1; }
vf() { jf ".rota.analise.veredito_final[\"$1\"]"; }
cf() { jf ".rota.analise.node_para_conferir[]|select(.bead==\"$1\")|$2"; }
oh() { jf ".ocupacao.analise.horas[]|select(.hora==\"$1\")|$2"; }
fc() { jf ".funil.analise.categorias.$1|\"\(.linhas)/\(.beads)\""; }
H09="2026-10-20T09:00Z"; H08="2026-10-20T08:00Z"; H10="2026-10-20T10:00Z"; H11="2026-10-20T11:00Z"

# ============================== ROTA ==============================
chk_veredito_final() {
  jrun UTC "$RT"; eq "$RC" 0 rc && eq "$(jf .rota.estado)" ok estado &&
  eq "$(vf node-despachada)" 1 despachada && eq "$(vf node-sombra)" 2 sombra && eq "$(vf node-sem-vaga)" 3 sem-vaga &&
  eq "$(vf node-sem-etiqueta)" 1 sem-etiqueta && eq "$(vf mini)" 4 mini && eq "$(vf nao-sei)" 2 nao-sei &&
  eq "$(jf '.rota.analise.fora_do_veredito|to_entries|map("\(.key)=\(.value)")|join(",")')" "nao-elegivel=2,nao-li=1" fora
}
chk_sombra_nao_e_entrega() {
  jrun UTC "$RT"; eq "$(jf '.rota.analise.ao_no_de_verdade|join(",")')" wa-n2 ao_no && eq "$(jf .rota.analise.soltas)" 1 soltas &&
  trun UTC "$RT" && has "$OUT" "WhatsApp ao nó DE VERDADE (atribuída pelo despachante): 1 bead(s) — wa-n2; soltas depois da entrega: 1"
}
chk_ultimo_por_hora() { jrun UTC "$RT"; eq "$(cf wa-w1 .ultimo)" node-sombra "ultimo de w1" && eq "$(cf wa-u1 .ultimo)" mini "ultimo de u1" && eq "$(cf wa-u2 .ultimo)" nao-sei "ultimo de u2"; }
chk_instaveis() {
  jrun UTC "$RT"; eq "$(jf '.rota.analise.instaveis|join(",")')" "wa-u1,wa-u2,wa-w1" instaveis &&
  trun UTC "$RT" && has "$OUT" "ATENÇÃO — mudaram de veredito" && has "$OUT" "wa-u1, wa-u2, wa-w1"
}
chk_conferir_lista() {
  jrun UTC "$RT"; eq "$RC" 0 rc &&
  eq "$(jf '.rota.analise.node_para_conferir|map(.bead)|join(",")')" "wa-e1,wa-n1,wa-n2,wa-n3,wa-n4,wa-n5,wa-u1,wa-u2,wa-w1" lista &&
  eq "$(cf wa-n1 .ultimo)" node-sombra n1 && eq "$(cf wa-n3 .ultimo)" node-sem-vaga n3 && eq "$(cf wa-e1 .ultimo)" node-sem-etiqueta e1 &&
  trun UTC "$RT" && has "$OUT" "PARA CONFERIR UMA A UMA" && has "$OUT" "wa-n1  [node, só sombra (dry-run), base label]  razões: code; test-sem-dado"
}
chk_base() {
  jrun UTC "$RT"
  eq "$(cf wa-n1 .base)" label base-n1 && eq "$(cf wa-n2 .base)" label base-n2 && eq "$(cf wa-w1 .base)" doc base-w1 && eq "$(cf wa-u1 .base)" code base-u1 &&
  eq "$(cf wa-e1 .base)" code base-e1 && eq "$(cf wa-n3 .base)" null base-n3-capacidade
}
chk_razoes() {
  jrun UTC "$RT"
  eq "$(cf wa-n1 '.razoes|tojson')" '["code","test-sem-dado"]' n1 && eq "$(cf wa-w1 '.razoes|join(",")')" "r1,r2,r3,r4,r5,r6" w1-no-maximo-6 &&
  eq "$(cf wa-n2 '.razoes|tojson')" null n2-vazio && eq "$(cf wa-u1 '.razoes|tojson')" null u1-texto && eq "$(cf wa-u2 '.razoes|tojson')" null u2-nao-lista
}
chk_razoes_so_rc0() { jrun UTC "$RT"; eq "$(cf wa-e1 '.razoes|tojson')" null "e1 (linha do Pilot com rc 10)"; }
chk_apply_ilegivel() {
  jrun UTC "$RT"; eq "$(jf .rota.analise.apply_ilegivel)" 4 apply_ilegivel && eq "$(jf .rota.analise.beads_distintas)" 16 beads && eq "$(jf .rota.analise.decisoes)" 19 decisoes
}
chk_linhas_ilegiveis() {
  jrun UTC "$RT"; eq "$(jf .rota.ilegiveis)" 3 ilegiveis && eq "$(jf .rota.analise.sem_hora)" 2 sem_hora &&
  trun UTC "$RT" && has "$OUT" "3 linha(s) ilegível(is), contadas e fora das contas" && has "$OUT" "2 sem hora legível" &&
  has "$OUT" "linhas de apply ilegíveis: 4; leituras de bead que falharam: 2"
}
chk_janela_rota() {
  jrun UTC "$RT"; eq "$(jf .rota.analise.linhas_na_janela)" 34 linhas && eq "$(jf .rota.analise.primeira)" "$((NOW-86400))" primeira && eq "$(jf .rota.analise.ultima)" "$NOW" ultima &&
  eq "$(jf '.rota.analise.node_para_conferir|map(.bead)|(index("wa-edge-out")), (index("wa-old")), (index("wa-future"))|tostring')" "$(printf 'null\nnull\nnull')" "fora da janela"
}
chk_cobertura() { jrun UTC "$RT"; eq "$(jf .rota.analise.horas_cobertas)" 24 horas && trun UTC "$RT" && has "$OUT" "(24,00 h), 34 linha(s) na janela"; }
chk_modos() {
  jrun UTC "$RT"; eq "$RC" 0 rc && eq "$(jf '.rota.analise.modos|to_entries|map("\(.key)=\(.value)")|join(",")')" "?=1,label=2,shadow=4" modos &&
  eq "$(jf '.rota.analise.pilot_ultimo|tojson')" '{"mode":"shadow","slots":"3","spawn":"pilot"}' pilot_ultimo
}
chk_soltas_leituras() { jrun UTC "$RT"; eq "$(jf .rota.analise.soltas)" 1 soltas && eq "$(jf .rota.analise.leituras_que_falharam)" 2 leituras; }
chk_ordem_do_arquivo() { jrun UTC "$RT"; eq "$(vf node-sombra)" 2 sombra && eq "$(vf mini)" 4 mini && eq "$(cf wa-w1 .ultimo)" node-sombra w1; }

# ============================== PRONTIDÃO ==============================
chk_prontidao_falta() {
  jrun UTC "$RT"; eq "$(jf .prontidao.suficiente_para_revisar)" false suficiente && eq "$(jf '.prontidao.falta|join(";")')" "16 bead(s) distinta(s) de 30" falta &&
  trun UTC "$RT" && has "$OUT" 'INSUFICIENTE: 16 bead(s) distinta(s) de 30. Não ligue o `auto` com isto.'
}
chk_prontidao_beads_na_borda() {
  jrun UTC "$RT" --min-beads 16; eq "$(jf .prontidao.suficiente_para_revisar)" true "16 de 16" && eq "$(jf .prontidao.a_conferir)" 9 a_conferir && eq "$(jf .prontidao.instaveis)" 3 instaveis &&
  trun UTC "$RT" --min-beads 16 && has "$OUT" "base suficiente PARA REVISAR: confira as 9 bead(s) node da lista acima; 3 mudaram de veredito" && has "$OUT" "Quem liga o auto é uma pessoa" &&
  jrun UTC "$RT" --min-beads 17 && eq "$(jf .prontidao.suficiente_para_revisar)" false "16 de 17"
}
chk_prontidao_horas_na_borda() {
  jrun UTC "$RT" --min-beads 1 --min-hours 24; eq "$(jf .prontidao.suficiente_para_revisar)" true "24 h de 24" &&
  jrun UTC "$RT" --min-beads 1 --min-hours 25 && eq "$(jf .prontidao.suficiente_para_revisar)" false "24 h de 25" && eq "$(jf '.prontidao.falta|join(";")')" "a sombra cobre 24,0 h de 25" falta
}
chk_prontidao_nunca_aprova() { trun UTC "$RT" --min-beads 1; hasnt "$OUT" "aprovad" && hasnt "$OUT" "APROVAD"; }

# ============================== OCUPAÇÃO (sempre em TZ=BRT3: a hora do rótulo é UTC mesmo assim) ==============================
chk_ocup_totais() {
  jrun BRT3 "$OC"; eq "$RC" 0 rc && eq "$(jf .ocupacao.estado)" ok estado && eq "$(jf .ocupacao.analise.leituras)" 13 leituras && eq "$(jf .ocupacao.analise.sem_epoch)" 3 sem_epoch &&
  eq "$(jf .ocupacao.analise.cpu_lidas)" 7 cpu_lidas && eq "$(jf .ocupacao.analise.cpu_sem_leitura)" 6 cpu_sem && eq "$(jf .ocupacao.analise.pct_medio)" 73.6 pct_medio &&
  eq "$(jf .ocupacao.analise.perto_de_100)" 4 perto && eq "$(jf .ocupacao.analise.perto_de_100_pct)" 57.1 perto_pct &&
  eq "$(jf .ocupacao.analise.sessoes_lidas)" 7 sess_lidas && eq "$(jf .ocupacao.analise.sessoes_nao_lidas)" 6 sess_nao && eq "$(jf .ocupacao.analise.leituras_com_wa_no_no)" 3 com_wa
}
chk_ocup_horas_utc() {
  jrun BRT3 "$OC"; eq "$(jf '.ocupacao.analise.horas|map(.hora)|join(",")')" "2026-10-19T12:00Z,2026-10-20T08:00Z,$H09,$H10,$H11,2026-10-20T12:00Z" horas
}
chk_ocup_hora09() {
  jrun BRT3 "$OC"; eq "$(oh $H09 .leituras)" 4 leituras && eq "$(oh $H09 .cpu_lidas)" 2 lidas && eq "$(oh $H09 .cpu_sem)" 2 sem && eq "$(oh $H09 .pct_medio)" 90 medio &&
  eq "$(oh $H09 .pct_min)" 80 min && eq "$(oh $H09 .pct_max)" 100 max && eq "$(oh $H09 .nucleos_medio)" 16 nucleos
}
chk_ocup_wa_remoto() { jrun BRT3 "$OC"; eq "$(oh $H09 .wa_medio)" 1 "wa remoto na hora 09 (o wa-worker-1 do mini não conta)" && eq "$(oh $H11 .wa_medio)" 1 hora11; }
chk_ocup_hora_sem_cpu() {
  jrun BRT3 "$OC"; eq "$(oh $H08 .pct_medio)" null "08Z pct_medio" && eq "$(oh $H08 .pct_min)" null "08Z min" && eq "$(oh $H08 .cpu_lidas)" 0 "08Z lidas" && eq "$(oh $H08 .wa_medio)" null "08Z wa" &&
  eq "$(oh $H10 .pct_medio)" 0 "10Z: o 0% de verdade" && eq "$(oh $H10 .cpu_lidas)" 1 "10Z lidas" && eq "$(oh $H10 .cpu_sem)" 2 "10Z sem" && eq "$(oh $H11 .pct_medio)" 92.5 "11Z"
}
chk_ocup_texto() {
  trun BRT3 "$OC"; has "$OUT" "13 leitura(s) na janela (esperadas ~96, uma a cada 15 min); CPU lida em 7, SEM CPU lida em 6" &&
  has "$OUT" "Média da janela: 73,6%; leituras com CPU >= 90%: 4 de 7 (57,1%)" && has "$OUT" "sessões wa-worker-remote vivas em 3 leitura(s) (de 7 com sessões lidas; 6 sem sessões lidas)" &&
  printf '%s\n' "$OUT" | grep -qE "^  $H08 +2 +0 +— +— +— +— +—$" && printf '%s\n' "$OUT" | grep -qE "^  $H10 +3 +1 +0,0 +0,0 +0,0 +16,00 +0,00$"
}
chk_ocup_bordas() {
  jrun BRT3 "$OC"; eq "$(oh 2026-10-19T12:00Z .leituras)" 1 "a leitura exatamente na borda de baixo" && eq "$(oh 2026-10-20T12:00Z .leituras)" 1 "a leitura exatamente agora (a de agora+1s fica fora)"
}
chk_sem_epoch() { jrun BRT3 "$OC"; eq "$(jf .ocupacao.analise.sem_epoch)" 3 "sem epoch / epoch em texto / epoch NaN" && trun BRT3 "$OC" && hasnt "$OUT" "janela de 24 h, até 2026-10-20T12:00:00Z." ; }
chk_tabela_72() {
  run UTC --city "$MU" --pilot-log "$NOPILOT" --dispatchable "$NOFILA" --hours 100; local t="$OUT" rc=$RC
  eq "$rc" 0 rc && eq "$(printf '%s\n' "$t" | grep -cE '^  20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:00Z ')" 72 "linhas da tabela" && has "$t" "(8 hora(s) mais antigas omitidas aqui; --json traz todas)" &&
  printf '%s\n' "$t" | grep -qE '^  2026-10-17T13:00Z ' && printf '%s\n' "$t" | grep -qE '^  2026-10-20T12:00Z ' &&
  run UTC --city "$MU" --pilot-log "$NOPILOT" --dispatchable "$NOFILA" --hours 100 --json && J=$OUT && eq "$(jf '.ocupacao.analise.horas|length')" 80 "o JSON traz todas"
}

# ============================== FUNIL ==============================
funil_esperado() { # <TZ> <log do Pilot>
  run "$1" --city "$FU" --pilot-log "$2" --dispatchable "$NOFILA" --json; J=$OUT
  eq "$RC" 0 rc && eq "$(jf .funil.estado)" ok estado && eq "$(jf .funil.analise.rodadas)" 3 rodadas &&
  eq "$(fc cedida)" "6/3" cedida && eq "$(fc teto)" "4/3" teto && eq "$(fc claim)" "3/2" claim && eq "$(fc mini)" "2/2" mini &&
  eq "$(jf .funil.analise.no_gancho)" 2 no_gancho && eq "$(jf .funil.analise.ao_no)" 0 ao_no && eq "$(jf .funil.analise.pararam_antes)" 4 pararam_antes
}
chk_funil_utc() { funil_esperado UTC "$PLU"; }
chk_funil_fuso() { funil_esperado BRT3 "$PLB"; }
chk_funil_texto() {
  run UTC --city "$FU" --pilot-log "$PLU" --dispatchable "$NOFILA"; has "$OUT" "3 rodada(s) do Pilot na janela" &&
  has "$OUT" "pararam antes do gancho (cedidas ou no teto) e não tiveram decisão na rota: 4 bead(s) — o nó nunca viu essas beads"
}
chk_funil_sem_rota() {
  run UTC --city "$SR" --pilot-log "$PLU" --dispatchable "$NOFILA" --json; J=$OUT
  eq "$RC" 0 rc && eq "$(jf .funil.estado)" ok estado && eq "$(jf .funil.analise.pararam_antes)" null pararam_antes && eq "$(jf .funil.analise.no_gancho)" null no_gancho && eq "$(jf .funil.analise.ao_no)" null ao_no &&
  eq "$(fc cedida)" "6/3" cedida && run UTC --city "$SR" --pilot-log "$PLU" --dispatchable "$NOFILA" && has "$OUT" "NÃO SEI — o log de rota (seção 1) não foi lido"
}
chk_funil_estados() {
  run UTC --city "$FU" --pilot-log "$NOPILOT" --dispatchable "$NOFILA" --json; J=$OUT; eq "$(jf .funil.estado)" ausente "log do Pilot ausente" && eq "$(jf .funil.analise)" null "sem análise" &&
  run UTC --city "$FU" --pilot-log "$FX/pilot-dir.log" --dispatchable "$NOFILA" --json && J=$OUT && eq "$(jf .funil.estado)" ilegivel "pasta no lugar do log" &&
  run UTC --city "$FU" --pilot-log "$FX/pilot-vazio.log" --dispatchable "$NOFILA" --json && J=$OUT && eq "$(jf .funil.estado)" vazio "log vazio" &&
  run UTC --city "$FU" --pilot-log "$NOPILOT" --dispatchable "$NOFILA" && has "$OUT" "AUSENTE" && has "$OUT" "NÃO é zero"
}
chk_wa_id_sem_ponto() { # o id não leva o ponto final da frase: carrega o módulo e testa as linhas do Pilot de verdade
  python3 -I - "$SCRIPT" <<'PYEOF' >/dev/null 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wa_node_report", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
casos = [("claim", "[2026-10-14 02:06:40] [pilot-dispatcher] Claim acquired on wa-qp98sy.", "wa-qp98sy"),
         ("claim", "[2026-10-14 02:06:40] [pilot-dispatcher] Claim acquired on wa-hut4l5.4.", "wa-hut4l5.4")]
for cat, linha, esperado in casos:
    achou = [rx.search(linha) for c, rx in m.FUNIL if c == cat]
    achou = [x for x in achou if x]
    assert len(achou) == 1 and achou[0].group(1) == esperado, (linha, [x.group(1) for x in achou])
PYEOF
}

# ============================== FILA ==============================
fila_run() { run UTC --city "$FU" --pilot-log "$NOPILOT" --dispatchable "$1" "${@:2}"; }
chk_fila_ok() {
  fila_run "$FX/fila-ok.json" --json; J=$OUT
  eq "$(jf .fila.estado)" ok estado && eq "$(jf .fila.analise.wa)" 6 wa && eq "$(jf .fila.analise.total)" 9 total && eq "$(jf '.fila.analise.prioridades|tojson')" '{"0":1,"1":2,"2":1,"3":1,"?":1}' prioridades &&
  eq "$(jf .fila.analise.idade_s)" 2400 idade && eq "$(jf .fila.analise.ttl_s)" 1800 ttl
}
chk_fila_texto() {
  fila_run "$FX/fila-ok.json"; has "$OUT" "fila despachável: 6 de WA entre 9 (gerada há 40 min, VENCIDA); por prioridade: P0=1, P1=2, P2=1, P3=1, P?=1" &&
  fila_run "$FX/fila-fresca.json" && has "$OUT" "gerada há 2 min)" && hasnt "$OUT" "VENCIDA"
}
chk_fila_hora_ruim() {
  fila_run "$FX/fila-futura.json" --json; J=$OUT; eq "$(jf .fila.analise.idade_s)" null "gerada no futuro" &&
  fila_run "$FX/fila-sem-hora.json" --json && J=$OUT && eq "$(jf .fila.analise.idade_s)" null "sem hora" &&
  fila_run "$FX/fila-futura.json" && has "$OUT" "sem hora de geração legível" && hasnt "$OUT" "gerada há -"
}
chk_fila_estados() {
  local f e
  for f in fila-itens-texto fila-lista fila-lixo fila-dir; do
    fila_run "$FX/$f.json" --json; J=$OUT; e=$(jf .fila.estado)
    [ "$e" = ilegivel ] || { [ "$VERBOSE" = 1 ] && echo "      $f: esperado ilegivel, veio $e" >&2; return 1; }
  done
  fila_run "$NOFILA" --json; J=$OUT; eq "$(jf .fila.estado)" ausente "fila ausente" && eq "$(jf .fila.analise)" null "sem análise"
}

# ============================== ESTADOS E CÓDIGOS DE SAÍDA ==============================
chk_rc3_nenhum_log() {
  jrun UTC "$NA"; eq "$RC" 3 "cidade sem logs" && eq "$(jf .rota.estado)" ausente rota && eq "$(jf .ocupacao.estado)" ausente ocupacao && eq "$(jf .prontidao)" null prontidao &&
  grep -q 'nenhum dos dois logs' "$T/err" &&
  jrun UTC "$LX" && eq "$RC" 3 "os dois ilegíveis" && eq "$(jf .rota.estado)" ilegivel "rota lixo" && eq "$(jf .ocupacao.estado)" ilegivel "ocupação lixo" &&
  jrun UTC "$DN" && eq "$RC" 3 "rota é pasta, ocupação ausente" && eq "$(jf .rota.estado)" ilegivel "rota pasta"
}
chk_rc0_basta_um() {
  jrun UTC "$SR"; eq "$RC" 0 "rota ausente, ocupação ok" && eq "$(jf .rota.estado)" ausente "SR rota" && eq "$(jf .ocupacao.estado)" ok "SR ocupação" && eq "$(jf .prontidao)" null "SR prontidão" &&
  trun UTC "$SR" && has "$OUT" "sem log de rota utilizável (ausente ou ilegível): não dá para dizer" &&
  jrun UTC "$LR" && eq "$RC" 0 "rota só lixo, ocupação ok" && eq "$(jf .rota.estado)" ilegivel "LR rota" && eq "$(jf .rota.ilegiveis)" 2 "LR ilegíveis" &&
  jrun UTC "$DR" && eq "$RC" 0 "rota é pasta, ocupação ok" && eq "$(jf .rota.estado)" ilegivel "DR rota"
}
chk_rota_vazia() {
  jrun UTC "$VZ"; eq "$RC" 0 rc && eq "$(jf .rota.estado)" vazio estado && eq "$(jf .rota.analise.beads_distintas)" 0 beads && eq "$(jf .prontidao.suficiente_para_revisar)" false suficiente &&
  trun UTC "$VZ" && has "$OUT" "vazio (" && has "$OUT" "nenhuma linha ainda" && has "$OUT" "INSUFICIENTE: a sombra cobre 0,0 h de 24; 0 bead(s) distinta(s) de 30"
}
chk_ausente_nao_e_zero() { trun UTC "$NA"; has "$OUT" "AUSENTE" && has "$OUT" "ainda não houve rodada, isto NÃO é zero"; }
chk_args_rc2() {
  local a
  for a in "--hours 0" "--hours abc" "--hours -5" "--hours 5x" "--hours 100000" "--hours 1.5" "--min-hours x" "--min-beads -1" "--busy-pct 0" "--busy-pct 101" "--bogus"; do
    run UTC --city "$RT" $a
    [ "$RC" = 2 ] || { [ "$VERBOSE" = 1 ] && echo "      '$a' → rc $RC (esperado 2)" >&2; return 1; }
  done
  run UTC --city "$RT" --hours ""; eq "$RC" 2 "--hours vazio"
}
chk_args_validos() {
  local a
  for a in "--hours 1" "--hours 99999" "--busy-pct 100" "--busy-pct 1" "--min-hours 0" "--min-beads 0"; do
    run UTC --city "$RT" --pilot-log "$NOPILOT" --dispatchable "$NOFILA" $a
    [ "$RC" = 0 ] || { [ "$VERBOSE" = 1 ] && echo "      '$a' → rc $RC (esperado 0)" >&2; return 1; }
  done
}
chk_horas_decimal() {
  jrun UTC "$RT" --hours 010; eq "$(jf .janela.horas)" 10 "010 é dez" && eq "$(jf .rota.analise.primeira)" "$((NOW-36000))" "a janela de 10 h abre em agora-10h" &&
  jrun UTC "$RT" && eq "$(jf .janela.horas)" 24 padrao && eq "$(jf .janela.inicio)" "$((NOW-86400))" inicio && eq "$(jf .janela.fim)" "$NOW" fim
}
chk_now_env() {
  NOWENV=abc; run UTC --city "$RT"; local r1=$RC
  NOWENV=""; run UTC --city "$NA" --pilot-log "$NOPILOT" --dispatchable "$NOFILA"; local r2=$RC
  unset NOWENV; eq "$r1" 2 "WA_NODE_REPORT_NOW=abc" && eq "$r2" 3 "WA_NODE_REPORT_NOW vazio = a hora de agora"
}
chk_somente_leitura() {
  local a b d
  a=$(cd "$T" && { find fx -type f -exec cksum {} +; find fx; } | sort)
  for d in rota ocup muitas funil sr lr dr na vz lx dn; do jrun UTC "$FX/$d"; trun BRT3 "$FX/$d" --hours 100; done
  b=$(cd "$T" && { find fx -type f -exec cksum {} +; find fx; } | sort)
  eq "$a" "$b" "a árvore de fixtures depois de rodar tudo"
}
chk_json_uma_linha() {
  local d
  for d in rota ocup funil na vz; do
    jrun UTC "$FX/$d"
    printf '%s' "$J" | jq -e 'type=="object"' >/dev/null 2>&1 || { [ "$VERBOSE" = 1 ] && echo "      $d: a saída não é um objeto JSON" >&2; return 1; }
    eq "$(printf '%s\n' "$J" | wc -l | tr -d ' ')" 1 "$d: linhas" || return 1
    eq "$(jf 'keys|join(",")')" "fila,funil,janela,ocupacao,prontidao,rota" "$d: chaves" || return 1
  done
}

# ---- o caso real: cada função tem de passar contra o script de verdade
check() { SCRIPT="$REAL"; VERBOSE=1; if "chk_$1"; then ok "$1"; else bad "$1"; fi; VERBOSE=0; }
for c in veredito_final sombra_nao_e_entrega ultimo_por_hora instaveis conferir_lista base razoes razoes_so_rc0 apply_ilegivel linhas_ilegiveis janela_rota cobertura modos soltas_leituras ordem_do_arquivo \
         prontidao_falta prontidao_beads_na_borda prontidao_horas_na_borda prontidao_nunca_aprova \
         ocup_totais ocup_horas_utc ocup_hora09 ocup_wa_remoto ocup_hora_sem_cpu ocup_texto ocup_bordas sem_epoch tabela_72 \
         funil_utc funil_fuso funil_texto funil_sem_rota funil_estados wa_id_sem_ponto \
         fila_ok fila_texto fila_hora_ruim fila_estados \
         rc3_nenhum_log rc0_basta_um rota_vazia ausente_nao_e_zero args_rc2 args_validos horas_decimal now_env somente_leitura json_uma_linha; do
  check "$c"
done

# ---- controle negativo: cada mutante quebra UM trecho do script; a função designada tem de reprovar
# mut <nome> <função> <velho> <novo> [<velho> <novo>…]
mut() {
  local name=$1 chk=$2; shift 2
  [ -n "${WA_NODE_REPORT_ST_NOMUT:-}" ] && return 0
  MUTANTS=$((MUTANTS+1))
  SCRIPT="$T/mut-$name.py"
  if ! python3 -I "$T/mut.py" "$REAL" "$SCRIPT" "$@" 2>"$T/mut.err"; then bad "mutante $name: $(cat "$T/mut.err") — o script mudou: atualize o mutante"; return; fi
  if ! python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$SCRIPT" 2>/dev/null; then bad "mutante $name: a cópia mutada nem compila (um erro de sintaxe não prova nada)"; return; fi
  VERBOSE=0
  if "$chk"; then bad "mutante SOBREVIVEU: $name ($chk não notou)"; else ok "mutante morto: $name"; fi
}
nl=$'\n'
# -- rota
mut sombra-vira-despachada chk_sombra_nao_e_entrega 'return "node-sombra"' 'return "node-despachada"'
mut despachada-sem-marca chk_sombra_nao_e_entrega '            if c == "node-despachada":' '            if False:'
mut dryrun-sem-prefixo chk_veredito_final 'if rc == 0 and detail.startswith("dry-run:"):' 'if rc == 0:'
mut etiqueta-vira-mini chk_veredito_final 'return "node-sem-etiqueta" if detail.startswith("base=") else "mini"' 'return "mini"'
mut unknown-vira-nao-li chk_veredito_final 'return "nao-sei" if detail.startswith("classificador:unknown") else "nao-li"' 'return "nao-li"'
mut capacidade-vira-nao-elegivel chk_veredito_final 'return "node-sem-vaga" if re.split(r"[ =:]", detail, 1)[0] in SEM_VAGA else "nao-elegivel"' 'return "nao-elegivel"'
mut split-sem-dois-pontos chk_veredito_final 'r"[ =:]"' 'r"[ =]"'
mut nao-elegivel-vira-sem-vaga chk_veredito_final 'in SEM_VAGA else "nao-elegivel"' 'in SEM_VAGA else "node-sem-vaga"'
mut rc-bool-vale-int chk_apply_ilegivel 'if isinstance(rc, bool) or not isinstance(rc, int) or not isinstance(det, str):' 'if not isinstance(rc, int) or not isinstance(det, str):'
mut apply-ilegivel-calado chk_apply_ilegivel "                apply_ilegivel += 1${nl}                continue${nl}            decisoes += 1" "                continue${nl}            decisoes += 1"
mut ordem-do-arquivo chk_ordem_do_arquivo 'ev.sort(key=lambda t: (t[0], t[1]))' 'ev.sort(key=lambda t: t[1])'
mut janela-rota-baixa-exclusiva chk_janela_rota '        elif lo <= e <= hi:' '        elif lo < e <= hi:'
mut janela-rota-alta-exclusiva chk_janela_rota '        elif lo <= e <= hi:' '        elif lo <= e < hi:'
mut janela-rota-sem-teto chk_janela_rota '        elif lo <= e <= hi:' '        elif lo <= e:'
mut primeiro-no-lugar-do-ultimo chk_ultimo_por_hora "            b[\"final\"] = vs[-1]${nl}            final[vs[-1]] += 1" "            b[\"final\"] = vs[0]${nl}            final[vs[0]] += 1"
mut instavel-so-mini chk_instaveis 'any(c in ("mini", "nao-sei") for c in vs)' 'any(c == "mini" for c in vs)'
mut conferir-so-o-final chk_conferir_lista 'if any(c in NODE_CATS for c in b["cats"]))' 'if b.get("final") in NODE_CATS)'
mut cobertura-em-minutos chk_cobertura '/ 3600.0, 2)' '/ 60.0, 2)'
mut razoes-com-qualquer-rc chk_razoes_so_rc0 'if is_rc(r, 0) and isinstance(out, str) and out.strip():' 'if isinstance(out, str) and out.strip():'
mut razoes-sem-teto chk_razoes '[str(x) for x in rs][:6]' '[str(x) for x in rs]'
mut razoes-nao-lista chk_razoes 'if isinstance(rs, list):' 'if rs:'
mut modo-nao-texto chk_modos 'mo = r.get("mode") if isinstance(r.get("mode"), str) else "?"' 'mo = r.get("mode")'
mut solta-qualquer-rc chk_soltas_leituras 'elif kind == "release" and is_rc(r, 0):' 'elif kind == "release":'
mut leitura-so-read chk_soltas_leituras 'elif kind in ("read", "classify"):' 'elif kind in ("read",):'
mut base-solta-demais chk_base 'if c in ("node-sombra", "node-despachada"):' 'if c in NODE_CATS:' 'm = re.match(r"(?:dry-run: iria para|despachada para) \S+ \(([A-Za-z0-9_-]+)\)", det)' 'm = re.search(r"\(([A-Za-z0-9_-]+)\)", det)'
mut etiqueta-sem-base chk_base 'm = re.match(r"base=([A-Za-z0-9_-]+)", det)' 'm = None'
mut array-nao-conta chk_linhas_ilegiveis "        else:${nl}            bad += 1${nl}    if not rows and bad:" "        else:${nl}            pass${nl}    if not rows and bad:"
# -- prontidão
mut beads-no-minimo-nao-basta chk_prontidao_beads_na_borda 'if rota["beads_distintas"] < min_beads:' 'if rota["beads_distintas"] <= min_beads:'
mut horas-no-minimo-nao-basta chk_prontidao_horas_na_borda 'if rota["horas_cobertas"] < min_hours:' 'if rota["horas_cobertas"] <= min_hours:'
mut suficiente-sempre chk_prontidao_falta '"suficiente_para_revisar": not falta' '"suficiente_para_revisar": True'
# -- ocupação
mut cpu-nao-lido-vira-zero chk_ocup_totais 'if isinstance(cpu, dict) and cpu.get("lido") is True else None' 'if isinstance(cpu, dict) else None'
mut cpu-fora-da-faixa chk_ocup_totais 'not (0.0 <= pct <= 100.0)' 'not (0.0 <= pct)'
mut bool-e-numero chk_ocup_totais 'if isinstance(x, bool) or not isinstance(x, (int, float)):' 'if not isinstance(x, (int, float)):'
mut nan-e-numero chk_sem_epoch 'return float(x) if math.isfinite(x) else None' 'return float(x)'
mut hora-local chk_ocup_horas_utc 'time.strftime("%Y-%m-%dT%H:00Z", time.gmtime(ep))' 'time.strftime("%Y-%m-%dT%H:00Z", time.localtime(ep))'
mut perto-estrito chk_ocup_totais 'if pct >= busy_pct:' 'if pct > busy_pct:'
mut wa-prefixo-largo chk_ocup_wa_remoto 'n.startswith("wa-worker-remote")' 'n.startswith("wa-worker")'
mut sessoes-nao-lidas-viram-zero chk_ocup_totais 'if isinstance(ss, dict) and ss.get("lido") is True else None' 'if isinstance(ss, dict) else None'
mut nome-nao-texto chk_ocup_totais 'if isinstance(nomes, list) and all(isinstance(n, str) for n in nomes):' 'if isinstance(nomes, list):'
mut media-hora-por-leitura chk_ocup_hora09 'round(h["soma_pct"] / h["cpu_lidas"], 1) if h["cpu_lidas"] else None' 'round(h["soma_pct"] / h["leituras"], 1) if h["cpu_lidas"] else None'
mut media-janela-por-leitura chk_ocup_totais '"pct_medio": round(soma_pct / cpu_ok, 1) if cpu_ok else None' '"pct_medio": round(soma_pct / total, 1) if cpu_ok else None'
mut hora-sem-cpu-vira-zero chk_ocup_hora_sem_cpu 'round(h["soma_pct"] / h["cpu_lidas"], 1) if h["cpu_lidas"] else None' 'round(h["soma_pct"] / h["cpu_lidas"], 1) if h["cpu_lidas"] else 0.0'
mut janela-ocup-baixa-exclusiva chk_ocup_bordas 'if not (lo <= ep <= hi):' 'if not (lo < ep <= hi):'
mut janela-ocup-alta-exclusiva chk_ocup_bordas 'if not (lo <= ep <= hi):' 'if not (lo <= ep < hi):'
mut sem-epoch-calado chk_sem_epoch "        if ep is None:${nl}            sem_epoch += 1${nl}            continue" "        if ep is None:${nl}            continue"
mut tabela-do-inicio chk_tabela_72 'tab = tab[-72:]' 'tab = tab[:72]'
mut tabela-sem-teto chk_tabela_72 'if len(tab) > 72:' 'if len(tab) > 10**6:'
# -- funil
mut funil-sem-fuso chk_funil_fuso 'e = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))' 'e = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))'
mut funil-sem-teto-de-hora chk_funil_utc 'if not (lo <= e <= hi):' 'if not (lo <= e):'
mut funil-sem-piso-de-hora chk_funil_utc 'if not (lo <= e <= hi):' 'if not (e <= hi):'
mut funil-rodadas-calado chk_funil_utc "        if \"=== Pilot sweep start\" in ln:${nl}            rodadas += 1${nl}            continue" "        if \"=== Pilot sweep start\" in ln:${nl}            continue"
mut funil-teto-so-um-padrao chk_funil_utc '    ("teto", re.compile(r"ga-in9ebr: wa-worker pool at session cap \(.*?\) — QUEUED " + WA_ID + r": claim released")),' ''
mut funil-mini-pega-o-no chk_funil_utc 'r" → wa-worker ")' 'r" → wa-worker")'
mut funil-qualquer-prefixo chk_funil_utc 'WA_ID = r"(wa-[A-Za-z0-9]+(?:\.[0-9]+)*)"' 'WA_ID = r"([a-z]+-[A-Za-z0-9]+(?:\.[0-9]+)*)"'
mut id-leva-o-ponto-final chk_wa_id_sem_ponto 'WA_ID = r"(wa-[A-Za-z0-9]+(?:\.[0-9]+)*)"' 'WA_ID = r"(wa-[A-Za-z0-9.]+)"'
mut pararam-so-cedidas chk_funil_utc 'antes = fa["categorias"]["cedida"]["_beads"] | fa["categorias"]["teto"]["_beads"]' 'antes = fa["categorias"]["cedida"]["_beads"]'
mut pararam-sem-rota-vira-todas chk_funil_sem_rota 'fa["pararam_antes"] = len(antes - ra["_beads"]) if ra else None' 'fa["pararam_antes"] = len(antes - ra["_beads"]) if ra else len(antes)'
mut no-gancho-sem-rota-vira-zero chk_funil_sem_rota 'fa["no_gancho"] = len(ra["_beads"]) if ra else None' 'fa["no_gancho"] = len(ra["_beads"]) if ra else 0'
mut ao-no-sem-rota-vira-zero chk_funil_sem_rota 'fa["ao_no"] = len(ra["ao_no_de_verdade"]) if ra else None' 'fa["ao_no"] = len(ra["ao_no_de_verdade"]) if ra else 0'
mut funil-ilegivel-vira-vazio chk_funil_estados "        return \"ilegivel\", None${nl}    cats = {" "        return \"vazio\", None${nl}    cats = {"
mut funil-ausente-vira-vazio chk_funil_estados "        return \"ausente\", None${nl}    except OSError:${nl}        return \"ilegivel\", None${nl}    cats = {" "        return \"vazio\", None${nl}    except OSError:${nl}        return \"ilegivel\", None${nl}    cats = {"
# -- fila
mut fila-items-nao-lista chk_fila_estados 'if not isinstance(o, dict) or not isinstance(o.get("items"), list):' 'if not isinstance(o, dict):'
mut fila-toda-loja chk_fila_ok 'isinstance(it, dict) and it.get("store") == "whatsapp_automation"' 'isinstance(it, dict)'
mut fila-idade-negativa chk_fila_hora_ruim '        if idade < 0:' '        if idade < -10**9:'
mut fila-vencida-invertida chk_fila_texto 'q["idade_s"] <= q["ttl_s"]' 'q["idade_s"] >= q["ttl_s"]'
mut fila-ilegivel-vira-ausente chk_fila_estados "    except (OSError, ValueError):${nl}        return \"ilegivel\", None" "    except (OSError, ValueError):${nl}        return \"ausente\", None"
mut fila-prioridade-fixa chk_fila_ok 'k = str(it.get("priority", "?"))' 'k = "?"'
# -- estados e saída
mut lixo-vira-vazio chk_rc3_nenhum_log '        return "ilegivel", [], bad' '        return "vazio", [], bad'
mut pasta-vira-ausente chk_rc3_nenhum_log "    except OSError:${nl}        return \"ilegivel\", [], 0" "    except OSError:${nl}        return \"ausente\", [], 0"
mut vazio-vira-ok chk_rota_vazia 'return ("ok" if rows else "vazio"), rows, bad' 'return "ok", rows, bad'
mut rc3-se-qualquer-um chk_rc0_basta_um 'if re_ not in ("ok", "vazio") and oe not in ("ok", "vazio"):' 'if re_ not in ("ok", "vazio") or oe not in ("ok", "vazio"):'
mut rc3-vira-zero chk_rc3_nenhum_log '        return 3' '        return 0'
mut prontidao-sem-rota chk_rc0_basta_um '"prontidao": prontidao(ra, a.min_hours, a.min_beads) if ra else None,' '"prontidao": prontidao(ra, a.min_hours, a.min_beads),'
mut ausente-sem-aviso chk_ausente_nao_e_zero '"ausente": "AUSENTE (%s): ainda não houve rodada, isto NÃO é zero" % caminho' '"ausente": "(%s)" % caminho'
mut horas-octal chk_horas_decimal 'int(a.hours, 10), int(a.min_hours, 10)' 'int(a.hours, 8), int(a.min_hours, 10)'
mut args-sem-fullmatch chk_args_rc2 'if not re.fullmatch(r"[0-9]{1,6}", v or "") or' 'if not re.match(r"[0-9]+", v or "") or'
mut horas-zero-vale chk_args_rc2 '("--hours", a.hours, 1, 99999)' '("--hours", a.hours, 0, 99999)'
mut horas-teto-menor chk_args_validos '("--hours", a.hours, 1, 99999)' '("--hours", a.hours, 1, 9999)'
mut busy-acima-de-100 chk_args_rc2 '("--busy-pct", a.busy_pct, 1, 100)' '("--busy-pct", a.busy_pct, 1, 1000)'
mut now-lixo-passa chk_now_env 'if now_env and not re.fullmatch(r"[0-9]{1,12}", now_env):' 'if False:'
mut now-vazio-quebra chk_now_env 'now = int(now_env, 10) if now_env else int(time.time())' 'now = int(now_env, 10)'
mut janela-em-minutos chk_horas_decimal 'lo, hi = now - a.hours * 3600, now' 'lo, hi = now - a.hours * 60, now'
mut escreve-na-cidade chk_somente_leitura '    rota_p, occ_p = os.path.join(city, ".gc", "wa-node-route.jsonl"), os.path.join(city, ".gc", "hetzner-occupancy.jsonl")' "    rota_p, occ_p = os.path.join(city, \".gc\", \"wa-node-route.jsonl\"), os.path.join(city, \".gc\", \"hetzner-occupancy.jsonl\")${nl}    open(os.path.join(city, \".gc\", \"x.tmp\"), \"w\").write(\"x\")"
mut json-em-varias-linhas chk_json_uma_linha 'json.dumps(res, ensure_ascii=False, sort_keys=True)' 'json.dumps(res, ensure_ascii=False, sort_keys=True, indent=2)'
mut json-sem-ordem-das-chaves chk_json_uma_linha 'json.dumps(res, ensure_ascii=False, sort_keys=True)' 'json.dumps({k: v for k, v in res.items() if k != "fila"}, ensure_ascii=False, sort_keys=True)'

if [ -z "${WA_NODE_REPORT_ST_NOMUT:-}" ]; then
  [ "$MUTANTS" -ge "$MIN_MUT" ] || { echo "FAIL o piso: só $MUTANTS mutantes (mínimo $MIN_MUT) — apagar mutantes não passa por 'todos mortos'"; fails=$((fails+1)); n=$((n+1)); }
  echo "mutantes: $MUTANTS"
else
  echo "mutantes: pulados (WA_NODE_REPORT_ST_NOMUT=1)"
fi
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
