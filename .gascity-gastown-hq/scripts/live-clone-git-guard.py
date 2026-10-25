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
  · move o HEAD = tudo, menos (a) sem argumento, (b) só `main` com no máximo -q/--quiet (a volta), (c) `checkout [<árvore>] -- <arquivo>` (ao menos um arquivo depois do `--`) sem -b/-d/--detach/--orphan (arquivo, HEAD fica).
  · clone = o ancestral mais próximo do alvo que tem `.git`; só vale se for um dos protegidos (LCG_ROOTS, separados por `:`; padrão ~/gt/whatsapp_automation).
    Clone aninhado (crew/x) e worktree ligado têm `.git` próprio e ficam livres. Um checkout toca DUAS coisas e as duas contam: a árvore que ele reescreve
    (--work-tree/GIT_WORK_TREE, senão o cwd) e o repositório cujo HEAD anda (o pai de --git-dir/GIT_DIR, senão o achado a partir do cwd — mesmo com --work-tree apontando para outro
    lugar). O cwd vem do hook, de `-C` e de `cd`. Qualquer das duas sem resposta (variável, glob) é "não sei", nunca "é outro lugar".
  · FALHA ABERTA, de propósito: é trava contra engano (o slip de cwd), não sandbox, e roda em TODA sessão do mini — um defeito dele não pode derrubar o trabalho dos outros.
    Payload que o guarda não sabe ler → libera, mas SEMPRE com uma linha result=ERROR (um guarda morto tem de aparecer no log): JSON ilegível (inclusive aninhado fundo demais) ou que não é o objeto do hook; sem tool_name
    (ou "bash" em outra caixa); Bash sem tool_input.command em texto não vazio (`cmd`, `command` null, embrulho `input`…); cwd que não é texto (123, lista). Parser que não carrega ou exceção na decisão → idem
    (`--selfcheck` falha para o ativador ver o parser). O veredito não depende do log: gravar falhou (pasta que não existe, disco cheio) ou o texto não codifica (surrogate solto sai escapado) → o exit 2 fica.
    Pasta que o parser não resolve (variável em cd/-C/--git-dir/--work-tree, glob, lançador opaco como flock/watch, aninhado fundo demais) → libera, EXCETO quando o cwd da sessão é o clone vivo: aí é o
    escorregão do incidente e barra, pedindo `git -C <pasta-absoluta>` (a mensagem explica; com a pasta dita por extenso e fora do vivo, passa). O que libera sem saber onde roda
    NÃO é silencioso: uma linha result=UNRESOLVED (op, cwd, sessão) no log, exit 0 — contar essas linhas diz quantas vezes o guarda ficou cego.
    Não saber O QUE o git roda vale o mesmo: subcomando por variável/substituição (`X=checkout; git $X --detach abc`) ou git checkout/switch (ou git sem subcomando) num comando que cita xargs/parallel: o subcomando ou os operandos chegam em tempo de execução
    (`echo --detach | xargs git checkout main` NÃO é a volta; `echo checkout --detach abc | xargs git`) → barra se o git roda no vivo ou a sessão está nele, senão libera e CONTA (UNRESOLVED).
CÓDIGOS: 0 liberado · 2 bloqueado. `--selfcheck [settings.json…]`: 0 se o guarda decide como deveria numa pasta de teste E (com settings) todo PreToolUse de Bash é EXATAMENTE
  `python3 -I <este arquivo>` (só type/command/timeout — um `if` limitaria o disparo a `git -C *`, e `|| true` apagaria o exit 2) sem `disableAllHooks`; 1 caso contrário.
CUSTO: roda em TODA chamada de Bash. Comando que não cita checkout/switch (nem abre `$'…'`) sai no pré-filtro, perto do Python vazio (~85-120 ms no mini, que mede ruidoso sob load alto); o que cita carrega o parser
  e custa ~140-220 ms. O parser traz `import tempfile` só para o --selfcheck dele (shutil → compression.zstd, +~270 ms): load_rcg() põe um módulo vazio no lugar. Não importe nada pesado no topo deste arquivo.
  Texto de mais de MAX_CMD (32768 caracteres) que cita checkout/switch NÃO vai ao parser: o custo dele é superlinear nesse texto (medido: ~110 ms a 25 KB, ~170 ms a 50 KB, ~950 ms a 200 KB com load ~12; ~10 s a 200 KB com load ~43, segundo o revisor do
  gate). Fora do vivo libera e grava result=UNRESOLVED op="comando grande demais…"; com o cwd da sessão no vivo barra, como todo "não sei" (o escorregão pode estar escondido no texto).
