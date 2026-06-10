# Tau (current attempt) — research analysis for clean-slate architecture

**Status:** Research input, not a design to preserve. The current repo at
`/home/brentw/src/tau` is a prior, under-architected attempt at the same
goal: a fully autonomous agentic coding software factory. This document
mines it for hard-won constraints, encoded knowledge, and documented
failure modes — as *inspiration* for the new spec.

**Sources read:** `.claude/rules/{factory-loop,worktree-discipline,spec-before-code,otp-non-negotiables,hooks-and-scripts}.md`,
`docs/{MISSION,PROJECT}.md`, `CLAUDE.md`, `TAU.md`, `docs/spec/SPEC-*.md`
(structure only), `lib/tau/` inventory (one level deep, no implementation
deep-reads).

---

## 1. Stated mission and operating model

### Mission (two layers)

- **Product mission** (`docs/MISSION.md`): a working TUI binary
  (`burrito_out/tau_linux_<arch>`) that renders in a real terminal,
  completes a single user→assistant turn against a real provider, and
  quits cleanly. This is the prerequisite for **self-hosting** — Tau
  replacing the vendored claude-harness as the dev tool for Tau itself.
- **Factory mission** (`.claude/rules/factory-loop.md` + auto-memory):
  the factory loop's *sole* objective is to drive an **assigned
  milestone** to zero open issues, autonomously, with no per-step human
  checkpoints. Per user auto-memory, every factory step must advance **M1
  self-hosting**; M2..M8 are not pursued for their own sake.

The deep target is **recursive self-improvement**: an autonomous factory
that builds the agentic coding harness that *is* the factory.

### Coordinator / subagent model (current)

A single **coordinator** (a prompt-driven Claude Code session) receives
tasks, maintains a solution tree, spawns subagents, gates PRs, merges. It
"does not implement — subagents do." Roles (`CLAUDE.md`):

| Role | When | Isolation |
|---|---|---|
| `Plan` | Multi-step; touches a behaviour or supervision tree | — |
| `Explore` | Read-only multi-file queries | — |
| `general-purpose` | Research+edits outside `lib/tau/` | `worktree` |
| `critic` | Pre-impl review of coordination-heavy designs | — |
| `test-author` | Writes failing gating tests (oracle separation) | `worktree` |
| `implementer` | All Tau code changes (model: sonnet) | `worktree` |
| `reviewer` | Post-impl verification | — |

Skill index (on-demand knowledge modules): `heuristic-analysis` (classify
kill reasons), `retry-strategy` (refine vs pivot), `design-reasoning`
(PSDH method + L0 elicitation + 5-property triage), `code-review-patterns`,
`tau-architecture`, `tau-github-workflow`, `tau-adr`, `tau-toolchain`.

---

## 2. Encoded constraints worth preserving

Each tagged `[REQ-n]` (candidate requirement) or `[INV-n]` (candidate
invariant) for the new design.

### 2.1 The factory cycle (from `factory-loop.md`)

The atomic unit is **one PR**. One factory step opens, drives, and merges
exactly one PR. The cycle:

1. **Select work** — next open issue (or coherent issue set) from the
   assigned milestone; prefer smallest shippable increment, work that
   unblocks others; file a prerequisite issue if missing.
2. **Confirm issues** — open and correctly milestoned.
3. **Branch off fresh `main`** — `git fetch`, verify parent on `main` at
   `origin/main`, branch from that.
4. **Open the draft PR *before* any implementer** — empty seed commit,
   push, `gh pr create --draft`, body = full work plan. The draft PR is
   the durable plan-of-record and the single source of the implementer
   brief (no brief/PR drift).
4b. **Spawn the test-author** (oracle separation) — writes one failing
    test per `AC-N`/`D-NNN` exercising the *user-facing* path, reports the
    exact `test/...` paths it owns. Those paths become the frozen
    test/production boundary all later gates key on.
5. **Spawn implementer team** — one or more, each `isolation: worktree`,
   each briefed from the draft-PR body.
6. **Run the FULL gate** — both `critic` and `reviewer` on the actual
   diff. Mandatory, complete, never partial/deferred/overridden.
7. **Outcome** — green (both PASS) → merge path; red → refine/pivot/escalate.
8. **On green** — freshness re-check (re-fetch `origin/main`; if advanced,
   rebase + re-gate), mark ready, merge, sync local `main`, run post-merge
   `main` health check (`mix compile --warnings-as-errors` + `mix test`).
9. **Next PR** — no human pause between steps.

- `[REQ-1]` The factory's atomic unit MUST be a single PR with a frozen,
  declared scope (issue set fixed before any implementer runs).
