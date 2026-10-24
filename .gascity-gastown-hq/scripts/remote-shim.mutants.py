#!/usr/bin/env python3
"""remote-shim.mutants.py — campanha de mutantes do remote-shim (ga-2hd02v.1.2): prova que o selftest REPROVA quando uma guarda some.

Contents
  Como roda · O que conta como morto · Como acrescentar um mutante

COMO RODA
  python3 -I scripts/remote-shim.mutants.py [--jobs N] [--only NOME,NOME]
  Cada linha de MUTANTS troca UM trecho do wrapper (ou do shim) por uma versão sem a guarda, grava a cópia numa pasta temporária e roda
  `FAILFAST=1 WRAPPER_UNDER_TEST=<cópia> bash remote-shim.selftest.sh` (lado do mini) ou `SHIM_UNDER_TEST=<cópia> ... remote-shim-client.selftest.sh`
  (lado do servidor). O original nunca é tocado.
  Cada rodada sobe um sshd sem privilégio e leva minutos numa máquina carregada: o padrão é 2 em paralelo.
  No Linux do servidor 4 casos do selftest reprovam por AMBIENTE com a guarda intacta ("pedido grande demais", "JSON aninhado fundo demais", "o log é 0600", "sem a separação"):
  o 1º deles (linha ~209) para o FAILFAST antes de a rodada chegar nos casos que o mutante deveria reprovar, e a campanha inteira sai "OUTRO CASO". Nesse nó rode com
  FAILFAST_IGNORE='pedido grande demais|JSON aninhado fundo demais|o log é 0600|sem a separação' python3 -I scripts/remote-shim.mutants.py --only NOME,NOME
  (regex; o selftest não para nesses casos e o runner não os conta como "o primeiro que reprovou"; se SÓ eles reprovarem, o mutante SOBREVIVEU).

O QUE CONTA COMO MORTO
  MORTO = o selftest saiu 1 E o primeiro caso que reprovou casa com `expect` (a guarda apagada é a que aquele caso exercita).
  Três resultados NÃO são morte e fazem o script sair 1: SOBREVIVEU (o selftest passou com a guarda apagada: o teste não pega o bug),
  OUTRO CASO (morreu, mas por um caso que não é o esperado: a morte pode ser por acidente), INVÁLIDO (o trecho a trocar não está mais
  no arquivo: o mutante virou vazio, e vazio não pode contar como "morto").

COMO ACRESCENTAR UM MUTANTE
  (nome, "w" ou "s", trecho exato, trecho novo, regex do primeiro caso que deve reprovar). O trecho tem que aparecer UMA vez.
"""
from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
SELFTEST = {"w": HERE / "remote-shim.selftest.sh", "s": HERE / "remote-shim-client.selftest.sh",  # cada mutante roda no selftest do arquivo que ele altera
            "p": HERE / "remote-shim-spool.selftest.sh", "u": HERE / "remote-shim-spool.selftest.sh"}
TARGET = {"w": HERE / "remote-shim-wrapper.py", "s": HERE / "remote-shim.py", "p": HERE / "remote-shim.py", "u": HERE / "remote-shim-pump.py"}
ENVVAR = {"w": "WRAPPER_UNDER_TEST", "s": "SHIM_UNDER_TEST", "p": "SHIM_UNDER_TEST", "u": "PUMP_UNDER_TEST"}
# w = wrapper · s = shim, transporte ssh · p = shim, transporte por puxada (spool) · u = o puxador do mini e o agente que ele carrega ao MBP

