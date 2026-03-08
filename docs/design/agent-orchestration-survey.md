# Agent Orchestration Frameworks: Survey and Comparison

_Written for Gas City architects. Grounded in operational data, not marketing copy._
_Date: 2026-03-07_

---

## 1. Purpose and Scope

This document surveys the major agent orchestration frameworks from the perspective
of a team that runs Gas Town in daily production. Gas Town is the baseline — we know
its actual failure modes, not the theoretical ones. The goal is to help Gas City
architects make informed choices when evaluating or integrating frameworks.

**Frameworks covered:**
- **Gas Town** — our system, the reference point
- **CrewAI** — role-based multi-agent orchestration
- **AutoGen → Microsoft Agent Framework** — conversational multi-agent, now merged
- **LangGraph** — graph-based stateful agent workflows
- **Temporal** — durable workflow execution engine
- **Prefect / Airflow** — task DAG orchestration (contrast case)

**Key comparison axes:**
1. Work dispatch model
2. State management
3. Failure recovery
4. Coordination patterns
5. Data plane
6. Real-world failure modes

---

## 2. Gas Town (Baseline)

Gas Town is a multi-agent workspace manager built for sustained, autonomous software
development across multiple projects ("rigs").

### Architecture

```
Town (~/.gt/)
├── Mayor          — global coordinator, cross-rig dispatch
├── Deacon         — daemon beacon, heartbeats, monitoring
├── Witness        — per-rig health monitor, zombie patrol
├── Refinery       — merge queue processor (Bors-style batch-then-bisect)
└── Polecats       — ephemeral workers with persistent identity
```

Polecats are git worktrees (not full clones), spawned from the canonical rig
`mayor/rig` clone. This makes spawn fast and avoids object storage duplication.

### Work Dispatch

Work reaches agents through a **hook** — a bead (issue) explicitly assigned to an
agent's slot. The hook is checked at session start. The assignment model is pull-based:
agents check their hook, not a shared queue. There is no global task broker.

The **Propulsion Principle (GUPP)**: if something is on your hook, you run it.
No confirmation, no waiting. This is the core behavioral contract.

Dispatch path:
```
Mayor creates/assigns bead → bd hook set <polecat-slot> <bead-id>
→ Polecat spawns → gt hook → reads bead → executes
```

Molecules (formula workflows) are attached to beads as structured checklists.
Polecats work through steps in order, closing each step bead as they complete it.

### State Management

State is stored in **Dolt** — a MySQL-compatible SQL server with git-style versioning.
Every rig has its own Dolt database. All agents in a rig share a single server
on port 3307 via the MySQL protocol.

The key property: all agents write directly to `main` with transaction discipline
(`BEGIN / DOLT_COMMIT / COMMIT` as a unit), eliminating branch proliferation while
preserving version history. Cross-agent visibility is immediate.

Agent state lives as beads (rows in a SQL table). Bead status (open, in_progress,
hooked, closed) is the primary state machine. Design notes and findings persist via
`bd update --notes / --design`.

### Failure Recovery

The **Witness** runs a patrol cycle on a short interval, scanning for:
- Zombie polecats (working status, no recent activity)
- Orphaned beads (steps left open after root closed)
- Agents that have crashed or gone idle

Recovery is nudge-based: Witness nudges stuck polecats to restart their session.
If a polecat's session dies, its worktree and branch survive in git. The next session
picks up from wherever the code was committed. State that was only in the LLM context
window is lost unless it was persisted to the bead.

The Refinery handles merge failures: if a batch of MRs fails CI, it binary-bisects
to isolate the bad MR and merges the good ones. Polecats are not involved in this.

### Coordination

Agents communicate via two channels:
- **Mail** (permanent beads): for handoffs, escalations, structured protocol messages
- **Nudge** (ephemeral): lightweight signal for routine agent-to-agent communication

Mail creates a Dolt commit. Nudge creates nothing. The rule: default to nudge.

