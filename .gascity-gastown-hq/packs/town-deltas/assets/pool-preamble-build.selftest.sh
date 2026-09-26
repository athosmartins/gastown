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
#                  ga-swnkfm: papel com `workdir: city-root` no manifesto (os revisores: sem work_dir, rodam na RAIZ) só pode ter o
#                  overlay BASE fiado — o do papel vaza pro .claude/settings.json da raiz e daí pro .gc/settings.json de TODA sessão;
#                  `workdir: own` exige work_dir declarado. C3 são as mutações da fiação (o teste antigo EXIGIA o pool-reviewer).
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
# gate ga-0g70nl: a 1ª versão negava ao REVISOR Monitor/TaskStop/ScheduleWakeup/Skill por uma premissa de "0 uso" que um contador cego produziu; medido
# de verdade, o gate-reviewer usa Monitor (13), TaskStop (22), ScheduleWakeup (3), Skill (3) e o refino-gate-reviewer usa Skill (3). O `check` tem que
# recusar a regressão — antes, `if td_role != "reviewer"` deixava o revisor negar qualquer coisa.
for t in Monitor TaskStop ScheduleWakeup Skill; do
  reset_tree; python3 - "$T/packs/town-deltas/assets/claude-overlays" "$t" <<'EOF'
import json, sys
p = sys.argv[1] + "/pool-roles.json"; m = json.load(open(p)); m["roles"]["reviewer"]["deny_tools_extra"].append(sys.argv[2])
json.dump(m, open(p, "w"), indent=1, ensure_ascii=False)
EOF
  PP_ASSETS_DIR="$T/packs/town-deltas/assets" python3 "$BUILD" build >/dev/null 2>&1
  expect_fail "revisor passa a negar $t (o gate-reviewer/refino-gate-reviewer a usa de verdade)" "nega tool essencial"
