# Migration appendix — current repo → clean-slate factory (D-S3)

**Decision D-S3:** greenfield component design *plus* a migration note. The
new factory (`:tau_factory`, OTP application — `supervision-tree.md`) is a
clean-slate design, but it does not throw away the current repo's hard-won
subsystems. This appendix maps each current `lib/tau/*` subsystem onto the new
component boundaries (L/K/S/G/W/U/M + Toolchain + Policy —
`../03-system-architecture/system-architecture.md`) as **reusable seams**,
classifies how much of each carries forward, and gives a strangler-style
migration path that keeps the current harness usable while the new factory is
stood up beside it.

The framing throughout is **evolve, not rewrite-from-zero**. The product code
(providers, gates, circuit breaker, memory, telemetry) is mature and lifts
nearly as-is; the *factory* itself — which exists today only as prose rules +
a Claude prompt loop + three CLI checks — is the part that becomes a real
supervised OTP system (research `tau-current-analysis.md` §5, GAP-1..GAP-8).

Cross-references: layer-03 components (L/K/S/G/W/U/M); layer-04
`supervision-tree.md` (topology), `traceability.md` (module index, D-300..D-360,
INV/CON/LIV), `gate-and-toolchain.md` (HR-3, the three pure gate modules),
`worker-fleet.md` (W), `control-plane.md` (K/S), `merge-and-integration.md` (M),
`durable-spine.md` (L); HR-1..HR-9 from `../03-system-architecture/`.

---

## 1. Subsystem → component mapping table

Reuse class: **lift** = move with minimal change (a behaviour or pure module
that already fits a new seam); **adapt** = keep the concept, re-home and reshape
to a new boundary; **inspiration** = mine for constraints/shape, rewrite the
implementation; **drop** = do not carry forward (with the reason in §7). "Side"
notes whether the home is the new **factory** app, the **product** app it
builds, or **shared** (a library both depend on).