- `[REQ-2]` Plan-of-record and implementer brief MUST be a single source
  (eliminate brief/PR drift). In the new design this is a candidate for a
  durable **process-per-PR** holding the plan as state.
- `[INV-1]` Branch is always derived from fresh `origin/main`; never from
  stale state.
- `[INV-2]` Merge only a gate-green diff that is *current* with
  `origin/main` (freshness re-check before every merge — stale-diff merge
  forbidden).
- `[INV-3]` Every merge is followed *in the same step* by a local-`main`
  sync and a post-merge `main` health check; a red `main` halts the loop.

### 2.2 The gate model — two judgement halves + three mechanical gates

**Judgement gates** (both MUST PASS on the same final diff):

- **`critic`** — pre/at-impl review: scope creep, coordination hazards,
  spec linkage, masking-deletion adjudication, under-asserting/wrong-path
  test judgement.
- **`reviewer`** — post-impl verification: AC/D-NNN naming, spec
  amendments present, new test covers the criterion.

**Three mechanical gates** (CI-enforced, `Tau.Factory.Gate` + `mix
tau.gate.*`):

- **Gate 5.1 — AC-to-test linkage.** Every `AC-N`/`D-NNN` token in the
  draft-PR body's `## Acceptance criteria` section MUST appear in a
  gating-test name or `@tag`. Scoped to that section only. Meta-ACs (`AC-N
  (meta)`) exempt (CI-wiring-verified). Blocking.
- **Gate 5.2 — Masking detection (detection-only).** Diff scanned for
  deleted/weakened assertions (`- assert`/`- refute`, or any implementer
  edit to a declared gating-test path). No self-bypass tag; every flagged
  deletion is a mandatory `critic` review item. Path-based, never hard-fails.
- **Gate 5.3 — Mutation check (path-based).** Keep declared gating-test
  paths at the test-author's state, revert everything else to
  `git merge-base origin/main HEAD`, run the gating tests, assert ≥1
  fails. Proves the tests actually bind to the implementation (closes the
  *vacuous-test* hole). Path-based so it survives refine-cycle rebases.

- `[REQ-3]` The gate is two judgement oracles + three mechanical checks;
  it MUST be mandatory, complete, and run on the *final* diff. No skip, no
  override, no partial, no promote-later, no stale-diff merge.
- `[REQ-4]` Mechanical gates MUST be **path-based, not commit-attribution-
  based** — survives rebases; the test/production boundary is the declared
  gating-test path set.
- `[INV-4]` The mutation check is the structural guarantee that a passing
  test is non-vacuous. Residual holes (under-asserting, wrong-path tests)
  are explicitly *not* mechanically closed — they rest on critic judgement.

### 2.3 Oracle / test-author separation

Tests are authored by a *separate* `test-author` agent before the
implementer runs, against the user-facing path. The implementer may not
edit a declared gating-test path. This is the structural core that makes
the mutation check meaningful: the oracle (test) and the subject
(implementation) are written by different agents.

- `[REQ-5]` The party that writes the acceptance oracle MUST be distinct
  from the party that writes the implementation. The boundary is a frozen
  path set, declared before implementation.
- `[INV-5]` An implementer editing a gating-test path is a protocol
  violation even with no deletion (caught by gate 5.2).

### 2.4 The challenge protocol

