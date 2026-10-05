#!/usr/bin/env python3
"""bead-token-meter.selftest.py — ga-5c3msy: a ferramenta que MEDE tokens por bead tem que estar certa, senão a decisão modelo/effort
(US$ por bead aprovada) vira número sem lastro. Hermético: fixtures sintéticas, ledger/gate/projetos/aws em diretórios temporários.

Cada caso existe por um erro real que a medição já teve (01/10, nos 1.783 transcritos locais) ou poderia ter:
  * dedup por message.id: o Claude Code grava UM registro por bloco (thinking/text/tool_use) e todos repetem o `usage` — 512 registros
    para 187 respostas num worker; somar linhas inflaria o gasto ~2,7x (e o dedup tem que valer ENTRE o transcrito e o de subagente)
  * preço: escrita de cache 5m (1,25x) e 1h (2x) e leitura (0,1x) conferidos à mão; modelo SEM preço = None, nunca US$ 0
  * <synthetic> (resposta do cliente, uso 0 ou lixo) não é chamada de modelo
  * bead de um worker = claim COM resultado ok; claim que falhou não conta; id citado no preâmbulo (93 ids de doutrina) não é bead;
    sessão de pool sem claim e sem referência = spawn OCIOSO (custo real, linha própria); worker com bead já atribuído (sem claim) cai
    no fallback por referência; crew (sessão conversacional) NÃO ganha bead por referência
  * revisor: o cabeçalho da tarefa chega dentro de um tool_result e pode vir um EXEMPLO de doutrina antes — resolve pelo ramo que o gate conhece
  * janela por DIA DA MENSAGEM (sessão que cruza a meia-noite), não por início de sessão
  * ledger: idempotente, crescente, sobrevive à remoção do transcrito, "o registro com mais mensagens vence", lock de instância única
  * backfill-s3: erro do aws != lista vazia; falha de download é contada e devolvida (nunca silenciosa); guarda de disco; fora de escopo
  * terceiro estado: sem ledger / sem log do gate = "SEM DADO" (exit 2), nunca zeros
  * varredura do terceiro estado (gate-done): spawn ocioso em modelo sem preço mostra os tokens sem preço em vez de US$ 0; revisor sem ramo
    conta SESSÕES; veredito do gate sem bead é linha ilegível contada (não derruba o relatório); claim sem timestamp é contado; linha
    ilegível do ledger é guardada antes da reescrita
  * 3º estado "sem preço" no relatório TODO, não só nas seções 1-2 (gate-fix 1): bead com qualquer token sem preço = custo n/p (nunca a
    soma parcial, que é um piso); coorte só sobre os beads com preço e razão por aprovada n/p; sistema inteiro = piso rotulado com o
    US$ por aprovada null no JSON; CV da seção 6 só sobre beads com preço (quantos, impresso) e n/p — não nan — quando não há; e uma
    seção que estoura não leva embora as já prontas (exit 1, texto e --json). Mais os achados baixos da mesma família: claim sem
    resultado ≠ verificado, veredito sem dry_run ≠ ensaio, resposta sem timestamp contada e avisada
  * 4 estados de um claim (gate-fix 2): ok / failed / unconfirmed (resultado VISÍVEL que não confirma: heredoc, echo, saída cortada — NÃO é claim
    e não abre bucket) / noresult (nenhum resultado: conta, sinalizado); dois claims num comando têm um tool_use id só e cada um recebe o seu estado
  * irmãos da mesma classe achados na varredura do diff inteiro (gate-fix 2): sessão de pool com claim NÃO confirmado não é spawn ocioso (como a sem
    timestamp); JSON válido que não é registro (`null`, string, lista) é linha ilegível CONTADA, não AttributeError; queda maior que a taxa na
    seção 6 é n/a, não '0 beads por braço'; o texto da atribuição lista todos os verbos de REF_CMD
  * ramo do revisor no cabeçalho QUEBRADO em ~80 colunas pelo `gc bd show` (gate-fix 4): as fixtures são o formato real (continuação indentada e
    preenchida, e a leitura por `cat -n`), não o cabeçalho de uma linha só que os casos antigos usavam; quebra ambígua guarda os dois candidatos
    e a ponte do gate escolhe; uma linha v=3 com o ramo truncado é reescaneada (SCHEMA 4)
  * transcrito que EXISTE mas não abre (gate-fix 4): só FileNotFoundError é "sumiu no meio"; permissão/I-O é entrada ilegível (alarme + exit 6),
    no `stat` do filtro de janela e na abertura, e a colheita segue com as outras sessões; o backfill-s3 conta e nomeia a falha
  * controles de mutação: cada mutante do script (tabela MUTANTS) tem que ser reprovado por pelo menos um caso (o teste que só passa não prova nada);
    o número de casos e de mutantes vem da própria saída — não é repetido aqui para não envelhecer
"""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
import shutil
import stat
import statistics
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / "bead-token-meter.py"
PASS = FAIL = 0


class Fail(Exception):
    pass


def ck(cond, msg):
    if not cond:
        raise Fail(msg)


def approx(a, b, tol=1e-9):
    return a is not None and abs(a - b) <= tol


def load(src_path=None, source=None, name="btm"):
    src = source if source is not None else Path(src_path or TOOL).read_text()
    spec = importlib.util.spec_from_loader(name, loader=None)
    mod = importlib.util.module_from_spec(spec)
    mod.__file__ = str(TOOL)
    exec(compile(src, str(TOOL), "exec"), mod.__dict__)
    return mod


# ----------------------------------------------------------------------------- fixtures
U_SMALL = dict(input_tokens=10, output_tokens=20, cache_creation_input_tokens=30, cache_read_input_tokens=40)   # 100 tokens, US$ 0.000303 (sonnet-5-5)
USD_SMALL = (10 * 2 + 20 * 10 + 30 * 2 * 1.25 + 40 * 2 * 0.1) / 1e6
U_BIG = dict(input_tokens=1000, output_tokens=2000, cache_creation_input_tokens=7000, cache_read_input_tokens=5000,
             cache_creation={"ephemeral_5m_input_tokens": 3000, "ephemeral_1h_input_tokens": 4000})
USD_BIG_SONNET = (1000 * 2 + 2000 * 10 + 3000 * 2 * 1.25 + 4000 * 2 * 2 + 5000 * 2 * 0.1) / 1e6      # 0.0465 (calculado à mão)


def user(text, ts, content=None):
    return {"type": "user", "timestamp": ts, "cwd": "/x", "message": {"role": "user", "content": text if content is None else content}}


def tool_result(tid, text, ts, is_error=False):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tid, "content": text, "is_error": is_error}]}}


def asst(mid, ts, usage=None, model="claude-sonnet-5-5", effort="xhigh", cmd=None, tid=None, blocks=3):
    """UMA resposta da API = `blocks` registros com o MESMO message.id e o mesmo usage (o layout real do Claude Code)."""
    content = [[{"type": "thinking", "thinking": ""}], [{"type": "text", "text": "ok"}]]
    tool = [{"type": "tool_use", "id": tid or f"toolu_{mid}", "name": "Bash", "input": {"command": cmd or "true"}}]
    shapes = (content + [tool])[-blocks:] if blocks <= 3 else content + [tool]
    return [{"type": "assistant", "timestamp": ts, "effort": effort, "perTurnEffort": effort, "message": {
        "id": mid, "model": model, "usage": dict(usage or U_SMALL), "content": b}} for b in shapes]


def write_session(root, proj, sid, records, subagents=None):
    d = Path(root) / proj
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{sid}.jsonl").write_text("\n".join(json.dumps(r, separators=(",", ":")) for r in records) + "\n")   # compacto, como o Claude Code grava
    for name, recs in (subagents or {}).items():
        sd = d / sid / "subagents"
        sd.mkdir(parents=True, exist_ok=True)
        (sd / f"{name}.jsonl").write_text("\n".join(json.dumps(r, separators=(",", ":")) for r in recs) + "\n")


def beacon(alias, ts, extra=""):
    return user(f"[gascity] {alias} • {ts}\n\n# role\nsee ga-doct1 ga-doct2 ga-doct3 {extra}", ts)


D = "2026-09-30T"
GATE_EVENTS = [
    {"ts": D + "09:00:00Z", "event": "guard_queued", "branch": "feat/ga-aaa1", "bead": "ga-aaa1", "rig": "gascity"},
    {"ts": D + "11:00:00Z", "event": "dispatcher_complete", "branch": "feat/ga-aaa1", "bead": "ga-aaa1", "rig": "gascity", "result": "PASS", "dry_run": "0"},
    {"ts": D + "11:00:00Z", "event": "dispatcher_complete", "branch": "feat/ga-bbb2", "bead": "ga-bbb2", "rig": "gascity", "result": "FAIL", "dry_run": "0"},
    {"ts": D + "12:00:00Z", "event": "dispatcher_complete", "branch": "feat/ga-bbb2", "bead": "ga-bbb2", "rig": "gascity", "result": "PASS", "dry_run": "0"},
    {"ts": D + "11:30:00Z", "event": "dispatcher_complete", "branch": "crew/wa-worker/wa-zzz1", "bead": "wa-zzz1", "rig": "whatsapp_automation", "result": "PASS", "dry_run": "0"},
    {"ts": D + "11:40:00Z", "event": "dispatcher_complete", "branch": "feat/ga-dry9", "bead": "ga-dry9", "rig": "gascity", "result": "PASS", "dry_run": "1"},   # dry-run: fora
]


def build_world(W):
    """Sessões de todos os papéis + log do gate. -> dict(projects, gate, ledger)."""
    P, proj = W / "projects", "-proj"
    # ---- dog: preâmbulo com ids de doutrina; 1 msg antes do claim, claim A ok, claim B ok, claim C que FALHA
    recs = [beacon("gastown.dog-1", D + "10:00:00.000Z")]
    recs += asst("m1", D + "10:00:00.500Z")
    recs += asst("m2", D + "10:00:10.000Z", cmd="gc bd update ga-aaa1 --claim", tid="tu_a")
    recs += [tool_result("tu_a", "warning: pack differs\n✓ Updated issue: ga-aaa1 — build", D + "10:00:11.000Z")]
    recs += asst("m3", D + "10:01:00.000Z")
    recs += asst("m4", D + "10:02:00.000Z", cmd="bd update ga-bbb2 --claim", tid="tu_b")
    recs += [tool_result("tu_b", "✓ Updated issue: ga-bbb2 — build", D + "10:02:01.000Z")]
    recs += asst("m5", D + "10:03:00.000Z")
    recs += asst("m6", D + "10:04:00.000Z", cmd="bd update ga-ccc3 --claim", tid="tu_c")
    recs += [tool_result("tu_c", "Error: issue ga-ccc3 already claimed by someone", D + "10:04:01.000Z", is_error=True)]
    recs += asst("m7", D + "10:05:00.000Z")
    write_session(P, proj, "dog1", recs)
    # ---- revisor do gate: exemplo de doutrina (ramo placeholder) ANTES da tarefa real, ambos dentro de tool_results
    recs = [beacon("gate-reviewer-adhoc-xyz", D + "11:00:00.000Z")]
    recs += asst("r1", D + "11:00:05.000Z", cmd="gc bd show ga-ver1", tid="tu_r")
    recs += [tool_result("tu_r", "QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: crew/peter/wa-\nexample only", D + "11:00:06.000Z")]
    recs += [tool_result("tu_r2", "QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: feat/ga-aaa1\nBranch SHA: abc", D + "11:00:07.000Z")]
    recs += asst("r2", D + "11:00:30.000Z")
    write_session(P, proj, "rev1", recs)
    # ---- ps-worker OCIOSO: só preâmbulo, sondou a fila e saiu
    write_session(P, proj, "ps1", [beacon("ps-worker", D + "08:00:00.000Z")] + asst("p1", D + "08:00:05.000Z", cmd="bd ready --assignee x"))
    # ---- wa-worker com bead JÁ atribuído (sem claim): 3 referências a wa-zzz1, 1 a outro bead
    recs = [beacon("wa-worker-adhoc-abc123", D + "10:30:00.000Z")]
    recs += asst("w1", D + "10:30:05.000Z", cmd="bd show wa-zzz1", tid="tu_w1")
    recs += asst("w2", D + "10:31:00.000Z", cmd="bd comments wa-zzz1; bd show ga-other", tid="tu_w2")
    recs += asst("w3", D + "10:32:00.000Z", cmd="bd comment wa-zzz1 'feito'", tid="tu_w3")
    write_session(P, proj, "wa1", recs)
    # ---- crew conversacional: refere beads mas NÃO é atribuída por referência
    recs = [beacon("peter-wa", D + "10:00:00.000Z")] + asst("c1", D + "10:00:10.000Z", cmd="bd show wa-yyy1 && bd show wa-yyy1 && bd show wa-yyy1")
    write_session(P, proj, "crew1", recs)
    # ---- mayor cruzando a meia-noite (janela por dia da MENSAGEM) + modelo sem preço + <synthetic> com lixo
    recs = [beacon("gastown.mayor", "2026-09-29T23:50:00.000Z")]
    recs += asst("y1", "2026-09-29T23:59:00.000Z", usage=U_SMALL)
    recs += asst("y2", "2026-09-30T00:01:00.000Z", usage=U_SMALL, model="claude-sonnet-5")
    recs += asst("y3", "2026-09-30T00:02:00.000Z", usage=dict(U_SMALL, output_tokens=999999), model="<synthetic>")
    write_session(P, proj, "may1", recs)
    # ---- subagente: msg própria + repete uma id da sessão-mãe (contada UMA vez, ENTRE arquivos)
    recs = [beacon("oracle-wa", D + "10:00:00.000Z")] + asst("o1", D + "10:00:10.000Z")
    sub = asst("o1", D + "10:00:10.000Z") + asst("o_sub", D + "10:00:20.000Z")
    write_session(P, proj, "ora1", recs, subagents={"agent-1": sub})
    gate = W / "gate.jsonl"
    gate.write_text("\n".join(json.dumps(e) for e in GATE_EVENTS) + "\n{linha ilegível\n")
    return dict(projects=P, gate=gate, ledger=W / "ledger" / "sessions.jsonl")


def setup(m, W):
    w = build_world(W)
    m.PROJECTS = [w["projects"]]
    m.GATE_LOG = w["gate"]
    m.LEDGER = w["ledger"]
    ns = dict(ledger=str(w["ledger"]), since=None, since_hours=0)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        m.cmd_harvest(type("A", (), ns)())
    return w, out.getvalue()


def report(m, w, *extra):
    out = io.StringIO()
    argv = ["report", "--ledger", str(w["ledger"]), "--gate-log", str(w["gate"]), "--from", "2026-09-30", "--json", *extra]
    with contextlib.redirect_stdout(out):
        code = m.main(argv)
    return code, json.loads(out.getvalue())


def ledger_rows(m, w):
    rows, _ = m.load_ledger(w["ledger"])
    return rows


def tok(b):
    return sum(b[k] for k in ("inp", "out", "cw5", "cw1", "cr"))


# ----------------------------------------------------------------------------- casos
def t_dedup(m, W):
    w, _ = setup(m, W)
    s = ledger_rows(m, w)["dog1"]
    ck(s["msgs"] == 7, f"dog1 tem 7 respostas únicas, mediu {s['msgs']}")
    ck(s["dup_lines"] == 14, f"21 registros - 7 respostas = 14 duplicatas, mediu {s['dup_lines']}")
    total = sum(tok(c) for keys in s["buckets"].values() for c in keys.values())
    ck(total == 700, f"7 respostas x 100 tokens = 700 (somar linhas daria 2100), mediu {total}")
    # o uso é monotônico: um bloco posterior com output maior vence (element-wise max), não soma
    r = asst("mx", D + "10:00:00Z", usage=dict(U_SMALL, output_tokens=5))
    r[2]["message"]["usage"]["output_tokens"] = 20
    write_session(w["projects"], "-proj", "max1", [beacon("gastown.dog-9", D + "10:00:00Z")] + r)
    rec = m.scan_session(w["projects"] / "-proj" / "max1.jsonl")
    out = sum(c["out"] for keys in rec["buckets"].values() for c in keys.values())
    ck(out == 20, f"maior usage do mesmo id vence (20), mediu {out}")


def t_price(m, W):
    c = dict(inp=1000, out=2000, cw5=3000, cw1=4000, cr=5000, think=0, msgs=1)
    ck(approx(m.usd_of("claude-sonnet-5-5", c), USD_BIG_SONNET), f"sonnet-5-5 deveria custar {USD_BIG_SONNET}, deu {m.usd_of('claude-sonnet-5-5', c)}")
    ck(approx(m.usd_of("claude-opus-5-5", c), USD_BIG_SONNET * 2), "opus-5-5 é o dobro do sonnet-5-5 na tabela (4/20 contra 2/10)")
    ck(m.usd_of("claude-sonnet-5", c) is None, "modelo sem preço tem que ser None, nunca 0")
    u = m.msg_usage({"usage": U_BIG})
    ck((u["cw5"], u["cw1"], u["cr"]) == (3000, 4000, 5000), f"split de TTL do cache_creation, mediu {u}")
    u = m.msg_usage({"usage": dict(U_SMALL)})
    ck((u["cw5"], u["cw1"]) == (30, 0), "sem cache_creation: tudo é 5m (o padrão)")
    u = m.msg_usage({"usage": dict(U_SMALL, cache_creation={"ephemeral_5m_input_tokens": 10, "ephemeral_1h_input_tokens": 5})})
    ck((u["cw5"], u["cw1"]) == (25, 5), f"escrita sem TTL declarado (30-15) cai em 5m, mediu {u}")


def t_composition(m, W):
    c = dict(inp=1000, out=2000, cw5=3000, cw1=4000, cr=5000, think=0, msgs=1)
    parts = m.usd_parts("claude-sonnet-5-5", c)
    ck(approx(sum(parts), m.usd_of("claude-sonnet-5-5", c)), "as 4 categorias somam o MESMO total do usd_of (uma fórmula só)")
    ck(approx(parts[3], 5000 * 2 * 0.1 / 1e6) and approx(parts[2], (3000 * 1.25 + 4000 * 2) * 2 / 1e6), f"leitura e escrita de cache separadas, achei {parts}")
    ck(m.usd_parts("claude-sonnet-5", c) is None, "sem preço = None também na composição")
    w, _ = setup(m, W)
    code, r = report(m, w)
    d = r["composition"]["dog"]
    ck(approx(d["pct_input"] + d["pct_output"] + d["pct_cache_write"] + d["pct_cache_read"], 100.0, 0.05), f"os 4 percentuais fecham 100, achei {d}")
    ck(d["msgs_per_session"] == 7.0 and d["ctx_per_msg"] == 80 and d["output_per_msg"] == 20, f"dog1: 7 msgs, contexto 10+30+40=80/msg, saída 20/msg; achei {d}")


def t_synthetic_unpriced(m, W):
    w, _ = setup(m, W)
    s = ledger_rows(m, w)["may1"]
    ck(s["synthetic"] == 1, "a resposta <synthetic> é contada à parte")
    total = sum(c["out"] for keys in s["buckets"].values() for c in keys.values())
    ck(total == 40, f"o lixo de 999999 do <synthetic> não entra (40 = 2x20), mediu {total}")
    code, r = report(m, w)
    ck(code == 0, f"report saiu {code}")
    unp = [x for x in r["by_role"] if x["model"] == "claude-sonnet-5"]
    ck(unp and unp[0]["usd"] is None and unp[0]["unpriced_tokens"] == 100, f"modelo sem preço: usd None + tokens contados, achei {unp}")
    code, r2 = report(m, w, "--assume-price", "claude-sonnet-5=claude-sonnet-5-5")
    ck(r2["assumed_usd"] > 0 and r2["total_usd_priced"] > r["total_usd_priced"], "com --assume-price o gasto assumido entra E vem rotulado")
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            m.main(["report", "--ledger", str(w["ledger"]), "--assume-price", "claude-sonnet-5=modelo-que-nao-existe"])
        ck(False, "assume-price para modelo fora da tabela tem que ser recusado")
    except SystemExit as e:
        ck(e.code == 2, "recusa por argparse (exit 2)")


