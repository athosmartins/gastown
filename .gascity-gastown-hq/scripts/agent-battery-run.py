#!/usr/bin/env python3
"""agent-battery-run.py — executor por tarefa da bateria noturna de agentes (ga-hyp55ss.1, fatia 2).

## Contents
  Uso · O que faz por tarefa · Teto de tokens · Estados · Códigos de saída

USO: agent-battery-run.py [--tasks ARQ] [--repo DIR] [--prefix SUBPASTA] [--config-ref REF] [--as-role PAPEL] [--limit N]
        [--only BEAD]... [--model M] [--token-cap N] [--task-reserve-tokens N] [--task-budget-usd X] [--agent-timeout S]
        [--selftest-timeout S] [--state-dir DIR] [--out ARQ] [--claude CMD] [--claude-extra ARGS] [--role-prompt PAPEL=CAMINHO]...
        [--infra-stop N] [--agent-real-home] [--day AAAA-MM-DD] [--dry-run | --verify-only]
  Lê o acervo da fatia 1 (agent-battery-corpus.py) e roda cada tarefa; grava uma linha JSON por tarefa:
  {task, papel, config_sha, estado, ok, tokens, motivo} (+ duracao_s nas que chamaram o agente). Só `estado == "medida"` entra na taxa; ok é true/false só aí, senão null.

O QUE FAZ POR TAREFA (um worktree descartável, sempre removido): (1) valida os campos do acervo — `success.commands` NÃO é usado: o argv
  é montado aqui, ['bash', caminho], e caminho/sha fora da regex estrita descartam a tarefa, contada; (2) confere que o selftest PASSA em
  fix_sha e REPROVA em base_sha (com só os test_files do fix copiados): senão a tarefa é descartada, com o motivo; (3) põe por cima do
  checkout a CONFIGURAÇÃO sob teste (--config-ref: .claude/, CLAUDE.md e o prompt do papel; o prompt vai por --append-system-prompt-file)
  e roda `claude -p` com o enunciado da bead; (4) restaura os selftests do fix (o agente não pode "passar" editando o teste) e roda-os:
  passou = ok. config_sha = hash do conteúdo dessa configuração + do prompt do papel.
TETO DE TOKENS: por noite (--token-cap, ledger em <state-dir>/spend-<dia>.json, soma entre rodadas do mesmo dia UTC; tokens = entrada +
  saída + cache_creation, cache_read vai à parte) e por tarefa (--max-budget-usd do CLI). Antes de cada tarefa: gasto + reserva > teto →
  PARA LIMPO: o resto vira `pulada` (motivo teto_de_tokens), rc 6. Saída do agente ilegível = gasto DESCONHECIDO, cobrado como a reserva
  (nunca como zero). Ledger ilegível = não sei quanto já gastei: nada roda (rc 5).
ESTADOS: medida (rodou o agente e conferiu o selftest) · descartada (tarefa não serve; motivo) · pulada (freio ou papel sem prompt) ·
  infra (o agente não pôde ser medido: login/cota/API/saída ilegível, o `claude` não INICIOU, git sem resposta; não entra na taxa).
  Timeout do agente é FALHA medida (um prompt que faz o agente girar sem parar é exatamente a regressão que a bateria tem de ver);
  "não iniciou" (OSError no exec) NÃO é timeout: é infra e não cobra reserva. Três infra seguidas SEM uma medida no meio param a rodada.
CÓDIGOS: 0 ok · 2 uso errado, acervo/git ilegível · 3 nenhuma tarefa utilizável · 4 não consegui gravar saída/ledger · 5 ledger ilegível ·
  6 freio de tokens (parcial gravado) · 7 outra rodada em andamento · 8 claude ausente ou infra repetida (parcial gravado).
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import resource
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

SHA_RE = re.compile(r"^[0-9a-f]{40}\Z")
TASK_RE = re.compile(r"^ga-[a-z0-9]+(\.[0-9]{1,4})*\Z")
ROLE_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}\Z")
PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+\Z")
TEST_RE = re.compile(r"^[A-Za-z0-9._/-]+\.selftest\.sh\Z")
ROOTS = ("scripts/", "packs/", "formulas/", "commands/")  # começa por letra: um caminho nunca vira opção do bash
TEST_ROOTS = ROOTS + ("docs/",)  # o acervo aceita selftest também em docs/ (ALLOW_ROOTS da fatia 1)
ROLE_PROMPTS = {"dog": "agents/dog-remote/prompt.template.md", "wa-worker": "agents/wa-worker/prompt.template.md",
                "ps-worker": "agents/ps-worker/prompt.template.md", "reviewer": "agents/gate-reviewer/prompt.template.md"}
CONFIG_PATHS = (".claude", "CLAUDE.md")  # + <prefix>/CLAUDE.md
FSIZE = 512 * 1024 * 1024
KEEP_SECRET = ("CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY")
NOT_STARTED = "nao_iniciou"  # rc de run_capped: o exec falhou (≠ None, que é o prazo estourado)
KEEP_ENV = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "USER", "LOGNAME")  # lista de PERMITIDOS: o resto do ambiente não passa

def die(code, msg):
    print("agent-battery-run: " + msg, file=sys.stderr)
    sys.exit(code)

def _limits():
    resource.setrlimit(resource.RLIMIT_FSIZE, (FSIZE, FSIZE))

def run_capped(argv, cwd, env, timeout, stdin_text=None):
    """(rc, out, err). rc NOT_STARTED = o exec falhou (binário trocado/shebang quebrado/EMFILE...); rc None = estourou o prazo (o grupo todo é
    morto); os dois são 'não sei' (nunca 0), mas DIFERENTES: timeout é falha do prompt, não-iniciou é infra."""
    try:
        p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace",
                             start_new_session=True, preexec_fn=_limits)
    except (OSError, ValueError, subprocess.SubprocessError):  # SubprocessError = preexec_fn falhou
        return NOT_STARTED, "", ""
    try:
        out, err = p.communicate(stdin_text, timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(OSError):
            os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return None, "", ""
    return p.returncode, out, err

def git(repo, *args, timeout=300):
    return run_capped(["git", "-C", repo] + list(args), None, dict(os.environ, GIT_TERMINAL_PROMPT="0"), timeout)[:2]

def tree_files(repo, ref, paths):
    """[(nome, blob_sha, modo)] dos arquivos comuns sob `paths` em `ref`. None = git falhou (≠ lista vazia, que é 'não há')."""
    rc, out = git(repo, "ls-tree", "-r", "-z", ref, "--", *paths)
    if rc != 0:
        return None
    res = []
    for ent in out.split("\0"):
        meta, _, name = ent.partition("\t")
        f = meta.split(" ")
        if len(f) == 3 and f[0] in ("100644", "100755"):  # symlink (120000) e submódulo (160000) ficam de fora
            res.append((name, f[2], f[0]))
    return sorted(res)

def blob(repo, sha):
    """bytes do blob; None = não consegui ler (um blob vazio legítimo é b'')."""
    try:
        p = subprocess.run(["git", "-C", repo, "cat-file", "blob", sha], capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout if p.returncode == 0 else None

def write_into(wt, name, data, mode):
    dest = os.path.join(wt, name)
    real = os.path.realpath(os.path.dirname(dest))
    if not (real + os.sep).startswith(os.path.realpath(wt) + os.sep):
        return False  # diretório que é symlink para fora do checkout: não escreve
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with contextlib.suppress(FileNotFoundError):
        os.unlink(dest)
    with open(dest, "wb") as f:
        f.write(data)
    os.chmod(dest, 0o755 if mode == "100755" else 0o644)
    return True

def put_files(repo, wt, entries):
    for name, sha, mode in entries:
        data = blob(repo, sha)
        if data is None or not write_into(wt, name, data, mode):
            return False
    return True

def good_path(p, rx, roots=ROOTS):
    return (isinstance(p, str) and rx.match(p) is not None and p.startswith(roots) and "//" not in p
            and ".." not in p.split("/") and "." not in p.split("/"))

def validate(t):
    """None se a tarefa serve; senão o motivo. O que o acervo traz NUNCA vai para um shell: só estes campos, só estas regex."""
    if not isinstance(t, dict):
        return "argumento_invalido:linha"
    if not isinstance(t.get("task_id"), str) or not TASK_RE.match(t["task_id"]):
        return "argumento_invalido:task_id"
    for k in ("base_sha", "fix_sha"):
        if not isinstance(t.get(k), str) or not SHA_RE.match(t[k]):
            return "argumento_invalido:" + k
    if not isinstance(t.get("role"), str) or not ROLE_RE.match(t["role"]):
        return "argumento_invalido:role"
    for k, rx, roots in (("test_files", TEST_RE, TEST_ROOTS), ("prod_files", PATH_RE, ROOTS)):
        v = t.get(k)
        if not isinstance(v, list) or not v or not all(good_path(p, rx, roots) for p in v):
            return "argumento_invalido:" + k
    if not isinstance(t.get("description"), str) or not isinstance(t.get("title"), str):
        return "argumento_invalido:enunciado"
    return None

def suite_state(rcs, after_agent=False):
    """pass | fail | indeterminado. 126/127/None/NOT_STARTED = o teste nem rodou: 'não sei' (nunca 'reprovou'). Depois do agente o mesmo selftest
    já deu 0 em fix_sha neste ambiente: 126/127 ali é o agente que quebrou o que o selftest chama (apagou, tirou o x) = falha."""
    if any(isinstance(r, int) and (r not in (0, 126, 127) or (after_agent and r in (126, 127))) for r in rcs):
        return "fail"
    return "indeterminado" if any(not isinstance(r, int) or r in (126, 127) for r in rcs) else "pass"

def run_tests(wt_dir, tests, timeout, after_agent=False):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": wt_dir, "TMPDIR": wt_dir, "LANG": "C.UTF-8"}
    return suite_state([run_capped(["bash", t], wt_dir, env, timeout)[0] for t in tests], after_agent)

def agent_env(home, real_home):
    """Ambiente do agente por lista de permitidos: PATH/LANG/..., a credencial do claude e nada mais. HOME e TMPDIR são o diretório descartável;
    só com --agent-real-home e SEM credencial em env o HOME é o real (login guardado), e o agente passa a enxergar o HOME do operador."""
    # vazio/ausente → a variável não passa (o agente roda sem ela); falhou/ilegível → não existe leitura que falhe: os.environ é memória do processo
    env = {k: os.environ[k] for k in KEEP_ENV if k in os.environ}
    creds = {k: os.environ[k] for k in KEEP_SECRET if os.environ.get(k)}
    env.update(creds)
    env["HOME"] = os.environ["HOME"] if real_home and not creds and os.environ.get("HOME") else home
    env["TMPDIR"] = home
    return env

def agent_allowed(tests):
    """Só rodar o próprio selftest. Ler/editar dentro do checkout vem do modo acceptEdits e de leitura não pedir permissão;
    nada de bash scripts/* (o agente escreveria um script e o rodaria) nem cat/git, que leem fora do checkout."""
    return ",".join("Bash(bash %s:*)" % t for t in tests)

def build_prompt(t):
    esc = lambda s: s.replace("</enunciado_da_bead>", "<\\/enunciado_da_bead>")
    return ("Você está num checkout descartável do repositório. Corrija a bead abaixo editando os arquivos de produção.\n"
            "O(s) selftest(s) %s já estão no checkout e REPROVAM hoje; o trabalho termina quando passarem (rode com `bash <arquivo>`). "
            "Não edite os selftests: são restaurados antes da conferência. Sem rede, sem commit, nada fora do checkout.\n\n"
            "<enunciado_da_bead id=\"%s\">\n%s\n\n%s\n</enunciado_da_bead>\n"
            % (", ".join(t["test_files"]), t["task_id"], esc(t["title"]), esc(t["description"])))

def parse_claude(out):
    """dict do resultado do `claude -p --output-format json`; None = ilegível (vazio e podre dão o MESMO 'não sei', nunca 'ok')."""
    try:
        d = json.loads(out)
    except ValueError:
        return None
    if isinstance(d, list):
        d = next((x for x in reversed(d) if isinstance(x, dict) and x.get("type") == "result"), None)
    return d if isinstance(d, dict) and d.get("type") == "result" else None

def tokens_of(d):
    """(gasto, cache_read) — gasto = entrada + saída + cache_creation; None se o uso não veio inteiro (desconhecido ≠ zero)."""
    u = d.get("usage") if isinstance(d, dict) else None
    if not isinstance(u, dict):
        return None, None
    vals = [u.get(k) for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")]
    if not all(isinstance(v, int) and not isinstance(v, bool) and v >= 0 for v in vals):
        return None, None
    return vals[0] + vals[1] + vals[2], vals[3]

def read_ledger(path):
    # vazio (arquivo ausente) → 0 gasto, é a 1ª rodada do dia; falhou/ilegível → None e o chamador sai com rc 5.
    try:
        with open(path) as f:
            d = json.load(f)
    except FileNotFoundError:
        return 0
    except (OSError, ValueError):
        return None
    v = d.get("tokens") if isinstance(d, dict) else None
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None

def atomic_write(path, text):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-run-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise

class Ctx:
    pass

def role_of(a, t):
    """papel da tarefa (ou o forçado por --as-role); None se o campo não é texto — nunca deixa um valor estranho derrubar a rodada."""
    r = t.get("role") if isinstance(t, dict) else None
    return a.as_role or (r if isinstance(r, str) else None)

def rec_of(c, t, role, estado, motivo, ok=None, tokens=None, **extra):
    r = {"task": t.get("task_id") if isinstance(t, dict) else None, "papel": role, "config_sha": c.config_sha.get(role),
         "estado": estado, "ok": ok, "tokens": tokens, "motivo": motivo}
    r.update(extra)
    return r

def git_fail(c, t, role, rc, motivo):
    """git que não deu 0: NOT_STARTED/None (nem iniciou, estourou o prazo) = não sei, é infra; rc ≠ 0 = o git RESPONDEU erro (sha que não existe...):
    fato da tarefa, descartada com o motivo."""
    infra = {NOT_STARTED: "git_nao_iniciou", None: "git_estourou_prazo"}.get(rc)
    return rec_of(c, t, role, "infra", infra) if infra else rec_of(c, t, role, "descartada", motivo)

def run_task(c, t, role):
    why = validate(t)
    if why:
        return rec_of(c, t, role, "descartada", why)
    pre = c.prefix
    tests = t["test_files"]
    tfiles = tree_files(c.repo, t["fix_sha"], [os.path.join(pre, p) for p in tests])
    if tfiles is None:  # o ls-tree falhou: não sei se o selftest existe (≠ lista curta, que é 'não existe')
        return rec_of(c, t, role, "infra", "git_lstree_falhou")
    if len(tfiles) != len(tests):
        return rec_of(c, t, role, "descartada", "selftest_ausente_no_fix")
    wt = tempfile.mkdtemp(prefix="wt-", dir=c.scratch)
    cwd = os.path.join(wt, pre) if pre else wt
    try:
        rc, _ = git(c.repo, "worktree", "add", "--detach", "--force", wt, t["fix_sha"])
        if rc != 0:
            return git_fail(c, t, role, rc, "checkout_fix_falhou")
        st = run_tests(cwd, tests, c.selftest_timeout)
        if st != "pass":
            return rec_of(c, t, role, "descartada", "selftest_nao_rodou_no_fix" if st == "indeterminado" else "selftest_reprova_no_fix")
        rc, _ = git(wt, "checkout", "-q", "-f", "--detach", t["base_sha"])
        if rc == 0:
            rc, _ = git(wt, "clean", "-fdxq")
        if rc != 0:
            return git_fail(c, t, role, rc, "checkout_base_falhou")
        if not put_files(c.repo, wt, tfiles):
            return rec_of(c, t, role, "infra", "overlay_selftest_falhou")
        st = run_tests(cwd, tests, c.selftest_timeout)
        if st != "fail":
            return rec_of(c, t, role, "descartada", "selftest_nao_rodou_na_base" if st == "indeterminado" else "selftest_passa_na_base")
        if c.verify_only:
            return rec_of(c, t, role, "verificada", "reprova_na_base_passa_no_fix")
        # configuração sob teste por cima: apaga o que a base tinha nesses caminhos e escreve o do --config-ref
        old = tree_files(c.repo, t["base_sha"], c.cfg_paths)
        if old is None:
            return rec_of(c, t, role, "infra", "overlay_config_falhou")
        for name, _, _ in old:
            with contextlib.suppress(OSError):
                os.unlink(os.path.join(wt, name))
        if not put_files(c.repo, wt, c.cfg_entries):
            return rec_of(c, t, role, "infra", "overlay_config_falhou")
        argv = shlex.split(c.claude) + ["-p", "--model", c.model, "--output-format", "json", "--no-session-persistence",
                                        "--permission-mode", "acceptEdits", "--setting-sources", "project", "--allowedTools", agent_allowed(tests),
                                        "--disallowedTools", "WebFetch,WebSearch", "--max-budget-usd", str(c.task_budget_usd),
                                        "--append-system-prompt-file", c.role_file[role]] + shlex.split(c.claude_extra)
        c.agent_ran, t0 = True, time.monotonic()
        rc, out, _ = run_capped(argv, cwd, agent_env(c.agent_home, c.real_home), c.agent_timeout, build_prompt(t))
        dur = round(time.monotonic() - t0, 1)
        if rc == NOT_STARTED:  # nada rodou, nada foi gasto: infra, sem reserva (e conta para --infra-stop)
            c.agent_ran = False
            return rec_of(c, t, role, "infra", "agente_nao_iniciou", duracao_s=dur)
        if rc is None:  # estourou o prazo. Tokens desconhecidos → cobra a reserva.
            return rec_of(c, t, role, "medida", "agente_timeout", ok=False, tokens=None, tokens_cobrados=c.reserve, duracao_s=dur)
        d = parse_claude(out)
        if d is None:
            return rec_of(c, t, role, "infra", "saida_do_agente_ilegivel", tokens_cobrados=c.reserve, duracao_s=dur)
        spent, cache_read = tokens_of(d)
        cobrado = spent if spent is not None else c.reserve
        sub = str(d.get("subtype", ""))
        if d.get("is_error") is not False and not sub.startswith("error_max"):
            return rec_of(c, t, role, "infra", "agente_erro:" + (sub or "?"), tokens=spent, tokens_cobrados=cobrado, duracao_s=dur)
        if not put_files(c.repo, wt, tfiles):
            return rec_of(c, t, role, "infra", "restaurar_selftest_falhou", tokens=spent, tokens_cobrados=cobrado, duracao_s=dur)
        st = run_tests(cwd, tests, c.selftest_timeout, after_agent=True)
        if st == "indeterminado":
            return rec_of(c, t, role, "infra", "selftest_nao_rodou_apos_agente", tokens=spent, tokens_cobrados=cobrado, duracao_s=dur)
        ok = st == "pass"
        return rec_of(c, t, role, "medida", "" if ok else (sub if sub.startswith("error_max") else "selftest_reprova_apos_agente"),
                      ok=ok, tokens=spent, tokens_cobrados=cobrado, cache_read=cache_read, custo_usd=d.get("total_cost_usd"), duracao_s=dur)
    finally:
        git(c.repo, "worktree", "remove", "--force", wt)
        shutil.rmtree(wt, ignore_errors=True)

def load_tasks(path):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        die(2, "não consegui ler o acervo %s: %s" % (path, e))
    sha = hashlib.sha256(raw).hexdigest()
    # .meta.json: ausente → segue, o resumo diz meta=ausente; ilegível ou sha que não bate → não sei se o acervo está inteiro: rc 2, nada roda.
    try:
        with open(path + ".meta.json") as f:
            want = json.load(f).get("sha256")
        if want != sha:
            die(2, "o sha256 do acervo não bate com o .meta.json: acervo alterado ou gravado pela metade")
        meta = "confere"
    except FileNotFoundError:
        meta = "ausente"
    except (OSError, ValueError, AttributeError):
        die(2, "o .meta.json do acervo está ilegível")
    # linha vazia → ignora; linha que não é JSON → conta em linhas_ilegiveis e segue (uma podre não derruba as outras).
    tasks, bad = [], 0
    for line in raw.decode("utf-8", "replace").split("\n"):  # NÃO splitlines: ele também quebra em U+2028/2029/0085, que o produtor grava crus
        if not line.strip():
            continue
        try:
            tasks.append(json.loads(line))
        except ValueError:
            bad += 1
    return tasks, bad, sha, meta

def main():
    city = os.environ.get("GC_CITY_PATH", "")
    ap = argparse.ArgumentParser()
    ap.add_argument("--state-dir", default=os.path.join(city, ".gc/agent-battery") if city else "")
    ap.add_argument("--tasks", default="")
    ap.add_argument("--repo", default=os.path.dirname(city) if city else ".")
    ap.add_argument("--prefix", default=os.path.basename(city) if city else ".gascity-gastown-hq")
    ap.add_argument("--config-ref", default="origin/main")
    ap.add_argument("--as-role", default="")
    ap.add_argument("--agent-real-home", action="store_true", help="sem credencial em env: usa o login guardado no HOME real (o agente enxerga o HOME)")
    ap.add_argument("--role-prompt", action="append", default=[])
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--token-cap", type=int, default=2000000)
    ap.add_argument("--task-reserve-tokens", type=int, default=400000)
    ap.add_argument("--task-budget-usd", type=float, default=1.5)
    ap.add_argument("--agent-timeout", type=int, default=900)
    ap.add_argument("--selftest-timeout", type=int, default=600)
    ap.add_argument("--infra-stop", type=int, default=3)
    ap.add_argument("--claude", default="claude")
    ap.add_argument("--claude-extra", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--day", default="")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--verify-only", action="store_true")
    a = ap.parse_args()
    if not a.state_dir:
        die(2, "sem --state-dir e sem GC_CITY_PATH")
    if a.token_cap < 1 or a.task_reserve_tokens < 1 or a.task_budget_usd <= 0 or a.agent_timeout < 1 or a.selftest_timeout < 1 \
            or a.limit < 0 or a.infra_stop < 1:
        die(2, "teto, reserva, orçamento, prazos, --limit e --infra-stop precisam ser positivos")
    if a.as_role and a.as_role not in ROLE_PROMPTS:
        die(2, "--as-role %s desconhecido (%s)" % (a.as_role, ",".join(sorted(ROLE_PROMPTS))))
    rp = dict(ROLE_PROMPTS)
    for spec in a.role_prompt:
        k, _, v = spec.partition("=")
        if not ROLE_RE.match(k) or not good_path(v, PATH_RE, ("agents/", "packs/", "scripts/")):
            die(2, "--role-prompt inválido: " + spec)
        rp[k] = v
    day = a.day or time.strftime("%Y-%m-%d", time.gmtime())
    if not re.match(r"^\d{4}-\d{2}-\d{2}\Z", day):
        die(2, "--day inválido")

    c = Ctx()
    c.repo, c.prefix, c.claude, c.claude_extra, c.model = a.repo, a.prefix.strip("/"), a.claude, a.claude_extra, a.model
    c.task_budget_usd, c.agent_timeout, c.selftest_timeout, c.reserve = a.task_budget_usd, a.agent_timeout, a.selftest_timeout, a.task_reserve_tokens
    c.verify_only = a.verify_only
    rc, top = git(c.repo, "rev-parse", "--show-prefix")
    if rc != 0 or top.strip():
        die(2, "--repo precisa ser a RAIZ de um repositório git (%s)" % c.repo)
    rc, ref_sha = git(c.repo, "rev-parse", "--verify", a.config_ref + "^{commit}")
    if rc != 0 or not SHA_RE.match(ref_sha.strip()):
        die(2, "--config-ref %s não resolve" % a.config_ref)
    ref_sha = ref_sha.strip()

    tasks_path = a.tasks or os.path.join(a.state_dir, "tasks.jsonl")
    tasks, bad_lines, tasks_sha, meta = load_tasks(tasks_path)
    if a.only:
        tasks = [t for t in tasks if isinstance(t, dict) and t.get("task_id") in a.only]
    if a.limit:
        tasks = tasks[:a.limit]
    if not tasks:
        die(3, "nenhuma tarefa utilizável em %s" % tasks_path)

    # configuração sob teste: arquivos comuns + o prompt de cada papel que vai rodar
    c.cfg_paths = list(CONFIG_PATHS) + ([c.prefix + "/CLAUDE.md"] if c.prefix else [])
    c.cfg_entries = tree_files(c.repo, ref_sha, c.cfg_paths)
    if c.cfg_entries is None:
        die(2, "git ls-tree falhou em %s" % a.config_ref)
    common = hashlib.sha256("".join("%s\0%s\n" % (n, s) for n, s, _ in c.cfg_entries).encode()).hexdigest()
    roles = {role_of(a, t) for t in tasks}
    c.config_sha, role_blob = {}, {}
    for r in roles:
        pf = tree_files(c.repo, ref_sha, [os.path.join(c.prefix, rp[r])]) if r in rp else []
        if pf is None:
            die(2, "git ls-tree falhou no prompt do papel %s" % r)
        if len(pf) == 1:
            role_blob[r] = pf[0]
            c.config_sha[r] = hashlib.sha256((common + pf[0][0] + pf[0][1]).encode()).hexdigest()

    ledger = os.path.join(a.state_dir, "spend-%s.json" % day)
    spent_before = read_ledger(ledger)
    if spent_before is None:
        die(5, "ledger de gasto ilegível (%s): não sei quanto já gastei; nada roda" % ledger)
    plan = {"tarefas": len(tasks), "linhas_ilegiveis": bad_lines, "meta": meta, "config_ref_sha": ref_sha, "papeis_sem_prompt":
            sorted(str(r) for r in roles if r not in role_blob), "tokens_noite_antes": spent_before, "teto_noite": a.token_cap}
    if a.dry_run:
        plan["config_sha"] = c.config_sha
        print(json.dumps(plan, ensure_ascii=False))
        return 0
    if not a.verify_only and shutil.which(shlex.split(a.claude)[0]) is None:
        die(8, "claude ausente (%s): nada roda" % a.claude)
    c.real_home = a.agent_real_home
    if not a.verify_only and not c.real_home and not any(os.environ.get(k) for k in KEEP_SECRET):
        die(8, "sem CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_API_KEY no ambiente: nada roda (ou --agent-real-home, que expõe o HOME ao agente)")

    os.makedirs(a.state_dir, exist_ok=True)
    lock = open(os.path.join(a.state_dir, "run.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        die(7, "outra rodada em andamento; nada feito")
    # relido COM o lock (outra rodada pode ter gravado desde a 1ª leitura, e esta sobrescreveria o gasto dela): sem arquivo → 0; ilegível → rc 5, nada roda.
    spent_before = read_ledger(ledger)
    if spent_before is None:
        die(5, "ledger de gasto ilegível (%s): não sei quanto já gastei; nada roda" % ledger)
    plan["tokens_noite_antes"] = spent_before
    out = a.out or os.path.join(a.state_dir, "runs", "run-%s.jsonl" % time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    c.scratch = tempfile.mkdtemp(prefix="battery-", dir=os.environ.get("TMPDIR") or None)
    c.agent_home = os.path.join(c.scratch, "home")
    try:
        os.makedirs(c.agent_home)
    except OSError as e:
        shutil.rmtree(c.scratch, ignore_errors=True)
        die(4, "não consegui criar o HOME descartável do agente: %s" % e)
    c.role_file = {}
    for r, (name, sha, _) in role_blob.items():
        data = blob(c.repo, sha)
        if data is None:
            die(2, "não consegui ler o prompt do papel %s" % r)
        c.role_file[r] = os.path.join(c.scratch, "role-%s.md" % r)
        with open(c.role_file[r], "wb") as f:
            f.write(data)

    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    spent, infra_run, brake, code, results = spent_before, 0, None, 0, []
    try:
        with open(out + ".partial", "w") as pf:
            for t in tasks:
                role = role_of(a, t)
                if brake:
                    r = rec_of(c, t, role, "pulada", brake)
                elif not a.verify_only and role not in role_blob and isinstance(t, dict) and validate(t) is None:
                    r = rec_of(c, t, role, "pulada", "papel_sem_prompt")
                elif not a.verify_only and spent + c.reserve > a.token_cap:
                    brake, code = "teto_de_tokens", 6
                    r = rec_of(c, t, role, "pulada", brake)
                else:
                    c.agent_ran = False
                    try:
                        r = run_task(c, t, role)
                    except OSError as e:  # disco cheio/unlink/mkdtemp: a tarefa vira infra, a rodada segue; cobra a reserva se o agente já tinha rodado
                        r = rec_of(c, t, role, "infra", "erro_de_io:" + type(e).__name__, tokens_cobrados=c.reserve if c.agent_ran else 0)
                    paid = r.get("tokens_cobrados", r.get("tokens")) or 0
                    spent += paid
                    if paid:
                        try:
                            atomic_write(ledger, json.dumps({"date": day, "tokens": spent}) + "\n")
                        except OSError:
                            brake, code = "ledger_sem_gravar", 4
                    if r["estado"] == "infra":  # só uma MEDIDA zera a sequência: descartada/pulada não provam que o agente voltou a funcionar
                        infra_run += 1
                    elif r["estado"] == "medida":
                        infra_run = 0
                    if infra_run >= a.infra_stop and not brake:
                        brake, code = "infra_repetida", 8
                results.append(r)
                pf.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
                pf.flush()
        os.replace(out + ".partial", out)
    except OSError as e:
        die(4, "não consegui gravar %s: %s" % (out, e))
    finally:
        shutil.rmtree(c.scratch, ignore_errors=True)

    por_estado, descartes, por_papel = {}, {}, {}
    for r in results:
        por_estado[r["estado"]] = por_estado.get(r["estado"], 0) + 1
        if r["estado"] in ("descartada", "pulada", "infra"):
            descartes[r["motivo"]] = descartes.get(r["motivo"], 0) + 1
        if r["estado"] == "medida":
            p = por_papel.setdefault(r["papel"], {"medidas": 0, "ok": 0})
            p["medidas"] += 1
            p["ok"] += 1 if r["ok"] else 0
    for p in por_papel.values():
        p["taxa"] = round(p["ok"] / p["medidas"], 4)
    summary = dict(plan, iniciada_em=started, terminada_em=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), tasks_sha256=tasks_sha,
                   config_sha=c.config_sha, por_estado=por_estado, por_papel=por_papel, descartes=descartes, freio=brake, out=out,
                   tokens_noite_depois=spent, teto_excedido=spent > a.token_cap, verify_only=a.verify_only)
    try:
        atomic_write(out + ".summary.json", json.dumps(summary, ensure_ascii=False, indent=1) + "\n")
    except OSError as e:
        die(4, "não consegui gravar o resumo: %s" % e)
    print(json.dumps(summary, ensure_ascii=False))
    return code

if __name__ == "__main__":
    sys.exit(main())
