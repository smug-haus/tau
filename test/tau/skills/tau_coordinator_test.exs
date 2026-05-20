defmodule Tau.Skills.TauCoordinatorTest do
  @moduledoc """
  Loadability and discoverability tests for the `tau-coordinator` skill and
  its required sub-personas (`implementer`, `critic`, `reviewer`).

  Asserts:
    1. `Tau.Skills.Loader.discover/1` (the runtime resolver path) discovers
       `tau-coordinator`, `implementer`, `critic`, and `reviewer` from
       `priv/skills/` — the only path scanned that ships with the binary.
    2. Each discovered skill resolves to a `%Tau.Skill{}` with the correct
       `name` and a non-empty `description`.
    3. Sub-persona resolution via the same logic as `Tau.Tools.Builtin.Agent`
       (`List.keyfind/3` on the discovered skills list) succeeds for all three
       sub-personas.
    4. `Tau.CLI.build_headless_skill/1` round-trips the coordinator body
       (the `--system-prompt-file` injection contract).

  The discover-based tests in group 1-3 would have FAILED before f-1's move:
  `Loader.discover/1` does NOT scan `.claude/skills/`, so the coordinator
  and sub-personas were unreachable at runtime, causing every
  `subagent_type: "implementer"` (etc.) call to fast-fail with
  `{:error, {:unknown_subagent_type, name}}` inside `Agent.execute/2`.

  After f-1's move to `priv/skills/`, `discover/1` finds them all.
  """

  use ExUnit.Case, async: true

  @priv_dir :code.priv_dir(:tau) |> to_string()

  # ---------------------------------------------------------------------------
  # 1. Discovery via Tau.Skills.Loader.discover/1
  # ---------------------------------------------------------------------------

  describe "Tau.Skills.Loader.discover/1 finds all coordinator personas" do
    setup do
      # Use a tmp cwd so ~/.tau/skills and <cwd>/.tau/skills are empty;
      # only priv/skills/ contributes.
      tmp = System.tmp_dir!()
      {:ok, cwd: tmp}
    end

    test "discovers tau-coordinator", %{cwd: cwd} do
      skills = Tau.Skills.Loader.discover(cwd)

      assert List.keyfind(skills, "tau-coordinator", 0) != nil,
             "tau-coordinator not found in discovered skills: #{inspect(Enum.map(skills, &elem(&1, 0)))}"
    end

    test "discovers implementer", %{cwd: cwd} do
      skills = Tau.Skills.Loader.discover(cwd)

      assert List.keyfind(skills, "implementer", 0) != nil,
             "implementer not found in discovered skills: #{inspect(Enum.map(skills, &elem(&1, 0)))}"
    end

    test "discovers critic", %{cwd: cwd} do
      skills = Tau.Skills.Loader.discover(cwd)

      assert List.keyfind(skills, "critic", 0) != nil,
             "critic not found in discovered skills: #{inspect(Enum.map(skills, &elem(&1, 0)))}"
    end

    test "discovers reviewer", %{cwd: cwd} do
      skills = Tau.Skills.Loader.discover(cwd)

      assert List.keyfind(skills, "reviewer", 0) != nil,
             "reviewer not found in discovered skills: #{inspect(Enum.map(skills, &elem(&1, 0)))}"
    end

    test "all discovered coordinator skills are %Tau.Skill{} structs", %{cwd: cwd} do
      skills = Tau.Skills.Loader.discover(cwd)

      for name <- ["tau-coordinator", "implementer", "critic", "reviewer"] do
        case List.keyfind(skills, name, 0) do
          {^name, %Tau.Skill{} = skill} ->
            assert skill.name == name,
                   "expected skill.name == #{name}, got #{inspect(skill.name)}"

            assert is_binary(skill.description) and byte_size(skill.description) > 0,
                   "expected non-empty description for #{name}, got #{inspect(skill.description)}"

            assert is_binary(skill.body) and byte_size(skill.body) > 0,
                   "expected non-empty body for #{name}"

          nil ->
            flunk("#{name} not found in discovered skills")
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Sub-persona resolution (mirrors Tau.Tools.Builtin.Agent.resolve_skill/2)
  # ---------------------------------------------------------------------------

  describe "sub-persona resolution via Agent's resolve_skill logic" do
    setup do
      tmp = System.tmp_dir!()
      skills = Tau.Skills.Loader.discover(tmp)
      {:ok, skills: skills}
    end

    # This is the exact logic from Tau.Tools.Builtin.Agent.resolve_skill/2
    # (lines 301-306 of lib/tau/tools/builtin/agent.ex):
    #   case List.keyfind(skills, name, 0) do
    #     {^name, %Tau.Skill{} = skill} -> {:ok, skill}
    #     _ -> {:error, {:unknown_subagent_type, name}}
    #   end

    for sub <- ["implementer", "critic", "reviewer"] do
      test "resolves subagent_type: #{inspect(sub)}", %{skills: skills} do
        name = unquote(sub)

        result =
          case List.keyfind(skills, name, 0) do
            {^name, %Tau.Skill{} = skill} -> {:ok, skill}
            _ -> {:error, {:unknown_subagent_type, name}}
          end

        assert {:ok, %Tau.Skill{name: ^name}} = result,
               "Expected {:ok, %Tau.Skill{name: #{inspect(name)}}}, got #{inspect(result)}"
      end
    end

    test "unknown subagent_type returns error tuple", %{skills: skills} do
      name = "does-not-exist"

      result =
        case List.keyfind(skills, name, 0) do
          {^name, %Tau.Skill{} = skill} -> {:ok, skill}
          _ -> {:error, {:unknown_subagent_type, name}}
        end

      assert {:error, {:unknown_subagent_type, "does-not-exist"}} = result
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Direct parse of each priv/skills persona
  # ---------------------------------------------------------------------------

  describe "Tau.Skills.Loader.parse/1 parses each persona directly" do
    for {skill_name, subdir} <- [
          {"tau-coordinator", "tau-coordinator"},
          {"implementer", "implementer"},
          {"critic", "critic"},
          {"reviewer", "reviewer"}
        ] do
      test "parses #{skill_name}" do
        path =
          Path.join([:code.priv_dir(:tau) |> to_string(), "skills", unquote(subdir), "SKILL.md"])

        assert {:ok, %Tau.Skill{name: unquote(skill_name)}} = Tau.Skills.Loader.parse(path),
               "expected parse to return {:ok, %Tau.Skill{name: #{inspect(unquote(skill_name))}}}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 4. build_headless_skill/1 round-trip (--system-prompt-file injection contract)
  # ---------------------------------------------------------------------------

  describe "build_headless_skill/1 round-trip" do
    test "coordinator body can be injected via build_headless_skill/1" do
      path = Path.join([@priv_dir, "skills", "tau-coordinator", "SKILL.md"])
      {:ok, skill} = Tau.Skills.Loader.parse(path)

      headless = Tau.CLI.build_headless_skill({:text, skill.body})

      assert %Tau.Skill{} = headless
      assert headless.name == "headless-system-prompt"
      assert headless.body == skill.body
      assert headless.path == "<cli:--system-prompt>"
    end

    test "coordinator body contains required factory-cycle markers" do
      path = Path.join([@priv_dir, "skills", "tau-coordinator", "SKILL.md"])
      {:ok, skill} = Tau.Skills.Loader.parse(path)
      headless = Tau.CLI.build_headless_skill({:text, skill.body})

      for marker <- ["Agent", "Factory cycle", "critic", "reviewer", "STOP-FACTORY"] do
        assert String.contains?(headless.body, marker),
               "expected headless skill body to contain '#{marker}'"
      end
    end
  end
end
