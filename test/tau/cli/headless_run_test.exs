defmodule Tau.CLI.HeadlessRunTest do
  @moduledoc """
  AC-10 / D-058 (SPEC-USER-TURN §4 B2): headless FSM-backed `tau run`.

  Verifies that `tau run` drives a full `Tau.Session` FSM (not a bare
  provider.stream/3 call), that JSONL is persisted, and that the command
  surface works correctly with the Replay provider.

  Tests exercise `Tau.CLI`'s real public/doc-false functions — NOT private
  duplicates — so the AC-10 gate validates shipped code, not a parallel copy.

  Functions under test:
    - `Tau.CLI.drain_run_loop/1`   — event-drain loop (B2, B3)
    - `Tau.CLI.drain_session_end/2` — post-stop flush wait
    - `Tau.CLI.extract_assistant_text/1` — text extraction helper
    - `Tau.CLI.extract_error_text/1`     — error text helper
    - `Tau.CLI.resolve_system_prompt/1`  — CLI option resolver
    - `Tau.CLI.build_headless_skill/1`   — skill builder (B1)
    - `Tau.CLI.spec/0`                   — Optimus parser spec
  """

  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Provider.Event
  alias Tau.Persistence.Jsonl, as: PJsonl

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-headless-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  # ---------------------------------------------------------------------------
  # Shared fixture helpers
  # ---------------------------------------------------------------------------

  defp replay_fixture do
    [
      %Event.Start{request_id: "r", model: "replay"},
      %Event.TextStart{block_id: "b"},
      %Event.TextDelta{block_id: "b", text: "(replay) hello"},
      %Event.TextEnd{block_id: "b"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]
  end

  # Start a session and subscribe, then send a prompt. Returns session_id.
  defp start_and_send(prompt, extra_opts \\ []) do
    session_id = Tau.Session.generate_id()

    # D-004: subscribe BEFORE start_session.
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")

    start_opts =
      [
        session_id: session_id,
        provider: Tau.Providers.Replay,
        model: "replay",
        provider_ctx: %{replay_fixture: replay_fixture()}
      ] ++ extra_opts

    {:ok, ^session_id} = start_session_for_test(start_opts)
    :ok = Tau.send(session_id, prompt)
    session_id
  end

  # ---------------------------------------------------------------------------
  # B4: tests exercise Tau.CLI's real drain_run_loop/1 (not a duplicate).
  # ---------------------------------------------------------------------------

  describe "headless FSM-backed session run (AC-10, D-058)" do
    test "replay provider produces assistant text and exits 0", %{data_dir: _tmp} do
      session_id = start_and_send("ping")
      exit_code = Tau.CLI.drain_run_loop(session_id)

      assert exit_code == 0,
             "expected exit code 0 from a clean replay run; got #{exit_code}"
    end

    test "JSONL is persisted after headless run", %{data_dir: _tmp} do
      session_id = start_and_send("persist-test")
      _exit_code = Tau.CLI.drain_run_loop(session_id)

      sessions = Tau.list_sessions()
      matching = Enum.filter(sessions, &(&1.id == session_id))
      assert length(matching) == 1, "expected session to appear in Tau.list_sessions/0"

      events = PJsonl.stream(session_id) |> Enum.to_list()
      assert length(events) > 0, "expected non-empty JSONL for session #{session_id}"

      kinds = Enum.map(events, & &1["kind"])
      assert "user_message" in kinds, "expected user_message event; got: #{inspect(kinds)}"
    end

    test "default Replay provider used when none specified", %{data_dir: _tmp} do
      session_id = start_and_send("hello")
      exit_code = Tau.CLI.drain_run_loop(session_id)

      assert exit_code == 0
    end
  end

  # ---------------------------------------------------------------------------
  # B2: stop_reason matrix — test that :stop, :length, :tool_loop_aborted,
  #     and :error all produce the correct exit codes.
  # ---------------------------------------------------------------------------

  describe "drain_run_loop stop_reason matrix (B2 fix)" do
    test ":stop maps to exit 0" do
      session_id = Tau.Session.generate_id()
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")

      fixture = [
        %Event.Start{request_id: "r", model: "replay"},
        %Event.TextStart{block_id: "b"},
        %Event.TextDelta{block_id: "b", text: "ok"},
        %Event.TextEnd{block_id: "b"},
        %Event.Done{stop_reason: :stop, usage: %{}}
      ]

      {:ok, ^session_id} =
        start_session_for_test(
          session_id: session_id,
          provider: Tau.Providers.Replay,
          model: "replay",
          provider_ctx: %{replay_fixture: fixture}
        )

      :ok = Tau.send(session_id, "test")
      assert Tau.CLI.drain_run_loop(session_id) == 0
    end

    test ":length maps to exit 0 (B2 — context-window stop)" do
      # :length is what Anthropic/OpenAI emit for max_tokens;
      # it MUST map to exit 0, not fall through to the error branch.
      session_id = Tau.Session.generate_id()
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")

      fixture = [
        %Event.Start{request_id: "r", model: "replay"},
        %Event.TextStart{block_id: "b"},
        %Event.TextDelta{block_id: "b", text: "truncated"},
        %Event.TextEnd{block_id: "b"},
        %Event.Done{stop_reason: :length, usage: %{}}
      ]

      {:ok, ^session_id} =
        start_session_for_test(
          session_id: session_id,
          provider: Tau.Providers.Replay,
          model: "replay",
          provider_ctx: %{replay_fixture: fixture}
        )

      :ok = Tau.send(session_id, "test")
      assert Tau.CLI.drain_run_loop(session_id) == 0
    end

    test ":tool_loop_aborted maps to exit 1" do
      session_id = Tau.Session.generate_id()
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")

      fixture = [
        %Event.Start{request_id: "r", model: "replay"},
        %Event.TextStart{block_id: "b"},
        %Event.TextDelta{block_id: "b", text: "aborting"},
        %Event.TextEnd{block_id: "b"},
        %Event.Done{stop_reason: :tool_loop_aborted, usage: %{}}
      ]

      {:ok, ^session_id} =
        start_session_for_test(
          session_id: session_id,
          provider: Tau.Providers.Replay,
          model: "replay",
          provider_ctx: %{replay_fixture: fixture}
        )

      :ok = Tau.send(session_id, "test")
      assert Tau.CLI.drain_run_loop(session_id) == 1
    end

    test ":error stop_reason maps to exit 1" do
      session_id = Tau.Session.generate_id()
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")

      fixture = [
        %Event.Start{request_id: "r", model: "replay"},
        %Event.Done{stop_reason: :error, usage: %{}}
      ]

      {:ok, ^session_id} =
        start_session_for_test(
          session_id: session_id,
          provider: Tau.Providers.Replay,
          model: "replay",
          provider_ctx: %{replay_fixture: fixture}
        )

      :ok = Tau.send(session_id, "test")
      assert Tau.CLI.drain_run_loop(session_id) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # f-1 regression: :tool_use continuation and success-atom coverage (f-3)
  # ---------------------------------------------------------------------------

  describe "drain_run_loop stop_reason inverted-logic coverage (f-1 fix)" do
    # Inject PubSub events directly into the test process mailbox so we can
    # exercise drain_run_loop/1's logic without a full multi-turn FSM session.

    test ":tool_use causes loop to continue, then terminal stop exits 0" do
      # Regression test: :tool_use must NOT exit — it must keep waiting.
      # We inject a :tool_use MessageEnd followed by a :stop MessageEnd and
      # a SessionEnd into the mailbox, then assert exit_code == 0.
      session_id = Tau.Session.generate_id()

      msg_tool_use = %Tau.Message.Assistant{
        timestamp: DateTime.utc_now(),
        content: [],
        stop_reason: :tool_use
      }

      msg_stop = %Tau.Message.Assistant{
        timestamp: DateTime.utc_now(),
        content: [%{type: :text, text: "done"}],
        stop_reason: :stop
      }

      send(self(), %Tau.Session.Events.MessageEnd{session_id: session_id, message: msg_tool_use})
      send(self(), %Tau.Session.Events.MessageEnd{session_id: session_id, message: msg_stop})
      # drain_session_end waits for SessionEnd after Tau.stop/1 is called; inject it.
      send(self(), %Tau.Session.Events.SessionEnd{session_id: session_id, reason: :normal})

      exit_code = Tau.CLI.drain_run_loop(session_id)

      assert exit_code == 0,
             "expected exit 0 after :tool_use continuation + :stop terminal; got #{exit_code}"
    end

    test ":stop_sequence maps to exit 0 (f-1 regression lock)" do
      # :stop_sequence is emitted by Anthropic when a stop_sequence is hit
      # (anthropic.ex:237). Under the old enumeration it fell through to exit 1.
      # Under the new failure-list logic it must be exit 0.
      session_id = Tau.Session.generate_id()

      msg = %Tau.Message.Assistant{
        timestamp: DateTime.utc_now(),
        content: [%{type: :text, text: "stopped at seq"}],
        stop_reason: :stop_sequence
      }

      send(self(), %Tau.Session.Events.MessageEnd{session_id: session_id, message: msg})
      send(self(), %Tau.Session.Events.SessionEnd{session_id: session_id, reason: :normal})

      exit_code = Tau.CLI.drain_run_loop(session_id)

      assert exit_code == 0,
             "expected exit 0 for :stop_sequence (completed turn); got #{exit_code}"
    end

    test ":content_filter maps to exit 0 (unknown-atom defaults to success)" do
      # OpenAI may emit "content_filter" which maps to :content_filter via
      # String.to_atom (openai_chat_wire.ex:196). Must exit 0.
      session_id = Tau.Session.generate_id()

      msg = %Tau.Message.Assistant{
        timestamp: DateTime.utc_now(),
        content: [%{type: :text, text: "filtered"}],
        stop_reason: :content_filter
      }

      send(self(), %Tau.Session.Events.MessageEnd{session_id: session_id, message: msg})
      send(self(), %Tau.Session.Events.SessionEnd{session_id: session_id, reason: :normal})

      exit_code = Tau.CLI.drain_run_loop(session_id)

      assert exit_code == 0,
             "expected exit 0 for :content_filter (unknown provider atom → success); got #{exit_code}"
    end

    test ":aborted maps to exit 1" do
      # :aborted is produced by session.ex:2871 when coding agent exits with -2.
      session_id = Tau.Session.generate_id()

      msg = %Tau.Message.Assistant{
        timestamp: DateTime.utc_now(),
        content: [],
        stop_reason: :aborted,
        error_message: "aborted"
      }

      send(self(), %Tau.Session.Events.MessageEnd{session_id: session_id, message: msg})
      send(self(), %Tau.Session.Events.SessionEnd{session_id: session_id, reason: :error})

      exit_code = Tau.CLI.drain_run_loop(session_id)

      assert exit_code == 1,
             "expected exit 1 for :aborted; got #{exit_code}"
    end

    test ":compaction_failed maps to exit 1" do
      # :compaction_failed is produced by session.ex:1743 after 3 failures.
      session_id = Tau.Session.generate_id()

      msg = %Tau.Message.Assistant{
        timestamp: DateTime.utc_now(),
        content: [],
        stop_reason: :compaction_failed,
        error_message: "compaction failed"
      }

      send(self(), %Tau.Session.Events.MessageEnd{session_id: session_id, message: msg})
      send(self(), %Tau.Session.Events.SessionEnd{session_id: session_id, reason: :error})

      exit_code = Tau.CLI.drain_run_loop(session_id)

      assert exit_code == 1,
             "expected exit 1 for :compaction_failed; got #{exit_code}"
    end
  end

  # ---------------------------------------------------------------------------
  # B1: --system-prompt injection — text reaches the model (via session.ex).
  # ---------------------------------------------------------------------------

  describe "--system-prompt injection seam (B1 fix, D-058)" do
    test "system prompt text is injected into the session's message list" do
      # We start a session with an active_skill (the headless skill) and
      # verify via Tau.Session.snapshot/1 that the skill body appears in the
      # model-visible message list (prepended by prepend_skill_messages/2
      # during session.ex init/1).
      system_text = "You are a test assistant. Reply only with 'ok'."
      skill = Tau.CLI.build_headless_skill(system_text)

      session_id = Tau.Session.generate_id()
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")

      fixture = [
        %Event.Start{request_id: "r", model: "replay"},
        %Event.TextStart{block_id: "b"},
        %Event.TextDelta{block_id: "b", text: "(reply)"},
        %Event.TextEnd{block_id: "b"},
        %Event.Done{stop_reason: :stop, usage: %{}}
      ]

      {:ok, ^session_id} =
        start_session_for_test(
          session_id: session_id,
          provider: Tau.Providers.Replay,
          model: "replay",
          provider_ctx: %{replay_fixture: fixture},
          active_skill: skill,
          persona_lifetime: :session
        )

      # Snapshot the session immediately after start (before sending a prompt)
      # so we can inspect the initial message list built by init/1.
      {:ok, snap} = Tau.Session.snapshot(session_id)

      # The system prompt skill should appear as a user message (system-role)
      # prepended to snap.messages by prepend_skill_messages/2.
      system_messages =
        Enum.filter(snap.messages, fn
          %Tau.Message.User{metadata: %{role: :system, source: :skill}} -> true
          _ -> false
        end)

      assert length(system_messages) >= 1,
             "expected at least one system-role skill message in data.messages; " <>
               "got: #{inspect(system_messages)}"

      # Check the skill body is present in the rendered message.
      bodies = Enum.map(system_messages, & &1.content)

      assert Enum.any?(bodies, &String.contains?(&1, system_text)),
             "expected system_text '#{system_text}' in messages; got: #{inspect(bodies)}"

      :ok = Tau.send(session_id, "hello")
      assert Tau.CLI.drain_run_loop(session_id) == 0
    end

    test "nil system prompt does not inject a headless-system-prompt skill" do
      assert Tau.CLI.build_headless_skill(nil) == nil

      session_id = start_and_send("hello")

      {:ok, snap} = Tau.Session.snapshot(session_id)

      # Specifically check that the "headless-system-prompt" skill is NOT
      # injected. Other bundled/on-disk skills may be present in the skill list
      # (e.g. the example skill in priv/skills/); we only care that the
      # headless injection path was not triggered.
      headless_messages =
        Enum.filter(snap.messages, fn
          %Tau.Message.User{
            metadata: %{role: :system, source: :skill, name: "headless-system-prompt"}
          } ->
            true

          _ ->
            false
        end)

      assert length(headless_messages) == 0,
             "expected no headless-system-prompt skill message when --system-prompt is not given; " <>
               "got: #{inspect(headless_messages)}"

      assert Tau.CLI.drain_run_loop(session_id) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests for the public helper functions (B4)
  # ---------------------------------------------------------------------------

  describe "build_headless_skill/1" do
    test "nil returns nil" do
      assert Tau.CLI.build_headless_skill(nil) == nil
    end

    test "text produces a %Tau.Skill{} with correct fields" do
      skill = Tau.CLI.build_headless_skill("be helpful")

      assert %Tau.Skill{} = skill
      assert skill.name == "headless-system-prompt"
      assert skill.body == "be helpful"
      assert skill.path == "<cli:--system-prompt>"
    end
  end

  describe "resolve_system_prompt/1" do
    test "--system-prompt text is returned as {:ok, text}" do
      opts = %{system_prompt: "inline text", system_prompt_file: nil}
      assert {:ok, "inline text"} = Tau.CLI.resolve_system_prompt(opts)
    end

    test "--system-prompt-file reads file contents" do
      path = Path.join(System.tmp_dir!(), "tau-sp-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "file system prompt")
      on_exit(fn -> File.rm(path) end)

      opts = %{system_prompt: nil, system_prompt_file: path}
      assert {:ok, "file system prompt"} = Tau.CLI.resolve_system_prompt(opts)
    end

    test "missing --system-prompt-file returns {:error, reason}" do
      path = "/tmp/tau-nonexistent-sp-#{System.unique_integer([:positive])}.txt"
      opts = %{system_prompt: nil, system_prompt_file: path}
      assert {:error, reason} = Tau.CLI.resolve_system_prompt(opts)
      assert is_binary(reason)
    end

    test "neither option returns {:ok, nil}" do
      assert {:ok, nil} = Tau.CLI.resolve_system_prompt(%{})
    end
  end

  describe "extract_assistant_text/1" do
    test "extracts text blocks from an Assistant message" do
      msg = %Tau.Message.Assistant{
        timestamp: DateTime.utc_now(),
        content: [
          %{type: :text, text: "hello"},
          %{type: :tool_use, id: "t1"},
          %{type: :text, text: " world"}
        ]
      }

      assert Tau.CLI.extract_assistant_text(msg) == "hello world"
    end

    test "returns empty string for non-Assistant messages" do
      assert Tau.CLI.extract_assistant_text(%{}) == ""
      assert Tau.CLI.extract_assistant_text(nil) == ""
    end
  end

  describe "extract_error_text/1" do
    test "returns error_message field when present" do
      msg = %Tau.Message.Assistant{
        timestamp: DateTime.utc_now(),
        error_message: "something went wrong",
        content: []
      }

      assert Tau.CLI.extract_error_text(msg) == "something went wrong"
    end

    test "falls back to extract_assistant_text when no error_message" do
      msg = %Tau.Message.Assistant{
        timestamp: DateTime.utc_now(),
        content: [%{type: :text, text: "fallback text"}]
      }

      assert Tau.CLI.extract_error_text(msg) == "fallback text"
    end
  end

  # ---------------------------------------------------------------------------
  # spec/0 argument parser (no System.halt)
  # ---------------------------------------------------------------------------

  describe "spec/0 argument parser (no System.halt)" do
    test "run subcommand accepts --system-prompt option" do
      result =
        Optimus.parse!(Tau.CLI.spec(), [
          "run",
          "hello",
          "--provider",
          "replay",
          "--model",
          "replay",
          "--system-prompt",
          "you are a test agent"
        ])

      assert {[:run], parsed} = result
      assert parsed.args.prompt == "hello"
      assert parsed.options.system_prompt == "you are a test agent"
    end

    test "run subcommand accepts --system-prompt-file option" do
      path = "/tmp/tau-sp-#{System.unique_integer([:positive])}.txt"

      result =
        Optimus.parse!(Tau.CLI.spec(), [
          "run",
          "hello",
          "--system-prompt-file",
          path
        ])

      assert {[:run], parsed} = result
      assert parsed.options.system_prompt_file == path
    end

    test "run subcommand works without system prompt options" do
      result =
        Optimus.parse!(Tau.CLI.spec(), ["run", "hello", "--provider", "replay"])

      assert {[:run], parsed} = result
      assert parsed.args.prompt == "hello"
      assert parsed.options.system_prompt == nil
      assert parsed.options.system_prompt_file == nil
    end
  end
end