done
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
reset_tree; python3 - "$T/packs/town-deltas/assets/claude-overlays" <<'EOF'
import json, sys
p = sys.argv[1] + "/pool-roles.json"; m = json.load(open(p)); m["roles"]["dog"]["auto_memory"] = True
json.dump(m, open(p, "w"), indent=1, ensure_ascii=False)
EOF
PP_ASSETS_DIR="$T/packs/town-deltas/assets" python3 "$BUILD" build >/dev/null 2>&1
expect_fail "dog volta a carregar o índice de memória do Mayor (o corte que a bead manda)" "índice de memória desse papel é o do Mayor"
reset_tree; python3 - "$T/packs/town-deltas/assets/claude-overlays/pool-roles.json" <<'EOF'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["doctrine"]["guarded"]["claudemd-carryover"]["roles"].remove("wa-worker")
json.dump(m, open(p, "w"), indent=1, ensure_ascii=False)
EOF
expect_fail "wa-worker tem o CLAUDE.md excluído mas deixa de receber o carry-over (as regras só-do-CLAUDE.md sumiriam em silêncio)" "não recebe 'claudemd-carryover'"
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
wiring_check() { python3 - "$1" "$2" <<'EOF'
import json, sys, tomllib
from pathlib import Path
hq, man = Path(sys.argv[1]), json.load(open(sys.argv[2]))
city = tomllib.load(open(hq / "city.toml", "rb"))
patches = [p for p in city.get("patches", {}).get("agent", [])]
def effective(name):
    """overlay_dir (último vence), env (merge aditivo) e work_dir de um agente: patches do city.toml + o próprio agent.toml."""
    ov, env, wd = None, {}, None
    at = hq / "agents" / name / "agent.toml"
    if at.exists():
        a = tomllib.load(open(at, "rb")); ov = a.get("overlay_dir", ov); env.update(a.get("env", {})); wd = a.get("work_dir", wd)
    for p in patches:
        if p.get("name") in (name, "gastown." + name) and p.get("dir", "") == "":
            ov = p.get("overlay_dir", ov); env.update(p.get("env", {})); wd = p.get("work_dir", wd)
    return ov, env, wd
errs = []
base = "packs/town-deltas/assets/claude-overlays/"
claimed = set()
for role, r in man["roles"].items():
    for ag in r["agents"]:
        bare = ag.split(".")[-1]; claimed.add(bare)
        ov, env, wd = effective(bare if bare != "dog" else "dog")
        # wired_overlay (Mayor, 49cd6f040): papel cujo overlay próprio foi DESLIGADO de propósito (ex.: revisor, ga-swnkfm) — a fiação tem que bater com ele.
        want_name = r.get("wired_overlay", r["overlay"])
        want = base + want_name
        # ga-swnkfm (26/09): overlay_dir faz JSON-merge em <workdir>/.claude/settings.json e o .gc/settings.json de TODAS as sessões é derivado do
        # <cidade>/.claude/settings.json. Agente SEM work_dir roda na RAIZ da cidade => só o overlay BASE é seguro ali (o pool-reviewer vazou: gate-done
        # off + CLAUDE.md fora + memória off pra cidade inteira). O manifesto declara onde o papel roda (`workdir`); o overlay fiado tem que combinar.
        at_root = r.get("workdir") == "city-root"
        if ov != want:
            why = f" — papel workdir=city-root: na raiz só o overlay base `{man['base_overlay']}` é seguro (ga-swnkfm; ver overlay-root-leak-guard.py)" if at_root else ""
            errs.append(f"{ag}: overlay_dir={ov!r}, esperado {want!r}{why}")
        if at_root and want_name != man["base_overlay"]:
            errs.append(f"{ag}: manifesto diz workdir=city-root mas ESPERA o overlay {want_name!r} fiado — na raiz só o base `{man['base_overlay']}` é seguro (foi o incidente do ga-swnkfm, com manifesto e agent.toml concordando no vazamento); troque workdir para \"own\" (com work_dir) ou use wired_overlay = base")
        if at_root and wd:
            errs.append(f"{ag}: manifesto diz workdir=city-root mas o agente tem work_dir={wd!r} — troque o manifesto para \"own\" (e religue o overlay do papel) ou tire o work_dir")
        if r.get("workdir") == "own" and (hq / "agents" / bare / "agent.toml").exists() and not wd:
            errs.append(f"{ag}: manifesto diz workdir=own mas o agente NÃO declara work_dir — ele roda na RAIZ e o overlay do papel vaza pra cidade inteira (ga-swnkfm)")
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
    ov, _, _ = effective(name)
    if ov != base + "pool": errs.append(f"{name}: overlay_dir={ov!r}; esperado o `pool` original (sem dado de uso para trocar)")
for e in errs: print("      ✗", e)
sys.exit(1 if errs else 0)
EOF
}
wiring_check "$HQ" "$SELF_DIR/claude-overlays/pool-roles.json" && ok "fiação bate com o manifesto" || bad "fiação diverge do manifesto (ver acima)"