| Current subsystem (`lib/tau/…`) | New home (component / side) | Reuse class | Notes |
|---|---|---|---|
| `provider.ex` + `providers/{anthropic,openai,gemini,bedrock,mistral,groq,deepseek,azure_openai,copilot,custom,replay}` | **Egress / Gov** (shared) | **lift** | `Tau.Provider` behaviour + adapter set reused verbatim (`supervision-tree.md` Step 7; `traceability.md` Gov row). The LLM is *a tool the factory calls*, not the locus of state (GAP-1). |
| `provider/event.ex` | shared | **lift** | Canonical stream event struct — the single-event-format invariant. Used by both product turn-loop and factory worker I/O parsing. |
| `provider/context_windows.ex` | shared | **lift** | Context-window lookup table; pure data. |
| `providers/rate_limiter/{supervisor,token_bucket}` | **Egress** (`Provider.RateLimiter`) | **lift** | Token-bucket reused as-is in `Egress.Supervisor` (`supervision-tree.md` tree; D-351 NFR-EGRESS). |
| `circuit_breaker.ex` + `circuit_breaker/{state,store}` | **Egress** (`CircuitBreaker.Store`) | **lift** | Per-provider `:closed/:open/:half_open` FSM + ETS-owner Store reused verbatim — clean OTP shape (`supervision-tree.md` Egress; D-351). |
| `cost.ex` + `cost/tracker.ex` | **Gov / L** (`Cost.Tracker`) | **lift→adapt** | Lift the per-(model,role) tracker; re-home attribution into L's durable accounting (CON-4, D-333). Add factory roles (impl/test-author/critic/reviewer). |
| `otel_reporter.ex` + `otel_reporter/` | **Gov** (`OtelReporter`) | **lift** | Supervised OTLP exporter from `[:tau,…]` telemetry; extend namespace to `[:tau,:factory,…]` (D-352 NFR-OBS=100%). |
| `telemetry/{handlers,supervisor}` | **Gov** (shared) | **lift** | Telemetry handler+supervisor pattern; add paired factory spans. |
| `message.ex` + `message/assembler.ex` | **product** (turn-loop) | **lift** | Pure, properties-tested event→message fold. Product-side; the factory consumes worker events, not assembled chat messages. |
| `permissions/` (evaluator, matcher, mode, parser, rule sets, heuristics) | **product** / **Gov** (`ActionClassifier` inspiration) | **lift (product) + inspiration (Gov)** | Property-tested engine lifts as-is for product tool-gating; its matcher discipline *inspires* the factory's `ActionClassifier` denylist (INV-20, D-319). |
| `memory/` (Exqlite store, migrations, supervisor, FTS5, sqlite-vec, embedder) | **L** (durable ledger backing) | **lift→adapt** | OQ-1 resolved to **SQLite/Exqlite** (`durable-spine.md` §8), so this substrate is a **direct lift** for L's durable store (GAP-5) — Repo/migration scaffolding reused; the same store also backs product-side semantic memory. Adapt = add the factory schema (units/verdicts/budget). |
| `tool.ex` + `tool/` + `tools/` | **product** | **lift** | `Tau.Tool` behaviour + structured-result pattern; product tool surface. Factory workers *use* product tools via the agent port. |
| `hook.ex` + `hooks/` | **product** | **lift** | Hook behaviour + dispatcher; product extensibility. |
| `mcp/` | **product** | **lift** | MCP transports/server/reconciler; product capability. |
| `settings/{loader,cache,schema,vault,watcher}` | **product** + **Policy** (inspiration) | **lift (product) + inspiration (Policy)** | Property-tested merge lifts for product config; its versioned-schema shape *inspires* the factory `Policy` data plane (Π), which is engine-clamped, not free config (HR-8). |
| `session.ex` + `session/{provider_turn,tool_dispatch,…,journal,queue,events}` | **product** (turn-loop) | **inspiration** | FSM-per-session concept lifts; the 55 KB monolith does not (GAP-6). The `:gen_statem`-per-entity shape directly informs **U** (Unit PR-FSM) and **K** (Coordinator), but those are new factory FSMs, not session reuse. |
| `coding_agent.ex` + `coding_agent/{dispatcher,supervisor,workspace,tau_context,event,cost}` + `coding_agents/` | **W** (Worker fleet) | **inspiration** | The embryonic "spawn a coding agent" mechanism. Concept lifts; the **subprocess shell-out substrate is replaced** by a supervised BEAM worker fleet with structured `Port` I/O (GAP-4; `worker-fleet.md`; §4 below). |
| `mix/tasks/tau.gate.{ac_linkage,masking,mutation}` | **G** (`Gate.{AcLinkage,Masking,Mutation}`) | **adapt** | **The crown jewels.** Gate *semantics* lift; the CLI-task packaging is split into pure modules + engine-owned execution (HR-3; §3 below; `gate-and-toolchain.md`). |
| `mix/tasks/{smoke,tui_ux,qa,release}` + TUI headless protocol (`SPEC-TUI-HEADLESS`) | **product** (G consumes via Toolchain) | **adapt** | The headless PTY testing protocol is a product-side reuse the factory's Elixir Toolchain adapter invokes as a `test`/`mutation_run` recipe (§3). |
| `cli.ex` (31 KB) + `cli/` | **product** | **inspiration** | escript/argv entry concept; the monolith does not lift (GAP-6). Factory has no human CLI — it is driven by Coordinator + Oban cron. |
| `tui/` (Ratatouille app, render, editor, fuzzy, …) | **product** | **lift (product)** | Product-facing UI. Not a factory concern; the *headless testing protocol* (above) is the reusable artifact, not the widgets. |
| `extension.ex` + `extensions/loader.ex` | **product** | **lift** | Extension DSL + hot-reload; product capability. |
| `compactor.ex` + `compactor/`; `skill.ex` + `skills/`; `command(s)` + `prompt_template(s)` | **product** | **lift** | Context-compaction, skills, slash-commands, templates — product turn-loop concerns. Factory state is durable, so context-compaction is *not* a factory mechanism (see §7). |
| `persistence.ex` + `persistence/jsonl.ex` | — | **drop (factory) / lift (product)** | JSONL persistence behaviour is too weak for factory state (GAP-5). Product may keep it; the factory uses SQLite/Exqlite (L). |
| `application.ex`, `registries.ex` | **factory** (re-derived) | **inspiration** | `rest_for_one` spine + Registry-container pattern is exactly the new tree's shape (`supervision-tree.md` Step 3 confirms it is already the live pattern); the tree itself is re-derived for `:tau_factory`. |
| `markdown.ex`, `build.ex`, `burrito_steps/` | **product / Toolchain** | **lift** | Build/release plumbing the Elixir Toolchain adapter's `package` recipe invokes. Minor. |
| `.claude/rules/*.md`, `.claude/logs/solution-tree.json`, context-window state, meta-restart machinery | **factory** (structural) | **inspiration / drop** | Prose MUSTs → D-NNN invariants (§5); JSON tree → durable L (§4); context-hygiene meta-restart → **dropped** (§7, GAP-1). |

