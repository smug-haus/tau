defmodule Tau.Session.PromptTemplateDispatchTest do
  @moduledoc """
  Integration tests for the prompt-template branch of `classify_slash_command/4`.

  These tests exercise the full session-FSM path: a `/template-name args`
  message sent via `Tau.send/2` routes through `classify_slash_command/4`,
  which looks up the template from `data.prompt_templates`, renders the body
  via `Tau.PromptTemplates.render/3`, and returns `{:sync, rewritten_msg}` —
  causing the rendered content to reach the provider as the user turn.

  ## Acceptance criteria covered

  - **AC-1**: rendered text (no `{{` remaining) reaches the provider's
    `stream/3` as the user message content.
  - **AC-2**: a template named like a built-in (`ping`) or a skill is shadowed
    by the higher-precedence entry.
  - **AC-8**: the `classify_slash_command/4` template branch has direct
    session-level coverage.

  These tests use the `RecordingProvider` pattern from other session tests:
  a `Tau.Provider` implementation that captures the `messages` argument of
  `stream/3` so we can assert on the rendered content.
  """

  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Session.Events, as: SE

  @moduletag :tmp_dir

  # ---------------------------------------------------------------------------
  # Provider that captures the messages arg for assertion
  # ---------------------------------------------------------------------------

  defmodule CapturingProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl Tau.Provider
    def default_model, do: "capture-model"

    @impl Tau.Provider
    def capabilities,
      do: %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl Tau.Provider
    def configure(opts), do: {:ok, opts}

    @impl Tau.Provider
    def stream(messages, _opts, ctx) do
      owner = ctx[:owner]
      if owner, do: send(owner, {:messages_captured, messages})

      stream =
        Stream.map(
          [
            %Tau.Provider.Event.Start{request_id: "r", model: "capture-model"},
            %Tau.Provider.Event.TextStart{block_id: "b"},
            %Tau.Provider.Event.TextDelta{block_id: "b", text: "ack"},
            %Tau.Provider.Event.TextEnd{block_id: "b"},
            %Tau.Provider.Event.Done{stop_reason: :stop, usage: %{}}
          ],
          & &1
        )

      {:ok, stream}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_session_with_templates(sid, templates, %{tmp_dir: tmp}) do
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    # Write templates to <tmp>/.tau/prompts/ so discover/1 picks them up
    prompts_dir = Path.join(tmp, ".tau/prompts")
    File.mkdir_p!(prompts_dir)

    for {name, {body, fm}} <- templates do
      content =
        case fm do
          nil -> body
          frontmatter -> "---\n#{frontmatter}\n---\n#{body}"
        end

      File.write!(Path.join(prompts_dir, "#{name}.md"), content)
    end

    {:ok, ^sid} =
      start_session_for_test(
        provider: CapturingProvider,
        model: "capture-model",
        session_id: sid,
        provider_ctx: %{owner: self()},
        # Use tmp as cwd so discover/1 finds our templates
        cwd: tmp
      )

    :ok
  end

  defp drain_turn(sid) do
    receive do
      %SE.MessageEnd{session_id: ^sid} -> :ok
    after
      5_000 -> {:error, :timeout}
    end
  end

  # ---------------------------------------------------------------------------
  # AC-1 / AC-8: template body rendered, no {{ remaining
  # ---------------------------------------------------------------------------

  describe "template dispatch — AC-1 / AC-8" do
    test "slash command with template renders variables into user turn content", ctx do
      sid = "pt-dispatch-ac1-#{System.unique_integer([:positive])}"

      fm = "description: Refactor\nvariables:\n  - module\n  - function"
      body = "Please refactor {{module}}.{{function}} for OTP compliance."

      :ok =
        start_session_with_templates(
          sid,
          %{"refactor-otp" => {body, fm}},
          ctx
        )

      Tau.send(sid, "/refactor-otp Tau.Session start_session")

      assert_receive {:messages_captured, messages}, 3_000

      # The last User message is the rendered user turn
      # (system skill messages may also appear as User messages)
      user_msgs = Enum.filter(messages, &match?(%Tau.Message.User{}, &1))
      user_msg = List.last(user_msgs)
      assert user_msg, "expected at least one User message to reach the provider"

      rendered = user_msg.content
      assert is_binary(rendered)

      refute rendered =~ "{{",
             "rendered content must have no {{ remaining; got: #{rendered}"

      assert rendered =~ "Tau.Session",
             "rendered content must include the substituted module name"

      assert rendered =~ "start_session",
             "rendered content must include the substituted function name"

      assert :ok = drain_turn(sid)
    end

    test "unknown variable in template renders as literal, does not crash session", ctx do
      sid = "pt-dispatch-unknown-#{System.unique_integer([:positive])}"

      body = "Module: {{module}}. Unknown: {{ghost}}."
      fm = "variables:\n  - module"

      :ok = start_session_with_templates(sid, %{"test-tpl" => {body, fm}}, ctx)

      Tau.send(sid, "/test-tpl MyModule")

      assert_receive {:messages_captured, messages}, 3_000

      user_msgs = Enum.filter(messages, &match?(%Tau.Message.User{}, &1))
      user_msg = List.last(user_msgs)
      assert user_msg

      rendered = user_msg.content
      assert rendered =~ "MyModule"
      assert rendered =~ "{{ghost}}", "unknown variable must render as literal {{ghost}}"

      assert :ok = drain_turn(sid)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-2: precedence — built-in shadows same-named template
  # ---------------------------------------------------------------------------

  describe "template dispatch — AC-2: precedence" do
    test "a template named 'ping' is shadowed by the built-in /ping", ctx do
      sid = "pt-dispatch-ac2-#{System.unique_integer([:positive])}"

      body = "TEMPLATE BODY — should not reach provider"

      :ok = start_session_with_templates(sid, %{"ping" => {body, nil}}, ctx)

      Tau.send(sid, "/ping")

      # Built-in /ping produces a SystemNotice "pong", never a provider turn
      assert_receive %SE.SystemNotice{session_id: ^sid, text: "pong"}, 2_000

      # The template body MUST NOT reach the provider
      refute_receive {:messages_captured, _}, 500
    end
  end
end
