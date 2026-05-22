# SPEC-EXTENSIONS — Extension API

**Status:** Active
**Version:** 1.0
**Date:** 2026-05-22
**PRs:** Stage A (#365 / #180)

---

## §0 Why

Tau's built-in tools, hooks, slash commands, and skills cover the harness
substrate. Third-party workflows that want to add tools or hooks without
modifying the core codebase need a stable extension point. The extension
subsystem ships this without requiring `mix` at runtime (Burrito binary
constraint) and without sandboxing (trusted-author posture, Stage A).

ADR-0022 records the key decisions: behaviour-based DSL, synchronous
`init/1` load, crash-proof registration, git-URL distribution.

---

## §1 PSDH Triage — Score 4/5

| Property | Present? | Rationale |
|---|---|---|
| **P** — shared mutable state | Yes | Four registries (Tools, Hooks, Commands, Skills) mutated by the Loader |
| **S** — temporal ordering constraints | Yes | Extensions must be registered before Sessions.Supervisor starts |
| **D** — cross-process data flow | Yes | Loader is a GenServer; registries are separate processes |
| **H** — hard real-time constraints | No | No latency SLA on extension load |

Score 4/5. The "feedback loops" property does NOT hold: an extension hook
firing on its own tool call is re-entrancy, not a state-coupled loop. Spec
is mandatory under `spec-before-code.md`.

---

## §2 Components

```
Tau.Extension                 ── Behaviour + DSL (`use Tau.Extension`)
Tau.Extension.DSL             ── Macros: tool/1, hook/2, command/2, skill/2
Tau.Extensions.Loader         ── GenServer; owns loaded-extension map;
                                  compiles, registers, hot-reloads extensions
Tau.CLI.Extensions            ── `tau extensions list|reload` CLI handlers

Four registries (owned by Tau.Registries):
  Tau.Tools.Registry          ── :duplicate, keyed by tool public name
  Tau.Hooks.Registry          ── :duplicate, keyed by event atom
  Tau.Commands.Registry       ── :unique, keyed by slash-command string
  Tau.Skills.Registry         ── :unique, keyed by skill name
```

**Stage A scope:** behaviour + DSL, Loader (compile/register/reload),
CLI handlers, crash-proof registration, synchronous `init/1` load,
auto-discovery of `~/.tau/extensions/` and `<cwd>/.tau/extensions/`,
hot-reload `unload`-before-`load`, schema reconciliation.

---

## §3 Constraints (L0)

### Registration constraints

**C-001** — `register_module/1` and every per-callback invocation
(`mod.tools/0`, `mod.hooks/0`, `mod.commands/0`, `mod.skills/0`) are
wrapped in `try/rescue`. A callback that raises is logged at `:warning`
level, telemetered via `[:tau, :extensions, :load, :exception]`, and
skipped. It MUST NOT crash the Loader process or propagate to the
supervisor.

**C-002 — OTP #7 exemption:** wrapping `register_module/1` in
`try/rescue` is OTP-idiomatic for this surface. The "process you would
otherwise isolate the untrusted code behind" does not exist — tools are
stateless modules, not processes. The standard OTP boundary (spawn +
monitor) is inapplicable to synchronous, stateless module dispatch. This
exemption is explicit and intentional; the reviewer gate MUST NOT flag
it as a violation of otp-non-negotiable #7.

**C-003** — A crash inside `init/1` during extension load (after AC-3
wrap is applied) MUST NOT propagate as `{:stop, reason}` from `init/1`.
The Loader catches the error and logs + skips the failing extension,
then returns `{:ok, state}`. A Loader crash in `init/1` is strictly
worse than today's deferred-load crash because it becomes a
`max_restarts` → application-boot-failure cascade under `:rest_for_one`.

### Load-ordering constraints

**C-004** — Extensions are loaded synchronously inside `Loader.init/1`,
not via a deferred self-message. This is a structural `:rest_for_one`
guarantee: `Sessions.Supervisor` (the last child) cannot start until the
Loader reports `{:ok, state}`, so extension tools are always visible to
sessions.

**C-005** — `Loader.init/1` MUST call `Tau.Settings.Cache.get/0` to
obtain the `extensions` list. `Settings.Cache` starts before the Loader
in the `:rest_for_one` tree (position 4 vs 10); the call is safe.

### Auto-discovery constraints

**C-006** — Auto-discovery scans `~/.tau/extensions/` then
`<cwd>/.tau/extensions/` in that order (global before local, matching
`Tau.Skills.Loader.discover/1` precedence). An explicit
`settings.extensions` entry overrides discovery for that specific entry;
discovery supplements, not replaces.

**C-007** — A module-name collision across two discovered directories is
a silent BEAM module-table clobber (last `Code.compile_file/1` wins).
The guard extracts declared module names from the source text via
`String.to_atom/1` (not `String.to_existing_atom/1` — the latter silently
drops names for modules not yet compiled, defeating the guard for brand-new
modules) and checks via `Code.ensure_loaded?/1` BEFORE `Code.compile_file/1`.
If a collision is detected, the later file is skipped with a `:warning` log;
`Enum.uniq_by` after compilation is insufficient.

### Hot-reload constraints

**C-008** — `reload/1` MUST unregister the prior generation from all
four registries before registering the new one. `Registry.unregister/2`
is keyed by calling process — the Loader registered the entries, so the
Loader must unregister them. Omitting unload leaves stale tool/command
generations in the registry alongside the new ones.

**C-009** — `Registry.unregister/2` only removes entries owned by the
calling process. Extension entries registered by the Loader are owned by
the Loader pid. Unregistration from `Tau.Tools.Registry` (`:duplicate`)
uses `Registry.unregister_match/4` to remove only the Loader's entries
for the given module's tool name.

### Schema constraints

**C-010** — `settings.extensions` in `lib/tau/settings/schema.ex` is
`array of strings`. The Loader MUST NOT accept `{module, opts}` tuples
from settings-validated input — this form is unreachable through the
schema validator. The `{module, opts}` branch in `load_entry/1` is
retained as a programmatic API (for test injection), but the schema must
be consistent with what the Loader actually handles from settings.

### Distribution constraints

**C-011** — Extensions are distributed as git repositories or local
directories, not Hex packages. `Code.compile_file/1` compiles `.ex`
sources at runtime. `mix` tasks are NOT available in the Burrito binary.

### Namespace constraints

**C-012** — Extension modules SHOULD be namespaced under the extension
author's reverse-domain or project name (e.g.
`MyOrg.Extensions.SearchTool`). Flat names (e.g. `SearchTool`) risk
collisions with Tau internals. This is a convention, not enforcement.

