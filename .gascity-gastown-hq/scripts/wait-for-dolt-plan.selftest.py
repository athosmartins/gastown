#!/usr/bin/env python3
"""wait-for-dolt-plan.selftest.py — hermético: plists e programas falsos numa pasta de mktemp, `plutil` de mentira, "cidade" de mentira com uma cópia do wait-for-dolt.sh de verdade.
Não lê o ~/Library/LaunchAgents, não chama launchctl. O único caso que usa a política e um plist REAIS usa os do REPO (o vigia de ocupação), copiados para a pasta de mktemp.

Contents
  Casos · Controle negativo (mutantes) · Variáveis

CASOS: plano é SÓ LEITURA (checksum da pasta não muda) e a medição separa chamada de texto (echo/log/jq/comentário/aspas ≠ LÊ), lê o script executado direto e trata script citado que não existe como ILEGÍVEL · 17 formas de chamada
  que já escaparam (timeout com opções, if/elif/while/until/else/{, `echo …; bd`, `printf … | bd`, `echo "$(bd …)"`) e 6 de texto que NÃO são chamada (inclui variável que só parece o binário) · programa do interpretador ausente com outro argumento legível = ILEGÍVEL ·
  escopo (label de fora, programa na árvore de outro rig, RunAtLoad=false) · plist ilegível listado e divergente (--apply recusa) · plist com topo/Label estranho sem traceback · plist que o expat recusa e o plutil aceita · --apply: ProgramArguments novo exato, demais chaves e a ordem delas preservadas, o que não é
  wrap fica byte a byte igual, backup byte a byte do original, idempotente (2ª vez não embrulha de novo) · --revert devolve o original e é idempotente · RECUSAS (nada é escrito): divergência,
  wrapper ausente/não executável/com sintaxe ruim, wrap em KeepAlive, wrap sem chamada medida, label em 2 arquivos · plist symlink / com chave Program / que o plutil -lint recusa não são
  alterados · política ilegível, com decisão desconhecida ou label repetido = exit 3 · uso errado = exit 2 · --revert com plist ilegível (lista e sai 1) · wrapper embrulhado por OUTRO caminho ·
  política × vivo (isento embrulhado, nao-medido que mede LÊ, wrap sem gatilho) · backup (falha de criação sem traceback; --backup-dir reaproveitado não sobrescreve) · sonda ao lado do wrapper · a política REAL do repo isenta o vigia de ocupação (ga-2hd02v.1.17).
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
for lib_dir in (f"{CITY}/scripts", T):   # a sonda que o wrapper carrega fica AO LADO dele (o preflight confere)
    shutil.copy(os.path.join(HERE, "dolt-pid-lib.sh"), lib_dir)
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
open(f"{PROG}/readable.conf", "w").write("x=1\n")
CALL_FORMS = {   # UMA chamada de verdade a bd/gc/dolt por programa: o detector tem que dizer LE (cada forma já escapou da medição uma vez; a 1ª é a do worktree-reaper.sh:498 vivo)
    "tmo-k": 'raw="$(timeout -k "$GRACE" "$LIMIT" gc --city "${CITY:-$GT/.c}" session list --json --state all 2>/dev/null)"; rc=$?\n',
    "tmo-s": 'x=$(timeout -s KILL 5 bd list --json)\n',
    "tmo-long": 'timeout --kill-after=5 --foreground 10 dolt sql -q x\n',
    "if": 'if bd show "$1" >/dev/null 2>&1; then\n  :\nfi\n',
    "elif": 'if [ -z "$1" ]; then\n  :\nelif gc rig list >/dev/null 2>&1; then\n  :\nfi\n',
    "while": 'while bd list --json | grep -q x; do sleep 1; done\n',
    "until": 'until dolt sql -q "select 1" >/dev/null 2>&1; do sleep 1; done\n',
    "else": 'if [ -z "$1" ]; then :; else bd list --json; fi\n',
    "brace": 'f() { bd list --json; }\n',
    "echo-semi": 'echo "go"; bd list --json\n',
    "printf-pipe": 'printf "%s" "$body" | bd update "$id" --body-file -\n',
    "log-and": 'log "start" && gc nudge x\n',
    "echo-subst": 'echo "ids: $(bd list --json)"\n',
    "var-local": '_bd="${LCA_BD:-bd}"\nout=$("$_bd" -C "$store" list --status open --json)\n',   # lifecycle-correctness-auditor.sh:379 vivo: o alias local do binário
    "var-prefixed": '( cd "$C" && GC_CITY="$C" "$LCA_GC" mail send mayor -s x )\n',
    "var-braced": 'if ${MY_BD_BIN} show "$1" >/dev/null; then :; fi\n',
    "env-prefix": 'FOO=1 BAR="a b" BAZ=$HOME/x bd list --json\n',   # `VAR=x cmd` continua sendo chamada
}
NOT_CALLS = {   # (estado esperado, corpo): texto que cita bd/gc/dolt sem chamar continua TALVEZ, e variável que só PARECE o binário (GC_CITY, BDIR) continua NAO-ACHEI: o detector não pode virar "tudo que parece é chamada"
    "log-then": ("TALVEZ", 'echo it was fine then bd list failed\n'),
    "log-quoted": ("TALVEZ", 'echo "if bd list fails"; warn "while gc is down"\n'),
    "text-var": ("TALVEZ", 'reason="until dolt answers, if bd list hangs"\n'),
    "comment-tail": ("TALVEZ", 'df -h   # if bd list is down, then gc waits\n'),
    "fn-arg": ("NAO-ACHEI", 'if paths=$(rig_paths "$MY_GC" 20 " "); then :; fi\n'),   # git-lock-hygiene.sh:222 vivo: $MY_GC é ARGUMENTO da função, não o comando
    "var-not-bin": ("NAO-ACHEI", 'cd "$GC_CITY" && "$BDIR" run && "$MYGC" x && ls "$HOME_DB"\n'),
}
for name, body in {**{f"f-{k}": v for k, v in CALL_FORMS.items()}, **{f"n-{k}": v[1] for k, v in NOT_CALLS.items()}}.items():
    open(f"{PROG}/{name}.sh", "w").write("#!/bin/bash\n" + body)


def plist(d, label, args, **kw):
    data = {"Label": label, "ProgramArguments": args, "RunAtLoad": True}
    data.update(kw)
    with open(f"{d}/{label}.plist", "wb") as fh:
        plistlib.dump(data, fh, sort_keys=False)


def fixture(name, garbage=True):
    """Pasta nova de LaunchAgents falsos (uma por cenário, para um não sujar o outro). garbage=False: sem o plist ilegível (cenários do caminho limpo)."""
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
    if garbage:
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
com.gascity.direct-p\tisento\tp
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


def states(d):
    """→ {rótulo sem o prefixo: estado medido} de todo job do escopo. Política vazia: cada job vira "NÃO CLASSIFICADO … [ESTADO gatilho]", que carrega o estado medido sem depender de decisão."""
    out = run([], d, policy("# vazia: todo job vira NÃO CLASSIFICADO e mostra o estado medido\n"))[1]
    return dict(re.findall(r"NÃO CLASSIFICADO \(fora da política\): com\.gascity\.(\S+) \[(\S+)", out))


def same(got, want):
    if got != want and os.environ.get("WFDP_DEBUG"):
        print("   got ≠ want:", {k: (got.get(k), want.get(k)) for k in sorted(set(got) | set(want)) if got.get(k) != want.get(k)}, file=sys.stderr)
    return got == want


# ---- cenários (cada um devolve True = passou; a suíte e os mutantes usam as mesmas funções)
def c_plan_readonly():
    d = fixture("plan"); before = snap(d)
    rc, out, _ = run([], d)                          # o fixture traz o garbage.plist: ilegível = divergência (exit 1), mas o plano sai inteiro
    return (rc == 1 and snap(d) == before and "medido (escopo HQ): LE=6 · TALVEZ=1 · NAO-ACHEI=1 · ILEGIVEL=2" in out and "garbage.plist" in out
            and out.count("A EMBRULHAR") == 4 and "com.other.f" in out.split("== FORA DO ESCOPO")[1] and "otherrig-g" in out.split("== FORA DO ESCOPO")[1]
            and "norun-h" not in out and "política: wrap=4 · isento=2 · nao-medido=4 · embrulhados hoje: 0 de 4" in out
            and "direct-p [LE]" in out and "gone-q [ILEGIVEL]" in out)


def c_apply_revert():
    d = fixture("ar", garbage=False); orig = {l: prog_of(d, l) for l in WRAP_LABELS}; keys = {l: list(load(d, l)) for l in WRAP_LABELS}; before = snap(d); bk = f"{T}/bk-ar"; pol = policy()
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
    d = fixture("wr", garbage=False); before = snap(d); res = []   # sem plist ilegível: ele recusaria antes (exit 1) e o preflight do wrapper (exit 4) nem seria testado
    res.append(run(["--apply"], d, wrapper=f"{T}/nao-existe.sh")[0])
    noexec = f"{T}/noexec.sh"; shutil.copy(WRAPPER, noexec); os.chmod(noexec, 0o644)
    res.append(run(["--apply"], d, wrapper=noexec)[0])
    bad = f"{T}/bad.sh"; open(bad, "w").write("#!/bin/bash\nif then fi\n"); os.chmod(bad, 0o755)
    res.append(run(["--apply"], d, wrapper=bad)[0])
    nolib = f"{T}/nolib/wait-for-dolt.sh"; os.makedirs(os.path.dirname(nolib)); shutil.copy(WRAPPER, nolib); os.chmod(nolib, 0o755)   # wrapper são, sem a sonda ao lado: todo job sairia 76
    res.append(run(["--apply"], d, wrapper=nolib)[0])
    return res == [4, 4, 4, 4] and snap(d) == before


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
    d = fixture("sk", garbage=False); real = f"{T}/real-l.plist"
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
    d = fixture("only", garbage=False); before = snap(d); pol = policy(); one = "com.gascity.reaper-a"
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
    d = fixture("gone", garbage=False); w2 = f"{T}/w2.sh"; shutil.copy(WRAPPER, w2); os.chmod(w2, 0o755)
    rc, _, _ = run(["--apply"], d, wrapper=w2, bk=f"{T}/bk-gone")
    ok_before = run([], d, wrapper=w2)[0]
    os.rename(w2, w2 + ".gone")
    rc2, out2, _ = run([], d, wrapper=w2)
    return rc == 0 and ok_before == 0 and rc2 == 1 and "JÁ embrulhado(s) apontam para" in out2 and "NÃO vão subir" in out2


def c_revert_unreadable():
    d = fixture("rv", garbage=False); orig = {l: prog_of(d, l) for l in WRAP_LABELS}
    applied = run(["--apply"], d, bk=f"{T}/bk-rv")[0] == 0
    open(f"{d}/garbage.plist", "wb").write(b"\x00\x01 isto nao e plist")   # só agora aparece o ilegível: não sei se está embrulhado
    rc, out, _ = run(["--revert"], d, bk=f"{T}/bk-rv2")
    return applied and rc == 1 and "NÃO LI garbage.plist" in out and "4 revertido(s)" in out and all(prog_of(d, l) == orig[l] for l in WRAP_LABELS)


def c_wrapper_other_path():
    d = fixture("op", garbage=False); orig = {l: prog_of(d, l) for l in WRAP_LABELS}; other_dir = f"{T}/other"; other = f"{other_dir}/wait-for-dolt.sh"
    os.makedirs(other_dir); [shutil.copy(os.path.join(HERE, f), other_dir) for f in ("wait-for-dolt.sh", "dolt-pid-lib.sh")]; os.chmod(other, 0o755)
    applied = run(["--apply"], d, wrapper=other, bk=f"{T}/bk-op")[0] == 0
    rc, out, _ = run([], d)                         # plano com o wrapper PADRÃO: os 4 são embrulhados (por outro caminho), não "a embrulhar"
    rc2, _, _ = run(["--apply"], d)                  # e não se embrulha por cima
    shutil.rmtree(other_dir)
    rc3, out3, _ = run([], d)                        # o wrapper do outro caminho sumiu: os jobs não sobem
    rc4, _, _ = run(["--revert"], d, bk=f"{T}/bk-op2")
    return (applied and rc == 1 and "OUTRO caminho" in out and out.count("JÁ EMBRULHADO") == 4 and "A EMBRULHAR" not in out and rc2 == 1
            and rc3 == 1 and "NÃO vão subir" in out3 and rc4 == 0 and all(prog_of(d, l) == orig[l] for l in WRAP_LABELS))


def c_policy_vs_live():
    d = fixture("pv", garbage=False); a = ["/bin/bash", f"{PROG}/a.sh"]
    plist(d, "com.gascity.once-r", a)                                                                                              # só RunAtLoad: sem gatilho de re-disparo
    plist(d, "com.gascity.pre-s", [WRAPPER, "--timeout", "300", "--boot-window", "900", "--"] + a, StartInterval=60)                 # já embrulhado
    plist(d, "com.gascity.lia-t", a, StartInterval=60)                                                                             # a medição acha chamada (LE)
    pol = policy(BASE_POLICY + "com.gascity.once-r\twrap\tr\ncom.gascity.pre-s\tisento\ts\ncom.gascity.lia-t\tnao-medido\tt\n"); before = snap(d)
    rc, out, _ = run([], d, pol); rc2, _, _ = run(["--apply"], d, pol)
    return (rc == 1 and "DIVERGÊNCIAS (3)" in out and "wrap sem gatilho de re-disparo: com.gascity.once-r" in out and "isento mas já embrulhado: com.gascity.pre-s" in out
            and "nao-medido mas a medição achou chamada (LE): com.gascity.lia-t" in out and rc2 == 1 and snap(d) == before)


def c_backup_safety():
    d = fixture("bs", garbage=False); before = snap(d); pol = policy(); blocker = f"{T}/arquivo-no-caminho"; open(blocker, "w").write("x")
    rc, out, err = run(["--apply"], d, pol, bk=f"{blocker}/sub")   # o backup não pode ser criado: sem traceback, falha por plist, nada escrito
    first = rc == 1 and "Traceback" not in err and "4 falha(s)" in out and snap(d) == before
    bk = f"{T}/bk-bs"; applied = run(["--apply"], d, pol, bk=bk)[0] == 0; wrapped = snap(d)
    rc2, out2, _ = run(["--revert"], d, bk=bk)                     # mesmo --backup-dir: não sobrescreve o original guardado
    return (first and applied and rc2 == 1 and "backup já existe" in out2 and snap(d) == wrapped and len(os.listdir(bk)) == 4
            and all(hashlib.sha256(open(f"{bk}/{n}", "rb").read()).hexdigest() == before[n] for n in os.listdir(bk)))


def c_call_forms():
    d = f"{T}/la-forms"; os.makedirs(d)
    for name in [f"f-{k}" for k in CALL_FORMS] + [f"n-{k}" for k in NOT_CALLS]:
        plist(d, f"com.gascity.{name}", ["/bin/bash", f"{PROG}/{name}.sh"], StartInterval=60)
    return same(states(d), {**{f"f-{k}": "LE" for k in CALL_FORMS}, **{f"n-{k}": v[0] for k, v in NOT_CALLS.items()}})


def c_unread_program():
    d = f"{T}/la-unread"; os.makedirs(d); conf = f"{PROG}/readable.conf"
    plist(d, "com.gascity.sh-miss", ["/bin/bash", f"{PROG}/nao-existe.sh", conf], StartInterval=60)                  # o programa (args[1]) some e há OUTRO argumento legível: não sei, ≠ sem menção
    plist(d, "com.gascity.py-miss", ["/usr/bin/python3", f"{PROG}/nao-existe.py", conf], StartInterval=60)
    plist(d, "com.gascity.sh-ok", ["/bin/bash", f"{PROG}/n.sh", conf], StartInterval=60)                              # controle: o programa existe e não menciona → NAO-ACHEI
    plist(d, "com.gascity.sh-data", ["/bin/bash", f"{PROG}/n.sh", f"{PROG}/dado-ausente.dat"], StartInterval=60)     # controle: argumento que não é o programa, ausente ali não conta
    return same(states(d), {"sh-miss": "ILEGIVEL", "py-miss": "ILEGIVEL", "sh-ok": "NAO-ACHEI", "sh-data": "NAO-ACHEI"})


def c_odd_plists():
    d = fixture("odd", garbage=False)
    plistlib.dump(["isto", "e", "uma", "lista"], open(f"{d}/array.plist", "wb"))                                      # topo que não é dicionário
    plistlib.dump({"Label": 5, "RunAtLoad": True, "ProgramArguments": ["/bin/true"]}, open(f"{d}/label-int.plist", "wb"))   # Label que não é texto
    rc, out, err = run([], d)
    head = out.splitlines()[0]
    return (rc == 1 and "Traceback" not in err and "2 ilegíveis" in head and "ILEGÍVEL (plist não lido, fica fora da conta): array.plist" in out
            and "label-int.plist" in out and out.count("A EMBRULHAR") == 4 and "plist(s) não lido(s)" in out)   # os outros 4 jobs continuam planejados


def c_unreadable_refuses_apply():
    d = fixture("bad"); before = snap(d)                                       # o fixture traz garbage.plist: pode ser o gêmeo de um label wrap, e não sei
    rc, out, _ = run([], d); rc2, _, err2 = run(["--apply"], d)
    div = out.split("== DIVERGÊNCIAS")[1]
    return rc == 1 and "(1) ==" in div and "plist(s) não lido(s) (garbage.plist)" in div and rc2 == 1 and "RECUSADO" in err2 and snap(d) == before


def c_real_policy_hetzner_occupancy():
    """ga-2hd02v.1.17: a política REAL do repo (não a BASE_POLICY de teste) isenta o vigia de ocupação. O plist é o do repo, copiado para uma pasta de mktemp. Sem a linha
    isento o mesmo plano diz "NÃO CLASSIFICADO (fora da política)" para o job que o Mayor instalou. Os outros rótulos da política real não têm plist aqui: o exit é 1 nos dois casos, por isso o que vale é a saída."""
    label = "com.gascity.hetzner-occupancy-watch"
    pol, src = os.path.join(HERE, "wait-for-dolt.policy.tsv"), os.path.join(HERE, f"{label}.plist")
    # vazio → arquivo existente e vazio cai no regex abaixo e reprova; falhou/ilegível → política ou plist ausente: reprova aqui, limpo, em vez de uma exceção do shutil.copy
    if not (os.path.isfile(pol) and os.path.isfile(src)):
        return False
    d = f"{T}/la-real-hetzner"
    os.makedirs(d)
    shutil.copy(src, d)
    out = run([], d, pol)[1]
    # vazio → sem a seção ISENTOS, m é None e o caso reprova; falhou/ilegível → traceback ou saída sem o plano, m é None e reprova (timeout vira exceção, que a SUITE conta como FAIL); nunca "isento por falta de dado"
    m = re.search(r"== ISENTOS \((\d+)\) ==\n(.*?)(?=\n== |\Z)", out, re.S)
    return bool(m) and m.group(1) == "1" and m.group(2).startswith(f"{label} [") and f"NÃO CLASSIFICADO (fora da política): {label}" not in out


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
    (c_revert_unreadable, "--revert lista o plist que não leu (não sei se está embrulhado), sai 1 e reverte os que leu"),
    (c_wrapper_other_path, "embrulhado por OUTRO caminho do wrapper: reconhecido (não embrulha por cima), divergência, sumido = NÃO vão subir, revert tira"),
    (c_policy_vs_live, "política × vivo além do wrap: isento já embrulhado, nao-medido com LE, wrap sem gatilho de re-disparo → divergência"),
    (c_backup_safety, "backup que não dá para criar → falha por plist sem traceback; --backup-dir reaproveitado não sobrescreve o original"),
    (c_call_forms, "17 formas de chamada (timeout com opções, if/elif/while/until/else/{, echo; bd, printf | bd, echo \"$(bd)\", $_bd/$LCA_GC) → LE; texto que só cita → TALVEZ; variável que só parece o binário → NAO-ACHEI"),
    (c_unread_program, "programa (args[1] do interpretador) ausente com outro argumento legível → ILEGÍVEL, não NÃO ACHEI; argumento de dado ausente não conta"),
    (c_odd_plists, "plist com topo que não é dicionário / Label que não é texto → listado como ilegível, sem traceback, o resto do plano sai"),
    (c_unreadable_refuses_apply, "plist que não consegui ler é divergência: o plano sai 1 e --apply recusa sem escrever nada"),
    (c_real_policy_hetzner_occupancy, "a política REAL do repo isenta o vigia de ocupação: o plist do repo cai em ISENTOS e não em NÃO CLASSIFICADO (ga-2hd02v.1.17)"),
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
    ("wrapper-sumido-passa", "/GUARD:wrapper-missing-div/ s/if not (.*):   # GUARD/if False:   # GUARD/", c_wrapper_gone),
    ("direto-nao-e-lido", "/GUARD:direct-exec/ s/if args\\[0\\]/if False and args[0]/", c_plan_readonly),
    ("citado-ausente-vira-sem-mencao", "/GUARD:named-missing/ s/unreadable += p in named/pass/", c_plan_readonly),
    ("revert-erra-o-corte", "/GUARD:inner-strip/ s/args.index(\"--\") + 1:/args.index(\"--\"):/", c_apply_revert),
    ("revert-esconde-ilegivel", "/GUARD:revert-bad/ s/for fn, why in bad:/for fn, why in []:/", c_revert_unreadable),
    ("embrulhado-so-pelo-caminho-exato", "/GUARD:wrapped-by-name/ s/or os.path.basename(args\\[0\\]) == WRAPPER_NAME//", c_wrapper_other_path),
    ("embrulhado-so-pelo-nome", "/GUARD:wrapped-by-name/ s/args\\[0\\] == wrapper or //", c_wrapper_gone),
    ("outro-caminho-do-wrapper-passa", "/GUARD:wrapper-other-path/ s/if p != wrapper:/if False:/", c_wrapper_other_path),
    ("wrap-sem-gatilho-passa", "/GUARD:no-trigger/ s/elif dec == \"wrap\" and not/elif False and not/", c_policy_vs_live),
    ("isento-embrulhado-passa", "/GUARD:iso-wrapped/ s/elif dec != \"wrap\" and/elif False and/", c_policy_vs_live),
    ("nao-medido-com-LE-passa", "/GUARD:nm-le/ s/elif dec == \"nao-medido\" and/elif False and/", c_policy_vs_live),
    ("sobrescreve-backup", "/GUARD:backup-exists/ s/if os.path.exists(bak):/if False:/", c_backup_safety),
    ("falha-de-escrita-sobe-traceback", "/GUARD:write-except/ s/except Exception as e:/except ZeroDivisionError as e:/", c_backup_safety),
    ("sonda-ao-lado-nao-conferida", "/GUARD:lib-preflight/ s/returncode == 0/returncode >= 0/", c_refuse_wrapper),
    ("timeout-so-aceita-um-token", r'/GUARD:timeout-options/ s/^_TMO = r"[^"]*"/_TMO = r"timeout\\s+\\S+\\s+"/', c_call_forms),
    ("palavra-de-controle-nao-ancora", "/GUARD:keyword-anchors/ s/(?:then|do|else|elif|if|while|until)/(?:then|do)/", c_call_forms),
    ("chave-nao-ancora", r'/GUARD:brace-anchor/ s/^_BRACE = r"[^"]*"/_BRACE = r"(?!)"/', c_call_forms),
    ("linha-de-log-inteira-descartada", "/GUARD:log-split/ s/SEGSPLIT.split(code)/[code]/", c_call_forms),
    ("log-descarta-a-substituicao", '/GUARD:log-tail/ s/seg = seg\\[m.start():\\] if m else ""/seg = ""/', c_call_forms),
    ("log-vira-chamada", "/GUARD:log-segment/ s/if LOGCMD.match(seg):/if False:/", c_call_forms),
    ("variavel-binario-so-os-nomes-conhecidos", r'/GUARD:var-binary/ s/^_VARBIN = r"[^"]*"/_VARBIN = r"\\$\\{?(?:BD|GC|DOLT|BD_BIN|GC_BIN|bd_bin|gc_bin)\\}?"/', c_call_forms),
    ("argumento-vira-comando", r'/GUARD:assign-prefix/ s/^_ASSIGN = r"[^"]*"/_ASSIGN = r"\\w+=\\S*\\s+"/', c_call_forms),
    ("interpretador-nao-nomeia-o-programa", "/GUARD:interp-script/ s/if len(args) > 1 and/if False and/", c_unread_program),
    ("plist-estranho-derruba-o-plano", "/GUARD:scan-guard/ s/except Exception as e:/except OSError as e:/", c_odd_plists),
    ("ilegivel-nao-e-divergencia", "/GUARD:bad-div/ s/if bad:/if False:/", c_unreadable_refuses_apply),
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
