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

    test "notice text is 'Reloaded settings, skills, and prompt templates.'" do
      assert {:mutate, _fun, "Reloaded settings, skills, and prompt templates."} =
               Reload.run("", %{cwd: "."})
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
        skills: [{"old_skill", %Tau.Skill{name: "old_skill", body: "", path: "/tmp/old_skill.md"}}],
        prompt_templates: []
      }

      {:mutate, fun, _} = Reload.run("", data)
      result = fun.(data)
      # skills key replaced; no crash
      assert Map.has_key?(result, :skills)
      assert is_list(result.skills)
      assert Map.has_key?(result, :prompt_templates)
      assert is_list(result.prompt_templates)
    end

    test "other data fields are preserved" do
      tmp = System.tmp_dir!()
      data = %{cwd: tmp, skills: [], prompt_templates: [], id: "test-id", messages: [42]}
      {:mutate, fun, _} = Reload.run("", data)
      result = fun.(data)
      assert result.id == "test-id"
      assert result.messages == [42]
    end

    test "skills are sorted by name after reload" do
      tmp = System.tmp_dir!()
      data = %{cwd: tmp, skills: [], prompt_templates: []}
      {:mutate, fun, _} = Reload.run("", data)
      result = fun.(data)
      names = Enum.map(result.skills, fn {name, _} -> name end)
      assert names == Enum.sort(names)
    end

    test "prompt_templates are re-discovered after reload (AC-7)" do
      tmp = System.tmp_dir!()

      data = %{
        cwd: tmp,
        skills: [],
        prompt_templates: [
          {"old-template",
           %Tau.PromptTemplate{name: "old-template", body: "x", path: "/tmp/old.md", variables: []}}
        ]
      }

      {:mutate, fun, _} = Reload.run("", data)
      result = fun.(data)
      # Result is a freshly-discovered list (not the old stale one)
      assert is_list(result.prompt_templates)

      # Verify a freshly-added template would be picked up
      prompts_dir = Path.join(tmp, ".tau/prompts")
      File.mkdir_p!(prompts_dir)
      new_template_path = Path.join(prompts_dir, "new-ac7.md")
      File.write!(new_template_path, "Fresh template {{x}}")

      on_exit(fn -> File.rm(new_template_path) end)

      {:mutate, fun2, _} = Reload.run("", result)
      result2 = fun2.(result)
      names = Enum.map(result2.prompt_templates, fn {name, _} -> name end)
      assert "new-ac7" in names
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