---

## §4 Boundary Contracts

### Extension ↔ Loader

An extension module implements `Tau.Extension`:

```elixir
@callback tools()    :: [module()]
@callback hooks()    :: [{Tau.Hook.event(), module()}]
@callback commands() :: [{String.t(), module()}]
@callback skills()   :: [{String.t(), Path.t()}]
```

The DSL (`use Tau.Extension`) generates these via `@before_compile`
from accumulated module attributes. Each callback MUST be infallible at
the `Tau.Extension` level; exceptions are caught by the Loader
(`C-001`).

A module is identified as an extension via:

```elixir
Code.ensure_loaded?(mod) and
  function_exported?(mod, :tools, 0) and
  function_exported?(mod, :hooks, 0)
```

### Loader ↔ Tools Registry

```
Tau.Tool.register(mod :: module()) :: {:ok, pid()} | {:error, term()}
```

Registers under `Tau.Tools.Registry` (`:duplicate`) with key
`mod.name()`. The Loader is the calling process; entries are
Loader-owned. On reload: `Registry.unregister_match/4` removes the
Loader's prior entry for that tool name before re-registering.

### Loader ↔ Hooks Registry

```
Registry.register(Tau.Hooks.Registry, event :: atom(), handler :: module())
```

Registers under `Tau.Hooks.Registry` (`:duplicate`) with key `event`.
On reload: `Registry.unregister/2` removes ALL of the Loader's hook
entries for the reloaded extension before re-registering.

### Loader ↔ Commands Registry

```
Registry.register(Tau.Commands.Registry, name :: String.t(), mod :: module())
```

Registers under `Tau.Commands.Registry` (`:unique`) with key `name`.
On reload: `Registry.unregister/2` removes the Loader's entry for the
command name before re-registering.

### Loader ↔ Skills Registry

```
Registry.register(Tau.Skills.Registry, name :: String.t(), %Tau.Skill{})
```

Registers under `Tau.Skills.Registry` (`:unique`) with key `name`.
Skills are parsed at registration time via `Tau.Skills.Loader.parse/1`.
A bad skill path is logged + skipped (not fatal). On reload:
`Registry.unregister/2` removes the Loader's entry before re-registering.

### Loader ↔ Settings.Cache

```
Tau.Settings.Cache.get() :: map()
```

Called synchronously in `Loader.init/1` and in `handle_cast(:reload_all)`
to obtain the `extensions` key. `Settings.Cache` is guaranteed to be
started before the Loader in the `:rest_for_one` tree (C-005).

### Loader ↔ Hooks Dispatcher — `:pre_tool_use` payload contract

