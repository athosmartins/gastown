#!/usr/bin/env python3
"""hetzner-ballast-hq-selftests-mem-probe.py — mede NO nó a memória do item hq-selftests selftest a selftest, com a MESMA conta do governo (soma de RSS do `statm` da sessão), ao lado da soma
de PSS (smaps_rollup) e do que sobra vivo de cada selftest depois que ele acaba (ga-2hd02v.5.8).

Contents
  Por quê · Uso · Saída · Segurança · Limites

POR QUÊ: o governo (hetzner-ballast.py, running_items) termina o hq-selftests com `why=rss` quando a SOMA de RSS (statm) dos processos da sessão passa de `rss_mb` (4096). Em 02-03/11 isso
  matou 9 de 31 rodadas, sempre depois de ~3700-4000 s, com MemAvailable do nó em 19-28 GB: a soma passou do teto sem o nó estar apertado. A soma de RSS conta página compartilhada (libc, o binário
  do python, mapeamento de arquivo) uma vez POR PROCESSO, e conta também o que um selftest deixa vivo na sessão (órfão que fica até o `orfaos` do governo). Este probe separa as três coisas:
  (a) quem tem RSS grande, (b) quanto disso é PSS (memória que de fato pertence ao processo), (c) quanto fica vivo depois de o selftest acabar.
USO (do mini; leva ~2 h, então SEMPRE solto do ssh):
  scp scripts/hetzner-ballast-hq-selftests-mem-probe.py hetzner-teste:gt-remote/measure/hqprobe.py
  ssh hetzner-teste 'mkdir -p ~/gt-remote/measure/hq1 && ( nohup setsid systemd-run --user --scope --quiet --collect --unit=ballast-hqprobe -p TasksMax=6000 -p MemoryMax=10G -p MemorySwapMax=0 \\
      python3 -I ~/gt-remote/measure/hqprobe.py ~/gt-remote/measure/hq1 [tests.txt] [4] [9000] > ~/gt-remote/measure/hq1.log 2>&1 < /dev/null & )'
  argumentos: <pasta-de-saida> [lista=ordem do item] [trabalhadores=4] [limite_s=9000]; sem `lista`, usa a ordem do item (os mais lentos da última rodada primeiro, hq-selftests.durations).
  A última linha do .log é `probe: fim: …`. rc: 0 = a lista acabou · 3 = nada rodou (trava, wt-add, lista, overlay) · 4 = limite de tempo (sobrou selftest sem medir) · 5 = abortado (RAM ou /proc) · 143 = sinal.
  peaks.json diz também `pull` (ok/falhou: com falhou a árvore é a do clone que havia) e `dropped` (nomes da lista que a árvore não tem); PSS que o smaps_rollup não deixou ler vai como null e o `item_peak` traz `sem_pss` (o PSS somado é PISO).
SAÍDA: samples.jsonl (1 linha por tick: soma de RSS/PSS da sessão inteira, MemAvailable, os 6 selftests de maior RSS e quantos processos cada um deixa vivo depois de acabar) · hot.jsonl (a lista dos
  30 maiores processos sempre que a soma passa de 60% do teto) · peaks.json (por selftest: pico de RSS/PSS/processos, rc, duração, RSS que sobrou vivo no fim; e o pico do item inteiro com a composição) ·
  tests/<nome>.log (a saída de cada selftest). Leitura: o pico do item contra o teto; se RSS >> PSS a conta do governo está inflada por página compartilhada; se o RSS do `leaked` é grande, o selftest vaza.
SEGURANÇA: UMA sonda por vez (trava ~/gt-remote/measure/hqprobe.lock; a 2ª sai com rc 3 sem tocar na árvore da 1ª); só mexe na PRÓPRIA sessão de cada selftest (sid == o líder que lancei), nunca por nome; aborta e termina tudo se MemAvailable < 8000 MB (o governo pausa os itens dele em 10240); roda em nice 19,
  ionice idle e oom_score_adj 1000; árvore PRÓPRIA (`ballast-hq-probe`, o item usa `ballast-hq`) no origin/main do espelho; não grava baseline, ponta nem lista de reprovadas do item (hq-selftests.last/.failed/
  .durations ficam como estão) e não passa pelo governo (nem crontab, nem registro).
VARIÁVEIS (só o selftest troca): HQP_MIN_AVAIL_MB (piso de MemAvailable do aborto; padrão 8000) · HQP_INTERVAL_S (tick; padrão 2) · HQ_SELFTEST_TIMEOUT (prazo de cada selftest; padrão 1200, o do item) ·
  HQP_OVERLAY (pasta com arquivos copiados por cima da árvore antes de rodar, para medir um conserto ainda não mergeado) · BALLAST_HQ_RIG · BALLAST_REMOTE_GIT · GT_REMOTE_GIT · BALLAST_HOME (os mesmos do item).
LIMITES: roda FORA do cgroup do item (sem o teto de 5120 MB do kernel): a proteção é o aborto por MemAvailable e o escopo systemd do USO acima. Mede UMA rodada: o pico depende do commit do hq e de quem
  disputa a CPU. Selftest que sai da sessão (setsid) some da conta do governo e daqui também, de propósito.
"""
import fcntl, json, os, signal, subprocess, sys, time

