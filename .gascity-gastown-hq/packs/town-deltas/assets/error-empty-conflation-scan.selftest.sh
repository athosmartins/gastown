#!/usr/bin/env bash
# error-empty-conflation-scan.selftest.sh — regression + falsification harness
# for error-empty-conflation-scan.sh (ga-p5q3: "ERROR and EMPTY produce the
# same value" — 5 real incidents in one night, 20h lost).
#
# Two things this proves (ga-p5q3 ACEITE, both required — neither alone is
# enough):
#   1. DETECTION — planted fixtures reproducing each category's real shape,
#      including the literal ga-jfo7 / ga-u4yi-attempt-1 anti-pattern text
#      and the collectPhones()/cwEnsurePhones incident shape, are found.
#   2. FALSIFICATION — the established FIXED idiom for the shell category
#      (`if ! VAR=$(cmd); then ...`, ga-jfo7's verdict_count_from_query /
#      ga-u4yi's prune_decision), non-empty catch/except blocks, a launchd
#      job that does notify on failure, and unrelated-but-superficially-
#      similar shell idioms (`rm -f x 2>/dev/null || true` cleanup) all
#      produce ZERO findings. A scanner that flags everything is exactly as
#      useless as one that flags nothing — ga-p5q3 defense (b): falsify every
#      check whose emptiness is load-bearing.
#
# Also smoke-tests the real script end-to-end against the live framework tree
# (must complete without error — proves the tool runs on real data, not just
# synthetic fixtures; see comment at that section for why exact counts
# against the live tree are not asserted).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/error-empty-conflation-scan.sh"
# shellcheck disable=SC1090
CONFLATION_SCAN_LIB_ONLY=1 . "$SCANNER" \
  || { echo "FATAL: could not source scanner in lib-only mode"; exit 1; }
set +e  # the harness counts its own pass/fail

for fn in scan_shell_query_masking scan_js_empty_catch scan_py_bare_except scan_launchd_no_notify run_scan; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by scanner"; exit 1; }
done

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

FIXDIR="$(mktemp -d)"
trap 'rm -rf "$FIXDIR"' EXIT
mkdir -p "$FIXDIR/mixed" "$FIXDIR/clean"

# ═════════════════════════════════════════════════════════════════════════
# Fixtures
# ═════════════════════════════════════════════════════════════════════════

# ── C2 (priority): the literal ga-u4yi gate-feedback-attempt-1 anti-pattern,
# as it existed in gate-needs-human-divergence-sweep.sh before its fix ──────
cat > "$FIXDIR/mixed/bad_query_mask_echo.sh" <<'EOF'
_found=$(bd -C "$_store" list --label "gate:needs-human" --status=open --json 2>/dev/null || echo "[]")
EOF

# ── C1 (shell flavor): query result masked via unconditional `|| true` — a
# generalization of category 1's own named shape, not tied to one incident ──
cat > "$FIXDIR/mixed/bad_query_mask_true.sh" <<'EOF'
X=$(dolt sql -q "select 1" 2>/dev/null) || true
EOF

# ── "planted case" (ACEITE: "acha um caso plantado de propósito") — a fresh
# example, not a copy of a known incident, proving the detector generalizes
# past memorized text: a gh CLI query masked the same way ─────────────────
cat > "$FIXDIR/mixed/planted_gh_query.sh" <<'EOF'
LATEST=$(gh api repos/example/example/releases/latest --jq .tag_name 2>/dev/null || echo "")
EOF

# ── ga-vkjs: o idioma que a C2 NÃO via — `cmd 2>/dev/null | parser-com-default`.
# Não tem `|| echo`/`|| true`, então os case-suffixes acima não casam. MAS é o mais
# comum na city E o mais perigoso: PROVADO que erro-de-query e campo-ausente produzem
# o MESMO valor **e o mesmo rc=0** (o jq `// ""` fabrica o default e zera o rc do pipe):
#     bd -C /nao/existe show x --json 2>/dev/null | jq -r '.a // ""'  -> ''  rc=0
#     echo '{}'                                   | jq -r '.a // ""'  -> ''  rc=0
# Foi exatamente assim que o mila-wa leu "o worker não despachou" (era a query falhando)
# e o gc sling (ga-66wc) leu "não roteado". Instâncias reais, não hipótese.
cat > "$FIXDIR/mixed/bad_query_jq_default.sh" <<'EOF'
routed=$(bd show "$BEAD" --json 2>/dev/null | jq -r '.metadata."gc.routed_to" // ""')
EOF

