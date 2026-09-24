#!/usr/bin/env bash
# daemon-refresh.sh — post-deploy daemon refresh + freshness verification (ga-iwv0).
#
# THE BUG (ga-iwv0): the story-delivery deploy step is effectively `git pull`.
# It updates files on disk but does NOT restart long-lived launchd daemons, so a
# daemon-side feature merged into an already-running process stays DORMANT until
# that process happens to restart for some other reason — while the story is
# marked story:done. (ga-d81: com.whatsapp.ban-risk-dashboard served 5-day-old
# code; every new endpoint 404'd until an ops agent kickstarted it.)
#
# THIS HELPER closes the gap. Called by story-delivery.sh AFTER a deploy, given
# the pre/post deploy SHAs and the deploy timestamp, it:
#   1. Computes the source files the deploy actually changed (git diff).
#   2. Discovers the rig's long-lived launchd daemons from their plists
#      (ProgramArguments → the .py entrypoint it runs, following wrapper .sh).
#   3. Marks a daemon AFFECTED when its entrypoint changed, when a changed
#      shared module (routes/*.py, lib/*.py, …) is imported by its entrypoint
#      (the exact ga-d81 dashboard-mounts-route scenario), OR when a changed
#      Jinja template (*.html/*.htm/*.jinja/*.jinja2/*.j2) is rendered by its
#      entrypoint via render_template(...) — templates are compiled and cached
#      in-process (TEMPLATES_AUTO_RELOAD off in prod), so a disk-only template
#      edit was otherwise invisible here (ga-jkj0: com.whatsapp.map-viewer
#      served a stale layout twice despite "deployed + verified").
#   4. SAFE daemons (read-only dashboards): kickstart -k, then VERIFY the new
#      process actually started AFTER the deploy timestamp. A daemon that stays
#      stale (restart did not take / crash-loop) FAILS verification.
#   5. SENSITIVE hot-path daemons (central_sender, webhook_receiver,
#      slot_scheduler, conversation_monitor — matched via SENSITIVE_DAEMONS):
#      NEVER auto-bounced (in-flight messages/webhooks must be drained first).
#      They are FLAGGED for a guarded restart unless a DRAIN_CMD_<label> is
#      provided, in which case drain → kickstart → verify.
#   6. (ga-ylr2m) SENSITIVE_DAEMONS is a small, hand-maintained substring list
#      — the exact registry-drift gap this closes: it silently auto-kickstarted
#      frota_dashboard/demand_dashboard/campaign_dashboard, all notify_only_
#      locked or vetoed for a physical or in-flight-state reason in WA's own
#      restart_policy.yaml, because nobody had copied their names here yet.
#      When the rig ships that file at $RUNTIME_DIR/daemons/restart_policy.yaml
#      (e.g. whatsapp_automation), it is consulted DIRECTLY: a daemon whose
#      .py entrypoint is not explicitly listed under that file's 'auto'/
#      'deploy_restart' allowlists is ALSO treated SENSITIVE here — matching
#      the policy file's own documented default ("unlisted = manual"),
#      instead of requiring a human to keep a second copy of the same list in
#      sync. SENSITIVE_DAEMONS and the policy file are a UNION (either source
#      calling a daemon sensitive makes it sensitive) — this only ever ADDS
#      scrutiny, never removes it, and a rig with no restart_policy.yaml
#      behaves identically to before. Independently, any daemon named in that
#      file's 'restart_guard_scripts:' has its guard script consulted
#      immediately before EVERY kickstart of it (SAFE or drained-SENSITIVE) —
#      this script was a 4th, previously-unguarded restart trigger alongside
#      WA's own three (deploy_daemons.sh's two loops + auto_restart_daemons.py's
#      deploy_restart branch), closing the classification_dashboard
#      send-in-flight gap for this trigger too.
#   7. (ga-j3j6s; refined ga-puq8z) Before flagging a SENSITIVE daemon at all
#      (drain path or not), check whether its CURRENT live process already
#      started after the code was COMMITTED (COMMIT_EPOCH — the committer date
#      of POST_DEPLOY_SHA, computed near Step 1 below) — the same pid-start
#      primitives verify_fresh() uses to confirm a restart THIS script
#      performed, just compared against a different reference point. If it's
#      already fresh, some OTHER mechanism (e.g. the rig's own auto-deploy, or
#      a sibling bead's own guarded restart on the same shared daemon) already
#      restarted it; flagging NEEDS_GUARDED_RESTART here is a false positive
#      that pushes a human toward an unnecessary, non-zero-risk hot-path
#      restart (real incident: com.whatsapp.map-viewer flagged ~1m45s after
#      auto-deploy had already restarted it and was serving the new template).
#      Deliberately NOT a file-mtime comparison — a daemon can serve from a
#      different tree than the changed file, which would make an mtime check
#      lie; a pid-start-epoch is a process-clock timestamp, compared only
#      against the live PID's own start time (never a file path).
#      ga-puq8z GATE-FIX: the ga-j3j6s original compared against DEPLOY_EPOCH
#      (this check's OWN "now", captured by the CALLER right before its
#      deploy step) rather than COMMIT_EPOCH. DEPLOY_EPOCH can be minutes-to-
#      hours after the commit itself (gate-queue wait, deploy retry/backoff —
#      ga-d5rrr — or just a slow sweep cycle), and any restart that already
#      happened via another path is, by construction, always BEFORE "now" —
#      so the DEPLOY_EPOCH-only comparison was nearly impossible to satisfy
#      and under-caught exactly the case point 7 exists to catch (measured
#      2026-09-01: com.whatsapp.demand-dashboard flagged twice in 15 minutes,
#      both times already running code newer than the commit each check was
#      verifying).
#      ga-puq8z GATE-FIX-2 (gate_run=ga-9a45d, Reviewer-1 FAIL): the first
#      gate-fix's own safety claim here — "COMMIT_EPOCH <= DEPLOY_EPOCH always
#      holds, so this only ever ADDS true-fresh detections, never masks a real
#      stale daemon" — does not hold. The named SENSITIVE daemons run under
#      launchd KeepAlive=true; an unrelated crash/jetsam-OOM respawn landing
#      in the (COMMIT_EPOCH, DEPLOY_EPOCH) gap restarts the process from
#      whatever is STILL on disk — pre-commit code, since THIS deploy's own
#      checkout update (DEPLOY_EPOCH) has not happened yet — giving a
#      pid-start > COMMIT_EPOCH for a daemon that is in fact still stale. A
#      pid-start after COMMIT_EPOCH but NOT after DEPLOY_EPOCH is therefore a
#      real, useful CORRELATION (it rules out the common false-positive this
#      point exists to catch) but not a PROOF the live code matches — a
#      pid-start that ALSO clears DEPLOY_EPOCH is the identical bar
#      verify_fresh() uses and stays a genuine positive confirmation.
#      already_fresh() below skips the guarded-restart flag either way —
#      reverting to DEPLOY_EPOCH-only would just reintroduce the original
#      over-flagging bug — but reports PROOF=not_verified (never verified)
#      for the commit-only tier: the same disambiguation this script already
#      applies to every other case it cannot positively confirm (see the
#      PROOF block above).
#   8. (ga-y108i) Complementary to point 7's "is the PROCESS fresh?" question:
#      "does this CHANGE need a restart AT ALL?" A rig can declare, in its own
#      restart_policy.yaml, a global no_restart_paths: [glob, ...] list (e.g.
#      ["daemons/static/**"]) naming paths a daemon re-reads from disk on
#      EVERY request — a live process serving one is never stale, so its age
#      is irrelevant (real incident: a commit touching only daemons/static/
#      demand_previsao.js flagged the SENSITIVE demand-dashboard daemon for a
#      guarded restart; verified by hand that the live-served md5 already
#      matched the merged blob under the pre-merge PID — restarting would have
#      changed nothing). Checked FIRST, against the FULL raw changed-file set
#      (Step 1, before the *.py/template split below) — when EVERY changed
#      file matches a declared glob, this emits OK/asset_served_per_request
#      immediately, before daemon discovery or SENSITIVE/GUARDED classification
#      ever run. Path-based, deliberately NOT extension- or directory-guessed:
#      a *.py helper can be just as exemptable as a *.js file if the RIG says
#      so (e.g. a module that only proxies static bytes), and the reverse
#      holds too — this same rig's templates/ genuinely DOES need a restart
#      (Jinja is compiled+cached at import, point 3/ga-jkj0), so a
#      no_restart_paths glob covering only static/ must never accidentally
#      swallow templates/. A partially-covered changed set (even one file
#      outside every declared glob) does NOT exempt anything — falls straight
#      through to today's classification. An undeclared/absent key is a pure
#      no-op: identical to pre-ga-y108i behavior.
#   9. (ga-dk7fw) Point 8's no_restart_paths is opt-in per rig — real, but it
#      means a rig that never declared restart_policy.yaml (or forgot to list
#      a path there) gets ZERO benefit even for path classes that are
#      universally, unconditionally daemon-irrelevant on EVERY rig: a test
#      file (tests/**) or a doc file (docs/**, *.md) is never imported by any
#      daemon's runtime code, full stop — no rig-specific judgment call is
#      needed to know that, unlike static/ (point 8's own "a *.py helper can
#      be just as exemptable... if the RIG says so"). So this is a SECOND,
#      unconditional short-circuit, framework-default rather than rig-
#      declared, covering exactly {tests/**, docs/**, *.md} — deliberately NOT
#      static/** or templates/**, which stay point-8-only (rig opt-in) because
#      they are NOT universally safe (templates/ especially: blanket-exempting
#      it here would silently reintroduce the point-3/ga-jkj0 stale-Jinja-
#      template regression). Checked first in Step 1, same all-or-nothing
#      shape as point 8 (a mixed lib/+tests/ commit is NOT exempted — falls
#      through to full evaluation on its lib/ file, unchanged).
#  10. (ga-tdzsh) A plist that fails to parse (point 2's plist_args() exit 1
#      path) used to log the identical WARN regardless of whether that label
#      is a live, loaded daemon (real coverage gap: its code can go stale
#      with nobody warned — this hid com.gastown.dolt-server, the CITY'S
#      OWN DATA PLANE, until 2026-09-02/ga-dgrzf) or nothing loaded at all
#      (dead symlink, stale file — harmless). The harmless case is common
#      and noisy enough that it buried the real one. Now split by
#      daemon_is_loaded() (launchd LOAD status — NOT daemon_pid()/live-PID
#      presence, which is empty for both "not loaded" and "loaded but
#      idle" and so can't tell them apart): a loaded label gets an
#      ERROR-level log line naming it and lands in the new PARSE_ERROR_LOADED
#      output field/JSON key; an unloaded one gets a low-priority note and
#      lands in PARSE_ERROR_UNLOADED instead. Neither list feeds VERDICT —
#      an unrelated daemon's broken plist must never block THIS rig's
#      deploy gate — they exist purely so a consumer (a human, or a future
#      watchdog) can grep the structured output for a real gap without
#      reparsing log text.
#  11. (ga-q617u) Point 3's import-level match is single-hop: it only inspects
#      each entrypoint's OWN file for an import of the changed module. A
#      module imported ONLY by a daemons/routes/*.py blueprint file — never
#      by the entrypoint that mounts it — was invisible (real incident:
#      lib/assertiva_cache.py's read_pessoas_ref_items changed; its only
#      caller was daemons/routes/pregao.py, mounted by
#      classification_dashboard.py via `from routes import ..., pregao,
#      ...`; classification_dashboard.py itself never imports
#      assertiva_cache, so it was never flagged, while two UNRELATED
#      daemons that import assertiva_cache directly — for a DIFFERENT
#      function — were flagged instead: a false negative on the one daemon
#      that mattered, hidden behind two false positives on daemons that
#      didn't). daemon_imports_stem_via_routes() adds exactly one more hop,
#      scoped to <entrypoint-dir>/routes/*.py (mirrors the .sh-wrapper-follow
#      pattern in Step 2): a routes file only counts when the entrypoint
#      itself actually mounts it (imports its stem) — otherwise every
#      dashboard sharing one daemons/routes/ directory would inherit every
#      OTHER dashboard's route changes. Still not a full transitive closure
#      (a THIRD hop stays invisible), so the NEEDS_GUARDED_RESTART REASON
#      text now says the affected/guarded list itself can be INCOMPLETE (a
#      false negative), not only that a listed daemon can be a false
#      positive — pre-fix the message warned about just the latter.
#  12. (wa-jts45) Points 1-11 all answer "is a DAEMON's live PROCESS running
#      fresh code?" — a question that structurally cannot see a *.plist this
#      deploy adds/edits for a brand-new SCHEDULED job: it has no live PID to
#      compare staleness against (nothing to flag), and if the deploy touched
#      no .py/template file at all (e.g. scheduling an already-existing,
#      unchanged script for the first time), Step 1's own "no python source
#      or template changed" short-circuit emits OK/not_applicable without
#      ever looking at the new plist. Measured live (wa-sas9j): a merged,
#      gate:passed bead whose new launchd/*.plist was never copied into
#      LAUNCH_AGENTS_DIR at all — "no old process to flag" and "no process,
#      period" collapsed into the identical green signal for a month. Step 1b
#      (right after Step 1's CHANGED, before any early-exit) closes this: any
#      *.plist this deploy changed is checked for (a) present under
#      LAUNCH_AGENTS_DIR and (b) `launchctl list` sees its label — a new
#      VERDICT=JOB_NOT_INSTALLED when either fails. Deliberately NOT also
#      requiring "has it produced a successful run yet" — a job installed by
#      THIS deploy may legitimately not have reached its next scheduled
#      window (a daily 04:35 job checked at 23:00 has nothing to show), so
#      that would false-positive on every ordinary nightly-job delivery
#      instead of catching a real gap; left to the human follow-up named in
#      JOB_NOT_INSTALLED's own ACTION text.
#  13. (ga-pntex) Step 3's import-level/routes-hop matching (daemon_imports_
#      stem(), below) checks each daemon against each changed-file "stem" —
#      for N daemons x M changed .py files, up to N*M checks. Pre-fix, each
#      check re-invoked a fresh python3 ast.parse of the SAME entrypoint file
#      regardless of which stem it was being checked against — measured
#      live: a 33min citywide quality-gate stall (the serial dispatcher calls
#      this synchronously in its critical path), ~1-2 daemons/min processed,
#      ~1% CPU throughout (the cost was process-SPAWN overhead, not
#      computation). Fixed two ways: (a) each file's import-stem set is now
#      computed ONCE and cached (daemon_all_import_stems()), so a subsequent
#      check against the SAME file for a DIFFERENT stem is an in-memory
#      lookup, zero extra python3 spawns; (b) a changed tests/**/docs/** file
#      never contributes its own basename as a candidate stem in the first
#      place (CHANGED_STEMS, precomputed above) — same universal claim point
#      9/ga-dk7fw already established for the whole-changeset short-circuit,
#      applied per-file. (b) is not just a perf nit: pre-fix, a changed test
#      file whose basename happened to collide with a real module name some
#      daemon genuinely imports produced a false-positive AFFECTED.
#  14. (ga-9lsuq0) Points 11/13 still leave Step 3's .py-side matching a BARE-
#      NAME stem comparison (daemon_imports_stem(): every dot-separated
#      import component or "from X import Y" alias, with NO path resolution)
#      at most TWO hops deep (entrypoint + one routes/*.py hop, ga-q617u) —
#      unsound in BOTH directions: two unrelated real modules that happen to
#      share a basename (e.g. lib/x.py vs. daemons/routes/x.py) are
#      indistinguishable to a bare-name check (false positive: importing one
#      flags the daemon when the OTHER is what actually changed), and a real
#      dependency reached only through a THIRD hop or deeper is invisible
#      (false negative). Measured live (2 production deliveries cited on
#      ga-9lsuq0): reproducing the reported changed-file shapes against this
#      script's unmodified matching, in the investigating session's own
#      repro, did NOT reproduce the reported false-positive COUNTS (likely a
#      wider PRE/POST range than the isolated per-story diff used to repro,
#      or a measurement error in the original report — never isolated; see
#      the bead's resolution comment) — but the STRUCTURAL claim holds by
#      inspection regardless of that discrepancy: bare-name matching IS
#      collision-prone, and 2-hop IS not transitive. Separately,
#      whatsapp_automation already computes and SHIPS the correct answer:
#      daemons/deploy_deps.json (scripts/gen_daemon_deps.py) is a real,
#      path-resolved, fully RECURSIVE import closure per daemon entrypoint —
#      the SAME file scripts/compute_deploy_restarts.py already trusts for
#      its own (more consequential — unconditional auto-kickstart) restart
#      decision. Consulted here when present (opt-in by file presence,
#      mirroring restart_policy.yaml's own pattern — point 6): for any
#      entrypoint the file has a "closure" entry for, that closure ALONE
#      (intersected against this deploy's changed files) decides whether
#      THAT entrypoint counts as changed — REPLACING, not supplementing, the
#      ad-hoc direct/import-level/routes-hop checks for it (supplementing
#      via union would still let a bare-name false positive leak through).
#      An entrypoint the file does NOT mention (never generated for this
#      rig, or added after the last gen_daemon_deps.py run) still gets the
#      existing ad-hoc scan, UNCHANGED — coverage is only ever gained per
#      entrypoint, never lost, and a rig with no deploy_deps.json at all
#      (every rig but whatsapp_automation, today) is byte-for-byte
#      unaffected. Scoped to "closure" (the .py import graph) only —
#      template/asset matching (point 3/ga-jkj0) is untouched, a
#      structurally separate question the file tracks under a different key
#      ("assets") this fix does not consume.
#  15. (ga-1ivcn4) The precondition below (PRE_DEPLOY_SHA==POST_DEPLOY_SHA)
#      answers "did THIS invocation's own git-pull change anything" — a
#      question about a RACE, not about the bead. If some OTHER path (a
#      rig's 5-min cron, town-root-reconciler, a manual pull) already
#      advanced RUNTIME_DIR to the merge before this call's own deploy step
#      ran, PRE/POST_DEPLOY_SHA are BOTH already at (or past) that merge —
#      their delta is empty even though the merge itself may have changed
#      live runtime code no daemon has picked up yet. Measured live
#      (wa-ycyf8, 2026-09-17): exactly this let a P0 close with
#      VERDICT=SKIPPED/not_applicable while the affected daemon (notify_
#      only_locked, never auto-restarted) kept serving the old code — closed
#      as delivered with zero verification. When the caller also passes
#      BEAD_MERGE_PRE_SHA/BEAD_MERGE_SHA (point 14's own attribution inputs —
#      quality-gate-dispatcher.sh already computes and threads both
#      through), a true no-op pull now falls back to THAT range instead of
#      declaring SKIPPED outright: same guard chain Step 1b already
#      established (ga-agracx) — never trust the inputs blindly, only fall
#      back when both are non-empty, distinct, and BEAD_MERGE_PRE_SHA is a
#      confirmed ancestor of BEAD_MERGE_SHA in THIS runtime checkout. Every
#      step below (CHANGED, Step 1b, discovery, AFFECTED, restart/guard,
#      verdict) then runs exactly as it would for any other genuine delta —
#      a bead whose own merge is docs/tests-only still legitimately resolves
#      to OK/not_applicable (point 9), and one that reaches a live,
#      not-yet-restarted daemon now correctly reaches NEEDS_GUARDED_RESTART
#      instead of being hidden behind the race. Any guard failure (inputs
#      absent/unresolvable/not-an-ancestor/equal) — including every caller
#      that simply doesn't pass them, e.g. story-delivery.sh's own primary
#      call (it has its own separate MERGE_OWN_* side-channel probe instead
#      — see ga-6zkhci) — falls straight through to today's exact
#      SKIPPED/not_applicable behavior, zero regression.
#  16. (wa-flysp) GUARDED itself stays a single flat list (unchanged — callers
#      already parse it), but every label added to it is ALSO independently
#      classified as own-file-changed vs. closure-only: did THIS label's own
#      entrypoint file/template appear in the diff, or was it flagged only
#      because it (transitively) imports something else that changed? Real
#      incident this answers (wa-aknpy/wa-h140n, 2026-09-18): a daemon whose
#      OWN .py file changed — the single strongest signal this script has —
#      was buried inside a same-day 27-daemon GUARDED list dominated by
#      closure-only noise, and nobody could tell which of the 27 actually
#      mattered without manually re-deriving what Step 3 already knew and
#      threw away. GUARDED_OWN/GUARDED_CLOSURE_ONLY (new fields, always
#      present even empty — same convention as AFFECTED_NOT_RUNNING/
#      PARSE_ERROR_LOADED) surface that split structurally, and REASON's text
#      renders OWN-FILE-CHANGED first, CLOSURE-ONLY second, so the actionable
#      half is never buried under the noise. Presentation/attribution only —
#      changes NEITHER which labels land in GUARDED NOR the VERDICT; a
#      closure-only daemon is still exactly as blocking as before (point 1's
#      false-negative caveat — a real reachability gap can hide in either
#      bucket — is unaffected). A FORCE_RESTART_LABELS entry (point 5's
#      static override — reached only via that separate loop, never via
#      Step 3's own_hit computation, exactly because Step 2 couldn't resolve
#      an entrypoint for it at all — see T50/T61) is classified GUARDED_OWN
#      by construction: it is an explicit operator directive, the strongest
#      signal this script has, never "known closure-only noise".
#  17. (ga-8q1ulq, building on wa-th4b1) Point 16's split is still file-level:
#      "this label's own file is in the diff" vs. "this label only imports a
#      file that is". Measured live 18/09 on three real halts (wa-46k9n,
#      wa-6m0ec, wa-ut5lc): even with that split, each one still left 19-29
#      daemons with no way to tell which, if any, actually EXECUTES the
#      changed code — a human (thies-wa) walked the call graph by hand every
#      time, and the real answer was 1 daemon (or 0) each time (confirmed
#      even inside GUARDED_OWN: wa-ut5lc's com.whatsapp.conversation-monitor
#      had its own file in the diff yet was NOT among the daemons thies-wa
#      confirmed actually call a changed symbol — an own-file change can
#      still touch code nothing calls). The rig's own scripts/
#      compute_symbol_reachability.py (wa-th4b1, already gate-passed and
#      live) already answers "does this entrypoint's call graph reach a
#      symbol that actually changed", not just "does it import the file that
#      changed" — but nothing in this HQ copy ever called it: the WA rig's
#      own scripts/daemon-refresh.sh wrapper and daemon_refresh_advisory.py
#      do, but story-delivery.sh calls THIS file, which didn't (confirmed
#      live by the Mayor on wa-th4b1: "ela nunca chama o
#      compute_symbol_reachability.py ... só ranqueia own-file ×
#      closure-only"). When $RUNTIME_DIR/scripts/compute_symbol_
#      reachability.py exists, every label in GUARDED (both point-16
#      buckets — see the conversation-monitor case above) is independently
#      classified a THIRD way, via symbol_reachability_manifest_entry() +
#      one batched compute_symbol_reachability.py --batch call (ga-4oh2r6 —
#      see point 18 below for why this is one call, not one per label):
#        SYMBOL-CONFIRMED         — the entrypoint's call graph reaches a
#                                   symbol that changed in this window
#                                   (via=direct or via=graph).
#        SEM EVIDÊNCIA DE SÍMBOLO — ran cleanly, found no such path (still
#                                   just import-closure noise; same caveat as
#                                   CLOSURE-ONLY — not a full transitive
#                                   closure, a false negative can hide here).
#        NÃO CALCULADO            — no resolved entrypoint, the batch
#                                   invocation gave no usable answer at all
#                                   (nonzero exit or total-budget timeout), or
#                                   this label's own line never arrived in the
#                                   batch's output (killed mid-run — the
#                                   calculator flushes each entry as it
#                                   completes, so this only affects whichever
#                                   entries hadn't finished yet), or its answer
#                                   was reaches=false but the calculator's own
#                                   warnings flag the analysis as partial or
#                                   unrunnable (point 19). NEVER folded
#                                   into SEM EVIDÊNCIA — an unanswered
#                                   question is not a negative answer (the
#                                   same distinction PROOF's not_verified
#                                   already draws for the verdict as a whole,
#                                   applied here per daemon).
#      Presentation/attribution only, exactly like point 16: NEVER changes
#      VERDICT, NEVER removes a label from GUARDED or moves it between
#      GUARDED_OWN/GUARDED_CLOSURE_ONLY — only adds an independent, always-
#      present-even-empty third split (GUARDED_SYMBOL_CONFIRMED/_NO_EVIDENCE/
#      _NOT_COMPUTED) and a matching REASON section, rendered after the
#      point-16 sections. Window: prefers BEAD_MERGE_PRE_SHA/BEAD_MERGE_SHA
#      (this bead's own attribution range, point 14/ga-agracx) over the wider
#      PRE_DEPLOY_SHA/POST_DEPLOY_SHA when the same ancestor-guard used there
#      passes — a narrower, more relevant diff makes for a more precise
#      reachability answer, the same reason attribution prefers it elsewhere
#      in this file. Closure: the entrypoint's real deploy_deps.json closure
#      (point 14) when covered, else the full $CHANGED_PY set — coarser, but
#      Step 3's ad-hoc matching (direct/import-stem/routes-hop) does not
#      retain which specific changed file triggered a given label, and
#      threading that through its exactly-tuned branches is out of scope
#      here (see json_closure_for_entry()'s call site in
#      symbol_reachability_manifest_entry()). A same-named-function collision
#      this coarser closure can invite is the underlying tool's own
#      documented, accepted bias — it promotes toward SYMBOL-CONFIRMED rather
#      than hiding a real one. A rig without the script behaves identically
#      to today, no error: SYMBOL_SCRIPT simply doesn't exist, the whole
#      block is skipped, and all three new fields stay empty. Bounded cost:
#      SYMBOL_REACHABILITY_TOTAL_TIMEOUT for the ONE batch invocation (see
#      point 18) — tripping it degrades every label that hadn't finished
#      yet to NÃO CALCULADO rather than stalling the halt (the caller
#      already wraps this whole script in `timeout 180`).
#  18. (ga-4oh2r6, replacing point 17's per-label subprocess) Point 17 called
#      compute_symbol_reachability.py once PER GUARDED label — bounded by
#      SYMBOL_REACHABILITY_TIMEOUT (5s) per call and SYMBOL_REACHABILITY_
#      TOTAL_TIMEOUT (30s) for the whole loop. Measured live 18/09, the first
#      real production run after merge (story-delivery.log:120141-120158):
#      6 of 17 daemons hit the 5s per-daemon timeout, the other 11 were
#      skipped once the 30s total budget was already spent — 17/17 landed on
#      NÃO CALCULADO, the feature shipped live and delivered nothing on its
#      first real run. Root cause: each subprocess re-fetched (git show) and
#      re-parsed (ast) every file in its own entrypoint+closure from
#      scratch, with zero sharing across daemons — measured on this rig's
#      real deploy_deps.json, closures run 130-211 files each and overlap
#      ~86% between daemons (2517 summed paths across 17 daemons, 340
#      distinct). Fix: compute_symbol_reachability.py's --batch mode
#      (wa-zqyi4, companion bead, same "consult the rig, don't vendor a
#      second copy" choice this whole point-17/18 layer already made) takes
#      ALL of this run's GUARDED entries in one manifest and answers them in
#      one process with a shared (ref,path) cache — measured on the real
#      repro window (979f89533..d5383b04b, whatsapp_automation, same 17
#      daemons): ~3-5s total, where the unbatched loop had been timing out
#      at 30s on roughly half of repeated runs under this machine's real
#      load (`uptime` load average ~30 — fork/exec of hundreds of `git show`
#      subprocesses competes for scheduler CPU under load in a way one
#      persistent process's pipe I/O does not; see GitBatchReader in the
#      rig's compute_symbol_reachability.py). SYMBOL_REACHABILITY_TIMEOUT
#      (the old per-daemon bound) is gone — there is only one process now,
#      so only SYMBOL_REACHABILITY_TOTAL_TIMEOUT still applies, to that one
#      call. Classification semantics (SYMBOL-CONFIRMED/SEM EVIDÊNCIA DE
#      SÍMBOLO/NÃO CALCULADO, never promoted into VERDICT, never removing a
#      label from GUARDED) are UNCHANGED from point 17 — this point only
#      changes HOW the answer is computed, never what it means.
#  19. (ga-j3lh6p) A guarded daemon that restart_policy.yaml lists as
#      notify_only_locked ("Trava humana: NUNCA auto" — e.g. demand_dashboard
#      hosts the outreach_worker in-process, a restart halts outreach) can never
#      be made fresh by ANY automation. A consumer that holds a delivery for "a
#      still-stale guarded daemon" therefore holds it FOREVER once that is the
#      only one left (wa-z66jb 20/09: delivery:deploy-pending permanent, closed
#      by hand after ~20min of investigation, then wa-ho1ol the same day) —
#      even when point 17's split already says that daemon's entrypoint has NO
#      call-graph path to any symbol this window changed: staleness that is
#      cosmetic and never going to clear. Nothing consumed that answer.
#      GUARDED_LOCKED_COSMETIC names, in ONE place that owns both facts (the
#      policy file and the split), the GUARDED subset that is (a) locked — at
#      least one entrypoint in notify_only_locked and NOT explicitly
#      allow-listed in auto/deploy_restart (the same "explicitly safe first"
#      precedence policy_says_sensitive() applies), and only when the policy
#      PARSED (an unreadable file proves nothing is locked) — AND (b) in
#      GUARDED_SYMBOL_NO_EVIDENCE. It only ANNOTATES: VERDICT and GUARDED never
#      change; the consumers (story-delivery.sh Step 5b, quality-gate-
#      dispatcher.sh) decide, and release only on POSITIVE membership — every
#      still-stale label named here — never on an emptiness inferred from a
#      missing field. A locked daemon whose symbol IS reached (SYMBOL-CONFIRMED)
#      or was never computed stays a real hold: this is NOT "ignore
#      notify_only_locked".
#      What makes (b) trustworthy: compute_symbol_reachability.py returns
#      reaches=false not only for "analysed cleanly, found no path" but ALSO for
#      an unparseable or absent ENTRYPOINT ("reaches=False por padrão seguro",
#      "não dá pra avaliar") and after DROPPING a closure file whose structural
#      diff failed (a possible false negative). Those used to land in SEM
#      EVIDÊNCIA DE SÍMBOLO — harmless while that section was only presentation,
#      unsound the moment a release depends on it. They are NÃO CALCULADO now:
#      the same erro != vazio distinction point 17 already draws for a crash or a
#      missing line, applied to the calculator's own warnings. The ONE warning
#      that leaves the answer trustworthy is "<closure file>: ausente em --after
#      (<sha>) — ignorado" (a file added by a commit later than the range
#      examined, or deleted): nothing else about the analysis is affected, and
#      demanding zero warnings would only ever release a story merged at the tip
#      of the runtime (the closure JSON is the runtime's CURRENT one). A result
#      with no "warnings" list at all (a calculator that predates the field)
#      cannot be verified clean and is NÃO CALCULADO too.
#      The bound this puts on the claim: "no call-graph path" is not proof — a
#      changed module-level constant read by an unchanged function, or a call
#      chain the AST walk does not follow, is invisible to it (see point 17's
#      "not a full transitive closure"). For a daemon that automation may
#      restart that residual risk is what the guarded-restart hold exists for;
#      for one that automation may NEVER restart, the alternative is a hold that
#      can never clear, which is why only the locked class is released on it.
#  20. (ga-abofl6) Points 1-19 all answer "does this entrypoint's CLOSURE/import-
#      graph reach a changed file?" — a family of increasingly careful
#      REIMPLEMENTATIONS of that question, never a consultation of the rig's
#      OWN answer. MEDIDO 21/09: at the same instant, closure (what this script
#      used) said 16 daemons needed a restart; whatsapp_automation's own
#      scripts/detect_stale_daemons.py --mode own (already tested, already
#      scheduled daily via com.whatsapp.stale-daemons-daily, already the tool
#      that ESCALATES real staleness to a bead) said 2 — and of those 2, one
#      (campaign_scheduler) was itself cosmetic for a reason neither detector
#      alone could see (an added parameter whose else-branch is byte-identical
#      to the old code). Cost: four same-shaped alerts in one day demanding a
#      guarded restart of up to 14 production daemons — including
#      demand_dashboard, which hosts outreach and carries a human lock — each
#      requiring a human to read a diff by hand to learn it wasn't needed.
#      FIX (per CLAUDE.md's own "Deploy / Restart Hygiene": restart only who
#      actually USES the new symbol): when the rig exposes a verdict tool,
#      CONSUME it, don't reimplement it — two implementations of the same
#      question diverge by construction, which is exactly what happened here.
#      DESIGN CONSTRAINT this fix cannot violate: not every rig has this
#      detector, and "the rig said no" must never look identical to "the rig
#      has no way to say" — today those two collapse into the same silence.
#      So: $RUNTIME_DIR/scripts/detect_stale_daemons.py, when present, is
#      invoked ONCE (--mode own --no-fetch --json, bounded by
#      RIG_STALE_DETECTOR_TIMEOUT) for a {"known":[...],"affected":[...]}
#      answer keyed by entrypoint relpath — mirroring deploy_deps.json's own
#      K:/A: shape (header point 14) precisely so Step 3 below reuses the
#      identical "trust exclusively when covered, fall through only when it
#      isn't" pattern, with the rig detector taking precedence OVER deploy_
#      deps.json's broader closure (own mode already folds in registered
#      template/static assets AND one-hop imports — see detect_stale_
#      daemons.py's own docstring — so a covered entry's verdict already
#      accounts for what the ad-hoc/JSON-closure checks would otherwise ask).
#      RIG_DETECTOR_USED (rig-level: was it consulted successfully this run —
#      0 for both "absent" and "present but crashed/timed out/bad JSON", the
#      same fail-soft default every other point-14-shaped consultation in
#      this file already uses) plus AFFECTED_RIG_DETECTOR/GUARDED_RIG_
#      DETECTOR (label-level: which of THIS run's AFFECTED/GUARDED members
#      came from it) are the new always-present fields that let a consumer
#      tell "the rig detector ran and confirmed nothing needed restarting"
#      apart from "it was never asked" — the exact distinction this bead's
#      own description demanded, and the one thing an annotation-only layer
#      (points 16-19) could never provide, because none of those change
#      membership. This one does, deliberately: suppressing the false
#      positive IS the fix, not a side effect of one.
#
# VERDICT (last-resort gate): the caller must NOT mark a story:done unless the
# verdict is OK/SKIPPED. A dormant or unverifiable daemon halts delivery.
#
# PROOF (ga-vmq1i): VERDICT=OK/SKIPPED collapses two very different situations
# — "we positively confirmed a live daemon came up fresh" and "we never
# actually confirmed anything is running the new code" — into the same green
# light. The caller used to phrase BOTH as "deployed + verified in prod",
# which is a false claim for the second case. PROOF disambiguates:
#   verified       — a live daemon was confirmed running code from after
#                     DEPLOY_EPOCH: either restarted by THIS script and then
#                     confirmed fresh, or (ga-j3j6s) found ALREADY fresh via
#                     some OTHER restart path whose pid-start ALSO clears
#                     DEPLOY_EPOCH — same bar, same confidence, either way.
#                     (gate-fix-2, gate_run=ga-9a45d: an already-fresh match
#                     whose pid-start clears ONLY COMMIT_EPOCH — not also
#                     DEPLOY_EPOCH — is a commit-vs-check-time correlation, not
#                     this same positive confirmation; see already_fresh()'s
#                     AFR_TIER. Reported not_verified, even though the
#                     verdict still skips an unneeded guarded restart.)
#   not_applicable — structurally certain there was nothing live to verify
#                     (no source changed, no rig daemons exist at all, or the
#                     only daemon(s) tied to the change have no live PID to
#                     begin with — e.g. a scheduled job, not a dormant one).
#   asset_served_per_request (ga-y108i) — a stronger, path-proven refinement
#                     of not_applicable: every changed file matched a
#                     rig-declared restart_policy.yaml no_restart_paths glob
#                     (header point 8), so the content is structurally proven
#                     safe rather than merely un-flagged by extension. Callers
#                     must treat it identically to verified/not_applicable
#                     (never as not_verified) — see story-delivery.sh and
#                     quality-gate-dispatcher.sh's own PROOF case arms.
#   not_verified   — everything else: environment prevented checking (not a
#                     git work tree), or changed code could not be confidently
#                     tied to any live daemon by this script's (documented,
#                     single-hop) detection — which is NOT the same as
#                     confidently ruled out. Default when unset — fail closed.
#
# Output: machine-readable key=value lines + a trailing JSON object on STDOUT;
# all human logging goes to STDERR.
#   VERDICT=OK|SKIPPED|VERIFY_FAILED|NEEDS_GUARDED_RESTART|JOB_NOT_INSTALLED
#   AFFECTED=<labels>   RESTARTED=<labels>   FRESH_FAIL=<labels>   GUARDED=<labels>
#   GUARDED_OWN=<labels>   GUARDED_CLOSURE_ONLY=<labels>   (wa-flysp, header
#     point 16: always present, even empty. A partition of GUARDED — every
#     label in GUARDED is in exactly one of these two, never both, never
#     neither. OWN = this label's own entrypoint file/template is itself in
#     the diff. CLOSURE_ONLY = flagged only via a transitively-changed import/
#     route-hop/JSON-closure member, its own file untouched.)
#   GUARDED_SYMBOL_CONFIRMED=<labels>   GUARDED_SYMBOL_NO_EVIDENCE=<labels>
#     GUARDED_SYMBOL_NOT_COMPUTED=<labels>   (ga-8q1ulq, header point 17: a
#     THIRD, independent split of GUARDED, orthogonal to GUARDED_OWN/
#     GUARDED_CLOSURE_ONLY above — not a subdivision of either bucket. Always
#     present, even empty. All three stay empty when $RUNTIME_DIR/scripts/
#     compute_symbol_reachability.py does not exist.)
#   GUARDED_LOCKED_COSMETIC=<labels>   (ga-j3lh6p, header point 19: always
#     present, even empty. The subset of GUARDED that is BOTH notify_only_locked
#     in restart_policy.yaml (no automation may ever restart it) AND cleanly
#     classified GUARDED_SYMBOL_NO_EVIDENCE. Annotation only — VERDICT and
#     GUARDED never change. A consumer may stop holding a delivery for such a
#     daemon ONLY on positive membership: every still-stale label named here.)
#   RIG_DETECTOR_USED=0|1   AFFECTED_RIG_DETECTOR=<labels>
#     GUARDED_RIG_DETECTOR=<labels>   (ga-abofl6, header point 20: always
#     present. RIG_DETECTOR_USED is rig-level — 1 only when $RUNTIME_DIR/
#     scripts/detect_stale_daemons.py exists AND this run's --mode own --json
#     call succeeded; 0 covers both "absent" and "present but failed", so a
#     consumer must check it before treating an empty AFFECTED_RIG_DETECTOR as
#     "the rig confirmed everything fresh" rather than "never asked". The
#     other two are label-level: unlike GUARDED_OWN/CLOSURE_ONLY (a partition
#     of GUARDED) or GUARDED_SYMBOL_* (an annotation that never changes
#     membership), these mark labels whose AFFECTED/GUARDED membership itself
#     was DECIDED by the rig detector — this layer suppresses false positives,
#     it does not just describe them.)
#   WOULD_RESTART=<labels>   (ga-omfwe: DRY_RUN=1 only — labels that would be
#     restarted for real; RESTARTED is always empty under DRY_RUN=1, so the
#     two never collapse into the same string)
#   PARSE_ERROR_LOADED=<labels>   PARSE_ERROR_UNLOADED=<labels>   (ga-tdzsh:
#     always present, even empty — launchd-loaded vs. not, for any plist
#     that failed to parse; see header point 10. Informational only, never
#     feeds VERDICT.)
#   REASON=<text>   PROOF=verified|not_applicable|asset_served_per_request|not_verified
# Exit 0 when VERDICT is OK/SKIPPED (or DRY_RUN=1); non-zero otherwise.
#
# Inputs (env):
#   RUNTIME_DIR       deployed git work tree (e.g. /Users/athos/gt/whatsapp_automation)
#                     (ga-ylr2m) if $RUNTIME_DIR/daemons/restart_policy.yaml
#                     exists, it is consulted directly — see header point 6
#                     (and point 8/ga-y108i for its no_restart_paths key).
#   PRE_DEPLOY_SHA    HEAD before deploy
#   POST_DEPLOY_SHA   HEAD after deploy
#   DEPLOY_EPOCH      unix epoch captured immediately before deploy
#   SENSITIVE_DAEMONS space/newline-separated launchd-label substrings (hot-path)
#   EXTRA_RUNTIME_ROOTS (ga-00ptz) space/newline-separated absolute paths of
#                     OTHER independently-deployed clones of this same rig's
#                     repo (e.g. painel-prod, a hand-synced second checkout of
#                     whatsapp_automation kept fresh by its own deploy-sync
#                     job, not by this pipeline's git-pull). A plist entrypoint
#                     under one of these is resolved to the relpath it shares
#                     with RUNTIME_DIR — see resolve_relpath() — so a daemon
#                     running from a second clone of the SAME source is still
#                     discovered. Never invents an entrypoint: the relpath must
#                     also actually exist under RUNTIME_DIR. Empty = none
#                     (identical to pre-ga-00ptz behavior).
#   DRY_RUN           1 = report only, no kickstart/verify (default 0)
#   DRAIN_CMD_<label> optional graceful-drain command for a sensitive daemon
#                     (<label> sanitized: non-alnum → _)
#   DAEMON_BASELINE_OVERRIDES (ga-0fawwr) optional per-daemon baseline
#                     narrowing — one "<label> <sha>" pair per line. See the
#                     big comment at its point of use (end of Step 3, just
#                     before Step 4) for the full rationale. Empty (default)
#                     = identical behavior to before this fix.
# Test seams:
#   LAUNCH_AGENTS_DIR (default $HOME/Library/LaunchAgents)
#   LAUNCHCTL_BIN     (default launchctl)
#   PS_BIN            (default ps)
#   VERIFY_TIMEOUT    seconds to wait for a fresh process (default 20)
#   VERIFY_INTERVAL   poll interval seconds (default 1)
#   SYMBOL_REACHABILITY_TOTAL_TIMEOUT   seconds for the ONE batched
#                     compute_symbol_reachability.py --batch call covering
#                     every GUARDED label this run (default 30; ga-8q1ulq,
#                     header point 17, batched by point 18/ga-4oh2r6 — there
#                     used to be a SYMBOL_REACHABILITY_TIMEOUT per-daemon
#                     bound too, removed with the per-label subprocess loop
#                     it governed) — tripping it degrades whichever labels
#                     hadn't finished yet to NÃO CALCULADO.
#   RIG_STALE_DETECTOR_TIMEOUT   seconds for the ONE $RUNTIME_DIR/scripts/
#                     detect_stale_daemons.py --mode own --json call (default
#                     30; ga-abofl6, header point 20) — tripping it, or the
#                     script failing/being absent, leaves RIG_DETECTOR_USED=0
#                     and every entrypoint falls through to today's exact
#                     deploy_deps.json/ad-hoc behavior (fail-soft).

