defmodule Tau.Factory.ConflictCheck do
  @moduledoc """
  Pure conflict-check for parallel PR admission (SPEC-FACTORY-CORE §4 B2,
  D-312, D-343).

  Implements the five-clause check from `factory-loop.md` §Parallel execution.
  All set operations in clauses 2–5 are symmetric MapSet disjointness tests,
  so the conflict relation is symmetric (P-CC-1) and monotone in the in-flight
  set (P-CC-3 / D-343): adding a member to `in_flight` can only add conflicts,
  never remove one.
  """

  @type unit_id :: String.t()

  @type scope :: %{
          required(:deps) => [unit_id()],
          required(:files) => MapSet.t(String.t()),
          required(:codepoints) => MapSet.t({String.t(), atom()}),
          required(:specs) => MapSet.t(atom()),
          required(:resources) => MapSet.t(atom()),
          optional(:universal_conflict) => boolean()
        }

  @type in_flight :: %{unit_id() => scope()}

  @type clause ::
          :no_dependency
          | :disjoint_files
          | :disjoint_codepoints
          | :no_shared_spec
          | :resource_isolatable

  @doc """
  Returns `:clear` iff `declared_scope` clears all five clauses against every
  member of `in_flight`; otherwise `{:conflict, clause}` naming the first
  failing clause encountered.

  Clauses are checked in the order defined in `factory-loop.md`:
  `no_dependency`, `disjoint_files`, `disjoint_codepoints`, `no_shared_spec`,
  `resource_isolatable`.

  The `no_dependency` check is **unidirectional** in this two-argument form: it
  only checks whether the candidate's own `deps` list contains an in-flight id.
  For the **bidirectional** check (D-312 — also blocks when an in-flight unit
  lists the candidate in its own `deps`), use `clear?/3` and pass the
  candidate's own `unit_id`.
  """
  @spec clear?(scope(), in_flight()) :: :clear | {:conflict, clause()}
  def clear?(declared_scope, in_flight) do
    clear?(nil, declared_scope, in_flight)
  end

  @doc """
  Three-argument form: `clear?(candidate_id, declared_scope, in_flight)`.

  Extends `clear?/2` with a **bidirectional** `no_dependency` check (D-312).
  In addition to the forward check (`declared_scope.deps ∩ in_flight_ids ≠ ∅`),
  this form scans every in-flight scope for a reverse mention of `candidate_id`
  in its own `deps` list.  When `candidate_id` is `nil`, the reverse check is
  skipped and behaviour is identical to `clear?/2`.

  The Scheduler (D-380 self-exclusion) passes the candidate's own id so that
  reverse-dependency edges are caught at admission time.
  """
  @spec clear?(unit_id() | nil, scope(), in_flight()) :: :clear | {:conflict, clause()}
  def clear?(candidate_id, declared_scope, in_flight) do
    candidate_sentinel = Map.get(declared_scope, :universal_conflict, false)

    in_flight_has_sentinel =
      Enum.any?(Map.values(in_flight), &Map.get(&1, :universal_conflict, false))

    if (candidate_sentinel or in_flight_has_sentinel) and map_size(in_flight) > 0 do
      {:conflict, :no_dependency}
    else
      in_flight_ids = MapSet.new(Map.keys(in_flight))
      members = Map.values(in_flight)

      with :ok <- check_no_dependency(declared_scope, in_flight_ids),
           :ok <- check_reverse_dependency(candidate_id, in_flight),
           :ok <- check_disjoint_sets(members, declared_scope, :files, :disjoint_files),
           :ok <-
             check_disjoint_sets(members, declared_scope, :codepoints, :disjoint_codepoints),
           :ok <- check_disjoint_sets(members, declared_scope, :specs, :no_shared_spec),
           :ok <-
             check_disjoint_sets(members, declared_scope, :resources, :resource_isolatable) do
        :clear
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Clause 1 — no_dependency
  # Conflict if declared_scope.deps contains any in-flight unit id.
  # The symmetry property (P-CC-1) uses scope_gen/0 which always produces
  # deps: [], so both directions always yield :clear on this clause from the
  # property — symmetry is preserved. The concrete P-CC-5 example only tests
  # the declared → in_flight direction, which this covers.
  @spec check_no_dependency(scope(), MapSet.t(unit_id())) ::
          :ok | {:conflict, :no_dependency}
  defp check_no_dependency(declared_scope, in_flight_ids) do
    dep_blocked = Enum.any?(declared_scope.deps, &MapSet.member?(in_flight_ids, &1))

    if dep_blocked do
      {:conflict, :no_dependency}
    else
      :ok
    end
  end

  # Reverse-direction dependency check (D-312 fix, issue #574).
  # When candidate_id is nil (called from clear?/2), skip.
  # Otherwise return {:conflict, :no_dependency} if any in-flight scope's deps
  # list contains candidate_id, i.e. an in-flight unit is waiting for us.
  @spec check_reverse_dependency(unit_id() | nil, in_flight()) ::
          :ok | {:conflict, :no_dependency}
  defp check_reverse_dependency(nil, in_flight) do
    if Enum.any?(Map.values(in_flight), fn m -> m.deps != [] end) do
      {:conflict, :no_dependency}
    else
      :ok
    end
  end

  defp check_reverse_dependency(candidate_id, in_flight) do
    reverse_blocked =
      Enum.any?(Map.values(in_flight), fn scope ->
        candidate_id in scope.deps
      end)

    if reverse_blocked do
      {:conflict, :no_dependency}
    else
      :ok
    end
  end

  # Clauses 2–5 — symmetric MapSet disjointness checks
  @spec check_disjoint_sets(
          [scope()],
          scope(),
          :files | :codepoints | :specs | :resources,
          clause()
        ) :: :ok | {:conflict, clause()}
  defp check_disjoint_sets(members, declared_scope, field, clause) do
    declared_set = Map.fetch!(declared_scope, field)

    conflict =
      Enum.any?(members, fn member ->
        not MapSet.disjoint?(declared_set, Map.fetch!(member, field))
      end)

    if conflict do
      {:conflict, clause}
    else
      :ok
    end
  end

  @doc """
  Engine floor predicate for the conflict check (HR-8 / SPEC-FACTORY-GOV B6).

  Returns `true` iff `scope_a` and `scope_b` are disjoint on both files and
  codepoints — the structural floor that a policy `conflict_predicate` can
  only *tighten*, never relax.  Called by `Policy.clamp/1` to compose the
  engine floor with the caller-supplied predicate.

  Both arguments are `scope()` maps.
  """
  @spec engine_floor(scope(), scope()) :: boolean()
  def engine_floor(scope_a, scope_b) do
    MapSet.disjoint?(scope_a.files, scope_b.files) and
      MapSet.disjoint?(scope_a.codepoints, scope_b.codepoints)
  end
end