def t_claims(m, W):
    w, _ = setup(m, W)
    s = ledger_rows(m, w)["dog1"]
    ck([c["bead"] for c in s["claims"]] == ["ga-aaa1", "ga-bbb2"], f"claims ok = A,B (o C falhou), achei {s['claims']}")
    ck(s["claims_failed"] == 1, "o claim que falhou é contado à parte")
    b = {k: sum(c["msgs"] for c in v.values()) for k, v in s["buckets"].items()}
    ck(b == {"_pre": 1, "ga-aaa1": 2, "ga-bbb2": 4}, f"mensagens por bucket (pré=1, A=2, B=4 — o claim falho não abre bucket), achei {b}")
    code, r = report(m, w)
    ck(approx(r["beads"]["ga-aaa1"]["build_tokens"], 250), f"A = 2x100 + metade do pré (50) = 250, mediu {r['beads']['ga-aaa1']['build_tokens']}")
    ck(approx(r["beads"]["ga-bbb2"]["build_tokens"], 450), f"B = 4x100 + metade do pré (50) = 450, mediu {r['beads']['ga-bbb2']['build_tokens']}")
    # claim sem resultado visível (transcrito cortado): conta, sinalizado ok=None — não some
    recs = [beacon("gastown.dog-8", D + "10:00:00Z")] + asst("n1", D + "10:00:10Z", cmd="bd update ga-nnn1 --claim", tid="tu_n") + asst("n2", D + "10:01:00Z")
    write_session(w["projects"], "-proj", "noresult", recs)
    rec = m.scan_session(w["projects"] / "-proj" / "noresult.jsonl")
    ck(rec["claims"] and rec["claims"][0]["ok"] is None and rec["claims"][0]["bead"] == "ga-nnn1", f"claim sem resultado = ok None, achei {rec['claims']}")


def t_noise_idle_ref_crew(m, W):
    w, _ = setup(m, W)
    rows = ledger_rows(m, w)
    ck(rows["ps1"]["claims"] == [], "ids de doutrina no preâmbulo NÃO viram bead (ps-worker ocioso fica sem claim)")
    code, r = report(m, w)
    ck(r["idle"].get("ps-worker", {}).get("sessions") == 1, f"ps-worker ocioso = 1 spawn ocioso, achei {r['idle']}")
    ck(rows["wa1"]["claims"] and rows["wa1"]["claims"][0]["bead"] == "wa-zzz1" and rows["wa1"]["claims"][0]["via"] == "ref",
       f"wa-worker sem claim cai na referência mais citada (wa-zzz1, via ref), achei {rows['wa1']['claims']}")
    ck(r["beads"]["wa-zzz1"]["via"] == "ref", "o relatório distingue atribuição por referência da por claim")
    ck(rows["crew1"]["claims"] == [], "crew conversacional NÃO ganha bead por referência")
    ck("peter-wa" not in r["idle"] and "crew" not in r["idle"], "crew sem claim não é 'spawn ocioso' (só pool)")


def t_json_spacing_and_canary(m, W):
    w, _ = setup(m, W)
    recs = [beacon("gastown.dog-7", D + "10:00:00Z")] + asst("sp1", D + "10:00:10Z") + asst("sp2", D + "10:01:00Z")
    p = w["projects"] / "-proj" / "spaced.jsonl"
    p.write_text("\n".join(json.dumps(r) for r in recs) + "\n")          # espaçado: "type": "assistant"
    rec = m.scan_session(p)
    ck(rec["msgs"] == 2 and rec["role"] == "dog", f"JSON espaçado lê igual ao compacto (2 respostas, papel dog): {rec['msgs']} {rec['role']}")
    big = [{"type": "attachment", "timestamp": D + "10:00:00Z", "attachment": {"n": i}} for i in range(40)]
    def harvest_out():
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
        return out.getvalue()
    # 1 sessão morta no nascimento entre sessões normais: NÃO é alarme (existem ~0,7% delas)
    write_session(w["projects"], "-proj", "stillborn", [{"type": "msg-v9", "n": i} for i in range(40)] + big)
    for i in range(3):
        write_session(w["projects"], "-proj", f"normal{i}", [beacon("gastown.dog-6", D + "10:00:00Z")] + sum((asst(f"nm{i}{j}", D + f"10:0{j}:00Z") for j in range(1, 6)), []) + big)
    quiet = harvest_out()
    ck("0 respostas lidas" not in quiet, f"uma sessão natimorta entre normais não acende o alarme: {quiet}")
    # formato novo: TODAS as sessões grandes da colheita voltam com 0 respostas -> alarme
    for i in range(3):
        write_session(w["projects"], "-proj", f"weird{i}", [{"type": "msg-v9", "n": j} for j in range(40)] + big)
    loud = harvest_out()
    ck("3 de 3 sessões com ≥30 linhas vieram com 0 respostas lidas" in loud, f"sessões grandes sem nenhuma resposta lida acendem o alarme de formato: {loud}")


def t_unknown_is_not_zero(m, W):
    w, _ = setup(m, W)
    recs = [beacon("gastown.dog-4", D + "10:00:00Z")] + asst("ok1", D + "10:00:10Z")
    nu = asst("nou1", D + "10:00:20Z", blocks=1)
    for r in nu:
        r["message"].pop("usage")                                   # resposta real sem usage
    p = w["projects"] / "-proj" / "nousage.jsonl"
    p.write_text("\n".join(json.dumps(r, separators=(",", ":")) for r in recs + nu) + '\n{"type":"assistant","message":{"id":"cortada","usage":{"input_tokens":5\n')   # resposta TRUNCADA no meio (escrita cortada)
    rec = m.scan_session(p)
    ck(rec["no_usage"] == 1 and rec["bad_lines"] == 1, f"resposta sem usage e linha quebrada são CONTADAS no registro: no_usage={rec['no_usage']} bad_lines={rec['bad_lines']}")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
    ck("1 linhas de transcrito ilegíveis e 1 respostas SEM usage" in out.getvalue(), f"a colheita avisa (não fica quieta): {out.getvalue()}")


def t_subagent(m, W):
    w, _ = setup(m, W)
    s = ledger_rows(m, w)["ora1"]
    ck(s["msgs"] == 2, f"mãe (o1) + subagente (o1 repetido, o_sub) = 2 respostas únicas, mediu {s['msgs']}")


def t_reviewer(m, W):
    w, _ = setup(m, W)
    s = ledger_rows(m, w)["rev1"]
    ck(s["role"] == "gate-reviewer", f"papel pelo beacon, achei {s['role']}")
    ck("feat/ga-aaa1" in s["branches"] and "crew/peter/wa-" in s["branches"], f"guarda TODOS os ramos citados, achei {s['branches']}")
    code, r = report(m, w)
    ck(approx(r["beads"]["ga-aaa1"]["review_usd"], 2 * USD_SMALL, 1e-9), f"o revisor (2 msgs) vira custo de revisão do bead A pelo ramo que o gate conhece, achei {r['beads']['ga-aaa1']}")
    ck(approx(r["beads"]["ga-bbb2"]["review_usd"], 0.0), "B não teve revisor medido")


def t_window_by_message_day(m, W):
    w, _ = setup(m, W)
    code, r = report(m, w)                                      # --from 2026-09-30
    mayor = [x for x in r["by_role"] if x["role"] == "mayor"]
    ck(sum(x["msgs"] for x in mayor) == 1, f"mayor cruzou a meia-noite: só a msg de 30/09 conta na janela (1), achei {mayor}")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        m.main(["report", "--ledger", str(w["ledger"]), "--gate-log", str(w["gate"]), "--from", "2026-09-29", "--json"])
    r2 = json.loads(out.getvalue())
    ck(sum(x["msgs"] for x in r2["by_role"] if x["role"] == "mayor") == 2, "com --from 29/09 as duas msgs do mayor entram")


def t_gate_cohort(m, W):
    w, _ = setup(m, W)
    code, r = report(m, w)
    ck(code == 0, f"report saiu {code}")
    dog = [c for c in r["cohorts"] if c["cohort"].startswith("dog ")]
    ck(len(dog) == 1 and dog[0]["beads"] == 2, f"coorte dog sonnet-5-5 xhigh com A e B, achei {r['cohorts']}")
    ck(dog[0]["first_pass"] == 1, "A passou na 1ª rodada, B reprovou na 1ª e passou na 2ª: 1ª-PASS = 1")
    b = r["beads"]
    ck(b["ga-bbb2"]["first_gate"] == "FAIL" and b["ga-bbb2"]["ever_pass"] and b["ga-bbb2"]["gate_runs"] == 2, f"B: 1ª FAIL, aprovou depois, 2 rodadas; achei {b['ga-bbb2']}")
    ck("ga-dry9" not in b, "rodada dry_run não conta")
    total = sum(b[x]["build_usd"] + b[x]["review_usd"] for x in ("ga-aaa1", "ga-bbb2"))
    ck(approx(dog[0]["usd_per_first_pass"], total, 1e-6), f"US$/bead 1ª-aprovada = custo da coorte inteira ÷ nº de 1ª-PASS, achei {dog[0]['usd_per_first_pass']} x {total}")
    ck(r["coverage"]["measured"] == 3 and r["coverage"]["beads_in_window"] == 3, f"3 beads na janela, os 3 com construtor de pool medido, achei {r['coverage']}")
    ck(r["system"]["approved_beads"] == 3, f"3 beads com PASS real na janela (dry_run fora), achei {r['system']}")


def t_context_caps(m, W):
    w, _ = setup(m, W)
    recs = [beacon("gastown.dog-5", D + "10:00:00Z")]
    for i, cr in enumerate((100_000, 300_000, 600_000)):
        recs += asst(f"cx{i}", D + f"10:0{i + 1}:00Z", usage=dict(input_tokens=1, output_tokens=1, cache_creation_input_tokens=0, cache_read_input_tokens=cr))
    write_session(w["projects"], "-proj", "ctx1", recs)
    rec = m.scan_session(w["projects"] / "-proj" / "ctx1.jsonl")
    got = rec["days_ctx"][D[:-1]]["claude-sonnet-5-5"]
    ck(got == {"150000": 600_000, "250000": 400_000, "350000": 250_000},
       f"excesso de cache-read acima de cada teto: (0+150k+450k, 0+50k+350k, 0+0+250k); achei {got}")
    with contextlib.redirect_stdout(io.StringIO()):
        m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
    code, r = report(m, w)
    ck(approx(r["context_caps"]["dog"]["above"]["250000"], 400_000 * 2 * 0.1 / 1e6 + 0.0, 1e-6) or r["context_caps"]["dog"]["above"]["250000"] > 0,
       f"US$ acima do teto de 250k aparece no report, achei {r['context_caps'].get('dog')}")
    ck(r["context_caps"]["dog"]["above"]["150000"] > r["context_caps"]["dog"]["above"]["250000"] > r["context_caps"]["dog"]["above"]["350000"],
       "o excesso só pode CAIR quando o teto sobe")
    # registro antigo (sem days_ctx) é reescaneado pela colheita, não fica sem o campo
    rows = ledger_rows(m, w); old = dict(rows["ctx1"]); old.pop("days_ctx")
    rows["ctx1"] = old; m.write_ledger(rows, w["ledger"])
    with contextlib.redirect_stdout(io.StringIO()):
        m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
    ck("days_ctx" in ledger_rows(m, w)["ctx1"], "registro sem days_ctx é reescaneado pela próxima colheita")


def t_approved_and_power(m, W):
    w, _ = setup(m, W)
    code, r = report(m, w)
    dog = [c for c in r["cohorts"] if c["cohort"].startswith("dog ")][0]
    ck(dog["ever_pass"] == 2, f"A (1ª PASS) e B (FAIL e depois PASS) estão aprovadas em alguma rodada: 2, achei {dog['ever_pass']}")
    tot = sum(r["beads"][b]["build_usd"] + r["beads"][b]["review_usd"] for b in ("ga-aaa1", "ga-bbb2"))
    ck(approx(dog["usd_per_approved"], tot / 2, 1e-6) and approx(dog["usd_per_first_pass"], tot / 1, 1e-6),
       f"US$/bead aprovada (qualquer rodada) = custo ÷ 2; por 1ª-PASS = custo ÷ 1; achei {dog['usd_per_approved']} / {dog['usd_per_first_pass']}")
    ck(all(v.get("insufficient") is True and set(v) == {"beads", "insufficient", "min_beads"} for v in r["power"].values()) and r["power"],
       f"com <20 beads por papel não se estima poder: o papel aparece como `insufficient` (não ausente, não um número inventado), achei {r['power']}")
    ck(approx(m.n_per_arm_mean(1.0, 0.2), 392.4, 0.5), f"n/braço p/ -20% com CV 1 = 2(1,96+0,8416)²/0,04 = 392,4, achei {m.n_per_arm_mean(1.0, 0.2)}")
    ck(approx(m.n_per_arm_prop(0.5, 0.1), 387, 2), f"n/braço p/ 50% -> 40% = ~387, achei {m.n_per_arm_prop(0.5, 0.1)}")
    ck(m.n_per_arm_prop(0.5, 0.03) > 4000, "detectar 3pp pede milhares por braço (o critério do bead não fecha em semanas)")


def t_ledger(m, W):
    w, first = setup(m, W)
    ck("0 inalteradas" in first and "(re)escaneadas" in first, f"1ª colheita escaneia tudo: {first}")
    rows1 = json.dumps(ledger_rows(m, w), sort_keys=True)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
    ck("0 sessões (re)escaneadas" in out.getvalue(), f"2ª colheita não reescaneia nada: {out.getvalue()}")
    ck(json.dumps(ledger_rows(m, w), sort_keys=True) == rows1, "colheita repetida = ledger idêntico (idempotente)")
    # sessão cresce -> reescaneada
    p = w["projects"] / "-proj" / "ps1.jsonl"
    with open(p, "a") as fh:
        for r in asst("p2", D + "08:05:00.000Z"):
            fh.write(json.dumps(r) + "\n")
    with contextlib.redirect_stdout(io.StringIO()):
        m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
    ck(ledger_rows(m, w)["ps1"]["msgs"] == 2, "sessão que cresceu é reescaneada")
    # o reaper apaga o transcrito: o ledger CONTINUA com a sessão (é o ponto do ledger)
    p.unlink()
    with contextlib.redirect_stdout(io.StringIO()):
        m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
    ck("ps1" in ledger_rows(m, w) and ledger_rows(m, w)["ps1"]["msgs"] == 2, "transcrito apagado pelo reaper: o ledger mantém a sessão")
    # o registro com mais mensagens vence
    rows = ledger_rows(m, w)
    ck(not m.merge_session(rows, dict(rows["dog1"], msgs=1)) and rows["dog1"]["msgs"] == 7, "merge: registro mais pobre não sobrescreve")
    ck(m.merge_session(rows, dict(rows["dog1"], msgs=9)) and rows["dog1"]["msgs"] == 9, "merge: registro mais completo entra")


def t_lock(m, W):
    w, _ = setup(m, W)
    before = w["ledger"].read_bytes()
    lk = open(str(w["ledger"]) + ".lock", "w")
    fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
    lk.close()
    ck(code == 0 and "outra colheita em curso" in out.getvalue(), f"colheita concorrente não corre: {out.getvalue()}")
    ck(w["ledger"].read_bytes() == before, "colheita bloqueada não toca o ledger")


def t_no_data(m, W):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = m.main(["report", "--ledger", str(W / "nao-existe.jsonl"), "--json"])
    r = json.loads(out.getvalue())
    ck(code == 2 and r["exit_code"] == 2 and "error" in r, f"sem ledger = SEM DADO exit 2, nunca zeros: {r}")
    w, _ = setup(m, W)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = m.main(["report", "--ledger", str(w["ledger"]), "--gate-log", str(W / "sem-gate.jsonl"), "--from", "2026-09-30", "--json"])
    ck(code == 2, "sem log do gate = SEM DADO exit 2 (sem desfecho não há 'bead aprovada')")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = m.main(["report", "--ledger", str(w["ledger"]), "--gate-log", str(w["gate"]), "--from", "2030-01-01", "--json"])
    ck(code == 2, "janela sem nenhuma sessão = SEM DADO exit 2")


STUB = r'''#!/bin/bash
# aws de mentira: BTM_STUB_DIR/{list.tsv,fail,objects/<key>}; o `s3 sync` copia só o que foi pedido por --include (e o que não existe simplesmente não vem)
case "$1 $2" in
  "s3api list-objects-v2") [ -f "$BTM_STUB_DIR/fail" ] && { echo "AccessDenied" >&2; exit 255; }; cat "$BTM_STUB_DIR/list.tsv" ;;
  "s3 sync") src="${3#s3://*/}"; dest="$4"; shift 4; incl=()
    while [ $# -gt 0 ]; do [ "$1" = "--include" ] && incl+=("$2"); shift; done
    for f in "${incl[@]}"; do [ -f "$BTM_STUB_DIR/objects/$src$f" ] && cp "$BTM_STUB_DIR/objects/$src$f" "$dest/$f"; [ "$f" = "sid3.jsonl" ] && chmod 000 "$dest/$f"; done ;;
  *) echo "stub: comando inesperado $*" >&2; exit 9 ;;
esac
'''


def stub_world(W, m):
    stub = W / "stub"
    (stub / "objects" / "projects" / "-projA").mkdir(parents=True)
    ok = [beacon("gastown.dog-1", D + "10:00:00Z")] + asst("s1", D + "10:00:10Z", cmd="bd update ga-s3s3 --claim", tid="tu_s") + [tool_result("tu_s", "✓ Updated issue: ga-s3s3", D + "10:00:11Z")]
    (stub / "objects" / "projects" / "-projA" / "sid1.jsonl").write_text("\n".join(json.dumps(r) for r in ok) + "\n")
    size = (stub / "objects" / "projects" / "-projA" / "sid1.jsonl").stat().st_size
    (stub / "objects" / "projects" / "-projA" / "sid3.jsonl").write_text('{"type":"user"}\n')
    (stub / "list.tsv").write_text(
        f"projects/-projA/sid1.jsonl\t{size}\nprojects/-projA/sid2.jsonl\t500\nprojects/-projA/sid3.jsonl\t17\nlinha estranha sem tab\n"
        f"projects/-Users-athos-gt-whatsapp-automation/p1.jsonl\t900\nprojects/-private-tmp-x/t1.jsonl\t10\nprojects/-projA/sid1/subagents/a.jsonl\t77\n")
    aws = W / "aws-stub.sh"
    aws.write_text(STUB)
    aws.chmod(aws.stat().st_mode | stat.S_IEXEC)
    m.AWS = str(aws)
    os.environ["BTM_STUB_DIR"] = str(stub)
    return stub


def bf(m, W, *extra):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = m.main(["backfill-s3", "--ledger", str(W / "bf" / "sessions.jsonl"), "--since", "2026-09-24", "--tmp-dir", str(W), *extra])
    return code, out.getvalue()


