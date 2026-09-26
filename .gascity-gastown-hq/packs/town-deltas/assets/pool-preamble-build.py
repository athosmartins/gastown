#!/usr/bin/env python3
"""pool-preamble-build.py — ga-aijm2v.6 (etapa 1 do "preâmbulo por papel").

Uma sessão de pool nascia com ~137-147k tokens de contexto FIXO, relidos a cada turno. Este script
mantém sob controle as duas alavancas que cortam isso por PAPEL, a partir de UMA fonte:

    claude-overlays/pool-roles.json          (manifesto — edite AQUI)
        |-- build  --> claude-overlays/pool-<papel>/.claude/settings.json   (um overlay por papel)
        `-- check  --> valida os overlays gerados E as guardas de seção no fragment town-deltas

Subcomandos:
    build       reescreve os overlays a partir do manifesto (determinístico)
    check       sai 1 se overlay commitado != gerado, ou se guarda/manifesto/fragment divergem
    sections    lista as seções da doutrina entregues por papel (com tamanho em chars)
    per-task    (ga-aijm2v.7) por papel: quais seções o Jev pode dispensar por tarefa e o teto de economia
    new-skills  ADVISORY: skills que existem no disco mas o manifesto não conhece (nunca falha)

Por que NÃO gerar o fragment: o engine lê o fragment direto do git; um passo de geração no deploy seria
mais uma coisa que pode ficar velha. As guardas moram no fragment; aqui só se PROVA que batem com o manifesto.

Garantias que `check` defende (cada uma nasceu de uma medição, ver docs/pool-preamble-per-role.md):
  * agente SEM `TD_ROLE` (Mayor, crews, witness, deacon, boot...) continua recebendo o fragment inteiro;
  * toda seção do fragment está no manifesto exatamente uma vez, e a condição da guarda é a gerada;
  * nenhum overlay nega uma tool que o papel usa (NEVER_DENY_ALL: Bash/Read/Edit/Write/Grep/Glob/ToolSearch e as que dog, wa-worker
    E gate-reviewer mediram em uso — Monitor/TaskStop/ScheduleWakeup/Skill; NEVER_DENY_BUILDERS: Agent, só o reviewer pode perdê-la),
    e todo overlay mantém os deny/RC do overlay `pool` base. Quais tools cada papel usa vem de MEDIÇÃO (docs/pool-preamble-per-role.md,
    `pool-preamble-measure.py denied-attempts` sem --cutover), nunca de premissa — a 1ª versão negava Monitor/TaskStop/Skill ao revisor
    por "0 uso" produzido por um contador que só via ~1 de cada 9 tool_use (gate ga-0g70nl).

Só stdlib. Somente leitura, exceto `build`.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

ASSETS = Path(os.environ.get("PP_ASSETS_DIR") or Path(__file__).resolve().parent)
OVERLAYS = ASSETS / "claude-overlays"
MANIFEST = Path(os.environ.get("PP_MANIFEST") or OVERLAYS / "pool-roles.json")
FRAGMENT = Path(os.environ.get("PP_FRAGMENT") or ASSETS.parent / "template-fragments" / "town-deltas.template.md")

# tools que NENHUM papel de pool pode perder. Medido em 18-26/09 (~8 dias de transcritos, tool_use contado por BLOCO):
#   Bash/Read/Edit/Write/Grep/ToolSearch: em praticamente toda sessão;
#   Monitor (dog 20, wa-worker 10, gate-reviewer 13), TaskStop (22/21/23), ScheduleWakeup (3/1/3), Skill (77/50/6): TODOS os papéis medidos
#   usam. Monitor é a forma sancionada de esperar uma suíte longa (foreground `sleep` é bloqueado); TaskStop encerra o que o Monitor/bg deixou.
NEVER_DENY_ALL = {"Bash", "Read", "Edit", "Write", "Grep", "Glob", "ToolSearch", "Monitor", "TaskStop", "ScheduleWakeup", "Skill"}
# tools que só os construtores (dog/wa-worker/ps-worker) usam — dog 8 chamadas, wa-worker 15; o revisor mediu 0, então só ele pode perdê-las
NEVER_DENY_BUILDERS = {"Agent"}

RE_CORE = re.compile(r"^\{\{/\* td:core:(?P<id>[a-z0-9-]+) \*/ -\}\}$")
RE_BEGIN = re.compile(r"^\{\{ if (?P<cond>.+?) -\}\}\{\{/\* td:(?P<id>[a-z0-9-]+) \*/ -\}\}$")
RE_END = re.compile(r"^\{\{ end -\}\}$")


def load_manifest():
    with open(MANIFEST, encoding="utf-8") as fh:
        return json.load(fh)


def _subst(s, paths):
    return s.format(**paths)


# ----------------------------------------------------------------------------- overlays
def _subst_deep(obj, paths):
    """{chave} -> caminho em toda string do objeto. Por replace (não str.format): o comando do hook tem `$P`/aspas e nenhum outro
    par de chaves, mas o manifesto não deve quebrar no dia em que tiver."""
    if isinstance(obj, str):
        for k, v in paths.items():
            obj = obj.replace("{" + k + "}", v)
        return obj
    if isinstance(obj, list):
        return [_subst_deep(x, paths) for x in obj]
    if isinstance(obj, dict):
        return {k: _subst_deep(v, paths) for k, v in obj.items()}
    return obj


GUARD_HOOK_MARKER = "home-scan-guard"     # ga-02cqk4: todo overlay de papel TEM que carregar este hook (ver check_overlays)


def overlay_for(m, role):
    """settings.json (dict, ordem de chaves fixa) do papel `role`."""
    r = m["roles"][role]
    with open(OVERLAYS / m["base_overlay"] / ".claude" / "settings.json", encoding="utf-8") as fh:
        base = json.load(fh)
    deny = list(base.get("permissions", {}).get("deny", []))
    for t in sorted(set(m["common"]["deny_tools"]) | set(r.get("deny_tools_extra", []))):
        if t not in deny:
            deny.append(t)
    out = {"permissions": {"deny": deny}}
    for k in ("remoteControlAtStartup", "env"):
        if k in base:
            out[k] = base[k]
    if m["common"].get("hooks"):
        out["hooks"] = _subst_deep(m["common"]["hooks"], m["paths"])
    out["autoMemoryEnabled"] = bool(r.get("auto_memory", m["common"]["auto_memory"]))
    out["claudeMdExcludes"] = [_subst(p, m["paths"]) for p in m["common"]["claude_md_excludes"]]
    sk = r.get("skills")
    if sk:
        keep = set(sk["keep"])
        out["skillOverrides"] = {n: sk["mode"] for n in sorted(m["skills_universe"]) if n not in keep}
    if r.get("plugins_off"):
        out["enabledPlugins"] = {p: False for p in r["plugins_off"]}
    return out


def dump_json(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def overlay_path(m, role):
    return OVERLAYS / m["roles"][role]["overlay"] / ".claude" / "settings.json"


def cmd_build(m):
    for role in m["roles"]:
        p = overlay_path(m, role)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(dump_json(overlay_for(m, role)), encoding="utf-8")
        print(f"wrote {p.relative_to(ASSETS.parent.parent)}")
    print("LEMBRETE: .gitignore ignora `.claude/` — overlay NOVO precisa de `git add -f <arquivo>` (o selftest reprova se ficar de fora).")
    return 0


# ----------------------------------------------------------------------------- fragment
def guard_cond(roles, show_unset=True):
    """Condição Go-template. show_unset=True (padrão): agente SEM TD_ROLE recebe a seção (fail-open, byte-idêntico ao de antes) OU o papel
    está na lista. show_unset=False: SÓ os papéis listados — para texto que substitui o que o papel perdeu ao excluir o CLAUDE.md (um agente
    sem TD_ROLE ainda carrega o CLAUDE.md, então receberia a regra em duplicata)."""
    eqs = [f'(eq .TD_ROLE "{r}")' for r in sorted(roles)]
    if show_unset:
        return "not .TD_ROLE" if not eqs else "or (not .TD_ROLE) " + " ".join(eqs)
    if not eqs:
        raise ValueError("seção com show_unset=false precisa de ao menos um papel")
    return eqs[0][1:-1] if len(eqs) == 1 else "or " + " ".join(eqs)


def receives(guarded_entry, role):
    """O papel `role` (None = agente sem TD_ROLE) recebe esta seção guardada?"""
    if role is None:
        return guarded_entry.get("show_unset", True)
    return role in guarded_entry["roles"]


def parse_fragment(text):
    """-> blocks: lista de dict(id, cond|None, lines[], line). Falha alto se sobrar texto fora de bloco marcado."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]  # o \n final do arquivo
    if not lines or lines[0] != '{{ define "town-deltas" }}':
        raise ValueError('fragment: 1ª linha deve ser {{ define "town-deltas" }} (o gate depende disso — story-ga-1xnfx)')
    if lines[-1] != "{{ end }}":
        raise ValueError("fragment: última linha deve ser {{ end }} (o gate depende disso — story-ga-1xnfx)")
    inner = lines[1:-1]
    blocks, cur = [], None
    for n, ln in enumerate(inner, start=2):
        mc, mb = RE_CORE.match(ln), RE_BEGIN.match(ln)
        if mc or mb:
            if cur is not None and cur["cond"] is not None and not cur.get("closed"):
                raise ValueError(f"fragment L{n}: bloco guardado '{cur['id']}' não foi fechado com {{{{ end -}}}} antes do próximo")
            cur = {"id": (mc or mb).group("id"), "cond": mb.group("cond") if mb else None, "lines": [], "line": n}
            blocks.append(cur)
        elif RE_END.match(ln):
            if cur is None or cur["cond"] is None or cur.get("closed"):
                raise ValueError(f"fragment L{n}: '{{{{ end -}}}}' sem guarda aberta")
            cur["closed"] = True
        else:
            if cur is None or cur.get("closed"):
                raise ValueError(f"fragment L{n}: texto fora de qualquer bloco marcado ({ln[:60]!r})")
            cur["lines"].append(ln)
    if cur is not None and cur["cond"] is not None and not cur.get("closed"):
        raise ValueError(f"fragment: bloco guardado '{cur['id']}' sem {{{{ end -}}}}")
    return blocks


