#!/usr/bin/env bash
# overlay-root-leak-guard.selftest.sh — ga-swnkfm: prove the guard catches an overlay por papel vazando pro settings
# compartilhado da cidade, e que NAO da falso alarme nem falso verde.
#
# A prova que o bead exige: "a prova tem que ler os DOIS arquivos depois de um spawn real ou simulado". Aqui o spawn e
# SIMULADO por um modelo fiel do engine (fonte lida em internal/overlay/merge.go MergeSettingsJSON e internal/hooks/hooks.go
# installClaude/desiredClaudeSettings, engine gc-1.1.1):
#   • spawn: overlay_dir faz JSON-merge em <workdir>/.claude/settings.json (chave de topo nao-hook: o overlay vence;
#     hooks: uniao por identidade; NUNCA remove chave);
#   • installClaude: <cidade>/.gc/settings.json = merge(defaults embutidos, <cidade>/.claude/settings.json).
# O modelo e VALIDADO contra o incidente real: o overlay pool-reviewer tem 94 skillOverrides — o numero que o Mayor mediu
# no arquivo vazado (ver A/B).
#
# Metades (nenhuma sozinha prova):
#   U. UNIDADE     — folhas/delta calculados dos overlays REAIS do repo.
#   A. CONTROLE +  — revisor na raiz com o overlay base `pool`: limpo (rc 0), e uma edicao legitima da raiz nao da falso alarme.
#   B. REPLAY      — o incidente: revisor na raiz com pool-reviewer => os DOIS arquivos contaminados => rc 1 nos dois.
#   C. RESIDUO     — reverter o overlay NAO limpa (merge so adiciona) => segue vermelho; limpar => verde.
#   D. CLASSE      — TODO overlay por papel (dog, workers, revisor, longlived) na raiz => vermelho; work_dir proprio => verde.
#   E. TOPOLOGIA   — a causa, ANTES de qualquer spawn: agente na raiz com overlay de papel; work_dir compartilhado.
#   F. ERRO != VAZIO — ilegivel/ausente/config que nao carrega => rc 2, nunca 0.
#   G. DENTES      — o proprio teste reprova um guard que sempre diz "limpo" e um que sempre diz "vazou".
#   H. ALARME      — cooldown por fingerprint, entrega falha NAO grava, recorrencia depois de limpo alarma na hora.
#   I. LOCK        — instancia unica (ga-y0g5x).
#   L. CIDADE VIVA — o guard le a cidade real (somente leitura) e devolve 0 ou 1, nunca 2.
#
# HERMETICO: tudo em diretorio temporario; a cidade viva so e LIDA (L), com --no-alarm --no-lock. Sem go build, sem sessao.
# Env: OVLG_GUARD (guard a testar; default o irmao), OVLG_OVERLAYS (dir de overlays), OVLG_KEEP=1 (mantem o tmp).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_GUARD="$SELF_DIR/overlay-root-leak-guard.py"
GUARD="${OVLG_GUARD:-$REAL_GUARD}"
OVERLAYS="${OVLG_OVERLAYS:-$(cd "$SELF_DIR/.." && pwd)/claude-overlays}"

PASS=0; FAIL=0

[ -f "$GUARD" ] || { echo "FATAL: guard nao encontrado em $GUARD"; exit 1; }
[ -d "$OVERLAYS" ] || { echo "FATAL: overlays nao encontrados em $OVERLAYS"; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 ausente"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/ovlg-selftest.XXXXXX")"
cleanup() { [ "${OVLG_KEEP:-0}" = 1 ] && { echo "(mantido: $W)"; return; }; rm -rf "$W"; }
trap cleanup EXIT

# O script Python escreve num arquivo (nao numa process substitution): assim o rc dele NAO se perde. Um crash no meio do cenario
# deixaria so as linhas OK anteriores — e um teste que morre calado e um falso verde. Exigimos rc 0 E a sentinela final DONE.
python3 - "$GUARD" "$REAL_GUARD" "$OVERLAYS" "$W" > "$W/py.out" 2>&1 <<'PY'
import fcntl, importlib.util, json, os, subprocess, sys, textwrap
from pathlib import Path

GUARD, REAL_GUARD, OVERLAYS, W = sys.argv[1], sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])

def ok(m): print("OK:", m, flush=True)
def bad(m): print("BAD:", m, flush=True)
def check(cond, m, detail=""):
    ok(m) if cond else bad(m + (f"  [{detail}]" if detail else ""))
def section(t): print(f"== {t}", flush=True)

spec = importlib.util.spec_from_file_location("ovlg", REAL_GUARD)
ovlg = importlib.util.module_from_spec(spec); spec.loader.exec_module(ovlg)

# ------------------------------------------------------------------ modelo do engine (fonte: merge.go / hooks.go)
DEFAULTS = {  # o que o engine embute em config/claude.json (fixture: formato real, conteudo minimo)
    "awaySummaryEnabled": False, "editorMode": "normal", "skipDangerousModePermissionPrompt": True,
    "hooks": {
        "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "gc prime --hook"}]}],
        "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "gc nudge drain --inject"}]}],
    },
}
def _canon(v): return json.dumps(v, sort_keys=True, separators=(",", ":"))
def hook_key(e):  # hookEntryKey
    for k, pre in (("matcher", ""), ("command", "cmd:"), ("bash", "bash:")):
        if k in e: return (pre + e[k]) if isinstance(e[k], str) else None
    if isinstance(e.get("hooks"), list): return "inner:" + _canon(e["hooks"])
    return None
def merge_hook_array(base, over):  # mergeHookArray
    res = list(base); idx = {}
    for i, e in enumerate(res):
        if isinstance(e, dict) and hook_key(e) is not None: idx[hook_key(e)] = i
    for e in over:
        k = hook_key(e) if isinstance(e, dict) else None
        if k is None: res.append(e)
        elif k in idx: res[idx[k]] = e
        else: res.append(e); idx[k] = len(res) - 1
    return res