set -uo pipefail

RUNTIME_DIR="${RUNTIME_DIR:-}"
PRE_DEPLOY_SHA="${PRE_DEPLOY_SHA:-}"
POST_DEPLOY_SHA="${POST_DEPLOY_SHA:-}"
DAEMON_BASELINE_OVERRIDES="${DAEMON_BASELINE_OVERRIDES:-}"
# ga-agracx: OPTIONAL attribution-narrowing inputs, distinct from PRE/POST_
# DEPLOY_SHA above. PRE/POST_DEPLOY_SHA is the WIDE runtime-checkout window
# (correct for "is ANY daemon/job stale on this rig") — when the runtime
# fell behind (a previous deploy failed/skipped), that window can span
# SEVERAL beads' merges at once, so Step 1b's plist-installation check below
# used to attribute a gap to whichever bead's deploy happened to close the
# window, not the one that actually introduced it (same root class ga-3bdttu
# fixed for story-delivery.sh's own blame decision, one caller up the stack —
# see tests/story-delivery-daemon-refresh-attribution.test.sh). When a caller
# passes BOTH of these (its own merge's pre-image and the merge commit
# itself — quality-gate-dispatcher.sh already computes both as MERGE_PRE_
# MAIN_SHA/MERGE_SHA before this call), Step 1b narrows JUST the blocking
# JOB_NOT_INSTALLED verdict to gaps that range actually introduced, without
# ever suppressing the underlying alert (see SJ_UNATTRIBUTED_REASON below).
# Left empty by any caller that doesn't pass them (e.g. story-delivery.sh's
# own call) — falls back to today's exact behavior, zero regression.
BEAD_MERGE_PRE_SHA="${BEAD_MERGE_PRE_SHA:-}"
BEAD_MERGE_SHA="${BEAD_MERGE_SHA:-}"
DEPLOY_EPOCH="${DEPLOY_EPOCH:-0}"
SENSITIVE_DAEMONS="${SENSITIVE_DAEMONS:-}"
EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}"
# ga-fzfqsu: launchd labels the caller wants ALWAYS restarted+verified
# regardless of whether Step 2/3 below can discover or entrypoint-match them
# (delivery-runbooks.toml's daemon_restarts — a static, unconditional list;
# see the Step 3 boundary below for how this merges into AFFECTED). Space-
# separated. Empty (the default) changes nothing about existing behavior.
FORCE_RESTART_LABELS="${FORCE_RESTART_LABELS:-}"
DRY_RUN="${DRY_RUN:-0}"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
PS_BIN="${PS_BIN:-ps}"
# ga-8q1ulq (header point 17), batched by point 18/ga-4oh2r6: bounds the cost
# of the ONE symbol-reachability --batch call covering every GUARDED label
# this run — a rig-side git-show+AST-heavy computation, not a cheap check.
# Tripping it degrades whichever label(s) hadn't finished yet to NÃO
# CALCULADO, never blocks the halt past it. There used to be a second,
# per-daemon SYMBOL_REACHABILITY_TIMEOUT bound here too; it governed the
# per-label subprocess loop point 18 replaced, and has no meaning against a
# single batched call, so it's gone — only the total budget remains.
SYMBOL_REACHABILITY_TOTAL_TIMEOUT="${SYMBOL_REACHABILITY_TOTAL_TIMEOUT:-30}"
# ga-abofl6 (header point 20): bounds the ONE detect_stale_daemons.py --json
# call below. Same "trip it, degrade to today's exact fallback" shape as
# SYMBOL_REACHABILITY_TOTAL_TIMEOUT above, never blocks the halt past it.
RIG_STALE_DETECTOR_TIMEOUT="${RIG_STALE_DETECTOR_TIMEOUT:-30}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-20}"
VERIFY_INTERVAL="${VERIFY_INTERVAL:-1}"

log() { echo "[daemon-refresh] $*" >&2; }

# ── restart_policy.yaml consultation (ga-ylr2m) ───────────────────────────────
# See header point 6. Parsed once, up front, into space-separated .py-basename
# lists (POLICY_AUTO / POLICY_DEPLOY_RESTART / POLICY_NOTIFY_ONLY_LOCKED) plus
# a "daemon.py=script/relpath" pair list (POLICY_GUARDS) plus a space-separated
# glob-pattern list (POLICY_NO_RESTART_PATHS — ga-y108i, header point 8).
# Three distinct states,
# kept distinct on purpose (self-audit finding — "not found" and "found but
# unreadable" must NOT collapse to the same value just because both end up with
# empty POLICY_* lists):
#   no file at all       → RESTART_POLICY_YAML doesn't exist. This rig genuinely
#                           has no stricter registry; defer entirely to
#                           SENSITIVE_DAEMONS, IDENTICAL to pre-ga-ylr2m behavior.
#   file exists, parses  → POLICY_PARSE_OK=1. Empty lists here are a REAL "this
#                           policy clears nothing", handled correctly by
#                           policy_says_sensitive()'s normal per-entrypoint logic.
#   file exists, does
#   NOT parse (rare —
#   e.g. a future edit
#   breaks this subset
#   parser's assumptions) → POLICY_PARSE_OK stays unset even though the file is
#                           present. We cannot prove this rig has nothing extra
#                           to be careful about — the third state — so
#                           policy_says_sensitive()/guard_allows_restart() below
#                           treat this as "everything on this rig is sensitive
#                           and every restart is refused" until the file parses
#                           again. This can only ADD caution vs. the no-file
#                           case, never silently fall back to it.
RESTART_POLICY_YAML="$RUNTIME_DIR/daemons/restart_policy.yaml"
POLICY_AUTO=""; POLICY_DEPLOY_RESTART=""; POLICY_NOTIFY_ONLY_LOCKED=""; POLICY_GUARDS=""; POLICY_NO_RESTART_PATHS=""; POLICY_PARSE_OK=""
# ga-gjum0y: scheduled-job labels a rig owner has deliberately decided NOT to
# install/load (recorded decision, not a gap) — see Step 1b below, at its
# point of use, for the full incident this closes.
POLICY_SCHEDULED_JOB_OPT_OUT=""
if [ -f "$RESTART_POLICY_YAML" ]; then
  eval "$(python3 - "$RESTART_POLICY_YAML" <<'PY' 2>/dev/null