cat > "$FIXDIR/mixed/bad_query_py_default.sh" <<'EOF'
n=$(bd -C "$S" list --label "$L" --json 2>/dev/null | python3 -c "import sys,json;print(len(json.load(sys.stdin)))" 2>/dev/null)
EOF

# ── GOOD (ga-vkjs, falsificação da minha própria regra): a fonte do pipe é um
# `echo` de variável — NÃO pode falhar, logo não existe "a pergunta falhou" pra
# confundir com "o campo não está lá". Sem esta exclusão a regra gerava 89% de
# ruído (48 de 54 achados novos no HQ eram este shape) — medido, não estimado.
cat > "$FIXDIR/mixed/good_echo_var_jq.sh" <<'EOF'
c_type=$(echo "$row" | jq -r '.issue_type // ""')
EOF

# ── GOOD (must NOT be flagged): the established FIXED idiom — explicit rc
# capture via `if ! VAR=$(cmd); then`, same shape as verdict_count_from_query
# (ga-jfo7) / prune_decision (ga-u4yi attempt 1) ───────────────────────────
cat > "$FIXDIR/mixed/good_rc_capture.sh" <<'EOF'
if ! _found=$(bd -C "$_store" list --label "gate:needs-human" --status=open --json 2>/dev/null); then
  warn "candidate query failed for store $_store — not pruning this sweep"
fi
EOF
cp "$FIXDIR/mixed/good_rc_capture.sh" "$FIXDIR/clean/"

# ── GOOD (must NOT be flagged): `|| true` on a non-query, non-assignment
# cleanup command — the idiom appears constantly in this codebase and is
# fine; only a query-command ASSIGNMENT is in scope ────────────────────────
cat > "$FIXDIR/mixed/good_cleanup_true.sh" <<'EOF'
rm -f "${ALERT_DIR:?}/$BEAD_ID" 2>/dev/null || true
notify -t "job failed" -p 5 "the thing failed" 2>/dev/null || true
EOF
cp "$FIXDIR/mixed/good_cleanup_true.sh" "$FIXDIR/clean/"

# ── ga-6jfuo: a *.selftest.sh file containing a C2-shaped pattern ON PURPOSE
# — mirrors exactly what tripped the false positive (this scanner's OWN
# fixture heredocs above are C1/C2-shaped by construction, e.g.
# bad_query_mask_echo.sh's content). Proves FIND-level exclusion, not
# detection-level: scan_shell_query_masking still flags this content when
# called directly (asserted in the scan_shell_query_masking section below) —
# only run_scan's file-discovery `find` must skip *.selftest.sh files ───────
cat > "$FIXDIR/mixed/fixture_shape.selftest.sh" <<'EOF'
_found=$(bd -C "$_store" list --label "gate:needs-human" --status=open --json 2>/dev/null || echo "[]")
EOF

# ── C1: JS empty catch — mirrors the real collectPhones()/cwEnsurePhones
# incident shape (single-line), plus the common multi-line shape ──────────
cat > "$FIXDIR/mixed/bad_catch.js" <<'EOF'
function cwEnsurePhones(x) {
  try { collectPhones(x); } catch (e) {}
  return x;
}
function other() {
  try {
    doThing();
  } catch (e) {
  }
}
EOF

cat > "$FIXDIR/mixed/good_catch.js" <<'EOF'
function cwEnsurePhones(x) {
  try {
    collectPhones(x);
  } catch (e) {
    console.error("collectPhones failed", e);
    throw e;
  }
  return x;
}
EOF
cp "$FIXDIR/mixed/good_catch.js" "$FIXDIR/clean/"

