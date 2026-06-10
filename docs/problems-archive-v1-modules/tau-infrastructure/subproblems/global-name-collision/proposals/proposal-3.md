---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Process-group namespace via a supervised `Tau.Instance` GenServer injected into every subsystem

## Approach

Introduce `Tau.Instance` — a supervised GenServer that starts as the first
child of `Tau.Application` and holds the authoritative name-set for the running
Tau instance. Every subsystem that needs a global name calls
`Tau.Instance.names()` at the point of use (lazy resolution, not compile-time
atom). The GenServer is registered under a process group key derived from the
OTP application name + a runtime ref, so two concurrent Tau instances each have
their own `Tau.Instance` pid. All other children receive no `name:` change in
`Tau.Application` — instead each child's internal references to global names
(e.g. `Tau.PubSub` in `Phoenix.PubSub.broadcast/3`) are replaced by calls to
`Tau.Instance.names().pubsub`. `CircuitBreaker.Store` and `Cost.Tracker` accept
a `table:` opt supplied by `Tau.Instance` at startup.

## Rationale

This proposal separates the concern of "what names does this instance own" from
the concern of "how are those names derived and stored." The `Tau.Instance`
GenServer is the single source of truth for its instance's names at runtime.
Unlike a `:persistent_term`-only approach, `Tau.Instance` can be monitored: if
it crashes, the `:rest_for_one` strategy cascades the restart to all dependent
children, ensuring stale name references are never observable.

## Sketch

```elixir
# lib/tau/instance.ex  (new module, ~80 lines)
defmodule Tau.Instance do
  @moduledoc """
  Supervised home for an instance's name-set.

  Started as the first non-telemetry child of Tau.Application.
  Registers itself under a well-known key when instance_id == :default;
  otherwise under {Tau.Instance, instance_id}.

  All subsystems that need a global name call Tau.Instance.names/0 at
  the point of use.
  """
  use GenServer

  @type names :: %{
    required(:pubsub)                => atom(),
    required(:finch)                 => atom(),
    required(:cb_store)              => atom(),
    required(:cb_table)              => atom(),
    required(:cost_tracker)          => atom(),
    required(:cost_table)            => atom(),
    required(:tools_registry)        => atom(),
    required(:hooks_registry)        => atom(),
    required(:commands_registry)     => atom(),
    required(:skills_registry)       => atom(),
    required(:sessions_registry)     => atom(),
    required(:mcp_registry)          => atom(),
    required(:rate_limiter_registry) => atom(),
    required(:tools_task_supervisor) => atom(),
    required(:sessions_supervisor)   => atom()
  }

  def start_link(opts) do
    instance_id = Keyword.get(opts, :instance_id, :default)
    via         = via(instance_id)
    GenServer.start_link(__MODULE__, opts, name: via)
  end

  @spec names() :: names()
  def names, do: names(:default)

  @spec names(atom()) :: names()
  def names(instance_id) do
    GenServer.call(via(instance_id), :names)
  end

  @impl true
  def init(opts) do
    instance_id = Keyword.get(opts, :instance_id, :default)
    {:ok, %{names: derive_names(instance_id)}}
  end

  @impl true
  def handle_call(:names, _from, state), do: {:reply, state.names, state}

  defp via(:default), do: {:via, Registry, {Tau.Instance.Registry, :default}}
  defp via(id),       do: {:via, Registry, {Tau.Instance.Registry, id}}

  defp derive_names(:default) do
    %{
      pubsub:                Tau.PubSub,
      finch:                 Tau.Providers.Finch,
      cb_store:              Tau.CircuitBreaker.Store,
      cb_table:              :tau_circuit_breakers,
      cost_tracker:          Tau.Cost.Tracker,
      cost_table:            :tau_cost_counters,
      tools_registry:        Tau.Tools.Registry,
      hooks_registry:        Tau.Hooks.Registry,
      commands_registry:     Tau.Commands.Registry,
      skills_registry:       Tau.Skills.Registry,
      sessions_registry:     Tau.Sessions.Registry,
      mcp_registry:          Tau.MCP.Registry,
      rate_limiter_registry: Tau.Providers.RateLimiter.Registry,
      tools_task_supervisor: Tau.Tools.TaskSupervisor,
      sessions_supervisor:   Tau.Sessions.Supervisor
    }
  end

  defp derive_names(id) when is_atom(id) do
    s = id
    %{
      pubsub:                :"Tau.PubSub.#{s}",
      finch:                 :"Tau.Providers.Finch.#{s}",
      cb_store:              :"Tau.CircuitBreaker.Store.#{s}",
      cb_table:              :"tau_circuit_breakers_#{s}",
      cost_tracker:          :"Tau.Cost.Tracker.#{s}",
      cost_table:            :"tau_cost_counters_#{s}",
      tools_registry:        :"Tau.Tools.Registry.#{s}",
      hooks_registry:        :"Tau.Hooks.Registry.#{s}",
      commands_registry:     :"Tau.Commands.Registry.#{s}",
      skills_registry:       :"Tau.Skills.Registry.#{s}",
      sessions_registry:     :"Tau.Sessions.Registry.#{s}",
      mcp_registry:          :"Tau.MCP.Registry.#{s}",
      rate_limiter_registry: :"Tau.Providers.RateLimiter.Registry.#{s}",
      tools_task_supervisor: :"Tau.Tools.TaskSupervisor.#{s}",
      sessions_supervisor:   :"Tau.Sessions.Supervisor.#{s}"
    }
  end
end
```