---

## 2. Direct lifts (minimal change)

These already have the right shape — a behaviour, a pure module, or a clean
ETS-owner OTP process — and slot into a new component with re-homing only.

| Lift | Slots into | How it slots |
|---|---|---|
| `Tau.Provider` behaviour + 11 adapters | **Egress/Gov**, shared | Reused verbatim. The factory calls providers for its agent roles through the same behaviour; the merge/gate path never bypasses Egress (D-351). |
| `Provider.Event` struct | shared | The one canonical event format (INV — no ad-hoc events). Both the product turn-loop and the factory's worker-`Port` parser key off it. |
| `providers/rate_limiter` (token-bucket) | `Egress.Supervisor` | Lifts into the `Egress` subtree unchanged (`supervision-tree.md`). |
| `circuit_breaker/` (state + ETS Store) | `Egress.Supervisor` | `CircuitBreaker.Store` is already an ETS-owner-under-a-supervisor — exactly the new tree's `Egress` child. No change. |
| `otel_reporter/` | `Gov` | Lifts; subscribe additionally to `[:tau,:factory,…]` (D-352). |
| `cost/tracker.ex` | `Cost.Tracker` under Gov, attribution to L | Lift the tracker; route durable attribution writes through `Ledger.Writer` (CON-4/D-333). |
| `settings/` (loader+cache+schema, property-tested merge) | **product** config; *inspires* `Policy` | Product config lifts as-is. The factory `Policy` data plane reuses the schema-validation *shape* but is engine-clamped (HR-8) — not arbitrary live config. |
| `telemetry/` | `Gov`, shared | Handlers + supervisor lift; add paired `*.start`/`*.stop` factory events. |
| `provider/event.ex`, canonical event | shared | (see above) |
| `message/assembler.ex` (pure fold, properties) | **product** turn-loop | Pure, already properties-tested; lifts untouched. Product-side. |
| `permissions/` engine (properties) | **product** tool-gating; *inspires* Gov `ActionClassifier` | Product engine lifts; its matcher discipline informs the factory destructive-action denylist (INV-20). |
| `memory/` (SQLite/Exqlite, FTS5, sqlite-vec) | **L** backing / product semantic memory | Lift the persistence substrate as the durable-state reuse candidate (GAP-5). OQ-1 resolved to **SQLite/Exqlite** (`durable-spine.md` §8), so L's system-of-record reuses this scaffolding directly (RPO=0 via SQLite-WAL, D-315) — single binary preserved — see the phased path (§6). |

**Net:** the entire provider/egress/observability/cost/permissions/message
spine lifts with re-homing only. None of it is factory-specific; all of it is
the shared correctness floor the new factory inherits (INV-23/24 via the gate,
D-322/D-323).

---

## 3. The crown jewels — gate semantics (G + Toolchain, HR-3)

The three mechanical gates are the single most mature artifact in the repo
(`tau-current-analysis.md` lesson 4, REQ-3..REQ-6). Today they are **Mix
tasks** (`lib/mix/tasks/tau.gate.{ac_linkage,masking,mutation}.ex`) that mix
*pure decision logic* and *execution* in one CLI command. The new design keeps
the semantics and splits along **HR-3 (engine owns execution)**.