# ── C1: Python bare except: pass — single-line and multi-line ─────────────
cat > "$FIXDIR/mixed/bad_except.py" <<'EOF'
try:
    do_thing()
except Exception:
    pass

try:
    other()
except: pass
EOF

cat > "$FIXDIR/mixed/good_except.py" <<'EOF'
try:
    do_thing()
except Exception as e:
    log.error("do_thing failed: %s", e)
    raise
EOF
cp "$FIXDIR/mixed/good_except.py" "$FIXDIR/clean/"

# ── C3: launchd job with / without a failure-notification path ────────────
cat > "$FIXDIR/mixed/bad-daemon.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "doing the thing" >> /tmp/log
EOF
cat > "$FIXDIR/mixed/good-daemon.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if ! do_thing; then
  notify -t "job failed" -p 5 "the thing failed" 2>/dev/null || true
fi
EOF
cp "$FIXDIR/mixed/good-daemon.sh" "$FIXDIR/clean/"

# ── ga-g2eg falsification: the two real idioms the original C3 pattern
# missed (variable indirection, function naming) — the exact shapes named in
# ga-g2eg's dolt-s3-backup.sh / sling-task-janitor.py / gate-marker-rehome-
# janitor.py / dolt-gc-maintenance.sh false positives ──────────────────────
cat > "$FIXDIR/mixed/good-var-daemon.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
NOTIFY="/Users/athos/.local/bin/notify"
if ! do_thing; then
  "$NOTIFY" -t "job failed" -p 5 "the thing failed" 2>/dev/null || true
fi
EOF
cp "$FIXDIR/mixed/good-var-daemon.sh" "$FIXDIR/clean/"

cat > "$FIXDIR/mixed/good-func-daemon.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
notify_fail() {
  echo "ALERT: $*" >&2
}
if ! do_thing; then
  notify_fail "the thing failed"
fi
EOF
cp "$FIXDIR/mixed/good-func-daemon.sh" "$FIXDIR/clean/"

