#!/usr/bin/env bash
# pool-preamble-build.selftest.sh — ga-aijm2v.6: prove the "preâmbulo por papel" (etapa 1) cuts what it claims and
# LOSES nothing it must keep.
#
# Uma sessão de pool nascia com ~137-147k tokens de contexto fixo (schemas de tools, CLAUDE.md/MEMORY do Mayor,
# listagem de skills, doutrina town-deltas). O corte por papel tem 2 alavancas e o risco de cada uma é um buraco
# SILENCIOSO (uma regra some do prompt de um papel; um overlay nega uma tool que o papel usa). Este teste tem 4 metades
# porque nenhuma sozinha prova isso:
#   A. GERADOR   — overlays commitados == gerados do manifesto; guardas do fragment == manifesto; núcleo presente
#                  em bloco NÃO guardado (pool-preamble-build.py check).
#   B. CONTROLES — o detector TEM DENTES: cada mutação abaixo TEM que reprovar o `check`. Um teste que só passa não prova
#                  nada (regra 7 da doutrina): sem estes controles um `check` que sempre devolve 0 ficaria verde.
#   C. FIAÇÃO    — city.toml/agent.toml: cada papel aponta pro SEU overlay e tem o TD_ROLE certo; ninguém fora do
#                  manifesto ganhou TD_ROLE (Mayor/crews/witness seguem recebendo a doutrina inteira — fail-open); os
#                  agentes sem dado de uso (boot/deacon/auto-refiner/context-check) seguem no overlay `pool`.
#   D. MOTOR REAL — `gc prime --strict` (o binário VIVO) em uma cidade descartável, com um agente sintético por papel:
#                  o texto renderizado é EXATAMENTE o que o manifesto promete; agente SEM TD_ROLE recebe o fragment
#                  inteiro, byte a byte igual ao fragment sem guardas; toda sentinela do núcleo aparece em TODO papel;
#                  o texto de uma seção escondida não vaza. (Prova também que `env` do agent.toml chega no template.)
#
# HERMÉTICO: não toca a cidade viva, não abre store, não cria sessão. `gc prime` sem --hook só escreve em stdout.
# Sem `go build` (disco ≥96% -> o monitor esvazia o cache no meio do build): usa só o `gc` já instalado.
# Env: PP_GC (binário do gc, default `gc`), PP_KEEP=1 (mantém o diretório temporário p/ inspeção).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${PP_BUILD:-$SELF_DIR/pool-preamble-build.py}"
HQ="${PP_HQ:-$(cd "$SELF_DIR/../../.." && pwd)}"          # .../.gascity-gastown-hq (a raiz da cidade no git)
GC="${PP_GC:-gc}"

PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$BUILD" ] || { echo "FATAL: gerador não encontrado em $BUILD"; exit 1; }
[ -f "$HQ/city.toml" ] || { echo "FATAL: city.toml não encontrado em $HQ"; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 ausente"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/pool-preamble-selftest.XXXXXX")"
cleanup() { [ "${PP_KEEP:-0}" = 1 ] && { echo "(mantido: $W)"; return; }; rm -rf "$W"; }
trap cleanup EXIT

echo "== A. gerador: overlays/guardas/núcleo vs manifesto"
if out="$(python3 "$BUILD" check 2>&1)"; then ok "pool-preamble-build.py check: $(echo "$out" | tail -1)"; else bad "check reprovou:"; echo "$out" | sed 's/^/      /'; fi
if secs="$(python3 "$BUILD" sections 2>&1)" && echo "$secs" | grep -q '^== dog:' && echo "$secs" | grep -q '^== reviewer:'; then ok "sections lista as seções entregues por papel"; else bad "sections não listou os papéis"; fi