import re, shlex, sys

def scalar(v):
    v = v.strip()
    if v[:1] in "'\"" and v[-1:] == v[:1]:
        return v[1:-1]
    low = v.lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("null", "~", ""):
        return None
    if low == "{}":
        return {}
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v

def load_policy(path):
    # Subset-YAML reader mirroring whatsapp_automation/scripts/
    # lint_restart_policy.py's load_policy(): top-level 'k: v', '- item'
    # lists, indented 'k: v' nested dicts; full-line and trailing ' #'
    # comments stripped. Keep the two in sync if that file's supported
    # subset ever changes — this is a deliberate, documented duplication of
    # a small (~30-line) already-reviewed parser, not a second design.
    out = {}
    cur_key = None
    cur_kind = None  # 'list' | 'dict'
    for raw in open(path, encoding="utf-8"):
        line = raw.split(" #", 1)[0].rstrip() if " #" in raw else raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indented = line[0] in " \t"
        s = line.strip()
        if not indented:
            key, _, val = s.partition(":")
            key = key.strip()
            if val.strip() == "":
                out[key], cur_key, cur_kind = None, key, None
            else:
                out[key], cur_key, cur_kind = scalar(val), None, None
        elif s.startswith("- "):
            if cur_kind != "list":
                out[cur_key], cur_kind = [], "list"
            out[cur_key].append(scalar(s[2:]))
        else:
            if cur_kind != "dict":
                out[cur_key], cur_kind = {}, "dict"
            k, _, v = s.partition(":")
            out[cur_key][k.strip()] = scalar(v)
    return out

try:
    policy = load_policy(sys.argv[1])
except Exception:
    policy = None   # distinct from "parsed to an empty dict" — see bash comment above

def strlist(key):
    return " ".join(str(x) for x in (policy.get(key) or []) if isinstance(x, str))

# Only emit POLICY_* (including the OK marker) on a SUCCESSFUL parse. On
# failure this prints nothing at all, so the eval below is a no-op and every
# POLICY_* var (POLICY_PARSE_OK included) keeps its pre-set empty default —
# the signal bash checks for the unparseable third state.
if policy is not None:
    print("POLICY_AUTO=" + shlex.quote(strlist("auto")))
    print("POLICY_DEPLOY_RESTART=" + shlex.quote(strlist("deploy_restart")))
    print("POLICY_NOTIFY_ONLY_LOCKED=" + shlex.quote(strlist("notify_only_locked")))
    print("POLICY_NO_RESTART_PATHS=" + shlex.quote(strlist("no_restart_paths")))
    print("POLICY_SCHEDULED_JOB_OPT_OUT=" + shlex.quote(strlist("scheduled_job_opt_out")))
    guards = policy.get("restart_guard_scripts") or {}
    if isinstance(guards, dict):
        pairs = " ".join(f"{d}={s}" for d, s in guards.items()
                          if isinstance(d, str) and isinstance(s, str))
        print("POLICY_GUARDS=" + shlex.quote(pairs))
    print("POLICY_PARSE_OK=1")
PY
)" 2>/dev/null || true
  if [ -z "$POLICY_PARSE_OK" ]; then
    log "WARN: $RESTART_POLICY_YAML exists but could not be parsed — cannot verify its content, so every daemon on this rig is treated as policy-sensitive and every guarded restart is refused until it parses again (fail closed, not silently ignored)."
  fi
fi

# ── emit result + exit ────────────────────────────────────────────────────────
emit() {  # emit <verdict> <reason> [<proof>]  (proof defaults to not_verified — fail closed)
  local verdict="$1" reason="$2" proof="${3:-not_verified}"
  # gate ga-ax0t9: Step 1b USED TO call emit directly, and emit exits (see the
  # bottom of this function). That foreclosed Step 2 entirely: a deploy that both
  # shipped an uninstalled scheduled-job plist AND changed a SENSITIVE daemon
  # running stale code reported ONLY the plist, with GUARDED empty — which reads
  # exactly like "there was no other problem". Proven by the reviewer against this
  # very SHA: combining fixtures T4 + T37 in one deploy produced
  # VERDICT=JOB_NOT_INSTALLED, GUARDED= (empty), and the mock launchctl kicks.log
  # was never even created — the staleness check had not run at all.
  #
  # Now Step 1b only RECORDS its finding and lets Step 2 run. Whichever emit
  # finally fires carries both: the verdict stays JOB_NOT_INSTALLED (an
  # uninstalled job is at least as actionable as anything Step 2 finds, and
  # consumers already branch on it), while AFFECTED/GUARDED/RESTARTED — filled in
  # by Step 2 by the time we get here — stop being silently empty. The two are
  # not alternatives; they can both be true, and the report has to say so.
  if [ -n "${SJ_PENDING_REASON:-}" ] && [ "$verdict" != "JOB_NOT_INSTALLED" ]; then
    reason="$SJ_PENDING_REASON — AND ALSO ($verdict): $reason"
    verdict="JOB_NOT_INSTALLED"
    # O proof tem de vir junto. Step 1b nunca verificou o job (ele nem esta
    # instalado pra rodar), entao herdar o proof do Step 2 — que pode ser
    # "not_applicable" — afirmaria algo que ninguem checou. Fail closed, igual
    # ao default do proprio emit.
    proof="not_verified"
  fi
  echo "VERDICT=$verdict"
  # ga-0fawwr: every label THIS run's discovery actually examined (empty on
  # every early-precondition emit above, before discovery ever ran — nothing
  # to report). Lets the caller (story-delivery.sh) advance a per-daemon
  # baseline marker for whichever labels are NOT in GUARDED/FRESH_FAIL below,
  # independently of every other daemon on the same rig — see
  # DAEMON_BASELINE_OVERRIDES above for the full mechanism this feeds.
  echo "ALL_LABELS=${DAEMON_LABELS:-}"
  echo "AFFECTED=${AFFECTED:-}"
  # wa-xokje: always present (even empty), same convention as
  # PARSE_ERROR_LOADED/UNLOADED below — a caller can check it unconditionally
  # without reparsing log text.
  echo "AFFECTED_NOT_RUNNING=${AFFECTED_NOT_RUNNING:-}"
  echo "RESTARTED=${RESTARTED:-}"
  echo "FRESH_FAIL=${FRESH_FAIL:-}"
  echo "GUARDED=${GUARDED:-}"
  # wa-flysp (header point 16): always present, even empty — same convention
  # as AFFECTED_NOT_RUNNING/PARSE_ERROR_LOADED above. A partition of GUARDED:
  # every label in GUARDED is in exactly one of these two, never both.
  echo "GUARDED_OWN=${GUARDED_OWN:-}"
  echo "GUARDED_CLOSURE_ONLY=${GUARDED_CLOSURE_ONLY:-}"
  # ga-8q1ulq (header point 17): a THIRD, independent split of GUARDED —
  # always present, even empty, same convention as GUARDED_OWN/
  # GUARDED_CLOSURE_ONLY above. All three stay empty when the rig has no
  # compute_symbol_reachability.py.
  echo "GUARDED_SYMBOL_CONFIRMED=${GUARDED_SYMBOL_CONFIRMED:-}"
  echo "GUARDED_SYMBOL_NO_EVIDENCE=${GUARDED_SYMBOL_NO_EVIDENCE:-}"
  echo "GUARDED_SYMBOL_NOT_COMPUTED=${GUARDED_SYMBOL_NOT_COMPUTED:-}"
  # ga-j3lh6p (header point 19): always present, even empty — a subset of
  # GUARDED (locked against automation AND cleanly no-evidence). A consumer
  # reads it unconditionally; an absent line means an older helper and is never
  # the same as an empty one.
  echo "GUARDED_LOCKED_COSMETIC=${GUARDED_LOCKED_COSMETIC:-}"
  # ga-xrn8ni (header point 21): always present, even empty — same convention
  # as GUARDED_LOCKED_COSMETIC just above, of which this is a sibling (excused
  # via a missing $DRAIN_CMD_<label>, not via restart_policy.yaml). A consumer
  # reads it unconditionally; an absent line means a helper that predates it.
  echo "GUARDED_NODRAIN_COSMETIC=${GUARDED_NODRAIN_COSMETIC:-}"
  # ga-abofl6 (header point 20): always present, even empty — same convention
  # as every other field above. RIG_DETECTOR_USED distinguishes "consulted,
  # confirmed nothing" (AFFECTED_RIG_DETECTOR/GUARDED_RIG_DETECTOR empty, USED=1)
  # from "never asked" (empty, USED=0) — the one thing this run's fallback to
  # today's closure/ad-hoc behavior must never let look the same as a positive
  # rig confirmation.
  echo "RIG_DETECTOR_USED=${RIG_DETECTOR_USED:-0}"
  echo "AFFECTED_RIG_DETECTOR=${AFFECTED_RIG_DETECTOR:-}"
  echo "GUARDED_RIG_DETECTOR=${GUARDED_RIG_DETECTOR:-}"
  echo "ALREADY_FRESH=${ALREADY_FRESH:-}"
  echo "WOULD_RESTART=${WOULD_RESTART:-}"
  # ga-tdzsh: always present (even on the early-precondition emits above,
  # before plist discovery ever ran, where these are simply empty) so a
  # consumer can diff this field across runs without reparsing log text —
  # see daemon_is_loaded()/the discovery-loop split above for what feeds it.
  echo "PARSE_ERROR_LOADED=${PARSE_ERROR_LOADED:-}"
  echo "PARSE_ERROR_UNLOADED=${PARSE_ERROR_UNLOADED:-}"
  echo "REASON=$reason"
  echo "PROOF=$proof"
  # ga-agracx: a Step 1b plist gap this bead's own merge did NOT introduce —
  # deliberately never folded into $reason or forced into $verdict (that
  # would just reintroduce the misattribution this field exists to avoid).
  # Always present (even empty) so a caller can check it unconditionally,
  # same convention as PARSE_ERROR_LOADED/UNLOADED above.
  echo "UNATTRIBUTED_JOB_GAP=${SJ_UNATTRIBUTED_REASON:-}"
  # Trailing JSON for the caller's bead comment / jsonl log.
  python3 - "$verdict" "$reason" "${AFFECTED:-}" "${RESTARTED:-}" "${FRESH_FAIL:-}" "${GUARDED:-}" "$proof" "${ALREADY_FRESH:-}" "${WOULD_RESTART:-}" "${PARSE_ERROR_LOADED:-}" "${PARSE_ERROR_UNLOADED:-}" "${SJ_UNATTRIBUTED_REASON:-}" "${AFFECTED_NOT_RUNNING:-}" "${GUARDED_OWN:-}" "${GUARDED_CLOSURE_ONLY:-}" "${GUARDED_SYMBOL_CONFIRMED:-}" "${GUARDED_SYMBOL_NO_EVIDENCE:-}" "${GUARDED_SYMBOL_NOT_COMPUTED:-}" "${GUARDED_LOCKED_COSMETIC:-}" "${GUARDED_NODRAIN_COSMETIC:-}" "${AFFECTED_RIG_DETECTOR:-}" "${GUARDED_RIG_DETECTOR:-}" "${RIG_DETECTOR_USED:-0}" <<'PY' 2>/dev/null || true
import json, sys
v, reason, aff, res, ff, gd, proof, afr, wr, pel, peu, ujg, anr, gd_own, gd_co, gd_sc, gd_sne, gd_snc, gd_lc, gd_ndc, afr_rig, gd_rig, rdu = sys.argv[1:24]
sp = lambda s: [x for x in s.split() if x]
print("JSON=" + json.dumps({
    "verdict": v, "reason": reason,
    "affected": sp(aff), "affected_not_running": sp(anr), "restarted": sp(res),
    "fresh_fail": sp(ff), "guarded": sp(gd), "proof": proof,
    "guarded_own": sp(gd_own), "guarded_closure_only": sp(gd_co),
    "guarded_symbol_confirmed": sp(gd_sc), "guarded_symbol_no_evidence": sp(gd_sne),
    "guarded_symbol_not_computed": sp(gd_snc),
    "guarded_locked_cosmetic": sp(gd_lc),
    "guarded_nodrain_cosmetic": sp(gd_ndc),
    "affected_rig_detector": sp(afr_rig), "guarded_rig_detector": sp(gd_rig),
    "rig_detector_used": rdu == "1",
    "already_fresh": sp(afr), "would_restart": sp(wr),
    "parse_error_loaded": sp(pel), "parse_error_unloaded": sp(peu),
    "unattributed_job_gap": ujg,
}))
PY
  if [ "$DRY_RUN" = "1" ]; then exit 0; fi
  case "$verdict" in OK|SKIPPED) exit 0 ;; *) exit 1 ;; esac
}

AFFECTED=""; RESTARTED=""; FRESH_FAIL=""; GUARDED=""; ALREADY_FRESH=""; WOULD_RESTART=""
# wa-flysp (header point 16): AFFECTED_OWN is a subset of AFFECTED (which
# labels' own file/template changed); GUARDED_OWN/GUARDED_CLOSURE_ONLY
# partition GUARDED the same way, built from it at Step 4 below.
AFFECTED_OWN=""; GUARDED_OWN=""; GUARDED_CLOSURE_ONLY=""
# ga-8q1ulq (header point 17): a THIRD, independent split of GUARDED, built
# lazily in Step 5 (not here at Step 3/4, unlike GUARDED_OWN/
# GUARDED_CLOSURE_ONLY) — see symbol_reachability_for()'s call site.
GUARDED_SYMBOL_CONFIRMED=""; GUARDED_SYMBOL_NO_EVIDENCE=""; GUARDED_SYMBOL_NOT_COMPUTED=""
# ga-j3lh6p (header point 19): the subset of GUARDED that is locked against
# automation AND cleanly classified no-evidence. Built in Step 5, right after
# the three lists above are final; empty on every path that never reaches it.
GUARDED_LOCKED_COSMETIC=""
# ga-xrn8ni (header point 21): a SIBLING split, same shape as GUARDED_LOCKED_
# COSMETIC just above but for a daemon that cannot be auto-restarted for a
# DIFFERENT durable reason — SENSITIVE with no $DRAIN_CMD_<label> configured
# (this script's own "NO drain path configured -- NOT auto-bounced" log line
# below), never notify_only_locked. Kept as its own field rather than folded
# into GUARDED_LOCKED_COSMETIC: the two reasons are not interchangeable in the
# human-facing text a consumer builds from them ("notify_only_locked in
# restart_policy.yaml" would be a FALSE claim about a daemon that isn't in
# that file at all) — see label_no_drain_configured() below.
GUARDED_NODRAIN_COSMETIC=""
# ga-abofl6 (header point 20): AFFECTED_RIG_DETECTOR is a subset of AFFECTED
# (built at Step 3, same boundary as AFFECTED_OWN above); GUARDED_RIG_DETECTOR
# is built from it at Step 4 via classify_guarded(), same shape as GUARDED_OWN/
# GUARDED_CLOSURE_ONLY. RIG_DETECTOR_USED is rig-level, set once at Step 3.
AFFECTED_RIG_DETECTOR=""; GUARDED_RIG_DETECTOR=""; RIG_DETECTOR_USED=0
# wa-xokje: subset of AFFECTED that Step 4 below finds has no live PID at all
# (a scheduled/one-shot job or an already-down daemon) — never kickstarted,
# never a restart candidate, and — unlike a live daemon — cannot be made
# fresh by ANY amount of retrying: it will pick up the new code on its own,
# automatically, the next time launchd fires it. A caller comparing THIS
# story's own delta against AFFECTED alone cannot tell "only reaches a
# self-healing scheduled job" from "reaches a live daemon that genuinely
# needs a human's guarded restart" — this field lets it.
AFFECTED_NOT_RUNNING=""
# ga-ax0t9: achado do Step 1b que espera o Step 2 rodar antes de virar veredito.
SJ_PENDING_REASON=""
# ga-agracx: a real Step 1b gap that was NOT attributed to this bead's own
# merge — never forces the verdict (contrast SJ_PENDING_REASON above), only
# surfaced via emit()'s own UNATTRIBUTED_JOB_GAP field so it is never lost.
SJ_UNATTRIBUTED_REASON=""
# gate-fix-2 (ga-puq8z, gate_run=ga-9a45d): weakest confidence tier across all
# ALREADY_FRESH daemons this run — starts optimistic, downgraded to
# not_verified the moment any already-fresh match is only a COMMIT_EPOCH
# correlation rather than a genuine past-DEPLOY_EPOCH confirmation (see
# already_fresh()/AFR_TIER below). A batch summary can only be as trustworthy
# as its weakest member.
ALREADY_FRESH_PROOF="verified"

# ── preconditions ─────────────────────────────────────────────────────────────
if [ -z "$RUNTIME_DIR" ] || ! git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "runtime '$RUNTIME_DIR' is not a git work tree — skip (static daemon_restarts still apply)."
  emit SKIPPED "runtime not a git work tree" not_verified
fi
if [ -z "$PRE_DEPLOY_SHA" ] || [ -z "$POST_DEPLOY_SHA" ]; then
  log "no SHA delta ($PRE_DEPLOY_SHA .. $POST_DEPLOY_SHA) — deploy changed nothing — skip."
  emit SKIPPED "no source change in deploy" not_applicable
fi
if [ "$PRE_DEPLOY_SHA" = "$POST_DEPLOY_SHA" ]; then
  # ga-1ivcn4 (header point 15): a true no-op pull only proves THIS
  # invocation's own git-pull found nothing — not that the bead being
  # checked changed nothing (some OTHER path may have already pulled it).
  # Fall back to the bead's own merge range before giving up on it: same
  # guard chain Step 1b already uses below for BEAD_MERGE_PRE_SHA/
  # BEAD_MERGE_SHA (ga-agracx) — only when both are non-empty, distinct, and
  # BEAD_MERGE_PRE_SHA is a confirmed ancestor of BEAD_MERGE_SHA in THIS
  # runtime checkout. A caller that doesn't pass them (e.g. story-
  # delivery.sh's own primary call) or passes an untrustworthy pair falls
  # straight through to the exact same SKIPPED this precondition has always
  # emitted here — zero regression.
  if [ -n "$BEAD_MERGE_PRE_SHA" ] && [ -n "$BEAD_MERGE_SHA" ] \
     && [ "$BEAD_MERGE_PRE_SHA" != "$BEAD_MERGE_SHA" ] \
     && git -C "$RUNTIME_DIR" rev-parse --verify -q "$BEAD_MERGE_PRE_SHA" >/dev/null 2>&1 \
     && git -C "$RUNTIME_DIR" rev-parse --verify -q "$BEAD_MERGE_SHA" >/dev/null 2>&1 \
     && git -C "$RUNTIME_DIR" merge-base --is-ancestor "$BEAD_MERGE_PRE_SHA" "$BEAD_MERGE_SHA" 2>/dev/null; then
    log "this invocation's own pull was a true no-op (PRE_DEPLOY_SHA==POST_DEPLOY_SHA=$POST_DEPLOY_SHA) — falling back to the bead's own merge range ($BEAD_MERGE_PRE_SHA..$BEAD_MERGE_SHA) instead of declaring SKIPPED, so a race with some other path that already pulled this merge cannot hide it from verification (ga-1ivcn4, wa-ycyf8)."
    PRE_DEPLOY_SHA="$BEAD_MERGE_PRE_SHA"
    POST_DEPLOY_SHA="$BEAD_MERGE_SHA"
  else
    log "no SHA delta ($PRE_DEPLOY_SHA .. $POST_DEPLOY_SHA) — deploy changed nothing — skip."
    emit SKIPPED "no source change in deploy" not_applicable
  fi
fi

# ── commit-epoch (ga-puq8z) ─────────────────────────────────────────────────────
# The committer date of POST_DEPLOY_SHA — used below by already_fresh() as the
# freshness reference INSTEAD OF DEPLOY_EPOCH alone. DEPLOY_EPOCH is captured
# by the CALLER right before ITS OWN deploy step for THIS specific bead/story's
# check — which can be minutes-to-hours after the commit itself (gate-queue
# wait, deploy retry/backoff — ga-d5rrr, or simply a slow sweep cycle). A
# daemon already refreshed by some OTHER path in that gap has a pid-start
# strictly AFTER the commit but strictly BEFORE DEPLOY_EPOCH: genuinely
# fresh, but the DEPLOY_EPOCH-only comparison called that stale and flagged an
# unnecessary hot-path restart (measured 2026-09-01:
# com.whatsapp.demand-dashboard flagged twice within 15 minutes, both times
# already running code newer than the commit under review — ga-puq8z).
# COMMIT_EPOCH <= DEPLOY_EPOCH always holds (code cannot deploy before it is
# committed), so using it as the already_fresh() threshold only ever ADDS
# true-fresh detections relative to the old DEPLOY_EPOCH-only check (see T27
# in the test suite for the regression guard: a process predating the commit
# itself is still correctly flagged).
# gate-fix-2 (gate_run=ga-9a45d): it does NOT follow that this "never masks a
# real stale daemon" outright — a SENSITIVE daemon under launchd
# KeepAlive=true can crash and respawn from whatever is still on disk at any
# point in the (COMMIT_EPOCH, DEPLOY_EPOCH) gap, before THIS deploy's own
# checkout update has happened, producing a pid-start > COMMIT_EPOCH (but NOT
# > DEPLOY_EPOCH) while still running pre-commit code. So a match in that gap
# is a correlation that avoids the common false-positive, not a proof of live
# freshness — already_fresh() (below) reports that tier as PROOF=not_verified,
# never verified; a pid-start that ALSO clears DEPLOY_EPOCH is the identical
# bar verify_fresh() uses and stays a genuine verified confirmation.
# Falls back to DEPLOY_EPOCH (the old, more conservative reference) if `git
# show` cannot produce a value — fail toward existing behavior, not toward a
# wider window, when the commit date is unverifiable.
COMMIT_EPOCH="$(git -C "$RUNTIME_DIR" show -s --format=%ct "$POST_DEPLOY_SHA" 2>/dev/null || true)"
case "$COMMIT_EPOCH" in ''|*[!0-9]*) COMMIT_EPOCH="$DEPLOY_EPOCH" ;; esac

# ── Step 1: changed files in this deploy ──────────────────────────────────────
CHANGED="$(git -C "$RUNTIME_DIR" diff --name-only "$PRE_DEPLOY_SHA" "$POST_DEPLOY_SHA" 2>/dev/null || true)"

