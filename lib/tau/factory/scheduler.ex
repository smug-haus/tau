defmodule Tau.Factory.Scheduler do
  @moduledoc """
  Admission authority for parallel PR execution (SPEC-FACTORY-CORE §4, D-312, D-343).

  Holds the in-flight set F (`%{unit_id => declared_scope}`) and the policy-version
  pins (`%{unit_id => %Policy{}}`) in GenServer state, and gates admission through
  three sequential conditions:

  1. **Conflict check** — `ConflictCheck.clear?(unit_id, declared_scope, F)` (D-312 bidirectional).
  2. **Capacity check** — `map_size(F) < w_cap`.
  3. **Budget check** (when `:budget` is configured) — calls
     `Budget.Owner.budget_precheck/2` for each configured dimension.

  The first failing condition wins (defer reason precedence: conflict →
  at_capacity → budget). A `{:defer, _}` reply NEVER mutates F (D-343).

  ## INV-POLICY-PIN

  `admit/4` captures the supplied `%Policy{}` in `pins` at admission time.
  A mid-flight policy version bump only affects units admitted after the change —
  the pinned policy for an in-flight unit is immutable for its lifetime.
  `pinned_policy_for/2` exposes the frozen `%Policy{}` for downstream use
  (e.g., by the Unit FSM when composing a `Gate.Request`; arch `control-plane.md §2.2`).

  ## Public API

    - `start_link/1` — start and register.
    - `admit/3` — `call`; returns `:admit` or `{:defer, reason}`. No policy pin.
    - `admit/4` — `call`; returns `:admit` or `{:defer, reason}`. Pins the `%Policy{}`
      at admission (INV-POLICY-PIN, arch §2.2).
    - `release/2` — `call`; removes `unit_id` from F and pins; no-op if absent.
    - `in_flight/1` — `call`; returns the current F snapshot.
    - `pinned_policy_for/2` — `call`; returns the `%Policy{}` pinned at admission,
      or `nil` if the unit has no pin.
  """

  use GenServer

  alias Tau.Factory.Budget.Owner, as: BudgetOwner
  alias Tau.Factory.ConflictCheck
  alias Tau.Factory.Policy

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type unit_id :: String.t()
  @type declared_scope :: ConflictCheck.scope()
  @type defer_reason ::
          {:conflict, ConflictCheck.clause()}
          | :at_capacity
          | {:budget, atom()}

  @type state :: %{
          f: %{unit_id() => declared_scope()},
          pins: %{unit_id() => Policy.t()},
          w_cap: pos_integer(),
          budget: {atom(), [atom()]} | nil
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the Scheduler and register it under `:name`.

  Required options:
    - `:name`  — atom; registered name for the GenServer.
    - `:w_cap` — positive integer; maximum concurrent admitted units (|F| < W_cap).

  Optional options:
    - `:budget` — `{owner_name :: atom(), dimensions :: [atom()]}`;
                  if present, `admit/3` gates on `Budget.Owner.budget_precheck/2`
                  for each listed dimension.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Attempt to admit `unit_id` with `declared_scope`. No policy pin recorded.

  Returns `:admit` when all conditions clear; `{:defer, reason}` otherwise.
  On `:admit`, `unit_id => declared_scope` is added to F before the reply.
  On `{:defer, _}`, F is left unchanged (D-343).

  Defer reason precedence: `{:conflict, clause}` → `:at_capacity` → `{:budget, dim}`.
  """
  @spec admit(GenServer.server(), unit_id(), declared_scope()) ::
          :admit | {:defer, defer_reason()}
  def admit(server, unit_id, declared_scope) do
    GenServer.call(server, {:admit, unit_id, declared_scope, nil})
  end

  @doc """
  Attempt to admit `unit_id` with `declared_scope`, pinning `policy` at admission.

  Identical to `admit/3` but also stores `policy` in `pins` on `:admit`,
  implementing INV-POLICY-PIN (arch `control-plane.md §2.2`).  A mid-flight
  policy version bump only affects units admitted after the change; the pinned
  policy for this unit is frozen for its lifetime.

  Returns `:admit` when all conditions clear; `{:defer, reason}` otherwise.
  On `{:defer, _}`, neither F nor pins are mutated (D-343).
  """
  @spec admit(GenServer.server(), unit_id(), declared_scope(), Policy.t()) ::
          :admit | {:defer, defer_reason()}
  def admit(server, unit_id, declared_scope, policy) do
    GenServer.call(server, {:admit, unit_id, declared_scope, policy})
  end

  @doc """
  Return the `%Policy{}` pinned at admission for `unit_id`.

  Returns the `%Policy{}` struct that was supplied at `admit/4` time, or `nil`
  if `unit_id` was admitted via `admit/3` (no policy) or is not in `pins`.
  """
  @spec pinned_policy_for(GenServer.server(), unit_id()) :: Policy.t() | nil
  def pinned_policy_for(server, unit_id) do
    GenServer.call(server, {:pinned_policy_for, unit_id})
  end

  @doc """
  Release `unit_id` from F. No-op if `unit_id` is not currently in F.
  """
  @spec release(GenServer.server(), unit_id()) :: :ok
  def release(server, unit_id) do
    GenServer.call(server, {:release, unit_id})
  end

  @doc """
  Return a snapshot of the current in-flight set F.
  """
  @spec in_flight(GenServer.server()) :: %{unit_id() => declared_scope()}
  def in_flight(server) do
    GenServer.call(server, :in_flight)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    w_cap = Keyword.fetch!(opts, :w_cap)
    budget = Keyword.get(opts, :budget, nil)

    state = %{
      f: %{},
      pins: %{},
      w_cap: w_cap,
      budget: budget
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:admit, unit_id, declared_scope, policy}, _from, state) do
    # D-380 self-exclusion: evaluate admission over F ∖ {unit_id} so a unit
    # never conflicts with its own in-flight entry (idempotent upsert).
    f_prime = Map.delete(state.f, unit_id)

    case evaluate_admission(unit_id, declared_scope, %{state | f: f_prime}) do
      :admit ->
        new_f = Map.put(state.f, unit_id, declared_scope)
        # INV-POLICY-PIN: pin the policy at admission when supplied.
        new_pins =
          if is_nil(policy) do
            state.pins
          else
            Map.put(state.pins, unit_id, policy)
          end

        {:reply, :admit, %{state | f: new_f, pins: new_pins}}

      {:defer, reason} ->
        # D-343: F and pins MUST NOT be mutated on a defer path.
        {:reply, {:defer, reason}, state}
    end
  end

  def handle_call({:release, unit_id}, _from, state) do
    new_f = Map.delete(state.f, unit_id)
    new_pins = Map.delete(state.pins, unit_id)
    {:reply, :ok, %{state | f: new_f, pins: new_pins}}
  end

  def handle_call(:in_flight, _from, state) do
    {:reply, state.f, state}
  end

  def handle_call({:pinned_policy_for, unit_id}, _from, state) do
    {:reply, Map.get(state.pins, unit_id), state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Evaluate all three admission conditions in precedence order.
  # Returns :admit or {:defer, reason}. Never mutates state.
  @spec evaluate_admission(unit_id(), declared_scope(), state()) ::
          :admit | {:defer, defer_reason()}
  defp evaluate_admission(unit_id, declared_scope, %{f: f, w_cap: w_cap, budget: budget}) do
    with :clear <- ConflictCheck.clear?(unit_id, declared_scope, f),
         :ok <- check_capacity(f, w_cap),
         :ok <- check_budget(budget) do
      :admit
    else
      {:conflict, clause} -> {:defer, {:conflict, clause}}
      {:defer, reason} -> {:defer, reason}
    end
  end

  @spec check_capacity(%{}, pos_integer()) :: :ok | {:defer, :at_capacity}
  defp check_capacity(f, w_cap) do
    if map_size(f) < w_cap do
      :ok
    else
      {:defer, :at_capacity}
    end
  end

  @spec check_budget({atom(), [atom()]} | nil) :: :ok | {:defer, {:budget, atom()}}
  defp check_budget(nil), do: :ok

  defp check_budget({owner_name, dimensions}) do
    Enum.reduce_while(dimensions, :ok, fn dim, :ok ->
      case BudgetOwner.budget_precheck(owner_name, dim) do
        :ok -> {:cont, :ok}
        {:exhausted, dim} -> {:halt, {:defer, {:budget, dim}}}
      end
    end)
  end
end
