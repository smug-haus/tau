# SPEC: OpenTelemetry Reporter

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-05-18 |
| **Scope** | Telemetry-to-OTel bridge: supervised process that subscribes to `[:tau, ...]` telemetry events and exports them as OpenTelemetry spans and metrics. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. |
| **Issue** | #35 (M2) |

**Changelog:** Initial draft — §0–§7 + Appendix B. D-050..D-055 introduced. C68..C78 renumbered to C69..C79 (avoid collision with SPEC-USER-TURN C68). PR2 amendments: C70 fixed-handler-id clarification; §4 B1 PR2 attach set revised (provider-request deferred to C76; optional events made config-gated, default off).

## 0. Why this spec exists

Tau emits telemetry via `:telemetry.execute/3` at every user-visible and
perf-sensitive boundary: provider requests, tool executions, hook runs,
session transitions, compaction, rate-limiter decisions, and circuit breaker
transitions. These events are consumed by `Tau.Telemetry.Handlers` today
(logging and metrics). Without an OTel export path, distributed tracing of
multi-session and multi-agent Tau workloads requires custom instrumentation
outside the codebase.

The OTel Reporter bridges the existing telemetry events to the OpenTelemetry
Protocol (OTLP), exporting spans and counters to any OTLP-compatible backend
(Jaeger, Honeycomb, OpenTelemetry Collector, etc.). It is a pure sink — it does
not change the shape of telemetry events, does not add new session state, and
does not participate in session FSM transitions.

