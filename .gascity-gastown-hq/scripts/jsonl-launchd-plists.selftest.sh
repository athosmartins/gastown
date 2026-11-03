#!/usr/bin/env bash
# jsonl-launchd-plists.selftest.sh — ga-ki02nmt: the two backup jobs that run from launchd (com.gascity.jsonl-export, com.gascity.jsonl-hourly-offsite)
# must stay what the gc orders they replaced were: same script, same timeout, same cadence, the env the order gave for free, and the orders must be OFF.
#
# WHY A TEST AND NOT A COMMENT: the two plists are a COPY of two order files (timeout, interval, script) in another format, and the orders stay in the
# repo as the single source of those numbers. Nothing makes a later edit of the order's timeout reach the plist; this file does. The cases that matter:
#   - timeout: the exporter commits ONCE after the last database, so a run killed by a too-short timeout commits nothing (ga-fegzc8h: three runs in a row
#     wrote every file and committed none). The plist's timeout must equal the order's and, for the exporter, timeout + the 20 s KILL grace must fit
#     inside the interval (no second run on top: the exporter has no single-flight lock).
#   - env: without GC_PACK_STATE_DIR (= .gc/runtime/packs/town-deltas) the exporter falls back to packs/maintenance and starts from a blank state file
#     (degraded-table memory, death streak, last-export time that the disk policy reads). GC_DOLT_PORT must NOT be pinned (dolt-target.sh reads the
#     live port on each run; a pinned one points at a dead server after a Dolt restart).
#   - the skip: BOTH names in city.toml [orders] skip, the three older ones still there, and jsonl-hourly-offsite-age NOT there (that one stays an order).
#
# THREE STATES on every input (unreadable / read but the key is absent / present and compared): the first two are BAD, never "ok". Injected failures at the
# bottom each require rc != 0 and the right reason.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HQ_REPO="${JLP_REPO:-$(cd "$HERE/.." && pwd)}"
CITY_TOML="${JLP_CITY_TOML:-$HQ_REPO/city.toml}"
JX_PLIST="${JLP_JX_PLIST:-$HERE/com.gascity.jsonl-export.plist}"
JO_PLIST="${JLP_JO_PLIST:-$HERE/com.gascity.jsonl-hourly-offsite.plist}"
JX_ORDER="${JLP_JX_ORDER:-$HQ_REPO/packs/town-deltas/orders/jsonl-export.toml}"
JO_ORDER="${JLP_JO_ORDER:-$HQ_REPO/packs/town-deltas/orders/jsonl-hourly-offsite.toml}"

W="$(mktemp -d "${TMPDIR:-/tmp}/jsonl-launchd-plists.XXXXXX")"
trap 'chmod -R u+rwX "$W" 2>/dev/null; rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# python3 -I (isolated: no cwd/site imports). plistlib and tomllib are stdlib; a python without tomllib (< 3.11) says so and the case is BAD, not skipped.
read -r -d '' PYCHECK <<'PY'
import sys, os, re, plistlib
try:
    import tomllib
except Exception as e:
    print(f"BAD python has no tomllib ({e}): cannot read the order files"); sys.exit(1)

mode = sys.argv[1]
bad = 0
def OK(m):  print("OK " + m)
def BAD(m):
    global bad; bad += 1; print("BAD " + m)

def secs(v):
    m = re.fullmatch(r"\s*(\d+)\s*([smh])\s*", str(v))
    return int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[m.group(2)] if m else None

def load_toml(p):
    try:
        with open(p, "rb") as f: return tomllib.load(f)
    except Exception as e:
        BAD(f"cannot read/parse {p}: {e}"); return None

