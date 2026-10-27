#!/usr/bin/env python3
"""hetzner-ballast-newfail.py — dá DONO ao que um item do lastro confirma: as regressões do wa-suite (ga-r4lw72, a fonte padrão) e os mutantes que sobrevivem ao hq-mutants (ga-2hd02v.5.6.4, `--fonte hq-mutants`). Roda no MINI (gc order, a cada 30 min). Python 3.9+, só biblioteca padrão.

Contents
  Para que serve · Fontes · O que lê · O que faz · Três estados · Estado local · Ambiente

PARA QUE SERVE
  O item wa-suite do lastro (no nó) compara cada rodada completa da suíte inteira do WA com a anterior, e o `new_fail` do resumo ninguém lia (24/10: 237 numa rodada, ruído até separar o tropeço da regressão).
  O item agora CONFIRMA: falha NOVA numa rodada completa que AINDA reprova na rodada completa seguinte. Esta ponta, no mini, transforma a lista dele em UMA bead no rig do WA, com a lista COMPLETA (o resumo corta em 15).
FONTES (`--fonte NOME`; sem o argumento é wa-suite; as duas não dividem estado, label nem bead)
  wa-suite    lê wa-suite.confirmed, bead no rig do WA (label origem:lastro-wa-suite), bug P2, estado newfail.json.
  hq-mutants  lê hq-mutants.state.json (o estado do motor hq-mutate.py: de cada alvo, `survivors` = os mutantes que NENHUM selftest da família pegou, confirmados por uma 2ª rodada numa cópia limpa), bead no rig do HQ
              (a cidade; label origem:lastro-hq-mutants), task P3, estado newfail-hq-mutants.json. A lista é a do ÚLTIMO rodízio: o id sai quando o motor varre o alvo de novo e o mutante morre (ou deixa de existir); alvo apagado ou ainda não varrido de novo mantém a linha (pode estar velha).
              Lista que ZERA não é 'pegos': alvo sem sobrevivente também é alvo que o motor NÃO reavaliou (base vermelha, scanner perdido, prazo, estado novo). O comentário diz quantos alvos não foram julgados por inteiro e quais.
O QUE LÊ (wa-suite)
  `ssh <nó> cat ~/gt-remote/ballast/wa-suite.confirmed`: {"v": 1, "main": <ponta da rodada>, "items": {<id do teste>: {"from": <ponta antes>, "to": <ponta onde apareceu>, "seen": <ponta que confirmou>}}}.
  É o estado ATUAL (o id fica até o teste passar), então olhar menos vezes que a rodada não perde nada.
O QUE FAZ
  Lista vazia e nenhuma bead nossa aberta → nada. Lista com impressão digital nova → abre a bead (bug, P2, labels origem:lastro-wa-suite e area:testes, SEM rota: quem triagem decide) ou, se a que abrimos
  segue aberta, a atualiza por comentário com a lista inteira. Bead que o dono fechou e uma lista DIFERENTE depois → abre outra (a MESMA lista com a bead fechada não reabre nada). Lista que zera → um comentário (não fecha: quem corrigiu fecha): wa-suite diz "corrigidas"; hq-mutants só diz o que o estado prova (alvos todos julgados por inteiro) ou, havendo alvo não reavaliado, que vazia NÃO prova que foram pegos. Mesma lista = nada.
  ANTES de abrir, sempre lista o rig (`bd list -l origem:lastro-wa-suite`): se já existe uma nossa não fechada (a criação anterior pode ter nascido sem eu saber), comenta nela em vez de abrir outra.
  Sem a bandeira do nó (.gc/hetzner-node.on) não faz nada, como as outras orders do nó.
TRÊS ESTADOS
  Toda leitura é leu / vazio / não consegui ler. Arquivo ausente no nó = "nada confirmado ainda" (rc 0). ssh que não conectou = rc 98. Arquivo que não é o JSON esperado, estado local ilegível ou bead que não consigo
  ler = rc 3 e NADA é aberto nem comentado: avisar de novo sobre uma bead que já existe duplicaria. Escrita do estado local que falha depois do `bd` ter respondido = rc 3 e a frase "NÃO gravei", nunca traceback: num comentário a próxima volta o repete (repetido é melhor que perdido); depois de um create ela lista o rig e comenta na bead que nasceu.
  `bd create` sem resposta certa (não executou, estourou o prazo, rc ≠ 0 ou respondeu sem o id) = a bead PODE ter nascido: rc 3, estado intacto, e a volta seguinte olha o rig antes de abrir. Rig que não consigo listar = rc 3 e nada feito ("não achei nenhuma nossa" e "não consegui listar" nunca são a mesma resposta).
ESTADO LOCAL
  <cidade>/.gc/hetzner-ballast/newfail.json (hq-mutants: newfail-hq-mutants.json): {"v": 1, "fp": <impressão digital da última lista avisada>, "bead": <id>, "n": <quantas>}.
AMBIENTE
  GC_CITY_PATH · HETZNER_NODE_HOST (padrão hetzner-teste) · HB_SSH (padrão ssh) · HB_BD (padrão bd) · HB_WA_RIG (padrão /Users/athos/gt/whatsapp_automation) · HB_HQ_RIG (padrão a cidade) · HB_BD_TIMEOUT (segundos do `bd create` e do `bd list`; padrão 90, valor que não é número > 0 = 90). Saída: 0 ok · 3 recusado ou não consegui · 98 ssh fora.
"""
import hashlib
import json
import math
import os
import subprocess
import sys
import tempfile
import time

