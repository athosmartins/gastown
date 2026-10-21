#!/usr/bin/env bash
# wa-node-report.selftest.sh — hermético: o relatório lê fixtures de uma pasta temporária (rota, ocupação), com a hora fixada em WA_NODE_REPORT_NOW e o fuso em TZ. (ga-2hd02v.3)
#
# Contents
#   Casos · Controle negativo · O que não cobre · Como rodar
#
# CASOS (cada um é uma função chk_*; passa contra o script real e tem de REPROVAR contra os mutantes designados):
#   ROTA: veredito = o ÚLTIMO da bead na janela, ordenado pela hora e não pela ordem do arquivo · dry-run (sombra) nunca conta como entrega ao nó · capacidade (sem vaga) ≠ não elegível ≠ não li ≠ não sei ·
#     as que mudaram de veredito (em qualquer sentido) · a lista "para conferir" com a base e as razões (só de linha do Pilot com rc 0, no máximo 6, nunca de texto que não é lista) · linha de apply ilegível
#     (rc bool/texto, sem detalhe, sem bead) contada · linhas que não são objeto JSON contadas e avisadas · a janela é fechada nas duas pontas, o futuro não entra · modos do Pilot · soltas · leituras que falharam.
#     MODO SHADOW (o que o Pilot grava hoje): a linha `pilot-node-route` É a decisão (o Pilot só roda `check`, não há `apply`); só o par coerente rc+verdict dá veredito (0+node, 10+mini, 11+unknown);
#     rc 11 sem saída = 'não li' e não 'não sei'; prazo/sinal = 'não li'; rc e veredito que discordam = 'outro' + INCOERENTE (nunca mini, nunca node) e entra na lista de conferência.
#     ESCRITA NÃO CONFIRMADA: apply rc 13 (menos 'conferencia-falhou-desfeito', que prova que nada nosso sobrou), release rc 13, Pilot label/auto com rc 13/124+ — até um despacho ou uma soltura CONFIRMAR.
#     COBERTURA: horas UTC COM VEREDITO (duas linhas a 24 h de distância são duas horas, não 24; hora só de 'não li'/'não elegível'/'outro' não conta, nem a do apply sem veredito), o maior silêncio ENTRE VEREDITOS e o intervalo ·
#     aviso quando o Pilot gravou linhas e NENHUMA deu veredito · EVENTO DESCONHECIDO (event ausente, vazio, não-texto ou novo) contado à parte, fora de decisão/bead/'linha ilegível' · base e razões de um node ANTERIOR rotuladas como tais.
#     O GANCHO DE VERDADE: o selftest roda `_pilot_wa_node_decide` (extraída do pilot-dispatcher.sh) contra um despachante falso e lê a linha que ELE grava (chk_hook_real); falha alto se a função sumir.
#   PRONTIDÃO: mecânica (horas UTC COM VEREDITO e beads COM VEREDITO); igual ao mínimo basta, um a menos não; --min-hours que não cabe na janela (> --hours + 1) diz isso em vez de "ainda não deu tempo"; nunca diz "aprovado".
#   OCUPAÇÃO: CPU por hora em UTC (qualquer TZ) · CPU não lida (lido=false, ausente, bool, fora de 0..100, NaN) NUNCA vira 0%, e 0% de verdade aparece como 0,0 · média da janela sobre as LIDAS · "perto de 100%" é >= · sessões
#     wa-worker-remote (não o wa-worker do mini) · sessões não lidas não viram "0 sessões" · leitura de sessões lida pela metade (`ilegiveis` != 0/ausente: N>0, texto, bool) também não entra na conta de WA ·
#     linhas sem epoch contadas · bordas da janela · a tabela de texto mostra as últimas 72 horas e avisa ·
#     o que NÃO é leitura do vigia (a linha `tipo:"reaper"` que o reaper grava no mesmo arquivo, `tipo` que não é texto, linha sem cpu NEM sessoes) fica fora de leituras/hora/sem-CPU e vem CONTADA, inclusive num arquivo só de reaper.
#   FUNIL (o log do Pilot): as cinco frases do Pilot contadas por categoria (linhas e beads distintas) e as rodadas, na janela FECHADA (as duas beads exatamente nas bordas entram, a de -25 h e a do futuro não) · a hora do log é lida no fuso de
#     quem roda (UTC e BRT3 dão o mesmo número) · o id da bead não leva o ponto final da frase nem perde o sufixo `.N` · linha do funil sem hora ou com hora impossível (início de rodada inclusive) FORA das contas e CONTADA; continuação que não
#     é do funil não conta · o cruzamento com a rota: "tem linha na rota" inclui a bead que só teve leitura que falhou; rota ausente/ilegível = NÃO SEI (null) em tudo, rota vazia = nenhuma tem linha; "o Pilot não gravou NENHUMA linha de rota"
#     avisa, e com linha gravada a ressalva "sem linha na rota não prova que o nó não viu" · log ausente ≠ vazio ≠ ilegível ≠ ok com zeros (nada na janela)
#   FILA (~/.gc/pilot-dispatchable.json): WA entre o total, por prioridade (sem prioridade = P?), item que não é objeto contado · idade/VENCIDA (idade == ttl não venceu) · `generated_at` ausente/no futuro/impossível = idade null, sem quebrar ·
#     items que não é lista, JSON que não é objeto, lixo e pasta = ilegível; ausente ≠ ilegível · caminhos padrão (log na cidade, fila em $HOME/.gc, nunca a do usuário de verdade) · caminho vazio = rc 2, não o padrão
#   ESTADOS: ausente ≠ vazio ≠ ilegível (lixo, pasta no lugar do arquivo) · rc 3 só quando NENHUM dos dois logs serve (e JSON mesmo assim) · rc 2 em uso errado (inclui "010" = dez, nunca octal) · só leitura (nada novo, nada alterado) ·
#     --json é UMA linha de JSON com as seis chaves (fila, funil, janela, ocupacao, prontidao, rota).
# CONTROLE NEGATIVO: cada mutante troca UMA trecho do script numa cópia (e FALHA se o trecho sumiu ou se repete: o script mudou, atualize o mutante) e a função designada tem de reprovar; mutante que sobrevive reprova esta bateria.
#   O piso (MIN_MUT) impede que apagar mutantes passe por "todos mortos".
# O QUE NÃO COBRE: o formato exato de cada linha do DESPACHANTE (`apply`/`release`) além dos padrões fixados aqui (se ele mudar o texto, a bead cai em 'sem veredito'); a do PILOT é a que o gancho real grava (hook_real), mas só
#   no modo shadow e contra um `check` falso que devolve o par (rc, saída) que classify_checked devolve — um `check` real que mudasse o par não é pego aqui; o ponto fraco restante é o aviso "o Pilot gravou N e nenhuma deu
#   veredito". A saída em locale não-UTF-8 (o script fixa UTF-8 na saída, sem mutante); o log vivo de verdade.
# COMO RODAR: bash scripts/wa-node-report.selftest.sh   (macOS /bin/bash 3.2 e Linux; precisa de jq e python3; ~90 s no nó, mais de 2 min no mini carregado)
#   WA_NODE_REPORT_ST_NOMUT=1 roda só os casos, sem os mutantes (o prod-test usa assim; os mutantes são a evidência do gate).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="$HERE/wa-node-report.py"
MIN_MUT=187
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


def pr(bead, off, mode, rc, out):
    """a linha que _pilot_wa_node_decide grava (jq -cn '{ts,event,bead,mode,rc,out}'): nenhum outro campo. No modo shadow ela é a ÚNICA linha da decisão (o Pilot só roda `check`, não há `apply`)"""
    return {"ts": iso(off), "event": "pilot-node-route", "bead": bead, "mode": mode, "rc": rc, "out": out}


def cj(verdict, basis="", reasons=()):
    """a saída do `check` do despachante (o JSON do classificador)"""
    return json.dumps({"verdict": verdict, "basis": basis, "reasons": list(reasons), "paths": [], "tests": [], "info": []}, ensure_ascii=False)


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


# ---- rota: beads com decisão na janela, na forma em que o Pilot e o despachante gravam
RAZ8 = cj("node", "doc", ["r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8"])
rota = [
    ap("wa-edge-in", -24 * H, 10, "classificador:mini test-toca-banco"),                       # exatamente a borda de baixo: ENTRA
    ap("wa-edge-out", -24 * H - 1, 0, "dry-run: iria para wa-worker-remote-1 (code)"),         # um segundo antes: fora
    ap("wa-old", -30 * H, 0, "despachada para wa-worker-remote-1 (label)"),                    # fora
    # ---- SÓ SOMBRA (shadow): uma linha `pilot-node-route` por decisão, nenhuma `apply`
    pr("wa-n1", -20 * H, "shadow", 0, cj("node", "label", ["code", "test-sem-dado"])),
    pr("wa-sn1", -19 * H, "shadow", 0, cj("node", "code", ["a", "b"])),
    pr("wa-sb1", -19 * H + 60, "shadow", 0, cj("node", "co de", ["x"])),                       # basis fora de [A-Za-z0-9_-]: node, mas sem base
    pr("wa-sn2", -18 * H, "shadow", 0, cj("node", "label", ["c"])),
    pr("wa-sn2", -3 * H + 1800, "shadow", 10, cj("mini", "", ["toca-banco"])),                 # node e depois mini: mudou de veredito
    pr("wa-sm1", -17 * H, "shadow", 10, cj("mini", "", ["toca-banco"])),
    pr("wa-su1", -17 * H + 60, "shadow", 11, cj("unknown", "", ["sem-arquivo"])),
    pr("wa-sl1", -16 * H, "shadow", 11, ""),                                                   # o despachante não leu a bead: rc 11 e nada na saída
    pr("wa-sh124", -15 * H, "shadow", 124, ""),                                                # o `check` estourou o prazo
    pr("wa-sx1", -14 * H, "shadow", 10, cj("node", "code", ["a"])),                            # rc 10 e verdict node: o `check` não devolve esse par
    pr("wa-sx2", -13 * H, "shadow", 0, ""),                                                    # rc 0 e nenhum veredito
    ap("wa-n2", -10 * H, 0, "despachada para wa-worker-remote-1 (label)"),
    pr("wa-n2", -10 * H, "label", 0, ""),
    {"ts": iso(-9 * H), "event": "release", "bead": "wa-n2", "rc": 0, "detail": "solta"},
    {"ts": iso(-9 * H + 60), "event": "release", "bead": "wa-n2", "rc": 13, "detail": "escrita-falhou"},
    ap("wa-n3", -8 * H, 12, "slot-ocupado bead(s)=1"),
    ap("wa-ap13a", -8 * H + 600, 13, "escrita-falhou-NAO-desfeito rc=1"),                      # escrita incerta
    ap("wa-ap13b", -8 * H + 1200, 13, "conferencia-falhou-desfeito"),                          # releu e provou que nada nosso sobrou: NÃO é incerta
    ap("wa-n4", -7 * H, 12, "oraculo-local:node_full"),
    ap("wa-n5", -7 * H + 60, 12, "oraculo-sem-vaga free=1 pendentes=1"),
    ap("wa-ap13c", -7 * H + 1200, 13, "escrita-falhou-sem-nada-nosso rc=124"),                  # incerta... até a despachada confirmar
    ap("wa-ap13c", -7 * H + 1800, 0, "despachada para wa-worker-remote-1 (code) [bd update rc=124, a releitura confere]"),
    ap("wa-n6", -6 * H, 12, "nao-elegivel status=in_progress assignee=x rota="),
    pr("wa-n6", -6 * H + 30, 5, 0, ""),                                                        # modo que não é texto → "?"
    ap("wa-n7", -6 * H + 60, 12, "perdeu-a-corrida"),
    ap("wa-ap13d", -6 * H + 1800, 13, "conferencia-falhou-NAO-desfeito"),                      # incerta... até uma soltura confirmada
    {"ts": iso(-6 * H + 3000), "event": "release", "bead": "wa-ap13d", "rc": 0, "detail": "solta"},
    ap("wa-m1", -5 * H, 10, "classificador:mini test-toca-banco"),
    ap("wa-s1", -5 * H + 60, 11, "classificador:unknown sem-arquivo"),
    ap("wa-s2", -5 * H + 120, 11, "slot-ilegivel"),
    ap("wa-rel13", -5 * H + 1200, 0, "despachada para wa-worker-remote-1 (label)"),
    {"ts": iso(-5 * H + 1500), "event": "release", "bead": "wa-rel13", "rc": 13, "detail": "conferencia-falhou"},   # a soltura pode ou não ter pegado
    ap("wa-e1", -4 * H, 10, "base=code, modo exige etiqueta"),
    pr("wa-e1", -4 * H, "label", 10, cj("node", "code", ["code"])),                            # rc 10: as razões NÃO entram
    {"ts": iso(-4 * H + 300), "event": "release", "bead": "wa-rel12", "rc": 12, "detail": "nao-e-do-no assignee= rota="},   # não era do nó: não é soltura
    pr("wa-pl124", -4 * H + 600, "label", 124, ""),                                            # label/auto: o apply morreu por prazo e não deixou linha; a escrita pode ter pegado
    pr("wa-sbadrc", -4 * H + 700, "shadow", False, cj("node", "code", ["a"])),                 # rc booleano: linha do Pilot ilegível
    ap("wa-x10", -4 * H + 900, 10, "texto-novo-do-despachante"),                               # rc 10 que não é nem base= nem classificador:mini: NÃO é mini
    {"ts": iso(-4 * H + 1000), "event": "pilot-node-route", "mode": "shadow", "rc": 0, "out": cj("node", "code", ["a"])},   # sem bead
    {"ts": iso(-4 * H + 1100), "event": "release", "rc": 0, "detail": "solta"},                # sem bead
    {"ts": iso(-4 * H + 1200), "event": "release", "bead": "wa-relbad", "rc": "0", "detail": "solta"},   # rc em texto: não é soltura, é linha ilegível
    ap("wa-u1", -6 * H, 0, "dry-run: iria para wa-worker-remote-1 (code)"),
    pr("wa-u1", -6 * H + 30, "label", 0, "not json: texto que nao e json"),
    ap("wa-u1", -3 * H, 10, "classificador:mini test-toca-banco"),
    ap("wa-u2", -6 * H, 0, "dry-run: iria para wa-worker-remote-1 (code)"),
    pr("wa-u2", -6 * H + 30, "label", 0, json.dumps({"reasons": "nao-lista"})),
    ap("wa-u2", -3 * H, 11, "classificador:unknown sem-arquivo"),
    pr("wa-w1", -1 * H, "shadow", 0, RAZ8),                                                    # o MAIS NOVO (e a última linha do Pilot) vem PRIMEIRO no arquivo
    ap("wa-w1", -2 * H, 0, "dry-run: iria para wa-worker-remote-1 (doc)"),
    ap("wa-w1", -5 * H, 10, "classificador:mini test-toca-banco"),                             # o mais velho vem por último: na ordem do arquivo o veredito seria mini
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

# ---- ocupação: 13 leituras do vigia na janela (e, no meio delas, 3 linhas do reaper + 1 sem forma de leitura, que NÃO são leituras)
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
    occ(-2 * H + 900, None, ses([], lido=False)),                                       # a chave `cpu` nem existe: sem CPU lida (nunca 0%)
    occ(-2 * H + 1800, cpu(True), ses([], lido=False)),                                 # pct bool: sem CPU lida
    occ(-1 * H, cpu(95.0), ses([1])),                                                   # 11Z: nome que não é texto → sessões não lidas
    occ(-1 * H + 900, cpu(90.0), ses(["wa-worker-remote-1"])),                          # exatamente 90: conta como perto de 100%
    occ(0, cpu(100.0), ses([])),                                                        # exatamente agora: entra
    occ(1, cpu(100.0), ses([])),                                                        # um segundo depois: fora
    # ---- o reaper grava no MESMO arquivo ({"ts","epoch","tipo":"reaper","fechadas","falhas"}, sem cpu nem sessoes): não é leitura do vigia
    {"ts": iso(-3 * H + 300), "epoch": NOW - 3 * H + 300, "tipo": "reaper", "fechadas": 2, "falhas": 0},      # 09Z
    {"ts": iso(-2 * H + 60), "epoch": NOW - 2 * H + 60, "tipo": "reaper", "fechadas": 0, "falhas": 1},        # 10Z
    {"ts": iso(-1 * H + 300), "epoch": NOW - 1 * H + 300, "tipo": 7},                                          # `tipo` que não é texto: '?'
    {"ts": iso(-25 * H), "epoch": NOW - 25 * H, "tipo": "reaper", "fechadas": 1, "falhas": 0},                # fora da janela: nem entra na conta dos eventos
    {"ts": iso(-1 * H + 500), "epoch": NOW - 1 * H + 500, "estado": "ok"},                                    # sem `tipo`, sem cpu e sem sessoes: não se sabe o que é
    {"ts": iso(-5 * H), "estado": "ok", "cpu": cpu(100.0)},                             # sem epoch
    {"ts": iso(-5 * H), "epoch": str(NOW - 5 * H), "cpu": cpu(100.0)},                  # epoch em texto
    b'{"ts": "x", "epoch": NaN, "cpu": {"lido": true, "nucleos": 16, "pct": 100.0}}',   # epoch NaN
]
jl(os.path.join(city("ocup"), ".gc", "hetzner-occupancy.jsonl"), ocup)