### Real-World Failure Modes (Operational Data)

These are failures we have observed in production, not hypothetical:

**1. Patrol DoS (CLOSE_WAIT accumulation)**
`gt patrol report` fires parallel `bd list` queries across all open wisps simultaneously.
With many open wisps, this overwhelms Dolt → TCP connections accumulate in CLOSE_WAIT
state → CPU thrashes 180-300% → all `bd` operations timeout → Dolt crashes.
_Recovery: `gt dolt stop && gt dolt cleanup && gt dolt start`._

**2. Hook delivery fragility at spawn time**
Polecats that spawn without proper `GT_ROLE` / `NODE_OPTIONS` environment variables
die immediately. The hook is never read. The Witness marks them zombie after the
health check window. One bad environment variable in the parent tmux session silently
broke all polecat spawns for weeks before the fix.

**3. Orphan accumulation (slow-motion crisis)**
Each patrol cycle that uses `bd close <root-wisp> --force` closes the root but leaves
child step wisps open. Over many cycles, hundreds of orphaned step wisps accumulate.
These are permanent Dolt rows that are never GC'd, degrading query performance and
causing `bd mol current` to time out from dependency graph traversal.
_Fix: always iterate children and close them before closing the root._

**4. Lock contention (mol squash concurrency)**
When multiple patrol agents (Deacon, Witness, Refinery) all call `bd mol squash`
at cycle end simultaneously, they compete for an exclusive Dolt write lock. One
process wins; the others spin at 90-101% CPU indefinitely, blocking all `bd` ops.
_Fix: `gt mol squash --jitter <duration>` to desynchronize callers._

**5. GUPP failure modes (where propulsion breaks)**
If a polecat restarts and waits for human confirmation before working, Gas Town stalls.
The Witness assumes work is progressing (the polecat is alive) but nothing happens.
The entire throughput model depends on agents executing immediately on hook.
In practice: LLM behavior is the limiting factor. Any uncertainty in the context
injection (ambiguous role prompt, missing `gt prime` output) causes hesitation.

---

## 3. CrewAI

CrewAI is a Python framework for orchestrating role-playing, autonomous AI agents.
It was rebuilt from scratch as a standalone framework — not a LangChain wrapper.

### Architecture

Two complementary primitives:
- **Crews**: teams of agents with defined roles, tools, and task assignments
- **Flows**: structured, event-driven workflows that manage state and delegate to Crews

Agent roles: **Manager** (oversees and delegates), **Worker** (executes tasks),
**Researcher** (information gathering). Roles are defined declaratively.

Execution modes:
- Sequential: agents run in order
- Hierarchical: a manager agent dynamically assigns tasks to workers

### Work Dispatch

Task-to-agent assignment is driven by role definitions and task descriptions. The
manager agent (in hierarchical mode) interprets which worker is best suited for
a task at runtime. There is no external hook system — the LLM decides assignment.

This is the core tradeoff: flexibility vs. determinism. In Gas Town, who works on
what is explicitly set by the Mayor. In CrewAI, it emerges from LLM reasoning.

### State Management

CrewAI provides memory layers:
- Short-term memory (within a crew run)
- Long-term memory (SQLite, persists across runs)
- Entity memory (tracks facts about named entities)
- Contextual memory (assembled from the above)

For agent communication: structured message-passing protocols pass context, results,
and task status between agents.

### Failure Recovery

Task isolation per role means a failure in one agent doesn't corrupt other plans.
CrewAI retries or reassigns failed task segments. However, there is no persistent
event history — if the process crashes, work must be replayed from the last checkpoint.

### What Gas Town Has That CrewAI Lacks

- **Persistent agent identity**: polecats are named workers with a track record.
  CrewAI agents are instantiated fresh per run. There is no "furiosa has closed 40 beads."
