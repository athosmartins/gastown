#!/usr/bin/env python3
"""disk-recovery-swap-cut.mutants.py — controle negativo do degrau de swap (ga-yh41v0e): cada guarda desligada tem que reprovar o selftest.

Contents
  O que faz · Como roda · Saída

O QUE FAZ: cada mutante troca UM trecho de scripts/disk-recovery-swap-cut.sh numa CÓPIA (o original nunca é tocado) e roda scripts/disk-recovery-swap-cut.selftest.sh contra a cópia (SWC_ST_SUT=<cópia>,
  SWC_ST_FAILFAST=1: sai no 1º FAIL). MORTO = o selftest saiu != 0 com a linha "FAIL" no texto (prazo, cópia que nem abre ou SyntaxError NÃO matam). SOBREVIVEU = saiu 0: a guarda não tem teste. Antes dos mutantes
  roda um CONTROLE: a cópia sem mutação tem de passar, senão "todos mortos" seria o harness quebrado reprovando tudo. Cada trecho trocado tem de aparecer EXATAMENTE uma vez no degrau (senão FATAL: o degrau andou e o
  mutante ficou velho). Os mutantes são as garantias do P0: nunca cortar dono que não é de pool, nunca sessão anexada/com bead/com transcrição recente, o teto por rodada, o gatilho de crescimento e o absoluto, a
  pausa do Pilot com validade, e o terceiro estado (amostrador cego = não corta, rc 30).
COMO RODA: python3 -I scripts/disk-recovery-swap-cut.mutants.py   (cada filho roda o selftest inteiro, hermético; 3 cópias por vez, 512 MB por arquivo e 300 s). No mini o disco é curto: rode no nó
  (o mbp-run.sh só aceita `*.selftest.sh`, então a porta é scripts/disk-recovery-swap-cut.mutants.selftest.sh, opt-in: mbp-run.sh --repo hq --dir <worktree>/.gascity-gastown-hq -- scripts/disk-recovery-swap-cut.mutants.selftest.sh --run).
  SWC_MUTANTS_SUT=<arquivo>  aponta para outro degrau (nenhum selftest o usa hoje; serve para ver o FATAL à mão com um degrau que perdeu um trecho) · SWC_MUTANTS_WORKERS=N (1 a 8, padrão 3)
SAÍDA: uma linha por mutante (morto / SOBREVIVEU) e `MUTANTES: <mortos>/<total> mortos`; exit 0 só com todos mortos; exit 2 (FATAL) para degrau ausente, mutante velho ou controle vermelho.
"""
import concurrent.futures
import os
import resource
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SUT = os.environ.get("SWC_MUTANTS_SUT") or os.path.join(HERE, "disk-recovery-swap-cut.sh")
SELFTEST = os.path.join(HERE, "disk-recovery-swap-cut.selftest.sh")
CHILD_TIMEOUT_SECS, CHILD_FSIZE_BYTES = 300, 512 * 1024 * 1024
try:
    WORKERS = min(8, max(1, int(os.environ.get("SWC_MUTANTS_WORKERS", "3"))))
except ValueError:
    WORKERS = 3

# (nome, trecho antigo, trecho novo) — cada trecho antigo aparece EXATAMENTE uma vez no degrau
MUTANTS = [
    # --- o gatilho ---
    ("gatilho absoluto some (swap > ABS_MB não dispara)",
     'if [ "$SW_REF" -gt "$ABS_MB" ]; then WHY_TRIG=',
     'if [ "$SW_REF" -gt 99999999 ]; then WHY_TRIG='),
    ("gatilho de crescimento some (>= GROW_MB não dispara)",
     'if [ -n "$GROWTH" ] && [ "$GROWTH" -ge "$GROW_MB" ]; then WHY_TRIG=',
     'if [ -n "$GROWTH" ] && [ "$GROWTH" -ge 99999999 ]; then WHY_TRIG='),
    ("gatilho de crescimento dispara no limite errado (> em vez de >=)",
     'if [ -n "$GROWTH" ] && [ "$GROWTH" -ge "$GROW_MB" ]; then WHY_TRIG=',
     'if [ -n "$GROWTH" ] && [ "$GROWTH" -gt "$GROW_MB" ]; then WHY_TRIG='),
    # --- quem pode ser cortado ---
    ("sessão anexada deixa de ser protegida",
     'if s.get("attached") is not False:',
     'if False:'),
    ("a deny-list deixa de valer (crew/dog/dolt entram como candidatos)",
     'if n and fnmatch.fnmatchcase(n, g):',
     'if False:'),
    ("sessão que não está active (asleep/closed) vira candidata",
     'if s.get("closed") is True or s.get("state") != "active":',
     'if False:'),
    ("transcrição recente deixa de proteger (IDLE_MIN ignorado)",
     'if [ "$idle" -lt "$IDLE_MIN" ]; then skipped=',
     'if [ "$idle" -lt -1 ]; then skipped='),
    ("bead in_progress deixa de proteger a sessão",
     'if [ "$st" != 0 ]; then blocked=',
     'if false; then blocked='),
    ("o teto MAX_CUT por rodada some",
     'if [ $((cut_n + unc_n)) -ge "$MAX_CUT" ]; then skipped=',
     'if [ $((cut_n + unc_n)) -ge 99999 ]; then skipped='),
    # --- o terceiro estado: amostrador cego = não corta ---
    ("sessions_lookup_failed ausente/True deixa de barrar (rótulos de sessão não confiáveis)",
     'if best.get("sessions_lookup_failed") is not False:',
     'if False:'),
    ("amostrador parado há > SAMPLER_DEAD_S deixa de ser 'cego'",
     'if [ "$age" -gt "$SAMPLER_DEAD_S" ]; then BLIND=',
     'if [ "$age" -gt 99999999 ]; then BLIND='),
    ("amostra velha depois de colher uma deixa de ser 'cego'",
     'if [ $((NOW - NEW_TS)) -gt "$SAMPLE_MAX_AGE_S" ]; then',
     'if [ $((NOW - NEW_TS)) -gt 99999999 ]; then'),
    ("leitura cega vira 'sem gatilho' (rc 10 em vez de 30)",
     'read_history || { log "SEM LEITURA: $BLIND — nao corto, nao pauso"; say "SEM LEITURA: $BLIND; nao cortei nada"; return 30; }',
     'read_history || { log "SEM LEITURA: $BLIND — nao corto, nao pauso"; say "SEM LEITURA: $BLIND; nao cortei nada"; return 10; }'),
    # --- a pausa do Pilot ---
    ("a pausa do Pilot ganha validade infinita (o freio de expiração some)",
     '  exp=$((t + PAUSE_TTL_S))',
     '  exp=$((t + 99999999))'),
    # --- a retomada ---
    ("a retomada apaga a pausa sem esperar calma (PAUSE_CALM_S ignorado)",
     'if [ "$has_pause" = 1 ] && [ "$age" -ge "$PAUSE_CALM_S" ]; then',
     'if [ "$has_pause" = 1 ] && [ "$age" -ge -1 ]; then'),
    ("a retomada considera calmo sem conferir o nível absoluto",
     'if [ "$SW_REF" -le $((ABS_MB - HYST_MB)) ] && [ -n "$GROWTH" ]',
     'if [ "$SW_REF" -le 99999999 ] && [ -n "$GROWTH" ]'),
    ("a retomada considera calmo crescimento desconhecido (histórico curto)",
     '[ -n "$GROWTH" ] && [ "$GROWTH" -lt $((GROW_MB / 2)) ] && ! triggered; then calm=1; fi',
     '{ [ -z "$GROWTH" ] || [ "$GROWTH" -lt $((GROW_MB / 2)) ]; } && ! triggered; then calm=1; fi'),
]


