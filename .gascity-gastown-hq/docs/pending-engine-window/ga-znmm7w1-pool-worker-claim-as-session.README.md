# ga-znmm7w1 — a claude-headless worker claims under the pool ALIAS, then refuses the bead it just won

## Contents

• State · What was measured · Root cause · What the patch does · Tests · What it does NOT fix · Until the window · Apply / verify

Patch: `ga-znmm7w1-pool-worker-claim-as-session.patch` (4 files: `cmd/gc/cmd_prime.go` and the two core-pack prompts `pool-worker.template.md` / `graph-worker.template.md` edited, `cmd/gc/builtin_worker_prompt_claim_actor_test.go` new; +279 / -9).
Base: `consolidated/engine-window-20261023` (`8f1be0e2b3`), the same anchor as the other staged patches (`git rev-parse HEAD:cmd/gc/session_reconciler.go` = `66cdbdecbb`, the `index` line of `ga-fsm94q1`). It is the base of the live binary only according to the READMEs of 11/11 (not re-checked on the mini).
NOT applied. No build, no binary swap, no supervisor kickstart was done to produce it. The engine window stays Mayor-coordinated.

## State

Built and tested on the Hetzner node (Go 1.26.5 linux/arm64) from the exact base tarball. The new tests FAIL by assertion on the pristine base and pass on the patched tree (table below); `gofmt` is clean; the patch applies with `patch -p1` to a fresh base copy and reproduces the tested files byte for byte. No other pending patch touches these four files, and none declares the new test identifiers. The gate-fix revision of the tests (24/11) was run on the MBP through `mbp-run.sh --exec --go` on the same base: `gofmt -l` and `go vet ./cmd/gc/` clean, the six new tests pass patched; only those tests were run there, not the full `./cmd/gc` package. **Not verified on a running patched binary** (only possible after the window; checks below).

## What was measured

Reported by the bead (not re-measured): 2026-11-19, bead `wa-fj2lqh`, builder `whatsapp_automation/claude-headless-1`: 5 sessions claimed it in ~35 min, 0 commits, each one stopped by `session.stopped "drain acknowledged"` 2.5-3.7 min after its claim; `BEADS_ACTOR="$GC_SESSION_NAME" bd update <id> --claim` made it work.

Measured on this node, read-only through the bd shortcut:

- The session bead of the builder that finally held the bead (`ga-7bku77s`, closed) has `alias=whatsapp_automation/claude-headless-1`, `session_name=claude-headless-ga7bku77s`, `template=whatsapp_automation/claude-headless`, `pool_managed=true`, `pool_slot=1`, and its launch command is the city launcher `claude-ctxcap-ab.sh` with provider `claude-headless`: the engine-synthesized implicit agent, alias and session name are two different strings. That session bead was created 2026-11-19T22:49Z and closed 2026-11-20T17:03Z ("pool slot retired by reconciler"), and it wrote the comments of `wa-fj2lqh` from 2026-11-19 23:07Z to 2026-11-20 02:16Z: it ran for hours, which fits the bead's statement that the manual `BEADS_ACTOR="$GC_SESSION_NAME"` workaround made a session work (not re-measured here).
- Sweep of every `in_progress` bead of the six stores (24/11 ~22:35Z): 18 beads (whatsapp_automation 13, HQ 5, the other four rigs 0); none is assigned to a `claude-headless` identity, so nothing is stuck in the alias-claimed state today.

NOT measured (the node has no `.gc/`, no `gc events`, no live binary): the BEADS_ACTOR of a live claude-headless session; the event history behind "drain acknowledged"; which of the three prompts below the live binary hands the synthesized agent (it depends on the materialized core pack and on `formula_v2 = true` in `city.toml:752`). The patch therefore covers all three.

## Root cause

