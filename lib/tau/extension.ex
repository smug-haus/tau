defmodule Tau.Extension do
  @moduledoc """
  Behaviour + DSL for bundling tools, hooks, slash commands, and skills.

      defmodule MyExt do
        use Tau.Extension

        tool MyExt.SearchTool
        hook :pre_tool_use, MyExt.AuditHook
        command "/deploy", MyExt.DeployCommand
        skill "deploy", "priv/skills/deploy/SKILL.md"
      end

  `Tau.Extensions.Loader` loads each `Tau.Extension` module on boot,
  invokes the four callbacks, and registers their entries in the
  appropriate `Registry`.
  """

  @callback tools() :: [module()]
  @callback hooks() :: [{Tau.Hook.event(), module()}]
  @callback commands() :: [{String.t(), module()}]
  @callback skills() :: [{String.t(), Path.t()}]

  defmacro __using__(_opts) do
    quote do
      @behaviour Tau.Extension
      import Tau.Extension.DSL
      Module.register_attribute(__MODULE__, :tau_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :tau_hooks, accumulate: true)
      Module.register_attribute(__MODULE__, :tau_commands, accumulate: true)
      Module.register_attribute(__MODULE__, :tau_skills, accumulate: true)
      @before_compile Tau.Extension
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @impl Tau.Extension
      def tools, do: @tau_tools |> Enum.reverse()

      @impl Tau.Extension
      def hooks, do: @tau_hooks |> Enum.reverse()

      @impl Tau.Extension
      def commands, do: @tau_commands |> Enum.reverse()

      @impl Tau.Extension
      def skills, do: @tau_skills |> Enum.reverse()
    end
  end
end

defmodule Tau.Extension.DSL do
  @moduledoc "Macros injected by `use Tau.Extension`."

  @doc "Register a `Tau.Tool`-implementing module."
  defmacro tool(mod) do
    quote do
      @tau_tools unquote(mod)
    end
  end

  @doc "Register a `Tau.Hook` implementation for an event."
  defmacro hook(event, mod) do
    quote do
      @tau_hooks {unquote(event), unquote(mod)}
    end
  end

  @doc "Register a slash command — its name is the user-typed string (e.g. `\"/deploy\"`)."
  defmacro command(name, mod) do
    quote do
      @tau_commands {unquote(name), unquote(mod)}
    end
  end

  @doc "Register a skill by name and `SKILL.md` path."
  defmacro skill(name, path) do
    quote do
      @tau_skills {unquote(name), unquote(path)}
    end
  end
end
