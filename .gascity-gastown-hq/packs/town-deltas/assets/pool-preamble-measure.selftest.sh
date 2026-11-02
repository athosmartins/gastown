#!/usr/bin/env bash
# pool-preamble-measure.selftest.sh — ga-aijm2v.6: a ferramenta que MEDE o corte tem que estar certa, senão o critério de aceite
# ("caiu >= 40k tokens, medido") vira número sem lastro. Fixtures sintéticas, hermético (PPM_PROJECTS / PPM_GATE_LOG).
# Cada caso existe por um erro real que a 1ª versão da ferramenta teve ou poderia ter:
#   * mensagem <synthetic> de uso 0 contada como "1º turno = 0" (corrompia a cauda baixa — achado medindo o baseline)
#   * sessão de subagente (isSidechain) contada como sessão de pool
#   * "1ª tentativa" contando re-execução de bead cuja 1ª execução foi ANTES da janela
#   * linhas ilegíveis do log do gate derrubando a leitura (havia 20 de 14.6k) / dry_run contado como rodada real
#   * veredito de queda sem controle histórico (o gate varia sozinho: um corte arbitrário mostrou -25 pontos, p~0)
#   * tool_use contada DEPOIS do dedup por message.id: o Claude Code grava 1 registro por bloco (thinking/text/tool_use) com o MESMO id, então só
#     ~1 de cada 9 tool_use era vista e "nenhuma tentativa de tool negada" significava "não consegui ver" (gate ga-0g70nl, bloqueante 1)
#   * terceiro estado em todo lugar: papel sem sessão = SEM DADO; queda significativa sem histórico = "não sei"; sessão sem timestamp != "sem sessão";
#     transcrito apagado no meio da varredura não derruba a medição e é CONTADO
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$SELF_DIR/pool-preamble-measure.py"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/pool-measure-selftest.XXXXXX")"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/projects/-p1"

