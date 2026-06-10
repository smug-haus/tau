---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Eliminate global names by replacing atom-keyed lookups with pid-passing and `{:via, Registry}` everywhere

## Approach

Remove all hard-coded atom names for long-lived processes (PubSub, Finch,
CircuitBreaker.Store, Cost.Tracker, all Registries, Sessions.Supervisor) and
replace them with `{:via, Registry, {Tau.Instance.Registry, key}}` references
or explicit pid threading via function opts. The one remaining global singleton
is `Tau.Instance.Registry` — a single named `Registry` that maps well-known
keys to pids for each Tau instance, keyed by `{instance_id, :pubsub}`,
`{instance_id, :finch}`, etc. No process uses `name: SomeModule` in its
`start_link/1`. Call sites that today pass `Tau.PubSub` (an atom) to
`Phoenix.PubSub.broadcast/3` instead resolve the pid via
`Tau.Instance.Registry.lookup(:pubsub)` at startup and hold it in their
GenServer state. Processes that are not GenServers (pure callers) look up the
pid inline. This is an API-breaking change to every `start_link/1` that
currently registers under `__MODULE__`.

## Rationale

The root complaint is that atom names embed a topological assumption. The
purest decomplecting move is to eliminate atom-keyed global process registration
entirely: processes find each other through the supervision tree structure (pid
threading from parent to child) or through a single well-known Registry whose
key space is scoped per instance. This proposal answers the acceptance criterion
question (a) definitively — no subsystem needs a "natural `name:` opt path"
because no subsystem uses atom-keyed registration at all.

## Sketch

```elixir
# lib/tau/instance/registry.ex  (new, replaces scattered atom names)
defmodule Tau.Instance.Registry do
  @moduledoc """
  The one global Registry in the system. Maps {instance_id, role} pairs to
  pids. Started exactly once per node as the very first child of
  Tau.Application before any instance-scoped children.

  Well-known roles: :pubsub, :finch, :cb_store, :cost_tracker,
  :sessions_supervisor, :tools_task_supervisor, and all registry roles
  (:tools_registry, :hooks_registry, etc.).
  """

  @registry_name Tau.Instance.Registry   # the one true atom in the system

  def child_spec(_opts) do
    {Registry, keys: :unique, name: @registry_name}
  end

  @spec via(atom(), atom()) :: {:via, Registry, {atom(), {atom(), atom()}}}
  def via(instance_id, role), do: {:via, Registry, {@registry_name, {instance_id, role}}}

  @spec lookup(atom(), atom()) :: pid() | nil
  def lookup(instance_id, role) do
    case Registry.lookup(@registry_name, {instance_id, role}) do
      [{pid, _}] -> pid
      []         -> nil
    end
  end
end
```

```elixir
# lib/tau/application.ex (modified start/2)
def start(_type, args) do
  instance_id = Keyword.get(args, :instance_id, :default)

  children = [
    # The only globally-named process in the system:
    Tau.Instance.Registry,
    Tau.Telemetry.Supervisor,
    otel_reporter_spec(),
    # PubSub registers itself in Tau.Instance.Registry under {:default, :pubsub}.
    {Phoenix.PubSub,
     name: Tau.Instance.Registry.via(instance_id, :pubsub)},
    {Tau.Registries,     instance_id: instance_id},
    ...
    {Finch,
     name: Tau.Instance.Registry.via(instance_id, :finch)},
    {Tau.CircuitBreaker.Store,
     name: Tau.Instance.Registry.via(instance_id, :cb_store),
     table: :"tau_circuit_breakers_#{instance_id}"},
    {Tau.Cost.Tracker,
     name: Tau.Instance.Registry.via(instance_id, :cost_tracker),
     table: :"tau_cost_counters_#{instance_id}"},
    ...
  ]

  opts = [
    strategy: :rest_for_one,
    name: Tau.Instance.Registry.via(instance_id, :supervisor)
  ]
  Supervisor.start_link(List.flatten(children), opts)
end
```

Call sites that previously used `Tau.PubSub` directly:

```elixir
# Before (in Tau.Session.init/1):
Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{id}")

# After (instance_id stored in session state at init):
pubsub_pid = Tau.Instance.Registry.lookup(instance_id, :pubsub)
Phoenix.PubSub.subscribe(pubsub_pid, "session:#{id}")
```

GenServers that currently have no instance_id in their state must receive it
via their `start_link/1` opts (passed from their supervisor). For
`Tau.Session`, `instance_id` is already in the session opts; the only change is
using it to resolve names at init.

