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
SELFTEST = {"w": HERE / "remote-shim.selftest.sh", "s": HERE / "remote-shim-client.selftest.sh"}  # cada mutante roda no selftest do arquivo que ele altera
TARGET = {"w": HERE / "remote-shim-wrapper.py", "s": HERE / "remote-shim.py"}
ENVVAR = {"w": "WRAPPER_UNDER_TEST", "s": "SHIM_UNDER_TEST"}

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
    p = subprocess.Popen(["bash", str(SELFTEST[which])], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGTERM)
        p.communicate()
        return name, "ERRO", f"passou de {timeout}s"
    if p.returncode == 0:
        return name, "SOBREVIVEU", "o selftest passou com a guarda apagada"
    first = next((ln for ln in out.splitlines() if ln.startswith("FAIL ")), None)
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
