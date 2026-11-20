#!/usr/bin/env bash
# inflight-reclaim-guard.salvage-ref.selftest.sh — ga-vpan6h8: o resgate do guard (push-before-reclaim, ga-ufr7) não pode cair no vocabulário de ENTREGA.
#
# Contents
#   O que prova · Como roda
#
# O QUE PROVA: wa-4qu2n6.1 (19/11, relato do witness): builder morto com commit local; o guard empurrou o trabalho pela metade para crew/wa-worker/<bead> — nome que delivery-branch-patterns.sh lê como "esta bead tem
#   entrega" — e o Pilot vetou a bead 48 vezes em ~13 h (_filter_built: branch exists). Com git de verdade e o oráculo REAL (delivery-branch-patterns.sh, não uma cópia da lista):
#   G1 o resgate vai para origin como salvage/<bead>-<dono> com o sha do commit, e nenhum ref de origin é lido como entrega da bead; o ramo local e o worktree do builder ficam como estavam
#   G2 repetir o resgate (mesma ponta) devolve o mesmo registro, sem empurrar de novo  G3 salvage/ de mesmo nome já divergido em origin → refs/reclaimed/<bead>/<sha>
#   G4 push que falha (origin fora) → nada registrado, não levanta  G5 trabalho que já está em origin → nada a salvar, nada registrado
#   G6 do_reclaim grava pilot.salvage_ref + pilot.salvage_sha NA BEAD antes de soltar o dono (status open / assign); G7 a gravação que falha não trava o reclaim e o comentário de auditoria diz que ficou sem registro
#   G8 sem trabalho salvo não há `bd update --set-metadata`  G9 o nome do ref é ref válido para o git, único por ramo de origem, e fora do vocabulário de entrega
# COMO RODA: bash scripts/inflight-reclaim-guard.salvage-ref.selftest.sh   (~2 s no nó Linux, medido; bash 3.2.57 também passa)
#   SALVAGE_GUARD_UNDER_TEST=<guard>  SALVAGE_LIB_UNDER_TEST=<delivery-branch-patterns.sh>   apontam para outra árvore: é assim que "falha antes do fix" se prova (o guard do commit pai).
# Exit 0 iff todo check passa.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${SALVAGE_GUARD_UNDER_TEST:-$HERE/inflight-reclaim-guard.py}"
LIB="${SALVAGE_LIB_UNDER_TEST:-$HERE/../packs/town-deltas/assets/delivery-branch-patterns.sh}"
[ -f "$GUARD" ] || { echo "FATAL: guard ausente: $GUARD"; exit 2; }
[ -r "$LIB" ] || { echo "FATAL: delivery-branch-patterns.sh ausente: $LIB"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git ausente"; exit 2; }
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/irg-salvage-st.XXXXXX")" || { echo "FATAL: sem diretório temporário"; exit 2; }
trap 'rm -rf "$SCRATCH"' EXIT

env SCRATCH="$SCRATCH" GUARD="$GUARD" LIB="$LIB" python3 - <<'PY'
import importlib.util, json, os, subprocess, sys

SCRATCH, GUARD, LIB = os.environ["SCRATCH"], os.environ["GUARD"], os.environ["LIB"]
for k in ("NAME", "EMAIL"):
    os.environ["GIT_AUTHOR_" + k] = os.environ["GIT_COMMITTER_" + k] = "selftest" if k == "NAME" else "t@t.invalid"
sys.path.insert(0, os.path.dirname(GUARD))
spec = importlib.util.spec_from_file_location("irg", GUARD)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
real_run = subprocess.run          # m.subprocess IS this module: o G6/G7 troca .run, o git do fixture segue pelo real
m.time.sleep = lambda _s: None
PASS = FAIL = 0


def check(msg, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1; print("  ok: " + msg)
    else:
        FAIL += 1; print("  FAIL: " + msg + (" — " + str(detail) if detail else ""))


def git(*a, cwd=None):
    r = real_run(["git"] + list(a), cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(a), r.stderr.strip()))
    return r.stdout.strip()


def git_try(*a, cwd=None):
    """git que pode falhar DENTRO de um check: '' em vez de levantar (um ref que não existe é um FAIL a mostrar, não um crash que esconde os cenários seguintes)."""
    r = real_run(["git"] + list(a), cwd=cwd, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def make_rig(name):
    d = os.path.join(SCRATCH, name); os.makedirs(d)
    origin, rig = os.path.join(d, "origin.git"), os.path.join(d, "rig")
    git("init", "-q", "--bare", origin); git("symbolic-ref", "HEAD", "refs/heads/main", cwd=origin)
    git("init", "-q", rig); git("checkout", "-q", "-b", "main", cwd=rig)
    with open(os.path.join(rig, "README"), "w") as f:
        f.write("base\n")
    git("add", "README", cwd=rig); git("commit", "-q", "-m", "init", cwd=rig)
    git("remote", "add", "origin", origin, cwd=rig); git("push", "-q", "origin", "main", cwd=rig); git("fetch", "-q", "origin", cwd=rig)
    return origin, rig


def builder(rig, bead, branch):
    """Passo 2 do Build Protocol do wa-worker: worktree + ramo, um commit que nunca foi empurrado. -> (worktree, sha)"""
    wt = os.path.join(rig, "crew", "worker-" + bead)
    git("worktree", "add", "-q", wt, "-b", branch, "origin/main", cwd=rig)
    with open(os.path.join(wt, "feature.txt"), "w") as f:
        f.write(bead + "\n")
    git("add", "feature.txt", cwd=wt); git("commit", "-q", "-m", "feat(%s): half-built" % bead, cwd=wt)
    return wt, git("rev-parse", branch, cwd=rig)


def delivery_pick(bead, lines):
    """O que o oráculo REAL (gc_delivery_branch_pick) diz destes refs: o nome que ele toma por entrega da bead, '' se nenhum."""
    r = real_run(["bash", "-c", '. "$LIB"; gc_delivery_branch_pick "$1"', "x", bead], input=lines, capture_output=True, text=True, env=dict(os.environ, LIB=LIB))
    return r.stdout if r.returncode == 0 else ""


def origin_heads(origin):
    return git("for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", cwd=origin)


BEAD, BRANCH = "wa-x1", "crew/wa-worker/wa-x1"
SALV = "salvage/wa-x1-wa-worker"

print("oráculo vivo: o ramo de entrega de uma bead É lido como entrega (sem isto 'nenhum ref é entrega' não prova nada)")
check("G0 refs/heads/%s → entrega de %s" % (BRANCH, BEAD), delivery_pick(BEAD, "refs/heads/%s\n" % BRANCH) == BRANCH)

print("G1 o caso do incidente: builder morto, commit local nunca empurrado")
origin, rig = make_rig("g1"); wt, tip = builder(rig, BEAD, BRANCH)
m.REPOS = [rig]
res = m.preserve_unpushed_branch(BEAD)
recs = list(getattr(res, "records", []))
heads = origin_heads(origin)
check("G1a o commit está em origin/%s" % SALV, "%s refs/heads/%s" % (tip, SALV) in heads, heads)
check("G1b nenhum ref de origin é lido como entrega de %s" % BEAD, delivery_pick(BEAD, git("ls-remote", "--heads", "origin", cwd=rig) + "\n") == "", heads)
check("G1c registro estruturado: ramo salvage + sha do commit", len(recs) == 1 and recs[0].get("ref") == SALV and recs[0].get("sha") == tip, recs)
check("G1d o texto de auditoria nomeia o ref", len(res) == 1 and SALV in res[0], list(res))
check("G1e o ramo local do builder segue na ponta dele e o worktree está limpo (o resgate não mexe no que o builder deixou)",
      git_try("rev-parse", "--verify", "-q", BRANCH, cwd=rig) == tip and os.path.isdir(wt) and git_try("status", "--porcelain", cwd=wt) == "")

print("G2 repetir o resgate com a mesma ponta (a gravação do 1º falhou, ou o reclaim repete)")
pushes2 = []


def counting_run(cmd, *a, **kw):
    if cmd and cmd[0] == "git" and "push" in cmd:
        pushes2.append(list(cmd))
    return real_run(cmd, *a, **kw)


m.subprocess.run = counting_run
try:
    res2 = m.preserve_unpushed_branch(BEAD)
finally:
    m.subprocess.run = real_run
recs2 = list(getattr(res2, "records", []))
check("G2a mesmo ref e sha de novo, para a gravação poder ser refeita", len(recs2) == 1 and recs2[0].get("ref") == SALV and recs2[0].get("sha") == tip, recs2)
check("G2b nenhum git push (nem o idempotente) e nada novo em origin", pushes2 == [] and origin_heads(origin) == heads, pushes2)

print("G3 salvage/ de mesmo nome já divergido em origin → o refs/reclaimed/<bead>/<sha> de sempre")
origin3, rig3 = make_rig("g3"); wt3, tip3 = builder(rig3, BEAD, BRANCH)
git("branch", SALV, "origin/main", cwd=rig3)
with open(os.path.join(rig3, "other.txt"), "w") as f:
    f.write("diverged\n")
git("checkout", "-q", SALV, cwd=rig3); git("add", "other.txt", cwd=rig3); git("commit", "-q", "-m", "diverge", cwd=rig3)
git("push", "-q", "origin", SALV, cwd=rig3); git("checkout", "-q", "main", cwd=rig3); git("branch", "-q", "-D", SALV, cwd=rig3)
m.REPOS = [rig3]
res3 = m.preserve_unpushed_branch(BEAD); recs3 = list(getattr(res3, "records", []))
tag = "refs/reclaimed/%s/%s" % (BEAD, tip3)
check("G3a o commit está em %s" % tag, git_try("rev-parse", "--verify", "-q", tag, cwd=origin3) == tip3)
check("G3b registro aponta o refs/reclaimed", len(recs3) == 1 and recs3[0].get("ref") == tag and recs3[0].get("sha") == tip3, recs3)

print("G4 push que falha: origin fora do ar")
origin4, rig4 = make_rig("g4"); wt4, tip4 = builder(rig4, BEAD, BRANCH)
git("config", "remote.origin.pushurl", os.path.join(SCRATCH, "nao-existe.git"), cwd=rig4)
m.REPOS = [rig4]
try:
    res4 = m.preserve_unpushed_branch(BEAD); recs4 = list(getattr(res4, "records", []))
    check("G4 as duas tentativas falham → nada registrado (falhou não é 'salvo') e não levanta", list(res4) == [] and recs4 == [], (list(res4), recs4))
except Exception as exc:
    check("G4 não levanta", False, repr(exc))

print("G5 o trabalho já está em origin: nada a salvar")
origin5, rig5 = make_rig("g5"); wt5, tip5 = builder(rig5, BEAD, BRANCH)
git("push", "-q", "origin", "%s:refs/heads/fix/%s-slug" % (tip5, BEAD), cwd=rig5)
m.REPOS = [rig5]
res5 = m.preserve_unpushed_branch(BEAD)
check("G5 lista vazia e sem registro", list(res5) == [] and list(getattr(res5, "records", [])) == [], (list(res5), list(getattr(res5, "records", []))))

print("G6-G8 do_reclaim: a gravação na bead, e a ordem em relação ao dono")


class R:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err


def reclaim(rig, meta_rc=0):
    calls = []

    def run(cmd, *a, **kw):
        if cmd and cmd[0] == "git":
            return real_run(cmd, *a, **kw)
        calls.append(list(cmd))
        if len(cmd) > 1 and cmd[1] == "show":
            return R(0, json.dumps([{"id": BEAD, "labels": ["lane:small"]}]))
        if "--set-metadata" in cmd:
            return R(meta_rc, "", "" if meta_rc == 0 else "bd: boom")
        return R(0, "")
    m.subprocess.run = run
    m.REPOS = [rig]
    try:
        ok = m.do_reclaim(BEAD, "titulo", 0, 30.0, ["story:in-flight", "pilot:dispatched", "lane:small"])
    finally:
        m.subprocess.run = real_run
    return ok, calls


def meta_of(calls):
    for c in calls:
        if "--set-metadata" in c:
            return dict(c[i + 1].split("=", 1) for i, a in enumerate(c) if a == "--set-metadata")
    return None


def idx(calls, pred):
    return next((i for i, c in enumerate(calls) if pred(c)), None)


origin6, rig6 = make_rig("g6"); wt6, tip6 = builder(rig6, BEAD, BRANCH)
ok6, calls6 = reclaim(rig6)
meta = meta_of(calls6)
i_meta, i_status = idx(calls6, lambda c: "--set-metadata" in c), idx(calls6, lambda c: c[1:3] == ["update", BEAD] and "--status" in c)
i_assign = idx(calls6, lambda c: len(c) > 1 and c[1] == "assign")
check("G6a pilot.salvage_ref e pilot.salvage_sha gravados na bead", meta is not None and meta.get("pilot.salvage_ref") == SALV and meta.get("pilot.salvage_sha") == tip6, meta)
check("G6b a gravação vem ANTES do status open e do assign (a bead só fica candidata do Pilot com a prova já escrita)",
      None not in (i_meta, i_status, i_assign) and i_meta < i_status and i_meta < i_assign, (i_meta, i_status, i_assign))
comment = next((c[-1] for c in calls6 if len(c) > 2 and c[1] == "comment"), "")
check("G6c o comentário de auditoria diz onde o trabalho ficou", SALV in comment, comment[:300])
m.subprocess.run = lambda cmd, *a, **kw: R(0, "")
try:
    note = m._record_salvage_metadata(["bd"], BEAD, recs3) if hasattr(m, "_record_salvage_metadata") else ""     # recs3 = o registro do fallback refs/reclaimed (G3)
finally:
    m.subprocess.run = real_run
check("G6d o fallback refs/reclaimed aparece pelo nome inteiro, não como origin/refs/…", tag in note and "origin/refs/" not in note, note[:300])

origin7, rig7 = make_rig("g7"); wt7, tip7 = builder(rig7, BEAD, BRANCH)
ok7, calls7 = reclaim(rig7, meta_rc=1)
comment7 = next((c[-1] for c in calls7 if len(c) > 2 and c[1] == "comment"), "")
check("G7a a gravação que falha não trava o reclaim (o dono sai e o status vira open)", ok7 is True and idx(calls7, lambda c: len(c) > 1 and c[1] == "assign") is not None and idx(calls7, lambda c: c[1:3] == ["update", BEAD] and "--status" in c) is not None)
check("G7b o comentário diz que o registro NÃO foi gravado (o Pilot segue lendo o ramo local como antes)", "NOT recorded" in comment7, comment7[:300])

origin8, rig8 = make_rig("g8"); wt8, tip8 = builder(rig8, BEAD, BRANCH)
git("push", "-q", "origin", "%s:refs/heads/fix/%s-slug" % (tip8, BEAD), cwd=rig8)
ok8, calls8 = reclaim(rig8)
check("G8 nada salvo (já está em origin) → nenhum `bd update --set-metadata`", meta_of(calls8) is None, meta_of(calls8))

print("G9 o nome do ref")
names = {(BEAD, BRANCH): "salvage/wa-x1-wa-worker", ("ga-abc", "fix/ga-abc-my-slug"): "salvage/ga-abc-fix-my-slug", ("ga-abc", "feat/ga-abc"): "salvage/ga-abc-feat",
         ("ga-abc", "crew/wa-worker/ga-abc"): "salvage/ga-abc-wa-worker", ("wa-x1", "crew/wa-worker/wa-x1.1"): "salvage/wa-x1-wa-worker-1"}
for (b, br), want in names.items():
    got = m._salvage_branch_name(b, br) if hasattr(m, "_salvage_branch_name") else None
    check("G9a %s de %s → %s" % (b, br, want), got == want, got)
distinct = {m._salvage_branch_name("ga-abc", br) for br in ("crew/wa-worker/ga-abc", "crew/ps-worker/ga-abc", "fix/ga-abc-a", "fix/ga-abc-b", "feat/ga-abc")} if hasattr(m, "_salvage_branch_name") else set()
check("G9b ramos de origem diferentes não dividem o nome (cada um tem o seu resgate)", len(distinct) == 5, distinct)
hostile = m._salvage_branch_name("ga-abc", "crew/p@{x}/ga-abc..y.lock") if hasattr(m, "_salvage_branch_name") else ""
fmt = real_run(["git", "check-ref-format", "refs/heads/" + hostile], capture_output=True, text=True).returncode if hostile else 1
check("G9c nome montado a partir de ramo com caracteres estranhos ainda é ref válido (git check-ref-format)", fmt == 0, hostile)
check("G9d nenhum desses nomes é lido como entrega pelo oráculo real", all(delivery_pick(b, "refs/heads/%s\n" % m._salvage_branch_name(b, br)) == "" for (b, br) in names) if hasattr(m, "_salvage_branch_name") else False)

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(0 if FAIL == 0 else 1)
PY
