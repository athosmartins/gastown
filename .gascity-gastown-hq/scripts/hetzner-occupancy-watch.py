#!/usr/bin/env python3
"""hetzner-occupancy-watch.py — o nó Hetzner pago está trabalhando? Uma leitura a cada 15 min; aviso ao Mayor se ocioso com fila ou se a CPU fica abaixo da régua; diz a causa em números e age em degraus. (ga-2hd02v.1.12, ga-2hd02v.6, ga-2hd02v.5.10)

Contents
  Regra · Estado · Aviso · Causa, degraus e número do dia · Arquivos · Uso

REGRA (Athos, 14/10): "Hetzner pago trabalha sempre". O launchd do mini roda isto a cada 900 s (com.gascity.hetzner-occupancy-watch). Cada rodada faz TRÊS
leituras, e cada uma tem três estados (leu / não consegui ler / vale X): "não consegui" nunca vira "ocioso" nem "ocupado".
  sessões  `gc session list --json`: sessões com `-remote-` no nome em state active/awake (as de `-remote-mbp-` são de outro host e não contam), e `bd list --status
           in_progress --json --limit 0` (só leitura): dessas, só conta a que SEGURA uma bead (assignee = o alias, o session_name ou o name dela)
  CPU     `ssh hetzner-teste` lê o /proc/stat: núcleos ocupados NA JANELA desde a leitura anterior (uma rajada entre duas leituras aparece; um instante não vale)
  fila     ~/.gc/pilot-dispatchable.json (o Pilot a grava a cada rodada): só as lojas elegíveis (hq), com idade e ttl conferidos
ESTADO   ocupado = sessão remota que SEGURA bead in_progress OU CPU >= régua (0,5 núcleo, HETZNER_OCC_BUSY_CORES): uma prova basta. Sessão viva sem bead NÃO prova nada
         (20/10: 2 dog-remote paradas, beads fechadas, 26 de 26 leituras "ocupado" com CPU de 1 a 18 %, ga-l9q18u); o bd que falha não vira "ninguém segura bead"
         ocioso  = sessões (e quem segura bead) e CPU lidas e as duas dizem ocioso
         desconhecido = o resto (inclui a 1ª leitura, que só semeia o baseline de CPU)
AVISO    ao Mayor por `gc mail send` (não nudge: o nudge ao Mayor trava com a sessão anexada, ga-eldeu). Só avisa; não atribui nem despacha nada.
  ocioso   ocioso há >= 30 min (3 leituras seguidas, 2 min de folga para o jitter do launchd) COM fila > 0; cooldown de 3 h; o mail que falha não gasta o cooldown
  cpu baixa  a CPU do nó abaixo de 85 % (HETZNER_OCC_LOW_PCT; 0 desliga) por >= 30 min: janelas de CPU seguidas, cada uma com média abaixo da régua, que juntas cobrem 30 min medidos (2 min de folga);
           cooldown de 3 h. Só olha a CPU: NÃO depende de fila, de sessão nem do foco do gate. Athos, 20/10: "o que nao pode é ficar menos do que 100% ocupado"; na madrugada de 20/10 a CPU ficou em
           0-15 % por 7 h e nenhum aviso saiu, porque toda leitura era "ocupado" (havia sessão segurando bead)
  cego     nenhuma leitura decidiu o estado há >= 1 h (sessões, CPU ou fila ilegíveis), OU a CPU não é lida há >= 1 h (com a CPU cega o aviso de CPU baixa está mudo, mesmo que a sessão prove "ocupado"); cooldown de 6 h
  foco     o foco do gate (gate-focus.state, mesma regra de 3 estados da gate-focus-lib.sh) liga: só conserto é despachado, então o aviso de ocioso se cala
  chave    o aviso só sai com <cidade>/.gc/hetzner-occupancy-alarm.on presente (e sem HETZNER_OCC_ALARM=0): sem ela é o modo só-medir, INERTE de propósito (mede e grava, nunca manda mail)
CAUSA, DEGRAUS E NÚMERO DO DIA  (ga-2hd02v.5.10; 04/11, das 10h às 14h: CPU em 24-47 % em 18 leituras seguidas (4 h36 abaixo da régua) e o vigia só avisava, não dizia por quê nem agia; pedido do Athos: monitorar de perto e agir)
  causa em números  a MESMA ssh da CPU traz também os contadores de cgroup v2 (cpu.stat do user-<uid>.slice e do ballast.slice), o iowait do /proc/stat, a MemAvailable e a lista de sessões do tmux do nó. Cada leitura do JSONL ganha
           `nucleos` = {sessoes, lastro, sistema, espera, livres} (núcleos MÉDIOS na janela; somam o ncpu): lastro = ballast.slice, sessoes = o resto do user-<uid>.slice (sessões e o que o mbp-run lança por ssh), sistema = o que sobra do
           ocupado (kernel, serviços do root), espera = iowait, livres = o que nem trabalha nem espera; `ram_mb` (MemAvailable); `lixo` = sessões do tmux do nó que a cidade não reconhece; e `causa`, UMA entre
           lixo > RAM > lastro-sem-trabalho > fila-sem-elegível > cego, só com a CPU lida e abaixo da régua (acima dela é null). A ordem é de PRIORIDADE, não prova de culpa: o que prova é o `efeito` medido na leitura seguinte.
           lixo = há sessão do tmux do nó (nome com -remote-) que a cidade não lista (em nenhum estado), não segura bead e está quieta há >= 30 min (HETZNER_OCC_D1_IDLE_S); RAM = MemAvailable abaixo do piso de partida do lastro (14336 MB,
           HETZNER_OCC_RAM_START_MB) mais um slot (1024 MB): subir o lastro é inútil; lastro-sem-trabalho = sobram >= 2 núcleos livres e há RAM para mais lastro; fila-sem-elegível = a fila elegível do Pilot (hq) lida e vazia;
           cego = o que falta para dizer a causa não foi lido (CPU, cgroup, RAM, fila) OU nenhuma das quatro explica. Leitura cega NUNCA vira "ocioso" nem dispara degrau (os 3 estados valem aqui também).
  degraus  só com a CPU abaixo da régua há >= 30 min (a sequência de `baixa`) e a causa dizendo qual: lixo → D1, lastro-sem-trabalho → D2, fila-sem-elegível → D3; um degrau que não resolve (tentativas esgotadas) deixa o seguinte agir. UM degrau por
           leitura e no mínimo 30 min (HETZNER_OCC_ACT_COOLDOWN_S) entre duas ações, para o efeito de cada uma ser medível. Cada degrau tem SUA chave em <cidade>/.gc (sem ela o degrau só mede: INERTE) e grava na leitura seguinte o `efeito` medido
           (CPU antes/depois da ação). Nada aqui liga a queima (burn.on) nem despacha bead de P2 ao mini (Athos, 12/10).
    D1 lixo     hetzner-occupancy-d1.on: mata a sessão do tmux do nó que a cidade não reconhece (precedente ga-vg16lk; caso real gate-reviewer-remote-adhoc-033f7bd5c1, 4 h parada em 04/11). Nunca mata sessão que a cidade lista, nem a que segura bead, nem a
                que mexeu nos últimos 30 min: o ssh que mata confere a quietude de novo no próprio nó (TOCTOU) e a lista da cidade e a dos donos de bead têm de ter sido LIDAS (ilegível = não mata). No máximo 2 por leitura.
    D2 lastro   hetzner-occupancy-d2.on: PEDE mais lastro gravando ~/gt-remote/ballast/lastro-pedido.json no nó ({v, epoch, ate, slots_extra, livres, ram_mb, quem}); quem consome é o governo do lastro (ga-2hd02v.5.11), que também aplica os pisos de RAM
                dele: o vigia só pede com MemAvailable >= piso + 1 slot, e o pedido vence em 2 leituras (ate). Sem consumidor o efeito medido é zero e a escada segue.
    D3 fila     hetzner-occupancy-d3.on: tira da memória de vereditos do Pilot (<cidade>/.gc/wa-node-pass-memo.tsv) as linhas `unknown` ainda frescas, e a passada seguinte reclassifica essas beads de WA; o «Só no ocioso» (P2+ só ocupa o nó quando
                nenhuma P0/P1 cabe lá, Athos 30/10; ga-2hd02v.3.18 e, na passada do disk floor, ga-2hd02v.3.26) já é do Pilot e vale para o que voltar `node`: o vigia não despacha nada.
    D4 esgotou  hetzner-occupancy-d4.on: abaixo da régua há >= 6 h (HETZNER_OCC_D4_AFTER_S), sem nenhum degrau aplicável que ainda tenha tentativa (ou com a causa RAM, em que nada cabe) → UM `notify` ao Athos por dia (quanto, por quê, o que foi tentado) e
                uma bead com a causa. O notify roda com NOTIFY_STRICT_EXIT=1 e o rc é conferido: 0 saiu, 10 segurado até as 7 h e 11 já tinha saído contam como entregue; 12 (digest/teto), 13, 14, timeout e qualquer outro NÃO saíram (04/11, ga-i4t0lzx:
                exit 12 e o aviso não chegou): o vigia manda o mesmo texto por `gc mail send mayor` uma vez e tenta o notify de novo a cada hora.
  número do dia  hetzner-occupancy-dia.on: na 1ª leitura de cada dia, se o dia anterior fechou com ocupacao_pct < régua (e >= 48 janelas de CPU lidas: dia cego não tem número), 1 notify ao Athos com o % e a causa principal do dia; dia na meta
           ou sem número não avisa (e não gasta o aviso).
ARQUIVOS (só em <cidade>/.gc): hetzner-occupancy.jsonl (uma leitura por rodada) · hetzner-occupancy-daily.json (o número por dia: ocupado/ocioso/desconhecido;
  ocupacao_pct = a média de CPU do nó no dia, ponderada pela janela (cpu_nucleos_s / cpu_capacidade_s; cpu_janelas = quantas janelas entraram), null se nenhuma janela foi lida;
  ocupacao_sessao_pct = ocupado/(ocupado+ocioso), o número que ocupacao_pct era até a ga-2hd02v.6, null se nenhuma leitura decidiu. Dia gravado antes dela fica com o número antigo
  em ocupacao_sessao_pct e ocupacao_pct null: a CPU daquele dia nunca foi somada) · hetzner-occupancy.state.json (baseline de CPU e contadores) · hetzner-occupancy.lock.
  Arquivo corrompido não some: a cópia fica em <arquivo>.corrupt-<epoch>.
USO      hetzner-occupancy-watch.py [--print] [--dry-run] [--print-config]
         exit 0 ok (inclui "outra instância rodando") · 1 crash (traceback no stderr) · 3 não consegui gravar
"""
import argparse
import base64
import calendar
import errno
import fcntl
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
import traceback
from types import SimpleNamespace