HOME = os.path.expanduser("~")
GR = os.environ.get("GT_REMOTE_GIT", HOME + "/gt-remote/git")
RIG = os.environ.get("BALLAST_HQ_RIG", "gascity")
NAME = "ballast-hq-probe"
RG = os.environ.get("BALLAST_REMOTE_GIT", HOME + "/gt-remote/bin/hetzner-remote-git.sh")
BH = os.environ.get("BALLAST_HOME", HOME + "/gt-remote/ballast")
# HQP_MIN_AVAIL_MB / HQP_INTERVAL_S: só o selftest troca (uma máquina pequena aborta com MemAvailable < 8000 MB; o tick de 2 s faz o selftest durar). Valor que não é inteiro ≥ 1 → o padrão, nunca 0 (0 desligaria o aborto)
def _env_int(name, default):
    v = os.environ.get(name, "")
    return int(v) if v.isdigit() and int(v) >= 1 else default


MIN_AVAIL_MB = _env_int("HQP_MIN_AVAIL_MB", 8000)
INTERVAL_S = _env_int("HQP_INTERVAL_S", 2)
HOT_FRACTION = 0.6
PAGE_KB = os.sysconf("SC_PAGE_SIZE") // 1024
STOP = False
FIELDS = ("rel", "rc", "secs", "peak_rss_mb", "peak_pss_mb", "peak_n", "t_peak", "leak_rss_mb", "leak_n", "leak_secs")


def log(msg):
    print("%s probe: %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def on_signal(_sig, _frm):
    global STOP
    STOP = True


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


def cap_mb():
    # vazio (item hq-selftests ausente do registro) → 4096 com o aviso; falhou/ilegível (arquivo que não abre) → 4096 com o aviso: o teto só serve de régua para o `hot.jsonl`, não de limite
    try:
        with open(BH + "/items.tsv", encoding="utf-8") as f:
            for ln in f:
                a = ln.rstrip("\n").split("\t")
                if len(a) >= 4 and a[0] == "hq-selftests" and a[3].isdigit():
                    return int(a[3])
    except OSError:
        pass
    log("AVISO: não li o rss_mb do hq-selftests em %s/items.tsv: uso 4096 como régua" % BH)
    return 4096


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


def scan_sessions(sids):
    """{sid: [(pid, ppid, estado, rss_kb_statm, cmd)]} dos membros VIVOS das sessões em `sids` (a leitura do governo: stat campo 6, statm campo 2, zumbi fora)."""
    out = {s: [] for s in sids}
    # vazio (nada listado) → todas as sessões vazias; falhou/ilegível (/proc não abre) → exceção sobe: a rodada é abortada, nunca lida como "ninguém roda"
    for nm in os.listdir("/proc"):
        if not nm.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % nm, "rb") as f:
                data = f.read().decode("utf-8", "replace")
            rest = data[data.rindex(")") + 2:].split()
            st, ppid, psid = rest[0], int(rest[1]), int(rest[3])
            if psid not in out or st == "Z":
                continue
            with open("/proc/%s/statm" % nm) as f:
                rss = int(f.read().split()[1]) * PAGE_KB
            with open("/proc/%s/cmdline" % nm, "rb") as f:
                cmd = f.read().decode("utf-8", "replace").replace("\0", " ")[:120]
        except (OSError, ValueError, IndexError):
            continue          # sumiu no meio da leitura: ignorado, como no governo
        out[psid].append((int(nm), ppid, st, rss, cmd))
    return out