def merge(base, over):  # MergeSettingsJSON: topo nao-hook = overlay vence; hooks = uniao; NUNCA remove
    res = dict(base)
    for k, v in over.items():
        if k == "hooks":
            h = dict(base.get("hooks") or {})
            for cat, arr in (v or {}).items():
                h[cat] = merge_hook_array(h[cat], arr) if isinstance(arr, list) and isinstance(h.get(cat), list) else arr
            res["hooks"] = h
        else:
            res[k] = v
    return res
def jread(p): return json.loads(Path(p).read_text())
def jwrite(p, o): Path(p).parent.mkdir(parents=True, exist_ok=True); Path(p).write_text(json.dumps(o, indent=2) + "\n")
def install_claude(city):  # installClaude: .gc/settings.json = merge(defaults, <cidade>/.claude/settings.json)
    src = city / ".claude/settings.json"
    jwrite(city / ".gc/settings.json", merge(DEFAULTS, jread(src) if src.exists() else {}))
def spawn(city, workdir, overlay):
    """Spawn simulado: overlay_dir -> merge em <workdir>/.claude/settings.json; se o workdir E a raiz, o engine
    re-deriva o .gc/settings.json (start/reload/inicio de sessao)."""
    dst = Path(workdir) / ".claude/settings.json"
    jwrite(dst, merge(jread(dst) if dst.exists() else {}, jread(OVERLAYS / overlay / ".claude/settings.json")))
    if Path(workdir).resolve() == city.resolve(): install_claude(city)
_n = [0]
def new_city():
    _n[0] += 1; c = W / f"city{_n[0]}"; (c / ".gc/runtime").mkdir(parents=True)
    jwrite(c / ".claude/settings.json", jread(OVERLAYS / "pool/.claude/settings.json"))  # raiz = overlay base (estado limpo)
    install_claude(c); return c

# ------------------------------------------------------------------ configs (o que `gc config show` devolveria)
OV = "packs/town-deltas/assets/claude-overlays/"
def A(name, overlay=None, work_dir=None, **kw):
    a = {"name": name, "scope": "city"}
    if overlay: a["overlay_dir"] = OV + overlay
    if work_dir: a["work_dir"] = work_dir
    a.update(kw); return a
def toml_of(agents):
    out = []
    for a in agents:
        out.append("[[agent]]"); out += [f"{k} = {json.dumps(v)}" for k, v in a.items()]
    return "\n".join(out) + "\n"
def cfg_file(name, agents): p = W / f"{name}.toml"; p.write_text(toml_of(agents)); return p
CLEAN_AGENTS = [A("gate-reviewer", "pool"), A("auto-refiner", "pool"),
                A("dog", "pool-dog", ".gc/agents/dogs/{{.AgentBase}}"), A("mayor", "longlived", ".gc/agents/mayor"),
                A("wa-worker", "pool-wa-worker", "/abs/whatsapp_automation/crew/worker")]
CFG_CLEAN = cfg_file("clean", CLEAN_AGENTS)

def run(city, cfg=None, guard=None, args=(), env=None, alarm=False, lock=False, overlays=None):
    cmd = [guard or GUARD, "--city", str(city), "--overlays-dir", str(overlays or OVERLAYS), "--json"]
    if cfg is not None: cmd += ["--config-toml", str(cfg)]
    if not alarm: cmd.append("--no-alarm")
    if not lock: cmd.append("--no-lock")
    cmd += list(args)
    e = dict(os.environ); e.update(env or {})
    r = subprocess.run(cmd, capture_output=True, text=True, env=e, timeout=120)
    try: j = json.loads(r.stdout)
    except ValueError: j = None
    return r.returncode, j, r
def files_hit(j): return sorted({f["file"] for f in (j or {}).get("findings", []) if f.get("kind") == "artifact-contaminated"})
def kinds(j): return sorted({f["kind"] for f in (j or {}).get("findings", [])})

# ================================================================== U. unidade
section("U. unidade: folhas e delta dos overlays REAIS")
check(ovlg.leaves({"a": {"b": [1, 2]}, "c": True}) == {(("a", "b", "[]"), "1"), (("a", "b", "[]"), "2"), (("c",), "true")}, "leaves(): dict recursa, lista vira uma folha por elemento, escalar e folha")
check((("s",), "{}") in ovlg.leaves({"s": {}}), "leaves(): container vazio conta (senao 'skillOverrides: {}' ficaria invisivel)")
ovs, errs = ovlg.load_overlays(OVERLAYS)
check(not errs and {"pool", "pool-reviewer", "pool-dog", "longlived"} <= set(ovs), "overlays reais carregam (pool, pool-reviewer, pool-dog, longlived)", str(errs))
base, _bw = ovlg.base_overlay_name(OVERLAYS, None)
check(base == "pool", "overlay base vem do manifesto (pool-roles.json base_overlay)", base)
D = ovlg.role_deltas(ovs, base)
rev = {ovlg.fmt_leaf(l) for l in D.get("pool-reviewer", set())}
check('skillOverrides.gate-done="off"' in rev and 'autoMemoryEnabled=false' in rev and any(x.startswith("claudeMdExcludes.[]=") for x in rev) and 'permissions.deny.[]="Agent"' in rev,
      "delta do pool-reviewer contem as 4 chaves do incidente (gate-done off, memoria off, claudeMdExcludes, deny Agent)")
