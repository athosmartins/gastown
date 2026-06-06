#!/usr/bin/env bash
# skill-integrity-install.sh — Idempotent bootstrap for the skill-publish
# integrity mechanism (story ga-5lx). Safe to run repeatedly.
#
# It does three things, each idempotent:
#
#   1. BASELINE ADOPT — for every city skill currently published (gc skill list),
#      record its current canonical content digest into the manifest IF no entry
#      exists yet. This adopts the present, already-live canonical as the
#      official baseline so the auditor reports off-path=0 for skills that were
#      published before the manifest mechanism existed. Skills that already have
#      a manifest entry are left untouched (so a real off-path edit stays flagged).
#
#   2. INSTALL LAUNCHD — copy the periodic-auditor plist into ~/Library/LaunchAgents
#      and (re)bootstrap it so the drift=0 dashboard metric file stays fresh.
#
#   3. VERIFY — run the auditor once and print the result.
#
# This is the live bootstrap that a plain `git pull` deploy cannot perform
# (launchd registration + per-host baseline are not in the git tree). It is
# read-only with respect to skills/config and never runs gc reload, so it cannot
# drain crew.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="$(cd "$SELF_DIR/.." && pwd)"
GC="${GC:-gc}"
MANIFEST="${SKILL_MANIFEST:-$CITY/.gc/state/skill-manifest.json}"
PLIST_SRC="$CITY/packs/town-deltas/assets/skill-audit.plist"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_DST="$LAUNCH_AGENTS/com.gascity.skill-audit.plist"
LABEL="com.gascity.skill-audit"
NO_LAUNCHD="${SKILL_INTEGRITY_NO_LAUNCHD:-false}"

# shellcheck source=skill-lib.sh
source "$SELF_DIR/skill-lib.sh"

say() { echo "[skill-integrity-install] $*"; }

# install_plist <plist_src> <label> — idempotently copy a plist into
# ~/Library/LaunchAgents and (re)bootstrap + kickstart it. Safe to run
# repeatedly. Honors SKILL_INTEGRITY_NO_LAUNCHD=true (test/CI seam).
install_plist() {
    local src="$1" label="$2"
    local dst="$LAUNCH_AGENTS/$label.plist"
    if [[ "$NO_LAUNCHD" == "true" ]]; then
        say "Skipping launchd install for $label (SKILL_INTEGRITY_NO_LAUNCHD=true)."
        return 0
    fi
    if [[ ! -f "$src" ]]; then
        say "WARNING: plist source not found ($src) — skipping launchd install for $label."
        return 0
    fi
    mkdir -p "$LAUNCH_AGENTS"
    cp -f "$src" "$dst"
    say "Installed plist -> $dst"
    local uid; uid="$(id -u)"
    # bootout first (ignore failure if not loaded), then bootstrap. Idempotent.
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
    if launchctl bootstrap "gui/$uid" "$dst" >/dev/null 2>&1; then
        say "launchd bootstrap OK ($label)"
    else
        # Fall back to legacy load for older macOS.
        launchctl load -w "$dst" >/dev/null 2>&1 \
            && say "launchd load OK ($label, legacy)" \
            || say "WARNING: launchd registration failed for $label"
    fi
    launchctl kickstart "gui/$uid/$label" >/dev/null 2>&1 || true
}

# ── 1. Baseline adopt ─────────────────────────────────────────────────────────
say "Adopting current canonical as baseline for unmanaged skills..."
mkdir -p "$(dirname "$MANIFEST")"

# Build "name<TAB>canonical-dir" for source:"city" skills.
skills_tsv="$(
    "$GC" skill list --json --city "$CITY" 2>/dev/null | CITY="$CITY" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
city = os.environ["CITY"]
for e in data.get("entries", []):
    if e.get("source") != "city":
        continue
    name, path = e.get("name",""), e.get("path","")
    if not name or not path:
        continue
    d = os.path.dirname(path)
    if not os.path.isabs(d):
        d = os.path.join(city, d)
    print(f"{name}\t{d}")
'
)"

if [[ -n "$skills_tsv" ]]; then
    while IFS=$'\t' read -r name canon; do
        [[ -z "$name" ]] && continue
        [[ -d "$canon" ]] || { say "  skip $name (canonical missing: $canon)"; continue; }
        digest="$(skilllib_tree_digest "$canon")"
        MANIFEST="$MANIFEST" NAME="$name" DIGEST="$digest" CANON="$canon" python3 <<'PY'
import json, os, tempfile
path = os.environ["MANIFEST"]; name = os.environ["NAME"]
try:
    with open(path) as f:
        m = json.load(f)
        if not isinstance(m, dict): m = {}
except (FileNotFoundError, json.JSONDecodeError):
    m = {}
m.setdefault("schema_version", "1")
skills = m.setdefault("skills", {})
if name in skills:
    print(f"  keep   {name} (already has manifest entry)")
else:
    skills[name] = {
        "tree_digest": os.environ["DIGEST"],
        "deployed_at": "bootstrap",
        "deployed_by": "bootstrap-adopt",
        "source_dir":  os.environ["CANON"],
    }
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".skill-manifest.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(m, f, indent=2, sort_keys=True); f.write("\n")
    os.replace(tmp, path)
    print(f"  adopt  {name} -> {os.environ['DIGEST']}")
PY
    done <<< "$skills_tsv"
else
    say "  (no city skills found via gc skill list)"
fi

# ── 2. Install launchd ────────────────────────────────────────────────────────
# The skill-publish auditor (ga-5lx) — original purpose of this bootstrap.
install_plist "$PLIST_SRC" "$LABEL"
# The crew-hang detector (ga-khuz1) — like the auditor, its launchd registration
# is not in the git tree, so a plain `git pull` deploy cannot bring it live. This
# bootstrap (run by the gascity deploy_cmd) installs + loads it; story-delivery's
# daemon_restarts then kickstarts it after every deploy.
install_plist "$CITY/packs/town-deltas/assets/crew-hang-detector.plist" "com.gascity.crew-hang-detector"

# ── 3. Verify ─────────────────────────────────────────────────────────────────
say "Running auditor to verify..."
"$SELF_DIR/skill-audit.sh" || true
say "Done."
