# Spec-Before-Code Rule

Coordination-heavy components (PSDH triage score >= 2) MUST have a written
specification under `docs/spec/SPEC-*.md` before any implementation PR is opened
that modifies their behaviour.

## What counts as coordination-heavy

A component is coordination-heavy when it scores >= 2 on the PSDH triage
checklist (`.claude/skills/design-reasoning`). Concretely: shared mutable state,
temporal coupling, cross-process coordination, feedback loops, or state
accumulation. Single-process pure functions and CRUD endpoints do NOT need a
spec.

The current spec catalog:

- `docs/spec/SPEC-TUI-HEADLESS.md` — M1.1 TUI behaviour + UX testing protocol.
  Re-chartered from a test-harness spec (2026-05-04) to the full M1.1 UX surface
  (2026-05-21). Mandatory for any PR touching `lib/tau/tui/` (all files),
  `lib/tau/tui/app.ex`, `lib/tau/tui/input_editor.ex`,
  `lib/tau/tui/sub_agent_panel.ex`, `lib/tau/tui/status_bar.ex`,
  `lib/tau/tui/theme.ex`, `lib/tau/tui/keybindings.ex`,
  `lib/tau/provider.ex` (the `context_window/1` callback),
  `lib/tau/provider/context_windows.ex` (the `ContextWindows` lookup table),
  `test/support/tui_pty_helper.ex`, or `test/tau/cli/tui_smoke_test.exs` /
  `test/tau/cli/tui_ux_test.exs`. Triage score 5/5; D-066..D-075 live here.
  D-160..D-169 (status surface, #340) also live here.
  Spec home for M1.1 child issues #335, #338, #340, #345.

- `docs/spec/SPEC-USER-TURN.md` — the binary launch → TUI → session FSM →
  provider stream → render loop. Mandatory for any PR touching `lib/tau/cli.ex`,
  `lib/tau/tui/`, `lib/tau/session.ex`, `lib/tau/application.ex`,
  `lib/tau/providers/*` (in their `stream/3` callback), or
  `lib/tau/settings/cache.ex`.

  **Dual-gating note (`lib/tau/tui/`):** both SPEC-TUI-HEADLESS and
  SPEC-USER-TURN list `lib/tau/tui/` as mandatory scope. Ownership is
  divided by contract layer: SPEC-USER-TURN owns the session-FSM and
  turn-loop contracts that surface in `lib/tau/tui/`; SPEC-TUI-HEADLESS
  owns the UX, render, and input-behaviour contracts. A TUI PR cites the
  AC/D-NNN of whichever SPEC owns the contract it changes.

- `docs/spec/SPEC-CODING-AGENT.md` — the coding-agent adapter substrate
  (subprocess sub-agents driven by `Tau.CodingAgent` + dispatcher).
  Mandatory for any PR touching `lib/tau/coding_agent.ex`,
  `lib/tau/coding_agent/`, `lib/tau/coding_agents/`, `lib/tau/cli.ex`
  (the `--coding-agent` flag), `lib/tau/cost.ex` /
  `lib/tau/cost/tracker.ex` (D-038 adapter-tagged line items), or
  `lib/tau/tools/builtin/delegate.ex` (Phase 2; D-039). Triage score
  4/5; D-031..D-039 live here.

- `docs/spec/SPEC-CIRCUIT-BREAKER.md` — the per-provider circuit breaker:
  `:closed/:open/:half_open` state machine, ETS-owner lifecycle anchor
  (`Tau.CircuitBreaker.Store`), and `Tau.CircuitBreaker` façade.
  Mandatory for any PR touching `lib/tau/circuit_breaker.ex`,
  `lib/tau/circuit_breaker/state.ex`, `lib/tau/circuit_breaker/store.ex`,
  `test/tau/circuit_breaker/`, or the supervision-tree entry for `Store`
  in `lib/tau/application.ex`. Triage score 5/5; D-029, D-030, D-043,
  D-044 live here.

- `docs/spec/SPEC-MEMORY-STORE.md` — the persistent memory store (SQLite via
  Exqlite; write/delete in PR1, FTS5 search in PR2, sqlite-vec semantic search
  in PR3). Mandatory for any PR touching `lib/tau/memory/store.ex`,
  `lib/tau/memory/store/sqlite.ex`, `lib/tau/memory/migrations.ex`,
  `lib/tau/memory/supervisor.ex`, or the `Tau.Memory.Supervisor` entry in
  `lib/tau/application.ex`. Triage score 3/5; D-045, D-046, D-047 live here.

- `docs/spec/SPEC-OTEL-REPORTER.md` — the OpenTelemetry reporter: supervised
  GenServer that subscribes to `[:tau, ...]` telemetry events and exports spans
  and metrics via OTLP. Mandatory for any PR touching `lib/tau/otel_reporter.ex`,
  `lib/tau/otel_reporter/`, `config/runtime.exs` (the `otel` block),
  `lib/tau/settings/schema.ex` (the `"otel"` property), or the
  `Tau.OtelReporter` entry in `lib/tau/application.ex`. Triage score 4/5;
  D-050..D-055 live here.

- `docs/spec/SPEC-PROMPT-CACHING.md` — provider prompt caching: the
  `Tau.Provider` behaviour extension (`cache_regions/2`; `prepare_cache/3`
  deferred until Gemini is scoped) plus the B3 cache-usage normalisation
  contract (each adapter's `merge_usage` emits canonical `cache_read` /
  `cache_write` keys), mapping a Tau-side "stable regions" policy onto each
  provider's caching mechanism (six families across nine providers).
  Mandatory for any PR touching `lib/tau/provider.ex` (the new callback),
  `lib/tau/providers/anthropic.ex` (`build_body/3` cache-marker injection),
  `lib/tau/providers/bedrock.ex` (Family A — `cachePoint`/`cache_control`),
  `lib/tau/providers/gemini.ex` (Family D — `cachedContent` resource
  lifecycle, deferred), `lib/tau/providers/mistral.ex` (Family E —
  `prompt_cache_key`), or any new adapter that needs to declare caching
  behaviour. Triage score 3/5; D-063..D-065 live here.

- `docs/spec/SPEC-PERMISSION-PROMPTS.md` — interactive permission prompts for
  `:ask`-verdict tool calls; the `:awaiting_permission` FSM state; non-interactive
  fail-closed `:deny` resolution; the `interactive?` session property; the
  `decide_permission/3` and `set_permissions_mode/2` public API.
  Mandatory for any PR touching `lib/tau/session.ex` (the permission gate in
  `dispatch_tools/2` or the `:awaiting_permission` state), `lib/tau/session/events.ex`
  (the `%PermissionRequest{}` struct), or `lib/tau/cli.ex` (the `interactive:` opt in
  `run_cmd/1`). Also mandatory for PR-B (TUI approval dialog / `Shift+Tab` cycle /
  status-bar indicator). Triage score 4/5; D-090..D-099 live here.

- `docs/spec/SPEC-TUI-COMPLETION.md` — the TUI completion sub-state machine:
  slash-command autocomplete (#333) and `@`-mention autocomplete (#344 — adds its
  source later). Covers `Tau.TUI.Fuzzy`, `Tau.Commands.Catalog`, the
  `CommandCatalog` PubSub event, the MVU menu sub-state in `Tau.TUI.App`, the
  unknown-command guard in `classify_slash_command/2`, and the `/help` builtin.
  Mandatory for any PR touching `lib/tau/tui/fuzzy.ex`,
  `lib/tau/commands/catalog.ex`, `lib/tau/commands/builtin/help.ex`,
  `lib/tau/session/events.ex` (the `CommandCatalog` struct), or
  `lib/tau/tui/app.ex` (the `menu` model field or `catalog` model field).
  Triage score 2/5; D-100..D-109 live here.

- `docs/spec/SPEC-EXTENSIONS.md` — the extension subsystem:
  `Tau.Extension` behaviour + DSL, `Tau.Extensions.Loader` (supervised
  GenServer; compile/register/hot-reload), `tau extensions list|reload`
  CLI handlers, auto-discovery of `~/.tau/extensions/` and
  `<cwd>/.tau/extensions/`. Mandatory for any PR touching
  `lib/tau/extension.ex`, `lib/tau/extensions/loader.ex`,
  `lib/tau/cli/extensions.ex`, `lib/tau/settings/schema.ex` (extensions
  property only), `lib/tau/application.ex` (Extensions.Loader entry only),
  `test/tau/extensions/`, `test/tau/cli/extensions_test.exs`,
  `test/tau/extension_skill_validation_test.exs`, or
  `test/support/extensions/`. Triage score 4/5; D-120..D-129 live here.
  Spec home for #180 (Stage A) and Stage B (#337, #345 — deferred surfaces).

Future SPECs land here as new components reach triage threshold.

## What this rule requires

A PR is in scope of a SPEC if it touches any file the SPEC's source-map (Appendix B
in each spec) names, OR it changes a boundary contract (§4 in each spec), OR it
introduces new state at any boundary the spec lists.