An implementer may **challenge** a gating test *only* if it contradicts a
SPEC §4 contract (not merely because it is hard). Protocol: implementer
STOPS, reports the test + the §4 clause + the contradiction (must NOT edit
the test); coordinator forwards to `critic` (independent oracle, not the
coordinator's own judgement); critic rules **upheld** or **rejected**; if
upheld the test-author corrects and the mutation check re-runs. Every
challenge is logged. **>2 upheld challenges on one PR** is a safety-circuit
escalation (weak test-author or underspecified SPEC).

- `[REQ-6]` There MUST be a formal dispute path between the implementation
  party and the oracle party, adjudicated by an *independent* third party
  against the written contract — never by the coordinator's own taste.
- `[INV-6]` >2 upheld challenges on one PR ⇒ escalate (the oracle or the
  SPEC is broken, not the implementer).

### 2.5 Parallel-execution conflict check (5 clauses)

Two+ issues may run concurrently only if ALL hold:

1. **No dependency** — neither blocked by the other.
2. **Disjoint files** — expected changed-file sets (incl. declared
   gating-test paths) do not overlap.
3. **Disjoint codepoints** — do not modify the same function (`file:line`
   from elaborations; when in doubt, serialize).
4. **No shared SPEC or D-NNN block** — not both authoring/amending the
   same SPEC nor drawing invariants from the same D-NNN block.
5. **Shared-resource isolation possible** — any non-worktree resource both
   touch is isolatable; else serialize.

Concurrency applies to **implementation only**: gates run per-PR on a
stable diff; **merges are serialized**; post-merge health check runs
serially.

- `[REQ-7]` Parallelism is the default and SHOULD be maximised, but gated
  by an explicit, mechanical conflict check across files, codepoints,
  dependencies, shared specs, and shared resources.
- `[INV-7]` Merges are *always* serialized regardless of implementation
  concurrency; each merge forces a freshness re-check on every other
  in-flight branch.

### 2.6 N=3 refine → pivot → escalate

- **Red** → load `retry-strategy`, **refine**: address named findings,
  stay on the same draft PR, re-run FULL gate. Bounded to **N=3**.
- **After N=3** → **pivot**: close the draft PR, materially different
  approach, fresh draft PR, reset attempt count.
- **Pivot also fails** → **escalate**.
- The **incomplete-fix rule**: a finding is "out of scope / follow-up"
  *only if* it falsifies no named `AC-N`/`D-NNN`. The test is mechanical,
  not editorial. Deflecting a substantive failure to a follow-up issue is
  forbidden.
- A harness **3-consecutive-failure meta-restart** (context hygiene:
  compress history ≤1000 tokens, clear context, restart from archived
  solution tree) is *not* a fourth attempt and does *not* override an N=3
  escalation. The solution tree is the single source of truth across a
  meta-restart.

- `[REQ-8]` Retry is bounded and laddered (refine → pivot → escalate),
  with attempt count and rationale persisted in a durable solution tree.
- `[INV-8]` "Follow-up issue" is reserved for findings that falsify *no*
  named AC/D-NNN; anything that falsifies a named invariant is an
  incomplete fix and MUST be reopened, not deflected.
- `[INV-9]` Context-hygiene restarts and product-retry bounds are
  *orthogonal* mechanisms keyed off the same number 3; they MUST NOT be
  conflated. Escalation always wins over restart.

### 2.7 Safety circuit (stop / escalate conditions)

The loop MUST halt and surface to the user — never silently continue — on:

1. N=3 gate failures + no green pivot.
2. Unresolvable merge conflict.
3. A destructive/irreversible action the gate cannot competently assess
   (force-push, history rewrite, data migration, release).
4. Genuine spec/product ambiguity (human product judgement needed).
5. Budget exhaustion (time/token/iteration).
6. Red `main` after merge (post-merge health check failed).
7. >2 upheld implementer challenges on one PR.

- `[REQ-9]` The autonomous loop MUST have an explicit, enumerable set of
  halt conditions; halting on a safety condition is *correct* behaviour,
  not failure. Each halt writes reason + state to the solution tree.

### 2.8 Kill switch + continuity

- The loop is driven by a recurring driver (`/loop` skill) re-invoking
  "execute one factory step" on an interval.
- Kill switch: cancel the driver, **or** place `.claude/STOP-FACTORY`
  sentinel (checked at the *start* of every step). Worst-case latency is
  one full step; halt is clean (between steps, `main` synced, never
  mid-merge). Sentinel is operator state, gitignored, never committable.

- `[REQ-10]` The autonomous loop MUST have an out-of-band kill switch with
  bounded, clean-state latency (halt between atomic units, never mid-
  commit). Operator control state is separate from project state.

### 2.9 Spec-before-code discipline + D-NNN namespace

(`spec-before-code.md` + `MISSION.md` + SPEC structure.)

- Coordination-heavy components (**PSDH triage score ≥2** — shared mutable
  state, temporal coupling, cross-process coordination, feedback loops,
  state accumulation) MUST have a written `docs/spec/SPEC-*.md` *before*
  any implementation PR that changes their behaviour. Pure single-process
  functions and CRUD do not.
- A SPEC's canonical structure (confirmed across SPEC-CIRCUIT-BREAKER and
  SPEC-USER-TURN): **§0** why · **§1** triage · **§2** component
  decomposition · **§3** L0 constraints (the *eight elicitation
  questions*: multi-writer, ordering, silent failure, boundary
  information-loss, feedback loops, pre/post-conditions, message-ordering
  protocol, change-impact) · **§4** boundary contracts (B-N: each
  inter-component interface with its invariants) · **§5** state
  enumeration on highest-risk interactions · **§6** D-NNN runtime
  invariants · **§7** acceptance criteria (AC-N) · **Appendix B** source
  map (D-NNN/C-N → exact file:symbol).
