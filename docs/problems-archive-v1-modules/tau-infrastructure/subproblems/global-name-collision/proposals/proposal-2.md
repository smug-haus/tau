---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Thread `name:` opts from `Application.start/2` through every child `start_link/1`

## Approach

Change `Tau.Application.start/2` to accept an `instance_id` option (defaulting
to `:default`) and derive all global names from it. Every named child process
(`Phoenix.PubSub`, `Finch`, `CircuitBreaker.Store`, `Cost.Tracker`,
`Task.Supervisor`, and each `Registry`) receives a computed `name:` opt of the
form `:"#{module}.#{instance_id}"`. The `Tau.Registries` supervisor receives the
full name-set via opts and passes each `name:` to its `Registry` children. All
call sites in `lib/` that resolve a name at runtime (PubSub broadcasts,
`Finch.request/3` calls, `Registry.lookup/3` calls) are updated to fetch the
name from a lightweight `Tau.Names` module that reads from `:persistent_term`
(set once at startup, read without a GenServer hop). ETS table names follow the
owning process's registered name derived from `instance_id`.

## Rationale

This proposal threads the `instance_id` through the entire startup path so that
both the process registry (`:name`) and the ETS table name are derived from the
same root. It eliminates the test-fixture collision and the production
multi-tenant collision in one atomic change. Call sites that read names at
runtime go through `Tau.Names`, which reads from `:persistent_term` — so the
hot path is an unboxed atom read with no function call overhead at the
application level. D-044 is not violated because the ETS table *name* is not
part of the circuit-breaker row schema; only the row layout triggers a version
bump.

## Sketch

```elixir
# lib/tau/application.ex (modified start/2)
def start(_type, args) do
  instance_id = Keyword.get(args, :instance_id, :default)
  names       = Tau.Names.compute(instance_id)

  # Store names once in persistent_term for zero-cost read everywhere.
  :persistent_term.put({:tau_names, instance_id}, names)
  # Default instance also published under the well-known key.
  if instance_id == :default do
    :persistent_term.put(:tau_names, names)
  end

  children = [
    Tau.Telemetry.Supervisor,
    otel_reporter_spec(),
    {Phoenix.PubSub,         name: names.pubsub},
    {Tau.Registries,         names: names},
    {Tau.Settings.Cache,     pubsub: names.pubsub},
    {Tau.Settings.Watcher,   []},
    Tau.Memory.Supervisor,
    {Tau.Permissions.RuleSet, pubsub: names.pubsub},
    {Finch,                  name: names.finch},
    {Tau.Providers.RateLimiter.Supervisor, pubsub: names.pubsub,
                                           registry: names.rate_limiter_registry},
    {Tau.CircuitBreaker.Store, name: names.cb_store, table: names.cb_table},
    ...
    {Task.Supervisor, name: names.tools_task_supervisor},
    ...
    {Tau.Sessions.Supervisor, registry: names.sessions_registry}
  ]

  opts = [strategy: :rest_for_one, name: names.supervisor]
  Supervisor.start_link(List.flatten(children), opts)
end
```

```elixir
# lib/tau/names.ex  (new module)
defmodule Tau.Names do
  @moduledoc """
  Derives the full set of process and ETS table names for one Tau instance.
  Stored once in :persistent_term at startup; read without a GenServer hop.
  """

  @type t :: %__MODULE__{
    pubsub:                    atom(),
    finch:                     atom(),
    cb_store:                  atom(),
    cb_table:                  atom(),
    cost_tracker:              atom(),
    cost_table:                atom(),
    supervisor:                atom(),
    tools_registry:            atom(),
    hooks_registry:            atom(),
    commands_registry:         atom(),
    skills_registry:           atom(),
    sessions_registry:         atom(),
    mcp_registry:              atom(),
    rate_limiter_registry:     atom(),
    tools_task_supervisor:     atom(),
    sessions_supervisor:       atom()
  }
  defstruct [
    :pubsub, :finch, :cb_store, :cb_table, :cost_tracker, :cost_table,
    :supervisor, :tools_registry, :hooks_registry, :commands_registry,
    :skills_registry, :sessions_registry, :mcp_registry,
    :rate_limiter_registry, :tools_task_supervisor, :sessions_supervisor
  ]

  @doc "Compute names struct for a given instance_id atom."
  @spec compute(atom()) :: t()
  def compute(:default) do
    %__MODULE__{
      pubsub:                Tau.PubSub,
      finch:                 Tau.Providers.Finch,
      cb_store:              Tau.CircuitBreaker.Store,
      cb_table:              :tau_circuit_breakers,
      cost_tracker:          Tau.Cost.Tracker,
      cost_table:            :tau_cost_counters,
      supervisor:            Tau.Supervisor,
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

  def compute(id) when is_atom(id) do
    suffix = id
    %__MODULE__{
      pubsub:                :"Tau.PubSub.#{suffix}",
      finch:                 :"Tau.Providers.Finch.#{suffix}",
      cb_store:              :"Tau.CircuitBreaker.Store.#{suffix}",
      cb_table:              :"tau_circuit_breakers_#{suffix}",
      cost_tracker:          :"Tau.Cost.Tracker.#{suffix}",
      cost_table:            :"tau_cost_counters_#{suffix}",
      supervisor:            :"Tau.Supervisor.#{suffix}",
      tools_registry:        :"Tau.Tools.Registry.#{suffix}",
      hooks_registry:        :"Tau.Hooks.Registry.#{suffix}",
      commands_registry:     :"Tau.Commands.Registry.#{suffix}",
      skills_registry:       :"Tau.Skills.Registry.#{suffix}",
      sessions_registry:     :"Tau.Sessions.Registry.#{suffix}",
      mcp_registry:          :"Tau.MCP.Registry.#{suffix}",
      rate_limiter_registry: :"Tau.Providers.RateLimiter.Registry.#{suffix}",
      tools_task_supervisor: :"Tau.Tools.TaskSupervisor.#{suffix}",
      sessions_supervisor:   :"Tau.Sessions.Supervisor.#{suffix}"
    }
  end

  @doc "Fetch names for the default instance."
  @spec get() :: t()
  def get, do: :persistent_term.get(:tau_names)

  @doc "Fetch names for a specific instance_id."
  @spec get(atom()) :: t()
  def get(id), do: :persistent_term.get({:tau_names, id})
end
```

