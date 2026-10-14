#!/usr/bin/env python3
"""remote-bundle-build.py — monta o BUNDLE de settings/hooks (e, opcionalmente, skills) que uma sessão
Claude no servidor Hetzner carrega no lugar do que o mini tem em ~/.claude, <city>/.gc/settings.json e
<workdir do papel>/.claude (ga-2hd02v.1, desenho do ga-ukxa3k).

Contents
  Uso · O que entra · Por que falha em vez de copiar · Saída · Códigos de saída

USO
  remote-bundle-build.py build --city C --claude-home ~/.claude --role dog --role-dir C/.gc/agents/dogs/gastown.dog-1 \
      --remote-root /home/runner/gt-remote/bundle --remote-home /home/runner --out OUT [--skills]
  remote-bundle-build.py verify OUT          # re-hasheia os arquivos e confere com o manifest (inclui bit de execução e bundle_hash)

O QUE ENTRA (cada hook tem UM veredito, na tabela POLICY):
  keep  — o script é portável (bash/jq/python3, sem nada de macOS) e é copiado para home/.claude/hooks/;
  shim  — o comando só chama `gc` (handoff, prime, nudge drain, mail check) e fica como está: no servidor `gc` é o
          atalho ssh→mini (fatia seguinte). É comparado INTEIRO, sem strip nem normalização (SHIM_RE.fullmatch): o PATH é o
          literal que o gc injeta, variável só GC_*, argumentos sem caractere de controle nem ; & | ` $ ( ) < >, e o
          subcomando executado é o do token que decidiu. O manifest lista o que o atalho precisa aceitar (shim_needs): o
          subcomando e os argumentos, exatamente como são enviados;
  drop  — não se aplica no servidor (TCC do macOS, FUSE, ntfy com tópico privado, experimento de log local...).
  Chaves de settings fora da lista de portáveis (modelo, statusLine, plugins...) são descartadas e registradas.
  Só é lido o que está nomeado aqui: settings.local.json NUNCA entra (guarda permissões e segredos de sessões).

POR QUE FALHA EM VEZ DE COPIAR (três estados: sei que serve / sei que não serve / não sei — o último não vira "serve"):
  hook que não está na tabela, grupo de hooks sem a lista `hooks`, comando de shim que ganhou mais coisa (newline, PATH
  diferente, variável que não é GC_*...), script `keep` com construção de macOS ou com
  caminho do mini, segredo, CPF/CNPJ/telefone, arquivo de dado (*.duckdb/*.db/*.csv/*.parquet/*.gz...), binário,
  symlink de skill que sai da cidade, `--skills` com a pasta vazia, ou qualquer `/Users/` sobrando no que seria enviado
  → exit 3 e NADA é escrito.

SAÍDA (OUT/): home/.claude/{settings.json,hooks/*} → {remote_home}/.claude/ · city/settings.json → arquivo de --settings ·
  role/<papel>/.claude/{settings.json,skills/*} → .claude/ do diretório de trabalho da sessão · manifest.json (veredito
  por hook, shim_needs, chaves descartadas, contagem de regras de permissão descartadas, sha256 de cada arquivo, bundle_hash — sem data/hora: mesma entrada, mesmo hash).

CÓDIGOS: 0 ok · 2 uso · 3 recusado (política/guarda/entrada ilegível/OUT não gravável) · 4 verify encontrou diferença
  ou não conseguiu ler o manifest.
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


# (trecho do comando, veredito, motivo). A primeira linha que casa decide; sem casar → Refused.
POLICY = [
    ("gc handoff", "shim", "ciclo de contexto: o gc de verdade roda no mini"),
    ("gc prime", "shim", "monta o prompt da sessão a partir do estado da cidade (mini)"),
    ("gc nudge drain", "shim", "entrega nudges pendentes à sessão"),
    ("gc mail check", "shim", "entrega mail pendente à sessão"),
    ("home-scan-guard", "drop", "guarda do TCC do macOS; no Linux não há TCC"),
    ("cut-output-shadow", "drop", "experimento em sombra; o log é local do mini e ninguém o agregaria"),
    ("fuse-avoidance", "drop", "CloudStorage/Mobile Documents não existem no servidor"),
    ("ntfy-prompt-submit", "drop", "tópico ntfy privado + CLI notify; o servidor não guarda segredo"),
    ("ntfy-on-stop", "drop", "idem ntfy-prompt-submit"),
    ("gt tap guard", "drop", "usa o binário gt e o layout de clones do mini; GAP: reescrever p/ clones do servidor"),
    ("enforce-multiple-choice-question.sh", "keep", "regra 1 do Athos vale em qualquer host (jq, falha aberta)"),
    ("enforce-mail-mcq-on-send.sh", "keep", "idem, no canal gc mail send (jq+python3, falha aberta)"),
    ("filter-bash-output.sh", "keep", "poupa tokens da cota compartilhada (jq)"),
    ("filter-test-output.sh", "keep", "idem"),
    ("filter-scraper-output.sh", "keep", "idem"),
    ("log-token-usage.sh", "keep", "grava só em ~/.claude/usage-analytics.jsonl do servidor"),
]
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
        for token, verdict, why in POLICY:
            if token in cmd:
                break
        else:
            raise Refused(f"hook sem veredito em {src}/{event}: {cmd[:100]!r} — acrescente à POLICY (keep/shim/drop)")
        if verdict == "shim":
            m = SHIM_RE.fullmatch(cmd)
            if not m:
                raise Refused(f"hook shim em {src}/{event} ganhou mais que um `gc ...`: {cmd[:100]!r}")
            if f"gc {m.group(1)}" != token:  # o token decidiu "shim" por um trecho, mas o que executa é outro subcomando
                raise Refused(f"hook shim em {src}/{event}: o veredito veio de {token!r} mas o comando executa `gc {m.group(1)}`: {cmd[:100]!r}")
            if self.rewrite(cmd) != cmd:  # shim_needs tem que ser a string que VAI: reescrita de caminho não pode mexer nela
                raise Refused(f"hook shim em {src}/{event} tem caminho do mini: {cmd[:100]!r}")
            self.shim_needs.add(m.group(1) + m.group(2))
        elif verdict == "keep":
            m = re.fullmatch(r"(?:~|\$HOME|%s)/\.claude/hooks/([\w.-]+)" % re.escape(self.home), cmd)
            if not m:
                raise Refused(f"hook keep em {src}/{event} não é só ~/.claude/hooks/<script>: {cmd[:100]!r}")
            if m.group(1) != token:  # o token casou por trecho do nome: script que ninguém classificou não vira "keep"
                raise Refused(f"hook keep em {src}/{event}: {m.group(1)!r} só contém o token {token!r}, não é ele — classifique-o na POLICY")
            self.keep_script(m.group(1))
        self.hooks.append({"source": src, "event": event, "matcher": matcher, "verdict": verdict, "token": token,
                           "reason": why})
        return verdict

    def keep_script(self, name: str) -> None:
        p = Path(self.a.claude_home) / "hooks" / name
        if not p.is_file():
            raise Refused(f"hook keep {name}: {p} não existe (ausente ≠ descartado)")
        code = "\n".join(l for l in p.read_text().splitlines() if not l.lstrip().startswith("#"))
        bad = MAC_ONLY.search(code)
        if bad:
            raise Refused(f"hook keep {name}: construção de macOS/caminho do mini no código: {bad.group(0)!r}")
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
        for link in sorted(sdir.iterdir()):
            real = link.resolve()
            if not real.is_dir() or self.city not in real.parents:
                raise Refused(f"skill {link.name}: aponta para fora da cidade ou não é diretório ({real})")
            before = len(self.files)
            for root, dirs, names in os.walk(real, followlinks=False):
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
                "files": {rel: {"sha256": hashlib.sha256(d).hexdigest(), "exec": ex} for rel, (d, ex) in sorted(self.files.items())},
                "bundle_hash": listing_hash({rel: (hashlib.sha256(d).hexdigest(), ex) for rel, (d, ex) in self.files.items()})}


def write_atomic(b: Bundle, manifest: dict, out: Path) -> None:
    tmp = Path(tempfile.mkdtemp(prefix=out.name + ".tmp.", dir=out.parent))
    try:
        tmp.chmod(0o755)
        for rel, (data, ex) in b.files.items():
            p = tmp / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            p.chmod(0o755 if ex else 0o644)
        (tmp / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
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
    bad = []
    seen = {str(p.relative_to(d)) for p in d.rglob("*") if p.is_file()} - {"manifest.json"}
    for rel, (sha, ex) in want.items():
        p = d / rel
        if not p.is_file():
            bad.append(f"falta {rel}")
        elif hashlib.sha256(p.read_bytes()).hexdigest() != sha or os.access(p, os.X_OK) != ex:
            bad.append(f"mudou {rel}")
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
    v = sub.add_parser("verify")
    v.add_argument("dir")
    a = ap.parse_args(argv)
    if a.cmd == "verify":
        return verify(Path(a.dir))
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
    out = Path(a.out)
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(bundle, manifest, out)
    except OSError as e:  # a entrada estava boa; o que falhou foi gravar — a mensagem não pode culpar a entrada
        print(f"remote-bundle-build: RECUSADO: não consegui gravar {out}: {e}", file=sys.stderr)
        return REFUSED
    print(f"remote-bundle-build: ok {len(manifest['files'])} arquivos{f', {bundle.skill_count} skills' if a.skills else ''}, "
          f"hash {manifest['bundle_hash'][:12]}, shim_needs={manifest['shim_needs']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
