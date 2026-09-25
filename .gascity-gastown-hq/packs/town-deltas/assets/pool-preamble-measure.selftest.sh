#!/usr/bin/env bash
# pool-preamble-measure.selftest.sh — ga-aijm2v.6: a ferramenta que MEDE o corte tem que estar certa, senão o critério de aceite
# ("caiu >= 40k tokens, medido") vira número sem lastro. Fixtures sintéticas, hermético (PPM_PROJECTS / PPM_GATE_LOG).
# Cada caso existe por um erro real que a 1ª versão da ferramenta teve ou poderia ter:
#   * mensagem <synthetic> de uso 0 contada como "1º turno = 0" (corrompia a cauda baixa — achado medindo o baseline)
#   * sessão de subagente (isSidechain) contada como sessão de pool
#   * "1ª tentativa" contando re-execução de bead cuja 1ª execução foi ANTES da janela
#   * linhas ilegíveis do log do gate derrubando a leitura (havia 20 de 14.6k) / dry_run contado como rodada real
#   * veredito de queda sem controle histórico (o gate varia sozinho: um corte arbitrário mostrou -25 pontos, p~0)
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
# controle positivo do denied-attempts: um dog DEPOIS do corte que chama Workflow (negada a todo papel de pool)
sess("g", "gastown.dog-5", "2026-09-26T13:00:00Z", 600, extra=[{"type": "assistant", "timestamp": "2026-09-26T13:00:01Z", "message": {"id": "m9", "usage": {"input_tokens": 1, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 10}, "content": [{"type": "tool_use", "name": "Workflow"}]}}])
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
echo; echo "== resultado: $PASS ok, $FAIL falha(s)"; [ "$FAIL" -eq 0 ]