if mode == "plist":
    plist, order, script_name, must_fit, same_err, want_state_dir, repo = sys.argv[2:9]
    must_fit, same_err, want_state_dir = must_fit == "1", same_err == "1", want_state_dir == "1"
    try:
        with open(plist, "rb") as f: d = plistlib.load(f)
    except Exception as e:
        BAD(f"cannot read/parse plist {plist}: {e}"); sys.exit(1)
    o = load_toml(order)
    if o is None: sys.exit(1)
    o = o.get("order", {})
    stem = os.path.basename(plist)[:-len(".plist")]
    if d.get("Label") == stem: OK(f"Label == file name ({stem})")
    else: BAD(f"Label [{d.get('Label')}] != file name stem [{stem}]")
    interval, o_int = d.get("StartInterval"), secs(o.get("interval"))
    if isinstance(interval, int) and o_int is not None and interval == o_int: OK(f"StartInterval {interval} s == the order's interval ({o.get('interval')})")
    else: BAD(f"StartInterval [{interval}] != the order's interval [{o.get('interval')}] ({o_int})")
    a = d.get("ProgramArguments") or []
    # ProgramArguments = [<...>/timeout, -k, <grace>, <timeout>, /bin/bash, <script>]; anything else is "no timeout in front of the script", which is BAD
    if len(a) == 6 and os.path.basename(a[0]) == "timeout" and a[1] == "-k" and a[2].isdigit() and a[3].isdigit() and a[4] == "/bin/bash":
        grace, tmo, script = int(a[2]), int(a[3]), a[5]
        OK(f"ProgramArguments = timeout -k {grace} {tmo} /bin/bash <script>")
        o_tmo = secs(o.get("timeout"))
        if o_tmo is not None and tmo == o_tmo: OK(f"timeout {tmo} s == the order's timeout ({o.get('timeout')})")
        else: BAD(f"timeout {tmo} s != the order's timeout [{o.get('timeout')}]")
        if must_fit:
            if isinstance(interval, int) and tmo + grace < interval: OK(f"timeout {tmo} + KILL grace {grace} < interval {interval} (a run is over before the next tick)")
            else: BAD(f"timeout {tmo} + KILL grace {grace} does not fit under the interval [{interval}]: a second exporter could start on top (it has no lock)")
        if script.endswith("/packs/town-deltas/assets/scripts/" + script_name) and os.path.isfile(os.path.join(repo, "packs/town-deltas/assets/scripts", script_name)):
            OK(f"script is packs/town-deltas/assets/scripts/{script_name} and exists in the repo")
        else: BAD(f"script [{script}] is not packs/town-deltas/assets/scripts/{script_name} or is missing in {repo}")
        if re.search(r"/" + re.escape(script_name) + r"\"?\s*$", str(o.get("exec", ""))): OK("the order's exec runs the same script")
        else: BAD(f"the order's exec [{o.get('exec')}] does not run {script_name}")
    else:
        BAD(f"ProgramArguments is not `timeout -k <n> <n> /bin/bash <script>`: {a}")
    if d.get("RunAtLoad") is True: OK("RunAtLoad true")
    else: BAD(f"RunAtLoad [{d.get('RunAtLoad')}] is not true")
    if d.get("ProcessType") == "Interactive": OK("ProcessType Interactive (macOS DAS does not defer it under load)")
    else: BAD(f"ProcessType [{d.get('ProcessType')}] is not Interactive: a Standard job can be deferred under load (ga-9wv5)")
    e = d.get("EnvironmentVariables") or {}
    city = e.get("GC_CITY_PATH")
    if city and e.get("GC_CITY") == city and d.get("WorkingDirectory") == city: OK(f"GC_CITY == GC_CITY_PATH == WorkingDirectory ({city})")
    else: BAD(f"GC_CITY [{e.get('GC_CITY')}] / GC_CITY_PATH [{city}] / WorkingDirectory [{d.get('WorkingDirectory')}] disagree or are missing")
    rt = e.get("GC_CITY_RUNTIME_DIR")
    if city and rt == city + "/.gc/runtime": OK("GC_CITY_RUNTIME_DIR == <city>/.gc/runtime")
    else: BAD(f"GC_CITY_RUNTIME_DIR [{rt}] != <city>/.gc/runtime")
    if want_state_dir:
        sd = e.get("GC_PACK_STATE_DIR")
        if city and sd == city + "/.gc/runtime/packs/town-deltas": OK("GC_PACK_STATE_DIR == <runtime>/packs/town-deltas (the state file of the order's pack)")
        else: BAD(f"GC_PACK_STATE_DIR [{sd}] != <runtime>/packs/town-deltas: the exporter would start from a blank state in packs/maintenance")
    if "GC_DOLT_PORT" not in e: OK("GC_DOLT_PORT is not pinned (dolt-target.sh reads the live port on each run)")
    else: BAD(f"GC_DOLT_PORT is pinned to [{e.get('GC_DOLT_PORT')}]: a Dolt restart onto another port leaves this job on a dead one")
    path = e.get("PATH", "")
    parts = path.split(":")
    if parts and parts[0] == "/opt/homebrew/bin" and "/Users/athos/.local/bin" in parts: OK("PATH has /opt/homebrew/bin first (jq, dolt, git, GNU timeout, aws) and ~/.local/bin (bd)")
    else: BAD(f"PATH [{path}] lacks /opt/homebrew/bin first or /Users/athos/.local/bin")
    so, se = d.get("StandardOutPath"), d.get("StandardErrorPath")
    if so and city and so.startswith(city + "/.gc/logs/") and se and se.startswith(city + "/.gc/logs/"): OK("StandardOutPath/StandardErrorPath under <city>/.gc/logs/")
    else: BAD(f"StandardOutPath [{so}] / StandardErrorPath [{se}] are not under <city>/.gc/logs/")
    if same_err:
        if so and so == se: OK("StandardErrorPath == StandardOutPath (the script logs to stderr; the watchdog heartbeat is the StandardOutPath)")
        else: BAD(f"StandardErrorPath [{se}] != StandardOutPath [{so}]: the heartbeat file would never advance")
    else:
        if so and se and so != se: OK("stdout and stderr go to separate files")
        else: BAD(f"StandardOutPath == StandardErrorPath [{so}]: failures would be mixed into the file that carries the run summaries")
    sys.exit(1 if bad else 0)

