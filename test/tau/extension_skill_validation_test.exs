defmodule Tau.ExtensionSkillValidationTest do
  @moduledoc """
  Verifies that `Tau.Extension.DSL.skill/2` emits a compile-time
  warning when the skill path doesn't resolve to an existing file
  (issue #28). A typo in `priv/skils/...` should fail fast rather
  than silently register a path the loader can't read.

  Compiling a synthetic extension module to a tmp file lets us
  capture the warning without polluting the lib tree.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Tau.Extension.DSL

  test "resolve_skill_path/2: absolute paths are returned expanded" do
    assert DSL.resolve_skill_path("/tmp/x/SKILL.md", "/some/where") == "/tmp/x/SKILL.md"
  end

  test "resolve_skill_path/2: relative paths are resolved against the caller dir" do
    assert DSL.resolve_skill_path("skills/foo/SKILL.md", "/work/ext") ==
             "/work/ext/skills/foo/SKILL.md"
  end

  test "skill/2 emits a compile warning when the path doesn't exist" do
    src = """
    defmodule TauExtSkillWarning#{System.unique_integer([:positive])} do
      use Tau.Extension
      skill "doesnt_exist", "priv/skils/typo/SKILL.md"
    end
    """

    output =
      capture_io(:stderr, fn ->
        Code.compile_string(src, "synthetic_test_extension.exs")
      end)

    assert output =~ "doesnt_exist"
    assert output =~ "priv/skils/typo/SKILL.md"
    assert output =~ "does not exist"
  end

  test "skill/2 is silent when the path exists" do
    tmp_dir = Path.join(System.tmp_dir!(), "tau-skill-ok-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    skill_path = Path.join(tmp_dir, "GOOD.md")
    File.write!(skill_path, "---\nname: ok\n---\nbody")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    src = """
    defmodule TauExtSkillOk#{System.unique_integer([:positive])} do
      use Tau.Extension
      skill "ok", #{inspect(skill_path)}
    end
    """

    output =
      capture_io(:stderr, fn ->
        Code.compile_string(src, "synthetic_test_extension.exs")
      end)

    refute output =~ "does not exist"
  end
end