# ── Step 1b: scheduled-job plist delivery (wa-jts45, header point 12) ─────────
# Runs BEFORE every early-exit below (including Step 1's own "no .py/template
# changed" short-circuit further down) — see header point 12 for the full
# rationale. Only asks: did this deploy touch a *.plist, and if so, is the
# job it declares actually installed+loaded on this machine? NOT "has it run
# yet" — see point 12 for why that bar would false-positive on an ordinary
# nightly job checked hours before its next scheduled window.
#
# Inlines the launchctl-list check rather than calling daemon_is_loaded()
# (defined later, in Step 2's helper block) — that function is not yet
# defined at this point in the script's top-to-bottom execution, and moving
# it earlier would touch code this bead has no other reason to move.
SJ_CHANGED_PLISTS="$(echo "$CHANGED" | grep -E '\.plist$' || true)"
if [ -n "${SJ_CHANGED_PLISTS// /}" ]; then
  SJ_MISSING=""
  SJ_UNLOADED=""
  SJ_MISSING_UNATTRIB=""
  SJ_UNLOADED_UNATTRIB=""
  SJ_CHECKED=""
  # ga-agracx: this bead's OWN plist-touching set, computed once up front —
  # only when BOTH attribution inputs are usable (non-empty, both resolve in
  # THIS runtime checkout, and BEAD_MERGE_PRE_SHA is an actual ancestor of
  # BEAD_MERGE_SHA — same guard chain ga-6zkhci established for story-
  # delivery.sh's own MERGE_PRE_MAIN fallback; never trust the inputs blindly).
  # Any guard failure (unset, unresolvable, not-an-ancestor) leaves attribution
  # UNKNOWN, which below defaults to "attributable" — i.e. today's exact
  # behavior — never silently exempting on a bad signal.
  SJ_ATTRIBUTION_KNOWN=0
  SJ_BEAD_OWN_PLISTS=""
  if [ -n "$BEAD_MERGE_PRE_SHA" ] && [ -n "$BEAD_MERGE_SHA" ] \
     && [ "$BEAD_MERGE_PRE_SHA" != "$BEAD_MERGE_SHA" ] \
     && git -C "$RUNTIME_DIR" rev-parse --verify -q "$BEAD_MERGE_PRE_SHA" >/dev/null 2>&1 \
     && git -C "$RUNTIME_DIR" rev-parse --verify -q "$BEAD_MERGE_SHA" >/dev/null 2>&1 \
     && git -C "$RUNTIME_DIR" merge-base --is-ancestor "$BEAD_MERGE_PRE_SHA" "$BEAD_MERGE_SHA" 2>/dev/null; then
    # ga-agracx gate-fix: do NOT set SJ_ATTRIBUTION_KNOWN=1 until the diff
    # ITSELF has actually succeeded — an empty result from a FAILED diff
    # (git internal error, however unlikely after the three checks just
    # above already succeeded) must not read the same as "ran fine, this
    # bead's own range genuinely touches no plists": the former is
    # third-state UNKNOWN (falls back to blame, the safe direction — a
    # transient failure here must never silently exempt a truly-guilty
    # bead), the latter is a real, confirmed negative.
    sj_own_diff_rc=0
    sj_own_diff_out="$(git -C "$RUNTIME_DIR" diff --name-only "$BEAD_MERGE_PRE_SHA" "$BEAD_MERGE_SHA" 2>/dev/null)" || sj_own_diff_rc=$?
    if [ "$sj_own_diff_rc" -eq 0 ]; then
      SJ_ATTRIBUTION_KNOWN=1
      SJ_BEAD_OWN_PLISTS="$(printf '%s\n' "$sj_own_diff_out" | grep -E '\.plist$' || true)"
    fi
  fi
  while IFS= read -r sj_rel; do
    [ -n "$sj_rel" ] || continue
    sj_path="$RUNTIME_DIR/$sj_rel"
    [ -f "$sj_path" ] || continue   # deleted by this deploy — nothing to verify installed
    sj_parsed="$(python3 - "$sj_path" <<'PY' 2>/dev/null
import sys, plistlib
try:
    d = plistlib.load(open(sys.argv[1], 'rb'))
except Exception:
    sys.exit(1)
label = d.get('Label')
if not label:
    sys.exit(1)
print(label)
print('1' if d.get('Disabled') else '0')
PY
)"
    if [ -z "$sj_parsed" ]; then
      log "Step 1b: could not parse $sj_rel (or no Label key) — scheduled-job delivery could not be checked for this file (not counted as missing, not counted as installed)."
      continue
    fi
    sj_label="$(echo "$sj_parsed" | sed -n '1p')"
    sj_disabled="$(echo "$sj_parsed" | sed -n '2p')"
    if [ "$sj_disabled" = "1" ]; then
      log "Step 1b: $sj_label ($sj_rel) is Disabled=true (intentionally manual) — skipping."
      continue
    fi
    # ga-gjum0y: a label the rig owner recorded as deliberately not
    # installed/not loaded (restart_policy.yaml's scheduled_job_opt_out) is
    # the SAME kind of decision as Disabled=true above — it just can't be
    # expressed that way when the job was never installed at all (no plist
    # on disk to carry a Disabled key) or was disabled via `launchctl
    # disable` (a separate launchd-side database, never written back into
    # the plist's own content). Incident: com.whatsapp.pbh-edificacao-scrape
    # (never installed) and com.whatsapp.ficha360-search-index-refresh
    # (installed, `launchctl disable`d) forced VERDICT=JOB_NOT_INSTALLED on
    # every deploy that merely touched their committed plists, which in turn
    # never let this rig's daemon-refresh-baseline advance (wa-waxw8 recorded
    # both as OPT-IN; see restart_policy.yaml for the per-label reason).
    # Checked as a whitespace-bounded substring match (same idiom as every
    # other space-separated accumulator in this file, e.g. GUARDED/AFFECTED
    # below) — never a plain case glob, so "com.foo.bar" cannot false-match
    # "com.foo.barbaz".
    case " $POLICY_SCHEDULED_JOB_OPT_OUT " in
      *" $sj_label "*)
        log "Step 1b: $sj_label ($sj_rel) is in restart_policy.yaml's scheduled_job_opt_out (recorded decision, not a gap) — skipping."
        continue
        ;;
    esac
    SJ_CHECKED="$SJ_CHECKED $sj_label"
    sj_broken=""
    if [ ! -f "$LAUNCH_AGENTS_DIR/$sj_label.plist" ]; then
      sj_broken="missing"
    elif ! $LAUNCHCTL_BIN list "$sj_label" >/dev/null 2>&1; then
      sj_broken="unloaded"
    fi
    if [ -n "$sj_broken" ]; then
      # ga-agracx: the gap itself is established above (unconditionally, same
      # as before) — this only decides which BUCKET it lands in. Unknown
      # attribution (SJ_ATTRIBUTION_KNOWN=0) defaults to attributable, i.e.
      # identical to pre-ga-agracx behavior.
      sj_attributable=1
      if [ "$SJ_ATTRIBUTION_KNOWN" = "1" ] && ! printf '%s\n' "$SJ_BEAD_OWN_PLISTS" | grep -Fx "$sj_rel" >/dev/null; then
        sj_attributable=0
      fi
      if [ "$sj_broken" = "missing" ]; then
        if [ "$sj_attributable" = "1" ]; then SJ_MISSING="$SJ_MISSING $sj_label"; else SJ_MISSING_UNATTRIB="$SJ_MISSING_UNATTRIB $sj_label"; fi
      else
        if [ "$sj_attributable" = "1" ]; then SJ_UNLOADED="$SJ_UNLOADED $sj_label"; else SJ_UNLOADED_UNATTRIB="$SJ_UNLOADED_UNATTRIB $sj_label"; fi
      fi
    fi
  done <<< "$SJ_CHANGED_PLISTS"
  SJ_MISSING="$(echo "$SJ_MISSING" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  SJ_UNLOADED="$(echo "$SJ_UNLOADED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  SJ_MISSING_UNATTRIB="$(echo "$SJ_MISSING_UNATTRIB" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  SJ_UNLOADED_UNATTRIB="$(echo "$SJ_UNLOADED_UNATTRIB" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  if [ -n "${SJ_MISSING// /}" ] || [ -n "${SJ_UNLOADED// /}" ]; then
    # gate_run=ga-3khhu (Reviewer-1 FAIL): this used to be AFFECTED="$SJ_CHECKED"
    # — the FULL set of plists this deploy touched, fine ones included, not
    # just the broken ones. Step 4's kickstart loop below walks every AFFECTED
    # label, so a deploy that ALSO made a cosmetic edit to an already-
    # installed+loaded+live SAFE daemon's plist swept that fine daemon in too
    # and it got kickstarted for zero reason — a live process with no code
    # change and no installation problem, reproduced by combining a T4-shaped
    # fine-but-touched plist with a T37-shaped never-installed one in one
    # deploy (see T42). AFFECTED must carry only the labels that are actually
    # missing/unloaded. SJ_MISSING and SJ_UNLOADED are disjoint by construction
    # (the if/elif above sets exactly one or neither per label), so no extra
    # dedup is needed here — line ~1105's existing normalize pass covers it.
    # ga-agracx: unattributed findings are STILL real gaps (Step 4 below just
    # logs "not currently running — skipping" for any AFFECTED label with no
    # live PID, the same as it always has for a never-installed job — no
    # remedial action was ever gated on attribution), so they stay in AFFECTED
    # for full visibility. Only SJ_PENDING_REASON below — the BLOCKING verdict
    # — is scoped to what this bead's own merge actually introduced.
    AFFECTED="$SJ_MISSING $SJ_UNLOADED $SJ_MISSING_UNATTRIB $SJ_UNLOADED_UNATTRIB"
    SJ_REASON="scheduled-job plist(s) changed by this deploy are not actually installed for launchd to run them"
    [ -n "${SJ_MISSING// /}" ] && SJ_REASON="$SJ_REASON — missing from $LAUNCH_AGENTS_DIR: $SJ_MISSING"
    [ -n "${SJ_UNLOADED// /}" ] && SJ_REASON="$SJ_REASON — present but not loaded (launchctl list): $SJ_UNLOADED"
    log "Step 1b: JOB_NOT_INSTALLED — $SJ_REASON (recorded; Step 2 still runs)"
    # NAO chamar emit aqui: emit encerra o script (ver o case no fim dele) e o
    # Step 2 nunca rodaria. Registra e segue; emit combina no fim.
    SJ_PENDING_REASON="$SJ_REASON"
  fi
  if [ -n "${SJ_MISSING_UNATTRIB// /}" ] || [ -n "${SJ_UNLOADED_UNATTRIB// /}" ]; then
    # ga-agracx: a real gap, but NOT introduced by this bead's own merge
    # (BEAD_MERGE_PRE_SHA..BEAD_MERGE_SHA does not contain this plist) — an
    # earlier, unrelated commit somewhere in the wider PRE_DEPLOY_SHA..
    # POST_DEPLOY_SHA runtime-checkout window introduced it, and this deploy
    # is simply the one whose pull finally advanced the runtime past it.
    # Never silenced (Mayor's ACEITE 2 on ga-agracx: the alert must keep
    # firing) — recorded here and surfaced via emit()'s own
    # UNATTRIBUTED_JOB_GAP field so the caller can still act on it (e.g.
    # nudge Mayor) without holding an innocent bead responsible for it.
    AFFECTED="$SJ_MISSING $SJ_UNLOADED $SJ_MISSING_UNATTRIB $SJ_UNLOADED_UNATTRIB"
    SJ_UNATTRIB_REASON="scheduled-job plist(s) somewhere in the wider deploy window are not actually installed for launchd to run them, but this bead's own merge did not introduce them"
    [ -n "${SJ_MISSING_UNATTRIB// /}" ] && SJ_UNATTRIB_REASON="$SJ_UNATTRIB_REASON — missing from $LAUNCH_AGENTS_DIR: $SJ_MISSING_UNATTRIB"
    [ -n "${SJ_UNLOADED_UNATTRIB// /}" ] && SJ_UNATTRIB_REASON="$SJ_UNATTRIB_REASON — present but not loaded (launchctl list): $SJ_UNLOADED_UNATTRIB"
    log "Step 1b: unattributed JOB_NOT_INSTALLED gap (not caused by this bead's own merge) — $SJ_UNATTRIB_REASON"
    SJ_UNATTRIBUTED_REASON="$SJ_UNATTRIB_REASON"
  fi
  # gate_run=ga-3khhu: the log line below used to name the FULL $SJ_CHECKED,
  # which could (and did, in the reviewer's repro) name a label the block
  # above had just reported MISSING one line earlier — self-contradictory.
  # Exclude anything already counted as missing/unloaded (ga-agracx: in
  # EITHER attribution bucket — an unattributed gap is still not fine).
  SJ_FINE="$(comm -23 \
    <(echo "$SJ_CHECKED" | tr ' ' '\n' | grep -v '^$' | sort -u) \
    <(printf '%s\n%s\n%s\n%s\n' "$SJ_MISSING" "$SJ_UNLOADED" "$SJ_MISSING_UNATTRIB" "$SJ_UNLOADED_UNATTRIB" | tr ' ' '\n' | grep -v '^$' | sort -u) \
    | tr '\n' ' ' | sed 's/ $//')"
  if [ -n "${SJ_FINE// /}" ]; then
    log "Step 1b: scheduled-job plist(s) changed by this deploy are installed+loaded:$SJ_FINE (not proof they have run successfully — see JOB_NOT_INSTALLED's own ACTION text at the caller for that follow-up check)."
  fi
fi

# (ga-dk7fw, header point 9) framework-default "structurally inert" path
# classes — checked against the FULL raw changed set, unconditionally, with
# NO restart_policy.yaml opt-in required (contrast with POLICY_NO_RESTART_PATHS
# below, which IS rig-declared). tests/**, docs/**, and *.md are never part of
# ANY daemon's runtime import graph on ANY rig — this is a universal claim,
# not a rig-specific one, so it belongs here rather than in a config file every
# rig would otherwise have to repeat. Deliberately NOT extended to static/** or
# templates/**: those stay rig-declared-only (point 8) because they are NOT
# universally safe — a *.py "helper" can live under a rig's static/ dir (point
# 8's own docstring), and Jinja templates are compiled+cached at import (point
# 3/ga-jkj0), so a blanket templates/** exemption here would silently
# reintroduce that exact regression. Checked BEFORE the *.py/template split
# below so a *.py file under tests/ is caught too, matching the path shape
# ga-dk7fw's bug report cites (wa-zmmyd: a tests/*.py file present in a
# NEEDS_GUARDED_RESTART deploy). CAVEAT verified while fixing this (see
# daemon-refresh.test.sh T28's comment for the full trace): an ISOLATED
# tests/*.py change already resolved to VERDICT=OK pre-fix too (Step 3's
# "touches no live daemon" fallback) — the wa-zmmyd alert itself was driven
# by 4 real production .py files in the SAME deploy (confirmed against the
# daemon-refresh log actually posted on that bead), not by its 2 co-changed
# test files. What this point concretely fixes is PROOF/REASON precision
# (not_applicable vs. the weaker not_verified) on a tests/docs/md-only
# change — which matters downstream: story-delivery.sh labels
# delivery:daemon-unverified and warns "may still be dormant" for any PROOF
# other than verified/not_applicable/asset_served_per_request, so a
# tests-only story used to get that live, misleading label for zero reason.
# Same all-or-nothing short-circuit shape as point 8 just below (a partially-
# covered changed set falls straight through to full evaluation unchanged) —
# this is what lets a mixed lib/+tests/ commit still evaluate its lib/ file
# normally instead of becoming an escape hatch (ga-dk7fw ACEITE item 2; T30
# reproduces the actual wa-zmmyd mixed shape and confirms it still flags).
DEFAULT_NO_RESTART_PATTERNS="tests/** docs/** *.md"
if [ -n "${CHANGED// /}" ]; then
  changed_uncovered_default=""
  set -f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    covered=0
    for pat in $DEFAULT_NO_RESTART_PATTERNS; do
      # shellcheck disable=SC2254  # deliberate glob match, not literal
      case "$f" in $pat) covered=1; break ;; esac
    done
    [ "$covered" -eq 1 ] || changed_uncovered_default="$changed_uncovered_default $f"
  done <<< "$CHANGED"
  set +f
  if [ -z "${changed_uncovered_default// /}" ]; then
    log "every changed file matches a default structurally-inert path (tests/**, docs/**, *.md) — OK (no daemon anywhere imports a test or doc file)."
    emit OK "all changed files are tests/docs/md-only (structurally inert — no daemon could load them)" not_applicable
  fi
fi

# (ga-y108i, header point 8) no_restart_paths short-circuit — checked against
# the FULL raw changed set, before the *.py/template split below, so it also
# covers a *.py (or any other extension) file living under a declared path.
# Only engages when the rig's restart_policy.yaml declares the key AND
# parsed successfully (POLICY_NO_RESTART_PATHS stays "" on no file, an
# unparseable file, or an undeclared key — identical no-op in all three
# cases, matching "path not listed -> current behavior, no change").
if [ -n "${CHANGED// /}" ] && [ -n "${POLICY_NO_RESTART_PATHS// /}" ]; then
  changed_uncovered=""
  # POLICY_NO_RESTART_PATHS holds glob-pattern TEXT (e.g. "daemons/static/**")
  # meant to be split on spaces below — but left unquoted, bash also runs
  # pathname expansion on each split word against the process's ambient CWD
  # (never RUNTIME_DIR), so a CWD that happens to contain a matching subtree
  # silently swaps a real filename in for the pattern string and this
  # short-circuit fails to fire (gate-review finding on ga-y108i, T25).
  # `set -f` disables that expansion for the split only; the `case` pattern
  # match just below is unaffected either way — it is shell pattern matching
  # against a string, never filesystem globbing.
  set -f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    covered=0
    for pat in $POLICY_NO_RESTART_PATHS; do
      # shellcheck disable=SC2254  # deliberate glob match, not literal
      case "$f" in $pat) covered=1; break ;; esac
    done
    [ "$covered" -eq 1 ] || changed_uncovered="$changed_uncovered $f"
  done <<< "$CHANGED"
  set +f
  if [ -z "${changed_uncovered// /}" ]; then
    log "every changed file matches restart_policy.yaml's no_restart_paths — OK (content re-read from disk per request; no live process needs a restart)."
    emit OK "all changed files match declared no_restart_paths" asset_served_per_request
  fi
fi

CHANGED_PY="$(echo "$CHANGED" | grep -E '\.py$' || true)"
CHANGED_TEMPLATES="$(echo "$CHANGED" | grep -E '\.(html|htm|jinja2?|j2)$' || true)"

# (ga-9ps272) CHANGED_PY_FOR_STEMS — CHANGED_PY with every tests/**, docs/**,
# *.md-covered entry removed (the SAME universal claim DEFAULT_NO_RESTART_PATTERNS
# already established above: no daemon anywhere imports a test or doc file).
# Hoisted here, BEFORE this gate's own emptiness check, from its previous
# position further below (where it fed CHANGED_STEMS only) — moving it earlier
# changes nothing about that later use (it has no dependency on anything Step
# 2 discovers in between; same input $CHANGED_PY, same $DEFAULT_NO_RESTART_PATTERNS,
# same output), but it now ALSO lets this gate see the right thing.
#
# Pre-fix, this gate checked the RAW $CHANGED_PY: a deploy whose ONLY changed
# .py file is a tests/*.py, but which ALSO touches some non-.py/non-template
# file this gate's sibling above (DEFAULT_NO_RESTART_PATTERNS) does not list —
# e.g. a brand-new standalone scripts/*.sh, which cannot be part of ANY
# daemon's Python import graph either, but was never added to that pattern
# list — fell through both early gates with zero daemon-relevant code changed,
# landing on the weaker not_verified PROOF via Step 3's own "changed code
# touches no live daemon" fallback further below, instead of this gate's own
# not_applicable. VERDICT was already OK either way (Step 3 finds no daemon
# actually importing a filtered-out tests/*.py stem) — the delta is
# PROOF/REASON precision, identical in kind to header point 9/ga-dk7fw's own
# fix for the ISOLATED tests/docs/md-only case (T28/T29): downstream,
# story-delivery.sh/quality-gate-dispatcher.sh add a delivery:daemon-unverified
# label and rewrite the done-notification to "DAEMON LIVENESS NOT VERIFIED"
# for any PROOF other than verified/not_applicable/asset_served_per_request —
# so this exact shape (measured live, wa-p7g7g: CLAUDE.md + docs + a new
# scripts/*.sh + a new tests/*.py, zero real lib/daemons code) got that
# scary, actionable-looking label for a delivery with zero daemon relevance.
# Deliberately does NOT also extend DEFAULT_NO_RESTART_PATTERNS itself (e.g.
# with scripts/**/*.sh): that would only help changesets containing NO .py
# file at all, which this same gate already resolves correctly today (CHANGED_PY
# is already empty in that case, filtered or not) — enumerating every
# non-importable extension there is unbounded and unnecessary. Filtering the
# .py side once, here, covers any companion file of any extension.
CHANGED_PY_FOR_STEMS=""
set -f
while IFS= read -r pyf; do
  [ -n "$pyf" ] || continue
  py_covered=0
  for pat in $DEFAULT_NO_RESTART_PATTERNS; do
    # shellcheck disable=SC2254  # deliberate glob match, not literal
    case "$pyf" in $pat) py_covered=1; break ;; esac
  done
  if [ "$py_covered" -eq 0 ]; then
    CHANGED_PY_FOR_STEMS="$CHANGED_PY_FOR_STEMS
$pyf"
  fi
done <<< "$CHANGED_PY"
set +f

if [ -z "$CHANGED_PY_FOR_STEMS" ] && [ -z "$CHANGED_TEMPLATES" ]; then
  log "deploy changed no daemon-relevant *.py (tests/**, docs/**, *.md-covered python excluded — see CHANGED_PY_FOR_STEMS above) and no template files — no daemon code affected — OK."
  emit OK "no python source (excluding tests/docs/md) or template changed" not_applicable
fi
log "changed python files:"; echo "$CHANGED_PY" | sed 's/^/[daemon-refresh]   /' >&2
log "changed template files:"; echo "$CHANGED_TEMPLATES" | sed 's/^/[daemon-refresh]   /' >&2