check('permissions.deny.[]="Bash(sudo:*)"' not in rev and 'remoteControlAtStartup=false' not in rev, "delta NAO inclui o que ja e do base (sudo/rm -rf deny, RC off)")
check("pool" not in D and {ovlg.fmt_leaf(l) for l in D.get("longlived", set())} == {"autoCompactWindow=900000"}, "base nao tem delta; longlived = so autoCompactWindow")
rev_json = jread(OVERLAYS / "pool-reviewer/.claude/settings.json")
check(len(rev_json["skillOverrides"]) == 94, "modelo bate com o incidente: pool-reviewer tem 94 skillOverrides (o numero que o Mayor mediu no arquivo vazado)", str(len(rev_json["skillOverrides"])))

# ================================================================== A. controle positivo
section("A. controle positivo: revisor na raiz com o overlay base")
c = new_city(); spawn(c, c, "pool"); spawn(c, c, "pool")
check(jread(c / ".claude/settings.json") == jread(OVERLAYS / "pool/.claude/settings.json"), "modelo: spawn repetido do overlay base e idempotente (raiz == base)")
rc, j, r = run(c, CFG_CLEAN)
check(rc == 0 and j and not j["findings"] and not j["unknowns"], "guard: raiz + .gc limpos => rc 0, zero achados, zero desconhecidos", f"rc={rc} {r.stdout[:300]}")
check(j and j["artifacts"] == {".claude/settings.json": "ok", ".gc/settings.json": "ok"}, "guard LEU os dois arquivos", str(j and j["artifacts"]))
root = jread(c / ".claude/settings.json"); root["cleanupPeriodDays"] = 30; root["permissions"]["deny"].append("Bash(shutdown:*)"); jwrite(c / ".claude/settings.json", root); install_claude(c)
rc, j, r = run(c, CFG_CLEAN)
check(rc == 0, "sem falso alarme: edicao LEGITIMA da raiz (chave nova + deny extra) nao vira vazamento", f"rc={rc} {r.stdout[:300]}")

# ================================================================== B. replay do incidente
section("B. replay do incidente: revisor na raiz com pool-reviewer")
c = new_city(); spawn(c, c, "pool-reviewer")
for rel in (".claude/settings.json", ".gc/settings.json"):
    d = jread(c / rel)
    check(d.get("skillOverrides", {}).get("gate-done") == "off" and d.get("autoMemoryEnabled") is False and len(d.get("skillOverrides", {})) == 94 and "Agent" in d["permissions"]["deny"],
          f"modelo reproduz o incidente em {rel}: gate-done off, memoria off, 94 skillOverrides, deny Agent")
rc, j, r = run(c, CFG_CLEAN)
check(rc == 1, "guard: rc 1 (vazamento)", f"rc={rc} {r.stdout[:300]}")
check(files_hit(j) == [".claude/settings.json", ".gc/settings.json"], "guard reporta OS DOIS arquivos contaminados", str(files_hit(j)))
art = [f for f in (j or {"findings": []})["findings"] if f["kind"] == "artifact-contaminated"]
check(art and all(f["sources"] == ["pool-reviewer"] and f["coverage"]["pool-reviewer"] == 1.0 for f in art),
      "guard nomeia a fonte por COBERTURA do delta: so pool-reviewer (100%), nao os overlays que apenas compartilham folhas com ele", str([(f["sources"], f["coverage"]) for f in art]))
one = c.parent / "only_gc"; (one / ".gc/runtime").mkdir(parents=True); jwrite(one / ".claude/settings.json", jread(OVERLAYS / "pool/.claude/settings.json")); install_claude(one)
g = jread(one / ".gc/settings.json"); g["autoMemoryEnabled"] = False; jwrite(one / ".gc/settings.json", g)
rc, j, r = run(one, CFG_CLEAN); check(rc == 1 and files_hit(j) == [".gc/settings.json"], "vazamento SO no .gc/settings.json (raiz limpa) => rc 1, aponta so o .gc", f"rc={rc} {files_hit(j)}")
two = c.parent / "only_root"; (two / ".gc/runtime").mkdir(parents=True); jwrite(two / ".claude/settings.json", jread(OVERLAYS / "pool/.claude/settings.json")); install_claude(two)
g = jread(two / ".claude/settings.json"); g["skillOverrides"] = {"gate-done": "off"}; jwrite(two / ".claude/settings.json", g)
rc, j, r = run(two, CFG_CLEAN); check(rc == 1 and files_hit(j) == [".claude/settings.json"], "vazamento SO na raiz (.gc limpo) => rc 1, aponta so a raiz", f"rc={rc} {files_hit(j)}")
three = c.parent / "foreign_key"; (three / ".gc/runtime").mkdir(parents=True); jwrite(three / ".claude/settings.json", jread(OVERLAYS / "pool/.claude/settings.json")); install_claude(three)
g = jread(three / ".claude/settings.json"); g["claudeMdExcludes"] = ["/x/CLAUDE.md"]; g["skillOverrides"] = {"gate-done": "on"}; jwrite(three / ".claude/settings.json", g); install_claude(three)
rc, j, r = run(three, CFG_CLEAN); check(rc == 0, "chave de papel com valor DIFERENTE do overlay (skillOverrides.gate-done=on, exclude proprio) nao e vazamento: so folha (caminho+valor) igual a do overlay conta", f"rc={rc} {files_hit(j)}")

# ================================================================== C. residuo
section("C. residuo: reverter o overlay nao limpa; limpar limpa")
spawn(c, c, "pool")  # o revert que o Mayor fez (overlay_dir de volta pro pool) + um novo spawn
check(jread(c / ".claude/settings.json").get("skillOverrides", {}).get("gate-done") == "off", "modelo: spawn com o overlay base NAO removeu as chaves do revisor (merge so adiciona)")
rc, j, r = run(c, CFG_CLEAN)
check(rc == 1 and files_hit(j) == [".claude/settings.json", ".gc/settings.json"], "guard: RESIDUO pos-revert continua vermelho nos dois arquivos", f"rc={rc} {files_hit(j)}")
jwrite(c / ".claude/settings.json", jread(OVERLAYS / "pool/.claude/settings.json")); install_claude(c)
rc, j, r = run(c, CFG_CLEAN)
check(rc == 0, "guard: depois de limpar (raiz == base, .gc re-derivado) volta a rc 0", f"rc={rc} {r.stdout[:300]}")

