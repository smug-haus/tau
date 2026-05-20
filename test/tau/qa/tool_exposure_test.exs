defmodule Tau.QA.ToolExposureTest do
  @moduledoc """
  Layer (E) of `mix tau.qa` (issue #268).

  The defect this guards against (issue #267): the coordinator
  persona was loaded but the model's tool list contained only
  `__activate_skill__` — the headline builtins (`Agent`, `Bash`,
  `Read`, `Edit`, `Write`) never reached the provider, so the
  model literally could not call its tools.

  PR #272's `Tau.Session.model_visible_tool_specs/1`,
  `active_skill_tool_specs/1`, and `tool_spec_for/1` helpers fix this
  by unioning the activate-skill tool with the active skill's
  resolved tool specs (D-059 semantics).

  This test pins the in-memory contract directly: start a session
  with `:active_skill` set to a `%Tau.Skill{allowed_tools: []}`
  (the headless-skill default that PR #273 also produces), drive a
  single turn, and assert the captured `stream_opts[:tools]` contains
  every name in `Tau.Tool.list/0`.

  `async: false` because (a) the recorder registers itself by a
  globally-unique atom name, and (b) `:data_dir` is overridden via
  `Application.put_env/3`.

  ## Fail-before / pass-after harness

  Reverting PR #272's `model_visible_tool_specs/1` to its predecessor
  (which only exposed `skill_activation_tool_spec(data.skills)`)
  must make this test FAIL with `stream_opts.tools` containing only
  `__activate_skill__`. The fails-before transcript lives in the
  PR description for #268.
  """

  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Test.CapturingProvider

  @capture_name CapturingProvider.default_capture_name()

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "tau-qa-tool-exposure-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    # Register the test process so CapturingProvider's stream/3 finds
    # it via Process.whereis/1 in the absence of an explicit
    # :report_to in ctx.
    Process.register(self(), @capture_name)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{tmp: tmp}
  end

  defp tool_names(opts) do
    case opts[:tools] do
      nil -> []
      list when is_list(list) -> Enum.map(list, & &1.name)
    end
  end

  test "active_skill with allowed_tools: [] exposes every registered builtin (regression guard for #267)",
       %{tmp: tmp} do
    # The headless-skill default that `Tau.CLI.build_headless_skill/1`
    # produces under PR #273: a persona-bearing skill with
    # `allowed_tools: []` meaning "unrestricted — all builtins".
    headless_skill = %Tau.Skill{
      name: "headless-test-persona",
      body: "You are a test persona.",
      path: "(synthetic)",
      description: "A synthetic persona for the tool-exposure smoke.",
      allowed_tools: [],
      disable_model_invocation: false
    }

    sid = "qa-tool-exposure-#{System.unique_integer([:positive])}"

    {:ok, ^sid} =
      start_session_for_test(
        provider: CapturingProvider,
        model: "capturing",
        session_id: sid,
        cwd: tmp,
        active_skill: headless_skill
      )

    Tau.send(sid, "go")

    assert_receive {:stream_opts, opts}, 10_000

    names = tool_names(opts) |> Enum.sort()

    # The set of builtins registered for any live session — the very
    # set the production headless-skill path expects to surface.
    registered = Tau.Tool.list() |> Enum.sort()

    refute registered == [],
           "Tau.Tool.list/0 returned no registered builtins — fixture state is wrong"

    for builtin <- registered do
      assert builtin in names,
             "expected registered builtin #{inspect(builtin)} in stream_opts.tools, got: #{inspect(names)}"
    end

    # The headline regression: pre-#272, the only model-visible tool
    # was `__activate_skill__`. That collapse is exactly what this
    # test forbids.
    refute names == ["__activate_skill__"],
           "stream_opts.tools collapsed to just __activate_skill__ — the #267 regression"
  end
end