# helper: epoch of a pid's start time (parses `ps -o lstart=`)
pid_start_epoch() {  # pid_start_epoch <pid>
  local pid="$1" ls
  [ -n "$pid" ] || return 1
  ls="$($PS_BIN -o lstart= -p "$pid" 2>/dev/null)"
  ls="${ls%"${ls##*[![:space:]]}"}"   # rtrim trailing whitespace ps pads with
  [ -n "$ls" ] || return 1
  date -j -f "%a %b %e %T %Y" "$ls" +%s 2>/dev/null
}

# helper: current PID for a launchd label
daemon_pid() {  # daemon_pid <label>
  $LAUNCHCTL_BIN list "$1" 2>/dev/null \
    | awk -F'=' '/"PID"/ {gsub(/[^0-9]/,"",$2); print $2; exit}'
}

# helper: is a launchd label currently LOADED (registered with launchd)? (ga-tdzsh)
# Deliberately NOT daemon_pid()-based: a job can be loaded but between runs
# (e.g. KeepAlive=false, or simply idle) and still report an empty PID —
# indistinguishable, by PID alone, from a label launchd has never heard of.
# `launchctl list <label>` itself is the discriminator: it exits 0 the moment
# the label is registered (live PID or not), non-zero ("Could not find
# service ... in domain") when nothing is loaded under it at all. This is the
# exact ambiguity ga-tdzsh is about: a plist that fails to parse could belong
# to a LIVE, loaded daemon (real coverage gap — its code can go stale with
# nobody warned, e.g. com.gastown.dolt-server) or to nothing loaded at all
# (dead symlink, stale file — harmless noise that buried the real case).
daemon_is_loaded() {  # daemon_is_loaded <label>
  $LAUNCHCTL_BIN list "$1" >/dev/null 2>&1
}

# ── Step 2: discover the rig's daemons + their entrypoint files ───────────────
# For each plist, read ProgramArguments. An arg under RUNTIME_DIR that is a .py
# file is an entrypoint; a wrapper .sh under RUNTIME_DIR is followed to the .py
# it execs. A plist with no entrypoint under RUNTIME_DIR is not a rig daemon.
plist_args() {  # plist_args <plist>; exit 0 (possibly empty output) when the
                 # plist parses but has no usable ProgramArguments, exit 1 when
                 # plistlib could not parse the file at all. The caller must be
                 # able to tell "not a rig daemon" apart from "could not tell"
                 # (ga-otn7u) — collapsing both into exit 0 is what made 5
                 # daemons permanently invisible to discovery.
  python3 - "$1" <<'PY' 2>/dev/null
import sys, plistlib
try:
    d = plistlib.load(open(sys.argv[1], 'rb'))
except Exception:
    sys.exit(1)
for a in (d.get('ProgramArguments') or []):
    print(a)
PY
}

# Resolve a (possibly $VAR-prefixed or absolute) .py token to a relpath that
# exists under RUNTIME_DIR; echoes nothing if it cannot be resolved.
resolve_relpath() {  # resolve_relpath <token>
  local t="$1" c root
  # absolute under runtime
  case "$t" in
    "$RUNTIME_DIR"/*) c="${t#"$RUNTIME_DIR"/}"; [ -f "$RUNTIME_DIR/$c" ] && { echo "$c"; return; } ;;
  esac
  # absolute under a configured EXTRA_RUNTIME_ROOTS entry (ga-00ptz): a second,
  # independently-deployed clone of this SAME rig's repo (e.g. painel-prod).
  # The relpath it shares with RUNTIME_DIR must also actually exist there —
  # this only grants visibility into a file genuinely present in both trees,
  # never invents an entrypoint out of thin air.
  for root in $EXTRA_RUNTIME_ROOTS; do
    case "$t" in
      "$root"/*) c="${t#"$root"/}"; [ -f "$RUNTIME_DIR/$c" ] && { echo "$c"; return; } ;;
    esac
  done
  # strip a leading shell-var segment: $BASEDIR/ ${WA_ROOT}/ etc.
  c="$(echo "$t" | sed -E 's#^.*\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/##')"
  [ -n "$c" ] && [ "$c" != "$t" ] && [ -f "$RUNTIME_DIR/$c" ] && { echo "$c"; return; }
  return 1
}

# WorkingDirectory of a plist, or empty if absent/unparseable. (ga-fzfqsu)
plist_working_directory() {  # plist_working_directory <plist>
  python3 - "$1" <<'PY' 2>/dev/null
import sys, plistlib
try:
    d = plistlib.load(open(sys.argv[1], 'rb'))
except Exception:
    sys.exit(0)
wd = d.get('WorkingDirectory')
if wd:
    print(wd)
PY
}

# Is <dir> RUNTIME_DIR itself, or under RUNTIME_DIR or an EXTRA_RUNTIME_ROOTS
# entry? (ga-fzfqsu) Same roots resolve_relpath() already trusts for a file
# token, applied instead to a plist's WorkingDirectory — the signal a
# `python -m <module>` launch (e.g. lexbh's `python -m flask run`, which names
# no .py file anywhere in argv; the real app module lives behind FLASK_APP or
# an equivalent env var this script deliberately does not special-case)
# leaves behind when no entrypoint file can be resolved at all.
working_directory_under_runtime() {  # working_directory_under_runtime <dir>
  local wd="$1" root
  [ -n "$wd" ] || return 1
  case "$wd" in
    "$RUNTIME_DIR"|"$RUNTIME_DIR"/*) return 0 ;;
  esac
  for root in $EXTRA_RUNTIME_ROOTS; do
    case "$wd" in
      "$root"|"$root"/*) return 0 ;;
    esac
  done
  return 1
}

# label -> space-separated entrypoint relpaths (parallel arrays via temp files)
DISCO_DIR="$(mktemp -d "${TMPDIR:-/tmp}/daemon-disco.XXXXXX")"
trap 'rm -rf "$DISCO_DIR"' EXIT
DAEMON_LABELS=""
PARSE_ERROR_LABELS=""
# ga-tdzsh: the two buckets a parse-error label actually splits into — see
# daemon_is_loaded() above. Kept alongside (not instead of) PARSE_ERROR_LABELS,
# which still drives the pre-existing "was the whole scan even complete?"
# not_verified/not_applicable choice below (line ~636) unchanged — that
# question ("did discovery see everything?") is orthogonal to this one
# ("of what it couldn't read, was any of it actually live?").
PARSE_ERROR_LOADED=""
PARSE_ERROR_UNLOADED=""

shopt -s nullglob
for plist in "$LAUNCH_AGENTS_DIR"/*.plist; do
  label="$(basename "$plist" .plist)"
  entry=""
  prev_arg=""
  args_out="$(plist_args "$plist")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    PARSE_ERROR_LABELS="$PARSE_ERROR_LABELS $label"
    # ga-tdzsh: this WARN used to read identically regardless of whether
    # $label is a live, loaded daemon (real coverage gap) or nothing loaded
    # at all (dead symlink, stale file) — the harmless case's noise is what
    # buried com.gastown.dolt-server's real one (ga-dgrzf). Split by load
    # status: only a LOADED label is worth an escalatable ERROR line; an
    # unloaded one gets a low-priority note, still naming the plist for
    # anyone who wants to clean it up, but never confused for a live gap.
    if daemon_is_loaded "$label"; then
      PARSE_ERROR_LOADED="$PARSE_ERROR_LOADED $label"
      log "ERROR: $plist could not be parsed by plistlib, and launchd HAS $label loaded — this daemon is invisible to auto-refresh discovery until the XML is fixed (common cause: a literal '--' inside an <!-- --> comment, which Apple's launchd parser tolerates but plistlib does not). Verify with: python3 -c \"import plistlib; plistlib.load(open('$plist','rb'))\""
    else
      PARSE_ERROR_UNLOADED="$PARSE_ERROR_UNLOADED $label"
      log "note: $plist could not be parsed by plistlib, but launchd does not have $label loaded — nothing live is invisible here (likely a dead symlink or stale file). Verify with: python3 -c \"import plistlib; plistlib.load(open('$plist','rb'))\""
    fi
  fi
  while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    case "$arg" in
      *.py)
        rel="$(resolve_relpath "$arg" || true)"
        [ -n "$rel" ] && entry="$entry $rel"
        ;;
      *.sh)
        # wrapper under runtime → follow to the .py it execs
        wrel="$(resolve_relpath "$arg" || true)"
        if [ -n "$wrel" ]; then
          while IFS= read -r tok; do
            prel="$(resolve_relpath "$tok" || true)"
            [ -n "$prel" ] && entry="$entry $prel"
          done < <(grep -oE '[^"[:space:]]+\.py' "$RUNTIME_DIR/$wrel" 2>/dev/null || true)
        fi
        ;;
    esac
    # ga-fzfqsu: `-m <dotted.module>` (python's own module-execution flag) may
    # name a real in-repo module with no .py suffix anywhere in argv — resolve
    # it the same way an import statement would (dots -> path separators, a
    # trailing .py) via the same roots resolve_relpath() already trusts. A
    # module that isn't actually under RUNTIME_DIR (e.g. `-m flask`, `-m
    # gunicorn` — a globally-installed package, lexbh's real case) fails to
    # resolve here exactly like any other unmatched token, falling through to
    # the WorkingDirectory fallback below.
    if [ "$prev_arg" = "-m" ]; then
      mrel="$(resolve_relpath "$(echo "$arg" | tr '.' '/').py" || true)"
      [ -n "$mrel" ] && entry="$entry $mrel"
    fi
    prev_arg="$arg"
  done <<< "$args_out"
  entry="$(echo "$entry" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  if [ -z "${entry// /}" ]; then
    # ga-fzfqsu: no .py/.sh/-m entrypoint resolved. Before dropping this plist
    # entirely (the pre-fix behavior — invisible to discovery, and if it's the
    # rig's ONLY daemon, the whole scan short-circuits to "no rig daemons
    # discovered" before Step 3/4 ever run), check whether its WorkingDirectory
    # itself is under a runtime root. If so, still register it as a rig daemon
    # with an empty entry set: Step 3's ad-hoc/import/template matching can
    # never mark an empty-entry daemon AFFECTED on its own (nothing to match
    # against), but it becomes visible to is_sensitive/policy_says_sensitive/
    # guard_allows_restart and reachable by FORCE_RESTART_LABELS below —
    # instead of vanishing from discovery entirely.
    wd="$(plist_working_directory "$plist")"
    if working_directory_under_runtime "$wd"; then
      log "$label: no .py/.sh/-m entrypoint resolved, but WorkingDirectory ($wd) is under this rig's runtime — registering as a rig daemon with no known entrypoint (reachable via FORCE_RESTART_LABELS / daemon_restarts, not ad-hoc scanning)."
    else
      continue
    fi
  fi
  echo "$entry" > "$DISCO_DIR/$label"
  DAEMON_LABELS="$DAEMON_LABELS $label"
done
shopt -u nullglob

# ga-tdzsh: normalize like every other accumulator in this file (AFFECTED,
# RESTARTED, ... — see Step 4/5 below) before either the log lines or emit()
# read them, so the leading space `"$X $label"` accumulation leaves behind
# never reaches a caller doing an exact-match comparison on a single label.
PARSE_ERROR_LOADED="$(echo "$PARSE_ERROR_LOADED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
PARSE_ERROR_UNLOADED="$(echo "$PARSE_ERROR_UNLOADED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"

if [ -n "${PARSE_ERROR_LOADED// /}" ]; then
  log "ERROR: $(echo "$PARSE_ERROR_LOADED" | wc -w | tr -d ' ') LOADED daemon plist(s) could not be parsed — real discovery coverage gap:$PARSE_ERROR_LOADED"
fi
if [ -n "${PARSE_ERROR_UNLOADED// /}" ]; then
  log "note: $(echo "$PARSE_ERROR_UNLOADED" | wc -w | tr -d ' ') unloaded plist(s) could not be parsed and were skipped during discovery (harmless — nothing loaded under them):$PARSE_ERROR_UNLOADED"
fi

if [ -z "${DAEMON_LABELS// /}" ]; then
  if [ -n "${PARSE_ERROR_LABELS// /}" ]; then
    log "no rig daemons discovered under $LAUNCH_AGENTS_DIR for runtime $RUNTIME_DIR, but discovery could not read every plist — this is incomplete, not a confirmed-empty scan (see WARNs above)."
    emit OK "no rig daemons discovered but discovery incomplete (unparseable plists — see WARNs)" not_verified
  fi
  log "no rig daemons discovered under $LAUNCH_AGENTS_DIR for runtime $RUNTIME_DIR — OK (nothing to refresh)."
  emit OK "no rig daemons discovered" not_applicable
fi

# precompute changed basenames + stems for matching
CHANGED_BASENAMES="$(echo "$CHANGED_PY" | while read -r f; do [ -n "$f" ] && basename "$f"; done)"
# (ga-pntex) CHANGED_STEMS feeds the import-level/routes-hop checks in Step 3
# below — a tests/**/docs/** file must never contribute its own basename as a
# candidate "stem" there, same universal claim DEFAULT_NO_RESTART_PATTERNS
# already established above for the whole-changeset short-circuit (point
# 9/ga-dk7fw: "no daemon on any rig imports a test or doc file"), applied
# per-file instead of all-or-nothing. A real lib/*.py file changed in the
# SAME deploy is unaffected by this (its own basename still flows through
# normally) — only individual tests/**/docs/** entries are dropped from the
# candidate pool. Does NOT touch CHANGED_BASENAMES just above (used only for
# the direct entrypoint-basename match in Step 3) — a daemon's own entrypoint
# is never itself a tests/**/docs/** file. Pre-fix, a changed test file whose
# basename happened to COLLIDE with a real module name some daemon genuinely
# imports (e.g. tests/shared_helper.py vs. a daemon's own `from lib import
# shared_helper`) produced a false-positive AFFECTED — flagging (and for a
# SENSITIVE daemon, HOLDING THE GATE on) a daemon nothing about this deploy
# actually touched.
#
# (ga-9ps272) CHANGED_PY_FOR_STEMS itself now computed earlier, right after
# CHANGED_PY/CHANGED_TEMPLATES above — this gate's own no-python/template-
# changed early-exit needed the SAME filtered set, so the computation was
# hoisted rather than duplicated. Nothing here depends on anything Step 2
# discovers, so the earlier computation is identical to what this line used
# to produce itself.
CHANGED_STEMS="$(echo "$CHANGED_PY_FOR_STEMS" | while read -r f; do [ -n "$f" ] && basename "$f"; done | sed 's/\.py$//' | grep -v '^$' || true)"
CHANGED_TEMPLATE_BASENAMES="$(echo "$CHANGED_TEMPLATES" | while read -r f; do [ -n "$f" ] && basename "$f"; done)"

# is_sensitive <label>
is_sensitive() {
  local label="$1" sub
  for sub in $SENSITIVE_DAEMONS; do
    [ -n "$sub" ] || continue
    case "$label" in *"$sub"*) return 0 ;; esac
  done
  return 1
}

# policy_says_sensitive <label> (ga-ylr2m) -> 0 if restart_policy.yaml (when
# present) does NOT explicitly clear ALL of this daemon's entrypoints for
# auto-restart. Mirrors that file's own documented default ("unlisted =
# manual, notify-only") instead of this script's historical default
# ("unlisted = safe") — the registry-drift gap ga-ylr2m closes. No policy
# file, or a daemon whose entrypoint didn't resolve to a relpath (see
# resolve_relpath), means no opinion — returns 1 (not sensitive BY THIS
# SOURCE; SENSITIVE_DAEMONS is still checked independently by the caller via
# `||` — this only ever ADDS scrutiny, never removes it). A policy file that
# EXISTS but failed to parse (POLICY_PARSE_OK unset — see the loader comment
# above) is the third state: unconditionally sensitive, since "couldn't read
# it" must never collapse into the same value as "read it, nothing applies".
# Reads $DISCO_DIR/$label, populated for every label by Step 2 above.
policy_says_sensitive() {
  local label="$1" entries entry base locked_hit
  [ -f "$RESTART_POLICY_YAML" ] || return 1
  if [ -z "$POLICY_PARSE_OK" ]; then
    log "$label: restart_policy.yaml exists but did not parse — treating as sensitive (fail closed, unverifiable != cleared)."
    return 0
  fi
  entries="$(cat "$DISCO_DIR/$label" 2>/dev/null || true)"
  [ -n "${entries// /}" ] || return 1
  for entry in $entries; do
    base="$(basename "$entry")"
    case " $POLICY_AUTO $POLICY_DEPLOY_RESTART " in
      *" $base "*) continue ;;   # this entrypoint is explicitly allow-listed safe
    esac
    locked_hit=0
    case " $POLICY_NOTIFY_ONLY_LOCKED " in *" $base "*) locked_hit=1 ;; esac
    if [ "$locked_hit" -eq 1 ]; then
      log "$label ($base): restart_policy.yaml notify_only_locked — human trava, never auto."
    else
      log "$label ($base): not in restart_policy.yaml's 'auto'/'deploy_restart' — unlisted defaults to manual there."
    fi
    return 0   # at least one entrypoint is NOT explicitly safe -> sensitive
  done
  return 1   # every entrypoint explicitly allow-listed safe
}

# label_notify_only_locked <label> (ga-j3lh6p, header point 19) -> 0 iff at
# least one of this daemon's entrypoints is listed notify_only_locked in
# restart_policy.yaml AND is NOT explicitly allow-listed for automatic restart
# (auto/deploy_restart) — the SAME "explicitly safe first" precedence
# policy_says_sensitive() applies just above, so a daemon that automation CAN
# restart is never called locked (it is not stuck forever).
# Three-state honesty, and the uncertain direction is ALWAYS 1: no policy file,
# a policy that EXISTS but did not parse (POLICY_PARSE_OK unset — the sibling
# treats that as "sensitive", which is the fail-closed answer THERE; here the
# fail-closed answer is the opposite, "cannot prove locked"), or a label with no
# resolved entrypoint all return 1. This only feeds GUARDED_LOCKED_COSMETIC,
# where a wrong 0 would let a delivery through, so "don't know" must not read as
# "locked". Reads $DISCO_DIR/$label, populated for every label by Step 2.
label_notify_only_locked() {
  local label="$1" entries entry base
  [ -f "$RESTART_POLICY_YAML" ] || return 1
  [ -n "$POLICY_PARSE_OK" ] || return 1
  entries="$(cat "$DISCO_DIR/$label" 2>/dev/null || true)"
  [ -n "${entries// /}" ] || return 1
  for entry in $entries; do
    base="$(basename "$entry")"
    case " $POLICY_AUTO $POLICY_DEPLOY_RESTART " in
      *" $base "*) continue ;;   # explicitly allow-listed safe: not locked (precedes locked)
    esac
    case " $POLICY_NOTIFY_ONLY_LOCKED " in *" $base "*) return 0 ;; esac
  done
  return 1
}

# label_no_drain_configured <label> (ga-xrn8ni, header point 21) -> 0 iff this
# label is SENSITIVE (is_sensitive || policy_says_sensitive — the same "either
# source calling it sensitive makes it sensitive" union point 6 already
# established) AND no $DRAIN_CMD_<sanitized-label> is set for it — the exact
# fact that sends a SENSITIVE daemon down the "NO drain path configured -- NOT
# auto-bounced" branch in the Step-4 loop below, rather than the drain+
# kickstart path. Checks the underlying fact directly (never "which branch did
# Step 4 take") so it stays correct regardless of call order: a SENSITIVE
# daemon that DOES have a drain configured but was guarded for some OTHER
# reason (already_fresh() false, guard_allows_restart() refused) has
# DRAIN_CMD_<label> set and is correctly NOT no-drain-configured — that is a
# transient/dynamic reason (an in-flight guard can allow it next cycle),
# unlike this one, which is a static configuration gap that only changes when
# a human wires a drain command. Never true for a SAFE daemon: the SAFE branch
# below never even looks at DRAIN_CMD_<label>, so "no drain configured" is not
# why a SAFE daemon would ever be GUARDED.
# Three-state honesty, same direction as label_notify_only_locked() just
# above: a label that is not even SENSITIVE returns 1 ("don't know / not
# applicable"), never a false 0 — this only ever feeds
# GUARDED_NODRAIN_COSMETIC, where a wrong 0 would let a delivery through.
label_no_drain_configured() {
  local label="$1" sani drain_var
  is_sensitive "$label" || policy_says_sensitive "$label" || return 1
  sani="${label//[^A-Za-z0-9_]/_}"
  drain_var="DRAIN_CMD_${sani}"
  [ -z "${!drain_var:-}" ]
}

# guard_allows_restart <label> (ga-ylr2m) -> 0 if no configured guard objects.
# Consults restart_policy.yaml's restart_guard_scripts: for ANY of this
# daemon's entrypoints, mirroring whatsapp_automation/scripts/
# auto_restart_daemons.py's guard_allows_restart(): guard script exit 0 =
# proceed; any non-zero (1=in-flight, 2=don't know, a crash, a timeout) = do
# NOT restart — the third state ("don't know") collapses to the safe one,
# never to "proceed" (ga-mlsc0's own discipline, reused verbatim here). No
# entry for this daemon -> always allowed, IDENTICAL to before this change —
# the guard only ever SUBTRACTS a restart that would otherwise have happened,
# never adds one. Closes the "consult restart_guard_scripts before an
# auto-kickstart" half of ga-ylr2m: this script was a 4th, previously-
# unguarded restart trigger alongside WA's own three. A policy file that
# EXISTS but failed to parse (POLICY_PARSE_OK unset) refuses unconditionally
# — we cannot rule out a real guard entry we simply failed to read, and
# "couldn't verify" must fail the same way an active guard refusal does, not
# the same way "verified, no guard configured" does.
guard_allows_restart() {
  local label="$1" entries entry base pair d s script rc
  if [ -f "$RESTART_POLICY_YAML" ] && [ -z "$POLICY_PARSE_OK" ]; then
    log "$label: restart_policy.yaml exists but did not parse — cannot verify whether a guard applies; refusing restart (fail closed)."
    return 1
  fi
  [ -n "$POLICY_GUARDS" ] || return 0
  entries="$(cat "$DISCO_DIR/$label" 2>/dev/null || true)"
  for entry in $entries; do
    base="$(basename "$entry")"
    for pair in $POLICY_GUARDS; do
      d="${pair%%=*}"; s="${pair#*=}"
      [ "$d" = "$base" ] || continue
      script="$RUNTIME_DIR/$s"
      if [ ! -f "$script" ]; then
        log "$label ($base) guard script declared but missing on disk: $script — treating as refused (fail closed)."
        return 1
      fi
      timeout 15 python3 "$script" --quiet
      rc=$?
      if [ "$rc" -ne 0 ]; then
        log "$label ($base) guard $s refused (exit $rc) — not restarting."
        return 1
      fi
      log "$label ($base) guard $s: OK."
    done
  done
  return 0
}

# extract literal render_template("...") / render_template('...') first-arg
# names referenced in a file — same single-hop precision as the import-level
# .py match below (checks the daemon's own entrypoint, not its full transitive
# closure).
daemon_template_names() {  # daemon_template_names <file>
  local f="$1"
  [ -f "$f" ] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import re, sys
try:
    src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except Exception:
    sys.exit(0)
for m in re.findall(r'render_template\(\s*[\'"]([^\'"]+)[\'"]', src):
    print(m)
PY
}

# does <file> genuinely IMPORT <stem> — via the file's own AST, not a text
# grep, so a name merely MENTIONED in a comment/docstring/string literal
# never counts (ga-dn9ye: a bare `\bstem\b` grep over the whole file matched
# a filename named in a comment like "consumed by admin_dashboard.py",
# flagging daemons that never imported it). A single-line anchored regex
# (`^\s*(import|from)\s+.*\bstem\b`) fixes that but breaks on a parenthesized
# multi-line `from X import (\n    stem,\n)` — common, and exactly what the
# first gate review caught as a regression (ga-dn9ye attempt 1) — because the
# line with the stem doesn't itself start with import/from. Real AST parsing
# has neither problem: comments/docstrings/strings are never Import nodes,
# and multi-line/backslash-continued/aliased forms all parse the same as a
# single-line one. On a genuine parse failure, exits 1 (not affected) — same
# fail-soft shape as daemon_template_names() above; every entrypoint here is
# a live, running production daemon, so in practice it always parses.
#
# ga-pntex: Step 3 below (and daemon_imports_stem_via_routes() further down,
# which also calls this) checks this per (daemon, changed-stem) pair — for N
# daemons x M changed .py files that is up to N*M calls. Pre-fix this
# re-invoked a fresh python3 ast.parse of the SAME <file> on every one of
# those calls, even though <file>'s import set does not change across the M
# different stems it gets checked against — measured live: a 33min citywide
# gate stall, ~1-2 daemons/min processed, ~1% CPU throughout (the cost was
# process-SPAWN overhead, not computation). Now backed by a cache (below):
# the AST is parsed ONCE per unique file, and every subsequent stem check
# against that SAME file is an in-memory `grep -qxF` — zero additional
# python3 spawns. Mirrors daemon_template_names() above (extract once,
# membership-check in bash) instead of a fresh subprocess per candidate. The
# function's own signature/contract (call with <file> <stem>, get exit 0/1)
# is unchanged, so every call site benefits without modification.
IMPORTS_CACHE_DIR="$DISCO_DIR/.imports-cache"
mkdir -p "$IMPORTS_CACHE_DIR"

# extract EVERY stem <file> imports (one python3 ast.parse, all matches) —
# same single-hop precision as daemon_imports_stem() below, computed once per
# file instead of once per (file, candidate-stem) pair.
daemon_all_import_stems() {  # daemon_all_import_stems <file> -> one stem/line
  local f="$1"
  [ -f "$f" ] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import ast, sys
path = sys.argv[1]
try:
    tree = ast.parse(open(path, encoding="utf-8", errors="replace").read())
except Exception:
    sys.exit(0)
stems = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            stems.update(alias.name.split('.'))
    elif isinstance(node, ast.ImportFrom):
        if node.module:
            stems.update(node.module.split('.'))
        for alias in node.names:
            stems.add(alias.name)
for s in sorted(stems):
    print(s)
PY
}

daemon_imports_stem() {  # daemon_imports_stem <file> <stem>
  local f="$1" stem="$2" key cache_file
  [ -f "$f" ] || return 1
  key="$(echo "$f" | tr '/' '#')"
  cache_file="$IMPORTS_CACHE_DIR/$key"
  if [ ! -f "$cache_file" ]; then
    daemon_all_import_stems "$f" > "$cache_file.tmp" 2>/dev/null
    mv "$cache_file.tmp" "$cache_file"
  fi
  grep -qxF "$stem" "$cache_file"
}

# does <entrypoint-relpath> reach <stem> through a daemons/routes/*.py
# blueprint it mounts? (ga-q617u — header point 11.) One extra, TARGETED hop
# beyond daemon_imports_stem()'s own single-hop scan: real Flask dashboards in
# this codebase wire blueprints as `from routes import ..., pregao, ...` in
# the entrypoint, with the blueprint module doing its own separate imports
# (e.g. pregao.py's `from lib import assertiva_cache as _ac`) that the
# entrypoint's own AST never mentions. Gated on BOTH hops so this can only
# ever ADD a true finding, never cascade across unrelated dashboards: a
# routes/*.py file counts only when (a) the entrypoint itself imports that
# file's own stem (i.e. actually mounts it — not just shares the directory)
# AND (b) that routes file imports the changed stem. Deliberately scoped to
# <entrypoint-dir>/routes/*.py (non-recursive), not a full transitive
# closure — matches this codebase's actual blueprint layout and keeps the
# scan bounded to a handful of files instead of walking the whole tree.
daemon_imports_stem_via_routes() {  # daemon_imports_stem_via_routes <entrypoint-relpath> <stem>
  local entry="$1" stem="$2" routes_dir rfile rstem
  routes_dir="$RUNTIME_DIR/$(dirname "$entry")/routes"
  [ -d "$routes_dir" ] || return 1
  for rfile in "$routes_dir"/*.py; do
    [ -f "$rfile" ] || continue
    rstem="$(basename "$rfile" .py)"
    daemon_imports_stem "$RUNTIME_DIR/$entry" "$rstem" || continue
    daemon_imports_stem "$rfile" "$stem" && return 0
  done
  return 1
}

# ── deploy_deps.json consultation (ga-9lsuq0, header point 14) ───────────────
# See header point 14 for the full rationale. Computed ONCE here (not inside
# Step 3's per-daemon loop below) — same "compute once, reuse via bash
# membership checks" shape as ga-pntex's daemon_all_import_stems() cache
# above, so this adds exactly one python3 spawn total for the whole run, not
# one per daemon. Two space-separated relpath sets result:
#   JSON_KNOWN_ENTRYPOINTS    every entrypoint this file has a "closure" for
#   JSON_AFFECTED_ENTRYPOINTS the subset whose closure intersects $CHANGED
# Matched against the FULL raw $CHANGED (not the tests/docs/md-filtered
# CHANGED_PY_FOR_STEMS) — gen_daemon_deps.py's closure() only ever walks REAL
# import edges starting from a real entrypoint, so a tests/**/docs/**/*.md
# path can never be a member of any closure regardless of this choice;
# filtering here would be a no-op at best, and one more place for the two
# filters to silently drift apart at worst.
DEPLOY_DEPS_JSON="$RUNTIME_DIR/daemons/deploy_deps.json"
# ga-8q1ulq (header point 17): rig-owned symbol-reachability CLI (wa-th4b1) —
# generic, never vendored/reimplemented here. Its mere presence gates the
# whole ranking layer in Step 5 below (point 17's own item 3: absent =
# today's exact behavior, no error).
SYMBOL_SCRIPT="$RUNTIME_DIR/scripts/compute_symbol_reachability.py"
JSON_KNOWN_ENTRYPOINTS=""
JSON_AFFECTED_ENTRYPOINTS=""
if [ -f "$DEPLOY_DEPS_JSON" ]; then
  DDJ_LINES="$(CHANGED_FOR_DDJ="$CHANGED" python3 - "$DEPLOY_DEPS_JSON" <<'PY' 2>/dev/null
import json, os, sys
try:
    daemons = json.load(open(sys.argv[1], encoding="utf-8"))["daemons"]
    if not isinstance(daemons, dict):
        raise ValueError("'daemons' is not an object")
except Exception:
    sys.exit(1)
changed = {ln for ln in os.environ.get("CHANGED_FOR_DDJ", "").splitlines() if ln}
for path, info in sorted(daemons.items()):
    if not isinstance(path, str) or not isinstance(info, dict):
        continue
    print("K:" + path)
    closure = {x for x in (info.get("closure") or []) if isinstance(x, str)}
    if changed & closure:
        print("A:" + path)
PY
)"
  if [ $? -eq 0 ]; then
    JSON_KNOWN_ENTRYPOINTS="$(echo "$DDJ_LINES" | sed -n 's/^K://p' | tr '\n' ' ')"
    JSON_AFFECTED_ENTRYPOINTS="$(echo "$DDJ_LINES" | sed -n 's/^A://p' | tr '\n' ' ')"
  else
    log "WARN: $DEPLOY_DEPS_JSON exists but could not be read as the expected {\"daemons\": {\"<relpath>\": {\"closure\": [...]}}} shape — every entrypoint falls back to this script's own import-stem matching for this run (fail-soft, not fail-closed: unlike restart_policy.yaml's sensitivity default above, discovery/matching already has a working — if less precise — path to fall back to, so there is no reason to treat every daemon as maximally suspect over an unparseable companion file)."
  fi
fi

# ga-9lug2k: aggregate, per-run coverage accounting — how many of THIS run's
# discovered entrypoints (Step 3 below, all of $DAEMON_LABELS) had their
# import-reachability decided by deploy_deps.json's real recursive closure vs
# fell back to the bounded ad-hoc heuristic (entrypoint-direct + one
# routes/*.py hop). Incremented by Step 3's existing per-daemon loop (one
# bump per entry already being iterated there — no new loop, no new python3
# spawn). Consulted by Step 5 (verdict) below to decide whether the
# NEEDS_GUARDED_RESTART caveat can honestly say "closure is complete for
# every entrypoint this run considered" instead of the generic "verify by
# hand" — never guessed, only asserted when the count proves it.
TOTAL_ENTRY_COUNT=0
JSON_COVERED_ENTRY_COUNT=0

# Regen date for that same caveat — prefer the commit that last touched the
# file in RUNTIME_DIR's own history (the real "when was this rig's closure
# last regenerated" answer for a checked-out deploy), falling back to the
# file's own mtime when the path isn't git-tracked (non-git runtime, or a
# freshly-copied file never committed). Never fatal either way: cosmetic
# context in a message, not a correctness input.
DEPLOY_DEPS_REGEN=""
if [ -f "$DEPLOY_DEPS_JSON" ]; then
  DEPLOY_DEPS_REGEN="$(git -C "$RUNTIME_DIR" log -1 --format=%ad --date=short -- daemons/deploy_deps.json 2>/dev/null || true)"
  if [ -z "$DEPLOY_DEPS_REGEN" ]; then
    DEPLOY_DEPS_REGEN="$(stat -f '%Sm' -t '%Y-%m-%d' "$DEPLOY_DEPS_JSON" 2>/dev/null || true)"
  fi
  [ -n "$DEPLOY_DEPS_REGEN" ] || DEPLOY_DEPS_REGEN="unknown date"
fi

# does deploy_deps.json have a closure entry for <entrypoint-relpath> at all?
json_covers_entry() {  # json_covers_entry <entrypoint-relpath>
  case " $JSON_KNOWN_ENTRYPOINTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
# is <entrypoint-relpath>'s (deploy_deps.json) closure known to intersect
# this deploy's changed files?
json_entry_affected() {  # json_entry_affected <entrypoint-relpath>
  case " $JSON_AFFECTED_ENTRYPOINTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
# closure paths (one per line) deploy_deps.json has for <entrypoint-relpath>,
# or nothing if it doesn't cover that entry or the file can't be read.
# (ga-8q1ulq, header point 17) Re-reads the file rather than reusing
# DDJ_LINES above: DDJ_LINES only ever kept path MEMBERSHIP (K:/A:), never
# the closure LISTS themselves, and only entries that end up GUARDED (a
# small subset of JSON_KNOWN_ENTRYPOINTS) ever need their closure — reading
# those few here, lazily, is cheaper than carrying every entry's full
# closure through the whole run whether or not it is ever used.
json_closure_for_entry() {  # json_closure_for_entry <entrypoint-relpath>
  [ -f "$DEPLOY_DEPS_JSON" ] || return 1
  python3 - "$DEPLOY_DEPS_JSON" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    daemons = json.load(open(sys.argv[1], encoding="utf-8"))["daemons"]
    entry = daemons.get(sys.argv[2])
except Exception:
    sys.exit(1)
if not isinstance(entry, dict):
    sys.exit(1)
for p in entry.get("closure") or []:
    if isinstance(p, str):
        print(p)
PY
}

# ── rig-owned own-mode stale detector consultation (ga-abofl6, header point 20) ─
# See header point 20 for the full rationale. Computed ONCE here, same "one
# python3 spawn total for the whole run" shape as the deploy_deps.json block
# above — RIG_STALE_SCRIPT's --json output already IS the two K:/A|"known"/
# "affected" sets, no per-daemon re-derivation needed. Bounded by `timeout`:
# an external rig script is not this file's to trust with an unbounded wait
# (same reasoning SYMBOL_REACHABILITY_TOTAL_TIMEOUT already applies to
# compute_symbol_reachability.py above).
RIG_STALE_SCRIPT="$RUNTIME_DIR/scripts/detect_stale_daemons.py"
RIG_KNOWN_ENTRYPOINTS=""
RIG_AFFECTED_ENTRYPOINTS=""
if [ -f "$RIG_STALE_SCRIPT" ]; then
  RSD_JSON="$(timeout "$RIG_STALE_DETECTOR_TIMEOUT" python3 "$RIG_STALE_SCRIPT" --mode own --no-fetch --json 2>/dev/null)"
  RSD_RC=$?
  if [ "$RSD_RC" -eq 0 ] && [ -n "$RSD_JSON" ]; then
    # ga-abofl6: argv, not a piped stdin -- `python3 -` already consumes the
    # heredoc below AS its own program source, so stdin is spent before the
    # program body ever runs; a second redirect/pipe into the same fd0 cannot
    # also deliver data (the deploy_deps.json/json_closure_for_entry blocks
    # above never hit this because they pass a FILE PATH via argv and let the
    # script open it itself -- same shape, applied to a string instead).
    RSD_LINES="$(python3 - "$RSD_JSON" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.loads(sys.argv[1])
    known = d.get("known") or []
    affected = d.get("affected") or []
    if not isinstance(known, list) or not isinstance(affected, list):
        raise ValueError("known/affected not lists")
except Exception:
    sys.exit(1)
for p in known:
    if isinstance(p, str):
        print("K:" + p)
for p in affected:
    if isinstance(p, str):
        print("A:" + p)
PY
)"
    if [ $? -eq 0 ]; then
      RIG_KNOWN_ENTRYPOINTS="$(echo "$RSD_LINES" | sed -n 's/^K://p' | tr '\n' ' ')"
      RIG_AFFECTED_ENTRYPOINTS="$(echo "$RSD_LINES" | sed -n 's/^A://p' | tr '\n' ' ')"
      RIG_DETECTOR_USED=1
    else
      log "WARN: $RIG_STALE_SCRIPT --json produced output that wasn't the expected {\"known\":[...],\"affected\":[...]} shape — every entrypoint falls back to deploy_deps.json/ad-hoc matching for this run (fail-soft, same as an unparseable deploy_deps.json above)."
    fi
  else
    log "WARN: $RIG_STALE_SCRIPT --mode own --no-fetch --json failed or timed out (rc=$RSD_RC, timeout=${RIG_STALE_DETECTOR_TIMEOUT}s) — every entrypoint falls back to deploy_deps.json/ad-hoc matching for this run. RIG_DETECTOR_USED stays 0: 'the rig detector failed to answer' must never look like 'it positively confirmed nothing is stale'."
  fi
fi
# does the rig's own detector's own-mode examine <entrypoint-relpath> at all?
rig_detector_covers_entry() {  # rig_detector_covers_entry <entrypoint-relpath>
  case " $RIG_KNOWN_ENTRYPOINTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
# did the rig's own detector's own-mode find <entrypoint-relpath> stale?
rig_detector_entry_affected() {  # rig_detector_entry_affected <entrypoint-relpath>
  case " $RIG_AFFECTED_ENTRYPOINTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# ── Step 3: resolve affected daemons ──────────────────────────────────────────
for label in $DAEMON_LABELS; do
  entries="$(cat "$DISCO_DIR/$label")"
  affected=0
  own_stems=""
  for e in $entries; do own_stems="$own_stems $(basename "$e" .py)"; done

  # (ga-9lsuq0, header point 14) split entries into ones deploy_deps.json
  # already has a real closure for — trust it EXCLUSIVELY for those, since
  # supplementing (union) would still let a bare-name false positive leak
  # through from the ad-hoc side below — and ones it doesn't, which still get
  # the full ad-hoc scan, unchanged. An entrypoint's own file is trivially a
  # member of its own closure (gen_daemon_deps.py's closure() seeds the walk
  # with the start file itself), so json_entry_affected already subsumes the
  # "direct" self-changed case below for a covered entry — no separate check
  # needed for it.
  ad_hoc_entries=""
  rig_hit=0
  for e in $entries; do
    TOTAL_ENTRY_COUNT=$((TOTAL_ENTRY_COUNT + 1))
    # (ga-abofl6, header point 20) rig detector takes precedence OVER
    # deploy_deps.json's closure — trust it EXCLUSIVELY when it covers this
    # entry, same "supplementing would let a false positive leak through"
    # reasoning as the JSON split below, one tier up: own mode already folds
    # in registered assets + one-hop imports, so a covered entry's verdict
    # already subsumes what the JSON/ad-hoc checks would otherwise ask.
    if rig_detector_covers_entry "$e"; then
      if rig_detector_entry_affected "$e"; then affected=1; rig_hit=1; fi
    elif json_covers_entry "$e"; then
      JSON_COVERED_ENTRY_COUNT=$((JSON_COVERED_ENTRY_COUNT + 1))
      json_entry_affected "$e" && affected=1
    else
      ad_hoc_entries="$ad_hoc_entries $e"
    fi
  done

  # direct: an entrypoint relpath or basename is in the changed set
  # (ad_hoc_entries only, ga-9lsuq0 — a deploy_deps.json-covered entry's own
  # file is already handled via its own closure above)
  if [ "$affected" -eq 0 ]; then
    for e in $ad_hoc_entries; do
      if echo "$CHANGED_PY" | grep -xF "$e" >/dev/null; then affected=1; break; fi
      eb="$(basename "$e")"
      if echo "$CHANGED_BASENAMES" | grep -xF "$eb" >/dev/null; then affected=1; break; fi
    done
  fi

  # import-level: a changed shared module (not this daemon's own entrypoint)
  # is actually imported by one of the entrypoint files — see
  # daemon_imports_stem() above for why this is real AST parsing, not a
  # grep/regex (ga-dn9ye: a bare text match flagged a comment MENTION as an
  # import; the first, regex-anchored fix then missed a multi-line
  # parenthesized import — both classes need real parsing, not text
  # matching). ad_hoc_entries only (ga-9lsuq0) — see the split above.
  if [ "$affected" -eq 0 ]; then
    for stem in $CHANGED_STEMS; do
      case " $own_stems " in *" $stem "*) continue ;; esac   # own entrypoint → handled above
      for e in $ad_hoc_entries; do
        if daemon_imports_stem "$RUNTIME_DIR/$e" "$stem"; then
          affected=1; break
        fi
      done
      [ "$affected" -eq 1 ] && break
    done
  fi

  # route-blueprint hop (ga-q617u, header point 11): the changed module is
  # not imported by the entrypoint directly, but IS imported by a
  # daemons/routes/*.py blueprint file the entrypoint mounts — see
  # daemon_imports_stem_via_routes() above. ad_hoc_entries only (ga-9lsuq0).
  if [ "$affected" -eq 0 ]; then
    for stem in $CHANGED_STEMS; do
      case " $own_stems " in *" $stem "*) continue ;; esac   # own entrypoint → handled above
      for e in $ad_hoc_entries; do
        if daemon_imports_stem_via_routes "$e" "$stem"; then
          affected=1; break
        fi
      done
      [ "$affected" -eq 1 ] && break
    done
  fi

  # template: a changed template this daemon's own entrypoint renders via
  # render_template(...) (ga-jkj0 — Jinja templates are cached in-process and
  # a disk-only change is otherwise invisible to this script). Uses the FULL
  # $entries, not $ad_hoc_entries: deploy_deps.json's "closure" key is
  # import-only (ga-9lsuq0) — template coverage stays on this mechanism
  # regardless of closure coverage (see the header point 14 "assets" note).
  if [ "$affected" -eq 0 ] && [ -n "${CHANGED_TEMPLATE_BASENAMES// /}" ]; then
    for e in $entries; do
      [ -f "$RUNTIME_DIR/$e" ] || continue
      while IFS= read -r tmpl; do
        [ -n "$tmpl" ] || continue
        tb="$(basename "$tmpl")"
        if echo "$CHANGED_TEMPLATE_BASENAMES" | grep -xF "$tb" >/dev/null; then
          affected=1; break
        fi
      done < <(daemon_template_names "$RUNTIME_DIR/$e")
      [ "$affected" -eq 1 ] && break
    done
  fi

  [ "$affected" -eq 1 ] || continue
  AFFECTED="$AFFECTED $label"
  log "AFFECTED: $label (entrypoints:$entries)"
  # (ga-abofl6, header point 20) did the rig's own detector decide THIS
  # label's affected=1, for at least one of its entries? Independent of
  # own_hit below (own_hit asks "is the entrypoint's OWN file in the diff",
  # this asks "which mechanism made the call") — a rig-detector hit can be
  # own_hit=1 (its own .py changed) or 0 (a one-hop import changed instead).
  [ "$rig_hit" -eq 1 ] && AFFECTED_RIG_DETECTOR="$AFFECTED_RIG_DETECTOR $label"

  # wa-flysp (header point 16): independently of WHICH check above set
  # affected=1 (direct, import-level, route-hop, JSON-closure, or template),
  # also record whether THIS label's OWN entrypoint file/template
  # specifically — not a transitively-imported sibling module — is itself in
  # the changed set. A SECOND, fully independent pass over $entries (not
  # $ad_hoc_entries — a JSON-covered entry's own file counts too) against
  # $CHANGED_PY/$CHANGED_BASENAMES/$CHANGED_TEMPLATE_BASENAMES directly,
  # deliberately NOT threaded through the five short-circuited affected=1
  # branches above — those are exactly-tuned and heavily bug-fixed on their
  # CURRENT shape (ga-dn9ye, ga-q617u, ga-9lsuq0); a fully separate read-only
  # pass here can never perturb them.
  own_hit=0
  for e in $entries; do
    if echo "$CHANGED_PY" | grep -xF "$e" >/dev/null; then own_hit=1; break; fi
    eb="$(basename "$e")"
    if echo "$CHANGED_BASENAMES" | grep -xF "$eb" >/dev/null; then own_hit=1; break; fi
  done
  if [ "$own_hit" -eq 0 ] && [ -n "${CHANGED_TEMPLATE_BASENAMES// /}" ]; then
    for e in $entries; do
      [ -f "$RUNTIME_DIR/$e" ] || continue
      while IFS= read -r tmpl; do
        [ -n "$tmpl" ] || continue
        tb="$(basename "$tmpl")"
        if echo "$CHANGED_TEMPLATE_BASENAMES" | grep -xF "$tb" >/dev/null; then
          own_hit=1; break
        fi
      done < <(daemon_template_names "$RUNTIME_DIR/$e")
      [ "$own_hit" -eq 1 ] && break
    done
  fi
  [ "$own_hit" -eq 1 ] && AFFECTED_OWN="$AFFECTED_OWN $label"
done

AFFECTED="$(echo "$AFFECTED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
AFFECTED_OWN="$(echo "$AFFECTED_OWN" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
AFFECTED_RIG_DETECTOR="$(echo "$AFFECTED_RIG_DETECTOR" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"

# ga-fzfqsu: FORCE_RESTART_LABELS (delivery-runbooks.toml's daemon_restarts,
# threaded through by the caller) forces its labels into AFFECTED
# unconditionally — regardless of whether Step 2 discovered an entrypoint for
# them, or the ad-hoc/import-level/route-hop/template matching above would
# ever have concluded they're affected. This is the static, "ALWAYS restart"
# override delivery-runbooks.toml documents, and the only mechanism that
# reaches a daemon whose real entrypoint isn't resolvable from argv at all
# (e.g. `python -m flask` — see the WorkingDirectory fallback in Step 2). A
# label here that Step 2 never discovered still flows cleanly through Step 4
# below: daemon_pid()/is_sensitive()/policy_says_sensitive() are all launchd-
# label-keyed, not entry-keyed, and degrade safely (not sensitive, no policy
# opinion) when $DISCO_DIR/$label doesn't exist.
for fr_label in $FORCE_RESTART_LABELS; do
  [ -n "$fr_label" ] || continue
  case " $AFFECTED " in
    *" $fr_label "*) ;;
    *)
      log "FORCE_RESTART_LABELS: $fr_label forced into AFFECTED (daemon_restarts static override, not entrypoint-matched)."
      AFFECTED="$AFFECTED $fr_label"
      # wa-flysp (header point 16, pre-flight self-audit finding): a
      # force-restart label never runs through Step 3's own_hit loop above
      # (it can be added here precisely because Step 2 couldn't even
      # discover an entrypoint for it), so it would otherwise default to
      # GUARDED_CLOSURE_ONLY by omission if it later becomes GUARDED — a
      # "don't know" (own_hit was never evaluated) silently collapsing into
      # the SAME bucket as "checked and it's transitively-only", mislabeling
      # an explicit operator override as "known noise, verify by hand"
      # instead of the strongest, most-actionable signal this script has.
      # Treat it as own/actionable by construction — never closure-only.
      AFFECTED_OWN="$AFFECTED_OWN $fr_label"
      ;;
  esac