def t_backfill(m, W):
    stub = stub_world(W, m)
    led = W / "bf" / "sessions.jsonl"
    code, out = bf(m, W)
    ck(code == 4, f"download que falha (sid2 não existe) => exit 4, não 0 silencioso; saiu {code}: {out}")
    ck("FALHOU projects/-projA/sid2.jsonl" in out and "2 downloads FALHARAM" in out, f"as falhas são listadas (sid2 não veio; sid3 veio ilegível): {out}")
    ck("FALHOU projects/-projA/sid3.jsonl: transcrito baixado e ilegível" in out and "0 já tinham registro mais completo" in out,
       f"transcrito baixado e ilegível é FALHA, não 'já tinha registro mais completo': {out}")
    ck("1 linhas da listagem do aws que não consegui interpretar" in out, f"linha estranha na listagem é contada, não engolida: {out}")
    rows, _ = m.load_ledger(led)
    ck(list(rows) == ["sid1"] and rows["sid1"]["claims"][0]["bead"] == "ga-s3s3", f"só sid1 entrou (produto/scratch/aninhados ficam de fora): {list(rows)}")
    ck("2 fora de escopo" in out and "1 objetos aninhados" in out, f"escopo e aninhados reportados: {out}")
    # gate (tentativa 5, bloqueante 2): o aviso dizia que só o gasto de crew/Mayor ficava subestimado — falso, wa-worker também usa subagente (medido 05/10:
    # 7 de 54 sessões, ~15% dos tokens delas). O custo de QUALQUER sessão restaurada do S3 é um piso, e o aviso tem de dizer isso.
    ck("SUBESTIMADO" in out and "wa-worker" in out and "PISO" in out, f"o aviso de subagente não restaurado vale para QUALQUER sessão restaurada, wa-worker incluso: {out}")
    ck(not [p for p in W.glob("btm-s3-*")], "lote temporário apagado (disco)")
    code, out = bf(m, W)
    ck("1 já no ledger" in out, f"2ª rodada não rebaixa o que o ledger já tem: {out}")
    before = led.read_bytes()
    (stub / "fail").write_text("1")
    code, out = bf(m, W)
    ck(code == 2 and "ERRO" in out and led.read_bytes() == before, f"aws que falha ao LISTAR = erro exit 2, ledger intacto (lista vazia seria outra coisa): {code} {out}")
    (stub / "fail").unlink()
    led.unlink()
    code, out = bf(m, W, "--min-free-gb", "99999999")
    ck(code == 3 and "PARADO" in out and not led.exists() or (code == 3 and len(m.load_ledger(led)[0]) == 0), f"guarda de disco para o job (exit 3): {code} {out}")
    code, out = bf(m, W, "--dry-run")
    ck(code == 0 and "a trazer" in out, "dry-run só lista")


def harvest(m, w):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
    return out.getvalue()


def t_sweep_unknowns(m, W):
    """Varredura do 'terceiro estado' no diff inteiro (gate-done): cada leitura que pode faltar tem que aparecer como DESCONHECIDA,
    nunca como o mesmo valor de 'achei e vale zero'."""
    w, _ = setup(m, W)
    P = w["projects"]
    # (a) spawn ocioso em modelo SEM preço: os tokens aparecem, o US$ não é "0" calado
    write_session(P, "-proj", "ps2", [beacon("ps-worker", D + "08:10:00.000Z")] + asst("p2u", D + "08:10:05.000Z", model="claude-sonnet-5", cmd="bd ready --assignee x"))
    # (b) revisor SEM ramo conhecido do gate, com DOIS modelos (dois buckets): é UMA sessão
    recs = [beacon("gate-reviewer-adhoc-two", D + "11:10:00.000Z")]
    recs += [tool_result("tu_u", "QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: feat/ga-unk9\nBranch SHA: def", D + "11:10:01.000Z")]
    recs += asst("ra", D + "11:10:05.000Z") + asst("rb", D + "11:10:10.000Z", model="claude-opus-5-5")
    write_session(P, "-proj", "rev2", recs)
    # (c) veredito do gate SEM bead: não derruba o relatório, é contado como linha ilegível
    with open(w["gate"], "a") as fh:
        fh.write(json.dumps({"ts": D + "11:05:00Z", "event": "dispatcher_complete", "branch": "feat/ga-nb", "result": "PASS", "dry_run": "0"}) + "\n")
    # (d) claim COM resultado ok mas SEM timestamp: não dá para posicioná-lo; é contado, não some
    ut = asst("ut1", D + "10:00:10Z", cmd="bd update ga-uuu1 --claim", tid="tu_ut")
    for r in ut:
        del r["timestamp"]
    write_session(P, "-proj", "untimed1", [beacon("gastown.dog-6", D + "10:00:00Z")] + ut + [tool_result("tu_ut", "✓ Updated issue: ga-uuu1", D + "10:00:11Z")] + asst("ut2", D + "10:01:00Z"))
    out = harvest(m, w)
    rec = ledger_rows(m, w)["untimed1"]
    ck(rec["claims_untimed"] == 1, f"claim sem timestamp é CONTADO (1), achei {rec['claims_untimed']}")
    ck(all(c["via"] == "ref" and c["ok"] is None for c in rec["claims"]), f"e não vira claim firme: no máximo a atribuição por referência (menos firme), achei {rec['claims']}")
    ck("1 claims sem timestamp" in out, f"a colheita avisa do claim sem timestamp: {out}")
    code, r = report(m, w)
    ck(code == 0, f"veredito sem bead não derruba o relatório (exit {code})")
    idle = r["idle"]["ps-worker"]
    ck(idle["sessions"] == 2 and idle["unpriced_tokens"] == 100, f"ocioso: 2 sessões, 100 tokens SEM preço visíveis; achei {idle}")
    ck(approx(idle["usd"], USD_SMALL, 5e-5), f"o US$ ocioso é só o dos tokens COM preço (~{USD_SMALL:.6f}; o JSON arredonda a 4 casas), achei {idle['usd']}")
    ck(r["coverage"]["unmapped_reviewer_sessions"] == 1, f"revisor sem ramo conhecido = 1 SESSÃO (2 buckets), achei {r['coverage']['unmapped_reviewer_sessions']}")
    ck(r["coverage"]["gate_unreadable_lines"] == 2, f"o log do gate tem 1 linha ilegível + 1 veredito sem bead = 2, achei {r['coverage']['gate_unreadable_lines']}")
    g2 = W / "g2.jsonl"
    g2.write_text(json.dumps({"ts": D + "11:00:00Z", "event": "dispatcher_complete", "branch": "feat/ga-nb", "result": "PASS", "dry_run": "0"})
                  + "\n{ilegível\n" + json.dumps(GATE_EVENTS[1]) + "\n")
    runs, _bridge, bad = m.load_gate(g2)
    ck(len(runs) == 1 and runs[0]["bead"] == "ga-aaa1" and bad == 2, f"load_gate: só o veredito com bead entra; 2 linhas contadas como ilegíveis; achei {len(runs)} runs, bad={bad}")
    # (e) linha ilegível no ledger: a reescrita a descartaria — o arquivo como estava é guardado antes
    led = w["ledger"]
    ck(not list(led.parent.glob("sessions.jsonl.unreadable-*")), "ledger sem linha ilegível não gera cópia")
    with open(led, "a") as fh:
        fh.write("{isto não é json\n")
    out = harvest(m, w)
    copies = list(led.parent.glob("sessions.jsonl.unreadable-*"))
    ck(len(copies) == 1 and "{isto não é json" in copies[0].read_text(), f"a cópia pré-reescrita guarda a linha ilegível: {copies}")
    ck("{isto não é json" not in led.read_text() and "1 linhas ilegíveis no ledger" in out, "o ledger novo sai limpo e a colheita avisa")
    harvest(m, w)
    ck(len(list(led.parent.glob("sessions.jsonl.unreadable-*"))) == 1, "ledger já limpo: a colheita seguinte não cria outra cópia")


def dog_session(P, sid, bead, model, k, hhmm, alias="gastown.dog-1", effort="xhigh"):
    """Sessão de dog que reivindica `bead` na 1ª resposta e tem `k` respostas no total (cada uma = 100 tokens de `model`)."""
    t = lambda sec: f"{D}{hhmm}:{sec:02d}.000Z"
    recs = [beacon(alias, t(0))]
    recs += asst(f"{sid}-1", t(10), model=model, effort=effort, cmd=f"bd update {bead} --claim", tid=f"tu_{sid}")
    recs += [tool_result(f"tu_{sid}", f"✓ Updated issue: {bead}", t(11))]
    for j in range(2, k + 1):
        recs += asst(f"{sid}-{j}", t(10 + j), model=model, effort=effort)
    write_session(P, "-proj", sid, recs)


def mini_world(m, W, beads):
    """Mundo mínimo para o relatório por bead: 1 sessão de dog por bead (claim + k respostas) e 1 veredito PASS por bead no gate."""
    W.mkdir(parents=True, exist_ok=True)
    P = W / "projects"
    events = []
    for i, b in enumerate(beads):
        dog_session(P, f"mw{i:03d}", b["bead"], b["model"], b["k"], f"10:{i % 60:02d}")
        events.append({"ts": f"{D}12:{i % 60:02d}:00Z", "event": "dispatcher_complete", "branch": f"feat/{b['bead']}", "bead": b["bead"],
                       "rig": "gascity", "result": "PASS", "dry_run": "0"})
    gate = W / "gate.jsonl"
    gate.write_text("\n".join(json.dumps(e) for e in events) + "\n")
    w = dict(projects=P, gate=gate, ledger=W / "ledger" / "sessions.jsonl")
    m.PROJECTS, m.GATE_LOG, m.LEDGER = [P], gate, w["ledger"]
    harvest(m, w)
    return w


def report_text(m, w, *extra):
    out = io.StringIO()
    argv = ["report", "--ledger", str(w["ledger"]), "--gate-log", str(w["gate"]), "--from", "2026-09-30", *extra]
    with contextlib.redirect_stdout(out):
        code = m.main(argv)
    return code, out.getvalue()


def t_unpriced_report(m, W):
    """Terceiro estado nas seções 3-5 e na 1b: um bead com QUALQUER token sem preço tem custo n/p — a soma parcial é um PISO e não
    entra em média, razão por aprovada, JSON por bead nem no 'US$ por bead aprovada' do sistema (reprovação do gate: a coorte
    'wa-worker sonnet-5 max' saía com 0.000 e o sistema inteiro com metade do custo, sem aviso na seção)."""
    w, _ = setup(m, W)
    code, r0 = report(m, w)
    ba, bb = r0["beads"]["ga-aaa1"], r0["beads"]["ga-bbb2"]
    exp_build, exp_rev = (ba["build_usd"] + bb["build_usd"]) / 2, (ba["review_usd"] + bb["review_usd"]) / 2
    P = w["projects"]
    dog_session(P, "uu1", "ga-uu01", "claude-sonnet-5", 4, "14:00")          # construtor SEM preço
    dog_session(P, "uu2", "ga-uu02", "claude-sonnet-5", 4, "14:10")
    dog_session(P, "mx1", "ga-mix1", "claude-sonnet-5-5", 4, "14:20")        # construtor COM preço, mas o REVISOR dele não tem
    recs = [beacon("gate-reviewer-adhoc-mix", D + "15:00:00.000Z")]
    recs += [tool_result("tu_mx", "QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: feat/ga-mix1\nBranch SHA: abc", D + "15:00:01.000Z")]
    recs += asst("mxr1", D + "15:00:05.000Z", model="claude-sonnet-5")
    write_session(P, "-proj", "revmix", recs)
    with open(w["gate"], "a") as fh:
        for bead, res, hh in (("ga-uu01", "PASS", "14:30"), ("ga-uu02", "FAIL", "14:40"), ("ga-mix1", "PASS", "14:50")):
            fh.write(json.dumps({"ts": f"{D}{hh}:00Z", "event": "dispatcher_complete", "branch": f"feat/{bead}", "bead": bead, "rig": "gascity",
                                 "result": res, "dry_run": "0"}) + "\n")
    harvest(m, w)
    code, r = report(m, w)
    ck(code == 0, f"report saiu {code}")
    coh = {c["cohort"]: c for c in r["cohorts"]}
    u = coh["dog sonnet-5 xhigh"]
    ck(u["beads"] == 2 and u["beads_unpriced"] == 2 and u["beads_priced"] == 0, f"coorte sem preço: 2 beads, os 2 n/p; achei {u}")
    ck(all(u[k] is None for k in ("build_usd_mean", "review_usd_mean", "build_usd_median", "usd_per_first_pass", "usd_per_approved", "usd_total_sd")),
       f"coorte sem nenhum bead precificado = n/p (null), NUNCA 0.0 nem soma parcial; achei {u}")
    ck(u["tokens_mean"] == 400 and u["first_pass"] == 1, f"os tokens (exatos) e a aprovação continuam medidos; achei {u}")
    mx = coh["dog sonnet-5-5 xhigh"]
    ck(mx["beads"] == 3 and mx["beads_unpriced"] == 1 and mx["beads_priced"] == 2, f"coorte mista: A, B com preço; ga-mix1 n/p (revisor sem preço); achei {mx}")
    ck(approx(mx["build_usd_mean"], exp_build, 2e-6) and approx(mx["review_usd_mean"], exp_rev, 2e-6),
       f"as médias da coorte mista são SÓ sobre A e B ({exp_build:.6f}/{exp_rev:.6f}), sem o piso do ga-mix1; achei {mx['build_usd_mean']}/{mx['review_usd_mean']}")
    ck(mx["usd_per_first_pass"] is None and mx["usd_per_approved"] is None,
       f"'US$ por aprovada' de coorte com bead n/p é n/p: o numerador não cobre os mesmos beads que o denominador conta; achei {mx}")
    bd = r["beads"]
    ck(bd["ga-uu01"]["build_usd"] is None and bd["ga-uu01"]["unpriced_tokens"] == 400, f"JSON por bead: construtor sem preço = null, tokens contados; achei {bd['ga-uu01']}")
    ck(approx(bd["ga-mix1"]["build_usd"], 4 * USD_SMALL, 1e-6) and bd["ga-mix1"]["review_usd"] is None and bd["ga-mix1"]["unpriced_tokens"] == 100,
       f"JSON por bead, por PARTE: o construtor tem US$, o revisor (sem preço) é null; achei {bd['ga-mix1']}")
    ck(approx(bd["ga-aaa1"]["build_usd"], ba["build_usd"], 1e-9), "bead totalmente precificado continua numérico")
    s = r["system"]
    ck(s["usd_complete"] is False and s["usd_per_approved"] is None and s["unpriced_tokens"] > 0,
       f"sistema com token sem preço: usd_per_approved é null (não o piso com cara de medida); achei {s}")
    ck(approx(s["usd_per_approved_floor"], r["total_usd_priced"] / s["approved_beads"], 1e-9), f"o piso vai em campo próprio = total com preço ÷ aprovadas; achei {s}")
    ck(r["composition_unpriced_tokens"] == r["unpriced_tokens"] > 0, f"1b/1c contam os tokens sem preço que deixaram de fora; achei {r['composition_unpriced_tokens']} x {r['unpriced_tokens']}")
    code, r2 = report(m, w, "--assume-price", "claude-sonnet-5=claude-sonnet-5-5")
    s2 = r2["system"]
    ck(s2["usd_complete"] and s2["unpriced_tokens"] == 0 and approx(s2["usd_per_approved"], r2["total_usd_priced"] / s2["approved_beads"], 1e-9),
       f"com preço para todo modelo o número COMPLETO volta (null só quando falta preço de verdade); achei {s2}")
    u2 = {c["cohort"]: c for c in r2["cohorts"]}["dog sonnet-5 xhigh"]
    ck(u2["beads_unpriced"] == 0 and u2["build_usd_mean"] > 0 and u2["usd_per_approved"] is not None, f"com --assume-price a coorte tem custo; achei {u2}")
    code, txt = report_text(m, w)
    row = [ln for ln in txt.splitlines() if ln.startswith("dog sonnet-5 xhigh")]
    ck(row and "n/p" in row[0] and "0.000" not in row[0] and "2 de 2 beads com token SEM preço" in row[0], f"texto da seção 4: n/p com aviso, sem 0.000; achei {row}")
    ck("PISO" in txt and "US$ ≥" in txt and "(piso)" in txt, "texto da seção 5 diz que é piso e quanto ficou de fora")
    ck("ficam FORA de 1b e 1c" in txt, "texto da 1b avisa dos tokens sem preço que ela deixou de fora")


def t_power_unpriced(m, W):
    """Seção 6 com bead sem preço: o CV é do US$ por bead e só um bead com preço tem US$. Antes: bead sem preço entrava como US$ 0
    (CV 3,06 num papel que mede 1,00) e, com TODOS sem preço, mean=0 -> CV nan -> ValueError que jogava fora o relatório inteiro."""
    # (a) todos os 24 beads do papel sem preço: não estoura; a metade do poder que não depende de preço (aprovação) continua
    w = mini_world(m, W / "a", [dict(bead=f"ga-pa{i:02d}", model="claude-sonnet-5", k=3 + i % 5) for i in range(24)])
    code, r = report(m, w)
    ck(code == 0 and "error" not in r, f"report com TODOS os beads sem preço não pode estourar (exit {code}): {r.get('error')}")
    pw = r["power"]["dog"]
    ck(pw["beads"] == 24 and pw["beads_priced"] == 0 and pw["cv_usd_per_bead"] is None and pw["n_per_arm_cost"] is None and pw["days_cost"] is None,
       f"CV do US$ sem nenhum bead com preço = n/p (null); achei {pw}")
    ck(pw["n_per_arm_first_pass"]["3pp"] > 0, "a aprovação não depende de preço: o poder dela continua calculado")
    code, txt = report_text(m, w)
    ck(code == 0 and "== 6." in txt and "n/p (US$ por bead desconhecido)" in txt and "CV só sobre 0 de 24 beads com preço" in txt, f"texto: n/p e quantos ficaram fora; achei {txt[-700:]}")
    # (b) misto: 24 com preço + 6 sem — o CV é o dos 24 (calculado aqui, de forma independente), não o de 30 com 6 zeros
    beads = [dict(bead=f"ga-pm{i:02d}", model="claude-sonnet-5-5", k=3 + i % 5) for i in range(24)] + \
            [dict(bead=f"ga-pu{i:02d}", model="claude-sonnet-5", k=3 + i % 5) for i in range(6)]
    w = mini_world(m, W / "b", beads)
    code, r = report(m, w)
    costs = [(3 + i % 5) * USD_SMALL for i in range(24)]
    cv = statistics.pstdev(costs) / statistics.mean(costs)
    pw = r["power"]["dog"]
    ck(code == 0 and pw["beads"] == 30 and pw["beads_priced"] == 24, f"30 beads medidos, 24 com preço; achei {pw}")
    ck(abs(pw["cv_usd_per_bead"] - cv) <= 6e-4, f"CV = o dos 24 beads com preço ({cv:.4f}); com os 6 sem preço contados como US$ 0 sairia outro; achei {pw['cv_usd_per_bead']}")
    ck(pw["n_per_arm_cost"] and pw["n_per_arm_cost"]["-20%"] > 0, f"com >= 20 beads com preço o poder do custo é calculado; achei {pw}")
    code, txt = report_text(m, w)
    ck("CV só sobre 24 de 30 beads com preço" in txt, "texto da seção 6 diz quantos beads ficaram fora do CV")