1. `bd update <id> --claim` writes the bd ACTOR as the assignee. The actor is the `--actor` flag, else `$BEADS_ACTOR`, else `$BD_ACTOR`, else git user.name (`third_party/beads/cmd/bd/main.go:696` `getActorWithGit`; `issueops/claim.go:36` `ClaimIssueInTx(..., actor)`).
2. For a pool slot the engine stamps `BEADS_ACTOR` with the slot ALIAS, not the session name: `setTemplateEnvIdentity` (`cmd/gc/build_desired_state.go:2642`, called at `:660`, `:2157` and, through `setPoolTemplateRuntimeIdentity`, `:2475`) overrides the `BEADS_ACTOR=sessName` default of `cmd/gc/template_resolve.go:247`.
3. The builtin worker prompts claim with a bare `bd update <id> --claim` and then require the opposite: "the assignee must be `$GC_SESSION_NAME`" (`defaultPrimePrompt` step 5; `pool-worker.template.md` step 5; `graph-worker.template.md` "How To Work" 3). The claim lands on the alias, the check fails, and the prompt says do NOT work the bead: `gc hook` again (it finds the same alias-assigned bead) or `gc runtime drain-ack`.
4. The controller does not rescue it. Its assigned-work match knows the session bead id, the session name and a named identity, not the alias (`cmd/gc/compute_awake_set.go:805` `sessionAssigneeMatches`), and the default pool-demand query deliberately does not count assigned in-progress work (`internal/config/config.go:4363`). A pool session whose only work is alias-claimed therefore has no wake reason and takes the "No reason to be awake" drain (`cmd/gc/session_reconciler.go:2510`). This step is read from the code, not observed live; it means that even a worker that ignored the verification would be drained.
5. The engine's own scripted claim already gets this right: `cmd/gc/cmd_agent_script.go:303` appends `--actor <agentScriptClaimActor()>` and that function prefers `GC_SESSION_NAME` (`:815`). Only the prompt text, which an LLM follows literally, lacks it.

The implicit agent is created in `internal/config/config.go:4645` with the builtin `pool-worker` prompt; `gc prime` falls back to `graph-worker` (formula_v2) or to `defaultPrimePrompt` (`cmd/gc/cmd_prime.go:372`, `:408`).

## What the patch does

Every `bd update <id> --claim` the three prompts tell the agent to run (or list as a tool) becomes `bd update <id> --claim --actor "$GC_SESSION_NAME"`, with one sentence (a comment in `pool-worker`, prose in the others) saying why the flag is not optional. Nothing else in the prompts moves: the verification still says the assignee must be the session name, which is now true. `--claim` stays the atomic compare-and-set (the flag only changes who "you" is), so a lost race still exits non-zero. The tutorial golden (`test/acceptance/tutorial_goldens/tutorial02_test.go:63`) looks for the substring `bd update <id> --claim` in the default prompt, which the new text still contains (checked by reading; that acceptance test was not run).

## Tests

`cmd/gc/builtin_worker_prompt_claim_actor_test.go` (reads the three texts the way the binary ships them: the const, and the two prompts materialized from the embedded core pack):

| test | pristine `8f1be0e2b3` | patched |
|---|---|---|
| `TestBuiltinWorkerPromptsClaimAsSessionActor` (every `bd update <bead> --claim` of each prompt carries `--actor "$GC_SESSION_NAME"`; and no line mentions a claim in a spelling the regexp does not capture, shell comments aside) | **FAIL** x3 prompts | pass |
| `TestBuiltinWorkerPromptClaimCommandRecordsTheSession` (runs each claim command through `sh` with a fake bd that resolves the actor like bd does, in an environment stamped like a pool slot: `BEADS_ACTOR`=alias, `GC_SESSION_NAME`=session) | **FAIL** x3: recorded `whatsapp_automation/claude-headless-1`, want `claude-headless-ga7bku77s` | pass |
| same test, control: the OLD bare `bd update ga-test1 --claim` must record the alias (the fake is not vacuous and the environment reproduces the incident) | pass | pass |
| `TestBuiltinWorkerPromptsVerifyTheClaimAgainstTheSessionName` (the EXACT verification wording of each prompt is still there: `claimVerificationPins`, 1 phrase for `defaultPrimePrompt` and `graph-worker`, 3 for `pool-worker`) | pass | pass |
| `TestClaimVerificationPinsGoRedWhenTheVerificationChanges` (mutate-then-red inside the test: each pin is retargeted to `$GC_ALIAS` and deleted in a copy of the real prompt, and each mutation must be reported missing) | pass | pass |
| `TestUnrecognisedClaimSpellingIsReported` (`gc bd update --claim <id>` style spellings are reported, comments and recognised claims are not) | pass | pass |

Gate fix (attempt 1, gate_run ga-ezyyt9c): the verification test used to be one loose `assign...$GC_SESSION_NAME` regexp over the whole prompt, which the startup queries (`bd list --assignee="$GC_SESSION_NAME"`) satisfy in all three prompts, so it stayed green with the verification deleted. Proven red now, on the real prompt files, by editing them on the node and running the tests (cmd/gc, 24/11):