The component is coordination-heavy (triage score 4/5; see §1) because the
reporter maintains a span-id map shared across telemetry callbacks, must handle
missing stop events (leaked spans), and must interoperate with the OTel SDK's
own process hierarchy.

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | The reporter holds an in-process map of open spans (`%{correlation_key => span_ctx}`); every `*.start` callback writes it; every `*.stop` / `*.exception` callback reads and deletes from it. The map is local to the reporter GenServer — no ETS, no shared table — but it is mutated by every telemetry callback (callbacks run in the emitter's process, so the reporter must handle concurrent delivery). |
| 2 | Temporal coupling | 1 | `*.start` must precede `*.stop`; the reporter correlates them via a key computed at attach time. If a `*.stop` arrives without a matching `*.start` the span is silently dropped; if a `*.start` has no matching `*.stop` within the sweep window it is force-finished and tagged as stale (D-053). |
| 3 | Cross-process coordination | 1 | Telemetry handlers are invoked in the emitter's process, not the reporter's. The reporter's `handle_event/4` callback is a plain function — it communicates with the GenServer via `GenServer.cast/2` to deliver span open/close operations. |
| 4 | Feedback loops | 0 | The reporter is a pure sink; no OTel export outcome feeds back into session flow. |
| 5 | State accumulation | 1 | Open spans accumulate in the reporter's map until matched or swept. Unbounded accumulation is the primary memory risk; D-053 and D-054 bound it. |

**Triage score: 4/5. L0 + boundary contracts indicated.**

## 2. Component decomposition

Three layers.

| # | Component | Role |
|---|-----------|------|
| C1 | `Tau.OtelReporter` | GenServer. Supervised. Attaches telemetry handlers on `init/1`; holds the open-span map; implements the sweep timer; detaches handlers on `terminate/2`. |
| C2 | `Tau.OtelReporter.Handler` | Pure-function module. Each `handle_event/4` callback casts a structured message to `Tau.OtelReporter`. No state. |
| C3 | `Tau.OtelReporter.Config` | Pure-function module. Reads the `:tau, :otel` application env and returns a validated config struct. No process. |

Boundaries:

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | `Tau.OtelReporter` (C1) ↔ `:telemetry` | Attach/detach handler registrations; receive callbacks via `Tau.OtelReporter.Handler.handle_event/4`. |
| B2 | `Tau.OtelReporter.Handler` (C2) → `Tau.OtelReporter` (C1) | `GenServer.cast/2` with structured `{:span_open, key, meta}` / `{:span_close, key, measurements, outcome}` messages. |
| B3 | `Tau.OtelReporter` (C1) ↔ OTel SDK | `:otel_tracer.start_span/3`, `:otel_span.end_span/1`, `:otel_span.set_status/2`, attribute setting. |
| B4 | `Tau.Application` ↔ `Tau.OtelReporter` (C1) | `child_spec/1`; conditional start gated on `otel.enabled` config flag. |

## 3. L0 constraints

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **★ [C69-B2]** Telemetry callbacks are invoked synchronously in the emitter's
  process. Multiple session turns can emit `[:tau, :tool, :execute, :start]`
  concurrently — each fires `Handler.handle_event/4` in its own process, each
  casts to the reporter. The reporter GenServer serialises all span-map mutations
  through its mailbox; the map itself is never touched from outside the GenServer.
  This is the correct isolation boundary: no ETS, no lock, no shared table.
- **[C70-B1]** The reporter MUST attach telemetry handlers with a **fixed**
  `handler_id` (`Tau.OtelReporter`, not pid-scoped). A pid-scoped id
  (e.g. `{Tau.OtelReporter, self()}`) would make the crashed instance's handler
  undetachable after restart, because the new pid cannot reconstruct the old
  pid's id. A fixed id ensures `detach_before_attach` works across supervisor
  restarts: the restarted reporter calls `:telemetry.detach(Tau.OtelReporter)`
  which genuinely removes the prior instance's handler.

### Q2: What ordering assumptions are implicit?

- **★ [C71-B2]** The correlation key for a `*.stop` event MUST be computable
  from the metadata available at `*.stop` time alone — no state from `*.start`
  may be assumed present. If a `*.start` was lost (reporter crash + restart
  between start and stop), the `*.stop` cast arrives and finds no open span; the
  reporter MUST discard it silently rather than crashing.
- **[C72-B3]** OTel span lifecycle: `:otel_tracer.start_span/3` sets the active
  span on the calling process's context. Because the reporter operates on spans
  from many different emitter processes, it MUST use explicit span contexts
  (`otel_ctx`) rather than relying on process-local active-span state. Span
  contexts are stored in the reporter's open-span map and passed explicitly to
  `:otel_span.end_span/1`.

### Q3: What happens if a component fails silently?

- **★ [C73-B1]** If a `*.stop` event never arrives (emitter crashed after
  `*.start`; a compaction path skips the stop; a cancel path fires
  `[:tau, :provider, :request, :cancelled]` instead of `[:tau, :provider,
  :request, :stop]`), the span remains open in the reporter's map indefinitely.
  D-053 mandates a sweep; D-054 caps the map size. Without both, memory grows
  unboundedly and the OTel backend sees permanently open spans.
- **[C74-B4]** If the OTel SDK is not started (deps present but `:opentelemetry`
  application not in the supervision tree), `:otel_tracer.start_span/3` raises.
  The reporter MUST guard against this at startup: if the OTel application is not
  running, the reporter logs a warning and exits with `:ignore` so the supervisor
  does not loop-restart it.
- **[C75-B2]** If the reporter GenServer is killed mid-span (supervisor restart),
  all in-flight spans are lost. The OTel backend will see spans with no
  corresponding stop. This is accepted: the supervisor restarts the reporter
  fresh; new spans from that point are correctly exported. Lost in-flight spans
  are surfaced as stale by the backend's own timeout mechanisms.

### Q4: What information crosses a boundary, and what is lost?

- **★ [C76-B1] B1 — span correlation (resolution of design defect B1).**
  A `[:tau, :provider, :request, :start]` event is keyed on `session_id`
  alone in the current telemetry metadata. This is NOT request-unique — a session
  makes many sequential provider requests. The reporter MUST use an exact
  composite key: `{:provider_request, session_id, provider, ref}` where `ref` is
  a `make_ref()` discriminator generated by the `*.start` handler at the moment
  of the cast. The handler embeds this ref in both the `{:span_open, key, attrs}`
  cast and in the open-span map value; the `*.stop` / `*.cancelled` /
  `*.brutal_kill` metadata MUST echo the same ref so the handler can reconstruct
  the identical key. **Decision: exact-composite-key with per-request `make_ref()`
  discriminator. No LIFO-within-group fallback.** The ref is unambiguous under
  concurrency — concurrent requests from the same session to the same provider
  each carry distinct refs and are correlated independently.
- **★ [C77-B1] B2 — `hook.run` correlation (resolution of design defect B2).**
  A `[:tau, :hook, :run, :start]` span keyed on `{hook_module, event}` collides
  when the same hook fires for the same event concurrently (parallel sessions,
  parallel tool dispatches). **Decision: `hook.run` span export is IN scope for
  PR2, but requires a per-invocation discriminator.** The `*.start` handler
  generates a `make_ref()` discriminator and stores `{hook_module, event, ref}`
  as the key. The `Tau.Hooks.Dispatcher` MUST be amended (in the same PR2) to
  pass the discriminator ref through the `*.stop` / `*.exception` metadata so
  the handler can correlate. This is a SPEC amendment to the dispatcher's
  telemetry contract: `[:tau, :hook, :run, :start]` metadata MUST include a
  `span_ref :: reference()` field; `*.stop` and `*.exception` MUST echo it.
- **★ [C78-B1] B3 — `tool.execute.exception` correlation (resolution of design
  defect B3).** The current `[:tau, :tool, :execute, :exception]` telemetry
  event metadata is `%{tool: name, error: message}` — it does NOT carry
  `tool_call_id`. This breaks OTel correlation: the exception span cannot be
  linked to its `[:tau, :tool, :execute, :start]` span. **This is a required
  emit-site fix for PR2:** `lib/tau/session.ex` MUST be amended to include
  `tool_call_id: call_id` in the exception metadata, consistent with the `*.start`
  and `*.stop` events.
- **[C79-B3]** OTel span attribute values MUST be primitive types (string,
  integer, float, boolean, or arrays thereof). The reporter MUST serialize
  non-primitive metadata values (e.g. `provider :: module()`, `result :: term()`)
  to strings via `inspect/1` before setting them as span attributes. No
  structured Elixir terms may be passed to the OTel SDK directly.

## 4. Boundary contracts

### B1: `Tau.OtelReporter` ↔ `:telemetry`

**Attach contract:**

- Called in `init/1`; detached in `terminate/2`.
- Handler ID: `Tau.OtelReporter` (fixed, not pid-scoped — see C70 amendment).
- Events attached in PR2 (mandatory — correlatable in this PR):
  - `[:tau, :tool, :execute, :start | :stop | :exception]` (correlates on `tool_call_id`; C78)
  - `[:tau, :hook, :run, :start | :stop | :exception]` (correlates on `span_ref`; C77)
  - `[:tau, :session, :stop]` (point event)
  - `[:tau, :circuit_breaker, :transition]` (point event)
- **Deferred to C76 (PR3):**
  - `[:tau, :provider, :request, :start | :stop | :cancelled | :brutal_kill]` — the
    emit site does not yet echo a `span_ref` through `*.stop`; attaching in PR2 would
    leak every provider span. Attach when C76 emit-site amendment lands.
- Optional events (configurable via `Config`; **default off** — SPEC §4 B1):
  - `[:tau, :mcp, :rpc, :start | :stop]` — enabled by `otel.mcp_spans_enabled: true`
  - `[:tau, :compaction, :start | :stop]` — enabled by `otel.compaction_spans_enabled: true`
  - `[:tau, :permissions, :decision]` — enabled by `otel.permissions_spans_enabled: true`
  - Note: MCP and compaction emit sites do not yet carry `span_ref`; when enabled,
    spans will leak until their emit sites are amended. The config flag is an explicit
    operator opt-in acknowledging this.

**Handler callback:**

- `Tau.OtelReporter.Handler.handle_event(event, measurements, metadata, config)`
- Runs in the emitter's process. MUST be fast and non-blocking.
- Casts `{:span_open, key, attrs}` or `{:span_close, key, measurements, outcome}`
  to the reporter GenServer.
- MUST NOT raise; wraps in `rescue` → logs warning → returns `:ok`.

### B2: `Tau.OtelReporter.Handler` → `Tau.OtelReporter`

**Cast messages (binding):**

```
{:span_open, correlation_key :: term(), attrs :: map()}
{:span_close, correlation_key :: term(), duration_native :: integer(), outcome :: :ok | :error | :exception}
```

- `correlation_key` is a term computed from event metadata; type and format are
  event-specific (see §3 C76/C77).
- `attrs` is a plain map of string → primitive; safe for OTel attribute setting.

### B3: `Tau.OtelReporter` ↔ OTel SDK

- All OTel calls go through `:opentelemetry_api` (`OpenTelemetry` Elixir
  wrappers or raw `:otel_tracer` / `:otel_span` Erlang modules).
- Span contexts (`otel_ctx()`) are stored in the reporter's open-span map and
  are NOT shared across processes.
- Span names follow the pattern `"tau.<subsystem>.<operation>"`, e.g.
  `"tau.provider.request"`, `"tau.tool.execute"`.

### B4: `Tau.Application` ↔ `Tau.OtelReporter`

- `Tau.OtelReporter` is added to the supervision tree in `Tau.Application`
  only when `Application.get_env(:tau, :otel, []) |> Keyword.get(:enabled, false)` is `true`.
- The reporter's `init/1` additionally checks that `:opentelemetry` is running
  (`Application.started_applications/0`); if not, returns `{:stop, :otel_not_started}`.
- Child spec: `{Tau.OtelReporter, []}` with default restart `:permanent`.

## 5. State enumeration

The reporter GenServer holds:

| Field | Type | Purpose |
|-------|------|---------|
| `open_spans` | `%{term() => {span_ctx :: term(), opened_at_mono :: integer()}}` | In-flight spans awaiting `*.stop`. |
| `config` | `%Tau.OtelReporter.Config{}` | Validated config snapshot from `init/1`. |
| `sweep_timer` | `reference()` | Timer ref for the stale-span sweep (D-053). |

State transitions:

| Event | Transition |
|-------|-----------|
| `{:span_open, key, attrs}` cast | Insert `{span_ctx, monotonic_time}` into `open_spans`. If `map_size(open_spans) >= max_open_spans`, evict the entry with the smallest `opened_at_mono` (oldest-first eviction; D-054). |
| `{:span_close, key, duration, outcome}` cast | Look up `key` in `open_spans`; if found, end span with duration + outcome, delete from map. If not found, discard. |
| `:sweep` message | Scan `open_spans`; end any span older than `sweep_age_ms` with status `stale`; delete from map. Reset timer. |
| `terminate/2` | Detach telemetry handlers. End all open spans with status `terminated`. |

## 6. Invariants (D-NNN)

| D-NNN | Statement |
|-------|-----------|
| **D-050** | `Tau.OtelReporter` MUST run as a supervised GenServer under `Tau.Application`. It MUST NOT be started outside the supervision tree. Telemetry handlers are attached in `init/1` and detached in `terminate/2`; no handler attachment happens at module load time. |
| **D-051** | The reporter MUST NOT mutate the open-span map from any process other than the reporter GenServer itself. All telemetry callbacks communicate via `GenServer.cast/2`. The open-span map is private state. |
| **D-052** | Every `[:tau, :tool, :execute, :exception]` event MUST carry `tool_call_id` in its metadata so the exception span correlates to its `*.start` span. The emit site in `lib/tau/session.ex` is amended in PR2 (C78). |
| **D-053** | **Stale-span sweep.** The reporter MUST sweep open spans on a configurable interval (`otel.sweep_interval_ms`, default 60_000). Any span open longer than `otel.sweep_age_ms` (default 120_000) is force-finished with OTel status `ERROR` and attribute `tau.span.stale = true`. The sweep MUST run even when no new events arrive. |
| **D-054** | **Bounded memory.** The `open_spans` map MUST NOT exceed `otel.max_open_spans` entries (default 1_000). When the limit is reached, the oldest entry (by `opened_at_mono`) is evicted before inserting a new one. Evicted spans are force-finished with attribute `tau.span.evicted = true`. |
| **D-055** | The OTel deps (`:opentelemetry_api`, `:opentelemetry`, `:opentelemetry_exporter`) MUST be declared `optional: true` in `mix.exs`. A build that does not include them MUST compile cleanly. The reporter module MUST use `Code.ensure_loaded?/1` guards on OTel module references so compilation succeeds without the deps. |

## 7. Deployment target

The OTel reporter is **optional in all environments** — dev, test, and Burrito
release. It is not started unless `otel.enabled: true` is set in application
config. The OTel dependencies are declared `optional: true` (D-055).

Note: `optional: true` relaxes the dependency requirement for **downstream
consumers** of `tau` — it does NOT exclude the deps from `tau`'s own build. Hex
still fetches and compiles `:opentelemetry_api`, `:opentelemetry`,
`:opentelemetry_exporter`, and their transitive deps (`:grpcbox`, `:gproc`, etc.)
in any `tau` build. Whether these deps are compiled into the Burrito release
binary is a PR2 concern; PR1 declares them optional only and does not implement
release-exclusion.

For operators who want OTel in the release binary: set the environment variable
`MIX_OTEL=1` at build time; `mix.exs` will conditionally include the OTel apps
in `extra_applications` when this var is set. This mechanism is wired in PR2.

Test environments: the reporter is not started in `:test` (no `otel.enabled`
key in `config/test.exs`); telemetry handler attachment does not occur;
existing tests are unaffected.

## Appendix A: Acceptance criteria

- **AC-1 (PR1):** `mix compile --warnings-as-errors` passes with OTel deps
  added as `optional: true`. `mix test` passes with no OTel application running.
- **AC-2 (PR1):** `Tau.Settings.Schema.json_schema/0` includes an `"otel"`
  top-level key with `enabled`, `endpoint`, `headers`, `sampling_ratio`,
  `max_open_spans`, `sweep_interval_ms`, `sweep_age_ms` properties.
- **AC-3 (PR2):** `Tau.OtelReporter` starts under `Tau.Application` when
  `otel.enabled: true` is set; `mix test` passes.
- **AC-4 (PR2):** Property test: for any sequence of `span_open` / `span_close`
  casts, `map_size(open_spans)` never exceeds `max_open_spans` (D-054).
- **AC-5 (PR2):** Property test: after a sweep with `sweep_age_ms = 0`, all
  entries in `open_spans` have `opened_at_mono >= sweep_start` (D-053).
- **AC-6 (PR2):** `[:tau, :tool, :execute, :exception]` telemetry metadata
  includes `tool_call_id` (D-052 / C78).

## Appendix B: Source-map (files in scope of this SPEC)

Any PR touching the following files MUST name the AC-N or D-NNN it advances:

- `lib/tau/otel_reporter.ex` — C1 GenServer
- `lib/tau/otel_reporter/handler.ex` — C2 handler
- `lib/tau/otel_reporter/config.ex` — C3 config
- `lib/tau/settings/schema.ex` — OTel settings schema addition
- `config/runtime.exs` — OTel runtime config reading
- `lib/tau/application.ex` — conditional supervisor child
- `lib/tau/session.ex` (tool.execute.exception metadata only) — D-052
- `lib/tau/hooks/dispatcher.ex` (span_ref discriminator only) — C77
- `mix.exs` (OTel optional deps only)
- `test/tau/otel_reporter/` — all test files
