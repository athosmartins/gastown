#!/usr/bin/env python3
"""hetzner-tmp-reaper.py — reaper permanente do /tmp do nó Hetzner (ga-d4iob2s). Roda NO NÓ, como o usuário do lastro, por cron; nunca como root.

Contents
  O que faz · Como julga · Os 3 estados · Saída · Sementes de teste · Instalar

O QUE FAZ  Apaga de /tmp a UNIDADE do dono cuja ÁRVORE INTEIRA (ela e tudo abaixo) está parada há mais de N horas (padrão 6, --max-age-hours). Por idade e dono,
  nunca por lista de nomes: a lista do Mayor (7 padrões) casava 15 % do que sobrou em 17/11. Unidade = cada entrada de 1º nível e, dentro de um CONTÊINER (claude-<uid>, os
  scratchpads das sessões), cada filho (CONTAINERS: claude-<uid> e pytest-of-<usuário>): o contêiner está sempre fresco (sessão viva, teste rodando) e sozinho nunca seria limpo; medido em 17/11: 2.687 de 2.758 projetos parados, ~4-13 M de inodes, e 18 GB em pytest-of-runner.
COMO JULGA  Na ordem: dono (st_uid != o meu = alheio: nunca toco /tmp de outro usuário, o `dados` da trava 1) · exceção (tmux-*, .X11-unix..., mais as linhas do keep.txt) ·
  montagem (outro dispositivo, ou ponto de montagem em /proc/mounts dentro da unidade: o bind do MESMO disco passa pelo st_dev e apagar por ele apaga o original = mantém) · EM USO (cwd, exe, fd e argv de processo vivo, e socket unix ligado em /proc/net/unix: o socket do tmux dos agentes fica quieto por
  dias e a pasta dele pareceria velha) · idade da ÁRVORE (maior mtime/ctime de tudo abaixo; o ctime vale porque tar -x e chmod deixam mtime velho em coisa nova). Link simbólico:
  apaga o link, nunca segue. Antes de apagar reconfere dispositivo, inode e carimbos da hora do julgamento (mudou → mantém).
OS 3 ESTADOS  O que decide a apagar e não respondeu NÃO vira "nada a limpar": df (statvfs), /proc, a varredura da raiz, o keep.txt (linha fora do alfabeto de nome = incerteza) ou
  uma raiz que não é um /tmp (sticky + gravável por todos) → NAO-CONSEGUI (rc 2), nada é apagado, o motivo vai ao status. Árvore com um filho cujo carimbo não se lê (pasta legível sem busca) → mantida (kept.ilegivel).
  Falhar em gravar o status/log DEPOIS de apagar também é NAO-CONSEGUI/escrever (no log e no status, melhor esforço, e rc 2), nunca LIMPO. Entrada que sumiu no meio da varredura (o runner cria e apaga em /tmp o tempo todo) não é erro.
SAÍDA  Uma linha JSON na stdout; fora do --dry-run também <state>/status.json (troca atômica; gravado ANTES do log) e uma linha em <state>/reaper.log (teto de 1 MB, vira reaper.log.1; traz erros=N e result/motivo).
  result: LIMPO | PARCIAL (acabou o --max-seconds; a próxima rodada continua pelas unidades que sobraram, e a que estava no meio fica "recente" por N h) | ERROS (algo não apagou) | PULADO (outra instância tem o lock) | NAO-CONSEGUI. rc: 0 | 0 | 1 | 0 | 2 (64 = root, idade que não é número finito > 0 ou teto de tempo que não é finito >= 0; 70 = crash).
  disk_pct/inode_pct (como o df) são os de DEPOIS; alerta lista disco (> --disk-pct, 90) e/ou inodes (> --inode-pct, 80): é o que o vigia do mini lê.
SEMENTES DE TESTE  --now (relógio), --proc (/proc de mentira), TMP_REAPER_FAKE_DF=<disco,inodes>|fail, TMP_REAPER_UID (dono de mentira, SÓ com --dry-run) e
  TMP_REAPER_PRETEND_ROOT=1 (finge ser root: só aumenta a recusa).
INSTALAR  docs/runbooks/hetzner-tmp-reaper.md: cron do runner, com nice, ionice e flock."""
import argparse
import fcntl
import fnmatch
import json
import math
import os
import re
import stat
import sys
import time

