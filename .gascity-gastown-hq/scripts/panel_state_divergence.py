#!/usr/bin/env python3
"""panel_state_divergence.py — compara o veredito do PAINEL com o do modelo canônico.

⚠️ ESTE SCRIPT JÁ MENTIU UMA VEZ. LEIA ANTES DE CONFIAR EM QUALQUER NÚMERO DAQUI.

A 1ª versão REIMPLEMENTAVA as regras de coluna do painel (lia as constantes do
arquivo-fonte e reproduzia a lógica: "sem story:* → Triagem"). Ela reportou **239
beads nas colunas que o Athos olha e que não eram dele**. O painel REAL, rodado no
mesmo instante sobre os mesmos dados, tinha **1** em Sua vez, 0 na Vez do criador,
9 na esteira e 73 em Travadas. Erro de ~240x.

A reimplementação era permissiva demais: o fetch real da Triagem passa por
`_is_automation_bead`, `_KANBAN_VISIBLE_TYPES`, filtro de status, e `_is_auto_dispatch_card`
levanta parte para APROVADAS — nada disso existia na cópia.

O erro é EXATAMENTE a doença que este script existe para diagnosticar: um
interpretador privado divergindo do consumidor real. Escrever um segundo
interpretador para auditar o primeiro só cria um terceiro. Por isso agora ele
**IMPORTA E RODA `_load_kanban()`** — a única fonte que não pode divergir do painel,
porque é o painel.

REGRA GERAL QUE FICA: para auditar um consumidor, EXECUTE o consumidor. Se você
precisou reescrever a lógica dele para medi-la, você está medindo a sua reescrita.

USO:  python3 panel_state_divergence.py
"""
import subprocess
import sys

PANEL_DIR = "/Users/athos/gt/whatsapp_automation"
sys.path.insert(0, "/Users/athos/gt/.gascity-gastown-hq/scripts")
sys.path.insert(0, PANEL_DIR + "/daemons")

from bead_state import derive  # noqa: E402

CREWS = frozenset({"batista-wa", "digo-wa", "mila-wa", "oracle-wa", "peter-wa",
                   "thies-wa", "batista-ps", "batista-lx", "mayor"})

# Colunas que o HUMANO olha esperando que sejam trabalho DELE.
HUMAN_COLUMNS = ("sua:vez",)


def live_sessions() -> frozenset:
    try:
        out = subprocess.run(["tmux", "-L", "gascity", "ls"], capture_output=True,
                             text=True, timeout=20).stdout
        return frozenset(l.split(":")[0] for l in out.splitlines() if l.strip())
    except Exception:
        # Erro ≠ vazio: sem a lista de sessões, "detentor vivo" é indeterminado e o
        # modelo classificaria trabalho vivo como abandonado. Aborta em vez de medir
        # errado — um número errado aqui é pior que nenhum número.
        print("ERRO: não consegui listar as sessões vivas. Sem isso a derivação de "
              "'executing' vs 'stranded' é inválida. Abortando.", file=sys.stderr)
        raise SystemExit(2)


def main():
    import painel_visibilidade as pv

    print("modelo canônico carregado no painel:",
          "SIM" if getattr(pv, "_CANONICAL_STATE_FN", None) else "NÃO (painel roda label-driven)")
    board, degraded = pv._load_kanban()
    if degraded:
        print("⚠️  buckets degradados nesta leitura (números parciais):", degraded)
    if not board:
        print("ERRO: _load_kanban devolveu vazio — isso é falha da leitura, não "
              "'quadro vazio'. Abortando.", file=sys.stderr)
        raise SystemExit(2)

    live = live_sessions()
    print("\n%-22s %5s" % ("COLUNA DO PAINEL", "n"))
    print("-" * 30)
    for key, cards in board.items():
        if isinstance(cards, list):
            print("%-22s %5d" % (key, len(cards)))

    print("\nDIVERGÊNCIA por coluna (o que o painel põe ali × de quem o modelo diz que é a vez)")
    print("-" * 78)
    for key, cards in board.items():
        if not isinstance(cards, list) or not cards:
            continue
        if key in ("story:done", "story:cancelled"):
            continue
        buckets = {}
        for c in cards:
            st = derive(c, live, CREWS)
            buckets.setdefault((st["state"], st["turn"]), []).append(c.get("id"))
        for (state, turn), ids in sorted(buckets.items(), key=lambda x: -len(x[1])):
            print("  %-20s %-20s vez=%-10s %4d  %s"
                  % (key, state, turn, len(ids), ", ".join(i for i in ids[:3] if i)))

    # O achado que importa: card na coluna DELE que o modelo não atribui a ele.
    print()
    bad = []
    for key in HUMAN_COLUMNS:
        for c in board.get(key, []):
            st = derive(c, live, CREWS)
            if st["turn"] != "athos":
                bad.append((key, c.get("id"), st["state"], st["turn"], st["actions"]))
    if not bad:
        print("✅ nenhuma bead na coluna do Athos que não seja dele.")
    else:
        print("⭐ NA COLUNA DO ATHOS E NÃO É DELE: %d" % len(bad))
        for key, i, state, turn, acts in bad:
            print("   %-10s %-14s modelo=%-18s vez=%-8s acoes=%s" % (key, i, state, turn, acts))


if __name__ == "__main__":
    main()
