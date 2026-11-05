#!/usr/bin/env python3
"""inflight-reclaim-guard.alias-reuse.mutants.py — controle negativo dos checks LS-* do inflight-reclaim-guard (ga-lotseol).

Contents
  O que faz · Como roda · Saída

O QUE FAZ: cada mutante troca UM trecho numa CÓPIA (o original nunca é tocado) — do guard, ou da lib bead_state.py, onde mora o corpo da regra desde o ga-d63o9n1 — e roda o `--selftest` do guard contra a cópia. O mutante só conta como MORTO se os checks LS-*
  que prendem aquela guarda reprovarem (ou, nos dois mutantes que tiram uma checagem de "não consegui ler", se o selftest quebrar com Traceback: sem a checagem a comparação com None estoura).
  Reprovar por OUTRO motivo (cópia que nem abre, SyntaxError) NÃO mata: sem isto, um mutante quebrado contaria como pego. Antes dos mutantes roda um CONTROLE: a cópia sem mutação tem de passar,
  senão "todos mortos" seria o harness quebrado reprovando tudo. O trecho trocado tem de aparecer EXATAMENTE uma vez no arquivo-alvo (senão o executor para: o alvo mudou e o mutante ficou velho).
COMO RODA: python3 -I scripts/inflight-reclaim-guard.alias-reuse.mutants.py   (14 mutantes + 1 controle, 3 cópias por vez; cada filho com teto de 512 MB por arquivo e 120 s; ~35 s no nó Linux)
  ALIAS_MUTANTS_GUARD=<arquivo>   aponta para outro guard (o selftest usa isto para provar o FATAL de guard ausente)
  ALIAS_MUTANTS_LIB=<arquivo>     aponta para outra bead_state.py (idem, para o FATAL de lib ausente ou de trecho velho nela)
  Cada filho roda com GC_SELFTEST=1 e GC_LEDGER_DIR num diretório descartável: nenhuma linha vai para os ledgers de produção.
SAÍDA: uma linha por mutante (morto / SOBREVIVEU) e `MUTANTES: <mortos>/<total> mortos`; exit 0 só com todos mortos; exit 2 (FATAL) para guard ou lib ausente, mutante velho ou controle vermelho.
"""
import concurrent.futures
import os
import resource
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.environ.get("ALIAS_MUTANTS_GUARD") or os.path.join(HERE, "inflight-reclaim-guard.py")
LIB = os.environ.get("ALIAS_MUTANTS_LIB") or os.path.join(os.path.dirname(GUARD), "bead_state.py")   # o corpo da regra (ga-d63o9n1); alvo de mutante, não só irmão
SIBLINGS = ("gc_ledger.py", "park_labels.py")   # o guard importa gc_ledger no nível do módulo; o bead_state importa o park_labels (sem mais imports)
WORKERS = 3
CHILD_TIMEOUT_SECS = 120
CHILD_FSIZE_BYTES = 512 * 1024 * 1024

_RULE = "    return bead_update_age > session_age + ALIAS_CLAIM_BIRTH_MARGIN_SECS\n"
_CALL = "            if alias_claim_predates_session(assignee, s, bead_update_age, now):\n                continue\n"

# (nome, alvo "lib"|"guard", trecho antigo, trecho novo, checks LS-* que TÊM de reprovar | ["Traceback"] quando a checagem tirada protege contra uma exceção)
MUTANTS = [
    ("margem-zero", "lib", _RULE, "    return bead_update_age > session_age\n", ["LS-3a", "LS-3b"]),
    ("borda-inclusiva", "lib", _RULE, "    return bead_update_age >= session_age + ALIAS_CLAIM_BIRTH_MARGIN_SECS\n", ["LS-3b"]),
    ("regra-nunca-vale", "lib", _RULE, "    return False\n", ["LS-1", "LS-3c"]),
    ("regra-vale-sempre", "lib", _RULE, "    return True\n", ["LS-2", "LS-3a", "LS-7a"]),
    ("sem-escopo-de-pool", "lib",
     '    if not template or not name.startswith(template + "-"):\n        return False\n',
     "    if False:\n        return False\n", ["LS-5", "LS-6e"]),
    ("escopo-sem-hifen", "lib",
     '    if not template or not name.startswith(template + "-"):\n',
     '    if not template or not name.startswith(template):\n', ["LS-5"]),
    ("sem-guarda-de-futuro", "lib", "    if session_age < 0:\n        return False\n", "    if False:\n        return False\n", ["LS-6d"]),
    ("sem-isencao-por-id-e-session-name", "lib",
     '    if assignee in (session.get("id", ""), session.get("session_name", "")):\n        return False\n',
     "    if False:\n        return False\n", ["LS-4a", "LS-4b"]),
    # só o LS-7a prende o `continue`: no LS-7b a incarnação velha vem PRIMEIRO, devolve True antes de a linha mutada ser alcançada (o 7b prova a simetria de ordem, e passa com os dois códigos)
    ("return-no-lugar-de-continue", "guard", _CALL, _CALL.replace("continue", "return False"), ["LS-7a"]),
    ("regra-desligada-no-session-is-live", "guard", _CALL, _CALL.replace("alias_claim_predates_session(assignee, s, bead_update_age, now)", "False"), ["LS-1", "LS-3c"]),
    ("sling-nao-passa-a-idade-da-bead", "guard", "        if session_is_live(assignee, sessions, now, bead_update_age,\n", "        if session_is_live(assignee, sessions, now, None,\n", ["LS-9"]),
    ("run-cycle-nao-passa-a-idade-da-bead", "guard",
     "has_live_session = session_is_live(\n                assignee, sessions, now, bead_update_age,",
     "has_live_session = session_is_live(\n                assignee, sessions, now, None,", ["LS-8"]),
    ("sem-checagem-de-idade-ilegivel", "lib", "    if bead_update_age is None:\n        return False\n", "    if False:\n        return False\n", ["Traceback"]),
    ("sem-checagem-de-nascimento-ilegivel", "lib", "    if born is None:\n        return False\n", "    if False:\n        return False\n", ["Traceback"]),
]