MUTANTS = [
    # --- wrapper: a tabela e o parser de argumentos
    ("argumento-a-mais", "w", "        if p != len(pos):\n", "        if False:\n", r"argumento a mais"),
    ("flag-desconhecida", "w", 'raise Refused(f"flag fora da lista: {a[:40]!r}")', "out.append(a); i += 1; continue", r"flag fora da lista"),
    ("flag-repetida", "w", "if name in seen and not f.rep:", "if False:", r"flag repetida"),
    ("flag-obrigatoria", "w", "if f.req and n not in seen:", "if False:", r"falta --set-metadata|sem --set-metadata"),
    ("valor-de-flag-sem-formato", "w", "if i + 1 >= len(args) or not VAL[f.val](args[i + 1]):", "if i + 1 >= len(args):", r"fora do formato"),
    ("posicional-sem-formato", "w", "                if not VAL[val](tok):", "                if False:", r"id com|fora do formato"),
    ("prefixo-basta", "w", "list(r.words) == argv[:len(r.words)]", "list(r.words[:1]) == argv[:1]", r"id de wisp com \$\(\)|gc prime SEM --hook|comando fora da lista"),  # o caso do wisp (gate-fix 1) vem antes no selftest: com a regra errada o MOTIVO da recusa muda; 22 casos reprovam sem FAILFAST, `gc prime SEM --hook` entre eles
    ("limit-zero", "w", 're.fullmatch(r"[1-9][0-9]{0,2}", s)', 're.fullmatch(r"[0-9]{1,3}", s)', r"limit 0"),
    ("nudge-com-controle", "w", "return v_text(s) and not CTRL.search(s)", "return v_text(s)", r"gc session nudge com (ESC|CR|LF|C1)"),
    ("metadata-sem-lista", "w", "k.startswith(ALLOW_META) and ", "", r"set-metadata gc\.routed_to"),
    ("metadata-prefixo-largo", "w", 'ALLOW_META = ("athos.", "story.")', 'ALLOW_META = ("athos.", "story.", "gate.", "delivery.")', r"gate\.submitted_by"),
    ("metadata-sem-caixa", "w", "and k.startswith(ALLOW_META)", "and k.lower().startswith(ALLOW_META)", r"Story\.x"),
    # ga-6auslu: o nó NÃO grava rótulo de veredito (forjaria PASS: o bd não confere dono no `label add`). Uma regra `bd label` — o alargamento óbvio — tem que reprovar o 1º caso por chave.
    ("rotulo-do-veredito-passa", "w", '    Rule("bd", ["close"], [("id", 1, 1)], {**_J, "--reason": F("text", short="-r")}, owner_lock=True),\n',
     '    Rule("bd", ["close"], [("id", 1, 1)], {**_J, "--reason": F("text", short="-r")}, owner_lock=True),\n    Rule("bd", ["label"], [("word", 1, 1), ("id", 1, 1), ("word", 1, 1)], {}),\n', r"rótulo do veredito: bd label remove"),
    # ga-2hd02v.1.16: a trava de DONO (bd comment/close em bead de veredito só pelo assignee == alias; estado que não li = recusa). Cada guarda dela, apagada, reprova o caso que a exercita.
    ("dono-sem-checagem", "w", '            owner_gate(read_bead(exe, cwd, child, bead, cfg["timeout_s"]), bead, alias)\n',
     '            read_bead(exe, cwd, child, bead, cfg["timeout_s"])\n', r"bd comment em bead de veredito de OUTRA sessão"),
    ("trava-so-sem-comment", "w", '    Rule("bd", ["comment"], [("id", 1, 1), ("text", 1, 50)], {}, owner_lock=True),\n',
     '    Rule("bd", ["comment"], [("id", 1, 1), ("text", 1, 50)], {}),\n', r"a leitura de estado é UM bd show|bd comment em bead de veredito de OUTRA sessão"),  # (a asserção da leitura vem antes do caso de recusa: sem a trava a regra nem lê)
    ("trava-so-sem-stdin", "w", '    Rule("bd", ["comment"], [("id", 1, 1)], {"--stdin": F(req=True)}, owner_lock=True),\n',
     '    Rule("bd", ["comment"], [("id", 1, 1)], {"--stdin": F(req=True)}),\n', r"bd comment --stdin em bead de veredito de outra sessão"),
    ("trava-so-sem-close", "w", '    Rule("bd", ["close"], [("id", 1, 1)], {**_J, "--reason": F("text", short="-r")}, owner_lock=True),\n',
     '    Rule("bd", ["close"], [("id", 1, 1)], {**_J, "--reason": F("text", short="-r")}),\n', r"bd close em bead de veredito de outra sessão"),
    ("tipo-sempre-casa", "w", "if VERDICT_LABEL in labels and owner != alias:", "if owner != alias:", r"bd comment <id> palavras|bd comment em bead COMUM de outro dono"),  # bloquearia a entrega dos dogs (comentar/fechar a própria bead)
    ("rotulo-por-substring", "w", "if VERDICT_LABEL in labels and owner != alias:", "if any(VERDICT_LABEL in x for x in labels) and owner != alias:", r"rótulo parecido não é o rótulo"),
    ("assignee-vazio-passa", "w", "if VERDICT_LABEL in labels and owner != alias:", "if VERDICT_LABEL in labels and owner and owner != alias:", r"bead de veredito SEM dono"),
    ("leitura-rc-ignorado", "w", "    if p.returncode != 0:\n", "    if False:\n", r"bd show com rc≠0"),
    ("leitura-lista-vazia-passa", "w", "    if not (isinstance(data, list) and len(data) == 1 and isinstance(data[0], dict)):\n", "    if False:\n", r"lista vazia"),
    ("leitura-labels-torto-passa", "w", "    if not (isinstance(labels, list) and all(isinstance(x, str) for x in labels)):\n", "    if False:\n", r"labels null"),
    ("leitura-assignee-torto-passa", "w", "if not isinstance(owner, str):", "if False:", r"assignee null"),
    ("leitura-sem-readonly", "w", '    env = {**child, "BD_READONLY": "true", "BD_DOLT_AUTO_COMMIT": "off"}\n', "    env = dict(child)\n", r"bd comment <id> palavras|bd comment em bead de veredito DO PRÓPRIO alias"),  # (sem BD_READONLY a leitura cai no calls.log e o 1º bd comment conta 2 chamadas)
    ("leitura-herda-stdin", "w", "stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,", "stdout=subprocess.PIPE,", r"o stdin chega ao comando|o stdin chega inteiro ao COMANDO"),  # (o caso do --stdin da lista, mais cedo, já reprova: a leitura herdada come o texto)
    ("leitura-no-cwd-errado", "w", '[exe, "show", bead, "--json"], cwd=cwd,', '[exe, "show", bead, "--json"], cwd="/",', r"a leitura de estado é UM bd show"),
    ("leitura-com-stderr-junto", "w", "stderr=subprocess.DEVNULL, ", "stderr=subprocess.STDOUT, ", r"aviso do Dolt no stderr"),
    ("leitura-sem-prazo", "w", "timeout=min(timeout_s, OWNER_READ_S)", "timeout=None", r"bd show que não responde"),
    # ga-dxszii: devolver a PRÓPRIA bead ao mini (`bd update <id> --if-assignee <alias> --if-status in_progress --assignee '' --status open --add-label node:never [--remove-label …]`). Cada mutante abaixo,
    # apagando ou alargando UMA guarda dela, reprova o caso que a exercita (nem toda guarda tem mutante: o `req` de --if-assignee, --assignee e --status, o formato do <alias> e o `rep` do --remove-label só têm os casos do selftest); "alargar" aqui é o jeito de a regra virar `bd label`/`bd update` livre por outra porta (verdict:PASS aprovaria código sem revisão: ga-6auslu)
    ("devolver-alias-qualquer", "w", 'if f.val == "alias" and args[i + 1] != alias:', "if False:", r"devolver: --if-assignee de OUTRO alias"),
    ("devolver-rotulo-largo", "w", '"--add-label": F(lit=("node:never",), req=True)', '"--add-label": F("word", req=True)', r"--add-label 'verdict:PASS'"),
    ("devolver-tira-qualquer-rotulo", "w", '"--remove-label": F(lit=DISPATCH_LABELS, rep=True)', '"--remove-label": F("word", rep=True)', r"--remove-label 'node:never'"),
    ("devolver-status-qualquer", "w", '"--status": F(lit=("open",), req=True)', '"--status": F("word", req=True)', r"--status closed"),
    ("devolver-passa-a-bead-adiante", "w", '"--assignee": F(lit=("",), req=True)', '"--assignee": F(lit=("", "gastown.dog-2"), req=True)', r"--assignee 'gastown.dog-2'"),
    ("devolver-sem-if-status", "w", '"--if-status": F(lit=("in_progress",), req=True)', '"--if-status": F(lit=("in_progress",))', r"devolver: sem --if-status"),
    ("devolver-reabre-bead-fechada", "w", '"--if-status": F(lit=("in_progress",), req=True)', '"--if-status": F(lit=("in_progress", "open", "closed"), req=True)', r"--if-status open"),
    ("devolver-sem-veto", "w", '"--add-label": F(lit=("node:never",), req=True)', '"--add-label": F(lit=("node:never",))', r"devolver: sem --add-label"),
    ("devolver-em-bead-de-rig", "w", 'if r.city_only and cwd != os.path.realpath(cfg["city"]):', "if False:", r"bead de RIG"),
    ("devolver-aceita-metadata", "w", '"--remove-label": F(lit=DISPATCH_LABELS, rep=True)},', '"--remove-label": F(lit=DISPATCH_LABELS, rep=True), "--set-metadata": F("kv", rep=True)},', r"flag a mais: --set-metadata"),
    ("devolver-le-a-bead-antes", "w", "city_only=True),", "city_only=True, owner_lock=True),", r"NÃO faz a leitura de estado do bd show"),  # ler e depois escrever deixa uma janela: a guarda é o compare-and-swap do bd
    ("recusa-so-a-primeira-forma", "w", "for r, why in reasons[1:] if why != reasons[0][1])", "for r, why in reasons[:0] if why != reasons[0][1])", r"devolver: sem --if-assignee"),  # o 1º caso que lê o motivo da 2ª forma (o "falta --if-assignee" só vem junto)
    # ga-2hd02v.1.18: `gate-done <bead> <ref> <sha>`: a regra, o formato do sha e do ref (o executável confere o resto) e a recusa que diz a forma
    ("gate-done-3-args-sem-regra", "w", '    Rule("gate-done", [], [("id", 1, 1), ("ref", 1, 1), ("sha", 1, 1)], hint="gate-done <bead> <ref> <sha>, ou gate-done sem argumento"),\n', "", r"gate-done <bead> <ref> <sha>"),
    ("gate-done-sha-prefixo", "w", '"sha": _fm(r"[0-9a-f]{40}")', '"sha": _fm(r"[0-9a-f]{4,40}")', r"gate-done com sha curto"),
    ("gate-done-sha-maiusculo", "w", '"sha": _fm(r"[0-9a-f]{40}")', '"sha": _fm(r"[0-9a-fA-F]{40}")', r"gate-done com sha em maiúsculas"),
    ("gate-done-ref-dotdot", "w", 'and ".." not in s and "//" not in s', 'and "//" not in s', r"gate-done com ref que o git recusaria"),
    ("gate-done-ref-lock", "w", 'not s.endswith(("/", ".", ".lock"))', 'not s.endswith(("/", "."))', r"gate-done com ref terminando em \.lock"),
    ("gate-done-ref-dois-pontos", "w", 're.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,127}", s)', 're.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}", s)', r"gate-done com ref com ':'"),
    ("gate-done-sem-a-forma-na-recusa", "w", 'hint="gate-done <bead> <ref> <sha>, ou gate-done sem argumento"', 'hint=""', r"gate-done com 1 argumento"),
    ("identidade-sessao-solta", "w", '("GC_ALIAS", "GC_AGENT", "GC_SESSION_NAME", "GC_TEMPLATE")', '("GC_ALIAS", "GC_AGENT")', r"GC_SESSION_NAME do Mayor"),
    ("session-id-atravessa", "w", '"GC_SESSION_NAME": _IDENT, "GC_TEMPLATE": _IDENT,', '"GC_SESSION_NAME": _IDENT, "GC_SESSION_ID": _IDENT, "GC_TEMPLATE": _IDENT,', r"GC_SESSION_ID não atravessa"),
    ("nudge-alvo-livre", "w", 'if r.words == ("session", "nudge") and not (cfg["nudge_re"] and cfg["nudge_re"].fullmatch(pos[0])):', "if False:", r"alvo fora do nudge_pattern"),
    ("nudge-sem-chave-roda", "w", 'not (cfg["nudge_re"] and cfg["nudge_re"].fullmatch(pos[0]))', 'not ((not cfg["nudge_re"]) or cfg["nudge_re"].fullmatch(pos[0]))', r"SEM nudge_pattern"),
    ("delivery-immediate", "w", '"delivery": _fm(r"wait-idle|queue")', '"delivery": _fm(r"immediate|wait-idle|queue")', r"delivery immediate"),
    ("surrogate-passa", "w", "and no_surrogate(a) for a in doc[\"argv\"])", "for a in doc[\"argv\"])", r"surrogate solto"),
    # --- wrapper: protocolo, identidade, ambiente
    ("chave-duplicada", "w", "if len(d) != len(pairs):", "if False:", r"chave duplicada"),
    ("identidade-casa-em-parte", "w", 'cfg["identity_re"].fullmatch(env[k])', 'cfg["identity_re"].search(env[k])', r"casa só em parte"),
    ("rig-fora-das-rotas", "w", "if d not in dirs.values():", "if False:", r"bd -C"),
    ("ambiente-do-sshd-vaza", "w", '"BEADS_ACTOR": alias, **env}', '"BEADS_ACTOR": alias, **os.environ, **env}', r"higiene"),
    ("timeout-so-o-pai", "w", "        os.killpg(p.pid, signal.SIGKILL)\n", "        p.kill()\n", r"GRUPO"),
    ("grupo-que-ja-saiu", "w", "    except ProcessLookupError:  # o grupo já não existe (filho já reapado)\n", "    except KeyError:  # o grupo já não existe (filho já reapado)\n", r"kill_group"),
    ("desfecho-calado", "w", 'say(f"aviso: não consegui gravar o desfecho ({what}) no log ({e.strerror})")', "pass", r"desfecho que não grava"),
    # --- wrapper: as guardas que o gate pediu depois (gate-fix 2 e 3 da 1.2.1): a corrida do fim-do-filho e o sinal que chega dentro do Popen
    ("kill-eperm-vivo-engolido", "w", "        if p.poll() is None:  # (o poll reapa)", "        if False:  # (o poll reapa)", r"kill_group: EPERM com o filho ainda VIVO"),
    ("kill-eperm-zumbi-levanta", "w", "        if p.poll() is None:  # (o poll reapa)", "        if True:  # (o poll reapa)", r"kill_group: grupo cujo filho SAIU"),
    ("corrida-decide-pelo-wait", "w", "if rc == -signal.SIGKILL:", "if True:", r"corrida fim-do-filho"),
    ("sinal-no-popen-sem-adiamento", "w", 'if _LAUNCH["on"]:  # Popen em curso', 'if False:  # Popen em curso', r"o log diz 'filho-encerrado'"),  # o caso "SIGTERM DENTRO do Popen" passa de propósito (143 igual): quem pega é a 2ª asserção do mesmo cenário, a do log
    ("executa-sem-rastro", "w", 'raise Refused(f"não consegui gravar o log de auditoria ({e.strerror}); não executo sem rastro")', "pass", r"não grava|NÃO executa"),
    # --- wrapper: a linha do authorized_keys
    ("sem-restrict", "w", 'opts = ["restrict"] +', "opts = [] +", r"forma:|NÃO ganha pty|NÃO encaminha"),
    ("from-com-aspas", "w", 'if frm is not None and not re.fullmatch(r"[0-9A-Za-z.:,/*?!-]{1,200}", frm):', "if False:", r"--from com aspas"),
    ("pubkey-duas-linhas", "w", "parts = lines[0].split() if len(lines) == 1 else []", "parts = lines[0].split() if lines else []", r"duas chaves|quebra de linha"),
    # --- shim (servidor)
    ("host-key-nao-conferida", "s", 'o("StrictHostKeyChecking=yes")', 'o("StrictHostKeyChecking=no")', r"StrictHostKeyChecking"),
    ("encaminha-o-ambiente-todo", "s", 'c = load_conf()\n    payload = json.dumps({"tool": tool, "argv": sys.argv[1:], "env": {k: os.environ[k] for k in FORWARD_ENV if k in os.environ}},',
     'c = load_conf()\n    payload = json.dumps({"tool": tool, "argv": sys.argv[1:], "env": dict(os.environ)},', r"pelo shim|segredo|env tem só"),
    ("session-id-encaminhado", "s", '"GC_MANAGED_SESSION_HOOK", "GC_SESSION_NAME",', '"GC_MANAGED_SESSION_HOOK", "GC_SESSION_ID", "GC_SESSION_NAME",', r"pelo shim|env tem só"),
    ("agente-encaminhado", "s", 'o("ForwardAgent=no")', 'o("ForwardAgent=yes")', r"ForwardAgent"),
    ("install-sobrescreve", "s", 'if (p.exists() or p.is_symlink()) and not (p.is_symlink() and os.readlink(p) == "remote-shim"):', "if False:", r"não sobrescreve"),
    ("pasta-da-conexao-sem-erro", "s", 'die(f"não consegui criar a pasta da conexão multiplexada ({c[\'control_dir\']}): {e.strerror}", 78)', "pass", r"pasta da conexão"),
    # --- shim: transporte por puxada (spool) — ga-w7qwl1.1
    ("spool-chave-extra", "p", 'need(not (set(c) - SPOOL_KEYS) and isinstance(c.get("spool_dir"), str)', 'need(isinstance(c.get("spool_dir"), str)', r"config recusada"),
    ("spool-prazo-sem-faixa", "p", '5 <= c["timeout_s"] <= 3600', 'c["timeout_s"] > 0', r"config recusada"),
    ("spool-modo-largo", "p", " and not st.st_mode & 0o077)", ")", r"modo 0755"),
    ("spool-link-simbolico", "p", "st = os.lstat(sp)\n        need(os.path.isdir(sp) and not os.path.islink(sp) and st.st_uid", "st = os.stat(sp)\n        need(os.path.isdir(sp) and st.st_uid", r"link simbólico"),  # a guarda é lstat+islink JUNTOS: tirar só o islink é mutante EQUIVALENTE (o modo 0777 do link já recusa)
    ("spool-sem-pump-alive", "p", "if age is None or age > ALIVE_MAX_S:", "if False:", r"sem pump.alive"),
    ("spool-alive-velho", "p", "if age is None or age > ALIVE_MAX_S:", "if age is None:", r"pump.alive velho"),
    ("spool-prazo-nao-retira", "p", "                os.unlink(req)  # ainda parado no spool", "                pass  # ainda parado no spool", r"ninguém pegou"),
    ("spool-pego-vira-75", "p", "pode ter rodado — não repita às cegas\", 125)\n                break", "pode ter rodado — não repita às cegas\", 75)\n                break", r"pedido pego e sem resposta"),
    ("spool-id-da-resposta", "p", ' and r.get("id") == rid)', ")", r"id de dentro"),
    ("spool-stdin-sem-teto", "p", "        if total > MAX_STDIN:", "        if False:", r"acima de 1 MB"),
    ("stdin-erro-calado", "p", '            die(f"não consegui ler a entrada padrão ({e.strerror}); nada foi enviado", 2)', "            break", r"entrada padrão que falha ao ler"),
    # --- a entrada padrão: lida até o EOF, só por quem a lê; silêncio não é fim (gate de ga-w7qwl1.1.1)
    ("stdin-mudo-vira-fim", "p", '                die(f"a entrada padrão não terminou (sem EOF) em {wait_s} s; nada foi enviado e nada rodou", 75)', '                return b"".join(chunks)', r"pipe aberto e mudo|escreve e não fecha"),
    ("stdin-bd-nunca-le", "p", '        return "--stdin" in argv', "        return False", r"stdin passa|produtor lento|pausa de 3 s"),
    ("stdin-bd-sempre-le", "p", '        return "--stdin" in argv', "        return True", r"bd show \(não lê a entrada\)|bd show com pipe aberto e mudo"),
    ("stdin-hook-nao-le", "p", '    return tool == "gc" and tuple(argv[:2]) in HOOK_STDIN', "    return False", r"gc prime --hook: o JSON"),
    ("stdin-gc-sempre-le", "p", '    return tool == "gc" and tuple(argv[:2]) in HOOK_STDIN', '    return tool == "gc"', r"gc mail inbox \(não lê a entrada\)"),
    ("stdin-fechada-crasha", "p", "    except (AttributeError, OSError, ValueError):  # entrada fechada", "    except (OSError, ValueError):  # entrada fechada", r"com a entrada fechada"),
    ("saida-fechada-troca-rc", "p", "        except (AttributeError, OSError, ValueError):  # saída fechada", "        except ValueError:  # saída fechada", r"saída fechada"),
    ("saida-fechada-sys-exit", "p", "    os._exit(rc)", "    sys.exit(rc)", r"saída fechada"),
    ("stdin-eof-sem-faixa", "p", 'need(type(c["stdin_eof_s"]) is int and 1 <= c["stdin_eof_s"] <= 600)', 'need(type(c["stdin_eof_s"]) is int)', r"stdin_eof_s=(0|601) recusado"),
    ("stdin-eof-aceita-bool", "p", 'need(type(c["stdin_eof_s"]) is int and 1 <= c["stdin_eof_s"] <= 600)', 'need(isinstance(c["stdin_eof_s"], int) and 1 <= c["stdin_eof_s"] <= 600)', r"stdin_eof_s=true recusado"),
    ("resposta-ilegivel-vira-nada", "p", 'die("resposta do mini ilegível; o pedido pode ter rodado — não repita às cegas", 125)', "return None", r"resposta corrompida no spool"),
    # --- o puxador e o agente do MBP (ga-w7qwl1.1)
    ("agente-spool-largo", "u", "or st.st_mode & 0o077:", "or False:", r"modo largo"),
    ("agente-nome-sem-id", "u", "            if not ID.fullmatch(rid):\n                try: os.unlink", "            if False:\n                try: os.unlink", r"nome que não é id"),
    ("agente-id-de-dentro", "u", 'isinstance(d, dict) and d.get("id") == rid and', "isinstance(d, dict) and", r"id de dentro diferente"),
    ("agente-put-sem-pego", "u", ' or not os.path.exists(sp + "/claimed/" + rid + ".json"): continue', ": continue", r"put de um id que NINGUÉM pegou"),
    ("puxador-nunca-ocioso", "u", "if time.time() - idle_since > cfg.idle_s:", "if False:", r"sai sozinho"),
    ("puxador-sem-corte", "u", "return b if len(b) <= MAX_OUT else b[:MAX_OUT] +", "return b if True else b[:MAX_OUT] +", r"cut\(\)"),
    ("puxador-argv-no-log", "u", 'self.cfg.log(f"id={rid} rc={rc} out=', 'self.cfg.log(f"cmd={cmd[:80]} id={rid} rc={rc} out=', r"não guarda argv"),  # `cmd` = PROTO + o argv em base64: o vazamento é em base64, não em texto puro (o caso tem que ver isso)
    ("puxador-stop-cego", "u", "        return 1\n    os.kill(pid, signal.SIGTERM)", "        return 0\n    os.kill(pid, signal.SIGTERM)", r"lock preso e pid ilegível"),
    ("puxador-lock-ilegivel-vira-nao", "u", "    except FileNotFoundError:\n        return False  # a pasta de estado nem existe", "    except OSError:\n        return False  # a pasta de estado nem existe", r"o lock não abre"),
    ("puxador-registro-ilegivel-vazio", "u", '            return True  # não consegui ler: não sei, e "não sei" mantém o puxador de pé', "            return False", r"registro de sessões que não lê"),
    ("puxador-flock-erro-vira-ocupado", "u", "    except BlockingIOError:\n        return True  # outro processo segura o flock", "    except OSError:\n        return True  # outro processo segura o flock", r"flock que FALHA"),
    ("puxador-serve-flock-erro-vira-ja-roda", "u", "        except BlockingIOError:\n            print(", "        except OSError:\n            print(", r"flock que FALHA"),
    ("puxador-put-ok-zero-e-entrega", "u", 'pout.split() == [b"ok", b"1"]', 'pout.startswith(b"ok")', r"flock que FALHA"),
    ("agente-open-pedido-crash", "u", "            except (OSError, ValueError) as e:\n                write_resp(rid, 78,", "            except ValueError as e:\n                write_resp(rid, 78,", r"leitura do spool que FALHA"),
    # --- a última faxina do spool no stop (ga-w7qwl1.1.7): cada guarda do reap e do desfecho, apagada, reprova o caso que a exercita
    ("agente-reap-sem-carencia", "u", "REAP_GRACE_S = 90", "REAP_GRACE_S = -86400", r"DENTRO da carência"),  # a carência some: sai também o que um puxador novo acabou de escrever
    ("puxador-stop-sem-faxina", "u", "        return reap_spool(cfg)\n", "        return 0\n", r"apaga a resposta e o claimed/ velhos"),
    ("agente-reap-listdir-erro-vira-vazio", "u", "        except FileNotFoundError: continue\n", "        except OSError: continue\n", r"agente reap: a carência"),
    ("agente-reap-apagar-que-falha-calado", "u", "            except OSError: bad += 1\n", "            except OSError: pass\n", r"velho que não sai"),
    ("agente-reap-sem-spool-vira-erro", "u", '    if mode != "reap": raise\n    print("reap sem-spool"); sys.exit(0)\n', "    raise\n", r"sem a pasta do spool no MBP"),
    ("agente-reap-cria-as-pastas", "u", 'if mode != "reap":  # a faxina de parada não cria nada no MBP', "if True:  # a faxina de parada não cria nada no MBP", r"agente reap: a carência"),
    ("puxador-faxina-falha-sai-zero", "u", '    code = 1\n    if rc == 0 and text == "reap sem-spool":', '    code = 0\n    if rc == 0 and text == "reap sem-spool":', r"ssh fora"),
    ("puxador-resposta-vazia-vira-nao-havia", "u", '    if rc == 0 and text == "reap sem-spool":', '    if text in ("", "reap sem-spool"):', r"ssh fora"),
    ("puxador-apagar-que-falha-vira-limpei", "u", '        if bad:\n            msg = f"NÃO DEU PARA LIMPAR TUDO', '        if False:\n            msg = f"NÃO DEU PARA LIMPAR TUDO', r"velho que não sai"),
    ("puxador-ssh-que-nem-lanca-estoura", "u", "    except OSError as e:  # nem consegui lançar o ssh", "    except KeyError as e:  # nem consegui lançar o ssh", r"resposta do agente que não entendo"),
    ("dolt-nao-recusa", "s", '    if name in REFUSED_TOOLS:\n        die(', '    if False:\n        die(', r"dolt pelo shim"),
    ("dolt-ligado-sem-pedir", "s", "links = TOOLS + (REFUSED_TOOLS if refuse else ())", "links = TOOLS + REFUSED_TOOLS", r"sem --refuse-dolt"),
    ("dolt-vira-pedido", "s", '    if name in REFUSED_TOOLS:\n        die(', '    if name in REFUSED_TOOLS:\n        request(name)\n    if False:\n        die(', r"dolt pelo shim"),
    ("known-hosts-opcional", "s", 'need(os.path.isfile(c["identity_file"]) and os.path.isfile(c["known_hosts_file"]))', "need(True)", r"config do shim ruim|known_hosts_file ausente"),
]


