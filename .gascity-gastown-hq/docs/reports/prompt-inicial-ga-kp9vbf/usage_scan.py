#!/usr/bin/env python3
"""usage_scan.py (ga-kp9vbf, read-only): per-session token composition + which procedures each role actually ran.

Reuses beacon/role logic from pool-preamble-measure.py. Reads ~/.claude/projects/*/*.jsonl only.
Output: JSON list of per-session records on stdout.

Token rules (same as pool-preamble-measure.py): one usage per message.id (the JSONL repeats usage on every content block);
tool_use counted per BLOCK id, before any message-id dedup.
"""
import glob, importlib.util, json, os, re, sys, time
from collections import Counter

spec = importlib.util.spec_from_file_location(
    "ppm", __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "..", "..", "..", "packs", "town-deltas", "assets", "pool-preamble-measure.py"))
ppm = importlib.util.module_from_spec(spec); spec.loader.exec_module(ppm)

# What a role would have to RUN (Bash) for a doctrine section to matter. Regexes are applied to the Bash command text.
PROC = {
    "gc_dolt":            r"\bgc dolt\b|SHOW FULL PROCESSLIST|dolt sql|dolt_server_pid",
    "gc_dolt_cleanup":    r"gc dolt[ -]cleanup",
    "gc_mail":            r"\bgc mail\b",
    "gc_nudge":           r"\bgc session nudge\b",
    "gc_session_kill":    r"\bgc session kill\b",
    "gc_formula":         r"\bformula show\b",
    "mol_current":        r"\bmol current\b|gc\.root_bead_id",
    "bd_claim":           r"\bbd update\b.*--claim|\bgc bd update\b.*--claim",
    "bd_close":           r"\bbd close\b|\bgc bd close\b",
    "bd_list":            r"\bbd list\b|\bgc bd list\b",
    "drain_ack":          r"\bgc runtime drain-ack\b",
    "athos_acao":         r"athos\.acao",
    "next_action":        r"label add\b.*next-action:|--add-label[ =]\S*next-action:",
    "s3_mockup":          r"\baws s3\b|presign|mockup",
    "cloud_paths":        r"CloudStorage|Mobile Documents|Google Drive",
    "engine_patch":       r"pending-engine-window|go build|\.patch\b",
    "git_worktree":       r"git (-C \S+ )?worktree",
    "git_commit":         r"\bgit (-C \S+ )?commit\b",
    "git_add_all":        r"\bgit (?:-C \S+ )?(?:add (?:-A\b|--all\b|\.(?=\s|$|;|&|\|))|commit (?:\S+ )*?-[a-zA-Z]*a[a-zA-Z]*(?=\s|$))",
    "tmux_sendkeys":      r"tmux send-keys",
    "safe_clean":         r"\bsafe-clean\b",
    "rm_rf":              r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f|\brm\s+-[a-zA-Z]*f[a-zA-Z]*r",
    "secret_cli":         r"(^|[\s;&|(])secret\s+[\"']?[A-Za-z]",
    "gmail_totp":         r"gmail-totp",
    "bd_reclaim_raw":     r"\bbd reclaim\b",
    "notify_cli":         r"(^|[\s;&|(])notify\s",
    "gate_done":          r"gate-done|gate-ready|ready-for-gate",
    "recall_cli":         r"(^|[\s;&|(])recall\s",
}
PROC_RE = {k: re.compile(v) for k, v in PROC.items()}
BDLIST = re.compile(r"\b(?:gc )?bd (?:-C \S+ )?list\b")
LIMIT_OK = re.compile(r"--limit(?:[ =]\d+)?|-n\s*\d+|--all\b|--limit\s*0")
HOME_SCAN = re.compile(r"(du|find|ls -R|tree|ncdu|fd)\s[^|;&]*(?:\s~/?\s|\s/Users/athos/?\s|\$HOME/?\s|\s~/\*)")


def scan(path):
    alias = start = None
    seen, seen_tools = set(), set()
    first = None
    turns = 0
    tok = Counter()
    first_split = None
    tools, proc, viol = Counter(), Counter(), Counter()
    skills = Counter()
    try:
        fh = open(path, errors="replace")
    except OSError:
        return None
    with fh:
        for line in fh:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("isSidechain"):
                continue
            if start is None and r.get("timestamp"):
                try:
                    start = ppm.parse_ts(r["timestamp"])
                except Exception:
                    pass
            t = r.get("type")
            if t == "user" and alias is None:
                m = ppm.BEACON.match(ppm.first_text(r).lstrip())
                alias = m.group(1) if m else ""
            elif t == "assistant":
                msg = r.get("message") or {}
                for b in msg.get("content") or []:
                    if not (isinstance(b, dict) and b.get("type") == "tool_use"):
                        continue
                    key = b.get("id") or (msg.get("id"), b.get("name"))
                    if key in seen_tools:
                        continue
                    seen_tools.add(key)
                    name = b.get("name")
                    tools[name] += 1
                    inp = b.get("input") or {}
                    if name == "Skill":
                        skills[str(inp.get("skill"))] += 1
                    if name == "Bash":
                        cmd = str(inp.get("command") or "")
                        for k, rx in PROC_RE.items():
                            if rx.search(cmd):
                                proc[k] += 1
                        # violation detectors (inverse of the rules the prompt states)
                        if PROC_RE["rm_rf"].search(cmd) and "safe-clean" not in cmd:
                            viol["rm_rf_direct"] += 1
                        if BDLIST.search(cmd) and "--json" in cmd and not LIMIT_OK.search(cmd):
                            viol["bd_list_json_no_limit"] += 1
                            # truncation-risk subset: nothing narrows the result (no assignee/label/parent/metadata/id)
                            if not re.search(r"--assignee|\s-l\s|--label|--parent|--metadata-field|--id\b", cmd):
                                viol["bd_list_json_no_limit_UNSCOPED"] += 1
                        if PROC_RE["git_add_all"].search(cmd):
                            viol["git_add_all_or_commit_a"] += 1
                        if re.search(r"gc dolt cleanup", cmd):
                            viol["gc_dolt_cleanup_space"] += 1
                        if PROC_RE["bd_reclaim_raw"].search(cmd):
                            viol["bd_reclaim_raw"] += 1
                        if HOME_SCAN.search(cmd):
                            viol["home_scan"] += 1
                        if PROC_RE["tmux_sendkeys"].search(cmd):
                            viol["tmux_sendkeys"] += 1
                if msg.get("id") in seen:
                    continue
                seen.add(msg.get("id"))
                u = msg.get("usage") or {}
                i, cw, cr, o = (int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"))
                if i + cw + cr == 0:
                    continue
                if first is None:
                    first = i + cw + cr
                    first_split = (i, cw, cr)
                turns += 1
                tok["input"] += i; tok["cache_write"] += cw; tok["cache_read"] += cr; tok["output"] += o
    if first is None:
        return None
    return dict(role=ppm.role_of(alias), alias=alias, start=start.isoformat() if start else None, first=first,
                first_split=first_split, turns=turns, tok=dict(tok), tools=dict(tools), proc=dict(proc), viol=dict(viol),
                skills=dict(skills))


def main():
    hours = float(sys.argv[1]) if len(sys.argv) > 1 else 480
    cut = time.time() - hours * 3600
    out = []
    for p in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
        try:
            if os.path.getmtime(p) < cut:
                continue
        except OSError:
            continue
        s = scan(p)
        if s:
            out.append(s)
    json.dump(out, sys.stdout)


main()