# C3. controles negativos da fiação — o incidente ga-swnkfm (26/09) passou por um teste de fiação que só conferia "o agente aponta pro overlay do
#     manifesto": ele EXIGIA o pool-reviewer e o pool-reviewer é justamente o que vaza quando o agente roda na raiz. HQ descartável, mesmas leis.
H="$W/hq"; mkdir -p "$H/packs/town-deltas/assets" "$H/agents"
ln -s "$SELF_DIR/claude-overlays" "$H/packs/town-deltas/assets/claude-overlays"
reset_hq() {
  cp "$HQ/city.toml" "$H/city.toml"; cp "$SELF_DIR/claude-overlays/pool-roles.json" "$H/man.json"
  for d in "$HQ"/agents/*/; do n="$(basename "$d")"; mkdir -p "$H/agents/$n"; [ -f "$d/agent.toml" ] && cp "$d/agent.toml" "$H/agents/$n/agent.toml"; done
  return 0
}
pyedit() { python3 - "$@" <<'EOF'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
if old not in s: sys.exit(f"pyedit: '{old}' não está em {p}")
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
EOF
}
prepend() { printf '%s\n%s' "$2" "$(cat "$1")" > "$1"; }
man_edit() { # $1=own|nowire — own: workdir=own E tira o wired_overlay (religar); nowire: só tira o wired_overlay (manifesto passa a ESPERAR o overlay do papel)
  python3 - "$H/man.json" "$1" <<'EOF'
import json, sys
p, mode = sys.argv[1], sys.argv[2]
m = json.load(open(p, encoding="utf-8")); r = m["roles"]["reviewer"]
if mode == "own": r["workdir"] = "own"
r.pop("wired_overlay", None); r.pop("_wired_overlay_why", None)
json.dump(m, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
EOF
}
REVS="gate-reviewer refino-gate-reviewer"
expect_wiring_fail() { # $1=descrição $2=trecho esperado
  local o rc; o="$(wiring_check "$H" "$H/man.json" 2>&1)"; rc=$?
  if [ $rc -ne 0 ] && echo "$o" | grep -q -F -- "$2"; then ok "reprova: $1"; else bad "fiação NÃO reprovou (rc=$rc): $1 — esperava '$2'"; echo "$o" | sed 's/^/      /' | head -5; fi
}
reset_hq; if o="$(wiring_check "$H" "$H/man.json" 2>&1)"; then ok "controle positivo: cópia intacta da fiação passa"; else bad "cópia intacta da fiação deveria passar"; echo "$o" | sed 's/^/      /' | head -5; fi
reset_hq; for r in $REVS; do pyedit "$H/agents/$r/agent.toml" 'claude-overlays/pool"' 'claude-overlays/pool-reviewer"'; done
expect_wiring_fail "INCIDENTE: revisor SEM work_dir fiado ao pool-reviewer (o overlay vaza da raiz pra cidade inteira)" "workdir=city-root"
reset_hq; man_edit nowire; for r in $REVS; do pyedit "$H/agents/$r/agent.toml" 'claude-overlays/pool"' 'claude-overlays/pool-reviewer"'; done
expect_wiring_fail "INCIDENTE com manifesto E agent.toml concordando no vazamento (era o estado do commit eb4ef5b6b: o teste antigo o EXIGIA)" "na raiz só o base"
reset_hq; for r in $REVS; do prepend "$H/agents/$r/agent.toml" 'work_dir = ".gc/agents/gate-reviewer"'; done
expect_wiring_fail "manifesto diz city-root mas o revisor JÁ tem work_dir (manifesto velho: o overlay do papel ficaria desligado à toa)" "tem work_dir"
reset_hq; pyedit "$H/man.json" '"workdir": "city-root"' '"workdir": "own"'; for r in $REVS; do pyedit "$H/agents/$r/agent.toml" 'claude-overlays/pool"' 'claude-overlays/pool-reviewer"'; done
expect_wiring_fail "manifesto diz own + pool-reviewer fiado, mas o revisor NÃO declara work_dir (religar sem dar work_dir = o incidente de novo)" "NÃO declara work_dir"
reset_hq; man_edit own; for r in $REVS; do pyedit "$H/agents/$r/agent.toml" 'claude-overlays/pool"' 'claude-overlays/pool-reviewer"'; prepend "$H/agents/$r/agent.toml" 'work_dir = ".gc/agents/gate-reviewer"'; done
if o="$(wiring_check "$H" "$H/man.json" 2>&1)"; then ok "caminho legítimo de religar passa: workdir=own + work_dir próprio + overlay pool-reviewer + wired_overlay removido"; else bad "o caminho legítimo de religar o pool-reviewer deveria passar"; echo "$o" | sed 's/^/      /' | head -5; fi

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
        should = ppb.receives(m["doctrine"]["guarded"][b["id"]], role)
        if should != (b["lines"][0] in out): errs.append(f"{name}: seção '{b['id']}' {'deveria estar' if should else 'VAZOU (deveria estar escondida)'}")
    print(f"      {name:14s} {len(out):>7,} chars  == referência do motor")
for e in errs: print("      ✗", e)
sys.exit(1 if errs else 0)
EOF
fi

echo
echo "== resultado: $PASS ok, $FAIL falha(s)"
[ "$FAIL" -eq 0 ]
