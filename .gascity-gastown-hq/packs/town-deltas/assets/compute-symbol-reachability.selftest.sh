#!/usr/bin/env bash
# compute-symbol-reachability.selftest.sh (wa-th4b1)
#
# Proves compute_symbol_reachability.py against the three live cases the bead
# measured (see that script's module docstring for the full incident writeup):
#   T1 — Case 1 (thies-wa, wa-d23f1, Ficha 360): a daemon that imports an
#        UNCHANGED function which internally calls a newly-added one IS
#        reported reachable; a sibling daemon that imports a DIFFERENT,
#        unchanged symbol from the same file is NOT.
#   T2 — Case 3 (Mayor, wa-5792j/wa-fil4i, inbound_sweep): a daemon that
#        transitively imports the changed file, but only ever names two
#        UNCHANGED helpers that do not call any of the 5 changed ones, is NOT
#        reported reachable — the exact shape a naive "imports the file at
#        all" check gets wrong (this is what made (B) alone insufficient in
#        the bead's own analysis).
#   T3 — a real shared-lib change genuinely relevant to THREE daemons at once
#        (each imports the changed function directly) — proves this script
#        does not just always shrink the list; it ranks up when the file
#        really is broadly relevant.
#   T4 — fail-open: deploy_deps.json missing/unreadable, or git diff itself
#        fails, must echo every requested entrypoint back unfiltered rather
#        than silently dropping one.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/compute_symbol_reachability.py"
PY="$(command -v python3)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mk_repo() {  # mk_repo <name> -> prints repo path
  local d="$WORK/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "test"
  echo "$d"
}

# ── T1: Case 1 shape (intra-file call-graph hop through an unchanged caller) ──
R1="$(mk_repo t1)"
mkdir -p "$R1/lib" "$R1/daemons"
cat > "$R1/lib/ficha360_data.py" <<'PY'
def normalize_doc(doc):
    return doc.strip()

def build_perfil(doc):
    return {"doc": normalize_doc(doc)}
PY
cat > "$R1/daemons/ficha360_app.py" <<'PY'
from lib.ficha360_data import build_perfil

def route():
    return build_perfil("123")
PY
cat > "$R1/daemons/demand_dashboard.py" <<'PY'
from lib.ficha360_data import normalize_doc

def other_route(doc):
    return normalize_doc(doc)
PY
git -C "$R1" add -A && git -C "$R1" commit -q -m pre
PRE1="$(git -C "$R1" rev-parse HEAD)"

cat > "$R1/lib/ficha360_data.py" <<'PY'
def normalize_doc(doc):
    return doc.strip()

def get_consultas(doc):
    return {"consultas": []}

def build_perfil(doc):
    perfil = {"doc": normalize_doc(doc)}
    perfil.update(get_consultas(doc))
    return perfil
PY
git -C "$R1" add -A && git -C "$R1" commit -q -m post
POST1="$(git -C "$R1" rev-parse HEAD)"

cat > "$R1/daemons/deploy_deps.json" <<'JSON'
{"daemons": {
  "daemons/ficha360_app.py": {"closure": ["daemons/ficha360_app.py", "lib/ficha360_data.py"], "label": "br.urblink.ficha360"},
  "daemons/demand_dashboard.py": {"closure": ["daemons/demand_dashboard.py", "lib/ficha360_data.py"], "label": "com.whatsapp.demand-dashboard"}
}}
JSON

OUT1="$("$PY" "$SCRIPT" --repo "$R1" --deps "$R1/daemons/deploy_deps.json" \
  --pre "$PRE1" --post "$POST1" \
  --entrypoints daemons/ficha360_app.py daemons/demand_dashboard.py)"

echo "$OUT1" | grep -qxF "daemons/ficha360_app.py" \
  && ok "T1: ficha360_app.py (calls build_perfil, which now calls the new get_consultas) reported reachable" \
  || bad "T1: ficha360_app.py should be reachable via the intra-file call graph — got: [$OUT1]"
