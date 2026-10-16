#!/usr/bin/env python3
"""wait-for-dolt-plan.selftest.py — hermético: plists e programas falsos numa pasta de mktemp, `plutil` de mentira, "cidade" de mentira com uma cópia do wait-for-dolt.sh de verdade.
Não lê o ~/Library/LaunchAgents, não chama launchctl.

Contents
  Casos · Controle negativo (mutantes) · Variáveis

CASOS: plano é SÓ LEITURA (checksum da pasta não muda) e a medição separa chamada de texto (echo/log/jq/comentário/aspas ≠ LÊ), lê o script executado direto e trata script citado que não existe como ILEGÍVEL · escopo (label de fora, programa na árvore de outro
  rig, RunAtLoad=false) · plist ilegível listado · plist que o expat recusa e o plutil aceita · --apply: ProgramArguments novo exato, demais chaves e a ordem delas preservadas, o que não é
  wrap fica byte a byte igual, backup byte a byte do original, idempotente (2ª vez não embrulha de novo) · --revert devolve o original e é idempotente · RECUSAS (nada é escrito): divergência,
  wrapper ausente/não executável/com sintaxe ruim, wrap em KeepAlive, wrap sem chamada medida, label em 2 arquivos · plist symlink / com chave Program / que o plutil -lint recusa não são
  alterados · política ilegível, com decisão desconhecida ou label repetido = exit 3 · uso errado = exit 2.
CONTROLE NEGATIVO: cada guarda (marca `GUARD:` no script) é adulterada numa cópia e o caso que a cobre TEM que passar a falhar; mutante que não muda o arquivo também falha.
VARIÁVEIS: WFDP_UNDER_TEST (script a testar) · WFDP_NO_MUTANTS=1
"""
import atexit
import hashlib
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.environ.get("WFDP_UNDER_TEST", os.path.join(HERE, "wait-for-dolt-plan.py"))
T = os.path.realpath(tempfile.mkdtemp(prefix="wfdp."))
atexit.register(shutil.rmtree, T, True)
ROOT, CITY, PROG, STUB = f"{T}/gt", f"{T}/city", f"{T}/gt/.gascity-gastown-hq/scripts", f"{T}/plutil-stub"
WRAPPER = f"{CITY}/scripts/wait-for-dolt.sh"
os.makedirs(PROG), os.makedirs(f"{CITY}/scripts"), os.makedirs(f"{ROOT}/otherrig/scripts")
shutil.copy(os.path.join(HERE, "wait-for-dolt.sh"), WRAPPER)
os.chmod(WRAPPER, 0o755)
LENIENT = b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>com.gascity.lenient-k</string><key>RunAtLoad</key><true/><key>StartInterval</key><integer>60</integer><key>ProgramArguments</key><array><string>/bin/bash</string><string>%s/k.sh</string></array></dict></plist>' % PROG.encode()
open(f"{T}/lenient.xml", "wb").write(LENIENT)
open(STUB, "w").write(f'#!/bin/sh\ncase "$1" in -convert) case "$5" in *lenient*) cat "{T}/lenient.xml" ;; *) exit 1 ;; esac ;; -lint) grep -q BROKEN "$2" && exit 1; exit 0 ;; esac\n')
os.chmod(STUB, 0o755)
ENV = dict(os.environ, WFD_GT_ROOT=ROOT, GC_CITY_PATH=CITY, WFD_PLUTIL=STUB)

PROGRAMS = {
    "a.sh": '#!/bin/bash\nout=$(bd -C "$CITY" list --json 2>/dev/null) || exit 0\n',
    "b.sh": '#!/bin/bash\necho "bd list failed"\n# bd list\nlog "gc down: retry"\nmsg=\'run gc session list later\'\nprintf "%s\\n" "gc rig list failed"\n'
            'jq \'if type != "array" then error("bd list did not print an array") else . end\'\nx="kept (gc failed and printed)"\n',
    "c.py": 'r = sh(["gc", "session", "list"])\n',
    "d.py": 'import subprocess\nsubprocess.run(["bd", "list", "--json"])\n',
    "e.sh": '#!/bin/bash\nx=$(timeout 20 gc rig list --json)\n',
    "k.sh": '#!/bin/bash\n"$GC" nudge x\n',
    "n.sh": '#!/bin/bash\ndf -h\n',
    "m.sh": '#!/bin/bash\nbd list --json >/dev/null 2>&1\n',
}
for name, body in PROGRAMS.items():
    open(f"{PROG}/{name}", "w").write(body)