def role_text(blocks, m, role):
    """Texto ESPERADO do fragment para `role` (None = agente sem TD_ROLE => tudo). Sem nenhum template dentro."""
    guarded = m["doctrine"]["guarded"]
    out = []
    for b in blocks:
        if b["cond"] is not None and not receives(guarded[b["id"]], role):
            continue
        out.append("\n".join(b["lines"]) + "\n")
    return '{{ define "town-deltas" }}\n' + "".join(out) + "{{ end }}\n"


def check_fragment(m):
    errs = []
    try:
        blocks = parse_fragment(FRAGMENT.read_text(encoding="utf-8"))
    except (ValueError, OSError) as e:
        return [f"fragment: {e}"], []
    core = set(m["doctrine"]["core"])
    guarded = m["doctrine"]["guarded"]
    seen = {}
    for b in blocks:
        if b["id"] in seen:
            errs.append(f"fragment: id de seção repetido '{b['id']}' (L{seen[b['id']]} e L{b['line']})")
        seen[b["id"]] = b["line"]
        if b["cond"] is None:
            if b["id"] not in core:
                errs.append(f"fragment: seção core '{b['id']}' (L{b['line']}) não está em doctrine.core do manifesto")
        else:
            if b["id"] not in guarded:
                errs.append(f"fragment: seção guardada '{b['id']}' (L{b['line']}) não está em doctrine.guarded do manifesto")
            else:
                want = guard_cond(guarded[b["id"]]["roles"], guarded[b["id"]].get("show_unset", True))
                if b["cond"] != want:
                    errs.append(f"fragment: guarda de '{b['id']}' (L{b['line']}) diverge do manifesto.\n    no fragment: {b['cond']}\n    esperado   : {want}")
    for i in sorted(core):
        if i not in seen:
            errs.append(f"manifesto: seção core '{i}' não existe no fragment")
    for i in sorted(guarded):
        if i not in seen:
            errs.append(f"manifesto: seção guardada '{i}' não existe no fragment")
    for r in {r for g in guarded.values() for r in g["roles"]}:
        if r not in {x["td_role"] for x in m["roles"].values()}:
            errs.append(f"manifesto: papel '{r}' citado em doctrine.guarded não é td_role de nenhum papel")
    # todo papel cujo overlay EXCLUI o CLAUDE.md perdeu as regras que só viviam lá: ou recebe o carry-over ou está isento com motivo
    carry = set(guarded.get("claudemd-carryover", {}).get("roles", []))
    exempt = set(m["doctrine"].get("carryover_exempt_roles", {}))
    for role_key, r in m["roles"].items():
        if m["common"]["claude_md_excludes"] and r["td_role"] not in carry and r["td_role"] not in exempt:
            errs.append(f"papel '{r['td_role']}' tem o CLAUDE.md excluído mas não recebe 'claudemd-carryover' nem está em doctrine.carryover_exempt_roles")
    # núcleo obrigatório: cada sentinela tem que estar em bloco NÃO guardado
    core_text = "\n".join("\n".join(b["lines"]) for b in blocks if b["cond"] is None)
    for name, needle in m["doctrine"]["core_sentinels"].items():
        if needle not in core_text:
            errs.append(f"NÚCLEO: sentinela '{name}' não está em nenhum bloco core (não-guardado) do fragment: {needle!r}")
    return errs, blocks


