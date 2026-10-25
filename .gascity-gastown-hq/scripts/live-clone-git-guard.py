#!/usr/bin/env python3
r"""live-clone-git-guard.py — trava contra o `git checkout`/`git switch` que tira o HEAD do clone VIVO de produção do `main` (ga-9jiq86).
Hook PreToolUse (Bash). Selftest: live-clone-git-guard.selftest.sh.

Contents
  Para que serve · Como decide · Ativação · Limites
PARA QUE SERVE
  O clone /Users/athos/gt/whatsapp_automation é o que os jobs de produção leem. Em 10/10 ele ficou em HEAD destacado por 15 dias (o drift-guard
  gravou 73.919 linhas de erro) e o reflog mostra idas e voltas de 19 s em 21/10 e 24/10: sessões do Claude (revisores do gate) com o cwd dentro
  dele rodando `git checkout --detach <sha>`. O que já existia só AVISA depois (post-checkout → prod-clone-checkout.log) ou pede por escrito
  (prompt do revisor). O `gt tap guard cross-clone-block` não cobre: só olha `git -C <clone de crew>`, e no settings dispara só com `if: Bash(git -C *)`.
  Este hook recusa ANTES, com uma mensagem que ensina o idioma seguro. Vale sob `--dangerously-skip-permissions` (exit 2 bloqueia em qualquer modo).
COMO DECIDE
  Reaproveita o leitor de shell do remote-clone-guard.py (scan: cd/pushd, `-C`, `bash -c`, eval, subshell, função, find -exec, VAR=x, env/sudo…) e troca só a
  pergunta feita a cada `git`: o subcomando é checkout/switch, ele MOVE o HEAD, e o clone onde roda é um dos protegidos?
  · move o HEAD = tudo, menos (a) sem argumento, (b) só `main` com no máximo -q/--quiet (a volta), (c) `checkout [<árvore>] -- <arquivo>` sem -b/-d/--detach/--orphan (arquivo, HEAD fica).
  · clone = o ancestral mais próximo do alvo que tem `.git`; só vale se for um dos protegidos (LCG_ROOTS, separados por `:`; padrão ~/gt/whatsapp_automation).
    Clone aninhado (crew/x) e worktree ligado têm `.git` próprio e ficam livres. O alvo vem do cwd do hook, de `-C`, de `cd`, de --work-tree/GIT_WORK_TREE e do pai
    de --git-dir/GIT_DIR (o checkout de um --git-dir cai no cwd mas move o HEAD do clone do --git-dir).
  · FALHA ABERTA, de propósito: é trava contra engano (o slip de cwd), não sandbox, e roda em TODA sessão do mini — um defeito dele não pode derrubar o trabalho dos outros.
    Diretório que não resolvo (variável, glob), JSON ilegível, parser que não carrega, qualquer exceção → libera (o parser que não carrega e o erro viram result=ERROR no log;
    `--selfcheck` falha para o ativador ver).
CÓDIGOS: 0 liberado · 2 bloqueado. `--selfcheck [settings.json…]`: 0 se o guarda decide como deveria numa pasta de teste E (com settings) todo PreToolUse de Bash é EXATAMENTE
  `python3 -I <este arquivo>` (só type/command/timeout — um `if` limitaria o disparo a `git -C *`, e `|| true` apagaria o exit 2) sem `disableAllHooks`; 1 caso contrário.
CUSTO: roda em TODA chamada de Bash. Comando que não cita checkout/switch sai no pré-filtro, perto do Python vazio (~85-120 ms no mini, que mede ruidoso sob load alto); o que cita carrega o parser
  e custa ~140-220 ms. O parser traz `import tempfile` só para o --selfcheck dele (shutil → compression.zstd, +~270 ms): load_rcg() põe um módulo vazio no lugar. Não importe nada pesado no topo deste arquivo.
LOG: uma linha TSV por bloqueio/erro em $LCG_LOG, senão $GC_CITY_PATH/.gc/logs/live-clone-git-guard.log (ts result root op cwd session agent alias). Liberar não grava.
ATIVAÇÃO (decisão do Mayor/Athos: o settings do usuário não é editado por agente): em PreToolUse, matcher "Bash", UM hook
  {"type": "command", "command": "python3 -I /Users/athos/gt/.gascity-gastown-hq/scripts/live-clone-git-guard.py"}   — sem `if`.
  Depois: `python3 -I <este arquivo> --selfcheck ~/.claude/settings.json` tem que sair 0.
LIMITES (não vê, e o que isso quer dizer): checkout feito FORA do Claude (launchd, script, terminal do Athos — o post-checkout cobre com log); `git rebase`/`bisect`/`reset --hard` (também mexem no HEAD ou
  na árvore, mas não foram o incidente; `git reset --hard` já tem o guarda dangerous-command); alvo que só se sabe em tempo de execução (`cd "$(…)"`, `cd $VAR`); alias do git; `g''it`/`che''ckout`
  não escapam do pré-filtro mas um git por variável (`$G checkout`) sim. Depende do remote-clone-guard.py (scan/res): mudar a assinatura de lá quebra este selftest.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time

RCG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "remote-clone-guard.py")
HEAD_MOVERS = ("checkout", "switch")
QUIET = {"-q", "--quiet"}
BRANCHY = re.compile(r"-[A-Za-z]*[bBdt][A-Za-z]*|--(?:detach|orphan|track)(?:=.*)?")  # opção do checkout que cria branch ou destaca: `--` depois dela NÃO vira modo arquivo
PREFILTER = re.compile(r"checkout|switch")


def load_rcg():
    """O parser de shell do remote-clone-guard.py. vazio (sem LCG_RCG) → o vizinho deste arquivo; falhou/ilegível → exceção, e quem chama decide (main libera e grava ERROR)."""
    import importlib.util
    sys.dont_write_bytecode = True  # não deixa __pycache__ dentro de scripts/ (árvore rastreada)
    # o parser importa `tempfile` só para o --selfcheck DELE (que não chamo); no mini isso puxa shutil → compression.zstd (~270 ms) em toda sessão que cita "checkout". Um módulo vazio no lugar
    # (setdefault: se o `tempfile` de verdade já foi importado, como no meu selfcheck, fica o de verdade) tira o custo do caminho quente
    sys.modules.setdefault("tempfile", type(sys)("tempfile"))
    spec = importlib.util.spec_from_file_location("remote_clone_guard", os.environ.get("LCG_RCG") or RCG_FILE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def roots_from_env() -> set:
    # vazio → a raiz padrão (o clone vivo do WA); preenchido → só as dadas. Caminho que não existe fica na lista e simplesmente não casa com nada.
    items = [x for x in os.environ.get("LCG_ROOTS", "").split(":") if x] or ["~/gt/whatsapp_automation"]
    return {os.path.realpath(os.path.expanduser(x)) for x in items}


def protected(p, roots: set):
    """A raiz protegida a que o diretório `p` pertence, ou None: sobe até o primeiro ancestral com `.git` (clone, clone aninhado ou worktree) e só vale se ele for protegido."""
    while p and p != os.path.dirname(p):
        # vazio (nenhum .git neste nível) → sobe; falhou/ilegível (sem permissão, caminho que não existe) → os.path.exists diz não e sobe também
        if os.path.exists(os.path.join(p, ".git")):
            return p if p in roots else None
        p = os.path.dirname(p)
    return None


def moves_head(sub: str, rest: list) -> bool:
    """O checkout/switch pode tirar o HEAD do main? Só não tira: sem argumento, a volta (`main` com -q), e `checkout [<árvore>] -- <arquivo>` sem opção que cria branch/destaca."""
    if not rest:
        return False
    if sub == "checkout" and "--" in rest:
        before = rest[:rest.index("--")]
        return any(BRANCHY.fullmatch(a) for a in before if a.startswith("-"))
    flags = [a for a in rest if a.startswith("-")]
    words = [a for a in rest if not a.startswith("-")]
    return not (words == ["main"] and all(f in QUIET for f in flags))


def make_hit(rcg, roots: set):
    def hit(seg: list, env: dict, cwd, terr, own):
        """Substitui rcg.git_hit (mesma assinatura): (raiz, operação) se este `git` move o HEAD de um clone protegido; None se não (ou se não sei onde roda: falha aberta)."""
        # vazio (sem GIT_WORK_TREE/GIT_DIR) → o cwd manda; ilegível ($VAR, glob) → res devolve None e o alvo vira "não sei"
        wt, gd, i = env.get("GIT_WORK_TREE"), env.get("GIT_DIR"), 1
        while i < len(seg) and seg[i].startswith("-"):
            a = seg[i]
            if a == "-C" and i + 1 < len(seg):
                cwd, i = rcg.res(seg[i + 1], cwd), i + 2
            elif a in ("-c", "--config-env", "--namespace", "--attr-source") and i + 1 < len(seg):
                i += 2
            elif a.startswith(("--git-dir", "--work-tree")):
                k, _, v = a.partition("=")
                if not v and i + 1 < len(seg):
                    v, i = seg[i + 1], i + 1
                if k == "--work-tree":
                    wt = v
                else:
                    gd = v
                i += 1
            else:  # opção de topo sem valor (--no-pager, -p…) ou que não conheço: segue; o pior caso é não achar o subcomando e liberar
                i += 1
        sub, rest = (seg[i] if i < len(seg) else ""), seg[i + 1:]
        if sub not in HEAD_MOVERS or not moves_head(sub, rest):
            return None
        cands = [rcg.res(wt, cwd) if wt else cwd]
        gdp = rcg.res(gd, cwd) if gd else None
        if gdp and os.path.basename(gdp) == ".git":  # o checkout de --git-dir=<clone>/.git cai no cwd, mas o HEAD que se move é o do <clone>
            cands.append(os.path.dirname(gdp))
        for c in cands:
            root = protected(c, roots) if c else None
            if root:
                return root, " ".join(["git", sub] + rest)[:200]
        return None
    return hit


def decide(cmd: str, cwd, roots: set, rcg):
    """None = liberado; (raiz, operação) = bloqueado. Alvo que o parser não resolveu (scan devolve (None, motivo)) = não sei = liberado."""
    rcg.git_hit = make_hit(rcg, roots)  # scan chama git_hit pelo nome do módulo: trocar aqui troca a pergunta, não o leitor de shell
    res = rcg.scan(cmd, os.path.realpath(cwd) if cwd else None, "", None)
    return res if res and res[0] else None


def log(result: str, root: str, op: str, cwd: str) -> None:
    # vazio (sem LCG_LOG e sem GC_CITY_PATH) → sem destino, não grava; falhou/ilegível (pasta que não existe, disco cheio) → segue sem log: o veredito já está dado e não depende dele
    path = os.environ.get("LCG_LOG") or (os.path.join(os.environ["GC_CITY_PATH"], ".gc", "logs", "live-clone-git-guard.log") if os.environ.get("GC_CITY_PATH") else "")
    if not path:
        return
    row = [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "result=" + result, "root=" + root, "op=" + re.sub(r"\s+", " ", op), "cwd=" + cwd,
           "session=" + os.environ.get("GC_SESSION_NAME", ""), "agent=" + os.environ.get("GC_AGENT", ""), "alias=" + os.environ.get("GC_ALIAS", "")]
    try:
        with open(path, "a") as f:
            f.write("\t".join(row) + "\n")
    except OSError:
        pass


def message(root: str, op: str) -> str:
    return ("[HOOK BLOCK: live-clone-git-guard] NÃO É CANCELAMENTO DO USUÁRIO — política automática (ga-9jiq86).\n"
            f"BLOQUEADO: `{op}` no clone vivo de produção.\nClone: {root}\n"
            "Este clone só fica em `main`: os jobs de produção leem o HEAD dele, e um checkout destacado já o deixou dias fora do main.\n"
            f"Para OLHAR um commit sem mexer no clone: git -C {root} show <sha>:<arquivo> · git -C {root} grep <padrão> <sha> -- <pasta> · "
            f"git -C {root} worktree add --detach <pasta-fora-do-clone> <sha> (e trabalhe lá, dentro do scratchpad).\n"
            "Se o clone JÁ está solto, a volta é liberada: git checkout main.\n"
            "Restaurar um ARQUIVO (git checkout -- <arquivo>) e ler (log/status/show/grep) continuam liberados.\n")


def selfcheck(args: list) -> int:
    import tempfile  # antes do load_rcg: o parser não pode trocá-lo por um módulo vazio aqui
    ok = True
    try:
        rcg = load_rcg()
    except Exception as e:  # noqa: BLE001 — qualquer defeito do parser é "FALHOU" para quem ativa
        print(f"selfcheck: o parser não carrega ({type(e).__name__}: {e})", file=sys.stderr)
        print("selfcheck: FALHOU")
        return 1
    with tempfile.TemporaryDirectory() as d:
        d = os.path.realpath(d)
        live, nested = d + "/live", d + "/live/crew/x"
        os.makedirs(live + "/.git")
        os.makedirs(nested + "/.git")
        for cmd, cwd, want in (("git checkout --detach abc", live, True), ("git switch --detach", live, True), ("cd " + live + " && git checkout abc", d, True),
                               ("git checkout main", live, False), ("git checkout -- f", live, False), ("git status", live, False),
                               ("git checkout --detach abc", nested, False)):
            try:
                got = decide(cmd, cwd, {live}, rcg) is not None
            except Exception as e:  # noqa: BLE001
                got = f"erro {type(e).__name__}"
            if got != want:
                ok = False
                print(f"selfcheck: `{cmd}` em {cwd.replace(d, '<tmp>')}: bloqueou={got}, deveria={want}", file=sys.stderr)
    me = os.path.abspath(__file__)
    for path in args:
        try:
            # vazio ({} ou sem PreToolUse) → nenhum grupo vale → FALHOU abaixo; falhou/ilegível (não existe, JSON ruim) → FALHOU com o motivo, nunca "ok"
            s = json.load(open(path))
            if s.get("disableAllHooks"):
                raise ValueError("disableAllHooks ligado")
            groups = (s.get("hooks") or {}).get("PreToolUse") or []
            # um grupo vale se o matcher pega "Bash", não tem campo que mude QUANDO dispara (só matcher/hooks) e tem o hook EXATO (só type/command/timeout)
            if not any((g.get("matcher") in (None, "", "*") or re.fullmatch(g["matcher"], "Bash")) and set(g) <= {"matcher", "hooks"}
                       and any(h.get("type") == "command" and h.get("command", "").strip() == "python3 -I " + me and set(h) <= {"type", "command", "timeout"}
                               for h in g.get("hooks", []))
                       for g in groups):
                raise ValueError(f"nenhum hook PreToolUse de Bash é exatamente `python3 -I {me}` (sem `if`, `|| …`, async — só type/command/timeout)")
        except (OSError, ValueError, AttributeError, KeyError, TypeError, re.error) as e:
            ok = False
            print(f"selfcheck: settings {path}: {e}", file=sys.stderr)
    print("selfcheck: " + ("ok" if ok else "FALHOU"))
    return 0 if ok else 1


def main(argv: list) -> int:
    if argv[1:2] == ["--selfcheck"]:
        return selfcheck(argv[2:])
    try:
        # vazio → nada a conferir (libera); ilegível (não é JSON, bytes ruins) → libera: não é o pedido de ferramenta do hook
        inp = json.loads(sys.stdin.read())
    except (ValueError, OSError):
        return 0
    if not isinstance(inp, dict) or inp.get("tool_name") != "Bash":
        return 0
    # vazio (sem tool_input/command) → cmd "" → o pré-filtro libera; ilegível (tool_input que não é objeto) → também "" e libera, sem traceback
    ti = inp.get("tool_input")
    cmd = str(ti.get("command") or "") if isinstance(ti, dict) else ""
    if not PREFILTER.search(re.sub(r"['\"\\]", "", cmd)):  # sem a palavra (nem escondida por aspas/barra), nada a conferir: não paga o parser
        return 0
    try:
        rcg = load_rcg()
    except Exception as e:  # noqa: BLE001 — trava contra engano: parser quebrado não derruba a sessão de ninguém
        log("ERROR", "", "parser: " + str(e)[:100], "")
        return 0  # sem parser
    try:
        hit = decide(cmd, inp.get("cwd") or None, roots_from_env(), rcg)
    except Exception as e:  # noqa: BLE001
        log("ERROR", "", "decide: " + str(e)[:100], inp.get("cwd") or "")
        return 0  # falhou
    if not hit:
        return 0
    root, op = hit
    log("BLOCK", root, op, inp.get("cwd") or "")
    print(message(root, op), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
