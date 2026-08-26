#!/usr/bin/env python3
"""ram-owner-report.py (ga-yr8vm) — turns ram-owner-sampler.py's JSONL into
what the bead's ACEITE actually asks for (Mayor, 25/08): the QUEM-consome-
quanto table, plus the 3 biggest cut opportunities with an estimated gain —
not just raw numbers.

Two independent modes:
  (default) history mode — reads the JSONL: current top owners, who GREW
    since the last sample, who's above their own historical range, and the
    top-3 actionable opportunities (idle sessions / daemons over median).
  --top N   live mode — no JSONL needed, takes one fresh sample via
    ram_owner_lib directly and prints the top N owners in one compact line.
    This is the mode ram-pressure-monitor.sh calls at alert time (item 4 of
    the bead: "quando ele pausar o Pilot, o alerta deve dizer QUEM") — kept
    as a separate code path from history mode on purpose, so a RAM emergency
    alert never depends on the JSONL file, rotation, or history being intact.

Usage:
  ram-owner-report.py [--in PATH] [--window 7d] [--json]
  ram-owner-report.py --top 3          # compact live line, for alert callers
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ram_owner_lib as lib

HQ = "/Users/athos/gt/.gascity-gastown-hq"
JSONL = os.environ.get("RAM_OWNER_OUT", os.path.join(HQ, ".gc", "ram-owner-samples.jsonl"))
NOW = int(os.environ.get("RAM_OWNER_NOW_EPOCH", str(int(time.time()))))
IDLE_SESSION_SEC = int(os.environ.get("RAM_OWNER_IDLE_SESSION_SEC", str(2 * 3600)))  # bead's own example: "ociosas há 2h"
ABOVE_MEDIAN_RATIO = float(os.environ.get("RAM_OWNER_ABOVE_MEDIAN_RATIO", "1.5"))
# A "median" of 1-2 adjacent samples is just noise, not a baseline — measured
# live (25/08): a fresh JSONL with 2 samples 2s apart produced "28.9x the
# median" for an owner whose only two readings were 3MB and 71MB, an artifact
# of having no real history yet, not a genuine growth signal. Below this
# count, historical_medians() omits the owner entirely (treated the same as
# "no baseline yet", not zero-filled).
MIN_SAMPLES_FOR_BASELINE = int(os.environ.get("RAM_OWNER_MIN_SAMPLES_FOR_BASELINE", "3"))
PS_FIXTURE = os.environ.get("RAM_OWNER_PS_FIXTURE")
SESSIONS_FIXTURE = os.environ.get("RAM_OWNER_SESSIONS_FIXTURE")


def load(path, since_ts=None):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if since_ts is None or rec.get("ts", 0) >= since_ts:
                rows.append(rec)
    rows.sort(key=lambda r: r.get("ts", 0))
    return rows


def parse_window(w):
    if w.endswith("d"):
        return float(w[:-1]) * 86400
    if w.endswith("h"):
        return float(w[:-1]) * 3600
    return 7 * 86400


def median(vals):
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 else (s[mid - 1] + s[mid]) / 2.0


def fmt_mb(kb):
    return f"{kb / 1024.0:.0f}MB" if kb is not None else "?"


def session_idle_seconds(sess, now):
    """now - last_active, in seconds; None if unparseable/missing (never
    treated as 0 — an unknown idle time must not silently look 'freshly
    active', matching this codebase's own error/empty discipline)."""
    ts = sess.get("last_active") or sess.get("created_at")
    if not ts:
        return None
    try:
        import datetime
        t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
        return now - t
    except Exception:
        return None


def growth_since_last(rows):
    """Delta (kb) per owner between the last two samples. Empty if <2 rows —
    that's a real 'not enough history yet' state, not a zero-growth claim."""
    if len(rows) < 2:
        return {}
    prev, latest = rows[-2]["by_owner"], rows[-1]["by_owner"]
    deltas = {}
    for owner, kb in latest.items():
        deltas[owner] = kb - prev.get(owner, 0)
    return deltas


def historical_medians(rows, exclude_latest=True):
    """owner -> median RSS (kb) across all but the most recent sample, so
    'above historical range' never compares a sample against itself. Owners
    with fewer than MIN_SAMPLES_FOR_BASELINE prior readings are omitted
    entirely — not enough history to call it a baseline yet."""
    series = rows[:-1] if (exclude_latest and len(rows) > 1) else rows
    by_owner_series = {}
    for r in series:
        for owner, kb in r.get("by_owner", {}).items():
            by_owner_series.setdefault(owner, []).append(kb)
    return {
        owner: median(vals) for owner, vals in by_owner_series.items()
        if len(vals) >= MIN_SAMPLES_FOR_BASELINE
    }


def top3_opportunities(latest, medians, sess_by_key, now):
    """Merges two actionable signal classes the bead names explicitly:
      - idle SESSIONS holding real RSS ("pool X com 4 sessões ociosas há 2h")
      - DAEMONS above their own historical median ("daemon Y com RSS 3x a mediana")
    Ranked by estimated recoverable kb, top 3. Never invents a number for an
    owner with no baseline yet (skipped, not zero-filled)."""
    candidates = []
    by_owner = latest.get("by_owner", {})
    owner_kind = latest.get("owner_kind", {})

    sess_by_name = {s["name"]: s for s in sess_by_key.values()}
    for owner, kb in by_owner.items():
        if owner_kind.get(owner) != "session":
            continue
        sess = sess_by_name.get(owner)
        if not sess:
            continue
        idle_sec = session_idle_seconds(sess, now)
        if idle_sec is not None and idle_sec >= IDLE_SESSION_SEC:
            candidates.append({
                "owner": owner, "kind": "idle_session", "est_gain_kb": kb,
                "detail": f"ociosa há {idle_sec / 3600:.1f}h",
            })

    for owner, kb in by_owner.items():
        if owner_kind.get(owner) != "daemon":
            continue
        base = medians.get(owner)
        if not base or base <= 0:
            continue  # no baseline yet — not a candidate, not a false zero
        ratio = kb / base
        if ratio >= ABOVE_MEDIAN_RATIO:
            candidates.append({
                "owner": owner, "kind": "above_median_daemon",
                "est_gain_kb": max(0, kb - base),
                "detail": f"{ratio:.1f}x a mediana ({fmt_mb(base)})",
            })

    candidates.sort(key=lambda c: c["est_gain_kb"], reverse=True)
    return candidates[:3]


