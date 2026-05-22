defmodule HelloWorldExt do
  @moduledoc """
  Reference extension for SPEC-EXTENSIONS AC-7 / AC-8.

  Exercises all four extension seams:
    * tool   — `HelloWorldExt.HelloTool`
    * hook   — `HelloWorldExt.AuditHook` on `:pre_tool_use`
    * command — `/hello`
    * skill  — `hello_skill`
  """
  use Tau.Extension

  tool(HelloWorldExt.HelloTool)
  hook(:pre_tool_use, HelloWorldExt.AuditHook)
  command("/hello", HelloWorldExt.HelloCommand)
  skill("hello_skill", Path.join(__DIR__, "skills/hello_skill/SKILL.md"))
end

defmodule HelloWorldExt.HelloTool do
  @moduledoc "A simple tool that echoes a greeting."
  @behaviour Tau.Tool

  alias Tau.Tool.Result

  @impl Tau.Tool
  def name, do: "hello_world"

  @impl Tau.Tool
  def description, do: "Returns a greeting. Used in SPEC-EXTENSIONS integration tests."

  @impl Tau.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "Name to greet"}
      },
      "required" => [],
      "additionalProperties" => false
    }
  end

  @impl Tau.Tool
  def execute(params, _ctx) do
    name = Map.get(params, "name", "World")
    {:ok, Result.text("Hello, #{name}!")}
  end
end

defmodule HelloWorldExt.AuditHook do
  @moduledoc "A pre_tool_use hook that records fired events for test inspection."
  @behaviour Tau.Hook

  @impl Tau.Hook
  def events, do: [:pre_tool_use]

  @impl Tau.Hook
  def handle(:pre_tool_use, payload) do
    # Publish a PubSub event so tests can observe hook execution.
    if Code.ensure_loaded?(Phoenix.PubSub) and function_exported?(Phoenix.PubSub, :broadcast, 3) do
      try do
        Phoenix.PubSub.broadcast(
          Tau.PubSub,
          "test:hooks",
          {:pre_tool_use, payload}
        )
      rescue
        _ -> :ok
      end
    end

    {:cont, payload}
  end
end

defmodule HelloWorldExt.HelloCommand do
  @moduledoc "A slash command /hello for SPEC-EXTENSIONS tests."
  use Tau.Command

  @impl Tau.Command
  def name, do: "/hello"

  @impl Tau.Command
  def description, do: "Say hello. Reference extension command for SPEC-EXTENSIONS tests."

  @impl Tau.Command
  def execute(_args, _ctx) do
    {:inject, "Hello from HelloWorldExt!"}
  end
end