SELF = os.path.dirname(os.path.abspath(__file__))
CITY = os.environ.get("GC_CITY_PATH") or os.path.dirname(SELF)
NODE = os.environ.get("HETZNER_NODE_HOST", "hetzner-teste")
SSH = os.environ.get("HB_SSH", "ssh")
BD = os.environ.get("HB_BD", "bd")
OUTDIR = os.path.join(CITY, ".gc", "hetzner-ballast")


def _bd_timeout():
    # vazio (variável ausente ou vazia) → 90 s; ilegível (não é número finito > 0) → 90 s também: o prazo é só um teto e o padrão é o que já valia
    try:
        v = float(os.environ.get("HB_BD_TIMEOUT") or 90)
    except ValueError:
        return 90.0
    return v if math.isfinite(v) and v > 0 else 90.0


BD_TIMEOUT = _bd_timeout()
REMOTE = ('B="$HOME/gt-remote/ballast"; F="$B/%s"; if cat "$F" 2> /dev/null; then exit 0; fi; '
          'if [ -d "$B" ] && [ -x "$B" ] && [ ! -e "$F" ]; then exit 10; fi; exit 11')


def say(msg):
    print("hetzner-ballast-newfail: %s" % msg)


def die(rc, msg):
    print("hetzner-ballast-newfail: %s" % msg, file=sys.stderr)
    sys.exit(rc)