For an in-scope PR, the description MUST state:

1. **Which acceptance criterion (AC-N) the PR advances**, or which D-xxx
   invariant it enforces, or both.
2. **Whether any new constraint surfaced** during implementation that should
   be added to §3 of the SPEC. Adding a constraint is a spec amendment, not a
   silent slip; the amendment lives in the same PR.

Out-of-scope PRs (typo fixes, dependency bumps, formatting) need not reference
the SPEC.

## What this rule forbids

- MUST NOT merge a PR that adds new state to a SPEC'd boundary without a
  corresponding §3 entry and §4 contract update in the same PR.
- MUST NOT implement an acceptance criterion without a property test or unit
  test that fails before the change and passes after. The "binary smoke" tests
  named in AC-5 (e.g. `test/tau/cli/binary_smoke_test.exs`) are a CI-level
  blocking gate; do not bypass.
- MUST NOT close an issue that is referenced as "closes a constraint" without
  the corresponding D-xxx invariant landing as enforcement.

## Critic / reviewer gate amendment

Both gates' review prompts are extended to ask:

- **Critic (pre-impl):** "Does the planned change touch any file in
  `docs/spec/SPEC-*.md` Appendix B? If yes, which AC-N or D-xxx does it
  advance? Does the plan amend the spec where new constraints surfaced?"
- **Reviewer (post-impl):** "Does the PR description name the AC-N / D-xxx?
  Are spec amendments (if any) in this PR or absent? Does the new test cover
  the listed criterion?"

A PR that fails either question receives a FAIL verdict regardless of code
quality.

## When to update this rule

When a new SPEC enters the catalog, list it under "the current spec catalog"
above. When a SPEC is retired (component dropped, refactored away), remove it
and amend the source-map references in any consuming PRs.

## Why this exists

Three days of activity (May 1-3 2026) produced 110 commits and a non-functional
TUI. The diagnosis on file (memory: `project_state_2026_05_03_evening.md`)
attributes this to an absence of plan-of-record and a review gate tuned for
local OTP correctness rather than product behaviour. This rule converts the
PSDH method into an enforced gate, applied to the components where the method
yields the most.
