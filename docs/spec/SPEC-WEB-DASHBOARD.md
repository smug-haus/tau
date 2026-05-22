# SPEC: Web Dashboard

| | |
|---|---|
| **Date** | 2026-05-22 |
| **Scope** | The `:tau_web` Phoenix poncho package: endpoint lifecycle, LiveView → PubSub → session FSM boundary, `/health` liveness probe, and the D-180..D-189 runtime invariants. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); triage score 4/5. |
| **D-NNN block** | D-180..D-189 (reserved in `docs/MISSION.md`). |
| **Tracking issues** | #374 (M7 foundation — this PR), #42 (LiveView dashboard tracking), #43–#48 (individual dashboard features). |

## 0. Why this spec exists

The web dashboard (M7) runs LiveView sockets that subscribe to `Tau.PubSub`,
replays persisted session history on mount, and drives sessions via the public
`Tau` API. This combination of shared mutable state (PubSub subscriptions),
temporal coupling (mount-then-subscribe ordering, replay-then-live de-dup),
cross-process coordination (LiveView ↔ session FSM ↔ `Tau.Sessions.Registry`),
and a feedback loop (#44 drive-broadcast-driver) puts the component at a PSDH
triage score of 4/5 — above the 2/5 threshold requiring a spec before code.

The design choice to use a **poncho layout** (standalone `web/` Mix project
path-depping `:tau`) rather than an umbrella conversion is fixed for the life
of this spec. The rationale: umbrella conversion would move `lib/tau/` and
rewrite the root `mix.exs`, colliding with every in-flight M1.1 PR. The
poncho approach is 100% greenfield and parallel-safe with M1.1.

## 1. Scope

**Self-hosted, no SaaS.** The dashboard is a local web UI served by
`mix phx.server` (or, once #43 lands a CLI arm, `tau web`). It is not a
deployed service; no authentication, no multi-tenancy in the M7 scope.

**Coordination-heavy surface.** The dashboard touches five PSDH hazard
categories; the boundary contracts in §4 govern each hazard point.

**Out of scope for the M7 foundation PR (#374):** the LiveView dashboard
pages (#43–#48), the `tau web` CLI subcommand, asset compilation
(`mix assets.build`), and any multi-node or cluster concern (M9).

## 2. Architecture

**Packaging.** `:tau_web` is a standalone Mix project under `web/` in the
repository root. It path-deps `:tau` (`{:tau, path: ".."}` in `web/mix.exs`).
The root `mix.exs` and `lib/tau/` are **not touched** by any `:tau_web` PR;
the two projects are fully parallel in CI.

**Supervision.** `TauWeb.Application` starts its own OTP supervision tree.
The supervisor is named `TauWeb.Supervisor`. It MUST NOT be added to
`Tau.Application`; the Burrito binary that runs `tau` does not include the
Phoenix stack and must not be burdened with it.

**PubSub reuse.** `:tau_web` reuses the running `Tau.PubSub` process started
by `Tau.Application`. `TauWeb.Application` MUST NOT start a second
`Phoenix.PubSub` child — only one `Tau.PubSub` process exists in the BEAM
node. The endpoint is configured with `pubsub_server: Tau.PubSub`; the
`Application.get_env(:tau_web, TauWeb.Endpoint)[:pubsub_server]` returns
`Tau.PubSub` (D-184, see §4 B4 and §6).

**Endpoint.** `TauWeb.Endpoint` is the Phoenix endpoint module. The project
uses a single collapsed `TauWeb` namespace — the `_web`-suffixed app
deliberately does NOT take the double-`Web` (`TauWebWeb`) default that
`phx.new --app tau_web` would otherwise generate. It is supervised by
`TauWeb.Application`, not by `Tau.Application`.

## 3. Constraints (L0)

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **[C1-B1]** LiveView sockets subscribe to `Tau.PubSub` topics. Multiple
  sockets may subscribe simultaneously; PubSub broadcast is fan-out, not a
  write contention point. No race on subscription.
- **★ [C2-B1]** The mount-then-subscribe window. Between `mount/3` completion
  and `handle_info/2` wiring the socket subscribes; events broadcast in that
  window are lost. The replay (reading from `Tau.Persistence`) covers this
  window. The de-dup logic (D-180) prevents double-display of events present
  in both the replay and the live stream.

### Q2: What ordering is semantically critical?

- **★ [C3-B1]** Replay MUST complete before the socket subscribes. Subscribing
  before replay creates a race: live events arrive before replay is done and
  de-dup state is incomplete. The correct sequence: `Tau.Persistence.read/1` →
  apply replay events → `Phoenix.PubSub.subscribe/2` (D-181).
- **[C4-B2]** Session drive calls (via the public `Tau` API) MUST NOT bypass
  the `Tau.Session` gen_statem interface. Direct `:gen_statem.call/cast` on the
  session PID from LiveView is forbidden (D-182).

### Q3: What crosses a process boundary?

- **[C5-B1]** LiveView `handle_info/2` receives `Tau.Session.Events` structs
  broadcast over `Tau.PubSub`. These are the same structs the TUI consumes;
  the web layer MUST NOT define a parallel event format (D-183).
- **[C6-B3]** `Tau.Sessions.Registry` liveness ping is a cross-process call.
  The `/health` endpoint uses `Application.spec(:tau, :vsn)` (a pure env read,
  no process call) rather than a registry lookup to avoid flakiness in test
  (D-185).

### Q4: Are there feedback loops?

- **★ [C7-B2]** Issue #44 introduces a drive→broadcast→driver loop: the
  dashboard sends a drive command; the session FSM broadcasts an event; the
  LiveView updates the view which may emit another drive. Loop termination
  depends on the FSM reaching a terminal state (`:idle`) between drives. This
  loop is out of scope for the M7 foundation but MUST be addressed in #44's
  spec amendment to this document before #44 implementation begins.

### Q5: Is state accumulated?

- **[C8-B1]** Each LiveView socket accumulates session-event state in its
  `assigns`. This state is socket-local (no shared accumulation) and bounded
  by `Tau.Persistence`'s JSONL retention policy. The M7 foundation does not
  implement LiveView pages; this constraint is forward-looking for #43.

## 4. Boundary contracts

### B1 — LiveView ↔ Tau.PubSub (mount-replay-subscribe)

On `connected?/1 == true`:

1. Call `Tau.Persistence.read(session_id)` to get the persisted event list.
2. Apply the replay events to socket assigns.
3. Call `Phoenix.PubSub.subscribe(Tau.PubSub, topic)` to begin live stream.
4. In `handle_info/2`, de-dup incoming events against already-applied replay
   events using a monotonic event ID or timestamp cursor (D-180).

On `connected?/1 == false` (static render): skip steps 1-4; render empty or
loading state.

### B2 — LiveView → Tau session (drive-only via public API)

LiveView handlers that drive a session MUST call only the public `Tau` module
API (e.g. `Tau.send_message/2`, `Tau.cancel/1`). They MUST NOT:

- Call `:gen_statem.call/cast` on a session PID directly (D-182).
- Access `Tau.Session` internal state structs.
- Call any `Tau.Session.*` private function.

### B3 — LiveView → Tau.Sessions.Registry (liveness)

To check whether a session is alive, use:

```elixir
Tau.Sessions.Registry.lookup(session_id)
```

which returns `{:ok, pid}` or `:error`. Do NOT use `Process.whereis/1` with
a derived atom name (D-186).

### B4 — PubSub reuse (no second Phoenix.PubSub)

`:tau_web` MUST NOT start its own `Phoenix.PubSub` process. The invariant is
enforced at two levels (both are sub-points of **D-184**):

1. **Supervisor children:** `TauWeb.Application.start/2` MUST NOT
   include `{Phoenix.PubSub, …}` in its child list. `Supervisor.which_children/1`
   on `TauWeb.Supervisor` MUST return an empty list when filtered for
   `Phoenix.PubSub` children.
2. **Endpoint configuration:** `Application.get_env(:tau_web,
   TauWeb.Endpoint)[:pubsub_server]` MUST equal `Tau.PubSub`.

### B5 — Telemetry namespace

All `:tau_web`-originated telemetry events MUST use the `[:tau, :web, …]`
prefix. Examples: `[:tau, :web, :request, :start]`,
`[:tau, :web, :live_view, :mount]`. Events MUST NOT use the `[:phoenix, …]`
or `[:tau_web, …]` prefixes at the application level (D-187).

## 5. Acceptance criteria

- **AC-1 (meta)** `docs/spec/SPEC-WEB-DASHBOARD.md` lands, structured per
  §1–§6, added to `.claude/rules/spec-before-code.md`, D-block recorded in
  `docs/MISSION.md`.
- **AC-2 (meta)** `web/` poncho compiles — `cd web && mix compile
  --warnings-as-errors` exits 0; `web/mix.exs` path-deps `:tau`.
- **AC-3** `GET /health` returns HTTP 200, content-type `application/json`,
  body `{"status": "ok", "tau_version": "<v>"}` where `<v>` equals
  `to_string(Application.spec(:tau, :vsn))`. Exercised by `Phoenix.ConnTest`
  through the real `TauWeb.Router` (not a hand-built conn).
- **AC-4** `:tau_web` reuses `Tau.PubSub` and starts no second
  `Phoenix.PubSub`. Asserted by `Supervisor.which_children(TauWeb.Supervisor)`
  returning no `Phoenix.PubSub` child AND
  `Application.get_env(:tau_web, TauWeb.Endpoint)[:pubsub_server] == Tau.PubSub`.
- **AC-5 (meta)** `.gitignore` excludes `web/{_build,deps,assets/node_modules}`;
  core `lib/tau/`, root `mix.exs`, and `config/` are unchanged.

## 6. D-NNN namespace (D-180..D-189)

| D-NNN | Invariant |
|---|---|
| D-180 | LiveView mount-replay de-dup: events present in the JSONL replay AND arriving via live PubSub MUST NOT be rendered twice. De-dup cursor is a monotonic event ID or timestamp applied before subscription. |
| D-181 | Replay-before-subscribe ordering: `Tau.Persistence.read/1` MUST complete and replay events MUST be applied to assigns BEFORE `Phoenix.PubSub.subscribe/2` is called in `mount/3`. |
| D-182 | No direct gen_statem access: LiveView handlers MUST NOT call `:gen_statem.call/cast` on session PIDs. All session interaction goes through the public `Tau` module API. |
| D-183 | No parallel event format: `handle_info/2` MUST consume `Tau.Session.Events` structs as-is. `:tau_web` MUST NOT define a parallel or shadow event struct for the same events. |
| D-184 | No second PubSub / correct endpoint config: (1) `TauWeb.Application.start/2` MUST NOT include `{Phoenix.PubSub, …}` in its children — `Supervisor.which_children(TauWeb.Supervisor)` filtered for `Phoenix.PubSub` MUST return `[]`; (2) `Application.get_env(:tau_web, TauWeb.Endpoint)[:pubsub_server]` MUST equal `Tau.PubSub`. |
| D-185 | /health uses Application.spec: the `/health` controller MUST use `Application.spec(:tau, :vsn)` to obtain the `:tau` version, not a process call to `Tau.Sessions.Registry`. |
| D-186 | Registry lookup via public API: `Tau.Sessions.Registry.lookup/1` is the only permitted session-liveness probe from LiveView. `Process.whereis/1` with a derived atom is forbidden. |
| D-187 | Telemetry namespace: `:tau_web`-originated telemetry MUST use `[:tau, :web, …]` prefix. |
| D-188 | Poncho isolation: `:tau_web` MUST NOT be added to `Tau.Application`'s supervision tree. The Burrito binary MUST NOT include the Phoenix stack. |
| D-189 | reserved |

## Appendix A — PSDH triage record

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | PubSub subscription state shared across multiple LiveView sockets. No write contention but ordering matters (C2-B1). |
| 2 | Temporal coupling | 1 | Mount-replay-subscribe ordering (C3-B1); replay must complete before subscribe. |
| 3 | Cross-process coordination | 1 | LiveView ↔ PubSub ↔ session FSM ↔ Registry — multiple process hops (C5-B1, C6-B3). |
| 4 | Feedback loops | 1 | #44 drive→broadcast→driver loop (C7-B2); deferred to #44 but identified here. |
| 5 | State accumulation | 0 | Socket-local assigns; no shared accumulation in M7 scope. |

**Triage: 4/5. Spec required per `.claude/rules/spec-before-code.md`.**

## Appendix B — Source map

Files owned by this SPEC (any PR touching them must cite an AC-N or D-NNN
from this document):

| File | Owner boundary |
|---|---|
| `web/lib/tau_web/application.ex` | B4, D-184, D-188 |
| `web/lib/tau_web/endpoint.ex` | B4, D-184 |
| `web/lib/tau_web/router.ex` | AC-3 |
| `web/lib/tau_web/controllers/health_controller.ex` | AC-3, D-185 |
| `web/lib/tau_web/telemetry.ex` | B5, D-187 |
| `web/config/config.exs` | B4, D-184 |
| `web/mix.exs` | AC-2, D-188 |
| `web/test/tau_web/foundation_test.exs` | AC-3, AC-4 |
| `web/test/support/conn_case.ex` | AC-3, AC-4 |

Future LiveView files (added by #43–#48) will be added to this source map
in the corresponding spec amendment PR.
