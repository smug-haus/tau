defmodule Tau.CodingAgents.ClaudeCode.ConfigDirTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [&&&: 2]

  alias Tau.CodingAgents.ClaudeCode.ConfigDir

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_tmp(label) do
    Path.join(System.tmp_dir!(), "tau_cfg_test_#{label}_#{System.unique_integer([:positive])}")
  end

  defp write_fake_creds(path) do
    File.write!(path, ~s({"type":"oauth","access_token":"test-only"}))
    path
  end

  # ---------------------------------------------------------------------------
  # seed/2 — happy path
  # ---------------------------------------------------------------------------

  describe "seed/2" do
    test "returns :ok, writes matching .credentials.json and a settings.json with no hooks key" do
      src = unique_tmp("src_creds")
      target = unique_tmp("target")

      on_exit(fn ->
        File.rm_rf!(src)
        File.rm_rf!(target)
      end)

      write_fake_creds(src)
      File.mkdir_p!(target)

      assert :ok = ConfigDir.seed(target, src)

      # .credentials.json must exist and match source bytes
      dest_creds = Path.join(target, ".credentials.json")
      assert File.exists?(dest_creds)
      assert File.read!(dest_creds) == File.read!(src)

      # settings.json must exist and parse as a map with no "hooks" key
      settings_path = Path.join(target, "settings.json")
      assert File.exists?(settings_path)
      parsed = Jason.decode!(File.read!(settings_path))
      assert is_map(parsed)
      refute Map.has_key?(parsed, "hooks")

      # No hooks/plugins/skills content anywhere under the dir
      assert Path.wildcard(Path.join(target, "**/{hooks,plugins,skills}/**")) == []
    end
  end

  # ---------------------------------------------------------------------------
  # seed/2 — missing source credentials
  # ---------------------------------------------------------------------------

  describe "seed/2 with missing source creds" do
    test "does not crash, writes settings.json, does NOT create .credentials.json" do
      # This documents the current no-crash behaviour for the unit-test / CI path
      # where real credentials are absent. See follow-up #530 for fail-loud on
      # the factory path — do NOT assert fail-loud here, just pin no-crash.
      absent_src = unique_tmp("absent_creds")
      target = unique_tmp("target_no_creds")

      on_exit(fn ->
        File.rm_rf!(absent_src)
        File.rm_rf!(target)
      end)

      # Confirm source truly does not exist
      refute File.exists?(absent_src)

      File.mkdir_p!(target)
      assert :ok = ConfigDir.seed(target, absent_src)

      # settings.json still written
      assert File.exists?(Path.join(target, "settings.json"))

      # .credentials.json must NOT be created when source is absent
      refute File.exists?(Path.join(target, ".credentials.json"))
    end
  end

  # ---------------------------------------------------------------------------
  # create_isolated/1 — perms hardening (critic f-1)
  # ---------------------------------------------------------------------------

  describe "create_isolated/1" do
    test "returns an existing dir with 0o700 perms; seeded .credentials.json has 0o600 perms" do
      src = unique_tmp("src_creds_iso")

      on_exit(fn ->
        File.rm_rf!(src)
      end)

      write_fake_creds(src)

      result_dir = ConfigDir.create_isolated(src)

      on_exit(fn ->
        File.rm_rf!(result_dir)
      end)

      # Dir must exist
      assert File.exists?(result_dir)
      assert File.dir?(result_dir)

      # Dir mode must be 0o700 (owner rwx, no group/other bits)
      dir_stat = File.stat!(result_dir)

      assert (dir_stat.mode &&& 0o777) == 0o700,
             "expected dir mode 0o700, got 0o#{Integer.to_string(dir_stat.mode &&& 0o777, 8)}"

      # .credentials.json must exist with 0o600 perms
      creds_path = Path.join(result_dir, ".credentials.json")
      assert File.exists?(creds_path)
      creds_stat = File.stat!(creds_path)

      assert (creds_stat.mode &&& 0o777) == 0o600,
             "expected .credentials.json mode 0o600, got 0o#{Integer.to_string(creds_stat.mode &&& 0o777, 8)}"
    end
  end
end