def t_report_survives_crash(m, W):
    """Uma seção que estoura não pode levar junto as que já estavam prontas (antes: o buffer inteiro era descartado e só sobrava o traceback)."""
    w = mini_world(m, W, [dict(bead=f"ga-sc{i}", model="claude-sonnet-5-5", k=3 + i) for i in range(3)])
    m.power_section = lambda *a, **k: 1 / 0               # a última seção (6) estoura
    argv = ["report", "--ledger", str(w["ledger"]), "--gate-log", str(w["gate"]), "--from", "2026-09-30"]
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = m.main(argv)
    txt = out.getvalue()
    ck(code == 1, f"seção que estoura = exit 1, nunca 0; saiu {code}")
    for sec in ("== 1.", "== 2.", "== 3.", "== 4.", "== 5."):
        ck(sec in txt, f"a seção '{sec}' já estava pronta e tem que continuar na saída; saída: {txt[-400:]}")
    ck("RELATÓRIO INCOMPLETO" in txt and "ZeroDivisionError" in txt, f"a saída diz que ficou incompleto e por quê; achei {txt[-300:]}")
    ck("Traceback" in err.getvalue() and "ZeroDivisionError" in err.getvalue(), "o traceback vai para o stderr")
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = m.main(argv + ["--json"])
    r = json.loads(out.getvalue())
    ck(code == 1 and r["exit_code"] == 1 and r["error_type"] == "ZeroDivisionError" and r["by_role"] and r["cohorts"] and r["system"]["approved_beads"] == 3,
       f"--json: o que já foi calculado (by_role, cohorts, system) sobrevive, com error e exit 1; achei chaves {sorted(r)}")


def t_lows(m, W):
    """Achados não-bloqueantes do gate, mesma família (desconhecido lido como valor): claim sem resultado chamado de 'verificado';
    veredito sem dry_run lido como ensaio; resposta sem timestamp caindo calada no overhead de partida e em todas as janelas."""
    w, _ = setup(m, W)
    P = w["projects"]
    # (1) claim SEM resultado visível: conta, mas a linha de atribuição não o chama de 'verificado'
    recs = [beacon("gastown.dog-8", D + "16:00:00Z")] + asst("n1", D + "16:00:10Z", cmd="bd update ga-nnn1 --claim", tid="tu_nn") + asst("n2", D + "16:01:00Z")
    write_session(P, "-proj", "noresult2", recs)
    with open(w["gate"], "a") as fh:
        fh.write(json.dumps({"ts": D + "16:10:00Z", "event": "dispatcher_complete", "branch": "feat/ga-nnn1", "bead": "ga-nnn1", "rig": "gascity", "result": "PASS", "dry_run": "0"}) + "\n")
    harvest(m, w)
    code, r = report(m, w)
    ck(r["coverage"]["attribution"] == dict(claim_verified=2, claim_no_result=1, ref=1),
       f"A e B por claim verificado, ga-nnn1 por claim SEM resultado, wa-zzz1 por referência; achei {r['coverage'].get('attribution')}")
    code, txt = report_text(m, w)
    ck("1 por claim SEM resultado visível" in txt and "2 por `bd update --claim` com resultado verificado" in txt, f"texto da atribuição: {[ln for ln in txt.splitlines() if 'atribuição' in ln]}")
    # (2) veredito do gate SEM dry_run (ausente ou null): não sei se foi real ou ensaio — conta como ilegível, não some como ensaio
    g3 = W / "g3.jsonl"
    g3.write_text("\n".join(json.dumps(e) for e in [
        {"ts": D + "11:00:00Z", "event": "dispatcher_complete", "branch": "feat/ga-nd1", "bead": "ga-nd1", "result": "PASS"},
        {"ts": D + "11:01:00Z", "event": "dispatcher_complete", "branch": "feat/ga-nd2", "bead": "ga-nd2", "result": "FAIL", "dry_run": None},
        GATE_EVENTS[1], GATE_EVENTS[5]]) + "\n")                       # [1] = real PASS; [5] = ensaio (dry_run "1"): fora, sem ser 'ilegível'
    runs, _bridge, bad = m.load_gate(g3)
    ck([x["bead"] for x in runs] == ["ga-aaa1"] and bad == 2, f"load_gate: só o real entra; sem dry_run e dry_run null = 2 ilegíveis; o ensaio fica de fora; achei {[x['bead'] for x in runs]} bad={bad}")
    # (3) resposta SEM timestamp: contada na colheita, avisada, e o relatório diz que ela está em todas as janelas
    ut = asst("nt1", D + "10:00:10Z")
    for x in ut:
        del x["timestamp"]
    write_session(P, "-proj", "untimed_msg", [beacon("gastown.dog-6", D + "10:00:00Z")] + ut + asst("nt2", D + "10:01:00Z"))
    out = harvest(m, w)
    ck(ledger_rows(m, w)["untimed_msg"]["msgs_untimed"] == 1, f"resposta sem timestamp é contada no registro; achei {ledger_rows(m, w)['untimed_msg'].get('msgs_untimed')}")
    ck("1 respostas sem timestamp" in out, f"a colheita avisa: {out}")
    code, r = report(m, w)
    ck(r["undated_msgs"] == 1, f"o relatório conta as respostas de dia desconhecido; achei {r.get('undated_msgs')}")
    code, txt = report_text(m, w)
    ck("1 respostas SEM timestamp" in txt and "TODAS as janelas" in txt, "o texto do relatório avisa que elas entram em todas as janelas")


def asst_noid(mid, ts, cmd):
    """Resposta cujo tool_use NÃO traz id (nenhum resultado consegue apontar para ele)."""
    return [{"type": "assistant", "timestamp": ts, "effort": "xhigh", "message": {"id": mid, "model": "claude-sonnet-5-5", "usage": dict(U_SMALL),
             "content": [{"type": "tool_use", "name": "Bash", "input": {"command": cmd}}]}}]


def scan_recs(m, w, sid, recs):
    write_session(w["projects"], "-proj", sid, recs)
    return m.scan_session(w["projects"] / "-proj" / f"{sid}.jsonl")


def bucket_msgs(rec):
    return {k: sum(c["msgs"] for c in v.values()) for k, v in rec["buckets"].items()}


def t_claim_states(m, W):
    """Gate (tentativa 2, bloqueantes 1 e 2): o RESULTADO VISÍVEL de um claim e a AUSÊNCIA de resultado são dois estados. Um comando que só
    CITA `bd update <id> --claim` (heredoc, echo, mensagem de commit) tem resultado visível que não confirma nada: não é claim e não abre
    bucket — antes virava claim vivo (ok=None) e a sessão inteira passava para o bead fantasma (real: 75 de 103 msgs da sessão aa9cc819).
    Dois claims num comando compartilham UM tool_use id: cada um tem o seu resultado e o seu estado."""
    w, _ = setup(m, W)
    head = lambda alias="gastown.dog-5": [beacon(alias, D + "10:00:00Z")]
    real = lambda tid="tu_r": (asst("a1", D + "10:00:10Z", cmd="gc bd update ga-real11 --claim", tid=tid)
                               + [tool_result(tid, "warning: pack differs\n✓ Updated issue: ga-real11 — build", D + "10:00:11Z")] + asst("a2", D + "10:01:00Z"))
    more = lambda n0, n: sum((asst(f"a{i}", D + f"10:{i:02d}:00Z") for i in range(n0, n0 + n)), [])
    # (1) heredoc que cita o claim, resultado VISÍVEL e vazio
    rec = scan_recs(m, w, "ph1", head() + real() + asst("a3", D + "10:02:00Z", cmd="cat > fx.sh <<'EOF'\nbd update ga-fake11 --claim\nEOF", tid="tu_f")
                    + [tool_result("tu_f", "", D + "10:02:01Z")] + more(4, 5))
    ck([c["bead"] for c in rec["claims"]] == ["ga-real11"] and rec["claims"][0]["ok"] is True, f"(1) só o claim real, verificado; achei {rec['claims']}")
    ck(bucket_msgs(rec) == {"ga-real11": 8}, f"(1) todas as 8 respostas ficam no bead real (o fantasma não toma a sessão); achei {bucket_msgs(rec)}")
    ck(rec["claims_unconfirmed"] == 1 and rec["claims_failed"] == 0, f"(1) o comando que só citou o claim é contado como 'resultado visível que não confirma'; achei unconfirmed={rec.get('claims_unconfirmed')} failed={rec['claims_failed']}")
    # (2) echo: o resultado visível REPETE o texto do comando, sem palavra de erro
    rec = scan_recs(m, w, "ph2", head() + real() + asst("a3", D + "10:02:00Z", cmd='echo "bd update ga-fake22 --claim"', tid="tu_e")
                    + [tool_result("tu_e", "bd update ga-fake22 --claim", D + "10:02:01Z")] + more(4, 2))
    ck([c["bead"] for c in rec["claims"]] == ["ga-real11"] and rec["claims_unconfirmed"] == 1, f"(2) echo não é claim; achei {rec['claims']} unc={rec.get('claims_unconfirmed')}")
    # (3) o resultado confirma OUTRO id: não confirma este
    rec = scan_recs(m, w, "ph3", head() + asst("b1", D + "10:00:10Z", cmd="bd update ga-aaa9 --claim", tid="tu_x")
                    + [tool_result("tu_x", "✓ Updated issue: ga-zzz9 — outro", D + "10:00:11Z")] + more(2, 2))
    ck(rec["claims"] == [] and rec["claims_unconfirmed"] == 1, f"(3) 'Updated issue' de outro id não confirma ga-aaa9; achei {rec['claims']} unc={rec.get('claims_unconfirmed')}")
    # (4) SEM resultado nenhum (transcrito cortado / sessão em curso): continua claim vivo, ok None, e NÃO é 'não confirmado'
    rec = scan_recs(m, w, "ph4", head() + asst("c1", D + "10:00:10Z", cmd="bd update ga-nores1 --claim", tid="tu_n") + more(2, 2))
    ck([(c["bead"], c["ok"]) for c in rec["claims"]] == [("ga-nores1", None)] and rec["claims_unconfirmed"] == 0, f"(4) sem resultado = ok None vivo, não 'não confirmado'; achei {rec['claims']}")
    # (5) o TÍTULO do bead tem palavra de erro: a confirmação do id vence a regex de erro (um claim real não vira 'falhou')
    rec = scan_recs(m, w, "ph5", head() + asst("d1", D + "10:00:10Z", cmd="bd update ga-title1 --claim", tid="tu_t")
                    + [tool_result("tu_t", "✓ Updated issue: ga-title1 — fix error already failed not found", D + "10:00:11Z")] + more(2, 1))
    ck([(c["bead"], c["ok"]) for c in rec["claims"]] == [("ga-title1", True)] and rec["claims_failed"] == 0, f"(5) título com 'error' não derruba o claim confirmado; achei {rec['claims']} failed={rec['claims_failed']}")
    # (6) DOIS claims num comando, um resultado que confirma os dois: cada um é um claim; o bucket é compartilhado (rateio igual)
    both = (asst("e0", D + "10:00:00.500Z") + asst("e1", D + "10:00:10Z", cmd="bd update ga-mm01 --claim && bd update ga-mm02 --claim", tid="tu_m")
            + [tool_result("tu_m", "✓ Updated issue: ga-mm01 — a\n✓ Updated issue: ga-mm02 — b", D + "10:00:11Z")] + more(2, 4))
    rec = scan_recs(m, w, "ph6", head() + both)
    ck(sorted((c["bead"], c["ok"]) for c in rec["claims"]) == [("ga-mm01", True), ("ga-mm02", True)], f"(6) os DOIS claims do comando existem e estão verificados; achei {rec['claims']}")
    ck(bucket_msgs(rec) == {"_pre": 1, "_grp:ga-mm01,ga-mm02": 5}, f"(6) as respostas depois dos dois claims (mesmo instante) vão para UM bucket do grupo; achei {bucket_msgs(rec)}")
    for b in ("ga-mm01", "ga-mm02"):
        with open(w["gate"], "a") as fh:
            fh.write(json.dumps({"ts": D + "13:00:00Z", "event": "dispatcher_complete", "branch": f"feat/{b}", "bead": b, "rig": "gascity", "result": "PASS", "dry_run": "0"}) + "\n")
    harvest(m, w)
    code, r = report(m, w)
    ck(r["beads"]["ga-mm01"]["build_tokens"] == 300 and r["beads"]["ga-mm02"]["build_tokens"] == 300,
       f"(6) cada bead leva metade do grupo (250) + metade do pré (50) = 300; achei {r['beads'].get('ga-mm01', {}).get('build_tokens')} / {r['beads'].get('ga-mm02', {}).get('build_tokens')} (nenhum fica com custo 0 só por ter sido pedido no mesmo instante)")
    # (7) dois claims num comando, o 2º falha: o 1º foi feito (o texto o confirma, mesmo com is_error), o 2º falhou
    rec = scan_recs(m, w, "ph7", head() + asst("f1", D + "10:00:10Z", cmd="bd update ga-nn01 --claim && bd update ga-nn02 --claim", tid="tu_k")
                    + [tool_result("tu_k", "✓ Updated issue: ga-nn01 — a\nError: issue ga-nn02 already claimed", D + "10:00:11Z", is_error=True)] + more(2, 3))
    ck([(c["bead"], c["ok"]) for c in rec["claims"]] == [("ga-nn01", True)] and rec["claims_failed"] == 1 and bucket_msgs(rec) == {"ga-nn01": 4},
       f"(7) ga-nn01 verificado, ga-nn02 falhou; achei {rec['claims']} failed={rec['claims_failed']} {bucket_msgs(rec)}")
    # (9) formato do resultado SEM o id ("Updated issue" puro): dá para atribuir quando o comando tinha UM claim; com dois, não dá — nenhum vira claim
    rec = scan_recs(m, w, "ph9a", head() + asst("h1", D + "10:00:10Z", cmd="bd update ga-old01 --claim", tid="tu_o1")
                    + [tool_result("tu_o1", "✓ Updated issue", D + "10:00:11Z")] + more(2, 2))
    ck([(c["bead"], c["ok"]) for c in rec["claims"]] == [("ga-old01", True)], f"(9a) formato sem id + UM claim = confirmado; achei {rec['claims']}")
    rec = scan_recs(m, w, "ph9b", head() + asst("h1", D + "10:00:10Z", cmd="bd update ga-old02 --claim && bd update ga-old03 --claim", tid="tu_o2")
                    + [tool_result("tu_o2", "✓ Updated issue\n✓ Updated issue", D + "10:00:11Z")] + more(2, 2))
    ck(rec["claims"] == [] and rec["claims_unconfirmed"] == 2, f"(9b) formato sem id + DOIS claims: não dá para dizer qual é qual, nenhum vira bead; achei {rec['claims']} unc={rec.get('claims_unconfirmed')}")
    # (8) tool_use SEM id entre claims: a chave de espera não pode colidir depois que um resultado a liberou
    rec = scan_recs(m, w, "ph8", head() + asst("g1", D + "10:00:10Z", cmd="bd update ga-q001 --claim", tid="tu_q1") + asst_noid("g2", D + "10:00:20Z", "bd update ga-q002 --claim")
                    + [tool_result("tu_q1", "✓ Updated issue: ga-q001 — a", D + "10:00:21Z")] + asst_noid("g3", D + "10:00:30Z", "bd update ga-q003 --claim") + more(4, 2))
    ck(sorted(c["bead"] for c in rec["claims"]) == ["ga-q001", "ga-q002", "ga-q003"], f"(8) nenhum claim some por colisão de chave; achei {sorted(c['bead'] for c in rec['claims'])}")


def t_claim_not_a_reference(m, W):
    """Um claim que FALHOU não pode virar atribuição por referência: `bd update <id> --claim` casa REF_CMD, e o perdedor da corrida pelo
    bead (3 sessões pequenas de dog nos dados reais) ficava com a sessão inteira atribuída a um bead que ele nunca construiu."""
    w, _ = setup(m, W)
    recs = [beacon("wa-worker-adhoc-lose1", D + "15:00:00Z")] + asst("l1", D + "15:00:10Z", cmd="bd update wa-lose1 --claim", tid="tu_l")
    recs += [tool_result("tu_l", "Error: issue wa-lose1 already claimed by someone", D + "15:00:11Z", is_error=True)] + asst("l2", D + "15:01:00Z")
    rec = scan_recs(m, w, "loser", recs)
    ck(rec["claims"] == [] and rec["claims_failed"] == 1 and rec["refs"] == [], f"claim perdido: sem bead, sem referência; achei claims={rec['claims']} refs={rec['refs']}")
    # a referência de verdade (bd show/comment de um bead já atribuído) continua valendo, mesmo no comando que também reivindica
    recs = [beacon("wa-worker-adhoc-keep1", D + "15:00:00Z")] + asst("k1", D + "15:00:10Z", cmd="bd show wa-keep1 && bd update wa-keep1 --claim", tid="tu_k1")
    recs += [tool_result("tu_k1", "warning\n(no output)", D + "15:00:11Z")] + asst("k2", D + "15:01:00Z", cmd="bd comment wa-keep1 'x'", tid="tu_k2")
    rec = scan_recs(m, w, "keeper", recs)
    ck(rec["claims"] and rec["claims"][0]["bead"] == "wa-keep1" and rec["claims"][0]["via"] == "ref", f"`bd show`/`bd comment` seguem sendo referência; achei {rec['claims']}")


def t_idle_vs_untimed_claim(m, W):
    """Seção 2: sessão de pool que reivindicou mas sem timestamp (não dá para posicionar) NÃO é ociosa — é um desconhecido com linha própria."""
    w, _ = setup(m, W)
    ut = asst("u1", D + "17:00:10Z", cmd="bd update wa-unt01 --claim", tid="tu_u") + [tool_result("tu_u", "✓ Updated issue: wa-unt01 — x", D + "17:00:11Z")]
    for x in ut[:3]:
        del x["timestamp"]
    write_session(w["projects"], "-proj", "untimed_claim", [beacon("wa-worker-adhoc-unt01", D + "17:00:00Z")] + ut + asst("u2", D + "17:01:00Z"))
    harvest(m, w)
    s = ledger_rows(m, w)["untimed_claim"]
    ck(s["claims"] == [] and s["claims_untimed"] == 1, f"o claim sem timestamp fica fora de `claims` e é contado; achei {s['claims']} untimed={s['claims_untimed']}")
    code, r = report(m, w)
    ck(r["idle"].get("wa-worker", {}).get("sessions", 0) == 0, f"sessão com claim sem timestamp NÃO é spawn ocioso; achei {r['idle'].get('wa-worker')}")
    ck(r["idle"].get("wa-worker", {}).get("claim_untimed_sessions") == 1, f"…e tem contagem própria; achei {r['idle'].get('wa-worker')}")
    code, txt = report_text(m, w)
    ck("1 sessões com claim SEM timestamp" in txt, f"o texto da seção 2 avisa; achei {[ln for ln in txt.splitlines() if 'sem timestamp' in ln.lower()]}")


def t_report_unknown_counters(m, W):
    """O --json não pode ter MENOS avisos que o texto: janela incompleta, linhas ilegíveis do ledger e os desconhecidos que a colheita grava
    por sessão (resposta sem usage, claim sem timestamp, claim que não confirmou) vão para o resultado, e o texto os imprime."""
    w, _ = setup(m, W)
    nu = asst("nu1", D + "18:00:10Z")
    for x in nu:
        del x["message"]["usage"]
    recs = [beacon("gastown.dog-6", D + "18:00:00Z")] + nu + asst("nu2", D + "18:01:00Z", cmd="echo 'bd update ga-cit01 --claim'", tid="tu_c1") + [tool_result("tu_c1", "bd update ga-cit01 --claim", D + "18:01:01Z")]
    write_session(w["projects"], "-proj", "unk1", recs)
    harvest(m, w)
    with open(w["ledger"], "a") as fh:
        fh.write("{linha ilegível do ledger\n")
    code, r = report(m, w)
    ck(r.get("ledger_unreadable_lines") == 1, f"linhas ilegíveis do ledger no JSON; achei {r.get('ledger_unreadable_lines')}")
    ck(r.get("window_incomplete") is True and (r.get("pool_floor") or "").startswith("2026-09-30"), f"JANELA INCOMPLETA no JSON (o 1º transcrito de pool é de 30/09, a janela começa em 30/09); achei {r.get('window_incomplete')} {r.get('pool_floor')}")
    u = r.get("unknown") or {}
    ck(u.get("usage_msgs") == 1 and u.get("claims_unconfirmed") == 1, f"respostas sem usage e claims não confirmados no JSON; achei {u}")
    for k in ("claims_untimed", "msgs_untimed", "transcript_lines_unreadable", "claims_failed", "rows_old_schema"):
        ck(k in u, f"o objeto `unknown` tem a chave {k}; achei {sorted(u)}")
    code, txt = report_text(m, w)
    ck("1 respostas SEM usage" in txt and "1 claims com resultado visível que NÃO confirma" in txt, f"o texto imprime os mesmos avisos; achei {[ln for ln in txt.splitlines() if '⚠' in ln]}")
    # janela que COMEÇA depois do 1º transcrito de pool: completa
    write_session(w["projects"], "-proj", "early", [beacon("gastown.dog-2", "2026-09-29T08:00:00Z")] + asst("e1", "2026-09-29T08:00:10Z"))
    harvest(m, w)
    code, r = report(m, w)
    ck(r.get("window_incomplete") is False, f"com um transcrito de pool ANTES da janela ela está completa; achei {r.get('window_incomplete')}")


