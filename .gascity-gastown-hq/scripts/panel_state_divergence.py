#!/usr/bin/env python3
"""panel_state_divergence.py — compara o veredito do PAINEL com o do modelo canônico.

Este é o passo que precede a migração do painel para scripts/bead_state.py: antes de
trocar o interpretador, MEDIR onde os dois discordam e exigir justificativa por
divergência. Migração sem esta medição seria trocar um interpretador não-verificado
por outro não-verificado.

O lado "painel" é reimplementado FIELMENTE a partir das constantes do próprio
painel_visibilidade.py (LIFECYCLE_STAGES, _SUAVEZ_LABELS, _TRIAGEM_KEY) — lidas do
arquivo, não de memória. Se elas mudarem, este script precisa ser re-derivado; por isso
ele imprime as constantes que usou, para o leitor conferir contra a fonte.

USO:  python3 panel_state_divergence.py
"""
import json
import re
import subprocess
import sys

PANEL = "/Users/athos/gt/whatsapp_automation/daemons/painel_visibilidade.py"
sys.path.insert(0, "/Users/athos/gt/.gascity-gastown-hq/scripts")
from bead_state import derive  # noqa: E402

STORES = (
    "/Users/athos/gt/whatsapp_automation",
    "/Users/athos/gt/.gascity-gastown-hq",
    "/Users/athos/gt/property_scrapers",
)


def panel_constants():
    """Lê as constantes de coluna DO ARQUIVO do painel — não hardcode."""
    src = open(PANEL, encoding="utf-8").read()
    stages = re.findall(r'\(\s*"(story:[a-z-]+)",\s*"([^"]+)"\)', src)
    suavez = set(re.findall(r'_SUAVEZ_APPROVAL_LABEL = "([^"]+)"', src))
    suavez |= set(re.findall(r'_SUAVEZ_ESCALATED_LABELS = frozenset\(\{([^}]*)\}', src)[0]
                  .replace('"', "").replace(" ", "").split(",")) if re.findall(
        r'_SUAVEZ_ESCALATED_LABELS = frozenset\(\{([^}]*)\}', src) else set()
    return dict(stages), {s for s in suavez if s}


def panel_column(bead, stages, suavez):
    """Coluna que o painel atribui, pelas regras dele."""
    L = set(bead.get("labels") or [])
    if L & suavez:
        return "Sua vez"
    for lbl, col in stages.items():
        if lbl in L:
            return col
    if not any(l.startswith("story:") for l in L):
        return "Triagem"
    return "(nenhuma)"


def main():
    stages, suavez = panel_constants()
    print("CONSTANTES LIDAS DO PAINEL (confira contra a fonte):")
    print("  Sua vez  ←", sorted(suavez))
    for k, v in stages.items():
        print("  %-24s → %s" % (k, v))
    live = set()
    try:
        out = subprocess.run(["tmux", "-L", "gascity", "ls"], capture_output=True,
                             text=True, timeout=20).stdout
        live = {l.split(":")[0] for l in out.splitlines() if l.strip()}
    except Exception:
        pass
    crews = {"batista-wa", "digo-wa", "mila-wa", "oracle-wa", "peter-wa",
             "thies-wa", "batista-ps", "batista-lx", "mayor"}
    beads = {}
    for s in STORES:
        p = subprocess.run(["bd", "-C", s, "list", "--all", "--json", "--limit", "0"],
                           capture_output=True, text=True, timeout=90)
        try:
            for b in json.loads(p.stdout):
                if b.get("status") != "closed":
                    beads[b.get("id")] = b
        except Exception:
            pass

    div = {}
    for i, b in sorted(beads.items()):
        col = panel_column(b, stages, suavez)
        st = derive(b, frozenset(live), frozenset(crews))
        key = (col, st["state"], st["turn"].split(":")[0])
        div.setdefault(key, []).append(i)

    print("\n%-12s %-22s %-9s %5s  exemplos" % ("PAINEL", "MODELO(state)", "vez de", "n"))
    print("-" * 78)
    for (col, state, turn), ids in sorted(div.items(), key=lambda x: -len(x[1])):
        print("%-12s %-22s %-9s %5d  %s" % (col, state, turn, len(ids), ", ".join(ids[:3])))

    # O achado que importa pro Athos: o que ELE vê e que não é dele.
    not_his = [i for (col, state, turn), ids in div.items()
               if col in ("Sua vez", "Triagem") and turn != "athos" for i in ids]
    his = [i for (col, state, turn), ids in div.items() if turn == "athos" for i in ids]
    print("\n⭐ nas colunas que o Athos olha (Sua vez + Triagem) e que NÃO são dele: %d"
          % len(not_his))
    print("⭐ que o modelo diz serem DELE: %d %s" % (len(his), his or ""))


if __name__ == "__main__":
    main()
