#!/usr/bin/env python3
"""hetzner-ballast-signal-proof.py — prova NO NÓ (ga-2hd02v.8) de que o governo do lastro pausa e mata o que roda sob `sudo -n gt-netns-run`.

Contents
  Por quê · Uso · O que prova · Códigos · Limites

POR QUÊ: o item wa-suite roda o pytest dentro do gt-iso-run, e o processo do meio (o bash do helper) é root. A pergunta da bead era se o `runner` ainda consegue pausar (SIGSTOP) e matar (SIGKILL/TERM) o que roda ali.
  Pela leitura do helper (setpriv --reuid) a carga roda com o uid do runner; este script confere NO NÓ, com o gt-iso-run real, em vez de confiar na leitura. Medido pela 1ª vez em 24/10 (runbook hetzner-ballast.md).
USO (do mini): ssh hetzner-teste 'python3 -I -' < scripts/hetzner-ballast-signal-proof.py     (a tabela vem do /proc, a mesma que o governo lê, e não depende de `ps`)
O QUE PROVA, em duas rodadas com um `sleep` inofensivo lançado do jeito do governo (sessão nova, nice 19 + SCHED_IDLE, timeout -k, gt-iso-run -- cmd):
  A pausa e depois KILL: o sleep está NA SESSÃO do item e não é root · SIGSTOP (o send() do governo) deixa parados todos os membros que o runner pode sinalizar · SIGKILL esvazia a sessão, inclusive o bash root
     do helper (que sai sozinho quando o filho sai) · o netns do helper some.
  B pausa e depois TERM+CONT (o terminate() do governo): idem, pelo caminho do prazo.
CÓDIGOS: 0 PROVADO · 1 NÃO PROVADO (uma das condições acima falhou; a linha PROVA: diz qual) · 2 NÃO CONSEGUI MEDIR (sem gt-iso-run, sem /proc, o lançamento falhou): "não consegui" nunca vira "provado" ·
  3 PARCIAL (só com PROOF_ALLOW_NO_HELPER=1, para o selftest: rodou sem o bash root do helper, então NÃO prova a cadeia sudo; nunca sai 0).
VARIÁVEIS (todas só para o selftest; no nó não se usa nenhuma): PROOF_ISO (outro gt-iso-run) · PROOF_APPEAR_S (quanto esperar o sleep aparecer; padrão 30) · PROOF_ALLOW_NO_HELPER=1.
LIMITES: só toca nos processos da PRÓPRIA sessão (sid == o líder que este script lançou), nunca por nome de comando — o nó tem centenas de `sleep` de outras rodadas (incidente de 24/10, ga-2hd02v.8).
  Não usa o governo, a crontab nem o registro; roda com ou sem a chave `on`. Não prova o pytest do WA, só a cadeia de sinais. O send() abaixo é uma CÓPIA do hetzner-ballast.py: o original está fixado
  por hetzner-ballast.selftest.sh (grupo send); aqui se prova que o sinal chega pela cadeia sudo real.
"""
import os
import signal
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
ISO = os.environ.get("PROOF_ISO") or os.path.join(HOME, "gt-remote/bin/gt-iso-run")
MARK = "ballast-item:proof:"
ALLOW_NO_HELPER = os.environ.get("PROOF_ALLOW_NO_HELPER") == "1"
try:
    APPEAR_S = max(1, int(os.environ.get("PROOF_APPEAR_S", "30")))
except ValueError:
    APPEAR_S = 30   # variável que não é inteiro → o padrão, nunca um tempo de espera zerado
problems = []
partial = []


def say(msg):
    print(msg, flush=True)