echo "$OUT1" | grep -qxF "daemons/demand_dashboard.py" \
  && bad "T1: demand_dashboard.py (only imports the unrelated, unchanged normalize_doc) should NOT be reachable — got: [$OUT1]" \
  || ok "T1: demand_dashboard.py correctly excluded (imports a different, unchanged symbol)"

# ── T2: Case 3 shape (transitively closure-connected, but the only imported
#        names are unchanged helpers that don't call any changed one) ────────
R2="$(mk_repo t2)"
mkdir -p "$R2/lib" "$R2/daemons"
cat > "$R2/daemons/inbound_sweep.py" <<'PY'
def _capture_from_dump(x):
    return x

def _resolve_own_identity(x):
    return x

def _propagate_twins(x):
    return x

def _load_pending_media_targets(x):
    return x

def _contact_card_key(x):
    return x
PY
cat > "$R2/lib/device_human_sender.py" <<'PY'
from daemons.inbound_sweep import _capture_from_dump, _resolve_own_identity

def send(x):
    return _resolve_own_identity(_capture_from_dump(x))
PY
git -C "$R2" add -A && git -C "$R2" commit -q -m pre
PRE2="$(git -C "$R2" rev-parse HEAD)"

cat > "$R2/daemons/inbound_sweep.py" <<'PY'
def _capture_from_dump(x):
    return x

def _resolve_own_identity(x):
    return x

def _propagate_twins(x):
    return {"changed": True, "x": x}

def _load_pending_media_targets(x):
    return {"changed": True, "x": x}

def _contact_card_key(x):
    return {"changed": True, "x": x}
PY
git -C "$R2" add -A && git -C "$R2" commit -q -m post
POST2="$(git -C "$R2" rev-parse HEAD)"

cat > "$R2/daemons/deploy_deps.json" <<'JSON'
{"daemons": {
  "lib/device_human_sender.py": {"closure": ["lib/device_human_sender.py", "daemons/inbound_sweep.py"], "label": "com.whatsapp.referral-outreach"}
}}
JSON

OUT2="$("$PY" "$SCRIPT" --repo "$R2" --deps "$R2/daemons/deploy_deps.json" \
  --pre "$PRE2" --post "$POST2" \
  --entrypoints lib/device_human_sender.py)"

[ -z "$OUT2" ] \
  && ok "T2: device_human_sender.py correctly excluded (only names 2 unchanged helpers that call none of the 5 changed ones)" \
  || bad "T2: device_human_sender.py should NOT be reported reachable — got: [$OUT2]"

# ── T3: real shared-lib change, genuinely relevant to 3 daemons at once ──────
R3="$(mk_repo t3)"
mkdir -p "$R3/lib" "$R3/daemons"
cat > "$R3/lib/shared_util.py" <<'PY'
def compute(x):
    return x
PY
for n in a b c; do
  cat > "$R3/daemons/daemon_$n.py" <<PY
from lib.shared_util import compute

def route_$n(x):
    return compute(x)
PY
done
git -C "$R3" add -A && git -C "$R3" commit -q -m pre
PRE3="$(git -C "$R3" rev-parse HEAD)"

cat > "$R3/lib/shared_util.py" <<'PY'
def compute(x):
    return x * 2
PY
git -C "$R3" add -A && git -C "$R3" commit -q -m post
POST3="$(git -C "$R3" rev-parse HEAD)"

{
  printf '{"daemons": {'
  first=1
  for n in a b c; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '"daemons/daemon_%s.py": {"closure": ["daemons/daemon_%s.py", "lib/shared_util.py"], "label": "com.whatsapp.daemon-%s"}' "$n" "$n" "$n"
  done
  printf '}}'
} > "$R3/daemons/deploy_deps.json"

OUT3="$("$PY" "$SCRIPT" --repo "$R3" --deps "$R3/daemons/deploy_deps.json" \
  --pre "$PRE3" --post "$POST3" \
  --entrypoints daemons/daemon_a.py daemons/daemon_b.py daemons/daemon_c.py)"
N3=$(echo "$OUT3" | grep -c .)
[ "$N3" -eq 3 ] \
  && ok "T3: all 3 daemons directly calling the changed compute() reported reachable" \
  || bad "T3: expected all 3 daemons reachable, got $N3: [$OUT3]"