chmod +x "$FIXDIR/mixed"/*-daemon.sh "$FIXDIR/clean"/*-daemon.sh 2>/dev/null

cat > "$FIXDIR/mixed/bad-daemon.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.selftest.bad-daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$FIXDIR/mixed/bad-daemon.sh</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
</dict>
</plist>
PLISTEOF

cat > "$FIXDIR/clean/good-daemon.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.selftest.good-daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$FIXDIR/clean/good-daemon.sh</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
</dict>
</plist>
PLISTEOF

# ── ga-vkjs (revisor do gate, run ga-wisp-3f5t3y): o launchd aceita a chave
# `Program` (string única) como alternativa VÁLIDA a `ProgramArguments` (array).
# A v1 fazia `PlistBuddy -c "Print :ProgramArguments" || return 0`, e `return 0`
# significa "nada a reportar" = "este job avisa". Ou seja: NÃO CONSEGUI LER saía
# igual a JÁ CHEQUEI E ESTÁ OK — fail-open mudo dentro da ferramenta que existe
# pra caçar fail-open mudo. Estas 2 fixtures exercitam o que nenhuma exercitava.
mkdir -p "$FIXDIR/progkey"
cat > "$FIXDIR/progkey/prog-key-daemon.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.test.progkey</string>
    <key>Program</key><string>$FIXDIR/progkey/silent-prog.sh</string>
</dict>
</plist>
PLISTEOF
cat > "$FIXDIR/progkey/silent-prog.sh" <<'EOS'
#!/bin/bash
echo "faco trabalho e morro calado"
EOS
chmod +x "$FIXDIR/progkey/silent-prog.sh"

cat > "$FIXDIR/progkey/ilegivel.plist" <<'PLISTEOF'
isto nao e um plist valido de jeito nenhum
PLISTEOF
cp "$FIXDIR/clean/good-daemon.plist" "$FIXDIR/mixed/good-daemon.plist"
sed -i '' "s#$FIXDIR/clean/good-daemon.sh#$FIXDIR/mixed/good-daemon.sh#" "$FIXDIR/mixed/good-daemon.plist"

cat > "$FIXDIR/clean/good-var-daemon.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.selftest.good-var-daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$FIXDIR/clean/good-var-daemon.sh</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
</dict>
</plist>
PLISTEOF
cp "$FIXDIR/clean/good-var-daemon.plist" "$FIXDIR/mixed/good-var-daemon.plist"
sed -i '' "s#$FIXDIR/clean/good-var-daemon.sh#$FIXDIR/mixed/good-var-daemon.sh#" "$FIXDIR/mixed/good-var-daemon.plist"

cat > "$FIXDIR/clean/good-func-daemon.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.selftest.good-func-daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$FIXDIR/clean/good-func-daemon.sh</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
</dict>
</plist>
PLISTEOF
cp "$FIXDIR/clean/good-func-daemon.plist" "$FIXDIR/mixed/good-func-daemon.plist"
sed -i '' "s#$FIXDIR/clean/good-func-daemon.sh#$FIXDIR/mixed/good-func-daemon.sh#" "$FIXDIR/mixed/good-func-daemon.plist"

# ── ga-9krhl: worktree/rig-copy + backup-dir classes added to EXCL ─────────
# Measured against the live silent-ignorance-watch baseline: whatsapp_automation's
# own mayor/rig/ + refinery/rig/ copies alone accounted for 1054 of 2279 C1
# findings (3x duplication of canonical source — e.g. demand_dashboard.js:
# 103 canonical + 97 + 78 from the two rig copies = 278 "findings" that were
# really 1 file counted 3x). polecats/ (Gas Town's own term for transient
# worktrees) and .worktrees/ (property_scrapers' convention) are the same
# class under different names. Each planted pair below proves the SAME
# content is excluded under the copy path but still flagged at a canonical
# path — differential proof, not just "the excluded one produced nothing"
# (ga-p5q3 defense (b): a check that always says nothing is as useless as
# one that always says something).
mkdir -p "$FIXDIR/mixed/somerig/mayor/rig" "$FIXDIR/mixed/somerig/refinery/rig" \
  "$FIXDIR/mixed/somerig/polecats/furiosa" "$FIXDIR/mixed/somerig/.worktrees/wt1" \
  "$FIXDIR/mixed/scripts.bak-20260101-000000"

cat > "$FIXDIR/mixed/somerig/mayor/rig/dupe_except.py" <<'EOF'
try:
    do_thing()
except:
    pass
EOF
# canonical counterpart: identical content, NOT under an excluded path —
# must still be flagged (proves exclusion is path-specific, not content-based)
cat > "$FIXDIR/mixed/canonical_control_except.py" <<'EOF'
try:
    do_thing()
except:
    pass
EOF

cat > "$FIXDIR/mixed/somerig/mayor/rig/dupe_catch.js" <<'EOF'
function f(x) {
  try { g(x); } catch (e) {}
  return x;
}
EOF

cat > "$FIXDIR/mixed/somerig/refinery/rig/dupe_shell.sh" <<'EOF'
X=$(dolt sql -q "select 1" 2>/dev/null) || true
EOF

cat > "$FIXDIR/mixed/somerig/polecats/furiosa/dupe_polecat.sh" <<'EOF'
Y=$(bd list --json 2>/dev/null) || true
EOF

cat > "$FIXDIR/mixed/somerig/.worktrees/wt1/dupe_worktree.py" <<'EOF'
try:
    do_other()
except:
    pass
EOF

cat > "$FIXDIR/mixed/scripts.bak-20260101-000000/dupe_backup.py" <<'EOF'
try:
    do_third()
except:
    pass
EOF

# ═════════════════════════════════════════════════════════════════════════
# 1. Direct pure-function detection tests
# ═════════════════════════════════════════════════════════════════════════
echo "── scan_shell_query_masking ──"
r="$(scan_shell_query_masking "$FIXDIR/mixed/bad_query_mask_echo.sh")"
case "$r" in *:C2:*) ok "ga-u4yi anti-pattern text → flagged C2" ;; *) bad "ga-u4yi anti-pattern NOT flagged: '$r'" ;; esac

r="$(scan_shell_query_masking "$FIXDIR/mixed/bad_query_mask_true.sh")"
case "$r" in *:C1:*) ok "dolt query masked via || true → flagged C1" ;; *) bad "|| true mask NOT flagged: '$r'" ;; esac

r="$(scan_shell_query_masking "$FIXDIR/mixed/planted_gh_query.sh")"
case "$r" in *:C2:*) ok "planted gh-query case (novel, not a memorized instance) → flagged C2" ;; *) bad "planted case NOT flagged: '$r'" ;; esac

r="$(scan_shell_query_masking "$FIXDIR/mixed/bad_query_jq_default.sh")"
case "$r" in *:C2:*) ok "ga-vkjs: jq // \"\" default após 2>/dev/null → flagged C2 (o idioma do ga-66wc)" ;; *) bad "ga-vkjs: parser-com-default NAO flagged (a C2 e cega ao idioma mais comum): '$r'" ;; esac

r="$(scan_shell_query_masking "$FIXDIR/mixed/bad_query_py_default.sh")"
case "$r" in *:C2:*) ok "ga-vkjs: parser com 2>/dev/null proprio → flagged C2" ;; *) bad "ga-vkjs: parser-2>/dev/null NAO flagged: '$r'" ;; esac

r="$(scan_shell_query_masking "$FIXDIR/mixed/good_echo_var_jq.sh")"
[ -z "$r" ] && ok "ga-vkjs: echo \$var | jq // \"\" → NAO flagged (fonte inerte; falsificação da propria regra)" \
  || bad "ga-vkjs REGRESSION: echo-var-jq flagged (89% de ruido volta): '$r'"

r="$(scan_shell_query_masking "$FIXDIR/mixed/good_rc_capture.sh")"
[ -z "$r" ] && ok "fixed if-!-rc-capture idiom → NOT flagged (no false positive)" || bad "REGRESSION: fixed idiom flagged: '$r'"

r="$(scan_shell_query_masking "$FIXDIR/mixed/good_cleanup_true.sh")"
[ -z "$r" ] && ok "non-query cleanup '|| true' and notify call → NOT flagged" || bad "REGRESSION: innocent || true flagged: '$r'"

r="$(scan_shell_query_masking "$FIXDIR/mixed/fixture_shape.selftest.sh")"
case "$r" in *:C2:*) ok "ga-6jfuo: detection still fires on *.selftest.sh CONTENT when scanned directly (exclusion is find-level, not detection-level)" ;; *) bad "ga-6jfuo: detection regressed on *.selftest.sh content: '$r'" ;; esac

echo "── scan_js_empty_catch ──"
r="$(scan_js_empty_catch "$FIXDIR/mixed/bad_catch.js")"
n=$(printf '%s\n' "$r" | grep -c ':C1:')
[ "$n" = "2" ] && ok "single-line + multi-line empty catch (cwEnsurePhones shape) → 2 flagged" || bad "expected 2 empty-catch findings, got $n: '$r'"

r="$(scan_js_empty_catch "$FIXDIR/mixed/good_catch.js")"
[ -z "$r" ] && ok "non-empty catch (logs + rethrows) → NOT flagged" || bad "REGRESSION: non-empty catch flagged: '$r'"

echo "── scan_py_bare_except ──"
r="$(scan_py_bare_except "$FIXDIR/mixed/bad_except.py")"
n=$(printf '%s\n' "$r" | grep -c ':C1:')
[ "$n" = "2" ] && ok "multi-line + single-line bare except:pass → 2 flagged" || bad "expected 2 bare-except findings, got $n: '$r'"

r="$(scan_py_bare_except "$FIXDIR/mixed/good_except.py")"
[ -z "$r" ] && ok "except with logging + re-raise → NOT flagged" || bad "REGRESSION: handled except flagged: '$r'"

echo "── scan_launchd_no_notify ──"
r="$(scan_launchd_no_notify "$FIXDIR/mixed/bad-daemon.plist")"
case "$r" in *:C3:*) ok "launchd job with no notify call anywhere → flagged C3" ;; *) bad "silent launchd job NOT flagged: '$r'" ;; esac

r="$(scan_launchd_no_notify "$FIXDIR/mixed/good-daemon.plist")"
[ -z "$r" ] && ok "launchd job whose script calls notify → NOT flagged" || bad "REGRESSION: notifying launchd job flagged: '$r'"

r="$(scan_launchd_no_notify "$FIXDIR/mixed/good-var-daemon.plist")"
[ -z "$r" ] && ok "ga-g2eg: notify via NOTIFY=...; \"\$NOTIFY\" ... → NOT flagged (falsification)" \
  || bad "ga-g2eg REGRESSION: notify-via-variable flagged: '$r'"

r="$(scan_launchd_no_notify "$FIXDIR/mixed/good-func-daemon.plist")"
[ -z "$r" ] && ok "ga-g2eg: notify via notify_fail() function → NOT flagged (falsification)" \
  || bad "ga-g2eg REGRESSION: notify-via-function flagged: '$r'"

# ═════════════════════════════════════════════════════════════════════════
# 2. End-to-end driver: mixed dir finds a nonzero, expected-shape count
# ═════════════════════════════════════════════════════════════════════════
r="$(scan_launchd_no_notify "$FIXDIR/progkey/prog-key-daemon.plist")"
case "$r" in *:C3:*) ok "ga-vkjs: plist com chave Program (nao ProgramArguments) -> job silencioso FLAGRADO (era fail-open mudo)" ;;
  *) bad "ga-vkjs: plist com chave Program NAO flagrado — PlistBuddy falhou e virou 'esta ok': '$r'" ;; esac

r="$(scan_launchd_no_notify "$FIXDIR/progkey/ilegivel.plist")"
case "$r" in *:C3:*) ok "ga-vkjs: plist ilegivel -> reporta 'nao sei' em vez de engolir (nao-sei != esta-ok)" ;;
  *) bad "ga-vkjs: plist ilegivel passou EM SILENCIO — o fail-open que este scanner existe pra caçar: '$r'" ;; esac

echo "── run_scan end-to-end (mixed fixture dir) ──"
MIXED_OUT="$(mktemp)"
run_scan "$MIXED_OUT" "$FIXDIR/mixed"
mixed_count=$(wc -l <"$MIXED_OUT" | tr -d '[:space:]')
# 3 shell (C1x1 + C2x2) + 2 JS + 2 py + 1 plist = 8, +2 do ga-vkjs (parser-
# com-default) = 10. fixture_shape.selftest.sh is an 11th C2-shaped file
# planted on purpose — it must stay find-excluded, so the total stays 10.
# ga-9krhl: +1 for canonical_control_except.py (must still be counted — it is
# NOT under any excluded path). The 6 dupe_*/mayor/rig,refinery/rig,polecats,
# .worktrees,bak-dir fixtures must all stay find-excluded (net +0), so the
# total becomes 11, not 17.
[ "$mixed_count" = "11" ] && ok "mixed fixture dir → 11 findings (10 pre-existing + 1 canonical control; the 6 ga-9krhl copy/backup dupes correctly excluded, nothing missed or double-counted)" \
  || bad "expected 11 findings in mixed dir, got $mixed_count"