def t_schema_rescan(m, W):
    """A regra de claim mudou (SCHEMA 3): uma linha escrita pela regra antiga (v=2) pode ter claim fantasma e NÃO pode ser mantida só porque o
    transcrito não mudou — a colheita a reescaneia; e enquanto ela existir no ledger (transcrito já apagado) o relatório diz quantas há."""
    w, _ = setup(m, W)
    rows = ledger_rows(m, w)
    s = rows["dog1"]
    s["v"] = 2
    s["claims"] = s["claims"] + [dict(bead="ga-phantom", ts=D + "10:03:30.000Z", ok=None, via="claim")]
    m.write_ledger(rows, w["ledger"])
    code, r = report(m, w)
    ck((r.get("unknown") or {}).get("rows_old_schema", 0) >= 1, f"o relatório conta as linhas de schema antigo na janela; achei {r.get('unknown')}")
    code, txt = report_text(m, w)
    ck("schema antigo" in txt, f"o texto avisa que há claims não revalidados; achei {[ln for ln in txt.splitlines() if '⚠' in ln]}")
    harvest(m, w)
    s = ledger_rows(m, w)["dog1"]
    ck(s["v"] == m.SCHEMA and m.SCHEMA >= 3 and all(c["bead"] != "ga-phantom" for c in s["claims"]), f"a colheita reescaneou a linha v=2 (transcrito intacto); v={s['v']} claims={s['claims']}")
    code, r = report(m, w)
    ck((r.get("unknown") or {}).get("rows_old_schema") == 0, f"depois do rescan não resta linha antiga; achei {r.get('unknown')}")


def t_harvest_alarm_first_and_nonzero(m, W):
    """Alarme de formato do transcrito (todas as sessões grandes voltaram com 0 respostas): o wrapper do order corta a linha de log em 500
    caracteres e o alarme era o ÚLTIMO texto com exit 0 — a 1ª coisa que o corte joga fora. Agora é a PRIMEIRA linha e o exit é ≠ 0."""
    w, _ = setup(m, W)
    big = [{"type": "attachment", "timestamp": D + "10:00:00Z", "attachment": {"n": i}} for i in range(40)]
    for i in range(3):
        write_session(w["projects"], "-proj", f"weird{i}", [{"type": "msg-v9", "n": j} for j in range(40)] + big)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
    lines = out.getvalue().splitlines()
    ck(rc not in (0, None), f"formato do transcrito mudou -> exit ≠ 0 (o order enxerga); achei rc={rc}")
    ck(lines and "formato do transcrito mudou" in lines[0], f"o alarme é a 1ª linha; achei {lines[:1]}")
    ck(any(ln.startswith("harvest:") for ln in lines[1:]), "a linha-resumo da colheita continua lá, depois do alarme")
    ck(w["ledger"].exists() and len(ledger_rows(m, w)) >= 9, "o ledger foi escrito mesmo com o alarme (o alarme não perde a colheita)")
    # sem alarme: exit 0 e a linha-resumo é a 1ª
    W2 = W / "calm"
    W2.mkdir()
    w2 = setup(m, W2)[0]
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = m.cmd_harvest(type("A", (), dict(ledger=str(w2["ledger"]), since_hours=0))())
    ck(rc == 0 and out.getvalue().startswith("harvest:"), f"sem alarme: exit 0 e o resumo abre a saída; rc={rc} {out.getvalue()[:60]!r}")


def t_e2_readout_missing_dry_run(m, W):
    """e2-readout.py (mesma família do load_gate): um veredito do gate SEM dry_run não pode sumir como 'ensaio' — é contado e impresso."""
    script = HERE.parents[2] / "docs" / "reports" / "token-por-bead-e8" / "e2-readout.py"
    ck(script.exists(), f"o script do E2 existe em {script}")
    city = W / "city"
    (city / ".gc" / "token-ledger").mkdir(parents=True)
    # + uma linha ilegível e um JSON válido que não é registro (`null`): o script as CONTA em vez de calar (ou de estourar no `.get`)
    (city / ".gc" / "token-ledger" / "sessions.jsonl").write_text(json.dumps(dict(sid="c1", role="crew", alias="peter-wa", first_ts="2026-09-30T10:00:00Z", days={})) + "\n{ilegivel\nnull\n")
    ev = [{"ts": "2026-09-30T11:00:00Z", "event": "guard_queued", "branch": "crew/peter/wa-aaa", "bead": "wa-aaa"},
          {"ts": "2026-09-30T12:00:00Z", "event": "dispatcher_complete", "branch": "crew/peter/wa-aaa", "bead": "wa-aaa", "result": "PASS", "dry_run": "0"},
          {"ts": "2026-09-30T11:00:00Z", "event": "guard_queued", "branch": "crew/peter/wa-bbb", "bead": "wa-bbb"},
          {"ts": "2026-09-30T12:00:00Z", "event": "dispatcher_complete", "branch": "crew/peter/wa-bbb", "bead": "wa-bbb", "result": "FAIL"},
          {"ts": "2026-09-30T13:00:00Z", "event": "dispatcher_complete", "branch": "crew/peter/wa-ccc", "bead": "wa-ccc", "result": "PASS", "dry_run": None}]
    (city / ".gc" / "quality-gate.jsonl").write_text("\n".join(json.dumps(e) for e in ev) + "\nnull\n")
    import subprocess
    p = subprocess.run([sys.executable, str(script)], capture_output=True, text=True, env=dict(os.environ, GC_CITY_PATH=str(city)))
    ck(p.returncode == 0, f"o script roda no fixture (o `null` não estoura o `.get`); rc={p.returncode} {p.stderr[-300:]}")
    ck("2 verdicts without dry_run" in p.stdout, f"os 2 vereditos sem dry_run são contados e impressos; achei {[ln for ln in p.stdout.splitlines() if 'dry_run' in ln]}")
    ck("with a real verdict: 1 " in p.stdout, f"só o veredito real (dry_run '0') entra na amostra; achei {[ln for ln in p.stdout.splitlines() if 'verdict' in ln]}")
    ck("2 unreadable ledger lines" in p.stdout, f"as 2 linhas do ledger que não são registro são contadas; achei {[ln for ln in p.stdout.splitlines() if 'ledger' in ln]}")
    ck("1 unreadable lines" in p.stdout, f"a linha do log do gate que não é evento é contada; achei {[ln for ln in p.stdout.splitlines() if 'gate log' in ln]}")


def t_idle_vs_unconfirmed_claim(m, W):
    """Seção 2, irmã do claim sem timestamp: sessão de pool cujo ÚNICO claim teve resultado VISÍVEL que não confirma não é ociosa — não sei se
    pegou bead, e 'não vi o claim dar certo' não é 'não reivindicou'. Ela ganha linha própria; o spawn ocioso de verdade continua ocioso."""
    w, _ = setup(m, W)
    base = report(m, w)[1]["idle"].get("wa-worker", {}).get("sessions", 0)
    # o claim é real mas o resultado é de um formato que o medidor não reconhece (sem "Updated issue: <id>")
    recs = [beacon("wa-worker-adhoc-unc01", D + "17:30:00Z")] + asst("n1", D + "17:30:10Z", cmd="bd update wa-unc01 --claim", tid="tu_n")
    recs += [tool_result("tu_n", "ok (formato novo, sem a frase de confirmação)", D + "17:30:11Z")] + asst("n2", D + "17:31:00Z")
    write_session(w["projects"], "-proj", "unconf_only", recs)
    write_session(w["projects"], "-proj", "really_idle", [beacon("wa-worker-adhoc-idle01", D + "17:40:00Z")] + asst("i1", D + "17:40:10Z"))
    harvest(m, w)
    s = ledger_rows(m, w)["unconf_only"]
    ck(s["claims"] == [] and s["claims_unconfirmed"] == 1, f"o claim não confirmado fica fora de `claims` e é contado; achei {s['claims']} unconfirmed={s['claims_unconfirmed']}")
    code, r = report(m, w)
    idle = r["idle"]["wa-worker"]
    ck(idle["sessions"] == base + 1, f"só o spawn ocioso de verdade (sem claim nenhum) é ocioso: {base} + 1; achei {idle['sessions']} ({idle})")
    ck(idle["claim_unconfirmed_sessions"] == 1, f"a sessão com claim não confirmado tem contagem própria; achei {idle}")
    code, txt = report_text(m, w)
    ck("1 sessões com claim NÃO confirmado" in txt, f"o texto da seção 2 avisa; achei {[ln for ln in txt.splitlines() if 'NÃO confirmado' in ln]}")
    ck("`bd show|comment|heartbeat|close|label|update|reopen`" in txt, f"o texto da atribuição lista TODOS os verbos que contam como referência; achei {[ln for ln in txt.splitlines() if 'por referência' in ln]}")


def t_non_record_json_lines(m, W):
    """JSON válido que não é um registro (`null`, `"user"`, `["assistant", 1]`) não derruba nada: é uma linha ilegível, CONTADA. Antes o `.get`
    estourava com AttributeError e levava a colheita (ou o relatório) inteira embora."""
    w, _ = setup(m, W)
    # transcrito: as linhas passam do pré-filtro (têm "user"/"assistant") mas não são registros
    recs = [beacon("gastown.dog-9", D + "19:00:00Z"), "user", ["assistant", 1]] + asst("z1", D + "19:00:10Z")
    rec = scan_recs(m, w, "weird_lines", recs)
    ck(rec["bad_lines"] == 2 and rec["msgs"] == 1, f"2 linhas que não são registro contadas e a resposta real lida; achei bad={rec['bad_lines']} msgs={rec['msgs']}")
    # ledger: linhas que não são sessão
    n_before = len(ledger_rows(m, w))
    with open(w["ledger"], "a") as fh:
        fh.write("null\n[1]\n\"x\"\n{\"role\": \"dog\"}\n")      # + um objeto JSON SEM `sid`: também não é uma linha de sessão
    rows, bad = m.load_ledger(w["ledger"])
    ck(bad == 4 and len(rows) == n_before, f"4 linhas do ledger que não são sessão contadas (3 que não são objeto + 1 objeto sem sid), as sessões intactas; achei bad={bad} rows={len(rows)}/{n_before}")
    # log do gate: linhas que não são evento (o mundo-base já tem 1 linha ilegível de propósito: compara com ela, não com um número solto)
    runs0, _b0, gbad0 = m.load_gate(w["gate"])
    with open(w["gate"], "a") as fh:
        fh.write("null\n[1]\n")
    runs, bridge, gbad = m.load_gate(w["gate"])
    ck(gbad == gbad0 + 2 and len(runs) == len(runs0), f"2 linhas do log do gate que não são evento contadas ({gbad0} + 2), os vereditos reais intactos; achei bad={gbad} runs={len(runs or [])}/{len(runs0)}")
    code, r = report(m, w)
    ck(code == 0 and r["coverage"]["gate_unreadable_lines"] == gbad0 + 2, f"o relatório inteiro roda e mostra as linhas do gate; exit {code} {r.get('coverage')}")


def t_power_unreachable_drop(m, W):
    """Seção 6: com taxa de 1ª aprovação MENOR que a queda a detectar, uma queda desse tamanho não existe (a taxa não passa de 0). Antes saía
    '0 beads por braço' (max(0, p-diff)) — lido como 'não precisa de amostra'. Agora é n/a, no texto e no JSON."""
    ck(m.n_per_arm_prop(0.0, 0.03) is None and m.n_per_arm_prop(0.02, 0.03) is None, "p < queda -> None (não 0)")
    ck(m.n_per_arm_prop(0.03, 0.03) and m.n_per_arm_prop(0.5, 0.03) > 1000, "p == queda ainda é calculável (p2 = 0); p = 50% pede milhares para 3 pp")
    beads = [dict(bead=f"ga-pp{i:02d}", model="claude-sonnet-5-5", k=3 + i % 5) for i in range(24)]
    w = mini_world(m, W, beads)
    ev = [{"ts": f"{D}12:{i % 60:02d}:00Z", "event": "dispatcher_complete", "branch": f"feat/{b['bead']}", "bead": b["bead"], "rig": "gascity",
           "result": "PASS" if i == 0 else "FAIL", "dry_run": "0"} for i, b in enumerate(beads)]
    w["gate"].write_text("\n".join(json.dumps(e) for e in ev) + "\n")          # 1 de 24 na 1ª rodada: p = 4,2%
    code, r = report(m, w)
    pw = r["power"]["dog"]
    ck(code == 0 and pw["n_per_arm_first_pass"]["10pp"] is None and pw["n_per_arm_first_pass"]["5pp"] is None and pw["days_first_pass"]["10pp"] is None,
       f"queda de 10 pp e de 5 pp com p = 4,2%: n/a (null) no JSON; achei {pw}")
    ck(pw["n_per_arm_first_pass"]["3pp"] and pw["n_per_arm_first_pass"]["3pp"] > 0, f"a de 3 pp existe e é calculada; achei {pw['n_per_arm_first_pass']}")
    code, txt = report_text(m, w)
    ck("n/a (taxa<Δ)" in txt and "uma queda desse tamanho não existe" in txt, f"o texto diz n/a e por quê; achei {[ln for ln in txt.splitlines() if 'dog' in ln and '|' in ln]}")


@contextlib.contextmanager
def denied(path):
    """Tira TODA permissão de `path` (arquivo ou diretório) e prova que a negação vale neste ambiente; restaura ao sair (senão o rmtree do
    selftest não consegue limpar). Em root a negação não vale: o caso falha com a razão, em vez de passar sem provar nada."""
    path = Path(path)
    old = path.stat().st_mode
    path.chmod(0)
    try:
        ck(not os.access(path, os.R_OK), f"este ambiente ignora permissão de arquivo (root?): o caso não prova nada sobre {path.name}")
        yield
    finally:
        path.chmod(stat.S_IMODE(old))


def harvest_rc(m, w):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = m.cmd_harvest(type("A", (), dict(ledger=str(w["ledger"]), since_hours=0))())
    return rc, out.getvalue()


def t_harvest_input_unreadable(m, W):
    """Gate (tentativa 3, bloqueante 2): uma raiz de transcritos ausente/ilegível era "nada a colher" — o harvest imprimia o resumo normal
    ('0 sessões (re)escaneadas, 0 inalteradas'), saía com 0, o order ficava verde, e o reaper apagava os transcritos 24h depois. São TRÊS
    estados (achei / não há / NÃO CONSEGUI LER); o terceiro tem alarme próprio, 1ª linha e exit ≠ 0 — e o ledger continua intacto."""
    w, _ = setup(m, W)
    good = ledger_rows(m, w)
    ck(len(good) >= 5, f"mundo-base com sessões; achei {len(good)}")
    snap = w["ledger"].read_bytes()
    P = w["projects"]

    def alarm(roots, label, why, rc_want=6):
        m.PROJECTS = roots
        rc, out = harvest_rc(m, w)
        lines = out.splitlines()
        ck(rc == rc_want == m.RC_NO_INPUT, f"{label}: exit {rc_want} (entrada que não deu para ler), achei {rc}")
        ck(lines and lines[0].startswith("⚠ SEM ENTRADA") and why in lines[0], f"{label}: o alarme é a 1ª linha e diz '{why}'; achei {lines[:1]}")
        ck(any(ln.startswith("harvest:") for ln in lines[1:]), f"{label}: a linha-resumo continua, depois do alarme")
        return out

    # (a) raiz que não existe — a reprodução do revisor (BTM_PROJECTS=<diretório inexistente>)
    alarm([W / "nao-existe"], "raiz inexistente", "não existe")
    ck(w["ledger"].read_bytes() == snap, "o ledger não perde nem muda nada quando a entrada falta (a colheita anterior continua valendo)")
    # (b) a "raiz" é um arquivo
    (W / "arquivo").write_text("x")
    alarm([W / "arquivo"], "raiz que é arquivo", "não é um diretório")
    # (c) raiz existe mas está vazia: zero transcritos num city vivo não é "nada a colher"
    (W / "vazia").mkdir()
    alarm([W / "vazia"], "raiz vazia", "0 transcritos")
    # (d) nenhuma raiz configurada
    alarm([], "lista de raízes vazia", "nenhuma raiz de transcritos configurada")
    # (e) uma raiz boa e uma ausente: o que dá para ler é colhido (ledger novo), e ainda assim o exit é ≠ 0
    w2 = dict(w, ledger=W / "l2" / "sessions.jsonl")
    m.PROJECTS = [P, W / "nao-existe"]
    rc, out = harvest_rc(m, w2)
    ck(rc == 6 and "não existe" in out.splitlines()[0] and len(ledger_rows(m, w2)) == len(good), f"raiz boa + raiz ausente: colhe a boa ({len(good)} sessões) e sai com 6; achei rc={rc} rows={len(ledger_rows(m, w2))}")
    # (f) uma raiz sem permissão
    (W / "fechada").mkdir()
    with denied(W / "fechada"):
        alarm([W / "fechada"], "raiz sem permissão", "ilegível")
    # (g) um PROJETO ilegível dentro de uma raiz boa: o glob o pulava calado; as sessões dos outros projetos são colhidas mesmo assim
    write_session(P, "-trancado", "lk1", [beacon("gastown.dog-4", D + "22:00:00Z")] + asst("l1", D + "22:00:10Z"))
    w3 = dict(w, ledger=W / "l3" / "sessions.jsonl")
    with denied(P / "-trancado"):
        m.PROJECTS = [P]
        rc, out = harvest_rc(m, w3)
    ck(rc == 6 and "projeto ilegível" in out.splitlines()[0], f"projeto ilegível: alarme + exit 6; achei rc={rc} {out.splitlines()[:1]}")
    ck(len(ledger_rows(m, w3)) == len(good) and "lk1" not in ledger_rows(m, w3), f"os outros projetos continuam sendo colhidos; achei {len(ledger_rows(m, w3))} sessões")
    # (h) o caso saudável não acende nada
    m.PROJECTS = [P]
    (P / "-trancado" / "lk1.jsonl").unlink()
    (P / "-trancado").rmdir()
    rc, out = harvest_rc(m, w)
    ck(rc == 0 and "SEM ENTRADA" not in out, f"entrada boa: exit 0 e nenhum alarme de entrada; achei rc={rc} {out[:80]!r}")
    # (i) pela linha de comando, como o wrapper do order a chama (a reprodução do revisor, de ponta a ponta)
    import subprocess
    p = subprocess.run([sys.executable, str(TOOL), "harvest", "--ledger", str(W / "l4" / "sessions.jsonl")], capture_output=True, text=True,
                       env=dict(os.environ, BTM_PROJECTS=str(W / "nao-existe-cli")))
    ck(p.returncode == 6 and p.stdout.startswith("⚠ SEM ENTRADA"), f"CLI com BTM_PROJECTS inexistente: exit 6 e o alarme abre a saída; achei rc={p.returncode} {p.stdout[:90]!r}")
    ck(len(p.stdout.splitlines()[0]) <= 400, "o alarme cabe inteiro no corte de 500 caracteres do log do wrapper (não some junto com o resto)")