LOG: uma linha TSV por bloqueio (result=BLOCK), erro (ERROR) ou liberação às cegas (UNRESOLVED, exit 0) em $LCG_LOG, senão $GC_CITY_PATH/.gc/logs/live-clone-git-guard.log (ts result root op cwd session agent alias). Liberar sabendo onde roda não grava. Sem LCG_LOG e sem GC_CITY_PATH (terminal fora do gc) nada grava: o BLOCK ainda avisa no stderr, ERROR/UNRESOLVED não deixam rastro.
ATIVAÇÃO (decisão do Mayor/Athos: o settings do usuário não é editado por agente): em PreToolUse, matcher "Bash", UM hook
  {"type": "command", "command": "python3 -I /Users/athos/gt/.gascity-gastown-hq/scripts/live-clone-git-guard.py"}   — sem `if`.
  Depois: `python3 -I <este arquivo> --selfcheck ~/.claude/settings.json` tem que sair 0.
LIMITES (não vê, e o que isso quer dizer): checkout feito FORA do Claude (launchd, script, terminal do Athos — o post-checkout cobre com log); `git rebase`/`bisect`/`reset --hard` (também mexem no HEAD ou
  na árvore, mas não foram o incidente; `git reset --hard` já tem o guarda dangerous-command); alvo que só se sabe em tempo de execução (`cd "$(…)"`, `cd $VAR`) quando o cwd da sessão NÃO é o vivo; aninhamento além de 3 níveis (o parser desiste: o que vem depois no mesmo comando não é conferido — armadilha de propósito é fora do escopo); alias do git; `gh pr checkout <n>` (o parser só olha `git`); `$"…"` (aspas de locale: `ch$"e"ckout`, só o `$'…'` é decodificado); caminho do clone escrito com outra caixa (o APFS ignora a caixa, o guarda compara o texto do realpath);
  `g''it`/`che''ckout` e `$'\x63heckout'` não escapam do pré-filtro mas um git por variável (`$G checkout`) sim. Depende do remote-clone-guard.py (scan/res): mudar a assinatura de lá quebra este selftest.
  Subcomando por variável SEM a palavra checkout/switch em lugar nenhum do texto (`git $CMD abc` com CMD vindo do ambiente) não chega ao parser: alargar o pré-filtro mandaria ao parser todo `git … $VAR` e toda mensagem de commit em heredoc
  (+~100 ms em toda chamada com `git … $VAR` ou `$(…)`, para pegar um caso que não é o do incidente). xargs/parallel são vistos como PALAVRA no texto (sem aspas), não por git: qualquer git checkout/switch num comando que também cita xargs conta como não sei, até a volta `git checkout main` (separe em duas chamadas);
  `x$'\x61'rgs` não é visto; comando acima de MAX_CMD não é conferido (fora do vivo só contado, com a sessão no vivo barra).
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
UNQUOTE = re.compile(r"['\"\\]")  # aspas e barras: tiradas, o texto deixa ver `che''ckout` e `x''args` como o shell os junta
ANSI_C = "$" + "'"  # abre uma string ANSI-C ($'\x63heckout'): esconde letras por escape, o pré-filtro não enxerga a palavra e só o parser decodifica
UNKNOWN = "pasta desconhecida: "  # prefixo do `op` quando o parser não disse onde o git roda e o cwd da sessão é o clone vivo (message() troca o texto)
UNKNOWN_WHAT = "subcomando desconhecido: "  # prefixo do `op` quando não sei O QUE o git roda e ele roda no clone vivo, ou a sessão está nele (message() troca o texto)
SHELLY = re.compile(r"[$`*?\[{]")  # a mesma classe de caracteres com que o parser diz "não sei" a um caminho (res): variável, substituição, glob, chave
APPENDERS = re.compile(r"\b(?:xargs|parallel)\b")  # programas que acrescentam operandos ao git em tempo de execução: o `git checkout` sem argumento que o parser vê não é o que roda
BIG = "comando grande demais para conferir"  # começo do `op` do comando acima de MAX_CMD, na linha UNRESOLVED e no BLOCK (message() troca o texto)
MAX_CMD = 32768  # caracteres; o parser tem custo superlinear no texto que cita checkout/switch (medido aqui, load ~12: ~110 ms a 25 KB, ~170 ms a 50 KB, ~950 ms a 200 KB; o revisor do gate viu ~10 s a 200 KB sob load ~43): acima disto ele não roda: com a sessão no vivo barra, senão libera e CONTA


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
    """O checkout/switch pode tirar o HEAD do main? Só não tira: sem argumento, a volta (`main` com -q), e `checkout [<árvore>] -- <arquivo>` (com arquivo) sem opção que cria branch/destaca."""
    if not rest:
        return False
    if sub == "checkout" and "--" in rest and rest[rest.index("--") + 1:]:  # com arquivo depois do `--` é restaurar arquivo; `git checkout <sha> --` (nada depois) só desambigua o nome e o HEAD MOVE
        before = rest[:rest.index("--")]
        return any(BRANCHY.fullmatch(a) for a in before if a.startswith("-"))
    flags = [a for a in rest if a.startswith("-")]
    words = [a for a in rest if not a.startswith("-")]
    return not (words == ["main"] and all(f in QUIET for f in flags))