# ================================================================== D. classe
section("D. classe: TODO overlay por papel na raiz vaza; work_dir proprio nao")
for name in ("pool-dog", "pool-wa-worker", "pool-ps-worker", "pool-reviewer", "longlived"):
    c = new_city(); spawn(c, c, name)
    rc, j, r = run(c, CFG_CLEAN)
    srcs = sorted({s for f in (j or {"findings": []})["findings"] for s in f.get("sources", [])})
    check(rc == 1 and name in srcs and files_hit(j) == [".claude/settings.json", ".gc/settings.json"], f"overlay '{name}' na raiz => rc 1, fonte '{name}', os dois arquivos", f"rc={rc} srcs={srcs} {files_hit(j)}")
c = new_city(); before = (jread(c / ".claude/settings.json"), jread(c / ".gc/settings.json"))
own = c / ".gc/agents/gate-reviewer"; own.mkdir(parents=True); spawn(c, own, "pool-reviewer")
check(jread(own / ".claude/settings.json").get("skillOverrides", {}).get("gate-done") == "off", "modelo: o overlay do revisor foi aplicado no work_dir PROPRIO")
check((jread(c / ".claude/settings.json"), jread(c / ".gc/settings.json")) == before, "modelo: a raiz e o .gc/settings.json ficaram INTACTOS")
own_cfg = cfg_file("own", [A("gate-reviewer", "pool-reviewer", ".gc/agents/gate-reviewer")] + CLEAN_AGENTS[1:])
rc, j, r = run(c, own_cfg); check(rc == 0, "guard: revisor com pool-reviewer em work_dir PROPRIO (artefatos + topologia) => rc 0", f"rc={rc} {r.stdout[:300]}")

# ================================================================== E. topologia
section("E. topologia: a causa, antes de qualquer spawn")
c = new_city()  # artefatos LIMPOS: so a config esta errada
bad_cfg = cfg_file("rootrev", [A("gate-reviewer", "pool-reviewer")] + CLEAN_AGENTS[1:])
rc, j, r = run(c, bad_cfg)
check(rc == 1 and kinds(j) == ["root-resident-role-overlay"], "revisor SEM work_dir + pool-reviewer => achado 'root-resident' com artefatos ainda limpos (pega ANTES do spawn)", f"rc={rc} {kinds(j)}")
check(j and j["findings"][0]["agent"] == "gate-reviewer" and j["findings"][0]["overlay"] == "pool-reviewer", "achado nomeia agente e overlay")
rc, j, r = run(c, cfg_file("dot", [A("gate-reviewer", "pool-reviewer", ".")] + CLEAN_AGENTS[1:])); check(rc == 1 and kinds(j) == ["root-resident-role-overlay"], "work_dir '.' (relativo = a raiz) tambem e raiz", f"{rc} {kinds(j)}")
rc, j, r = run(c, cfg_file("abs", [A("gate-reviewer", "pool-reviewer", str(c))] + CLEAN_AGENTS[1:])); check(rc == 1 and kinds(j) == ["root-resident-role-overlay"], "work_dir absoluto == raiz tambem e raiz", f"{rc} {kinds(j)}")
rc, j, r = run(c, cfg_file("susp", [A("gate-reviewer", "pool-reviewer", suspended=True)] + CLEAN_AGENTS[1:])); check(rc == 1 and j and j["findings"][0]["suspended"] is True, "agente SUSPENSO na raiz tambem conta (landmine no un-suspend), marcado como suspenso", f"{rc}")
rc, j, r = run(c, cfg_file("okdog", CLEAN_AGENTS)); check(rc == 0, "dog/mayor/wa-worker com overlay de papel em work_dir PROPRIO (template, relativo, absoluto) => rc 0", f"{rc} {kinds(j)}")
shared = cfg_file("shared", [A("a", "pool-dog", ".gc/agents/shared"), A("b", "pool-reviewer", ".gc/agents/shared")] + CLEAN_AGENTS)
rc, j, r = run(c, shared); check(rc == 1 and kinds(j) == ["shared-workdir-divergent-overlays"], "dois agentes com overlays DIVERGENTES no mesmo work_dir => achado", f"{rc} {kinds(j)}")
same = cfg_file("same", [A("a", "pool-dog", ".gc/agents/shared"), A("b", "pool-dog", ".gc/agents/shared")] + CLEAN_AGENTS)
rc, j, r = run(c, same); check(rc == 0, "dois agentes com o MESMO overlay no mesmo work_dir => limpo (o pool de workers faz isso)", f"{rc} {kinds(j)}")
tmpl = cfg_file("tmpl", [A("a", "pool-dog", ".gc/agents/dogs/{{.AgentBase}}"), A("b", "pool-reviewer", ".gc/agents/dogs/{{.AgentBase}}")] + CLEAN_AGENTS)
rc, j, r = run(c, tmpl); check(rc == 0, "work_dir com template ({{.AgentBase}}) e um dir por instancia => nao e 'compartilhado'", f"{rc} {kinds(j)}")
rc, j, r = run(c, cfg_file("nover", [A("x", None)] + CLEAN_AGENTS)); check(rc == 0, "agente SEM overlay_dir nao e fonte de vazamento", f"{rc}")
rc, j, r = run(c, cfg_file("missing", [A("x", "pool-nao-existe", ".gc/agents/x")] + CLEAN_AGENTS))
check(rc == 0 and j and any("nao existe" in w for w in j["warnings"]), "overlay_dir que nao existe em disco => AVISO (no-op silencioso no engine), nao vermelho", f"{rc} {j and j['warnings']}")