def t_fingerprint_before_read(m, W):
    """Achado médio-baixo da tentativa 3: o fingerprint era tirado DEPOIS de ler o transcrito, então uma escrita no meio era atestada por um
    fingerprint de conteúdo que nunca foi lido ('1 inalteradas' para sempre). Reprodução do revisor: injeta um append no instante do
    fingerprint. Invariante: se o fingerprint do ledger bate com o do arquivo agora, a linha cobre o arquivo INTEIRO."""
    w, _ = setup(m, W)
    f = w["projects"] / "-proj" / "racey.jsonl"
    write_session(w["projects"], "-proj", "racey", [beacon("gastown.dog-7", D + "20:00:00Z")] + asst("rc1", D + "20:00:10Z"))
    real_fp, calls = m.fingerprint, []

    def appending_fp(main):
        if not calls:                       # uma escrita cai no instante em que o fingerprint é tirado
            with open(f, "a") as fh:
                for r in asst("rc2", D + "20:00:20Z"):
                    fh.write(json.dumps(r, separators=(",", ":")) + "\n")
        calls.append(1)
        return real_fp(main)

    m.fingerprint = appending_fp
    try:
        rec = m.scan_session(f)
    finally:
        m.fingerprint = real_fp
    covers_all = rec["msgs"] == 2
    attests_now = rec["fp"] == real_fp(f)
    ck(not attests_now or covers_all, f"o ledger atesta o arquivo de agora (fp bate) mas leu {rec['msgs']} de 2 mensagens: uma sessão 'inalterada' que nunca foi lida por inteiro")
    ck(covers_all, f"com o fingerprint tirado ANTES da leitura, a escrita do meio é lida junto; achei {rec['msgs']} mensagens")


def t_unreadable_subagent_files(m, W):
    """Irmão da entrada ilegível: um arquivo de subagente que existe mas não abre (ou o diretório deles sem permissão) era pulado calado — os
    tokens dele sumiam do gasto da sessão e 'sem subagente' e 'não consegui ler o subagente' eram a mesma coisa."""
    w, _ = setup(m, W)
    P = w["projects"]
    write_session(P, "-proj", "subs", [beacon("gastown.dog-8", D + "21:00:00Z")] + asst("u1", D + "21:00:10Z"),
                  subagents={"agent-ok": asst("u_ok", D + "21:00:20Z"), "agent-bad": asst("u_bad", D + "21:00:30Z")})
    with denied(P / "-proj" / "subs" / "subagents" / "agent-bad.jsonl"):
        out = harvest(m, w)
    rec = ledger_rows(m, w)["subs"]
    ck(rec["files_unreadable"] == 1 and rec["msgs"] == 2, f"o subagente que não abre é CONTADO e as respostas dos outros arquivos entram (2); achei files_unreadable={rec['files_unreadable']} msgs={rec['msgs']}")
    ck("1 arquivos/diretórios de subagente" in out, f"a colheita avisa; achei {[ln for ln in out.splitlines() if 'subagente' in ln]}")
    write_session(P, "-proj", "subs2", [beacon("gastown.dog-8", D + "21:10:00Z")] + asst("v1", D + "21:10:10Z"), subagents={"agent-1": asst("v2", D + "21:10:20Z")})
    with denied(P / "-proj" / "subs2" / "subagents"):
        harvest(m, w)
    rec2 = ledger_rows(m, w)["subs2"]
    ck(rec2["files_unreadable"] == 1, f"diretório de subagentes sem permissão: o glob devolvia vazio ('sem subagentes'); agora é contado; achei {rec2['files_unreadable']}")
    code, r = report(m, w)
    ck(r["unknown"]["transcript_files_unreadable"] == 2, f"o --json traz o desconhecido na janela; achei {r['unknown']}")
    code, txt = report_text(m, w)
    ck("NÃO abrem" in txt, f"o texto do relatório avisa; achei {[ln for ln in txt.splitlines() if '⚠' in ln]}")


def t_power_json_and_sessions(m, W):
    """Seção 6: (1) papel com poucos beads aparece no --json como `insufficient` (ausente era indistinguível de 'papel que não existe');
    (2) o A/B de effort sorteia o braço por SESSÃO, e a conta de poder trata cada bead como unidade: o nº de sessões por trás dos beads e
    os beads por sessão são MEDIDOS e impressos (texto e JSON), não supostos."""
    w, _ = setup(m, W)
    code, r = report(m, w)
    ck(r["power"].get("dog") == dict(beads=2, insufficient=True, min_beads=20) and "cv_usd_per_bead" not in r["power"]["dog"],
       f"<20 beads: o JSON diz 'insufficient' e não traz número nenhum; achei {r['power']}")
    beads = [dict(bead=f"ga-ps{i:02d}", model="claude-sonnet-5-5", k=3 + i % 5) for i in range(22)]
    w = mini_world(m, W / "ps", beads)
    t = lambda sec: f"{D}18:00:{sec:02d}.000Z"
    recs = [beacon("gastown.dog-1", t(0))]
    recs += asst("tb-1", t(10), cmd="bd update ga-tb01 --claim", tid="tu_tb1") + [tool_result("tu_tb1", "✓ Updated issue: ga-tb01", t(11))]
    recs += asst("tb-2", t(20))
    recs += asst("tb-3", t(30), cmd="bd update ga-tb02 --claim", tid="tu_tb2") + [tool_result("tu_tb2", "✓ Updated issue: ga-tb02", t(31))]
    recs += asst("tb-4", t(40))
    write_session(w["projects"], "-proj", "twobeads", recs)
    with open(w["gate"], "a") as fh:
        for b in ("ga-tb01", "ga-tb02"):
            fh.write(json.dumps({"ts": f"{D}19:00:00Z", "event": "dispatcher_complete", "branch": f"feat/{b}", "bead": b, "rig": "gascity", "result": "PASS", "dry_run": "0"}) + "\n")
    harvest(m, w)
    code, r = report(m, w)
    pw = r["power"]["dog"]
    ck(pw["beads"] == 24 and pw["sessions"] == 23 and approx(pw["beads_per_session"], 24 / 23, 1e-3), f"24 beads em 23 sessões (uma construiu 2): beads/sessão = 1,043; achei {pw}")
    code, txt = report_text(m, w)
    ck("23 sessões construíram esses 24 beads = 1.04 beads/sessão" in txt and "o braço do A/B é por SESSÃO" in txt, f"o texto da seção 6 diz o design; achei {[ln for ln in txt.splitlines() if 'sessões construíram' in ln]}")
    ck("agrupamento pequeno" in txt and "agrupamento grande" not in txt, f"1,04 beads/sessão é agrupamento pequeno: o texto diz isso, e não 'grande'; achei {[ln for ln in txt.splitlines() if 'sessões construíram' in ln]}")


def pad80(s):
    return s + " " * max(0, 80 - len(s))


def wrapped_header(head, tail, numbered=False):
    """O cabeçalho da tarefa do revisor como o `gc bd show` o entrega: o comentário é quebrado em ~80 colunas, a quebra cai logo depois de um
    hífen do ramo, e o resto do ramo vem numa linha de continuação indentada e preenchida com espaços até a coluna 80. `numbered` = a mesma
    coisa lida por `cat -n` (cada linha ganha `<n>\\t`). Formato COPIADO do transcrito real do revisor 5cbf7a1b (01/10) — não inventado."""
    lines = [f"QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: {head}", pad80("    " + tail),
             pad80("    Author (EXCLUDED from reviewing): peter-wa-gawisp95ct49"), pad80("    Rig: whatsapp_automation"), "    Branch SHA: abc123"]
    return "\n".join(f"{7 + i}\t{ln}" for i, ln in enumerate(lines)) if numbered else "\n".join(lines)


def t_reviewer_wrapped_header(m, W):
    """Gate (tentativa 4, bloqueante 1): `gc bd show` quebra o cabeçalho "… for branch: <ramo>" em ~80 colunas logo depois de um hífen, e o
    REVIEW_HEADER capturava só `crew/wa-worker/wa-`: o ramo truncado não está na ponte do gate, então o custo da revisão NUNCA chegava ao bead
    (real: 46 sessões de revisor com ramo que o gate não conhece = 11% dos tokens de revisor; +109 sem ramo) e a coluna rev$/bead saía menor
    sem aviso. Os 106 checks verdes não diziam nada porque as fixtures só tinham cabeçalho de UMA linha. Aqui as fixtures são o formato real
    quebrado; o ramo é juntado com a linha de continuação e o custo chega ao bead."""
    w, _ = setup(m, W)
    P = w["projects"]
    cases = [   # sid, ramo, bead, cabeçalho, ramos que a sessão tem que guardar
        ("rvA", "crew/wa-worker/wa-x5g89", "wa-x5g89", wrapped_header("crew/wa-worker/wa-", "x5g89"), ["crew/wa-worker/wa-x5g89"]),
        ("rvB", "feat/ga-5c3msy-token-meter", "ga-5c3msy", wrapped_header("feat/ga-5c3msy-", "token-meter", numbered=True), ["feat/ga-5c3msy-token-meter"]),
        # quebra que NÃO cai depois de hífen (palavra longa partida no meio): não dá para saber se `name1` é o resto do ramo -> guarda os DOIS
        # candidatos e deixa a ponte do gate escolher (a decisão certa sob dúvida: nenhum dos dois é descartado por palpite)
        ("rvC", "feat/ga-longbranchname1", "ga-lng1", wrapped_header("feat/ga-longbranch", "name1"), ["feat/ga-longbranch", "feat/ga-longbranchname1"]),
        # controle: cabeçalho de uma linha só, seguido de linha com várias palavras -> nada a juntar, nenhum candidato extra
        ("rvD", "feat/ga-ctl1", "ga-ctl1", "QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: feat/ga-ctl1\n    Author (EXCLUDED from reviewing): x\n    Rig: y", ["feat/ga-ctl1"]),
    ]
    with open(w["gate"], "a") as fh:
        for sid, branch, bead, _hdr, _want in cases:
            fh.write(json.dumps({"ts": D + "13:00:00Z", "event": "dispatcher_complete", "branch": branch, "bead": bead, "rig": "gascity", "result": "PASS", "dry_run": "0"}) + "\n")
    def write_reviewer(sid, hdr):
        recs = [beacon(f"gate-reviewer-adhoc-{sid}", D + "13:10:00.000Z")]
        recs += asst(f"{sid}-r1", D + "13:10:05.000Z", cmd="gc bd show x", tid=f"tu_{sid}_r")
        recs += [tool_result(f"tu_{sid}_r", hdr, D + "13:10:06.000Z")]
        recs += asst(f"{sid}-r2", D + "13:10:30.000Z")
        write_session(P, "-proj", sid, recs)

    for sid, branch, bead, hdr, _want in cases:
        recs = [beacon("gastown.dog-7", D + "12:00:00.000Z")]
        recs += asst(f"{sid}-b1", D + "12:00:10.000Z", cmd=f"bd update {bead} --claim", tid=f"tu_{sid}_b") + [tool_result(f"tu_{sid}_b", f"✓ Updated issue: {bead}", D + "12:00:11.000Z")]
        recs += asst(f"{sid}-b2", D + "12:00:20.000Z")
        write_session(P, "-proj", f"b{sid}", recs)
        write_reviewer(sid, hdr)
    harvest(m, w)
    rows = ledger_rows(m, w)
    for sid, branch, bead, _hdr, want in cases:
        ck(rows[sid]["role"] == "gate-reviewer", f"{sid}: papel pelo beacon; achei {rows[sid]['role']}")
        ck(rows[sid]["branches"] == want, f"{sid}: o ramo do cabeçalho quebrado é juntado com a continuação; esperava {want}, achei {rows[sid]['branches']}")
    code, r = report(m, w)
    ck(r["coverage"]["unmapped_reviewer_sessions"] == 0, f"nenhuma sessão de revisor fica sem ramo conhecido (o truncado não estava na ponte do gate); achei {r['coverage']['unmapped_reviewer_sessions']}")
    for sid, branch, bead, _hdr, _want in cases:
        ck(approx(r["beads"][bead]["review_usd"], 2 * USD_SMALL, 1e-9), f"{bead}: as 2 respostas do revisor viram custo de revisão do bead; achei {r['beads'][bead]}")
    # cópia do cabeçalho CORTADA (sem a continuação): o ramo fica como veio — nada a juntar, nada adivinhado. Formas reais do transcrito local (01/10):
    # uma linha `----` de separador depois do cabeçalho (virava o ramo-lixo 'crew/oracle/wa-----'), a string que termina logo depois do ramo
    # (`| head`), e o `grep -n` que mostra só a linha casada e pula para a próxima linha casada (`53:`)
    cut = [("rvE", "QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: crew/oracle/wa-   \n----\n/Users/athos/gt/whatsapp_automation\ncommit abc1", ["crew/oracle/wa-"]),
           ("rvF", "QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: fix/ga-mv896u-", ["fix/ga-mv896u-"]),
           ("rvG", "QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: crew/ps-worker/ps-\n53:      FULL DIFF (complete — 625 lines)", ["crew/ps-worker/ps-"])]
    for sid, hdr, _want in cut:
        write_reviewer(sid, hdr)
    harvest(m, w)
    rows = ledger_rows(m, w)
    for sid, _hdr, want in cut:
        ck(rows[sid]["branches"] == want, f"{sid}: cópia cortada — o ramo fica como veio, sem juntar separador nem linha de outra saída; esperava {want}, achei {rows[sid]['branches']}")
    # uma linha do ledger escrita pela regra antiga (ramo truncado, schema anterior) é reescaneada, e o ramo sai certo — o transcrito ainda existe
    rows["rvA"]["v"] = 3
    rows["rvA"]["branches"] = ["crew/wa-worker/wa-"]
    m.write_ledger(rows, w["ledger"])
    harvest(m, w)
    s = ledger_rows(m, w)["rvA"]
    ck(s["v"] == m.SCHEMA and m.SCHEMA >= 4 and s["branches"] == ["crew/wa-worker/wa-x5g89"], f"a linha v=3 (ramo truncado) é reescaneada pela colheita; v={s['v']} branches={s['branches']}")


def t_harvest_unreadable_transcript(m, W):
    """Gate (tentativa 4, bloqueante 2): um transcrito que EXISTE mas não abre (permissão, I/O) caía no mesmo balde de "sumiu no meio" — a linha
    "N sumiram no meio" é a de um transcrito apagado pelo reaper entre a listagem e a abertura (ENOENT: legítimo), mas EACCES/EIO não sumiram,
    e a colheita saía com 0 e sem alarme: o reaper apaga esse transcrito 24h depois e o ledger nunca o recebeu. "Não consegui ler" ≠ "sumiu":
    só FileNotFoundError é "sumiu"; o resto é entrada ilegível (alarme na 1ª linha, exit 6) e a colheita segue com as demais sessões."""
    w, _ = setup(m, W)
    good = ledger_rows(m, w)
    P = w["projects"]
    snap = set(good)
    write_session(P, "-proj", "locked1", [beacon("gastown.dog-9", D + "23:00:00Z")] + asst("k1", D + "23:00:10Z"))
    # (a) o arquivo de topo existe mas não abre: a reprodução do revisor (2 transcritos, chmod 000, ledger novo)
    wa = dict(w, ledger=W / "lA" / "sessions.jsonl")
    with denied(P / "-proj" / "locked1.jsonl"):
        rc, out = harvest_rc(m, wa)
    lines = out.splitlines()
    ck(rc == m.RC_NO_INPUT == 6, f"transcrito que existe mas não abre: exit 6, achei {rc}")
    ck(lines and lines[0].startswith("⚠ SEM ENTRADA") and "locked1" in lines[0] and "ilegível" in lines[0], f"o alarme é a 1ª linha e nomeia o transcrito; achei {lines[:1]}")
    ck("0 sumiram no meio" in out, f"não abriu ≠ sumiu: o balde 'sumiram no meio' fica em 0; achei {[ln for ln in lines if ln.startswith('harvest:')]}")
    ck(set(ledger_rows(m, wa)) == snap, f"as demais sessões são colhidas mesmo assim; achei {sorted(set(ledger_rows(m, wa)) ^ snap)}")
    ck(len(lines[0]) <= 400, f"o alarme com o caminho do transcrito cabe no corte de 500 caracteres do log do wrapper; {len(lines[0])}")
    # (b) o mesmo, com a janela --since-hours: o `stat` do filtro falha com EACCES (não ENOENT) num diretório que lista mas não deixa entrar
    (P / "-semx").mkdir()
    write_session(P, "-semx", "semx1", [beacon("gastown.dog-9", D + "23:10:00Z")] + asst("k2", D + "23:10:10Z"))
    (P / "-semx").chmod(0o444)
    try:
        ck(not os.access(P / "-semx", os.X_OK), "este ambiente ignora permissão de diretório (root?): o caso não prova nada")
        wb = dict(w, ledger=W / "lB" / "sessions.jsonl")
        out_b = io.StringIO()
        with contextlib.redirect_stdout(out_b):
            rc_b = m.cmd_harvest(type("A", (), dict(ledger=str(wb["ledger"]), since_hours=24))())
        rc_c, out_c = harvest_rc(m, dict(w, ledger=W / "lC" / "sessions.jsonl"))      # e sem janela
    finally:
        (P / "-semx").chmod(0o755)
    for label, rc_x, txt in (("com --since-hours", rc_b, out_b.getvalue()), ("sem janela", rc_c, out_c)):
        ck(rc_x == 6 and txt.startswith("⚠ SEM ENTRADA") and "semx1" in txt.splitlines()[0], f"{label}: transcrito inacessível = alarme + exit 6, não 'sumiu'; achei rc={rc_x} {txt[:120]!r}")
        ck("0 sumiram no meio" in txt, f"{label}: 'sumiram no meio' continua 0; achei {[ln for ln in txt.splitlines() if ln.startswith('harvest:')]}")
    # (c) o que de fato sumiu entre a listagem e a abertura (ENOENT: o reaper) continua sendo "sumiu", sem alarme e com exit 0
    real = m.list_transcripts
    m.list_transcripts = lambda root: (real(root)[0] + [P / "-proj" / "gone1.jsonl"], real(root)[1])
    try:
        (P / "-proj" / "locked1.jsonl").unlink()
        rc_d, out_d = harvest_rc(m, dict(w, ledger=W / "lD" / "sessions.jsonl"))
    finally:
        m.list_transcripts = real
    ck(rc_d == 0 and "SEM ENTRADA" not in out_d and "1 sumiram no meio" in out_d, f"transcrito que sumiu de verdade (ENOENT): 'sumiram no meio', sem alarme, exit 0; achei rc={rc_d} {[ln for ln in out_d.splitlines() if ln.startswith('harvest:')]}")
    # (d) o transcrito baixado do S3 que não abre: a falha é contada e nomeada (o backfill não pode estourar com a exceção nova)
    stub_world(W, m)
    code, out = bf(m, W)
    ck("FALHOU projects/-projA/sid3.jsonl: transcrito baixado e ilegível" in out and code == 4, f"backfill-s3 com transcrito ilegível: falha contada, exit 4; achei {code} {out[-300:]!r}")


def old_row(sid, v, msgs, out):
    """Uma linha do ledger como a escreveu uma versão do script no schema `v`: para o merge só importam as mensagens e os tokens dos buckets."""
    return dict(v=v, sid=sid, msgs=msgs, first_ts=D + "10:00:00Z", size=1, fp="x", days_ctx={},
                buckets={"_pre": {"claude-sonnet-5-5|xhigh": dict(inp=0, out=out, cw5=0, cw1=0, cr=0, think=0, msgs=msgs)}})


