defmodule Tau.CodingAgents.ClaudeCode.ConfigDir do
  @moduledoc """
  Per-invocation CLAUDE_CONFIG_DIR isolation (D-388).

  Provides a minimal seeding helper that produces an isolated Claude config
  directory containing only OAuth credentials and an empty settings file.
  No operator hooks, plugins, or skills are copied — the factory agent runs
  in a clean config context with no inherited tool customisations.

  ## D-388 contract

    * `seed/2` copies ONLY the OAuth `.credentials.json` from the source
      path into `target_dir/.credentials.json` and writes a minimal
      `target_dir/settings.json` (no `hooks` key).
    * If the source credentials file is absent, `settings.json` is still
      written and the call succeeds (factory may run without credentials
      in unit tests). No hooks/plugins/skills content is created.
    * `create_isolated/1` creates a fresh unique temp dir, calls `seed/2`,
      and returns the dir path.

  ## Usage

  The ClaudeCode adapter calls `create_isolated/1` in its port_env assembly
  and passes the returned path as `CLAUDE_CONFIG_DIR` so each subprocess
  gets its own isolated config context.
  """

  @doc """
  Returns the default path to the host user's OAuth credentials file.
  """
  @spec default_source_creds_path() :: String.t()
  def default_source_creds_path do
    Path.expand("~/.claude/.credentials.json")
  end

  @doc """
  Seed `target_dir` with an isolated Claude config.

  Copies `.credentials.json` from `source_creds_path` into `target_dir`
  (if the source exists) and writes a minimal `settings.json` with no
  `hooks` key. Creates `target_dir` if necessary. Returns `:ok`.

  If `source_creds_path` does not exist the credentials copy is skipped;
  `settings.json` is always written.
  """
  @spec seed(String.t(), String.t()) :: :ok
  def seed(target_dir, source_creds_path)
      when is_binary(target_dir) and is_binary(source_creds_path) do
    File.mkdir_p!(target_dir)
    # Restrict directory to owner-only access so credential copies in /tmp
    # are not world-readable (defense-in-depth, D-388).
    File.chmod!(target_dir, 0o700)

    # Copy OAuth credentials only if the source file exists.
    # Absence is not an error — unit tests run without real credentials.
    if File.exists?(source_creds_path) do
      dest_creds = Path.join(target_dir, ".credentials.json")
      File.cp!(source_creds_path, dest_creds)
      # Restrict credential file to owner-read/write only.
      File.chmod!(dest_creds, 0o600)
    end

    # Write a minimal settings.json with no hooks key.
    settings_path = Path.join(target_dir, "settings.json")
    File.write!(settings_path, "{}")

    :ok
  end

  @doc """
  Create a fresh isolated config directory seeded from `source_creds_path`.

  Makes a unique temp directory, calls `seed/2`, and returns the directory path.
  The caller is responsible for cleanup.
  """
  @spec create_isolated(String.t()) :: String.t()
  def create_isolated(source_creds_path) when is_binary(source_creds_path) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "tau_claude_cfg_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    :ok = seed(dir, source_creds_path)
    dir
  end
end
