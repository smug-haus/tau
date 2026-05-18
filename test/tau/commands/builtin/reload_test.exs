defmodule Tau.Commands.Builtin.ReloadTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Reload`.

  Verifies:
  - `name/0` returns `"/reload"`.
  - `run/2` returns `{:mutate, fun, notice}` with the correct notice.
  - The mutate `fun` rebuilds `data.skills` from disk (pure transform).
  - Behaviour compliance.
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin.Reload

  describe "name/0" do
    test "returns \"/reload\"" do
      assert Reload.name() == "/reload"
    end
  end

  describe "run/2 — outcome shape" do
    test "returns {:mutate, fun, notice}" do
      assert {:mutate, fun, notice} = Reload.run("", %{cwd: "."})
      assert is_function(fun, 1)
      assert is_binary(notice)
      assert String.contains?(notice, "Reload")
    end

    test "notice text is 'Reloaded settings and skills.'" do
      assert {:mutate, _fun, "Reloaded settings and skills."} = Reload.run("", %{cwd: "."})
    end

    test "args are ignored" do
      assert {:mutate, _fun, _notice} = Reload.run("extra args", %{cwd: "."})
    end
  end

  describe "mutate fun — pure data transform" do
    test "replaces data.skills without crashing (cwd with no skills)" do
      tmp = System.tmp_dir!()

      data = %{
        cwd: tmp,
        skills: [{"old_skill", %Tau.Skill{name: "old_skill", body: "", path: "/tmp/old_skill.md"}}]
      }

      {:mutate, fun, _} = Reload.run("", data)
      result = fun.(data)
      # skills key replaced; no crash
      assert Map.has_key?(result, :skills)
      assert is_list(result.skills)
    end

    test "other data fields are preserved" do
      tmp = System.tmp_dir!()
      data = %{cwd: tmp, skills: [], id: "test-id", messages: [42]}
      {:mutate, fun, _} = Reload.run("", data)
      result = fun.(data)
      assert result.id == "test-id"
      assert result.messages == [42]
    end

    test "skills are sorted by name after reload" do
      tmp = System.tmp_dir!()
      data = %{cwd: tmp, skills: []}
      {:mutate, fun, _} = Reload.run("", data)
      result = fun.(data)
      names = Enum.map(result.skills, fn {name, _} -> name end)
      assert names == Enum.sort(names)
    end
  end

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(Reload)
      assert function_exported?(Reload, :name, 0)
      assert function_exported?(Reload, :run, 2)
    end
  end
end