echo "== B. controles negativos (cada mutação TEM que reprovar o check)"
# árvore descartável: a mesma estrutura packs/town-deltas/{assets/claude-overlays,template-fragments}
T="$W/mut"; mkdir -p "$T/packs/town-deltas/assets" "$T/packs/town-deltas/template-fragments"
ASSETS_SRC="$(cd "$SELF_DIR" && pwd)"
reset_tree() {
  rm -rf "$T/packs/town-deltas/assets/claude-overlays" 2>/dev/null || true
  cp -R "$ASSETS_SRC/claude-overlays" "$T/packs/town-deltas/assets/claude-overlays"
  cp "$SELF_DIR/../template-fragments/town-deltas.template.md" "$T/packs/town-deltas/template-fragments/town-deltas.template.md"
}
run_check() { PP_ASSETS_DIR="$T/packs/town-deltas/assets" python3 "$BUILD" check 2>&1; }
expect_fail() { # $1=descrição $2=trecho esperado na saída
  local o rc; o="$(run_check)"; rc=$?
  if [ $rc -ne 0 ] && echo "$o" | grep -q -F -- "$2"; then ok "reprova: $1"; else bad "NÃO reprovou (rc=$rc): $1 — esperava '$2'"; echo "$o" | sed 's/^/      /' | head -5; fi
}
reset_tree; if o="$(run_check)"; then ok "controle positivo: cópia intacta passa"; else bad "cópia intacta deveria passar"; echo "$o" | sed 's/^/      /' | head; fi

reset_tree; sed -i.bak 's/"Bash(sudo:\*)"/"Bash(sudo:*)", "Bash"/' "$T/packs/town-deltas/assets/claude-overlays/pool-dog/.claude/settings.json"
expect_fail "overlay editado à mão (nega Bash)" "DIVERGE"
reset_tree; python3 - "$T/packs/town-deltas/assets/claude-overlays" <<'EOF'
import json,sys
d=sys.argv[1]; p=d+"/pool-roles.json"; m=json.load(open(p)); m["common"]["deny_tools"].append("Read"); json.dump(m,open(p,"w"),indent=1,ensure_ascii=False)
EOF
PP_ASSETS_DIR="$T/packs/town-deltas/assets" python3 "$BUILD" build >/dev/null 2>&1
expect_fail "manifesto passa a negar Read (tool essencial)" "nega tool essencial"
reset_tree; python3 - "$T/packs/town-deltas/assets/claude-overlays" <<'EOF'
import json,sys
p=sys.argv[1]+"/pool-roles.json"; m=json.load(open(p)); m["roles"]["dog"]["deny_tools_extra"].append("Agent"); json.dump(m,open(p,"w"),indent=1,ensure_ascii=False)
EOF
PP_ASSETS_DIR="$T/packs/town-deltas/assets" python3 "$BUILD" build >/dev/null 2>&1
expect_fail "construtor (dog) passa a negar Agent" "construtor nega tool que usa"
reset_tree; python3 - "$T/packs/town-deltas/assets/claude-overlays" <<'EOF'
import json,sys
p=sys.argv[1]+"/pool-roles.json"; m=json.load(open(p)); m["common"]["claude_md_excludes"]=[x for x in m["common"]["claude_md_excludes"] if not x.endswith("AGENTS.md")]; json.dump(m,open(p,"w"),indent=1,ensure_ascii=False)
EOF
PP_ASSETS_DIR="$T/packs/town-deltas/assets" python3 "$BUILD" build >/dev/null 2>&1
expect_fail "exclude sem AGENTS.md (o fallback que reintroduz 24k chars)" "AGENTS.md é o fallback"
reset_tree; python3 - "$T/packs/town-deltas/template-fragments/town-deltas.template.md" <<'EOF'
import sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read()
# tira ps-worker da guarda de mockup-s3 SÓ no fragment; o manifesto continua dizendo que ps-worker recebe.
# Asserta que mutou (senão o controle seria vácuo: passaria por não ter mudado nada).
old='(eq .TD_ROLE "ps-worker") (eq .TD_ROLE "wa-worker") -}}{{/* td:mockup-s3 */ -}}'; assert old in s, "mutação não aplicou: formato da guarda mudou"
open(p,"w",encoding="utf-8").write(s.replace(old,'(eq .TD_ROLE "wa-worker") -}}{{/* td:mockup-s3 */ -}}',1))
EOF
expect_fail "guarda de mockup-s3 editada (some ps-worker) sem mexer no manifesto" "diverge do manifesto"
reset_tree; sed -i.bak 's/Verifique o ARTEFATO, nunca o relato/Verifique o resultado/' "$T/packs/town-deltas/template-fragments/town-deltas.template.md"
expect_fail "núcleo perde 'verificação de artefato'" "NÚCLEO: sentinela 'verificacao-de-artefato'"
reset_tree; python3 - "$T/packs/town-deltas/template-fragments/town-deltas.template.md" <<'EOF'
import sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read()
# move a sentinela do núcleo para DENTRO de uma seção guardada: a frase continua no arquivo, mas some pra alguns papéis
needle="Secrets — Bitwarden é source of truth"; assert needle in s
s=s.replace("**"+needle+".**","**Segredos.**",1).replace("{{ end -}}\n{{ if not .TD_ROLE -}}{{/* td:witness-startup */ -}}\n","{{ end -}}\n{{ if not .TD_ROLE -}}{{/* td:witness-startup */ -}}\n"+needle+" (só aqui)\n",1)
open(p,"w",encoding="utf-8").write(s)
EOF
expect_fail "sentinela de segredos migra para seção guardada (existe no arquivo, mas não é núcleo)" "NÚCLEO: sentinela 'segredos'"
reset_tree; python3 - "$T/packs/town-deltas/template-fragments/town-deltas.template.md" <<'EOF'
import sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read()
s=s.replace("{{/* td:core:rule-2 */ -}}","{{/* td:core:rule-1 */ -}}",1); open(p,"w",encoding="utf-8").write(s)
EOF
expect_fail "id de seção duplicado" "id de seção repetido"
reset_tree; python3 - "$T/packs/town-deltas/template-fragments/town-deltas.template.md" <<'EOF'
import sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read(); s=s.replace("\n{{ end -}}\n","\n",1); open(p,"w",encoding="utf-8").write(s)
EOF
expect_fail "guarda sem {{ end -}} (template quebraria o prompt de TODOS os agentes)" "fragment"