Extension hook handlers receive a payload built by `Tau.Session.hook_payload/3`.
The canonical fields are documented in `Tau.Hook` (Phase-10 base fields:
`:session_id`, `:cwd`, `:permission_mode`, `:hook_event_name`, `:transcript_path`,
`:metadata`).

For `:pre_tool_use`, the event-specific fields are (f-4):

```elixir
%{
  tool_name:    String.t(),   # public tool name, e.g. "hello_world"
  tool_call_id: String.t(),   # unique ID for the call within the turn
  tool_input:   map()         # decoded arguments map
}
```

Extension hooks matching on `:pre_tool_use` MUST pattern-match at minimum
`:tool_name` and MAY inspect the other fields. This contract is stable for
Stage A; Stage B may extend but not remove keys.

---

## §5 Telemetry

Every extension load attempt emits a `[:tau, :extensions, :load]` span:

```elixir
# on load start:
:telemetry.execute(
  [:tau, :extensions, :load, :start],
  %{system_time: System.system_time()},
  %{entry: entry}
)

# on success (result: :ok):
:telemetry.execute(
  [:tau, :extensions, :load, :stop],
  %{duration: duration},
  %{entry: entry, result: :ok, modules: [mod]}
)

# on non-raise skip (module does not implement Tau.Extension; result: :skipped):
:telemetry.execute(
  [:tau, :extensions, :load, :stop],
  %{duration: duration},
  %{entry: entry, result: :skipped, skipped: true}
)

# on extension callback crash:
:telemetry.execute(
  [:tau, :extensions, :load, :exception],
  %{duration: duration},
  %{entry: entry, kind: kind, reason: reason, stacktrace: stacktrace}
)
```

The `result:` key in `*.stop` disambiguates `:ok` (extension loaded and
registered) from `:skipped` (module present but not a `Tau.Extension`).
Consumers counting successful loads MUST filter on `result: :ok`. The
`skipped: true` key is retained for backwards compatibility — f-6.

Reload events emit `[:tau, :extensions, :reloaded]` as before.

---

## §6 D-NNN Invariants

**D-120** — Every invocation of `register_module/1` and every per-callback
call (`mod.tools/0`, `mod.hooks/0`, `mod.commands/0`, `mod.skills/0`) is
wrapped in `try/rescue`. A failing extension is logged, telemetered, and
skipped. It MUST NOT crash the `Tau.Extensions.Loader` process.

**D-121** — Extension load runs synchronously in `Tau.Extensions.Loader.init/1`.
The Loader MUST NOT defer load via a self-message. Sessions may assume
extension tools are registered before `Tau.Sessions.Supervisor` starts.

**D-122** — `Tau.Extensions.Loader.init/1` MUST return `{:ok, state}` even if
every configured extension fails to load. The Loader is never the source of a
`:max_restarts` boot-failure cascade. Two sources can propagate a crash from
`init/1`: `Settings.Cache.get/0` failing (deeper startup ordering bug) and
`File.cwd/0` failing (OS-level cwd error). The Loader guards both: `Settings.Cache`
is an upstream dependency — its failure is intentional propagation; `File.cwd/0`
(non-raising form; f-5) is used in `discover_extension_dirs/0` so a missing cwd
produces an empty discovery list rather than a raised exception.

**D-123** — Auto-discovery scans `~/.tau/extensions/` then
`<cwd>/.tau/extensions/`. Module names are extracted from source text via
`String.to_atom/1` (not `String.to_existing_atom/1`, which silently drops
names for brand-new modules). Collision is detected via `Code.ensure_loaded?/1`
BEFORE `Code.compile_file/1`. The later file is skipped with a `:warning` log.
`Enum.uniq_by` after compilation is insufficient because BEAM already has the
clobbered module in the table.

**D-124** — `reload/1` calls `unload/1` for the prior generation of the
extension before registering the new one. The prior generation's entries
in all four registries are removed. Registry unregistration is performed
by the Loader process (the same process that registered the entries).

**D-125** — `settings.extensions` is `array of strings`. The Loader's
`{module, opts}` branch is a programmatic API, not reachable from
settings-validated input. The schema and the Loader's settings-driven
code path are consistent.

**D-126** — The `[:tau, :extensions, :load]` telemetry span is emitted
as `*.start` / `*.stop` / `*.exception` per OTP non-negotiable #5. The
load-failed path emits `*.exception`.

**D-127** — Extension tools registered by the Loader resolve via
`Tau.Tool.lookup/1` in the same way as built-in tools. The Loader's
registration uses `Tau.Tool.register/1`, not raw `Registry.register/3`.

**D-128** — Skill paths declared by an extension are parsed at
registration time via `Tau.Skills.Loader.parse/1`. A bad path is logged
and skipped; it does not prevent the extension's tools, hooks, or
commands from registering.

