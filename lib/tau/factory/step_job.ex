defmodule Tau.Factory.StepJob do
  @moduledoc """
  Oban Worker that drives one factory step (one PR cycle).

  INV-DS-KILL-SWITCH: `perform/1` checks the kill-switch sentinel at the start
  of every execution. If the sentinel is armed, the job is cancelled immediately
  (`{:cancel, :kill_switch_armed}`) without performing any factory-step work.

  The job args map may contain:
    - `"store"`     — registered name (atom, stringified) of the
                      `Tau.Factory.KillSwitch.Store` to consult.
    - `"milestone"` — the milestone title to pass to the factory coordinator.

  See `docs/spec/SPEC-FACTORY-CORE.md`, D-321; `Tau.Factory.KillSwitch.Store`.
  """

  @behaviour Oban.Worker

  alias Tau.Factory.KillSwitch.Store

  @doc """
  Build an `Oban.Job` struct for this worker with the given `args` map.
  """
  @spec new(map()) :: Oban.Job.t()
  def new(args) when is_map(args) do
    Oban.Worker.new(__MODULE__, args)
  end

  @doc """
  Perform one factory step.

  Checks the kill-switch sentinel at job start (INV-DS-KILL-SWITCH):

  1. If a `"sentinel_path"` arg is present and the file EXISTS, returns
     `{:cancel, :kill_switch_armed}` immediately — independent of any Store.
  2. If a `"store"` arg is present and `Store.armed?/1` returns `true`, returns
     `{:cancel, :kill_switch_armed}`.
  3. Otherwise performs the factory step and returns `:ok`.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:cancel, :kill_switch_armed}
  def perform(%Oban.Job{args: args}) do
    if sentinel_armed?(args) do
      {:cancel, :kill_switch_armed}
    else
      store = resolve_store(args)

      if store && Store.armed?(store) do
        {:cancel, :kill_switch_armed}
      else
        :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # INV-DS-KILL-SWITCH: check the filesystem sentinel from job args.
  # Returns true when the file at "sentinel_path" exists at job start.
  # This is the primary kill-switch check, independent of any Store process.
  @default_sentinel_path ".claude/STOP-FACTORY"

  defp sentinel_armed?(args) do
    path = Map.get(args, "sentinel_path", @default_sentinel_path)
    File.exists?(path)
  end

  # Resolve the KillSwitch.Store reference from job args.
  # Args carry the store name as a string (JSON serialisation) or atom.
  defp resolve_store(args) do
    case Map.get(args, "store") do
      nil -> nil
      name when is_atom(name) -> name
      name when is_binary(name) -> String.to_existing_atom(name)
    end
  rescue
    ArgumentError -> nil
  end
end