def render_table(latest, growth, top3, medians, sess_ok=True):
    lines = []
    lines.append(f"=== QUEM consome quanto (ts={latest.get('ts')}) ===")
    lines.append(f"total_rss={fmt_mb(latest.get('total_rss_kb'))}  "
                  f"nao-atribuido={fmt_mb(latest.get('unresolved_kb'))}  "
                  f"swap={latest.get('swap_used_mb')}MB/{latest.get('swap_total_mb')}MB  "
                  f"free={latest.get('free_pct')}%")
    if not sess_ok:
        # Same visibility gap as cmd_top()'s AVISO: this run's live session
        # lookup (used only for the idle-session half of top3_opportunities,
        # see below) failed — idle-session candidates may be silently
        # unfindable this round, distinct from "there genuinely are none."
        lines.append("AVISO: busca de sessoes ao vivo falhou nesta chamada — "
                      "candidatos de sessao ociosa podem nao ter sido detectados")
    lines.append(f"{'dono':<38} {'RSS':>8} {'Δ ult. amostra':>16}")
    for owner, kb in sorted(latest.get("by_owner", {}).items(), key=lambda kv: -kv[1])[:15]:
        d = growth.get(owner)
        dstr = f"{'+' if d and d > 0 else ''}{fmt_mb(d)}" if d is not None else "(sem historico)"
        lines.append(f"{owner:<38} {fmt_mb(kb):>8} {dstr:>16}")
    lines.append("")
    lines.append("=== por rig ===")
    for rig, kb in sorted(latest.get("by_rig", {}).items(), key=lambda kv: -kv[1]):
        lines.append(f"{rig:<20} {fmt_mb(kb):>8}")
    lines.append("")
    lines.append("=== top 3 oportunidades de corte ===")
    if not top3:
        lines.append("(nenhuma — sem sessao ociosa >2h nem daemon acima da mediana nesta amostra)")
    for c in top3:
        lines.append(f"- {c['owner']}: ~{fmt_mb(c['est_gain_kb'])} ({c['detail']})")
    return "\n".join(lines)


def cmd_top(n):
    """Live mode: one fresh sample, top-N owners, single compact line. No
    JSONL touched — this must keep working even if history/rotation is
    broken, since ram-pressure-monitor.sh calls this at alert time."""
    rec = lib.sample(now=NOW, ps_fixture=PS_FIXTURE, sessions_fixture=SESSIONS_FIXTURE, compute_rig=False)
    if rec.get("error"):
        # Distinct from "no significant owners" — the ps read itself failed.
        # Worth saying plainly to whoever's reading a RAM alert right now.
        print(f"top RSS: (falha na leitura — {rec['error']})")
        return
    ranked = sorted(rec.get("by_owner", {}).items(), key=lambda kv: -kv[1])[:n]
    parts = [f"{name}={fmt_mb(kb)}" for name, kb in ranked]
    unresolved = rec.get("unresolved_kb", 0)
    line = "top RSS: " + ", ".join(parts) if parts else "top RSS: (sem dados)"
    if unresolved:
        line += f" | nao-atribuido={fmt_mb(unresolved)}"
    if rec.get("sessions_lookup_failed"):
        # The RSS numbers above are still real — only per-session naming is
        # degraded (every claude PID falls into "claude (no session-id
        # match)"). Say so plainly: this is the exact visibility gap
        # ga-yr8vm's gate review caught (error and empty must not look alike).
        line += " | AVISO: busca de sessoes falhou nesta amostra — atribuicao por sessao pode estar degradada"
    print(line)


def main(argv):
    if "--top" in argv:
        n = int(argv[argv.index("--top") + 1]) if len(argv) > argv.index("--top") + 1 else 3
        cmd_top(n)
        return 0

    path = JSONL
    if "--in" in argv:
        path = argv[argv.index("--in") + 1]
    window_sec = 7 * 86400
    if "--window" in argv:
        window_sec = parse_window(argv[argv.index("--window") + 1])

    rows = load(path, since_ts=NOW - window_sec)
    if not rows:
        msg = f"(sem amostras em {path} na janela pedida — instrumento ainda sem historico ou nao rodou)"
        if "--json" in argv:
            print(json.dumps({"error": "no_data", "detail": msg}))
        else:
            print(msg)
        return 0

    latest = rows[-1]
    growth = growth_since_last(rows)
    medians = historical_medians(rows)
    sess, sess_ok = lib.sessions_by_key(SESSIONS_FIXTURE)
    top3 = top3_opportunities(latest, medians, sess, NOW)

    if "--json" in argv:
        print(json.dumps({
            "latest": latest, "growth_since_last_kb": growth,
            "historical_medians_kb": medians, "top3_opportunities": top3,
            "sessions_lookup_failed": not sess_ok,
        }, indent=2))
    else:
        print(render_table(latest, growth, top3, medians, sess_ok))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