| Current (Mix task) | New shape (`gate-and-toolchain.md`) | Split |
|---|---|---|
| `tau.gate.ac_linkage` | `Tau.Factory.Gate.AcLinkage` — **pure** | Scan-`## Acceptance criteria`-section logic becomes a referentially-transparent function over the PR body + gating-test names. Meta-AC exemption preserved. Enforces INV-23-adjacent AC-linkage; D-305 family. |
| `tau.gate.masking` | `Tau.Factory.Gate.Masking` — **pure** (detection-only) | Path-scan of the diff vs the *frozen* gating-test path set (`paths_g`). Becomes a pure predicate; every flagged deletion is surfaced to `critic`. Enforces **INV-6** (D-305). Path-based, not commit-attribution (REQ-4). |
| `tau.gate.mutation` | `Tau.Factory.Gate.Mutation` (**pure plan + pure `judge/1`**) + **engine execution** | The decisive split. The module returns a `Mutation.Plan` and a pure predicate over the engine-parsed report; it **never runs a test**. The trusted **engine** (G + W) does the revert-to-`merge-base`, runs the gating tests in an isolated workspace via the Toolchain adapter's `mutation_run` recipe, parses the structured artifact with an engine-owned parser, and applies `judge/1`. Enforces **INV-7** (D-306, NFR-GAME-RESISTANCE D-354). |

**Why the split matters (HR-3, FC-5).** Today's Mix task both *runs* `mix test`
and *decides* pass/fail — fine for a single-language (Elixir) repo, fatal for
the polyglot factory: a Rust/JS/Go Toolchain adapter that both ran and judged
its own mutation check could fake a pass. The new contract: the **Toolchain
adapter returns only a declarative descriptor** (invocation recipe + report
format + resource-namespace declaration) and **no verdict**; the engine
executes the recipe and judges the structured artifact itself
(`system-architecture.md` Toolchain; `gate-and-toolchain.md` §3). The Elixir
adapter is just the first such descriptor — the current Mix-task internals
become its `test`/`mutation_run` recipe.

**TUI headless protocol as product-side reuse.** `SPEC-TUI-HEADLESS` and the
PTY smoke harness (`mix tau.smoke`, `test/support/tui_pty_helper.ex`) are the
product's user-visible-behaviour oracle — the direct answer to the founding
failure (INV-F9: gate on substance, not ceremony). They carry forward as
**product-side test recipes the Elixir Toolchain adapter invokes** under
`test`. The factory does not own the TUI protocol; it *runs* it through the
gate, satisfying the "exact command + observable signal" acceptance contract.

---

## 4. The big rewrites — the gaps

These are the parts that do **not** lift, because the thing they need to become
does not exist in the current tree. Each is a named gap.

### 4.1 The factory itself: prose loop → supervised OTP application (GAP-1/GAP-2)

**Today:** `.claude/rules/factory-loop.md` (the procedure) + a Claude Code
session re-invoked by `/loop` (the executor) + three CLI gate checks. State
lives in the model's context window plus `.claude/logs/solution-tree.json` that
the coordinator must *remember* to update. There is **no `lib/tau/factory/`
subsystem** beyond the gate Mix tasks; `Tau.Factory.Gate` is referenced in
prose but absent from the tree.

**Becomes:** the `:tau_factory` OTP application (`supervision-tree.md`):

| Prose role today | New supervised process | OTP form |
|---|---|---|
| coordinator (Claude loop) | `Tau.Factory.Coordinator` | `gen_statem` (`running`/`halting`/`halted`), started last under `rest_for_one`; resumes from L on crash (LIV-5, D-344) |
| work-selection + conflict check | `Tau.Factory.Scheduler` + pure `ConflictCheck` | `GenServer` admission authority (INV-13, D-312); 5-clause check is a pure predicate (HR-4) |
| per-PR plan + attempt count + verdicts | `Tau.Factory.Unit` | `gen_statem` per PR under `DynamicSupervisor`+`Registry`; bounded refine→pivot→escalate (INV-19, D-318) |
| "serialized merge" prose MUST | `Tau.Factory.MergeAuthority` | single `gen_statem`; one `:integrating` train at a time + serialized commit **is** INV-3 (D-302; build runs off-mailbox, `merge-and-integration.md` §1); CAS for INV-1/2/4 (HR-1, D-300/301/303) |