Call sites change from:
```elixir
Phoenix.PubSub.broadcast(Tau.PubSub, topic, event)
```
to:
```elixir
Phoenix.PubSub.broadcast(Tau.Names.get().pubsub, topic, event)
```

For the default instance, `Tau.Names.get()` is a single `:persistent_term.get/1`
returning the pre-computed struct; field access is a pattern-match on a map, not
a function call. Hot-path overhead is O(1) memory read.

Each `start_link/1` that previously used `__MODULE__` or a bare atom for `name:`
is updated to accept `name:` and `table:` from opts, with defaults matching
the existing atoms for backward compatibility.

## Tradeoffs

### Strengths

- Fully eliminates the test-fixture collision and the production multi-tenant
  collision in one atomic PR.
- `:persistent_term` read is effectively free (no GenServer, no ETS hop, no
  function overhead beyond a map field access).
- All names in the system flow from one `Tau.Names.compute/1` derivation —
  no names are scattered; the set is inspectable.
- ETS table names follow the owning process name (same `instance_id` suffix)
  satisfying the acceptance criterion's (c) question definitively.
- D-044 schema version is not affected: the row layout is unchanged; only the
  table name atom changes.
- `compute(:default)` preserves all existing atom names for the common case,
  so no migration is needed for deployed configurations.

### Weaknesses

- Broad call-site churn: ~30 locations in `lib/` move from bare atoms to
  `Tau.Names.get().field`. Each is a trivial change but the diff is wide.
- `:persistent_term.put/2` in `Application.start/2` is called before the
  supervision tree; if `start/2` fails mid-tree, the term is orphaned until
  the BEAM node restarts. This is benign (a failed start means no sessions)
  but slightly untidy.
- Modules that receive a `name:` through their supervisor chain (e.g.
  `Tau.Registries`) now need to thread the full `names` struct through opts,
  increasing `start_link/1` arity complexity.
- `Tau.Sessions.Supervisor`, `Tau.MCP.Supervisor`, and `Tau.CodingAgent.Supervisor`
  currently use `__MODULE__` for their supervisor names; making them accept a
  `name:` opt requires each supervisor to be updated even though they have no
  external name references.
- Non-default instances cannot be started without explicitly passing
  `instance_id`; there is no auto-discovery mechanism if two instances are
  embedded in one node by a library user.

### Costs

- Approximately 30 call-site changes in `lib/` (PubSub: 15, Finch: 6, Registry:
  ~9 distinct modules) — all mechanical find-and-replace.
- `Tau.Names` module: ~70 lines.
- Each named child's `start_link/1` updated to accept `name:` / `table:` opts
  with defaults: ~12 modules, ~5 lines each.
- `Tau.Registries.init/1` updated to pass per-name to `Registry` children: ~15
  lines.
- No supervision strategy changes; no behaviour changes.

## Dependencies

- All named `start_link/1` callables (PubSub and Finch accept `name:` already;
  `CircuitBreaker.Store`, `Cost.Tracker`, all Registry children via
  `Tau.Registries`, `Task.Supervisor` — all already accept `name:` in their
  child spec) need to be verified. The main work is threading opts into
  supervisors that currently ignore opts.

## Confidence

High. The `:persistent_term` pattern for application-wide read-only name
resolution is standard Elixir practice; `Tau.Names.compute(:default)` returning
the existing atoms means the default case is provably unchanged. The only risk
is the call-site sweep missing a location — mechanically verifiable with
`grep -rn "Tau.PubSub\|Tau.Providers.Finch"` after the change.

## Prior art / references

- `Phoenix.PubSub` accepts `name:` in `start_link/1` since v2.0 — the pattern
  is already used by the project's own PubSub dependency.
- Finch's `start_link/1` `name:` opt: standard documented opt.
- `:persistent_term` for app-wide read-only config: Erlang/OTP docs
  `erlang.org/doc/man/persistent_term.html`.
- `Ecto.Repo` uses a similar `otp_app:` derivation to namespace all its
  registered names per repo module.