def stop_sids(sids, why):
    """TERM em cada membro das sessões `sids` (as MINHAS), KILL 20 s depois nos que sobraram. Só por sid: nunca por nome."""
    sids = list(sids)
    if not sids:
        return
    log("encerrando %d sessão(ões) (%s)" % (len(sids), why))
    for sig, wait in ((signal.SIGTERM, 20), (signal.SIGKILL, 5)):
        try:
            cur = scan_sessions(sids)
        except OSError:
            cur = {}
        for ms in cur.values():
            for pid, _pp, _st, _rss, _cmd in ms:
                try:
                    os.kill(pid, sig)
                except OSError:
                    pass          # sumiu, ou é de root: sai sozinho quando o filho sai
        end = time.time() + wait
        while time.time() < end:
            try:
                if not any(scan_sessions(sids).values()):
                    return
            except OSError:
                return
            time.sleep(1)


def read_tests(arg, tree):
    """Lista de selftests (relativos à árvore). Sem `arg`: a ordem do item (durations, mais lentos primeiro) sobre o que a árvore tem, menos a lista só-macOS que vem NA ÁRVORE."""
    # vazio (arquivo sem nome) → lista vazia e a rodada não roda; falhou/ilegível (não abre) → exceção: nada roda
    if arg:
        with open(arg, encoding="utf-8") as f:
            rels = [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]
        return rels
    pats = []
    with open(tree + "/scripts/hetzner-mac-only.hq.txt", encoding="utf-8") as f:
        pats = [ln.strip() for ln in f if ln.strip() and not ln.lstrip().startswith("#")]
    if not pats:
        raise ValueError("lista só-macOS sem nenhum padrão: não rodo (os testes de macOS viram ruído)")
    import fnmatch
    rels = []
    # vazio (árvore sem selftest) → lista vazia; falhou (pasta que não abre: o os.walk engole o erro e devolve nada) → TAMBÉM vazia, e os dois caem no mesmo estado inerte: "nada para rodar", rc 3
    for root, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d != ".git"]
        for fn in files:
            if fn.endswith(".selftest.sh"):
                rel = os.path.relpath(os.path.join(root, fn), tree)
                if not any(fnmatch.fnmatchcase(rel, p) for p in pats):
                    rels.append(rel)
    dur = {}
    try:
        with open(BH + "/hq-selftests.durations", encoding="utf-8") as f:
            for ln in f:
                k, _, v = ln.rstrip("\n").partition("\t")
                if v.isdigit():
                    dur[k] = int(v)
    except OSError:
        pass          # sem histórico: a ordem do find, como o item
    return sorted(rels, key=lambda r: (-dur.get(r, 10 ** 9), r))


def mb(kb, nd=0):
    # kB → MB. vazio (0 kB lidos) → 0; falhou/ilegível (None: o smaps_rollup não abriu) → None e vai como null no JSON: "não consegui ler" nunca é impresso como 0 MB
    if kb is None:
        return None
    return round(kb / 1024, nd) if nd else kb // 1024


def short(rel):
    return os.path.basename(rel).replace(".selftest.sh", "")


