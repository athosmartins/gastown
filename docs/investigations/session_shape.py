#!/usr/bin/env python3
"""Re-implementation of the ga-w6vbc session_shape.py methodology (script itself
was not committed to the repo - only its output was pasted into the bead comment).
Dedups by message.id (per the documented 2.21x inflation bug: each turn writes
multiple JSONL lines - one per content block - each carrying a copy of the same
usage), sorts by timestamp, prints cache_read_input_tokens per unique turn, and
flags sharp drops as likely compaction/reset events.
"""
import json
import sys

def analyze(path):
    seen = {}
    with open(path, 'r', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = obj.get('message')
            if not isinstance(msg, dict):
                continue
            usage = msg.get('usage')
            if not isinstance(usage, dict):
                continue
            mid = msg.get('id')
            if not mid:
                continue
            ts = obj.get('timestamp', '')
            if mid in seen:
                continue
            seen[mid] = {
                'ts': ts,
                'cache_read': usage.get('cache_read_input_tokens', 0) or 0,
                'cache_creation': usage.get('cache_creation_input_tokens', 0) or 0,
                'input': usage.get('input_tokens', 0) or 0,
                'output': usage.get('output_tokens', 0) or 0,
            }
    turns = sorted(seen.values(), key=lambda x: x['ts'])
    return turns

def main():
    for path in sys.argv[1:]:
        turns = analyze(path)
        if not turns:
            print(f"=== {path}: no usage-bearing turns found ===")
            continue
        print(f"=== {path} --- {len(turns)} unique turns ===")
        max_cr = 0
        drops = []
        prev_cr = None
        for i, t in enumerate(turns):
            cr = t['cache_read']
            total = cr + t['cache_creation'] + t['input']
            if prev_cr is not None and prev_cr > 20000 and cr < prev_cr * 0.5:
                drops.append((i, prev_cr, cr))
            prev_cr = cr
            max_cr = max(max_cr, cr)
            if i < 3 or i >= len(turns) - 3 or (i, prev_cr, cr) in [(d[0], turns[d[0]-1]['cache_read'], d[2]) for d in drops]:
                print(f"turn {i:5d}: ts={t['ts']} cache_read={cr:>10,} cache_creation={t['cache_creation']:>8,} total={total:>10,}")
        print(f"max cache_read seen: {max_cr:,}")
        print(f"sharp-drop events (possible compaction/reset): {len(drops)}")
        for idx, before, after in drops:
            prevt = turns[idx-1]
            t = turns[idx]
            print(f"  drop at turn {idx}: {before:,} -> {after:,}  (floor retained = {after:,}, {after/before*100:.1f}% of pre-drop peak)")
            print(f"    pre : ts={prevt['ts']} cache_read={prevt['cache_read']:>10,} cache_creation={prevt['cache_creation']:>8,}")
            print(f"    post: ts={t['ts']} cache_read={t['cache_read']:>10,} cache_creation={t['cache_creation']:>8,} input={t['input']:>8,}")
            gap_s = None
            try:
                from datetime import datetime
                fmt = "%Y-%m-%dT%H:%M:%S.%fZ"
                gap_s = (datetime.strptime(t['ts'], fmt) - datetime.strptime(prevt['ts'], fmt)).total_seconds()
                print(f"    time gap: {gap_s:.0f}s")
            except Exception:
                pass
            classification = "TTL-cache-miss (same content, re-paid)" if t['cache_creation'] > before * 0.5 else "likely real compaction (content shortened)"
            print(f"    => {classification}")
        print()

if __name__ == '__main__':
    main()
