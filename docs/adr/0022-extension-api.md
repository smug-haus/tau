# ADR-0022: Extension API — behaviour DSL, synchronous load, crash-proof registration

- **Status:** Accepted
- **Date:** 2026-05-22
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #180
  - PR: #365
  - Spec: `docs/spec/SPEC-EXTENSIONS.md` §6 D-120..D-129

## Context

Tau needed a stable extension point for third-party tools, hooks, slash
commands, and skills without requiring modification of the core codebase.
Several design axes required explicit decisions:

1. **What is the API shape?** Struct registration, string dispatch, or
   behaviours?
2. **When are extensions loaded?** At boot (blocking) or deferred
   (non-blocking)?
3. **What happens if an extension crashes during registration?**
4. **How are extensions distributed?** Hex packages, git URLs, local dirs?
5. **How are extensions isolated?** Sandboxed VM or trusted author?
6. **What is the process topology for extensions that need state?**

The subsystem was shipped in commit `5e25bd8`. This ADR records the
decisions behind it and the Stage-A hardening applied in PR #365.

## Decision

### 1 — Behaviour-based DSL, not string dispatch

Extensions implement the `Tau.Extension` behaviour. The `use Tau.Extension`
DSL generates four callbacks — `tools/0`, `hooks/0`, `commands/0`,
`skills/0` — via module attributes accumulated during compilation.

**Rejected: string-keyed registration** (e.g. a map or keyword list
returned from a single `describe/0` callback). String keying couples
callers to layout conventions and bypasses the Elixir compile-time
machinery that catches callback-shape errors. OTP non-negotiable #2
mandates behaviours as extensibility seams.

**Rejected: struct-based registration** (pass a struct, not a module).
Structs require the extension author to construct the right shape; a
behaviour + DSL is more discoverable and lets the compiler check
completeness.

### 2 — Synchronous load in `Loader.init/1`

`Tau.Extensions.Loader.init/1` loads all configured and discovered
extensions synchronously before returning `{:ok, state}`. The Loader
occupies position 14 in the `:rest_for_one` child list; `Sessions.Supervisor`
is at position 18. This is a structural guarantee: sessions see extension
tools without any race.

**Rejected: deferred self-message** (the original `Process.send_after(self(), :boot_load, 0)` pattern). The self-message guaranteed nothing about ordering relative to session start. A session that started before `:boot_load` fired would silently see no extension tools. The fix is synchronous load — the OTP supervision tree enforces the ordering automatically.

**Enabling condition:** deferred load was safe to remove only because crash-proof registration (decision 3 below) was landed in the same PR. Moving load into `init/1` without crash isolation turns an extension callback crash into a Loader `init/1` crash → `:max_restarts` → application-boot-failure. This would be strictly worse than the deferred pattern.

### 3 — Crash-proof registration via `try/rescue`

Every invocation of `register_module/1` and every per-callback call is
wrapped in `try/rescue`. A failing extension is logged at `:warning`,
telemetered via `[:tau, :extensions, :load, :exception]`, and skipped.

This is an explicit exemption from OTP non-negotiable #7 ("MUST NOT
`try/rescue` across process boundaries"). The rationale: there IS no
process boundary here. Extension tools are stateless modules; the
"process you would otherwise isolate the code behind" does not exist.
Spawning a one-shot Task per extension to isolate a synchronous module
invocation would be an abstraction inversion — the complexity of Task
supervision without any of the state-isolation benefit.

**Rejected: `:one_for_one` child per extension** for the stateless
registration surface. Extension modules do not own state; there is
nothing a per-extension process would supervise. A future `init/1`
callback for stateful extensions (Stage B) will use a `DynamicSupervisor`,
but that is scoped to extensions that opt into process-ownership — not
the default.

### 4 — Git-URL and local-directory distribution; no Hex hot-install

Extensions are distributed as git repositories or local directories.
`Code.compile_file/1` compiles `.ex` sources at runtime from the
discovered paths.

**Rejected: Hex package hot-install.** `mix` tasks are unavailable in
the Burrito binary. Hex download + compilation at runtime would require
bundling the Mix toolchain, which violates the single-binary distribution
model.

**Rejected: compiled `.beam` distribution.** Shipping pre-compiled
`.beam` files ties the extension to a specific OTP/Elixir version and
makes source auditing harder. Compiling from source at load time is
slower but more portable.

### 5 — No sandboxing (trusted-author posture)

Extensions run in the same BEAM VM with full access to all modules and
processes. There is no sandbox boundary in Stage A.

**Rationale:** BEAM provides no native sandboxing primitive short of a
separate node. Inter-node communication adds significant complexity
(serialisation, network, latency). For the current audience (developers
extending their own Tau installation), the complexity is not justified
by the risk reduction.

**Deferred:** signing and marketplace are Stage B+ concerns.

### 6 — Auto-discovery supplements explicit configuration

The Loader scans `~/.tau/extensions/` then `<cwd>/.tau/extensions/` in
addition to the `settings.extensions` list. This mirrors
`Tau.Skills.Loader.discover/1`'s precedence model.

A module-name collision across discovered directories is detected via
`Code.ensure_loaded?/1` BEFORE `Code.compile_file/1`. The later file is
skipped. `Enum.uniq_by` after compilation is insufficient: BEAM already
has the first-compiled module in its table.

### 7 — `DynamicSupervisor` deferred to Stage B

Extensions that need persistent state (e.g. a file watcher, a cache) will
use an optional `init/1` callback started under
`Tau.Extensions.Supervisor` (a `DynamicSupervisor`). This surface is
deferred until #337 (renderer contract) and #345 (keybinding surface) are
merged, as the process lifecycle must integrate with TUI-managed
keybindings.

## Consequences

**Good:**

- Extensions are guaranteed visible to sessions without any race.
- A misbehaving extension cannot crash the application at boot.
- Discovery works without explicit configuration for the common case.
- Reload is clean: no stale generations left in any registry.

**Accepted tradeoffs:**

- Synchronous load in `init/1` blocks the supervisor until all extensions
  are compiled and registered. On a slow filesystem with many large
  extension files this could extend boot time. Acceptable in Stage A;
  a deferred-but-ordered mechanism (e.g. `:continue` in `init/1`) is
  available if profiling shows a problem.
- No sandboxing. Extensions have full BEAM access. This is a deliberate
  trusted-author posture.
- `{module, opts}` entries in the Loader are a programmatic API (for
  tests) that does not surface through settings validation. This latent
  inconsistency is documented in D-125 and C-010.

## Implementation

`lib/tau/extension.ex`, `lib/tau/extensions/loader.ex`,
`lib/tau/cli/extensions.ex`, `lib/tau/settings/schema.ex`. Full source
map in `docs/spec/SPEC-EXTENSIONS.md` Appendix B (D-120..D-129 entry).