echo "== C. fiação: overlay_dir + TD_ROLE por papel (city.toml patches + agent.toml)"
python3 - "$HQ" "$SELF_DIR/claude-overlays/pool-roles.json" <<'EOF' && ok "fiação bate com o manifesto" || bad "fiação diverge do manifesto (ver acima)"
import json, sys, tomllib
from pathlib import Path
hq, man = Path(sys.argv[1]), json.load(open(sys.argv[2]))
city = tomllib.load(open(hq / "city.toml", "rb"))
patches = [p for p in city.get("patches", {}).get("agent", [])]
def effective(name):
    """overlay_dir (último vence) e env (merge aditivo) de um agente: patches do city.toml + o próprio agent.toml."""
    ov, env = None, {}
    at = hq / "agents" / name / "agent.toml"
    if at.exists():
        a = tomllib.load(open(at, "rb")); ov = a.get("overlay_dir", ov); env.update(a.get("env", {}))
    for p in patches:
        if p.get("name") in (name, "gastown." + name) and p.get("dir", "") == "":
            ov = p.get("overlay_dir", ov); env.update(p.get("env", {}))
    return ov, env
errs = []
base = "packs/town-deltas/assets/claude-overlays/"
claimed = set()
for role, r in man["roles"].items():
    for ag in r["agents"]:
        bare = ag.split(".")[-1]; claimed.add(bare)
        ov, env = effective(bare if bare != "dog" else "dog")
        if ov != base + r["overlay"]: errs.append(f"{ag}: overlay_dir={ov!r}, esperado {base + r['overlay']!r}")
        # overlay_dir que NÃO existe é NO-OP SILENCIOSO no engine (internal/overlay: "se srcDir não existe, retorna nil"): a sessão nasce
        # SEM overlay — sem o deny de `rm -rf` (ga-q640n), sem RC off (wa-cy6we) e sem nenhum corte. Sem erro. Por isso o arquivo tem que existir.
        if ov and not (hq / ov / ".claude" / "settings.json").is_file(): errs.append(f"{ag}: overlay_dir aponta pra {ov!r} mas {ov}/.claude/settings.json NÃO existe (no-op silencioso: sessão sem overlay nenhum)")
        if env.get("TD_ROLE") != r["td_role"]: errs.append(f"{ag}: TD_ROLE={env.get('TD_ROLE')!r}, esperado {r['td_role']!r}")