def fatal(msg):
    print("FATAL: " + msg)
    sys.exit(2)


def run_selftest(guard_text, lib_text, label):
    """Roda o --selftest de uma cópia com `guard_text` e `lib_text` (a bead_state.py); devolve (rc, saída). Falhou em rodar/estourou prazo → (None, motivo): nunca vira 'passou'."""
    tmp = tempfile.mkdtemp(prefix="irg-alias-mut-")
    try:
        with open(os.path.join(tmp, "inflight-reclaim-guard.py"), "w", encoding="utf-8") as f:
            f.write(guard_text)
        with open(os.path.join(tmp, "bead_state.py"), "w", encoding="utf-8") as f:
            f.write(lib_text)
        for sib in SIBLINGS:
            src = os.path.join(os.path.dirname(os.path.abspath(GUARD)), sib)
            if not os.path.isfile(src):
                return None, "irmão ausente ao lado do guard: " + sib
            shutil.copy(src, os.path.join(tmp, sib))
        env = dict(os.environ, GC_SELFTEST="1", GC_LEDGER_DIR=os.path.join(tmp, "ledger"))
        os.makedirs(env["GC_LEDGER_DIR"], exist_ok=True)

        def _limits():
            resource.setrlimit(resource.RLIMIT_FSIZE, (CHILD_FSIZE_BYTES, CHILD_FSIZE_BYTES))

        try:
            r = subprocess.run([sys.executable, os.path.join(tmp, "inflight-reclaim-guard.py"), "--selftest"], cwd=tmp, env=env,
                               capture_output=True, text=True, timeout=CHILD_TIMEOUT_SECS, preexec_fn=_limits)
        except subprocess.TimeoutExpired:
            return None, "estourou %ds (%s)" % (CHILD_TIMEOUT_SECS, label)
        except Exception as e:   # noqa: BLE001 — não conseguir rodar não é "mutante morto"
            return None, "não rodou (%s): %r" % (label, e)
        return r.returncode, r.stdout + r.stderr
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def judge(rc, out, expect):
    """True sse o mutante morreu PELO MOTIVO esperado."""
    if rc is None or rc == 0:
        return False
    if expect == ["Traceback"]:
        return "Traceback" in out
    return all(("FAIL: " + check_id) in out for check_id in expect)


def main():
    texts = {}
    for alvo, path in (("guard", GUARD), ("lib", LIB)):
        if not os.path.isfile(path):
            fatal("%s ausente: %s" % (alvo, path))
        with open(path, encoding="utf-8") as f:
            texts[alvo] = f.read()
    for name, alvo, old, new, _expect in MUTANTS:
        n = texts[alvo].count(old)
        if n != 1:
            fatal("mutante '%s' velho: o trecho aparece %d vez(es) no %s, tem de ser exatamente 1" % (name, n, alvo))
        if old == new:
            fatal("mutante '%s' não muda nada" % name)

    rc0, out0 = run_selftest(texts["guard"], texts["lib"], "controle")
    ls_pass = sum(1 for line in (out0 or "").splitlines() if line.startswith("PASS: LS-"))
    if rc0 != 0 or ls_pass < 17 or "FAIL:" in (out0 or ""):
        fatal("controle vermelho (cópia SEM mutação: rc=%r, checks LS passando=%d): %s" % (rc0, ls_pass, (out0 or "")[-300:].replace("\n", " | ")))
    print("controle: a cópia sem mutação passa (%d checks LS-*)" % ls_pass)

    def one(m):
        name, alvo, old, new, expect = m
        mutated = dict(texts, **{alvo: texts[alvo].replace(old, new, 1)})
        rc, out = run_selftest(mutated["guard"], mutated["lib"], name)
        return name, expect, judge(rc, out, expect), rc, out

    killed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for name, expect, dead, rc, out in pool.map(one, MUTANTS):
            if dead:
                killed += 1
                print("  morto      %s  (reprovou: %s)" % (name, ", ".join(expect)))
            else:
                fails = [l[6:30] for l in (out or "").splitlines() if l.startswith("FAIL: ")]
                print("  SOBREVIVEU %s  (esperava reprovar %s; rc=%r; reprovou: %s)" % (name, expect, rc, fails or (out or "")[-160:].replace("\n", " | ")))
    print("MUTANTES: %d/%d mortos" % (killed, len(MUTANTS)))
    sys.exit(0 if killed == len(MUTANTS) else 1)


if __name__ == "__main__":
    main()