def t_merge_never_poorer(m, W):
    """Gate (tentativa 5, bloqueante 1): `merge_session` só guardava a linha mais rica quando a antiga JÁ estava no schema atual — uma linha de
    schema antigo era sobrescrita por QUALQUER cópia, e o backfill-s3 (só os arquivos de topo, nunca os de subagente) refaz toda linha v<4: a linha
    com os tokens dos subagentes era trocada por uma mais pobre, contada como "atualizada", sem cópia — irreversível depois que o reaper apaga o
    transcrito. "Schema novo" não é "mais dados": nunca se troca uma linha por uma cópia mais pobre, de nenhum schema (nem em mensagens, nem em
    tokens); o que não dá para comparar fica como está; e a cópia que ENTRA no lugar de uma linha de schema antigo é a que não perde nada."""
    # o repro do revisor: linha v3 msgs=7 out=20.300 × cópia do S3 (schema atual) msgs=3 out=300
    rows = {"s1": old_row("s1", 3, 7, 20300)}
    ck(not m.merge_session(rows, old_row("s1", m.SCHEMA, 3, 300)) and rows["s1"] == old_row("s1", 3, 7, 20300),
       f"linha de schema antigo MAIS RICA não é trocada por cópia mais pobre: {rows['s1']['v']=} {rows['s1']['msgs']=}")
    # nenhum eixo sozinho basta: mais mensagens com MENOS tokens, e o contrário, também são mais pobres
    rows = {"s1": old_row("s1", 3, 3, 20300)}
    ck(not m.merge_session(rows, old_row("s1", m.SCHEMA, 7, 300)) and rows["s1"]["msgs"] == 3, "mais mensagens mas menos tokens é mais pobre")
    rows = {"s1": old_row("s1", 3, 7, 300)}
    ck(not m.merge_session(rows, old_row("s1", m.SCHEMA, 3, 20300)) and rows["s1"]["msgs"] == 7, "mais tokens mas menos mensagens é mais pobre")
    # "não consegui comparar" (a linha do ledger não tem buckets legíveis) não é "mais completa": fica como está
    broken = old_row("s1", 3, 7, 20300)
    del broken["buckets"]
    rows = {"s1": dict(broken)}
    ck(not m.merge_session(rows, old_row("s1", m.SCHEMA, 9, 99999)) and rows["s1"] == broken, "linha que não dá para comparar não é sobrescrita")
    # controles: a cópia igual-ou-mais-completa de uma linha de schema antigo ENTRA (senão a v<4 nunca migra) e a sessão nova entra
    rows = {"s1": old_row("s1", 3, 3, 300)}
    ck(m.merge_session(rows, old_row("s1", m.SCHEMA, 7, 20300)) and rows["s1"]["v"] == m.SCHEMA and rows["s1"]["msgs"] == 7, "cópia mais completa substitui a de schema antigo")
    rows = {"s1": old_row("s1", 3, 7, 300)}
    ck(m.merge_session(rows, old_row("s1", m.SCHEMA, 7, 300)) and rows["s1"]["v"] == m.SCHEMA, "cópia igual migra a linha de schema antigo")
    rows = {}
    ck(m.merge_session(rows, old_row("s1", m.SCHEMA, 1, 1)) and "s1" in rows, "sessão nova entra")


def t_backfill_keeps_richer_row_and_saves_the_replaced(m, W):
    """O mesmo, de ponta a ponta pelo backfill-s3 (o caminho que o relatório documenta): a linha mais rica FICA e o texto diz que ficou; quando a
    cópia do S3 entra no lugar de uma linha de schema antigo, a linha que saiu vai para `.replaced-<ts>` ANTES da reescrita (como o
    `.unreadable-<ts>`) e a contagem aparece — o ledger é reescrito inteiro, e o que sai dele sem cópia some."""
    stub_world(W, m)
    led = W / "bf" / "sessions.jsonl"
    led.parent.mkdir(parents=True, exist_ok=True)
    # (a) o S3 traz msgs=1 / 100 tokens (só o topo); a linha v3 do ledger tem msgs=7 / 20.300 (com os subagentes)
    m.write_ledger({"sid1": old_row("sid1", 3, 7, 20300)}, led)
    code, out = bf(m, W)
    row = m.load_ledger(led)[0]["sid1"]
    ck(row["v"] == 3 and row["msgs"] == 7 and row["buckets"]["_pre"]["claude-sonnet-5-5|xhigh"]["out"] == 20300,
       f"o backfill não troca a linha mais rica pela do S3: v={row['v']} msgs={row['msgs']}")
    ck("1 linhas mantidas" in out and "MAIS POBRE" in out, f"o texto diz que a cópia do S3 era mais pobre e a linha ficou: {out}")
    ck(not list(led.parent.glob("sessions.jsonl.replaced-*")), "nada foi trocado: não há o que guardar")
    # (b) a linha v3 do ledger é mais pobre que a do S3: a do S3 entra e a linha que saiu fica guardada
    led.unlink()
    m.write_ledger({"sid1": old_row("sid1", 3, 1, 5)}, led)
    code, out = bf(m, W)
    row = m.load_ledger(led)[0]["sid1"]
    ck(row["v"] == m.SCHEMA and row["msgs"] == 1, f"a cópia do S3 não é mais pobre: entra: v={row['v']}")
    saved = sorted(led.parent.glob("sessions.jsonl.replaced-*"))
    ck(len(saved) == 1, f"a linha de schema antigo que saiu foi guardada em .replaced-<ts>: {[p.name for p in led.parent.iterdir()]}")
    kept = [json.loads(ln) for ln in saved[0].read_text().splitlines()]
    ck(len(kept) == 1 and kept[0]["sid"] == "sid1" and kept[0]["v"] == 3 and kept[0]["buckets"]["_pre"]["claude-sonnet-5-5|xhigh"]["out"] == 5,
       f"o arquivo tem a linha como estava ANTES da troca: {kept}")
    ck("1 linhas de schema antigo substituídas" in out and str(saved[0]) in out, f"a contagem e o caminho da cópia aparecem: {out}")
    # (c) a sessão que o S3 trouxe não trocou nada no ledger de schema ATUAL: nenhuma cópia desnecessária a cada rodada
    for p in saved:
        p.unlink()
    code, out = bf(m, W)
    ck(not list(led.parent.glob("sessions.jsonl.replaced-*")), "linha já no schema atual não gera cópia")
    # (d) a linha do ledger que não dá para comparar (sem buckets legíveis) fica, com a frase dela — NÃO a de "já tinha registro mais completo"
    led.unlink()
    broken = old_row("sid1", 3, 7, 20300)
    del broken["buckets"]
    m.write_ledger({"sid1": broken}, led)
    code, out = bf(m, W)
    ck(m.load_ledger(led)[0]["sid1"] == broken, "linha que não dá para comparar não é trocada pelo backfill")
    ck("1 linhas mantidas: não deu para comparar" in out and "0 já tinham registro mais completo" in out,
       f"o que não deu para comparar não é contado como 'já tinha registro mais completo': {out}")


def t_harvest_keeps_richer_old_schema_row(m, W):
    """E pela colheita local: uma linha de schema antigo é reescaneada (o schema subiu), mas o transcrito local pode ter menos que a linha (o
    reaper já apagou os arquivos de subagente): a linha mais rica fica; a que a colheita pode substituir sem perda (cópia igual) é guardada."""
    w, _ = setup(m, W)
    rows = ledger_rows(m, w)
    rich = json.loads(json.dumps(rows["dog1"]))
    rich["v"], rich["msgs"] = 3, rich["msgs"] + 50
    cell = next(iter(next(iter(rich["buckets"].values())).values()))
    cell["out"] += 5000
    same = json.loads(json.dumps(rows["ora1"]))
    same["v"] = 3                                           # mesma sessão, schema antigo, NADA a mais: a cópia nova só a migra
    rows.update(dog1=rich, ora1=same)
    m.write_ledger(rows, w["ledger"])
    out = harvest(m, w)
    now = ledger_rows(m, w)
    ck(now["dog1"] == rich, f"colheita: a linha de schema antigo mais rica fica como estava: v={now['dog1']['v']} msgs={now['dog1']['msgs']}")
    ck("1 linhas mantidas" in out and "MAIS POBRE" in out, f"colheita: o texto diz que a linha ficou: {out}")
    ck(now["ora1"]["v"] == m.SCHEMA, "colheita: a linha de schema antigo que não perde nada é migrada")
    saved = sorted(w["ledger"].parent.glob("sessions.jsonl.replaced-*"))
    ck(len(saved) == 1 and [json.loads(ln)["sid"] for ln in saved[0].read_text().splitlines()] == ["ora1"],
       f"colheita: a linha que saiu (só ela) foi guardada: {[p.name for p in saved]}")
    ck("1 linhas de schema antigo substituídas" in out, f"colheita: a contagem aparece: {out}")


def t_lock_error_is_not_contention(m, W):
    """Gate (tentativa 5, baixo): `lock_ledger` lia QUALQUER OSError do flock como "outra colheita em curso — nada feito" com exit 0: ENOLCK/EBADF/EIO
    viravam o pulo educado de uma colheita concorrente e a colheita nunca rodava (erro lido como contenção — o terceiro estado). Só
    EWOULDBLOCK/EAGAIN é contenção; qualquer outra coisa é falha alta (exit ≠ 0, nada feito, a mensagem NÃO é a de contenção). Vale para o
    harvest e para o backfill-s3."""
    import errno
    import types
    w, _ = setup(m, W)
    stub_world(W, m)
    real = m.fcntl

    def with_flock_error(code):
        def raiser(fd, op):
            raise OSError(code, os.strerror(code))
        return types.SimpleNamespace(flock=raiser, LOCK_EX=real.LOCK_EX, LOCK_NB=real.LOCK_NB)

    before = w["ledger"].read_bytes()
    try:
        m.fcntl = with_flock_error(errno.ENOLCK)
        rc, out = harvest_rc(m, w)
        ck(rc != 0 and "outra colheita em curso" not in out, f"harvest: ENOLCK não é contenção: rc={rc} {out!r}")
        ck(rc == m.RC_LOCK_ERROR and "ERRO" in out and os.strerror(errno.ENOLCK) in out, f"harvest: falha alta que diz o que o SO respondeu: {out!r}")
        ck(w["ledger"].read_bytes() == before, "harvest: com o lock em erro o ledger não é tocado")
        led = W / "bf" / "sessions.jsonl"
        code, out = bf(m, W)
        ck(code == m.RC_LOCK_ERROR and "outra colheita em curso" not in out and "ERRO" in out, f"backfill-s3: ENOLCK não é contenção: rc={code} {out!r}")
        ck(not led.exists(), "backfill-s3: com o lock em erro nada foi trazido")
        # controle: contenção de verdade (EAGAIN/EWOULDBLOCK) continua sendo o pulo educado, exit 0
        for code_ in {errno.EAGAIN, errno.EWOULDBLOCK}:
            m.fcntl = with_flock_error(code_)
            rc, out = harvest_rc(m, w)
            ck(rc == 0 and "outra colheita em curso" in out, f"harvest: {errno.errorcode[code_]} é contenção: rc={rc} {out!r}")
            code, out = bf(m, W)
            ck(code == 0 and "outra colheita em curso" in out, f"backfill-s3: {errno.errorcode[code_]} é contenção: rc={code} {out!r}")
    finally:
        m.fcntl = real


def t_assistant_record_with_user_word_is_counted(m, W):
    """Gate (tentativa 5, baixo): o atalho que pula linhas de usuário (depois das 3 primeiras, sem claim pendente) decidia pela SUBSTRING `"user"` na
    linha crua — um registro de ASSISTENTE cuja linha contém `"user"` (um valor de input de ferramenta, `{"role": "user"}`) era pulado e o uso dele
    nunca contado: tokens sumidos sem aviso. O atalho só vale para linha que não pode ser de assistente."""
    P = W / "projects"
    recs = [beacon("gastown.dog-1", D + "10:00:00.000Z"), user("segunda", D + "10:00:01.000Z"), user("terceira", D + "10:00:02.000Z")]
    a = asst("m1", D + "10:00:10.000Z")[2]                       # o bloco tool_use da resposta
    a["message"]["content"][0]["input"] = {"command": "true", "meta": {"role": "user"}}
    recs.append(a)
    write_session(P, "-proj", "u1", recs)
    ck(b'"user"' in (P / "-proj" / "u1.jsonl").read_bytes().splitlines()[-1], "a fixture: a linha crua do assistente contém a palavra entre aspas")
    rec = m.scan_session(P / "-proj" / "u1.jsonl")
    ck(rec["msgs"] == 1 and rec["bad_lines"] == 0, f"o registro de assistente com a palavra \"user\" é contado: msgs={rec['msgs']}")
    # controle: uma linha de usuário comum, sem claim pendente, depois das 3 primeiras, segue sendo pulada sem estragar nada
    recs2 = recs[:3] + [user("quarta", D + "10:00:05.000Z")] + asst("m2", D + "10:00:20.000Z")
    write_session(P, "-proj", "u2", recs2)
    ck(m.scan_session(P / "-proj" / "u2.jsonl")["msgs"] == 1, "linha de usuário comum não atrapalha a contagem")