def table():
    """[{pid, ppid, pgid, sid, state, uid, cmd}] do /proc. Falhou ao ler a pasta = levanta (vira rc 2: não consegui medir)."""
    rows = []
    for nm in os.listdir("/proc"):
        if not nm.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % nm) as f:
                raw = f.read()
            with open("/proc/%s/status" % nm) as f:
                st = f.read()
            with open("/proc/%s/cmdline" % nm, "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        except OSError:
            continue   # o processo sumiu no meio da leitura
        rest = raw[raw.rindex(")") + 2:].split()
        uid = next((l.split()[1] for l in st.splitlines() if l.startswith("Uid:")), "?")   # uid REAL: o sudo é setuid-root mas tem real=runner
        rows.append({"pid": int(nm), "ppid": int(rest[1]), "pgid": int(rest[2]), "sid": int(rest[3]), "state": rest[0], "uid": uid, "cmd": cmd[:110]})
    if not rows:
        raise OSError("/proc sem nenhum processo legível")
    return rows


def members(leader):
    return sorted((r for r in table() if r["sid"] == leader and r["state"] != "Z"), key=lambda r: r["pid"])


def show(leader, title):
    say("== " + title)
    mem = members(leader)
    for r in mem:
        say("  pid=%-8d ppid=%-8d pgid=%-8d uid=%-5s st=%s %s" % (r["pid"], r["ppid"], r["pgid"], r["uid"], r["state"], r["cmd"]))
    if not mem:
        say("  (sessão vazia)")
    return mem


def send(leader, pids, sig):
    """Cópia fiel de send() do hetzner-ballast.py: killpg no líder e os.kill em cada membro; PermissionError por membro é ignorado (é o bash root do helper)."""
    hit = False
    try:
        os.killpg(leader, sig)
        hit = True
    except ProcessLookupError:
        pass
    except PermissionError:
        return False
    for m in pids:
        try:
            os.kill(m, sig)
            hit = True
        except (ProcessLookupError, PermissionError):
            pass
    return hit


def until(pred, secs):
    end = time.time() + secs
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.4)
    return pred()


def launch(tag, dur):
    # vazio/falhou ao lançar → levanta (rc 2): sem sessão lançada não há nada a provar
    wrapper = ["sh", "-c", '{ echo 1000 > /proc/self/oom_score_adj; } 2>/dev/null; "$@"', MARK + tag,
               "nice", "-n", "19", "chrt", "-i", "0", "timeout", "-k", "30", "120", ISO, "--", "sleep", str(dur)]
    return subprocess.Popen(wrapper, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)


def sleeper_of(leader, dur):
    return [r for r in members(leader) if r["cmd"] == "sleep %d" % dur]