case "$(cat "$MIXED_OUT")" in
  *fixture_shape.selftest.sh*) bad "ga-6jfuo REGRESSION: *.selftest.sh file was scanned by run_scan (should be find-excluded): $(grep 'fixture_shape.selftest.sh' "$MIXED_OUT")" ;;
  *) ok "ga-6jfuo: *.selftest.sh fixture excluded from run_scan's find (fixtures are intentional test patterns, not real findings)" ;;
esac

# ga-9krhl: each new exclusion class checked individually — an aggregate count
# match alone wouldn't say WHICH exclusion broke if one did.
for dupe in \
  "somerig/mayor/rig/dupe_except.py:mayor/rig worktree-copy (.py)" \
  "somerig/mayor/rig/dupe_catch.js:mayor/rig worktree-copy (.js)" \
  "somerig/refinery/rig/dupe_shell.sh:refinery/rig worktree-copy (.sh)" \
  "somerig/polecats/furiosa/dupe_polecat.sh:polecats transient worktree" \
  "somerig/.worktrees/wt1/dupe_worktree.py:.worktrees convention (property_scrapers)" \
  "scripts.bak-20260101-000000/dupe_backup.py:*.bak-* backup dir"
do
  relpath="${dupe%%:*}"; label="${dupe#*:}"
  case "$(cat "$MIXED_OUT")" in
    *"$relpath"*) bad "ga-9krhl REGRESSION: $label NOT excluded — found in output: $(grep "$relpath" "$MIXED_OUT")" ;;
    *) ok "ga-9krhl: $label correctly excluded from run_scan" ;;
  esac
