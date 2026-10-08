#!/usr/bin/env python3
"""Selftest de jev_gate_fail_desfecho_report.py (ga-rmzfye). Fica em arquivo próprio — como
jev_recomecar_experiment.selftest.py — porque o teto E11 do gate (800 linhas) não conta *.selftest.py como
produção. Rode: python3 jev_gate_fail_desfecho_report.selftest.py  (ou  ...report.py selftest, que delega).

git real num repositório temporário; nada de rede, nem `bd`, nem log vivo (o único subprocess é o próprio
CLI, apontado pra arquivos temporários). Saída: 0 = tudo passou, 1 = alguma falha."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_gate_fail_desfecho_report as _report  # noqa: E402
from jev_gate_fail_desfecho_report import (  # noqa: E402
    BASE,
    InputError,
    LIGHT,
    _numstat_total,
    _patch_lines,
    atomic_leve,
    base_for,
    build_summary,
    compare,
    fail_kind,
    fc,
    first_submit_ts,
    format_report,
    group_stats,
    join_records,
    newcombe_diff,
    parse_rebases,
    pending_fails,
    repair_size,
    strict_leve,
    summarize,
    wilson,
)


def _selftest() -> int:
    import subprocess

    passed = failed = 0

    def ok(label: str, cond: bool) -> None:
        nonlocal passed, failed
        passed, failed = (passed + 1, failed) if cond else (passed, failed + 1)
        print(f"  {'ok  ' if cond else 'FAIL'} {label}")

    # fail_kind: espelha classify_fail_reason
    ok("FAIL de revisão", fail_kind("Reviewer 1 FAIL: VERDICT: FAIL") == "review")
    ok("TIMEOUT é mecânico", fail_kind("TIMEOUT: reviewers did not submit verdicts within 45 minutes.") == "mechanical")
    ok("merge quebrado é mecânico", fail_kind("Merge failed after all-PASS verdict.") == "mechanical")
    ok("reason ausente é unknown (3º estado), não 'review'", fail_kind(None) == "unknown" and fail_kind("") == "unknown")

    # estatística
    ok("wilson n=0 -> None", wilson(0, 0) is None)
    lo, hi = wilson(5, 10)
    ok("wilson 5/10 contém 0.5", lo < 0.5 < hi)
    d = newcombe_diff(30, 40, 10, 40)
    ok("newcombe: 75% vs 25% exclui 0", d is not None and d[0] > 0)

    # git real, repositório temporário
    with tempfile.TemporaryDirectory() as td:
        def git(*args):
            return subprocess.run(["git", "-C", td, *args], check=True, capture_output=True, text=True,
                                  env={"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                                       "GIT_COMMITTER_EMAIL": "t@t", "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"}).stdout.strip()
        git("init", "-q", "-b", "main")
        (Path(td) / "a.txt").write_text("\n".join(f"l{i}" for i in range(100)) + "\n")
        git("add", "."); git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        git("checkout", "-qb", "feat")
        (Path(td) / "b.txt").write_text("x\n" * 10)
        git("add", "."); git("commit", "-qm", "feat v1")
        v1 = git("rev-parse", "HEAD")
        (Path(td) / "b.txt").write_text("x\n" * 10 + "fix1\nfix2\nfix3\n")
        git("add", "."); git("commit", "-qm", "repair")
        v2 = git("rev-parse", "HEAD")
        n, state = repair_size(td, v1, v2, base, base)
        ok(f"conserto linear: 3 linhas, método ancestral (got {n},{state})", n == 3 and state == "ancestral")

        # main avança 40 linhas; o autor reescreve (rebase) e conserta 3 linhas
        git("checkout", "-q", "main")
        (Path(td) / "a.txt").write_text("\n".join(f"m{i}" for i in range(140)) + "\n")
        git("add", "."); git("commit", "-qm", "main moves")
        base2 = git("rev-parse", "HEAD")
        git("checkout", "-qb", "feat2", "main")
        (Path(td) / "b.txt").write_text("x\n" * 10 + "fix1\nfix2\nfix3\n")
        git("add", "."); git("commit", "-qm", "feat rebased + repair")
        v2r = git("rev-parse", "HEAD")
        raw = _numstat_total(td, v1, v2r)
        n2, state2 = repair_size(td, v1, v2r, base, base2)
        ok(f"reescrito: diff CRU inflaria ({raw} linhas) mas o delta de patch mede só o conserto (got {n2},{state2})",
           raw is not None and raw > 40 and n2 == 3 and state2 == "delta-de-patch")
        ok("reescrito SEM base_commit é nao-medido, não 0 nem o diff cru",
           repair_size(td, v1, v2r, None, base2) == (None, "nao-medido:reescrito-sem-base_commit"))
        ok("commit que não existe é nao-medido", repair_size(td, v1, "0" * 40, base, base)[0] is None)
        ok("sha ausente é nao-medido", repair_size(td, None, v2, base, base) == (None, "nao-medido:sha-ausente"))
        ok("repo sem caminho é nao-medido", repair_size(None, v1, v2, base, base) == (None, "nao-medido:repo-sem-caminho"))
        # o gate rebaseia ANTES de revisar: o base_commit do marker fica velho. Base velha = deriva do main
        # dentro do "conserto"; a base certa vem do comentário do dispatcher.
        txt = f"Gate dispatcher auto-rebased crew/x/y onto main ({base2}). New tip: {v2r}. Proceeding with review."
        mk_m = {"base_commit": base, "rebases": parse_rebases(["lixo", txt])}
        ok("parse_rebases lê 'onto main (X). New tip: Y' (tip -> onto)", mk_m["rebases"] == {v2r: base2})
        nb_ok, why = base_for(mk_m, v2r)
        ok("base_for usa o 'onto' do rebase, não o base_commit velho", nb_ok == base2 and why is None)
        stale = repair_size(td, v1, v2r, base, base)[0]
        fresh = repair_size(td, v1, v2r, base, nb_ok)[0]
        ok(f"base velha infla o conserto ({stale}); base do rebase mede 3 (got {fresh})",
           stale is not None and stale > 40 and fresh == 3)
        # linha adicionada que começa com '++ ' não pode ser lida como cabeçalho de arquivo
        git("checkout", "-q", "feat")
        (Path(td) / "c.txt").write_text("++ not a header\n")
        git("add", "."); git("commit", "-qm", "tricky")
        pl = _patch_lines(td, base, git("rev-parse", "HEAD"))
        ok("linha '++ ...' conta como linha adicionada, sem trocar o arquivo",
           pl is not None and pl[("b/c.txt", "+", "++ not a header")] == 1)

        # arquivo SEM '\n' final, editando a última linha: o git põe "\ No newline at end of file" ENTRE o '-' e
        # o '+'. Dois consertos DIFERENTES não podem medir 0 (antes: o marcador era lido como o '+').
        git("checkout", "-q", "main")
        (Path(td) / "nl.txt").write_text("a\nb")
        git("add", "."); git("commit", "-qm", "nl base")
        nlbase = git("rev-parse", "HEAD")
        git("checkout", "-qb", "nl1")
        (Path(td) / "nl.txt").write_text("a\nb1")
        git("add", "."); git("commit", "-qm", "nl v1")
        nl1 = git("rev-parse", "HEAD")
        git("checkout", "-q", "main"); git("checkout", "-qb", "nl2")
        (Path(td) / "nl.txt").write_text("a\nb2")
        git("add", "."); git("commit", "-qm", "nl v2")
        nl2 = git("rev-parse", "HEAD")
        ok("'\\ No newline at end of file' entre '-' e '+' não é linha do patch",
           _patch_lines(td, nlbase, nl1) == Counter({("b/nl.txt", "-", "b"): 1, ("b/nl.txt", "+", "b1"): 1}))
        ok("dois consertos diferentes de arquivo sem '\\n' final medem 2, não 0 (got "
           f"{repair_size(td, nl1, nl2, nlbase, nlbase)})",
           repair_size(td, nl1, nl2, nlbase, nlbase) == (2, "delta-de-patch"))

    # base_for: três estados (sei / não sei / não pude saber)
    ok("sem rebase registrado: usa base_commit", base_for({"base_commit": "b" * 40, "rebases": {}}, "t" * 40) == ("b" * 40, None))
    ok("rebase registrado mas não pra este tip: nao-medido (base_commit pode estar velho)",
       base_for({"base_commit": "b" * 40, "rebases": {"x" * 40: "y" * 40}}, "t" * 40) == (None, "rebase-sem-registro-do-tip"))
    ok("marker não lido é motivo próprio, não 'sem base'", base_for(None, "t" * 40) == (None, "bd-nao-leu-marker"))
    ok("marker sem base_commit nem rebase é nao-medido", base_for({"base_commit": None, "rebases": {}}, "t" * 40) == (None, "marker-sem-base_commit"))

    # join + três estados
    def rv(run, res, reason, ts, marker="m"):
        return {"gate_run": run, "result": res, "reason": reason, "ts": ts, "marker": marker, "rig": "r"}
    real = "Reviewer 1 FAIL: VERDICT: FAIL"
    revs = {
        "b1": [rv("g1", "FAIL", real, "2026-10-01T00:00:00Z", "m1"), rv("g2", "PASS", "quorum_1_of_1", "2026-10-01T02:00:00Z", "m2")],
        "b2": [rv("g3", "FAIL", real, "2026-10-01T00:00:00Z", "m3"), rv("g4", "FAIL", "TIMEOUT: x", "2026-10-01T01:00:00Z", "m4")],
        "b3": [rv("g5", "FAIL", real, "2026-10-01T00:00:00Z", "m5")],  # nunca reenviado
        "b4": [rv("g6", "FAIL", "TIMEOUT: x", "2026-10-01T00:00:00Z", "m6"), rv("g7", "PASS", "q", "2026-10-01T01:00:00Z", "m7")],
    }
    recs = [
        {"entity_id": "b1#2", "bead": "b1", "attempt": 2, "jev_ok": True, "categoria_jev": LIGHT, "prob_categoria": 0.9,
         "probabilidades": {LIGHT: 0.9}, "desfecho_gate_run": "g2"},
        {"entity_id": "b2#2", "bead": "b2", "attempt": 2, "jev_ok": True, "categoria_jev": BASE, "prob_categoria": 0.9,
         "probabilidades": {LIGHT: 0.2}, "desfecho_gate_run": "g4"},
        {"entity_id": "b4#2", "bead": "b4", "attempt": 2, "jev_ok": True, "categoria_jev": LIGHT, "prob_categoria": 0.8,
         "probabilidades": {LIGHT: 0.8}, "desfecho_gate_run": "g7"},
        {"entity_id": "b1#9", "bead": "b1", "attempt": 9, "jev_ok": True, "categoria_jev": LIGHT, "prob_categoria": 0.9},
        {"entity_id": "bx#2", "bead": "b1", "attempt": 2, "jev_ok": True, "categoria_jev": LIGHT, "prob_categoria": 0.9,
         "desfecho_gate_run": "OUTRA"},
        {"entity_id": "b5#2", "bead": "b5", "attempt": 2, "jev_ok": False},
    ]
    rows, skipped = join_records(recs, revs)
    ok("join: 3 entidades fecham", len(rows) == 3)
    ok("join: attempt fora do range, gate_run divergente e jev_ok=False são contados, não descartados",
       skipped == Counter({"join-sem-par-de-revisoes": 1, "join-inconsistente": 1, "jev-nao-respondeu": 1}))
    by = {r["entity_id"]: r for r in rows}
    ok("b1#2: próxima passou", by["b1#2"]["next"] == "pass")
    ok("b2#2: TIMEOUT na rodada seguinte NÃO é 'conserto falhou'", by["b2#2"]["next"] == "mechanical")
    ok("b4#2: FAIL anterior mecânico fica marcado", by["b4#2"]["prior_kind"] == "mechanical")
    g = group_stats(rows)
    ok("denominador de 'passou' exclui mecânico (judged=1 de n=2 FAIL-anterior-review)", g["n"] == 2 and g["judged"] == 1 and g["pass"] == 1)
    ok("mecânico da seguinte é contado à parte", g["n_next_mecanico"] == 1 and g["n_prior_mecanico"] == 1)
    pend = pending_fails(revs, None, now=datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc))
    ok("b3 (FAIL de revisão sem nova rodada, 12h) = sem desfecho RECENTE; TIMEOUT de b4 não conta como FAIL de revisão",
       pend == {"fails_revisao": 3, "com_desfecho": 2, "sem_desfecho_recente": 1, "sem_desfecho_antigo": 0,
                "ts_desconhecido": 0, "sem_motivo": 0})
    # três estados no pendente: ts ilegível NÃO vira "antigo"; FAIL sem motivo NÃO some dos contadores
    odd = {"bx": [rv("g8", "FAIL", real, None, "m8")], "by": [rv("g9", "FAIL", real, "lixo", "m9")],
           "bz": [rv("g10", "FAIL", None, "2026-10-01T00:00:00Z", "m10")],
           "bw": [rv("g11", "FAIL", "", "2026-10-01T00:00:00Z", "m11")]}
    now0 = datetime(2026, 10, 3, tzinfo=timezone.utc)
    for since in (None, "2026-09-01T00:00:00Z"):
        po = pending_fails(odd, since, now=now0)
        ok(f"ts ausente/ilegível => ts_desconhecido=2, não 'antigo' nem fora da janela em silêncio (since={since})",
           po["ts_desconhecido"] == 2 and po["sem_desfecho_antigo"] == 0 and po["fails_revisao"] == 0)
        ok(f"FAIL sem reason (None e '') => sem_motivo=2, contado (since={since})", po["sem_motivo"] == 2)
    fs = first_submit_ts([{"event": "guard_queued", "marker": "m2", "ts": "2026-10-01T01:30:00Z"},
                          {"event": "guard_queued", "marker": "m2", "ts": "2026-10-01T01:10:00Z"},
                          {"event": "dispatcher_complete", "marker": "m2", "ts": "2026-10-01T00:01:00Z"}])
    ok("primeiro envio = menor ts de guard_*, ignora dispatcher_complete", fs == {"m2": "2026-10-01T01:10:00Z"})

    # régua do enunciado
    mk = lambda n, sp, sz: {"judged": n, "pass": sp, "sized": sz, "small_pass": sp}
    ok("separa: +30pp e n>=30", compare(mk(40, 36, 40), mk(40, 24, 40))["separa"] is True)
    ok("não separa: +30pp mas n<30", compare(mk(10, 9, 10), mk(40, 12, 40))["separa"] is False)
    ok("não separa: n ok mas +10pp", compare(mk(40, 24, 40), mk(40, 20, 40))["separa"] is False)
    ok("veredito em TRÊS estados: n pequeno é 'inconclusivo', não 'nao_separa'",
       compare(mk(40, 36, 40), mk(40, 24, 40))["veredito"] == "separa"
       and compare(mk(40, 24, 40), mk(40, 20, 40))["veredito"] == "nao_separa"
       and compare(mk(10, 9, 10), mk(40, 12, 40))["veredito"] == "inconclusivo")

    # ── ponta a ponta sem bd: summarize/group_stats/format_report. Tamanho que não se leu NUNCA vira 0.
    class SemBd:
        def get(self, _): return None
        def marker(self, _): return None
        def save(self): pass
    s = summarize(recs, revs, {}, SemBd(), {}, workers=1)
    ta = s["stats"]["TODAS"]
    ok("sem bd: julgada=1 e NENHUMA 'sized' (nao-medido não vira 0 linha)",
       ta["judged"] == 1 and ta["sized"] == 0 and ta["nao_medido"] == 1 and ta["small"] == 0)
    ok("sem bd: motivo do nao-medido aparece em size_states",
       s["size_states"] == {"nao-medido:bd-nao-leu-gate_run": 1})
    ok("sem bd: todo grupo vs base é 'inconclusivo' (n_medido=0), e o JSON carrega o veredito",
       all(c["veredito"] == "inconclusivo" for c in s["vs_base"].values()))
    txt = format_report(s)
    ok("relatório nomeia o motivo nao-medido e rotula amostra pequena como INCONCLUSIVO, sem 'NAO SEPARA'",
       "bd-nao-leu-gate_run" in txt and "INCONCLUSIVO" in txt and "NAO SEPARA" not in txt)
    # probabilidade que não se leu != probabilidade baixa: fora dos cortes, mas CONTADA e mostrada
    recs_np = [dict(r, prob_categoria=None) if r["entity_id"] == "b1#2" else r for r in recs]
    s_np = summarize(recs_np, revs, {}, SemBd(), {}, workers=1)
    ok("sem prob_categoria: n_sem_prob=1, fora do grupo estrito (mas dentro de 'qualquer prob'), e o texto avisa",
       s["n_sem_prob"] == 0 and s_np["n_sem_prob"] == 1
       and s_np["stats"]["ajuste_pequeno_p07_estrito"]["n"] == s["stats"]["ajuste_pequeno_p07_estrito"]["n"] - 1
       and s_np["stats"]["ajuste_pequeno_qualquer_prob"]["n"] == s["stats"]["ajuste_pequeno_qualquer_prob"]["n"]
       and "SEM probabilidade legível" in format_report(s_np) and "SEM probabilidade legível" not in txt)
    ok("prob ausente nunca passa o corte (None != 0.0 != 0.9)",
       not strict_leve({"categoria": LIGHT, "prob": None}) and not atomic_leve({"p_ajuste": None})
       and strict_leve({"categoria": LIGHT, "prob": 0.7}) and atomic_leve({"p_ajuste": 0.7})
       and not strict_leve({"categoria": LIGHT, "prob": 0.69}))
    ok("sem linha em comum com a base: sem rótulo de sobreposição",
       s["vs_base"]["ajuste_pequeno_atomico_p07"]["n_sobrepoe_base"] == 0 and "também estão na base" not in txt)
    # b2#2 tem argmax bug_logica (é da base) mas p(ajuste_pequeno)=0.9: o grupo atômico ignora o argmax e o pega
    recs_ov = [dict(r, probabilidades={LIGHT: 0.9}) if r["entity_id"] == "b2#2" else r for r in recs]
    s_ov = summarize(recs_ov, revs, {}, SemBd(), {}, workers=1)
    ok("atômico (p>=0.7 ignorando o argmax) pega linha de bug_logica: sobreposição contada e rotulada no texto",
       s_ov["vs_base"]["ajuste_pequeno_atomico_p07"]["n_sobrepoe_base"] == 1
       and s_ov["vs_base"]["ajuste_pequeno_p07_estrito"]["n_sobrepoe_base"] == 0
       and "1 linhas também estão na base" in format_report(s_ov))
    s_lim = summarize(recs, revs, {}, SemBd(), {}, workers=1, limit=1)
    ok("--limit: joined é a população inteira, joined_medidas só as N primeiras, e o relatório diz TRUNCADO",
       s_lim["joined"] == 3 and s_lim["joined_medidas"] == 1 and s_lim["limit"] == 1
       and "TRUNCADO por --limit 1" in format_report(s_lim))
    ok("--limit que não trunca nada não rotula",
       summarize(recs, revs, {}, SemBd(), {}, workers=1, limit=3)["limit"] is None)

    # ── joined == 0: o relatório tem de dizer POR QUÊ (ga-rmzfye gate-fail 1: entrada ilegível ≠ "nada a medir")
    s_zero = summarize(recs, {}, {}, SemBd(), {}, workers=1)
    out0 = format_report(s_zero)
    ok("records>0 e join todo vazio: imprime os motivos e NÃO diz 'nada a medir'",
       s_zero["joined"] == 0 and s_zero["records"] == len(recs) and "join-sem-par-de-revisoes" in out0
       and "NADA FOI MEDIDO" in out0 and "nada a medir" not in out0)
    out_empty = format_report(summarize([], {}, {}, SemBd(), {}, workers=1) | {"inputs": {
        "jev_log": "/x/jev.jsonl", "jev_linhas": 5, "gate_log": "/x/gate.jsonl", "gate_revisoes": 9}})
    ok("sombra realmente sem entidades do modo: 'nada a medir', COM os arquivos e as contagens lidas",
       "nada a medir" in out_empty and "/x/jev.jsonl" in out_empty and "5 linhas JSON" in out_empty)

    # ── entrada ausente/ilegível => InputError / exit != 0 (a mesma coisa que o relatório faz quando SABE != quando NÃO PODE saber)
    with tempfile.TemporaryDirectory() as td2:
        d = Path(td2)
        good_jev = d / "jev.jsonl"
        good_jev.write_text(json.dumps({"mode": fc.MODE, "experiment": fc.EXPERIMENT, "entity_id": "b1#2", "bead": "b1",
                                        "attempt": 2, "jev_ok": True}) + "\n")
        good_gate = d / "gate.jsonl"
        good_gate.write_text(json.dumps({"event": "dispatcher_complete", "bead": "b1", "gate_run": "g1", "result": "FAIL",
                                         "reason": real, "ts": "2026-10-01T00:00:00Z", "dry_run": "0"}) + "\n")
        no_reviews = d / "gate-sem-revisoes.jsonl"
        no_reviews.write_text(json.dumps({"event": "guard_queued", "marker": "m1", "ts": "2026-10-01T00:00:00Z"}) + "\n")
        garbage = d / "lixo.jsonl"
        garbage.write_text("isto não é json\n{quebrado\n")
        empty_jev = d / "vazio.jsonl"
        empty_jev.write_text("")
        missing = str(d / "nao-existe.jsonl")

        def raises(**kw) -> str | None:
            try:
                build_summary(gc_city=td2, **kw)
            except InputError as e:
                return str(e)
            return None

        m1 = raises(log=str(good_jev), gate_log=missing)
        ok("--gate-log inexistente => InputError que nomeia o caminho", m1 is not None and missing in m1)
        m2 = raises(log=missing, gate_log=str(good_gate))
        ok("--log inexistente => InputError que nomeia o caminho", m2 is not None and missing in m2)
        m3 = raises(log=str(good_jev), gate_log=str(no_reviews))
        ok("entidades no Jev + log do gate sem nenhuma revisão => InputError (não 'nada a medir')",
           m3 is not None and "nenhuma revisão" in m3)
        m4 = raises(log=str(garbage), gate_log=str(good_gate))
        ok("log do Jev com conteúdo mas nenhuma linha JSON legível => InputError", m4 is not None and "nenhuma linha JSON" in m4)
        m5 = raises(log=str(d), gate_log=str(good_gate))
        ok("--log apontando pra diretório => InputError", m5 is not None)
        sv = build_summary(log=str(empty_jev), gate_log=str(good_gate), gc_city=td2)
        ok("Jev legitimamente vazio + gate com revisões => sem erro, records=0, e as entradas lidas vêm no resumo",
           sv["records"] == 0 and sv["inputs"]["gate_revisoes"] == 1 and sv["inputs"]["jev_linhas"] == 0)

        # ponta a ponta pelo CLI: stdout VAZIO, stderr explica, exit 2 — nunca exit 0 com texto de relatório
        me = Path(_report.__file__).resolve()
        for label, args in (("--gate-log inexistente", ["--log", str(good_jev), "--gate-log", missing]),
                            ("--log inexistente", ["--log", missing, "--gate-log", str(good_gate)]),
                            ("--json + --gate-log inexistente", ["--json", "--log", str(good_jev), "--gate-log", missing])):
            p = subprocess.run([sys.executable, str(me), "--gc-city", td2, *args], capture_output=True, text=True, timeout=60)
            ok(f"CLI {label}: exit 2, stdout vazio, stderr nomeia o erro (got rc={p.returncode})",
               p.returncode == 2 and p.stdout == "" and "ERRO:" in p.stderr and "nada a medir" not in p.stdout)

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(_selftest())
