#!/usr/bin/env python3
"""hetzner-ballast-wa-suite-mem-probe.py — mede NO nó a memória do item wa-suite numa rodada manual igual à dele: soma de RSS (a conta do governo, hetzner-ballast.py running_items) contra soma de PSS
(smaps_rollup) da sessão, a cada tick, mais o MemAvailable do nó e o progresso do pytest (ga-weaih6).

Contents
  Por quê · Uso · Saída · Segurança · Limites

POR QUÊ: o `rss_mb` da linha wa-suite do registro é o teto que o governo cobra (passou, termina com `why=rss`) e também o que entra na conta de partida (`MemAvailable − rss_mb ≥ ram_start_mb`). Ele é um número
  MEDIDO, e a suíte do WA cresce: quando as rodadas voltarem a morrer por `rss`, ou antes de mexer nos núcleos, rode isto e reponha o número (docs/runbooks/hetzner-ballast.md, "Medido"; o teste
  hetzner-ballast-wa-suite.selftest.sh, grupo reg, fixa a conta núcleos × MB por worker + base ≤ rss_mb).
USO (do mini; leva ~1 h a 5 núcleos, então SEMPRE solto do ssh):
  scp scripts/hetzner-ballast-wa-suite-mem-probe.py hetzner-teste:gt-remote/measure/probe.py
  ssh hetzner-teste 'mkdir -p ~/gt-remote/measure/r1 && ( nohup setsid python3 -I ~/gt-remote/measure/probe.py ~/gt-remote/measure/r1 5 7200 > ~/gt-remote/measure/r1.log 2>&1 < /dev/null & )'
  argumentos: <pasta-de-saida> [nucleos=8] [limite_s=900]; a última linha do .log é `probe: fim: …` (a rodada acabou).
SAÍDA: samples.jsonl (1 linha por tick: soma de RSS/PSS, PSS anon/arquivo/shmem, Shared/Private, MemAvailable, `pct` do pytest, os 10 maiores processos) · pytest.out · rc.
  Leitura: pico de `rss_statm_mb` (o que o governo soma) contra o de `pss_mb`; se PSS ≈ RSS a memória é REAL (não é fork compartilhado contado em dobro) e o ajuste é nos núcleos/`rss_mb`, não na conta.
SEGURANÇA: só roda se o canário do gt-iso-run disser `GTN-ISO: isolado` (a suíte do WA toca APIs de terceiros; a rede cortada é o que a torna inofensiva); só sinaliza a PRÓPRIA sessão (sid == o líder que
  lançou), nunca por nome; aborta e termina a própria sessão se MemAvailable < 8000 MB (o governo pausa em 10240: rode com o lastro ligado e o nó dividido só sabendo disso).
LIMITES: árvore PRÓPRIA (`ballast-wa-probe`; o item usa `ballast-wa` e o wt-rm dele apagaria a minha) no origin/main do espelho; não grava baseline nem trava do item (wa-suite.last/.failed/.leak ficam como
  estão) e não passa pelo governo (nem pela crontab, nem pelo registro). Mede UMA rodada: o pico depende do commit do WA e do quanto da suíte já correu (`pct`).
"""
import json, os, re, signal, subprocess, sys, time

HOME = os.path.expanduser("~")
GR = os.environ.get("GT_REMOTE_GIT", HOME + "/gt-remote/git")
RIG, NAME = "whatsapp_automation", "ballast-wa-probe"
RG, ISO, PYV = HOME + "/gt-remote/bin/hetzner-remote-git.sh", HOME + "/gt-remote/bin/gt-iso-run", HOME + "/gt-remote/venv-wa/bin/python"
MIN_AVAIL_MB = 8000
OUT_PYTEST = ""
PAGE_KB = os.sysconf("SC_PAGE_SIZE") // 1024


