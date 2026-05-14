defmodule Tau.CLI.SessionsShowTest do
  @moduledoc """
  AC-7 (SPEC-USER-TURN §7): headless portion — `tau sessions show <id>`.

  Exercises the logic underlying the `sessions_show` private function in
  `Tau.CLI`: `Tau.Persistence.impl().stream(id)` followed by
  `Jason.encode!/1` per event (JSONL output, one JSON object per line).

  Note: `Tau.CLI.main/1` calls `System.halt/1` after every dispatch arm,
  which would terminate the test VM. Following the pattern established in
  `test/tau/cli/config_test.exs`, we call the underlying logic directly
  instead of routing through `main/1`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tau.Persistence.Jsonl, as: PJsonl

  @model "claude-haiku-show-test"

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-sessions-show-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  defp make_event(kind, content, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "evt_#{System.unique_integer([:positive])}"),
      "parent_id" => Keyword.get(opts, :parent_id, nil),
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => kind,
      "data" => %{"content" => content}
    }
  end

  defp synthesize_session(session_id, cwd, events) do
    opts = [cwd: cwd, model: @model]
    {:ok, handle} = PJsonl.open(session_id, opts)

    handle =
      Enum.reduce(events, handle, fn event, h ->
        {:ok, h2} = PJsonl.append(h, event)
        h2
      end)

    :ok = PJsonl.close(handle)
    :ok
  end

  defp sessions_show_output(session_id) do
    capture_io(fn ->
      Tau.Persistence.impl().stream(session_id)
      |> Enum.each(&IO.puts(Jason.encode!(&1)))
    end)
  end

  test "output is JSONL: each non-empty line is parseable JSON", %{data_dir: tmp} do
    session_id = "show-jsonl-#{System.unique_integer([:positive])}"
    cwd = Path.join(tmp, "proj-show")
    File.mkdir_p!(cwd)

    events = [
      make_event("user_message", "hello"),
      make_event("assistant_message", "world")
    ]

    :ok = synthesize_session(session_id, cwd, events)

    output = sessions_show_output(session_id)

    lines = String.split(output, "\n", trim: true)

    # header + 2 events = 3 lines minimum
    assert length(lines) >= 3,
           "expected at least 3 lines (header + 2 events); got #{length(lines)}"

    Enum.each(lines, fn line ->
      case Jason.decode(line) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          flunk("line is not valid JSON (#{inspect(reason)}): #{inspect(line)}")
      end
    end)
  end

  test "no trailing comma between lines (valid JSONL, not JSON array)", %{data_dir: tmp} do
    session_id = "show-no-comma-#{System.unique_integer([:positive])}"
    cwd = Path.join(tmp, "proj-comma")
    File.mkdir_p!(cwd)

    :ok = synthesize_session(session_id, cwd, [make_event("user_message", "test")])

    output = sessions_show_output(session_id)

    lines = String.split(output, "\n", trim: true)

    Enum.each(lines, fn line ->
      refute String.ends_with?(line, ","),
             "JSONL lines must not end with commas; got: #{inspect(line)}"
    end)
  end

  test "events contain the kinds and content written", %{data_dir: tmp} do
    session_id = "show-content-#{System.unique_integer([:positive])}"
    cwd = Path.join(tmp, "proj-content")
    File.mkdir_p!(cwd)

    events = [
      make_event("user_message", "hello", id: "evt_user_1"),
      make_event("assistant_message", "world", id: "evt_asst_1")
    ]

    :ok = synthesize_session(session_id, cwd, events)

    output = sessions_show_output(session_id)

    decoded =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    kinds = Enum.map(decoded, & &1["kind"])

    assert "session_header" in kinds,
           "expected session_header event; got kinds: #{inspect(kinds)}"

    assert "user_message" in kinds,
           "expected user_message event; got kinds: #{inspect(kinds)}"

    assert "assistant_message" in kinds,
           "expected assistant_message event; got kinds: #{inspect(kinds)}"

    user_event = Enum.find(decoded, &(&1["kind"] == "user_message"))
    assert user_event["data"]["content"] == "hello"

    assistant_event = Enum.find(decoded, &(&1["kind"] == "assistant_message"))
    assert assistant_event["data"]["content"] == "world"
  end

  test "session_header event contains the session id and model", %{data_dir: tmp} do
    session_id = "show-header-#{System.unique_integer([:positive])}"
    cwd = Path.join(tmp, "proj-header")
    File.mkdir_p!(cwd)

    :ok = synthesize_session(session_id, cwd, [make_event("user_message", "ping")])

    output = sessions_show_output(session_id)

    decoded =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    header = Enum.find(decoded, &(&1["kind"] == "session_header"))
    assert header != nil, "expected a session_header event in output"
    assert header["data"]["session_id"] == session_id
    assert header["data"]["model"] == @model
  end

  test "unknown session id returns empty output" do
    output = sessions_show_output("nonexistent-session-id-#{System.unique_integer([:positive])}")
    assert output == ""
  end
end