open(f"{ROOT}/otherrig/scripts/x.sh", "w").write("#!/bin/bash\nbd list\n")


def plist(d, label, args, **kw):
    data = {"Label": label, "ProgramArguments": args, "RunAtLoad": True}
    data.update(kw)
    with open(f"{d}/{label}.plist", "wb") as fh:
        plistlib.dump(data, fh, sort_keys=False)


def fixture(name):
    """Pasta nova de LaunchAgents falsos (uma por cenário, para um não sujar o outro)."""
    d = f"{T}/la-{name}"
    os.makedirs(d)
    plist(d, "com.gascity.reaper-a", ["/bin/bash", f"{PROG}/a.sh"], StartInterval=300, EnvironmentVariables={"X": "1"}, StandardErrorPath="/tmp/a.err")
    plist(d, "com.gascity.logonly-b", ["/bin/bash", f"{PROG}/b.sh"], StartInterval=60)
    plist(d, "com.gascity.keepalive-c", ["/usr/bin/python3", f"{PROG}/c.py"], KeepAlive=True)
    plist(d, "com.gascity.py-d", ["/usr/bin/python3", f"{PROG}/d.py"], StartCalendarInterval={"Hour": 4, "Minute": 0})
    plist(d, "com.gascity.inline-e", ["/bin/bash", "-c", f"{PROG}/e.sh && echo done"], StartInterval=120)
    plist(d, "com.gascity.noprog-i", ["/bin/true"], StartInterval=60)
    plist(d, "com.gascity.nolook-n", ["/bin/bash", f"{PROG}/n.sh"], StartInterval=60)
    plist(d, "com.gascity.direct-p", [f"{PROG}/m.sh"], StartInterval=60)
    plist(d, "com.gascity.gone-q", ["/bin/bash", "-c", f"{PROG}/nao-existe.sh && echo done"], StartInterval=60)
    plist(d, "com.other.f", ["/bin/bash", f"{PROG}/a.sh"], StartInterval=60)
    plist(d, "com.gascity.otherrig-g", ["/bin/bash", f"{ROOT}/otherrig/scripts/x.sh"], StartInterval=60)
    plist(d, "com.gascity.norun-h", ["/bin/bash", f"{PROG}/a.sh"], RunAtLoad=False)
    open(f"{d}/com.gascity.lenient-k.plist", "wb").write(LENIENT.replace(b"<dict>", b"<dict><!-- x -- y -->", 1))
    open(f"{d}/garbage.plist", "wb").write(b"\x00\x01 isto nao e plist")
    return d


BASE_POLICY = """# política de teste
com.gascity.reaper-a\twrap\ta
com.gascity.py-d\twrap\td
com.gascity.inline-e\twrap\te
com.gascity.lenient-k\twrap\tk
com.gascity.keepalive-c\tisento\tKeepAlive
com.gascity.logonly-b\tnao-medido\tb
com.gascity.noprog-i\tnao-medido\ti
com.gascity.nolook-n\tnao-medido\tn
com.gascity.direct-p\tnao-medido\tp
com.gascity.gone-q\tnao-medido\tq
"""
WRAP_LABELS = ["reaper-a", "py-d", "inline-e", "lenient-k"]
_n = [0]


def policy(text=BASE_POLICY):
    _n[0] += 1
    path = f"{T}/policy-{_n[0]}.tsv"
    open(path, "w", encoding="utf-8").write(text)
    return path


