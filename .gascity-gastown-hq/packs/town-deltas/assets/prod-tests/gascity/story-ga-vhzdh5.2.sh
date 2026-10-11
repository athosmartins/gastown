#!/usr/bin/env bash
# prod-tests/gascity/story-ga-vhzdh5.2.sh — prod test for ga-vhzdh5.2: the two doc rules (Athos, 2026-10-11) now reach the AGENT
# PROMPT, and the repo files that carried 568 lines of instructions obey them.
#   1. every doc > 300 chars starts with `## Contents`;
#   2. CLAUDE.md / CLAUDE.local.md / AGENTS.md have <= 200 lines.
# What this proves, each as its own check (a green run means every one passed; none is skipped silently):
#   * the town-deltas fragment carries the `doc-rules` block (<= 6 lines), registered in the pool manifest, and a LIVE `gc prime
#     --strict` of a wa-worker and of a crew (no TD_ROLE) renders it — while the source-only Contents index renders nothing;
#   * AGENTS.md has <= 200 lines, a Contents that lists every `##` title, the three rules non-Claude agents depend on, and EVERY
#     line of the pre-change file (pinned commit) is still present in AGENTS.md or in the two destination docs ("no rule lost");
#   * the destination docs, the townroot template and the scope-check command each start with a Contents, and the pointers resolve.
# CITY / REPO can be overridden to run this against a worktree before merge; the pinned base is read from BASE_GIT (any clone that
# has the commit). Called by run.sh after deploy (STORY_ID=ga-vhzdh5.2). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
REPO="${REPO:-$(cd "$CITY/.." && pwd)}"
BASE_GIT="${BASE_GIT:-$REPO}"
BASE_SHA="${BASE_SHA:-02da0eea8}"
GC="${GC:-gc}"