The LLM becomes *a tool a process calls*, not the process. The solution tree
becomes durable SQLite/Exqlite state (L), not a JSON file.

### 4.2 Coding-agent subprocess → supervised worker fleet (GAP-4)

**Today:** `coding_agent/` drives sub-agents as external subprocesses (the
`claude_code` adapter shells out). Right idea, wrong substrate: no BEAM-level
lifecycle supervision, screen-scraping risk on stdout, and the `$HOME`/cache
races (F-5) come precisely from subprocesses sharing `$HOME`.

**Becomes:** `Tau.Factory.WorkerSupervisor` (`worker-fleet.md`, W) — a
`DynamicSupervisor` + `WorkerRegistry` fleet where each worker owns a *complete*
isolation boundary (git checkout + `$HOME`/cache/XDG + network-cache namespace,
declared by the Toolchain adapter), communicates via **structured `Port` I/O**
keyed off `Provider.Event` (not scraped stdout), self-verifies its position in
`init/1` (INV-12, D-311), and is reclaimed on every exit path by a
`WorkspaceJanitor` **monitor** that captures staged+unstaged+untracked before
reclaim (INV-14/15, D-313/314). The `coding_agent/workspace` and
`coding_agent/event` concepts inform this; the subprocess shell-out is dropped.

### 4.3 JSON solution-tree + context state → durable ledger (GAP-1/GAP-5)

**Today:** `.claude/logs/solution-tree.json` reconciled against `gh issue list`
each step; the rest of factory state is the context window.

**Becomes:** **L — the Durable Ledger** (`durable-spine.md`): an append-only
decision log + materialized state in SQLite via Ecto/Exqlite, backlog/jobs via Oban-Lite or a hand-rolled SQLite backlog (OQ-1),
single logical writer (`Ledger.Writer`), WAL-before-ack (RPO=0, INV-16/D-315).
Verdicts are immutable per `(hash,run)` — a revoke appends a superseding record
(HR-2, CON-6/D-335). The `memory/` SQLite substrate is the reuse candidate for
the bootstrap backing (§6). This removes the "reconcile a JSON file against
GitHub each step" burden and makes the factory's own decisions queryable and
crash-surviving (D-353 NFR-AUDIT=100%).

---

## 5. `.claude/rules/` prose → D-NNN invariants

The prose MUSTs that an agent must *read, hold in context, and choose to obey*
become **structurally enforced** runtime invariants. Each row crosses to
`traceability.md` (D-NNN → enforcer → detection test). The pattern: a rule that
recurs in prose ("this has happened in this project") is exactly a rule prose
cannot enforce — it becomes a process/OS boundary instead (GAP-2).