done
AFFECTED="$(echo "$AFFECTED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"

# ── per-daemon baseline narrowing (ga-0fawwr) ─────────────────────────────────
# THE BUG THIS BLOCK FIXES: everything above computes ONE shared $CHANGED
# window (this call's own PRE_DEPLOY_SHA..POST_DEPLOY_SHA) and applies it to
# EVERY daemon on the rig alike. The caller (story-delivery.sh) only ever
# advances that shared PRE_DEPLOY_SHA when the WHOLE rig comes back OK|SKIPPED
# in one cycle — deliberately (ga-gokm6/ga-3bdttu): advancing it on a partial
# pass would hide a real unresolved staleness from every future sweep, not
# just this one. But the two facts compound badly: a rig with even ONE daemon
# that legitimately needs a human's guarded restart (and can stay that way for
# days — e.g. inbound_sweep.py's own restart_guard_scripts deliberately defers
# while it is "between chats") freezes that SAME shared window for every OTHER
# daemon too. A daemon with a large import closure (inbound_sweep.py: 53
# files, the largest in the WA fleet) then intersects SOME file in that
# ever-widening window on nearly every cycle, regardless of whether anything
# in ITS OWN closure specifically changed since it was last individually
# clean — measured live: 115 of 194 cycles NEEDS_GUARDED_RESTART over 5
# days/507 files of accumulated drift, with the rig-wide baseline advancing
# only twice in that window.
#
# THE FIX: the caller additionally tracks, per label, the POST_DEPLOY_SHA of
# the last cycle in which THAT SPECIFIC label was not stuck (not in GUARDED,
# not in FRESH_FAIL) — see DAEMON_BASELINE_OVERRIDES above — and we use it
# here to ask a NARROWER, label-specific question for any label the wide/
# shared computation above already flagged AFFECTED: does this label's
# closure ALSO intersect the changed set since ITS OWN last-clean point,
# specifically? This can only ever REMOVE a label from AFFECTED, never add
# one: a label with no override (every label, the first cycle this ships) or
# an unusable one (see the ancestor checks below) is left completely
# untouched — byte-for-byte identical to this script's behavior before this
# fix. A label that fails the narrow recheck too (its OWN window ALSO
# intersects its closure) stays in AFFECTED exactly as before; nothing here
# ever hides a real, unresolved restart need — it only stops re-litigating one
# that a DIFFERENT sibling daemon's own stuck state was incidentally widening.
#
# Runs AFTER FORCE_RESTART_LABELS is folded in (never reconsiders a static
# always-restart override — that list is direct operator/runbook intent, not
# closure-diff evidence) and BEFORE Step 4, so a downgraded label never
# reaches the restart/verify machinery at all this cycle — same as if it had
# never been flagged.
# ga0fawwr (per-daemon baseline narrowing) + ga-n2jnsa (per-daemon freshness
# floor + AFFECTED widening) share these two helpers. Defined
# UNCONDITIONALLY (not gated on DAEMON_BASELINE_OVERRIDES/AFFECTED as they
# used to be) because already_fresh() below needs ga0fawwr_label_hits on
# EVERY invocation, including the common case where DAEMON_BASELINE_OVERRIDES
# is empty (first cycle for a rig, or a rig that has never had a stuck
# daemon) — calling into a conditionally-defined function is silently
# "command not found" in bash, and that must never depend on which cycle
# happens to be running.
#
# git diff --name-only <sha>..POST_DEPLOY_SHA, memoized per distinct <sha> —
# several labels sharing the same last-resolved cycle (the common case) pay
# for exactly one git invocation, not one per label.
ga0fawwr_narrow_changed() {  # ga0fawwr_narrow_changed <sha> -> prints multiline changed
  # set on stdout, returns 1 if the diff itself could not be computed at
  # all. Third-state: a FAILED `git diff` and a SUCCESSFUL diff that just
  # happens to be empty must never collapse into the same "" — the first
  # means "unknown, could not check" (caller must keep the label as
  # originally affected), the second means "confirmed, genuinely nothing
  # changed" (a real, safe signal to downgrade on). Returning 1 only on the
  # former, distinct from printing empty output on the latter, is what lets
  # the caller tell them apart.
  local sha="$1" cache
  cache="$DISCO_DIR/.ga0fawwr-changed.$(echo "$sha" | tr -c 'A-Za-z0-9' '_')"
  if [ ! -f "$cache" ]; then
    if ! git -C "$RUNTIME_DIR" diff --name-only "$sha" "$POST_DEPLOY_SHA" > "$cache" 2>/dev/null; then
      rm -f "$cache" 2>/dev/null
      return 1
    fi
  fi
  cat "$cache" 2>/dev/null || true
}