- **D-NNN** = runtime invariant; **AC-N** = acceptance criterion; **C-N** =
  constraint. The D-NNN namespace is *globally partitioned* across SPECs
  (block-to-SPEC table in `MISSION.md`); a new D-NNN must be verified free
  across the whole repo and all branches before use. Each D-NNN carries a
  *detection method* naming the file/test that enforces it.

- `[REQ-11]` Coordination-heavy components MUST be specified before
  implementation, using a fixed structured-elicitation template that ends
  in *named, enforceable runtime invariants* each linked to a detection
  test.
- `[REQ-12]` Invariants live in a single globally-partitioned namespace
  (`D-NNN`) with a registry mapping block→owner spec; every invariant is
  traceable to the exact file/symbol that enforces it (source map).
- `[INV-10]` An acceptance criterion MUST have a test that fails before the
  change and passes after; a SPEC'd boundary may not gain new state
  without a corresponding §3 constraint + §4 contract update in the *same*
  PR.

### 2.10 OTP non-negotiables (8 invariants + forbidden forms)

These are correctness invariants the new architecture should inherit
wholesale:

1. **Stateful subsystems MUST be supervised processes.** No module-level
   mutable state, no `:ets` outside an owner process, no
   `Application.put_env/3` for runtime state.
2. **Extensibility seams MUST be behaviours.** No abstract base classes,
   no string-keyed dispatch. Pattern-match on atoms and structs.
3. **MUST NOT wrap stateless logic in a GenServer.**
4. **Cross-process events MUST use `Phoenix.PubSub` or monitored refs.**
   Never `Process.whereis/1 |> send/2`. Never `:global`.
5. **Telemetry on everything user-visible or perf-sensitive.**
   `:telemetry.execute/3` in `[:tau, ...]`; pair `*.start` with
   `*.stop`/`*.exception`.
6. **Invariant-bearing modules MUST have properties before examples**
   (StreamData).
7. **Let it crash; supervise; restart.** No `try/rescue` across process
   boundaries; never catch `:exit`.
8. **Pure functions are the default; processes are the exception.**

Concrete forbidden forms: no "Manager"/"Service" GenServer for shared
state (use per-entity processes / `:persistent_term` / ETS-with-owner); no
hand-rolled `receive` loop in place of `:gen_statem`; no HTTP client
besides Finch/Mint; no JSON lib besides Jason; no `IO.puts/1` for logging;
no ad-hoc event format (extend `Tau.Provider.Event`); no swallowed errors
(tagged tuples / `%Event.Error{}`, never raise on user input); no
shell-output screen-scraping in `Bash` callers (tools return structured
`details`).

- `[INV-11..18]` Adopt all eight OTP non-negotiables verbatim as the
  runtime-correctness floor for the new architecture.

---

## 3. Documented failure modes — evidence for structural invariants

From `worktree-discipline.md`, every item is annotated **"this has
happened in this project"** — i.e. each is empirical, not hypothetical.
The recurring lesson: these are enforced today by *prose rules an agent
must remember*, and the prose itself notes they keep recurring. **The new
design should make each structurally impossible (OTP isolation /
process-per-unit), not rule-enforced.**