| Rule prose (file → MUST) | Now enforced structurally by | INV / D-NNN |
|---|---|---|
| `worktree-discipline.md`: parent HEAD always on `main` at `origin/main`; no shared mutable tree | `MergeAuthority` sole `main` writer; worker-private forks | INV-11 / **D-310** |
| `worktree-discipline.md`: `isolation: worktree` non-negotiable for every file-touching agent | `WorkerSupervisor` allocates isolation on spawn (a property of the spawn, not an opt-in flag) | INV-10 / **D-309** |
| `worktree-discipline.md`: remove worktree in the same turn an agent completes; no leaked locked worktrees | linked workspace + `WorkspaceJanitor` reclaim on every exit path | INV-15 / **D-314** |
| `worktree-discipline.md`: capture-before-destroy (staged+unstaged+**untracked**) | `WorkspaceJanitor` **monitor** captures all three on `:DOWN` (survives `:kill`) | INV-14 / **D-313** |
| `worktree-discipline.md`: per-agent `XDG_DATA_HOME` for shared `$HOME` caches | per-worker complete resource namespace declared by Toolchain adapter | INV-10 / **D-309** |
| `worktree-discipline.md`: spawn-brief integrity — agent verifies its own pwd/HEAD/branch, aborts in parent root | worker self-verifies position in `init/1` | INV-12 / **D-311** |
| `factory-loop.md`: never branch off stale `main`; merge only a fresh diff (freshness re-check) | `MergeAuthority` CAS `git push --force-with-lease=<expected-old-oid>` (HR-1) | INV-2 / **D-301** |
| `factory-loop.md`: both `critic` and `reviewer` PASS before merge; no skip/override/partial | `MergeAuthority` CAS reads latest PASS verdict@hash before push (HR-2) | INV-1 / **D-300** |
| `factory-loop.md`: merges are serialized — one PR at a time | `MergeAuthority` single GenServer, concurrency-1 mailbox | INV-3 / **D-302** |
| `factory-loop.md`: post-merge `main` health check; red `main` halts | `MergeAuthority` post-batch health → `E-RED-MAIN`; no merge while red | INV-4 / **D-303** |
| `factory-loop.md`: 5-clause conflict check before concurrent admission | `Scheduler` admits iff pure `ConflictCheck` clears on *declared* sets (HR-4) | INV-13 / **D-312** |
| `factory-loop.md`: oracle separation — test-author ≠ implementer, frozen path set | `WorkerSupervisor` spawn-order + recorded author identity (HR-7); `Gate.Masking` path-scan | INV-5 / **D-304**, INV-6 / **D-305** |
| `factory-loop.md`: implementer may not edit a gating-test path | `Gate.Masking` flags any implementer diff touching `paths_g` | INV-6 / **D-305** |
| `factory-loop.md`: mutation check — ≥1 gating test fails on the reverted tree | `Gate.Mutation` plan + engine-executed revert+run (HR-3) | INV-7 / **D-306** |
| `factory-loop.md`: incomplete-fix — a finding falsifying a named AC is not a follow-up | `Gate` mechanical AC-falsification test | INV-9 / **D-308** |
| `factory-loop.md`: N=3 refine → pivot → escalate; attempt count durable | `Unit` gen_statem retry ladder; count in L | INV-19 / **D-318** |
| `factory-loop.md`: 7 safety-circuit halt conditions; total escalation | `Coordinator` + pure `Escalation.classify/1` total over `term()` | INV-18 / **D-317** |
| `factory-loop.md`: kill switch checked at unit boundaries; clean-state halt | `KillSwitch` + `Coordinator` between-unit guard | INV-22 / **D-321** |
| `factory-loop.md`: budget exhaustion halts | `Scheduler`/`Budget.Owner` pre-admission check against ETS snapshot | INV-21 / **D-320** |
| `factory-loop.md`: destructive/irreversible action escalates (no autonomous force-push) | `ActionClassifier` denylist → `E-DESTRUCTIVE`; M never force-pushes | INV-20 / **D-319** |
| `spec-before-code.md`: SPEC'd boundary may not gain state without a §3/§4 + D-NNN | `Gate.SpecMembership` mechanical source-map check (HR-6) | INV-23 / **D-322** |
| `otp-non-negotiables.md`: the 8 invariants (warnings-as-errors, credo, dialyzer) | `Gate` lint/compile/credo/dialyzer via Toolchain (HR-6) | INV-24 / **D-323** |
| `hooks-and-scripts.md`: enforcement infra is not part of the mutable task surface | gate floor engine-fixed, non-shrinkable; Policy may add halves, never remove a floor (HR-8) | (gate-floor invariant) |

The recurring lesson (`tau-current-analysis.md` §3, F-1..F-7): every prose
mitigation that the document itself annotates *"has happened"* is converted to
a state the design makes **unreachable**, not recoverable. The 7-step
stale-parent recovery procedure (F-7) ceases to exist because the violated
state is structurally impossible.

---

## 6. Phased migration path (strangler-style)

Goal: keep the **current Claude-harness factory usable** while the new
`:tau_factory` is stood up beside it, dogfooding the new pieces in
risk-increasing order. The factory's sole objective is self-hosting (auto-memory
`feedback_factory_loop_objective.md`), so the first dogfood seam must be the one
that lets the new system gate *its own* Elixir work.

**Recommended first dogfood seam: the self-hosting Elixir Toolchain adapter +
the three pure gate modules + a single-Unit MergeAuthority.** This is the
smallest slice that produces an *end-to-end gated merge* on the project's own
language, exercising the highest-leverage, highest-risk seam (the gate +
serialized merge) while everything else stays manual.

