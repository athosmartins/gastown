#!/usr/bin/env python3
# safe-clean — rm -rf that never triggers Claude Code's Bash(rm -rf:*) ask
# rule, because it isn't spelled "rm -rf" and doesn't pattern-match command
# text at all. It resolves each target to a canonical filesystem path
# (symlinks and ".." included) and only proceeds if that resolved path falls
# under an explicitly disposable tree; deletion itself then acts on the
# literal argument (so a symlink target is validated but never dereferenced
# for deletion — only the symlink entry itself is ever removed). Everything
# else — including anything it can't classify — is refused; use plain
# `rm -rf` for that (it will prompt for approval, which is the intended
# safety net here, not a bug).
#
# Policy below is the allow/deny list Athos approved 2026-08-15 (bead
# ga-gkap9p) verbatim. Deny always wins over allow, even on a double match.
# --help renders this same policy so the two can't drift apart.
# See packs/town-deltas/template-fragments/town-deltas.template.md for the
# doctrine entry that makes this discoverable to agents.

import os
import sys

HOME = os.path.realpath(os.path.expanduser("~"))

# ── Policy tables. classify() and --help both read from these — there is no
# second copy of the rules to drift out of sync. ──────────────────────────

DENY_COMPONENTS = [
    (".dolt", "Dolt data plane"),
    (".beads", "production bead databases"),
    (".gc-worktrees", "worktree — may hold undelivered crew WIP, not disposable"),
    ("crew", "undelivered agent work"),
    (".git", "repo history"),
]
DENY_HOME_PREFIXES = [
    (("Library", "CloudStorage"), "Athos's personal Google Drive documents"),
]
# Special-cased below (needs a single-component wildcard): ~/gt/<rig>/shared/data/**
DENY_RIG_SHARED_DATA_REASON = "production data directory (~/gt/<rig>/shared/data)"

# Special-cased below (glob prefix on one segment): /private/tmp/claude-*/**
ALLOW_SCRATCHPAD_REASON = "session scratchpad (/private/tmp/claude-*)"
ALLOW_HOME_PREFIXES = [
    (("Library", "Caches", "go-build"), "Go build cache"),
    ((".cache",), "tool cache directory"),
    ((".npm", "_cacache"), "npm cache"),
]
ALLOW_COMPONENTS = [
    ("node_modules", "reinstallable dependency directory"),
    ("__pycache__", "Python bytecode cache"),
    (".pytest_cache", "pytest cache"),
]
ALLOW_SUFFIXES = [
    (".pyc", "Python bytecode file"),
]


def parts_of(resolved_path):
    return [p for p in resolved_path.split(os.sep) if p]


def under(resolved_path, prefix_path):
    # Segment-boundary prefix match, so e.g. ".cache-evil" can't be mistaken
    # for ".cache".
    rp = parts_of(resolved_path)
    pp = parts_of(prefix_path)
    return rp[: len(pp)] == pp


def deny_reason(resolved_path):
    parts = parts_of(resolved_path)

    for comp, why in DENY_COMPONENTS:
        if comp in parts:
            return f"path contains protected component '{comp}' ({why})"

    for sub, why in DENY_HOME_PREFIXES:
        if under(resolved_path, os.path.join(HOME, *sub)):
            return why

    home_parts = parts_of(HOME)
    tail = parts[len(home_parts):]
    if parts[: len(home_parts)] == home_parts and len(tail) >= 4:
        if tail[0] == "gt" and tail[2] == "shared" and tail[3] == "data":
            return DENY_RIG_SHARED_DATA_REASON

    return None


def allow_reason(resolved_path):
    parts = parts_of(resolved_path)

    if len(parts) >= 3 and parts[0] == "private" and parts[1] == "tmp" and parts[2].startswith("claude-"):
        return ALLOW_SCRATCHPAD_REASON

    for sub, why in ALLOW_HOME_PREFIXES:
        if under(resolved_path, os.path.join(HOME, *sub)):
            return why

    for comp, why in ALLOW_COMPONENTS:
        if comp in parts:
            return why

    for suffix, why in ALLOW_SUFFIXES:
        if resolved_path.endswith(suffix):
            return why

    return None