# ---- a cobertura é de horas COM linha, não o intervalo: duas linhas com 24 h de distância são DUAS horas
jl(os.path.join(city("span"), ".gc", "wa-node-route.jsonl"), [pr("wa-sp1", -24 * H, "shadow", 0, cj("node", "label", ["a"])), pr("wa-sp2", 0, "shadow", 10, cj("mini", "", ["b"]))])
# ---- o dia inteiro: uma decisão do Pilot (shadow) em cada hora UTC de -24 h a agora = 25 horas e 25 beads com veredito
jl(os.path.join(city("dia"), ".gc", "wa-node-route.jsonl"),
   [pr("wa-d%02d" % k, -k * H, "shadow", 0 if k % 2 else 10, cj("node", "label", ["a"]) if k % 2 else cj("mini", "", ["b"])) for k in range(25)])
# ---- eventos que o relatório não conhece: contados à parte, nunca decisão, nunca bead, nunca "linha ilegível"
jl(os.path.join(city("ev"), ".gc", "wa-node-route.jsonl"), [
    pr("wa-ev0", -2 * H, "shadow", 0, cj("node", "code", ["a"])),
    {"ts": iso(-2 * H), "event": "futuro", "bead": "wa-ev1", "rc": 0, "detail": "x"},
    {"ts": iso(-2 * H), "event": "futuro", "rc": 0},                       # sem bead: não é "linha ilegível", é evento desconhecido
    {"ts": iso(-2 * H), "event": 7, "bead": "wa-ev2"},                     # event que nem é texto
    {"ts": iso(-2 * H), "bead": "wa-ev3", "rc": 0},                        # sem event
    {"ts": iso(-2 * H), "event": "", "bead": "wa-ev4"},
])
# ---- horas em que o DESPACHANTE (apply) rodou e NÃO deu veredito (não elegível, não li, escrita falhou): são horas com decisão, mas não horas COM VEREDITO
jl(os.path.join(city("sv"), ".gc", "wa-node-route.jsonl"), [
    ap("wa-sv1", -5 * H, 12, "nao-elegivel status=in_progress assignee=x rota="),
    ap("wa-sv2", -4 * H, 11, "bead-ilegivel"),
    ap("wa-sv3", -3 * H, 13, "escrita-falhou-NAO-desfeito rc=1"),
    ap("wa-sv4", -1 * H, 10, "classificador:mini test-toca-banco"),
])
# ---- a ocupação só com linhas do reaper (o vigia ainda não rodou): zero leituras, e isso é dito
jl(os.path.join(city("sor"), ".gc", "hetzner-occupancy.jsonl"), [
    {"ts": iso(-2 * H), "epoch": NOW - 2 * H, "tipo": "reaper", "fechadas": 0, "falhas": 0},
    {"ts": iso(-1 * H), "epoch": NOW - 1 * H, "tipo": "reaper", "fechadas": 1, "falhas": 0},
])
# ---- o Pilot gravou, mas nenhuma linha dá veredito: o relatório avisa
jl(os.path.join(city("pv"), ".gc", "wa-node-route.jsonl"), [pr("wa-pv1", -3 * H, "shadow", 124, ""), pr("wa-pv2", -2 * H, "shadow", 2, "usage: ...")])
# ---- sessões lidas pela metade: a lista pode estar incompleta, então não entra na conta de WA
def ses_i(nomes, ileg):
    d = ses(nomes)
    d["ilegiveis"] = ileg
    return d


jl(os.path.join(city("oi"), ".gc", "hetzner-occupancy.jsonl"), [
    occ(-1 * H, cpu(50.0), ses_i(["wa-worker-remote-1"], 1)),
    occ(-1 * H + 60, cpu(60.0), ses_i(["wa-worker-remote-1"], 0)),
    occ(-1 * H + 120, cpu(70.0), ses_i([], "x")),
    occ(-1 * H + 180, cpu(80.0), ses_i(["wa-worker-remote-2"], True)),
    occ(-1 * H + 240, cpu(90.0), ses_i(["wa-worker-remote-3"], False)),
])

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
        f.write(b"garbage lixo\n[1]\n")
with open(os.path.join(city("lx"), ".gc", "hetzner-occupancy.jsonl"), "wb") as f:
    f.write(b"{nao: json}\n")
os.makedirs(os.path.join(city("dr"), ".gc", "wa-node-route.jsonl"), exist_ok=True)
os.makedirs(os.path.join(city("dn"), ".gc", "wa-node-route.jsonl"), exist_ok=True)

# ---- o funil: o log do Pilot (hora local, sem fuso) em UTC e em BRT (UTC-3). Os checks usam --hours 24: as linhas de -25 h ficam de fora
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
    a(-24 * H, "Claim acquired on wa-bordaa.")                                          # exatamente no início da janela: entra (janela fechada)
    a(0, "Claim acquired on wa-bordab.")                                                # exatamente no fim da janela (agora): entra
    L.append("    Claim acquired on wa-zz.")                                               # linha do funil SEM hora: contada em sem_hora, fora das contas
    L.append("=== Pilot sweep start (DRY_RUN=0) ===")                                     # início de rodada SEM hora: idem (não é uma rodada da janela)
    L.append("[2026-13-45 99:99:99] [pilot-dispatcher] Claim acquired on wa-bad.")         # hora impossível: idem
    L.append("    uma continuação qualquer, sem padrão e sem hora: não é do funil e não conta")
    a(60, SWEEP)                                                                          # no futuro
    a(60, "Claim acquired on wa-fut.")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")


pilot_log(os.path.join(T, "pilot-utc.log"), 0)
pilot_log(os.path.join(T, "pilot-brt.log"), -3 * H)
open(os.path.join(T, "pilot-vazio.log"), "wb").close()
os.makedirs(os.path.join(T, "pilot-dir.log"), exist_ok=True)
# a rota do funil: o despachante gravou só `apply` (nenhuma linha do Pilot → o gancho não gravou nada)
jl(os.path.join(city("funil"), ".gc", "wa-node-route.jsonl"), [ap("wa-c2", -1 * H, 10, "classificador:mini test-toca-banco"), ap("wa-qp98sy", -1 * H, 10, "classificador:mini test-toca-banco")])
# a rota do funil com a linha do Pilot (o gancho gravou) e uma bead que só tem leitura que falhou (tem linha na rota, não tem veredito)
jl(os.path.join(city("funil2"), ".gc", "wa-node-route.jsonl"), [ap("wa-c2", -1 * H, 10, "classificador:mini test-toca-banco"), pr("wa-c1", -1 * H, "shadow", 10, cj("mini", "", ["toca-banco"])),
                                                                ap("wa-t2", -1 * H, 1, "bd show falhou", ev="read")])
# os caminhos padrão: o log do Pilot na cidade e a fila em $HOME/.gc
jl(os.path.join(city("padrao"), ".gc", "wa-node-route.jsonl"), [ap("wa-c2", -1 * H, 10, "classificador:mini test-toca-banco")])
with open(os.path.join(T, "pilot-utc.log"), "rb") as f:
    log_bytes = f.read()
with open(os.path.join(city("padrao"), ".gc", "logs", "pilot-dispatcher.log"), "wb") as f:
    f.write(log_bytes)

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
fila("fila-na-borda.json", -1800)   # idade == ttl: ainda não venceu
fila("fila-futura.json", 600)
fila("fila-sem-hora.json", None)
fila("fila-hora-impossivel.json", 0, extra={"items": itens, "ttl_seconds": 1800, "generated_at": "2026-13-45T99:99:99Z"})
fila("fila-itens-texto.json", 0, extra={"items": "x", "ttl_seconds": 1800})
fila("fila-lista.json", 0, extra=[])
with open(os.path.join(T, "fila-lixo.json"), "w") as f:
    f.write("isto nao e json")
os.makedirs(os.path.join(T, "fila-dir.json"), exist_ok=True)
os.makedirs(os.path.join(T, "home", ".gc"), exist_ok=True)
fila(os.path.join("home", ".gc", "pilot-dispatchable.json"), -100)