# ── T4: fail-open on a missing/unreadable deploy_deps.json ───────────────────
OUT4="$("$PY" "$SCRIPT" --repo "$R1" --deps "$R1/daemons/DOES-NOT-EXIST.json" \
  --pre "$PRE1" --post "$POST1" \
  --entrypoints daemons/ficha360_app.py daemons/demand_dashboard.py 2>/dev/null)"
N4=$(echo "$OUT4" | grep -c .)
[ "$N4" -eq 2 ] \
  && ok "T4: missing deploy_deps.json fails open — both requested entrypoints echoed back" \
  || bad "T4: expected both entrypoints echoed back on fail-open, got $N4: [$OUT4]"

# ── T5: fail-open on an unresolvable git ref (bad PRE/POST) ──────────────────
OUT5="$("$PY" "$SCRIPT" --repo "$R1" --deps "$R1/daemons/deploy_deps.json" \
  --pre "not-a-real-sha" --post "$POST1" \
  --entrypoints daemons/ficha360_app.py daemons/demand_dashboard.py 2>/dev/null)"
N5=$(echo "$OUT5" | grep -c .)
[ "$N5" -eq 2 ] \
  && ok "T5: unresolvable PRE sha fails open — both requested entrypoints echoed back" \
  || bad "T5: expected both entrypoints echoed back on fail-open, got $N5: [$OUT5]"

# ── T6/T7: whole-module import (no "from X import Y") ────────────────────────
# T6 — imported but the single-level Attribute scan finds ZERO uses of the
#      bound name at all: fails open (reachable) rather than treat an
#      unusual "confirmed unused" as safe to demote.
# T7 — imported AND used, but only for an unrelated, unchanged function:
#      a genuine negative, still correctly excluded.
R6="$(mk_repo t6)"
mkdir -p "$R6/lib" "$R6/daemons"
cat > "$R6/lib/shared_util.py" <<'PY'
def compute(x):
    return x

def other(x):
    return x
PY
cat > "$R6/daemons/daemon_unused_import.py" <<'PY'
import lib.shared_util

def route(x):
    return x
PY
cat > "$R6/daemons/daemon_uses_other.py" <<'PY'
import lib.shared_util as su

def route(x):
    return su.other(x)
PY
git -C "$R6" add -A && git -C "$R6" commit -q -m pre
PRE6="$(git -C "$R6" rev-parse HEAD)"

cat > "$R6/lib/shared_util.py" <<'PY'
def compute(x):
    return x * 2

def other(x):
    return x
PY
git -C "$R6" add -A && git -C "$R6" commit -q -m post
POST6="$(git -C "$R6" rev-parse HEAD)"

cat > "$R6/daemons/deploy_deps.json" <<'JSON'
{"daemons": {
  "daemons/daemon_unused_import.py": {"closure": ["daemons/daemon_unused_import.py", "lib/shared_util.py"], "label": "com.test.unused-import"},
  "daemons/daemon_uses_other.py": {"closure": ["daemons/daemon_uses_other.py", "lib/shared_util.py"], "label": "com.test.uses-other"}
}}
JSON

OUT6="$("$PY" "$SCRIPT" --repo "$R6" --deps "$R6/daemons/deploy_deps.json" \
  --pre "$PRE6" --post "$POST6" \
  --entrypoints daemons/daemon_unused_import.py daemons/daemon_uses_other.py)"

echo "$OUT6" | grep -qxF "daemons/daemon_unused_import.py" \
  && ok "T6: whole-module import with zero attribute uses found fails open (reachable)" \
  || bad "T6: expected daemon_unused_import.py to fail open — got: [$OUT6]"
echo "$OUT6" | grep -qxF "daemons/daemon_uses_other.py" \
  && bad "T7: daemon_uses_other.py (only ever calls the unrelated, unchanged other()) should NOT be reachable — got: [$OUT6]" \
  || ok "T7: whole-module import used only for an unrelated, unchanged function correctly excluded"

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