KEEP = ("tmux-*", ".X11-unix", ".ICE-unix", ".font-unix", ".XIM-unix", "hsperfdata_*", "systemd-private-*", "snap-private-tmp")  # exceções de fábrica
CONTAINERS = ("claude-[0-9]*", "pytest-of-*")  # scratchpads de sessão e o /tmp/pytest-of-<usuário> (18 GB em 17/11): sempre frescos, então só os filhos são unidades
NAME_OK = re.compile(r"[A-Za-z0-9._*?\[\]-]+")
LOG_MAX = 1 << 20


class Inert(Exception):
    """A leitura que decide não respondeu: nada é apagado (args: motivo, detalhe)."""


class Budget(Exception):
    """O teto de tempo acabou (args[0], quando há: quantas entradas a unidade em curso já apagou antes de parar)."""


def check_root(root):
    # falhou/ilegível → Inert('root'): só atuo em um /tmp de verdade (pasta, sticky, gravável por todos), nunca num $HOME apontado por engano
    try:
        rs = os.lstat(root)
    except OSError as e:
        raise Inert("root", "%s: %s" % (root, e))
    if not stat.S_ISDIR(rs.st_mode) or not rs.st_mode & stat.S_ISVTX or not rs.st_mode & stat.S_IWOTH:
        raise Inert("root", "%s não é um diretório temporário (sticky + gravável por todos)" % root)
    return rs


def read_keep(state):
    # vazio (sem keep.txt) → só as exceções de fábrica; falhou/ilegível ou linha fora do alfabeto → Inert: a lista guarda uma ação destrutiva, linha ruim é incerteza, não "ignoro a linha"
    pats = list(KEEP)
    try:
        with open(os.path.join(state, "keep.txt"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return pats
    except (OSError, UnicodeDecodeError) as e:
        raise Inert("keep", "keep.txt: %s" % e)
    for ln in lines:
        ln = ln.split("#", 1)[0].strip()
        if ln and not NAME_OK.fullmatch(ln):
            raise Inert("keep", "keep.txt: linha fora do alfabeto de nome: %r" % ln[:60])
        if ln:
            pats.append(ln)
    return pats


def read_df(root):
    # vazio → n/a; falhou/ilegível (statvfs, ou sem blocos/inodes) → Inert: sem o número do disco o alarme não sai e a bead manda não apagar às cegas
    fake = os.environ.get("TMP_REAPER_FAKE_DF")
    if fake:
        try:
            d, i = (float(x) for x in fake.split(","))
        except ValueError:
            raise Inert("df", "TMP_REAPER_FAKE_DF=%s" % fake)
        return d, i
    try:
        v = os.statvfs(root)
    except OSError as e:
        raise Inert("df", "statvfs %s: %s" % (root, e))
    used, iused = v.f_blocks - v.f_bfree, v.f_files - v.f_ffree
    if used + v.f_bavail <= 0 or iused + v.f_favail <= 0:
        raise Inert("df", "statvfs sem blocos ou inodes")
    return round(100.0 * used / (used + v.f_bavail), 1), round(100.0 * iused / (iused + v.f_favail), 1)


def read_in_use(proc, root):
    # vazio → conjunto vazio (nenhum processo toca a raiz); falhou/ilegível (a pasta do /proc ou o net/unix) → Inert('proc'): sem saber quem usa, não apaga
    paths = []
    try:
        pids = [d for d in os.listdir(proc) if d.isdigit()]
        with open(os.path.join(proc, "net", "unix"), encoding="utf-8", errors="replace") as f:
            for ln in f.read().splitlines()[1:]:
                cols = ln.split(None, 7)
                if len(cols) == 8:
                    paths.append(cols[7].strip())
    except OSError as e:
        raise Inert("proc", "%s: %s" % (proc, e))
    pat = re.compile(re.escape(root) + r"/[^\s'\":;|&<>()]*")
    for pid in pids:
        base = os.path.join(proc, pid)
        links = [os.path.join(base, "cwd"), os.path.join(base, "exe")]
        try:
            links += [os.path.join(base, "fd", n) for n in os.listdir(os.path.join(base, "fd"))]
        except OSError:
            pass  # o processo saiu, ou não deixa ler (de outro dono; não-dumpable, como os renderers do Chromium): não protege nada, quem protege é a idade da árvore
        for ln in links:
            try:
                paths.append(os.readlink(ln))
            except OSError:
                pass
        try:
            with open(os.path.join(base, "cmdline"), "rb") as f:
                for tok in f.read().decode("utf-8", "replace").split("\0"):
                    paths += ([tok] if tok.startswith(root + "/") else []) + pat.findall(tok)
        except OSError:
            pass
    keys = set()
    for p in paths:
        if p.startswith(root + "/"):
            parts = p[len(root) + 1:].split("/")
            keys.update((parts[0], "/".join(parts[:2])))
    return keys


def read_mounts(proc, root):
    # vazio (nenhuma montagem sob a raiz) → lista vazia; falhou/ilegível → Inert('proc'): um bind do MESMO dispositivo passa pelo st_dev, e apagar por ele apaga o original
    try:
        with open(os.path.join(proc, "mounts"), encoding="utf-8", errors="replace") as f:
            cols = [ln.split(" ") for ln in f.read().splitlines()]
    except OSError as e:
        raise Inert("proc", "%s/mounts: %s" % (proc, e))
    unesc = lambda s: re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), s)  # o kernel escreve espaço, tab, newline e barra invertida como \040 \011 \012 \134
    return [unesc(c[1]) for c in cols if len(c) >= 2 and unesc(c[1]).startswith(root + "/")]