def classify(raw_path):
    resolved = os.path.realpath(raw_path)
    deny = deny_reason(resolved)
    if deny:
        return ("deny", resolved, deny)
    allow = allow_reason(resolved)
    if allow:
        return ("allow", resolved, allow)
    return ("unmatched", resolved, "no allow/deny rule matched — fail closed")


def policy_text():
    lines = ["ALLOW (removed without approval):"]
    lines.append(f"  /private/tmp/claude-*/**            {ALLOW_SCRATCHPAD_REASON}")
    for sub, why in ALLOW_HOME_PREFIXES:
        lines.append(f"  ~/{'/'.join(sub)}/**{' ' * max(1, 24 - len('/'.join(sub)))}{why}")
    for comp, why in ALLOW_COMPONENTS:
        lines.append(f"  **/{comp}/**{' ' * max(1, 25 - len(comp))}{why}")
    for suffix, why in ALLOW_SUFFIXES:
        lines.append(f"  **/*{suffix}{' ' * max(1, 25 - len(suffix))}{why}")
    lines.append("")
    lines.append("DENY (always refused, wins over allow even on double match):")
    for comp, why in DENY_COMPONENTS:
        lines.append(f"  **/{comp}/**{' ' * max(1, 25 - len(comp))}{why}")
    for sub, why in DENY_HOME_PREFIXES:
        lines.append(f"  ~/{'/'.join(sub)}/**{' ' * max(1, 24 - len('/'.join(sub)))}{why}")
    lines.append(f"  ~/gt/*/shared/data/**      {DENY_RIG_SHARED_DATA_REASON}")
    lines.append("")
    lines.append("Anything matching neither list is refused (fail-closed).")
    lines.append("Matching is on the RESOLVED path (symlinks and .. included);")
    lines.append("deletion itself acts on the literal argument, so a symlink is")
    lines.append("only ever unlinked, never dereferenced for deletion.")
    return "\n".join(lines)


def main(argv):
    check_only = False
    targets = []
    for arg in argv:
        if arg == "--check":
            check_only = True
        elif arg in ("-h", "--help"):
            print("Usage: safe-clean [--check] <path> [<path> ...]")
            print("  --check   classify only, delete nothing (exit 0 iff every path allowed)")
            print()
            print(policy_text())
            return 0
        else:
            targets.append(arg)

    if not targets:
        print("safe-clean: no paths given. Usage: safe-clean [--check] <path> [<path> ...]", file=sys.stderr)
        return 1

    verdicts = [(t,) + classify(t) for t in targets]
    refused = [v for v in verdicts if v[1] != "allow"]

    for raw, verdict, resolved, reason in verdicts:
        tag = {"allow": "ALLOW", "deny": "DENY", "unmatched": "REFUSE"}[verdict]
        print(f"[{tag}] {raw} -> {resolved} ({reason})")

    if refused:
        print(
            "safe-clean: refusing — not all targets are known-disposable. "
            "Nothing was deleted. Use `rm -rf` directly if this removal is "
            "actually intended (it will prompt for approval).",
            file=sys.stderr,
        )
        return 2

    if check_only:
        return 0

    import shutil

    failures = []
    for raw, verdict, resolved, reason in verdicts:
        if os.path.islink(raw) or os.path.exists(raw):
            try:
                if os.path.isdir(raw) and not os.path.islink(raw):
                    shutil.rmtree(raw)
                else:
                    os.remove(raw)
            except OSError as e:
                # A partial failure here must not look like success: swallowing
                # it (e.g. rmtree(ignore_errors=True)) would report exit 0 for
                # a target that's still partly on disk, indistinguishable from
                # one that was fully removed.
                failures.append((raw, str(e)))
        # Already absent: idempotent no-op, not an error.

    if failures:
        for raw, err in failures:
            print(f"safe-clean: failed to remove {raw}: {err}", file=sys.stderr)
        return 3

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
