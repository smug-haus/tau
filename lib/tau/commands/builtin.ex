defmodule Tau.Commands.Builtin do
  @moduledoc """
  Behaviour and registry for built-in slash commands.

  Built-in commands run inline in the session FSM and return a typed
  `t:outcome/0` value.  They shadow same-named extension commands; the
  session resolves built-ins before consulting the Commands.Registry.

  ## Outcome semantics

  - `{:notice, text}` / `{:notice, lines}` — broadcast one or more
    `%Tau.Session.Events.SystemNotice{}` messages and stay in
    `:awaiting_user`.  No provider turn is started (D-042).
  - `{:mutate, fun, notice}` — apply `fun` to FSM `data`, optionally
    broadcast a notice, and stay in `:awaiting_user`.  `fun` MUST be a
    pure `data -> data` transform.  No provider turn is started (D-042).
  - `{:error, text}` — broadcast a `SystemNotice` prefixed with `"Error: "`.
    No provider turn is started (D-042).
  - `:passthrough` — the session falls through to `process_user_message/2`
    with the original message, starting a normal provider turn.

  ## Built-in table

  `table/0` returns the compile-time constant `"/name" => module` map.
  """

  @type outcome ::
          {:notice, String.t()}
          | {:notice, [String.t()]}
          | {:mutate, (map() -> map()), String.t() | nil}
          | {:error, String.t()}
          | :passthrough

  @doc "Returns the slash-command name including the leading slash, e.g. `\"/ping\"`."
  @callback name() :: String.t()

  @doc """
  Run the built-in command.

  `args` is the tail of the user's input after the command name (trimmed).
  `data` is the current session FSM data map.  Return an `t:outcome/0`.
  """
  @callback run(args :: String.t(), data :: map()) :: outcome()

  @doc """
  Compile-time constant map of `\"/name\"` to module.

  All entries are built-in modules that implement `Tau.Commands.Builtin`.
  Built-in resolution precedes extension lookup in
  `Tau.Commands.Parser.lookup_builtin/1` ([C55-B4]).
  """
  @spec table() :: %{String.t() => module()}
  def table do
    %{
      "/ping" => Tau.Commands.Builtin.Ping,
      "/tree" => Tau.Commands.Builtin.Tree,
      "/copy" => Tau.Commands.Builtin.Copy,
      "/export" => Tau.Commands.Builtin.Export
    }
  end
end