def main():
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    out = os.path.abspath(sys.argv[1])
    list_arg = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] not in ("", "-") else ""
    workers = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    limit = int(sys.argv[4]) if len(sys.argv) > 4 else 9000
    per_test = int(os.environ.get("HQ_SELFTEST_TIMEOUT", "1200"))
    # trava de instância única: duas sondas usam a MESMA árvore (`ballast-hq-probe`) e a segunda apagaria a da primeira (aconteceu em 03/11, ga-2hd02v.5.8: a 1ª caiu com FileNotFoundError no meio da rodada)
    # vazio (ninguém segura a trava) → segue; falhou/ilegível (a pasta não cria, o flock não abre) → rc 3 e nada roda: sem a trava não sei se há outra sonda, e "não sei" nunca vira "não há"
    try:
        os.makedirs(HOME + "/gt-remote/measure", exist_ok=True)
        lock = open(HOME + "/gt-remote/measure/hqprobe.lock", "w")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        log("outra sonda já roda (ou a trava não abre: %s): nada roda, a árvore dela fica como está" % e); return 3
    os.makedirs(out + "/tests", exist_ok=True)
    cap = cap_mb()
    wt = "%s/%s/wt/%s" % (GR, RIG, NAME)
    if os.path.exists(wt):
        subprocess.run([RG, "wt-rm", RIG, NAME], capture_output=True)          # sobra de uma medição minha anterior (nome só meu)
    subprocess.run(["git", "-C", "%s/%s/repo.git" % (GR, RIG), "branch", "-D", "worker/" + NAME], capture_output=True)
    # vazio (rc 0) → pull "ok"; falhou (rc != 0, prazo estourado) → pull "falhou": segue com o clone que há (código velho não é código errado), MAS o log e o peaks.json dizem, porque o pico medido é o
    # de uma ponta que pode não ser a do main
    pull = "ok"
    try:
        pr = subprocess.run([RG, "pull", RIG], capture_output=True, text=True, timeout=300)
        if pr.returncode != 0:
            pull = "falhou"
            log("AVISO: pull do espelho falhou (rc %d): sigo com o clone que há: %s" % (pr.returncode, (pr.stdout + pr.stderr).strip()[-160:]))
    except subprocess.SubprocessError:
        pull = "falhou"
        log("AVISO: pull do espelho estourou o prazo: sigo com o clone que há")
    add = subprocess.run([RG, "wt-add", RIG, NAME, "main"], capture_output=True, text=True, timeout=900)
    tree = wt + "/.gascity-gastown-hq"
    if add.returncode != 0 or not os.path.isdir(tree + "/scripts"):
        log("wt-add falhou: %s" % (add.stdout + add.stderr)[-200:]); return 3
    head = subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    # HQP_OVERLAY=<pasta>: arquivos (com o caminho de dentro do hq: scripts/…) copiados POR CIMA da árvore antes de rodar, para medir um conserto que ainda não chegou ao main.
    # vazio (variável ausente) → sem overlay; falhou/ilegível (pasta que não existe, cp que falha) → rc 3 e nada roda: medir "com o conserto" sem o conserto seria uma medição falsa
    ov = os.environ.get("HQP_OVERLAY", "")
    if ov:
        if not os.path.isdir(ov):
            log("HQP_OVERLAY '%s' não é uma pasta: nada roda" % ov); subprocess.run([RG, "wt-rm", RIG, NAME], capture_output=True); return 3
        cp = subprocess.run(["cp", "-a", ov.rstrip("/") + "/.", tree + "/"], capture_output=True, text=True)
        if cp.returncode != 0:
            log("overlay não copiou (rc %d): %s" % (cp.returncode, cp.stderr[-160:])); subprocess.run([RG, "wt-rm", RIG, NAME], capture_output=True); return 3
        log("overlay aplicado de %s" % ov)
    # vazio (lista sem nenhum selftest) → tratado logo abaixo ("nada para rodar", rc 3); falhou/ilegível (lista que não abre, lista só-macOS ausente ou sem padrão) → rc 3 e a árvore SAI: a exceção solta
    # largava a árvore `ballast-hq-probe` no espelho, e a medição seguinte a apagaria como "sobra minha"
    try:
        tests = read_tests(list_arg, tree)
    except (OSError, ValueError, UnicodeDecodeError) as e:
        log("lista de selftests ilegível ou inválida (%s): nada roda" % e)
        subprocess.run([RG, "wt-rm", RIG, NAME], capture_output=True)
        subprocess.run(["git", "-C", "%s/%s/repo.git" % (GR, RIG), "branch", "-D", "worker/" + NAME], capture_output=True)
        return 3
    # vazio (todos existem) → nada a dizer; falhou (nome da lista que a árvore não tem) → fica de fora E é dito, com os nomes: uma lista com nome errado medindo "tudo" seria uma medição de outra coisa
    dropped = [t for t in tests if not os.path.isfile(os.path.join(tree, t))]
    tests = [t for t in tests if t not in dropped]
    if dropped:
        log("AVISO: %d selftest(s) da lista não existem na árvore e ficam de fora: %s%s" % (len(dropped), ", ".join(dropped[:5]), " …" if len(dropped) > 5 else ""))
    log("árvore %s em %s; %d selftests, %d trabalhadores, limite %d s, régua %d MB; pull %s" % (wt, head[:9], len(tests), workers, limit, cap, pull))
    if not tests:
        log("nada para rodar"); return 3
    env = dict(os.environ, PATH=HOME + "/.local/bin:" + os.environ["PATH"], PYTHONDONTWRITEBYTECODE="1", GIT_AUTHOR_NAME="gt", GIT_AUTHOR_EMAIL="gt@no",
               GIT_COMMITTER_NAME="gt", GIT_COMMITTER_EMAIL="gt@no")
    pending = list(tests)
    live = {}                 # sid -> {rel, name, t0, popen, rc, secs, peak...}; fica até a sessão esvaziar (órfão conta)
    done = {}                 # name -> registro final
    item_peak = {"rss_mb": 0}
    t0 = time.time()
    why = "fim-da-lista"
    last_hot = 0.0
    try:
        with open(out + "/samples.jsonl", "w") as sf, open(out + "/hot.jsonl", "w") as hf:
            while True:
                now = time.time()
                t = int(now - t0)
                # novos: enquanto houver vaga (testes com líder vivo) e fila
                running = sum(1 for r in live.values() if r["rc"] is None)
                while not STOP and pending and running < workers and t < limit:
                    rel = pending.pop(0)
                    nm = short(rel)
                    lf = open("%s/tests/%s.log" % (out, nm), "wb")
                    argv = ["sh", "-c", '{ echo 1000 > /proc/self/oom_score_adj; } 2>/dev/null; exec nice -n 19 ionice -c 3 timeout -k 10 "$1" bash "$2"',
                            "ballast-measure:" + NAME, str(per_test), rel]
                    p = subprocess.Popen(argv, cwd=tree, env=env, stdin=subprocess.DEVNULL, stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
                    lf.close()
                    live[p.pid] = {"rel": rel, "name": nm, "t0": now, "p": p, "rc": None, "secs": None, "peak_rss_mb": 0, "peak_pss_mb": 0, "peak_n": 0, "t_peak": 0,
                                   "leak_rss_mb": 0, "leak_n": 0, "leak_secs": 0, "t_exit": None, "leak_last": None}
                    running += 1
                # ORDEM: primeiro o rc dos líderes, DEPOIS a leitura de /proc. "Líder morto E sessão vazia" só vale com a leitura tirada depois da saída: lida antes, um selftest rápido (o filho ainda
                # não fez o setsid, ou já saiu) parece "acabou sem deixar nada" e a sessão seria largada com o órfão dentro (medido no selftest: o `sleep` do órfão nunca era visto)
                for r in live.values():
                    if r["rc"] is None and r["p"].poll() is not None:
                        r["rc"], r["secs"] = r["p"].returncode, int(now - r["t0"])
                sids = list(live)
                try:
                    ses = scan_sessions(sids)
                except OSError as e:
                    why = "abortado-proc (%s)" % e; break      # sem ler /proc ninguém é dado por morto: a rodada acaba
                item_rss = item_pss = item_n = sem_pss = 0
                per, procs_all = [], []
                for sid, r in list(live.items()):
                    ms = ses.get(sid, [])
                    rss = sum(m[3] for m in ms) // 1024
                    pss = 0
                    for pid, pp, st, rkb, cmd in ms:
                        ro = rollup(pid)
                        if ro is None:
                            sem_pss += 1
                        else:
                            pss += ro["Pss"]
                        procs_all.append((rkb, pid, pp, st, sid, cmd, None if ro is None else ro["Pss"]))   # Pss ilegível → None (null no JSON), nunca 0
                    pss //= 1024
                    item_rss += rss; item_pss += pss; item_n += len(ms)
                    if rss > r["peak_rss_mb"]:
                        r["peak_rss_mb"], r["peak_pss_mb"], r["peak_n"], r["t_peak"] = rss, pss, len(ms), t
                    if r["rc"] is not None:
                        # depois do líder: o MAIOR que ele deixou vivo na sessão e por quanto tempo (a sessão que esvazia no fim não apaga o que se viu: o governo só limpa órfão quando o ITEM acaba)
                        if r["t_exit"] is None:
                            r["t_exit"] = now
                        if ms:
                            r["leak_rss_mb"], r["leak_n"] = max(r["leak_rss_mb"], rss), max(r["leak_n"], len(ms))
                            r["leak_last"] = now
                            r["leak_secs"] = int(now - r["t_exit"])
                    per.append((rss, r["name"], len(ms), pss, r["rc"] is not None))
                    if r["rc"] is not None and not ms:                          # sessão vazia e líder morto: o selftest acabou de vez
                        done[r["name"]] = {k: r[k] for k in FIELDS}
                        del live[sid]
                per.sort(reverse=True)
                avail = mem_avail_mb()
                line = {"t": t, "item_rss_mb": item_rss, "item_pss_mb": item_pss, "item_n": item_n, "sem_pss": sem_pss, "avail_mb": avail, "sessions": len(live), "pending": len(pending),
                        "top": [{"test": n, "rss_mb": a, "pss_mb": c, "n": b, "after_exit": ex} for a, n, b, c, ex in per[:6]]}
                sf.write(json.dumps(line) + "\n"); sf.flush()
                procs_all.sort(reverse=True)
                if item_rss > item_peak["rss_mb"]:
                    item_peak = {"rss_mb": item_rss, "pss_mb": item_pss, "sem_pss": sem_pss, "n": item_n, "t": t, "avail_mb": avail,   # pss_mb é PISO quando sem_pss > 0 (soma só do que o smaps_rollup deixou ler)
                                 "by_test": [{"test": n, "rss_mb": a, "pss_mb": c, "n": b, "after_exit": ex} for a, n, b, c, ex in per[:8]],
                                 "top_procs": [{"pid": p[1], "ppid": p[2], "rss_mb": p[0] // 1024, "pss_mb": mb(p[6]), "sess": live[p[4]]["name"] if p[4] in live else "?", "cmd": p[5]} for p in procs_all[:20]]}
                if item_rss >= cap * HOT_FRACTION and now - last_hot >= 5:
                    last_hot = now
                    hf.write(json.dumps({"t": t, "item_rss_mb": item_rss, "item_pss_mb": item_pss, "sem_pss": sem_pss, "n": item_n,
                                         "procs": [{"pid": p[1], "ppid": p[2], "st": p[3], "rss_mb": round(p[0] / 1024, 1), "pss_mb": mb(p[6], 1),
                                                    "sess": live[p[4]]["name"] if p[4] in live else "?", "cmd": p[5]} for p in procs_all[:30]]}) + "\n"); hf.flush()
                if t % 60 < INTERVAL_S:
                    with open(out + "/peaks.json", "w") as pf:
                        json.dump({"cap_mb": cap, "t": t, "pull": pull, "dropped": dropped[:20], "done": done, "live": {r["name"]: {k: r[k] for k in FIELDS if k != "rel"} for r in live.values()},
                                   "item_peak": item_peak, "pending": len(pending)}, pf, indent=1)
                if STOP:
                    why = "sinal"; break
                if avail is None or avail < MIN_AVAIL_MB:
                    why = "abortado-ram (MemAvailable=%s MB)" % avail; break
                if t >= limit:
                    why = "limite"; break
                if not live and not pending:
                    break
                time.sleep(INTERVAL_S)
    finally:
        stop_sids(list(live), why)
        for sid, r in live.items():
            done.setdefault(r["name"], {k: r[k] for k in FIELDS})
        with open(out + "/peaks.json", "w") as pf:
            json.dump({"cap_mb": cap, "t": int(time.time() - t0), "why": why, "pull": pull, "dropped": dropped[:20], "done": done, "item_peak": item_peak, "pending": len(pending)}, pf, indent=1)
        r = subprocess.run([RG, "wt-rm", RIG, NAME], capture_output=True, text=True)
        subprocess.run(["git", "-C", "%s/%s/repo.git" % (GR, RIG), "branch", "-D", "worker/" + NAME], capture_output=True)
        log("fim: %s; pico do item %d MB (PSS %d%s) aos %d s, teto %d; pull %s; wt-rm rc=%d; árvore %s" % (
            why, item_peak["rss_mb"], item_peak.get("pss_mb", 0), " no mínimo, %d processo(s) sem PSS" % item_peak["sem_pss"] if item_peak.get("sem_pss") else "", item_peak.get("t", 0), cap,
            pull, r.returncode, "AINDA EXISTE" if os.path.exists(wt) else "removida"))
    # rc: 0 SÓ quando a lista acabou. limite (4: sobrou selftest sem medir), sinal (143) e abortado-ram/abortado-proc (5) são medição INCOMPLETA: quem encadeia (`&&`, systemd) não pode ler 0 como "medi tudo"
    return 0 if why == "fim-da-lista" else 4 if why == "limite" else 143 if why == "sinal" else 5


if __name__ == "__main__":
    sys.exit(main())
