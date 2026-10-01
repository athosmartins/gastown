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
  * controles de mutação: 9 mutantes do script, cada um reprovado por pelo menos um caso (o teste que só passa não prova nada)
"""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
import shutil
import stat
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
    ck(r["power"] == {}, f"com <20 beads por papel não se estima poder (vazio, não um número inventado), achei {r['power']}")
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


MUTANTS = {   # nome -> (trecho do script, mutação, caso que TEM que reprovar)
    "soma linhas (sem dedup)": ('if v > rec["use"][k]:\n                                rec["use"][k] = v', 'rec["use"][k] += v', t_dedup),
    "leitura de cache a preço cheio": ('"cr": 0.10}', '"cr": 1.0}', t_price),
    "sem preço vira US$ 0": ('        return None\n    pin, pout = p\n    return (c["inp"] * pin + c["out"] * pout', '        return 0.0\n    pin, pout = p\n    return (c["inp"] * pin + c["out"] * pout', t_price),
    "claim que falhou conta": ('if c["ok"] is not False and c["ts"]', 'if c["ts"]', t_claims),
    "só o 1º ramo do revisor": ("len(branches) < 6", "len(branches) < 1", t_reviewer),
    "janela por início de sessão": ('(s.get("days") or {}).items():\n            if day < since_day:\n                continue\n', '(s.get("days") or {}).items():\n', t_window_by_message_day),
    "excesso acima do teto vira o cache-read inteiro": ('+= max(0, m["use"]["cr"] - cap)', '+= m["use"]["cr"]', t_context_caps),
    "prefiltro depende do espaçamento": ('is_asst = \'"assistant"\' in line', 'is_asst = \'"type":"assistant"\' in line', t_json_spacing_and_canary),
    "id do preâmbulo vira bead": ("if not live and role in POOL_BUILDERS and refs:", "if not live and role in POOL_BUILDERS + ('crew',) and refs:", t_noise_idle_ref_crew),
}

CASES = [("dedup por message.id (entre registros e entre arquivos)", t_dedup), ("preço e TTL de cache", t_price),
         ("composição do custo: uma fórmula só", t_composition), ("<synthetic> fora, modelo sem preço = n/p, --assume-price rotulado", t_synthetic_unpriced),
         ("claim ok / falho / sem resultado; pré-claim rateado", t_claims), ("preâmbulo ≠ bead; ocioso; referência; crew", t_noise_idle_ref_crew),
         ("JSON espaçado lido igual + alarme de formato", t_json_spacing_and_canary), ("desconhecido ≠ zero: resposta sem usage e linha ilegível aparecem", t_unknown_is_not_zero), ("subagente entra na sessão-mãe sem duplicar", t_subagent), ("revisor: ramo certo entre citações", t_reviewer),
         ("janela por dia da mensagem", t_window_by_message_day), ("gate: 1ª rodada, coorte, US$/bead aprovada, dry_run fora", t_gate_cohort), ("aprovada em qualquer rodada + poder do A/B", t_approved_and_power), ("teto de contexto: excesso exato + registro antigo reescaneado", t_context_caps),
         ("ledger: idempotente, cresce, sobrevive ao reaper, mais completo vence", t_ledger), ("lock de instância única", t_lock),
         ("terceiro estado: SEM DADO", t_no_data), ("backfill-s3: erro≠vazio, falha contada, disco, escopo", t_backfill)]


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
        if src.count(old) != 1:
            print(f"  ✗ mutante '{name}': o trecho a mutar não existe exatamente 1x no script ({src.count(old)}) — o controle ficou cego")
            FAIL += 1
            continue
        mut = load(source=src.replace(old, new), name="btm_mut")
        W = Path(tempfile.mkdtemp(prefix="btm-mut."))
        try:
            try:
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