`Tau.Application` adds two children at position 1 (before PubSub):

```elixir
# A globally unique registry for Tau.Instance pids.
{Registry, keys: :unique, name: Tau.Instance.Registry},
# The instance coordinator; holds names for this run.
{Tau.Instance, instance_id: instance_id}
```

`Tau.Application` passes the computed names to its other children at startup
by calling `Tau.Instance.names(instance_id)` once before the `children` list is
built, then using the map entries as before:

```elixir
names = Tau.Instance.derive_names(instance_id)  # pure helper, no process needed
{Phoenix.PubSub, name: names.pubsub},
{Finch, name: names.finch},
...
```

All call sites in `lib/` that reference `Tau.PubSub` directly replace the atom
with `Tau.Instance.names().pubsub`. The `Tau.Instance.Registry` itself uses a
hard-coded atom (it is started exactly once per node, not per instance).

## Tradeoffs

### Strengths

- The `Tau.Instance` GenServer is a monitored, supervised process: its crash
  cascades via `:rest_for_one` to the entire name-dependent subtree, preventing
  silent use of stale names after a failure.
- Names are observable at runtime (`GenServer.call(via(id), :names)`) without
  reading `:persistent_term` internals.
- `derive_names(:default)` returns the same atoms as today — no migration for
  deployed configurations.
- The acceptance criterion's (c) question (ETS table names follow owning
  process name) is answered mechanically: `cb_table` is always `:"tau_circuit_breakers_#{id}"`.

### Weaknesses

- Introduces a GenServer call (`Tau.Instance.names()`) on every hot-path
  dispatch (PubSub broadcast, Finch request, Registry lookup). This is a
  mailbox hop per call, not an O(1) memory read. Under the render loop (which
  may broadcast multiple PubSub events per turn), this adds measurable latency
  unless callers cache the returned map in their own process state.
- Adding `Tau.Instance.Registry` as a global singleton re-introduces a
  single-atom name for the instance registry itself — it cannot be parameterised
  without a recursive bootstrapping problem.
- Two levels of Registry are now needed (`Tau.Instance.Registry` for
  `Tau.Instance` pids, plus all the per-instance registries), increasing the
  supervision tree depth.
- The `:rest_for_one` cascade on `Tau.Instance` crash is desirable for
  correctness but means a bug in the names GenServer halts all active sessions —
  higher blast radius than a pure data approach.
- Callers that need the name on hot paths (e.g. per-message PubSub broadcast)
  must cache it in their own `GenServer` state at `init/1`, pushing
  responsibility onto each subsystem.

### Costs

- ~80 lines for `Tau.Instance` module.
- ~30 call-site changes in `lib/` (same scope as Proposal 2), but each now
  calls `Tau.Instance.names().pubsub` rather than reading from `:persistent_term`.
- Callers on hot paths (sessions, TUI event bridge, agent tool) must cache
  the names map in their state: ~6 GenServers need an `init/1` change to store
  `Tau.Instance.names()` in state.
- `Tau.Instance.Registry` added to `Tau.Application` — minimal change.

## Dependencies

- `CircuitBreaker.Store` and `Cost.Tracker` must accept `table:` in `start_link/1`
  (same as Proposals 1 and 2).
- `Tau.Registries` must accept per-name opts (same as Proposal 2).

## Confidence

Medium. The supervised-GenServer-for-names approach is sound OTP design but
the hot-path mailbox-hop weakness is non-trivial. A hybrid where
`Tau.Instance.names/0` caches in `:persistent_term` after the first GenServer
call would mitigate this, but that hybrid is closer to Proposal 2 with an extra
GenServer layer. Confidence would rise if profiling confirmed the PubSub
broadcast path is not latency-sensitive at the per-message level.

## Prior art / references

- `Phoenix.PubSub` internal dispatch: calls the adapter module directly, no
  intermediate GenServer name resolution.
- OTP `:via` Registry pattern: `{:via, Registry, {name, key}}` — used here for
  `Tau.Instance` self-registration.
- Elixir `Registry` docs: `https://hexdocs.pm/elixir/Registry.html`
