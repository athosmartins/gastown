+++
name = "plugin-mail-cleanup"
description = "Close stale plugin mail beads left open after dog execution"
version = 1

[gate]
type = "cooldown"
duration = "2h"

[tracking]
labels = ["plugin:plugin-mail-cleanup", "category:cleanup"]
digest = false

[execution]
timeout = "2m"
notify_on_failure = false
severity = "low"
+++

# Plugin Mail Cleanup

Closes stale `Plugin: X` mail beads that dogs leave open after executing plugins.

## Background

When the daemon dispatches a plugin to a dog, it creates a task mail bead with
title `"Plugin: <name>"`. After execution, the dog creates an ephemeral result
wisp but never closes the original mail bead. These accumulate at ~12/hour per
plugin, creating noise.

## Action

Find open `Plugin:` mail beads older than 2 hours and close them:

```bash
# macOS-compatible cutoff (2 hours ago in ISO 8601)
CUTOFF=$(date -v-2H -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -d '-2 hours' -u +%Y-%m-%dT%H:%M:%SZ)

STALE_IDS=$(bd list --status=open --json 2>/dev/null \
  | jq -r --arg cutoff "$CUTOFF" \
    '.[] | select(.title | test("^Plugin: ")) | select(.created_at < $cutoff) | .id')

COUNT=0
for ID in $STALE_IDS; do
  [ -z "$ID" ] && continue
  bd close "$ID" --force --reason="plugin-mail-cleanup: stale plugin mail after dog execution" \
    2>/dev/null && COUNT=$((COUNT + 1))
done

echo "plugin-mail-cleanup: closed $COUNT stale plugin mail bead(s)"
```

## Record Result

```bash
bd create "plugin-mail-cleanup: closed $COUNT stale plugin mail bead(s)" \
  -t chore --ephemeral \
  -l type:plugin-run,plugin:plugin-mail-cleanup,result:success \
  --silent 2>/dev/null || true
```