MUTANTS = {   # nome -> (trecho do script, mutação, caso que TEM que reprovar)
    "soma linhas (sem dedup)": ('if v > rec["use"][k]:\n                                rec["use"][k] = v', 'rec["use"][k] += v', t_dedup),
    "leitura de cache a preço cheio": ('"cr": 0.10}', '"cr": 1.0}', t_price),
    "sem preço vira US$ 0": ('        return None\n    pin, pout = p\n    return (c["inp"] * pin + c["out"] * pout', '        return 0.0\n    pin, pout = p\n    return (c["inp"] * pin + c["out"] * pout', t_price),
    "claim que falhou conta": ('for c in claims if c["state"] in ("ok", "noresult")]', 'for c in claims if c["state"] != "unconfirmed"]', t_claims),
    "só o 1º ramo do revisor": ("len(branches) < 6", "len(branches) < 1", t_reviewer),
    "janela por início de sessão": ('(s.get("days") or {}).items():\n            if day < since_day:\n                continue\n', '(s.get("days") or {}).items():\n', t_window_by_message_day),
    "excesso acima do teto vira o cache-read inteiro": ('+= max(0, m["use"]["cr"] - cap)', '+= m["use"]["cr"]', t_context_caps),
    "prefiltro depende do espaçamento": ('is_asst = \'"assistant"\' in line', 'is_asst = \'"type":"assistant"\' in line', t_json_spacing_and_canary),
    "id do preâmbulo vira bead": ("if not live and role in POOL_BUILDERS and refs:", "if not live and role in POOL_BUILDERS + ('crew',) and refs:", t_noise_idle_ref_crew),
    "ocioso sem preço some do relatório": ('idle[s["role"]][2] += total_tokens(c)', 'idle[s["role"]][2] += 0', t_sweep_unknowns),
    "revisor sem ramo conta por bucket": ('unmapped_review.add(s["sid"])', 'unmapped_review.add((s["sid"], key))', t_sweep_unknowns),
    "veredito sem bead entra nas contas": ('if not r.get("bead"):', "if False:", t_sweep_unknowns),
    "claim sem timestamp some calado": ('untimed = sum(1 for c in eligible if not c["ts"])', "untimed = 0", t_sweep_unknowns),
    "linha ilegível do ledger é descartada sem cópia": ("shutil.copy2(path, keep)", "pass", t_sweep_unknowns),
    # ---- gate-fix 1 (ga-5c3msy): o terceiro estado "sem preço" nas seções 3-6, 1b, e o relatório que estoura
    "bead com token sem preço vira soma parcial": ('    if p["unpriced"]:\n        return None\n    return p["build_usd"] + p["review_usd"] + p["pregate_usd"]',
                                                   '    return p["build_usd"] + p["review_usd"] + p["pregate_usd"]', t_unpriced_report),
    "coorte conta bead sem preço nas médias": ('        costed = [b for b in beads if bead_usd(per[b]) is not None]\n        unp = n - len(costed)',
                                               '        costed = list(beads)\n        unp = n - len(costed)', t_unpriced_report),
    "US$ por aprovada da coorte ignora bead n/p": ("        tot = None if unp else sum(bu) + sum(ru)", "        tot = sum(bu) + sum(ru)", t_unpriced_report),
    "US$ por aprovada do sistema é o piso sem aviso": ("usd_per_approved=(None if unp_tok else per_sys)", "usd_per_approved=per_sys", t_unpriced_report),
    "JSON por bead: parte do construtor sem preço vira 0": ('                            p["unp_build"] += tt * share', "                            pass", t_unpriced_report),
    "JSON por bead: parte do revisor sem preço vira 0": ('                        p["unp_" + fld] += tt', "                        pass", t_unpriced_report),
    "1b esquece os tokens sem preço que deixou de fora": ("            comp_unpriced += total_tokens(c)", "            comp_unpriced += 0", t_unpriced_report),
    "CV conta bead sem preço como US$ 0": ("        tot = [bead_usd(per[b]) for b in priced]",
                                           '        tot = [per[b]["build_usd"] + per[b]["review_usd"] + per[b]["pregate_usd"] for b in beads]', t_power_unpriced),
    "CV sem guarda: média 0 vira nan e estoura": ("        cv = statistics.pstdev(tot) / mean if (len(priced) >= 20 and mean > 0) else None",
                                                  '        cv = statistics.pstdev(tot) / mean if mean else float("nan")', t_power_unpriced),
    "seção que estoura leva as prontas junto": ("    except Exception as e:  # noqa: BLE001 — qualquer seção pode estourar; as já prontas não podem ser jogadas fora",
                                                "    except KeyboardInterrupt as e:  # noqa: BLE001", t_report_survives_crash),
    # ---- gate-fix 2 (ga-5c3msy): resultado visível que não confirma ≠ sem resultado; dois claims num comando; claim ≠ referência
    "resultado visível que não confirma vira claim vivo": ('for c in claims if c["state"] in ("ok", "noresult")]', 'for c in claims if c["state"] != "failed"]', t_claim_states),
    "confirmação não olha o id": ("    if bead in named:\n        return \"ok\"", "    if named:\n        return \"ok\"", t_claim_states),
    "regex de erro antes da confirmação do id": ("    if bead in named:\n        return \"ok\"", "    if False:\n        return \"ok\"", t_claim_states),
    "formato sem id confirma com vários claims": ('if not named and "Updated issue" in txt and n_claims == 1 and not is_error:', 'if not named and "Updated issue" in txt and not is_error:', t_claim_states),
    "formato sem id nunca confirma": ('if not named and "Updated issue" in txt and n_claims == 1 and not is_error:', "if False:", t_claim_states),
    "dois claims do comando: o último vence": ('have += [(bead, r.get("timestamp") or "") for bead in targets if bead not in [x[0] for x in have]]',
                                               'have[:] = [(targets[-1], r.get("timestamp") or "")]', t_claim_states),
    "grupo: o último claim leva tudo": ('key = sbeads[0] if len(sbeads) == 1 else GROUP + ",".join(sorted(sbeads))', "key = sbeads[-1]", t_claim_states),
    "relatório não divide o bucket do grupo": ('bucket[len(GROUP):].split(",") if bucket.startswith(GROUP) else [bucket]', "[bucket]", t_claim_states),
    "comando de claim vira referência": ("if any(a <= rm.start() < z for a, z in spans):", "if False:", t_claim_not_a_reference),
    "ocioso conta sessão com claim sem timestamp": ('            if s.get("claims_untimed"):\n                idle[s["role"]][3] += 1', '            if False:\n                idle[s["role"]][3] += 1', t_idle_vs_untimed_claim),
    "JSON sem janela incompleta": ("    result.update(pool_floor=pool_floor, window_incomplete=window_incomplete)", "    pass", t_report_unknown_counters),
    "JSON sem os desconhecidos": ('    result["unknown"] = unk\n', '    result["unknown"] = {}\n', t_report_unknown_counters),
    "JSON sem linhas ilegíveis do ledger": ("sessions=len(sess), ledger_unreadable_lines=bad_ledger)", "sessions=len(sess))", t_report_unknown_counters),
    "desconhecido 'não confirmou' não é somado": ('claims_unconfirmed=sum(s.get("claims_unconfirmed", 0) for s in sess)', "claims_unconfirmed=0", t_report_unknown_counters),
    "linha de schema antigo não é contada": ('rows_old_schema=sum(1 for s in sess if s.get("v") != SCHEMA))', "rows_old_schema=0)", t_schema_rescan),
    "colheita mantém linha de schema antigo": ('old.get("fp") == fingerprint(f) and old.get("v") == SCHEMA and "days_ctx" in old', 'old.get("fp") == fingerprint(f) and "days_ctx" in old', t_schema_rescan),
    "schema não foi aumentado": ("SCHEMA = 4     # 4 = ramo do revisor", "SCHEMA = 2     # 4 = ramo do revisor", t_schema_rescan),
    "alarme de formato sem exit ≠ 0": ("    return RC_NO_INPUT if input_problems else (RC_FORMAT_ALARM if alarm else 0)", "    return RC_NO_INPUT if input_problems else 0", t_harvest_alarm_first_and_nonzero),
    "alarme de formato não impresso": ("    alarm = suspect >= 2 and suspect * 4 >= big\n    if alarm:\n", "    alarm = suspect >= 2 and suspect * 4 >= big\n    if False:\n", t_harvest_alarm_first_and_nonzero),
    # ---- gate-fix 1: os achados baixos da mesma família
    "claim sem resultado conta como verificado": ('    n_noresult = sum(1 for b in measured if first_session[b][3] == "claim" and first_ok.get(b) is None)', "    n_noresult = 0", t_lows),
    "veredito sem dry_run vira ensaio calado": ("                if dry is None:\n                    bad += 1", "                if False:\n                    bad += 1", t_lows),
    "resposta sem timestamp some calada": ("            untimed_msgs += 1", "            untimed_msgs += 0", t_lows),
    "dia desconhecido entra nas janelas sem aviso": ('    undated = sum(c["msgs"] for _s, day, _m, _e, c, _u in flat if day == "?")', "    undated = 0", t_lows),
    # ---- gate-fix 2 (ga-5c3msy): a varredura do diff inteiro achou irmãos da mesma classe (desconhecido lido como resposta definida)
    "ocioso conta sessão com claim não confirmado": ('            if s.get("claims_unconfirmed"):\n                idle[s["role"]][4] += 1', '            if False:\n                idle[s["role"]][4] += 1', t_idle_vs_unconfirmed_claim),
    "atribuição por referência lista só 4 verbos": ("por referência a `bd show|comment|heartbeat|close|label|update|reopen` (worker com ",
                                                    "por referência a `bd show|comment|heartbeat|close` (worker com ", t_idle_vs_unconfirmed_claim),
    "transcrito: linha que não é registro estoura": ("if not isinstance(r, dict):\n                    bad += 1          # JSON válido que não é um registro",
                                                     "if False:\n                    bad += 1          # JSON válido que não é um registro", t_non_record_json_lines),
    "ledger: linha que não é sessão estoura": ("if not isinstance(r, dict):\n                    bad += 1                            # JSON válido que não é uma linha de sessão",
                                               "if False:\n                    bad += 1                            # JSON válido que não é uma linha de sessão", t_non_record_json_lines),
    "gate: linha que não é evento estoura": ("if not isinstance(r, dict):\n                bad += 1                                # JSON válido que não é um evento do gate",
                                             "if False:\n                bad += 1                                # JSON válido que não é um evento do gate", t_non_record_json_lines),
    "queda impossível vira 0 beads por braço": ("    if p < diff:\n        return None\n    p2 = p - diff\n", "    p2 = max(0.0, p - diff)\n", t_power_unreachable_drop),
    # ---- gate-fix 3 (ga-5c3msy): entrada ilegível ≠ "nada a colher"; fingerprint antes da leitura; subagente que não abre; poder por sessão
    "raiz ausente vira 'nada a colher'": ('    except FileNotFoundError:\n        return files, [(root, "não existe")]', "    except FileNotFoundError:\n        return files, []", t_harvest_input_unreadable),
    "raiz que é arquivo vira 'nada a colher'": ('    except NotADirectoryError:\n        return files, [(root, "não é um diretório")]', "    except NotADirectoryError:\n        return files, []", t_harvest_input_unreadable),
    "raiz sem permissão vira 'nada a colher'": ('    except OSError as e:\n        return files, [(root, f"ilegível ({e.strerror or e})")]', "    except OSError as e:\n        return files, []", t_harvest_input_unreadable),
    "projeto ilegível é pulado calado": ('            problems.append((Path(d.path), f"projeto ilegível ({e.strerror or e})"))', "            pass", t_harvest_input_unreadable),
    "entrada ilegível sem exit ≠ 0": ("    return RC_NO_INPUT if input_problems else (RC_FORMAT_ALARM if alarm else 0)", "    return RC_FORMAT_ALARM if alarm else 0", t_harvest_input_unreadable),
    "alarme de entrada não impresso": ("    if input_problems:\n        # caminho de transcrito é longo", "    if False:\n        # caminho de transcrito é longo", t_harvest_input_unreadable),
    "zero transcritos não acende": ("    elif not seen and not input_problems:", "    elif False:", t_harvest_input_unreadable),
    "lista de raízes vazia não acende": ("    if not PROJECTS:\n        input_problems.append", "    if False:\n        input_problems.append", t_harvest_input_unreadable),
    "fingerprint tirado depois da leitura": (("    fp = fingerprint(main)\n    try:\n        st = main.stat()", "mtime_ns=mtime_ns, fp=fp,"),
                                             ("    try:\n        st = main.stat()", "mtime_ns=mtime_ns, fp=fingerprint(main),"), t_fingerprint_before_read),
    "subagente que não abre é pulado calado": ("            files_unreadable += 1\n            continue", "            continue", t_unreadable_subagent_files),
    "diretório de subagentes sem permissão é 'sem subagentes'": ("    if sub_dir.is_dir() and not os.access(sub_dir, os.R_OK | os.X_OK):", "    if False:", t_unreadable_subagent_files),
    "relatório não traz os subagentes que não abrem": ("               transcript_files_unreadable=sum(s.get(\"files_unreadable\", 0) for s in sess),", "               transcript_files_unreadable=0,", t_unreadable_subagent_files),
    "ledger: objeto sem sid some calado": ("                else:\n                    bad += 1                            # objeto JSON sem `sid`", "                else:\n                    pass                                # objeto JSON sem `sid`", t_non_record_json_lines),
    "JSON omite o papel com poucos beads": ("            out[role] = dict(beads=len(beads), insufficient=True, min_beads=20)", "            pass", t_power_json_and_sessions),
    "beads por sessão = beads (sessão não medida)": ("        n_sess = len({first_sid[b] for b in beads if first_sid.get(b)})", "        n_sess = len(beads)", t_power_json_and_sessions),
    "sessão do bead não gravada": ('                    first_sid[b] = s["sid"]', "                    pass", t_power_json_and_sessions),
    # ---- gate-fix 4 (ga-5c3msy): ramo do revisor quebrado em ~80 colunas; transcrito que existe mas não abre
    "ramo do cabeçalho quebrado não é juntado": ("            joined = raw + cm.group(1)", "            joined = raw", t_reviewer_wrapped_header),
    "continuação com `<n>\\t` do cat -n não é reconhecida": (r"(?:\d+\t[ \t]*)?", "", t_reviewer_wrapped_header),
    "junta a linha seguinte mesmo com várias palavras": (r"(\S*[A-Za-z0-9]\S*)[ \t]*(?:\r?\n|\Z)", r"(\S*[A-Za-z0-9]\S*)", t_reviewer_wrapped_header),
    "linha `----` de separador é juntada como resto do ramo": (r"(\S*[A-Za-z0-9]\S*)", r"(\S+)", t_reviewer_wrapped_header),
    "ramo truncado (termina em - ou /) fica junto do juntado": ('cands = [joined] if raw[-1] in "-/" else [raw, joined]', "cands = [raw, joined]", t_reviewer_wrapped_header),
    "quebra ambígua guarda só o juntado": ('cands = [joined] if raw[-1] in "-/" else [raw, joined]', "cands = [joined]", t_reviewer_wrapped_header),
    "schema não subiu para 4 (linha v=3 de ramo truncado não é reescaneada)": ("SCHEMA = 4     # 4 = ramo do revisor", "SCHEMA = 3     # 4 = ramo do revisor", t_reviewer_wrapped_header),
    "transcrito que não abre vira 'sumiu'": ("                raise TranscriptUnreadable(e.strerror or str(e)) from e", "                return None", t_harvest_unreadable_transcript),
    "colheita trata TranscriptUnreadable como 'sumiu'": ("            except TranscriptUnreadable as e:\n                input_problems.append((f, f\"transcrito ilegível ({e})\"))\n                continue",
                                                          "            except TranscriptUnreadable:\n                vanished += 1\n                continue", t_harvest_unreadable_transcript),
    "stat que falha com EACCES vira 'sumiu'": ("            except FileNotFoundError:\n                vanished += 1", "            except OSError:\n                vanished += 1", t_harvest_unreadable_transcript),
    "backfill não trata TranscriptUnreadable": ("                except TranscriptUnreadable as e:\n                    failed += 1", "                except KeyError as e:\n                    failed += 1", t_harvest_unreadable_transcript),
    # ---- gate-fix 5 (ga-5c3msy): nunca trocar uma linha por cópia mais pobre; erro de lock ≠ contenção; atalho de usuário por tipo
    "linha de schema antigo é trocada por qualquer cópia (como antes)": ('if verdict != "ok":', 'if verdict != "ok" and row_is_current(old):', t_merge_never_poorer),
    "só as mensagens decidem se a cópia é mais pobre": ('return "poorer" if nm < om or nt < ot else "ok"', 'return "poorer" if nm < om else "ok"', t_merge_never_poorer),
    "só os tokens decidem se a cópia é mais pobre": ('return "poorer" if nm < om or nt < ot else "ok"', 'return "poorer" if nt < ot else "ok"', t_merge_never_poorer),
    "linha que não dá para comparar é sobrescrita": ('        return "unknown"\n    return "poorer"', '        return "ok"\n    return "poorer"', t_merge_never_poorer),
    "a linha de schema antigo que sai não é anotada para guardar": ("            stats.superseded.append(old)", "            pass", t_backfill_keeps_richer_row_and_saves_the_replaced),
    "a linha que sai é anotada mas o arquivo .replaced fica vazio": ('                fh.write(json.dumps(r, sort_keys=True) + "\\n")', "                pass", t_backfill_keeps_richer_row_and_saves_the_replaced),
    "linha mantida porque a cópia era mais pobre não é dita": ("        if self.kept_poorer:", "        if False:", t_harvest_keeps_richer_old_schema_row),
    "linha que não deu para comparar não é dita": ("        if self.kept_unknown:", "        if False:", t_backfill_keeps_richer_row_and_saves_the_replaced),
    "troca de schema antigo não é contada nem aponta a cópia": ("        if self.saved:", "        if False:", t_harvest_keeps_richer_old_schema_row),
    "o que não deu para comparar é contado como 'já tinha registro mais completo'": ("{stats.kept_poorer} já tinham registro mais completo", "{stats.kept_poorer + stats.kept_unknown} já tinham registro mais completo", t_backfill_keeps_richer_row_and_saves_the_replaced),
    "qualquer erro do flock é contenção": ("        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):", "        if True:", t_lock_error_is_not_contention),
    "harvest não trata o erro do lock": ('    except LedgerLockError as e:\n        print(f"harvest: ERRO', '    except KeyError as e:\n        print(f"harvest: ERRO', t_lock_error_is_not_contention),
    "backfill-s3 não trata o erro do lock": ('    except LedgerLockError as e:\n        print(f"backfill-s3: ERRO', '    except KeyError as e:\n        print(f"backfill-s3: ERRO', t_lock_error_is_not_contention),
    "atalho de usuário pula registro de assistente": ("if is_user and not is_asst and alias is not None", "if is_user and alias is not None", t_assistant_record_with_user_word_is_counted),
}

CASES = [("dedup por message.id (entre registros e entre arquivos)", t_dedup), ("preço e TTL de cache", t_price),
         ("composição do custo: uma fórmula só", t_composition), ("<synthetic> fora, modelo sem preço = n/p, --assume-price rotulado", t_synthetic_unpriced),
         ("claim ok / falho / sem resultado; pré-claim rateado", t_claims), ("preâmbulo ≠ bead; ocioso; referência; crew", t_noise_idle_ref_crew),
         ("JSON espaçado lido igual + alarme de formato", t_json_spacing_and_canary), ("desconhecido ≠ zero: resposta sem usage e linha ilegível aparecem", t_unknown_is_not_zero), ("subagente entra na sessão-mãe sem duplicar", t_subagent), ("revisor: ramo certo entre citações", t_reviewer),
         ("janela por dia da mensagem", t_window_by_message_day), ("gate: 1ª rodada, coorte, US$/bead aprovada, dry_run fora", t_gate_cohort), ("aprovada em qualquer rodada + poder do A/B", t_approved_and_power), ("teto de contexto: excesso exato + registro antigo reescaneado", t_context_caps),
         ("ledger: idempotente, cresce, sobrevive ao reaper, mais completo vence", t_ledger), ("lock de instância única", t_lock),
         ("terceiro estado: SEM DADO", t_no_data), ("backfill-s3: erro≠vazio, falha contada, disco, escopo", t_backfill),
         ("varredura do 3º estado: ocioso sem preço, revisor por sessão, veredito sem bead, claim sem timestamp, ledger ilegível", t_sweep_unknowns),
         ("3º estado nas seções 3-5 e 1b: bead/coorte/sistema com token sem preço = n/p ou piso rotulado, nunca 0", t_unpriced_report),
         ("seção 6: bead sem preço fora do CV (quantos), todos sem preço = n/p e não estoura", t_power_unpriced),
         ("seção que estoura não joga fora as prontas (texto e --json, exit 1)", t_report_survives_crash),
         ("claim sem resultado ≠ verificado, veredito sem dry_run ≠ ensaio, resposta sem timestamp avisada", t_lows),
         ("claim: resultado visível que não confirma ≠ sem resultado; dois claims num comando; tool_use sem id", t_claim_states),
         ("claim que falhou não vira atribuição por referência", t_claim_not_a_reference),
         ("seção 2: claim sem timestamp não é spawn ocioso", t_idle_vs_untimed_claim),
         ("JSON e texto com os mesmos avisos: janela incompleta, ledger ilegível, desconhecidos da colheita", t_report_unknown_counters),
         ("schema novo: linha escrita pela regra antiga é reescaneada e contada", t_schema_rescan),
         ("alarme de formato: 1ª linha e exit ≠ 0", t_harvest_alarm_first_and_nonzero),
         ("e2-readout: veredito sem dry_run e linha que não é registro contados, não calados", t_e2_readout_missing_dry_run),
         ("seção 2: claim não confirmado não é spawn ocioso; atribuição por referência lista todos os verbos", t_idle_vs_unconfirmed_claim),
         ("JSON válido que não é registro (null, string, lista) é linha ilegível contada, não exceção", t_non_record_json_lines),
         ("seção 6: queda maior que a taxa é n/a, não '0 beads por braço'", t_power_unreachable_drop),
         ("harvest: raiz de transcritos ausente/ilegível/vazia, projeto ilegível = alarme + exit 6, não 'nada a colher'", t_harvest_input_unreadable),
         ("fingerprint tirado antes da leitura: a escrita do meio não é atestada sem ter sido lida", t_fingerprint_before_read),
         ("subagente que não abre (arquivo ou diretório) é contado, no ledger, na colheita e no relatório", t_unreadable_subagent_files),
         ("seção 6: papel com poucos beads no --json; sessões e beads/sessão medidos (o braço é por sessão)", t_power_json_and_sessions),
         ("revisor: cabeçalho quebrado em ~80 colunas (formato real, também `cat -n`) é juntado e o custo chega ao bead", t_reviewer_wrapped_header),
         ("transcrito que existe mas não abre = alarme + exit 6, nunca 'sumiu no meio'; ENOENT continua 'sumiu'", t_harvest_unreadable_transcript),
         ("merge: nunca troca uma linha (de nenhum schema) por cópia mais pobre; não-comparável fica; o que sai é guardado", t_merge_never_poorer),
         ("backfill-s3: a linha mais rica fica e o texto diz; a linha de schema antigo substituída vai para .replaced-<ts>", t_backfill_keeps_richer_row_and_saves_the_replaced),
         ("colheita: linha de schema antigo mais rica que o transcrito local fica; a migrada sem perda é guardada", t_harvest_keeps_richer_old_schema_row),
         ("lock do ledger: só EWOULDBLOCK/EAGAIN é contenção; ENOLCK é falha alta (harvest e backfill-s3)", t_lock_error_is_not_contention),
         ("registro de assistente cuja linha contém \"user\" é contado, não pulado como linha de usuário", t_assistant_record_with_user_word_is_counted)]


def run(name, fn, m):
    global PASS, FAIL
    W = Path(tempfile.mkdtemp(prefix="btm-selftest."))
    try:
        fn(m, W)
        print(f"  ✓ {name}")
        PASS += 1
        return True
    except Fail as e:
        print(f"  ✗ {name}: {e}")
        FAIL += 1
        return False
    except Exception as e:  # noqa: BLE001 — um erro inesperado reprova o caso, não derruba o resto
        print(f"  ✗ {name}: EXCEÇÃO {type(e).__name__}: {e}")
        FAIL += 1
        return False
    finally:
        shutil.rmtree(W, ignore_errors=True)


def main():
    global PASS, FAIL
    src = TOOL.read_text()
    m = load(source=src)
    print("== casos")
    for name, fn in CASES:
        run(name, fn, load(source=src))
    print("== controles de mutação (cada mutante TEM que ser reprovado por pelo menos um caso)")
    for name, (old, new, case) in MUTANTS.items():
        olds, news = (old, new) if isinstance(old, tuple) else ((old,), (new,))      # um mutante pode ser UMA troca ou várias (ex.: mover uma linha)
        blind = [o for o in olds if src.count(o) != 1]
        if blind:
            print(f"  ✗ mutante '{name}': o trecho a mutar não existe exatamente 1x no script ({src.count(blind[0])}) — o controle ficou cego")
            FAIL += 1
            continue
        mut_src = src
        for o, n in zip(olds, news):
            mut_src = mut_src.replace(o, n)
        mut = load(source=mut_src, name="btm_mut")
        W = Path(tempfile.mkdtemp(prefix="btm-mut."))
        try:
            try:
                with contextlib.redirect_stderr(io.StringIO()):     # um mutante que estoura o relatório imprime o traceback dele: ruído, não resultado
                    case(mut, W)
                print(f"  ✗ mutante '{name}' SOBREVIVEU (o caso passou com o script quebrado)")
                FAIL += 1
            except (Fail, Exception):  # noqa: BLE001
                print(f"  ✓ mutante '{name}' reprovado")
                PASS += 1
        finally:
            shutil.rmtree(W, ignore_errors=True)
    print(f"\n{PASS} ok, {FAIL} falhas")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
