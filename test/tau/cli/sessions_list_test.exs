defmodule Tau.CLI.SessionsListTest do
  @moduledoc """
  AC-7 (SPEC-USER-TURN §7): headless portion — `tau sessions list`.

  Exercises the logic underlying the `sessions_list` private function in
  `Tau.CLI`: `Tau.list_sessions/0` (which delegates to
  `Tau.Persistence.impl().list/1`) and the tab-separated line format it
  emits.

  Note: `Tau.CLI.main/1` calls `System.halt/1` after every dispatch arm,
  which would terminate the test VM. Following the pattern established in
  `test/tau/cli/config_test.exs`, we call the underlying logic directly
  instead of routing through `main/1`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tau.Persistence.Jsonl, as: PJsonl

  # A minimal unique-integer cwd so the JSONL hash-bucket doesn't
  # collide across parallel test runs.
  @model "claude-haiku-test"

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-sessions-list-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  defp synthesize_session(session_id, cwd, opts \\ []) do
    full_opts =
      Keyword.merge(
        [cwd: cwd, model: @model],
        opts
      )

    {:ok, handle} = PJsonl.open(session_id, full_opts)

    event = %{
      "id" => "evt_test_#{System.unique_integer([:positive])}",
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "user_message",
      "data" => %{"content" => "hello"}
    }

    {:ok, handle} = PJsonl.append(handle, event)
    :ok = PJsonl.close(handle)
    :ok
  end

  defp sessions_list_output do
    capture_io(fn ->
      Tau.list_sessions()
      |> Enum.each(fn s ->
        IO.puts("#{s.id}\t#{s.cwd}\t#{s.model}\t#{s.created_at}")
      end)
    end)
  end

  test "lists a synthesized session with id, cwd, and model", %{data_dir: tmp} do
    session_id = "list-test-#{System.unique_integer([:positive])}"
    cwd = Path.join(tmp, "project")
    File.mkdir_p!(cwd)

    :ok = synthesize_session(session_id, cwd)

    output = sessions_list_output()

    assert output =~ session_id,
           "stdout must contain the session id; got:\n#{output}"

    assert output =~ cwd,
           "stdout must contain the cwd; got:\n#{output}"

    assert output =~ @model,
           "stdout must contain the model name; got:\n#{output}"
  end

  test "lists multiple sessions", %{data_dir: tmp} do
    id_a = "list-multi-a-#{System.unique_integer([:positive])}"
    id_b = "list-multi-b-#{System.unique_integer([:positive])}"
    cwd_a = Path.join(tmp, "proj-a")
    cwd_b = Path.join(tmp, "proj-b")
    File.mkdir_p!(cwd_a)
    File.mkdir_p!(cwd_b)

    :ok = synthesize_session(id_a, cwd_a)
    :ok = synthesize_session(id_b, cwd_b, model: "claude-opus-test")

    output = sessions_list_output()

    assert output =~ id_a
    assert output =~ id_b
    assert output =~ cwd_a
    assert output =~ cwd_b
  end

  test "emits nothing when no sessions exist" do
    output = sessions_list_output()
    assert output == ""
  end

  test "each line is tab-separated with four fields", %{data_dir: tmp} do
    session_id = "list-fields-#{System.unique_integer([:positive])}"
    cwd = Path.join(tmp, "proj-fields")
    File.mkdir_p!(cwd)
    :ok = synthesize_session(session_id, cwd)

    output = sessions_list_output()

    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, session_id))

    assert length(lines) == 1, "expected exactly one line for session #{session_id}"

    [line] = lines
    fields = String.split(line, "\t")

    assert length(fields) == 4,
           "expected 4 tab-separated fields (id, cwd, model, created_at); got #{inspect(fields)}"
  end
end