**D-129** — The `Tau.Extension` behaviour is the sole extensibility seam
for bundling tools/hooks/commands/skills. String-keyed dispatch and
ad-hoc module injection bypass this seam and are forbidden.

---

## §7 Acceptance Criteria

**AC-1** This SPEC lands, structured per the §1 outline, added to the
`spec-before-code.md` catalog, D-120..D-129 in §6.

**AC-2** ADR-0022 lands in the same PR.

**AC-3** `register_module/1` and every per-callback invocation are
crash-isolated: a test extension whose `tools/0` raises is logged,
telemetered, and skipped; **the application boots successfully** with that
extension present; `mix test` proves no `:rest_for_one` cascade.

**AC-4** Extension load runs synchronously in `Loader.init/1`; a headless
`Tau.CLI.main(["run", ...])` invoked immediately at boot sees an
extension-registered tool. Lands only with AC-3.

**AC-5** Auto-discovery of `~/.tau/extensions/` and
`<cwd>/.tau/extensions/` with `Skills.Loader`-equivalent precedence and a
pre-compile module-collision guard.

**AC-6** Reload unregisters the prior generation before registering the
new — no stale tool version left in `Tau.Tool` lookup.

**AC-7** Reference extension `test/support/extensions/hello_world_ext/`
exercising tool + hook + command + skill.

**AC-8** Integration test: a session loads with the reference extension;
its tool dispatches via the real session path; its slash command resolves
via `Tau.Command`; its `:pre_tool_use` hook fires.

**AC-9** `settings.extensions` schema reconciled with the loader.

**AC-10** `mix compile --warnings-as-errors`, `mix format --check-formatted`,
`mix credo --strict`, full `mix test` green.

---

## §8 Out of Scope (Stage B and beyond)

The following surfaces are explicitly deferred. Do NOT draft §4 contracts
for these; they are named here so they are not accidentally implemented
in Stage A PRs.

- **Extension process callback** — an optional `init/1` callback that
  the Loader would start under a `DynamicSupervisor`, giving extensions a
  supervised process of their own. Depends on #337 (renderer contract)
  and #345 (keybinding surface) for lifecycle integration.
- **`Tau.Extensions.Supervisor` DynamicSupervisor** — the supervised
  container for extension processes. Stage B.
- **`keybindings/0` callback** — extension-provided keybinding
  contributions to the TUI. Depends on #345.
- **`ui_elements/0` callback** — extension-provided TUI panel
  contributions. Depends on #337.
- **`tau extensions install <git-url>`** — fetch + compile a remote
  extension at runtime. Stage B; requires network access from the binary.
- **Sandboxing / signing** — extensions run in the same BEAM VM with
  full access. No sandbox boundary in Stage A.
- **Marketplace / Hex hot-install** — not applicable in the Burrito binary.
- **Multi-language extensions** — Elixir only in Stage A.
- **LiveView extension management UI** — out of scope for CLI harness.

---

## Appendix A — Boot Position

```
lib/tau/application.ex  (:rest_for_one child list, positions matter)

  1.  Tau.Telemetry.Supervisor
  2.  Tau.OtelReporter (conditional)
  3.  Phoenix.PubSub
  4.  Tau.Registries
  5.  Tau.Settings.Cache          ← Loader reads this in init/1
  6.  Tau.Settings.Watcher
  7.  Tau.Memory.Supervisor
  8.  Tau.Permissions.RuleSet
  9.  Finch
  10. Tau.Providers.RateLimiter.Supervisor
  11. Tau.CircuitBreaker.Store
  12. Tau.Providers.Copilot.TokenStore
  13. {Task.Supervisor, name: Tau.Tools.TaskSupervisor}
  14. Tau.Extensions.Loader        ← HERE; Registries are at position 4
  15. Tau.MCP.Supervisor
  16. Tau.CodingAgent.Supervisor
  17. Tau.TUI.Supervisor
  18. Tau.Sessions.Supervisor      ← sees extensions on first session start
```

---

## Appendix B — Source Map

Files in scope of this SPEC (a PR touching any of these MUST name its
AC-N / D-NNN):

```
lib/tau/extension.ex
lib/tau/extensions/loader.ex
lib/tau/cli/extensions.ex
lib/tau/settings/schema.ex        (extensions property only)
lib/tau/application.ex            (Extensions.Loader entry only)
test/tau/extensions/
test/tau/cli/extensions_test.exs
test/tau/extension_skill_validation_test.exs
test/support/extensions/
docs/spec/SPEC-EXTENSIONS.md
docs/adr/0022-extension-api.md
```