# quem NÃO está no manifesto: nenhum TD_ROLE (fail-open) — varre city.toml (tudo) e todo agent.toml
import re
allowed_city = len(claimed & {"dog", "wa-worker", "ps-worker"})
n_city = len(re.findall(r"^\s*env\s*=\s*\{[^}]*TD_ROLE", (hq / "city.toml").read_text(encoding="utf-8"), flags=re.M))
if n_city != allowed_city: errs.append(f"city.toml declara TD_ROLE em {n_city} patches; esperado {allowed_city} (dog/wa-worker/ps-worker)")
for at in sorted((hq / "agents").glob("*/agent.toml")):
    name = at.parent.name
    a = tomllib.load(open(at, "rb"))
    has = "TD_ROLE" in (a.get("env") or {})
    if has and name not in claimed: errs.append(f"agents/{name}: tem TD_ROLE mas não está no manifesto (perderia doutrina em silêncio)")
# sem dado de uso -> seguem no overlay `pool` (a promessa do manifesto: 'papéis que NÃO estão aqui seguem como antes')
for name in ("boot", "deacon", "auto-refiner", "context-check-reviewer"):
    ov, _ = effective(name)
    if ov != base + "pool": errs.append(f"{name}: overlay_dir={ov!r}; esperado o `pool` original (sem dado de uso para trocar)")
for e in errs: print("      ✗", e)
sys.exit(1 if errs else 0)
EOF

# C2. os overlays TÊM que estar versionados: .gitignore ignora `.claude/` — um overlay novo fica de fora do commit em silêncio e o
#     deploy leva o city.toml apontando pra um diretório que não existe (achado na hora de commitar; use `git add -f`).
if git -C "$HQ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  miss=""
  for f in "$SELF_DIR"/claude-overlays/pool-*/.claude/settings.json; do
    git -C "$HQ" ls-files --error-unmatch "$f" >/dev/null 2>&1 || miss="$miss ${f#$SELF_DIR/claude-overlays/}"
  done
  n_ov=$(ls -d "$SELF_DIR"/claude-overlays/pool-*/ 2>/dev/null | wc -l | tr -d ' ')
  if [ -z "$miss" ] && [ "$n_ov" -ge 4 ]; then ok "os $n_ov overlays por papel estão VERSIONADOS no git (não ficaram de fora pelo .gitignore de .claude/)"; else bad "overlay(s) NÃO versionado(s) [${miss:-nenhum listado}] (n_ov=$n_ov) — .gitignore:.claude/ os ignora; rode: git add -f <arquivo>"; fi
else
  echo "  ~ SKIP: não é um checkout git — não dá pra provar que os overlays estão versionados"
fi

echo "== D. motor real: gc prime --strict (binário vivo) em cidade descartável"
if ! command -v "$GC" >/dev/null 2>&1; then
  bad "gc não encontrado ('$GC') — esta metade não pode passar em silêncio; defina PP_GC"
else
  PP_HQ="$HQ" PP_BUILD_PY="$BUILD" PP_GC="$GC" PP_WORK="$W/city" python3 - <<'EOF' && ok "render real == referência do motor para todos os papéis + núcleo em todos + sem vazamento" || bad "render real diverge (ver acima)"