# ----------------------------------------------------------------------------- check
def check_guard_hook(role, cfg):
    """ga-02cqk4: o hook do home-scan-guard existe, na forma que o motor não atropela. Checagem INDEPENDENTE da igualdade com o
    manifesto: se alguém tira o hook do manifesto E dos overlays, o `check` de igualdade passa calado e o guard some."""
    errs = []
    hooks = cfg.get("hooks")
    entries = hooks.get("PreToolUse") if isinstance(hooks, dict) else None
    # um `hooks` que não é objeto (mão pesada num overlay) é "não sei ler" = o mesmo erro de "sumiu", nunca uma exceção do check
    entries = entries if isinstance(entries, list) else []
    mine = [e for e in entries if isinstance(e, dict) and isinstance(e.get("hooks"), list)
            and any(GUARD_HOOK_MARKER in (h.get("command") or "") for h in e["hooks"] if isinstance(h, dict))]
    if not mine:
        return [f"overlay '{role}': perdeu o hook PreToolUse do home-scan-guard (ga-02cqk4) — sessão de pool voltaria a poder varrer o $HOME e disparar o prompt do TCC"]
    for e in mine:
        if e.get("matcher") != "^Bash$":
            errs.append(f"overlay '{role}': hook do home-scan-guard com matcher {e.get('matcher')!r}; tem que ser '^Bash$' — o motor mescla por identidade de "
                        "matcher, então 'Bash' SUBSTITUIRIA a entrada Bash do workdir (apagando os hooks dangerous-command) e um padrão de comando no matcher nunca dispara (ga-7j1yu)")
        for h in e["hooks"]:
            if isinstance(h, dict) and GUARD_HOOK_MARKER in (h.get("command") or "") and "if" in h:
                errs.append(f"overlay '{role}': hook do home-scan-guard com campo 'if' — o guard não usa (o prefiltro dele já é barato e um glob não enxerga dentro de for/do/done)")
    return errs


