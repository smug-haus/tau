defmodule Tau.Session.ActiveSkillToolExposureTest do
  @moduledoc """
  D-059 / AC-10 (SPEC-USER-TURN §6, §4 B2): when `data.active_skill` is
  set at session start, the model-visible tool list passed to
  `provider.stream/3` MUST include the active skill's `allowed_tools` —
  not just the synthetic `__activate_skill__` tool.

  Two paths are covered:

    * **Unrestricted active skill** (`allowed_tools: []`, the default
      shape produced by `Tau.CLI.build_headless_skill/1` and the
      `tau-coordinator` persona when activated) ⇒ every registered
      built-in tool MUST appear in `stream_opts.tools`.

    * **Restricted active skill** (`allowed_tools: [names]`) ⇒ only the
      listed tools appear.

  Pre-fix (issue #267) symptom: the headless `tau run
  --system-prompt-file` shape set `data.active_skill` but
  `stream_opts.tools` only ever contained `__activate_skill__`. The
  model could not call any built-in (`Bash`, `Read`, `Agent`, …) and
  the M1 coordinator persona was inert.
  """

  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  # ---------------------------------------------------------------------------
  # Recording provider — captures `stream_opts` on its first call and forwards
  # the captured map to the test pid stored in `ctx[:recorder]`.
  # ---------------------------------------------------------------------------

  defmodule RecordingProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_messages, opts, ctx) do
      if pid = ctx[:recorder], do: send(pid, {:stream_opts, opts})

      events = [
        %Event.Start{request_id: "rec", model: "rec"},
        %Event.TextStart{block_id: "b0"},
        %Event.TextDelta{block_id: "b0", text: "(recorded)"},
        %Event.TextEnd{block_id: "b0"},
        %Event.Done{stop_reason: :end_turn, usage: %{}}
      ]

      {:ok, events}
    end

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: true,
        vision: false,
        prompt_caching: false,
        parallel_tools: true
      }

    @impl true
    def default_model, do: "rec"
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-tool-exposure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  defp drive(active_skill) do
    sid = "tool-exposure-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: RecordingProvider,
        model: "rec",
        session_id: sid,
        active_skill: active_skill,
        # D-059 only fires when the FSM actually reaches :start_provider.
        # Plumb the test pid through the provider ctx so RecordingProvider
        # can forward the captured stream_opts back here.
        provider_ctx: %{recorder: self()}
      )

    :ok = Tau.send(sid, "go")

    assert_receive {:stream_opts, opts}, 5_000
    # Wait for the turn to complete so the on_exit Tau.stop/1 doesn't
    # race the streaming task.
    assert_receive %SE.MessageEnd{}, 5_000
    opts
  end

  defp tool_names(opts) do
    case opts[:tools] do
      nil -> []
      list when is_list(list) -> Enum.map(list, & &1.name)
    end
  end

  test "unrestricted active_skill (allowed_tools: []) exposes every registered built-in" do
    skill = %Tau.Skill{
      name: "headless-system-prompt",
      body: "You are the coordinator.",
      path: "<test>",
      description: "headless",
      allowed_tools: []
    }

    opts = drive(skill)

    names = tool_names(opts)

    # The active skill's empty allowed_tools list MUST be treated as
    # "no whitelist declared", surfacing every registered built-in.
    # `Tau.Tool.list/0` is the authoritative source post-`register_builtins/0`.
    registered = Tau.Tool.list() |> Enum.sort()

    # Every registered built-in MUST appear by name in the model-visible
    # tool list — regardless of whether the activate-skill tool is also
    # present.
    for builtin <- registered do
      assert builtin in names,
             "expected built-in tool #{inspect(builtin)} in stream_opts.tools, got #{inspect(names)}"
    end

    # And the surface MUST be richer than just the activate-skill tool —
    # this is the literal regression the bug fix targets.
    refute names == ["__activate_skill__"],
           "stream_opts.tools collapsed to just __activate_skill__ — active_skill ignored"
  end

  test "restricted active_skill (allowed_tools: [names]) exposes only the listed tools" do
    skill = %Tau.Skill{
      name: "narrow",
      body: "Only Bash.",
      path: "<test>",
      description: "narrow",
      allowed_tools: ["Bash"]
    }

    opts = drive(skill)

    names = tool_names(opts)

    # The named subset MUST appear; non-listed built-ins MUST NOT.
    assert "Bash" in names
    refute "Read" in names
    refute "Write" in names
    refute "Edit" in names
    refute "Agent" in names

    # Unknown names in allowed_tools are silently skipped (matches
    # Tau.Permissions.Evaluator posture); the listed-and-known set is
    # what the model sees.
    skill_unknown = %Tau.Skill{
      name: "ghost",
      body: "",
      path: "<test>",
      allowed_tools: ["NoSuchToolEverRegistered"]
    }

    opts2 = drive(skill_unknown)
    names2 = tool_names(opts2)
    refute "NoSuchToolEverRegistered" in names2
  end
end