| mutation of the patched prompts | result |
|---|---|
| `pool-worker` Step 5 `# assignee must be $GC_SESSION_NAME` -> `$GC_ALIAS` (claim still carries `--actor`) | `TestBuiltinWorkerPromptsVerifyTheClaimAgainstTheSessionName` **FAIL** |
| `graph-worker` "Verify the claimed bead is assigned to `$GC_SESSION_NAME`" -> "Verify the claimed bead" | same test **FAIL** |
| `defaultPrimePrompt` "The assignee must be `$GC_SESSION_NAME`" -> `$GC_ALIAS` | `TestBuiltinWorkerPromptsVerifyTheClaimAgainstTheSessionName` **FAIL** |
| `graph-worker` gets a second claim spelled `gc bd update --claim ga-9` | `TestBuiltinWorkerPromptsClaimAsSessionActor` **FAIL** (claim spelled in a way the tests do not recognise) |
| the three prompts' claim lines put back to the bare claim (pristine text) | claim tests **FAIL** x3 (recorded the alias), verification tests pass |

Neighbours, same selection on both trees (`-run 'Prime|Prompt|Builtin|Materialize|PoolWorker|GraphWorker|Implicit|Sling'` over `./cmd/gc ./internal/bootstrap/... ./internal/config/...`, umask 022): the only failures are `TestCmdSlingInlineBeadRigScopedBdProvider` and `TestCmdSlingInlineBeadBareTargetFromRigCwdBdProvider`, which fail identically on the pristine base (known baseline reds of the node). The full `./cmd/gc` package was not run for this patch.

## What it does NOT fix

- The controller's blindness to the alias (`sessionAssigneeMatches`) is left alone on purpose: the alias is reused by every incarnation of a slot, so counting it would let a dead incarnation's claim keep a new session awake (the alias-twin problem of ga-lotseol / ga-d63o9n1). With the prompt fix the claim is recorded under the name the controller does know.
- A claim typed without the flag from an LLM's memory, or by another tool, still records the alias. The launcher stopgap below covers every `bd` call of the implicit agent until the window.
- Explicit agents (dog, wa-worker, ps-worker, reviewers, crews) keep their prompts; they already verify against `$GC_SESSION_ID`, `$GC_SESSION_NAME` or `$GC_ALIAS`.
- `/gate-done` missing in these sessions is a different mechanism (see the bead comment).
- Upstream main restructured these prompts (implicit worker prompts are chosen at launch and resume, #9431). This patch is anchored on the live base, not on upstream main: after any rebase onto upstream, re-check that the claim line still carries the session actor.

## Until the window

The city launcher `packs/town-deltas/assets/scripts/claude-ctxcap-ab.sh` (the `command` of provider `claude-headless`) now hands the session its own name as `BEADS_ACTOR` when `GC_TEMPLATE` is `claude-headless` or `<rig>/claude-headless`, and only then. It is live for NEW launches as soon as the city repo reaches the mini (no engine change, no reload). Every launch that changes the value leaves `CLAIM-AS-SESSION template=... session=... was=...` in `$GC_CITY_PATH/.gc/logs/claude-lowprio.log`. Knobs: `GC_CLAIM_AS_SESSION=0` for one launch, `touch $GC_CITY_PATH/.gc/no-claim-as-session` for all new launches. After the window the stopgap is redundant but harmless.

## Apply / verify

```bash
P="$GC_CITY_PATH/docs/pending-engine-window/ga-znmm7w1-pool-worker-claim-as-session.patch"
git -C <engine-tree> apply --check "$P" && git -C <engine-tree> apply "$P"      # clean on 8f1be0e2b3
```

Read-only checks for the mini, because this node cannot make them:

1. Which prompt the synthesized agent really gets: `gc prime --strict whatsapp_automation/claude-headless | grep -n -E '^# |bd update'` (`# Pool Worker`, `# Graph Worker` or `# Gas City Agent`, and the claim line it prints).
2. After the city repo is live: launch (or wait for) one `whatsapp_automation/claude-headless` session, then `grep CLAIM-AS-SESSION "$GC_CITY_PATH/.gc/logs/claude-lowprio.log" | tail -3` shows `was=whatsapp_automation/claude-headless-<N>` and the session name.
3. The acceptance of the bead: route one trivial bead to `whatsapp_automation/claude-headless`; `bd -C whatsapp_automation show <id> --json | jq -r '.[0] | [.status, .assignee] | @tsv'` must read `in_progress` and `claude-headless-<tail>` (the session name, not `whatsapp_automation/claude-headless-<N>`); more than 10 minutes later the session is still in `gc session list --json` and `gc events` (run `gc events --help` for the filter flags) shows no `drain acknowledged` for it.

After the window: `strings $(readlink -f $(which gc)) | grep -c -- '--claim --actor'` returns more than `0`, and the supervisor was restarted after the swap.