if mode == "skip":
    city_toml, = sys.argv[2:3]
    c = load_toml(city_toml)
    if c is None: sys.exit(1)
    skip = (c.get("orders") or {}).get("skip")
    if not isinstance(skip, list): BAD(f"[orders].skip is not a list ({skip!r})"); sys.exit(1)
    for n in ("wisp-compact", "nudge-on-route", "mol-dog-jsonl"):
        if n in skip: OK(f"[orders].skip still carries {n}")
        else: BAD(f"[orders].skip lost {n}")
    for n in ("jsonl-export", "jsonl-hourly-offsite"):
        if n in skip: OK(f"[orders].skip carries {n} (the plist replaces the order)")
        else: BAD(f"[orders].skip does NOT carry {n}: the order and its launchd job would both run (the exporter has no lock)")
    if "jsonl-hourly-offsite-age" not in skip: OK("[orders].skip does not carry jsonl-hourly-offsite-age (the age alarm order stays on)")
    else: BAD("[orders].skip carries jsonl-hourly-offsite-age: the age alarm order would be off")
    sys.exit(1 if bad else 0)
PY

# plist_check <plist> <order> <script-name> <must-fit 0|1> <same-err 0|1> <state-dir 0|1>: prints OK/BAD lines; rc 1 if any BAD (or the plist/order is unreadable)
plist_check() { python3 -I -c "$PYCHECK" plist "$1" "$2" "$3" "$4" "$5" "$6" "$HQ_REPO"; }
skip_check()  { python3 -I -c "$PYCHECK" skip "$1"; }

# expect_bad <name> <needle> <command...>: the command must return != 0 AND say <needle> on a BAD line.
expect_bad() {
  local name="$1" needle="$2" o; shift 2
  o="$("$@" 2>&1)"
  if [ $? -eq 0 ]; then nope "$name — passed (rc 0); a broken input must reprove"; return; fi
  if ! printf '%s\n' "$o" | grep '^BAD' | grep -q -- "$needle"; then
    nope "$name — reproved, but not for the expected reason ($needle): $(printf '%s' "$o" | grep '^BAD' | head -2 | tr '\n' ' ')"; return
  fi
  ok "$name → rc != 0 ($needle)"
}

echo "== the real plists against the real order files =="
if o="$(plist_check "$JX_PLIST" "$JX_ORDER" jsonl-export.sh 1 0 1 2>&1)"; then ok "jsonl-export plist proven"; else nope "jsonl-export plist NOT proven"; fi
printf '%s\n' "$o" | sed 's/^/        | /'
if o="$(plist_check "$JO_PLIST" "$JO_ORDER" jsonl-hourly-offsite.sh 0 1 0 2>&1)"; then ok "jsonl-hourly-offsite plist proven"; else nope "jsonl-hourly-offsite plist NOT proven"; fi
printf '%s\n' "$o" | sed 's/^/        | /'
echo "== the real city.toml =="
if o="$(skip_check "$CITY_TOML" 2>&1)"; then ok "city.toml [orders] skip proven"; else nope "city.toml [orders] skip NOT proven"; fi
printf '%s\n' "$o" | sed 's/^/        | /'

