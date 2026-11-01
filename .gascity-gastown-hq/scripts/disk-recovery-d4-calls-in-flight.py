#!/usr/bin/python3
"""disk-recovery-d4-calls-in-flight.py — há ligação EM CURSO agora? (ga-1p1i5jr.4, guarda do D4)

## Contents
  Por que existe · Contrato (saída e exit code) · O que conta como "em curso" · Órfãs · Costuras de teste

POR QUE EXISTE. O reinício guardado do mini (D4 da escada de disco) não pode cortar uma ligação:
a decisão do Athos (01/11) foi "só sem ligação em curso nem envio em voo". As duas funções que
a cidade já tem pra isso — `pix_call_queue.live_calls()` e `voicebot.call_log.live_calls()` —
devolvem `[]` em QUALQUER erro (banco ausente, travado, tabela faltando): pra quem quer SABER se
pode reiniciar, "não consegui ler" e "não há ligação" viram o mesmo valor, e o reinício sairia
exatamente quando o guarda estava cego. Além disso `pix_call_queue._ensure()` CRIA tabela (escrita)
a cada leitura. Este script lê os mesmos dois bancos, só com SELECT, e responde em TRÊS estados.

COMO ABRE O BANCO (medido ao vivo em 01/11, 34 de 40 leituras falharam com a primeira versão). Os dois bancos são WAL. Uma conexão
`mode=ro` num banco WAL NÃO consegue abrir quando nenhum outro processo o mantém aberto (não há -shm/-wal e ela não pode criá-los):
"unable to open database file". Como os apps abrem e fecham a conexão a cada operação, isso acontecia na maior parte do tempo — o
guarda ficaria cego e o D4 nunca reiniciaria. Por isso abre com `mode=rw` (NÃO `rwc`: banco que não existe continua sendo erro, em vez
de ser criado vazio) e liga `PRAGMA query_only=ON` (o SQLite recusa qualquer escrita de dado). O efeito colateral é o que qualquer
cliente destes bancos já tem: num banco WAL sem outro leitor o SQLite cria o -shm/-wal (o python do sistema, SQLite 3.51, os DEIXA
depois de fechar, vazios — medido; os apps, com outro build, os removem). Nenhum dado é alterado. `immutable=1` está
descartado de propósito: ignora o -wal e leria dado velho justamente quando há escritor ativo (as linhas mais novas estão no -wal).

CONTRATO. Uma linha no stdout, `<estado>\\t<detalhe>`, e o exit code diz o mesmo (pensado pra `case`):
    0  ok       leu os dois bancos e não há ligação em curso
    1  block    há ligação em curso (detalhe diz quantas e onde)
    2  unknown  não consegui ler pelo menos um banco e nenhum mostrou ligação em curso
  `block` vence `unknown`: uma ligação provada em curso basta pra segurar o reinício, não importa
  o que o outro banco respondeu. `unknown` NUNCA é `ok`: o chamador não reinicia.
  Erro de uso (argumento) → exit 64.

O QUE CONTA COMO "EM CURSO".
  · pix  (demand_assignments.db, tabela pix_call_log): state IN ('dialing','bridged') — os dois
    estados NÃO terminais (`reset_stuck_dialing` os trata como "ligação viva ou órfã"). `ended_at
    IS NULL` NÃO serve: estados terminais antigos (answered_talked...) também têm ended_at nulo.
  · voicebot (voicebot_cost.db, tabela voicebot_call_log): status = 'live'.
  Uma linha sem `started_at` legível conta como EM CURSO (não dá pra provar que é órfã).

ÓRFÃS. Um processo que morre no meio deixa a linha em 'dialing'/'bridged'/'live' pra sempre
(até o `reset_stuck_dialing` do próximo start do motor). Se contássemos pra sempre, uma linha
esquecida seguraria o reinício indefinidamente e o disco morreria esperando. Linha com
`started_at` mais velho que --max-age-min (padrão 240 = 4 h; nenhuma ligação de discador dura
isso) é ÓRFÃ: não segura, mas é CONTADA no detalhe ("N órfã(s) ignorada(s)") pra não sumir em
silêncio. O corte compara `started_at` (texto, hora local) com `datetime('now','localtime')`:
se o relógio de quem gravou for outro (VM em UTC), a linha parece mais NOVA do que é e conta
como em curso por mais tempo — erra pro lado de NÃO reiniciar.

COSTURAS DE TESTE. --pix-db / --vb-db apontam pros bancos (padrão: PIX_CALL_QUEUE_DEMAND_DB ou
CLIENTES_DB, senão <whatsapp_automation>/shared/data/demand_assignments.db; VOICEBOT_COST_DB,
senão <whatsapp_automation>/shared/data/voicebot_cost.db). Sem import de nenhum módulo do repo
WA (eles têm efeito colateral no import).
"""
import argparse
import os
import sqlite3
import sys