def make_hit(rcg, roots: set, hook_cwd, blind: list, appends: bool = False):
    def hit(seg: list, env: dict, cwd, terr, own):
        """Substitui rcg.git_hit (mesma assinatura): (raiz, operação) se este `git` move o HEAD de um clone protegido; None se não (ou se não sei onde roda, ou o que faz, e a sessão não está no clone vivo: falha aberta, anotada em `blind`)."""
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
        # vazio (sem subcomando) → não é checkout/switch; ilegível ($VAR, $(…), glob no lugar do subcomando) ou git num comando com xargs/parallel: o subcomando ou os operandos chegam em tempo de execução, e
        # `xargs git checkout main` recebendo `--detach` NÃO é a volta, `xargs git` recebendo `checkout --detach abc` não tem subcomando para eu ler → "não sei O QUE roda", nunca "não move o HEAD" (qualquer `rest`)
        what = bool(SHELLY.search(sub)) or (appends and (sub == "" or sub in HEAD_MOVERS))
        if not what and (sub not in HEAD_MOVERS or not moves_head(sub, rest)):
            return None
        # um checkout toca DUAS coisas e as duas contam: a ÁRVORE que reescreve (--work-tree, senão o cwd) e o repositório cujo HEAD anda (--git-dir, senão o achado a partir do cwd)
        wtp = rcg.res(wt, cwd) if wt else None
        gdp = rcg.res(gd, cwd) if gd else None
        tree = wtp if wt else cwd
        cands = [tree]
        if not gd:  # sem --git-dir o repositório vem do cwd, mesmo com --work-tree apontando para outro lugar
            cands.append(cwd)
        elif gdp and os.path.basename(gdp) == ".git":  # o checkout de --git-dir=<clone>/.git cai no cwd, mas o HEAD que se move é o do <clone>
            cands.append(os.path.dirname(gdp))
        # vazio (sem --git-dir/--work-tree) → o cwd responde pelos dois; ilegível ($VAR, glob, lançador opaco → res/cwd None) → "não sei" de UMA das duas já basta, nunca "é outro lugar"
        unsure = what or tree is None or (gd and gdp is None) or (not gd and cwd is None)  # não sei O QUE roda vale como não sei ONDE: pode ser um checkout em qualquer lugar
        op = " ".join(["git", sub] + rest)[:200]
        for c in cands:
            root = protected(c, roots) if c else None
            if root:
                return root, (UNKNOWN_WHAT if what else "") + op
        if unsure:  # não sei onde este git roda (cd $VAR, lançador opaco, -C/--git-dir/--work-tree $VAR) ou o que ele faz: só barro se o cwd da SESSÃO é o clone vivo — o escorregão do incidente; fora dele, libera, mas CONTADO (blind → result=UNRESOLVED no log)
            root = protected(hook_cwd, roots) if hook_cwd else None
            if root:
                return root, (UNKNOWN_WHAT if what else UNKNOWN) + op
            blind.append(op)  # sessão fora do vivo: libera, mas conta
        return None
    return hit