echo "== injected failures: each must reprove, for its own reason =="
# each mutation edits a COPY; a sed that matches nothing leaves the copy intact, the check passes, and the case fails as "passed (rc 0)"
# vazio/ausente → o arquivo não existe → BAD "cannot read"; ilegível (chmod 000) → idem; nunca "ok"
expect_bad "plist missing" "cannot read/parse plist" plist_check "$W/nonexistent.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
expect_bad "order file missing" "cannot read/parse" plist_check "$JX_PLIST" "$W/nonexistent.toml" jsonl-export.sh 1 0 1
: > "$W/empty.plist"
expect_bad "plist empty (read ok, keys absent)" "cannot read/parse plist" plist_check "$W/empty.plist" "$JX_ORDER" jsonl-export.sh 1 0 1

# exporter: the timeout in ProgramArguments is the line right after the `20` (KILL grace) one
sed 's|<string>840</string>|<string>600</string>|' "$JX_PLIST" > "$W/jx-tmo600.plist"
expect_bad "exporter timeout 600 s != the order's 840 s" "the order's timeout" plist_check "$W/jx-tmo600.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
sed 's|<string>840</string>|<string>890</string>|' "$JX_PLIST" > "$W/jx-tmo890.plist"
expect_bad "exporter timeout 890 s (+20 grace >= 900 s interval, and != the order's)" "does not fit under the interval" plist_check "$W/jx-tmo890.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
sed 's|<key>StartInterval</key><integer>900</integer>|<key>StartInterval</key><integer>1800</integer>|' "$JX_PLIST" > "$W/jx-int1800.plist"
expect_bad "exporter StartInterval 1800 != the order's 15 m" "StartInterval" plist_check "$W/jx-int1800.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
grep -v '<string>-k</string>' "$JX_PLIST" > "$W/jx-nok.plist"
expect_bad "exporter without the timeout wrapper's -k" "ProgramArguments" plist_check "$W/jx-nok.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
sed 's|packs/town-deltas/assets/scripts/jsonl-export.sh|packs/maintenance/assets/scripts/jsonl-export.sh|' "$JX_PLIST" > "$W/jx-wrong-script.plist"
expect_bad "exporter runs another copy of the script" "is not packs/town-deltas/assets/scripts/jsonl-export.sh" plist_check "$W/jx-wrong-script.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
# GC_PACK_STATE_DIR: the key line and its string line both go (the <string> after it is the next line)
awk '/<key>GC_PACK_STATE_DIR<\/key>/{getline; next} {print}' "$JX_PLIST" > "$W/jx-no-state.plist"
expect_bad "exporter without GC_PACK_STATE_DIR (blank state in packs/maintenance)" "GC_PACK_STATE_DIR" plist_check "$W/jx-no-state.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
sed 's|<key>GC_CITY_RUNTIME_DIR</key>|<key>GC_DOLT_PORT</key><string>3307</string><key>GC_CITY_RUNTIME_DIR</key>|' "$JX_PLIST" > "$W/jx-port.plist"
expect_bad "exporter with GC_DOLT_PORT pinned" "GC_DOLT_PORT is pinned" plist_check "$W/jx-port.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
sed 's|<key>ProcessType</key><string>Interactive</string>|<key>ProcessType</key><string>Background</string>|' "$JX_PLIST" > "$W/jx-bg.plist"
expect_bad "exporter ProcessType Background" "ProcessType" plist_check "$W/jx-bg.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
sed 's|<key>RunAtLoad</key><true/>|<key>RunAtLoad</key><false/>|' "$JX_PLIST" > "$W/jx-noload.plist"
expect_bad "exporter RunAtLoad false" "RunAtLoad" plist_check "$W/jx-noload.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
sed 's|jsonl-export-launchd.err|jsonl-export-launchd.out|' "$JX_PLIST" > "$W/jx-same-err.plist"
expect_bad "exporter stderr merged into the summary .out (failures would be mixed into the summaries)" "StandardOutPath == StandardErrorPath" plist_check "$W/jx-same-err.plist" "$JX_ORDER" jsonl-export.sh 1 0 1
sed 's|/opt/homebrew/bin:/usr/local/bin|/usr/local/bin|' "$JX_PLIST" > "$W/jx-nopath.plist"
expect_bad "exporter PATH without /opt/homebrew/bin first" "PATH" plist_check "$W/jx-nopath.plist" "$JX_ORDER" jsonl-export.sh 1 0 1