| # | Failure mode (observed) | Today's prose mitigation | Structural invariant the new design should enforce |
|---|---|---|---|
| F-1 | **Parent-HEAD drift** — reviewer A's `gh pr checkout` mutates parent HEAD mid-write of implementer B; `main` ref drifts behind origin; later worktree spawns fork from stale state and never see merged work. | "Parent HEAD always on `main` at `origin/main`; verify before every spawn." | `[INV-F1]` No shared mutable working tree. Each unit of work owns an isolated checkout from a known-good ref; no agent can mutate another's HEAD. |
| F-2 | **Reviewer collisions** — reviewers run *without* `isolation: worktree` and collide with mid-write implementers. "Reviewers without `isolation: worktree` are the dominant cause of mid-task collisions." | "`isolation: worktree` non-negotiable for every file-touching agent." | `[INV-F2]` Isolation is a property of the *process spawn*, structurally enforced, not an opt-in flag an agent might omit. |
| F-3 | **Locked finished worktrees accumulate** and block future checkouts / hold the `main` ref. "Locked-finished worktrees accumulating is the symptom that hides every other failure mode." | "Remove worktree in the same turn an agent completes." | `[INV-F3]` Work-isolation resources have a *supervised lifecycle* — created on spawn, reclaimed on termination (incl. crash), never leaked. A linked/monitored owner process guarantees cleanup. |
| F-4 | **Capture-before-destroy** — a killed agent has three kinds of dirty work: staged + unstaged (caught by `git diff HEAD`) and **untracked** (caught by *neither* `git diff` — needs a separate tar). A naïve `git diff` silently omits both staged and untracked work. | A precise capture sequence: `status --short`, `diff HEAD`, `ls-files --others --exclude-standard | tar`. | `[INV-F4]` In-progress work is durable state that survives the worker's death. The supervisor captures *all* dirty state (staged, unstaged, untracked) before reclaiming a worker — ideally work is committed to a durable log continuously, not held in a volatile tree. |
| F-5 | **Shared `$HOME`-namespace cache races** — Burrito's unpack cache at `~/.local/share/.burrito/<ver>/` survives worktree isolation; two concurrent `mix tau.smoke` from different worktrees collide there → intermittent `XZ/LZMA Decode Failed`. (Also `~/.cache/zig/`, `~/.mix/`, `~/.tau/`, Hex mirror, GitHub release downloads.) | Per-agent `XDG_DATA_HOME=<worktree>/.xdg-data` override in every brief. | `[INV-F5]` *All* mutable resources a concurrent worker touches — not just the git tree — MUST be partitioned per worker. Worktree isolation isolates git refs only; `$HOME`/system/network caches leak through it. The new design needs a complete resource-isolation boundary per unit of work. |
| F-6 | **Spawn-brief integrity** — `isolation: worktree` *always* forks from `main`, never from the spawning agent's branch. A brief asserting "you are at commit X / branch Y" is unreliable; agents that trusted it operated on the wrong tree. | "A brief states the *task*, never the *position*; every agent verifies `pwd`/HEAD/branch itself and aborts if in the parent repo root." | `[INV-F6]` A worker's starting position is established by the *system* and verified by the worker, never asserted by an untrusted brief. Position is mechanism, not message. |
| F-7 | **Stale-parent recovery** is a documented multi-step manual procedure (inventory worktrees, preserve running ones, remove finished, clean leaked untracked files byte-compared against origin, re-sync main, prune orphan branches). That a *recovery procedure* exists is itself evidence the invariants are routinely violated under the prose regime. | A 7-step recovery checklist. | `[INV-F7]` If recovery procedures are needed, the isolation model is too weak. The new design should make the violated states unreachable rather than recoverable. |

Additional cross-cutting failure evidence:

- **`hooks-and-scripts.md`** — hook scripts are the enforcement layer;
  editing them mid-task disables monitoring. Implies: enforcement
  infrastructure must be tamper-resistant and out of the agent's normal
  write scope. `[INV-F8]` Enforcement mechanisms are not part of the
  mutable task surface.
- **`spec-before-code.md` rationale** — the "Why this exists" section
  records the founding failure: *"Three days of activity (May 1–3 2026)
  produced 110 commits and a non-functional TUI,"* diagnosed as an absence
  of plan-of-record and a review gate tuned for local OTP correctness
  rather than product behaviour. `[INV-F9]` The gate MUST verify
  *user-visible product behaviour*, not just local code correctness — the
  single most important lesson on file. The "substance over ceremony"
  section of `factory-loop.md` is the direct response: "works" is never a
  valid claim without the exact command and the observable signal against
  the user-facing path.

---

## 4. Subsystem inventory

Inventory only (responsibilities inferred from names, `PROJECT.md`, and
the spec catalog — *not* from reading implementations). "Reusable?" judges
fitness as *inspiration/lift* for a clean-slate design, not drop-in reuse.