WA = os.environ.get("DR4_WA_DIR", "/Users/athos/gt/whatsapp_automation")

OK, BLOCK, UNKNOWN = 0, 1, 2
LABEL = {OK: "ok", BLOCK: "block", UNKNOWN: "unknown"}


def _default_pix():
    return (os.environ.get("PIX_CALL_QUEUE_DEMAND_DB")
            or os.environ.get("CLIENTES_DB")
            or os.path.join(WA, "shared", "data", "demand_assignments.db"))


def _default_vb():
    return os.environ.get("VOICEBOT_COST_DB") or os.path.join(WA, "shared", "data", "voicebot_cost.db")


def _count(db, table, where, max_age_min, label):
    """(estado, detalhe) de UMA fonte. Banco/tabela/coluna que não dá pra ler = UNKNOWN, nunca OK."""
    # vazio → OK (leu e não há linha em curso); falhou/ilegível → UNKNOWN (o chamador não reinicia)
    if not os.path.isfile(db):
        return UNKNOWN, "%s: banco ausente (%s)" % (label, db)
    try:
        con = sqlite3.connect("file:%s?mode=rw" % db, uri=True, timeout=10)
    except sqlite3.Error as e:
        return UNKNOWN, "%s: não abri o banco (%s: %s)" % (label, type(e).__name__, e)
    try:
        con.execute("PRAGMA query_only=ON")
        has = con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone()
        if not has:
            return UNKNOWN, "%s: tabela %s ausente em %s" % (label, table, db)
        threshold = "-%d minutes" % max_age_min
        # NULL em started_at conta como EM CURSO: sem data não há como provar que é órfã
        live = con.execute(
            "SELECT COUNT(*) FROM %s WHERE %s AND (started_at IS NULL OR started_at >= datetime('now','localtime', ?))"
            % (table, where), (threshold,)).fetchone()[0]
        old = con.execute(
            "SELECT COUNT(*) FROM %s WHERE %s AND started_at IS NOT NULL AND started_at < datetime('now','localtime', ?)"
            % (table, where), (threshold,)).fetchone()[0]
    except sqlite3.Error as e:
        return UNKNOWN, "%s: erro lendo %s (%s: %s)" % (label, table, type(e).__name__, e)
    finally:
        con.close()
    note = ", %d órfã(s) ignorada(s) (> %d min)" % (old, max_age_min) if old else ""
    if live:
        return BLOCK, "%s: %d ligação(ões) em curso%s" % (label, live, note)
    return OK, "%s: nenhuma ligação em curso%s" % (label, note)


def main(argv=None):
    ap = argparse.ArgumentParser(description="há ligação em curso? (somente leitura, 3 estados)")
    ap.add_argument("--pix-db", default=None)
    ap.add_argument("--vb-db", default=None)
    ap.add_argument("--max-age-min", type=int, default=240)
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 64 if e.code else 0
    if a.max_age_min < 1:
        print("unknown\t--max-age-min deve ser >= 1")
        return 64
    results = [
        _count(a.pix_db or _default_pix(), "pix_call_log", "state IN ('dialing','bridged')", a.max_age_min, "pix"),
        _count(a.vb_db or _default_vb(), "voicebot_call_log", "status = 'live'", a.max_age_min, "voicebot"),
    ]
    states = [r[0] for r in results]
    state = BLOCK if BLOCK in states else (UNKNOWN if UNKNOWN in states else OK)
    print("%s\t%s" % (LABEL[state], "; ".join(r[1] for r in results)))
    return state


if __name__ == "__main__":
    sys.exit(main())
