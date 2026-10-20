#!/usr/bin/env -S python3 -I
"""hetzner-capacity.py — o teto de sessões do nó Hetzner por MEDIÇÃO e o veredito "nó ou mini". ga-2hd02v.1.11. Python 3.9+, só biblioteca padrão.

Contents
  Para que serve · Comandos · Os degraus · Meta: encher o nó · O veredito · Sessão ocupada × ociosa · Três estados · Arquivos · O que NÃO faz

PARA QUE SERVE
  O mini vive em swap; o nó (16 núcleos, 32 GB, sem swap) fica ocioso. Esta ferramenta responde duas perguntas com número medido, nunca com chute:
  (1) quantas sessões o nó aguenta AGORA (o teto sobe em degraus 1→3→6→10 só com evidência, e desce sozinho se o nó aperta) e
  (2) este trabalho vai para o nó ou fica no mini (`verdict`): nó primeiro, mini só no transbordo (nó cheio, quente, fora, ou ainda sem condição de receber).

COMANDOS  (todos aceitam --json; --dir muda a pasta de estado)
  verdict   mede se a última leitura passou de `refresh_s`, avalia os degraus e dá o veredito. exit 0 = NÓ, 1 = MINI (com o motivo), 2 = NÃO SEI
            (inclui erro interno nosso: reason "internal"; um traceback do Python sairia 1, que aqui é MINI, por isso `main` pega tudo).
            Quem chama trata 1 e 2 do mesmo jeito (fica no mini); a diferença está no motivo, para o log.
  step      o mesmo ciclo (mede se vencido, avalia, grava) sem dar veredito. Para um agendador. exit 0 se rodou, 3 se não conseguiu gravar/ler a configuração (ou erro interno).
            O agendador (com.gascity.hetzner-capacity-step, a cada 180 s) é o relógio das leituras: o degrau não pode depender de o Pilot pedir veredito (ga-2hd02v.2).
  hourly    só LÊ readings.jsonl: CPU OCUPADA (100 - ocioso) média por hora cheia UTC das últimas --hours (24) horas completas. exit 0 = toda hora tem leitura e média >= --min-pct (85),
            1 = alguma hora abaixo ou SEM leitura (hora sem leitura não prova nada: não é 0% nem é OK), 3 = não consegui ler o arquivo. É a consulta da prova ao vivo da meta.
  status    só LÊ (sem ssh, sem gravar): degrau, leituras, o que falta para subir, tetos fixos (cap do provider) e as condições do veredito.
  read      uma medição avulsa, nada é gravado. exit 0 lida, 1 não consegui, 3 erro de configuração/estado ou interno.
  set-ceiling N --reason T   força um degrau (só os da lista), registrado em events.jsonl. O ciclo seguinte continua a partir dele.
  pause --reason T | resume  trava / destrava o envio ao nó na hora (vale no próximo veredito): é o botão do Mayor.

OS DEGRAUS
  Sobe UM degrau (nunca pula) quando, desde a última mudança, passou `up_window_s`, há ao menos `up_min_reads` leituras e TODAS estão verdes
  (CPU livre >= `cpu_up_headroom_pct` E RAM disponível >= `mem_up_avail_pct`), e em alguma delas o nó já tinha `sessões OCUPADAS >= degrau` (prova de que aguentou
  o degrau atual com carga; `require_load_proof=false` dispensa). Só vale como prova a leitura em que o gc e o bd foram LIDOS (`idle_why` vazio): leitura em que um deles
  falhou ou estourou o prazo não prova nada (nem veta: as outras leituras da janela seguem valendo), e a gravada antes da separação ocupada×ociosa também não.
  Leitura que falhou NÃO é verde: atrasa a subida, nunca a adianta.
  Desce UM degrau com `down_reads` leituras seguidas com a RAM < `mem_down_avail_pct`. A CPU cheia NÃO derruba o degrau (ga-2hd02v.2, ver "Meta"); `cpu_lowers_ceiling=true` devolve a
  regra antiga (CPU livre < `cpu_down_headroom_pct` também desce). A faixa entre os limites é âmbar: mantém o degrau. Leitura que falhou não é vermelha: sem leitura, o degrau
  fica como está (e o veredito vira "não sei").
  CPU livre = o MENOR entre o ocioso de uma amostra de 2 s do /proc/stat e (1 - load5/núcleos): rajada curta e carga sustentada contam as duas.
  O nó não tem swap: RAM acabando é morte de sessão, por isso a RAM é o limite duro do degrau.

META: ENCHER O NÓ  (ga-2hd02v.2: o Athos quer o nó SEMPRE ocupado, por quem for; "o que não pode é ficar menos de 100%")
  (1) Relógio próprio: as leituras vêm do `step` agendado (a cada 180 s), não da varredura do Pilot (25-40 min, ~2 leituras por janela: o degrau nunca subia).
  (2) Verde = sobra para mais uma sessão: CPU livre >= `cpu_up_headroom_pct` (10: ~1,6 núcleo dos 16; era 35, que cortava a cidade em ~65% do nó) e RAM >= `mem_up_avail_pct`.
      A janela é de `up_window_s` (480 s) com `up_min_reads` (3) leituras: a escada 1→3→6→10 sobe em ~27 min com carga, não em horas.
  (3) O degrau só desce por RAM. A CPU ocupada por quem NÃO é sessão da cidade (o Traço BIM do Athos) não o derruba: o veredito do momento diz `node_hot` (CPU livre < `cpu_down_headroom_pct`,
      3) e a bead NOVA vai ao mini enquanto durar, mas o degrau fica e, na leitura seguinte à saída da carga (<= 3 min), o veredito volta a ser `node` com as vagas todas.
  Não distingue quem usa a CPU (sessão da cidade × externo): a cidade não derruba o degrau por CPU, e a CPU quente barra a bead nova no veredito do momento.

O VEREDITO  (a primeira condição que falha decide; só `node` autoriza)
  pausa → MINI · config do provider ilegível → NÃO SEI · `real_sessions_released_by` ausente → MINI · config do atalho ilegível → NÃO SEI ·
  `gate_done_bin` nulo, relativo ou não executável → MINI (o atalho recusa caminho relativo; uma bead no nó sem como entregar ao gate encalha: ga-2hd02v.1.13) · sem nenhuma leitura, ou a última mais velha que
  `max_age_s` (ou carimbada mais de 60 s no futuro) → NÃO SEI · último ssh não conectou → MINI (nó fora) · leitura ilegível → NÃO SEI · vermelho → MINI (nó quente) · sessões do nó ilegíveis → NÃO SEI ·
  sessões OCUPADAS >= min(degrau, cap do provider) → MINI (nó cheio) · senão NÓ.

SESSÃO OCUPADA × OCIOSA  (ga-2hd02v.1.22: o nó "cheio" de dogs parados)
  O nó lista as tmux vivas; uma sessão viva NÃO é uma sessão trabalhando. Uma dog-remote conta OCUPADA só se há uma bead `in_progress` atribuída ao alias dela
  (dog-remote-<n>; o nome da sessão no nó, dog-remote-<id>, também vale) — essa bead é o sinal de trabalho. Sem bead, a sessão é uma vaga LIVRE para ESTE oráculo.
  Só a leitura chega a isso: o `_pilot_node_pick_alias` do Pilot ainda só escolhe alias novo ou dormindo, então uma dog-remote ACORDADA e ociosa não é aproveitada por ele
  (veredito `node`, mas o Pick não acha alias) até o patch do engine do ga-2hd02v.1.22 entrar na janela e deixar a sessão morta pelo idle_timeout dormindo.
  Para casar a tmux do nó com o alias lê-se `gc session list --json` (session_name → alias). Só as beads do HQ contam (`bd -C <cidade>`, in_progress, não efêmeras):
  uma dog-remote trabalhando bead de rig ou efêmera aparece ociosa, coerente com a regra do Pilot de que só bead de dog do HQ vai ao nó.
  Conta sempre ocupada, sem prova em contrário: sessão que não é dog-remote-* (gate-reviewer, wa-worker), sessão cujo alias no gc não é de pool (`dog-remote-<n>`;
  dog-remote-adhoc-* não tem bead-por-alias), sessão que o gc não lista ou lista sem alias (sem dono conhecido não dá para dizer que está parada).
  Falhou/ilegível (gc ou bd com rc≠0, estourou o prazo, não é JSON, formato fora do esperado): TODAS as sessões do nó contam ocupadas e o motivo vai em `idle_why` —
  nunca "ociosa por falta de leitura", para não lotar o nó (é o veredito de antes desta leitura). Lista vazia lida com sucesso é a ausência de bead (vaga livre), não falha.
  Leituras: `sessions` = ocupadas (o que o veredito e a prova de carga do degrau usam), `sessions_total` = tmux vivas, `sessions_idle` = vagas livres. Com `idle_why`
  não vazio, `sessions` é o total vivo contado como ocupado: vale para o veredito (inerte: node_full) e NÃO vale como prova de carga (o `decide()` só conta a leitura com `idle_why` vazio).
  Prazo: o `gc session list` leva 10-21 s no mini com load 44 (medido 19/10) e o `bd list` ~3 s; as duas leituras correm em PARALELO (custo = o maior prazo, não a soma),
  com prazo de 25 s o gc e 15 s o bd, para caber nos 40 s que o Pilot dá ao veredito inteiro. A leitura é refeita no máximo a cada `refresh_s` (60 s). Estourou = ilegível = ocupadas.

TRÊS ESTADOS
  Cada leitura do nó é ok / unreachable (ssh não conectou ou estourou o prazo) / unreadable (respondeu, mas faltou ou veio fora de faixa algum campo). Nenhuma
  das duas falhas vira "ocioso" nem "ocupado": a cor da leitura é `unknown`, o degrau fica, e o veredito não autoriza. Estado corrompido (JSON ruim, bytes
  não-UTF-8, aninhado fundo demais, campo faltando) é posto de lado (state.json.corrupt-<época>) e o degrau recomeça no MENOR; estado que existe mas não abre
  = erro, não "recomeça". O mesmo vale para config.json: ilegível por qualquer motivo = erro (NÃO SEI no veredito), nunca o padrão.
  Se o ssh nem executa (sem o binário, sem permissão) a leitura é `unreadable` (ferramenta quebrada), não `unreachable` (nó fora).

ARQUIVOS  (pasta de estado: $HETZNER_CAPACITY_DIR, senão <cidade>/.gc/hetzner-capacity, cidade = pasta acima de scripts/)
  state.json (degrau, desde quando, últimas leituras) · readings.jsonl (toda medição, para o antes×depois) · events.jsonl (mudança de degrau, pausa, alarme) ·
  config.json (opcional; chave desconhecida ou valor inválido = erro, não "usa o padrão") · pause.json · lock (um ciclo por vez; quem não pega o lock lê o cache).
  Lê também: $GC_SSH_CONFIG ou <cidade>/.gc/session-ssh.json (host, cap, liberação) e $HETZNER_CAPACITY_SHIM_CONFIG ou ~/.gastown/remote-shim.json (gate_done_bin).
  Para os testes: HETZNER_CAPACITY_SSH_CMD e HETZNER_CAPACITY_LIST_CMD (lista JSON de argumentos) trocam o ssh e o list-running; HETZNER_CAPACITY_SESSIONS_CMD e
  HETZNER_CAPACITY_BEADS_CMD trocam o `gc session list --json` e o `bd list --status in_progress --json`; HETZNER_CAPACITY_READ_TIMEOUT_S ENCURTA o prazo dessas duas leituras
  (25 s o gc, 15 s o bd; nunca alonga); HETZNER_CAPACITY_NOW (época) troca o relógio.

O QUE NÃO FAZ
  Não abre sessão, não encerra sessão, não atribui bead (só LÊ gc e bd), não mexe em city.toml, agents/ nem session-ssh.json. O degrau é o teto de OPERAÇÃO; os tetos FIXOS (`cap` do host no provider
  e `max_active_sessions` do dog-remote) continuam sendo o limite duro, e o veredito usa o MENOR dos dois. Quem leva a bead ao nó (atribuir ao alias dog-remote-<n> e
  abrir a sessão) é outra fatia: aqui só se diz se pode.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.realpath(__file__))
CITY = os.path.dirname(HERE)
POOL_DOG_ALIAS = re.compile(r"dog-remote-[0-9]+")      # o alias do pool dog-remote: o Pilot atribui a bead a ele. dog-remote-adhoc-*, gate-reviewer-*, wa-worker-* não casam: não têm bead-por-alias
READ_TIMEOUT_GC_S = 25       # `gc session list --json` leva 10-21 s no mini com load 44 (medido 19/10); estourou = ilegível = ocupada. As duas leituras correm em PARALELO: o custo é o da maior
READ_TIMEOUT_BD_S = 15       # `bd list --status in_progress --json` leva ~3 s; ssh (2 leituras) + a maior das duas leituras cabe nos 40 s que o Pilot dá ao veredito inteiro

DEFAULTS = {
    "host": "hetzner",                 # chave em session-ssh.json → hosts
    "steps": [1, 3, 6, 10],
    "cpu_up_headroom_pct": 10.0,       # verde = sobra para mais uma sessão (~1,6 núcleo dos 16). Era 35: a cidade nunca levava o nó acima de ~65% (ga-2hd02v.2)
    "cpu_down_headroom_pct": 3.0,       # abaixo disto o veredito do momento é `node_hot` (a bead nova vai ao mini). Só derruba o degrau com cpu_lowers_ceiling
    "mem_up_avail_pct": 40.0,
    "mem_down_avail_pct": 20.0,
    "up_window_s": 480,                # com o `step` a cada 180 s cabem 3 leituras: ~9 min por degrau. Era 1800 s e 6 leituras, sobre o ritmo do Pilot (~2 por janela)
    "up_min_reads": 3,
    "down_reads": 2,
    "refresh_s": 60,                   # a leitura é refeita no máximo a cada tanto (o Pilot pode chamar o veredito a cada varredura)
    "max_age_s": 900,                  # leitura mais velha que isto não autoriza nada
    "ssh_timeout_s": 25,
    "require_load_proof": True,
    "cpu_lowers_ceiling": False,       # False: só a RAM desce o degrau (o nó não tem swap). True: a regra antiga, CPU livre < cpu_down_headroom_pct também desce
}
MAX_READINGS = 500
LOG_MAX_BYTES = 2_000_000
BEGIN, END = "@@CAP-BEGIN@@", "@@CAP-END@@"
# Roda no nó (sh). Duas amostras do /proc/stat com 2 s no meio; o resto é leitura de arquivo.
NODE_SH = """echo @@CAP-BEGIN@@
echo "ncpu=$(nproc 2>/dev/null)"
echo "stat1=$(head -n1 /proc/stat)"
sleep 2
echo "stat2=$(head -n1 /proc/stat)"
echo "load=$(cat /proc/loadavg)"
grep -E '^(MemTotal|MemAvailable):' /proc/meminfo
echo @@CAP-END@@
"""


class Unreadable(Exception):
    """A leitura veio, mas falta campo ou ele está fora de faixa."""


class ConfigError(Exception):
    """Config (do script, do provider ou do atalho) existe e não presta, ou não abre: nunca vira 'usa o padrão'."""


class StateUnreadable(Exception):
    """O state.json existe e não consigo abri-lo: não é 'recomeça'."""


def is_num(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool)


# ───────────────────────────────── configuração ─────────────────────────────────

def load_config(path: str) -> dict:
    cfg = dict(DEFAULTS)
    # vazio (arquivo ausente) → os padrões; ilegível/JSON ruim/bytes não-UTF-8 (UnicodeDecodeError é ValueError)/aninhado fundo demais/chave desconhecida/valor inválido → ConfigError (nada de padrão silencioso)
    try:
        with open(path, encoding="utf-8") as f:
            user = json.load(f)
    except FileNotFoundError:
        return cfg
    except OSError as e:
        raise ConfigError(f"{path}: não abre ({e})")
    except (ValueError, RecursionError) as e:
        raise ConfigError(f"{path}: JSON inválido ou não é UTF-8 ({e})")
    if not isinstance(user, dict):
        raise ConfigError(f"{path}: o topo tem que ser um objeto")
    for k in user:
        if k not in DEFAULTS:
            raise ConfigError(f"{path}: chave desconhecida {k!r} (válidas: {', '.join(sorted(DEFAULTS))})")
    cfg.update(user)
    for k in ("up_window_s", "up_min_reads", "down_reads", "refresh_s", "max_age_s", "ssh_timeout_s"):
        if not isinstance(cfg[k], int) or isinstance(cfg[k], bool) or cfg[k] < 1:
            raise ConfigError(f"{path}: {k} tem que ser inteiro >= 1")
    for k in ("cpu_up_headroom_pct", "cpu_down_headroom_pct", "mem_up_avail_pct", "mem_down_avail_pct"):
        if not is_num(cfg[k]) or not 0 <= cfg[k] <= 100:
            raise ConfigError(f"{path}: {k} tem que ser número entre 0 e 100")
    if cfg["cpu_down_headroom_pct"] >= cfg["cpu_up_headroom_pct"] or cfg["mem_down_avail_pct"] >= cfg["mem_up_avail_pct"]:
        raise ConfigError(f"{path}: o limite de descer tem que ser MENOR que o de subir (sem faixa âmbar o degrau oscila)")
    s = cfg["steps"]
    if (not isinstance(s, list) or not s or any(not isinstance(x, int) or isinstance(x, bool) or x < 1 for x in s)
            or any(b <= a for a, b in zip(s, s[1:]))):
        raise ConfigError(f"{path}: steps tem que ser lista de inteiros >= 1 em ordem estritamente crescente")
    if cfg["max_age_s"] <= cfg["refresh_s"]:
        raise ConfigError(f"{path}: max_age_s ({cfg['max_age_s']}) tem que ser MAIOR que refresh_s ({cfg['refresh_s']}), senão toda leitura fica velha antes de ser refeita")
    if not isinstance(cfg["host"], str) or not cfg["host"]:
        raise ConfigError(f"{path}: host tem que ser texto não vazio")
    for k in ("require_load_proof", "cpu_lowers_ceiling"):
        if not isinstance(cfg[k], bool):
            raise ConfigError(f"{path}: {k} tem que ser true/false")
    return cfg


class Env:
    """Onde ficam as coisas. Tudo resolvido uma vez; os testes trocam pelas variáveis de ambiente."""

    def __init__(self, dir_arg: str | None = None):
        self.dir = dir_arg or os.environ.get("HETZNER_CAPACITY_DIR") or os.path.join(CITY, ".gc", "hetzner-capacity")
        self.state = os.path.join(self.dir, "state.json")
        self.readings = os.path.join(self.dir, "readings.jsonl")
        self.events = os.path.join(self.dir, "events.jsonl")
        self.config = os.path.join(self.dir, "config.json")
        self.pause = os.path.join(self.dir, "pause.json")
        self.lock = os.path.join(self.dir, "lock")
        self.ssh_cfg = os.environ.get("GC_SSH_CONFIG") or os.path.join(CITY, ".gc", "session-ssh.json")
        self.shim_cfg = os.environ.get("HETZNER_CAPACITY_SHIM_CONFIG") or os.path.join(os.path.expanduser("~"), ".gastown", "remote-shim.json")


def json_env_cmd(name: str, default: list) -> list:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        v = json.loads(raw)
    except ValueError:
        v = None
    if not isinstance(v, list) or not v or any(not isinstance(x, str) for x in v):
        raise ConfigError(f"{name}: tem que ser uma lista JSON de textos")
    return v


def read_json(path: str, what: str) -> dict:
    # vazio (arquivo ausente) → ConfigError "não existe"; ilegível/JSON ruim/não é objeto → ConfigError com o motivo. Os dois viram NÃO SEI no veredito (nunca "liberado" nem {}).
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
    except FileNotFoundError:
        raise ConfigError(f"{what}: {path} não existe")
    except (OSError, ValueError, RecursionError) as e:
        raise ConfigError(f"{what}: {path} não abre/não é JSON ({e})")
    if not isinstance(v, dict):
        raise ConfigError(f"{what}: {path}: o topo tem que ser um objeto")
    return v


def host_caps(env: Env, host: str) -> dict:
    """{'cap': int, 'released': bool, 'ssh': str} do host no session-ssh.json. Falta `cap` ou `ssh` = ConfigError (o provider também recusa sem cap)."""
    h = read_json(env.ssh_cfg, "config do provider").get("hosts")
    h = h.get(host) if isinstance(h, dict) else None
    if not isinstance(h, dict):
        raise ConfigError(f"config do provider: host {host!r} não está em {env.ssh_cfg}")
    cap, ssh = h.get("cap"), h.get("ssh")
    if not isinstance(cap, int) or isinstance(cap, bool) or cap < 1 or not isinstance(ssh, str) or not ssh:
        raise ConfigError(f"config do provider: host {host!r} sem `cap` inteiro >= 1 ou sem `ssh`")
    rel = h.get("real_sessions_released_by")
    return {"cap": cap, "ssh": ssh, "released": isinstance(rel, str) and bool(rel.strip())}


def gate_done_state(env: Env) -> str:
    """'ok' | 'off' (nulo/vazio) | 'not-exec' (configurado mas não executável, ou caminho relativo: o atalho recusa a config inteira). Ilegível = ConfigError."""
    v = read_json(env.shim_cfg, "config do atalho").get("gate_done_bin", None)
    if v is None or v == "":
        return "off"
    if not isinstance(v, str):
        raise ConfigError("config do atalho: gate_done_bin tem que ser texto ou null")
    return "ok" if os.path.isabs(v) and os.path.isfile(v) and os.access(v, os.X_OK) else "not-exec"


# ───────────────────────────────── medição ─────────────────────────────────

def cpu_times(line: str):
    f = line.split()
    if len(f) < 9 or f[0] != "cpu":
        raise Unreadable(f"linha do /proc/stat estranha: {line[:60]!r}")
    try:
        n = [int(x) for x in f[1:9]]
    except ValueError:
        raise Unreadable(f"/proc/stat não numérico: {line[:60]!r}")
    return sum(n), n[3] + n[4]            # total (user..steal), parado (idle + iowait)


def parse_node(out: str) -> dict:
    """Texto entre os marcadores → medidas. Campo que falta ou fora de faixa levanta Unreadable: nada é preenchido com 0."""
    kv = {}
    for line in out.splitlines():
        for key, sep in (("ncpu", "="), ("stat1", "="), ("stat2", "="), ("load", "="), ("MemTotal", ":"), ("MemAvailable", ":")):
            if line.startswith(key + sep) and key not in kv:        # a primeira ocorrência vale
                kv[key] = line[len(key) + 1:].strip()
    for k in ("ncpu", "stat1", "stat2", "load", "MemTotal", "MemAvailable"):
        if k not in kv:
            raise Unreadable(f"faltou {k} na resposta do nó")
    try:
        ncpu = int(kv["ncpu"])
        load5 = float(kv["load"].split()[1])
        mt, ma = int(kv["MemTotal"].split()[0]), int(kv["MemAvailable"].split()[0])
    except (ValueError, IndexError):
        raise Unreadable("ncpu, loadavg ou meminfo não numérico")
    (t1, i1), (t2, i2) = cpu_times(kv["stat1"]), cpu_times(kv["stat2"])
    dt, di = t2 - t1, i2 - i1
    # load5 nan/inf também é fora de faixa: `nan < 0` é falso e o min() abaixo largaria a carga sem avisar (a leitura saía verde); inf sairia como "ok" de CPU 0
    if ncpu < 1 or mt <= 0 or not 0 <= ma <= mt or dt <= 0 or not 0 <= di <= dt or not 0 <= load5 < float("inf"):
        raise Unreadable(f"valor fora de faixa (ncpu={ncpu} mem={ma}/{mt} dt={dt} di={di} load5={load5})")
    idle_pct = 100.0 * di / dt
    cpu_headroom = max(0.0, min(100.0, idle_pct, 100.0 * (1.0 - load5 / ncpu)))
    return {"ncpu": ncpu, "cpu_idle_pct": round(idle_pct, 1), "load5": load5, "cpu_headroom_pct": round(cpu_headroom, 1),
            "mem_avail_pct": round(100.0 * ma / mt, 1), "mem_avail_mb": ma // 1024}


def between_markers(text: str) -> str:
    """Só o que está entre os marcadores: ruído de .bashrc não vira dado, e resposta cortada (sem o fim) é Unreadable, não 'lista vazia'."""
    lines = text.splitlines()
    if BEGIN not in lines or END not in lines or lines.index(END) < lines.index(BEGIN):
        raise Unreadable("resposta do nó sem os marcadores de início e fim (cortada?)")
    return "\n".join(lines[lines.index(BEGIN) + 1:lines.index(END)])


def run_ssh(env: Env, cfg: dict, ssh_dest: str) -> str:
    base = json_env_cmd("HETZNER_CAPACITY_SSH_CMD", None)
    if base is None:
        cm = os.path.join(os.path.expanduser("~"), ".ssh", "cm")   # o mesmo ControlPath do provider e do mbp-run.sh: a conexão é reaproveitada
        base = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        if os.path.isdir(cm):
            base += ["-o", "ControlMaster=auto", "-o", f"ControlPath={cm}/%C", "-o", "ControlPersist=600"]
        base += [ssh_dest, "sh", "-s"]
    p = subprocess.run(base, input=NODE_SH.encode(), capture_output=True, timeout=cfg["ssh_timeout_s"])
    if p.returncode == 255:
        raise ConnectionError(f"ssh não conectou: {p.stderr.decode('utf-8', 'replace').strip()[:120]}")
    if p.returncode != 0:
        raise Unreadable(f"o script no nó saiu com {p.returncode}: {p.stderr.decode('utf-8', 'replace').strip()[:120]}")
    return p.stdout.decode("utf-8", "replace")


def list_sessions(env: Env, host: str) -> list:
    """Nomes das sessões que o PROVIDER tem abertas no nó (o mesmo `list-running` do engine). Falha = Unreadable; saída vazia com rc 0 = lista vazia."""
    cmd = json_env_cmd("HETZNER_CAPACITY_LIST_CMD", [sys.executable, "-I", os.path.join(HERE, "gc-session-ssh"), "list-running"])
    e = dict(os.environ, GC_SSH_HOST=host)
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=40, env=e, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Unreadable("list-running estourou o prazo")
    except OSError as ex:
        raise Unreadable(f"list-running não rodou ({ex})")
    if p.returncode != 0:
        raise Unreadable(f"list-running saiu com {p.returncode}: {p.stderr.decode('utf-8', 'replace').strip()[:120]}")
    return [l.strip() for l in p.stdout.decode("utf-8", "replace").splitlines() if l.strip()]


def read_timeout(default: float) -> float:
    """O prazo de uma leitura de gc/bd: `default`, que HETZNER_CAPACITY_READ_TIMEOUT_S (só para os testes) pode ENCURTAR, nunca alongar nem desligar."""
    # vazio (variável ausente) → o prazo padrão; ilegível (não é número, é <= 0, nan) → o prazo padrão também: a variável só encurta
    try:
        v = float(os.environ.get("HETZNER_CAPACITY_READ_TIMEOUT_S", ""))
    except ValueError:
        return default
    return min(v, default) if v > 0 else default


def read_json_cmd(name: str, default: list, what: str, timeout_s: float):
    """Roda um comando de leitura (gc/bd) e devolve o JSON dele. Qualquer coisa que não seja um JSON lido = Unreadable (rc≠0, prazo, não executa, vazio, não é JSON)."""
    cmd = json_env_cmd(name, default)
    limit = read_timeout(timeout_s)
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=limit, stdin=subprocess.DEVNULL, cwd=CITY)
    except subprocess.TimeoutExpired:
        raise Unreadable(f"{what} estourou o prazo ({limit:g}s)")
    except OSError as ex:
        raise Unreadable(f"{what} não rodou ({ex})")
    if p.returncode != 0:
        raise Unreadable(f"{what} saiu com {p.returncode}: {p.stderr.decode('utf-8', 'replace').strip()[:120]}")
    try:
        return json.loads(p.stdout.decode("utf-8"))
    except (ValueError, RecursionError):        # inclui saída vazia e bytes que não são UTF-8
        raise Unreadable(f"{what}: a saída não é JSON")


def busy_aliases() -> set:
    """Os donos (assignee) das beads in_progress da cidade. Lista lida e vazia = conjunto vazio (ninguém trabalha); qualquer outra coisa que não seja uma lista de objetos = Unreadable."""
    # vazio ([] lido) → conjunto vazio: ninguém tem bead, as dog-remote do nó são vaga; falhou/ilegível (rc≠0, prazo, não é JSON, não é lista de objetos) → Unreadable
    rows = read_json_cmd("HETZNER_CAPACITY_BEADS_CMD", ["bd", "-C", CITY, "list", "--status", "in_progress", "--json", "--limit", "0"], "bd list in_progress", READ_TIMEOUT_BD_S)
    if not isinstance(rows, list) or any(not isinstance(b, dict) or not isinstance(b.get("assignee", ""), (str, type(None))) for b in rows):
        raise Unreadable("bd list in_progress: a saída não é uma lista de beads")
    return {b["assignee"] for b in rows if isinstance(b.get("assignee"), str) and b["assignee"]}


def session_owners() -> dict:
    """session_name → {alias, session_name}: os nomes pelos quais uma bead in_progress pode estar com a sessão (a tmux do nó se chama dog-remote-<id>; o Pilot atribui ao ALIAS
    dog-remote-<n>). Só entra sessão aberta com alias de POOL (dog-remote-<n>): sem alias, ou com alias de outro papel (dog-remote-adhoc-*, gate-reviewer-*), não há bead-por-alias
    que prove que está parada, e quem não entra conta ocupada."""
    # vazio (lista sem sessões) → ninguém entra, e toda dog-remote do nó fica sem dono conhecido = ocupada; falhou/ilegível (rc≠0, prazo, não é JSON, sem .sessions) → Unreadable
    doc = read_json_cmd("HETZNER_CAPACITY_SESSIONS_CMD", ["gc", "--city", CITY, "session", "list", "--json"], "gc session list", READ_TIMEOUT_GC_S)
    rows = doc.get("sessions") if isinstance(doc, dict) else None
    if not isinstance(rows, list):
        raise Unreadable("gc session list: sem a lista .sessions")
    return {x["session_name"]: {x["alias"], x["session_name"]} for x in rows
            if isinstance(x, dict) and x.get("closed") is not True and isinstance(x.get("session_name"), str) and isinstance(x.get("alias"), str) and POOL_DOG_ALIAS.fullmatch(x["alias"])}


def split_sessions(names: list) -> tuple:
    """(ocupadas, ociosas, porquê). Sessão VIVA não é sessão OCUPADA (ga-2hd02v.1.22): um dog-remote sem bead in_progress no alias dele é vaga, não lugar tomado.
    Só se prova ociosa a sessão `dog-remote-*` com alias de pool (`dog-remote-<n>`) e SEM bead in_progress nesse alias; o resto (gate-reviewer, wa-worker, dog-remote-adhoc,
    sem alias, fora da lista do gc) conta ocupado, como antes. As duas leituras (gc e bd) têm três estados: lida e vazia → ociosa · falhou/ilegível → TODAS as dog-remote contam ocupadas
    (nunca enche o nó além do teto) e o motivo vai em `why`."""
    dogs = [n for n in names if n.startswith("dog-remote-")]
    others = len(names) - len(dogs)
    if not dogs:
        return others, 0, ""
    # vazio (nenhuma bead in_progress, nenhuma sessão com alias) → as dog-remote sem dono conhecido contam ocupadas e as com dono sem bead contam ociosas;
    # falhou/ilegível (qualquer das duas leituras) → TODAS as sessões do nó contam ocupadas (o inerte: o veredito fica como era antes desta leitura), com o motivo
    # as duas leituras são independentes e lentas no mini: em paralelo o custo é o da maior, não a soma (o Pilot dá 40 s ao veredito inteiro)
    with ThreadPoolExecutor(max_workers=2) as pool:
        f_owners, f_work = pool.submit(session_owners), pool.submit(busy_aliases)
        try:
            owners, working = f_owners.result(), f_work.result()
        except Unreadable as e:
            return len(names), 0, f"não provei nenhuma sessão ociosa: {e}"
    idle = [n for n in dogs if n in owners and not (owners[n] & working)]
    return len(names) - len(idle), len(idle), ""


def measure(env: Env, cfg: dict, ssh_dest: str, now: int) -> dict:
    r = {"t": now, "state": "ok", "why": "", "sessions": None, "sessions_total": None, "sessions_idle": None, "idle_why": "", "sessions_why": ""}
    try:
        r.update(parse_node(between_markers(run_ssh(env, cfg, ssh_dest))))
    except (ConnectionError, subprocess.TimeoutExpired) as e:
        r.update(state="unreachable", why=str(e) or type(e).__name__)
    except (Unreadable, OSError) as e:          # OSError aqui = ssh que nem executa (sem o binário, sem permissão): ferramenta quebrada, não "nó fora"
        r.update(state="unreadable", why=str(e) or type(e).__name__)
    if r["state"] != "ok":
        r["sessions_why"] = "sem leitura do nó, não contei as sessões"
        return r
    try:
        names = list_sessions(env, cfg["host"])
        r["sessions_total"] = len(names)
        r["sessions"], r["sessions_idle"], r["idle_why"] = split_sessions(names)      # `sessions` = OCUPADAS: é o que o veredito e a prova de carga leem
    except Unreadable as e:
        r["sessions_why"] = str(e)
    return r


def color(r: dict, cfg: dict) -> str:
    """green / amber / red / unknown, SEMPRE pela política de agora (a cor não é gravada: mudar o limite reinterpreta o histórico)."""
    if r.get("state") != "ok" or not is_num(r.get("cpu_headroom_pct")) or not is_num(r.get("mem_avail_pct")):
        return "unknown"
    cpu, mem = r["cpu_headroom_pct"], r["mem_avail_pct"]
    if cpu < cfg["cpu_down_headroom_pct"] or mem < cfg["mem_down_avail_pct"]:
        return "red"
    if cpu >= cfg["cpu_up_headroom_pct"] and mem >= cfg["mem_up_avail_pct"]:
        return "green"
    return "amber"


# ───────────────────────────────── os degraus ─────────────────────────────────

def lowers_ceiling(r: dict, cfg: dict) -> bool:
    """A leitura conta para DESCER o degrau? (ga-2hd02v.2) Só a RAM abaixo de `mem_down_avail_pct` (o nó não tem swap). A CPU cheia não: quem a ocupa pode não ser sessão da
    cidade (o Traço BIM do Athos), a meta é o nó cheio, e a CPU quente já barra a bead NOVA no veredito do momento (node_hot). `cpu_lowers_ceiling=true` devolve a regra antiga."""
    # vazio/falhou/ilegível (leitura que não é ok, ou sem CPU/RAM numéricas) → cor `unknown` → não desce: sem leitura o degrau fica como está
    if color(r, cfg) != "red":
        return False
    return cfg["cpu_lowers_ceiling"] or r["mem_avail_pct"] < cfg["mem_down_avail_pct"]


def decide(st: dict, cfg: dict, now: int) -> dict:
    """{'action': up|down|hold, 'to': degrau, 'why': texto, 'unmet': [o que falta para subir]}. Pura: só olha o estado, a política e a hora."""
    steps, cur, reads = cfg["steps"], st["ceiling"], st["readings"]
    if cur not in steps:
        return {"action": "down", "to": steps[0], "why": f"degrau {cur} fora da lista {steps}: volta ao menor", "unmet": []}
    i = steps.index(cur)
    since = [r for r in reads if r["t"] > st["changed_at"]]      # evidência do degrau ATUAL: a leitura que provocou a mudança não vale duas vezes
    last = since[-cfg["down_reads"]:]
    if i > 0 and len(last) >= cfg["down_reads"] and all(lowers_ceiling(r, cfg) for r in last):
        r = last[-1]
        return {"action": "down", "to": steps[i - 1], "unmet": [],
                "why": f"{cfg['down_reads']} leituras seguidas vermelhas (CPU livre {r.get('cpu_headroom_pct')}%, RAM {r.get('mem_avail_pct')}%)" + ("" if cfg["cpu_lowers_ceiling"] else ": a RAM derruba o degrau")}
    if i == len(steps) - 1:
        return {"action": "hold", "to": cur, "why": "já no último degrau", "unmet": []}
    unmet = []
    waited = now - st["changed_at"]
    if waited < cfg["up_window_s"]:
        unmet.append(f"janela: faltam {cfg['up_window_s'] - waited}s dos {cfg['up_window_s']}s desde a última mudança")
    win = [r for r in since if now - r["t"] <= cfg["up_window_s"]]
    if len(win) < cfg["up_min_reads"]:
        unmet.append(f"leituras: {len(win)} na janela, precisa de {cfg['up_min_reads']}")
    bad = [r for r in win if color(r, cfg) != "green"]
    if bad:
        unmet.append(f"{len(bad)} de {len(win)} leituras da janela não estão verdes ({', '.join(sorted({color(r, cfg) for r in bad}))})")
    # vazio (sessions 0, ou nó sem dog-remote) → 0 >= cur é falso, não prova; falhou/ilegível (sessions não inteiro, ou idle_why com motivo / ausente = gc ou bd não lidos, ou leitura anterior à
    # separação ocupada×ociosa) → essa leitura não prova e não veta: o teto só sobe por outra leitura da janela que provou. `sessions` com idle_why é o TOTAL vivo contado como ocupado (inerte para o veredito).
    if cfg["require_load_proof"] and not any(isinstance(r.get("sessions"), int) and r.get("idle_why") == "" and r["sessions"] >= cur for r in win):
        unmet.append(f"prova de carga: nenhuma leitura da janela, com gc e bd lidos, com >= {cur} sessões ocupadas no nó")
    if unmet:
        return {"action": "hold", "to": cur, "why": "não subiu: " + "; ".join(unmet), "unmet": unmet}
    return {"action": "up", "to": steps[i + 1], "unmet": [],
            "why": f"{len(win)} leituras verdes em {cfg['up_window_s']}s" + (f", nó aguentou {cur} sessões" if cfg["require_load_proof"] else "")}


# ───────────────────────────────── estado em disco ─────────────────────────────────

def atomic_write(path: str, text: str) -> None:
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def present(path: str) -> bool:
    """True/False só quando o sistema de arquivos RESPONDEU. os.path.exists/lexists engolem o erro e devolvem False: 'não consegui olhar' viraria 'não existe'."""
    try:
        os.lstat(path)
        return True
    except FileNotFoundError:
        return False


def append_log(path: str, obj: dict) -> None:
    try:
        if os.path.getsize(path) > LOG_MAX_BYTES:
            os.replace(path, path + ".1")
    except OSError:
        pass                                  # sem o arquivo ainda (ou sem como medir): só segue; o append abaixo é quem diz se dá para gravar
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False, sort_keys=True) + "\n")


def fresh_state(cfg: dict, now: int, why: str) -> dict:
    return {"v": 1, "ceiling": cfg["steps"][0], "changed_at": now, "changed_why": why, "readings": []}


def valid_state(st) -> bool:
    return (isinstance(st, dict) and isinstance(st.get("ceiling"), int) and not isinstance(st["ceiling"], bool)
            and isinstance(st.get("changed_at"), int) and isinstance(st.get("changed_why"), str) and isinstance(st.get("readings"), list)
            and all(isinstance(r, dict) and isinstance(r.get("t"), int) and isinstance(r.get("state"), str) for r in st["readings"]))


def load_state(env: Env, cfg: dict, now: int, may_repair: bool):
    """(estado, alarmes). Ausente → começa no menor degrau. Corrompido → posto de lado (se pode gravar) e recomeça no menor, com alarme. Não abre → StateUnreadable."""
    try:
        with open(env.state, encoding="utf-8") as f:
            st = json.load(f)
    except FileNotFoundError:
        return fresh_state(cfg, now, "primeira execução"), []
    except OSError as e:
        raise StateUnreadable(f"{env.state}: não abre ({e})")
    except (ValueError, RecursionError):        # JSON ruim, bytes não-UTF-8 (UnicodeDecodeError é ValueError) ou aninhado fundo demais: o conteúdo está corrompido, igual
        st = None
    if valid_state(st):
        return st, []
    if not may_repair:
        raise StateUnreadable(f"{env.state}: corrompido e outro ciclo está com o lock; não mexo")
    aside = f"{env.state}.corrupt-{now}"
    os.replace(env.state, aside)
    msg = f"state.json corrompido: guardado em {os.path.basename(aside)}; degrau recomeça em {cfg['steps'][0]}"
    return fresh_state(cfg, now, msg), [msg]


def tick(env: Env, cfg: dict, now: int, ssh_dest: str, refresh: bool = True) -> dict:
    """Um ciclo: pega o lock SEM esperar, mede se a última leitura passou de refresh_s, avalia os degraus e grava. Sem o lock, devolve o cache (nada é gravado)."""
    os.makedirs(env.dir, exist_ok=True)
    out = {"refreshed": False, "locked": False, "decision": None, "alarms": [], "state": None}
    with open(env.lock, "a+") as lk:
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
            out["locked"] = True
        except OSError:
            out["locked"] = False
        st, alarms = load_state(env, cfg, now, may_repair=out["locked"])
        out["alarms"] = alarms
        dirty = bool(alarms) or not present(env.state)
        if out["locked"] and refresh:
            last = st["readings"][-1]["t"] if st["readings"] else None
            if last is None or now - last >= cfg["refresh_s"] or last > now:
                r = measure(env, cfg, ssh_dest, now)
                st["readings"] = (st["readings"] + [r])[-MAX_READINGS:]
                append_log(env.readings, dict(r, host=cfg["host"], color=color(r, cfg)))
                d = decide(st, cfg, now)
                out["decision"], out["refreshed"], dirty = d, True, True
                if d["action"] != "hold":
                    ev = {"t": now, "event": "ceiling", "from": st["ceiling"], "to": d["to"], "why": d["why"]}
                    st.update(ceiling=d["to"], changed_at=now, changed_why=d["why"])
                    append_log(env.events, ev)
        for a in alarms:
            append_log(env.events, {"t": now, "event": "alarm", "why": a})
        if out["locked"] and dirty:
            atomic_write(env.state, json.dumps(st, ensure_ascii=False, sort_keys=True))
        out["state"] = st
    return out


# ───────────────────────────────── o veredito ─────────────────────────────────

def idle_note(r: dict) -> str:
    """Texto curto para o detalhe do veredito: quantas vivas estão ociosas (vaga) e, se não deu para provar, por quê."""
    if r.get("idle_why"):
        return f" ({r['idle_why']})"
    return f" (+{r['sessions_idle']} vivas ociosas, contam vaga)" if isinstance(r.get("sessions_idle"), int) and r["sessions_idle"] > 0 else ""


def verdict(env: Env, cfg: dict, st: dict, now: int) -> dict:
    """{'verdict': node|local|unknown, 'reason': código, 'detail': texto, ...}. A primeira condição que falha decide; só `node` autoriza."""
    base = {"ceiling": st["ceiling"], "host_cap": None, "effective": None, "active": None, "free": None, "age_s": None, "reading": None}

    def out(v, reason, detail):
        return dict(base, verdict=v, reason=reason, detail=detail)

    # vazio (sem pause.json) → não pausado; existe → pausado; falhou ao olhar (que não "não existe") → NÃO SEI, nunca "não pausado"
    try:
        if present(env.pause):
            return out("local", "paused", "pausa do Mayor (pause.json)")
    except OSError as e:
        return out("unknown", "pause_unreadable", f"não consegui olhar o pause.json ({e})")
    try:
        caps = host_caps(env, cfg["host"])
    except ConfigError as e:
        return out("unknown", "provider_config", str(e))
    base["host_cap"] = caps["cap"]
    base["effective"] = min(st["ceiling"], caps["cap"])
    if not caps["released"]:
        return out("local", "not_released", "o host não tem real_sessions_released_by (liberação do Mayor)")
    try:
        gd = gate_done_state(env)
    except ConfigError as e:
        return out("unknown", "shim_config", str(e))
    if gd != "ok":
        return out("local", "gate_done_off" if gd == "off" else "gate_done_not_exec",
                   "gate_done_bin do atalho " + ("está nulo" if gd == "off" else "não é um executável de caminho absoluto") + ": bead entregue no nó não chegaria ao gate (ga-2hd02v.1.13)")
    r = st["readings"][-1] if st["readings"] else None
    if r is None:
        return out("unknown", "no_reading", "ainda não há nenhuma leitura do nó")
    base["age_s"], base["reading"] = now - r["t"], {k: r.get(k) for k in ("t", "state", "cpu_headroom_pct", "mem_avail_pct", "sessions", "sessions_total", "sessions_idle", "idle_why", "why")}
    if now - r["t"] > cfg["max_age_s"]:
        return out("unknown", "reading_stale", f"última leitura tem {now - r['t']}s (> {cfg['max_age_s']}s)")
    if now - r["t"] < -60:                    # leitura carimbada no futuro (o relógio voltou): idade negativa não é "recente"
        return out("unknown", "reading_future", f"última leitura é {r['t'] - now}s DEPOIS de agora (relógio?)")
    if r["state"] == "unreachable":
        return out("local", "node_down", f"o nó não respondeu: {r.get('why')}")
    if r["state"] != "ok":
        return out("unknown", "reading_unreadable", f"leitura do nó ilegível: {r.get('why')}")
    # leitura marcada ok mas sem CPU/RAM numéricas (só chega assim por state.json adulterado): cor `unknown` não é "não vermelha", é NÃO SEI
    if color(r, cfg) == "unknown":
        return out("unknown", "reading_unreadable", "leitura marcada ok mas sem CPU livre / RAM disponível numéricas (state.json adulterado?)")
    if color(r, cfg) == "red":
        return out("local", "node_hot", f"nó quente: CPU livre {r['cpu_headroom_pct']}%, RAM disponível {r['mem_avail_pct']}%")
    if not isinstance(r.get("sessions"), int):
        return out("unknown", "sessions_unreadable", f"não consegui contar as sessões do nó: {r.get('sessions_why')}")
    base["active"], base["free"] = r["sessions"], base["effective"] - r["sessions"]
    if r["sessions"] >= base["effective"]:
        return out("local", "node_full", f"{r['sessions']} sessões ocupadas no nó{idle_note(r)}, teto {base['effective']} (degrau {st['ceiling']}, cap do provider {caps['cap']})")
    return out("node", "free_slot", f"{r['sessions']} de {base['effective']} sessões ocupadas{idle_note(r)}; CPU livre {r['cpu_headroom_pct']}%, RAM {r['mem_avail_pct']}%")


# ───────────────────────────────── CPU por hora (a prova ao vivo da meta) ─────────────────────────────────

def read_readings(path: str) -> tuple:
    """(leituras, linhas ruins) de um readings.jsonl. Linha que não é objeto JSON com `t` inteiro é contada e pulada: não vira leitura nem zero."""
    # vazio (arquivo ausente) → ([], 0): nada medido ainda; falhou/ilegível (existe e não abre) → OSError sobe e o comando erra com rc 3, nunca "sem leitura"
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return [], 0
    out, bad = [], 0
    with f:
        for line in f:
            if not line.strip():
                continue
            try:
                o = json.loads(line)
            except (ValueError, RecursionError):
                bad += 1
                continue
            if isinstance(o, dict) and isinstance(o.get("t"), int) and not isinstance(o["t"], bool):
                out.append(o)
            else:
                bad += 1
    return out, bad


def hourly(env: Env, now: int, hours: int, min_pct: float) -> dict:
    """CPU OCUPADA (100 - ocioso da amostra de 2 s) por hora cheia UTC, nas últimas `hours` horas COMPLETAS (a hora corrente, parcial, não entra).
    Hora sem nenhuma leitura ok é `sem_leitura` (não prova nada: nem 0% nem OK); leitura que falhou (nó fora, ilegível) conta em `falhas` e fica fora da média."""
    rows, bad = [], 0
    for p in (env.readings + ".1", env.readings):         # o rotacionado primeiro; arquivo ausente = nada
        got, b = read_readings(p)
        rows += got
        bad += b
    cur = now // 3600
    busy = {h: [] for h in range(cur - hours, cur)}         # a CPU ocupada de cada leitura ok, por hora
    fails = {h: 0 for h in busy}
    for r in rows:
        h = r["t"] // 3600
        if h not in busy:
            continue
        idle = r.get("cpu_idle_pct")
        if r.get("state") == "ok" and is_num(idle) and 0 <= idle <= 100:
            busy[h].append(100.0 - idle)
        else:
            fails[h] += 1
    out = []
    for h, v in busy.items():
        mean = sum(v) / len(v) if v else None
        out.append({"hour": time.strftime("%Y-%m-%dT%HZ", time.gmtime(h * 3600)), "ok": len(v), "falhas": fails[h],
                    "media": None if mean is None else round(mean, 1), "min": round(min(v), 1) if v else None, "max": round(max(v), 1) if v else None,
                    "status": "sem_leitura" if mean is None else ("abaixo" if mean < min_pct else "ok")})
    return {"min_pct": min_pct, "hours": out, "bad_lines": bad, "all_ok": all(x["status"] == "ok" for x in out)}


def hourly_text(res: dict) -> str:
    lines = []
    for x in res["hours"]:
        s = f"{x['hour']}  {x['ok']:3d} leituras  " + (f"CPU ocupada média {x['media']}% (mín {x['min']}, máx {x['max']})" if x["ok"] else "SEM LEITURA")
        s += f"  +{x['falhas']} falhas" if x["falhas"] else ""
        s += f"  ABAIXO de {res['min_pct']:g}%" if x["status"] == "abaixo" else ""
        lines.append(s)
    lines.append(("tudo >= " + f"{res['min_pct']:g}%" if res["all_ok"] else "NÃO provado: há hora abaixo de " + f"{res['min_pct']:g}%" + " ou sem leitura") + (f" ({res['bad_lines']} linhas ruins puladas)" if res["bad_lines"] else ""))
    return "\n".join(lines)


# ───────────────────────────────── linha de comando ─────────────────────────────────

def say(args, obj: dict, text: str) -> None:
    print(json.dumps(obj, ensure_ascii=False, sort_keys=True) if args.json else text)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="hetzner-capacity.py", add_help=True)
    ap.add_argument("--dir", help="pasta de estado (padrão: $HETZNER_CAPACITY_DIR ou <cidade>/.gc/hetzner-capacity)")
    ap.add_argument("--json", action="store_true")
    common = argparse.ArgumentParser(add_help=False)     # as mesmas opções valem antes OU depois do comando; SUPPRESS evita o subcomando zerar o que veio antes dele
    common.add_argument("--dir", default=argparse.SUPPRESS)
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("verdict", "step", "status", "read", "resume"):
        sub.add_parser(c, parents=[common])
    sc = sub.add_parser("set-ceiling", parents=[common])
    sc.add_argument("n", type=int)
    sc.add_argument("--reason", required=True)
    pz = sub.add_parser("pause", parents=[common])
    pz.add_argument("--reason", required=True)
    hp = sub.add_parser("hourly", parents=[common])
    hp.add_argument("--hours", type=int, default=24)
    hp.add_argument("--min-pct", type=float, default=85.0)
    args = ap.parse_args(argv)
    env = Env(args.dir)
    try:
        # vazio (sem a variável) → o relógio de verdade; valor que não é inteiro → ConfigError, nunca "usa a hora de agora" (o relógio dos testes é só para testes)
        raw_now = os.environ.get("HETZNER_CAPACITY_NOW")
        try:
            now = int(raw_now) if raw_now else int(time.time())
        except ValueError:
            raise ConfigError(f"HETZNER_CAPACITY_NOW={raw_now!r} não é inteiro")
        cfg = load_config(env.config)
        if args.cmd == "pause":
            os.makedirs(env.dir, exist_ok=True)
            atomic_write(env.pause, json.dumps({"t": now, "reason": args.reason}, ensure_ascii=False))
            append_log(env.events, {"t": now, "event": "pause", "why": args.reason})
            say(args, {"paused": True}, f"pausado: {args.reason}")
            return 0
        if args.cmd == "resume":
            try:
                os.unlink(env.pause)
            except FileNotFoundError:
                pass
            if present(env.dir):
                append_log(env.events, {"t": now, "event": "resume"})
            say(args, {"paused": False}, "pausa retirada")
            return 0
        if args.cmd == "read":
            ssh_dest = host_caps(env, cfg["host"])["ssh"]
            r = measure(env, cfg, ssh_dest, now)
            r["color"] = color(r, cfg)
            say(args, r, f"{r['state']} {r['color']} CPU livre={r.get('cpu_headroom_pct')}% RAM={r.get('mem_avail_pct')}% sessões={r.get('sessions')} ocupadas de {r.get('sessions_total')} {r['why']}".strip())
            return 0 if r["state"] == "ok" else 1
        if args.cmd == "status":
            st, _ = load_state(env, cfg, now, may_repair=False)
            d = decide(st, cfg, now)
            try:
                caps = host_caps(env, cfg["host"])
            except ConfigError as e:
                caps = {"error": str(e)}
            last = st["readings"][-1] if st["readings"] else None
            obj = {"ceiling": st["ceiling"], "since_s": now - st["changed_at"], "changed_why": st["changed_why"], "reads": len(st["readings"]),
                   "last": dict(last, color=color(last, cfg)) if last else None, "next": d, "provider": caps, "paused": present(env.pause)}
            say(args, obj, f"degrau {st['ceiling']} há {obj['since_s']}s ({st['changed_why']}); {obj['reads']} leituras; próximo: {d['action']} — {d['why']}; provider {caps}")
            return 0
        if args.cmd == "hourly":
            if not 1 <= args.hours <= 720 or not 0 <= args.min_pct <= 100:      # nan também cai aqui (toda comparação com nan é falsa)
                print(f"hourly: --hours tem que estar em 1..720 e --min-pct em 0..100 (veio {args.hours} e {args.min_pct})", file=sys.stderr)
                return 3
            res = hourly(env, now, args.hours, args.min_pct)
            say(args, res, hourly_text(res))
            return 0 if res["all_ok"] else 1
        if args.cmd == "set-ceiling":
            if args.n not in cfg["steps"]:
                print(f"{args.n} não é um degrau ({cfg['steps']})", file=sys.stderr)
                return 3
            os.makedirs(env.dir, exist_ok=True)
            with open(env.lock, "a+") as lk:
                try:
                    fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError:
                    print("outro ciclo está rodando (lock); tente de novo", file=sys.stderr)
                    return 3
                st, _ = load_state(env, cfg, now, may_repair=True)
                old = st["ceiling"]
                st.update(ceiling=args.n, changed_at=now, changed_why=f"manual: {args.reason}")
                atomic_write(env.state, json.dumps(st, ensure_ascii=False, sort_keys=True))
                append_log(env.events, {"t": now, "event": "ceiling", "from": old, "to": args.n, "why": f"manual: {args.reason}"})
            say(args, {"ceiling": args.n}, f"degrau {old} → {args.n} (manual)")
            return 0
        # destino do ssh ilegível: `step` é erro (exit 3); o `verdict` não mede (nada a medir) e deixa o próprio veredito dizer provider_config (NÃO SEI)
        ssh_dest = None
        try:
            ssh_dest = host_caps(env, cfg["host"])["ssh"]
        except ConfigError:
            if args.cmd == "step":
                raise
        res = tick(env, cfg, now, ssh_dest, refresh=ssh_dest is not None)
        if args.cmd == "step":
            d = res["decision"]
            say(args, {"ceiling": res["state"]["ceiling"], "refreshed": res["refreshed"], "locked": res["locked"], "decision": d, "alarms": res["alarms"]},
                f"degrau {res['state']['ceiling']}" + (f" — {d['action']}: {d['why']}" if d else " — leitura em dia (ou outro ciclo rodando)"))
            return 0
        v = verdict(env, cfg, res["state"], now)
        v["alarms"] = res["alarms"]
        say(args, v, f"{v['verdict']} {v['reason']}: {v['detail']}")
        return {"node": 0, "local": 1}.get(v["verdict"], 2)
    except ConfigError as e:
        if args.cmd == "verdict":
            say(args, {"verdict": "unknown", "reason": "config", "detail": str(e)}, f"unknown config: {e}")
            return 2
        print(f"hetzner-capacity: {e}", file=sys.stderr)
        return 3
    except (StateUnreadable, OSError) as e:
        if args.cmd == "verdict":
            say(args, {"verdict": "unknown", "reason": "state", "detail": str(e)}, f"unknown state: {e}")
            return 2
        print(f"hetzner-capacity: {e}", file=sys.stderr)
        return 3
    except Exception as e:      # bug nosso: sem isto o Python sai com 1 (traceback), que aqui é o MINI conhecido. verdict → NÃO SEI (2); o resto → 3, nunca 0/1
        if args.cmd == "verdict":
            say(args, {"verdict": "unknown", "reason": "internal", "detail": f"{type(e).__name__}: {e}"}, f"unknown internal: {type(e).__name__}: {e}")
            return 2
        print(f"hetzner-capacity: erro interno: {type(e).__name__}: {e}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