# ================================================================== F. erro != vazio
section("F. erro != vazio: nao consegui saber => rc 2, nunca 0")
c = new_city(); (c / ".gc/settings.json").write_text("{ nao e json")
rc, j, r = run(c, CFG_CLEAN); check(rc == 2 and any(u["kind"] == "artifact-unreadable" for u in j["unknowns"]), ".gc/settings.json com JSON invalido => rc 2", f"{rc}")
c = new_city(); (c / ".claude/settings.json").write_text("[1,2]")
rc, j, r = run(c, CFG_CLEAN); check(rc == 2, "raiz com JSON que nao e objeto => rc 2", f"{rc}")
c = new_city(); (W / "empty_ov").mkdir(exist_ok=True)
rc, j, r = run(c, CFG_CLEAN, overlays=W / "empty_ov"); check(rc == 2, "diretorio de overlays vazio => rc 2 (sem overlay nao ha delta: 'nada a procurar' != 'limpo')", f"{rc}")
rc, j, r = run(c, CFG_CLEAN, overlays=W / "nao_existe"); check(rc == 2, "diretorio de overlays inexistente => rc 2", f"{rc}")
rc, j, r = run(c, CFG_CLEAN, args=["--base-overlay", "nao-existe"]); check(rc == 2 and any(u["kind"] == "base-overlay-missing" for u in j["unknowns"]), "overlay base inexistente => rc 2", f"{rc}")
rc, j, r = run(c, W / "nao_existe.toml"); check(rc == 2 and any(u["kind"] == "config-unavailable" for u in j["unknowns"]), "config que nao carrega (--config-toml ausente) => rc 2 (artefatos limpos NAO bastam)", f"{rc}")
(W / "vazia.toml").write_text("")
rc, j, r = run(c, W / "vazia.toml"); check(rc == 2, "config sem nenhum agente => rc 2 (config vazia != cidade sem overlays)", f"{rc}")
rc, j, r = run(c, None, env={"GC_BIN": "false"}); check(rc == 2 and any(u["kind"] == "config-unavailable" for u in j["unknowns"]), "`gc config show` que falha => rc 2", f"{rc}")
e = W / "cidade_vazia"; (e / ".gc/runtime").mkdir(parents=True)
rc, j, r = run(e, CFG_CLEAN); check(rc == 2 and any(u["kind"] == "artifacts-absent" for u in j["unknowns"]), "nenhum dos dois arquivos existe (cidade errada?) => rc 2", f"{rc}")
c = new_city(); spawn(c, c, "pool-reviewer")
rc, j, r = run(c, W / "nao_existe.toml"); check(rc == 1, "vazamento CONFIRMADO + config indisponivel => rc 1 (achado real vence o desconhecido)", f"{rc}")
# crash != vazamento: um traceback do Python sai com rc 1 — o MESMO codigo de "vazou". entry() tem que converter em 2.
def _boom(*a, **k): raise RuntimeError("falha injetada")
old_py = "/usr/bin/python3"   # macOS: 3.9, sem tomllib. O order roda `env python3`; se um dia o PATH do controller resolver esse, o import falha ANTES de main().
if os.path.exists(old_py) and subprocess.run([old_py, "-c", "import sys; sys.exit(0 if sys.version_info < (3, 11) else 1)"]).returncode == 0:
    r = subprocess.run([old_py, REAL_GUARD, "--city", str(new_city()), "--no-alarm", "--no-lock"], capture_output=True, text=True, timeout=60)
    check(r.returncode == 2 and "tomllib" in r.stderr, "python < 3.11 (sem tomllib, o /usr/bin/python3 do macOS) => rc 2 com mensagem, nao um traceback rc 1 que passaria por 'vazamento'", f"rc={r.returncode} {r.stderr[-160:]}")
else:
    print("  ~ SKIP: nao ha python < 3.11 neste host para provar o caminho sem tomllib")
_orig = ovlg.run_check; ovlg.run_check = _boom
import contextlib, io
_e = io.StringIO()
with contextlib.redirect_stderr(_e), contextlib.redirect_stdout(io.StringIO()):
    rc = ovlg.entry(["--city", str(new_city()), "--no-lock", "--no-alarm"])
