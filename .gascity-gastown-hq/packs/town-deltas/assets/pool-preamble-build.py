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


def cmd_check(m):
    errs = check_overlays(m)
    ferrs, _ = check_fragment(m)
    errs += ferrs
    if errs:
        print("pool-preamble-build check: FALHOU")
        for e in errs:
            print("  ✗", e)
        return 1
    print("pool-preamble-build check: OK (overlays == manifesto; guardas == manifesto; núcleo presente)")
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
    ap.add_argument("cmd", choices=["build", "check", "sections", "new-skills"])
    a = ap.parse_args(argv)
    m = load_manifest()
    return {"build": cmd_build, "check": cmd_check, "sections": cmd_sections, "new-skills": cmd_new_skills}[a.cmd](m)


if __name__ == "__main__":
    sys.exit(main())