| Subsystem (`lib/tau/…`) | Apparent responsibility | Reusable? |
|---|---|---|
| `application.ex` | Root supervision tree | Pattern yes; structure to be re-derived |
| `registries.ex` | Registry container | Pattern yes |
| `session.ex` (55 KB) + `session/` | `:gen_statem` turn loop FSM; sub-modules: `provider_turn`, `tool_dispatch`, `coding_agent_turn`, `compaction`, `queue`, `journal`, `model_swap`, `skill_activation`, `slash_command`, `data`, `events` | Core concept (FSM-per-session) yes; the 55 KB monolith is a smell — see gaps |
| `provider.ex` + `providers/` | `Tau.Provider` behaviour; adapters: anthropic, openai, gemini, bedrock, mistral, groq, deepseek, azure_openai, copilot, custom, replay; shared/, rate_limiter/ | Behaviour + adapter pattern: strong reuse candidate |
| `provider/event.ex`, `context_windows.ex` | Canonical stream event struct; context-window lookup | Yes — single event format is an INV |
| `message.ex` + `message/assembler.ex` | Pure event→message folding | Yes — pure core, properties-tested |
| `tool.ex` + `tool/` + `tools/` | `Tau.Tool` behaviour; context/result/validator; builtin + operations | Behaviour + structured-result pattern: yes |
| `permissions/` | Rule sets, evaluator, matcher(s), mode, parser, heuristics | Property-tested permission engine: strong reuse candidate |
| `hook.ex` + `hooks/` | Hook behaviour; dispatcher, shell | Pattern yes |
| `persistence.ex` + `persistence/jsonl.ex` | Persistence behaviour (default JSONL) | Behaviour yes; JSONL default is weak for a factory (see gaps) |
| `compactor.ex` + `compactor/` | Context-compaction behaviour | Concept yes |
| `mcp/` | MCP transports, server, reconciler, tool_adapter, supervisor | MCP support: reuse candidate |
| `extension.ex` + `extensions/loader.ex` | Extension DSL + runtime hot-reload loader (SPEC-EXTENSIONS) | Concept yes; hot-reload is coordination-heavy |
| `cli.ex` (31 KB) + `cli/` | escript/argv entry; config, mcp, extensions, init subcommands | Concept yes; 31 KB arg-parser monolith is a smell |
| `tui/` | Ratatouille TUI: app/, editor, event_bridge, fuzzy, history, render/, status_bar, subagent_tree, supervisor, runtime_opts | Product-facing; the *headless testing protocol* (SPEC-TUI-HEADLESS) is the valuable artifact |
| `circuit_breaker.ex` + `circuit_breaker/` | Per-provider `:closed/:open/:half_open` FSM; ETS-owner Store + façade (SPEC-CIRCUIT-BREAKER) | Strong reuse candidate; clean OTP shape |
| `memory/` | SQLite (Exqlite) store, migrations, supervisor, embedder, embedding_worker, FTS5 + sqlite-vec (SPEC-MEMORY-STORE) | Persistent + semantic memory: strong reuse candidate |
| `cost.ex` + `cost/tracker.ex` | Per-turn / adapter-tagged cost tracking (D-038) | Reuse candidate |
| `otel_reporter.ex` + `otel_reporter/` | Supervised OTLP span/metric exporter from `[:tau,…]` telemetry (SPEC-OTEL-REPORTER) | Strong reuse candidate; observability is essential for an autonomous factory |
| `telemetry/` | Telemetry handlers + supervisor | Yes |
| `settings/` | Loader, cache, schema, vault, watcher | Property-tested merge: reuse candidate; live-reload is coordination-heavy |
| `skill.ex` + `skills/` | Skill frontmatter + loader | Concept yes |
| `command.ex`/`commands/` + `prompt_template(s).ex` | Slash-command catalog/parser/builtin; prompt templates | Concept yes |
| `coding_agent.ex` + `coding_agent/` + `coding_agents/` | **Subprocess sub-agent substrate**: dispatcher, supervisor, workspace, tau_context, event, cost; adapters: `claude_code`, `replay` (SPEC-CODING-AGENT) | **Most directly relevant to the factory** — this is the embryonic "spawn a coding agent as a subprocess" mechanism. Reuse the *concept*; see gaps re: it being a subprocess shell-out rather than a first-class supervised factory worker |
| `markdown.ex`, `build.ex`, `burrito_steps/` | Headless markdown render; Burrito release relink steps | Build-specific; minor |
| `mix/tasks/` | release, qa, gate (`tau.gate.{ac_linkage,masking,mutation}`), smoke, tui_ux | **The mechanical gates + UX-smoke tasks are the crown jewels** — direct reuse of the *gate semantics* |

**Notable absence:** there is **no `lib/tau/factory/` subsystem in the
working tree** beyond the gate mix-tasks and `Tau.Factory.Gate` (referenced
by `factory-loop.md` as CI). The factory *operating procedure* exists only
as prose rules + a Claude prompt loop + three CLI gate checks. The factory
itself is not a supervised Elixir subsystem. This is the central gap.

---

## 5. What the current attempt got wrong / lacks

Architectural gaps, ordered by severity for the clean-slate goal.

### 5.1 The coordinator is a prompt-driven Claude loop, not a supervised process

The factory's brain is a Claude Code conversation re-invoked by a `/loop`
driver. Its "state" is the model's context window + a JSON solution tree it
must remember to update. Consequences:

- **No durable supervised process model for the factory itself.** The
  `otp-non-negotiables` (every stateful subsystem is a supervised process)
  apply to Tau's *product* code but **not to the factory that builds it.**
  The coordinator's state lives in a context window — the most volatile
  store imaginable — and is reconstructed by re-reading prose rules and a
  JSON file. The repeated "do not reread mid-run; rereading is a signal of
  context pollution" warnings are symptoms of this: context is the state
  store, and it degrades.