ovlg.run_check = _orig
check(rc == 2 and "ERRO INTERNO" in _e.getvalue(), "excecao inesperada dentro do guard => rc 2 (nao 1: crash nao pode se passar por vazamento)", f"rc={rc}")
import shutil
bm = W / "ov_badman"; shutil.copytree(OVERLAYS, bm); (bm / "pool-roles.json").write_text("{corrompido")
rc, j, r = run(new_city(), CFG_CLEAN, overlays=bm)
check(rc == 0 and j and any("manifesto ilegivel" in w for w in j["warnings"]), "manifesto (pool-roles.json) ILEGIVEL => segue com o base default mas o AVISO aparece (nao e fallback mudo)", f"rc={rc} {j and j['warnings']}")
nm = W / "ov_noman"; shutil.copytree(OVERLAYS, nm); (nm / "pool-roles.json").unlink()
rc, j, r = run(new_city(), CFG_CLEAN, overlays=nm)
check(rc == 0 and j and not any("manifesto" in w for w in j["warnings"]), "manifesto AUSENTE (cidade sem manifesto) => usa o default `pool` sem aviso (ausente != ilegivel)", f"rc={rc} {j and j['warnings']}")
c = new_city(); (c / "custom_ov/.claude").mkdir(parents=True); (c / "custom_ov/.claude/settings.json").write_text("{x")
rc, j, r = run(c, cfg_file("unreadable_ov", [{"name": "x", "scope": "city", "overlay_dir": "custom_ov"}] + CLEAN_AGENTS))
check(rc == 2 and j and any(u["kind"] == "overlay-unreadable" for u in j["unknowns"]), "overlay de agente ILEGIVEL (fora do dir de overlays) => rc 2 — nao da pra saber o que ele grava na raiz", f"rc={rc} {j and j['unknowns']}")
rc, j, r = run(new_city(), CFG_CLEAN)
check(j and j["root_resident"] == ["auto-refiner(pool)", "gate-reviewer(pool)"], "'limpo' mostra o que EXAMINOU: os agentes sem work_dir com overlay (auto-refiner, gate-reviewer)", str(j and j["root_resident"]))
rc, j, r = run(new_city(), W / "nao_existe.toml")
check(j and j["root_resident"] is None, "config indisponivel => root_resident null ('nao examinei'), nunca lista vazia", str(j and j["root_resident"]))
c = new_city(); (c / ".gc/runtime/overlay-root-leak-guard.lock").mkdir()
r = subprocess.run([GUARD, "--city", str(c), "--overlays-dir", str(OVERLAYS), "--config-toml", str(CFG_CLEAN), "--no-alarm"], capture_output=True, text=True, timeout=60)
check(r.returncode == 2 and "NAO rodei" in r.stderr, "lock que nao abre => rc 2 'NAO rodei' (sair 0 seria um guard cego que parece saudavel)", f"rc={r.returncode} {r.stderr[-160:]}")

# ================================================================== G. dentes
section("G. dentes: o teste reprova guard que sempre diz 'limpo' e guard que sempre diz 'vazou'")
def stub(name, rc, findings):
    p = W / name
    p.write_text("#!/bin/sh\necho '" + json.dumps({"rc": rc, "findings": findings, "unknowns": [], "warnings": [], "artifacts": {}}) + "'\nexit " + str(rc) + "\n"); p.chmod(0o755); return str(p)
def judge(guard):
    """(detecta_incidente, limpo_no_controle) segundo o MESMO critério dos blocos A e B."""
    ca = new_city(); spawn(ca, ca, "pool"); rca, ja, _ = run(ca, CFG_CLEAN, guard=guard)
    cb = new_city(); spawn(cb, cb, "pool-reviewer"); rcb, jb, _ = run(cb, CFG_CLEAN, guard=guard)
    return (rcb == 1 and files_hit(jb) == [".claude/settings.json", ".gc/settings.json"]), (rca == 0 and ja is not None and not ja.get("findings"))
det, clean = judge(GUARD); check(det and clean, "guard real: detecta o incidente E fica limpo no controle")
det, clean = judge(stub("sempre_limpo.sh", 0, [])); check(not det and clean, "controle negativo: guard 'sempre rc 0' NAO detecta o incidente (o teste o reprovaria)")
det, clean = judge(stub("sempre_vazou.sh", 1, [{"kind": "artifact-contaminated", "file": ".claude/settings.json", "sources": ["x"]}, {"kind": "artifact-contaminated", "file": ".gc/settings.json", "sources": ["x"]}]))
check(clean is False, "controle negativo: guard 'sempre vazou' reprova no controle limpo (o teste o reprovaria)")
mod_src = Path(REAL_GUARD).read_text()
for label, old, new in (("delta calculado contra o proprio overlay (nunca acha nada)", "return {n: (lv - b) for n, lv in overlays.items() if n != base and (lv - b)}", "return {n: (lv - lv) for n, lv in overlays.items() if n != base and (lv - lv)}"),
                        ("le so a raiz e ignora o .gc/settings.json", 'ARTIFACT_RELS = (".claude/settings.json", ".gc/settings.json")', 'ARTIFACT_RELS = (".claude/settings.json",)')):
    assert old in mod_src, f"mutacao '{label}' nao casa mais com o guard — atualize o teste"
    mp = W / "mutant.py"; mp.write_text(mod_src.replace(old, new)); mp.chmod(0o755)
    det, clean = judge(str(mp)); check(not det, f"mutante '{label}' e REPROVADO (nao detecta o incidente inteiro)")

# ================================================================== H. alarme
section("H. alarme: cooldown por fingerprint, entrega falha nao grava, recorrencia alarma na hora")
router = W / "router.sh"; calls = W / "router.calls"; rcfile = W / "router.rc"; rcfile.write_text("0")
router.write_text(f'#!/bin/sh\necho "CALL $2" >> "{calls}"\nexit $(cat "{rcfile}")\n'); router.chmod(0o755)
def ncalls(): return len(calls.read_text().splitlines()) if calls.exists() else 0
def alarmed(city, state, extra_env=None):
    env = {"OVLG_ROUTER": str(router), "OVLG_STATE_DIR": str(state), "OVLG_ESCALATE_AFTER_S": "3600"}; env.update(extra_env or {})
    return run(city, CFG_CLEAN, env=env, alarm=True)