DEFAULT_CITY = "/Users/athos/gt/.gascity-gastown-hq"
LIVE = frozenset({"active", "awake"})  # = bead_state.LIVE_SESSION_STATES
DEAD = frozenset({"asleep", "drained", "closed", "archived", "quarantined", "failed-create"})  # = bead_state.DEAD_SESSION_STATES
WARMUP = frozenset({"sem-leitura-anterior", "leitura-anterior-velha", "contador-recuou", "relogio-recuou"})  # a CPU só semeou o baseline: não é "cego"
BEGIN, END = "@@OCC-BEGIN@@", "@@OCC-END@@"
S_CG, S_MEM, S_TMUX, S_NOW = "@@OCC-CG@@", "@@OCC-MEM@@", "@@OCC-TMUX@@", "@@OCC-NOW@@"
# A MESMA ssh traz o /proc/stat e o resto (ga-2hd02v.5.10): cada parte tem o seu marcador e a falha de uma não derruba as outras. `u` = cpu.stat do user-<uid>.slice, `l` = o do ballast.slice (some quando nada do lastro roda),
# `m 1` = o gerenciador de usuário existe (sem ele a ausência do `l` não quer dizer "lastro parado"). O tmux diz o rc antes da lista: "sem servidor" (rc 1) é lista vazia, qualquer outra falha NÃO é.
REMOTE_CMD = (
    "echo " + BEGIN + "; grep '^cpu' /proc/stat; U=$(id -u); B=/sys/fs/cgroup/user.slice/user-$U.slice; "
    "echo " + S_CG + "; [ -d \"$B/user@$U.service\" ] && echo m 1; "
    "for p in \"u:$B\" \"l:$B/user@$U.service/ballast.slice\"; do awk -v k=\"${p%%:*}\" '/^usage_usec/{print k, $2}' \"${p#*:}/cpu.stat\" 2>/dev/null; done; "
    "echo " + S_MEM + "; grep -E '^(MemAvailable|MemTotal):' /proc/meminfo; "
    "echo " + S_TMUX + "; o=$(tmux -L gc-remote list-sessions -F '#{session_name}|#{session_activity}' 2>&1); echo \"rc=$?\"; echo \"$o\"; "
    "echo " + S_NOW + "; date +%s; echo " + END
)
RUNGS = ("d1", "d2", "d3")  # a ordem da escada; o D4 (esgotou) é o aviso, não um degrau que age
CAUSAS = ("lixo", "RAM", "lastro-sem-trabalho", "fila-sem-elegível", "cego")
RUNG_OF_CAUSE = {"lixo": "d1", "lastro-sem-trabalho": "d2", "fila-sem-elegível": "d3"}  # a causa diz por qual degrau começa; RAM e cego não têm degrau
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,80}")
BALLAST_REQ = "lastro-pedido.json"
RULE = 2  # a regra que produziu a leitura (vai no JSONL como "regra"): 2 = ocupado é sessão que SEGURA bead (ga-l9q18u); leitura sem o campo é da regra 1, em que sessão viva bastava


class Fail(Exception):
    def __init__(self, msg, rc=3):
        Exception.__init__(self, msg)
        self.rc = rc


# ---- configuração ------------------------------------------------------------------------------------------------------------------------------------
def _num(env, key, default, cast, lo):
    v = cast(env.get(key, default))
    if not v >= lo:  # NaN também reprova
        raise ValueError("%s=%r abaixo do mínimo %r" % (key, v, lo))
    return v


def _names(env, key, default, allow_empty=False):
    out = [s.strip() for s in env.get(key, default).split(",") if s.strip()]
    if not out and not allow_empty:
        raise ValueError("%s vazio" % key)
    return out


def load_config(env):
    city = env.get("GC_CITY_PATH") or DEFAULT_CITY
    home = env.get("HOME") or os.path.expanduser("~")
    interval = _num(env, "HETZNER_OCC_INTERVAL_S", 900, int, 60)
    c = SimpleNamespace(
        city=city, gc_dir=os.path.join(city, ".gc"), interval_s=interval,
        busy_cores=_num(env, "HETZNER_OCC_BUSY_CORES", 0.5, float, 0.01),
        stores=_names(env, "HETZNER_OCC_STORES", "hq"),
        other_hosts=_names(env, "HETZNER_OCC_OTHER_HOSTS", "mbp", True),
        ssh_host=env.get("HETZNER_SSH_HOST", "hetzner-teste"),
        idle_after_s=_num(env, "HETZNER_OCC_IDLE_AFTER_S", 1800, int, 60),
        blind_after_s=_num(env, "HETZNER_OCC_BLIND_AFTER_S", 3600, int, 60),
        slack_s=120,  # o launchd não é relógio suíço: 3 leituras a 890 s ainda são "30 min"
        idle_cooldown_s=_num(env, "HETZNER_OCC_IDLE_COOLDOWN_S", 10800, int, 0),
        blind_cooldown_s=_num(env, "HETZNER_OCC_BLIND_COOLDOWN_S", 21600, int, 0),
        low_pct=_num(env, "HETZNER_OCC_LOW_PCT", 85, float, 0),  # 0 = nenhuma janela é baixa = aviso de CPU baixa desligado
        low_after_s=_num(env, "HETZNER_OCC_LOW_AFTER_S", 1800, int, 60), low_cooldown_s=_num(env, "HETZNER_OCC_LOW_COOLDOWN_S", 10800, int, 0),
        min_window_s=120, max_window_s=3 * interval, future_tol_s=60,
        ssh_timeout_s=_num(env, "HETZNER_OCC_SSH_TIMEOUT_S", 30, int, 1),
        gc_timeout_s=_num(env, "HETZNER_OCC_GC_TIMEOUT_S", 60, int, 1), bd_timeout_s=_num(env, "HETZNER_OCC_BD_TIMEOUT_S", 60, int, 1),
        focus_stale_s=_num(env, "GATE_FOCUS_STALE_S", 7200, int, 1),
        pilot_file=env.get("HETZNER_OCC_PILOT_FILE") or os.path.join(home, ".gc", "pilot-dispatchable.json"),
        gc_bin=env.get("GC_BIN", "gc"), ssh_bin=env.get("SSH_BIN", "ssh"), bd_bin=env.get("BD_BIN", "bd"), notify_bin=env.get("NOTIFY_BIN", "notify"),
        # a escada (ga-2hd02v.5.10): o que é "lixo", o intervalo entre ações, as tentativas por degrau, quando o D4 desiste e os pisos de RAM do lastro (os do hetzner-ballast.py: partida 14336, pausa 10240, morte 7168)
        d1_idle_s=_num(env, "HETZNER_OCC_D1_IDLE_S", 1800, int, 60), d1_max=_num(env, "HETZNER_OCC_D1_MAX", 2, int, 1),
        act_cooldown_s=_num(env, "HETZNER_OCC_ACT_COOLDOWN_S", 1800, int, 0), act_tries=_num(env, "HETZNER_OCC_ACT_TRIES", 2, int, 1),
        d4_after_s=_num(env, "HETZNER_OCC_D4_AFTER_S", 21600, int, 60), notify_retry_s=_num(env, "HETZNER_OCC_NOTIFY_RETRY_S", 3600, int, 0), notify_timeout_s=_num(env, "HETZNER_OCC_NOTIFY_TIMEOUT_S", 60, int, 1),
        ram_start_mb=_num(env, "HETZNER_OCC_RAM_START_MB", 14336, int, 0), ram_slot_mb=_num(env, "HETZNER_OCC_RAM_SLOT_MB", 1024, int, 1),
        min_free_cores=_num(env, "HETZNER_OCC_MIN_FREE_CORES", 2, float, 0.1), day_min_windows=_num(env, "HETZNER_OCC_DAY_MIN_WINDOWS", 48, int, 1),
        ballast_home=env.get("HETZNER_OCC_BALLAST_HOME", "~/gt-remote/ballast"),
        wa_memo=env.get("HETZNER_OCC_WA_MEMO") or os.path.join(city, ".gc", "wa-node-pass-memo.tsv"), memo_unknown_ttl_s=_num(env, "PILOT_WA_NODE_PASS_UNKNOWN_TTL", 3600, int, 1),
        now=_now(env),
    )
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@-]*", c.ssh_host):
        raise ValueError("HETZNER_SSH_HOST inválido: %r" % c.ssh_host)
    if c.low_pct > 100:  # acima de 100 toda janela seria "baixa": o aviso sairia a cada cooldown para sempre (inf também cai aqui; NaN já reprovou no _num)
        raise ValueError("HETZNER_OCC_LOW_PCT=%r acima de 100" % c.low_pct)
    if not re.fullmatch(r"~?/?[A-Za-z0-9._/-]+", c.ballast_home) or ".." in c.ballast_home:
        raise ValueError("HETZNER_OCC_BALLAST_HOME inválido: %r" % c.ballast_home)
    c.alarm_key = os.path.join(c.gc_dir, "hetzner-occupancy-alarm.on")
    c.alarm = env.get("HETZNER_OCC_ALARM") != "0" and os.path.exists(c.alarm_key)  # chave ilegível/ausente = desligado (o estado inerte)
    # uma chave por degrau (e uma para o número do dia): ausente/ilegível = o degrau só mede, nunca age. HETZNER_OCC_ACT=0 desliga todas de uma vez
    c.keys = {k: os.path.join(c.gc_dir, "hetzner-occupancy-%s.on" % k) for k in ("d1", "d2", "d3", "d4", "dia")}
    c.on = {k: env.get("HETZNER_OCC_ACT") != "0" and os.path.exists(p) for k, p in c.keys.items()}
    return c


def _now(env):
    raw = env.get("HETZNER_OCC_NOW", "").strip()
    return int(raw) if raw else int(time.time())


# ---- processos e arquivos ----------------------------------------------------------------------------------------------------------------------------
def run_cmd(argv, timeout, env=None):
    """(rc, stdout, stderr, porque). porque: None = rodou até o fim · 'timeout' (o grupo de processos inteiro morre) · 'nao-executou'. env = variáveis a MAIS (o notify precisa das suas)."""
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, errors="replace", start_new_session=True,
                             env=dict(os.environ, **env) if env else None)
    except OSError as e:
        return None, "", str(e), "nao-executou"
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=5)
        except Exception:
            pass
        return None, "", "", "timeout"
    return p.returncode, out, err, None


def _failed(rc, why, prefix):
    """'<prefix>-timeout' / '<prefix>-falhou' se o comando não deu certo; None se rodou e saiu 0."""
    if why == "timeout":
        return prefix + "-timeout"
    return prefix + "-falhou" if (why or rc != 0) else None


def _oneline(s, n=160):
    return " ".join((s or "").split())[:n]