def tree_state(top, st0, dev, cut, deadline):
    """velho | recente | ilegivel | montagem: 'recente' se algo na árvore (ou ela) tem max(mtime, ctime) depois de `cut`."""
    def newer(s):
        return max(s.st_mtime, s.st_ctime) > cut
    if newer(st0):
        return "recente"
    stack, n = ([top] if stat.S_ISDIR(st0.st_mode) else []), 0
    while stack:
        try:
            with os.scandir(stack.pop()) as it:
                for e in it:
                    n += 1
                    if n % 512 == 0 and time.monotonic() > deadline:
                        raise Budget()
                    try:  # sumiu → não conta; falhou por outro motivo (pasta legível sem busca: o nome aparece e o carimbo do filho não) → 'ilegivel': a frescura é desconhecida, mantém
                        s = e.stat(follow_symlinks=False)
                    except FileNotFoundError:
                        continue
                    except OSError: return "ilegivel"
                    if newer(s):
                        return "recente"
                    if stat.S_ISDIR(s.st_mode):
                        if s.st_dev != dev:
                            return "montagem"
                        stack.append(e.path)
        except (FileNotFoundError, PermissionError):
            continue  # pasta sem acesso (modo 000): ninguém a atravessa, vale o carimbo dela, já conferido
        except OSError:
            return "ilegivel"
    return "velho"