done

case "$(cat "$MIXED_OUT")" in
  *canonical_control_except.py*:C1:*) ok "ga-9krhl: canonical (non-copy) duplicate of the SAME content still flagged — exclusion is path-specific, not content-based" ;;
  *) bad "ga-9krhl REGRESSION: canonical_control_except.py NOT flagged — exclusion is over-broad (content-based, not path-specific): $(cat "$MIXED_OUT")" ;;
esac
rm -f "$MIXED_OUT"

# ═════════════════════════════════════════════════════════════════════════
# 3. FALSIFICATION: clean dir (only established-good idioms) → ZERO findings
# ═════════════════════════════════════════════════════════════════════════
echo "── run_scan end-to-end (clean fixture dir — falsification) ──"
CLEAN_OUT="$(mktemp)"
run_scan "$CLEAN_OUT" "$FIXDIR/clean"
clean_count=$(wc -l <"$CLEAN_OUT" | tr -d '[:space:]')
[ "$clean_count" = "0" ] && ok "clean dir (fixed idiom + handled errors + notifying daemon) → 0 findings, no trivial false positive" \
  || bad "REGRESSION: clean dir produced $clean_count finding(s): $(cat "$CLEAN_OUT")"
rm -f "$CLEAN_OUT"

# ═════════════════════════════════════════════════════════════════════════
# 4. CLI wrapper: --path and --quiet, exit codes
# ═════════════════════════════════════════════════════════════════════════
echo "── CLI wrapper ──"
out="$(bash "$SCANNER" --path "$FIXDIR/mixed" --quiet)"; rc=$?
[ "$rc" = "0" ] && ok "CLI exits 0 on a completed scan with findings" || bad "CLI exit code was $rc, expected 0"
printf '%s\n' "$out" | grep -q '^error-empty-conflation-scan: 11 finding(s)$' \
  && ok "CLI summary line reports 11 finding(s)" || bad "CLI summary line unexpected: $(printf '%s\n' "$out" | head -1)"