# the order's timeout moves (the plist is a copy of it): the plist must reprove
sed 's|^timeout = "840s"|timeout = "900s"|' "$JX_ORDER" > "$W/jx-order-900.toml"
expect_bad "order timeout moved to 900 s, plist still 840 s" "the order's timeout" plist_check "$JX_PLIST" "$W/jx-order-900.toml" jsonl-export.sh 1 0 1
sed 's|^interval = "15m"|interval = "10m"|' "$JX_ORDER" > "$W/jx-order-10m.toml"
expect_bad "order interval moved to 10 m, plist still 900 s" "StartInterval" plist_check "$JX_PLIST" "$W/jx-order-10m.toml" jsonl-export.sh 1 0 1

# offsite: stderr must go to the heartbeat file; the timeout stays the order's (2400 s, above the interval ON PURPOSE: no must-fit)
sed 's|<string>2400</string>|<string>1500</string>|' "$JO_PLIST" > "$W/jo-tmo1500.plist"
expect_bad "offsite timeout 1500 s != the order's 2400 s" "the order's timeout" plist_check "$W/jo-tmo1500.plist" "$JO_ORDER" jsonl-hourly-offsite.sh 0 1 0
awk '/<key>StandardErrorPath<\/key>/{print; getline; print "  <string>/Users/athos/gt/.gascity-gastown-hq/.gc/logs/jsonl-hourly-offsite-launchd.err</string>"; next} {print}' "$JO_PLIST" > "$W/jo-err-apart.plist"
expect_bad "offsite stderr sent to another file (heartbeat would never advance)" "StandardErrorPath" plist_check "$W/jo-err-apart.plist" "$JO_ORDER" jsonl-hourly-offsite.sh 0 1 0
sed 's|<key>StartInterval</key><integer>1800</integer>|<key>StartInterval</key><integer>600</integer>|' "$JO_PLIST" > "$W/jo-int600.plist"
expect_bad "offsite StartInterval 600 != the order's 30 m" "StartInterval" plist_check "$W/jo-int600.plist" "$JO_ORDER" jsonl-hourly-offsite.sh 0 1 0
expect_bad "offsite order file runs another script" "does not run" plist_check "$JO_PLIST" "$JX_ORDER" jsonl-hourly-offsite.sh 0 1 0

# city.toml [orders] skip
sed 's|, "jsonl-export", "jsonl-hourly-offsite"\]|, "jsonl-hourly-offsite"]|' "$CITY_TOML" > "$W/ct-no-jx.toml"
expect_bad "skip without jsonl-export" "does NOT carry jsonl-export" skip_check "$W/ct-no-jx.toml"
sed 's|, "jsonl-export", "jsonl-hourly-offsite"\]|, "jsonl-export"]|' "$CITY_TOML" > "$W/ct-no-jo.toml"
expect_bad "skip without jsonl-hourly-offsite" "does NOT carry jsonl-hourly-offsite" skip_check "$W/ct-no-jo.toml"
sed 's|, "jsonl-export", "jsonl-hourly-offsite"\]|, "jsonl-export", "jsonl-hourly-offsite", "jsonl-hourly-offsite-age"]|' "$CITY_TOML" > "$W/ct-age.toml"
expect_bad "skip that also switches off the age alarm" "jsonl-hourly-offsite-age" skip_check "$W/ct-age.toml"
sed 's|"wisp-compact", ||' "$CITY_TOML" > "$W/ct-lost.toml"
expect_bad "skip that lost an older name" "lost wisp-compact" skip_check "$W/ct-lost.toml"
expect_bad "city.toml missing" "cannot read/parse" skip_check "$W/nonexistent-city.toml"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