c = new_city(); spawn(c, c, "pool-reviewer"); st = W / "state1"
n0 = ncalls(); rc, j, r = alarmed(c, st)
check(rc == 1 and ncalls() - n0 == 2, "vazamento nos 2 arquivos => 1 alarme por arquivo (2 chamadas ao router)", f"rc={rc} calls={ncalls()-n0}")
check("overlay-vazou" in calls.read_text() and "pool-reviewer" in calls.read_text(), "assunto do alarme cita o problema e a fonte (overlay-vazou / pool-reviewer)")
n0 = ncalls(); alarmed(c, st); check(ncalls() == n0, "2a rodada dentro do cooldown => ZERO alarmes novos (sem spam)")
rc, j, r = run(c, CFG_CLEAN, env={"OVLG_ROUTER": str(router), "OVLG_STATE_DIR": str(W / "state_na")}, alarm=False); n1 = ncalls()
check(n1 == n0, "--no-alarm => nunca chama o router")
st2 = W / "state2"; rcfile.write_text("1"); n0 = ncalls(); alarmed(c, st2); n1 = ncalls()
check(n1 - n0 == 2, "router falhando: tenta entregar", f"{n1-n0}")
rcfile.write_text("0"); alarmed(c, st2); check(ncalls() - n1 == 2, "entrega que FALHOU nao foi gravada como vista => a rodada seguinte re-tenta (nao silencia 4h)", f"{ncalls()-n1}")
jwrite(c / ".claude/settings.json", jread(OVERLAYS / "pool/.claude/settings.json")); install_claude(c)
rc, j, r = alarmed(c, st2); check(rc == 0 and not (st2 / "overlay-root-leak-guard-seen.json").exists(), "rodada limpa => apaga o estado 'visto'")
spawn(c, c, "pool-reviewer"); n0 = ncalls(); alarmed(c, st2); check(ncalls() - n0 == 2, "recorrencia DEPOIS de limpo alarma na hora (nao espera o cooldown)", f"{ncalls()-n0}")
c2 = new_city(); (c2 / ".gc/settings.json").write_text("nao json"); n0 = ncalls(); rc, j, r = alarmed(c2, W / "state3")
check(rc == 2 and ncalls() - n0 >= 1 and "overlay-guard-cego" in calls.read_text(), "DESCONHECIDO (rc 2) tambem alarma — guard cego nao fica quieto", f"rc={rc}")

# gate ga-3d1wno r1 — `gc config show` intermitente: o tick cego (config-unavailable) nao traz os achados de TOPOLOGIA. Esquecer a chave ali fazia o achado
# re-alarmar no tick seguinte SEM respeitar o cooldown (um alarme por flap). Cego != limpo: so um tick COMPLETO (sem desconhecido) esquece.
topo = cfg_file("flap_topo", [A("gate-reviewer", "pool-reviewer")] + CLEAN_AGENTS[1:]); nocfg = W / "nao_existe.toml"
def alarmed_cfg(city, state, cfg):
    return run(city, cfg, env={"OVLG_ROUTER": str(router), "OVLG_STATE_DIR": str(state), "OVLG_ESCALATE_AFTER_S": "3600"}, alarm=True)
cf = new_city(); stf = W / "state_flap"; n0 = ncalls()
rc, j, r = alarmed_cfg(cf, stf, topo)
check(rc == 1 and kinds(j) == ["root-resident-role-overlay"] and ncalls() - n0 == 1, "flap 1/4: achado de topologia alarma 1x", f"rc={rc} {kinds(j)} calls={ncalls()-n0}")
n0 = ncalls(); rc, j, r = alarmed_cfg(cf, stf, nocfg)
check(rc == 2 and [u["kind"] for u in (j or {}).get("unknowns", [])] == ["config-unavailable"] and ncalls() - n0 == 1, "flap 2/4: tick CEGO (config sumiu) alarma como DESCONHECIDO, nao como limpo", f"rc={rc} calls={ncalls()-n0}")
n0 = ncalls(); rc, j, r = alarmed_cfg(cf, stf, topo)
check(rc == 1 and ncalls() == n0, "flap 3/4: config volta => o achado NAO re-alarma (o tick cego nao esqueceu a chave; cooldown vale)", f"rc={rc} calls={ncalls()-n0}")
alarmed_cfg(cf, stf, CFG_CLEAN); n0 = ncalls(); alarmed_cfg(cf, stf, topo)
check(ncalls() - n0 == 1, "flap 4/4 (controle): um tick COMPLETO e limpo ainda esquece => recorrencia alarma na hora", f"calls={ncalls()-n0}")

# unknown|<kind>: 1 alarme por TIPO de cegueira (sem tempestade), mas o corpo lista TODOS os detalhes do kind — antes so o ultimo aparecia e dois
# arquivos ilegiveis pareciam um so.
fp = ovlg.fingerprints({"findings": [], "unknowns": [{"kind": "artifact-unreadable", "file": "a", "detail": "DETALHE-UM"},
                                                     {"kind": "artifact-unreadable", "file": "b", "detail": "DETALHE-DOIS"},
                                                     {"kind": "config-unavailable", "detail": "OUTRO-KIND"}]})
check(sorted(fp) == ["unknown|artifact-unreadable", "unknown|config-unavailable"], "unknown: dedup por KIND (1 chave por tipo de cegueira)", str(sorted(fp)))
b1 = fp["unknown|artifact-unreadable"][1]
check("DETALHE-UM" in b1 and "DETALHE-DOIS" in b1 and "OUTRO-KIND" not in b1 and "OUTRO-KIND" in fp["unknown|config-unavailable"][1],
      "unknown: o corpo do kind lista TODOS os seus detalhes (nao so o ultimo) e nao mistura kinds", b1[:200])
brouter = W / "router_body.sh"; bcalls = W / "router_body.calls"
brouter.write_text(f'#!/bin/sh\necho "CALL" >> "{bcalls}"\necho "$4" >> "{bcalls}"\nexit 0\n'); brouter.chmod(0o755)
c3 = new_city(); (c3 / ".claude/settings.json").write_text("nao json"); (c3 / ".gc/settings.json").write_text("{")
rc, j, r = run(c3, CFG_CLEAN, env={"OVLG_ROUTER": str(brouter), "OVLG_STATE_DIR": str(W / "state_body"), "OVLG_ESCALATE_AFTER_S": "3600"}, alarm=True)
ds = [u["detail"] for u in (j or {}).get("unknowns", []) if u["kind"] == "artifact-unreadable"]; mail = bcalls.read_text() if bcalls.exists() else ""
check(rc == 2 and len(ds) == 2 and ds[0] != ds[1] and mail.splitlines().count("CALL") == 1 and all(d in mail for d in ds),
      "e2e: 2 artefatos ilegiveis => UM alarme cujo corpo (o mail real) traz os DOIS detalhes", f"rc={rc} n={len(ds)} calls={mail.splitlines().count('CALL')}")

