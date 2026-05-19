defmodule Tau.Tool do
  @moduledoc """
  Behaviour for model-callable tools.

  A tool exposes a `name/0`, `description/0`, JSON-Schema `parameters/0`,
  and an `execute/2` function that takes already-validated parameters
  plus a `Tau.Tool.Context` and returns `{:ok, Tau.Tool.Result.t()}` or
  `{:error, term()}`.

  The session FSM:

    1. Validates `params` against `parameters/0` (`ex_json_schema`).
    2. Runs `:pre_tool_use` hooks (which may rewrite or block).
    3. Evaluates permissions (`Tau.Permissions.Evaluator`).
    4. Dispatches via `execute/2`.
       - `execution_mode/0 == :parallel` → batched via
         `Task.Supervisor.async_stream_nolink`.
       - `:sequential` → in the FSM-owned task, preserving order.
    5. Runs `:post_tool_use` (or `:post_tool_use_failure`) hooks.

  Tools must NEVER raise on user input. Use `{:error, _}` for expected
  failures and let the supervisor catch genuine bugs.
  """

  alias Tau.Tool.{Context, Result}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(params :: map(), ctx :: Context.t()) ::
              {:ok, Result.t()} | {:error, term()}

  @callback execution_mode() :: :sequential | :parallel
  @callback streams_updates?() :: boolean()

  @optional_callbacks [execution_mode: 0, streams_updates?: 0]

  @doc """
  Look up a registered tool by its public name.

  `Tau.Tools.Registry` is a `:duplicate` registry (see `Tau.Registries`):
  built-in tools are registered once per live session, so a name may carry
  several entries. Every registrant for a name holds the same module value,
  so the first entry is authoritative.
  """
  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(name) do
    case Registry.lookup(Tau.Tools.Registry, name) do
      [{_pid, mod} | _] -> {:ok, mod}
      [] -> :error
    end
  end

  @doc "Register a tool module under its `name/0`."
  @spec register(module()) :: {:ok, pid()} | {:error, term()}
  def register(mod) when is_atom(mod) do
    Registry.register(Tau.Tools.Registry, mod.name(), mod)
  end

  @doc """
  All tool names currently registered.

  De-duplicated: under the `:duplicate` `Tau.Tools.Registry` a name appears
  once per registrant process.
  """
  @spec list() :: [String.t()]
  def list do
    Tau.Tools.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end
end