def rm_tree(top, dev, me, deadline):
    """(apagados, erros): sem seguir link nem cruzar dispositivo; pasta do dono sem rwx ganha chmod antes (só ele a abre)."""
    n = bad = 0
    order, stack = [], [top]
    while stack:
        d = stack.pop()
        if time.monotonic() > deadline:
            raise Budget(n)
        try:
            s = os.lstat(d)
            if not stat.S_ISDIR(s.st_mode) or s.st_dev != dev:
                bad += 1  # virou link ou montagem no meio do caminho: não atravessa
                continue
            if s.st_uid == me and s.st_mode & 0o700 != 0o700:
                os.chmod(d, s.st_mode | 0o700)
            with os.scandir(d) as it:
                ents = list(it)
            for k, e in enumerate(ents):
                try:  # a entrada que sumiu entre o scandir e o unlink (outro apagador anda no mesmo /tmp) já está como se quer: segue com as irmãs, e a pasta ainda vai para o rmdir
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                    else:
                        os.unlink(e.path)
                        n += 1
                except FileNotFoundError: pass
                except OSError: bad += 1  # esta não apagou: conta o erro e segue com as outras; o rmdir da pasta vai falhar de novo (ENOTEMPTY) e o resultado sai ERROS
                if k % 4096 == 4095 and time.monotonic() > deadline:
                    raise Budget(n)
            order.append(d)
        except FileNotFoundError:
            continue
        except OSError:
            bad += 1
    for d in reversed(order):
        try:
            os.rmdir(d)
            n += 1
        except FileNotFoundError:
            pass
        except OSError:
            bad += 1
    return n, bad


def reap(path, st, dev, me, deadline):
    """(apagados, erros, motivo): reconfere a identidade da hora do julgamento (dispositivo, inode, mtime, ctime) antes de apagar."""
    try:
        s2 = os.lstat(path)
    except FileNotFoundError:
        return 0, 0, "sumiu"
    if (s2.st_dev, s2.st_ino, s2.st_mtime_ns, s2.st_ctime_ns) != (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_ctime_ns):
        return 0, 0, "mudou"
    if stat.S_ISDIR(s2.st_mode):
        return rm_tree(path, dev, me, deadline) + (None,)
    try:
        os.unlink(path)
    except FileNotFoundError:
        return 0, 0, "sumiu"
    except OSError:
        return 0, 1, None
    return 1, 0, None


def prefix(rel):
    """O censo de quem vaza: filho de contêiner vira `contêiner/*`; o sufixo aleatório (4+ letras/dígitos depois de - _ .) vira `*`."""
    head, _, tail = rel.partition("/")
    if tail:
        return head + "/*"
    m = re.match(r"(.*[-_.])[A-Za-z0-9]{4,}\Z", rel)
    return m.group(1) + "*" if m else rel


def _log_line(res):
    return "%s %s reaped=%d scanned=%d erros=%d secs=%s disco=%s%% inodes=%s%% alerta=%s top=%s" % (
        res["iso"], res["result"] + ("/" + res["motivo"] if res["motivo"] else ""), res["reaped"], res["scanned"], res["errors"], res["secs"], res["disk_pct"], res["inode_pct"], ",".join(res["alerta"]) or "-",
        ",".join("%s:%d" % (k, n) for k, n in res["top"][:3]) or "-")


def _write_status(state, res):
    os.makedirs(state, exist_ok=True)
    tmp = os.path.join(state, "status.json.tmp")
    with open(tmp, "w") as f:
        f.write(json.dumps(res, sort_keys=True) + "\n")
    os.replace(tmp, os.path.join(state, "status.json"))


def _append_log(state, line):
    os.makedirs(state, exist_ok=True)
    log = os.path.join(state, "reaper.log")
    if os.path.exists(log) and os.path.getsize(log) > LOG_MAX:
        os.replace(log, log + ".1")
    with open(log, "a") as f:
        f.write(line + "\n")


def publish(state, res):
    # falhou (disco cheio, pasta sem permissão) → devolve o erro E o que ficou gravado diz NAO-CONSEGUI/escrever (melhor esforço), nunca LIMPO: o cron manda a stdout para /dev/null e não guarda o rc, então só o log e o status.json ficam
    err = None
    try:
        _write_status(state, res)  # o status vem primeiro: a linha LIMPO do log só existe se o status que o vigia lê também foi gravado
        _append_log(state, _log_line(res))
    except OSError as e:
        err = str(e)
    if err is not None:
        flipped = dict(res, result="NAO-CONSEGUI", motivo="escrever", detalhe=err)
        for step in (lambda: _append_log(state, _log_line(flipped)), lambda: _write_status(state, flipped)):
            try:
                step()
            except OSError:
                pass  # o disco que falhou provavelmente falha de novo: o que não coube é o que o rc 2 e a stdout já dizem a quem rodou na mão
    return err


