defmodule Tau.Tools.BuiltinTest do
  use ExUnit.Case, async: true

  alias Tau.Tool.Context
  alias Tau.Tools.Builtin.{Bash, Edit, Read, Write}

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-builtin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{cwd: tmp}
  end

  defp ctx(cwd) do
    Context.new(tool_call_id: "tc1", session_id: "s1", cwd: cwd)
  end

  describe "Read" do
    test "reads a small file", %{cwd: cwd} do
      File.write!(Path.join(cwd, "hi.txt"), "alpha\nbeta\ngamma")
      {:ok, r} = Read.execute(%{"path" => "hi.txt"}, ctx(cwd))
      assert r.content =~ "alpha"
      assert r.details.total_lines == 3
      refute r.details.truncated?
    end

    test "missing file returns is_error", %{cwd: cwd} do
      {:ok, r} = Read.execute(%{"path" => "nope.txt"}, ctx(cwd))
      assert r.is_error
      assert r.content =~ "not found"
    end
  end

  describe "Write" do
    test "creates parent dirs", %{cwd: cwd} do
      {:ok, r} = Write.execute(%{"path" => "a/b/c.txt", "content" => "hi"}, ctx(cwd))
      refute r.is_error
      assert File.read!(Path.join(cwd, "a/b/c.txt")) == "hi"
    end
  end

  describe "Edit" do
    test "replaces a unique occurrence", %{cwd: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "foo bar baz")

      {:ok, r} =
        Edit.execute(
          %{"path" => "f.txt", "edits" => [%{"old_text" => "bar", "new_text" => "QUX"}]},
          ctx(cwd)
        )

      refute r.is_error
      assert File.read!(Path.join(cwd, "f.txt")) == "foo QUX baz"
    end

    test "rejects ambiguous old_text", %{cwd: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "x x x")

      {:ok, r} =
        Edit.execute(
          %{"path" => "f.txt", "edits" => [%{"old_text" => "x", "new_text" => "y"}]},
          ctx(cwd)
        )

      assert r.is_error
      assert r.content =~ "3 times"
    end

    test "rejects missing old_text", %{cwd: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "abc")

      {:ok, r} =
        Edit.execute(
          %{"path" => "f.txt", "edits" => [%{"old_text" => "zzz", "new_text" => "y"}]},
          ctx(cwd)
        )

      assert r.is_error
      assert r.content =~ "not found"
    end
  end

  describe "Bash" do
    test "captures stdout and exit_status", %{cwd: cwd} do
      {:ok, r} = Bash.execute(%{"command" => "echo hello"}, ctx(cwd))
      assert r.content =~ "hello"
      assert r.details.exit_status == 0
      refute r.is_error
    end

    test "non-zero exit sets is_error", %{cwd: cwd} do
      {:ok, r} = Bash.execute(%{"command" => "false"}, ctx(cwd))
      assert r.is_error
      assert r.details.exit_status != 0
    end

    test "merged stderr lands in content", %{cwd: cwd} do
      {:ok, r} = Bash.execute(%{"command" => "echo err 1>&2"}, ctx(cwd))
      assert r.content =~ "err"
    end
  end
end