def check_overlays(m):
    errs = []
    with open(OVERLAYS / m["base_overlay"] / ".claude" / "settings.json", encoding="utf-8") as fh:
        base = json.load(fh)
    base_deny = base.get("permissions", {}).get("deny", [])
    for role, r in m["roles"].items():
        p = overlay_path(m, role)
        want = dump_json(overlay_for(m, role))
        if not p.exists():
            errs.append(f"overlay '{role}': {p} não existe (rode: pool-preamble-build.py build)")
            continue
        got = p.read_text(encoding="utf-8")
        if got != want:
            errs.append(f"overlay '{role}': {p.name} commitado DIVERGE do gerado pelo manifesto (rode: pool-preamble-build.py build)")
        cfg = json.loads(got)
        deny = cfg.get("permissions", {}).get("deny", [])
        denied = {d for d in deny if re.fullmatch(r"[A-Za-z]+", d)}
        bad = denied & NEVER_DENY_ALL
        if bad:
            errs.append(f"overlay '{role}': nega tool essencial {sorted(bad)}")
        if r["td_role"] != "reviewer":
            bad = denied & NEVER_DENY_BUILDERS
            if bad:
                errs.append(f"overlay '{role}': construtor nega tool que usa de verdade {sorted(bad)}")
        for d in base_deny:
            if d not in deny:
                errs.append(f"overlay '{role}': perdeu o deny do overlay base '{d}'")
        if cfg.get("remoteControlAtStartup") is not False:
            errs.append(f"overlay '{role}': remoteControlAtStartup tem que ser false (wa-cy6we)")
        errs.extend(check_guard_hook(role, cfg))
        if r["td_role"] in m["common"].get("mayor_memory_roles", []) and cfg.get("autoMemoryEnabled") is not False:
            errs.append(f"overlay '{role}': autoMemoryEnabled tem que ser false (o índice de memória desse papel é o do Mayor)")
        if not isinstance(cfg.get("autoMemoryEnabled"), bool):
            errs.append(f"overlay '{role}': autoMemoryEnabled tem que estar EXPLÍCITO (true/false) — a decisão fica visível no arquivo")
        ex = cfg.get("claudeMdExcludes", [])
        for need in ("/.claude/CLAUDE.md", "/CLAUDE.md", "/AGENTS.md"):
            if not any(e.endswith(need) for e in ex):
                errs.append(f"overlay '{role}': claudeMdExcludes sem *{need} (AGENTS.md é o fallback quando CLAUDE.md sai)")
        sk = r.get("skills")
        if sk:
            missing = [k for k in sk["keep"] if k not in m["skills_universe"]]
            if missing:
                errs.append(f"papel '{role}': skills.keep cita skill fora do universo {missing}")
    return errs


