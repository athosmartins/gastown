#!/usr/bin/env python3
"""pilot-dispatcher.alias-twin.mutants.py — controle negativo dos cenários AT-* do pilot-dispatcher.session-liveness.selftest.sh (ga-d63o9n1).

Contents
  O que faz · Como roda · Saída

O QUE FAZ: cada mutante troca UM trecho numa CÓPIA (o original nunca é tocado) — da bead_state.py (a regra do gêmeo de alias e a entrada por roster) ou do pilot-dispatcher.sh (a ponte e os
  3 pontos de uso) — e roda o pilot-dispatcher.session-liveness.selftest.sh contra a cópia. Só MORRE se os cenários que prendem aquela guarda reprovarem: reprovar por OUTRO motivo (a cópia nem
  roda, sintaxe quebrada) NÃO mata, e um mutante que gera sintaxe inválida é erro do mutante (FATAL), não "morto". Antes dos mutantes roda um CONTROLE: a cópia sem mutação tem de passar,
  senão "todos mortos" seria o harness quebrado reprovando tudo. O trecho trocado tem de aparecer EXATAMENTE uma vez no alvo (senão o executor para: o alvo mudou e o mutante ficou velho).
COMO RODA: python3 -I pilot-dispatcher.alias-twin.mutants.py   (13 mutantes + 1 controle, 3 cópias por vez, cada filho com teto de 120 s)
  ALIAS_TWIN_MUTANTS_DISPATCHER=<arquivo> / ALIAS_TWIN_MUTANTS_LIB=<arquivo>   apontam para outro pilot-dispatcher.sh / outra bead_state.py (o selftest usa isto para provar o FATAL)
SAÍDA: uma linha por mutante (morto / SOBREVIVEU) e `MUTANTES: <mortos>/<total> mortos`; exit 0 só com todos mortos; exit 2 (FATAL) para alvo ausente, mutante velho/inválido ou controle vermelho.
"""
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DISPATCHER = os.environ.get("ALIAS_TWIN_MUTANTS_DISPATCHER") or os.path.join(HERE, "pilot-dispatcher.sh")
LIB = os.environ.get("ALIAS_TWIN_MUTANTS_LIB") or os.path.join(HERE, "..", "..", "..", "scripts", "bead_state.py")
SELFTEST = os.path.join(HERE, "pilot-dispatcher.session-liveness.selftest.sh")
WORKERS = 3
CHILD_TIMEOUT_SECS = 120

_TWIN = "                and alias_claim_predates_session(assignee, s, bead_update_age, now)):\n"
_BRIDGE_CALL = '"$_slb_asg" "$_slb_upd" "$(date +%s)"'
_WARN = '        warn "[pilot] bridge is_live_builder() quebrado p/ assignee=$_slb_asg (python3 rc=$_slb_rc, saída=\'${_slb_out}\') — usando checagem bash de fallback" >&2\n'

# (nome, alvo "lib"|"pilot", trecho antigo, trecho novo, cenários que TÊM de reprovar: fragmentos do que vem depois de "FAIL ")
MUTANTS = [
    ("regra-desligada", "lib", _TWIN, "                and False):\n", [r"AT-1\b", r"AT-9\b"]),
    ("regra-vale-sempre", "lib", _TWIN, "                and True):\n", [r"AT-2\b", r"AT-5a\b", r"AT-7a\b"]),
    ("sem-pertencimento-exato", "lib", " and assignee in _session_identifiers(s)\n", "\n", [r"AT-8\b"]),
    ("idade-da-bead-ignorada", "lib", "bead_update_age = None if updated is None else now - updated\n", "bead_update_age = None\n", [r"AT-1\b", r"AT-9\b"]),
    ("gemeos-nao-reportados", "lib", '            twins.append(s.get("session_name") or s.get("name") or s.get("id") or "?")\n', "            pass\n", [r"AT-1b\b"]),
    ("meta-ignora-sessao-fechada", "lib", '        if not isinstance(s, dict) or s.get("closed") is True:\n            continue\n', "        if not isinstance(s, dict):\n            continue\n", [r"closed crew"]),
    ("meta-ignora-asleep", "lib", '        if s.get("state") == "asleep":\n            asleep |= ids\n', '        if False:\n            asleep |= ids\n', [r"ASLEEP adhoc ps-worker"]),
    ("ponte-nao-passa-o-updated_at", "pilot", _BRIDGE_CALL, '"$_slb_asg" "" "$(date +%s)"', [r"AT-1\b", r"AT-9\b"]),
    ("descarte-vai-ao-stdout", "pilot", "(ga-d63o9n1)\" >&2 || true\n", "(ga-d63o9n1)\" || true\n", [r"AT-11\b", r"AT-1b\b"]),
    ("ponte-quebrada-sem-aviso", "pilot", _WARN, "        :\n", [r"AT-13b\b"]),
    ("ponto1-sem-o-updated_at", "pilot", '_session_is_live_builder "$_phe_live_assignee" "$_phe_live_updated_at"', '_session_is_live_builder "$_phe_live_assignee"', [r"AT-14\b"]),
    ("ponto2-sem-o-updated_at", "pilot", '_session_is_live_builder "$_asg" "$_ddw_upd"', '_session_is_live_builder "$_asg"', [r"AT-14\b"]),
    ("ponto3-sem-o-updated_at", "pilot", '_session_is_live_builder "$_asg" "$_sling_upd"', '_session_is_live_builder "$_asg"', [r"AT-14\b"]),
]


