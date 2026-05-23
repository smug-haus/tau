defmodule Tau.Command do
  @moduledoc """
  Behaviour for slash commands.

  A command is invoked when the user types `/<name>` (alone or followed
  by arguments). It returns a `:cont` to inject context into the next
  user prompt, or `:run` to drive the session directly.

  Commands can be defined in three ways:

    1. Programmatically via `use Tau.Extension` + `command "/foo", FooMod`
    2. Markdown files registered into `Tau.Commands.Registry` by an extension
       (the former `Tau.Commands.Files` module does not exist; file commands
       reach the session via `invoke_file_command/3` in `Tau.Session` when an
       extension registers a file path).
    3. Skills (with frontmatter) — see `Tau.Skill`.

  Prompt templates (`~/.tau/prompts/*.md`, `<cwd>/.tau/prompts/*.md`) are a
  fourth mechanism: they are discovered by `Tau.PromptTemplates` and invoked
  as slash commands with named-variable substitution. See
  `Tau.PromptTemplates` for details.

  ## Argument specs

  By default, `execute/2` is invoked with the raw tail string. Authors
  who want positional/flag/option parsing can declare a spec with the
  `command_spec/1` macro after `use Tau.Command`:

      defmodule MyExt.DeployCommand do
        use Tau.Command

        @impl Tau.Command
        def name, do: "/deploy"

        @impl Tau.Command
        def description, do: "Deploy to an environment."

        command_spec do
          arg :env, required: true
          flag :no_cache, default: false
          option :branch, default: "main"
        end

        @impl Tau.Command
        def execute(%{env: env, no_cache: nc, branch: b}, _ctx) do
          # ...
        end
      end

  When the macro is present, the session FSM tokenises the tail string,
  binds it against the spec via `Tau.Command.Spec`, and passes the
  resulting map to `execute/2`. Bind failures (missing required arg,
  unknown flag/option) are surfaced to the model as a friendly error
  string and `execute/2` is not called.

  Commands without a `command_spec` continue to receive the raw tail
  string at `execute(args_string, ctx)` — fully backwards-compatible.
  """

  @type result ::
          {:inject, String.t()}
          | {:replace, String.t()}
          | {:run, String.t()}
          | :ignore

  alias Tau.Command.Context

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback execute(args :: String.t() | map(), ctx :: Context.t()) :: result()

  @doc """
  Optional callback synthesised by `command_spec/1`. Returns the spec
  list consumed by `Tau.Command.Spec.bind/2`. Absent → the FSM passes
  the raw tail string to `execute/2`.
  """
  @callback parameters() :: [Tau.Command.Spec.entry()]

  @optional_callbacks [parameters: 0]

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Tau.Command
      import Tau.Command, only: [command_spec: 1]
    end
  end

  @doc """
  Declare an argument spec for this command.

  Lowers to a `parameters/0` callback returning a list of entry maps.
  Three macro forms are recognised inside the block:

    * `arg :name, required: bool, default: term` — positional argument.
    * `flag :name, default: bool` — boolean flag (`--name` / `--no-name`).
    * `option :name, default: term` — keyword option
      (`--name=value` or `--name value`).

  Compile-time only. The spec is plain data — there is no per-call cost
  beyond a `parameters/0` lookup.
  """
  defmacro command_spec(do: block) do
    entries = collect_entries(block)

    quote do
      @impl Tau.Command
      def parameters, do: unquote(Macro.escape(entries))
    end
  end

  # --- compile-time spec collection ----------------------------------------

  defp collect_entries({:__block__, _, stmts}), do: Enum.map(stmts, &entry_from_call/1)
  defp collect_entries(stmt), do: [entry_from_call(stmt)]

  defp entry_from_call({:arg, _, [name | rest]}) when is_atom(name) do
    opts = optslist(rest)

    base = %{
      kind: :arg,
      name: name,
      required: Keyword.get(opts, :required, false)
    }

    case Keyword.fetch(opts, :default) do
      {:ok, default} -> Map.put(base, :default, default)
      :error -> base
    end
  end

  defp entry_from_call({:flag, _, [name | rest]}) when is_atom(name) do
    opts = optslist(rest)
    %{kind: :flag, name: name, default: Keyword.get(opts, :default, false)}
  end

  defp entry_from_call({:option, _, [name | rest]}) when is_atom(name) do
    opts = optslist(rest)
    %{kind: :option, name: name, default: Keyword.get(opts, :default)}
  end

  defp entry_from_call(other) do
    raise ArgumentError,
          "unsupported entry in command_spec: #{Macro.to_string(other)}. " <>
            "Use `arg`, `flag`, or `option`."
  end

  defp optslist([]), do: []
  defp optslist([opts]) when is_list(opts), do: opts

  defp optslist(other) do
    raise ArgumentError,
          "command_spec entry options must be a keyword list, got: #{inspect(other)}"
  end
end