def decide(cmd: str, cwd, roots: set, rcg, blind: list):
    """None = liberado; (raiz, operação) = bloqueado. Onde o git roda, ou o que ele faz, e o parser não resolveu (variável, lançador opaco, aninhado fundo demais, subcomando por variável, operandos do xargs) = não sei: libera, salvo se o cwd da sessão é o clone vivo; o que liberou sem saber vai para `blind`."""
    # vazio (sem cwd no JSON) → None: não há de onde desconfiar, e o parser também recebe "não sei"
    real = os.path.realpath(cwd) if cwd else None
    if len(cmd) > MAX_CMD:  # o parser custa mais que linear neste texto e não roda: é um "não sei" como os outros — com a sessão NO vivo barra (o escorregão pode estar escondido aqui), senão libera e CONTA
        op = f"{BIG} ({len(cmd)} caracteres): {cmd[:100]}"
        root = protected(real, roots) if real else None
        if root:
            return root, op
        blind.append(op)  # acima do teto, fora do vivo: libera, mas conta
        return None
    # texto sem aspas/barras (como o pré-filtro): `x''args` também conta; vazio → False (nenhum xargs/parallel no comando)
    appends = bool(APPENDERS.search(UNQUOTE.sub("", cmd)))
    rcg.git_hit = make_hit(rcg, roots, real, blind, appends)  # scan chama git_hit pelo nome do módulo: trocar aqui troca a pergunta, não o leitor de shell
    res = rcg.scan(cmd, real, "", None)
    if res and res[0]:
        return res
    if res:  # (None, motivo): o parser desistiu no meio (aninhado fundo demais) e o resto do comando não foi conferido: mesmo critério do `não sei` acima; o `op` é o comando (o motivo do parser não diz nada a quem lê a mensagem)
        op = " ".join(cmd.split())[:200]
        root = protected(real, roots) if real else None
        if root:
            return root, UNKNOWN + op
        blind.append(op)  # aninhado fundo demais fora do vivo: libera, mas conta
    return None


def log(result: str, root: str, op: str, cwd: str) -> None:
    # vazio (sem LCG_LOG e sem GC_CITY_PATH) → sem destino, não grava; falhou/ilegível (pasta que não existe, disco cheio) → segue sem log: o veredito já está dado e não depende dele;
    # texto que não codifica (surrogate solto num comando que veio do JSON) sai escapado (errors=backslashreplace): sem isso o UnicodeEncodeError trocava o exit 2 por traceback + exit 1 e o checkout rodava
    path = os.environ.get("LCG_LOG") or (os.path.join(os.environ["GC_CITY_PATH"], ".gc", "logs", "live-clone-git-guard.log") if os.environ.get("GC_CITY_PATH") else "")
    if not path:
        return
    row = [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "result=" + result, "root=" + root, "op=" + re.sub(r"\s+", " ", op), "cwd=" + cwd,
           "session=" + os.environ.get("GC_SESSION_NAME", ""), "agent=" + os.environ.get("GC_AGENT", ""), "alias=" + os.environ.get("GC_ALIAS", "")]
    try:
        with open(path, "a", errors="backslashreplace") as f:
            f.write("\t".join(row) + "\n")
    except OSError:
        pass