ETS table names follow the pattern `:"tau_circuit_breakers_#{instance_id}"` and
`:"tau_cost_counters_#{instance_id}"` — derived from the instance id, not from
the owning process's registered name (since there is no registered name for the
owning process). D-044: the table name is not part of the row schema; no version
bump needed, but the PR description must document the naming convention change.

## Tradeoffs

### Strengths

- No atom names other than `Tau.Instance.Registry` itself; the atom-leakage
  problem is structurally eliminated rather than managed.
- Two concurrent Tau instances can coexist without any configuration — the
  `instance_id` differentiates everything.
- `{:via, Registry, {Tau.Instance.Registry, {id, role}}}` is a standard OTP
  pattern; no custom resolution logic needed.
- ETS table names are deterministic from `instance_id` — answering the
  acceptance criterion's (c) question with a pure derivation rather than a
  policy document.

### Weaknesses

- API-breaking: `start_link/1` signatures change for every named child process.
  Any external caller that starts `Tau.CircuitBreaker.Store` or
  `Tau.Cost.Tracker` directly (e.g. in tests) must be updated.
- `{:via, Registry, ...}` lookups are slightly slower than atom-based name
  lookups at the BEAM level (atom lookup is O(1) hash; Registry lookup is a
  table read), though the difference is negligible for init-time calls.
- `Tau.Instance.Registry` itself uses a hard-coded atom — the one necessary
  global singleton. If two libraries each embed Tau and both start
  `Tau.Instance.Registry` under the same atom, the collision problem is moved
  up one level. This is only an issue for library embedding, not for the
  test-fixture scenario.
- Modules that today reference `Tau.PubSub` in `Phoenix.PubSub.subscribe/2`
  must be updated to hold a resolved pid or look it up each time. This is
  mechanically straightforward but the diff is large (~30 call sites).
- `Tau.Registries.init/1` currently starts all seven `Registry` children with
  literal module atoms as names. Under this proposal, each `Registry` uses a
  `{:via, ...}` name, and `Tau.Registries` must accept `instance_id` and pass
  computed via-tuples to each child. The `Supervisor.child_spec/1` path for
  `Registry` accepts `name:` as any term that `Registry.start_link/1` accepts,
  including a `{:via, ...}` tuple — this must be confirmed against the `Registry`
  documentation before implementation.

### Costs

- ~30 call-site changes in `lib/` (same as Proposals 2 and 3).
- ~12 `start_link/1` signature changes to accept `instance_id:` or `name:` /
  `table:` opts.
- `Tau.Instance.Registry` module: ~30 lines.
- `Tau.Registries.init/1`: ~25-line change to accept `instance_id` and derive
  names for all seven `Registry` children.
- All tests that start named children directly must be updated to pass
  `instance_id` or a `{:via, ...}` name.
- The test-fixture scenario is resolved as a side effect: tests pass a unique
  `instance_id` to `Tau.Application.start/2` (or start individual children via
  `start_supervised` with explicit `via` names).

## Dependencies

- Confirmation that `Phoenix.PubSub.start_link/1` accepts `name: {:via, Registry, ...}`.
  (Phoenix.PubSub 2.x supports any GenServer name; `{:via, ...}` is a valid
  GenServer name — confirmed by OTP GenServer name contract.)
- Confirmation that `Finch.start_link/1` accepts `name: {:via, Registry, ...}`.
  (Finch 0.x uses `GenServer.start_link/3` which accepts any OTP name — confirmed.)
- `CircuitBreaker.Store` and `Cost.Tracker` accept `table:` in `start_link/1`.

## Confidence

Medium. The `{:via, Registry, ...}` mechanism is well-specified OTP and is used
in production Elixir systems (Phoenix.PubSub's own internals use it). The main
uncertainty is whether `Registry.start_link/1` accepts a `{:via, ...}` tuple as
its own `name:` opt (bootstrapping question: can a Registry register itself
via another Registry?). If it cannot, `Tau.Registries` children must be
launched without a `{:via, ...}` name and instead registered manually after
startup via `Registry.register/3` — adding complexity. This is the key
prototype risk to resolve before committing.

## Prior art / references

- OTP `GenServer` name forms: `https://erlang.org/doc/man/gen_server.html#start_link-4`
  — explicitly permits `{:via, Module, term()}`.
- `Phoenix.PubSub` `{:via, Registry, ...}` usage:
  `https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html#start_link/1` — `name`
  is any valid GenServer name.
- Elixir `Registry` as a process locator under dynamic supervision:
  `https://hexdocs.pm/elixir/Registry.html#module-using-in-via`.
- Erlang `global` module avoidance: Tau's OTP non-negotiables §4 — this
  proposal avoids `:global` while removing atom-keyed `name:` registration.