- **External work queue**: Gas Town has the Witness watching for zombie agents.
  CrewAI has no external health monitor — if your process hangs, no one nudges it.
- **Version-controlled data plane**: Dolt gives Gas Town audit history and rollback.
  CrewAI's SQLite is opaque.
- **Git integration**: polecats commit code, create MRs, get merged. CrewAI knows
  nothing about git.

### What CrewAI Does Better

- **Faster to start**: a working crew is a Python file with decorators.
- **Tool ecosystem**: 100+ pre-built integrations.
- **No infrastructure**: no Dolt server, no tmux, no daemon.
- **LLM-agnostic**: works with any API-compatible LLM.

---

## 4. AutoGen → Microsoft Agent Framework

AutoGen started as Microsoft Research's conversational multi-agent framework. In late 2025
it was consolidated with Semantic Kernel into the **Microsoft Agent Framework**, with
AutoGen entering maintenance mode (bug fixes only). See [Microsoft's announcement](https://microsoft.github.io/autogen/) for current status.

### AutoGen v0.4 Architecture (Pre-merger)

Three-layer design:
1. **Core API**: async message passing, event-driven agents, local and distributed runtime
2. **AgentChat API**: higher-level API for common multi-agent patterns (two-agent chat,
   group chats, round-robin conversations)
3. **Extensions API**: LLM client integrations (OpenAI, Azure OpenAI), code execution

Primary dispatch model: **conversation**. Agents take turns responding to each other
in structured dialogues. Work arrives as a message in the conversation, not as a
bead on a hook.

### Microsoft Agent Framework (Post-merger)

The successor unifies AutoGen's conversational model with Semantic Kernel's plugin/memory
architecture. It supports multi-language (.NET + Python). New features are landing here,
not in AutoGen.

Key differentiator: **cross-language support**. If your team writes Python and .NET,
this matters. Gas Town is Go + Claude CLI — cross-language is not a concern.

### State Management

Asynchronous message passing is the primary state vector. The event history of a
conversation is the state. There is no equivalent to Dolt — state is in-process,
in the message history.

AutoGen has OpenTelemetry integration for observability, which is ahead of Gas Town's
current observability story (we rely on tmux, Dolt queries, and Witness patrol).

### What AutoGen Does Better

- **Conversational patterns**: two-agent debate, critic-revise loops, code execution
  with human feedback — these are first-class patterns.
- **Observability**: OTel support out of the box.
- **Human-in-the-loop**: native support for pausing, injecting human feedback mid-run.

### What Gas Town Does Better

- **Persistent workers**: AutoGen agents are session-scoped. There is no persistent
  "furiosa" across conversation runs.
- **External work tracking**: no equivalent to beads. Work progress lives in conversation
  history, which is not independently queryable.
- **Merge queue**: AutoGen has no concept of CI gates or code review integration.

---

## 5. LangGraph

LangGraph is LangChain's framework for building stateful, multi-actor workflows using
a directed graph model.

### Architecture

Workflows are **graphs** where:
- **Nodes** execute specific actions (call LLM, run tool, transform data)
- **Edges** define control flow (conditional branching, loops, parallel fan-out)
- **State** is a typed dictionary (TypedDict or Pydantic model) that flows through nodes

This is fundamentally different from Gas Town's model. In LangGraph, the workflow is
the computation. In Gas Town, the workflow is the work *assignment* — the computation
happens in a Claude session.

### Work Dispatch

Work is defined as the initial state passed into the graph. There is no external
task broker. The graph itself defines what runs and in what order.

Multi-agent patterns:
- **Supervisor**: one agent routes to specialized sub-agents
- **Swarm**: agents hand off to each other without central control (LangGraph Swarm, 2025)
- **Parallel fan-out**: multiple agents run simultaneously on independent subgraphs

### State Management

State is LangGraph's standout feature. It is:
- **Shared** across all nodes in the graph
- **Typed** — you define the schema upfront
- **Checkpointed** — persisted to a backend (SQLite, PostgreSQL, Redis) between steps
- **Resumable** — a crashed workflow can restart from the last checkpoint

Three durability modes: async (fastest, less durable), sync (persists before proceeding),
and full (writes to two backends). This is more flexible than Gas Town's single-mode
Dolt writes.

Human-in-the-loop is native: the graph can pause at any node, wait for human input,
and resume with full context preserved.

### Failure Recovery

Built-in checkpointing means interrupted workflows resume from the last checkpoint.
The graph structure itself provides isolation — a failed node doesn't corrupt sibling
branches.

Production reality from one engineering team: they initially combined LangGraph with
Redis for persistence and found it "incredibly brittle in practice." They migrated to
Temporal for the infrastructure layer and kept LangGraph for the agent logic.

### What LangGraph Does Better

- **Explicit control flow**: the graph is inspectable, visualizable, and testable.
  In Gas Town, the polecat's behavior is determined by LLM context — it's a black box.
- **Checkpointing granularity**: checkpoint per node step. Gas Town's granularity is
  per git commit — coarser.
- **Conditional logic**: graph edges can route based on agent output. Very clean for
  "if the researcher finds X, go to path A; else path B."
- **Human-in-the-loop**: first class. Gas Town supports this but only via Witness
  escalation — an LLM-to-human handoff is not a structured protocol.

### What Gas Town Does Better

- **Multi-session persistence**: a polecat can work across multiple Claude sessions
  over hours/days. LangGraph's durability is within a workflow run.
- **Git integration**: polecats produce commits, branches, MRs. LangGraph produces
  graph outputs.
- **Named workers with history**: beads track who did what across time.
- **Infrastructure independence**: Gas Town's agents are just Claude CLI processes.
  LangGraph requires the LangChain ecosystem.

---

## 6. Temporal

Temporal is a durable workflow execution engine — not an agent framework per se, but
the infrastructure layer that several teams put *under* agent frameworks.

### Architecture

```
Frontend Service  — entry point for clients
History Service   — manages workflow state and event history
Matching Service  — matches tasks to available workers
Worker Service    — executes workflow activities
Persistence       — backend (Cassandra, MySQL, PostgreSQL)
```

### Core Concept: Durable Execution

A Temporal Workflow is code (Go, Java, Python, TypeScript, Ruby, .NET) that is
**guaranteed to complete** regardless of infrastructure failures. How:

1. All workflow events are written to an append-only history log
2. On worker failure, Temporal replays the history log to restore execution state
3. Activities (external calls) are retried with configurable policies

No custom retry logic. No checkpoint code. The framework handles it transparently.

This is the most mature failure recovery model in this survey. Temporal was built
to run billing workflows, payment processing, and subscription management at scale —
it has a zero-data-loss guarantee that no LLM framework even tries to match.

### Work Dispatch

Work arrives as **workflow starts** triggered by clients. Workers poll Temporal's task
queue for workflow and activity tasks. This is similar to Gas Town's hook model but
battle-hardened: the matching service handles load balancing, backpressure, and
worker health without external orchestration.

### State Management

State lives in the **event history**: every input, output, and side effect is recorded.
Replay reconstructs state deterministically. Workers are stateless — all state is in
Temporal's persistence layer.

Key constraint: workflows must be **deterministic**. LLM calls are non-deterministic
by nature. Teams handle this by wrapping LLM calls in Activities (which are retryable
units, not required to be deterministic) rather than embedding them in Workflow code.

### What Temporal Does Better

- **Zero-data-loss durability**: event history + replay is fundamentally more robust
  than Gas Town's commit-and-hope model.
- **Multi-language**: one Temporal cluster serves Go, Python, Java, .NET workers.
- **Battle-tested at scale**: Temporal runs in production at Stripe, Netflix, Airbnb,
  DoorDash. The scale story is proven.
- **Nexus (2025)**: durable cross-cluster RPC, enabling federated workflow graphs.
  Relevant for Gas City's multi-rig future.

### What Gas Town Does Better

- **LLM-native**: Temporal has no concept of a Claude session, context window, or
  LLM conversation. You must engineer that yourself.
- **Integrated data plane**: Dolt is not just persistence — it's queryable state with
  git history. You can `SELECT * FROM issues WHERE status='hooked'` and get a versioned
  answer. Temporal's persistence is opaque to application code.
- **Agent identity**: polecats have names, histories, capability ledgers. Temporal
  workers are interchangeable.
- **Developer ergonomics**: Gas Town's workflow is Claude + shell commands. Temporal
  requires SDK integration, server deployment, and workflow determinism constraints.

### Temporal + Gas Town

The natural integration point is using Temporal *under* the Agent Framework for
orchestrating long-running agentic pipelines that need durable guarantees, while
Gas Town handles the agent identity, work tracking, and git integration layers.
One real-world team combined LangGraph (agent logic) + Temporal (durability) for exactly
this reason.

---

## 7. Prefect / Airflow (Contrast Case)

These are **task DAG orchestrators**, not agent frameworks. They are included because
teams sometimes reach for them when "orchestration" is mentioned.

### Airflow

- Static DAGs defined at parse time (not runtime)
- Python operators for task execution
- Proven at scale for time-based batch workflows
- Bad fit for agent loops: DAGs cannot branch based on LLM output at runtime
- No native retry-aware LLM integration
- High operational overhead (scheduler, webserver, database, workers)

### Prefect

- Dynamic task creation at runtime (better than Airflow for ML)
- Flow and task decorators on standard Python functions
- Better observability than Airflow (built-in event management)
- Still task-oriented, not agent-oriented: no concept of a persistent agent identity
- Good for: ML pipelines (ingest → train → evaluate → deploy → monitor)
- Bad fit for: agent loops, multi-agent coordination, conversational patterns

### When to Reach for These

Use Airflow/Prefect when your work is **data pipelines with defined inputs and outputs**,
not when your work is **autonomous agents with decision-making**. The gap is real:
orchestrating a model training run is a DAG problem. Orchestrating a software engineer
that decides what to work on is an agent problem.

---

## 8. Comparison Matrix

| Axis | Gas Town | CrewAI | AutoGen/MAF | LangGraph | Temporal | Prefect/Airflow |
|------|----------|--------|-------------|-----------|----------|-----------------|
| **Work dispatch** | Hook (explicit assignment) | LLM-driven role match | Conversation message | Graph initial state | Task queue (client-triggered) | Scheduler / trigger |
| **State management** | Dolt SQL (git-versioned) | SQLite memory layers | In-process message history | Typed dict + checkpointing | Event history (append-only) | Task result backend |
| **Failure recovery** | Witness patrol + git | Task isolation + retry | Conversation replay | Checkpoint resume | Deterministic replay (zero-loss) | Task retry |
| **Coordination** | Mail + nudge (async) | Structured message-passing | Conversation turns | Graph edges | Activity calls | DAG edges |
| **Data plane** | Dolt (MySQL + git) | SQLite | None (in-process) | PostgreSQL/SQLite/Redis | Cassandra/MySQL/PostgreSQL | PostgreSQL / MySQL |
| **Agent identity** | Persistent named workers | Session-scoped roles | Session-scoped agents | None (graph is the identity) | Interchangeable workers | None |
| **Git integration** | Native (polecats commit code) | None | Code execution (not git) | None | None | None |
| **LLM-native** | Yes (Claude CLI) | Yes (multi-provider) | Yes (multi-provider) | Yes (LangChain) | No (you build it) | No |
| **Multi-language** | No (Go + Claude) | No (Python) | Yes (.NET + Python) | No (Python) | Yes (6+ languages) | No (Python) |
| **Scale story** | Single-host (alpha) | Small-medium | Medium | Medium-large | Very large (Stripe, Netflix) | Large (batch) |
| **Observability** | Dolt queries + Witness | Limited | OpenTelemetry | LangSmith | OpenTelemetry | Prefect UI / Airflow UI |
| **Operational complexity** | High (Dolt server, tmux, daemon) | Low | Medium | Medium | High (distributed services) | High (Airflow) / Medium (Prefect) |

---

## 9. Failure Mode Taxonomy

Cross-cutting failure modes observed across frameworks:

### 9.1 State Drift (Universal)

Agent reads stale state, makes decision based on outdated data, creates conflict.
- **Gas Town**: Dolt transactions + `main`-only writes mitigate this. Still happens
  when Witness and Refinery race on the same bead.
- **LangGraph**: checkpointing solves within-run drift. Cross-run drift (between
  separate workflow executions) requires application-layer logic.
- **CrewAI**: shared memory helps; no distributed locking means concurrent writes
  to the same entity can corrupt state.
- **Temporal**: activities are the boundary. State inside an activity is the app's
  problem. State between activities is Temporal's guarantee.

### 9.2 Compounding Unreliability

A 10-step agentic process with 99% per-step reliability has only ~90.4% end-to-end
reliability. At 20 steps: ~81.8%. This is the reliability tax of sequential agent chains.

Gas Town's response: polecats close molecule steps as they go. If a session dies after
step 3, the next session resumes from step 4. The formula is the checkpoint.
But this only works if the polecat persisted findings to the bead before the session died.

LangGraph's response: graph checkpointing at each node boundary. More granular.
Temporal's response: event history replay. The most robust.
CrewAI's response: task isolation per role. Coarser than LangGraph.

### 9.3 Slow-Motion Orphan Accumulation

Gas Town has direct operational experience with this. Long-running systems accumulate
orphaned work units that are never GC'd. Over time, query performance degrades and
patrol mechanisms get confused about system state.

No framework we surveyed has a built-in GC for orphaned work. This is a universal
operational problem that appears at different layers:
- Gas Town: orphaned wisps in Dolt
- LangGraph: checkpoints in PostgreSQL that are never cleaned
- Temporal: workflow histories that are never archived
- Airflow: task instance records accumulating in the metadata database

### 9.4 "Waiting for Confirmation" Anti-Pattern

Any agent framework that allows agents to pause and wait for human input (HITL) risks
idle stall if the human doesn't respond. Gas Town handles this via `gt escalate` and
Witness patrol. LangGraph's interrupt mechanism leaves the workflow suspended until
the application layer resumes it. AutoGen's conversation model assumes an always-on
human partner.

For fully autonomous workflows, HITL is a footgun. Design for it explicitly.

### 9.5 LLM Non-Determinism in Deterministic Systems

Temporal requires deterministic workflow code. LLM calls are fundamentally non-deterministic.
The solution is to wrap LLM calls in Activities (retryable, not required to be deterministic).
But this means LLM call results are re-fetched on replay, not replayed from history —
which changes the semantics. A workflow that "succeeded" might fail on replay because
the LLM now gives a different answer.

Gas Town sidesteps this by not replaying: polecats commit code to git as evidence of
work, and the work is not replayed — it's reviewed by Refinery. This is a different
correctness model: verify the output, not replay the execution.

---

## 10. Recommendations for Gas City Architects

### Choosing a Framework: Decision Tree

```
Is your work primarily data pipeline (ingest, transform, train, deploy)?
→ YES: Prefect (modern) or Airflow (proven). Stop here.

Is your work LLM-native (agents that reason, decide, and act)?
→ YES: Continue.

Do you need durability guarantees (zero data loss, process crash survival)?
→ YES: Consider Temporal as infrastructure layer. Layer LangGraph or CrewAI on top.

Do you need stateful multi-agent loops with explicit control flow?
→ YES: LangGraph. Steeper learning curve, most production-ready for complex graphs.

Do you need fast prototyping with role-based teams?
→ YES: CrewAI. Fastest to working demo. Weakest durability story.

Do you need persistent agent identity, git integration, and work tracking?
→ YES: Gas Town (or build Gas Town's data plane separately: Dolt + a hook system).

Do you need multi-language support and enterprise scale?
→ YES: Microsoft Agent Framework (formerly AutoGen + Semantic Kernel).
```

### Gas City Specific Guidance

Gas City is likely to need a **layered architecture**:

**Layer 1 — Durability**: Temporal (or equivalent) for workflow execution guarantees.
**Layer 2 — Agent Logic**: LangGraph or CrewAI for the agent reasoning and tool use.
**Layer 3 — Work Tracking**: a beads-style SQL store (Dolt or equivalent) for
persistent agent identity, work history, and audit trail.
**Layer 4 — Code Integration**: git-native workflow, not just API calls.

Gas Town currently conflates layers 1-4 into a single system optimized for a single-host
deployment. As Gas City scales, these layers will need to be separated and independently
scaled.

### What Gas Town Got Right (Worth Preserving)

1. **Named persistent workers**: capability ledger, reputation, handoffs. No other
   framework does this natively.
2. **Data-plane with history**: Dolt's git-versioned SQL is uniquely powerful for
   audit, debugging, and federation. Don't give this up.
3. **Explicit work dispatch**: hook-based assignment is more predictable than LLM-driven
   role matching. Keep it.
4. **External health monitoring**: Witness patrol catches failures that the agent itself
   cannot report. Autonomous systems need an outside observer.
5. **Self-managed completion**: polecats own their lifecycle. The Witness observes but
   doesn't gate. This prevents the monitor from becoming a bottleneck.

### What Gas Town Should Borrow

1. **Checkpointing granularity** (from LangGraph): per-step checkpoints are more
   granular than per-commit. Consider persisting to Dolt at each molecule step
   boundary, not just on explicit `bd update --notes`.
2. **OpenTelemetry** (from AutoGen/Temporal): structured distributed tracing would
   replace the current "grep tmux logs" debugging model.
3. **Determinism constraints** (from Temporal): the GUPP principle is close to
   Temporal's determinism requirement — an agent on a hook must execute the same
   way every time. Formalizing this (e.g., "no LLM-decided deviations from the
   molecule checklist") would improve reliability.
4. **Durable RPC / Nexus** (from Temporal): cross-rig workflow calls that survive
   network partitions. Critical for the federated Gas City vision.

---

## 11. Summary

Gas Town is a purpose-built system for a specific problem: autonomous software
engineering teams that work across multiple projects, need git integration, and must
maintain persistent agent identity and work history. No general-purpose framework
covers this use case natively.

The mainstream frameworks (CrewAI, LangGraph, AutoGen) optimize for fast LLM agent
prototyping and are making steady progress on production durability. Temporal is the
infrastructure layer for teams that need zero-data-loss guarantees. Prefect/Airflow
are not agent frameworks — they are pipeline orchestrators that happen to be confused
with agent frameworks.

The honest failure mode from our operational experience: **the biggest failures in Gas
Town are not framework failures — they are behavioral failures**. Agents that don't run
their hook. Patrol loops that DoS the database. Orphans that accumulate because closure
code was written wrong. The framework is solid; the emergent behavior of many concurrent
agents on shared infrastructure is where things break.

Any framework a Gas City architect chooses will face the same emergent behavior problems.
The frameworks surveyed here mostly don't have answers for them — they're still being
discovered in production. Gas Town's operational logs are, in a sense, a gift: we know
what goes wrong before Gas City architects have to find out the hard way.

---

_Written by polecat furiosa (gastown) for Wasteland wanted item w-gc-004._
_Source material: Gas Town MEMORY.md operational logs, framework documentation, 2025-2026 production reports._
