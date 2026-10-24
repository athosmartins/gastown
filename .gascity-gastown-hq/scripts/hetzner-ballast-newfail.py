#!/usr/bin/env python3
"""hetzner-ballast-newfail.py — dá DONO às regressões que o wa-suite do lastro confirma (ga-r4lw72). Roda no MINI (gc order, a cada 30 min). Python 3.9+, só biblioteca padrão.

Contents
  Para que serve · O que lê · O que faz · Três estados · Estado local · Ambiente

PARA QUE SERVE
  O item wa-suite do lastro (no nó) compara cada rodada completa da suíte inteira do WA com a anterior, e o `new_fail` do resumo ninguém lia (24/10: 237 numa rodada, ruído até separar o tropeço da regressão).
  O item agora CONFIRMA: falha NOVA numa rodada completa que AINDA reprova na rodada completa seguinte. Esta ponta, no mini, transforma a lista dele em UMA bead no rig do WA, com a lista COMPLETA (o resumo corta em 15).
O QUE LÊ
  `ssh <nó> cat ~/gt-remote/ballast/wa-suite.confirmed`: {"v": 1, "main": <ponta da rodada>, "items": {<id do teste>: {"from": <ponta antes>, "to": <ponta onde apareceu>, "seen": <ponta que confirmou>}}}.
  É o estado ATUAL (o id fica até o teste passar), então olhar menos vezes que a rodada não perde nada.
O QUE FAZ
  Lista vazia e nenhuma bead nossa aberta → nada. Lista com impressão digital nova → abre a bead (bug, P2, labels origem:lastro-wa-suite e area:testes, SEM rota: quem triagem decide) ou, se a que abrimos
  segue aberta, a atualiza por comentário com a lista inteira. Bead que o dono fechou e uma lista DIFERENTE depois → abre outra (a MESMA lista com a bead fechada não reabre nada). Lista que zera → um comentário "corrigidas" (não fecha: quem corrigiu fecha). Mesma lista = nada.
  Sem a bandeira do nó (.gc/hetzner-node.on) não faz nada, como as outras orders do nó.
TRÊS ESTADOS
  Toda leitura é leu / vazio / não consegui ler. Arquivo ausente no nó = "nada confirmado ainda" (rc 0). ssh que não conectou = rc 98. Arquivo que não é o JSON esperado, estado local ilegível ou bead que não consigo
  ler = rc 3 e NADA é aberto nem comentado: avisar de novo sobre uma bead que já existe duplicaria. Escrita do estado local que falha depois do `bd` ter respondido = rc 3 e a frase "NÃO gravei", nunca traceback: num comentário a próxima volta o repete (repetido é melhor que perdido); depois de um create ela abriria OUTRA bead, e por isso a frase manda conferir.
ESTADO LOCAL
  <cidade>/.gc/hetzner-ballast/newfail.json: {"v": 1, "fp": <impressão digital da última lista avisada>, "bead": <id>, "n": <quantas>}.
AMBIENTE
  GC_CITY_PATH · HETZNER_NODE_HOST (padrão hetzner-teste) · HB_SSH (padrão ssh) · HB_BD (padrão bd) · HB_WA_RIG (padrão /Users/athos/gt/whatsapp_automation). Saída: 0 ok · 3 recusado ou não consegui · 98 ssh fora.
"""
import hashlib
import json
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
WA_RIG = os.environ.get("HB_WA_RIG", "/Users/athos/gt/whatsapp_automation")
OUTDIR = os.path.join(CITY, ".gc", "hetzner-ballast")
STATE = os.path.join(OUTDIR, "newfail.json")
LABELS = ("origem:lastro-wa-suite", "area:testes")
REMOTE = ('B="$HOME/gt-remote/ballast"; F="$B/wa-suite.confirmed"; if cat "$F" 2> /dev/null; then exit 0; fi; '
          'if [ -d "$B" ] && [ -x "$B" ] && [ ! -e "$F" ]; then exit 10; fi; exit 11')