PYEOF
python3 -I "$T/fx.py" "$FX" "$NOW" || { echo "o gerador de fixtures falhou"; exit 2; }
# as cidades de fixture moram em $FX
RT="$FX/rota"; OC="$FX/ocup"; MU="$FX/muitas"; SR="$FX/sr"; LR="$FX/lr"; DR="$FX/dr"; NA="$FX/na"; VZ="$FX/vz"; LX="$FX/lx"; DN="$FX/dn"; SP="$FX/span"; DIA="$FX/dia"; PV="$FX/pv"; OI="$FX/oi"; RL="$FX/real"; EV="$FX/ev"; SOR="$FX/sor"; SV="$FX/sv"
FU="$FX/funil"; F2="$FX/funil2"; PD="$FX/padrao"; HM="$FX/home"
# os arquivos soltos (logs do Pilot, filas) moram em $FX; NOPILOT/NOFILA não existem de propósito
PLU="$FX/pilot-utc.log"; PLB="$FX/pilot-brt.log"; NOPILOT="$FX/nao-existe.log"; NOFILA="$FX/nao-existe.json"

# ---- a linha REAL do Pilot: o gancho de verdade (_pilot_wa_node_decide, extraído palavra por palavra do pilot-dispatcher.sh) roda em shadow contra um despachante falso e grava em $RL.
# O despachante falso devolve o par (rc, saída) que o `check` real devolve (classify_checked); a linha é a que o Pilot grava, não a que este selftest imagina.
DISP="$HERE/../packs/town-deltas/assets/pilot-dispatcher.sh"
HOOK_FN=""; [ -f "$DISP" ] && HOOK_FN=$(awk '/^_pilot_wa_node_decide\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISP")
mkdir -p "$RL/.gc" "$T/hook"
cat > "$T/hook/wa-node-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_OUT-}"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/hook/wa-node-dispatch.sh"
# hook <bead> <rc> <saída>
hook() {
  PILOT_WA_NODE_ROUTE=shadow GC_CITY="$RL" PILOT_WA_NODE_SCRIPTS="$T/hook" FAKE_RC="$2" FAKE_OUT="$3" DRY_RUN=0 \
    bash -c 'warn(){ :; }; log(){ :; }; timeout(){ shift; "$@"; }'$'\n'"$HOOK_FN"$'\n''_pilot_wa_node_decide "$@"' _ "$1" /x/store wa-worker >/dev/null 2>&1
}
if [ -n "$HOOK_FN" ]; then
  hook wa-hk-node 0 '{"verdict":"node","basis":"label","reasons":["code","test-sem-dado"],"paths":[],"tests":[],"info":[]}'
  hook wa-hk-mini 10 '{"verdict":"mini","basis":"","reasons":["toca-banco"],"paths":[],"tests":[],"info":[]}'
  hook wa-hk-unk 11 '{"verdict":"unknown","basis":"","reasons":["sem-arquivo"],"paths":[],"tests":[],"info":[]}'
  hook wa-hk-unread 11 ''
fi

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
# HOME aponta para uma pasta que não existe: a fila padrão (~/.gc/pilot-dispatchable.json) nunca é a do usuário de verdade. HOMEENV (se definida) troca
run() { local tz=$1; shift; OUT=$(HOME="${HOMEENV-$T/sem-home}" WA_NODE_REPORT_NOW="${NOWENV-$NOW}" TZ="$tz" python3 -I "$SCRIPT" "$@" 2>"$T/err"); RC=$?; }
# jrun <TZ> <cidade> [args…]: --json (log do Pilot e fila inexistentes: os casos de rota/CPU/estado não dependem deles)
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
H09="2026-10-20T09:00Z"; H08="2026-10-20T08:00Z"; H10="2026-10-20T10:00Z"; H11="2026-10-20T11:00Z"

# ============================== ROTA ==============================
chk_veredito_final() {
  jrun UTC "$RT" --hours 24; eq "$RC" 0 rc && eq "$(jf .rota.estado)" ok estado &&
  eq "$(vf node-despachada)" 3 despachada && eq "$(vf node-sombra)" 4 sombra && eq "$(vf node-sem-vaga)" 3 sem-vaga &&
  eq "$(vf node-sem-etiqueta)" 1 sem-etiqueta && eq "$(vf mini)" 6 mini && eq "$(vf nao-sei)" 3 nao-sei &&
  eq "$(jf '.rota.analise.fora_do_veredito|to_entries|map("\(.key)=\(.value)")|join(",")')" "falha-escrita=3,nao-elegivel=2,nao-li=3,outro=3" fora
}
chk_sombra_nao_e_entrega() {
  jrun UTC "$RT" --hours 24; eq "$(jf '.rota.analise.ao_no_de_verdade|join(",")')" wa-ap13c,wa-n2,wa-rel13 ao_no && eq "$(jf .rota.analise.soltas)" 2 soltas &&
  eq "$(vf node-despachada)" 3 "despachada = só as três com apply 0 'despachada…' (nenhuma linha shadow entra)" && eq "$(cf wa-sn1 .ultimo)" node-sombra "sn1 (só shadow) é sombra, não entrega" &&
  trun UTC "$RT" --hours 24 && has "$OUT" "WhatsApp ao nó DE VERDADE (atribuída pelo despachante): 3 bead(s) — wa-ap13c, wa-n2, wa-rel13; soltas depois da entrega: 2"
}
chk_ultimo_por_hora() {
  jrun UTC "$RT" --hours 24; eq "$(cf wa-w1 .ultimo)" node-sombra "ultimo de w1" && eq "$(cf wa-u1 .ultimo)" mini "ultimo de u1" && eq "$(cf wa-u2 .ultimo)" nao-sei "ultimo de u2" &&
  eq "$(cf wa-sn2 .ultimo)" mini "ultimo de sn2 (node e depois mini, as duas só no shadow)"
}
chk_instaveis() {
  jrun UTC "$RT" --hours 24; eq "$(jf '.rota.analise.instaveis|join(",")')" "wa-sn2,wa-u1,wa-u2,wa-w1" instaveis &&
  trun UTC "$RT" --hours 24 && has "$OUT" "ATENÇÃO — mudaram de veredito" && has "$OUT" "wa-sn2, wa-u1, wa-u2, wa-w1"
}
chk_conferir_lista() {
  jrun UTC "$RT" --hours 24; eq "$RC" 0 rc &&
  eq "$(jf '.rota.analise.node_para_conferir|map(.bead)|join(",")')" "wa-ap13a,wa-ap13c,wa-e1,wa-n1,wa-n2,wa-n3,wa-n4,wa-n5,wa-pl124,wa-rel13,wa-sb1,wa-sn1,wa-sn2,wa-sx1,wa-sx2,wa-u1,wa-u2,wa-w1" lista &&
  eq "$(cf wa-n1 .ultimo)" node-sombra n1 && eq "$(cf wa-n3 .ultimo)" node-sem-vaga n3 && eq "$(cf wa-e1 .ultimo)" node-sem-etiqueta e1 &&
  trun UTC "$RT" --hours 24 && has "$OUT" "PARA CONFERIR UMA A UMA" && has "$OUT" "wa-n1  [node, só sombra (shadow/dry-run), base label]  razões: code; test-sem-dado"
}
chk_base() {
  jrun UTC "$RT" --hours 24
  eq "$(cf wa-n1 .base)" label base-n1 && eq "$(cf wa-n2 .base)" label base-n2 && eq "$(cf wa-w1 .base)" doc base-w1 && eq "$(cf wa-u1 .base)" code base-u1 &&
  eq "$(cf wa-e1 .base)" code base-e1 && eq "$(cf wa-n3 .base)" null base-n3-capacidade && eq "$(cf wa-sn1 .base)" code base-sn1-shadow &&
  eq "$(cf wa-sb1 .base)" null "base-sb1 (basis fora de [A-Za-z0-9_-])"
}
chk_razoes() {
  jrun UTC "$RT" --hours 24
  eq "$(cf wa-n1 '.razoes|tojson')" '["code","test-sem-dado"]' n1 && eq "$(cf wa-w1 '.razoes|join(",")')" "r1,r2,r3,r4,r5,r6" w1-no-maximo-6 && eq "$(cf wa-sn1 '.razoes|tojson')" '["a","b"]' sn1-shadow &&
  eq "$(cf wa-n2 '.razoes|tojson')" null n2-vazio && eq "$(cf wa-u1 '.razoes|tojson')" null u1-texto && eq "$(cf wa-u2 '.razoes|tojson')" null u2-nao-lista
}
chk_razoes_so_rc0() { jrun UTC "$RT" --hours 24; eq "$(cf wa-e1 '.razoes|tojson')" null "e1 (linha do Pilot com rc 10)" && eq "$(cf wa-sx1 '.razoes|tojson')" null "sx1 (shadow com rc 10)"; }
chk_sombra_so_shadow() {
  jrun UTC "$RT" --hours 24
  eq "$(cf wa-n1 .ultimo)" node-sombra "n1: só a linha do Pilot, nenhum apply" && eq "$(cf wa-sn1 .ultimo)" node-sombra sn1 && eq "$(cf wa-sb1 .ultimo)" node-sombra sb1 &&
  eq "$(vf mini)" 6 "mini (sm1 e sn2 vêm do shadow)" && eq "$(vf nao-sei)" 3 "nao-sei (su1 vem do shadow; o rc 11 sem saída NÃO é 'não sei')" &&
  eq "$(jf '.rota.analise.fora_do_veredito["nao-li"]')" 3 "nao-li: s2 (apply) + sl1 (rc 11 sem saída) + sh124 (prazo do check)"
}
chk_incoerente() {
  jrun UTC "$RT" --hours 24
  eq "$(jf '.rota.analise.incoerentes|join(",")')" wa-sx1,wa-sx2 incoerentes && eq "$(cf wa-sx1 .incoerente)" true sx1 && eq "$(cf wa-sx1 .ultimo)" outro "sx1 não vira mini nem node" && eq "$(cf wa-sx2 .ultimo)" outro sx2 &&
  eq "$(cf wa-n1 .incoerente)" false "n1 é coerente" && eq "$(cf wa-n2 .incoerente)" false "n2 (label, rc 0, saída vazia) não é uma decisão shadow" && eq "$(jf .rota.analise.fora_do_veredito.outro)" 3 outro &&
  trun UTC "$RT" --hours 24 && has "$OUT" "ATENÇÃO — linha do Pilot cujo rc e veredito discordam" && has "$OUT" "wa-sx1, wa-sx2" && has "$OUT" "wa-sx1  [outro (rc ou saída fora do formato)] INCOERENTE"
}
chk_rc13() {
  jrun UTC "$RT" --hours 24
  eq "$(jf '.rota.analise.escrita_nao_confirmada|join(",")')" wa-ap13a,wa-n2,wa-pl124,wa-rel13 lista && eq "$(cf wa-ap13a .escrita_nao_confirmada)" true ap13a &&
  eq "$(cf wa-pl124 .escrita_nao_confirmada)" true "pl124 (Pilot label, rc 124)" && eq "$(cf wa-ap13c .escrita_nao_confirmada)" false "ap13c (a despachada confirmou)" &&
  eq "$(cf wa-ap13b .bead)" "" "ap13b: conferencia-falhou-desfeito prova que nada nosso sobrou" && eq "$(cf wa-ap13d .bead)" "" "ap13d: a soltura confirmada limpou" &&
  eq "$(cf wa-rel13 .escrita_nao_confirmada)" true "rel13: soltura incerta" && eq "$(cf wa-rel12 .bead)" "" "rel12: não era do nó" && eq "$(jf '.rota.analise.fora_do_veredito["falha-escrita"]')" 3 falha-escrita &&
  trun UTC "$RT" --hours 24 && has "$OUT" "ESCRITA NÃO CONFIRMADA — confira à mão" && has "$OUT" "wa-ap13a, wa-n2, wa-pl124, wa-rel13" &&
  has "$OUT" "wa-ap13a  [escrita falhou (rc 13)] ESCRITA NÃO CONFIRMADA" && has "$OUT" "wa-pl124  [—] ESCRITA NÃO CONFIRMADA"
}
chk_hook_real() {
  local f="$RL/.gc/wa-node-route.jsonl" r
  if [ -z "$HOOK_FN" ]; then [ "$VERBOSE" = 1 ] && echo "      _pilot_wa_node_decide não foi achada em $DISP" >&2; return 1; fi
  [ -s "$f" ] || { [ "$VERBOSE" = 1 ] && echo "      o gancho real não gravou nada em $f" >&2; return 1; }
  eq "$(wc -l < "$f" | tr -d ' ')" 4 "linhas gravadas pelo gancho" && eq "$(jq -r 'keys|join(",")' "$f" | sort -u)" "bead,event,mode,out,rc,ts" "chaves da linha do Pilot" &&
  { NOWENV=$(( $(date -u +%s) + 5 )); jrun UTC "$RL"; r=$RC; unset NOWENV; eq "$r" 0 rc; } &&
  eq "$(jf .rota.analise.decisoes)" 4 decisoes && eq "$(jf .rota.analise.pilot_linhas)" 4 pilot_linhas && eq "$(jf .rota.analise.beads_com_veredito)" 3 com_veredito &&
  eq "$(vf node-sombra)" 1 node-sombra && eq "$(vf mini)" 1 mini && eq "$(vf nao-sei)" 1 nao-sei && eq "$(jf '.rota.analise.fora_do_veredito["nao-li"]')" 1 nao-li &&
  eq "$(jf '.rota.analise.modos|to_entries|map("\(.key)=\(.value)")|join(",")')" "shadow=4" modos &&
  eq "$(jf '.rota.analise.node_para_conferir|map(.bead)|join(",")')" wa-hk-node lista && eq "$(cf wa-hk-node .base)" label base && eq "$(cf wa-hk-node '.razoes|join(",")')" "code,test-sem-dado" razoes &&
  eq "$(jf '.rota.analise.avisos|length')" 0 avisos && eq "$(jf '.rota.analise.incoerentes|length')" 0 incoerentes
}
chk_apply_ilegivel() {
  jrun UTC "$RT" --hours 24; eq "$(jf .rota.analise.apply_ilegivel)" 4 apply_ilegivel && eq "$(jf .rota.analise.beads_distintas)" 31 beads && eq "$(jf .rota.analise.decisoes)" 37 decisoes
}
chk_linhas_ilegiveis() {
  jrun UTC "$RT" --hours 24; eq "$(jf .rota.ilegiveis)" 3 ilegiveis && eq "$(jf .rota.analise.sem_hora)" 2 sem_hora && eq "$(jf .rota.analise.outras_ilegiveis)" 4 outras_ilegiveis &&
  trun UTC "$RT" --hours 24 && has "$OUT" "3 linha(s) ilegível(is), contadas e fora das contas" && has "$OUT" "2 sem hora legível" &&
  has "$OUT" "linhas ilegíveis: apply 4, outras (sem bead ou sem rc) 4; leituras de bead que falharam: 2"
}
chk_janela_rota() {
  jrun UTC "$RT" --hours 24; eq "$(jf .rota.analise.linhas_na_janela)" 58 linhas && eq "$(jf .rota.analise.primeira)" "$((NOW-86400))" primeira && eq "$(jf .rota.analise.ultima)" "$NOW" ultima &&
  eq "$(jf '.rota.analise.node_para_conferir|map(.bead)|(index("wa-edge-out")), (index("wa-old")), (index("wa-future"))|tostring')" "$(printf 'null\nnull\nnull')" "fora da janela"
}
chk_cobertura() {
  jrun UTC "$RT" --hours 24; eq "$(jf .rota.analise.horas_cobertas)" 15 "horas COM VEREDITO (as 4 horas só de 'não li'/'outro' não contam)" && eq "$(jf .rota.analise.horas_com_decisao)" 19 "horas com linha de decisão de qualquer tipo" && eq "$(jf .rota.analise.intervalo_h)" 24 intervalo && eq "$(jf .rota.analise.maior_lacuna_h)" 6.98 "maior silêncio ENTRE VEREDITOS" &&
  trun UTC "$RT" --hours 24 && has "$OUT" "veredito em 15 hora(s) UTC (decisão de qualquer tipo em 19; intervalo de 24,00 h, maior silêncio entre vereditos 6,98 h), 58 linha(s) na janela, 2 sem hora legível"
}
chk_horas_com_dado() {
  jrun UTC "$SP" --hours 24 --min-hours 24 --min-beads 2; eq "$(jf .rota.analise.horas_cobertas)" 2 "span: duas linhas a 24 h de distância são DUAS horas" && eq "$(jf .rota.analise.intervalo_h)" 24 "span: intervalo" &&
  eq "$(jf .prontidao.suficiente_para_revisar)" false "span: 24 h de intervalo não são 24 h com dado" && eq "$(jf '.prontidao.falta|join(";")')" "a sombra tem veredito em 2 hora(s) UTC de 24" "span: falta" &&
  jrun UTC "$DIA" --min-hours 24 --min-beads 25 && eq "$(jf .janela.horas)" 48 "dia: janela padrão" && eq "$(jf .rota.analise.horas_cobertas)" 25 "dia: um veredito em cada hora" && eq "$(jf .prontidao.suficiente_para_revisar)" true "dia: 25 horas com dado"
}
chk_aviso_pilot_sem_veredito() {
  jrun UTC "$PV" --hours 24; eq "$(jf '.rota.analise.avisos|length')" 1 aviso && eq "$(jf .rota.analise.pilot_linhas)" 2 linhas && eq "$(jf .rota.analise.beads_com_veredito)" 0 sem-veredito &&
  trun UTC "$PV" --hours 24 && has "$OUT" "ATENÇÃO — o Pilot gravou 2 linha(s) e NENHUMA deu veredito" &&
  jrun UTC "$RT" --hours 24 && eq "$(jf '.rota.analise.avisos|length')" 0 "RT tem veredito: sem aviso"
}
chk_modos() {
  jrun UTC "$RT" --hours 24; eq "$RC" 0 rc && eq "$(jf '.rota.analise.modos|to_entries|map("\(.key)=\(.value)")|join(",")')" "?=1,label=5,shadow=13" modos && eq "$(jf .rota.analise.pilot_linhas)" 18 pilot_linhas &&
  eq "$(jf '.rota.analise.pilot_ultimo|tojson')" "{\"mode\":\"shadow\",\"rc\":0,\"ts\":$((NOW-3600))}" pilot_ultimo &&
  trun UTC "$RT" --hours 24 && has "$OUT" "última linha do Pilot: 2026-10-20T11:00:00Z, modo shadow, rc 0"
}
chk_soltas_leituras() { jrun UTC "$RT" --hours 24; eq "$(jf .rota.analise.soltas)" 2 soltas && eq "$(jf .rota.analise.leituras_que_falharam)" 2 leituras; }
chk_ordem_do_arquivo() { jrun UTC "$RT" --hours 24; eq "$(vf node-sombra)" 4 sombra && eq "$(vf mini)" 6 mini && eq "$(cf wa-w1 .ultimo)" node-sombra w1; }

# ============================== PRONTIDÃO ==============================
chk_prontidao_falta() {
  jrun UTC "$RT" --hours 24; eq "$(jf .prontidao.suficiente_para_revisar)" false suficiente && eq "$(jf '.prontidao.falta|join(";")')" "a sombra tem veredito em 15 hora(s) UTC de 24;20 bead(s) com veredito de 30" falta &&
  trun UTC "$RT" --hours 24 && has "$OUT" 'INSUFICIENTE: a sombra tem veredito em 15 hora(s) UTC de 24; 20 bead(s) com veredito de 30. Não ligue o `auto` com isto.'
}
chk_prontidao_beads_na_borda() {
  jrun UTC "$RT" --hours 24 --min-hours 15 --min-beads 20; eq "$(jf .prontidao.suficiente_para_revisar)" true "20 de 20" && eq "$(jf .prontidao.a_conferir)" 18 a_conferir && eq "$(jf .prontidao.instaveis)" 4 instaveis &&
  eq "$(jf .prontidao.escrita_nao_confirmada)" 4 escrita_nao_confirmada && eq "$(jf .prontidao.incoerentes)" 2 incoerentes &&
  trun UTC "$RT" --hours 24 --min-hours 15 --min-beads 20 && has "$OUT" "base suficiente PARA REVISAR: confira as 18 bead(s) da lista acima; 4 mudaram de veredito; 4 com escrita não confirmada; 2 com rc/veredito incoerentes. Quem liga o auto é uma pessoa." &&
  jrun UTC "$RT" --hours 24 --min-hours 15 --min-beads 21 && eq "$(jf .prontidao.suficiente_para_revisar)" false "20 de 21"
}
chk_prontidao_so_veredito() {
  jrun UTC "$RT" --hours 24 --min-hours 0 --min-beads 21; eq "$(jf .rota.analise.beads_distintas)" 31 distintas && eq "$(jf .prontidao.suficiente_para_revisar)" false "31 distintas, mas só 20 com veredito" &&
  eq "$(jf '.prontidao.falta|join(";")')" "20 bead(s) com veredito de 21" falta
}
chk_prontidao_horas_na_borda() {
  jrun UTC "$RT" --hours 24 --min-beads 0 --min-hours 15; eq "$(jf .prontidao.suficiente_para_revisar)" true "15 de 15" &&
  jrun UTC "$RT" --hours 24 --min-beads 0 --min-hours 16 && eq "$(jf .prontidao.suficiente_para_revisar)" false "15 de 16" && eq "$(jf '.prontidao.falta|join(";")')" "a sombra tem veredito em 15 hora(s) UTC de 16" falta
}
chk_prontidao_inalcancavel() {
  jrun UTC "$RT" --hours 24 --min-beads 0 --min-hours 26; eq "$(jf .prontidao.suficiente_para_revisar)" false "26 h não cabem" &&
  eq "$(jf '.prontidao.falta|join(";")')" "--min-hours 26 não cabe na janela de 24 h (no máximo 25 hora(s) UTC): aumente --hours" "falta 26" &&
  jrun UTC "$RT" --hours 24 --min-beads 0 --min-hours 25 && eq "$(jf '.prontidao.falta|join(";")')" "a sombra tem veredito em 15 hora(s) UTC de 25" "falta 25 (cabe: é só falta de dado)" &&
  jrun UTC "$DIA" --hours 24 --min-beads 25 --min-hours 25 && eq "$(jf .prontidao.suficiente_para_revisar)" true "25 horas UTC cabem numa janela de 24 h"
}
chk_prontidao_nunca_aprova() { trun UTC "$RT" --hours 24 --min-hours 15 --min-beads 1; has "$OUT" "base suficiente PARA REVISAR" && hasnt "$OUT" "aprovad" && hasnt "$OUT" "APROVAD"; }

# ============================== OCUPAÇÃO (sempre em TZ=BRT3: a hora do rótulo é UTC mesmo assim) ==============================
chk_ocup_totais() {
  jrun BRT3 "$OC" --hours 24; eq "$RC" 0 rc && eq "$(jf .ocupacao.estado)" ok estado && eq "$(jf .ocupacao.analise.leituras)" 13 leituras && eq "$(jf .ocupacao.analise.sem_epoch)" 3 sem_epoch &&
  eq "$(jf .ocupacao.analise.cpu_lidas)" 7 cpu_lidas && eq "$(jf .ocupacao.analise.cpu_sem_leitura)" 6 cpu_sem && eq "$(jf .ocupacao.analise.pct_medio)" 73.6 pct_medio &&
  eq "$(jf .ocupacao.analise.perto_de_100)" 4 perto && eq "$(jf .ocupacao.analise.perto_de_100_pct)" 57.1 perto_pct &&
  eq "$(jf .ocupacao.analise.sessoes_lidas)" 7 sess_lidas && eq "$(jf .ocupacao.analise.sessoes_nao_lidas)" 6 sess_nao && eq "$(jf .ocupacao.analise.leituras_com_wa_no_no)" 3 com_wa
}
chk_ocup_horas_utc() {
  jrun BRT3 "$OC" --hours 24; eq "$(jf '.ocupacao.analise.horas|map(.hora)|join(",")')" "2026-10-19T12:00Z,2026-10-20T08:00Z,$H09,$H10,$H11,2026-10-20T12:00Z" horas
}
chk_ocup_hora09() {
  jrun BRT3 "$OC" --hours 24; eq "$(oh $H09 .leituras)" 4 leituras && eq "$(oh $H09 .cpu_lidas)" 2 lidas && eq "$(oh $H09 .cpu_sem)" 2 sem && eq "$(oh $H09 .pct_medio)" 90 medio &&
  eq "$(oh $H09 .pct_min)" 80 min && eq "$(oh $H09 .pct_max)" 100 max && eq "$(oh $H09 .nucleos_medio)" 16 nucleos
}
chk_ocup_wa_remoto() { jrun BRT3 "$OC" --hours 24; eq "$(oh $H09 .wa_medio)" 1 "wa remoto na hora 09 (o wa-worker-1 do mini não conta)" && eq "$(oh $H11 .wa_medio)" 1 hora11; }
chk_ocup_hora_sem_cpu() {
  jrun BRT3 "$OC" --hours 24; eq "$(oh $H08 .pct_medio)" null "08Z pct_medio" && eq "$(oh $H08 .pct_min)" null "08Z min" && eq "$(oh $H08 .cpu_lidas)" 0 "08Z lidas" && eq "$(oh $H08 .wa_medio)" null "08Z wa" &&
  eq "$(oh $H10 .pct_medio)" 0 "10Z: o 0% de verdade" && eq "$(oh $H10 .cpu_lidas)" 1 "10Z lidas" && eq "$(oh $H10 .cpu_sem)" 2 "10Z sem" && eq "$(oh $H11 .pct_medio)" 92.5 "11Z"
}
chk_ocup_texto() {
  trun BRT3 "$OC" --hours 24; has "$OUT" "13 leitura(s) na janela (esperadas ~96, uma a cada 15 min); CPU lida em 7, SEM CPU lida em 6" &&
  has "$OUT" "Média da janela: 73,6%; leituras com CPU >= 90%: 4 de 7 (57,1%)" && has "$OUT" "sessões wa-worker-remote vivas em 3 leitura(s) (de 7 com sessões lidas; 6 sem sessões lidas)" && hasnt "$OUT" "delas com entrada ilegível" &&
  printf '%s\n' "$OUT" | grep -qE "^  $H08 +2 +0 +— +— +— +— +—$" && printf '%s\n' "$OUT" | grep -qE "^  $H10 +3 +1 +0,0 +0,0 +0,0 +16,00 +0,00$"
}
chk_ocup_bordas() {
  jrun BRT3 "$OC" --hours 24; eq "$(oh 2026-10-19T12:00Z .leituras)" 1 "a leitura exatamente na borda de baixo" && eq "$(oh 2026-10-20T12:00Z .leituras)" 1 "a leitura exatamente agora (a de agora+1s fica fora)"
}
chk_sem_epoch() { jrun BRT3 "$OC" --hours 24; eq "$(jf .ocupacao.analise.sem_epoch)" 3 "sem epoch / epoch em texto / epoch NaN" && trun BRT3 "$OC" --hours 24 && hasnt "$OUT" "janela de 24 h, até 2026-10-20T12:00:00Z." ; }
chk_tabela_72() {
  run UTC --city "$MU" --hours 100; local t="$OUT" rc=$RC
  eq "$rc" 0 rc && eq "$(printf '%s\n' "$t" | grep -cE '^  20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:00Z ')" 72 "linhas da tabela" && has "$t" "(8 hora(s) mais antigas omitidas aqui; --json traz todas)" &&
  printf '%s\n' "$t" | grep -qE '^  2026-10-17T13:00Z ' && printf '%s\n' "$t" | grep -qE '^  2026-10-20T12:00Z ' &&
  run UTC --city "$MU" --hours 100 --json && J=$OUT && eq "$(jf '.ocupacao.analise.horas|length')" 80 "o JSON traz todas"
}
chk_ocup_ilegiveis() {
  jrun UTC "$OI" --hours 24; eq "$RC" 0 rc && eq "$(jf .ocupacao.analise.sessoes_lidas)" 1 lidas && eq "$(jf .ocupacao.analise.sessoes_nao_lidas)" 4 nao_lidas &&
  eq "$(jf .ocupacao.analise.sessoes_com_entrada_ilegivel)" 4 "com entrada ilegível (N>0, texto, true, false)" && eq "$(jf .ocupacao.analise.leituras_com_wa_no_no)" 1 com_wa &&
  eq "$(oh $H11 .wa_medio)" 1 "wa_medio só sobre a leitura inteira" &&
  trun UTC "$OI" --hours 24 && has "$OUT" "(de 1 com sessões lidas; 4 sem sessões lidas, 4 delas com entrada ilegível: a lista pode estar incompleta e não entra na conta)"
}

# ============================== FUNIL ==============================
fc() { jf ".funil.analise.categorias.$1|\"\(.linhas)/\(.beads)\""; }
# <TZ> <log do Pilot>: a mesma contagem, qualquer que seja o fuso de quem roda (o log grava a hora LOCAL, sem fuso)
funil_esperado() {
  run "$1" --city "$FU" --pilot-log "$2" --dispatchable "$NOFILA" --hours 24 --json; J=$OUT
  eq "$RC" 0 rc && eq "$(jf .funil.estado)" ok estado && eq "$(jf .funil.analise.rodadas)" 3 rodadas &&
  eq "$(fc cedida)" "6/3" cedida && eq "$(fc teto)" "4/3" teto && eq "$(fc claim)" "5/4" "claim (inclui as duas beads exatamente nas bordas da janela)" && eq "$(fc mini)" "2/2" mini &&
  eq "$(jf .funil.analise.sem_hora)" 3 "sem hora legível (a claim sem hora, a hora impossível e o início de rodada sem hora)" &&
  eq "$(jf .funil.analise.no_gancho)" 2 no_gancho && eq "$(jf .funil.analise.ao_no)" 0 ao_no && eq "$(jf .funil.analise.pararam_antes)" 4 pararam_antes && eq "$(jf .funil.analise.gancho_gravou)" false gancho_gravou
}
chk_funil_utc() { funil_esperado UTC "$PLU"; }
chk_funil_fuso() { funil_esperado BRT3 "$PLB"; }
chk_funil_texto() {
  run UTC --city "$FU" --pilot-log "$PLU" --dispatchable "$NOFILA" --hours 24; has "$OUT" "3 rodada(s) do Pilot na janela" &&
  has "$OUT" "cedidas ou no teto e SEM NENHUMA linha na rota: 4 bead(s)" && has "$OUT" "2 bead(s)  (atribuídas ao nó: 0)" &&
  has "$OUT" "3 linha(s) do funil sem hora legível (ausente ou impossível), FORA das contas acima" &&
  has "$OUT" "ATENÇÃO — o Pilot não gravou NENHUMA linha de rota na janela" && hasnt "$OUT" "o nó nunca viu"
}
# o gancho gravou (linha do Pilot) e uma bead só tem leitura que falhou: TEM linha na rota, mesmo sem veredito
chk_funil_gancho() {
  run UTC --city "$F2" --pilot-log "$PLU" --dispatchable "$NOFILA" --hours 24 --json; J=$OUT
  eq "$(jf .funil.analise.no_gancho)" 3 "wa-c2, wa-c1 e wa-t2 (esta só com leitura que falhou) têm linha na rota" && eq "$(jf .funil.analise.pararam_antes)" 2 "só wa-c3 e wa-hut4l5.4 ficaram sem linha" &&
  eq "$(jf .funil.analise.gancho_gravou)" true gancho_gravou &&
  run UTC --city "$F2" --pilot-log "$PLU" --dispatchable "$NOFILA" --hours 24 && has "$OUT" "cedidas ou no teto e SEM NENHUMA linha na rota: 2 bead(s)" &&
  has "$OUT" "sem linha na rota não prova que o nó não viu" && hasnt "$OUT" "ATENÇÃO — o Pilot não gravou NENHUMA linha"
}
# rota ausente ou ilegível → NÃO SEI (null), nunca 0 e nunca "todas pararam"; rota VAZIA é uma resposta (nenhuma bead tem linha → as 5 cedidas/no teto ficaram sem)
chk_funil_sem_rota() {
  local c
  for c in "$SR" "$LR"; do
    run UTC --city "$c" --pilot-log "$PLU" --dispatchable "$NOFILA" --hours 24 --json; J=$OUT
    eq "$RC" 0 rc && eq "$(jf .funil.estado)" ok estado && eq "$(jf .funil.analise.pararam_antes)" null pararam_antes && eq "$(jf .funil.analise.no_gancho)" null no_gancho && eq "$(jf .funil.analise.ao_no)" null ao_no &&
    eq "$(jf .funil.analise.gancho_gravou)" null gancho_gravou && eq "$(fc cedida)" "6/3" "cedida (a contagem do log não depende da rota)" || return 1
  done
  run UTC --city "$SR" --pilot-log "$PLU" --dispatchable "$NOFILA" --hours 24 && has "$OUT" "NÃO SEI — o log de rota (seção 1) não foi lido" &&
  run UTC --city "$VZ" --pilot-log "$PLU" --dispatchable "$NOFILA" --hours 24 --json && J=$OUT && eq "$(jf .funil.analise.no_gancho)" 0 "rota vazia: nenhuma tem linha" && eq "$(jf .funil.analise.pararam_antes)" 5 "rota vazia: as 5 ficaram sem linha" &&
  eq "$(jf .funil.analise.gancho_gravou)" false "rota vazia: o Pilot não gravou"
}
chk_funil_estados() {
  run UTC --city "$FU" --pilot-log "$NOPILOT" --dispatchable "$NOFILA" --hours 24 --json; J=$OUT; eq "$(jf .funil.estado)" ausente "log do Pilot ausente" && eq "$(jf .funil.analise)" null "sem análise" &&
  run UTC --city "$FU" --pilot-log "$FX/pilot-dir.log" --dispatchable "$NOFILA" --hours 24 --json && J=$OUT && eq "$(jf .funil.estado)" ilegivel "pasta no lugar do log" &&
  run UTC --city "$FU" --pilot-log "$FX/pilot-vazio.log" --dispatchable "$NOFILA" --hours 24 --json && J=$OUT && eq "$(jf .funil.estado)" vazio "log vazio" &&
  run UTC --city "$FU" --pilot-log "$NOPILOT" --dispatchable "$NOFILA" --hours 24 && has "$OUT" "AUSENTE" && has "$OUT" "NÃO é zero" || return 1
  # o log existe e nada cai na janela: é "ok" com zeros (a resposta é "nenhuma"), não "vazio" nem "ausente"
  NOWENV=$((NOW - 2592000)); run UTC --city "$FU" --pilot-log "$PLU" --dispatchable "$NOFILA" --hours 24 --json; J=$OUT; unset NOWENV
  eq "$(jf .funil.estado)" ok "log com linhas, nenhuma na janela" && eq "$(jf .funil.analise.rodadas)" 0 rodadas && eq "$(fc cedida)" "0/0" cedida
}
chk_wa_id_sem_ponto() { # o id não leva o ponto final da frase: carrega o módulo e testa as linhas do Pilot de verdade
  python3 -I - "$SCRIPT" <<'PYEOF' >/dev/null 2>&1
import importlib.util, sys
sys.dont_write_bytecode = True  # carregar o script não pode deixar um __pycache__ na árvore
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
  eq "$(jf .fila.estado)" ok estado && eq "$(jf .fila.analise.wa)" 6 wa && eq "$(jf .fila.analise.total)" 9 total && eq "$(jf .fila.analise.itens_ilegiveis)" 1 "o item que não é objeto" &&
  eq "$(jf '.fila.analise.prioridades|tojson')" '{"0":1,"1":2,"2":1,"3":1,"?":1}' prioridades && eq "$(jf .fila.analise.idade_s)" 2400 idade && eq "$(jf .fila.analise.ttl_s)" 1800 ttl
}
chk_fila_texto() {
  fila_run "$FX/fila-ok.json"; has "$OUT" "fila despachável: 6 de WA entre 9 (gerada há 40 min, VENCIDA); por prioridade: P0=1, P1=2, P2=1, P3=1, P?=1; 1 item(ns) que não é(são) objeto, fora da conta de WA" &&
  fila_run "$FX/fila-fresca.json" && has "$OUT" "gerada há 2 min)" && hasnt "$OUT" "VENCIDA" &&
  fila_run "$FX/fila-na-borda.json" && has "$OUT" "gerada há 30 min)" && hasnt "$OUT" "VENCIDA"
}
# gerada no futuro, sem hora ou com hora impossível (mês 13): idade null (não sei), nunca 0, nunca negativa — e o relatório NÃO cai
chk_fila_hora_ruim() {
  local f
  for f in fila-futura fila-sem-hora fila-hora-impossivel; do
    fila_run "$FX/$f.json" --json; J=$OUT
    eq "$RC" 0 "$f: rc" && eq "$(jf .fila.estado)" ok "$f: estado" && eq "$(jf .fila.analise.idade_s)" null "$f: idade" || return 1
  done
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
# os caminhos padrão: o log do Pilot na cidade, a fila em $HOME/.gc — e sem a fila no HOME ela é AUSENTE (nunca a do usuário de verdade)
chk_caminhos_padrao() {
  HOMEENV="$HM"; run UTC --city "$PD" --hours 24 --json; J=$OUT; unset HOMEENV
  eq "$RC" 0 rc && eq "$(jf .funil.estado)" ok "log padrão da cidade" && eq "$(jf .funil.arquivo)" "$PD/.gc/logs/pilot-dispatcher.log" arquivo_log && eq "$(fc cedida)" "6/3" cedida &&
  eq "$(jf .fila.estado)" ok "fila padrão em HOME/.gc" && eq "$(jf .fila.arquivo)" "$HM/.gc/pilot-dispatchable.json" arquivo_fila && eq "$(jf .fila.analise.wa)" 6 wa &&
  run UTC --city "$PD" --hours 24 --json && J=$OUT && eq "$(jf .fila.estado)" ausente "HOME sem a fila: ausente"
}
# caminho vazio é uso errado (rc 2), nunca "o padrão"
chk_caminho_vazio_rc2() {
  local r1
  run UTC --city "$RT" --pilot-log ""; r1=$RC
  run UTC --city "$RT" --dispatchable ""
  eq "$r1" 2 "--pilot-log vazio" && eq "$RC" 2 "--dispatchable vazio"
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
  trun UTC "$VZ" && has "$OUT" "vazio (" && has "$OUT" "nenhuma linha ainda" && has "$OUT" "INSUFICIENTE: a sombra tem veredito em 0 hora(s) UTC de 24; 0 bead(s) com veredito de 30"
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
  for a in "--hours 1" "--hours 99999" "--busy-pct 100" "--busy-pct 1" "--min-hours 0" "--min-beads 0" "--pilot-log $NOPILOT" "--dispatchable $NOFILA"; do
    run UTC --city "$RT" $a
    [ "$RC" = 0 ] || { [ "$VERBOSE" = 1 ] && echo "      '$a' → rc $RC (esperado 0)" >&2; return 1; }
  done
}
chk_horas_decimal() {
  jrun UTC "$RT" --hours 010; eq "$(jf .janela.horas)" 10 "010 é dez" && eq "$(jf .rota.analise.primeira)" "$((NOW-36000))" "a janela de 10 h abre em agora-10h" &&
  jrun UTC "$RT" && eq "$(jf .janela.horas)" 48 padrao && eq "$(jf .janela.inicio)" "$((NOW-172800))" inicio && eq "$(jf .janela.fim)" "$NOW" fim
}
chk_now_env() {
  NOWENV=abc; run UTC --city "$RT"; local r1=$RC
  NOWENV=""; run UTC --city "$NA"; local r2=$RC
  unset NOWENV; eq "$r1" 2 "WA_NODE_REPORT_NOW=abc" && eq "$r2" 3 "WA_NODE_REPORT_NOW vazio = a hora de agora"
}
chk_somente_leitura() {
  local a b d
  a=$(cd "$T" && { find fx -type f -exec cksum {} +; find fx; } | sort)
  for d in rota ocup muitas sr lr dr na vz lx dn span dia pv oi funil funil2 padrao; do jrun UTC "$FX/$d"; trun BRT3 "$FX/$d" --hours 100; done
  run UTC --city "$FU" --pilot-log "$PLU" --dispatchable "$FX/fila-ok.json" --hours 24; run BRT3 --city "$F2" --pilot-log "$PLB" --dispatchable "$FX/fila-hora-impossivel.json" --json
  HOMEENV="$HM"; run UTC --city "$PD" --hours 24; unset HOMEENV
  NOWENV=$(( $(date -u +%s) + 5 )); jrun UTC "$RL"; trun BRT3 "$RL" --hours 100; unset NOWENV
  b=$(cd "$T" && { find fx -type f -exec cksum {} +; find fx; } | sort)
  eq "$a" "$b" "a árvore de fixtures depois de rodar tudo"
}
chk_json_uma_linha() {
  local d
  for d in rota ocup na vz funil; do
    jrun UTC "$FX/$d"
    printf '%s' "$J" | jq -e 'type=="object"' >/dev/null 2>&1 || { [ "$VERBOSE" = 1 ] && echo "      $d: a saída não é um objeto JSON" >&2; return 1; }
    eq "$(printf '%s\n' "$J" | wc -l | tr -d ' ')" 1 "$d: linhas" || return 1
    eq "$(jf 'keys|join(",")')" "fila,funil,janela,ocupacao,prontidao,rota" "$d: chaves" || return 1
  done
}

# ============================== O QUE NÃO É LEITURA, EVENTO DESCONHECIDO, BASE DO NODE ANTERIOR ==============================
chk_ocup_nao_leitura() {
  jrun BRT3 "$OC" --hours 24; eq "$(jf '.ocupacao.analise.eventos_que_nao_sao_leitura|to_entries|map("\(.key)=\(.value)")|sort|join(",")')" "?=1,reaper=2" "eventos: só os da janela (o de -25 h fica fora)" &&
  eq "$(jf .ocupacao.analise.linhas_sem_forma_de_leitura)" 1 "sem tipo, sem cpu e sem sessoes" && eq "$(jf .ocupacao.analise.leituras)" 13 "leituras = SÓ as do vigia" &&
  eq "$(oh $H09 .leituras)" 4 "09Z: a linha do reaper não é leitura" && eq "$(oh $H10 .leituras)" 3 "10Z" && eq "$(oh $H11 .leituras)" 2 "11Z" &&
  eq "$(jf .ocupacao.analise.cpu_sem_leitura)" 6 "o reaper não vira CPU não lida" && eq "$(jf .ocupacao.analise.sessoes_nao_lidas)" 6 "nem sessões não lidas" && eq "$(jf .ocupacao.analise.cpu_lidas)" 7 "cpu_lidas" &&
  trun BRT3 "$OC" --hours 24 && has "$OUT" "7 linha(s) que NÃO são leitura do vigia, FORA das contas acima (?=1, reaper=2, sem cpu nem sessões=1, sem epoch legível=3)"
}
chk_ocup_so_reaper() {
  jrun UTC "$SOR" --hours 24; eq "$RC" 0 rc && eq "$(jf .ocupacao.estado)" ok estado && eq "$(jf .ocupacao.analise.leituras)" 0 "só reaper: zero leituras" && eq "$(jf .ocupacao.analise.cpu_sem_leitura)" 0 "o reaper não vira CPU não lida" &&
  eq "$(jf .ocupacao.analise.sessoes_nao_lidas)" 0 "nem sessões não lidas" && eq "$(jf '.ocupacao.analise.horas|length')" 0 "nenhuma hora na tabela" && eq "$(jf .ocupacao.analise.pct_medio)" null "média: não li (null), nunca 0" &&
  trun UTC "$SOR" --hours 24 && has "$OUT" "0 leitura(s) na janela" && has "$OUT" "2 linha(s) que NÃO são leitura do vigia, FORA das contas acima (reaper=2)"
}
chk_eventos_desconhecidos() {
  jrun UTC "$EV" --hours 24; eq "$(jf '.rota.analise.eventos_desconhecidos|to_entries|map("\(.key)=\(.value)")|sort|join(",")')" "?=3,futuro=2" "desconhecidos (event ausente, vazio, não-texto, e um nome novo)" &&
  eq "$(jf .rota.analise.outras_ilegiveis)" 0 "sem bead e desconhecido: não é 'linha ilegível'" && eq "$(jf .rota.analise.apply_ilegivel)" 0 apply_ilegivel && eq "$(jf .rota.analise.linhas_na_janela)" 6 "as seis entram na janela" &&
  eq "$(jf .rota.analise.beads_distintas)" 1 "só a wa-ev0 é bead com decisão" && eq "$(jf .rota.analise.decisoes)" 1 decisoes && eq "$(jf .rota.analise.pilot_linhas)" 1 "o Pilot gravou uma" &&
  trun UTC "$EV" --hours 24 && has "$OUT" "ATENÇÃO — 5 linha(s) de evento que este relatório não conhece, FORA das contas (?=3, futuro=2)" &&
  jrun UTC "$RT" --hours 24 && eq "$(jf '.rota.analise.eventos_desconhecidos|length')" 0 "o log de verdade só tem evento conhecido"
}
chk_horas_so_sem_veredito() {
  jrun UTC "$SV" --hours 24 --min-hours 2 --min-beads 0; eq "$(jf .rota.analise.horas_com_decisao)" 4 "4 horas com apply" && eq "$(jf .rota.analise.horas_cobertas)" 1 "só 1 hora COM VEREDITO (apply sem veredito não conta)" && eq "$(jf .rota.analise.maior_lacuna_h)" 0 "um veredito só: sem silêncio a medir" &&
  eq "$(jf .prontidao.suficiente_para_revisar)" false "1 hora com veredito de 2" && eq "$(jf '.prontidao.falta|join(";")')" "a sombra tem veredito em 1 hora(s) UTC de 2" falta &&
  trun UTC "$SV" --hours 24 && has "$OUT" "veredito em 1 hora(s) UTC (decisão de qualquer tipo em 4;"
}
chk_node_anterior() {
  jrun UTC "$RT" --hours 24; eq "$(cf wa-sn2 .do_node_anterior)" true "sn2: node e depois mini → base e razões são do node ANTERIOR" && eq "$(cf wa-sn1 .do_node_anterior)" false "sn1: o último É node" && eq "$(cf wa-sx1 .do_node_anterior)" false "sx1: na lista só por ser incoerente, nunca foi node: não há node anterior" && eq "$(cf wa-sn2 .base)" label "sn2: a base segue no JSON" &&
  trun UTC "$RT" --hours 24 && has "$OUT" "wa-sn2  [mini, base label do node anterior]  razões do node anterior: c" && has "$OUT" "wa-sn1  [node, só sombra (shadow/dry-run), base code]  razões: a; b"
}

# ---- o caso real: cada função tem de passar contra o script de verdade
check() { SCRIPT="$REAL"; VERBOSE=1; if "chk_$1"; then ok "$1"; else bad "$1"; fi; VERBOSE=0; }
for c in veredito_final sombra_nao_e_entrega ultimo_por_hora instaveis conferir_lista base razoes razoes_so_rc0 sombra_so_shadow incoerente rc13 hook_real apply_ilegivel linhas_ilegiveis janela_rota \
         cobertura horas_com_dado aviso_pilot_sem_veredito modos soltas_leituras ordem_do_arquivo \
         prontidao_falta prontidao_beads_na_borda prontidao_so_veredito prontidao_horas_na_borda prontidao_inalcancavel prontidao_nunca_aprova \
         ocup_totais ocup_horas_utc ocup_hora09 ocup_wa_remoto ocup_hora_sem_cpu ocup_texto ocup_ilegiveis ocup_bordas sem_epoch tabela_72 ocup_nao_leitura ocup_so_reaper eventos_desconhecidos horas_so_sem_veredito node_anterior \
         funil_utc funil_fuso funil_texto funil_gancho funil_sem_rota funil_estados wa_id_sem_ponto fila_ok fila_texto fila_hora_ruim fila_estados caminhos_padrao caminho_vazio_rc2 \
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
mut etiqueta-vira-mini chk_veredito_final 'return "node-sem-etiqueta" if detail.startswith("base=") else ("mini" if detail.startswith("classificador:mini") else "outro")' 'return "mini"'
mut unknown-vira-nao-li chk_veredito_final 'return "nao-sei" if detail.startswith("classificador:unknown") else "nao-li"' 'return "nao-li"'
mut capacidade-vira-nao-elegivel chk_veredito_final 'return "node-sem-vaga" if re.split(r"[ =:]", detail, maxsplit=1)[0] in SEM_VAGA else "nao-elegivel"' 'return "nao-elegivel"'
mut split-sem-dois-pontos chk_veredito_final 'r"[ =:]"' 'r"[ =]"'
mut nao-elegivel-vira-sem-vaga chk_veredito_final 'in SEM_VAGA else "nao-elegivel"' 'in SEM_VAGA else "node-sem-vaga"'
mut rc-bool-vale-int chk_apply_ilegivel 'if not rc_ok or not isinstance(det, str):' 'if not isinstance(rc, int) or not isinstance(det, str):'
mut apply-ilegivel-calado chk_apply_ilegivel "                apply_ilegivel += 1${nl}                continue${nl}            decisoes += 1" "                continue${nl}            decisoes += 1"
mut ordem-do-arquivo chk_ordem_do_arquivo 'ev.sort(key=lambda t: (t[0], t[1]))' 'ev.sort(key=lambda t: t[1])'
mut janela-rota-baixa-exclusiva chk_janela_rota '        elif lo <= e <= hi:' '        elif lo < e <= hi:'
mut janela-rota-alta-exclusiva chk_janela_rota '        elif lo <= e <= hi:' '        elif lo <= e < hi:'
mut janela-rota-sem-teto chk_janela_rota '        elif lo <= e <= hi:' '        elif lo <= e:'
mut primeiro-no-lugar-do-ultimo chk_ultimo_por_hora "            b[\"final\"] = vs[-1]${nl}            final[vs[-1]] += 1" "            b[\"final\"] = vs[0]${nl}            final[vs[0]] += 1"
mut instavel-so-mini chk_instaveis 'any(c in ("mini", "nao-sei") for c in vs)' 'any(c == "mini" for c in vs)'
mut conferir-so-o-final chk_conferir_lista 'if any(c in NODE_CATS for c in b["cats"]) or' 'if b.get("final") in NODE_CATS or'
mut cobertura-em-minutos chk_cobertura 'round((ev[-1][0] - ev[0][0]) / 3600.0, 2)' 'round((ev[-1][0] - ev[0][0]) / 60.0, 2)'
mut razoes-com-qualquer-rc chk_razoes_so_rc0 'if rc == 0 and isinstance(out, str) and out.strip():' 'if isinstance(out, str) and out.strip():'
mut razoes-sem-teto chk_razoes '[str(x) for x in rs][:6]' '[str(x) for x in rs]'
mut razoes-nao-lista chk_razoes 'if isinstance(rs, list):' 'if rs:'
mut modo-nao-texto chk_modos 'mo = r.get("mode") if isinstance(r.get("mode"), str) else "?"' 'mo = r.get("mode")'
mut solta-qualquer-rc chk_soltas_leituras 'elif rc == 0:' 'elif rc != 13:'
mut leitura-so-read chk_soltas_leituras 'elif kind in ("read", "classify"):' 'elif kind in ("read",):'
mut base-solta-demais chk_base 'if c in ("node-sombra", "node-despachada"):' 'if c in NODE_CATS:' 'm = re.match(r"(?:dry-run: iria para|despachada para) \S+ \(([A-Za-z0-9_-]+)\)", det)' 'm = re.search(r"\(([A-Za-z0-9_-]+)\)", det)'
mut etiqueta-sem-base chk_base 'm = re.match(r"base=([A-Za-z0-9_-]+)", det)' 'm = None'
mut array-nao-conta chk_linhas_ilegiveis "        else:${nl}            bad += 1${nl}    if not rows and bad:" "        else:${nl}            pass${nl}    if not rows and bad:"
# -- rota, linha do Pilot em modo shadow (a única da decisão)
mut shadow-ignorado chk_sombra_so_shadow '            if mo == "shadow":' '            if False:'
mut shadow-modo-qualquer chk_incoerente '            if mo == "shadow":' '            if True:'
mut shadow-vira-despachada chk_sombra_nao_e_entrega '0: ("node", "node-sombra")' '0: ("node", "node-despachada")'
mut aceita-qualquer-veredito chk_incoerente '    if v == esperado:' '    if True:'
mut incoerente-sem-marca chk_incoerente '                if inco:' '                if False:'
mut rc11-vazio-vira-nao-sei chk_sombra_so_shadow '    if rc == 11 and not (isinstance(out, str) and out.strip()):' '    if False:'
mut rc-estranho-vira-mini chk_sombra_so_shadow "    if rc not in SHADOW_PAR:${nl}        return \"nao-li\", False, None" "    if rc not in SHADOW_PAR:${nl}        return \"mini\", False, None"
mut base-shadow-sem-regex chk_base 'base = bs if isinstance(bs, str) and re.fullmatch(r"[A-Za-z0-9_-]+", bs) else None' 'base = bs if isinstance(bs, str) else None'
mut shadow-le-campo-errado chk_hook_real '            out = r.get("out")' '            out = r.get("saida")'
mut rc10-desconhecido-vira-mini chk_veredito_final '("mini" if detail.startswith("classificador:mini") else "outro")' '"mini"'
# -- rota, escrita que pode ter pegado (rc 13, prazo) e linha sem dono
mut rc13-nao-lista chk_rc13 '            if rc == 13 and not det.startswith("conferencia-falhou-desfeito"):' '            if False:'
mut desfeito-vira-incerta chk_rc13 '            if rc == 13 and not det.startswith("conferencia-falhou-desfeito"):' '            if rc == 13:'
mut despachada-nao-limpa chk_rc13 "                b[\"despachada\"] = True${nl}                b[\"incerta\"] = False" "                b[\"despachada\"] = True"
mut solta-nao-limpa chk_rc13 "                soltas += 1${nl}                b[\"incerta\"] = False" "                soltas += 1"
mut release13-ignorado chk_rc13 '            elif rc == 13:' '            elif False:'
mut pilot-label-prazo-ignorado chk_rc13 '            elif rc == 13 or rc >= 124:' '            elif False:'
mut pilot-rc124-estrito chk_rc13 '            elif rc == 13 or rc >= 124:' '            elif rc == 13 or rc > 124:'
mut incerta-fora-da-lista chk_rc13 ' or b["incerta"] or b["incoerente"])' ' or b["incoerente"])'
mut incoerente-fora-da-lista chk_incoerente ' or b["incoerente"])' ')'
# -- cobertura, linhas ilegíveis e aviso
mut horas-e-intervalo chk_horas_com_dado 'horas_dado = len({time.strftime("%Y-%m-%dT%H", time.gmtime(t)) for t in ver_ts})' 'horas_dado = int((ev[-1][0] - ev[0][0]) / 3600) if ev else 0'
mut horas-todas-as-linhas chk_cobertura ' for t in ver_ts})' ' for t, _j, _r in ev})'
mut pilot-fora-das-horas chk_cobertura "            pilot_linhas += 1${nl}            dec_ts.append(e)" "            pilot_linhas += 1"
mut lacuna-min chk_cobertura 'lacuna = max(' 'lacuna = min('
mut lacuna-em-minutos chk_cobertura 'round(lacuna / 3600.0, 2)' 'round(lacuna / 60.0, 2)'
mut aviso-pilot-sem-veredito chk_aviso_pilot_sem_veredito '    if pilot_linhas and not com_veredito:' '    if False:'
mut aviso-sempre chk_aviso_pilot_sem_veredito '    if pilot_linhas and not com_veredito:' '    if pilot_linhas:'
mut com-veredito-conta-tudo chk_prontidao_so_veredito 'if any(c in VEREDITOS for c in b["cats"]))' 'if b["cats"])'
mut outras-ilegiveis-calado chk_linhas_ilegiveis "                outras_ilegiveis += 1${nl}            continue" "                pass${nl}            continue"
mut pilot-rc-ilegivel-calado chk_linhas_ilegiveis "                outras_ilegiveis += 1${nl}                continue${nl}            pilot_linhas += 1" "                continue${nl}            pilot_linhas += 1"
mut release-rc-ilegivel-calado chk_linhas_ilegiveis "                outras_ilegiveis += 1${nl}            elif rc == 0:" "                pass${nl}            elif rc == 0:"
mut rc-ok-aceita-bool chk_apply_ilegivel 'rc_ok = isinstance(rc, int) and not isinstance(rc, bool)' 'rc_ok = isinstance(rc, int)'
mut horas-por-decisao chk_cobertura ' for t in ver_ts})' ' for t in dec_ts})'
mut lacuna-por-decisao chk_cobertura 'zip(ver_ts, ver_ts[1:])' 'zip(dec_ts, dec_ts[1:])'
mut veredito-apply-fora-das-horas chk_cobertura "            c = cat_of(rc, det)${nl}            if c in VEREDITOS:${nl}                ver_ts.append(e)" "            c = cat_of(rc, det)"
mut veredito-shadow-fora-das-horas chk_cobertura "                c, inco, base = shadow_cat(rc, out)${nl}                if c in VEREDITOS:${nl}                    ver_ts.append(e)" "                c, inco, base = shadow_cat(rc, out)"
mut veredito-conta-toda-decisao-apply chk_horas_so_sem_veredito "            if c in VEREDITOS:${nl}                ver_ts.append(e)" "            ver_ts.append(e)"
mut veredito-conta-toda-decisao-shadow chk_cobertura "                if c in VEREDITOS:${nl}                    ver_ts.append(e)" "                ver_ts.append(e)"
mut horas-decisao-so-veredito chk_cobertura 'horas_decisao = len({time.strftime("%Y-%m-%dT%H", time.gmtime(t)) for t in dec_ts})' 'horas_decisao = horas_dado'
mut prontidao-diz-decisao chk_prontidao_falta '"a sombra tem veredito em %d hora(s) UTC de %d"' '"a sombra tem decisão em %d hora(s) UTC de %d"'
mut texto-cobertura-sem-decisao chk_cobertura '(decisão de qualquer tipo em %d; intervalo' '(intervalo'
# -- rota, evento que o relatório não conhece
mut evento-desconhecido-passa chk_eventos_desconhecidos '        if kind not in EVENTOS_ROTA:' '        if False:'
mut evento-desconhecido-calado chk_eventos_desconhecidos '            desconhecidos[nome] = desconhecidos.get(nome, 0) + 1' '            pass'
mut evento-desconhecido-segue chk_eventos_desconhecidos "            desconhecidos[nome] = desconhecidos.get(nome, 0) + 1${nl}            continue" "            desconhecidos[nome] = desconhecidos.get(nome, 0) + 1"
mut evento-sem-nome-vira-chave chk_eventos_desconhecidos 'nome = kind if isinstance(kind, str) and kind else "?"' 'nome = kind'
mut evento-desconhecido-mudo-no-texto chk_eventos_desconhecidos '        if a["eventos_desconhecidos"]:' '        if False:'
mut evento-conhecido-faltando chk_eventos_desconhecidos 'EVENTOS_ROTA = ("apply", "release", "read", "classify", "pilot-node-route")' 'EVENTOS_ROTA = ("apply", "release", "read", "classify")'
# -- rota, base e razões que são do node ANTERIOR
mut node-anterior-nunca chk_node_anterior '"do_node_anterior": beads[bid]["final"] not in NODE_CATS and any(c in NODE_CATS for c in beads[bid]["cats"]),' '"do_node_anterior": False,'
mut node-anterior-sempre chk_node_anterior '"do_node_anterior": beads[bid]["final"] not in NODE_CATS and any(c in NODE_CATS for c in beads[bid]["cats"]),' '"do_node_anterior": True,'
mut node-anterior-sem-ter-sido-node chk_node_anterior ' and any(c in NODE_CATS for c in beads[bid]["cats"]),' ','
mut node-anterior-mudo-no-texto chk_node_anterior '                ant = " do node anterior" if n["do_node_anterior"] else ""' '                ant = ""'
# -- prontidão
mut beads-no-minimo-nao-basta chk_prontidao_beads_na_borda 'if rota["beads_com_veredito"] < min_beads:' 'if rota["beads_com_veredito"] <= min_beads:'
mut horas-no-minimo-nao-basta chk_prontidao_horas_na_borda 'elif rota["horas_cobertas"] < min_hours:' 'elif rota["horas_cobertas"] <= min_hours:'
mut suficiente-sempre chk_prontidao_falta '"suficiente_para_revisar": not falta' '"suficiente_para_revisar": True'
mut prontidao-conta-distintas chk_prontidao_so_veredito 'if rota["beads_com_veredito"] < min_beads:' 'if rota["beads_distintas"] < min_beads:'
mut inalcancavel-calado chk_prontidao_inalcancavel '    if min_hours > hours + 1:' '    if False:'
mut inalcancavel-estrito chk_prontidao_inalcancavel '    if min_hours > hours + 1:' '    if min_hours > hours:'
mut inalcancavel-frouxo chk_prontidao_inalcancavel '    if min_hours > hours + 1:' '    if min_hours > hours + 2:'
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
mut ilegiveis-ignorado chk_ocup_ilegiveis '        lista_inteira = ileg is None or (isinstance(ileg, int) and not isinstance(ileg, bool) and ileg == 0)' '        lista_inteira = True'
mut ilegiveis-bool-vale-zero chk_ocup_ilegiveis '(isinstance(ileg, int) and not isinstance(ileg, bool) and ileg == 0)' '(isinstance(ileg, int) and ileg == 0)'
mut sufixo-ilegivel-sempre chk_ocup_texto ' if b["sessoes_com_entrada_ilegivel"] else ""' ' if True else ""'
# -- ocupação, o que não é leitura do vigia (o reaper grava no mesmo arquivo)
mut reaper-vira-leitura chk_ocup_nao_leitura '        if "tipo" in r:' '        if False:'
mut reaper-so-vira-leitura chk_ocup_so_reaper '        if "tipo" in r:' '        if False:'
mut sem-forma-vira-leitura chk_ocup_nao_leitura '        if "cpu" not in r and "sessoes" not in r:' '        if False:'
mut sem-forma-so-sem-cpu chk_ocup_nao_leitura '"cpu" not in r and "sessoes" not in r' '"cpu" not in r'
mut sem-forma-basta-faltar-uma chk_ocup_nao_leitura '"cpu" not in r and "sessoes" not in r' '"cpu" not in r or "sessoes" not in r'
mut evento-nao-contado chk_ocup_nao_leitura '            eventos[tp] = eventos.get(tp, 0) + 1' '            pass'
mut sem-forma-nao-contada chk_ocup_nao_leitura '            sem_forma += 1' '            pass'
mut tipo-sem-nome-vira-chave chk_ocup_nao_leitura 'tp = tp if isinstance(tp, str) and tp else "?"' 'tp = tp'
mut nao-leitura-mudo-no-texto chk_ocup_nao_leitura '        if fora:' '        if False:'
mut nao-leitura-sem-epoch-fora-da-soma chk_ocup_nao_leitura ' + b["linhas_sem_forma_de_leitura"] + b["sem_epoch"]' ' + b["linhas_sem_forma_de_leitura"]'
mut evento-fora-da-janela-conta chk_ocup_nao_leitura "        if not (lo <= ep <= hi):${nl}            continue${nl}        # O arquivo" "        # O arquivo"
# -- estados e saída
mut lixo-vira-vazio chk_rc3_nenhum_log '        return "ilegivel", [], bad' '        return "vazio", [], bad'
mut pasta-vira-ausente chk_rc3_nenhum_log "    except OSError:${nl}        return \"ilegivel\", [], 0" "    except OSError:${nl}        return \"ausente\", [], 0"
mut vazio-vira-ok chk_rota_vazia 'return ("ok" if rows else "vazio"), rows, bad' 'return "ok", rows, bad'
mut rc3-se-qualquer-um chk_rc0_basta_um 'if re_ not in ("ok", "vazio") and oe not in ("ok", "vazio"):' 'if re_ not in ("ok", "vazio") or oe not in ("ok", "vazio"):'
mut rc3-vira-zero chk_rc3_nenhum_log '        return 3' '        return 0'
mut prontidao-sem-rota chk_rc0_basta_um '"prontidao": prontidao(ra, a.min_hours, a.min_beads, a.hours) if ra else None,' '"prontidao": prontidao(ra, a.min_hours, a.min_beads, a.hours),'
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
mut json-sem-ordem-das-chaves chk_json_uma_linha 'json.dumps(res, ensure_ascii=False, sort_keys=True)' 'json.dumps({k: v for k, v in res.items() if k != "prontidao"}, ensure_ascii=False, sort_keys=True)'

# -- funil (o log do Pilot) e a ligação com a rota
mut funil-sem-fuso chk_funil_fuso 'e = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))' 'e = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))'
mut funil-janela-sem-teto chk_funil_utc '        if not (lo <= e <= hi):' '        if not (lo <= e):'
mut funil-janela-sem-piso chk_funil_utc '        if not (lo <= e <= hi):' '        if not (e <= hi):'
mut funil-janela-piso-exclusivo chk_funil_utc '        if not (lo <= e <= hi):' '        if not (lo < e <= hi):'
mut funil-janela-teto-exclusivo chk_funil_utc '        if not (lo <= e <= hi):' '        if not (lo <= e < hi):'
mut funil-rodadas-caladas chk_funil_utc '            rodadas += 1' '            rodadas += 0'
mut funil-teto-so-um-padrao chk_funil_utc '    ("teto", re.compile(r"ga-in9ebr: wa-worker pool at session cap \(.*?\) — QUEUED " + WA_ID + r": claim released")),' '    ("teto", re.compile(r"NUNCA-CASA-" + WA_ID)),'
mut funil-mini-pega-o-no chk_funil_utc '→ wa-worker "))' '→ wa-worker"))'
mut funil-qualquer-prefixo chk_funil_utc 'WA_ID = r"(wa-[A-Za-z0-9]+(?:\.[0-9]+)*)"' 'WA_ID = r"([a-z]+-[A-Za-z0-9]+(?:\.[0-9]+)*)"'
mut funil-id-leva-o-ponto-final chk_wa_id_sem_ponto 'WA_ID = r"(wa-[A-Za-z0-9]+(?:\.[0-9]+)*)"' 'WA_ID = r"(wa-[A-Za-z0-9.]+)"'
mut funil-id-sem-sufixo chk_wa_id_sem_ponto 'WA_ID = r"(wa-[A-Za-z0-9]+(?:\.[0-9]+)*)"' 'WA_ID = r"(wa-[A-Za-z0-9]+)"'
mut funil-sem-hora-calado chk_funil_utc '                sem_hora += 1' '                sem_hora += 0'
mut funil-sem-hora-conta-tudo chk_funil_utc '            if hit or SWEEP_START in ln:' '            if True:'
mut funil-sem-hora-sem-rodada chk_funil_utc '            if hit or SWEEP_START in ln:' '            if hit:'
mut funil-hora-impossivel-quebra chk_funil_utc "            except (ValueError, OverflowError):${nl}                e = None" "            except OverflowError:${nl}                e = None"
mut funil-ilegivel-vira-vazio chk_funil_estados "        return \"ilegivel\", None${nl}    cats = {c: {" "        return \"vazio\", None${nl}    cats = {c: {"
mut funil-ausente-vira-vazio chk_funil_estados "        return \"ausente\", None${nl}    except OSError:" "        return \"vazio\", None${nl}    except OSError:"
mut funil-vazio-vira-ok chk_funil_estados 'return ("ok" if raw.strip() else "vazio"), {"rodadas"' 'return "ok", {"rodadas"'
mut funil-pararam-so-cedidas chk_funil_utc 'antes = fa["categorias"]["cedida"]["_beads"] | fa["categorias"]["teto"]["_beads"]' 'antes = fa["categorias"]["cedida"]["_beads"]'
mut funil-pararam-com-claim chk_funil_utc 'antes = fa["categorias"]["cedida"]["_beads"] | fa["categorias"]["teto"]["_beads"]' 'antes = fa["categorias"]["cedida"]["_beads"] | fa["categorias"]["teto"]["_beads"] | fa["categorias"]["claim"]["_beads"]'
mut funil-pararam-sem-rota-vira-todas chk_funil_sem_rota 'fa["pararam_antes"] = len(antes - ra["_beads"]) if ra else None' 'fa["pararam_antes"] = len(antes - (ra["_beads"] if ra else set()))'
mut funil-no-gancho-sem-rota-vira-zero chk_funil_sem_rota 'fa["no_gancho"] = len(ra["_beads"]) if ra else None' 'fa["no_gancho"] = len(ra["_beads"]) if ra else 0'
mut funil-ao-no-sem-rota-vira-zero chk_funil_sem_rota 'fa["ao_no"] = len(ra["ao_no_de_verdade"]) if ra else None' 'fa["ao_no"] = len(ra["ao_no_de_verdade"]) if ra else 0'
mut funil-gancho-gravou-sem-rota chk_funil_sem_rota 'fa["gancho_gravou"] = bool(ra["modos"]) if ra else None' 'fa["gancho_gravou"] = bool(ra["modos"]) if ra else False'
mut funil-gancho-gravou-sempre chk_funil_utc 'fa["gancho_gravou"] = bool(ra["modos"]) if ra else None' 'fa["gancho_gravou"] = True if ra else None'
mut funil-rota-so-com-veredito chk_funil_gancho '"_beads": set(beads),' '"_beads": set(b for b in beads if beads[b]["cats"]),'
mut funil-aviso-gancho-calado chk_funil_texto '            if not a["gancho_gravou"]:' '            if False:'
mut funil-aviso-gancho-sempre chk_funil_gancho '            if not a["gancho_gravou"]:' '            if True:'
mut funil-nao-sei-calado chk_funil_sem_rota '        if a["no_gancho"] is None:' '        if False:'
mut funil-sem-hora-nao-dita chk_funil_texto '        if a["sem_hora"]:' '        if False:'
mut funil-ressalva-trocada chk_funil_gancho '(sem linha na rota não prova que o nó não viu:' '(confira a rota:'
# -- fila despachável
mut fila-items-nao-lista chk_fila_estados 'if not isinstance(o, dict) or not isinstance(o.get("items"), list):' 'if not isinstance(o, dict):'
mut fila-lista-sem-dict chk_fila_estados 'if not isinstance(o, dict) or not isinstance(o.get("items"), list):' 'if not isinstance(o.get("items"), list):'
mut fila-toda-loja chk_fila_ok '        elif it.get("store") == "whatsapp_automation":' '        elif True:'
mut fila-prioridade-fixa chk_fila_ok 'k = str(it.get("priority", "?"))' 'k = "0"'
mut fila-prioridade-sem-padrao chk_fila_ok 'k = str(it.get("priority", "?"))' 'k = str(it.get("priority", 0))'
mut fila-itens-ilegiveis-calado chk_fila_ok '            ileg += 1' '            ileg += 0'
mut fila-total-so-wa chk_fila_ok '"total": len(o["items"])' '"total": wa'
mut fila-idade-negativa chk_fila_hora_ruim '        if idade is not None and idade < 0:' '        if False:'
mut fila-sem-hora-vira-zero chk_fila_hora_ruim "    idade = None${nl}    if isinstance(g, str) and TS_RE.match(g):" "    idade = 0${nl}    if isinstance(g, str) and TS_RE.match(g):"
mut fila-hora-impossivel-quebra chk_fila_hora_ruim "        except (ValueError, OverflowError):${nl}            idade = None" "        except OverflowError:${nl}            idade = None"
mut fila-vencida-invertida chk_fila_texto 'q["idade_s"] <= q["ttl_s"]' 'q["idade_s"] >= q["ttl_s"]'
mut fila-vencida-na-borda chk_fila_texto 'q["idade_s"] <= q["ttl_s"]' 'q["idade_s"] < q["ttl_s"]'
mut fila-ilegivel-vira-ausente chk_fila_estados "        return \"ausente\", None${nl}    except (OSError, ValueError):${nl}        return \"ilegivel\", None" "        return \"ausente\", None${nl}    except (OSError, ValueError):${nl}        return \"ausente\", None"
mut fila-ausente-vira-ilegivel chk_fila_estados "    except FileNotFoundError:${nl}        return \"ausente\", None${nl}    except (OSError, ValueError):" "    except FileNotFoundError:${nl}        return \"ilegivel\", None${nl}    except (OSError, ValueError):"
# -- caminhos e uso
mut caminho-vazio-vira-padrao chk_caminho_vazio_rc2 '        if v is not None and v == "":' '        if False:'
mut caminho-log-padrao-errado chk_caminhos_padrao 'os.path.join(city, ".gc", "logs", "pilot-dispatcher.log")' 'os.path.join(city, ".gc", "pilot-dispatcher.log")'
mut caminho-fila-padrao-errado chk_caminhos_padrao 'os.path.join(os.path.expanduser("~"), ".gc", "pilot-dispatchable.json")' 'os.path.join(os.path.expanduser("~"), ".gc", "pilot-dispatchable.jsonl")'
mut caminho-fila-padrao-na-cidade chk_caminhos_padrao 'os.path.join(os.path.expanduser("~"), ".gc", "pilot-dispatchable.json")' 'os.path.join(city, ".gc", "pilot-dispatchable.json")'
mut caminho-log-explicito-ignorado chk_funil_utc 'log_p = a.pilot_log if a.pilot_log is not None else os.path.join(city, ".gc", "logs", "pilot-dispatcher.log")' 'log_p = os.path.join(city, ".gc", "logs", "pilot-dispatcher.log")'
mut caminho-fila-explicito-ignorado chk_fila_ok 'fila_p = a.dispatchable if a.dispatchable is not None else os.path.join(os.path.expanduser("~"), ".gc", "pilot-dispatchable.json")' 'fila_p = os.path.join(os.path.expanduser("~"), ".gc", "pilot-dispatchable.json")'
mut json-sem-funil chk_json_uma_linha '        "funil": {"arquivo": log_p, "estado": fe, "analise": fa},' '        "funil_": {"arquivo": log_p, "estado": fe, "analise": fa},'
mut json-sem-fila chk_json_uma_linha '        "fila": {"arquivo": fila_p, "estado": qe, "analise": qa},' '        "fila_": {"arquivo": fila_p, "estado": qe, "analise": qa},'
mut funil-escreve-no-log chk_somente_leitura "        with open(path, \"rb\") as f:${nl}            raw = f.read().decode(\"utf-8\", \"replace\")" "        with open(path, \"ab+\") as f:${nl}            f.write(b\"x\\\\n\"); f.seek(0)${nl}            raw = f.read().decode(\"utf-8\", \"replace\")"

if [ -z "${WA_NODE_REPORT_ST_NOMUT:-}" ]; then
  [ "$MUTANTS" -ge "$MIN_MUT" ] || { echo "FAIL o piso: só $MUTANTS mutantes (mínimo $MIN_MUT) — apagar mutantes não passa por 'todos mortos'"; fails=$((fails+1)); n=$((n+1)); }
  echo "mutantes: $MUTANTS"
else
  echo "mutantes: pulados (WA_NODE_REPORT_ST_NOMUT=1)"
fi
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