# ----------------------------------------------------------------------------- por tarefa (ga-aijm2v.7)
def eligible_for_role(m, blocks, role):
    """Ids das seções que o Jev PODE dispensar para `role`, na ordem do fragment: elegíveis por tarefa E entregues a esse papel.
    Só esta lista é perguntada ao Jev e só ela pode ser cortada; o resto (núcleo, never_cut, seção não classificada) entra sempre."""
    guarded = m["doctrine"]["guarded"]
    eligible = (m["doctrine"].get("per_task") or {}).get("eligible", {})
    return [b["id"] for b in blocks if b["id"] in eligible and b["id"] in guarded and receives(guarded[b["id"]], role)]


def _is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _compiles(pattern):
    try:
        re.compile(pattern, re.I)
        return True
    except (re.error, TypeError):
        return False


def check_per_task(m, blocks):
    """-> (erros, avisos). Erro = o manifesto por tarefa é incoerente e o corte poderia atingir o que não devia. Aviso = seção guardada
    que ninguém classificou (o que é seguro: não classificada = NÃO elegível = entra sempre)."""
    pt = m["doctrine"].get("per_task")
    if not isinstance(pt, dict):
        return ["manifesto: doctrine.per_task ausente ou inválido (o preâmbulo por tarefa não tem política)"], []
    errs, adv = [], []
    guarded, core = m["doctrine"]["guarded"], set(m["doctrine"]["core"])
    pool = {r["td_role"] for r in m["roles"].values()}
    if not (isinstance(pt.get("experiment"), str) and pt["experiment"].strip()):
        errs.append("per_task.experiment: string não vazia")
    thr = pt.get("threshold")
    if not (_is_num(thr) and 0 < thr < 1):
        errs.append(f"per_task.threshold={thr!r}: precisa estar em (0,1) — 0 nunca corta, 1 corta tudo que o Jev não jura ser necessário")
    if not (isinstance(pt.get("max_questions_per_call"), int) and not isinstance(pt["max_questions_per_call"], bool) and pt["max_questions_per_call"] >= 1):
        errs.append("per_task.max_questions_per_call: inteiro >= 1")
    if not (_is_num(pt.get("chars_per_token")) and pt["chars_per_token"] > 0):
        errs.append("per_task.chars_per_token: número > 0")
    eligible, never = pt.get("eligible"), pt.get("never_cut")
    if not isinstance(eligible, dict) or not eligible:
        errs.append("per_task.eligible: dict não vazio")
        eligible = {}
    if not isinstance(never, dict):
        errs.append("per_task.never_cut: dict (id -> motivo)")
        never = {}
    for sid, e in eligible.items():
        if sid not in guarded:
            errs.append(f"per_task.eligible '{sid}': não é seção GUARDADA (o núcleo e ids inexistentes nunca são elegíveis)")
            continue
        if sid in core:
            errs.append(f"per_task.eligible '{sid}': está no núcleo")
        if sid in never:
            errs.append(f"per_task.eligible '{sid}': também está em never_cut (ou é elegível ou nunca corta)")
        if not any(r in pool for r in guarded[sid]["roles"]):
            errs.append(f"per_task.eligible '{sid}': nenhum papel de pool a recebe — a pergunta nunca seria feita")
        for k in ("instructions", "true", "false"):
            if not (isinstance(e.get(k), str) and e[k].strip()):
                errs.append(f"per_task.eligible '{sid}'.{k}: string não vazia (é a pergunta feita ao Jev)")
        terms = e.get("cite_terms")
        if not (isinstance(terms, list) and terms and all(isinstance(t, str) and t.strip() for t in terms)):
            errs.append(f"per_task.eligible '{sid}'.cite_terms: lista não vazia de strings (detecta reprovação que cita a seção cortada)")
    for sid, why in never.items():
        if sid not in guarded:
            errs.append(f"per_task.never_cut '{sid}': não é seção guardada")
        if not (isinstance(why, str) and why.strip()):
            errs.append(f"per_task.never_cut '{sid}': precisa de um motivo escrito")
    for sid, rule in (pt.get("must_include") or {}).items():
        if sid == "_doc":
            continue
        if sid not in eligible:
            errs.append(f"per_task.must_include '{sid}': não é elegível (piso estrutural de seção que nunca é cortada é inútil)")
            continue
        if not isinstance(rule, dict) or not (set(rule) & {"issue_types", "metadata_keys", "labels", "text_regex"}):
            errs.append(f"per_task.must_include '{sid}': regra vazia")
            continue
        for k in ("issue_types", "metadata_keys", "labels"):
            if k in rule and not (isinstance(rule[k], list) and all(isinstance(x, str) and x for x in rule[k])):
                errs.append(f"per_task.must_include '{sid}'.{k}: lista de strings")
        if "text_regex" in rule and not (isinstance(rule["text_regex"], str) and _compiles(rule["text_regex"])):
            errs.append(f"per_task.must_include '{sid}'.text_regex: regex inválida")
    markers = pt.get("injection_markers")
    if not (isinstance(markers, list) and markers):
        errs.append("per_task.injection_markers: lista não vazia (texto de tarefa é conteúdo de fora e pode ser hostil)")
    else:
        for i, pat in enumerate(markers):
            if not (isinstance(pat, str) and _compiles(pat)):
                errs.append(f"per_task.injection_markers[{i}]: regex inválida")
    for b in blocks:
        if b["cond"] is None or b["id"] in eligible or b["id"] in never:
            continue
        if any(receives(guarded[b["id"]], r) for r in pool):
            adv.append(f"seção guardada '{b['id']}' não está em per_task.eligible nem never_cut — fica FORA do corte por tarefa (entra sempre); classifique-a")
    return errs, adv