log()  { echo "[prod-test:gascity ga-vhzdh5.2] $*"; }
fail() { echo "[prod-test:gascity ga-vhzdh5.2] FAIL: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH"
# a prompt that cannot be rendered is not a prompt that was checked: no gc => no pass
command -v "$GC" >/dev/null 2>&1 || fail "gc not on PATH ('$GC') — the rendered prompt cannot be read; set GC=<path>"

python3 -I - "$CITY" "$REPO" "$BASE_GIT" "$BASE_SHA" "$GC" <<'PY'
import json, os, re, subprocess, sys, tempfile
from pathlib import Path

city, repo, base_git, base_sha, gc = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
TAG = "[prod-test:gascity ga-vhzdh5.2]"
errs = []


def ok(msg):
    print(f"{TAG} {msg} ✓")


def bad(msg):
    errs.append(msg)
    print(f"{TAG} FAIL: {msg}", file=sys.stderr)


def read(p):
    # falhou → bad() + None: a file that cannot be read is a FAIL, never an empty text that "has no violations"
    try:
        return Path(p).read_text(encoding="utf-8")
    except OSError as e:
        bad(f"cannot read {p}: {e}")
        return None


def h2_titles(text):
    """`## ` titles outside ``` fences, in order."""
    out, fenced = [], False
    for ln in text.split("\n"):
        if ln.lstrip().startswith("```"):
            fenced = not fenced
        elif not fenced and ln.startswith("## "):
            out.append(ln[3:].strip())
    return out


def contents_section(text):
    """text of the `## Contents` section (up to the next `## `), or None when there is none."""
    lines, grab, fenced = [], False, False
    for ln in text.split("\n"):
        if ln.lstrip().startswith("```"):
            fenced = not fenced
        if not fenced and ln.startswith("## "):
            if grab:
                break
            grab = ln[3:].strip() == "Contents"
            continue
        if grab:
            lines.append(ln)
    return "\n".join(lines) if (grab or lines) else None


def blocks_before_first_h2(text):
    """Blank-line-separated text/code blocks between the top of the doc and the first `## ` (frontmatter, `#` titles, HTML comment
    lines and blank lines do not count) — the same count slice ga-vhzdh5.1's `contents-late` uses (<= 1 intro paragraph allowed)."""
    lines = text.split("\n")
    start = 0
    if lines and lines[0].strip() == "---":
        close = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
        # sem fechamento → não é frontmatter: nada é pulado (todas as linhas contam como corpo)
        start = close + 1 if close is not None else 0
    blocks, in_block, fenced = 0, False, False
    for ln in lines[start:]:
        s = ln.strip()
        if fenced:
            eligible, fenced = True, not s.startswith("```")
        elif ln.startswith("## "):
            break
        elif s.startswith("```"):
            eligible, fenced = True, True
        elif not s or re.match(r"#{1,2}\s", ln) or (s.startswith("<!--") and s.endswith("-->")):
            eligible = False
        else:
            eligible = True
        if eligible and not in_block:
            blocks += 1
        in_block = eligible
    return blocks


def check_contents(label, text, every_title=True):
    """Slice ga-vhzdh5.1 rule (b): `## Contents` is the FIRST `##`, at most ONE intro block sits between the title and it, and
    (every_title) every other `##` title appears in its text. A doc without it is a FAIL — not 'nothing to list'."""
    if text is None:
        return
    titles = h2_titles(text)
    if not titles or titles[0] != "Contents":
        bad(f"{label}: first `## ` section is {titles[0]!r}, not 'Contents'" if titles else f"{label}: no `## Contents` section")
        return
    intro = blocks_before_first_h2(text)
    if intro > 1:
        bad(f"{label}: `## Contents` must follow the title (<= 1 intro paragraph before it); found {intro} blocks before it")
        return
    body = contents_section(text) or ""
    if not body.strip():
        bad(f"{label}: `## Contents` is empty")
        return
    missing = [t for t in titles[1:] if t not in body] if every_title else []
    if missing:
        bad(f"{label}: Contents does not list: {missing}")
        return
    ok(f"{label}: Contents first, lists {len(titles) - 1} other `##` title(s)")


# ── 1. town-deltas fragment: doc-rules block + source index ────────────────────────────────────────────────────────────────────
frag_p = city / "packs/town-deltas/template-fragments/town-deltas.template.md"
frag = read(frag_p)
if frag is not None:
    lines = frag.split("\n")
    trimmed = frag.rstrip("\n").split("\n")
    if trimmed[0] != '{{ define "town-deltas" }}' or trimmed[-1] != "{{ end }}":
        bad("fragment: define/end wrapper moved or missing")
    else:
        ok("fragment: define/end wrapper intact")
    idx = [i for i, ln in enumerate(lines) if ln == "{{/* td:core:doc-rules */ -}}"]
    if len(idx) != 1:
        bad(f"fragment: expected exactly one td:core:doc-rules marker, found {len(idx)}")
    else:
        block = []
        for ln in lines[idx[0] + 1:]:
            if ln.startswith("{{/*") or ln.startswith("{{ if") or ln.startswith("{{ end"):
                break
            block.append(ln)
        text = "\n".join(block)
        nonblank = [b for b in block if b.strip()]
        if len(nonblank) > 6:
            bad(f"fragment: doc-rules block has {len(nonblank)} non-blank lines (> 6)")
        for needle in ("> 300 caracteres", "## Contents", "CLAUDE.md, CLAUDE.local.md e AGENTS.md", "≤ 200 linhas", "contando o que importam", "ponteiro"):
            if needle not in text:
                bad(f"fragment: doc-rules block lost {needle!r}")
        if not any(e.startswith("fragment: doc-rules") for e in errs):
            ok(f"fragment: doc-rules block present, {len(nonblank)} line(s), both rules stated")
    # the fragment is itself a doc > 300 chars: its `## Contents` lives in a template comment BEFORE the first marker
    first_marker = next((i for i, ln in enumerate(lines) if ln.startswith("{{/* td:")), None)
    head = "\n".join(lines[1:first_marker]) if first_marker else ""
    if "\n## Contents\n" not in "\n" + head + "\n":
        bad("fragment: no `## Contents` in the header comment before the first section marker")
    else:
        named = set(re.findall(r"[a-z][a-z0-9-]+", contents_section(head) or ""))
        real = set()
        for ln in lines:
            m = re.search(r"\{\{/\* td:(?:core:)?([a-z0-9-]+) \*/ -\}\}$", ln)
            if m:
                real.add(m.group(1))
        if not real or real - named:
            bad(f"fragment: Contents index does not name section(s): {sorted(real - named)}")
        else:
            ok(f"fragment: Contents index names all {len(real)} sections")

# ── 2. manifest registers the section, and the repo's own preamble guard agrees ────────────────────────────────────────────────
mp = city / "packs/town-deltas/assets/claude-overlays/pool-roles.json"
mtxt = read(mp)
if mtxt is not None:
    try:
        doc = json.loads(mtxt)["doctrine"]
        if "doc-rules" not in doc["core"]:
            bad("manifest: doctrine.core does not list 'doc-rules' (every role must receive it)")
        elif "doc-rules" not in doc["core_sentinels"]:
            bad("manifest: doctrine.core_sentinels has no 'doc-rules' sentinel (a deleted block would go unnoticed)")
        else:
            ok("manifest: doc-rules is core and has a sentinel")
    except (ValueError, KeyError) as e:
        bad(f"manifest unreadable: {e!r}")
r = subprocess.run([sys.executable, "-I", str(city / "packs/town-deltas/assets/pool-preamble-build.py"), "check"],
                   capture_output=True, text=True, timeout=120)
if r.returncode == 0:
    ok("pool-preamble-build.py check passes")
else:
    bad("pool-preamble-build.py check failed: " + (r.stdout + r.stderr).strip()[:400])

# ── 3. LIVE render: a wa-worker and a crew (no TD_ROLE) get the block; the hidden index does not leak ──────────────────────────
CITY_TOML = ('[workspace]\nprovider = "claude"\nglobal_fragments = ["town-deltas"]\n\n[providers]\n[providers.claude]\nbase = "builtin:claude"\n\n'
             '[imports]\n[imports.town-deltas]\nsource = "packs/town-deltas"\n')
with tempfile.TemporaryDirectory(prefix="ga-vhzdh5.2-") as tmp:
    root = Path(tmp) / "city"
    (root / ".gc").mkdir(parents=True)
    (root / "gchome").mkdir()
    (root / "pack.toml").write_text('[pack]\nname = "scratch"\nschema = 2\n')
    (root / "city.toml").write_text(CITY_TOML)
    os.symlink(city / "packs", root / "packs")
    cases = [("p-wa-worker", "wa-worker"), ("p-crew", None)]
    for name, role in cases:
        d = root / "agents" / name
        d.mkdir(parents=True)
        env = f'env = {{ TD_ROLE = "{role}" }}\n' if role else ""
        (d / "agent.toml").write_text('max_active_sessions = 1\nmin_active_sessions = 0\nscope = "city"\n' + env)
        (d / "prompt.template.md").write_text(f"# {name}\nBASE-BODY\n")
    clean = {k: v for k, v in os.environ.items() if not k.startswith("GC_")}
    clean["GC_HOME"] = str(root / "gchome")
    for name, role in cases:
        out = None
        for _ in (1, 2):  # 1 retry: gc can be slow under load; a persistent error is a FAIL
            try:
                p = subprocess.run([gc, "--city", str(root), "prime", "--strict", name], cwd=root, env=clean,
                                   capture_output=True, text=True, timeout=120)
            except subprocess.TimeoutExpired:
                continue
            if p.returncode == 0:
                out = p.stdout
                break
        label = f"gc prime --strict {name} (TD_ROLE={role})"
        if out is None:
            bad(f"{label}: could not render (rc/timeout) — the prompt was not checked")
        elif "### Docs — 2 regras do Athos" not in out or "≤ 200 linhas" not in out:
            bad(f"{label}: rendered prompt does NOT carry the doc-rules block")
        elif "Índice do arquivo-fonte" in out or "worktree-commit-hygiene ·" in out:
            bad(f"{label}: the source-only Contents index leaked into the rendered prompt")
        else:
            ok(f"{label}: block present, index not leaked ({len(out):,} chars)")

# ── 4. AGENTS.md: <= 200 lines, Contents, the three rules, pointers, and NO RULE LOST ──────────────────────────────────────────
ag_p = repo / "AGENTS.md"
ag = read(ag_p)
dest = {"deacon-role-scope.md": None, "agents-md-beads-gt-blocks.md": None}
for k in dest:
    dest[k] = read(city / "docs/runbooks" / k)
if ag is not None:
    n = len(ag.splitlines())
    if n > 200:
        bad(f"AGENTS.md has {n} lines (> 200)")
    elif any(ln.startswith("@") for ln in ag.splitlines()):
        bad("AGENTS.md has an @import line — the 200-line cap counts imports, which this test does not resolve")
    else:
        ok(f"AGENTS.md: {n} lines (<= 200)")
    check_contents("AGENTS.md", ag)
    for needle in ("REGRA Nº 1 — TODA pergunta ao Athos é MÚLTIPLA ESCOLHA", "REGRA Nº 2 — só pergunte PRODUTO/NEGÓCIO",
                   'Dispatch de pesquisa ("research-only") — proíba o CANAL', "Silent execution", "Never run `git -C <other-rig-or-crew-clone> <write-op>`"):
        if needle not in ag:
            bad(f"AGENTS.md lost load-bearing text: {needle!r}")
    for k in dest:
        if f"docs/runbooks/{k}" not in ag:
            bad(f"AGENTS.md has no pointer to docs/runbooks/{k}")
        elif dest[k] is not None:
            ok(f"AGENTS.md points at docs/runbooks/{k} (exists)")
    if all(v is not None for v in dest.values()):
        for k, v in dest.items():
            check_contents(f"docs/runbooks/{k}", v)
        # no rule lost: every non-blank line of the pinned pre-change AGENTS.md is in AGENTS.md or a destination doc
        g = subprocess.run(["git", "-C", base_git, "show", f"{base_sha}:AGENTS.md"], capture_output=True, text=True)
        if g.returncode != 0 or not g.stdout.strip():
            bad(f"cannot read the pre-change AGENTS.md ({base_sha}) from {base_git}: {g.stderr.strip()[:200]} — 'no rule lost' NOT verified")
        else:
            have = {ln.rstrip() for t in (ag, *dest.values()) for ln in t.split("\n")}
            lost = [(i, ln) for i, ln in enumerate(g.stdout.split("\n"), 1) if ln.strip() and ln.rstrip() not in have]
            # the only lines allowed to differ: the two intro sentences that were merged into one paragraph (their words are kept)
            allowed = {"See **CLAUDE.md** for complete agent context and instructions.",
                       "This file exists for compatibility with tools that look for AGENTS.md."}
            real_lost = [(i, ln) for i, ln in lost if ln.strip() not in allowed]
            merged = ("See **CLAUDE.md** for complete agent context and instructions." in ag
                      and "This file exists for compatibility with tools that look for AGENTS.md." in ag.replace("\n", " "))
            if real_lost:
                bad(f"{len(real_lost)} line(s) of the old AGENTS.md exist nowhere now, e.g. L{real_lost[0][0]}: {real_lost[0][1][:90]!r}")
            elif lost and not merged:
                bad("the two merged intro sentences of AGENTS.md were dropped")
            else:
                ok(f"no rule lost: all {sum(1 for ln in g.stdout.split(chr(10)) if ln.strip())} non-blank lines of {base_sha}:AGENTS.md survive")

# ── 5. townroot template + scope-check command ─────────────────────────────────────────────────────────────────────────────────
tr = read(repo / "internal/templates/townroot/claude.md")
check_contents("internal/templates/townroot/claude.md", tr)
if tr is not None:
    for h in ("## Dolt Server", "### Communication hygiene"):  # what internal/doctor/town_claude_md_check.go requires
        if h not in tr:
            bad(f"townroot template lost the heading the doctor check requires: {h!r}")
sc = read(repo / ".claude/commands/scope-check.md")
check_contents(".claude/commands/scope-check.md", sc)
if sc is not None:
    if "AGENTS.md → Role: Deacon → Scope Discipline Protocol" in sc or "AGENTS.md is the canonical store" in sc:
        bad("scope-check.md still points at the section that moved out of AGENTS.md")
    elif "docs/runbooks/deacon-role-scope.md" not in sc:
        bad("scope-check.md does not point at docs/runbooks/deacon-role-scope.md")
    else:
        ok("scope-check.md points at the new home of the deacon rules")

# ── 6. slice .1's lint, when it is deployed (explicit, never a silent skip) ────────────────────────────────────────────────────
lint = next((p for p in (repo / "scripts/doc-rules-lint.py", city / "scripts/doc-rules-lint.py") if p.is_file()), None)
if lint is None:
    print(f"{TAG} NOTE: scripts/doc-rules-lint.py (slice ga-vhzdh5.1) is not deployed — the structural checks above stand in for it")
else:
    touched = [repo / "AGENTS.md", city / "docs/runbooks/deacon-role-scope.md", city / "docs/runbooks/agents-md-beads-gt-blocks.md",
               repo / "internal/templates/townroot/claude.md", repo / ".claude/commands/scope-check.md",
               city / "packs/town-deltas/template-fragments/town-deltas.template.md"]
    r = subprocess.run([sys.executable, "-I", str(lint), "--check", *map(str, touched)], capture_output=True, text=True, timeout=120)
    if r.returncode == 0:
        ok("doc-rules-lint.py --check passes on every touched file")
    else:
        bad("doc-rules-lint.py --check failed: " + (r.stdout + r.stderr).strip()[:500])

sys.exit(1 if errs else 0)
PY
rc=$?
[ "$rc" -eq 0 ] || fail "one or more checks failed (python exit $rc) — see the FAIL lines above"
log "PASS"
exit 0