def main(argv):
    ap = argparse.ArgumentParser(description="reaper do /tmp do nó Hetzner (ga-d4iob2s)")
    ap.add_argument("--root", default="/tmp")
    ap.add_argument("--state", default=os.path.expanduser("~/gt-remote/tmp-reaper"))
    ap.add_argument("--max-age-hours", type=float, default=float(os.environ.get("TMP_REAPER_MAX_AGE_H", "6")))
    ap.add_argument("--max-seconds", type=float, default=540)
    ap.add_argument("--disk-pct", type=float, default=90)
    ap.add_argument("--inode-pct", type=float, default=80)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--now", type=float)
    ap.add_argument("--proc", default="/proc")
    a = ap.parse_args(argv)
    if os.geteuid() == 0 or os.environ.get("TMP_REAPER_PRETEND_ROOT") or not (0 < a.max_age_hours < math.inf) or not (0 <= a.max_seconds < math.inf):  # `<= 0` deixava o nan passar: com nan todo carimbo é "mais velho que o corte" e a rodada apagaria até o fresco
        print("hetzner-tmp-reaper: não rodo como root, a idade tem de ser um número finito > 0 e o teto de tempo um número finito >= 0 (só apago o que é do usuário do lastro)", file=sys.stderr)
        return 64
    try:
        os.nice(19)
    except OSError:
        pass
    t0, now = time.monotonic(), (a.now if a.now is not None else time.time())
    cut, deadline, root = now - a.max_age_hours * 3600, time.monotonic() + a.max_seconds, a.root
    me = int(os.environ["TMP_REAPER_UID"]) if a.dry_run and "TMP_REAPER_UID" in os.environ else os.geteuid()
    res = {"v": 1, "epoch": int(now), "iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), "result": "LIMPO", "motivo": None, "detalhe": None, "dry_run": a.dry_run,
           "root": root, "max_age_h": a.max_age_hours, "scanned": 0, "reapable": 0, "reaped": 0, "inodes_apagados": 0, "kept": {}, "errors": 0, "falhou": [],
           "disk_pct": None, "inode_pct": None, "alerta": [], "secs": 0}
    lock = None
    if not a.dry_run:
        try:  # falhou ao criar/abrir o lock (disco sem inode livre) → segue sem lock: a limpeza é o que libera o inode e o flock do cron cobre a exclusão; lock tomado → PULADO
            os.makedirs(a.state, exist_ok=True)
            lock = open(os.path.join(a.state, "lock"), "a")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            res.update(result="PULADO", motivo="outra instância tem o lock")
            print(json.dumps(res, sort_keys=True))
            return 0
        except OSError:
            lock = None
    kept, census = res["kept"], {}
    try:
        rs = check_root(root)
    except Inert as e:
        res.update(result="NAO-CONSEGUI", motivo=e.args[0], detalhe=e.args[1])
    else:
        try:
            pats = read_keep(a.state)
            read_df(root)  # só a prova de que o df responde (sem ele não apago); o número que vale é o lido DEPOIS, no fim
            inuse, mounts = read_in_use(a.proc, root), read_mounts(a.proc, root)
            try:  # vazio → nenhuma unidade; falhou/ilegível → Inert('scan'), nunca "nada a limpar"
                names = os.listdir(root)
            except OSError as e:
                raise Inert("scan", "%s: %s" % (root, e))
            units = []
            for name in names:
                path = os.path.join(root, name)
                if any(fnmatch.fnmatchcase(name, c) for c in CONTAINERS):
                    try:  # contêiner (dono, pasta, sem exceção): os filhos são as unidades; o resto vai inteiro para o julgamento
                        cs = os.lstat(path)
                        if stat.S_ISDIR(cs.st_mode) and cs.st_uid == me and not any(fnmatch.fnmatchcase(name, p) for p in pats):
                            units += [(name + "/" + c, os.path.join(path, c)) for c in os.listdir(path)]
                            continue
                    except FileNotFoundError:
                        continue
                    except OSError:
                        kept["ilegivel"] = kept.get("ilegivel", 0) + 1
                        continue
                units.append((name, path))
            for rel, path in units:
                if time.monotonic() >= deadline:
                    raise Budget()
                try:
                    st = os.lstat(path)
                except FileNotFoundError:
                    kept["sumiu"] = kept.get("sumiu", 0) + 1
                    continue
                res["scanned"] += 1
                if st.st_uid != me:
                    why = "alheio"
                elif any(fnmatch.fnmatchcase(os.path.basename(path), p) for p in pats):
                    why = "excecao"
                elif st.st_dev != rs.st_dev or any(m == path or m.startswith(path + "/") for m in mounts):
                    why = "montagem"
                elif rel in inuse:
                    why = "em-uso"
                else:
                    why = tree_state(path, st, rs.st_dev, cut, deadline)
                if why != "velho":
                    kept[why] = kept.get(why, 0) + 1
                elif a.dry_run:
                    res["reapable"] += 1
                    census[prefix(rel)] = census.get(prefix(rel), 0) + 1
                else:
                    try:
                        n, bad, why2 = reap(path, st, rs.st_dev, me, deadline)
                    except Budget as e:  # parou no meio da unidade: o que ela já apagou conta. O resto dela fica "recente" por N horas (apagar mexe no mtime) e só a rodada seguinte a essa janela o termina
                        res["inodes_apagados"] += e.args[0] if e.args and isinstance(e.args[0], int) else 0
                        raise
                    res["inodes_apagados"] += n
                    if why2:
                        kept[why2] = kept.get(why2, 0) + 1
                    elif bad:
                        res["errors"] += bad
                        res["falhou"] = (res["falhou"] + [rel])[:5]
                    else:
                        res["reaped"] += 1
                        census[prefix(rel)] = census.get(prefix(rel), 0) + 1
        except Inert as e:
            res.update(result="NAO-CONSEGUI", motivo=e.args[0], detalhe=e.args[1])
        except Budget:
            res["result"] = "PARCIAL"
    if res["result"] == "LIMPO" and res["errors"]:
        res["result"] = "ERROS"
    try:  # falhou/ilegível depois de apagar → NAO-CONSEGUI/df (o que foi apagado segue contado em reaped; sem o número do disco o alarme não tem como sair)
        res["disk_pct"], res["inode_pct"] = read_df(root)
    except Inert as e:
        if res["motivo"] is None:
            res.update(result="NAO-CONSEGUI", motivo=e.args[0], detalhe=e.args[1])
    res["alerta"] = [k for k, v, lim in (("disco", res["disk_pct"], a.disk_pct), ("inodes", res["inode_pct"], a.inode_pct)) if v is not None and v > lim]
    res["secs"] = round(time.monotonic() - t0, 1)
    res["top"] = [[k, n] for k, n in sorted(census.items(), key=lambda kv: (-kv[1], kv[0]))[:8]]  # quem mais vazou nesta rodada: o censo que aponta o teste a consertar
    if not a.dry_run:
        err = publish(a.state, res)
        if err:
            res.update(result="NAO-CONSEGUI", motivo="escrever", detalhe=err)
    print(json.dumps(res, sort_keys=True))
    return {"LIMPO": 0, "PARCIAL": 0, "ERROS": 1}.get(res["result"], 2)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except BaseException as e:  # o excepthook do apport deste nó gira CPU em exceção solta: sempre sai por aqui, e deixa o rastro no log (o cron grava o stderr num arquivo que o disparo seguinte zera)
        msg = "%s: %s" % (type(e).__name__, e)
        print("hetzner-tmp-reaper: " + msg, file=sys.stderr)
        try:  # falhou (pasta de estado ausente ou sem permissão) → só o stderr: o crash já está contado no rc 70
            with open(os.path.expanduser("~/gt-remote/tmp-reaper/reaper.log"), "a") as f:
                f.write("%s CRASH %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg[:200]))
        except OSError:
            pass
        sys.exit(70)