| Phase | Build | Keeps usable | Rationale / cross-ref |
|---|---|---|---|
| **P0 — extract pure gate logic** | Move the decision logic out of `mix/tasks/tau.gate.*` into `Tau.Factory.Gate.{AcLinkage,Masking,Mutation}` pure modules (properties before examples). The Mix tasks become thin shims calling them. | Current CLI gates + Claude loop unchanged (shims preserve `mix tau.gate.*`). | No behaviour change; pure refactor. Validates the HR-3 split locally before any engine exists. `gate-and-toolchain.md` §2. |
| **P1 — Elixir Toolchain adapter** | Implement `Tau.Factory.Toolchain` for Elixir: declarative recipes for `{install_deps, build, test, lint, mutation_run, package}` (wrapping `mix deps.get`/`compile --warnings-as-errors`/`test`/`credo`/`dialyzer`/`mix tau.smoke`/`release`) + report formats + resource-namespace declaration (the XDG/Burrito caches). Adapter returns **no verdict**. | Manual gating still works; adapter is invoked only by the engine harness under test. | The self-hosting language first (Q-1 measure `T_unit/T_int`). Closes the "adapter cannot fake a pass" hole (HR-3, FC-5). |
| **P2 — engine-executed gate + L (bootstrap durable store)** | Stand up `Tau.Repo` + a minimal `Ledger.Writer` (or reuse `memory/` SQLite as bootstrap backing) and the engine that revert-to-`merge-base`, runs the adapter `mutation_run`, parses with an engine-owned parser, applies `Gate.Mutation.judge/1`. Verdicts append-only (HR-2). | Claude loop still drives selection/spawn; only the *gate execution* is now the new engine, run side-by-side and diffed against the CLI gate for confidence. | First durable factory state; first engine-owned execution. INV-7/D-306; CON-6/D-335; `durable-spine.md`. |
| **P3 — single-Unit MergeAuthority** | `Tau.Factory.MergeAuthority` (concurrency 1) doing the CAS merge for **one** Unit at a time: read latest PASS verdict@hash, `--force-with-lease` push, post-merge health. No merge-train yet (`B=1`). | Claude loop selects + spawns workers; the *merge* is now the new authority. Serial, conservative. | Makes INV-1/2/3/4 structural for the merge path (D-300..303). The riskiest seam, dogfooded narrowly. `merge-and-integration.md`. |
| **P4 — Unit FSM + Scheduler + worker fleet** | `Unit` gen_statem (retry ladder, INV-19), `Scheduler`+`ConflictCheck` (INV-13), `WorkerSupervisor`+`WorkspaceJanitor` replacing the `coding_agent/` subprocess shell-out (GAP-4). | Coordinator still a thin Claude shim selecting milestone work; everything below is now supervised OTP. | Structural isolation (INV-10..15) replaces prose worktree discipline. `worker-fleet.md`, `control-plane.md`. |
| **P5 — Coordinator + kill switch + full L** | `Coordinator` gen_statem (totality/escalation, INV-18; clean kill, INV-22) + full SQLite/Exqlite L (Oban-Lite backlog) + merge-train (`B≥2`, HR-5). Retire the `/loop` Claude driver. | New factory is now self-driving; the old prose loop is decommissioned. | The strangler completes: the Claude loop is fully replaced. GAP-1 closed. |

At every phase the **old path remains runnable** until its replacement is
gate-validated against it — the strangler invariant. P0–P2 are pure additions;
P3 onward incrementally removes the Claude loop's responsibilities, narrowest
(merge) first.

---

## 7. What to explicitly DROP (and why)