- **The "3-consecutive-failure meta-restart / compress to ≤1000 tokens"
  machinery exists *because* the state store is a context window.** A
  process-based factory with externalized state would not need context-
  hygiene restarts at all.
- `[GAP-1]` In the clean-slate design, **the factory is itself an OTP
  application**: a supervised coordinator process, a process-per-PR (or
  process-per-factory-step) holding plan + attempt count + gate verdicts as
  real state, with the LLM as a *tool the process calls*, not the process
  itself. The solution tree becomes durable process/ETS/DB state, not a
  JSON file an agent must remember to write.

### 5.2 Invariants are prose, enforced by agent diligence, not by the runtime

`factory-loop.md`, `worktree-discipline.md`, and `spec-before-code.md` are
thousands of words of MUST/MUST NOT that an agent must *read, hold in
context, and choose to obey* every step. The documents themselves record
that the rules are routinely violated (every worktree failure mode is
tagged "has happened"; a multi-step *recovery* procedure is documented).

- `[GAP-2]` Rules enforced by prose + agent attention are not invariants;
  they are suggestions with good intentions. The clean-slate design should
  convert every "MUST" that *can* be structural into a runtime guarantee:
  isolation by OS/process boundary, serialized-merge by a single
  merge-owning process, freshness re-check as a precondition the merge
  process *cannot skip*, the kill switch as a supervised gate rather than a
  start-of-step file read.

### 5.3 No first-class process-per-PR / process-per-worker

Work isolation today = git worktrees, an OS-level mechanism bolted on, with
manual lifecycle (create on spawn, *remember* to remove on completion).
Leaks are the "symptom that hides every other failure." Resource isolation
beyond git (the `$HOME` caches) is *additional* prose the agent must
remember per brief.

- `[GAP-3]` Model each unit of work as a **supervised worker process owning
  its full isolation boundary** (git checkout *and* per-worker
  `$HOME`/cache/XDG namespace), created and reclaimed by its supervisor.
  Crash ⇒ supervisor captures dirty state and reclaims resources
  automatically. The capture-before-destroy sequence (F-4) becomes a
  supervisor `terminate`/monitor callback, not a checklist. This makes
  F-1..F-7 structurally unreachable.

### 5.4 The "coding agent" substrate is a subprocess shell-out, not a native worker

`coding_agent/` drives sub-agents as external subprocesses (the
`claude_code` adapter shells out). That is the right *idea* (delegate
implementation to an agent) but the wrong *substrate* for an OTP factory:
no supervision of the agent's lifecycle as a BEAM process, structured I/O
via screen-scraping risk, and the worktree/cache races (F-5) come precisely
from subprocesses sharing `$HOME`.

- `[GAP-4]` First-class worker agents whose lifecycle, I/O (structured
  events, not scraped stdout), and resource boundary are owned by the BEAM
  supervision tree. If sub-agents must remain external processes, wrap each
  in a supervised port/monitor with an enforced per-worker resource
  namespace.

### 5.5 Persistence and solution-tree durability are weak

Default persistence is JSONL; the solution tree is a JSON file
(`.claude/logs/solution-tree.json`) the coordinator must remember to
reconcile against `gh issue list`. Source of truth for milestone state is
*GitHub*, queried live each step. The factory has no durable, queryable,
crash-surviving record of its own decisions.

- `[GAP-5]` A durable, transactional store for factory state (steps,
  attempts, verdicts, challenges, kill reasons) — survives restarts, is the
  *single* source of truth, removes the "reconcile the JSON against GitHub"
  reconciliation burden. The existing `memory/` SQLite subsystem is a
  reuse candidate for this.

### 5.6 Monolithic hotspots

`session.ex` (55 KB) and `cli.ex` (31 KB) are large monoliths (session.ex
has been partially decomposed into `session/` sub-modules — recent commits
show active "decompose Tau.Session" refactors, evidence the size was a
known problem). Large single modules concentrate coordination logic and
resist the "pure functions are the default; processes are the exception"
discipline.

- `[GAP-6]` Keep the turn-loop FSM thin; push pure folding/decision logic
  into small property-tested modules from the start (the `message/`,
  `permissions/`, and the *intended* `session/` decomposition show the
  target shape).

### 5.7 Gate residuals acknowledged but unclosed

The mechanical gates close the *vacuous-test* hole but explicitly do **not**
catch under-asserting or wrong-path tests — those rest on `critic`
judgement (an LLM). So the strongest guarantees are still ultimately
human/LLM-judgement-bound at the most failure-prone seam.