def run_phase(name, dur, finish):
    say("")
    say("######## rodada %s ########" % name)
    p = launch(name, dur)
    leader = p.pid
    try:
        # o sleep aparece só depois do canário + do helper montar o netns (alguns segundos)
        if not until(lambda: bool(sleeper_of(leader, dur)), APPEAR_S):
            mem = show(leader, "%s: o sleep NÃO apareceu na sessão do item em %d s" % (name, APPEAR_S))
            outside = [r for r in table() if r["cmd"] == "sleep %d" % dur and r["sid"] != leader]
            problems.append("%s: o sleep não está na sessão do item (o sudo abriu sessão/pty nova, ou o canário recusou?)%s" % (
                name, " — achei %d sleep %d FORA da sessão (não toquei)" % (len(outside), dur) if outside else ""))
            return
        mem = show(leader, "%s.1 sessão do item depois de lançar" % name)
        sl = sleeper_of(leader, dur)[0]
        roots = [r for r in mem if r["uid"] == "0"]
        helper = next((r for r in roots if "gt-netns-run" in r["cmd"]), None)
        say("   sleep: pid=%d uid=%s · membros root na sessão: %s" % (sl["pid"], sl["uid"], [r["pid"] for r in roots]))
        if sl["uid"] == "0":
            problems.append("%s: o sleep roda como ROOT: o runner não consegue sinalizá-lo" % name)
        if helper is None and ALLOW_NO_HELPER:
            partial.append(name)
        elif helper is None:
            problems.append("%s: não achei o bash root do helper na sessão (a cadeia sudo mudou?)" % name)
        ns = "/var/run/netns/gtn%d" % helper["pid"] if helper else None
        if ns and not os.path.exists(ns):
            problems.append("%s: o netns %s não existe com o helper vivo (nome mudou?)" % (name, ns))

        pids = [r["pid"] for r in mem]
        send(leader, pids, signal.SIGSTOP)
        movable = [r["pid"] for r in mem if r["uid"] != "0"]
        stopped = until(lambda: all(r["state"] == "T" for r in members(leader) if r["pid"] in movable), 6)
        mem2 = show(leader, "%s.2 depois de SIGSTOP (o send() do governo)" % name)
        if not stopped:
            problems.append("%s: SIGSTOP não parou todos os membros que o runner pode sinalizar" % name)
        elif not any(r["pid"] == sl["pid"] and r["state"] == "T" for r in mem2):
            problems.append("%s: o sleep não ficou parado (T)" % name)

        finish(leader, [r["pid"] for r in members(leader)])
        gone = until(lambda: not members(leader), 12)
        mem3 = show(leader, "%s.3 depois do fim" % name)
        if not gone:
            problems.append("%s: a sessão NÃO esvaziou em 12 s (restaram %s)" % (name, [r["pid"] for r in mem3]))
        if ns:
            ns_gone = until(lambda: not os.path.exists(ns), 8)
            say("   netns do helper %s: %s" % (os.path.basename(ns), "removido" if ns_gone else "AINDA EXISTE"))
            if not ns_gone:
                problems.append("%s: o netns do helper não foi removido" % name)
    finally:
        # SÓ a sessão que este script lançou (sid == líder). Nunca por nome de comando.
        # vazio → nada a limpar; falhou ao ler o /proc → o OSError sobe e a rodada vira rc 2 (não consegui medir), sem matar nada às cegas
        left = members(leader)
        if left:
            send(leader, [r["pid"] for r in left], signal.SIGKILL)
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


def finish_kill(leader, pids):
    say("   -> send(SIGKILL) com o grupo PARADO (o kill_now() do governo)")
    send(leader, pids, signal.SIGKILL)


def finish_term(leader, pids):
    say("   -> send(SIGTERM) + send(SIGCONT) (o terminate() do governo: um grupo parado não trata o TERM)")
    send(leader, pids, signal.SIGTERM)
    send(leader, pids, signal.SIGCONT)


def main():
    if not (os.path.isfile(ISO) and os.access(ISO, os.X_OK)):
        say("PROVA: NAO-MEDI: falta %s" % ISO)
        return 2
    try:
        table()
    except OSError as e:
        say("PROVA: NAO-MEDI: não consegui ler o /proc (%s)" % e)
        return 2
    say("uid do governo (runner): %d · gt-iso-run: %s" % (os.getuid(), ISO))
    try:
        run_phase("A", 337, finish_kill)
        run_phase("B", 331, finish_term)
    except OSError as e:
        say("PROVA: NAO-MEDI: %s" % e)
        return 2
    except Exception as e:   # defeito deste script (índice, chave…): sairia 1 pelo traceback, que é o código de "NÃO PROVADO"; erro do script não é resultado da medição
        say("PROVA: NAO-MEDI: erro inesperado (%s: %s)" % (type(e).__name__, e))
        return 2
    say("")
    if problems:
        for pr in problems:
            say("PROBLEMA: " + pr)
        say("PROVA: NAO-PROVADO (%d problema(s))" % len(problems))
        return 1
    if partial:
        say("PROVA: PARCIAL — rodei sem o bash root do helper (rodadas %s): a cadeia sudo NÃO foi provada" % ",".join(partial))
        return 3
    say("PROVA: PROVADO — pausa (SIGSTOP) e depois KILL e TERM+CONT esvaziam a sessão pela cadeia sudo real; o único membro que o runner não sinaliza é o bash root do helper, que sai sozinho")
    return 0


if __name__ == "__main__":
    sys.exit(main())