bash "$SCANNER" --path "$FIXDIR/does-not-exist" --quiet >/tmp/.conflation-selftest-missing-path.$$ 2>&1
rc=$?
[ "$rc" = "1" ] && ok "CLI exits 1 when --path does not exist" || bad "CLI exit code for missing path was $rc, expected 1"
rm -f "/tmp/.conflation-selftest-missing-path.$$"

# ═════════════════════════════════════════════════════════════════════════
# 5. Real-tree smoke test — proves the tool actually runs end-to-end against
# live, messy data, not just synthetic fixtures. Exact counts against the
# live tree are NOT asserted here (the tree changes daily as fixes land —
# any fixed-number assertion would itself become a stale, silently-wrong
# check, the exact failure mode this whole tool exists to catch). Only
# "completes without crashing, exit 0, prints a well-formed summary line" is
# asserted.
# ═════════════════════════════════════════════════════════════════════════
echo "── real-tree smoke test ──"
real_out="$(bash "$SCANNER" --quiet)"; rc=$?
[ "$rc" = "0" ] && ok "real-tree scan completes, exit 0" || bad "real-tree scan exited $rc"
printf '%s\n' "$real_out" | grep -qE '^error-empty-conflation-scan: [0-9]+ finding' \
  && ok "real-tree scan prints a well-formed summary line" || bad "real-tree scan summary line malformed: $(printf '%s\n' "$real_out" | head -1)"

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