def _limit_child():
    resource.setrlimit(resource.RLIMIT_FSIZE, (CHILD_FSIZE_BYTES, CHILD_FSIZE_BYTES))
    os.setsid()


def _run(sut, tmp):
    env = dict(os.environ, SWC_ST_SUT=sut, SWC_ST_FAILFAST="1", TMPDIR=tmp)
    for k in [k for k in env if k.startswith("DR_")]:
        del env[k]
    try:
        p = subprocess.run(["bash", SELFTEST], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=CHILD_TIMEOUT_SECS,
                           preexec_fn=_limit_child, text=True, errors="replace")
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        # prazo estourado: descarta a saída parcial (sem linha "FAIL" nunca vira "morto"); rc 124 é só o rótulo
        return 124, ""


def main():
    if not os.path.isfile(SUT):
        print("FATAL: degrau não encontrado em %s" % SUT, file=sys.stderr)
        return 2
    if not os.path.isfile(SELFTEST):
        print("FATAL: selftest não encontrado em %s" % SELFTEST, file=sys.stderr)
        return 2
    src = open(SUT, encoding="utf-8").read()
    for name, old, new in MUTANTS:
        n = src.count(old)
        if n != 1 or old == new:
            print("FATAL: o trecho do mutante '%s' aparece %d vez(es) no degrau (tem de ser exatamente 1) — o degrau andou, atualize o mutante" % (name, n), file=sys.stderr)
            return 2
    work = tempfile.mkdtemp(prefix="swc-mutants.")
    try:
        copies = []
        for i, (name, old, new) in enumerate([("controle", "", "")] + MUTANTS):
            d = os.path.join(work, "m%02d" % i)
            os.makedirs(d)
            f = os.path.join(d, "disk-recovery-swap-cut.sh")
            with open(f, "w", encoding="utf-8") as fh:
                fh.write(src if i == 0 else src.replace(old, new, 1))
            os.chmod(f, 0o755)
            if i > 0:
                bn = subprocess.run(["bash", "-n", f], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if bn.returncode != 0:
                    print("FATAL: o mutante '%s' não compila (bash -n): mutante inválido não vale como morto" % name, file=sys.stderr)
                    return 2
            copies.append((name, f, d))
        # controle: a cópia limpa PASSA (senão "todos mortos" é o harness quebrado)
        rc, out = _run(copies[0][1], copies[0][2])
        if rc != 0:
            print("FATAL: o CONTROLE (degrau sem mutação) não passa no selftest (rc=%d): nenhum veredito vale\n%s" % (rc, out[-1500:]), file=sys.stderr)
            return 2
        print("controle: o degrau sem mutação passa no selftest")

        def one(item):
            name, f, d = item
            rc, out = _run(f, d)
            killed = rc != 0 and any(l.startswith("FAIL") for l in out.splitlines())
            first = next((l for l in out.splitlines() if l.startswith("FAIL")), "")
            return name, killed, rc, first

        dead = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
            for name, killed, rc, first in ex.map(one, copies[1:]):
                if killed:
                    dead += 1
                    print("  morto     %s" % name)
                else:
                    print("  SOBREVIVEU %s (rc=%d%s)" % (name, rc, (" — " + first[:120]) if first else ""))
        total = len(MUTANTS)
        print("MUTANTES: %d/%d mortos" % (dead, total))
        return 0 if dead == total else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