def fatal(msg):
    print("FATAL: " + msg)
    sys.exit(2)


def syntax_error(alvo, text):
    """Motivo (str) se o texto mutado não é sintaxe válida do alvo, senão None."""
    if alvo == "lib":
        try:
            compile(text, "bead_state.py", "exec")
        except SyntaxError as e:
            return "python: %s" % e
        return None
    r = subprocess.run(["bash", "-n"], input=text, capture_output=True, text=True)
    return None if r.returncode == 0 else "bash -n: " + r.stderr.strip()[:120]


def run_selftest(dispatcher_text, lib_text, label):
    """Roda o selftest de liveness contra uma cópia; devolve (rc, saída). Falhou em rodar/estourou prazo → (None, motivo): nunca vira 'passou'."""
    park = os.path.join(os.path.dirname(os.path.abspath(LIB)), "park_labels.py")
    if not os.path.isfile(park):
        return None, "irmão ausente ao lado da bead_state.py: park_labels.py"
    tmp = tempfile.mkdtemp(prefix="pd-twin-mut-")
    try:
        assets = os.path.join(tmp, ".gascity-gastown-hq", "packs", "town-deltas", "assets")
        scripts = os.path.join(tmp, ".gascity-gastown-hq", "scripts")
        os.makedirs(assets)
        os.makedirs(scripts)
        for path, text in ((os.path.join(assets, "pilot-dispatcher.sh"), dispatcher_text), (os.path.join(scripts, "bead_state.py"), lib_text)):
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        shutil.copy(park, scripts)
        shutil.copy(SELFTEST, assets)
        try:
            r = subprocess.run(["bash", os.path.join(assets, os.path.basename(SELFTEST))], cwd=tmp, capture_output=True, text=True, errors="replace", timeout=CHILD_TIMEOUT_SECS)
        except subprocess.TimeoutExpired:
            return None, "estourou %ds (%s)" % (CHILD_TIMEOUT_SECS, label)
        except Exception as e:   # noqa: BLE001 — não conseguir rodar não é "mutante morto"
            return None, "não rodou (%s): %r" % (label, e)
        return r.returncode, r.stdout + r.stderr
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def judge(rc, out, expect):
    """True sse o mutante morreu PELO MOTIVO esperado: o selftest reprovou E cada cenário esperado aparece como FAIL."""
    if rc is None or rc == 0:
        return False
    return all(re.search(r"FAIL " + frag, out) for frag in expect)


def main():
    texts = {}
    for alvo, path in (("pilot", DISPATCHER), ("lib", LIB)):
        if not os.path.isfile(path):
            fatal("%s ausente: %s" % (alvo, path))
        with open(path, encoding="utf-8") as f:
            texts[alvo] = f.read()
    if not os.path.isfile(SELFTEST):
        fatal("selftest de liveness ausente: %s" % SELFTEST)
    for name, alvo, old, new, _expect in MUTANTS:
        n = texts[alvo].count(old)
        if n != 1:
            fatal("mutante '%s' velho: o trecho aparece %d vez(es) no %s, tem de ser exatamente 1" % (name, n, alvo))
        if old == new:
            fatal("mutante '%s' não muda nada" % name)
        bad = syntax_error(alvo, texts[alvo].replace(old, new, 1))
        if bad:
            fatal("mutante '%s' gera sintaxe inválida (%s): erro do mutante, não 'morto'" % (name, bad))

    rc0, out0 = run_selftest(texts["pilot"], texts["lib"], "controle")
    ok_at = len(re.findall(r"^  ok   AT-", out0 or "", re.M))
    if rc0 != 0 or ok_at < 19 or re.search(r"^  FAIL ", out0 or "", re.M):
        fatal("controle vermelho (cópia SEM mutação: rc=%r, cenários AT ok=%d): %s" % (rc0, ok_at, (out0 or "")[-300:].replace("\n", " | ")))
    print("controle: a cópia sem mutação passa (%d cenários AT-*)" % ok_at)

    def one(m):
        name, alvo, old, new, expect = m
        mutated = dict(texts, **{alvo: texts[alvo].replace(old, new, 1)})
        rc, out = run_selftest(mutated["pilot"], mutated["lib"], name)
        return name, expect, judge(rc, out, expect), rc, out

    killed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for name, expect, dead, rc, out in pool.map(one, MUTANTS):
            if dead:
                killed += 1
                print("  morto      %s  (reprovou: %s)" % (name, ", ".join(e.replace("\\b", "") for e in expect)))
            else:
                fails = [l.strip()[5:30] for l in (out or "").splitlines() if l.startswith("  FAIL ")]
                print("  SOBREVIVEU %s  (esperava reprovar %s; rc=%r; reprovou: %s)" % (name, expect, rc, fails or (out or "")[-160:].replace("\n", " | ")))
    print("MUTANTES: %d/%d mortos" % (killed, len(MUTANTS)))
    sys.exit(0 if killed == len(MUTANTS) else 1)


if __name__ == "__main__":
    main()