def message(root: str, op: str) -> str:
    if op.startswith(UNKNOWN_WHAT):
        what = (f"BLOQUEADO: não consegui ver o que `{op[len(UNKNOWN_WHAT):]}` faz (subcomando escrito por variável/substituição, ou operandos que xargs/parallel acrescentam em tempo de execução) e ele pode ser um checkout/switch que tira o HEAD do clone vivo de produção.\n"
                f"Clone: {root}\nRefaça com o subcomando e os operandos por extenso na linha: git checkout main (a volta) ou git -C <pasta-fora-do-vivo> checkout … (se a pasta NÃO é o clone vivo, passa).\n")
    elif op.startswith(BIG):
        what = (f"BLOQUEADO: {op.split(': ', 1)[0]}, teto {MAX_CMD}, e o texto cita checkout/switch: não consegui conferi-lo, e o cwd desta sessão é o clone vivo de produção.\n"
                f"Clone: {root}\nRefaça com um comando menor (escreva arquivos com a ferramenta Write/Edit, não com o Bash) ou rode de fora do clone vivo.\n")
    elif op.startswith(UNKNOWN):
        what = (f"BLOQUEADO: não consegui ver em que pasta `{op[len(UNKNOWN):]}` roda (variável em cd/-C/--git-dir/--work-tree, lançador como flock/watch, ou comando aninhado fundo demais) e o cwd desta sessão é o clone vivo de produção.\n"
                f"Clone: {root}\nRefaça dizendo a pasta por extenso e sem aninhar tanto: git -C <pasta-absoluta> checkout … (se ela NÃO é o clone vivo, passa).\n")
    else:
        what = f"BLOQUEADO: `{op}` no clone vivo de produção.\nClone: {root}\n"
    return ("[HOOK BLOCK: live-clone-git-guard] NÃO É CANCELAMENTO DO USUÁRIO — política automática (ga-9jiq86).\n"
            + what +
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
                               ("git checkout --detach abc", nested, False), ("X=checkout; git $X --detach abc", live, True), ("echo abc | xargs git checkout", live, True)):
            try:
                got = decide(cmd, cwd, {live}, rcg, []) is not None
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
        # vazio ou ilegível (não é JSON, bytes ruins, aninhado fundo demais → RecursionError) → libera, mas grava ERROR: se o Claude Code mudar o payload do hook o guarda morre em toda chamada, e sem a linha ninguém vê
        inp = json.loads(sys.stdin.read())
    except (ValueError, OSError, RecursionError) as e:
        log("ERROR", "", "stdin: " + str(e)[:100], "")
        return 0
    if not isinstance(inp, dict):  # JSON válido que não é o objeto do hook: o mesmo defeito de payload
        log("ERROR", "", "stdin: payload não é um objeto", "")
        return 0
    # vazio (sem cwd no JSON) → "" e o parser recebe "não sei"; ilegível (cwd que não é texto: 123, lista) → também "" e, num Bash legível, uma linha ERROR `payload: cwd não é texto` — texto é o único tipo que o resto do guarda aceita (realpath, "cwd=" + cwd)
    cwd = inp.get("cwd")
    bad_cwd = cwd is not None and not isinstance(cwd, str)
    cwd = cwd if isinstance(cwd, str) else ""
    # vazio (sem tool_name) ou ilegível (não é texto) → libera + ERROR `payload: sem tool_name`; texto que não é Bash → libera calado (é outra ferramenta), salvo "bash" em outra caixa (ERROR: o payload mudou)
    name = inp.get("tool_name")
    if not isinstance(name, str):  # a chave que diz a ferramenta sumiu ou foi renomeada: o guarda não sabe o que está olhando
        log("ERROR", "", "payload: sem tool_name", cwd)
        return 0
    if name != "Bash":
        if name.casefold() == "bash":  # a mesma ferramenta com outra grafia: o payload mudou e o guarda deixou de reconhecê-la
            log("ERROR", "", "payload: tool_name inesperado: " + name[:40], cwd)
        return 0
    # vazio ou ilegível (sem tool_input, tool_input que não é objeto, command ausente/null/vazio/que não é texto — `cmd`, embrulho `input`…) → libera, mas grava ERROR: é o mesmo payload que mudou, e sem a linha um guarda morto parece um guarda calado
    ti = inp.get("tool_input")
    cmd = ti.get("command") if isinstance(ti, dict) else None
    if not isinstance(cmd, str) or not cmd:
        log("ERROR", "", "payload: sem tool_input.command", cwd)
        return 0
    if bad_cwd:
        log("ERROR", "", "payload: cwd não é texto", "")
    if ANSI_C not in cmd and not PREFILTER.search(UNQUOTE.sub("", cmd)):  # sem a palavra (nem escondida por aspas/barra/ANSI-C), nada a conferir: não paga o parser
        return 0
    try:
        rcg = load_rcg()
    except Exception as e:  # noqa: BLE001 — trava contra engano: parser quebrado não derruba a sessão de ninguém
        log("ERROR", "", "parser: " + str(e)[:100], "")
        return 0  # sem parser
    blind = []  # ops de checkout/switch que liberei sem saber onde rodam (ou o que fazem)
    try:
        hit = decide(cmd, cwd or None, roots_from_env(), rcg, blind)
    except Exception as e:  # noqa: BLE001
        log("ERROR", "", "decide: " + str(e)[:100], cwd)
        return 0  # falhou
    if not hit:
        if blind:  # liberado sem saber: o veredito (0) não muda, mas fica contado e visível — sem isso ninguém mede quantas vezes o guarda ficou cego
            log("UNRESOLVED", "", blind[0], cwd)
        return 0
    root, op = hit
    log("BLOCK", root, op, cwd)
    print(message(root, op), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