# is <label> still affected once measured against its OWN narrower <changed>
# set? Same signals Step 3 above already trusts (deploy_deps.json closure
# when it covers an entry, else direct/basename + import-stem + routes-hop +
# template), replicated here rather than shared with Step 3's loop — that
# loop is optimized to run once for the WHOLE rig against the wide $CHANGED;
# this one runs rarely (only for a label already flagged AFFECTED that also
# has a usable override) against a label-specific narrow set, so a second,
# smaller implementation is the lower-risk choice over threading a second
# changed-set through the shared one.
ga0fawwr_label_hits() {  # ga0fawwr_label_hits <label> <changed-multiline> -> 0 if still affected
  local label="$1" changed="$2" e eb stem tmpl tb pat covered=0
  local entries json_entries="" adhoc_entries=""
  entries="$(cat "$DISCO_DIR/$label" 2>/dev/null || true)"
  # third-state: an entries file we can't read/find here is "don't know",
  # not "no entries" — Step 3 already proved this label real (it's only
  # ever called for a label already in $AFFECTED, and FORCE_RESTART_LABELS
  # members are excluded before this is ever reached), so an unreadable
  # file now is a filesystem hiccup, not evidence of a clean closure. Fail
  # toward the SAFE side of a downgrade decision: still hit (0), i.e. never
  # downgrade on a read we couldn't actually perform.
  [ -n "${entries// /}" ] || return 0
  for e in $entries; do
    if json_covers_entry "$e"; then json_entries="$json_entries $e"; else adhoc_entries="$adhoc_entries $e"; fi
  done

  if [ -n "${json_entries// /}" ] && [ -f "$DEPLOY_DEPS_JSON" ]; then
    local hit hit_rc
    hit="$(CHANGED_FOR_DDJ="$changed" ENTRIES_FOR_DDJ="$json_entries" python3 - "$DEPLOY_DEPS_JSON" <<'PY' 2>/dev/null
import json, os, sys
try:
    daemons = json.load(open(sys.argv[1], encoding="utf-8"))["daemons"]
except Exception:
    sys.exit(1)
changed = {ln for ln in os.environ.get("CHANGED_FOR_DDJ", "").splitlines() if ln}
entries = set(os.environ.get("ENTRIES_FOR_DDJ", "").split())
for path, info in daemons.items():
    if path not in entries or not isinstance(info, dict):
        continue
    closure = {x for x in (info.get("closure") or []) if isinstance(x, str)}
    if changed & closure:
        print("HIT")
        break
PY
)"
    hit_rc=$?
    if [ "$hit" = "HIT" ]; then
      return 0
    elif [ "$hit_rc" -ne 0 ]; then
      # third-state: python/deploy_deps.json failed to answer at all for
      # these exclusively-trusted entries (header point 14) — unknown, not
      # "confirmed clean". A crashed check must never look like a clean
      # one; fail toward keeping the label affected.
      return 0
    fi
    # hit_rc==0 and hit != HIT: python ran fine and positively confirmed no
    # intersection for every json-covered entry — trust that exclusively
    # (header point 14) and do NOT fall through to ad-hoc for THESE
    # entries; only adhoc_entries (below, entries json doesn't cover at
    # all) can still keep the label affected.
  fi
  [ -n "${adhoc_entries// /}" ] || return 1

  local c_py c_stems="" c_tpl_basenames py_basenames
  c_py="$(echo "$changed" | grep -E '\.py$' || true)"
  c_tpl_basenames="$(echo "$changed" | grep -E '\.(html|htm|jinja2?|j2)$' | while read -r f; do [ -n "$f" ] && basename "$f"; done)"
  py_basenames="$(echo "$c_py" | while read -r f; do [ -n "$f" ] && basename "$f"; done)"
  # tests/**, docs/**, *.md never contribute a stem — same universal claim
  # DEFAULT_NO_RESTART_PATTERNS already establishes for the wide computation.
  set -f
  while IFS= read -r pyf; do
    [ -n "$pyf" ] || continue
    covered=0
    for pat in $DEFAULT_NO_RESTART_PATTERNS; do
      # shellcheck disable=SC2254  # deliberate glob match, not literal
      case "$pyf" in $pat) covered=1; break ;; esac
    done
    [ "$covered" -eq 1 ] || c_stems="$c_stems $(basename "$pyf" .py)"
  done <<< "$c_py"
  set +f

  for e in $adhoc_entries; do
    echo "$c_py" | grep -xF "$e" >/dev/null && return 0
    eb="$(basename "$e")"
    echo "$py_basenames" | grep -xF "$eb" >/dev/null && return 0
  done
  for stem in $c_stems; do
    for e in $adhoc_entries; do
      daemon_imports_stem "$RUNTIME_DIR/$e" "$stem" && return 0
      daemon_imports_stem_via_routes "$e" "$stem" && return 0
    done
  done
  if [ -n "${c_tpl_basenames// /}" ]; then
    for e in $adhoc_entries; do
      [ -f "$RUNTIME_DIR/$e" ] || continue
      while IFS= read -r tmpl; do
        [ -n "$tmpl" ] || continue
        tb="$(basename "$tmpl")"
        echo "$c_tpl_basenames" | grep -xF "$tb" >/dev/null && return 0
      done < <(daemon_template_names "$RUNTIME_DIR/$e")
    done
  fi
  return 1
}

# ga-n2jnsa: resolve the best AVAILABLE per-daemon starting point to walk
# from when looking for the most recent commit that touches <label>'s own
# closure — deliberately a LOOSER contract than the narrowing block's own
# override-validity check below (which requires the override to sit
# STRICTLY inside (PRE_DEPLOY_SHA, POST_DEPLOY_SHA], because narrowing only
# ever wants a NARROWER window). Here an override OLDER than PRE_DEPLOY_SHA
# is exactly the case worth walking from: it is the "stuck" signature this
# story exists to fix (rig-wide marker advanced past the label's own last-
# clean point, ga-49fwiw's unattributed-release path). Only two bars: the
# value must be a real commit, and it must be an ancestor of POST_DEPLOY_SHA
# (so base..POST is a well-formed range for `git rev-list` below). Falls
# back to PRE_DEPLOY_SHA — today's implicit walk-from point — whenever no
# override exists or it fails either bar, so a label with nothing recorded
# yet behaves exactly as before this fix.
ga0fawwr_freshness_base_sha() {  # ga0fawwr_freshness_base_sha <label> -> prints a sha
  local label="$1" override_sha
  override_sha="$(printf '%s\n' "$DAEMON_BASELINE_OVERRIDES" | awk -v l="$label" '$1==l{print $2; exit}')"
  if [ -n "$override_sha" ] \
     && git -C "$RUNTIME_DIR" cat-file -e "${override_sha}^{commit}" 2>/dev/null \
     && git -C "$RUNTIME_DIR" merge-base --is-ancestor "$override_sha" "$POST_DEPLOY_SHA" 2>/dev/null; then
    printf '%s' "$override_sha"
  else
    printf '%s' "$PRE_DEPLOY_SHA"
  fi
}

# ga-n2jnsa: the epoch of the MOST RECENT commit in (<base_sha>,
# POST_DEPLOY_SHA] whose changes actually hit <label>'s closure (reusing
# ga0fawwr_label_hits's exact hit-test, single-commit at a time, newest
# first via `git rev-list`) — the per-daemon replacement for "the tip of
# whatever window happens to be under examination this cycle" that
# already_fresh() used exclusively before this fix. Returns 1 (nothing
# printed) when the range is empty or no single commit in it hits the
# closure — the caller falls back to COMMIT_EPOCH, unchanged from today,
# rather than ever guessing. The epoch found here is always <= COMMIT_EPOCH
# (it names a commit at or before POST_DEPLOY_SHA), so swapping it in below
# can only ever ADD true-fresh detections relative to the old COMMIT_EPOCH-
# only comparison — the identical safety argument the COMMIT_EPOCH-vs-
# DEPLOY_EPOCH comment above already established.
ga0fawwr_daemon_closure_epoch() {  # ga0fawwr_daemon_closure_epoch <label> <base_sha> -> prints epoch, or nothing (return 1)
  local label="$1" base_sha="$2" sha single_changed
  [ "$base_sha" != "$POST_DEPLOY_SHA" ] || return 1
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    single_changed="$(git -C "$RUNTIME_DIR" diff --name-only "${sha}^" "$sha" 2>/dev/null || true)"
    if ga0fawwr_label_hits "$label" "$single_changed"; then
      git -C "$RUNTIME_DIR" show -s --format=%ct "$sha" 2>/dev/null
      return 0
    fi
  done < <(git -C "$RUNTIME_DIR" rev-list "${base_sha}..${POST_DEPLOY_SHA}" 2>/dev/null)
  return 1
}

# ga-n2jnsa: already_fresh()'s per-daemon floor, or nothing when it cannot
# be determined (caller falls back to COMMIT_EPOCH — zero regression).
ga0fawwr_daemon_floor_epoch() {  # ga0fawwr_daemon_floor_epoch <label> -> prints epoch, or nothing (return 1)
  local label="$1" base_sha
  base_sha="$(ga0fawwr_freshness_base_sha "$label")"
  ga0fawwr_daemon_closure_epoch "$label" "$base_sha"
}

if [ -n "${DAEMON_BASELINE_OVERRIDES// /}" ] && [ -n "${AFFECTED// /}" ]; then
  NARROWED_AFFECTED=""
  for label in $AFFECTED; do
    # never reconsider a static always-restart override — see comment above.
    case " $FORCE_RESTART_LABELS " in
      *" $label "*) NARROWED_AFFECTED="$NARROWED_AFFECTED $label"; continue ;;
    esac
    override_sha="$(printf '%s\n' "$DAEMON_BASELINE_OVERRIDES" | awk -v l="$label" '$1==l{print $2; exit}')"
    if [ -z "$override_sha" ] \
       || [ "$override_sha" = "$PRE_DEPLOY_SHA" ] \
       || ! git -C "$RUNTIME_DIR" cat-file -e "${override_sha}^{commit}" 2>/dev/null \
       || ! git -C "$RUNTIME_DIR" merge-base --is-ancestor "$override_sha" "$POST_DEPLOY_SHA" 2>/dev/null \
       || ! git -C "$RUNTIME_DIR" merge-base --is-ancestor "$PRE_DEPLOY_SHA" "$override_sha" 2>/dev/null; then
      # no usable, strictly-narrower override for this label (missing, equal
      # to the wide baseline already used above, unresolvable, or not
      # actually between PRE_DEPLOY_SHA and POST_DEPLOY_SHA in this rig's
      # real history — a rebase/force-push/wrong-rig value) — leave it in
      # AFFECTED untouched, exactly as before this fix.
      NARROWED_AFFECTED="$NARROWED_AFFECTED $label"
      continue
    fi
    if ! narrow_changed="$(ga0fawwr_narrow_changed "$override_sha")"; then
      # `git diff` itself failed against a sha that passed every check above
      # (real commit, correctly ordered) — a transient/environmental fault,
      # not evidence of anything. Unknown, so keep the label exactly as the
      # wide computation found it; never treat "could not check" as "checked
      # and clean".
      log "ga-0fawwr: could not compute the narrow changed-set for $label against override $override_sha (git diff failed) — leaving it in AFFECTED, unmodified."
      NARROWED_AFFECTED="$NARROWED_AFFECTED $label"
    elif ga0fawwr_label_hits "$label" "$narrow_changed"; then
      NARROWED_AFFECTED="$NARROWED_AFFECTED $label"
    else
      log "ga-0fawwr: $label downgraded out of AFFECTED — its own closure is clean since $override_sha (its individually-tracked last-clean point), even though the rig-wide window ($PRE_DEPLOY_SHA..$POST_DEPLOY_SHA) still intersects it via a DIFFERENT daemon's unresolved staleness."
    fi
  done
  AFFECTED="$(echo "$NARROWED_AFFECTED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
fi

# ── ga-n2jnsa: widen AFFECTED back to include still-"stuck" per-daemon
# entries the wide window above no longer covers ──────────────────────────
# The narrowing block above (ga-0fawwr) can only ever REMOVE a label from
# AFFECTED; nothing until now could ever put one back. Once the rig-wide
# marker (PRE_DEPLOY_SHA) advances past the commit that originally caused a
# label's guarded/fresh-fail state (ga-49fwiw's unattributed-release path),
# the wide Step 3 computation above stops seeing that trigger commit at
# all, so the label never even reaches the narrowing block above — it just
# silently disappears from AFFECTED, from the wide list, and from
# consideration, with only its frozen .perdaemon record left behind
# ("<label> <sha> stuck", ga-7polxu) as evidence anything is still wrong.
#
# Re-adding it here means the per-label loop below examines it again this
# cycle exactly like any other AFFECTED label: already_fresh() (fixed below
# to use a per-daemon commit floor instead of the wide window's tip) then
# decides the actual outcome — still genuinely stale -> re-confirmed
# GUARDED/FRESH_FAIL (stays visible, ACEITE 1), already restarted since the
# real last-touching commit -> ALREADY_FRESH (clears on THIS sweep, ACEITE
# 1's "dentro de 1 varredura"). Nothing here decides that itself; it only
# ensures the label is examined at all. A widened-back label is not present
# in AFFECTED_OWN (Step 3's own-file check never ran for it this cycle), so
# classify_guarded() below files it under GUARDED_CLOSURE_ONLY by default —
# a minor severity-display nuance, not a correctness gap this bead is
# scoped to fix.
for ga_n2jnsa_stuck_label in $(printf '%s\n' "$DAEMON_BASELINE_OVERRIDES" | awk '$3=="stuck"{print $1}'); do
  case " $AFFECTED " in
    *" $ga_n2jnsa_stuck_label "*) continue ;;  # already covered this cycle
  esac
  case " $FORCE_RESTART_LABELS " in
    *" $ga_n2jnsa_stuck_label "*) continue ;;  # unrelated static-override path already handles this one
  esac
  AFFECTED="$AFFECTED $ga_n2jnsa_stuck_label"
  log "ga-n2jnsa: $ga_n2jnsa_stuck_label widened back into AFFECTED — .perdaemon records it 'stuck' but the wide window ($PRE_DEPLOY_SHA..$POST_DEPLOY_SHA) no longer reaches its trigger commit; re-examining this cycle instead of letting it silently drop out."
done
AFFECTED="$(echo "$AFFECTED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"

# wa-flysp (header point 16): keep AFFECTED_OWN in lockstep with any
# per-daemon narrowing just above — a label downgraded OUT of AFFECTED (its
# own closure clean since its individually-tracked last-clean point) must
# never survive as "own file changed" either. A plain intersection against
# the now-final AFFECTED, correct whether or not the narrowing block above
# even ran (its own guard can skip it entirely when DAEMON_BASELINE_OVERRIDES/
# AFFECTED are empty — this is then a same-set no-op).
AFFECTED_OWN="$(for l in $AFFECTED_OWN; do case " $AFFECTED " in *" $l "*) echo "$l" ;; esac; done | tr '\n' ' ' | sed 's/ $//')"

if [ -z "${AFFECTED// /}" ]; then
  # ga-vmq1i: py/template files DID change but detection (a bounded entrypoint
  # + routes-hop scan — see the import-level/route-hop/template-level comments
  # above — ga-q617u added the routes hop, still not a full transitive
  # closure) tied them to no live daemon. That is NOT the same certainty as
  # "nothing daemon-relevant changed" (the earlier not_applicable emits) — it
  # may be a real non-issue, or it may be exactly the blind spot the
  # detection comments already flag.
  # Report not_verified so the caller never claims this was confirmed live.
  log "no running daemon is affected by the changed code — OK."
  emit OK "changed code touches no live daemon" not_verified
fi

# ── Step 4: restart (safe) / flag (sensitive) + verify freshness ──────────────
verify_fresh() {  # verify_fresh <label> -> 0 if a process started after DEPLOY_EPOCH
  local label="$1" waited=0 pid se
  while :; do
    pid="$(daemon_pid "$label")"
    if [ -n "$pid" ]; then
      se="$(pid_start_epoch "$pid" || echo 0)"
      if [ -n "$se" ] && [ "$se" -gt "$DEPLOY_EPOCH" ] 2>/dev/null; then
        log "verify $label: pid $pid started $se > deploy $DEPLOY_EPOCH — FRESH."
        return 0
      fi
    fi
    # bash sleep accepts fractional on macOS
    awk "BEGIN{exit !($waited < $VERIFY_TIMEOUT)}" || break
    sleep "$VERIFY_INTERVAL"
    waited="$(awk "BEGIN{print $waited + $VERIFY_INTERVAL}")"
  done
  log "verify $label: no process started after deploy within ${VERIFY_TIMEOUT}s — STALE."
  return 1
}

# already_fresh <label> (ga-j3j6s; refined ga-puq8z, tiered gate-fix-2) -> 0
# if the CURRENTLY-live process already started after the code was COMMITTED
# (COMMIT_EPOCH, computed above from POST_DEPLOY_SHA) — a ONE-SHOT snapshot
# check (no wait/retry loop, unlike verify_fresh()): we are not waiting for a
# restart WE are about to perform, we are asking whether one already happened
# via some other path. Deliberately COMMIT_EPOCH, not DEPLOY_EPOCH alone:
# DEPLOY_EPOCH is "now" from THIS check's own point of view, so a restart that
# already happened via another path is — by construction — always BEFORE it;
# requiring pid-start > DEPLOY_EPOCH made this check nearly impossible to
# satisfy and produced exactly the false positives ga-puq8z measured (see the
# COMMIT_EPOCH comment above).
# gate-fix-2 (gate_run=ga-9a45d, Reviewer-1 FAIL): a pid-start in
# (COMMIT_EPOCH, DEPLOY_EPOCH] is NOT the same evidentiary weight as one past
# DEPLOY_EPOCH. verify_fresh() confirms a restart THIS script itself just
# performed, so DEPLOY_EPOCH is a hard floor for it; already_fresh() infers a
# restart that happened somewhere else, and a launchd KeepAlive respawn of a
# crashed daemon can land in that gap while the checkout is still pre-commit
# code — a real correlation, not proof. So this sets the global AFR_TIER on a
# match: "verified" when pid-start is ALSO past DEPLOY_EPOCH (the identical
# bar verify_fresh() clears — a genuine positive confirmation), else
# "not_verified" (a commit-vs-check-time correlation only). Callers fold
# AFR_TIER into the emitted PROOF — see ALREADY_FRESH_PROOF above — never
# assume verified outright. See header point 7 for why a file-mtime
# comparison would be a different (and misleading) alternative.
already_fresh() {  # already_fresh <label> -> 0/1; sets AFR_TIER on a 0 return
  local label="$1" pid se floor_epoch
  pid="$(daemon_pid "$label")"
  [ -n "$pid" ] || return 1
  se="$(pid_start_epoch "$pid" || echo 0)"
  # ga-n2jnsa: prefer the per-daemon closure-touching commit's epoch over
  # COMMIT_EPOCH (the tip of whatever window this cycle happens to examine)
  # — see ga0fawwr_daemon_closure_epoch above for why this can only ever
  # ADD true-fresh detections, never mask a real one. Falls back to
  # COMMIT_EPOCH, unchanged from before this fix, whenever the per-daemon
  # epoch cannot be determined (no AFFECTED context, no resolvable range).
  floor_epoch="$(ga0fawwr_daemon_floor_epoch "$label" 2>/dev/null)"
  case "$floor_epoch" in ''|*[!0-9]*) floor_epoch="$COMMIT_EPOCH" ;; esac
  [ -n "$se" ] && [ "$se" -gt "$floor_epoch" ] 2>/dev/null || return 1
  if [ "$se" -gt "$DEPLOY_EPOCH" ] 2>/dev/null; then
    AFR_TIER="verified"
  else
    AFR_TIER="not_verified"
  fi
  return 0
}

# wa-flysp (header point 16): partitions a label just added to GUARDED into
# GUARDED_OWN (its own file/template is in the diff) or GUARDED_CLOSURE_ONLY
# (reached only via a transitively-changed import/route-hop/JSON-closure
# member) — using AFFECTED_OWN, computed once at Step 3 above. A tiny wrapper
# so the three call sites below (drain-guard-refused, no-drain-configured,
# safe-guard-refused) stay one line each instead of repeating the case match.
classify_guarded() {  # classify_guarded <label>
  case " $AFFECTED_OWN " in
    *" $1 "*) GUARDED_OWN="$GUARDED_OWN $1" ;;
    *) GUARDED_CLOSURE_ONLY="$GUARDED_CLOSURE_ONLY $1" ;;
  esac
  # (ga-abofl6, header point 20) a FOURTH, independent split — orthogonal to
  # the OWN/CLOSURE_ONLY partition above, same convention as GUARDED_SYMBOL_*
  # below: never a subdivision of either bucket, just an additional fact.
  case " $AFFECTED_RIG_DETECTOR " in
    *" $1 "*) GUARDED_RIG_DETECTOR="$GUARDED_RIG_DETECTOR $1" ;;
  esac
}

# ga-4oh2r6, replacing the ga-8q1ulq per-label symbol_reachability_for(): does
# <label>'s entrypoint call graph reach a symbol that changed in
# [$SYMREACH_BEFORE, $SYMREACH_AFTER]? Same closure resolution as before
# (json_covers_entry/json_closure_for_entry, or the ad-hoc CHANGED_PY
# fallback) — this function ONLY builds one JSON manifest entry now, it no
# longer invokes the calculator itself. The invocation moved to ONE call for
# the WHOLE GUARDED batch (see the loop below) because 17 separate `timeout
# N python3 compute_symbol_reachability.py ...` subprocesses, one per
# daemon, blew both the per-daemon and total budgets in production 18/09
# (story-delivery.log:120141-120158, 6 timeouts + 11 skipped = 17/17 NÃO
# CALCULADO) — closures in the real rig run 130-211 files each with ~86%
# overlap between daemons (2517 summed paths, 340 distinct), and each
# separate invocation re-fetched + re-parsed every file from scratch with no
# sharing across daemons. compute_symbol_reachability.py's own --batch mode
# (wa-zqyi4, companion bead, same "consult the rig, don't vendor a second
# copy" choice this function's docstring already established) now does that
# work ONCE per run with a shared cache, and this function's only job is to
# describe what the batch needs to know about <label>.
#
# Prints nothing and returns 1 when no entrypoint resolved (a
# FORCE_RESTART_LABELS entry, points 5/16: Step 2 never found a file to
# point the AST parser at) — the caller degrades that label straight to
# NÃO CALCULADO without adding it to the manifest at all, same tri-state
# honesty as before (unknown, never folded into "no evidence").
symbol_reachability_manifest_entry() {  # symbol_reachability_manifest_entry <label>
  local label="$1" entries entry e c closures=()
  entries="$(cat "$DISCO_DIR/$label" 2>/dev/null || true)"
  entry=""
  for e in $entries; do entry="$e"; break; done
  if [ -z "$entry" ]; then
    return 1
  fi

  for e in $entries; do
    [ "$e" = "$entry" ] && continue
    closures+=("$e")
  done
  if json_covers_entry "$entry"; then
    while IFS= read -r c; do
      [ -n "$c" ] && closures+=("$c")
    done < <(json_closure_for_entry "$entry")
  else
    # ad-hoc tier (header point 17): no deploy_deps.json closure for this
    # entrypoint. Coarser fallback — the full changed-.py set, not just what
    # this label actually imports — deliberately, rather than threading a
    # new per-label "which changed file triggered this" tracker through
    # Step 3's exactly-tuned ad-hoc branches (a fully independent, read-only
    # addition, same boundary point 16 already established for AFFECTED_OWN).
    while IFS= read -r c; do
      [ -n "$c" ] && closures+=("$c")
    done < <(printf '%s\n' "$CHANGED_PY")
  fi

  python3 -c '
import json, sys
label, entry = sys.argv[1], sys.argv[2]
closure = sys.argv[3:]
print(json.dumps({"label": label, "entrypoint": entry, "closure": closure}))
' "$label" "$entry" "${closures[@]}"
}