def cmd_per_task(m):
    """Por papel: o que o Jev pode dispensar e o teto de economia (se ele dispensasse TUDO que pode)."""
    errs, blocks = check_fragment(m)
    if not blocks:
        print("fragment ilegível:", *errs, sep="\n  ")
        return 1
    pt = m["doctrine"]["per_task"]
    size = {b["id"]: len("\n".join(b["lines"])) + 1 for b in blocks}
    cpt = pt["chars_per_token"]
    print(f"limiar P(precisa) < {pt['threshold']} => dispensa; qualquer dúvida => a seção entra\n")
    for r in m["roles"].values():
        role = r["td_role"]
        ids = eligible_for_role(m, blocks, role)
        got = sum(size[b["id"]] for b in blocks if b["cond"] is None or receives(m["doctrine"]["guarded"][b["id"]], role))
        top = sum(size[i] for i in ids)
        print(f"== {role}: {len(ids)} elegíveis — teto {top:,} chars ≈ {int(top / cpt):,} tokens de {got:,} chars entregues ({top * 100 // max(got, 1)}%)")
        for i in ids:
            print(f"   {i:26s} {size[i]:>6,} chars ≈ {int(size[i] / cpt):>5,} tok")
    print("\nnunca corta (guardadas):", ", ".join(sorted(pt["never_cut"])))
    return 0


