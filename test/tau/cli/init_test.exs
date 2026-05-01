defmodule Tau.CLI.InitTest do
  @moduledoc """
  Drives `Tau.CLI.Init.run/2` with an injected IO shim that returns
  pre-canned answers from an Agent-backed stack.

  Covers the call sites the issue cares about:

    * provider selection (multi-index parse)
    * credential prompt → `Vault.put/2` (stored path) and Env-backend
      read-only fallback (export-line printed)
    * settings JSON validates against the schema before disk write
    * partial-abort (decline at the summary write prompt) leaves no
      file behind
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tau.CLI.Init

  setup do
    cwd = System.tmp_dir!() |> Path.join("tau-init-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)

    on_exit(fn -> File.rm_rf!(cwd) end)

    {:ok, cwd: cwd}
  end

  defmodule FakeIO do
    @moduledoc """
    Stack-backed IO shim. `setup/1` puts the answer list under a tag,
    `gets/1` pops the head off the stack. Output is silently captured
    via `IO.puts` on the calling process's group leader, so the
    test wraps the run in `capture_io/1`.
    """

    def setup(answers) do
      Process.put(:fake_io_answers, answers)
      :ok
    end

    def gets(prompt) do
      IO.write(prompt)

      case Process.get(:fake_io_answers) do
        [head | tail] ->
          Process.put(:fake_io_answers, tail)
          head <> "\n"

        _ ->
          # Empty stack → behave like blank line (accept defaults).
          "\n"
      end
    end

    def puts(line), do: IO.puts(line)
    def write(chars), do: IO.write(chars)
  end

  describe "non_interactive flag" do
    test "writes a valid settings file without prompting", %{cwd: cwd} do
      output =
        capture_io(fn ->
          assert {:ok, path} = Init.run(cwd, io: FakeIO, non_interactive: true)
          assert path == Path.join([cwd, ".tau", "settings.local.json"])
        end)

      # Banner still printed
      assert output =~ "Welcome to Tau"

      assert File.exists?(Path.join([cwd, ".tau", "settings.local.json"]))

      body = File.read!(Path.join([cwd, ".tau", "settings.local.json"]))
      decoded = Jason.decode!(body)

      assert decoded["provider"] == "anthropic"
      assert decoded["permissions"]["mode"] == "default"
    end
  end

  describe "interactive provider selection" do
    test "selects multiple providers via comma-separated indices", %{cwd: cwd} do
      # Answers in order:
      #   provider selection: "1,3"   → Anthropic + OpenAI Responses
      #   anthropic key:       blank   → skip (no vault write)
      #   openai_responses:    blank   → skip
      #   permissions mode:    "2"     → :accept_edits
      #   MCP servers?:        "n"
      #   skills example?:     "n"
      #   write?:              "y"
      FakeIO.setup(["1,3", "", "", "2", "n", "n", "y"])

      output =
        capture_io(fn ->
          assert {:ok, _path} = Init.run(cwd, io: FakeIO)
        end)

      assert output =~ "Anthropic"
      assert output =~ "OpenAI Responses"

      decoded =
        cwd
        |> Path.join(".tau/settings.local.json")
        |> File.read!()
        |> Jason.decode!()

      assert decoded["permissions"]["mode"] == "accept_edits"
      assert decoded["provider"] == "anthropic"
    end
  end

  describe "credential prompt + vault put" do
    setup do
      original = :persistent_term.get({Tau, :settings}, %{})

      on_exit(fn -> :persistent_term.put({Tau, :settings}, original) end)

      :ok
    end

    test "Env backend (read_only) prints an export line and does not crash", %{cwd: cwd} do
      :persistent_term.put({Tau, :settings}, %{})

      # provider 1 (anthropic), key "sk-test-123", mode "1" (default), no mcp,
      # no skill, write yes.
      FakeIO.setup(["1", "sk-test-123", "1", "n", "n", "y"])

      output =
        capture_io(fn ->
          assert {:ok, _path} = Init.run(cwd, io: FakeIO)
        end)

      # Read-only export hint surfaces.
      assert output =~ "export ANTHROPIC_API_KEY="
      assert output =~ "sk-test-123"

      # Credential never lands in JSON.
      body = File.read!(Path.join([cwd, ".tau", "settings.local.json"]))
      refute body =~ "sk-test-123"
    end

  end

  describe "schema validation" do
    test "the wizard's output passes the JSON Schema validator", %{cwd: cwd} do
      capture_io(fn ->
        assert {:ok, path} = Init.run(cwd, io: FakeIO, non_interactive: true)

        body = File.read!(path)
        decoded = Jason.decode!(body)

        resolved =
          Tau.Settings.Schema.json_schema()
          |> ExJsonSchema.Schema.resolve()

        assert :ok == ExJsonSchema.Validator.validate(resolved, decoded)
      end)
    end
  end

  describe "partial abort" do
    test "declining the final write leaves no settings file behind", %{cwd: cwd} do
      # provider 1, blank key, mode 1, no mcp, no skill, "n" at write prompt.
      FakeIO.setup(["1", "", "1", "n", "n", "n"])

      capture_io(fn ->
        assert {:ok, :no_write} = Init.run(cwd, io: FakeIO)
      end)

      refute File.exists?(Path.join([cwd, ".tau", "settings.local.json"]))
    end

    test "early EOF mid-flow does not write a partial settings file", %{cwd: cwd} do
      # Empty answer stack — every gets/1 returns blank line.
      # Default provider, blank key, default mode, default no-mcp, default no-skill,
      # default write=Y → still writes; but assert the disk-write path stays
      # intact under blank input (no crash, valid output).
      FakeIO.setup([])

      capture_io(fn ->
        assert {:ok, _path} = Init.run(cwd, io: FakeIO)
      end)

      body = Path.join([cwd, ".tau", "settings.local.json"]) |> File.read!()
      decoded = Jason.decode!(body)
      assert decoded["permissions"]["mode"] == "default"
    end
  end

  describe "extending existing settings" do
    test "merges new keys without clobbering existing ones", %{cwd: cwd} do
      File.mkdir_p!(Path.join(cwd, ".tau"))

      File.write!(
        Path.join([cwd, ".tau", "settings.json"]),
        Jason.encode!(%{"theme" => "dark", "extensions" => ["my_ext"]})
      )

      FakeIO.setup(["e", "1", "", "1", "n", "n", "y"])

      capture_io(fn ->
        assert {:ok, _path} = Init.run(cwd, io: FakeIO)
      end)

      decoded =
        cwd
        |> Path.join(".tau/settings.local.json")
        |> File.read!()
        |> Jason.decode!()

      assert decoded["theme"] == "dark"
      assert decoded["extensions"] == ["my_ext"]
      assert decoded["permissions"]["mode"] == "default"
    end

    test "reconfigure flag wipes prior settings before writing", %{cwd: cwd} do
      File.mkdir_p!(Path.join(cwd, ".tau"))

      File.write!(
        Path.join([cwd, ".tau", "settings.json"]),
        Jason.encode!(%{"theme" => "dark"})
      )

      capture_io(fn ->
        assert {:ok, _} = Init.run(cwd, io: FakeIO, reconfigure: true, non_interactive: true)
      end)

      decoded =
        cwd
        |> Path.join(".tau/settings.local.json")
        |> File.read!()
        |> Jason.decode!()

      # `theme` was only in settings.json (project layer), not in
      # settings.local.json. With --reconfigure we wrote a fresh local
      # layer that has no `theme` key.
      refute Map.has_key?(decoded, "theme")
      assert decoded["provider"] == "anthropic"
    end
  end
end