for label in $AFFECTED; do
  # Only refresh LONG-LIVED daemons that are running RIGHT NOW (have a live PID).
  # A discovered job with no current PID is a scheduled/one-shot agent (e.g. a
  # daily scraper) or an already-down daemon — kickstarting it would wrongly
  # TRIGGER the job, not "refresh" it, and there is no running stale process to
  # fix. This is precisely the bug's domain: a long-lived process already running
  # stale code. Skip the rest.
  if [ -z "$(daemon_pid "$label")" ]; then
    log "AFFECTED $label is not currently running (scheduled/one-shot or down) — not a dormant-running-daemon; skipping refresh."
    AFFECTED_NOT_RUNNING="$AFFECTED_NOT_RUNNING $label"
    continue
  fi
  if is_sensitive "$label" || policy_says_sensitive "$label"; then
    if already_fresh "$label"; then
      if [ "$AFR_TIER" = "verified" ]; then
        log "SENSITIVE $label: current process started after DEPLOY_EPOCH ($DEPLOY_EPOCH) via some other restart path — same bar verify_fresh() uses; positively confirmed fresh, not flagging for guarded restart (ga-j3j6s)."
      else
        log "SENSITIVE $label: current process started after this code was committed (COMMIT_EPOCH=$COMMIT_EPOCH) but not after DEPLOY_EPOCH ($DEPLOY_EPOCH) — plausibly already running the new code via some other restart path; not flagging for guarded restart, but this is a correlation, not proof (PROOF=not_verified — ga-j3j6s, confidence corrected gate-fix-2)."
        ALREADY_FRESH_PROOF="not_verified"
      fi
      ALREADY_FRESH="$ALREADY_FRESH $label"
      continue
    fi
    sani="${label//[^A-Za-z0-9_]/_}"
    drain_var="DRAIN_CMD_${sani}"
    drain="${!drain_var:-}"
    if [ -n "$drain" ]; then
      if ! guard_allows_restart "$label"; then
        log "SENSITIVE $label: guard refused — NOT draining/restarting; flagged for guarded restart."
        GUARDED="$GUARDED $label"
        classify_guarded "$label"
        continue
      fi
      log "SENSITIVE $label: draining via \$$drain_var then restarting (guarded path)."
      if [ "$DRY_RUN" != "1" ]; then
        eval "$drain" >&2 2>&1 || log "WARN: drain command for $label failed (rc=$?) — continuing to restart."
        $LAUNCHCTL_BIN kickstart -k "gui/$(id -u)/$label" 2>/dev/null \
          || $LAUNCHCTL_BIN kickstart "$label" 2>/dev/null \
          || log "WARN: kickstart failed for $label"
        RESTARTED="$RESTARTED $label"
        if ! verify_fresh "$label"; then
          FRESH_FAIL="$FRESH_FAIL $label"
        fi
      else
        WOULD_RESTART="$WOULD_RESTART $label"
      fi
    else
      log "SENSITIVE $label: NO drain path configured — NOT auto-bounced; flagged for guarded restart."
      GUARDED="$GUARDED $label"
      classify_guarded "$label"
    fi
    continue
  fi

  # SAFE (read-only dashboard etc.): consult any configured guard (ga-ylr2m),
  # then kickstart -k + verify freshness.
  if ! guard_allows_restart "$label"; then
    log "SAFE $label: guard refused — NOT auto-bounced; flagged for guarded restart."
    GUARDED="$GUARDED $label"
    classify_guarded "$label"
    continue
  fi
  log "SAFE $label: kickstart -k + verify fresh."
  if [ "$DRY_RUN" != "1" ]; then
    $LAUNCHCTL_BIN kickstart -k "gui/$(id -u)/$label" 2>/dev/null \
      || $LAUNCHCTL_BIN kickstart "$label" 2>/dev/null \
      || log "WARN: kickstart failed for $label (label wrong or not loaded?)"
    RESTARTED="$RESTARTED $label"
    if ! verify_fresh "$label"; then
      FRESH_FAIL="$FRESH_FAIL $label"
    fi
  else
    WOULD_RESTART="$WOULD_RESTART $label"
  fi
done

RESTARTED="$(echo "$RESTARTED" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
FRESH_FAIL="$(echo "$FRESH_FAIL" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
GUARDED="$(echo "$GUARDED" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
GUARDED_OWN="$(echo "$GUARDED_OWN" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
GUARDED_CLOSURE_ONLY="$(echo "$GUARDED_CLOSURE_ONLY" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
GUARDED_RIG_DETECTOR="$(echo "$GUARDED_RIG_DETECTOR" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
ALREADY_FRESH="$(echo "$ALREADY_FRESH" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
WOULD_RESTART="$(echo "$WOULD_RESTART" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"

# ── Step 5: verdict ───────────────────────────────────────────────────────────
if [ -n "${FRESH_FAIL// /}" ]; then
  emit VERIFY_FAILED "restarted daemon(s) did not come up fresh:${FRESH_FAIL}" not_verified
elif [ -n "${GUARDED// /}" ]; then
  # ga-puq8z ACEITE 2: affected-daemon detection above (Step 3) is a bounded
  # (entrypoint + routes-hop, ga-q617u) import/template-closure match, not a
  # proof that the daemon's live code path actually reaches the changed
  # symbols — say so here rather than asserting staleness outright, so a
  # human evaluating this hold knows a LISTED daemon can be a false positive
  # and checks pid-start vs. commit time before acting.
  # ga-q617u: the message used to stop there, warning only about the
  # false-positive half. It said nothing about the other direction — the
  # list itself can be INCOMPLETE, because this is still not a full
  # transitive closure (only entrypoint-direct + one routes/*.py hop). Real
  # incident: the one daemon that actually reached the changed symbol two
  # hops away was silently absent from a GUARDED list that named two
  # unrelated daemons instead, and the message gave no hint anything might
  # be missing — a reader had no reason to doubt the list was complete.
  #
  # ga-9lug2k: that false-negative half is no longer true for a rig where
  # deploy_deps.json covers every entrypoint this run considered — measured
  # live for whatsapp_automation (75/75, regenerated 2026-09-16) — and
  # repeating "verify by hand, may be incomplete" on a closure that already
  # IS complete just re-teaches a reader to distrust a list that has already
  # closed the gap it's warning about. Assert completeness only when
  # TOTAL_ENTRY_COUNT/JSON_COVERED_ENTRY_COUNT (Step 3's own per-entry tally,
  # never guessed) actually prove it for THIS run; fall back to the original
  # conservative wording the instant they don't (no deploy_deps.json,
  # unparseable JSON — WARN case above, or partial coverage). Even when
  # asserted, two risks stay real regardless of JSON coverage: the JSON
  # itself going stale (hence the regen date), and TEMPLATE/asset
  # reachability, a structurally separate mechanism this closure does not
  # track (header point 14) — "full closure" here means imports only.
  # wa-flysp (header point 16): rank GUARDED before either REASON branch
  # below — own-file-changed FIRST (the actionable half: the deployer should
  # have restarted these and didn't), closure-only SECOND (known noise, same
  # caveat as always). Renders a section even when the OTHER bucket is empty
  # — a GUARDED list that is 100% closure-only must still show a
  # CLOSURE-ONLY header, not silently vanish (mirrors the exact bug
  # whatsapp_automation's own daemon_refresh_advisory.py::render_advisory()
  # was fixed for, delivered wa-th4b1 — see its step5-ranking selftest).
  NGR_RANKED=""
  if [ -n "${GUARDED_OWN// /}" ]; then
    NGR_RANKED="${NGR_RANKED} || OWN-FILE-CHANGED ($(echo "$GUARDED_OWN" | wc -w | tr -d ' ')) -- its own entrypoint/template is in THIS diff, the deployer should have restarted these and didn't, restart THESE first:${GUARDED_OWN}"
  fi
  if [ -n "${GUARDED_CLOSURE_ONLY// /}" ]; then
    NGR_RANKED="${NGR_RANKED} || CLOSURE-ONLY ($(echo "$GUARDED_CLOSURE_ONLY" | wc -w | tr -d ' ')) -- only imports something that changed, its own code is untouched (known noise -- verify reachability by hand before restarting):${GUARDED_CLOSURE_ONLY}"
  fi
  # ga-8q1ulq (header point 17), batched by ga-4oh2r6: a THIRD, independent
  # ranking pass — symbol (not file) level — only when the rig has the
  # calculator, only up to the time budget below. Rendered AFTER the
  # point-16 sections above, never instead of them. Lazy on purpose: this
  # is the single most expensive thing this script does, so it only ever
  # runs on a batch that is actually about to render a NEEDS_GUARDED_RESTART
  # halt.
  #
  # ga-4oh2r6: ONE python3 invocation for the whole GUARDED batch, not one
  # per label. The prior per-label loop called compute_symbol_reachability.py
  # as a fresh subprocess per daemon, each re-fetching+re-parsing every file
  # in its own closure from scratch — measured blowing both the 5s-per-daemon
  # and 30s-total budgets on 17/17 daemons the same day this feature shipped
  # (story-delivery.log:120141-120158). The rig's --batch mode (wa-zqyi4)
  # shares one (ref,path) cache across every daemon in the run instead;
  # measured on the real repro window (979f89533..d5383b04b, 17 daemons):
  # ~3-5s total, down from timing out at 30s on roughly half of repeated
  # runs under this machine's real load. SYMBOL_REACHABILITY_TIMEOUT (the
  # old PER-DAEMON bound) no longer applies to anything — there is only one
  # process now, bounded by SYMBOL_REACHABILITY_TOTAL_TIMEOUT below.
  if [ -f "$SYMBOL_SCRIPT" ]; then
    SYMREACH_BEFORE="$PRE_DEPLOY_SHA"; SYMREACH_AFTER="$POST_DEPLOY_SHA"
    # Prefer this bead's own attribution range over the wider deploy window
    # when it's available and trustworthy — same ancestor-guard chain
    # ga-agracx already established (point 14) for the same reason: a
    # narrower, more relevant diff makes for a more precise answer.
    if [ -n "$BEAD_MERGE_PRE_SHA" ] && [ -n "$BEAD_MERGE_SHA" ] \
       && [ "$BEAD_MERGE_PRE_SHA" != "$BEAD_MERGE_SHA" ] \
       && git -C "$RUNTIME_DIR" rev-parse --verify -q "$BEAD_MERGE_PRE_SHA" >/dev/null 2>&1 \
       && git -C "$RUNTIME_DIR" rev-parse --verify -q "$BEAD_MERGE_SHA" >/dev/null 2>&1 \
       && git -C "$RUNTIME_DIR" merge-base --is-ancestor "$BEAD_MERGE_PRE_SHA" "$BEAD_MERGE_SHA" 2>/dev/null; then
      SYMREACH_BEFORE="$BEAD_MERGE_PRE_SHA"; SYMREACH_AFTER="$BEAD_MERGE_SHA"
    fi

    if [ "$SYMBOL_REACHABILITY_TOTAL_TIMEOUT" -le 0 ] 2>/dev/null; then
      # `timeout 0 cmd` is NOT "time out instantly" -- coreutils treats a
      # 0 duration as no bound at all (verified live: `timeout 0 sleep 5`
      # runs sleep to completion, exit 0). The old per-label loop's own
      # SECONDS-based budget check degraded every label without ever
      # invoking the calculator once TOTAL_TIMEOUT was 0 from the start;
      # this explicit pre-check preserves that exact behavior instead of
      # relying on `timeout`'s ambiguous zero-duration semantics.
      log "symbol-reachability: SYMBOL_REACHABILITY_TOTAL_TIMEOUT is $SYMBOL_REACHABILITY_TOTAL_TIMEOUT -- skipping the batch calculator entirely, all GUARDED labels NÃO CALCULADO."
      for label in $GUARDED; do
        GUARDED_SYMBOL_NOT_COMPUTED="$GUARDED_SYMBOL_NOT_COMPUTED $label"
      done
    else
      SR_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/daemon-refresh-symreach.XXXXXX.json")"
      {
        printf '{"entries": ['
        SR_FIRST=1
        for label in $GUARDED; do
          SR_LINE="$(symbol_reachability_manifest_entry "$label")" || {
            # No resolved entrypoint (FORCE_RESTART_LABELS, points 5/16) --
            # never in the manifest at all, straight to NÃO CALCULADO.
            GUARDED_SYMBOL_NOT_COMPUTED="$GUARDED_SYMBOL_NOT_COMPUTED $label"
            log "symbol-reachability $label: no resolved entrypoint — NÃO CALCULADO, ranking unaffected."
            continue
          }
          [ "$SR_FIRST" -eq 0 ] && printf ','
          printf '%s' "$SR_LINE"
          SR_FIRST=0
        done
        printf ']}'
      } > "$SR_MANIFEST"

      SR_OUT="$(timeout "$SYMBOL_REACHABILITY_TOTAL_TIMEOUT" python3 "$SYMBOL_SCRIPT" \
                  --batch "$SR_MANIFEST" --before "$SYMREACH_BEFORE" --after "$SYMREACH_AFTER" 2>/dev/null)"
      SR_RC=$?
      rm -f "$SR_MANIFEST"
      if [ "$SR_RC" -ne 0 ]; then
        log "symbol-reachability: batch invocation did not complete (exit $SR_RC, timeout=${SYMBOL_REACHABILITY_TOTAL_TIMEOUT}s) — any label with no JSONL line below is NÃO CALCULADO (partial output, if any, is still honored: compute_symbol_reachability.py flushes each entry as it completes, so a mid-batch kill only loses the entries that hadn't finished yet)."
      fi

      # ONE python3 pass classifies every label from the JSONL output --
      # never a per-label subprocess just to look up its own line. A label
      # absent from SR_OUT entirely (killed mid-batch, or never made it
      # into the manifest above) falls through every branch below and is
      # classified NOT_COMPUTED by the shell loop that follows, same
      # tri-state honesty as the old per-label timeout: an unanswered
      # question, never a negative answer.
      SR_CLASSIFY="$(printf '%s\n' "$SR_OUT" | python3 -c '
import json, re, sys
# ga-j3lh6p (header point 19): reaches=false is NOT always "analysed cleanly,
# found no path". The calculator also returns it for an unparseable or absent
# ENTRYPOINT (reaches=False por padrao seguro / nao da pra avaliar) and after
# DROPPING a closure file whose structural diff failed (a possible false
# negative). This is the ONE warning that leaves the answer trustworthy: a
# CLOSURE file absent at --after (added by a commit later than the range, or
# deleted) - nothing else about the analysis is affected. The separator before
# "ignorado" is an em dash in the calculator wording; it is matched as any single
# character so this Python stays pure ASCII (it runs under launchd with a
# minimal locale) and needs no escape.
BENIGN = re.compile(r"^.+: ausente em --after \([^)]*\) . ignorado$")
confirmed, no_evidence = [], []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    label = d.get("label")
    if not label:
        continue
    r = d.get("reaches")
    if r is True:
        confirmed.append(label)
    elif r is False:
        w = d.get("warnings")
        if isinstance(w, list) and all(isinstance(x, str) and BENIGN.match(x) for x in w):
            no_evidence.append(label)
        # else: reaches=false but the analysis was partial or could not run, or
        # this calculator predates the warnings field. NOT a negative answer:
        # appended to neither list, so the shell loop below files it under
        # NOT_COMPUTED (an unevaluated label is never no-evidence).
    # r is anything else (missing/null) -> not appended to either list;
    # the shell loop below defaults an unmatched label to NOT_COMPUTED.
print(" ".join(confirmed))
print(" ".join(no_evidence))
' 2>/dev/null)"
      SR_CONFIRMED_RAW=" $(printf '%s\n' "$SR_CLASSIFY" | sed -n '1p') "
      SR_NO_EVIDENCE_RAW=" $(printf '%s\n' "$SR_CLASSIFY" | sed -n '2p') "

      for label in $GUARDED; do
        case "$SR_CONFIRMED_RAW" in
          *" $label "*)
            GUARDED_SYMBOL_CONFIRMED="$GUARDED_SYMBOL_CONFIRMED $label"
            log "symbol-reachability $label: CONFIRMED."
            continue
            ;;
        esac
        case "$SR_NO_EVIDENCE_RAW" in
          *" $label "*)
            GUARDED_SYMBOL_NO_EVIDENCE="$GUARDED_SYMBOL_NO_EVIDENCE $label"
            continue
            ;;
        esac
        # Not in either list: either it was already routed to NOT_COMPUTED
        # above (no resolved entrypoint), in which case it's already there
        # and this is a harmless re-add (dedup'd by the sort -u below), or
        # its JSONL line never arrived (batch timeout/crash mid-run).
        GUARDED_SYMBOL_NOT_COMPUTED="$GUARDED_SYMBOL_NOT_COMPUTED $label"
      done
    fi
    GUARDED_SYMBOL_CONFIRMED="$(echo "$GUARDED_SYMBOL_CONFIRMED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    GUARDED_SYMBOL_NO_EVIDENCE="$(echo "$GUARDED_SYMBOL_NO_EVIDENCE" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    GUARDED_SYMBOL_NOT_COMPUTED="$(echo "$GUARDED_SYMBOL_NOT_COMPUTED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    # ga-j3lh6p (header point 19): the GUARDED subset that is BOTH locked against
    # automation (restart_policy.yaml notify_only_locked) AND cleanly classified
    # no-evidence. Only ever drawn FROM GUARDED_SYMBOL_NO_EVIDENCE, which is
    # itself a subset of GUARDED — so a label can never be named here that the
    # consumer was not already holding. Annotation only: VERDICT and GUARDED are
    # untouched.
    # ga-xrn8ni (header point 21): a SIBLING subset, same shape as
    # GUARDED_LOCKED_COSMETIC above but for a daemon that is SENSITIVE with no
    # $DRAIN_CMD_<label> configured — a durable configuration gap, not a
    # deliberate human lock, but equally unable to be auto-restarted, so a
    # merge that provably does not reach it is exonerated the same way.
    for label in $GUARDED_SYMBOL_NO_EVIDENCE; do
      if label_notify_only_locked "$label"; then
        GUARDED_LOCKED_COSMETIC="$GUARDED_LOCKED_COSMETIC $label"
      elif label_no_drain_configured "$label"; then
        GUARDED_NODRAIN_COSMETIC="$GUARDED_NODRAIN_COSMETIC $label"
      fi
    done
    GUARDED_LOCKED_COSMETIC="$(echo "$GUARDED_LOCKED_COSMETIC" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    GUARDED_NODRAIN_COSMETIC="$(echo "$GUARDED_NODRAIN_COSMETIC" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    if [ -n "${GUARDED_SYMBOL_CONFIRMED// /}" ]; then
      NGR_RANKED="${NGR_RANKED} || SYMBOL-CONFIRMED ($(echo "$GUARDED_SYMBOL_CONFIRMED" | wc -w | tr -d ' ')) -- entrypoint's call graph reaches a symbol that changed in this window (wa-th4b1), restart THESE first:${GUARDED_SYMBOL_CONFIRMED}"
    fi
    if [ -n "${GUARDED_SYMBOL_NO_EVIDENCE// /}" ]; then
      NGR_RANKED="${NGR_RANKED} || SEM EVIDÊNCIA DE SÍMBOLO ($(echo "$GUARDED_SYMBOL_NO_EVIDENCE" | wc -w | tr -d ' ')) -- imports what changed, no call-graph path found to a changed symbol (not a full transitive closure -- verify by hand):${GUARDED_SYMBOL_NO_EVIDENCE}"
    fi
    if [ -n "${GUARDED_SYMBOL_NOT_COMPUTED// /}" ]; then
      NGR_RANKED="${NGR_RANKED} || NÃO CALCULADO ($(echo "$GUARDED_SYMBOL_NOT_COMPUTED" | wc -w | tr -d ' ')) -- compute_symbol_reachability.py gave no usable answer for these (error/timeout/unparseable output, or a partial analysis its own warnings flag) -- absence of evidence is not evidence of absence, verify by hand:${GUARDED_SYMBOL_NOT_COMPUTED}"
    fi
    if [ -n "${GUARDED_LOCKED_COSMETIC// /}" ]; then
      NGR_RANKED="${NGR_RANKED} || TRAVA HUMANA SEM EVIDÊNCIA ($(echo "$GUARDED_LOCKED_COSMETIC" | wc -w | tr -d ' ')) -- notify_only_locked em restart_policy.yaml (nenhuma automação reinicia; só um humano, e reiniciar derruba o que o daemon hospeda) E nenhum caminho de chamada até símbolo alterado nesta janela: staleness cosmética que não se cura sozinha, então NÃO segura a entrega (ga-j3lh6p). É evidência, não prova -- mesma ressalva do split por símbolo acima (não é fechamento transitivo completo):${GUARDED_LOCKED_COSMETIC}"
    fi
    if [ -n "${GUARDED_NODRAIN_COSMETIC// /}" ]; then
      NGR_RANKED="${NGR_RANKED} || SEM DRAIN CONFIGURADO, SEM EVIDÊNCIA ($(echo "$GUARDED_NODRAIN_COSMETIC" | wc -w | tr -d ' ')) -- SENSITIVE sem \$DRAIN_CMD_<label> configurado (nenhuma automação sabe drenar e reiniciar; é lacuna de configuração, não trava humana deliberada -- muda assim que alguém configurar um drain) E nenhum caminho de chamada até símbolo alterado nesta janela: staleness cosmética que não se cura sozinha, então NÃO segura a entrega (ga-xrn8ni, extensão de ga-j3lh6p). É evidência, não prova -- mesma ressalva do split por símbolo acima (não é fechamento transitivo completo):${GUARDED_NODRAIN_COSMETIC}"
    fi
  fi
  if [ -f "$DEPLOY_DEPS_JSON" ] && [ "$TOTAL_ENTRY_COUNT" -gt 0 ] && [ "$JSON_COVERED_ENTRY_COUNT" -eq "$TOTAL_ENTRY_COUNT" ]; then
    NGR_REASON="sensitive hot-path daemon(s) need a guarded restart (import reachability for every entrypoint this run considered — ${TOTAL_ENTRY_COUNT}/${TOTAL_ENTRY_COUNT} — resolved via daemons/deploy_deps.json's real recursive closure, regenerated ${DEPLOY_DEPS_REGEN}: the bare-name/bounded-hop false-negative risk does NOT apply here. Two residual risks remain regardless: the JSON going stale since that regen date, and TEMPLATE/asset reachability, a structurally separate mechanism this closure does not track — verify those two, and still confirm a listed daemon isn't a false positive, before restarting):${GUARDED}${NGR_RANKED}"
  else
    NGR_REASON="sensitive hot-path daemon(s) need a guarded restart (import/template-closure match, not proven reachable to the changed symbols — a listed daemon may be a false positive; this is also NOT a full transitive closure — a daemon reached only through a deeper import chain can be missing from this list entirely, a false negative — verify by hand before treating this list as complete):${GUARDED}${NGR_RANKED}"
  fi
  emit NEEDS_GUARDED_RESTART "$NGR_REASON" not_verified
elif [ -n "${RESTARTED// /}" ]; then
  emit OK "all affected daemons restarted + verified fresh:${RESTARTED}" verified
elif [ -n "${WOULD_RESTART// /}" ]; then
  # ga-omfwe: DRY_RUN=1 skips both the kickstart and verify_fresh calls, so
  # this run confirmed nothing — RESTARTED must never be populated here (the
  # pre-fix bug: it was, and this branch was unreachable because RESTARTED
  # always won first). PROOF=not_applicable, matching the "nothing live to
  # refresh" branch below: verification wasn't attempted, not that it failed.
  emit OK "DRY RUN — no action taken; would restart daemon(s):${WOULD_RESTART}" not_applicable
elif [ -n "${ALREADY_FRESH// /}" ]; then
  # ga-j3j6s (confidence corrected gate-fix-2, gate_run=ga-9a45d): sensitive
  # daemon(s) whose live process started after COMMIT_EPOCH via some other
  # restart path (e.g. a sibling bead's own guarded restart, or the rig's own
  # auto-deploy). Still skip the guarded restart either way (reverting to
  # DEPLOY_EPOCH-only would just reintroduce the original over-flagging bug),
  # but ALREADY_FRESH_PROOF (set per-daemon by already_fresh()'s AFR_TIER, at
  # the call site above) tells us whether that pid-start ALSO cleared
  # DEPLOY_EPOCH — the identical bar verify_fresh() uses, a genuine positive
  # confirmation — or only COMMIT_EPOCH, a commit-vs-check-time correlation a
  # launchd KeepAlive respawn from an unrelated crash could satisfy while
  # still running pre-deploy code. A batch is only as trustworthy as its
  # weakest member, so one weak match downgrades the whole emitted PROOF.
  emit OK "sensitive daemon(s) already running post-deploy code via some other restart path, no restart needed:${ALREADY_FRESH}" "$ALREADY_FRESH_PROOF"
else
  # ga-vmq1i: AFFECTED was non-empty, but every affected daemon was skipped for
  # having no live PID (a scheduled/one-shot job, per the Step-4 loop above) —
  # RESTARTED is empty, so nothing was actually restarted or confirmed fresh.
  # The pre-fix code emitted this exact case as "...restarted + verified
  # fresh:" with a literally empty list, which is the concrete false-positive
  # ga-vmq1i reports. Nothing live exists to be stale, so not_applicable —
  # never "verified".
  emit OK "no affected daemon currently running — nothing live to refresh" not_applicable
fi
