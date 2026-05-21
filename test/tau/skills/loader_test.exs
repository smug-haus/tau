defmodule Tau.Skills.LoaderTest do
  @moduledoc """
  Tests for `Tau.Skills.Loader.discover/1` shadowing behaviour (issue #258).

  The bundled personas ship as `tau-implementer`, `tau-critic`, and
  `tau-reviewer` (namespaced) to avoid colliding with users' own skills
  named `implementer`, `critic`, or `reviewer`. These tests assert:

    1. When a user skill with the SAME namespaced name (e.g. a user
       `tau-implementer` at `<cwd>/.tau/skills/tau-implementer/`) is
       present, the user's copy wins (existing precedence) BUT a
       `Logger.warning/1` records that the bundled skill is being
       shadowed.

    2. When a user skill with the OLD generic name (e.g. `implementer`)
       is present, the bundled `tau-implementer` is STILL reachable —
       they are different names post-rename, so no shadowing occurs.
       This is the M1-protection guarantee that motivated #258.

  Tests use a `tmp_dir` fixture and pass it as `cwd` to `discover/1` so
  the user override lives under `<tmp>/.tau/skills/...`. The real
  `~/.tau/skills/` is never read or written.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  defp write_skill(dir, name, body) do
    skill_dir = Path.join([dir, ".tau/skills", name])
    File.mkdir_p!(skill_dir)

    contents = """
    ---
    name: #{name}
    description: "user-supplied skill #{name}"
    ---

    #{body}
    """

    File.write!(Path.join(skill_dir, "SKILL.md"), contents)
    skill_dir
  end

  describe "discover/1 — shadowing of namespaced bundled personas" do
    test "user `tau-implementer` masks bundled `tau-implementer` AND logs a warning",
         %{tmp_dir: tmp} do
      user_skill_dir = write_skill(tmp, "tau-implementer", "user override body")

      {skills, log} =
        with_log(fn ->
          Tau.Skills.Loader.discover(tmp)
        end)

      # The user's copy wins precedence (existing behaviour preserved).
      {"tau-implementer", %Tau.Skill{} = winning} =
        List.keyfind(skills, "tau-implementer", 0)

      assert winning.path == Path.join(user_skill_dir, "SKILL.md"),
             "expected user skill to win precedence over bundled, got path=#{winning.path}"

      # And a warning names both paths.
      assert log =~ "shadows bundled skill"
      assert log =~ "tau-implementer"
      assert log =~ Path.join(user_skill_dir, "SKILL.md")
    end

    test "no warning is logged when there is no collision", %{tmp_dir: tmp} do
      # No user skills at all — only priv/skills should contribute.
      {_skills, log} =
        with_log(fn ->
          Tau.Skills.Loader.discover(tmp)
        end)

      refute log =~ "shadows bundled skill"
    end
  end

  describe "discover/1 — M1 protection: namespaced bundled remains reachable" do
    test "user skill named `implementer` does NOT shadow bundled `tau-implementer`",
         %{tmp_dir: tmp} do
      _user_skill_dir = write_skill(tmp, "implementer", "user implementer body")

      {skills, log} =
        with_log(fn ->
          Tau.Skills.Loader.discover(tmp)
        end)

      # Bundled tau-implementer is still discoverable.
      assert {"tau-implementer", %Tau.Skill{name: "tau-implementer"}} =
               List.keyfind(skills, "tau-implementer", 0),
             "bundled tau-implementer must remain reachable when a user skill " <>
               "named `implementer` exists (M1 self-hosting guarantee, #258)"

      # The user's `implementer` is ALSO reachable (different name, no collision).
      assert {"implementer", %Tau.Skill{name: "implementer"}} =
               List.keyfind(skills, "implementer", 0)

      # No shadowing warning — these are different names.
      refute log =~ "shadows bundled skill"
    end

    test "all three bundled personas are reachable by their namespaced names",
         %{tmp_dir: tmp} do
      skills = Tau.Skills.Loader.discover(tmp)

      for name <- ["tau-implementer", "tau-critic", "tau-reviewer"] do
        assert {^name, %Tau.Skill{name: ^name}} = List.keyfind(skills, name, 0),
               "expected bundled #{name} to be reachable"
      end
    end
  end
end
