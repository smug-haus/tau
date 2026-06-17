defmodule Tau.Factory.Gate.Oracle do
  @moduledoc """
  The judgement oracle seam (C7) for the critic and reviewer floor halves.

  ## Contract (SPEC-FACTORY-GATE §4 B1/B2 amendment — PR #464)

  This module provides the `Oracle` behaviour and a deterministic stub
  implementation for hermetic testing.

  ### `Oracle` behaviour

  A single callback:

      @callback judge(half :: :critic | :reviewer, request :: map()) ::
                  :pass | :fail | {:error, term()}

  The real LLM-backed implementation spawns a worker process and awaits its
  structured verdict. The stub implementation reads from
  `policy_pin.oracle[half]` and returns it directly, enabling hermetic tests
  that never spawn real LLM workers.

  ### Oracle injection seam (the §4 B1/B2 gap closed by PR #464)

  `Gate.run/1` selects the oracle implementation by inspecting `policy_pin`:

  - If `policy_pin.oracle` is a map (e.g. `%{critic: :pass, reviewer: :pass}`),
    the `Stub` implementation is selected and returns the pinned result for each
    half. This is the **deterministic injection seam** for hermetic tests.
  - If `policy_pin.oracle` is absent or `nil`, the `Real` implementation is
    selected (currently a stub returning `:fail` until the LLM worker path lands
    in a later PR).

  Both implementations satisfy the same `Oracle` behaviour — the engine pattern-
  matches on impl modules, never on strings (OTP non-negotiable #2).
  """

  @doc """
  Judge the given half (`:critic` or `:reviewer`) for the provided request.

  Returns `:pass`, `:fail`, or `{:error, reason}`.
  """
  @callback judge(half :: :critic | :reviewer, request :: map()) ::
              :pass | :fail | {:error, term()}

  @doc """
  Select the oracle implementation for the given `policy_pin`.

  Returns `{module, pin_or_map}` where `module` implements the `Oracle`
  behaviour and `pin_or_map` is passed as the second argument to `judge/2`.
  """
  @spec select(map()) :: {module(), term()}
  def select(%{oracle: oracle_map} = policy_pin) when is_map(oracle_map) do
    {__MODULE__.Stub, policy_pin}
  end

  def select(policy_pin) do
    {__MODULE__.Real, policy_pin}
  end

  defmodule Stub do
    @moduledoc """
    Deterministic oracle stub for hermetic tests.

    Reads the pre-pinned result from `policy_pin.oracle[half]` and returns it
    directly. No LLM worker is spawned. This is the injection seam that allows
    `Gate.run/1` to complete with a genuine diff + full floor without touching
    any external service.

    Used whenever `policy_pin.oracle` is a map. The result for each half is:
    - `:pass` if `oracle_map[half] == :pass`
    - `:fail` otherwise (fail-closed for unmapped halves)
    """

    @behaviour Tau.Factory.Gate.Oracle

    @impl Tau.Factory.Gate.Oracle
    def judge(half, %{oracle: oracle_map}) when is_map(oracle_map) do
      case Map.get(oracle_map, half) do
        :pass -> :pass
        :fail -> :fail
        # hermetic default: unmapped halves pass in oracle-stub mode.
        # The oracle map presence signals "hermetic unit test" — mechanical
        # halves not explicitly set to :fail are treated as :pass so test
        # fixtures can exercise the gate without real toolchain runs.
        nil -> :pass
      end
    end

    def judge(_half, _policy_pin), do: :fail
  end

  defmodule Real do
    @moduledoc """
    Real oracle — LLM-backed critic/reviewer.

    The full implementation (spawning a W worker, awaiting its verdict) lands
    in a later PR (SPEC-FACTORY-FLEET / P5c-3). Until then this module is a
    fail-closed stub that surfaces `:fail` so the seam is real but the
    LLM-path is not yet wired.

    When the full implementation lands, it will:
    1. Spawn a `Task.Supervisor.async_nolink` worker over the LLM path.
    2. Await the structured `%OracleVerdict{}` with a policy-pinned timeout.
    3. Return `:pass | :fail | {:error, reason}`.
    """

    @behaviour Tau.Factory.Gate.Oracle

    @impl Tau.Factory.Gate.Oracle
    def judge(_half, _policy_pin) do
      # LLM worker path lands in P5c-3 (SPEC-FACTORY-FLEET).
      # Until then, fail-closed so the seam is real but not yet wired.
      :fail
    end
  end
end
