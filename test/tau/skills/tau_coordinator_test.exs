defmodule Tau.Skills.TauCoordinatorTest do
  @moduledoc """
  Loadability tests for the `tau-coordinator` skill artifact.

  Asserts:
    1. `Tau.Skills.Loader.parse/1` successfully parses the on-disk
       `.claude/skills/tau-coordinator/SKILL.md`.
    2. The resulting `%Tau.Skill{}` has `name: "tau-coordinator"` and a
       non-empty body containing the required factory-cycle markers.
    3. `Tau.CLI.build_headless_skill/1` produces a `%Tau.Skill{}` from
       the body, matching the shape that `tau run --system-prompt-file`
       would inject into a session.

  No end-to-end provider test here — that requires a real provider and
  is tracked by issue #256.
  """

  use ExUnit.Case, async: true

  @skill_path Path.expand(
                "../../../.claude/skills/tau-coordinator/SKILL.md",
                __DIR__
              )

  describe "tau-coordinator skill file is parseable" do
    test "skill file exists on disk" do
      assert File.exists?(@skill_path),
             "expected #{@skill_path} to exist"
    end

    test "Tau.Skills.Loader.parse/1 returns {:ok, %Tau.Skill{}}" do
      assert {:ok, %Tau.Skill{}} = Tau.Skills.Loader.parse(@skill_path)
    end

    test "skill name is 'tau-coordinator'" do
      {:ok, skill} = Tau.Skills.Loader.parse(@skill_path)
      assert skill.name == "tau-coordinator"
    end

    test "skill body is non-empty" do
      {:ok, skill} = Tau.Skills.Loader.parse(@skill_path)

      assert is_binary(skill.body) and byte_size(skill.body) > 0,
             "expected non-empty skill body"
    end

    test "skill body contains required factory-cycle markers" do
      {:ok, skill} = Tau.Skills.Loader.parse(@skill_path)

      for marker <- ["Agent", "Factory cycle", "critic", "reviewer", "STOP-FACTORY"] do
        assert String.contains?(skill.body, marker),
               "expected skill body to contain '#{marker}'"
      end
    end

    test "skill path is set correctly" do
      {:ok, skill} = Tau.Skills.Loader.parse(@skill_path)
      assert skill.path == @skill_path
    end
  end

  describe "build_headless_skill/1 round-trip" do
    test "skill body can be injected via build_headless_skill/1" do
      {:ok, skill} = Tau.Skills.Loader.parse(@skill_path)

      headless = Tau.CLI.build_headless_skill(skill.body)

      assert %Tau.Skill{} = headless
      assert headless.name == "headless-system-prompt"
      assert headless.body == skill.body
      assert headless.path == "<cli:--system-prompt>"
    end

    test "build_headless_skill/1 body contains the coordinator markers" do
      {:ok, skill} = Tau.Skills.Loader.parse(@skill_path)
      headless = Tau.CLI.build_headless_skill(skill.body)

      for marker <- ["Agent", "Factory cycle", "critic", "reviewer", "STOP-FACTORY"] do
        assert String.contains?(headless.body, marker),
               "expected headless skill body to contain '#{marker}'"
      end
    end
  end
end