- `[GAP-7]` Push more of the oracle into mechanism: require gating tests to
  drive the *real user entry point* (e.g. `Tau.CLI.main/1` with realistic
  argv), checkable structurally; consider mutation-of-assertions or
  coverage-delta checks to bound under-assertion mechanically rather than
  by critic taste.

### 5.8 The product the factory builds and the factory are conflated

Tau's *product* (a TUI coding harness) and the *factory* (the autonomous
loop that builds Tau) share one repo, one rule-set, one CLAUDE.md, and the
self-hosting goal deliberately fuses them. But the factory has no
architecture of its own — it borrows the product's OTP rules in *prose*
while running as a prompt loop. For a clean slate, the factory deserves its
*own* specified, supervised architecture, with self-hosting as the
convergence target rather than the starting assumption.

- `[GAP-8]` Specify the factory as a first-class system (its own
  `SPEC-FACTORY-*` with §3 constraints, §4 boundary contracts, D-NNN
  invariants, AC-N) *before* relying on it to build itself.

---

## 6. Lessons for the clean-slate tau

1. **The factory must be an OTP application, not a prompt.** A supervised
   coordinator + process-per-factory-step with externalized, durable state.
   The LLM is a tool the process calls, never the locus of state.
   (Addresses GAP-1, GAP-5; eliminates the context-hygiene-restart
   machinery.)
2. **Convert prose MUSTs into runtime guarantees.** Every invariant that
   *can* be structural (isolation, serialized merge, freshness precondition,
   kill switch, cleanup-on-crash) should be enforced by process/OS
   boundaries and supervisor lifecycle — not by an agent remembering a rule.
   The documented recurrence of every worktree failure mode is the proof
   that prose enforcement fails. (Addresses GAP-2, GAP-3.)
3. **Isolation is a complete resource boundary, not just a git worktree.**
   Git refs, `$HOME` caches (Burrito/zig/mix/tau), XDG dirs, network
   caches — all partitioned per worker, created/reclaimed by the worker's
   supervisor. Capture-before-destroy (staged + unstaged + untracked)
   becomes a `terminate` callback. (Addresses F-1..F-7, GAP-3, GAP-4.)
4. **Keep the gate model — it is the most mature artifact.** Two judgement
   oracles (critic + reviewer) + three path-based mechanical gates
   (AC-linkage, masking-detection, mutation), oracle/test-author separation,
   the challenge protocol, and the incomplete-fix mechanical test. Carry
   them forward; push more of the residual (under-asserting / wrong-path
   tests) into mechanism. (Preserves REQ-3..REQ-6; addresses GAP-7.)
5. **Preserve the bounded-retry + safety-circuit + kill-switch laddering.**
   refine→pivot→escalate (N=3), the seven halt conditions, and a clean-state
   kill switch are well-reasoned; reimplement them as process-state
   transitions, not context-held bookkeeping. (Preserves REQ-8..REQ-10.)
6. **Keep spec-before-code + the D-NNN invariant namespace.** The structured
   §0–§7 + Appendix-B-source-map template, PSDH ≥2 triage, globally-
   partitioned `D-NNN` invariants each linked to an enforcing test — this is
   how design knowledge was made durable and traceable. Inherit it,
   including a `SPEC-FACTORY-*` for the factory itself. (Preserves REQ-11,
   REQ-12; addresses GAP-8.)
7. **Inherit the eight OTP non-negotiables verbatim** as the runtime floor,
   and *also apply them to the factory*, not only to the product.
   (Preserves INV-11..18; addresses GAP-1.)
8. **Gate on product substance, not code ceremony.** The founding failure
   (110 commits / 3 days / non-functional TUI) was a review gate tuned for
   local OTP correctness rather than user-visible behaviour. "Works" requires
   the exact command and the observable signal against the user-facing path.
   Bake this into the acceptance-criterion contract. (Addresses GAP-2's
   product-behaviour dimension, INV-F9.)
9. **Externalize and make queryable the factory's own memory.** Reuse the
   SQLite `memory/` subsystem for a transactional solution tree; remove the
   "reconcile a JSON file against GitHub each step" burden. (Addresses
   GAP-5.)
10. **Reusable lifts:** the provider-behaviour + adapter set, the
    property-tested permissions engine, the circuit breaker, the OTEL
    reporter, the cost tracker, the canonical `Provider.Event`, the
    pure `Message.Assembler`, and especially the **mechanical gate
    mix-tasks and TUI headless-testing protocol** are the highest-value
    code-level inspirations.