section("H2. --order (o modo do `gc order`): o alarme e o canal; exit != 0 so se a ENTREGA falhou")
def order_run(city, state, router_rc):
    rcfile.write_text(str(router_rc))
    cmd = [GUARD, "--city", str(city), "--overlays-dir", str(OVERLAYS), "--config-toml", str(CFG_CLEAN), "--no-lock", "--order"]
    e = dict(os.environ); e.update({"OVLG_ROUTER": str(router), "OVLG_STATE_DIR": str(state), "OVLG_ESCALATE_AFTER_S": "3600"})
    return subprocess.run(cmd, capture_output=True, text=True, env=e, timeout=120).returncode
c = new_city(); spawn(c, c, "pool-reviewer")
check(order_run(c, W / "state_o1", 0) == 0, "--order + vazamento + alarme entregue => exit 0 (o run do order nao conta como falho)")
check(order_run(c, W / "state_o2", 1) == 2, "--order + vazamento + entrega do alarme FALHOU => exit 2 (o run falho e o sinal de que ninguem foi avisado)")
c2 = new_city(); (c2 / ".gc/settings.json").write_text("nao json")
check(order_run(c2, W / "state_o3", 0) == 0, "--order + desconhecido (rc 2 do CLI) + alarme entregue => exit 0")
check(order_run(new_city(), W / "state_o4", 0) == 0, "--order + limpo => exit 0")
rc, j, r = run(c, CFG_CLEAN); check(rc == 1, "CLI sem --order continua 0/1/2 (vazamento => 1)", f"{rc}")

# ================================================================== I. lock
section("I. lock: instancia unica")
c = new_city(); lockp = c / ".gc/runtime/overlay-root-leak-guard.lock"
fh = open(lockp, "w"); fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
LOCKED = [GUARD, "--city", str(c), "--overlays-dir", str(OVERLAYS), "--config-toml", str(CFG_CLEAN), "--no-alarm"]
r = subprocess.run(LOCKED + ["--order"], capture_output=True, text=True, timeout=60)
check(r.returncode == 0 and "outra instancia" in r.stdout and "═══" not in r.stdout, "--order + lock ocupado => sai 0 sem rodar (nao empilha, ga-y0g5x; a instancia que segura cobre a rodada)", f"rc={r.returncode} {r.stdout[:200]}")
# gate ga-3d1wno r1: o runbook le `rc=$?` do CLI manual sozinho — um 0 aqui e "limpo" sem check nenhum rodado (erro vira vazio).
r = subprocess.run(LOCKED, capture_output=True, text=True, timeout=60)
check(r.returncode == 2 and "NAO rodei" in r.stderr and "═══" not in r.stdout, "CLI manual + lock ocupado => rc 2 'NAO rodei' (0 seria 'limpo' sem check rodado)", f"rc={r.returncode} err={r.stderr[:160]}")
fcntl.flock(fh, fcntl.LOCK_UN); fh.close()
r = subprocess.run([GUARD, "--city", str(c), "--overlays-dir", str(OVERLAYS), "--config-toml", str(CFG_CLEAN), "--no-alarm"], capture_output=True, text=True, timeout=60)
check(r.returncode == 0 and "═══" in r.stdout, "lock livre => roda normalmente", f"rc={r.returncode}")

# ================================================================== L. cidade viva (somente leitura)
section("L. cidade viva: o guard le a cidade real (--no-alarm --no-lock, somente leitura)")
live = os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY")
if live and Path(live, "city.toml").is_file() and subprocess.run(["sh", "-c", "command -v gc"], capture_output=True).returncode == 0:
    r = subprocess.run([GUARD, "--city", live, "--no-alarm", "--no-lock", "--json"], capture_output=True, text=True, timeout=200)
    try: j = json.loads(r.stdout)
    except ValueError: j = None
    check(r.returncode in (0, 1) and j is not None, "guard le a cidade viva e chega a um veredito (0 ou 1, nunca 2)", f"rc={r.returncode} unknowns={j and j.get('unknowns')} err={r.stderr[-200:]}")
    print(f"  ~ veredito vivo: rc={r.returncode} findings={len(j['findings']) if j else '?'} — " + ("LIMPO" if r.returncode == 0 else "VAZAMENTO REAL NA CIDADE VIVA (o alarme cuida disso; este teste so prova que o guard le)"))
else:
    print("  ~ SKIP: GC_CITY_PATH/gc indisponivel — nao da pra provar a leitura da cidade viva")
print("DONE", flush=True)
PY
PYRC=$?
while IFS= read -r line; do
  case "$line" in
    OK:*)   echo "  ✓ ${line#OK: }";   PASS=$((PASS+1)) ;;
    BAD:*)  echo "  ✗ ${line#BAD: }";  FAIL=$((FAIL+1)) ;;
    DONE)   ;;
    *)      echo "$line" ;;
  esac
done < "$W/py.out"
if [ "$PYRC" -ne 0 ] || ! grep -qx 'DONE' "$W/py.out"; then
  echo "  ✗ o script de cenarios MORREU antes do fim (rc=$PYRC, sentinela DONE ausente) — os testes acima nao sao o conjunto completo"; FAIL=$((FAIL+1))
fi

echo
echo "== resultado: $PASS ok, $FAIL falha(s)"
[ "$FAIL" -eq 0 ]