| Dropped | Why | Cross-ref |
|---|---|---|
| **Context-hygiene meta-restart machinery** (3-consecutive-failure compress-to-≤1000-tokens, "do not reread mid-run", solution-tree-as-context reconstruction) | It exists *only because* the factory's state store is a context window. With durable L (SQLite/Exqlite, RPO=0), there is no volatile state to hygiene — the Coordinator resumes from L on crash (LIV-5). The whole mechanism is obviated. **Do not port it.** | GAP-1; `tau-current-analysis.md` §5.1; INV-16/D-315 |
| **Prose-enforced worktree discipline** (the entire `worktree-discipline.md` rule set as *agent-remembered MUSTs*, the 7-step stale-parent recovery, per-brief XDG reminders) | Replaced by *structural* isolation: `WorkerSupervisor` owns the complete per-worker boundary; `WorkspaceJanitor` monitor reclaims on every exit. The violated states (F-1..F-7) become unreachable, so the recovery procedure has nothing to recover. Keep the *knowledge* (it seeded the INVs); drop the *prose-as-enforcement*. | GAP-2/GAP-3; §5 table; INV-10..15 |
| **Conflation of product and factory** (one repo, one CLAUDE.md, one rule-set serving both; factory borrowing product OTP rules in prose) | The factory is now its **own** OTP application (`:tau_factory`) with its own SPEC, §3 constraints, §4 contracts, and D-NNN namespace (D-300..360). Self-hosting is the *convergence target*, not the *starting assumption* — the two are separated so the factory can be specified and supervised independently. | GAP-8; `supervision-tree.md` opening; `traceability.md` |
| **JSONL persistence as factory state** (`persistence/jsonl.ex` for the solution tree / decisions) | Too weak: not transactional, not queryable, no RPO guarantee, requires manual GitHub reconciliation. The factory uses SQLite/Ecto/Exqlite (L). JSONL may persist *product*-side; it is not a factory store. | GAP-5; §4.3; `durable-spine.md` |
| **Coding-agent subprocess shell-out as the worker substrate** (`coding_agents/claude_code` scraping stdout) | Replaced by a supervised BEAM worker fleet with structured `Port` I/O and a full isolation namespace. The subprocess `$HOME` sharing is the *source* of the F-5 cache races; removing it removes the race class. | GAP-4; §4.2; INV-10/D-309 |
| **Context-compaction as a factory mechanism** (`compactor/` driving the factory loop's memory) | A consequence of the context-as-state-store antipattern. Factory state is durable; the Coordinator does not compact a context to remember its decisions. (Compaction remains a legitimate *product* turn-loop concern.) | GAP-1/GAP-6 |
| **`Tau.Factory.Gate` as a single god-module + CLI-coupled execution** | The current `tau.gate.*` tasks couple pure decision logic to execution. Split into three pure modules + engine-owned execution (HR-3). Drop the coupling, keep the semantics. | §3; `gate-and-toolchain.md` §3 |

---

## Summary of reuse classification

Counting the §1 mapping rows (collapsing per-row dual classes to the dominant
factory-side class):

- **Direct lifts (lift / lift→adapt where the lifted artifact is unchanged):**
  ~11 — `Provider` behaviour+adapters, `Provider.Event`, `context_windows`,
  `rate_limiter`, `circuit_breaker`, `cost/tracker`, `otel_reporter`,
  `telemetry`, `message/assembler`, `permissions` engine, `settings` merge.
- **Adapt (concept kept, re-homed/reshaped):** ~6 — the three gate Mix-tasks →
  pure `Gate.*` modules, `memory/` SQLite → L backing, `cost` attribution → L,
  smoke/TUI-headless → Toolchain recipes.
- **Inspiration-only / big rewrites (mine for constraints, rewrite):** ~6 —
  the factory loop (Coordinator/Scheduler/Unit/MergeAuthority), `coding_agent/`
  → worker fleet, JSON solution-tree → durable L, `session.ex`/`cli.ex`
  monoliths, `application.ex` tree re-derivation, `.claude/rules/*` → D-NNN.
- **Explicit drops:** 7 (see §7) — led by the context-hygiene meta-restart
  machinery and prose-enforced worktree discipline.

**Recommended first dogfood seam:** the **self-hosting Elixir Toolchain adapter
+ the three pure `Gate.{AcLinkage,Masking,Mutation}` modules + a single-Unit
(`B=1`) `MergeAuthority`** (phases P0–P3). It is the smallest slice that
produces an end-to-end *gated, durable, serialized* merge on the project's own
language — exercising the highest-leverage and highest-risk seam (gate +
merge, the throughput bottleneck per `system-architecture.md` §5) while the
current Claude harness keeps running everything else.