def say(msg):
    print("hetzner-ballast-newfail: %s" % msg)


def die(rc, msg):
    print("hetzner-ballast-newfail: %s" % msg, file=sys.stderr)
    sys.exit(rc)


def run(args, inp=None, timeout=90):
    # vazio (comando sem saída) → stdout ""; falhou (não executou, estourou o prazo) → None: quem chama recusa, nunca lê como "vazio"
    try:
        return subprocess.run(args, input=inp, capture_output=True, text=True, errors="replace", timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None


def read_node():
    """('ok', itens) | ('ausente', None) | ('ssh', None) | ('ilegivel', texto do motivo)."""
    r = run([SSH, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", NODE, REMOTE], timeout=60)
    if r is None or r.returncode == 255:
        return "ssh", None
    if r.returncode == 10:
        return "ausente", None
    if r.returncode != 0:
        return "ilegivel", "o nó não leu wa-suite.confirmed (rc=%d)" % r.returncode
    try:
        v = json.loads(r.stdout)
    except (ValueError, RecursionError):
        return "ilegivel", "wa-suite.confirmed não é JSON"
    items = v.get("items") if isinstance(v, dict) and v.get("v") == 1 else None
    if not (isinstance(items, dict) and all(isinstance(k, str) and isinstance(x, dict) and all(x.get(f) is None or isinstance(x.get(f), str) for f in ("from", "to", "seen")) for k, x in items.items())):
        return "ilegivel", "wa-suite.confirmed não tem a forma esperada (v 1, items {id: {from, to, seen}})"
    return "ok", items


def load_state():
    """(estado, motivo). Sem o arquivo = {} (nunca avisamos); ilegível = None."""
    # vazio (sem arquivo) → {}; falhou/ilegível (não abre, não é objeto JSON, campos de outro tipo) → None: recuso, avisar de novo sobre uma bead que já existe duplicaria
    if not os.path.exists(STATE):
        return {}, ""
    try:
        with open(STATE, "r", encoding="utf-8") as f:
            v = json.load(f)
    except (OSError, ValueError, RecursionError) as e:
        return None, "newfail.json ilegível (%s)" % type(e).__name__
    if not (isinstance(v, dict) and v.get("v") == 1 and (v.get("fp") is None or isinstance(v.get("fp"), str)) and (v.get("bead") is None or isinstance(v.get("bead"), str))
            and isinstance(v.get("n", 0), int)):
        return None, "newfail.json com forma errada"
    return v, ""


def save_state(fp, bead, n):
    os.makedirs(OUTDIR, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"v": 1, "fp": fp, "bead": bead, "n": n, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, f)
    os.replace(tmp, STATE)


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


def render(items):
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
    r = run([BD, "-C", WA_RIG, "show", bead, "--json"], timeout=60)
    if r is None or r.returncode != 0:
        return None
    try:
        v = json.loads(r.stdout)
        v = v[0] if isinstance(v, list) and v else v
        st = v.get("status") if isinstance(v, dict) else None
    except (ValueError, RecursionError):
        return None
    return ("closed" if st == "closed" else "open") if isinstance(st, str) else None


def create(items, fp):
    title = "wa-suite do lastro: %d regressão(ões) confirmada(s) no main" % len(items)
    args = [BD, "-C", WA_RIG, "create", title, "-t", "bug", "-p", "2", "--stdin", "--json"]
    for lb in LABELS:
        args += ["-l", lb]
    r = run(args, inp=render(items), timeout=90)
    if r is None or r.returncode != 0:
        die(3, "bd create falhou (rc=%s): nada foi registrado; a próxima volta repete" % (r.returncode if r else "sem resposta"))
    try:
        v = json.loads(r.stdout)
        v = v[0] if isinstance(v, list) and v else v
        bead = v.get("id") if isinstance(v, dict) else None
    except (ValueError, RecursionError):
        bead = None
    if not (isinstance(bead, str) and bead):
        # a bead pode ter sido criada: guardo a impressão digital com bead '?' para a próxima volta NÃO abrir outra, e digo
        save_state_or_die(fp, "?", len(items), "bd create respondeu sem o id da bead (ela pode ter sido criada no rig do WA)",
                          "sem a marca '?' a próxima volta pode abrir outra: confira o rig do WA e grave %s à mão" % STATE)
        die(3, "bd create respondeu sem o id da bead: ela pode ter sido criada no rig do WA (confira); não abro outra")
    return bead


def main():
    if not os.path.exists(os.path.join(CITY, ".gc", "hetzner-node.on")):
        say("PULADO: o nó está desligado (falta %s/.gc/hetzner-node.on)" % CITY)
        return 0
    st, items_or_why = read_node()
    if st == "ssh":
        die(98, "ssh não conectou (%s): nada foi feito" % NODE)
    if st == "ilegivel":
        die(3, "%s: nada foi feito (isto NÃO quer dizer que não haja regressões)" % items_or_why)
    if st == "ausente":
        say("o nó ainda não tem wa-suite.confirmed: nada confirmado")
        return 0
    items = items_or_why
    state, why = load_state()
    if state is None:
        die(3, "%s: não abro nem comento bead sem saber o que já avisei" % why)
    bead, last_fp, last_n = state.get("bead"), state.get("fp"), state.get("n", 0)
    fp = fingerprint(items)
    if not items:
        if bead and bead != "?" and last_n:
            r = run([BD, "-C", WA_RIG, "comment", bead, "--stdin"], inp="As regressões confirmadas pelo lastro do nó (item wa-suite) foram corrigidas: a lista atual está vazia. "
                    "Quem corrigiu fecha esta bead.", timeout=60)
            if r is None or r.returncode != 0:
                die(3, "bd comment falhou em %s: o estado local não mudou; a próxima volta repete" % bead)
            save_state_or_die(fp, bead, 0, "comentei em %s que foram corrigidas" % bead, "a próxima volta repete o comentário")
            say("lista vazia: comentei em %s que foram corrigidas" % bead)
        else:
            say("0 regressões confirmadas")
        return 0
    if bead == "?":   # a criação anterior não devolveu o id: a bead pode existir. Fica ruidoso (rc 3) a cada volta até um humano acertar o estado; abrir outra duplicaria
        die(3, "uma bead desta lista pode já existir no rig do WA (o id não voltou na criação): confira e apague/ajuste %s; não abro outra" % STATE)
    if bead and fp == last_fp:
        say("%d confirmada(s), a mesma lista já avisada em %s: nada a fazer" % (len(items), bead))
        return 0
    action = "criar"
    if bead:
        status = bead_status(bead)
        if status is None:
            die(3, "não consegui ler a bead %s no rig do WA: não abro outra nem comento (a próxima volta repete)" % bead)
        action = "comentar" if status == "open" else "criar"
    if action == "comentar":
        r = run([BD, "-C", WA_RIG, "comment", bead, "--stdin"], inp="A lista de regressões confirmadas MUDOU (agora %d).\n\n%s" % (len(items), render(items)), timeout=90)
        if r is None or r.returncode != 0:
            die(3, "bd comment falhou em %s: o estado local não mudou; a próxima volta repete" % bead)
        save_state_or_die(fp, bead, len(items), "comentei a lista nova em %s" % bead, "a próxima volta repete o comentário")
        say("%d confirmada(s): comentei a lista nova em %s" % (len(items), bead))
        return 0
    new = create(items, fp)
    save_state_or_die(fp, new, len(items), "abri %s" % new, "a próxima volta abriria outra; apague a bead ou grave %s à mão" % STATE)
    say("%d confirmada(s): abri %s no rig do WA" % (len(items), new))
    return 0


if __name__ == "__main__":
    sys.exit(main())