def run(args, inp=None, timeout=90):
    # vazio (comando sem saída) → stdout ""; falhou (não executou OU estourou o prazo e foi morto) → None: quem chama recusa, nunca lê como "vazio". None NÃO prova que nada aconteceu: o comando morto pelo prazo pode ter gravado antes"
    try:
        return subprocess.run(args, input=inp, capture_output=True, text=True, errors="replace", timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None


def read_node():
    """('ok', itens, avaliação) | ('ausente', None, None) | ('ssh', None, None) | ('ilegivel', texto do motivo, None). avaliação = (quantos alvos o estado tem, [(alvo, por que não foi reavaliado)])."""
    r = run([SSH, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", NODE, REMOTE % F["arquivo"]], timeout=60)
    if r is None or r.returncode == 255:
        return "ssh", None, None
    if r.returncode == 10:
        return "ausente", None, None
    if r.returncode != 0:
        return "ilegivel", "o nó não leu %s (rc=%d)" % (F["arquivo"], r.returncode), None
    try:
        v = json.loads(r.stdout)
    except (ValueError, RecursionError):
        return "ilegivel", "%s não é JSON" % F["arquivo"], None
    items = F["items"](v)
    if items is None:
        return "ilegivel", "%s não tem a forma esperada (%s)" % (F["arquivo"], F["forma"]), None
    return "ok", items, F["avalia"](v)


def load_state():
    """(estado, motivo). Sem o arquivo = {} (nunca avisamos); ilegível = None."""
    # vazio (sem arquivo) → {}; falhou/ilegível (não abre, não é objeto JSON, campos de outro tipo) → None: recuso, avisar de novo sobre uma bead que já existe duplicaria
    if not os.path.exists(F["estado"]):
        return {}, ""
    try:
        with open(F["estado"], "r", encoding="utf-8") as f:
            v = json.load(f)
    except (OSError, ValueError, RecursionError) as e:
        return None, "%s ilegível (%s)" % (os.path.basename(F["estado"]), type(e).__name__)
    if not (isinstance(v, dict) and v.get("v") == 1 and (v.get("fp") is None or isinstance(v.get("fp"), str)) and (v.get("bead") is None or isinstance(v.get("bead"), str))
            and isinstance(v.get("n", 0), int)):
        return None, "%s com forma errada" % os.path.basename(F["estado"])
    return v, ""


def save_state(fp, bead, n):
    os.makedirs(OUTDIR, exist_ok=True)
    tmp = F["estado"] + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"v": 1, "fp": fp, "bead": bead, "n": n, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, f)
    os.replace(tmp, F["estado"])


def save_state_or_die(fp, bead, n, done, next_round):
    """Grava o estado local DEPOIS de o bd ter respondido. Falhou (disco, pasta no lugar do arquivo) → rc 3 dizendo o que já foi feito (`done`) e o que a próxima volta fará (`next_round`); o estado antigo fica."""
    try:
        save_state(fp, bead, n)
    except OSError as e:
        die(3, "%s, mas NÃO gravei o estado local (%s): %s" % (done, e, next_round))


def fingerprint(items):
    return hashlib.sha256(json.dumps(sorted([k, v.get("from"), v.get("to")] for k, v in items.items()), ensure_ascii=True).encode("utf-8")).hexdigest()[:16]


def short(sha):
    return sha[:9] if isinstance(sha, str) and sha else "?"


def items_wa(v):
    """wa-suite.confirmed → {id: {from, to, seen}} | None (forma errada: quem chama recusa)."""
    items = v.get("items") if isinstance(v, dict) and v.get("v") == 1 else None
    if not (isinstance(items, dict) and all(isinstance(k, str) and isinstance(x, dict) and all(x.get(f) is None or isinstance(x.get(f), str) for f in ("from", "to", "seen")) for k, x in items.items())):
        return None
    return items


def items_hq(v):
    """hq-mutants.state.json (o estado do hq-mutate.py) → {id: sobrevivente} de TODOS os alvos | None (forma errada: quem chama recusa). `survivors` ausente num alvo = sem sobrevivente (o motor também aceita assim)."""
    targets = v.get("targets") if isinstance(v, dict) and v.get("v") == 1 else None
    if not isinstance(targets, dict):
        return None
    items = {}
    for ent in targets.values():
        surv = ent.get("survivors", {}) if isinstance(ent, dict) else None
        if not isinstance(surv, dict):
            return None
        for sid, r in surv.items():
            if not (isinstance(sid, str) and isinstance(r, dict) and isinstance(r.get("file"), str) and type(r.get("line")) is int and all(isinstance(r.get(f, ""), str) for f in ("op", "old", "new"))
                    and isinstance(r.get("selftest", []), list) and all(isinstance(t, str) for t in r.get("selftest", []))):
                return None
            items[sid] = r
    return items


def avalia_wa(v):
    """O wa-suite.confirmed é a lista ATUAL de ids (não há alvo que fique sem ser reavaliado): nada a declarar."""
    return 0, []


def avalia_hq(v):
    """(quantos alvos o estado do motor tem, [(alvo, por que NÃO foi julgado por inteiro agora)]). `items_hq` já provou a forma de `targets`. Alvo sem sobrevivente na lista NÃO é alvo pego: o motor, quando o arquivo muda,
    zera a entrada e só volta a preenchê-la ao julgar (base vermelha, scanner perdido ou prazo deixam a entrada sem `survivors`); só o alvo com hash, sem `skip` e com todos os mutantes julgados está de fato reavaliado.
    Nenhum alvo no estado = o motor ainda não varreu nada (estado novo): também não vale como 'pegos'."""
    targets = v["targets"]
    out = [] if targets else [("estado", "sem nenhum alvo: o motor ainda não varreu nada")]
    for rel, ent in sorted(targets.items()):
        total, ver = ent.get("total"), ent.get("verdicts", {})
        if "skip" in ent:
            why = "pulado: %s" % str(ent["skip"])[:40]
        elif not ent.get("hash"):
            why = "sem hash"
        elif type(total) is not int or not isinstance(ver, dict):
            why = "sem total de mutantes"
        elif len(ver) < total:
            why = "restam %d de %d mutantes" % (total - len(ver), total)
        else:
            continue
        out.append((rel, why))
    return len(targets), out


def render_hq(items):
    """Texto da bead: a lista COMPLETA de mutantes sobreviventes, por arquivo e linha."""
    files = {}
    for sid, r in items.items():
        files.setdefault(r["file"], []).append((r["line"], sid, r))
    out = ["Mutantes SOBREVIVENTES confirmados pelo lastro do nó (item hq-mutants): %d troca(s) de UM trecho do código do hq que NENHUM selftest da família reprovou." % len(items), "",
           "Cada linha é uma quebra deliberada (antes → depois) que deixou os selftests do arquivo VERDES, e que repetida numa cópia limpa também passou: o teste não protege aquela linha. Para fechar, "
           "ponha no selftest um caso que reprove com a troca (o id é estável: sha1 de arquivo:linha:operador:antes>depois:ocorrência) ou, se a troca não muda o comportamento, diga qual é a equivalência. "
           "A lista é a do ÚLTIMO rodízio e a bead é atualizada quando ela muda. Um id sai quando o motor varre o arquivo de novo e o mutante morre (ou deixa de existir); arquivo apagado, renomeado ou ainda não varrido de novo "
           "MANTÉM a linha aqui, e ela pode estar velha: confira no arquivo atual antes de agir.", ""]
    for rel, rows in sorted(files.items()):
        out.append("ARQUIVO %s (%d)" % (rel, len(rows)))
        for line, sid, r in sorted(rows, key=lambda x: (x[0], x[1])):
            fam = ",".join(r.get("selftest", []))
            out.append("  L%d [%s] %s -> %s  id=%s%s" % (line, r.get("op", ""), r.get("old", "").replace("\n", "\\n"), r.get("new", "").replace("\n", "\\n"), sid, "  (testes: %s)" % fam if fam else ""))
        out.append("")
    out.append("Fonte: ~/gt-remote/ballast/hq-mutants.state.json no nó (hetzner-ballast-newfail.py --fonte hq-mutants, ga-2hd02v.5.6.4). Não é lead nem dado de cliente: só trechos do código do próprio hq.")
    return "\n".join(out)


def render_wa(items):
    """Texto da bead: a lista COMPLETA, agrupada pela faixa de pontas em que a falha apareceu."""
    groups = {}
    for k, v in items.items():
        groups.setdefault((v.get("from"), v.get("to")), []).append(k)
    out = ["Regressões CONFIRMADAS pelo lastro do nó (item wa-suite): %d teste(s) da suíte inteira do WA." % len(items), "",
           "Cada id reprovou numa rodada completa em que era NOVO (não reprovava na rodada completa anterior) e CONTINUOU reprovando na rodada completa seguinte: não é um tropeço de uma rodada só. "
           "O commit que quebrou está na faixa (de, até] de cada grupo; o `de` é a ponta da rodada que gerou a base ('?' = o nó não sabe). A lista é a ATUAL e a bead é atualizada quando ela muda; "
           "um id sai quando o teste passa.", ""]
    for (frm, to), ids in sorted(groups.items(), key=lambda g: (str(g[0][0]), str(g[0][1]))):
        out.append("FAIXA %s .. %s (%d)" % (short(frm), short(to), len(ids)))
        out.extend("  " + i for i in sorted(ids))
        out.append("")
    out.append("Fonte: ~/gt-remote/ballast/wa-suite.confirmed no nó (hetzner-ballast-newfail.py, ga-r4lw72). Não é lead nem dado de cliente: só ids de teste.")
    return "\n".join(out)


def bead_status(bead):
    """'open' | 'closed' | None (não consegui ler). Sem ler a bead NÃO se abre outra."""
    r = run([BD, "-C", F["rig"], "show", bead, "--json"], timeout=60)
    if r is None or r.returncode != 0:
        return None
    try:
        v = json.loads(r.stdout)
        v = v[0] if isinstance(v, list) and v else v
        st = v.get("status") if isinstance(v, dict) else None
    except (ValueError, RecursionError):
        return None
    return ("closed" if st == "closed" else "open") if isinstance(st, str) else None


def find_ours():
    """(ids, motivo): ids = as beads NOSSAS não fechadas do rig da fonte (label F["labels"][0]), em ordem; ids None = não consegui listar (motivo diz por quê)."""
    r = run([BD, "-C", F["rig"], "list", "-l", F["labels"][0], "--json", "--limit", "0"], timeout=BD_TIMEOUT)
    # vazio ([]) → ([], ""): nenhuma nossa aberta; falhou (não executou, prazo, rc ≠ 0, saída que não é uma lista de objetos com id e status) → (None, motivo): quem chama recusa, nunca lê como "nenhuma"
    if r is None or r.returncode != 0:
        return None, "não consegui listar o rig do %s (o bd não respondeu, estourou o prazo de %g s ou saiu com erro)" % (F["rig_nome"], BD_TIMEOUT)
    try:
        v = json.loads(r.stdout)
    except (ValueError, RecursionError):
        return None, "o bd list do rig do %s não devolveu JSON" % F["rig_nome"]
    forma = "o bd list do rig do %s devolveu uma forma que não conheço (esperava uma lista de beads com id e status)" % F["rig_nome"]
    if not isinstance(v, list):
        return None, forma
    ids = []
    for x in v:
        labels = x.get("labels") if isinstance(x, dict) else None   # o bd omite a chave quando não há label: ausente = não tem
        if not (isinstance(x, dict) and isinstance(x.get("id"), str) and x["id"] and isinstance(x.get("status"), str)
                and (labels is None or (isinstance(labels, list) and all(isinstance(lb, str) for lb in labels)))):
            return None, forma
        if F["labels"][0] in (labels or []) and x["status"] != "closed":
            ids.append(x["id"])
    return sorted(ids), ""


def create(items):
    args = [BD, "-C", F["rig"], "create", F["titulo"] % len(items), "-t", F["tipo"], "-p", F["prio"], "--stdin", "--json"]
    for lb in F["labels"]:
        args += ["-l", lb]
    r = run(args, inp=F["render"](items), timeout=BD_TIMEOUT)
    bead = None
    # vazio (resposta sem id) e falhou (não executou, prazo, rc ≠ 0, JSON ilegível) dão o MESMO bead None, de propósito: o `bd` pode ter gravado antes de falhar ou de ser morto, então nenhum dos quatro prova que
    # nada nasceu. A saída é a mesma nos quatro (rc 3, estado local intacto) e quem decide é a volta seguinte, que lista o rig antes de abrir
    if r is not None and r.returncode == 0:
        try:
            v = json.loads(r.stdout)
            v = v[0] if isinstance(v, list) and v else v
            bead = v.get("id") if isinstance(v, dict) else None
        except (ValueError, RecursionError):
            bead = None
    if not (isinstance(bead, str) and bead):
        if r is None:
            why = "o bd não respondeu (não executou ou estourou o prazo de %g s)" % BD_TIMEOUT
        elif r.returncode != 0:
            why = "o bd saiu com rc=%d" % r.returncode
        else:
            why = "o bd respondeu sem o id da bead"
        die(3, "bd create: %s. Não sei se a bead nasceu no rig do %s; o estado local não mudou e a próxima volta lista o rig (label %s) e comenta na nossa que achar, em vez de abrir outra" % (why, F["rig_nome"], F["labels"][0]))
    return bead


def zerou_hq(n, nao):
    """Comentário de lista que zerou. Vazia NÃO é 'pegos': só digo o que o estado prova, e o que ele não prova vai escrito (alvo não reavaliado, estado sem alvo, arquivo que saiu do estado)."""
    if nao:
        quais = "; ".join("%s (%s)" % x for x in nao[:10]) + ("; +%d" % (len(nao) - 10) if len(nao) > 10 else "")
        return ("A lista de mutantes sobreviventes (item hq-mutants) está vazia, mas isso NÃO prova que os testes foram reforçados. Estado do motor: %d alvo(s); NÃO julgados por inteiro agora: %d [%s]. "
                "Alvo que o motor ainda não reavaliou não tem sobrevivente na lista, nem por isso foi pego. Confira ~/gt-remote/ballast/hq-mutants.state.json no nó antes de fechar esta bead." % (n, len(nao), quais))
    return ("A lista de mutantes sobreviventes (item hq-mutants) está vazia: os %d alvo(s) do estado do motor estão com todos os mutantes julgados e nenhum sobrevive. Quem reforçou o teste fecha esta bead. "
            "(Arquivo que saiu do estado do motor também não aparece: confira ~/gt-remote/ballast/hq-mutants.state.json no nó.)" % n)


FONTES = {
    "wa-suite": dict(arquivo="wa-suite.confirmed", estado="newfail.json", rig=os.environ.get("HB_WA_RIG", "/Users/athos/gt/whatsapp_automation"), rig_nome="WA", labels=("origem:lastro-wa-suite", "area:testes"),
                     tipo="bug", prio="2", titulo="wa-suite do lastro: %d regressão(ões) confirmada(s) no main", items=items_wa, forma="v 1, items {id: {from, to, seen}}", render=render_wa, coisas="regressões", gen="as",
                     avalia=avalia_wa, zerou=lambda n, nao: "As regressões confirmadas pelo lastro do nó (item wa-suite) foram corrigidas: a lista atual está vazia. Quem corrigiu fecha esta bead."),
    "hq-mutants": dict(arquivo="hq-mutants.state.json", estado="newfail-hq-mutants.json", rig=os.environ.get("HB_HQ_RIG") or CITY, rig_nome="HQ", labels=("origem:lastro-hq-mutants", "area:testes"),
                       tipo="task", prio="3", titulo="hq-mutants do lastro: %d mutante(s) sobrevivente(s) confirmado(s) no main", items=items_hq, forma="v 1, targets {arquivo: {survivors: {id: {file, line, op, old, new}}}}", render=render_hq,
                       coisas="mutantes sobreviventes", gen="os",
                       avalia=avalia_hq, zerou=zerou_hq),
}


def pick_source(argv):
    """`--fonte NOME` ou nada (= wa-suite, o que a order antiga já chama). Qualquer outra coisa = rc 2: uma fonte que não conheço nunca cai na padrão."""
    if not argv:
        return "wa-suite"
    if len(argv) == 2 and argv[0] == "--fonte" and argv[1] in FONTES:
        return argv[1]
    die(2, "uso: hetzner-ballast-newfail.py [--fonte %s]" % "|".join(sorted(FONTES)))


F = dict(FONTES[pick_source(sys.argv[1:])])
F["estado"] = os.path.join(OUTDIR, F["estado"])


def main():
    if not os.path.exists(os.path.join(CITY, ".gc", "hetzner-node.on")):
        say("PULADO: o nó está desligado (falta %s/.gc/hetzner-node.on)" % CITY)
        return 0
    st, items_or_why, aval = read_node()
    if st == "ssh":
        die(98, "ssh não conectou (%s): nada foi feito" % NODE)
    if st == "ilegivel":
        die(3, "%s: nada foi feito (isto NÃO quer dizer que não haja %s)" % (items_or_why, F["coisas"]))
    if st == "ausente":
        say("o nó ainda não tem %s: nada confirmado" % F["arquivo"])
        return 0
    items = items_or_why
    state, why = load_state()
    if state is None:
        die(3, "%s: não abro nem comento bead sem saber o que já avisei" % why)
    bead, last_fp, last_n = state.get("bead"), state.get("fp"), state.get("n", 0)
    fp = fingerprint(items)
    if not items:
        if bead and last_n:
            r = run([BD, "-C", F["rig"], "comment", bead, "--stdin"], inp=F["zerou"](*aval), timeout=60)
            if r is None or r.returncode != 0:
                die(3, "bd comment falhou em %s: o estado local não mudou; a próxima volta repete" % bead)
            save_state_or_die(fp, bead, 0, "comentei em %s que a lista zerou" % bead, "a próxima volta repete o comentário")
            say("lista vazia: comentei em %s que a lista zerou (%d alvo(s) não reavaliado(s))" % (bead, len(aval[1])))
        else:
            say("0 %s confirmad%s" % (F["coisas"], F["gen"]))
        return 0
    if bead and fp == last_fp:
        say("%d confirmada(s), a mesma lista já avisada em %s: nada a fazer" % (len(items), bead))
        return 0
    action = "criar"
    if bead:
        status = bead_status(bead)
        if status is None:
            die(3, "não consegui ler a bead %s no rig do %s: não abro outra nem comento (a próxima volta repete)" % (bead, F["rig_nome"]))
        action = "comentar" if status == "open" else "criar"
    lead = "A lista de %s confirmad%s MUDOU (agora %d)." % (F["coisas"], F["gen"], len(items))
    if action == "criar":
        # nunca abro sem olhar o rig: uma criação anterior pode ter nascido sem eu saber (prazo, rc ≠ 0, resposta sem id, estado local que não gravou)
        ours, why = find_ours()
        if ours is None:
            die(3, "%s: não abro nem comento (a próxima volta repete)" % why)
        if ours:
            bead, action = ours[0], "comentar"
            lead = "Esta bead foi reencontrada no rig do %s (uma volta anterior não confirmou se a criou). Lista atual de %s confirmad%s (%d)." % (F["rig_nome"], F["coisas"], F["gen"], len(items))
            say("já existe uma bead nossa aberta no rig do %s (%s): comento em %s em vez de abrir outra" % (F["rig_nome"], ", ".join(ours), bead))
    if action == "comentar":
        r = run([BD, "-C", F["rig"], "comment", bead, "--stdin"], inp="%s\n\n%s" % (lead, F["render"](items)), timeout=90)
        if r is None or r.returncode != 0:
            die(3, "bd comment falhou em %s: o estado local não mudou; a próxima volta repete" % bead)
        save_state_or_die(fp, bead, len(items), "comentei a lista nova em %s" % bead, "a próxima volta repete o comentário")
        say("%d confirmada(s): comentei a lista nova em %s" % (len(items), bead))
        return 0
    new = create(items)
    save_state_or_die(fp, new, len(items), "abri %s" % new, "a próxima volta lista o rig e comenta nela em vez de abrir outra")
    say("%d confirmada(s): abri %s no rig do %s" % (len(items), new, F["rig_nome"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
