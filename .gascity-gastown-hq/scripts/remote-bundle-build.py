#!/usr/bin/env python3
"""remote-bundle-build.py — monta o BUNDLE de settings/hooks (e, opcionalmente, skills) que uma sessão
Claude no servidor Hetzner carrega no lugar do que o mini tem em ~/.claude, <city>/.gc/settings.json e
<workdir do papel>/.claude (ga-2hd02v.1, desenho do ga-ukxa3k).

Contents
  Uso · O que entra · Por que falha em vez de copiar · Saída · Códigos de saída

USO
  remote-bundle-build.py build --city C --claude-home ~/.claude --role dog --role-dir C/.gc/agents/dogs/gastown.dog-1 \
      --remote-root /home/runner/gt-remote/bundle --remote-home /home/runner --out OUT [--skills [--exclude-skill NOME]...]
      (--skills deixa de fora, POR NOME, as de SKILLS_NOT_ON_SERVER (3, CPF/CNPJ) e SKILLS_MINI_ONLY (3, caminho do mini); --exclude-skill acrescenta nomes; o manifest lista `excluded_skills` e,
       para nome que não existe em skills/, `excluded_skills_missing` + aviso no stderr — a guarda de CPF/CNPJ continua valendo para as demais)
  remote-bundle-build.py verify OUT         # re-hasheia os arquivos e confere com o manifest (inclui o bit de execução, lido do modo, e o
                                          bundle_hash; pasta ou arquivo ilegível, symlink no lugar de arquivo e arquivo a mais são diferença, não "limpo")

O QUE ENTRA (cada hook tem UM veredito, na tabela POLICY):
  keep  — o script é portável (bash/jq/python3, sem nada de macOS) e é copiado para home/.claude/hooks/;
  shim  — o comando só chama `gc` (handoff, prime, nudge drain, mail check) e fica como está: no servidor `gc` é o
          atalho ssh→mini (fatia seguinte). É comparado INTEIRO, sem strip nem normalização (SHIM_RE.fullmatch): o PATH é o
          literal que o gc injeta, variável só GC_*, argumentos sem caractere de controle nem ; & | ` $ ( ) < >, e o
          subcomando executado é o do token que decidiu. O manifest lista o que o atalho precisa aceitar (shim_needs): o
          subcomando e os argumentos, exatamente como são enviados;
  drop  — não se aplica no servidor (TCC do macOS, FUSE, ntfy com tópico privado, experimento de log local...). Só some o hook que a
          POLICY classificou: o trecho do comando escolhe a linha, mas o comando INTEIRO tem que ter a forma dele — script em
          ~/.claude/hooks/<nome do token>, `gt tap guard cross-clone-block` (gt com ~/.local/bin/ opcional) ou o PREFIXO do wrapper
          `: <marcador>; P='<cidade>/scripts/<marcador>.sh'; [ -f "$P" ] || ` (a cauda do wrapper é gerada e não é lida: o manifest guarda o
          sha256 do comando inteiro). Guarda irmã (`gt tap guard dangerous-command`) ou comando com algo a mais NÃO é descartado: recusa.
  Chaves de settings fora da lista de portáveis (modelo, statusLine, plugins...) são descartadas e registradas.
  Só é lido o que está nomeado aqui: settings.local.json NUNCA entra (guarda permissões e segredos de sessões).

POR QUE FALHA EM VEZ DE COPIAR (três estados: sei que serve / sei que não serve / não sei — o último não vira "serve"):
  hook que não está na tabela (ou que só CONTÉM o token de uma linha, ou casa com mais de uma: vale para keep, shim e drop), grupo de hooks sem a lista `hooks`, comando de shim que ganhou mais coisa (newline, PATH
  diferente, variável que não é GC_*...), script `keep` com construção de macOS ou com
  caminho do mini, segredo, CPF/CNPJ/telefone, arquivo de dado (*.duckdb/*.db/*.csv/*.parquet/*.gz...), binário,
  symlink de skill que sai da cidade, pasta ilegível dentro de uma skill, `--skills` com a pasta vazia, ou qualquer `/Users/` sobrando no que seria enviado
  → exit 3 e NADA é escrito.

SAÍDA (OUT/): home/.claude/{settings.json,hooks/*} → {remote_home}/.claude/ · city/settings.json → arquivo de --settings ·
  role/<papel>/.claude/{settings.json,skills/*} → .claude/ do diretório de trabalho da sessão · manifest.json (veredito
  por hook com `command` (a parte reconhecida) e `command_sha256` (do comando inteiro, drop inclusive), shim_needs, chaves descartadas, contagem de regras de permissão descartadas, sha256 de cada arquivo, bundle_hash — sem data/hora: mesma entrada, mesmo hash).

OUT: só é substituído se não existe, está vazio ou é um bundle que este builder gravou (manifest.json com version 1 e
  bundle_hash, e nada além do que o manifest lista); nunca se for (ou contiver) --city/--claude-home/--role-dir/--mini-home.
  Qualquer outra coisa em OUT, ou (com OUT existente) um OUT.old de troca anterior, → exit 3 e nada é apagado. OUT é resolvido (realpath) antes.

CÓDIGOS: 0 ok · 2 uso · 3 recusado (política/guarda/entrada ilegível/OUT que não é bundle deste builder ou não gravável) ·
  4 verify encontrou diferença ou não conseguiu ler o manifest, uma pasta ou um arquivo de OUT.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

REFUSED, MISMATCH = 3, 4


class Refused(Exception):
    pass


# (trecho do comando, veredito, motivo). O trecho só ESCOLHE a linha; quem decide é a forma: o comando INTEIRO tem que ser o hook que a
# linha classificou (keep, shim e drop), e comando que casa com nenhuma linha, ou com mais de uma, → Refused. Por isso o token de um drop
# nomeia o hook, não a família (`gt tap guard cross-clone-block`, não `gt tap guard`): uma guarda irmã cai em "sem veredito" em vez de sumir.
# O wrapper é a exceção declarada (WRAPPERS): o token é o marcador e o que se confere é o prefixo.
POLICY = [
    ("gc handoff", "shim", "ciclo de contexto: o gc de verdade roda no mini"),
    ("gc prime", "shim", "monta o prompt da sessão a partir do estado da cidade (mini)"),
    ("gc nudge drain", "shim", "entrega nudges pendentes à sessão"),
    ("gc mail check", "shim", "entrega mail pendente à sessão"),
    ("home-scan-guard", "drop", "guarda do TCC do macOS; no Linux não há TCC"),
    ("cut-output-shadow", "drop", "experimento em sombra; o log é local do mini e ninguém o agregaria"),
    ("fuse-avoidance.sh", "drop", "CloudStorage/Mobile Documents não existem no servidor"),
    ("ntfy-prompt-submit.sh", "drop", "tópico ntfy privado + CLI notify; o servidor não guarda segredo"),
    ("ntfy-on-stop.sh", "drop", "idem ntfy-prompt-submit.sh"),
    ("gt tap guard cross-clone-block", "drop", "usa o binário gt e o layout de clones do mini; GAP: reescrever p/ clones do servidor"),
    ("enforce-multiple-choice-question.sh", "keep", "regra 1 do Athos vale em qualquer host (jq, falha aberta)"),
    ("enforce-mail-mcq-on-send.sh", "keep", "idem, no canal gc mail send (jq+python3, falha aberta)"),
    ("filter-bash-output.sh", "keep", "poupa tokens da cota compartilhada (jq)"),
    ("filter-test-output.sh", "keep", "idem"),
    ("filter-scraper-output.sh", "keep", "idem"),
    ("log-token-usage.sh", "keep", "grava só em ~/.claude/usage-analytics.jsonl do servidor"),
]
# drop em forma de wrapper: `: <marcador>; P='<cidade>/scripts/<marcador>.sh'; [ -f "$P" ] || <cauda gerada>` (home-scan-guard-activate.sh, overlays).
# O prefixo é conferido; a cauda é gerada e não é lida: o manifest guarda o sha256 do comando inteiro para ela ser auditável.
WRAPPERS = {"home-scan-guard", "cut-output-shadow"}
# O shim é comparado INTEIRO (fullmatch, sem strip nem normalização): o que o builder decide é a string que vai para o servidor.
# O PATH é o literal que o gc injeta, não "qualquer coisa entre aspas"; variável só GC_*; nada de caractere de controle (newline = 2º comando).
GC_PATH = 'export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH" && '
SHIM_RE = re.compile("(?:" + re.escape(GC_PATH) + r")?(?:GC_[A-Z_]+=[\w-]+ )*gc (handoff|prime|nudge drain|mail check)"
                     r"((?: [^\x00-\x1f\x7f;&|`$()<>]*)?)")

USER_KEYS = {"$schema", "cleanupPeriodDays", "env", "permissions", "hooks", "skipDangerousModePermissionPrompt",
             "skipAutoPermissionPrompt"}
CITY_KEYS = {"awaySummaryEnabled", "editorMode", "env", "hooks", "permissions", "remoteControlAtStartup",
             "skipDangerousModePermissionPrompt"}
ROLE_KEYS = {"autoMemoryEnabled", "claudeMdExcludes", "env", "hooks", "permissions", "remoteControlAtStartup",
             "skillOverrides", "autoCompactWindow", "deniedMcpServers", "disabledMcpjsonServers"}
KEYS = {"user": USER_KEYS, "city": CITY_KEYS, "role": ROLE_KEYS}

MAC_ONLY = re.compile(
    r"\b(osascript|launchctl|pbcopy|pbpaste|sysctl|mdfind|diskutil|caffeinate|taskpolicy|plutil|ioreg|pmset|vm_stat|"
    r"memory_pressure|sw_vers)\b|stat -f|date -[jv]\b|sed -i ?''|mktemp -t\b|base64 -D|/Library/|/Volumes/|/private/|/Users/")
RULE_MAC = re.compile(r"launchctl|osascript|/Users/|/Library/|/private/")
SECRETS = [
    ("chave de API", re.compile(r"sk-[A-Za-z0-9_-]{20,}")),
    ("token do GitHub", re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}")),
    ("token do Slack", re.compile(r"xox[abprs]-[A-Za-z0-9-]{10,}")),
    ("chave AWS", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("chave privada", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("tópico ntfy", re.compile(r"ntfy\.sh/[A-Za-z0-9_-]{6,}")),
    ("CPF", re.compile(r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b")),
    ("CNPJ", re.compile(r"\b\d{2}\.\d{3}\.\d{3}/\d{4}-\d{2}\b")),
    ("telefone BR", re.compile(r"(?<![0-9A-Za-z])(?:(?:\+?55[\s-]?)?\(?[1-9][1-9]\)?[\s-]?(?:9\d{4}|[2-5]\d{3})[\s-]\d{4}"
                               r"|(?:\+?55)?[1-9][1-9]9\d{8})(?![0-9A-Za-z])")),
]
# Skills que NÃO vão ao servidor, por NOME (ga-2hd02v.1.5.2; decisão do Mayor, Q3): trazem valores em formato de CPF/CNPJ (consulta a cartório,
# prefeitura e TST) e o servidor não guarda dado de pessoa. A guarda de CPF/CNPJ de SECRETS NÃO é afrouxada por isso: uma 4ª skill com o mesmo formato recusa.
SKILLS_NOT_ON_SERVER = ("censec-inventario-extrajudicial", "cnd-municipal-pbh", "cnd-trabalhista-cndt")
# MEDIDO em 17/10 com as 18 skills do dog (o builder para na 1ª recusa, então a bead só conhecia as 3 de cima): outras 3 recusam, cada uma por UMA linha com caminho do mini
# (/Users/athos/gt/...: o daemon de anúncios do WA, o publicar_mockup.py, uma cópia da browser-control). São skills do WA que só funcionam com o mini; a guarda de /Users/ NÃO é afrouxada.
# Voltam ao servidor tirando o nome daqui quando a skill deixar de citar o mini (o aviso de nome inexistente denuncia lista velha).
SKILLS_MINI_ONLY = ("corrigir-imovel-do-anuncio", "rea-scraper-first", "wa-worker-session-protocol")
SKILL_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")  # nome exato de pasta em skills/: sem barra, sem glob
DATA_SUFFIX = {".db", ".duckdb", ".sqlite", ".sqlite3", ".csv", ".parquet", ".gz", ".zip", ".tar", ".xlsx", ".pem", ".key"}
DATA_NAMES = {"settings.local.json", ".credentials.json", ".env"}
MAX_FILE = 512 * 1024


def listing_hash(items: dict[str, tuple[str, bool]]) -> str:  # items: caminho → (sha256 do conteúdo, bit de execução)
    return hashlib.sha256("".join(f"{int(ex)} {sha} {rel}\n" for rel, (sha, ex) in sorted(items.items())).encode()).hexdigest()


class Bundle:
    def __init__(self, a: argparse.Namespace):
        self.a = a
        self.city = Path(a.city).resolve()
        self.home = str(Path(a.mini_home).resolve())
        self.rules = [(str(self.city), a.remote_root + "/city"), (str(self.city.parent), a.remote_root + "/work"),
                      (self.home, a.remote_home)]
        self.files: dict[str, tuple[bytes, bool]] = {}
        self.hooks: list[dict] = []
        self.shim_needs: set[str] = set()
        self.dropped_keys: dict[str, list[str]] = {}
        self.dropped_rules: dict[str, int] = {}
        self.skill_count = 0
        self.excluded: list[str] = []          # skills que existiam em skills/ e ficaram de fora, por nome
        self.excluded_missing: list[str] = []  # nomes de exclusão que NÃO existem em skills/ (renomeada? removida?)

    def rewrite(self, s: str) -> str:
        for old, new in self.rules:  # fronteira nos dois lados: gt-backup, gt2 e /xx/Users/... não são o caminho; sobram e a guarda de /Users/ recusa
            s = re.sub(r"(?<![\w.-])" + re.escape(old) + r"(?![\w.-])", lambda _m, new=new: new, s)
        return s

    def add(self, rel: str, data: bytes, ex: bool = False) -> None:
        name = Path(rel).name
        if name in DATA_NAMES or name.startswith(".env") or Path(rel).suffix.lower() in DATA_SUFFIX:
            raise Refused(f"{rel}: arquivo de dado/segredo não entra no bundle")
        if len(data) > MAX_FILE:
            raise Refused(f"{rel}: {len(data)} bytes passa do teto de {MAX_FILE}")
        if b"\0" in data:
            raise Refused(f"{rel}: binário não entra (só texto)")
        text = data.decode("utf-8", "replace")
        for what, rx in SECRETS:
            if rx.search(text):
                raise Refused(f"{rel}: parece conter {what}")
        if "/Users/" in text:
            raise Refused(f"{rel}: caminho do mini (/Users/...) sobrando")
        self.files[rel] = (data, ex)

    def hook_verdict(self, src: str, event: str, matcher, cmd: str) -> str:
        # nenhuma linha casa → "sem veredito"; mais de uma → o comando junta hooks (o 1º token decidiria pelos outros): recusa nos dois
        hits = [row for row in POLICY if row[0] in cmd]
        if not hits:
            raise Refused(f"hook sem veredito em {src}/{event}: {cmd[:100]!r} — acrescente à POLICY (keep/shim/drop)")
        if len(hits) > 1:
            raise Refused(f"hook em {src}/{event} casa com {len(hits)} linhas da POLICY: o veredito veio de {hits[0][0]!r} mas o comando "
                          f"também traz {[h[0] for h in hits[1:]]}: {cmd[:100]!r}")
        token, verdict, why = hits[0]
        # a linha só ESCOLHEU o hook; o comando INTEIRO tem que ser ele, senão o que é decidido (a linha) não é o que o shell executa
        # (wrapper: só o prefixo é conferido, a cauda gerada não é lida — por isso o sha256 do comando inteiro vai para o manifest)
        if verdict == "shim":
            m = SHIM_RE.fullmatch(cmd)
            if not m:
                raise Refused(f"hook shim em {src}/{event} ganhou mais que um `gc ...`: {cmd[:100]!r}")
            if self.rewrite(cmd) != cmd:  # shim_needs tem que ser a string que VAI: reescrita de caminho não pode mexer nela
                raise Refused(f"hook shim em {src}/{event} tem caminho do mini: {cmd[:100]!r}")
            self.shim_needs.add(m.group(1) + m.group(2))
        elif token.endswith(".sh"):  # script em ~/.claude/hooks, keep ou drop
            m = re.fullmatch(r"(?:~|\$HOME|%s)/\.claude/hooks/([\w.-]+)" % re.escape(self.home), cmd)
            if not m:
                raise Refused(f"hook {verdict} em {src}/{event} não é só ~/.claude/hooks/<script>: {cmd[:100]!r}")
            if m.group(1) != token:  # o token casou por trecho do nome: script que ninguém classificou não vira keep nem é descartado
                raise Refused(f"hook {verdict} em {src}/{event}: {m.group(1)!r} só contém o token {token!r}, não é ele — classifique-o na POLICY")
            if verdict == "keep":
                self.keep_script(m.group(1))
        elif token in WRAPPERS:
            m = re.match(r": %s; P='%s/scripts/%s\.sh'; \[ -f \"\$P\" \] \|\| " % (token, re.escape(str(self.city)), token), cmd)
            if not m:
                raise Refused(f"hook {verdict} em {src}/{event} não é só o wrapper `: {token}; P='<cidade>/scripts/{token}.sh'; [ -f \"$P\" ] || ...`: "
                              f"{cmd[:100]!r}")
        elif token == "gt tap guard cross-clone-block":
            m = re.fullmatch(r"(?:(?:~|\$HOME|%s)/\.local/bin/)?%s" % (re.escape(self.home), re.escape(token)), cmd)
            if not m:
                raise Refused(f"hook {verdict} em {src}/{event} não é só `{token}` (com ~/.local/bin/ opcional): {cmd[:100]!r}")
        else:  # linha da POLICY sem forma de comando conhecida: não sei o que ela classifica
            raise Refused(f"POLICY: a linha {token!r} ({verdict}) não tem forma de comando conhecida em hook_verdict")
        # `command` é só a parte RECONHECIDA (o resto de um wrapper não é lido) e `command_sha256` é do comando inteiro: o que foi
        # descartado fica auditável sem o manifest carregar texto que nenhuma forma conferiu
        self.hooks.append({"source": src, "event": event, "matcher": matcher, "verdict": verdict, "token": token, "reason": why,
                           "command": self.rewrite(m.group(0)), "command_sha256": hashlib.sha256(cmd.encode()).hexdigest()})
        return verdict

    def keep_script(self, name: str) -> None:
        p = Path(self.a.claude_home) / "hooks" / name
        if not p.is_file():
            raise Refused(f"hook keep {name}: {p} não existe (ausente ≠ descartado)")
        code = "\n".join(l for l in p.read_text().splitlines() if not l.lstrip().startswith("#"))
        bad = MAC_ONLY.search(code)
        if bad:
            raise Refused(f"hook keep {name}: construção de macOS/caminho do mini no código: {bad.group(0)!r}")
        if re.search(r"^\s*(?:source|\.)\s", code, re.M):  # o script que ele carrega não está no bundle: não sei se é portável
            raise Refused(f"hook keep {name}: carrega outro arquivo (source/.), que o bundle não entrega")
        self.add(f"home/.claude/hooks/{name}", p.read_bytes(), ex=True)

    def settings(self, src: str, kind: str, path: Path) -> dict:
        data = json.loads(path.read_text())
        out: dict = {}
        for k, v in data.items():
            if k not in KEYS[kind]:
                self.dropped_keys.setdefault(src, []).append(k)
            elif k == "hooks":
                out[k] = self.filter_hooks(src, v)
            elif k == "permissions":
                out[k] = self.filter_permissions(src, v)
            else:
                out[k] = json.loads(self.rewrite(json.dumps(v)))
        if not out.get("hooks"):
            out.pop("hooks", None)
        return out

    def filter_hooks(self, src: str, hooks: dict) -> dict:
        out: dict = {}
        for event, groups in hooks.items():
            kept_groups = []
            for g in groups:
                if not isinstance(g, dict) or not isinstance(g.get("hooks"), list):
                    raise Refused(f"grupo de hooks em {src}/{event} sem a lista `hooks` (forma plana?): sem veredito possível")
                kept = [h for h in g["hooks"]
                        if h.get("type") != "command" or self.hook_verdict(src, event, g.get("matcher"), h.get("command", "")) != "drop"]
                if any(h.get("type") != "command" for h in g["hooks"]):
                    raise Refused(f"hook que não é `command` em {src}/{event}: sem veredito possível")
                if kept:
                    kept_groups.append({**g, "hooks": json.loads(self.rewrite(json.dumps(kept)))})
            if kept_groups:
                out[event] = kept_groups
        return out

    def filter_permissions(self, src: str, perms: dict) -> dict:
        out: dict = {}
        for k, v in perms.items():
            if k == "additionalDirectories":
                v = [self.rewrite(x) for x in v]
            elif isinstance(v, list):
                gone = [x for x in v if RULE_MAC.search(x)]
                if gone and k in ("deny", "ask"):  # tirar uma trava não é inerte; sem saber o que ela guardava, não envia
                    raise Refused(f"permissions.{k} em {src} tem {len(gone)} regra(s) de macOS: tirá-las enfraqueceria a trava")
                if gone:
                    self.dropped_rules[f"{src}.{k}"] = len(gone)
                v = [x for x in v if x not in gone]
            out[k] = v
        return out

    def skills(self, role: str, role_dir: Path) -> None:
        sdir = role_dir / ".claude" / "skills"
        if not sdir.is_dir():
            raise Refused(f"--skills pedido mas {sdir} não existe")
        self.skill_count = 0
        entries = sorted(sdir.iterdir())
        skip = set(SKILLS_NOT_ON_SERVER) | set(SKILLS_MINI_ONLY) | set(self.a.exclude_skill)
        self.excluded = []  # preenchido no próprio laço, onde se decide: o manifest lista o que FOI pulado, não o que uma 2ª conta acha que seria
        self.excluded_missing = sorted(skip - {e.name for e in entries})
        for name in self.excluded_missing:  # antes do laço: uma skill renomeada recusa pelo CPF logo abaixo, e o aviso do nome velho tem de aparecer junto
            print(f"remote-bundle-build: AVISO: skill excluída por nome não existe em {sdir}: {name} (renomeada? a de nome novo NÃO está excluída: "
                  f"se tiver valor em formato de CPF/CNPJ o build recusa)", file=sys.stderr)
        for link in entries:
            if link.name in skip:  # por NOME e antes de resolver: o que não vai ao servidor não é lido, nem barrado por conteúdo
                self.excluded.append(link.name)
                continue
            real = link.resolve()
            if not real.is_dir() or self.city not in real.parents:
                raise Refused(f"skill {link.name}: aponta para fora da cidade ou não é diretório ({real})")
            before = len(self.files)

            def unreadable(e: OSError, skill=link.name, real=real) -> None:  # os.walk engole o erro: pasta que não lista contribuiria com 0 arquivos e o build diria "ok"
                raise Refused(f"skill {skill}: pasta ilegível {os.path.relpath(e.filename or real, real)} ({e.strerror})")
            for root, dirs, names in os.walk(real, followlinks=False, onerror=unreadable):
                for d in dirs:  # walk lista link-para-diretório em `dirs` e não desce: pularia em silêncio
                    if (Path(root) / d).is_symlink():
                        raise Refused(f"skill {link.name}: symlink interno {(Path(root) / d).relative_to(real)}")
                for n in sorted(names):
                    f = Path(root) / n
                    if f.is_symlink():
                        raise Refused(f"skill {link.name}: symlink interno {f.relative_to(real)}")
                    self.add(f"role/{role}/.claude/skills/{link.name}/{f.relative_to(real)}", f.read_bytes(), f.stat().st_mode & 0o111 != 0)
            if len(self.files) == before:  # skill é a pasta com os arquivos; pasta vazia entregaria uma skill que não existe
                raise Refused(f"skill {link.name}: diretório sem nenhum arquivo")
            self.skill_count += 1
        if not self.skill_count:  # pedido ≠ entregue: "ok 3 arquivos" com --skills não pode esconder que nenhuma skill foi
            raise Refused(f"--skills pedido mas {sdir} não tem nenhuma skill: entregaria 0")

    def build(self) -> dict:
        a = self.a
        for src, kind, path, dest in (("user", "user", Path(a.claude_home) / "settings.json", "home/.claude/settings.json"),
                                      ("city", "city", self.city / ".gc" / "settings.json", "city/settings.json"),
                                      (f"role:{a.role}", "role", Path(a.role_dir) / ".claude" / "settings.json",
                                       f"role/{a.role}/.claude/settings.json")):
            out = self.settings(src, kind, path)
            self.add(dest, (json.dumps(out, indent=2, sort_keys=True) + "\n").encode())
        if a.skills:
            self.skills(a.role, Path(a.role_dir))
        return {"version": 1, "remote_root": a.remote_root, "remote_home": a.remote_home, "role": a.role,
                "install": {"home/.claude": a.remote_home + "/.claude", "city/settings.json": a.remote_root + "/city/settings.json",
                            f"role/{a.role}/.claude": "<diretório de trabalho da sessão>/.claude"},
                "hooks": self.hooks, "shim_needs": sorted(self.shim_needs),
                "dropped_keys": {k: sorted(set(v)) for k, v in sorted(self.dropped_keys.items())},
                "dropped_rules": dict(sorted(self.dropped_rules.items())),
                "excluded_skills": self.excluded, "excluded_skills_missing": self.excluded_missing,
                "files": {rel: {"sha256": hashlib.sha256(d).hexdigest(), "exec": ex} for rel, (d, ex) in sorted(self.files.items())},
                "bundle_hash": listing_hash({rel: (hashlib.sha256(d).hexdigest(), ex) for rel, (d, ex) in self.files.items()})}


def scan(d: Path) -> tuple[set[str], list[str]]:
    """Tudo que há sob d, menos manifest.json (link para pasta conta e não é descido), e as pastas que não listou."""
    seen: set[str] = set()
    bad: list[str] = []

    def unreadable(e: OSError) -> None:  # rglob engolia a pasta que não lista: o que há dentro não foi conferido, e isso não é "limpo"
        bad.append(f"pasta ilegível {os.path.relpath(e.filename or d, d)}: {e.strerror}")
    for root, dirs, names in os.walk(d, onerror=unreadable):
        seen |= {os.path.relpath(os.path.join(root, n), d) for n in names + [x for x in dirs if os.path.islink(os.path.join(root, x))]}
    seen.discard("manifest.json")
    return seen, bad


def check_out(out: Path, protect: list) -> None:
    """A troca apaga o que estava em OUT: só passa quando OUT não existe, está vazio ou é um bundle que este builder gravou."""
    for p in protect:
        real = Path(os.path.realpath(p))
        if out == real or out in real.parents:
            raise Refused(f"OUT {out} é (ou contém) a entrada {real}: não apago")
    if not os.path.lexists(out):
        return
    if not out.is_dir():
        raise Refused(f"OUT {out} existe e não é diretório: não apago")
    old = out.with_name(out.name + ".old")
    if os.path.lexists(old):
        raise Refused(f"{old} já existe (sobra de uma troca anterior?): remova-o ou escolha outro OUT; não apago")
    if not any(out.iterdir()):
        return
    seen, bad = scan(out)
    try:
        doc = json.loads((out / "manifest.json").read_text())
        ours = doc["version"] == 1 and isinstance(doc["bundle_hash"], str) and isinstance(doc["files"], dict)
    except (OSError, ValueError, KeyError, TypeError):
        ours = False
    if not ours or bad or not seen <= set(doc["files"]):
        raise Refused(f"OUT existe e não é um bundle deste builder (sem manifest.json válido, ou com arquivo/pasta que ele não grava): "
                      f"não apago {out}")


def write_atomic(b: Bundle, manifest: dict, out: Path, protect: list) -> None:
    check_out(out, protect)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=out.name + ".tmp.", dir=out.parent))
    try:
        tmp.chmod(0o755)
        for rel, (data, ex) in b.files.items():
            p = tmp / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            p.chmod(0o755 if ex else 0o644)
        (tmp / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        # pasta que o builder acabou de criar: mkdir segue o umask de quem roda (0700 com umask 077) e o modo de pasta não entra no bundle_hash;
        # fixo como o dos arquivos. Sem subpasta → nada a fazer; chmod que falha → OSError sobe e vira "não consegui gravar"
        for root, dirs, _ in os.walk(tmp):
            for d in dirs:
                os.chmod(os.path.join(root, d), 0o755)
        if out.exists():
            old = out.with_name(out.name + ".old")
            os.replace(out, old)
            try:
                os.replace(tmp, out)
            except OSError:
                os.replace(old, out)  # troca falhou no meio: o bundle anterior volta, não fica OUT vazio
                raise
            try:
                shutil.rmtree(old)
            except OSError as e:  # o bundle novo JÁ está em OUT: não vira "falha ao gravar", mas o resto fica dito
                print(f"remote-bundle-build: aviso: bundle novo gravado; não consegui apagar {old}: {e}", file=sys.stderr)
        else:
            os.replace(tmp, out)
    finally:
        if tmp.exists():
            shutil.rmtree(tmp)


def verify(d: Path) -> int:
    try:
        doc = json.loads((d / "manifest.json").read_text())
        want = {rel: (info["sha256"], info["exec"]) for rel, info in doc["files"].items()}
        declared = doc.get("bundle_hash")
        if not all(isinstance(sha, str) and isinstance(ex, bool) for sha, ex in want.values()):
            raise TypeError("files[*].sha256 não é texto ou files[*].exec não é booleano")
    except (OSError, ValueError, KeyError, AttributeError, TypeError) as e:  # sem manifest legível não há o que conferir: não é "limpo"
        print(f"remote-bundle-build verify: manifest.json ilegível em {d}: {e!r}", file=sys.stderr)
        return MISMATCH
    seen, bad = scan(d)
    for rel, (sha, ex) in want.items():
        p = d / rel
        try:
            # p.is_file() segue link: um symlink no lugar do arquivo, com o mesmo conteúdo, passaria. O bit é o do modo, não de os.access
            # (que olha o usuário e a montagem: noexec dava "mudou" em bundle intacto)
            if p.is_symlink():
                bad.append(f"symlink no lugar de {rel}")
            elif not p.is_file():
                bad.append(f"falta {rel}")
            elif hashlib.sha256(p.read_bytes()).hexdigest() != sha or (p.stat().st_mode & 0o111 != 0) != ex:
                bad.append(f"mudou {rel}")
        except OSError as e:  # arquivo que não abre: não sei se mudou, e "não sei" não é "limpo"
            bad.append(f"ilegível {rel}: {e.strerror}")
    bad += [f"sobra {r}" for r in sorted(seen - set(want))]
    if declared != listing_hash(want):  # arquivo e manifest.files editados juntos só se denunciam aqui; ausente também é diferente
        bad.append("bundle_hash do manifest ausente ou diferente do recalculado a partir de manifest.files")
    for line in bad:
        print("remote-bundle-build verify:", line, file=sys.stderr)
    return MISMATCH if bad else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="remote-bundle-build.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--city", required=True)
    b.add_argument("--claude-home", required=True)
    b.add_argument("--role", required=True)
    b.add_argument("--role-dir", required=True)
    b.add_argument("--remote-root", required=True)
    b.add_argument("--remote-home", required=True)
    b.add_argument("--mini-home", default=str(Path.home()))
    b.add_argument("--out", required=True)
    b.add_argument("--skills", action="store_true")
    b.add_argument("--exclude-skill", action="append", default=[], metavar="NOME")
    v = sub.add_parser("verify")
    v.add_argument("dir")
    a = ap.parse_args(argv)
    if a.cmd == "verify":
        return verify(Path(a.dir))
    if a.exclude_skill and not a.skills:  # flag que não faz nada em silêncio é pior que erro de uso
        ap.error("--exclude-skill só vale com --skills")
    for name in a.exclude_skill:
        if not SKILL_NAME.fullmatch(name):
            ap.error(f"--exclude-skill {name!r}: é o NOME exato de uma pasta em skills/ (sem barra nem glob)")
    try:
        bundle = Bundle(a)
        manifest = bundle.build()
    except Refused as e:
        print(f"remote-bundle-build: RECUSADO: {e}", file=sys.stderr)
        return REFUSED
    except (OSError, ValueError) as e:  # arquivo de entrada ausente/ilegível: não sei ≠ serve
        print(f"remote-bundle-build: RECUSADO: entrada ilegível: {e}", file=sys.stderr)
        return REFUSED
    except (AttributeError, TypeError, KeyError) as e:  # JSON válido com forma que o claude não usa (hooks como lista...)
        print(f"remote-bundle-build: RECUSADO: settings com formato inesperado: {e!r}", file=sys.stderr)
        return REFUSED
    out = Path(os.path.realpath(a.out))  # um só caminho para decidir e para agir: "." e symlink para a cidade aparecem como o que são
    try:
        write_atomic(bundle, manifest, out, [bundle.city, a.claude_home, a.role_dir, a.mini_home])
    except Refused as e:
        print(f"remote-bundle-build: RECUSADO: {e}", file=sys.stderr)
        return REFUSED
    except OSError as e:  # a entrada estava boa; o que falhou foi gravar — a mensagem não pode culpar a entrada
        print(f"remote-bundle-build: RECUSADO: não consegui gravar {out}: {e}", file=sys.stderr)
        return REFUSED
    skills_note = f", {bundle.skill_count} skills ({len(bundle.excluded)} excluídas por nome)" if a.skills else ""
    print(f"remote-bundle-build: ok {len(manifest['files'])} arquivos{skills_note}, "
          f"hash {manifest['bundle_hash'][:12]}, shim_needs={manifest['shim_needs']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
