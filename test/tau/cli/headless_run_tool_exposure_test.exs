defmodule Tau.CLI.HeadlessRunToolExposureTest do
  @moduledoc """
  #273 / D-059 (SPEC-USER-TURN §6, §4 B2): `tau run --system-prompt-file
  <path>` must parse the file's YAML frontmatter so the persona's
  declared `allowed-tools:` whitelist constrains the model-visible tool
  surface. Pre-fix, `Tau.CLI.build_headless_skill/1` ignored frontmatter
  entirely and built the skill with `allowed_tools: []`, which under
  PR #272's `active_skill_tool_specs/1` semantics (D-059) exposes every
  registered builtin — silently widening every persona's declared
  whitelist.

  This test exercises the real CLI dispatch path
  (`Tau.CLI.run_cmd/1` with an Optimus-parsed struct identical to what
  `main/1` would pass, plus a recording provider injected via
  `:default_provider`) and captures the actual `stream_opts.tools`
  list passed to the provider on the first turn.

  Three cases:

    1. `--system-prompt-file` pointing at a file with
       `allowed-tools: Bash Read` frontmatter ⇒ `stream_opts.tools` MUST
       be exactly `["Bash", "Read"]` (plus `__activate_skill__` only
       when discoverable skills exist).

    2. `--system-prompt-file` pointing at a file with no frontmatter ⇒
       all registered builtins are exposed (default unrestricted
       behaviour preserved).

    3. `--system-prompt <text>` (raw text, no file, no frontmatter) ⇒
       all registered builtins are exposed (default unrestricted
       behaviour preserved).

  `async: false` because the test (a) overrides `:default_provider`
  via `Application.put_env/3`, (b) overrides `:data_dir`, and
  (c) shares the globally-registered recorder name.
  """

  use ExUnit.Case, async: false

  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  @recorder_name :tau_headless_run_tool_exposure_recorder

  # ---------------------------------------------------------------------------
  # Recording provider — captures `stream_opts` on its first call and forwards
  # it to whatever pid is registered under `@recorder_name`. We can't plumb
  # ctx through `Tau.CLI.run_cmd/1` (no :provider_ctx seam), so the recorder
  # is registered globally per-test by `setup`.
  # ---------------------------------------------------------------------------

  defmodule RecordingProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_messages, opts, _ctx) do
      if pid = Process.whereis(:tau_headless_run_tool_exposure_recorder) do
        send(pid, {:stream_opts, opts})
      end

      events = [
        %Event.Start{request_id: "rec", model: "rec"},
        %Event.TextStart{block_id: "b0"},
        %Event.TextDelta{block_id: "b0", text: "(replay) hello"},
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
    tmp =
      Path.join(
        System.tmp_dir!(),
        "tau-headless-tool-exposure-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    # Route `run_cmd/1`'s `resolve_provider(nil)` → `Tau.Provider.default()`
    # to our recorder. The flag is omitted from argv so this branch fires.
    prior_provider = Application.get_env(:tau, :default_provider)
    Application.put_env(:tau, :default_provider, RecordingProvider)

    Process.register(self(), @recorder_name)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)

      case prior_provider do
        nil -> Application.delete_env(:tau, :default_provider)
        prev -> Application.put_env(:tau, :default_provider, prev)
      end
    end)

    %{tmp: tmp}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_via_cli(argv) do
    {[:run], parsed} = Optimus.parse!(Tau.CLI.spec(), argv)

    # `Tau.CLI.run_cmd/1` blocks in `drain_run_loop/1` until the session
    # finishes, consuming every PubSub message from the current process's
    # mailbox along the way — including the `{:stream_opts, opts}` the
    # RecordingProvider sends back here. To avoid that the test process
    # spawns a dedicated runner task whose mailbox absorbs `drain_run_loop/1`
    # while the test process waits only for `{:stream_opts, opts}`.
    test_pid = self()
    runner = spawn_link(fn -> send(test_pid, {:run_cmd_exit, Tau.CLI.run_cmd(parsed)}) end)

    assert_receive {:stream_opts, opts}, 10_000

    # Wait for the runner to finish so the on_exit teardown doesn't race the
    # still-running session FSM. The recorded run terminates quickly (one
    # turn, :end_turn stop_reason).
    assert_receive {:run_cmd_exit, exit_code}, 15_000
    assert exit_code == 0, "expected run_cmd/1 to exit 0; got #{exit_code}"

    # Defensive: ensure the runner pid has actually exited (it might if the
    # spawn_link target raised, but spawn_link + assert_receive above covers
    # the success path).
    _ = runner

    opts
  end

  defp tool_names(opts) do
    case opts[:tools] do
      nil -> []
      list when is_list(list) -> Enum.map(list, & &1.name)
    end
  end

  # ---------------------------------------------------------------------------
  # Case 1 — file with allowed-tools frontmatter constrains the tool list (#273).
  # ---------------------------------------------------------------------------

  test "--system-prompt-file with allowed-tools frontmatter exposes only the listed tools (#273)",
       %{tmp: tmp} do
    persona_path = Path.join(tmp, "persona.md")

    File.write!(persona_path, """
    ---
    name: scoped-persona
    description: "A persona that locks the model to Bash and Read."
    allowed-tools: Bash Read
    ---

    Persona body — instructs the model.
    """)

    opts =
      run_via_cli([
        "run",
        "go",
        "--system-prompt-file",
        persona_path
      ])

    names = tool_names(opts) |> Enum.sort()

    # The persona's frontmatter MUST constrain the model-visible surface:
    # Bash and Read appear; nothing else from the builtin set.
    assert "Bash" in names, "expected Bash in stream_opts.tools, got: #{inspect(names)}"
    assert "Read" in names, "expected Read in stream_opts.tools, got: #{inspect(names)}"

    # No other builtin should leak through.
    for forbidden <- ["Write", "Edit", "Agent", "Delegate"] do
      refute forbidden in names,
             "expected #{forbidden} NOT in stream_opts.tools (frontmatter restricts to Bash+Read); got: #{inspect(names)}"
    end

    # `__activate_skill__` may legitimately appear when discoverable skills
    # exist; ignore it. Anything else beyond the whitelist + activate-skill
    # is a regression of the #273 fix.
    extras =
      names
      |> Enum.reject(&(&1 in ["Bash", "Read", "__activate_skill__"]))

    assert extras == [],
           "expected stream_opts.tools to be a subset of [Bash, Read, __activate_skill__]; got extras: #{inspect(extras)}"
  end

  # ---------------------------------------------------------------------------
  # Case 2 — file with NO frontmatter preserves the default "all builtins" behaviour.
  # ---------------------------------------------------------------------------

  test "--system-prompt-file without allowed-tools frontmatter exposes every registered builtin",
       %{tmp: tmp} do
    persona_path = Path.join(tmp, "persona-nofm.md")
    File.write!(persona_path, "Just a body, no frontmatter.\n")

    opts = run_via_cli(["run", "go", "--system-prompt-file", persona_path])
    names = tool_names(opts)

    # Empty allowed_tools ⇒ every registered builtin is visible (D-059
    # unrestricted semantics; preserves the legacy headless behaviour).
    registered = Tau.Tool.list() |> Enum.sort()

    for builtin <- registered do
      assert builtin in names,
             "expected builtin #{inspect(builtin)} in stream_opts.tools, got: #{inspect(names)}"
    end

    refute names == ["__activate_skill__"],
           "stream_opts.tools collapsed to just __activate_skill__ — frontmatter-less skill silently locked the tool surface"
  end

  # ---------------------------------------------------------------------------
  # Case 3 — `--system-prompt <text>` (raw text, no file) preserves the default.
  # ---------------------------------------------------------------------------

  test "--system-prompt <text> (raw text, no frontmatter parse) exposes every registered builtin" do
    opts =
      run_via_cli([
        "run",
        "go",
        "--system-prompt",
        "You are a generic test persona."
      ])

    names = tool_names(opts)

    registered = Tau.Tool.list() |> Enum.sort()

    for builtin <- registered do
      assert builtin in names,
             "expected builtin #{inspect(builtin)} in stream_opts.tools, got: #{inspect(names)}"
    end

    refute names == ["__activate_skill__"],
           "stream_opts.tools collapsed to just __activate_skill__ — raw-text headless skill silently locked the tool surface"
  end
end
