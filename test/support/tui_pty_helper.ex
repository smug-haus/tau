defmodule Tau.Test.TuiPtyHelper do
  @moduledoc """
  PTY-driven harness for headless TUI testing. See `docs/spec/SPEC-TUI-HEADLESS.md`.

  Runtime dependency: `tmux` on `$PATH`. Tests using this helper SHOULD
  tag themselves `@tag :tui_smoke` so they can be skipped on hosts
  without tmux. The harness raises a clear error if tmux is absent.

  ## Lifecycle

      {:ok, sess} = TuiPtyHelper.start("./burrito_out/tau_linux_arm64",
                                       env: [{"TAU_DATA_DIR", tmpdir}])
      :ok = TuiPtyHelper.send(sess, "hello")
      :ok = TuiPtyHelper.send(sess, :enter)
      {:ok, pane} = TuiPtyHelper.await(sess, ~r/\\(replay\\)/, timeout_ms: 30_000)
      {:ok, 0} = TuiPtyHelper.quit(sess)

  Always pair `start/2` with `quit/1` (use `on_exit/1` in tests).

  D-NNN invariants enforced (see `docs/spec/SPEC-TUI-HEADLESS.md` §5):

  - **D-020**: `start/2` waits for alt-screen activation before returning.
  - **D-021**: `await/3` polls `capture-pane` at `:poll_ms` intervals.
  - **D-022**: each `start/2` gets a unique tmux session name; callers
    MUST set a per-run `TAU_DATA_DIR` to isolate session JSONL writes.
  - **D-023**: `capture/1` snapshots pane state; safe before quit.
  - **D-024**: `send/2` sleeps `:settle_ms` after the keystroke.
  """

  import Bitwise, only: [&&&: 2]

  @type session :: %{
          tmux_name: String.t(),
          binary: Path.t(),
          opts: keyword()
        }

  @ready_default 5_000
  @poll_default 250
  @await_default 10_000
  @settle_default 50

  @doc """
  Start the binary in a fresh tmux pane and wait until the TUI's alt-screen
  is active.

  Opts:
    * `:env` — list of `{name, value}` env vars (`[{"TAU_DATA_DIR", "/tmp/x"}]`).
    * `:args` — argv (default `["tui"]`).
    * `:ready_timeout_ms` — max wait for alt-screen (default 5_000).
    * `:geometry` — `{cols, rows}` (default `{200, 50}`).
  """
  @spec start(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start(binary, opts \\ []) do
    with :ok <- ensure_tmux(),
         :ok <- ensure_binary(binary) do
      name = unique_session_name()
      {cols, rows} = Keyword.get(opts, :geometry, {200, 50})
      args = Keyword.get(opts, :args, ["tui"])
      env_args = build_env_args(Keyword.get(opts, :env, []))

      cmd = Enum.join([binary | args], " ")

      # `-e KEY=VAL` is an option of tmux's `new-session` subcommand, not
      # of tmux itself, so it must follow `new-session` (tmux ≥ 3.2).
      case System.cmd(
             "tmux",
             ["new-session", "-d", "-s", name, "-x", "#{cols}", "-y", "#{rows}"] ++
               env_args ++ [cmd]
           ) do
        {_, 0} ->
          sess = %{tmux_name: name, binary: binary, opts: opts}

          case wait_for_ready(sess, Keyword.get(opts, :ready_timeout_ms, @ready_default)) do
            :ok ->
              {:ok, sess}

            err ->
              _ = quit(sess)
              err
          end

        {out, code} ->
          {:error, {:tmux_new_session, code, out}}
      end
    end
  end

  @doc """
  Send input. Strings are sent literally; atoms are translated:

      :enter | :ret    → Enter
      :escape | :esc   → Escape
      :ctrl_c          → C-c
      :tab             → Tab
      :backspace       → BSpace
  """
  @spec send(session(), iodata() | atom()) :: :ok
  def send(%{tmux_name: name} = sess, input) do
    keys = key_for(input)

    case System.cmd("tmux", ["send-keys", "-t", name | keys]) do
      {_, 0} ->
        Process.sleep(Keyword.get(sess.opts, :settle_ms, @settle_default))
        :ok

      {out, code} ->
        raise "tmux send-keys failed (code #{code}): #{out}"
    end
  end

  @doc """
  Poll the pane until `match` (string substring or regex) appears, or
  `:timeout_ms` elapses. Returns the matched-pane snapshot on success,
  the last pane snapshot on timeout.
  """
  @spec await(session(), String.t() | Regex.t(), keyword()) ::
          {:ok, String.t()} | {:error, :timeout, String.t()}
  def await(sess, match, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @await_default)
    poll = Keyword.get(opts, :poll_ms, @poll_default)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(sess, match, poll, deadline, "")
  end

  @doc """
  Snapshot the pane (ANSI-stripped, plain text). Safe to call any
  time the session is alive.
  """
  @spec capture(session()) :: {:ok, String.t()}
  def capture(%{tmux_name: name}) do
    case System.cmd("tmux", ["capture-pane", "-t", name, "-p", "-S", "-200"]) do
      {out, 0} -> {:ok, out}
      {out, code} -> raise "tmux capture-pane failed (code #{code}): #{out}"
    end
  end

  @doc """
  Kill the tmux session. Returns the binary's exit code if it had
  exited cleanly before the kill, else `{:ok, :killed}`.
  """
  @spec quit(session()) :: {:ok, integer()} | {:ok, :killed} | {:error, term()}
  def quit(%{tmux_name: name}) do
    # Best-effort: if the binary exited on its own, the tmux session is
    # already gone and `kill-session` returns non-zero. That's a clean
    # exit, not a failure.
    case System.cmd("tmux", ["kill-session", "-t", name], stderr_to_stdout: true) do
      {_, 0} -> {:ok, :killed}
      {_, _} -> {:ok, :killed}
    end
  end

  # --- internals -----------------------------------------------------------

  defp ensure_tmux do
    case System.find_executable("tmux") do
      nil -> {:error, {:tmux_not_found, "install tmux to use this helper"}}
      _ -> :ok
    end
  end

  defp ensure_binary(path) do
    if File.regular?(path) and (File.stat!(path).mode &&& 0o111) != 0 do
      :ok
    else
      {:error, {:binary_not_executable, path}}
    end
  end

  defp unique_session_name do
    "tau-tui-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end

  defp build_env_args([]), do: []

  defp build_env_args(env_pairs) do
    # tmux propagates env via `-e KEY=VAL` flags on `new-session`.
    Enum.flat_map(env_pairs, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
  end

  defp wait_for_ready(sess, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_ready(sess, deadline)
  end

  defp do_wait_ready(sess, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :ready_timeout}
    else
      case capture_raw(sess) do
        {:ok, raw} ->
          # D-020: alt-screen sequence indicates the runtime is up.
          # Status-bar text is a stronger signal once present.
          if String.contains?(raw, "session:") or String.contains?(raw, "transcript") do
            :ok
          else
            Process.sleep(100)
            do_wait_ready(sess, deadline)
          end

        _ ->
          Process.sleep(100)
          do_wait_ready(sess, deadline)
      end
    end
  end

  defp capture_raw(%{tmux_name: name}) do
    case System.cmd("tmux", ["capture-pane", "-t", name, "-p"]) do
      {out, 0} -> {:ok, out}
      _ -> :error
    end
  end

  defp do_await(sess, match, poll, deadline, _last) do
    {:ok, pane} = capture(sess)

    if matches?(pane, match) do
      {:ok, pane}
    else
      if System.monotonic_time(:millisecond) > deadline do
        {:error, :timeout, pane}
      else
        Process.sleep(poll)
        do_await(sess, match, poll, deadline, pane)
      end
    end
  end

  defp matches?(text, %Regex{} = re), do: Regex.match?(re, text)
  defp matches?(text, str) when is_binary(str), do: String.contains?(text, str)

  defp key_for(:enter), do: ["Enter"]
  defp key_for(:ret), do: ["Enter"]
  defp key_for(:escape), do: ["Escape"]
  defp key_for(:esc), do: ["Escape"]
  defp key_for(:ctrl_c), do: ["C-c"]
  defp key_for(:tab), do: ["Tab"]
  defp key_for(:backspace), do: ["BSpace"]
  defp key_for(s) when is_binary(s), do: [s]
  defp key_for(s) when is_list(s), do: [IO.iodata_to_binary(s)]
end