def log(msg):
    print("%s probe: %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def mem_avail_mb():
    # vazio (sem a linha MemAvailable) → None; falhou/ilegível → None. None NÃO é "tem RAM": o chamador trata como "não sei" e aborta a rodada (estado inerte)
    try:
        with open("/proc/meminfo") as f:
            for ln in f:
                if ln.startswith("MemAvailable:"):
                    return int(ln.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        return None
    return None


def rollup(pid):
    # vazio (sem a chave Pss) → None; falhou (processo sumiu, EACCES no de root) → None: o processo entra na soma de RSS (statm) mas conta em `sem_pss`
    d = {}
    try:
        with open("/proc/%d/smaps_rollup" % pid) as f:
            for ln in f:
                k, _, v = ln.partition(":")
                p = v.split()
                if p and p[-1] == "kB":
                    d[k] = int(p[0])
    except (OSError, ValueError):
        return None
    return d if "Pss" in d else None


def suite_pct():
    # vazio (nenhuma linha "[ NN%]" ainda: coleta em curso) → None; falhou/ilegível (arquivo que não abre) → None. None = "sem progresso lido", nunca 0%
    try:
        with open(OUT_PYTEST, "rb") as f:
            f.seek(0, 2); f.seek(max(0, f.tell() - 4096))
            m = re.findall(r"\[\s*(\d+)%\]", f.read().decode("utf-8", "replace"))
    except OSError:
        return None
    return int(m[-1]) if m else None


def session_procs(sid):
    """[(pid, estado, rss_kb_statm, cmd)] dos membros VIVOS da sessão `sid` (mesma leitura do governo: stat campo 6, statm campo 2, zumbi fora)."""
    out = []
    # vazio (nada listado) → []; falhou/ilegível (/proc não abre) → exceção sobe: a rodada é abortada, nunca lida como "ninguém roda"
    for nm in os.listdir("/proc"):
        if not nm.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % nm, "rb") as f:
                data = f.read().decode("utf-8", "replace")
            rest = data[data.rindex(")") + 2:].split()
            st, psid = rest[0], int(rest[3])
            if psid != sid or st == "Z":
                continue
            with open("/proc/%s/statm" % nm) as f:
                rss = int(f.read().split()[1]) * PAGE_KB
            with open("/proc/%s/cmdline" % nm, "rb") as f:
                cmd = f.read().decode("utf-8", "replace").replace("\0", " ")[:110]
        except (OSError, ValueError, IndexError):
            continue          # sumiu no meio da leitura: ignorado, como no governo
        out.append((int(nm), st, rss, cmd))
    return out


def sample(sid, t):
    ms = session_procs(sid)
    agg = {"rss_statm_kb": 0, "rss_roll_kb": 0, "pss_kb": 0, "pss_anon_kb": 0, "pss_file_kb": 0, "pss_shmem_kb": 0, "shared_kb": 0, "private_kb": 0}
    rows, sem_pss = [], 0
    for pid, st, rss, cmd in ms:
        agg["rss_statm_kb"] += rss
        r = rollup(pid)
        row = {"pid": pid, "st": st, "rss_mb": rss // 1024, "cmd": cmd}
        if r is None:
            sem_pss += 1
        else:
            agg["rss_roll_kb"] += r.get("Rss", 0)
            agg["pss_kb"] += r["Pss"]
            agg["pss_anon_kb"] += r.get("Pss_Anon", 0)
            agg["pss_file_kb"] += r.get("Pss_File", 0)
            agg["pss_shmem_kb"] += r.get("Pss_Shmem", 0)
            agg["shared_kb"] += r.get("Shared_Clean", 0) + r.get("Shared_Dirty", 0)
            agg["private_kb"] += r.get("Private_Clean", 0) + r.get("Private_Dirty", 0)
            row["pss_mb"] = r["Pss"] // 1024
        rows.append(row)
    rows.sort(key=lambda x: -x["rss_mb"])
    line = {"t": t, "n": len(ms), "sem_pss": sem_pss, "workers": sum(1 for _, _, _, c in ms if "execnet" in c or "popen" in c or "xdist" in c),
            "avail_mb": mem_avail_mb()}
    line.update({k.replace("_kb", "_mb"): v // 1024 for k, v in agg.items()})
    line["top"] = rows[:10]
    line["pct"] = suite_pct()
    return line


def stop_session(sid, why):
    """TERM em cada membro da PRÓPRIA sessão, KILL 20 s depois nos que sobraram. Só por sid: nunca por nome (o `sleep 300` da 1ª medição do signal-proof matou 828 processos alheios)."""
    log("encerrando a sessão %d (%s)" % (sid, why))
    for sig, wait in ((signal.SIGTERM, 20), (signal.SIGKILL, 5)):
        for pid, _, _, _ in session_procs(sid):
            try:
                os.kill(pid, sig)
            except OSError:
                pass          # EPERM no bash de root do helper: sai sozinho quando o filho sai (medido no signal-proof)
        end = time.time() + wait
        while time.time() < end:
            if not session_procs(sid):
                return
            time.sleep(1)


def main():
    out = os.path.abspath(sys.argv[1])
    cores = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 900
    os.makedirs(out, exist_ok=True)
    # canário: vazio/ilegível/qualquer coisa ≠ `isolado` → NÃO roda (a suíte sem rede cortada pode tocar API de terceiro)
    # vazio (sem linha GTN-ISO) → first "" → não roda; falhou/ilegível (gt-iso-run ausente, sem permissão, pendurado) → não roda: "não consegui provar" nunca vira "isolado"
    try:
        can = subprocess.run([ISO, "--canary"], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        log("canário não rodou (%s): nada roda" % e); return 3
    first = next((ln for ln in can.stdout.splitlines() if ln.startswith("GTN-ISO: ")), "")
    log("canário: %s" % (first or "(sem linha GTN-ISO)"))
    if not first.startswith("GTN-ISO: isolado"):
        log("isolamento NÃO provado: nada roda"); return 3
    wt = "%s/%s/wt/%s" % (GR, RIG, NAME)
    if os.path.exists(wt):
        subprocess.run([RG, "wt-rm", RIG, NAME], capture_output=True)          # sobra de uma medição minha anterior (nome só meu)
    subprocess.run(["git", "-C", "%s/%s/repo.git" % (GR, RIG), "branch", "-D", "worker/" + NAME], capture_output=True)
    add = subprocess.run([RG, "wt-add", RIG, NAME, "main"], capture_output=True, text=True, timeout=900)
    if add.returncode != 0 or not os.path.isdir(wt + "/tests"):
        log("wt-add falhou: %s" % (add.stdout + add.stderr)[-200:]); return 3
    head = subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    log("árvore %s em %s" % (wt, head[:9]))
    env = dict(os.environ, PATH=HOME + "/.local/bin:" + os.environ["PATH"], PYTHONDONTWRITEBYTECODE="1", GTN_WORKERS=str(cores), MEASURE_DIR=out)
    argv = ["sh", "-c", '{ echo 1000 > /proc/self/oom_score_adj; } 2>/dev/null; "$@"; echo $? > "$MEASURE_DIR/rc"', "ballast-measure:" + NAME,
            "nice", "-n", "19", "chrt", "-i", "0", "ionice", "-c", "3", "timeout", "-k", "30", str(limit + 120),
            ISO, "--", PYV, "-m", "pytest", "-p", "no:cacheprovider", "tests/", "-n", str(cores), "-p", "gtn_stable_ids", "--timeout=900", "-q", "-rfE", "--tb=line",
            "--continue-on-collection-errors"]
    global OUT_PYTEST
    OUT_PYTEST = out + "/pytest.out"
    po = open(OUT_PYTEST, "wb")
    p = subprocess.Popen(argv, cwd=wt, env=env, stdin=subprocess.DEVNULL, stdout=po, stderr=subprocess.STDOUT, start_new_session=True)
    sid = p.pid
    t0 = time.time()
    log("pytest lançado: sessão %d, %d núcleos, limite %d s" % (sid, cores, limit))
    why = "fim-do-limite"
    try:
        with open(out + "/samples.jsonl", "w") as sf:
            while True:
                t = int(time.time() - t0)
                s = sample(sid, t)
                sf.write(json.dumps(s) + "\n"); sf.flush()
                if s["n"] == 0:
                    why = "pytest-terminou"; break
                if s["avail_mb"] is None or s["avail_mb"] < MIN_AVAIL_MB:
                    why = "abortado-ram (MemAvailable=%s MB)" % s["avail_mb"]; break
                if t >= limit:
                    break
                time.sleep(10 if t < 600 else 30)
    finally:
        if session_procs(sid):
            stop_session(sid, why)
        po.close()
        r = subprocess.run([RG, "wt-rm", RIG, NAME], capture_output=True, text=True)
        subprocess.run(["git", "-C", "%s/%s/repo.git" % (GR, RIG), "branch", "-D", "worker/" + NAME], capture_output=True)
        log("fim: %s; wt-rm rc=%d; árvore %s" % (why, r.returncode, "AINDA EXISTE" if os.path.exists(wt) else "removida"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