def run(args, d, pol=None, wrapper=WRAPPER, tool=None, bk=None):
    cmd = [sys.executable, "-I", tool or TOOL, "--dir", d, "--policy", pol or policy(), "--wrapper", wrapper, "--backup-dir", bk or f"{T}/bk-{_n[0]}"] + args
    r = subprocess.run(cmd, env=ENV, capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout, r.stderr


def snap(d):
    return {n: hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest() if not os.path.islink(os.path.join(d, n)) else "link:" + os.readlink(os.path.join(d, n)) for n in sorted(os.listdir(d))}


def load(d, label):
    try:
        return plistlib.load(open(f"{d}/com.gascity.{label}.plist", "rb"))
    except Exception:  # noqa: BLE001 — o plist "leniente" é o que o expat recusa; o que ele diz é o que o plutil de mentira devolve
        return plistlib.loads(LENIENT)


def prog_of(d, label):
    return load(d, label)["ProgramArguments"]


# ---- cenários (cada um devolve True = passou; a suíte e os mutantes usam as mesmas funções)
def c_plan_readonly():
    d = fixture("plan"); before = snap(d)
    rc, out, _ = run([], d)
    return (rc == 0 and snap(d) == before and "medido (escopo HQ): LE=6 · TALVEZ=1 · NAO-ACHEI=1 · ILEGIVEL=2" in out and "garbage.plist" in out
            and out.count("A EMBRULHAR") == 4 and "com.other.f" in out.split("== FORA DO ESCOPO")[1] and "otherrig-g" in out.split("== FORA DO ESCOPO")[1]
            and "norun-h" not in out and "política: wrap=4 · isento=1 · nao-medido=5 · embrulhados hoje: 0 de 4" in out
            and "direct-p [LE]" in out and "gone-q [ILEGIVEL]" in out)


def c_apply_revert():
    d = fixture("ar"); orig = {l: prog_of(d, l) for l in WRAP_LABELS}; keys = {l: list(load(d, l)) for l in WRAP_LABELS}; before = snap(d); bk = f"{T}/bk-ar"; pol = policy()
    rc, out, _ = run(["--apply"], d, pol, bk=bk)
    after = snap(d)
    if rc != 0 or "4 embrulhado(s), 0 falha(s)" not in out:
        return False
    for l in WRAP_LABELS:
        want = [WRAPPER, "--timeout", "300", "--boot-window", "900", "--"] + orig[l]
        got = load(d, l)
        if got["ProgramArguments"] != want or list(got) != keys[l]:
            return False
    changed = {n for n in after if after[n] != before[n]}
    if changed != {f"com.gascity.{l}.plist" for l in WRAP_LABELS}:
        return False
    if any(hashlib.sha256(open(f"{bk}/{n}", "rb").read()).hexdigest() != before[n] for n in changed):   # backup = original byte a byte
        return False
    rc2, out2, _ = run(["--apply"], d, pol, bk=f"{T}/bk-ar2")
    if rc2 != 0 or "0 embrulhado(s)" not in out2 or snap(d) != after:   # idempotente
        return False
    rc3, out3, _ = run([], d, pol)
    if rc3 != 0 or out3.count("JÁ EMBRULHADO") != 4:
        return False
    rc4, out4, _ = run(["--revert"], d, bk=f"{T}/bk-ar3")
    if rc4 != 0 or "4 revertido(s), 0 falha(s)" not in out4 or any(prog_of(d, l) != orig[l] or list(load(d, l)) != keys[l] for l in WRAP_LABELS):
        return False
    rc5, out5, _ = run(["--revert"], d, bk=f"{T}/bk-ar4")
    return rc5 == 0 and "0 revertido(s)" in out5


def c_refuse_divergence():
    d = fixture("div"); plist(d, "com.gascity.newjob-z", ["/bin/bash", f"{PROG}/a.sh"], StartInterval=60); before = snap(d)
    rc, out, _ = run([], d)
    rc2, _, err2 = run(["--apply"], d)
    return rc == 1 and "NÃO CLASSIFICADO" in out and "newjob-z" in out and rc2 == 1 and "RECUSADO" in err2 and snap(d) == before


def c_refuse_wrapper():
    d = fixture("wr"); before = snap(d); res = []
    res.append(run(["--apply"], d, wrapper=f"{T}/nao-existe.sh")[0])
    noexec = f"{T}/noexec.sh"; shutil.copy(WRAPPER, noexec); os.chmod(noexec, 0o644)
    res.append(run(["--apply"], d, wrapper=noexec)[0])
    bad = f"{T}/bad.sh"; open(bad, "w").write("#!/bin/bash\nif then fi\n"); os.chmod(bad, 0o755)
    res.append(run(["--apply"], d, wrapper=bad)[0])
    return res == [4, 4, 4] and snap(d) == before


def c_wrap_keepalive():
    d = fixture("ka"); pol = policy(BASE_POLICY.replace("keepalive-c\tisento", "keepalive-c\twrap")); before = snap(d)
    rc, out, _ = run([], d, pol); rc2, _, _ = run(["--apply"], d, pol)
    return rc == 1 and "wrap em job KeepAlive" in out and rc2 == 1 and snap(d) == before


def c_wrap_without_reading():
    d = fixture("nr"); pol = policy(BASE_POLICY.replace("logonly-b\tnao-medido", "logonly-b\twrap")); before = snap(d)
    rc, out, _ = run([], d, pol); rc2, _, _ = run(["--apply"], d, pol)
    return rc == 1 and "wrap sem leitura medida (TALVEZ): com.gascity.logonly-b" in out and rc2 == 1 and snap(d) == before


def c_duplicate_label():
    d = fixture("dup"); shutil.copy(f"{d}/com.gascity.reaper-a.plist", f"{d}/reaper-a-old.plist"); before = snap(d)
    rc, out, _ = run([], d); rc2, _, _ = run(["--apply"], d)
    return rc == 1 and "label em 2 arquivos" in out and rc2 == 1 and snap(d) == before


def c_policy_errors():
    d = fixture("pe"); codes = []
    codes.append(run([], d, policy(BASE_POLICY + "com.gascity.x\tembrulha\tmotivo\n"))[0])
    codes.append(run([], d, policy(BASE_POLICY + "com.gascity.reaper-a\twrap\tde novo\n"))[0])
    codes.append(run([], d, policy(BASE_POLICY + "com.gascity.x\twrap\n"))[0])
    codes.append(run([], d, pol=f"{T}/nao-existe.tsv")[0])
    codes.append(run([], f"{T}/pasta-que-nao-existe")[0])
    return codes == [3, 3, 3, 3, 3]


def c_usage():
    d = fixture("us")
    return [run(a, d)[0] for a in (["--apply", "--revert"], ["--timeout", "5000"], ["--boot-window", "99999999"], ["--bogus"])] == [2, 2, 2, 2]


def c_skips():
    d = fixture("sk"); real = f"{T}/real-l.plist"
    plist(T, "com.gascity.link-l", ["/bin/bash", f"{PROG}/a.sh"], StartInterval=60); os.rename(f"{T}/com.gascity.link-l.plist", real); os.symlink(real, f"{d}/com.gascity.link-l.plist")
    plist(d, "com.gascity.prog-m", ["/bin/bash", f"{PROG}/a.sh"], Program="/bin/bash", StartInterval=60)
    plist(d, "com.gascity.lint-o", ["/bin/bash", f"{PROG}/a.sh"], StartInterval=60, Note="BROKEN")
    pol = policy(BASE_POLICY + "com.gascity.link-l\twrap\tl\ncom.gascity.prog-m\twrap\tm\ncom.gascity.lint-o\twrap\to\n"); before = snap(d); realsum = hashlib.sha256(open(real, "rb").read()).hexdigest()
    rc, out, _ = run(["--apply"], d, pol)
    after = snap(d)
    untouched = all(after[n] == before[n] for n in ("com.gascity.link-l.plist", "com.gascity.prog-m.plist", "com.gascity.lint-o.plist"))
    return (rc == 1 and "plist é symlink" in out and "chave Program" in out and "plutil -lint recusou" in out and untouched and os.path.islink(f"{d}/com.gascity.link-l.plist")
            and hashlib.sha256(open(real, "rb").read()).hexdigest() == realsum and "4 embrulhado(s), 3 falha(s)" in out)


def c_only_canary():
    d = fixture("only"); before = snap(d); pol = policy(); one = "com.gascity.reaper-a"
    rc, out, _ = run(["--apply", "--only", one], d, pol, bk=f"{T}/bk-only")
    after = snap(d)
    changed = {n for n in after if after[n] != before[n]}
    if rc != 0 or "1 embrulhado(s)" not in out or changed != {f"{one}.plist"}:
        return False
    bad = [run(["--apply", "--only", "com.gascity.nope"], d, pol)[0], run(["--apply", "--only", "com.gascity.keepalive-c"], d, pol)[0], run(["--revert", "--only", "com.gascity.nope"], d)[0]]
    if bad != [2, 2, 2] or snap(d) != after:
        return False
    rc2, out2, _ = run(["--revert", "--only", "com.gascity.py-d"], d, bk=f"{T}/bk-only2")   # py-d não está embrulhado: nada a reverter, e o resto continua
    rc3, out3, _ = run(["--revert", "--only", one], d, bk=f"{T}/bk-only3")
    return rc2 == 0 and "0 revertido(s)" in out2 and rc3 == 0 and "1 revertido(s)" in out3 and snap(d) == before


def c_wrapper_gone():
    d = fixture("gone"); w2 = f"{T}/w2.sh"; shutil.copy(WRAPPER, w2); os.chmod(w2, 0o755)
    rc, _, _ = run(["--apply"], d, wrapper=w2, bk=f"{T}/bk-gone")
    ok_before = run([], d, wrapper=w2)[0]
    os.rename(w2, w2 + ".gone")
    rc2, out2, _ = run([], d, wrapper=w2)
    return rc == 0 and ok_before == 0 and rc2 == 1 and "JÁ embrulhado(s) apontam para" in out2 and "NÃO vão subir" in out2


SUITE = [
    (c_plan_readonly, "plano é só leitura; medição separa chamada de texto (b.sh = TALVEZ); script direto é lido; script citado e ausente = ILEGÍVEL; escopo; ilegível; plutil; contagens"),
    (c_apply_revert, "--apply exato + chaves/ordem + backup byte a byte + idempotente; --revert devolve o original e é idempotente"),
    (c_refuse_divergence, "job fora da política → exit 1 e --apply recusa sem escrever nada"),
    (c_refuse_wrapper, "wrapper ausente / não executável / sintaxe ruim → exit 4 sem escrever nada"),
    (c_wrap_keepalive, "wrap em KeepAlive → divergência e --apply recusa"),
    (c_wrap_without_reading, "wrap sem chamada medida → divergência e --apply recusa"),
    (c_duplicate_label, "label em 2 arquivos → divergência e --apply recusa"),
    (c_policy_errors, "política ilegível / decisão desconhecida / label repetido / pasta ausente → exit 3"),
    (c_usage, "uso errado → exit 2"),
    (c_skips, "symlink, chave Program e plutil -lint recusado não são alterados (e o resto é)"),
    (c_only_canary, "--only: só o label pedido muda (apply e revert); label inexistente/isento = exit 2 sem escrever"),
    (c_wrapper_gone, "plist já embrulhado + wrapper sumido → divergência que diz que os jobs NÃO vão subir"),
]
MUTANTS = [   # (nome, expressão sed, cenário)
    ("aplica-com-divergencia", "/GUARD:apply-refuses-divergence/ s/if div:/if False:/", c_refuse_divergence),
    ("sem-preflight-do-wrapper", "/GUARD:wrapper-preflight/ s/if not ok:/if False:/", c_refuse_wrapper),
    ("embrulha-duas-vezes", r"/GUARD:idempotent/ s/ and not r\[\"wrapped\"\] and / and /", c_apply_revert),
    ("texto-conta-como-chamada", "/GUARD:code-only/ s/code = line if py else code_only(line)/code = line/", c_plan_readonly),
    ("wrap-em-keepalive-passa", r"/GUARD:wrap-keepalive/ s/elif dec == \"wrap\" and r\[\"keepalive\"\]:/elif False:/", c_wrap_keepalive),
    ("symlink-reescrito", "/GUARD:symlink/ s/if row\\[\"link\"\\]:/if False:/", c_skips),
    ("chave-Program-reescrita", "/GUARD:program-key/ s/if \"Program\" in d:/if False:/", c_skips),
    ("sem-backup", "/GUARD:backup/ s/shutil.copy2(path, bak)/pass/", c_apply_revert),
    ("lint-ignorado", "/GUARD:lint/ s/if lint.returncode != 0:/if False:/", c_skips),
    ("politica-repetida-passa", "/GUARD:policy-dup/ s/if parts\\[0\\].strip() in pol:/if False:/", c_policy_errors),
    ("label-duplicado-passa", "/GUARD:dup-label/ s/if len(fs) > 1:/if False:/", c_duplicate_label),
    ("only-desconhecido-passa", "/GUARD:only-unknown/ s/if .*:   # GUARD/if False:   # GUARD/", c_only_canary),
    ("wrapper-sumido-passa", "/GUARD:wrapper-missing-div/ s/if wrapped and not (.*):/if False:/", c_wrapper_gone),
    ("direto-nao-e-lido", "/GUARD:direct-exec/ s/if args\\[0\\]/if False and args[0]/", c_plan_readonly),
    ("citado-ausente-vira-sem-mencao", "/GUARD:named-missing/ s/unreadable += p in named/pass/", c_plan_readonly),
    ("revert-erra-o-corte", "/GUARD:inner-strip/ s/args.index(\"--\") + 1:/args.index(\"--\"):/", c_apply_revert),
]


def main():
    fails = n = 0

    def ok(passed, msg):
        nonlocal fails, n
        n += 1
        print(("ok   " if passed else "FAIL ") + msg)
        fails += not passed
    if not os.path.isfile(TOOL):
        print(f"FAIL o script a testar não existe: {TOOL}")
        return 1
    for fn, desc in SUITE:
        try:
            ok(bool(fn()), desc)
        except Exception as e:  # noqa: BLE001
            ok(False, f"{desc} — exceção {type(e).__name__}: {e}")
    if os.environ.get("WFDP_NO_MUTANTS") != "1":
        src = open(TOOL, encoding="utf-8").read()
        os.makedirs(f"{T}/mut", exist_ok=True)
        for name, expr, fn in MUTANTS:
            mpath = f"{T}/mut/wait-for-dolt-plan.py"
            r = subprocess.run(["sed", expr, TOOL], capture_output=True, text=True)
            open(mpath, "w", encoding="utf-8").write(r.stdout)
            if r.stdout == src:
                ok(False, f"mutante {name}: o sed NÃO mudou o script (mutante vazio)")
                continue
            try:   # mutante com erro de sintaxe "morre" por qualquer motivo e não prova a guarda: não saber rodar ≠ ter reprovado
                compile(r.stdout, mpath, "exec")
            except SyntaxError:
                ok(False, f"mutante {name}: o sed produziu python inválido (morte por sintaxe não prova a guarda)")
                continue
            saved = globals()["TOOL"]
            globals()["TOOL"] = mpath
            try:
                passed = bool(fn())
            except Exception:  # noqa: BLE001
                passed = False
            globals()["TOOL"] = saved
            ok(not passed, f"mutante {name} reprova {fn.__name__}" if not passed else f"mutante {name} SOBREVIVEU a {fn.__name__}")
    print(f"{n} casos, {fails} falha(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