def cmd_check(m):
    errs = check_overlays(m)
    ferrs, blocks = check_fragment(m)
    errs += ferrs
    adv = []
    if blocks:
        perrs, adv = check_per_task(m, blocks)
        errs += perrs
    if errs:
        print("pool-preamble-build check: FALHOU")
        for e in errs:
            print("  ✗", e)
        return 1
    print("pool-preamble-build check: OK (overlays == manifesto; guardas == manifesto; núcleo presente; política por tarefa coerente)")
    for a in adv:
        print("  aviso:", a)
    return 0


def cmd_sections(m):
    errs, blocks = check_fragment(m)
    if not blocks:
        print("fragment ilegível:", *errs, sep="\n  ")
        return 1
    size = {b["id"]: len("\n".join(b["lines"])) + 1 for b in blocks}
    total_all = sum(size.values())
    roles = ["(sem TD_ROLE: Mayor/crews/witness/...)"] + [r["td_role"] for r in m["roles"].values()]
    print(f"fragment town-deltas: {total_all:,} chars em {len(blocks)} seções\n")
    for rl in roles:
        role = None if rl.startswith("(sem") else rl
        got = [b for b in blocks if b["cond"] is None or receives(m["doctrine"]["guarded"][b["id"]], role)]
        hid = [b for b in blocks if b not in got]
        chars = sum(size[b["id"]] for b in got)
        print(f"== {rl}: recebe {len(got)}/{len(blocks)} seções, {chars:,} chars ({chars * 100 // total_all}%)")
        print("   entrega :", ", ".join(b["id"] for b in got))
        print("   NÃO recebe:", ", ".join(b["id"] for b in hid) or "-")
    return 0


def cmd_new_skills(m):
    known = set(m["skills_universe"])
    home = Path(m["paths"]["home"])
    found = set()
    for d in (home / ".claude" / "skills",):
        if d.is_dir():
            for e in d.iterdir():
                if e.is_dir() and (e / "SKILL.md").exists():
                    found.add(e.name)
    cmd = home / ".claude" / "commands"
    if cmd.is_dir():
        for e in cmd.glob("*.md"):
            found.add(e.stem)
    new = sorted(found - known)
    print(f"skills no disco: {len(found)}; conhecidas pelo manifesto: {len(known)}; NOVAS (aparecem na listagem inteira até serem classificadas): {len(new)}")
    for n in new:
        print("  +", n)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["build", "check", "sections", "per-task", "new-skills"])
    a = ap.parse_args(argv)
    m = load_manifest()
    return {"build": cmd_build, "check": cmd_check, "sections": cmd_sections, "per-task": cmd_per_task, "new-skills": cmd_new_skills}[a.cmd](m)


if __name__ == "__main__":
    sys.exit(main())
