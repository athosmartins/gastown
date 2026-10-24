#!/usr/bin/env python3
"""inflight-reclaim-guard.mbp.mutants.py — controle negativo do inflight-reclaim-guard.mbp.selftest.sh (ga-w7qwl1.2.3).

Contents
  O que faz · Como roda · Saída

O QUE FAZ: cada mutante troca UM trecho do guard numa CÓPIA (o original nunca é tocado) e roda o selftest do MBP contra a cópia; o selftest tem de reprovar. Mutante que sobrevive quer dizer que um
  caso do selftest não prende a guarda que ele diz prender. O trecho trocado tem de aparecer EXATAMENTE uma vez no guard (senão o executor para: o guard mudou e o mutante ficou velho).
COMO RODA: python3 -I scripts/inflight-reclaim-guard.mbp.mutants.py   (o selftest chama este executor ao fim, a menos que MBP_GUARD_ST_NOMUT=1; ~15 s)
SAÍDA: uma linha por mutante (morto / SOBREVIVEU) e `MUTANTES: <mortos>/<total> mortos`; exit 0 só com todos mortos.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.environ.get("MBP_MUTANTS_GUARD") or os.path.join(HERE, "inflight-reclaim-guard.py")   # o selftest aponta para um caminho inexistente para provar o FATAL
SELFTEST = os.path.join(HERE, "inflight-reclaim-guard.mbp.selftest.sh")

# (nome, trecho antigo, trecho novo)
MUTANTS = [
    ("hold-desligado",
     '        has_mbp_hold = mbp_state == "hold"\n',
     '        has_mbp_hold = False\n'),
    ("hold-nao-chega-na-decisao",
     '        if has_mbp_hold:\n            has_suspended_owner = True\n',
     '        if has_mbp_hold:\n            pass\n'),
    ("sempre-hold-nunca-gone",
     '        mbp_state = mbp_owner_state(assignee, sessions)\n',
     '        mbp_state = "hold" if is_mbp_node_alias(assignee) else None\n'),
    ("gone-vira-hold",
     '            return "hold"\n    return "gone"\n',
     '            return "hold"\n    return "hold"\n'),
    ("roster-vazio-vira-gone",
     '    if not sessions:\n        return "hold"   # roster vazio não prova ausência\n',
     ''),
    ("relogio-nunca-zera",
     '            bead_state.pop("mbp_hold_since", None)\n            bead_state.pop("mbp_hold_alerted_at", None)\n',
     '            pass\n'),
    ("relogio-ignora-sessao-saudavel",
     '        if has_mbp_hold and not has_live_session:\n',
     '        if has_mbp_hold:\n'),
    ("aviso-a-cada-varredura",
     '            if (now - _hold_since) >= _hold_every and (now - bead_state.get("mbp_hold_alerted_at", 0)) >= _hold_every:\n',
     '            if (now - _hold_since) >= _hold_every:\n'),
    ("aviso-nunca",
     '            _hold_every = _mbp_hold_alert_secs()\n',
     '            _hold_every = 10 ** 12\n'),
    ("reclaim-nao-leva-a-marca",
     '                             unset_metadata=(MBP_NODE_MARK_KEYS if is_mbp_node_alias(assignee) else ()))',
     '                             unset_metadata=())'),
    ("marca-sai-de-toda-bead",
     '                             unset_metadata=(MBP_NODE_MARK_KEYS if is_mbp_node_alias(assignee) else ()))',
     '                             unset_metadata=MBP_NODE_MARK_KEYS)'),
    ("marca-sai-antes-do-dono",
     '    # 2b. Clear assignee so Pilot can claim it fresh.\n    try:\n',
     '    for _mk0 in (unset_metadata or ()):\n        subprocess.run(_bd + ["update", bead_id, "--unset-metadata", _mk0, "-q"], capture_output=True, text=True, timeout=15)\n'
     '    # 2b. Clear assignee so Pilot can claim it fresh.\n    try:\n'),
    ("do_reclaim-ignora-unset_metadata",
     '    for _mk in _marks_to_unset:\n        try:\n',
     '    for _mk in ():\n        try:\n'),
    ("marca-sai-mesmo-sem-o-dono-sair",
     '    _marks_to_unset = tuple(unset_metadata or ()) if _owner_cleared else ()\n',
     '    _marks_to_unset = tuple(unset_metadata or ())\n'),
    ("dono-saiu-por-padrao",
     '    _owner_cleared = False\n    # 2b. Clear assignee so Pilot can claim it fresh.\n',
     '    _owner_cleared = True\n    # 2b. Clear assignee so Pilot can claim it fresh.\n'),
    ("comentario-sempre-assignee-unset",
     '("assignee unset" if _owner_cleared else\n',
     '("assignee unset" if True else\n'),
    ("regex-sem-ancora",
     'MBP_NODE_ALIAS_RE = re.compile(r"^wa-worker-remote-mbp-[1-9]$")',
     'MBP_NODE_ALIAS_RE = re.compile(r"wa-worker-remote-mbp-[1-9]")'),
]


def main():
    # vazio → o guard sem texto não tem trecho de mutante: o `count` abaixo dá 0 e para com FATAL; falhou/ilegível (arquivo que não abre, pasta que não lista) → FATAL rc 2, nunca "0 mutantes, todos mortos"
    try:
        with open(GUARD, encoding="utf-8") as f:
            text = f.read()
        siblings = [e for e in os.listdir(HERE) if e != "inflight-reclaim-guard.py"]   # os irmãos (bead_state.py, gc_ledger.py, ...) por link: o guard os importa pelo diretório dele
    except OSError as exc:
        print("FATAL: não consegui ler o guard (%s) ou a pasta dos irmãos: %s" % (GUARD, exc))
        return 2
    killed = 0
    for name, old, new in MUTANTS:
        n = text.count(old)
        if n != 1:
            print("FATAL: o trecho do mutante %s aparece %d vezes no guard (esperava 1): o mutante ficou velho" % (name, n))
            return 2
        tmp = tempfile.mkdtemp(prefix="irg-mbp-mut.")
        try:
            for entry in siblings:
                os.symlink(os.path.join(HERE, entry), os.path.join(tmp, entry))
            copy = os.path.join(tmp, "inflight-reclaim-guard.py")
            with open(copy, "w", encoding="utf-8") as f:
                f.write(text.replace(old, new))
            env = dict(os.environ, MBP_GUARD_UNDER_TEST=copy, MBP_GUARD_ST_NOMUT="1")
            r = subprocess.run(["bash", SELFTEST], env=env, capture_output=True, text=True, timeout=120)
            fails = [ln for ln in r.stdout.splitlines() if ln.startswith("FAIL")]
            if r.returncode != 0:
                killed += 1
                print("mutante %-34s morto (%d FAIL%s)" % (name, len(fails), (": " + fails[0][5:75]) if fails else ", sem linha FAIL: rc=%d" % r.returncode))
            else:
                print("mutante %-34s SOBREVIVEU" % name)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    print("MUTANTES: %d/%d mortos" % (killed, len(MUTANTS)))
    return 0 if killed == len(MUTANTS) else 1


if __name__ == "__main__":
    sys.exit(main())