echo "== first-turn: papel pelo beacon, before/after pelo corte, ruído fora"
python3 - "$W/projects/-p1" <<'EOF'
import json, sys
d = sys.argv[1]
def sess(name, alias, ts, first, extra=()):
    rows = [{"type": "user", "timestamp": ts, "message": {"content": f"[gascity] {alias} • {ts}\n\n# ctx"}}]
    rows.append({"type": "assistant", "timestamp": ts, "message": {"id": "m0", "model": "<synthetic>", "usage": {"input_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}, "content": []}})
    rows.append({"type": "assistant", "timestamp": ts, "message": {"id": "m1", "usage": {"input_tokens": 2, "cache_creation_input_tokens": first - 502, "cache_read_input_tokens": 500}, "content": [{"type": "tool_use", "name": "Bash"}, {"type": "tool_use", "name": "SendMessage"}]}})
    rows.append({"type": "assistant", "isSidechain": True, "timestamp": ts, "message": {"id": "s1", "usage": {"input_tokens": 9, "cache_creation_input_tokens": 999999, "cache_read_input_tokens": 0}, "content": [{"type": "tool_use", "name": "Artifact"}]}})
    rows += list(extra)
    open(f"{d}/{name}.jsonl", "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
# antes do corte (23/09): dog 1502 e 1702 ; depois: dog 502 e 702 ; um gate-reviewer só depois ; um beacon desconhecido
sess("a", "gastown.dog-1", "2026-09-20T10:00:00Z", 1502); sess("b", "gastown.dog-2", "2026-09-21T10:00:00Z", 1702)
sess("c", "gastown.dog-3", "2026-09-26T10:00:00Z", 502);  sess("d", "gastown.dog-4", "2026-09-27T10:00:00Z", 702)
sess("e", "gate-reviewer-adhoc-abc123", "2026-09-26T11:00:00Z", 900); sess("f", "refino-gate-reviewer-adhoc-1", "2026-09-26T12:00:00Z", 800)
# controle positivo do denied-attempts: um dog DEPOIS do corte que chama Workflow (negada a todo papel de pool).
# Layout REAL do Claude Code: UM registro JSONL por bloco de conteúdo, todos com o MESMO message.id (thinking / text / tool_use), cada um
# repetindo o `usage`. Aqui a tool_use é o 3º registro do id "m9": um dedup por message.id ANTES de contar tool_use (a 1ª versão da ferramenta)
# NÃO a enxerga. O controle antigo punha a tool_use no 1º e único registro do id — passava no vácuo (veredito do gate ga-0g70nl).
U = {"input_tokens": 1, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 10}
wf = [[{"type": "thinking", "thinking": "vou chamar Workflow"}], [{"type": "text", "text": "chamando"}], [{"type": "tool_use", "id": "toolu_wf1", "name": "Workflow", "input": {}}]]
sess("g", "gastown.dog-5", "2026-09-26T13:00:00Z", 600, extra=[{"type": "assistant", "timestamp": "2026-09-26T13:00:01Z", "message": {"id": "m9", "usage": U, "content": b}} for b in wf])
EOF
out="$(PPM_PROJECTS="$W/projects" python3 "$TOOL" first-turn --since-hours 100000 --cutover 2026-09-23T00:00:00Z --json)"
cat > "$W/chk.py" <<'EOF'
import json, sys
d = json.load(sys.stdin)["roles"]; errs = []
def chk(c, m):
    if not c: errs.append(m)
dog = d["dog"]
chk(dog["before"]["n"] == 2 and dog["before"]["median"] == 1602, "dog antes: %r" % (dog["before"],))
chk(dog["after"]["n"] == 3 and dog["after"]["median"] == 600, "dog depois: %r" % (dog["after"],))
chk(d["gate-reviewer"]["after"]["median"] == 900 and d["gate-reviewer"]["before"]["n"] == 0, "gate-reviewer (beacon gate-reviewer-adhoc-*)")
chk("refino-gate-reviewer" in d and d["refino-gate-reviewer"]["after"]["median"] == 800, "refino-gate-reviewer não pode cair em gate-reviewer (ordem das regras)")
chk(all(v["after"]["median"] != 1000501 for v in d.values() if v["after"]["n"]), "subagente (isSidechain) foi contado como sessão")
chk(all(v["before"]["p10"] != 0 for v in d.values() if v["before"]["n"]), "synthetic de uso 0 virou 1º turno = 0")
print("\n".join("      ✗ " + e for e in errs)); sys.exit(1 if errs else 0)
EOF
echo "$out" | python3 "$W/chk.py" && ok "papéis por beacon, corte before/after, sidechain e synthetic-0 ignorados" || bad "first-turn diverge (ver acima)"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["roles"]; print("   dog antes/depois:", d["dog"]["before"]["median"], "->", d["dog"]["after"]["median"])'

echo "== denied-attempts: tool negada aparece; sessão anterior ao corte não conta"
o="$(PPM_PROJECTS="$W/projects" python3 "$TOOL" denied-attempts --since-hours 100000 --cutover 2026-09-23T00:00:00Z 2>&1)"
echo "$o" | grep -q "dog: tentou tool NEGADA: {'Workflow': 1}" && ok "controle positivo: dog que chamou Workflow (negada) FOI sinalizado" || { bad "não sinalizou o dog que chamou Workflow"; echo "$o" | sed 's/^/      /'; }
# gate-reviewer chamou SendMessage: NÃO é negada ao revisor (fica por decisão do manifesto) -> sem alerta pra ele
echo "$o" | grep -q 'gate-reviewer: tentou' && bad "sinalizou SendMessage do revisor, que NÃO é negada" || ok "SendMessage do revisor não é sinalizada (fica por decisão do manifesto)"
PPM_PROJECTS="$W/projects" python3 "$TOOL" denied-attempts --since-hours 100000 --cutover 2026-09-23T00:00:00Z --strict >/dev/null 2>&1; [ $? -eq 1 ] && ok "--strict sai 1 quando há tentativa" || bad "--strict deveria sair 1"
PPM_PROJECTS="$W/projects" python3 "$TOOL" denied-attempts --since-hours 100000 --cutover 2026-09-27T00:00:00Z --strict >/dev/null 2>&1; [ $? -eq 0 ] && ok "sessões ANTERIORES ao corte não contam (sai 0)" || bad "sessão anterior ao corte contou"

echo "== terceiro estado: ausência de dado NÃO pode virar 'tudo certo'"
PPM_PROJECTS="$W/projects" python3 "$TOOL" denied-attempts --since-hours 100000 --cutover 2099-01-01T00:00:00Z >"$W/o1" 2>&1; rc=$?
{ [ $rc -eq 2 ] && grep -q 'SEM AMOSTRA' "$W/o1" && ! grep -q 'nenhuma tentativa de tool negada' "$W/o1"; } && ok "denied-attempts sem NENHUMA sessão depois do corte -> SEM AMOSTRA (exit 2), não 'nenhuma tentativa'" || { bad "denied-attempts com zero sessões deveria ser SEM AMOSTRA (rc=$rc)"; sed 's/^/      /' "$W/o1"; }
PPM_PROJECTS="$W/projects" python3 "$TOOL" first-turn --since-hours 100000 --roles nao-existe >"$W/o2" 2>&1; rc=$?
{ [ $rc -eq 2 ] && grep -q 'SEM AMOSTRA' "$W/o2"; } && ok "first-turn sem sessão -> SEM AMOSTRA (exit 2), não tabela vazia" || { bad "first-turn vazio deveria ser SEM AMOSTRA (rc=$rc)"; sed 's/^/      /' "$W/o2"; }
PPM_PROJECTS="$W/nao-existe" python3 "$TOOL" first-turn --since-hours 24 >"$W/o3" 2>&1; rc=$?
{ [ $rc -ne 0 ] && grep -q 'não encontrado' "$W/o3"; } && ok "diretório de transcritos ausente falha ALTO" || { bad "diretório ausente deveria falhar alto (rc=$rc)"; sed 's/^/      /' "$W/o3"; }

echo "== gate-rate: só 1ª execução do bead, dry_run/ilegível fora, histórico como controle"
python3 - "$W/gate.jsonl" <<'EOF'
import json, sys, datetime as dt
T = dt.datetime(2026, 9, 25, 0, 0, tzinfo=dt.timezone.utc); rows = []
def run(bead, ts, res, dry="0", ev="dispatcher_complete", rig="gascity"):
    rows.append(json.dumps({"ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "event": ev, "bead": bead, "rig": rig, "result": res, "dry_run": dry}))
h = lambda x: dt.timedelta(hours=x)
for i in range(10): run(f"b{i}", T - h(30), "PASS" if i < 8 else "FAIL")          # ANTES: 8/10
for i in range(10): run(f"a{i}", T + h(5), "PASS" if i < 4 else "FAIL")           # DEPOIS: 4/10
run("b0", T + h(6), "FAIL")                                                       # re-execução de bead cuja 1ª foi antes: NÃO conta como 1ª tentativa do depois
run("a99", T + h(7), "FAIL", dry="1")                                             # dry-run: fora
run("a98", T + h(7), "PASS", ev="guard_queued")                                   # outro evento: fora
rows.append("{ isto não é json")                                                  # linha ilegível: pula e conta
for w in (1, 2, 3):                                                               # histórico: 3 janelas de 48h com 20 beads a 80%
    for i in range(20): run(f"h{w}_{i}", T - h(48 * w) - h(30), "PASS" if i < 16 else "FAIL")
open(sys.argv[1], "w").write("\n".join(rows) + "\n")
EOF
o="$(PPM_GATE_LOG="$W/gate.jsonl" python3 "$TOOL" gate-rate --cutover 2026-09-25T00:00:00Z --window-hours 48 --history-windows 3 2>&1)"; rc=$?
echo "$o" | grep -q 'ANTES .*8/10' && echo "$o" | grep -q 'DEPOIS .*4/10' && ok "ANTES 8/10 e DEPOIS 4/10 (re-execução, dry-run e outro evento não entram)" || { bad "contagem 1ª tentativa errada:"; echo "$o" | sed 's/^/      /'; }
echo "$o" | grep -q 'linhas ilegíveis do log ignoradas: 1' && ok "linha ilegível pulada E contada" || bad "linha ilegível não foi contada"
{ [ $rc -eq 1 ] && echo "$o" | grep -q 'VEREDITO: ALERTA'; } && ok "queda significativa E abaixo de todo o histórico -> ALERTA (exit 1)" || { bad "esperava ALERTA (rc=$rc)"; echo "$o" | sed 's/^/      /' | tail -6; }
echo "== classify_fail_reason(): formas REAIS que quality-gate-dispatcher.sh produz, íntegras E truncadas a 200 chars (gate-fix-1, ga-w3yvoz)"
# quality-gate-dispatcher.sh:8901 grava só `head -1 | tr '\n' ' ' | cut -c1-200` de FAIL_REASONS no log --
# o texto que classify_fail_reason() recebe em produção é SEMPRE a versão truncada, nunca o texto completo.
# O veredito do gate (ga-j3fjog) pegou 3 formas mecânicas reais que a 1ª versão perdia (virava "review"):
# verdict:TIMEOUT por revisor, no-verdict-label, e "Post-merge integrity check failed" (não começa com
# "Merge failed", cai fora do startswith). Também cobre o caso NEGATIVO que a 1ª correção introduziria se só
# trocasse o marcador sem entender o porquê: o fail-safe de comentário ilegível (ga-w7pm55 fail-safe) usa o
# MESMO texto de label ("Reviewer N verdict:pending: ...") do caso genuinamente mecânico -- casar o label cru
# confundiria os dois; o marcador certo é a frase que só existe no template mecânico.
o="$(python3 - "$TOOL" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ppm", sys.argv[1])
ppm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ppm)
cfr = ppm.classify_fail_reason

cases = [
    ("verdict:TIMEOUT por revisor (dispatcher ~9945-9950, no reviewer judgment)",
     "Reviewer 1 verdict:TIMEOUT: verdict bead closed without explicit PASS (no verdict:PASS label and no explicit PASS comment). No reviewer judgment was recorded — the reviewer died or drained before delivering a verdict, so this is an infrastructure failure, not a code rejection: re-submit the SAME commit with /gate-done, no code change needed (ga-w7pm55).",
     "mechanical"),
    ("no-verdict-label (nenhum label verdict: presente; dispatcher ~9945-9950)",
     "Reviewer 1 no-verdict-label: verdict bead closed without explicit PASS (no verdict:PASS label and no explicit PASS comment). No reviewer judgment was recorded — the reviewer died or drained before delivering a verdict, so this is an infrastructure failure, not a code rejection: re-submit the SAME commit with /gate-done, no code change needed (ga-w7pm55).",
     "mechanical"),
    ("Post-merge integrity check failed (dispatcher ~7238-7244, NÃO começa com 'Merge failed')",
     "Post-merge integrity check failed: merge silently dropped branch changes.",
     "mechanical"),
    ("top-level TIMEOUT, Phase C (dispatcher ~10509)",
     "TIMEOUT: reviewers did not submit verdicts within 30 minutes.",
     "mechanical"),
    ("Merge failed after all-PASS verdict (dispatcher ~7147)",
     "Merge failed after all-PASS verdict. Merge result: conflict. Check git state of rig gascity.",
     "mechanical"),
    ("REGRESSÃO: fail-safe de comentário ilegível, label verdict:pending (ga-w7pm55 fail-safe, dispatcher ~9938) -- FAIL real de revisor, NUNCA mecânico mesmo casando 'verdict:pending'",
     "Reviewer 1 verdict:pending: verdict bead closed without explicit PASS (no verdict:PASS label and no explicit PASS comment); its comments could not be read this sweep, so a reviewer FAIL cannot be ruled out (ga-w7pm55 fail-safe).",
     "review"),
    ("revisor real, veredito no label (dispatcher ~9938 FAIL_COMMENT branch)",
     "Reviewer 1 FAIL: VERDICT: FAIL — race condition in shared cache",
     "review"),
    ("revisor real, label perdeu a corrida mas comentário ancorado (dispatcher ~9938)",
     "Reviewer 1 FAIL: VERDICT: FAIL — off-by-one in the retry cap",
     "review"),
]

bad_cases = []
for label, reason, expect in cases:
    got = cfr(reason)
    tag = "OK " if got == expect else "BAD"
    print(f"{tag} integral   | {label} | want={expect} got={got}")
    if got != expect:
        bad_cases.append(label + " (integral)")
    truncated = reason[:200]
    got_t = cfr(truncated)
    tag_t = "OK " if got_t == expect else "BAD"
    print(f"{tag_t} truncado200 | {label} | want={expect} got={got_t}")
    if got_t != expect:
        bad_cases.append(label + " (truncado a 200 chars, como o log real grava)")

sys.exit(1 if bad_cases else 0)
EOF
)"
rc=$?
echo "$o" | sed 's/^/      /'
[ $rc -eq 0 ] && ok "classify_fail_reason(): todas as 8 formas reais, íntegras e truncadas a 200 chars, classificadas certo" || bad "classify_fail_reason(): pelo menos uma forma real classificada errado (ver linhas BAD acima)"

echo "== gate-rate: mesmas formas reais, fim-a-fim pelo comando (não só a função isolada) (ga-w3yvoz)"
python3 - "$W/gate_mech.jsonl" <<'EOF'
import json, sys, datetime as dt
T = dt.datetime(2026, 9, 25, tzinfo=dt.timezone.utc); rows = []
def run(bead, ts, res, reason=None):
    r = {"ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "event": "dispatcher_complete", "bead": bead, "rig": "gascity", "result": res, "dry_run": "0"}
    if reason is not None: r["reason"] = reason
    rows.append(json.dumps(r))
h = lambda x: dt.timedelta(hours=x)
# ANTES: 5 FAILs -- 2 de revisão real, 1 timeout de topo, 1 verdict:TIMEOUT por revisor (truncado a 200
# chars como o dispatcher realmente grava), 1 fail-safe de comentário ilegível (verdict:pending -- tem que
# ficar "review", não "mechanical", mesmo casando o label) (2/5 mecânicos)
run("b0", T - h(30), "PASS"); run("b1", T - h(30), "PASS")
run("b2", T - h(30), "FAIL", "Reviewer 1 FAIL: VERDICT: FAIL ")
run("b3", T - h(30), "FAIL", "Reviewer 1 FAIL: VERDICT: FAIL (lens: CORRECTNESS)")
run("b4", T - h(30), "FAIL", "TIMEOUT: reviewers did not submit verdicts within 30 minutes.")
run("b5", T - h(30), "FAIL", "Reviewer 1 verdict:TIMEOUT: verdict bead closed without explicit PASS (no verdict:PASS label and no explicit PASS comment). No reviewer judgment was recorded — the reviewer died or drained before deli")
run("b6", T - h(30), "FAIL", "Reviewer 1 verdict:pending: verdict bead closed without explicit PASS (no verdict:PASS label and no explicit PASS comment); its comments could not be read this sweep, so a reviewer FAIL cannot be rule")
# DEPOIS: 3 FAILs -- 1 de revisão real, 1 merge-quebrado-apos-PASS, 1 post-merge-integrity (2/3 mecânicos)
run("a0", T + h(5), "PASS")
run("a1", T + h(5), "FAIL", "Reviewer 1 FAIL: VERDICT: FAIL ")
run("a2", T + h(5), "FAIL", "Merge failed after all-PASS verdict. Merge conflict.")
run("a3", T + h(5), "FAIL", "Post-merge integrity check failed: merge silently dropped branch changes.")
open(sys.argv[1], "w").write("\n".join(rows) + "\n")
EOF
o="$(PPM_GATE_LOG="$W/gate_mech.jsonl" python3 "$TOOL" gate-rate --cutover 2026-09-25T00:00:00Z --window-hours 48 --history-windows 1 2>&1)"
echo "$o" | grep -q 'MECÂNICOS.*ANTES 2/5.*DEPOIS 2/3' && ok "breakdown mecânico/revisão fim-a-fim: ANTES 2/5, DEPOIS 2/3 (inclui verdict:TIMEOUT truncado e post-merge-integrity certos, fail-safe verdict:pending NÃO contado)" || { bad "breakdown mecânico ausente ou errado:"; echo "$o" | sed 's/^/      /'; }
# controle: FAILs sem campo "reason" (fixture antiga, sem essa informação) não podem ser CHUTADOS como mecânicos --
# terceiro estado (não sei classificar) tem que cair no lado conservador (review), nunca inflar a contagem mecânica.
o2="$(PPM_GATE_LOG="$W/gate.jsonl" python3 "$TOOL" gate-rate --cutover 2026-09-25T00:00:00Z --window-hours 48 --history-windows 3 2>&1)"
echo "$o2" | grep -q 'MECÂNICOS.*ANTES 0/2.*DEPOIS 0/6' && ok "FAIL sem 'reason': classificado como revisão (0 mecânicos), não inventado" || { bad "FAIL sem 'reason' classificado errado:"; echo "$o2" | sed 's/^/      /'; }

# cenário 2: queda pequena/ruidosa DENTRO do histórico não pode alarmar
python3 - "$W/gate.jsonl" <<'EOF'
import json, sys, datetime as dt
T = dt.datetime(2026, 9, 25, tzinfo=dt.timezone.utc); rows = []
def run(bead, ts, res):
    rows.append(json.dumps({"ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "event": "dispatcher_complete", "bead": bead, "rig": "gascity", "result": res, "dry_run": "0"}))
h = lambda x: dt.timedelta(hours=x)
for i in range(40): run(f"b{i}", T - h(30), "PASS" if i < 32 else "FAIL")       # ANTES 80%
for i in range(40): run(f"a{i}", T + h(5), "PASS" if i < 30 else "FAIL")        # DEPOIS 75%  (ruído)
for w, ok_ in ((1, 28), (2, 30)):                                                # histórico 70% e 75%: o DEPOIS está DENTRO da faixa
    for i in range(40): run(f"h{w}_{i}", T - h(48 * w) - h(30), "PASS" if i < ok_ else "FAIL")
open(sys.argv[1], "w").write("\n".join(rows) + "\n")
EOF
o="$(PPM_GATE_LOG="$W/gate.jsonl" python3 "$TOOL" gate-rate --cutover 2026-09-25T00:00:00Z --window-hours 48 --history-windows 2 2>&1)"; rc=$?
{ [ $rc -eq 0 ] && ! echo "$o" | grep -q 'VEREDITO: ALERTA'; } && ok "queda dentro da faixa histórica NÃO alarma (exit 0)" || { bad "alarmou queda dentro do ruído histórico (rc=$rc)"; echo "$o" | sed 's/^/      /' | tail -6; }
o="$(PPM_GATE_LOG="$W/none.jsonl" python3 "$TOOL" gate-rate --cutover 2026-09-25T00:00:00Z 2>&1)"; rc=$?
{ [ $rc -ne 0 ] && echo "$o" | grep -q 'não encontrado'; } && ok "log ausente falha ALTO (não devolve 0/0 como se fosse ok)" || bad "log ausente deveria falhar alto (rc=$rc)"

echo "== tool_use contada por BLOCO (gate ga-0g70nl, bloqueante 1): registros de um mesmo message.id"
mkdir -p "$W/unit/-p"
python3 - "$W/unit/-p" <<'EOF'
import json, sys
d = sys.argv[1]; U = {"input_tokens": 1, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 50}
def rec(mid, blocks, ts="2026-09-26T10:00:00Z", usage=U):
    return {"type": "assistant", "timestamp": ts, "message": {"id": mid, "usage": usage, "content": blocks}}
rows = [{"type": "user", "timestamp": "2026-09-26T10:00:00Z", "message": {"content": "[gascity] gastown.dog-9 • 2026-09-26T10:00:00\n\n# ctx"}},
        # m20: thinking / text / tool_use(Workflow) em 3 registros do MESMO id
        rec("m20", [{"type": "thinking", "thinking": "x"}]), rec("m20", [{"type": "text", "text": "y"}]),
        rec("m20", [{"type": "tool_use", "id": "toolu_w1", "name": "Workflow", "input": {}}]),
        # m21: DUAS tool_use Bash de ids diferentes em registros diferentes do mesmo message.id
        rec("m21", [{"type": "tool_use", "id": "toolu_b1", "name": "Bash", "input": {}}]),
        rec("m21", [{"type": "tool_use", "id": "toolu_b2", "name": "Bash", "input": {}}]),
        # o MESMO registro repetido (mesmo id de bloco): não pode contar duas vezes
        rec("m21", [{"type": "tool_use", "id": "toolu_b1", "name": "Bash", "input": {}}]),
        # 2 tool_use no MESMO registro
        rec("m22", [{"type": "tool_use", "id": "toolu_r1", "name": "Read", "input": {}}, {"type": "tool_use", "id": "toolu_r2", "name": "Read", "input": {}}]),
        # bloco SEM id (o real sempre traz; sem ele só resta a posição): conta 1 E o residual é declarado, não calado
        rec("m23", [{"type": "tool_use", "name": "Glob", "input": {}}]),
        # subagente: fora
        dict(rec("s1", [{"type": "tool_use", "id": "toolu_s1", "name": "Artifact", "input": {}}]), isSidechain=True)]
open(d + "/u.jsonl", "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
EOF
cat > "$W/unit_chk.py" <<'EOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("ppm", sys.argv[1]); ppm = importlib.util.module_from_spec(spec); spec.loader.exec_module(ppm)
s = ppm.scan_session(sys.argv[2] + "/-p/u.jsonl"); errs = []
def chk(c, m):
    if not c: errs.append(m)
chk(s is not None, "scan_session devolveu None")
t = dict(s["tools"]) if s else {}
chk(t.get("Workflow") == 1, f"Workflow no 3º registro do message.id: esperado 1, veio {t.get('Workflow')} (dedup por message.id antes de contar tool_use)")
chk(t.get("Bash") == 2, f"2 Bash de ids diferentes em registros do mesmo message.id + 1 registro repetido: esperado 2, veio {t.get('Bash')}")
chk(t.get("Read") == 2, f"2 tool_use no mesmo registro: esperado 2, veio {t.get('Read')}")
chk("Artifact" not in t, "tool_use de subagente (isSidechain) foi contada")
chk(t.get("Glob") == 1, f"tool_use sem id: esperado 1 (por posição), veio {t.get('Glob')}")
chk(ppm.NOID[0] == 1, f"tool_use sem id tem que ser CONTADA como residual (NOID), veio {ppm.NOID[0]}")
chk("sem id de bloco" in ppm.scan_notes(), "scan_notes não declara o residual de tool_use sem id")
# tokens/turnos continuam por message.id: 4 ids distintos com uso, 1º turno = 151
chk(s and s["turns"] == 4, f"turnos: 1 por message.id (m20, m21, m22, m23): esperado 4, veio {s and s['turns']}")
chk(s and s["first"] == 151, f"1º turno: esperado 151, veio {s and s['first']}")
print("\n".join("      ✗ " + e for e in errs)); sys.exit(1 if errs else 0)
EOF
python3 "$W/unit_chk.py" "$TOOL" "$W/unit" && ok "tool_use por bloco (dedup pelo id do BLOCO); tokens/turnos seguem por message.id; subagente fora" || bad "contagem de tool_use por bloco errada (ver acima)"
# controle: o MESMO checker tem que REPROVAR o código antigo (dedup por message.id antes de contar) — senão o teste passa no vácuo
python3 - "$TOOL" "$W/old_measure.py" <<'EOF'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
# reintroduz o defeito: conta tool_use só quando a mensagem é NOVA, depois do dedup (o código de 4f7ac3b0)
m = re.search(r"                for i, b in enumerate\(msg.get\(\"content\"\) or \[\]\):.*?tools\[b.get\(\"name\"\)\] \+= 1\n", s, re.S)
assert m, "não achei o bloco de contagem por bloco para reintroduzir o defeito"
s = s.replace(m.group(0), "", 1)
s = s.replace("                turns += 1\n", "                turns += 1\n                for b in msg.get(\"content\") or []:\n                    if isinstance(b, dict) and b.get(\"type\") == \"tool_use\":\n                        tools[b.get(\"name\")] += 1\n", 1)
open(sys.argv[2], "w", encoding="utf-8").write(s)
EOF
if python3 "$W/unit_chk.py" "$W/old_measure.py" "$W/unit" >/dev/null 2>&1; then bad "o checker passou no código ANTIGO — teste vácuo"; else ok "controle negativo: o mesmo checker REPROVA o dedup por message.id (código de 4f7ac3b0)"; fi
# e2e com o layout real: o denied-attempts tem que ver o Workflow do 3º registro (fixture g acima) mesmo com --strict
PPM_PROJECTS="$W/projects" python3 "$W/old_measure.py" denied-attempts --since-hours 100000 --cutover 2026-09-23T00:00:00Z >"$W/o_old" 2>&1
grep -q "Workflow" "$W/o_old" && bad "o código ANTIGO enxergou o Workflow do 3º registro — fixture não reproduz o defeito" || ok "controle negativo e2e: o código antigo diria 'nenhuma tentativa' para o dog que chamou Workflow (o defeito do gate)"

echo "== terceiro estado no denied-attempts: papel do manifesto SEM sessão = SEM DADO, não 'sem tentativas'"
o="$(PPM_PROJECTS="$W/projects" python3 "$TOOL" denied-attempts --since-hours 100000 --cutover 2026-09-27T00:00:00Z 2>&1)"; rc=$?
{ [ $rc -eq 0 ] && echo "$o" | grep -q 'SEM DADO' && echo "$o" | grep 'SEM DADO' | grep -q 'ps-worker' && echo "$o" | grep 'SEM DADO' | grep -q 'wa-worker'; } && ok "wa-worker e ps-worker (0 sessões) listados como SEM DADO; exit 0 (há dado nos outros papéis)" || { bad "papel sem sessão não foi listado como SEM DADO (rc=$rc)"; echo "$o" | sed 's/^/      /'; }
echo "$o" | grep -q 'papéis SEM DADO acima não foram avaliados' && ok "a frase 'nenhuma tentativa' vem qualificada (não cobre os papéis sem dado)" || bad "'nenhuma tentativa' sem ressalva apesar de papéis sem dado"

echo "== first-turn: sessão existe mas sem timestamp legível != 'nenhuma sessão'; % arredondada; p90 por rank; transcrito que some é contado"
mkdir -p "$W/pnots/-p" "$W/pround/-p" "$W/pp90/-p"
python3 - "$W" <<'EOF'
import json, sys
W = sys.argv[1]
def sess(d, name, alias, ts, first, stamp=True):
    r = [{"type": "user", "message": {"content": f"[gascity] {alias} • x\n\n# ctx"}},
         {"type": "assistant", "message": {"id": "m1", "usage": {"input_tokens": 1, "cache_creation_input_tokens": first - 1, "cache_read_input_tokens": 0}, "content": []}}]
    if stamp:
        for x in r: x["timestamp"] = ts
    open(f"{W}/{d}/-p/{name}.jsonl", "w").write("\n".join(json.dumps(x) for x in r) + "\n")
sess("pnots", "a", "gastown.dog-1", "", 500, stamp=False)                       # existe, mas sem timestamp
sess("pround", "a", "gastown.dog-1", "2026-09-20T10:00:00Z", 1000); sess("pround", "b", "gastown.dog-2", "2026-09-26T10:00:00Z", 639)   # -36,1%: floor daria -37%
for i in range(10): sess("pp90", f"s{i}", f"gastown.dog-{i}", "2026-09-26T10:00:00Z", 1000 * (i + 1))                                   # 1000..10000: p90 por rank = 9000
EOF
o="$(PPM_PROJECTS="$W/pnots" python3 "$TOOL" first-turn --since-hours 100000 --cutover 2026-09-23T00:00:00Z 2>&1)"; rc=$?
{ [ $rc -eq 2 ] && echo "$o" | grep -q 'timestamp ilegível' && ! echo "$o" | grep -q 'nenhuma sessão de pool com transcrito'; } && ok "1 sessão sem timestamp: SEM AMOSTRA diz 'timestamp ilegível' (não 'nenhuma sessão')" || { bad "sessão sem timestamp descrita como ausente (rc=$rc)"; echo "$o" | sed 's/^/      /'; }
o="$(PPM_PROJECTS="$W/pround" python3 "$TOOL" first-turn --since-hours 100000 --cutover 2026-09-23T00:00:00Z 2>&1)"
echo "$o" | grep -E '^dog ' | grep -q -- '-36%' && ! echo "$o" | grep -E '^dog ' | grep -q -- '-37%' && ok "-361 sobre 1000 (-36,1%) sai -36%, não -37% (arredonda, não piso)" || { bad "percentual negativo mal arredondado"; echo "$o" | sed 's/^/      /'; }
p90="$(PPM_PROJECTS="$W/pp90" python3 "$TOOL" first-turn --since-hours 100000 --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["dog"]["after"]["p90"])')"
[ "$p90" = "9000" ] && ok "p90 de n=10 é o 9º valor (9000), não o máximo" || bad "p90 de n=10 deveria ser 9000, veio '$p90'"
python3 - "$TOOL" "$W/pp90" <<'EOF' && ok "transcrito que some entre o glob e o stat: sessão descartada, CONTADA em VANISHED, medição segue" || bad "transcrito sumido derrubou a varredura ou não foi contado"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("ppm", sys.argv[1]); ppm = importlib.util.module_from_spec(spec); spec.loader.exec_module(ppm)
ppm.PROJECTS = ppm.Path(sys.argv[2]); real = os.path.getmtime; gone = str(ppm.PROJECTS / "-p" / "s3.jsonl")
def flaky(p):
    if str(p) == gone: raise FileNotFoundError(2, "No such file or directory", str(p))
    return real(p)
os.path.getmtime = flaky
got = list(ppm.sessions(100000))
errs = []
if len(got) != 9: errs.append(f"esperava 9 sessões (10 - 1 sumida), vieram {len(got)}")
if ppm.VANISHED[0] != 1: errs.append(f"VANISHED deveria ser 1, é {ppm.VANISHED[0]}")
if ppm.scan_session(str(ppm.PROJECTS / "-p" / "nao-existe.jsonl")) is not None or ppm.VANISHED[0] != 2: errs.append("scan_session de arquivo inexistente deveria devolver None e contar")
print("\n".join("      ✗ " + e for e in errs)); sys.exit(1 if errs else 0)
EOF

echo "== gate-rate: queda significativa SEM janela histórica = 'não sei' (exit 2), nunca 'sem significância'"
python3 - "$W/gate_nohist.jsonl" <<'EOF'
import json, sys, datetime as dt
T = dt.datetime(2026, 9, 25, tzinfo=dt.timezone.utc); rows = []
def run(bead, ts, res): rows.append(json.dumps({"ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "event": "dispatcher_complete", "bead": bead, "rig": "gascity", "result": res, "dry_run": "0"}))
h = lambda x: dt.timedelta(hours=x)
for i in range(40): run(f"b{i}", T - h(30), "PASS" if i < 36 else "FAIL")   # ANTES 90%
for i in range(40): run(f"a{i}", T + h(5), "PASS" if i < 20 else "FAIL")    # DEPOIS 50%; nenhuma janela histórica com n>=20
open(sys.argv[1], "w").write("\n".join(rows) + "\n")
EOF
o="$(PPM_GATE_LOG="$W/gate_nohist.jsonl" python3 "$TOOL" gate-rate --cutover 2026-09-25T00:00:00Z --window-hours 48 --history-windows 2 2>&1)"; rc=$?
{ [ $rc -eq 2 ] && echo "$o" | grep -q 'SEM CONTROLE HISTÓRICO' && ! echo "$o" | grep -q 'sem significância'; } && ok "queda 90% -> 50% (p~0) sem histórico: 'SEM CONTROLE HISTÓRICO', exit 2 (não 'sem significância', exit 0)" || { bad "queda significativa sem histórico mal classificada (rc=$rc)"; echo "$o" | sed 's/^/      /' | tail -5; }

# ── lastro hq-mutants (ga-5mnu1pp): os limites, defaults e saidas que as fixtures acima nunca poem num valor exato ─────────────────────
# Em processo: cada funcao do script recebe a entrada exata (transcrito na idade-limite com o relogio fixo, sessao no segundo do corte, bead no
# instante exato de cada janela, p exatamente 0.10, 40 beads). Os valores esperados saem das regras do docstring e de tabela de Wilson.
# NAO matavel, de proposito: L327 `r["rig"] == rig` -> `!=` (67bdc90f2d: mech_fails so e chamada sem rig, o `rig is None` ja decide);
# L332 `ts < hi_a` -> `<=` (7396ce259a: rig que so tem bead no instante hi_a entra na lista mas bucket() o exclui, e a linha so sai com n>0);
# L189 `len(v) - 1` -> `len(v) - 0` (7c813362ab: ceil(0.9*n) - 1 e sempre menor que n, o min() nunca escolhe o outro lado).
echo "== lastro: bordas, defaults e saidas (em processo)"
cat > "$W/lastro.py" <<'EOF'
import argparse, contextlib, datetime, importlib.util, io, json, os, sys, time
from pathlib import Path
from unittest import mock
sys.dont_write_bytecode = True
tool, W = sys.argv[1], sys.argv[2] + "/lastro"
os.makedirs(W, exist_ok=True)
os.environ["PPM_PROJECTS"], os.environ["PPM_GATE_LOG"] = W + "/projects", W + "/gate-x.jsonl"
spec = importlib.util.spec_from_file_location("ppm2", tool)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fails = []
def chk(name, got, want):
    if callable(got):
        try: got = got()
        except BaseException as e: got = "raised " + repr(e)
    if got != want: fails.append("FAIL " + name + ": got " + repr(got)[:300] + " want " + repr(want)[:300])
def run(fn, *a):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        try: r = fn(*a)
        except SystemExit as e: r = "exit %s" % (e.code,)
        except Exception as e: r = "raised " + repr(e)
    return r, " ".join(buf.getvalue().split()), buf.getvalue()
def wr(name, rows):
    p = W + "/" + name
    open(p, "w").write("".join((r if isinstance(r, str) else json.dumps(r)) + "\n" for r in rows))
    return p
NS = argparse.Namespace

# scan_notes, role_of
m.VANISHED[0] = 2
chk("scan_notes: vanished transcripts are counted", m.scan_notes(), "  (transcritos que sumiram durante a varredura e ficaram de fora: 2)")
m.VANISHED[0] = 0
chk("role_of: an unknown alias keeps 28 characters and what precedes -adhoc-", (m.role_of("x" * 40), m.role_of("foo-adhoc-123")), ("other:" + "x" * 28, "other:foo"))

# one transcript: the FIRST timestamp, the FIRST user message, a usage with one key, a message with no usage
rows = [{"type": "user", "timestamp": "2026-09-20T10:00:00Z", "message": {"content": "[gascity] wa-worker-1 • ts"}},
        {"type": "user", "timestamp": "2026-09-20T11:00:00Z", "message": {"content": "hello"}},
        {"type": "assistant", "timestamp": "2026-09-20T12:00:00Z", "message": {"id": "a1", "usage": {"input_tokens": 10}, "content": []}},
        {"type": "assistant", "timestamp": "2026-09-20T13:00:00Z", "message": {"id": "a2", "content": []}}]
s = m.scan_session(wr("s1.jsonl", rows))
chk("scan_session: start is the FIRST timestamp, the role comes from the FIRST user message, a missing usage key counts 0 and a message with no usage is no turn", (s["start"].isoformat(), s["role"], s["first"], s["turns"]), ("2026-09-20T10:00:00+00:00", "wa-worker", 10, 1))

# sessions(): a transcript exactly at the age limit stays, half a second older goes (the clock is fixed)
os.makedirs(W + "/pj/-p", exist_ok=True)
good = [{"type": "user", "timestamp": "2026-09-20T10:00:00Z", "message": {"content": "[gascity] gastown.dog-1 • ts"}}, {"type": "assistant", "timestamp": "2026-09-20T10:00:01Z", "message": {"id": "m", "usage": {"input_tokens": 5}, "content": []}}]
FIXED = 1000000000.0
for name, age in (("edge", 3600), ("older", 3600.5)):
    p = wr("pj/-p/" + name + ".jsonl", good); os.utime(p, (FIXED - age, FIXED - age))
m.PROJECTS = Path(W + "/pj")
with mock.patch.object(time, "time", return_value=FIXED): got = [os.path.basename(x["path"]) for x in m.sessions(1)]
chk("sessions: a transcript exactly since_hours old stays, half a second older goes", got, ["edge.jsonl"])

# first-turn: the cutover is inclusive for 'after', a session with no start is counted, a role may miss a side, p10/p90, the JSON, the exits
def S(role, start, first): return {"role": role, "start": m.parse_ts(start) if start else None, "first": first, "tools": m.Counter()}
sess = [S("dog", "2026-09-22T00:00:00Z", 300), S("dog", "2026-09-23T00:00:00Z", 400), S("gone", "2026-09-20T00:00:00Z", 500), S("newr", "2026-09-25T00:00:00Z", 700), S("dog", None, 1)]
CLEAN = "(varredura completa: nenhum transcrito sumiu; toda tool_use tinha id)"
with mock.patch.object(m, "sessions", side_effect=lambda since, roles=None: iter(sess)):
    r, t, raw = run(m.cmd_first_turn, NS(roles="", cutover="2026-09-23T00:00:00Z", since_hours=24, json=False))
    chk("first-turn with a cutover: rc 0, a session AT the cutover is after it, one with no start is counted, 33% of +100 over 300", (r, "(sessões sem timestamp legível: 1)" in t, "dog 1 300 1 400 +100 33%" in t), (0, True, True))
    chk("first-turn: a role missing a side shows 0 for it, never a median of nothing", ("gone 1 500 0 0 (falta amostra de um dos lados)" in t, "newr 0 0 1 700 (falta amostra de um dos lados)" in t), (True, True))
    chk("first-turn with a cutover: a scan that lost nothing says so", CLEAN in t, True)
    r, t, raw = run(m.cmd_first_turn, NS(roles="", cutover=None, since_hours=24, json=False))
    chk("first-turn without a cutover: rc 0, and the same sentence when nothing was lost", (r, t.startswith(CLEAN + " papel")), (0, True))
v20 = [S("other:façade", None, 100 * i) for i in range(1, 21)] + [S("small", None, 10 * i) for i in range(1, 6)]
with mock.patch.object(m, "sessions", side_effect=lambda since, roles=None: iter(v20)):
    r, t, raw = run(m.cmd_first_turn, NS(roles="", cutover=None, since_hours=24, json=True))
d = json.loads(raw)["roles"]
chk("first-turn --json: rc 0, 2-space indent, text unescaped", (r, raw.startswith("{\n  \"cutover\""), "other:façade" in raw), (0, True, True))
chk("first-turn --json: median, p10 (a tenth of the list, at least one value) and p90 of 20 values and of 5", (d["other:façade"]["after"], d["small"]["after"]), ({"n": 20, "median": 1050, "p10": 150, "p90": 1800}, {"n": 5, "median": 30, "p10": 10, "p90": 50}))

# denied-attempts: against a small manifest
man = wr("man.json", [json.dumps({"common": {"deny_tools": ["Workflow"]}, "roles": {"d": {"agents": ["gastown.dog"]}, "w": {"agents": ["wa-worker"]}}})])
def D(role, start, tools): return {"role": role, "start": m.parse_ts(start), "tools": m.Counter(tools)}
dsess = [D("dog", "2026-09-26T00:00:00Z", {"Workflow": 2, "Read": 1}), D("wa-worker", "2026-09-25T00:00:00Z", {"Workflow": 5})]
with mock.patch.object(m, "MANIFEST", Path(man)), mock.patch.object(m, "sessions", side_effect=lambda since, roles=None: iter(dsess)):
    r, t, raw = run(m.cmd_denied, NS(since_hours=48, cutover="2026-09-26T00:00:00Z", strict=False))
    chk("denied-attempts: a session AT the cutover is counted (before it is not), the count is printed, a denied tool is reported, and without --strict the exit is 0", (r, "(depois do corte): {'dog': 1}" in t, "dog: tentou tool NEGADA: {'Workflow': 2}" in t), (0, True, True))
    chk("denied-attempts --strict: the same finding exits 1", run(m.cmd_denied, NS(since_hours=48, cutover="2026-09-26T00:00:00Z", strict=True))[0], 1)
    r, t, raw = run(m.cmd_denied, NS(since_hours=48, cutover="2026-10-01T00:00:00Z", strict=False))
    chk("denied-attempts: with no session after the cutover it says nenhuma, and exits 2", (r, "(depois do corte): nenhuma" in t), (2, True))

# the statistics
chk("wilson: (0, 0) when there is nothing, and the 95% Wilson interval of 3 in 10", (m.wilson(0, 0), tuple(round(x, 4) for x in m.wilson(3, 10))), ((0.0, 0.0), (0.1078, 0.6032)))
chk("norm_cdf: 0 is 0.5 and 1.96 is 0.975", (m.norm_cdf(0), round(m.norm_cdf(1.96), 3)), (0.5, 0.975))

# load_gate: a line that is not JSON and a record with a bad ts are both counted
m.GATE_LOG = Path(wr("gate-bad.jsonl", ["not json", {"event": "dispatcher_complete", "dry_run": "0", "result": "PASS", "ts": "nope", "bead": "x"}, {"event": "dispatcher_complete", "dry_run": "0", "result": "PASS", "ts": "2026-01-01T00:00:00Z", "bead": "y"}]))
runs, bad = m.load_gate()
chk("load_gate: one good record, two unreadable lines", (len(runs), bad), (1, 2))

# gate-rate
def G(bead, ts, res, rig="ra", reason=""): return {"ts": ts, "event": "dispatcher_complete", "bead": bead, "rig": rig, "result": res, "reason": reason, "dry_run": "0"}
def blk(prefix, start, n, k, rig="ra"):
    t0 = m.parse_ts(start)
    return [G("%s%d" % (prefix, i), (t0 + datetime.timedelta(hours=i)).strftime("%Y-%m-%dT%H:%M:%SZ"), "PASS" if i < k else "FAIL", rig) for i in range(n)]
def gr(rows, w=48, hw=2, cut="2026-01-10T00:00:00Z"):
    m.GATE_LOG = Path(wr("g.jsonl", rows))
    return run(m.cmd_gate_rate, NS(cutover=cut, window_hours=w, history_windows=hw))
T1 = [G("B1", "2026-01-08T00:00:00Z", "FAIL", "rx", "TIMEOUT x"), G("B2", "2026-01-08T12:00:00Z", "PASS", "rb"), G("B3", "2026-01-09T00:00:00Z", "PASS", "rb"), G("B4", "2026-01-09T12:00:00Z", "FAIL", "rb", "Reviewer 1 FAIL"),
      G("A1", "2026-01-10T00:00:00Z", "FAIL", "ra", "TIMEOUT y"), G("A2", "2026-01-10T12:00:00Z", "PASS", "rb"), G("A3", "2026-01-11T00:00:00Z", "PASS", "rb"), G("A4", "2026-01-12T00:00:00Z", "PASS", "rc")]
r, t, raw = gr(T1)
chk("gate-rate: a bead exactly at the window start is before, one exactly at the cut is after, one exactly at the end is out; the intervals are Wilson in percent", ("ANTES 2/4 = 50.0% IC95% [15.0%, 85.0%]" in t, "DEPOIS 2/3 = 66.7% IC95% [20.8%, 93.9%]" in t), (True, True))
chk("gate-rate: the per-rig lines follow the same edges (a rig whose only bead is AT the window start is listed, one only at the end is not)", ("rig rx antes 0/1 depois 0/0" in t, "rig ra antes 0/0 depois 0/1" in t, "rig rb antes 2/3 depois 2/2" in t, "rig rc" in t), (True, True, True, False))
chk("gate-rate: mechanical FAILs are counted on the same edges (1 of 2 before, 1 of 1 after)", "ANTES 1/2 DEPOIS 1/1" in t, True)
chk("gate-rate: a rising rate is OK (rc 0) and a sample under 40 is called small", (r, "VEREDITO: OK — sem queda. [amostra pequena: <40 beads num lado]" in t), (0, True))
r, t, raw = gr([G("B1", "2026-01-09T00:00:00Z", "FAIL", "ra", "TIMEOUT x")])
chk("gate-rate: one side with no beads is SEM AMOSTRA (exit 2), after the mechanical line that one side is enough to print", (r, "VEREDITO: SEM AMOSTRA de um dos lados" in t, "ANTES 1/1 DEPOIS 0/0" in t), (2, True, True))
chk("gate-rate: the header gives the window after the cut in whole hours (2000, not 1999)", "janela 2000h antes x 2000h depois" in gr([], w=2000, hw=0)[1], True)
B40, A40 = blk("b", "2026-01-08T00:00:00Z", 40, 28), blk("a", "2026-01-10T00:00:00Z", 40, 24)
HIST = blk("p", "2026-01-06T00:00:00Z", 20, 12) + blk("q", "2026-01-04T00:00:00Z", 20, 14)
r, t, raw = gr(B40 + A40 + HIST)
chk("gate-rate: the history is the two 48 h windows before the first one, each from n>=20, and its range", ("histórico (2 janelas de 48h anteriores, n>=20): 60%(n=20) 70%(n=20)" in t, "faixa histórica: 60% a 70%" in t), (True, True))
chk("gate-rate: delta, z and p come from the pooled rate; exactly 40 beads is not a small sample", ("delta = -10.0 pontos (z=-0.94; P(queda por acaso)=0.17)" in t, "[amostra pequena" in t), (True, False))
chk("gate-rate: a drop that lands exactly ON the lowest historical rate is inside the historical range", (r, "VEREDITO: abaixo do ANTES mas dentro da faixa histórica (o gate varia sozinho) (p=0.17)." in t), (0, True))
r, t, raw = gr(B40 + A40)
chk("gate-rate: with no usable history a non-significant drop is just not significant, exit 0", (r, "abaixo do ANTES mas sem significância (p=0.17)." in t), (0, True))
r, t, raw = gr(B40 + blk("a", "2026-01-10T00:00:00Z", 40, 28))
chk("gate-rate: equal rates are OK, exit 0", (r, "VEREDITO: OK — sem queda." in t, "[amostra pequena" in t), (0, True, False))
with mock.patch.object(m, "norm_cdf", return_value=0.10):
    r, t, raw = gr(B40 + blk("a", "2026-01-10T00:00:00Z", 40, 20) + HIST)
    chk("gate-rate: p exactly 0.10 is not below 0.10: below the history it is still no alert", (r, "ALERTA" in t), (0, False))
    r, t, raw = gr(B40 + A40)
    chk("gate-rate: p exactly 0.10 with no history is not 'sem controle histórico' either", (r, "SEM CONTROLE" in t), (0, False))

# main(): the defaults, the usage errors, the help line
seen = {}
with mock.patch.object(m, "cmd_first_turn", side_effect=lambda a: seen.update(ft=a) or 0), mock.patch.object(m, "cmd_denied", side_effect=lambda a: seen.update(dn=a) or 0), mock.patch.object(m, "cmd_gate_rate", side_effect=lambda a: seen.update(gr=a) or 0):
    m.main(["first-turn"]); m.main(["denied-attempts"]); m.main(["gate-rate", "--cutover", "2026-01-10T00:00:00Z"])
chk("main: the defaults are 24 h, 48 h, a 48 h window and 6 history windows", (seen["ft"].since_hours, seen["dn"].since_hours, seen["gr"].window_hours, seen["gr"].history_windows), (24, 48, 48, 6))
chk("main: no command, and gate-rate with no --cutover, are usage errors (exit 2)", (run(m.main, [])[0], run(m.main, ["gate-rate"])[0]), ("exit 2", "exit 2"))
chk("main --help: the description is the first line of the docstring", "MEDE" in run(m.main, ["--help"])[1], True)

print("\n".join(fails))
print("DONE", len(fails))
EOF
LOUT="$(python3 "$W/lastro.py" "$TOOL" "$W" 2>&1)"
case "$LOUT" in *"DONE 0") ok "lastro: bordas das janelas, tabela de Wilson, defaults e saidas do script, todos nos valores exatos" ;; *) bad "lastro: $LOUT" ;; esac

echo; echo "== resultado: $PASS ok, $FAIL falha(s)"; [ "$FAIL" -eq 0 ]