def run_one(m, tmp: Path, timeout: int):
    name, which, old, new, expect = m
    src = TARGET[which].read_text()
    if src.count(old) != 1:
        return name, "INVÁLIDO", f"o trecho aparece {src.count(old)}x (esperado 1)"
    d = tmp / name
    d.mkdir()
    mutant = d / TARGET[which].name
    mutant.write_text(src.replace(old, new, 1))
    mutant.chmod(0o755)
    env = {**os.environ, "FAILFAST": "1", ENVVAR[which]: str(mutant), "TMPDIR": str(d)}
    if which in ("p", "u"):  # o puxador procura o wrapper AO LADO de si (HERE) e o selftest conta puxadores pelo caminho: cada mutante leva o seu puxador e um link para o wrapper de verdade
        pump = mutant if which == "u" else d / "remote-shim-pump.py"
        if which == "p":
            pump.write_text((HERE / "remote-shim-pump.py").read_text())  # third-state-waiver: fonte irmão no repositório; se faltar, o list(ex.map) re-levanta e a campanha sai ≠ 0, nunca vira "mutante morto"
            pump.chmod(0o755)
        (d / "remote-shim-wrapper.py").symlink_to(HERE / "remote-shim-wrapper.py")
        env["PUMP_UNDER_TEST"] = str(pump)
    p = subprocess.Popen(["bash", str(SELFTEST[which])], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGTERM)
        p.communicate()
        return name, "ERRO", f"passou de {timeout}s"
    if p.returncode == 0:
        return name, "SOBREVIVEU", "o selftest passou com a guarda apagada"
    ignore = os.environ.get("FAILFAST_IGNORE")  # casos que reprovam por causa do AMBIENTE (ver a lib do selftest): não são "o primeiro caso que reprovou"
    first = next((ln for ln in out.splitlines() if ln.startswith("FAIL ") and not (ignore and re.search(ignore, ln))), None)
    if first is None and ignore and p.returncode == 1:
        return name, "SOBREVIVEU", "só reprovaram os casos de ambiente ignorados (FAILFAST_IGNORE)"
    if p.returncode != 1 or first is None:
        return name, "ERRO", f"exit {p.returncode} sem linha FAIL: {out[-200:]!r}"
    return name, ("MORTO" if re.search(expect, first) else "OUTRO CASO"), first[:150]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--only", default="")
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()
    only = {x for x in a.only.split(",") if x}
    todo = [m for m in MUTANTS if not only or m[0] in only]
    if only and len(todo) != len(only):
        print("--only: nome desconhecido", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="rshm.") as t, ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(lambda m: run_one(m, Path(t), a.timeout), todo))
    for name, verdict, why in res:
        print(f"{verdict:11} {name:28} {why}")
    bad = [r for r in res if r[1] != "MORTO"]
    print(f"\n{len(res) - len(bad)}/{len(res)} mortos pelo caso esperado" + (f"; {len(bad)} NÃO: {', '.join(r[0] for r in bad)}" if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
