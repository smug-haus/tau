---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Shared module attribute — compile-time binding via a named constant

## Approach

Introduce a single module attribute (or a one-function module) that both
`Tau.Application` and `Tau.Memory.EmbeddingWorker` reference for the Finch pool
name. Both sites are changed to use this constant; the two atoms can no longer
drift. The `Application.get_env/3` runtime override is retained but its default
now derives from the shared constant rather than a bare atom.

## Rationale

The complecting hypothesis names the root cause as "no shared constant binding
the two sites." This proposal directly decomplects that: a single authoritative
source of truth for the pool name makes the two sites structurally dependent
rather than implicitly coordinated. If someone renames the pool, the compiler
surfaces every site that uses the constant; unnamed sites that still hold a
stale atom will fail at runtime, not compile time — but the shared constant
means there is exactly one place to update.

## Sketch

Option A — module attribute in `Tau.Application` (simpler, couples
`embedding_worker.ex` to `application.ex`):

```elixir
# lib/tau/application.ex
@finch_name Tau.Providers.Finch
def finch_name, do: @finch_name

# In children/0:
{Finch, name: @finch_name}
```

```elixir
# lib/tau/memory/embedding_worker.ex
finch_name = Application.get_env(:tau, :finch_name, Tau.Application.finch_name())
```

Option B — dedicated thin config module (decouples both from each other):

```elixir
# lib/tau/providers/config.ex  (new file, ~10 lines)
defmodule Tau.Providers.Config do
  @moduledoc "Shared infrastructure constants for provider subsystem."
  @finch_name Tau.Providers.Finch
  def finch_name, do: @finch_name
end
```

```elixir
# lib/tau/application.ex:78
{Finch, name: Tau.Providers.Config.finch_name()}
```

```elixir
# lib/tau/memory/embedding_worker.ex:106
finch_name = Application.get_env(:tau, :finch_name, Tau.Providers.Config.finch_name())
```

Option B is preferred: neither `application.ex` nor `embedding_worker.ex` depends
on the other; both depend on the config module.

## Tradeoffs

### Strengths

- Single source of truth: renaming the pool requires one change, surfaced at
  every callsite.
- Decomplects the two call-sites from each other (Option B).
- Runtime override via `Application.get_env/3` is preserved.
- The constant is accessible to future consumers (e.g. circuit breaker tests).

### Weaknesses

- Introduces a new module (Option B) or a public function on
  `Tau.Application` (Option A) — more surface than Proposal 1.
- The binding is nominal (atom equality), not structural; a typo in the
  constant definition (`Tau.Providers.Finch` vs `Tau.Provider.Finch`) still
  compiles but fails at runtime.
- Does not provide a compile-time proof that the named process exists;
  the process must still be started before the call.
- A caller who bypasses the shared constant and writes the atom inline still
  drifts silently.

### Costs

- 1 new file (Option B) or 1 new function (Option A); ~10–15 lines total.
- `application.ex` and `embedding_worker.ex` each change by one expression.
- No test surface change beyond what Proposal 1 requires.
- Code review: small; the change is mechanical.

## Dependencies

- None external. Option A requires no new file; Option B adds one file in
  `lib/tau/providers/`.

## Confidence

**High.** The pattern of a shared constant module is well-established in Elixir
projects. No design uncertainty; the tradeoff between Option A and Option B is
clear.

What would raise it further: a decision on whether `Tau.Providers.Config` is
the right namespace for infrastructure constants (could live in `Tau.Config`
or `Tau.Infrastructure` instead).

## Prior art / references

- Elixir idiom: `@moduledoc` + accessor function for named processes is
  standard in Phoenix contexts (`MyApp.Repo`, `MyApp.PubSub`).
- `lib/tau/providers/config.ex` does not yet exist; the namespace fits the
  existing `lib/tau/providers/` layout.