import importlib.util, os, subprocess, sys
from pathlib import Path
hq = Path(os.environ["PP_HQ"]); gc = os.environ["PP_GC"]; work = Path(os.environ["PP_WORK"])
spec = importlib.util.spec_from_file_location("ppb", os.environ["PP_BUILD_PY"]); ppb = importlib.util.module_from_spec(spec); spec.loader.exec_module(ppb)
m = ppb.load_manifest(); blocks = ppb.parse_fragment(ppb.FRAGMENT.read_text(encoding="utf-8"))
roles = [r["td_role"] for r in m["roles"].values()]
CITY = '[workspace]\nprovider = "claude"\nglobal_fragments = ["town-deltas"]\n\n[providers]\n[providers.claude]\nbase = "builtin:claude"\n\n[imports]\n[imports.town-deltas]\nsource = "packs/town-deltas"\n'
cases = [("p-unset", None)] + [("p-" + r, r) for r in roles]

def make_city(root, *, real_packs, fragment_text=None, with_env):
    """cidade descartável. real_packs=True: importa o pack DO REPO (guardas de verdade). Senão: pack mínimo cujo fragment é
    `fragment_text` (texto puro, sem guardas) — a REFERÊNCIA que o mesmo motor renderiza."""
    (root / ".gc").mkdir(parents=True); (root / "gchome").mkdir()
    (root / "pack.toml").write_text('[pack]\nname = "scratch"\nschema = 2\n'); (root / "city.toml").write_text(CITY)
    if real_packs:
        os.symlink(hq / "packs", root / "packs")
    else:
        td = root / "packs" / "town-deltas" / "template-fragments"; td.mkdir(parents=True)
        (root / "packs" / "town-deltas" / "pack.toml").write_text('[pack]\nname = "town-deltas"\nschema = 2\n')
        (td / "town-deltas.template.md").write_text(fragment_text)
    for name, role in cases:
        d = root / "agents" / name; d.mkdir(parents=True)
        env = f'env = {{ TD_ROLE = "{role}" }}\n' if (role and with_env) else ""
        (d / "agent.toml").write_text('max_active_sessions = 1\nmin_active_sessions = 0\nscope = "city"\n' + env)
        (d / "prompt.template.md").write_text(f"# {name}\nBASE-BODY\n")

clean = {k: v for k, v in os.environ.items() if not k.startswith("GC_")}
def render(root, name):
    env = dict(clean); env["GC_HOME"] = str(root / "gchome")
    for attempt in (1, 2):                      # 1 retry: o gc pode estar sob carga (Dolt quente); erro persistente reprova
        r = subprocess.run([gc, "--city", str(root), "prime", "--strict", name], cwd=root, env=env, capture_output=True, text=True, timeout=120)
        if r.returncode == 0: return r.stdout
    raise SystemExit(f"      ✗ gc prime --strict {name} ({root.name}) falhou rc={r.returncode}: {r.stderr.strip()[:300]}")

make_city(work / "real", real_packs=True, with_env=True)
errs = []
for name, role in cases:
    out = render(work / "real", name)
    # REFERÊNCIA: o MESMO motor renderizando o fragment já sem guardas e sem as seções escondidas deste papel (sem env)
    ref_root = work / ("ref-" + name); make_city(ref_root, real_packs=False, fragment_text=ppb.role_text(blocks, m, role), with_env=False)
    ref = render(ref_root, name)
    if out != ref: errs.append(f"{name}: render com guardas (TD_ROLE={role}) != referência do motor sem guardas ({len(out)} vs {len(ref)} chars)"); continue
    if not out.startswith(f"# {name}\nBASE-BODY\n"): errs.append(f"{name}: corpo do agente mudou")
    for key, needle in m["doctrine"]["core_sentinels"].items():
        if needle not in out: errs.append(f"{name}: NÚCLEO '{key}' ausente do prompt renderizado")
    for b in blocks:
        if b["cond"] is None: continue
        should = role is None or role in m["doctrine"]["guarded"][b["id"]]["roles"]
        if should != (b["lines"][0] in out): errs.append(f"{name}: seção '{b['id']}' {'deveria estar' if should else 'VAZOU (deveria estar escondida)'}")
    print(f"      {name:14s} {len(out):>7,} chars  == referência do motor")
for e in errs: print("      ✗", e)
sys.exit(1 if errs else 0)
EOF
fi

echo
echo "== resultado: $PASS ok, $FAIL falha(s)"
[ "$FAIL" -eq 0 ]