def load_json(path, valid, now, dry):
    """O objeto lido, ou None (ausente ou corrompido). Corrompido: a cópia fica em <arquivo>.corrupt-<epoch> (menos no --dry-run) e o stderr avisa."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise Fail("não consegui ler %s: %s" % (path, e))
    try:
        obj = json.loads(raw.decode("utf-8"))
        if valid(obj):
            return obj
    except ValueError:  # JSONDecodeError e UnicodeDecodeError
        pass
    dest, n = "%s.corrupt-%d" % (path, now), 1
    while os.path.exists(dest):
        n += 1
        dest = "%s.corrupt-%d-%d" % (path, now, n)
    if not dry:
        try:
            os.replace(path, dest)
        except OSError as e:
            raise Fail("não consegui gravar a cópia de %s: %s" % (path, e))
    print("hetzner-occupancy-watch: AVISO: %s estava corrompido; %s %s" % (path, "a cópia ficou em" if not dry else "(--dry-run) a cópia iria para", dest), file=sys.stderr)
    return None


def write_atomic(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise Fail("não consegui gravar %s: %s" % (path, e))


def append_line(path, line):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, (line + "\n").encode("utf-8"))
        finally:
            os.close(fd)
    except OSError as e:
        raise Fail("não consegui gravar %s: %s" % (path, e))


def take_lock(gc_dir):
    """fd do travamento; None se outra instância já o tem. Não conseguir nem abrir o arquivo = Fail (rc 3)."""
    try:
        os.makedirs(gc_dir, exist_ok=True)
        fd = os.open(os.path.join(gc_dir, "hetzner-occupancy.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as e:
        raise Fail("não consegui gravar em %s: %s" % (gc_dir, e))
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            return None
        raise Fail("não consegui travar %s: %s" % (gc_dir, e))
    return fd


# ---- leitura 1: sessões remotas ----------------------------------------------------------------------------------------------------------------------
def _ident(s):
    if not isinstance(s, dict):
        return None
    for k in ("session_name", "name", "template"):
        if isinstance(s.get(k), str) and s[k]:
            return s[k]
    return None


def _owners(s):
    """Os nomes pelos quais uma bead in_progress aponta para a sessão: o Pilot atribui ao ALIAS do pool (dog-remote-2); session_name e name também valem."""
    return [s[k] for k in ("session_name", "name", "alias") if isinstance(s.get(k), str) and s[k]]


def read_holders(c):
    """(donos, None, None) ou (None, motivo, detalhe). donos = os assignees das beads in_progress: a sessão que segura uma delas é a que trabalha. Uma leitura, só `list`."""
    # vazio → lista [] = ninguém segura bead (leu); falhou/ilegível/travou → (None, motivo): o chamador deixa 'ocupadas' null e a sessão viva não prova nada (nunca "ocioso")
    rc, out, err, why = run_cmd([c.bd_bin, "-C", c.city, "list", "--status", "in_progress", "--json", "--limit", "0"], c.bd_timeout_s)
    motivo = _failed(rc, why, "bd")
    if motivo:
        return None, motivo, _oneline(err)
    try:
        lst = json.loads(out)
    except ValueError:
        return None, "json-ilegivel" if out.strip() else "saida-vazia", ""
    if not isinstance(lst, list) or not all(isinstance(b, dict) and (b.get("assignee") is None or isinstance(b["assignee"], str)) for b in lst):
        return None, "forma-desconhecida", ""
    return {b["assignee"] for b in lst if b.get("assignee")}, None, None


def read_sessions(c):
    # `_reconhecidas` (todo nome que a cidade lista, em qualquer estado, host ou alias) e `_donos` (os assignees de bead in_progress) NÃO vão ao JSONL (o run os tira): servem ao D1, que só mata o que a cidade não reconhece
    r = {"lido": False, "ativas": None, "ocupadas": None, "nomes": [], "nomes_ocupadas": [], "motivo": None, "_reconhecidas": None, "_donos": None}
    rc, out, err, why = run_cmd([c.gc_bin, "--city", c.city, "session", "list", "--json"], c.gc_timeout_s)
    r["motivo"] = _failed(rc, why, "gc")
    if r["motivo"]:
        r["detalhe"] = _oneline(err)
        return r
    try:
        d = json.loads(out)
    except ValueError:
        r["motivo"] = "json-ilegivel" if out.strip() else "saida-vazia"
        return r
    if isinstance(d, dict) and "ok" in d and d["ok"] is not True:  # envelope de erro ({"ok":false,...}): a lista que vier junto não vale (a regra do worktree-reaper)
        r["motivo"] = "ok-falso"
        return r
    lst = d.get("sessions") if isinstance(d, dict) else None
    if not isinstance(lst, list):
        r["motivo"] = "sem-lista-sessions"
        return r
    other = re.compile(r"-remote-(%s)(-|$)" % "|".join(re.escape(h) for h in c.other_hosts)) if c.other_hosts else None
    active, live, bad_entry, bad_state, known = [], [], 0, 0, set()
    for s in lst:
        ident = _ident(s)
        if isinstance(s, dict):
            known.update(_owners(s))  # o que a cidade conhece por nome, qualquer estado (viva, dormindo, fechada, de outro host): o D1 só mata o que NÃO está aqui
            if ident:
                known.add(ident)
        if ident is None:
            bad_entry += 1
        elif "-remote-" not in "-%s-" % ident or (other and other.search(ident)):
            continue  # sessão local, ou de outro host remoto: não é ocupação do Hetzner
        elif s.get("closed"):
            continue
        elif isinstance(s.get("state"), str) and s["state"] in LIVE:
            active.append(ident)
            live.append((ident, _owners(s)))
        elif not (isinstance(s.get("state"), str) and s["state"] in DEAD):
            bad_state += 1  # state ausente ou fora do vocabulário (draining, start-pending...): não dá para dizer que trabalha nem que dorme
    if not bad_entry:  # uma entrada sem nome pode ser justamente a sessão que o tmux tem: com ela ilegível a lista não prova que "a cidade não conhece" nada
        r["_reconhecidas"] = known
    if bad_entry + bad_state:
        r["ilegiveis"] = bad_entry + bad_state
    unreadable = "entrada-ilegivel" if bad_entry else "estado-ilegivel"
    if not active:
        if bad_entry or bad_state:
            r["motivo"] = unreadable
        else:
            r.update(lido=True, ativas=0, ocupadas=0)  # nenhuma viva: o bd nem é chamado (e o Dolt fora do ar não atrapalha)
        return r
    r.update(ativas=len(active), nomes=sorted(active))  # o gc leu: as vivas contam mesmo que o bd falhe, mas viva não é ocupada
    held, why, detail = read_holders(c)
    if held is None:
        r["motivo"], r["detalhe"] = why, detail  # ocupadas fica null (não 0): não sei quem segura bead
        return r
    r["_donos"] = held
    mine = sorted(i for i, owners in live if held.intersection(owners))
    r.update(ocupadas=len(mine), nomes_ocupadas=mine)
    if mine:  # uma sessão que segura bead provada basta, mesmo com entrada ilegível ou sem nome ao lado
        r["lido"] = True
    elif bad_entry or bad_state:
        r["motivo"] = unreadable  # a ilegível pode ser a que trabalha
    elif any(not owners for _i, owners in live):
        r["motivo"] = "sessao-sem-dono"  # viva sem session_name, alias nem name: não dá para casar com bead
    else:
        r["lido"] = True
    return r


# ---- leitura 2: CPU do nó (/proc/stat por ssh) -------------------------------------------------------------------------------------------------------
def parse_stat(out):
    """((busy, total, ncpu), None) ou (None, motivo). busy = user+nice+system+irq+softirq; total = os 8 primeiros campos (guest já está em user)."""
    lines = [ln.strip() for ln in out.splitlines()]
    if BEGIN not in lines or END not in lines[lines.index(BEGIN) + 1:]:
        return None, "sem-marcador"
    i = lines.index(BEGIN)
    body = lines[i + 1:lines.index(END, i + 1)]
    body = body[:next((k for k, ln in enumerate(body) if ln == S_CG), len(body))]  # só o /proc/stat: depois do marcador é a leitura irmã (cgroup, RAM, tmux), que não tem linha `cpu`
    agg, ncpu = None, 0
    for ln in body:
        f = ln.split()
        if f and f[0] == "cpu":
            agg = f
        elif f and re.fullmatch(r"cpu[0-9]+", f[0]):
            ncpu += 1
    try:
        v = [int(x) for x in agg[1:9]] if agg else []
    except ValueError:
        v = []
    if len(v) < 8 or min(v) < 0:
        return None, "linha-cpu-ilegivel"
    if ncpu == 0:
        return None, "sem-nucleos"
    total = sum(v)
    return (total - v[3] - v[4] - v[7], total, ncpu), None


def _baseline_ok(b):
    return isinstance(b, dict) and all(isinstance(b.get(k), int) and not isinstance(b.get(k), bool) and b[k] >= 0 for k in ("epoch", "busy", "total"))


def read_cpu(c, base, now, raw=None):
    """(cpu, novo_baseline|None, núcleos). novo_baseline None = manter o antigo; a falha de leitura NUNCA apaga o baseline. `raw` (dict, opcional) recebe a saída da ssh (`out`) e o que o parse_stat leu
    (`busy`, `total`, `ncpu`) para as leituras irmãs da causa: o retorno e o baseline do CPU não mudam por causa dele."""
    cpu = {"lido": False, "nucleos": None, "ncpu": None, "janela_s": None, "pct": None, "motivo": None}
    argv = [c.ssh_bin, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", c.ssh_host, REMOTE_CMD]
    rc, out, err, why = run_cmd(argv, c.ssh_timeout_s)
    cpu["motivo"] = _failed(rc, why, "ssh")
    if cpu["motivo"]:
        cpu["detalhe"] = _oneline(err)
        return cpu, None, None
    if raw is not None:
        raw["out"] = out
    got, cpu["motivo"] = parse_stat(out)
    if got is None:
        return cpu, None, None
    busy, total, ncpu = got
    cpu["ncpu"] = ncpu
    if raw is not None:
        raw.update(busy=busy, total=total, ncpu=ncpu)
    now_b = {"epoch": now, "busy": busy, "total": total}
    if not _baseline_ok(base):
        cpu["motivo"] = "sem-leitura-anterior"
        return cpu, now_b, None
    win = now - base["epoch"]
    cpu["janela_s"] = win
    if win < 0:
        cpu["motivo"] = "relogio-recuou"
        return cpu, now_b, None
    if win < c.min_window_s:
        cpu["motivo"] = "janela-curta"
        return cpu, None, None
    if win > c.max_window_s:
        cpu["motivo"] = "leitura-anterior-velha"
        return cpu, now_b, None
    db, dt = busy - base["busy"], total - base["total"]
    if db < 0 or dt < 0:
        cpu["motivo"] = "contador-recuou"
        return cpu, now_b, None
    if dt == 0:
        cpu["motivo"] = "sem-tick"
        return cpu, None, None
    cores = db * ncpu / dt
    cpu.update(lido=True, nucleos=round(cores, 2), pct=round(100.0 * db / dt, 1), motivo=None)
    return cpu, now_b, cores


# ---- leituras irmãs da CPU: de onde vem o número (cgroup, iowait, RAM, tmux do nó) -----------------------------------------------------------------------
def _section(lines, mark):
    """As linhas entre o marcador e o próximo marcador; None se o marcador não veio (parte que falta ≠ parte vazia)."""
    if mark not in lines:
        return None
    out = []
    for ln in lines[lines.index(mark) + 1:]:
        if ln.startswith("@@OCC-"):
            break
        out.append(ln)
    return out


def parse_extra(out):
    """O que a ssh traz além do /proc/stat. Cada parte é lida sozinha e a que falta fica None/lido=False, NUNCA zero: o que não li não é "nada rodando"."""
    ex = {"iow": None, "u": None, "l": None, "m": False, "cg": False, "ram_mb": None, "node_now": None, "tmux": {"lido": False, "sessoes": [], "motivo": "sem-secao"}}
    lines = [ln.strip() for ln in (out or "").splitlines()]
    if BEGIN not in lines or END not in lines[lines.index(BEGIN) + 1:]:
        return ex
    i = lines.index(BEGIN)
    lines = lines[i + 1:lines.index(END, i + 1)]
    head = lines[:next((k for k, ln in enumerate(lines) if ln.startswith("@@OCC-")), len(lines))]
    for ln in head:
        f = ln.split()
        if f and f[0] == "cpu" and len(f) >= 9 and re.fullmatch(r"[0-9]+", f[5]):
            ex["iow"] = int(f[5])  # user nice system idle IOWAIT irq softirq steal
    cg = _section(lines, S_CG)
    if cg is not None:
        ex["cg"] = True
        for ln in cg:
            f = ln.split()
            if len(f) == 2 and re.fullmatch(r"[0-9]+", f[1]):
                if f[0] == "m":
                    ex["m"] = True
                elif f[0] in ("u", "l"):
                    ex[f[0]] = int(f[1])
    mem = _section(lines, S_MEM)
    for ln in mem or []:
        m = re.fullmatch(r"MemAvailable:\s+([0-9]+)\s*kB", ln)
        if m:
            ex["ram_mb"] = int(m.group(1)) // 1024
    t, tm = ex["tmux"], _section(lines, S_TMUX)
    if tm is not None:
        if not tm or not re.fullmatch(r"rc=[0-9]+", tm[0]):
            t["motivo"] = "rc-ausente"
        else:
            rc, body = int(tm[0][3:]), [x for x in tm[1:] if x]
            if rc == 0:
                ses, bad = [], 0
                for ln in body:
                    name, sep, act = ln.rpartition("|")
                    if sep and name and re.fullmatch(r"[0-9]+", act):
                        ses.append((name, int(act)))
                    else:
                        bad += 1
                t.update(lido=not bad, sessoes=ses if not bad else [], motivo="linha-ilegivel" if bad else None)
            elif rc == 1 and body and re.match(r"(no server running|error connecting to .*No such file or directory)", body[0]):
                t.update(lido=True, sessoes=[], motivo=None)  # sem servidor tmux no nó = nenhuma sessão (leu); qualquer outra falha do tmux NÃO é lista vazia
            else:
                t["motivo"] = "tmux-rc-%d" % rc
    nw = _section(lines, S_NOW)
    if nw and re.fullmatch(r"[0-9]+", nw[0]):
        ex["node_now"] = int(nw[0])
    return ex


def _extra_base_ok(b):
    return (isinstance(b, dict) and all(isinstance(b.get(k), int) and not isinstance(b.get(k), bool) and b[k] >= 0 for k in ("epoch", "u", "iow", "busy", "total"))
            and (b.get("l") is None or (isinstance(b["l"], int) and not isinstance(b["l"], bool) and b["l"] >= 0)))


def read_nucleos(c, base, ex, raw, now):
    """(nucleos, novo_baseline|None): a CPU da janela repartida em núcleos MÉDIOS (somam o ncpu): sessoes, lastro, sistema, espera (iowait) e livres. Baseline próprio (`cpu_extra`), separado do da CPU.
    Janela inválida (1ª leitura, relógio, contador que recuou, fatia do lastro que sumiu) = lido False com o motivo: nunca um número chutado. Sem `l` nas duas pontas, com o gerenciador de usuário de pé, o lastro foi 0."""
    n = {"lido": False, "sessoes": None, "lastro": None, "sistema": None, "espera": None, "livres": None, "janela_s": None, "motivo": None}
    if not raw or "busy" not in raw:
        n["motivo"] = "sem-leitura-cpu"
        return n, None
    if not ex["cg"] or ex["u"] is None:
        n["motivo"] = "cgroup-ilegivel"
        return n, None
    if ex["iow"] is None:
        n["motivo"] = "iowait-ilegivel"
        return n, None
    if ex["l"] is None and not ex["m"]:
        n["motivo"] = "sem-gerenciador-de-usuario"  # sem ele a ausência do `l` não diz "lastro parado": pode ser a leitura que falhou
        return n, None
    cur = {"epoch": now, "u": ex["u"], "l": ex["l"], "iow": ex["iow"], "busy": raw["busy"], "total": raw["total"]}
    if not _extra_base_ok(base):
        n["motivo"] = "sem-leitura-anterior"
        return n, cur
    win = now - base["epoch"]
    n["janela_s"] = win
    if win < 0:
        n["motivo"] = "relogio-recuou"
        return n, cur
    if win < c.min_window_s:
        n["motivo"] = "janela-curta"
        return n, None
    if win > c.max_window_s:
        n["motivo"] = "leitura-anterior-velha"
        return n, cur
    du, dio, db, dt = cur["u"] - base["u"], cur["iow"] - base["iow"], cur["busy"] - base["busy"], cur["total"] - base["total"]
    if min(du, dio, db, dt) < 0:
        n["motivo"] = "contador-recuou"
        return n, cur
    if dt == 0:
        n["motivo"] = "sem-tick"
        return n, None
    pl, l = base.get("l"), cur["l"]
    if pl is not None and (l is None or l < pl):
        n["motivo"] = "lastro-sumiu" if l is None else "contador-recuou"  # a fatia do lastro foi recriada: não sei o quanto rodou antes de sumir
        return n, cur
    dl = l if pl is None and l is not None else (l - pl if l is not None else 0)  # fatia nascida na janela conta do zero; ausente nas duas pontas = 0
    ncpu, us = raw["ncpu"], win * 1e6
    busy_c, user_c = db * ncpu / dt, du / us
    if user_c > ncpu * 1.1:
        n["motivo"] = "contador-implausivel"  # o cgroup diz mais núcleos do que o nó tem: um dos dois contadores não é o que penso
        return n, cur
    n.update(lido=True, lastro=round(dl / us, 2), sessoes=round(max(0, du - dl) / us, 2), sistema=round(max(0.0, busy_c - user_c), 2), espera=round(dio * ncpu / dt, 2),
             livres=round(max(0.0, ncpu - busy_c - dio * ncpu / dt), 2), motivo=None)  # steal não entra em nenhuma conta: cai em `livres` (no nó dedicado é ~0)
    return n, cur


def find_lixo(c, sess, ex):
    """O lixo do D1: sessão do tmux do nó (nome com -remote-) que a cidade NÃO lista em estado nenhum, não segura bead e está quieta há >= HETZNER_OCC_D1_IDLE_S. Três estados: o tmux, a lista da cidade,
    o relógio do nó e os donos de bead têm de ter sido LIDOS; o que não li dá lido False (e o D1 não mata nada). `_alvos` (interno) = os nomes a matar, os mais quietos primeiro."""
    r = {"lido": False, "n": 0, "nomes": [], "ocioso_max_s": None, "motivo": None, "_alvos": []}
    t = ex["tmux"]
    if not t["lido"]:
        r["motivo"] = "tmux-ilegivel:" + str(t["motivo"])
        return r
    known = sess.get("_reconhecidas")
    if known is None:
        r["motivo"] = "cidade-ilegivel"
        return r
    if ex["node_now"] is None:
        r["motivo"] = "sem-relogio-do-no"
        return r
    other = re.compile(r"-remote-(%s)(-|$)" % "|".join(re.escape(h) for h in c.other_hosts)) if c.other_hosts else None
    cand = []
    for name, act in t["sessoes"]:
        if "-remote-" not in "-%s-" % name or not SAFE_NAME.fullmatch(name) or name in known or (other and other.search(name)):
            continue
        idle = ex["node_now"] - act
        if idle >= c.d1_idle_s:
            cand.append((idle, name))
    if cand:
        donos = sess.get("_donos")
        if donos is None:
            donos, why, _d = read_holders(c)  # a cidade pode estar sem sessão viva (o bd nem foi chamado) ou o bd falhou: leio agora, e se não leio, não mato
            if donos is None:
                r["motivo"] = "donos-ilegivel:" + str(why)
                return r
        cand = [(i, n) for i, n in cand if n not in donos]
    cand.sort(key=lambda x: (-x[0], x[1]))
    r.update(lido=True, n=len(cand), nomes=[n for _i, n in cand[:3]], ocioso_max_s=cand[0][0] if cand else None, _alvos=[n for _i, n in cand[:c.d1_max]])
    return r


# ---- leitura 3: fila do Pilot e foco do gate ---------------------------------------------------------------------------------------------------------
def _iso_epoch(s):
    try:
        return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        return None


def read_queue(c, now):
    r = {"lido": False, "n": None, "ids": [], "motivo": None}
    try:
        with open(c.pilot_file, encoding="utf-8") as f:
            d = json.load(f)
    except FileNotFoundError:
        r["motivo"] = "arquivo-ausente"
        return r
    except (OSError, ValueError):
        r["motivo"] = "arquivo-ilegivel"
        return r
    items = d.get("items") if isinstance(d, dict) else None
    if not isinstance(items, list):
        r["motivo"] = "forma-desconhecida"
        return r
    gen, ttl = _iso_epoch(d.get("generated_at")), d.get("ttl_seconds")
    if gen is None:
        r["motivo"] = "generated_at-ilegivel"
    elif isinstance(ttl, bool) or not isinstance(ttl, (int, float)):
        r["motivo"] = "sem-ttl"
    elif now - gen > ttl:
        r["motivo"] = "velho"  # só passa do ttl é velho (mesma conta do approved-state-reconciler)
    elif now - gen < -c.future_tol_s:
        r["motivo"] = "no-futuro"
    elif not all(isinstance(it, dict) and isinstance(it.get("store"), str) for it in items):
        r["motivo"] = "forma-desconhecida"
    if r["motivo"]:
        return r
    elig = [str(it.get("id", "?")) for it in items if it["store"] in c.stores]
    r.update(lido=True, n=len(elig), ids=elig[:5])
    return r


def read_focus(c, now):
    """ligado / desligado / desconhecido: a mesma regra de gate_focus_active (gate-focus-lib.sh); desconhecido avisa como se estivesse desligado."""
    kv = {}
    try:
        with open(os.path.join(c.gc_dir, "gate-focus.state"), encoding="utf-8") as f:
            for ln in f:
                k, sep, v = ln.rstrip("\n").partition("=")
                if sep and k not in kv:
                    kv[k] = v
    except (OSError, ValueError):
        return "desconhecido"
    active, at = kv.get("active"), kv.get("at", "")
    if active not in ("0", "1") or not re.fullmatch(r"[0-9]+", at):
        return "desconhecido"
    if now - int(at) > c.focus_stale_s or int(at) > now + 60:
        return "desconhecido"
    return "ligado" if active == "1" else "desligado"


# ---- estado, sequências e aviso ----------------------------------------------------------------------------------------------------------------------
def decide(sess, cpu, cores, busy_cores):
    if (sess["lido"] and sess["ocupadas"]) or (cpu["lido"] and cores >= busy_cores):
        return "ocupado"
    if sess["lido"] and cpu["lido"]:
        return "ocioso"
    return "desconhecido"


def _int(v, default=None):
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else default


def _flt(v, default=None):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v >= 0 else default


def _mins(s):
    return int(round(s / 60.0))


def _avg_pct(nucleos_s, capacidade_s):
    """% da capacidade usada: núcleos-segundo ocupados / núcleos-segundo disponíveis. Sem capacidade medida é None (não 0 %: ninguém mediu)."""
    return round(100.0 * nucleos_s / capacidade_s, 1) if capacidade_s else None


def _show(v, none="não lido"):
    return none if v is None else str(v)


def low_streak(c, st, cpu, cores, now):
    """A sequência de janelas de CPU seguidas, cada uma com média abaixo da régua: {n, desde, nucleos_s, cap_s}. n = 0 = sem sequência. `desde` é o INÍCIO da janela da 1ª (a CPU é
    uma média sobre a janela inteira, então 2 janelas de 15 min = 30 min medidos). Só uma janela LIDA entra: CPU ilegível ou alta zera, nunca estende."""
    if not (cpu["lido"] and cpu["pct"] < c.low_pct):
        return {"n": 0, "desde": None, "nucleos_s": None, "cap_s": None}
    win_n, win_c = cores * cpu["janela_s"], cpu["ncpu"] * cpu["janela_s"]
    # vazio → sem sequência anterior (recomeça aqui); falhou/ilegível/no futuro (estado editado à mão, relógio que recuou) → recomeça aqui também: nunca SOMA um número que não confere (a janela de agora vale por si, medida pelos contadores)
    prev_n, since, acc_n, acc_c = _int(st.get("baixas_seguidas"), 0), _int(st.get("baixa_desde")), _flt(st.get("baixa_nucleos_s")), _flt(st.get("baixa_capacidade_s"))
    if prev_n > 0 and since is not None and since <= now and acc_n is not None and acc_c is not None:
        return {"n": prev_n + 1, "desde": since, "nucleos_s": acc_n + win_n, "cap_s": acc_c + win_c}
    return {"n": 1, "desde": now - cpu["janela_s"], "nucleos_s": win_n, "cap_s": win_c}


def migrate_daily(daily):
    """Dia gravado antes da ga-2hd02v.6 (sem cpu_janelas): o `ocupacao_pct` dele é o número de SESSÃO. Ele passa a se chamar ocupacao_sessao_pct e `ocupacao_pct` (a média de CPU) fica null:
    a CPU daquele dia nunca foi somada, e um número de sessão com cara de CPU seria pior que nenhum. Uma vez só: depois da 1ª passada o dia tem cpu_janelas."""
    for day in daily["dias"].values():
        if isinstance(day, dict) and "cpu_janelas" not in day:
            if "ocupacao_pct" in day and "ocupacao_sessao_pct" not in day:
                day["ocupacao_sessao_pct"] = day["ocupacao_pct"]
            day.update(ocupacao_pct=None, cpu_janelas=0, cpu_nucleos_s=0.0, cpu_capacidade_s=0)


def idle_mail(c, rd, span):
    fila, sess, cpu = rd["fila"], rd["sessoes"], rd["cpu"]
    foco = rd["foco"] + (" (tratado como desligado)" if rd["foco"] == "desconhecido" else "")
    subj = "Hetzner ocioso há %d min com %d bead(s) aprovada(s) na fila" % (_mins(span), fila["n"])
    body = "\n".join([
        "Estado do mundo: o nó Hetzner (%s) está OCIOSO há %d min (%d leituras seguidas, a cada %d min) e o Pilot tem %d bead(s) aprovada(s) esperando. "
        "Regra do Athos (14/10): o Hetzner pago trabalha sempre." % (c.ssh_host, _mins(span), rd["ociosas_seguidas"], _mins(c.interval_s), fila["n"]),
        "• sessões remotas vivas: %s · segurando bead: %s · CPU: %s núcleo(s) ocupado(s) de %s na última janela de %s s (régua: %s)" % (
            sess["ativas"], sess["ocupadas"], cpu["nucleos"], cpu["ncpu"], cpu["janela_s"], c.busy_cores),
        "• fila (até %d; primeiros ids): %s" % (fila["n"], ", ".join(fila["ids"])),
        "• foco do gate: " + foco,
        "A fila é lida do pilot-dispatchable.json ANTES dos vetos de pool e do freio de top-up: parte dela pode estar vetada, então o número é um teto, não uma promessa.",
        "O vigia não atribui nem despacha bead nenhuma; mede, avisa e, só nos degraus cuja chave .on existe, age (mata sessão sem dono, pede lastro, reclassifica a fila de WA). Próximo aviso deste tipo em no mínimo %d h. Voltar a só-medir: rm %s" % (c.idle_cooldown_s // 3600, c.alarm_key),
    ])
    return subj, body


def blind_mail(c, rd, span, cpu_span=None):
    """span = minutos sem leitura que decidisse o ESTADO (None = o estado não está cego); cpu_span = minutos sem ler a CPU (None = a CPU está lida). Pelo menos um dos dois."""
    sess, cpu, fila = rd["sessoes"], rd["cpu"], rd["fila"]
    subj = "Hetzner: vigia de ocupação CEGO há %d min (não consigo medir)" % _mins(max(s for s in (span, cpu_span) if s is not None))
    lines = []
    if span is not None:
        lines.append("Estado do mundo: há %d min (%d leituras) o vigia não consegue dizer se o nó Hetzner está ocioso ou ocupado. Enquanto isso NENHUM aviso de ocioso sai "
                     "(leitura que falha nunca vira \"ocioso\")." % (_mins(span), rd["cegas_seguidas"]))
    if cpu_span is not None:
        lines.append("%s há %d min (%d leituras) o vigia não consegue ler a CPU do nó Hetzner. Enquanto isso o aviso de CPU baixa NÃO sai (leitura que falha nunca vira \"CPU baixa\"), "
                     "mesmo que uma sessão segurando bead mantenha o estado em \"ocupado\"." % ("Estado do mundo:" if span is None else "E", _mins(cpu_span), rd["cpu_cegas_seguidas"]))
    body = "\n".join(lines + [
        "• sessões: %s · CPU: %s · fila: %s" % (sess["motivo"] or "ok", cpu["motivo"] or "ok", fila["motivo"] or "ok"),
        "• detalhe: %s" % (_oneline(sess.get("detalhe", "") + " " + cpu.get("detalhe", ""), 200) or "-"),
        "Conferir no mini: a lista de sessões do gc, o ssh %s e a idade do ~/.gc/pilot-dispatchable.json. Próximo aviso deste tipo em no mínimo %d h." % (c.ssh_host, c.blind_cooldown_s // 3600),
    ])
    return subj, body


def low_mail(c, rd, low):
    fila, sess, cpu = rd["fila"], rd["sessoes"], rd["cpu"]
    span, media = rd["epoch"] - low["desde"], _avg_pct(low["nucleos_s"], low["cap_s"])
    foco = rd["foco"] + (" (tratado como desligado)" if rd["foco"] == "desconhecido" else "")
    subj = "Hetzner abaixo da meta: CPU média de %s%% há %d min (aviso abaixo de %g%%)" % (media, _mins(span), c.low_pct)
    body = "\n".join([
        "Estado do mundo: a CPU do nó Hetzner (%s) está abaixo de %g%% há %d min (%d janelas seguidas de CPU): média de %s%%. Meta do Athos (20/10): o nó pago fica com a CPU perto de 100%% o tempo todo."
        % (c.ssh_host, c.low_pct, _mins(span), low["n"], media),
        "• última janela: %s%% (%s núcleo(s) de %s ocupados, janela de %s s)" % (cpu["pct"], cpu["nucleos"], cpu["ncpu"], cpu["janela_s"]),
        "• contexto (não entra na decisão): sessões remotas vivas: %s · segurando bead: %s · fila do Pilot (hq): %s · foco do gate: %s" % (
            _show(sess["ativas"]), _show(sess["ocupadas"]), _show(fila["n"], "não lida"), foco),
    ] + ([cause_line(rd)] if cause_line(rd) else []) + [
        "Este aviso NÃO depende de fila nem de sessão: com sessão segurando bead e a CPU parada ele sai do mesmo jeito (foi o que faltou na madrugada de 20/10, 7 h com 0 a 15% de CPU e zero aviso). "
        "A fila, quando lida, é a do Pilot ANTES dos vetos de pool e do freio de top-up: é um teto, não uma promessa.",
        "O vigia não atribui nem despacha bead nenhuma; mede, avisa e, só nos degraus cuja chave .on existe, age (mata sessão sem dono, pede lastro, reclassifica a fila de WA). Próximo aviso deste tipo em no mínimo %d h. Voltar a só-medir: rm %s" % (c.low_cooldown_s // 3600, c.alarm_key),
    ])
    return subj, body


def send_mail(c, subj, body):
    rc, _o, _e, why = run_cmd([c.gc_bin, "--city", c.city, "mail", "send", "mayor", "-s", subj, "-m", body], 45)
    return why is None and rc == 0


# ---- a causa, a escada e o aviso (ga-2hd02v.5.10) ----------------------------------------------------------------------------------------------------
CAUSA_FRASE = {
    "lixo": "sessão sem dono parada no nó (a cidade não a conhece)",
    "RAM": "pouca memória livre no nó: não cabe mais lastro",
    "lastro-sem-trabalho": "sobram núcleos livres e o lastro não os usa",
    "fila-sem-elegível": "a fila do Pilot não tem bead elegível para o nó",
}
RUNG_NOME = {"d1": "matar sessão sem dono", "d2": "pedir mais lastro", "d3": "reclassificar a fila de WA"}


def pick_cause(c, cpu, nuc, ram_mb, lixo, fila):
    """UMA causa, só com a CPU lida e abaixo da régua (None = acima dela, nada a explicar). Ordem de PRIORIDADE (não prova de culpa; o `efeito` da leitura seguinte é que prova): lixo > RAM > lastro-sem-trabalho >
    fila-sem-elegível > cego. cego = o que falta para dizer a causa não foi lido, ou nenhuma das quatro explica: leitura cega nunca vira causa nem dispara degrau."""
    if not cpu["lido"]:
        return "cego"
    if cpu["pct"] >= c.low_pct:
        return None
    if not nuc["lido"]:
        return "cego"
    if lixo["lido"] and lixo["n"] > 0:
        return "lixo"
    if nuc["livres"] >= c.min_free_cores:
        if ram_mb is None:
            return "cego"  # com núcleo sobrando, é a RAM que decide se o lastro cabe: sem ela não sei
        if ram_mb < c.ram_start_mb + c.ram_slot_mb:
            return "RAM"
        return "lastro-sem-trabalho"
    if fila["lido"] and fila["n"] == 0:
        return "fila-sem-elegível"
    return "cego"


def memo_unknown(c, now):
    """(chaves, linhas, motivo): as chaves (id, updated_at) cuja ÚLTIMA linha na memória do Pilot é `unknown` ainda fresca (a última linha da bead vale, como no _pilot_wa_node_pass_memo_hit). Arquivo ausente = memória
    vazia (leu); arquivo que não abre = (None, None, motivo): o D3 não sabe se há o que reclassificar."""
    try:
        with open(c.wa_memo, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return set(), [], None
    except (OSError, ValueError):
        return None, None, "memo-ilegivel"
    last = {}
    for ln in lines:
        f = ln.split("\t")
        if len(f) == 4 and re.fullmatch(r"[0-9]+", f[0]):
            last[(f[1], f[2])] = (int(f[0]), f[3])
    return {k for k, (ep, v) in last.items() if v == "unknown" and now - ep < c.memo_unknown_ttl_s}, lines, None


def purge_memo(c, now):
    """(chaves_removidas, motivo|None). Tira da memória TODAS as linhas das beads cuja última linha é `unknown` fresca: sem elas a próxima passada do Pilot sonda a bead de novo (reclassifica). Reescrita atômica;
    uma linha que o Pilot acrescente entre a leitura e o rename se perde, e isso é inofensivo (a memória só poupa orçamento de sonda)."""
    keys, lines, why = memo_unknown(c, now)
    if keys is None:
        return 0, why
    if not keys:
        return 0, None
    keep = [ln for ln in lines if not (len(ln.split("\t")) == 4 and (ln.split("\t")[1], ln.split("\t")[2]) in keys)]
    try:
        write_atomic(c.wa_memo, "".join(ln + "\n" for ln in keep))
    except Fail:
        return 0, "memo-nao-gravou"
    return len(keys), None


def d2_extra(c, nuc, ram_mb):
    """Quantos slots a mais o vigia pede: no máximo os núcleos livres, o que a RAM acima do piso de partida comporta (1 slot por ram_slot_mb) e 4. 0 = não há o que pedir (ou não li a RAM)."""
    if not nuc["lido"] or ram_mb is None:
        return 0
    return max(0, min(int(nuc["livres"]), (ram_mb - c.ram_start_mb) // c.ram_slot_mb, 4))


def _tries(st, k):
    d = st.get("degraus")
    e = d.get(k) if isinstance(d, dict) else None
    return _int(e.get("tentativas"), 0) if isinstance(e, dict) else 0


def plan_ladder(c, cause, low_due, st, now, lixo, nuc, ram_mb, memo_n):
    """(status_por_degrau, escolhido|None, esgotou). A escada só mexe com a CPU abaixo da régua há >= 30 min (low_due) e causa que diga por onde começar; considera os degraus a partir do da causa, em ordem; UM por leitura
    e com o intervalo global entre ações. Aplicabilidade em 3 estados (sim/não/não li): o que não li NUNCA conta como "esgotado". esgotou = causa dita (ou RAM, em que nada cabe) e nenhum degrau aplicável com chave e
    tentativa sobrando; degrau aplicável com a chave desligada NÃO esgota (ninguém autorizou a tentar)."""
    status = {k: None for k in RUNGS}
    if not low_due or cause is None:
        return {k: "nao-devido" for k in RUNGS}, None, False
    if cause == "cego":
        return {k: "cego" for k in RUNGS}, None, False
    if cause == "RAM":
        return {k: "ram" for k in RUNGS}, None, True
    appl = {"d1": None if not lixo["lido"] else lixo["n"] > 0 and bool(lixo["_alvos"]),
            "d2": None if not nuc["lido"] or ram_mb is None else d2_extra(c, nuc, ram_mb) >= 1,
            "d3": None if memo_n is None else memo_n > 0}
    last = _int(st.get("ultima_acao_em"))
    cooling = last is not None and 0 <= now - last < c.act_cooldown_s
    chosen, exhausted = None, True
    for i, k in enumerate(RUNGS):
        if i < RUNGS.index(RUNG_OF_CAUSE[cause]):
            status[k] = "fora"
        elif appl[k] is None:
            status[k], exhausted = "cego", False
        elif not appl[k]:
            status[k] = "nao-aplica"
        elif not c.on[k]:
            status[k], exhausted = "desligado", False
        elif _tries(st, k) >= c.act_tries:
            status[k] = "esgotado"
        else:
            exhausted = False
            if cooling:
                status[k] = "cooldown"
            elif chosen is None:
                chosen, status[k] = k, "pronto"
            else:
                status[k] = "aguarda"  # um degrau antes deste age primeiro
    return status, chosen, exhausted


def _ssh_node(c, script):
    return run_cmd([c.ssh_bin, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", c.ssh_host, script], c.ssh_timeout_s)


def _ssh_verdict(c, script, ok_word):
    """(ok, rótulo): o ssh de ação diz UMA palavra na última linha; só `ok_word` com rc 0 conta como feito. Falha, timeout e saída muda são rótulos, nunca sucesso."""
    rc, out, _e, why = _ssh_node(c, script)
    if why:
        return False, why
    words = out.split()
    if rc != 0:
        return False, "rc-%s" % rc
    return (words[-1] == ok_word, words[-1]) if words else (False, "sem-saida")


def kill_idle_session(c, name):
    """(ok, rótulo). O ssh confere DE NOVO, no próprio nó, que a sessão existe e segue quieta há >= d1_idle_s (a leitura que a achou é de minutos atrás: uma sessão que voltou a trabalhar não morre). Só nome
    seguro e com -remote- chega aqui."""
    if not SAFE_NAME.fullmatch(name) or "-remote-" not in "-%s-" % name:
        return False, "nome-recusado"
    script = ('S=%s; T="tmux -L gc-remote"; $T has-session -t "=$S" 2>/dev/null || { echo ausente; exit 0; }; '
              'a=$($T display-message -p -t "=$S:" "#{session_activity}" 2>/dev/null); n=$(date +%%s); '
              'case "$a" in ""|*[!0-9]*) echo ilegivel; exit 0;; esac; '
              '[ $((n - a)) -lt %d ] && { echo ativa; exit 0; }; '
              '$T kill-session -t "=$S" 2>/dev/null && echo morta || echo falhou' % (name, c.d1_idle_s))
    return _ssh_verdict(c, script, "morta")


def request_ballast(c, extra, nuc, ram_mb, now):
    """(ok, rótulo): grava ~/gt-remote/ballast/lastro-pedido.json no nó (tmp + mv: o governo nunca lê meio arquivo). O pedido VENCE em 2 leituras (`ate`): quem não renova não deixa pedido velho de pé."""
    body = json.dumps({"v": 1, "epoch": now, "ate": now + 2 * c.interval_s, "slots_extra": extra, "livres": nuc["livres"], "ram_mb": ram_mb, "quem": "hetzner-occupancy-watch"}, separators=(",", ":"))
    b64 = base64.b64encode(body.encode("utf-8")).decode("ascii")
    script = ('H=\'%s\'; case "$H" in "~/"*) H="$HOME/${H#"~/"}";; esac; [ -d "$H" ] || { echo sem-lastro; exit 0; }; '
              'echo %s | base64 -d > "$H/.%s.tmp" && mv "$H/.%s.tmp" "$H/%s" && echo gravado || echo falhou' % (c.ballast_home, b64, BALLAST_REQ, BALLAST_REQ, BALLAST_REQ))
    return _ssh_verdict(c, script, "gravado")


def do_rung(c, k, lixo, nuc, ram_mb, now):
    """(ok, o_que, detalhe): executa o degrau `k`. ok = mudou alguma coisa (o efeito dela só se mede se mudou)."""
    if k == "d1":
        res = [(n,) + kill_idle_session(c, n) for n in lixo["_alvos"]]
        done = [n for n, ok, _w in res if ok]
        return bool(done), "matou %d sessão(ões) sem dono: %s" % (len(done), ", ".join(done) or "-"), ", ".join("%s=%s" % (n, w) for n, _ok, w in res)
    if k == "d2":
        extra = d2_extra(c, nuc, ram_mb)
        ok, w = request_ballast(c, extra, nuc, ram_mb, now)
        return ok, "pediu +%d slot(s) de lastro" % extra, w
    n, why = purge_memo(c, now)
    return why is None and n > 0, "tirou %d bead(s) `unknown` da memória do Pilot" % n, why or "ok"


def measure_effects(st, cpu, nuc):
    """(efeitos, pendentes_restantes). O efeito de uma ação é medido na leitura SEGUINTE (a janela dela começa depois da ação): CPU e lastro antes/depois. Sem CPU lida a pendência espera até 3 leituras e depois
    vira {"motivo": "cpu-nao-lida"}: efeito que não deu para medir é dito, não inventado."""
    out, keep = [], []
    for p in st.get("pendentes") or []:
        a = p.get("antes") if isinstance(p, dict) else None
        if not isinstance(a, dict) or _int(p.get("em")) is None:
            continue  # lixo no estado (editado à mão): descarta
        base = {"degrau": p.get("degrau"), "em": p["em"], "o_que": p.get("o_que")}
        if cpu["lido"]:
            ef = dict(base, pct_antes=a.get("pct"), pct_depois=cpu["pct"], nucleos_antes=a.get("nucleos"), nucleos_depois=cpu["nucleos"],
                      ganho_nucleos=round(cpu["nucleos"] - a["nucleos"], 2) if isinstance(a.get("nucleos"), (int, float)) else None)
            if nuc["lido"]:
                ef.update(lastro_antes=a.get("lastro"), lastro_depois=nuc["lastro"], livres_antes=a.get("livres"), livres_depois=nuc["livres"])
            out.append(ef)
        elif _int(p.get("leituras"), 0) + 1 >= 3:
            out.append(dict(base, motivo="cpu-nao-lida"))
        else:
            keep.append(dict(p, leituras=_int(p.get("leituras"), 0) + 1))
    return out, keep


def send_notify(c, title, text):
    """(entregue, rótulo). NOTIFY_STRICT_EXIT=1 dá um rc por desfecho e SÓ ele diz se saiu: 0 entregue, 10 segurado até as 7 h (sai no flush) e 11 já tinha saído contam; 12 digest/teto, 13 autodispatch, 14 dropado,
    timeout e qualquer outro rc NÃO saíram (04/11, ga-i4t0lzx: exit 12 e o Athos não soube)."""
    rc, _o, _e, why = run_cmd([c.notify_bin, "-t", title, text], c.notify_timeout_s, env={"NOTIFY_STRICT_EXIT": "1", "NOTIFY_FORCE_PUSH": "1"})
    if why:
        return False, why
    ok = {0: "entregue", 10: "segurado-ate-7h", 11: "ja-tinha-saido"}
    return (True, ok[rc]) if rc in ok else (False, "rc-%s" % rc)


def deliver(c, title, text, falha_em, now):
    """(entregue, rótulo, falha_em_novo, mail_ok|None). O notify que não saiu tenta de novo a cada notify_retry_s; o mesmo texto vai UMA vez por `gc mail send mayor` (o Mayor repassa), na 1ª falha."""
    if falha_em is not None and 0 <= now - falha_em < c.notify_retry_s:
        return False, "espera-retry", falha_em, None
    ok, why = send_notify(c, title, text)
    if ok:
        return True, why, None, None
    mail = send_mail(c, title, text + "\n\n(O notify ao Athos não saiu: %s. Mando o mesmo texto aqui e tento o notify de novo em %d min.)" % (why, _mins(c.notify_retry_s))) if falha_em is None else None
    return False, why, now, mail


def plan_notice(c, key, due, done, falha_em, now, dry):
    """O estado de um aviso ao Athos: nao · desligado (sem a chave) · ja-avisou · espera-retry · enviaria (--dry-run) · enviar."""
    if not due:
        return "nao"
    if not c.on[key]:
        return "desligado"
    if done:
        return "ja-avisou"
    if falha_em is not None and 0 <= now - falha_em < c.notify_retry_s:
        return "espera-retry"
    return "enviaria" if dry else "enviar"


def yesterday_key(now):
    lt = time.localtime(now)
    midnight = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    return time.strftime("%Y-%m-%d", time.localtime(midnight - 43200))  # meio-dia de ontem: imune a horário de verão


def main_cause(day):
    """(causa, leituras, total): a causa que mais apareceu no dia (empate: a de maior prioridade). None se o dia não registrou causa."""
    t = day.get("causas") if isinstance(day, dict) else None
    if not isinstance(t, dict):
        return None, 0, 0
    cnt = {k: t[k] for k in CAUSAS if k != "cego" and isinstance(t.get(k), int) and t[k] > 0}
    if not cnt:
        return None, 0, 0
    best = max(cnt, key=lambda k: (cnt[k], -CAUSAS.index(k)))
    return best, cnt[best], sum(cnt.values())


def judge_yesterday(c, daily, now):
    """(veredito, dia, chave): na-meta · sem-numero · sem-dia-anterior · abaixo. Dia sem >= day_min_windows janelas de CPU lidas não tem número (dia cego não é "abaixo" nem "na meta")."""
    key = yesterday_key(now)
    day = (daily or {}).get("dias", {}).get(key)
    if not isinstance(day, dict):
        return "sem-dia-anterior", None, key
    pct, wins = _flt(day.get("ocupacao_pct")), _int(day.get("cpu_janelas"), 0)
    if pct is None or wins < c.day_min_windows:
        return "sem-numero", day, key
    return ("abaixo" if pct < c.low_pct else "na-meta"), day, key


def day_notice(c, day, key):
    pct, causa, n, total = day["ocupacao_pct"], *main_cause(day)
    why = "causa principal: %s (%d de %d leituras abaixo da meta)" % (CAUSA_FRASE[causa], n, total) if causa else "a causa não foi registrada nesse dia"
    acoes = _int(day.get("acoes"), 0)
    title = "Hetzner fechou ontem em %s%% de CPU (meta %g%%)" % (pct, c.low_pct)
    text = "Ontem (%s) o Hetzner pago fechou o dia com a CPU média em %s%%; a meta é %g%%. %s. O vigia agiu %d vez(es) no dia. Detalhe: %s" % (
        key[8:10] + "/" + key[5:7], pct, c.low_pct, why[0].upper() + why[1:], acoes, os.path.join(c.gc_dir, "hetzner-occupancy.jsonl"))
    return title, text


def d4_notice(c, rd, low, st, cause):
    span, media = rd["epoch"] - low["desde"], _avg_pct(low["nucleos_s"], low["cap_s"])
    nuc = rd["nucleos"]
    tried = []
    for k in RUNGS:  # `st` é o estado NOVO: a tentativa desta leitura já está contada
        n = _tries(st, k)
        ganho = st["degraus"][k].get("ganho_nucleos") if n else None
        if n:
            tried.append("%s %dx%s" % (RUNG_NOME[k], n, "" if ganho is None else " (ganho medido: %+.2f núcleo)" % ganho))
    nums = "" if not nuc["lido"] else " Hoje: %s núcleos em sessões, %s no lastro, %s de sistema, %s esperando disco, %s livres." % (nuc["sessoes"], nuc["lastro"], nuc["sistema"], nuc["espera"], nuc["livres"])
    title = "Hetzner abaixo de %g%% há %d h: esgotei o que o vigia faz sozinho" % (c.low_pct, span // 3600)
    text = "O Hetzner pago está com a CPU média em %s%% há %d h (meta %g%%). Causa: %s.%s Tentei: %s. Nada mais que o vigia possa fazer sozinho." % (
        media, span // 3600, c.low_pct, CAUSA_FRASE.get(cause, "não identificada"), nums, "; ".join(tried) or "nada (a causa não tem degrau que caiba)")
    return title, text


def create_d4_bead(c, title, text):
    """(id|None, rótulo). Bead SEM story:approved nem exec:auto: nada a despacha sozinho, é registro da causa (o aviso é o notify)."""
    rc, out, err, why = run_cmd([c.bd_bin, "-C", c.city, "create", "--silent", "-t", "task", "-p", "2", "-l", "area:infra,hetzner-ocupacao", "--title", title, "-d", text], c.bd_timeout_s)
    motivo = _failed(rc, why, "bd")
    bid = out.strip().splitlines()[-1].strip() if out.strip() else ""
    if motivo or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", bid):
        return None, motivo or "id-ilegivel"
    return bid, "criada"


def cause_line(rd):
    n = rd.get("nucleos")
    if not n or not n.get("lido"):
        return None
    return "• de onde vem o número (núcleos médios na janela): sessões %s · lastro %s · sistema %s · espera de disco %s · livres %s · causa: %s" % (
        n["sessoes"], n["lastro"], n["sistema"], n["espera"], n["livres"], rd.get("causa") or "-")


def _plan(c, due, last_at, cooldown_s, now, dry, silent=None):
    if not due:
        return "nao"
    if not c.alarm:
        return "desligado"
    if silent:
        return silent
    if last_at is not None and 0 <= now - last_at < cooldown_s:
        return "cooldown"
    return "enviaria" if dry else "enviar"


def run(args, env):
    c = load_config(env)
    if args.print_config:
        keys = ("city", "interval_s", "busy_cores", "stores", "other_hosts", "ssh_host", "alarm", "alarm_key", "idle_after_s", "blind_after_s", "slack_s",
                "idle_cooldown_s", "blind_cooldown_s", "low_pct", "low_after_s", "low_cooldown_s", "min_window_s", "max_window_s", "ssh_timeout_s", "gc_timeout_s", "bd_timeout_s", "pilot_file",
                "d1_idle_s", "d1_max", "act_cooldown_s", "act_tries", "d4_after_s", "notify_retry_s", "notify_timeout_s", "ram_start_mb", "ram_slot_mb", "min_free_cores", "day_min_windows", "ballast_home", "wa_memo",
                "memo_unknown_ttl_s", "keys", "on")
        print(json.dumps({k: getattr(c, k) for k in keys}, ensure_ascii=False, indent=2))
        return 0
    now, dry = c.now, args.dry_run
    if not dry and take_lock(c.gc_dir) is None:
        print("hetzner-occupancy-watch: outra instância ainda está rodando; saio sem medir (o lock é do kernel e some sozinho)", file=sys.stderr)
        return 0
    state_path = os.path.join(c.gc_dir, "hetzner-occupancy.state.json")
    daily_path = os.path.join(c.gc_dir, "hetzner-occupancy-daily.json")
    st = load_json(state_path, lambda o: isinstance(o, dict), now, dry) or {}
    today = time.strftime("%Y-%m-%d", time.localtime(now))

    sess = read_sessions(c)
    raw = {}
    cpu, new_base, cores = read_cpu(c, st.get("cpu"), now, raw)
    ex = parse_extra(raw.get("out"))
    nuc, new_xbase = read_nucleos(c, st.get("cpu_extra"), ex, raw, now)
    fila, foco = read_queue(c, now), read_focus(c, now)
    est = decide(sess, cpu, cores, c.busy_cores)
    lixo = find_lixo(c, sess, ex)
    sess.pop("_reconhecidas", None)  # só serviam ao find_lixo: não vão ao JSONL
    sess.pop("_donos", None)
    memo_keys, _memo_lines, _memo_why = memo_unknown(c, now)
    memo_n = None if memo_keys is None else len(memo_keys)
    cause = pick_cause(c, cpu, nuc, ex["ram_mb"], lixo, fila)

    decided = est == "ocupado" or (est == "ocioso" and fila["lido"])
    warm = est == "desconhecido" and sess["lido"] and cpu["motivo"] in WARMUP
    prev_ocio = _int(st.get("ociosas_seguidas"), 0)
    ocio = prev_ocio + 1 if est == "ocioso" else 0
    ocio_desde = (_int(st.get("ocioso_desde"), now) if prev_ocio > 0 else now) if est == "ocioso" else None
    cegas = 0 if decided else _int(st.get("cegas_seguidas"), 0) + (0 if warm else 1)
    decidida_em = now if decided else _int(st.get("decidida_em"), now)  # sem nenhuma decidida ainda, conta desde a 1ª leitura
    # a CPU cega é outra conta: uma sessão que prova "ocupado" decide o ESTADO, mas com a CPU ilegível o aviso de CPU baixa não tem como sair (ga-2hd02v.6)
    cpu_warm = not cpu["lido"] and cpu["motivo"] in WARMUP
    cpu_cegas = 0 if cpu["lido"] else _int(st.get("cpu_cegas_seguidas"), 0) + (0 if cpu_warm else 1)
    cpu_lida_em = now if cpu["lido"] else _int(st.get("cpu_lida_em"), now)  # sem nenhuma lida ainda, conta desde a 1ª leitura
    low = low_streak(c, st, cpu, cores, now)

    rd = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)), "epoch": now, "regra": RULE, "estado": est, "sessoes": sess, "cpu": cpu, "fila": fila, "foco": foco,
          "ociosas_seguidas": ocio, "cegas_seguidas": cegas, "baixas_seguidas": low["n"], "cpu_cegas_seguidas": cpu_cegas,
          "nucleos": nuc, "ram_mb": ex["ram_mb"], "lixo": {k: v for k, v in lixo.items() if not k.startswith("_")}, "memo_unknown": memo_n, "causa": cause}
    idle_due = est == "ocioso" and fila["lido"] and fila["n"] > 0 and now - ocio_desde >= c.idle_after_s - c.slack_s
    blind_state_due = cegas > 0 and now - decidida_em >= c.blind_after_s - c.slack_s
    blind_cpu_due = cpu_cegas > 0 and now - cpu_lida_em >= c.blind_after_s - c.slack_s
    blind_due = blind_state_due or blind_cpu_due
    low_due = low["n"] > 0 and now - low["desde"] >= c.low_after_s - c.slack_s
    last_idle, last_blind, last_low = _int(st.get("alarme_ocioso_em")), _int(st.get("alarme_cego_em")), _int(st.get("alarme_baixa_em"))
    a_idle = _plan(c, idle_due, last_idle, c.idle_cooldown_s, now, dry, "foco" if foco == "ligado" else None)
    a_blind = _plan(c, blind_due, last_blind, c.blind_cooldown_s, now, dry)
    a_low = _plan(c, low_due, last_low, c.low_cooldown_s, now, dry)
    rd["alarme"] = {"ocioso": a_idle, "cego": a_blind, "cpu_baixa": a_low}
    if dry:
        rd["dry_run"] = True

    # a escada: o efeito da ação da leitura anterior, depois o degrau desta
    efeitos, pendentes = measure_effects(st, cpu, nuc)
    deg_old = st.get("degraus") if low["n"] > 0 and isinstance(st.get("degraus"), dict) else {}  # sequência nova = tentativas novas
    deg = {k: dict(v) for k, v in deg_old.items() if k in RUNGS and isinstance(v, dict)}
    for ef in efeitos:
        if ef.get("degrau") in deg and ef.get("ganho_nucleos") is not None:
            deg[ef["degrau"]]["ganho_nucleos"] = ef["ganho_nucleos"]
    status, chosen, exhausted = plan_ladder(c, cause, low_due, {"degraus": deg, "ultima_acao_em": st.get("ultima_acao_em")}, now, lixo, nuc, ex["ram_mb"], memo_n)
    if dry and chosen:
        status[chosen] = "agiria"
    rd.update(degrau=status, acao=[], efeito=efeitos)

    daily = load_json(daily_path, lambda o: isinstance(o, dict) and isinstance(o.get("dias"), dict), now, dry) if c.on["dia"] else None
    if daily is not None:
        migrate_daily(daily)
    new_st = {"versao": 1, "cpu": new_base or (st.get("cpu") if _baseline_ok(st.get("cpu")) else None), "ociosas_seguidas": ocio, "ocioso_desde": ocio_desde,
              "cegas_seguidas": cegas, "decidida_em": decidida_em, "alarme_ocioso_em": last_idle, "alarme_cego_em": last_blind, "atualizado_em": now,
              "cpu_cegas_seguidas": cpu_cegas, "cpu_lida_em": cpu_lida_em, "baixas_seguidas": low["n"], "baixa_desde": low["desde"],
              "baixa_nucleos_s": None if low["n"] == 0 else round(low["nucleos_s"], 2), "baixa_capacidade_s": None if low["n"] == 0 else low["cap_s"], "alarme_baixa_em": last_low,
              "cpu_extra": new_xbase or (st.get("cpu_extra") if _extra_base_ok(st.get("cpu_extra")) else None), "degraus": deg, "pendentes": pendentes,
              "ultima_acao_em": _int(st.get("ultima_acao_em")), "d4_dia": st.get("d4_dia"), "d4_bead": st.get("d4_bead") if low["n"] > 0 else None, "d4_falha_em": _int(st.get("d4_falha_em")),
              "dia_avaliado": st.get("dia_avaliado"), "dia_falha_em": _int(st.get("dia_falha_em"))}

    # avisos ao Athos: o D4 (esgotou) e o número do dia
    d4_due = low["n"] > 0 and exhausted and now - low["desde"] >= c.d4_after_s - c.slack_s
    s_d4 = plan_notice(c, "d4", d4_due, st.get("d4_dia") == today, new_st["d4_falha_em"], now, dry)
    yday = ykey = None
    if not c.on["dia"]:
        verdict = "desligado"  # sem a chave: nem avalia (INERTE)
    elif st.get("dia_avaliado") == today:
        verdict = "ja-avaliado"
    else:
        verdict, yday, ykey = judge_yesterday(c, daily, now)
    s_dia = plan_notice(c, "dia", True, False, new_st["dia_falha_em"], now, dry) if verdict == "abaixo" else verdict
    rd.update(d4=s_d4, numero_do_dia=s_dia)

    sends = []  # (chave do estado, valor antigo, assunto, corpo)
    if a_idle == "enviar":
        sends.append(("alarme_ocioso_em", last_idle, ("ocioso",)) + idle_mail(c, rd, now - ocio_desde))
    if a_blind == "enviar":
        sends.append(("alarme_cego_em", last_blind, ("cego",)) + blind_mail(c, rd, now - decidida_em if blind_state_due else None, now - cpu_lida_em if blind_cpu_due else None))
    if a_low == "enviar":
        sends.append(("alarme_baixa_em", last_low, ("cpu_baixa",)) + low_mail(c, rd, low))
    if not dry:
        if verdict in ("na-meta", "sem-numero", "sem-dia-anterior"):
            new_st["dia_avaliado"] = today  # avaliou de verdade e não há o que avisar: não reavalia o dia todo
        for key, _old, _k, _s, _b in sends:
            new_st[key] = now  # o cooldown é gravado ANTES do mail: se não der para gravar, o mail nem sai (nada de repetir a cada rodada)
        if chosen:
            new_st["degraus"].setdefault(chosen, {})["tentativas"] = _tries(new_st, chosen) + 1  # a tentativa é gravada ANTES de agir: se o processo morrer no meio, não repete sem conta
            new_st["ultima_acao_em"] = now
        save = lambda: write_atomic(state_path, json.dumps(new_st, ensure_ascii=False, sort_keys=True, indent=1))
        save()
        if chosen:
            ok, o_que, det = do_rung(c, chosen, lixo, nuc, ex["ram_mb"], now)
            rd["acao"].append({"degrau": chosen, "ok": ok, "o_que": o_que, "detalhe": det})
            status[chosen] = "agiu" if ok else "falhou"
            if ok:  # só o que mudou algo tem efeito a medir; a tentativa que falhou já gastou a vez
                new_st["pendentes"].append({"degrau": chosen, "em": now, "o_que": o_que, "leituras": 0,
                                            "antes": {"pct": cpu["pct"], "nucleos": cpu["nucleos"], "lastro": nuc["lastro"], "livres": nuc["livres"], "sessoes": nuc["sessoes"]}})
            save()
        failed = False
        for key, old, (kind,), subj, body in sends:
            ok = send_mail(c, subj, body)
            rd["alarme"][kind] = "enviado" if ok else "falhou"
            if not ok:
                new_st[key], failed = old, True  # mail que falha não gasta o cooldown: a próxima rodada tenta de novo
        if failed:
            save()
        if s_d4 == "enviar":
            if not new_st["d4_bead"]:
                t4, x4 = d4_notice(c, rd, low, new_st, cause)
                bid, why = create_d4_bead(c, t4, x4)
                rd["d4_bead"] = bid or why
                if bid:
                    new_st["d4_bead"] = bid
                    save()  # a bead é gravada ANTES do aviso: o retry não cria outra
            t4, x4 = d4_notice(c, rd, low, new_st, cause)
            if new_st["d4_bead"]:
                x4 += " Bead: %s." % new_st["d4_bead"]
            new_st["d4_dia"] = today
            save()
            ok4, why4, falha4, mail4 = deliver(c, t4, x4, new_st["d4_falha_em"], now)
            rd["d4"] = "enviado:" + why4 if ok4 else "falhou:" + why4
            if mail4 is not None:
                rd["d4_mail"] = "enviado" if mail4 else "falhou"
            new_st["d4_falha_em"] = falha4
            if not ok4:
                new_st["d4_dia"] = st.get("d4_dia")  # não saiu: não conta como o aviso do dia (a próxima hora tenta de novo)
            save()
        if s_dia == "enviar":
            tt, xx = day_notice(c, yday, ykey)
            new_st["dia_avaliado"] = today
            save()
            okd, whyd, falhad, maild = deliver(c, tt, xx, new_st["dia_falha_em"], now)
            rd["numero_do_dia"] = "enviado:" + whyd if okd else "falhou:" + whyd
            if maild is not None:
                rd["numero_do_dia_mail"] = "enviado" if maild else "falhou"
            new_st["dia_falha_em"] = falhad
            if not okd:
                new_st["dia_avaliado"] = st.get("dia_avaliado")
            save()
        append_line(os.path.join(c.gc_dir, "hetzner-occupancy.jsonl"), json.dumps(rd, ensure_ascii=False, separators=(",", ":")))
        if daily is None:
            daily = load_json(daily_path, lambda o: isinstance(o, dict) and isinstance(o.get("dias"), dict), now, dry) or {"dias": {}}
            migrate_daily(daily)
        day = daily["dias"].setdefault(today, {"ocupado": 0, "ocioso": 0, "desconhecido": 0, "leituras": 0, "ocupacao_pct": None, "ocupacao_sessao_pct": None,
                                               "cpu_janelas": 0, "cpu_nucleos_s": 0.0, "cpu_capacidade_s": 0})
        day[est] += 1
        day["leituras"] += 1
        dec = day["ocupado"] + day["ocioso"]
        day["ocupacao_sessao_pct"] = round(100.0 * day["ocupado"] / dec, 1) if dec else None
        if cpu["lido"]:  # só janela LIDA entra na média de CPU do dia; sem nenhuma, ocupacao_pct fica null (nunca 0 %)
            day["cpu_janelas"] += 1
            day["cpu_nucleos_s"] = round(day["cpu_nucleos_s"] + cores * cpu["janela_s"], 2)
            day["cpu_capacidade_s"] += cpu["ncpu"] * cpu["janela_s"]
        day["ocupacao_pct"] = _avg_pct(day["cpu_nucleos_s"], day["cpu_capacidade_s"])
        # os extras do dia só aparecem quando há dado (o dia antigo e o dia sem leitura da causa ficam como estavam)
        if cause not in (None, "cego"):  # CPU lida e abaixo da régua, com causa dita
            day.setdefault("causas", {})
            day["causas"][cause] = _int(day["causas"].get(cause), 0) + 1
        if nuc["lido"]:
            ds = day.setdefault("decomp_s", {})
            for k in ("sessoes", "lastro", "sistema", "espera", "livres"):
                ds[k] = round(_flt(ds.get(k), 0.0) + nuc[k] * nuc["janela_s"], 2)
            day["decomp_win_s"] = _int(day.get("decomp_win_s"), 0) + nuc["janela_s"]
        if rd["acao"]:
            day["acoes"] = _int(day.get("acoes"), 0) + len(rd["acao"])
        daily["intervalo_s"] = c.interval_s
        write_atomic(daily_path, json.dumps(daily, ensure_ascii=False, sort_keys=True, indent=1))
    if args.show:
        print(json.dumps(rd, ensure_ascii=False, indent=2))
    else:
        print("%s estado=%s sessoes=%s cpu=%s fila=%s foco=%s ociosas=%d cegas=%d alarme=%s/%s/%s causa=%s" % (
            rd["ts"], est, sess["ativas"], cpu["nucleos"], fila["n"], foco, ocio, cegas, rd["alarme"]["ocioso"], rd["alarme"]["cego"], rd["alarme"]["cpu_baixa"], cause))
    return 0


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="vigia de ocupação do nó Hetzner (ga-2hd02v.1.12)")
    ap.add_argument("--print", dest="show", action="store_true", help="imprime a leitura (JSON) em vez do resumo de uma linha")
    ap.add_argument("--dry-run", action="store_true", help="lê tudo e mostra o que faria; não grava nada nem manda mail")
    ap.add_argument("--print-config", action="store_true", help="imprime a configuração em vigor e sai")
    args = ap.parse_args(argv)
    try:
        return run(args, os.environ)
    except Fail as e:
        print("hetzner-occupancy-watch: %s" % e, file=sys.stderr)
        return e.rc
    except Exception:  # inclui configuração inválida: o traceback fica à vista no log do launchd
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
