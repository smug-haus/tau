---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Test-isolation shim via `start_supervised` overrides in ExUnit

## Approach

Add an `ExUnit.CaseTemplate` (`Tau.Test.IsolatedApp`) that starts a second
Tau supervision subtree under unique names for each test that needs full
process isolation, without changing any production `start_link/1` signatures
or production call sites. The shim works by starting `Phoenix.PubSub`,
`Finch`, the `Registry` children, `CircuitBreaker.Store`, and
`Cost.Tracker` with per-test-unique names (e.g. `:"Tau.PubSub.test_<ref>"`),
then swapping them in via `Application.put_env/3` before the test runs and
restoring originals after. Production code continues to call `Tau.PubSub` etc.
by their compile-time module atom; the shim makes those atoms point to the
isolated process via the Application env.

## Rationale

The acceptance criterion requires (a) identifying which processes have a
natural `name:` opt path vs which require broad caller-site changes, (b) a
minimum change eliminating the test-fixture collision, and (c) an ETS table
name strategy. This proposal satisfies (b) directly — it eliminates the
collision for the test-fixture scenario with zero production code changes —
while leaving (a) and (c) to documentation rather than enforcement. The shim
is the narrowest possible footprint that resolves the highest-priority
scenario.

## Sketch

```elixir
# test/support/isolated_app.ex
defmodule Tau.Test.IsolatedApp do
  @moduledoc """
  ExUnit case template that starts an isolated Tau subsystem subtree
  per test to avoid global-name collisions in concurrent test runs.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      setup do
        ref = make_ref() |> :erlang.ref_to_list() |> List.to_string()
        pubsub_name   = :"Tau.PubSub.#{ref}"
        finch_name    = :"Tau.Providers.Finch.#{ref}"
        cb_table      = :"tau_circuit_breakers_#{ref}"
        cost_table    = :"tau_cost_counters_#{ref}"

        {:ok, pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})
        {:ok, finch}  = start_supervised({Finch, name: finch_name})
        {:ok, cb}     = start_supervised(
          {Tau.CircuitBreaker.Store,
           name: :"Tau.CircuitBreaker.Store.#{ref}",
           table: cb_table}
        )
        {:ok, ct}     = start_supervised(
          {Tau.Cost.Tracker,
           name: :"Tau.Cost.Tracker.#{ref}",
           table: cost_table}
        )

        # Shim Application env so modules that call Tau.PubSub etc. by atom
        # read the per-test name.
        Application.put_env(:tau, :pubsub_name, pubsub_name)
        Application.put_env(:tau, :finch_name, finch_name)
        Application.put_env(:tau, :cb_table, cb_table)
        Application.put_env(:tau, :cost_table, cost_table)

        on_exit(fn ->
          Application.delete_env(:tau, :pubsub_name)
          Application.delete_env(:tau, :finch_name)
          Application.delete_env(:tau, :cb_table)
          Application.delete_env(:tau, :cost_table)
        end)

        :ok
      end
    end
  end
end
```

`CircuitBreaker.Store` and `Cost.Tracker` would each need a one-line change
to accept an optional `table:` keyword in their `start_link/1` and `init/1`
(replacing `@table` with a runtime value from opts). No call-site changes
needed anywhere else.

`Application.get_env/3` wrappers in the *few* places a module resolves the
name at call time (e.g. `Tau.PubSub` in `Phoenix.PubSub.broadcast/3`) would
need to change from bare atom to a helper function:

```elixir
# lib/tau/names.ex  (new, 8 lines)
defmodule Tau.Names do
  def pubsub,  do: Application.get_env(:tau, :pubsub_name, Tau.PubSub)
  def finch,   do: Application.get_env(:tau, :finch_name, Tau.Providers.Finch)
  def cb_table, do: Application.get_env(:tau, :cb_table, :tau_circuit_breakers)
  def cost_table, do: Application.get_env(:tau, :cost_table, :tau_cost_counters)
end
```

Production code is unchanged as long as Application env is absent (the
`get_env/3` default returns the existing atom). Only the shim sets the env.

## Tradeoffs

### Strengths

- Zero production API surface change; all existing call sites compile unchanged.
- Resolves test-fixture collision (the highest-priority scenario) in one PR.
- `start_supervised` gives ExUnit lifecycle tracking; no manual cleanup.
- `on_exit` restores Application env so tests are hermetic.

### Weaknesses

- `Application.put_env/3` is the OTP-NN §1 violation the rule warns against:
  "No `Application.put_env/3` for runtime state." Using it as a shim in tests
  only partially masks this — any concurrent test that also reads `Application.get_env`
  for the same key will race, defeating isolation for parallel test runs.
- Does not address the production multi-tenant scenario (two Tau OTP apps
  embedded in one node in production). The collision remains latent in non-test
  deployments.
- The `Tau.Names` indirection adds a function call per event dispatch, with a
  negligible but real performance cost on hot paths (PubSub broadcasts in the
  render loop).
- Requires callers that hold the atom at compile time (e.g. pattern matching on
  `:tau_circuit_breakers` in match specs) to be identified and changed — the
  audit is manually verified, not mechanically enforced.
- ETS table parameterisation in `Store` and `Tracker` requires confirming D-044
  schema-version semantics are unaffected (the table *name* is not part of the
  row schema, so @schema_version need not bump, but this must be documented
  explicitly).

### Costs

- ~80 lines of test support code + ~20 lines in `Tau.Names`.
- `CircuitBreaker.Store.start_link/1` and `Cost.Tracker.start_link/1` each
  need a ~5-line change to accept `table:` and `name:` opts.
- All PubSub call sites (~15 locations in `lib/`) need to change from bare
  `Tau.PubSub` to `Tau.Names.pubsub()`. Similarly ~6 Finch call sites.
- No supervisor, behaviour, or spec changes.

## Dependencies

- `CircuitBreaker.Store` and `Cost.Tracker` must each be updated to accept
  `table:` and `name:` in their `start_link/1` / `init/1` before the shim
  works. These are two-process changes the problem statement flags as "natural
  `name:` opt path already exposed" — they are not currently exposed but are
  straightforward to add.

## Confidence

Medium. The approach is well-understood (Application env shim for test
isolation is an established Elixir idiom) but the concurrent test race risk
with `Application.put_env` lowers confidence for parallel test runs. A
prototype replacing bare atoms in three or four hot-path call sites would
confirm the pattern before committing.

## Prior art / references

- Elixir `Application.get_env/3` with default: standard idiom for
  test-overridable configuration.
- `ExUnit.Callbacks.start_supervised/2`: documented ExUnit lifecycle hook for
  processes-under-test.
- Ecto's `Ecto.Adapters.SQL.Sandbox` uses a similar per-test supervision
  approach for DB connections.
