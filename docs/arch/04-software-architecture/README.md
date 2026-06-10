# Layer 04 — Software architecture (Elixir/OTP)

The concrete mapping of the verified system shape
(`../03-system-architecture/system-architecture.md`) onto Elixir/Erlang-OTP,
following the OTP design ordering (topology and failure structure first, modules
last). The factory is its **own** supervised OTP application (`:tau_factory`),
not a prompt loop — the central correction to the current attempt.

## Reading order

1. **`supervision-tree.md`** — authoritative spine: the process gate, durability
   partition, the `rest_for_one` tree, identity/read-write split, back-pressure,
   the distribution boundary, modules last. Read this first; every other file
   references its topology.
2. **`durable-spine.md`** — L: `Ledger.Writer` + `Budget.Owner`, the Ecto schema
   (append-only verdicts = HR-2), SQLite/Exqlite store (OQ-1) with Oban-as-
   system-of-record, RPO=0 recovery, the
   deterministic-orchestrator / nondeterministic-activity split.
3. **`control-plane.md`** — K (Coordinator gen_statem, total escalation), S
   (Scheduler, the pure `ConflictCheck`, HR-4), U (per-PR gen_statem, bounded
   retry, challenge protocol).
4. **`merge-and-integration.md`** — M: the crux. The merge CAS (HR-1 + HR-2),
   sole-writer-of-`main`, the merge-train (HR-5) and its stability arithmetic.
5. **`worker-fleet.md`** — W: `DynamicSupervisor`+`Registry`, the complete
   isolation boundary, capture-before-destroy as an independent monitor, agent
   `Port` I/O. Makes the seven observed worktree failures unreachable.
6. **`gate-and-toolchain.md`** — G: bounded `Task.async_stream` fan-out, the
   three mechanical gates as pure modules, the `Toolchain` behaviour, and HR-3
   (engine owns test execution — the polyglot-critical anti-gaming fix).
7. **`governance.md`** — egress chain (rate-limiter → circuit-breaker → budget),
   policy plane + engine-clamp (HR-8), action classifier, observability, kill
   switch, reporting cadence.
8. **`traceability.md`** — keystone: every INV/CON/LIV → provisional `D-NNN` →
   enforcing module → detection test. Discharges the no-orphan-invariant
   obligation.
9. **`migration.md`** — current-repo subsystems → new components (D-S3 seam map).
10. **`distribution-readiness.md`** — the D-S4 single-node/dist-ready analysis.

## The five OTP decisions that carry the design

1. **The merge authority is a single `gen_statem` (`:idle/:integrating/:committing`) ⇒ INV-3
   holds** because at most one `:integrating` train exists at a time and the commit/push is
   serialized in the single M process — not lock discipline. It is the sole writer of
   `origin/main` and the factory's deliberate throughput bottleneck (the only place INV-1..4 hold).
2. **Supervisors recover *infrastructure*; the FSM + durable ledger recover
   *semantics*.** A crashed worker is a death certificate, not a resurrection; a
   gate FAIL is an FSM outcome, not a crash to restart. Conflating them is the
   dominant BEAM-for-agents mistake.
3. **Durable decisions, ephemeral work.** Every factory decision is WAL-committed
   before its effect is visible (RPO=0); a worker's uncommitted work is captured
   by an independent monitor (not `terminate/2`, which misses `:kill`).
4. **The toolchain adapter returns *descriptors*, the engine *executes and
   judges*** — moving the anti-gaming oracle onto the trusted side, which is what
   makes a polyglot mutation gate sound.
5. **Single-node control plane, location-transparent boundaries.** M and L are
   the consistency core that must never be naively clustered; only worker
   *execution* scales out, via an explicit queue boundary.
