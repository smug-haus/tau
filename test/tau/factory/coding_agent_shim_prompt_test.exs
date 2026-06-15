defmodule Tau.Factory.CodingAgentShimPromptTest do
  @moduledoc """
  Gating tests for PR #516 (issue #515 — real-run integration: D-381 per-unit
  prompt delivery).

  Written BEFORE production code exists (oracle-separation phase, factory-loop §4b).
  These tests MUST FAIL against the current branch because:

    (a) `Worker.open_port_final/5` does NOT append `{"TAU_AGENT_PROMPT", brief}`
        to the Port `:env` list. The agent subprocess (or shim) therefore sees
        `TAU_AGENT_PROMPT` as absent, which means `task.prompt` stays `""` and
        the real `claude` argv carries `-p ""`.

    (b) `CodingAgentShim.Runner.main/1` does NOT read `System.get_env("TAU_AGENT_PROMPT")`.
        The shim builds `task = %{prompt: "", ...}` (hardcoded at lines ~238 and ~258
        of `coding_agent_shim.ex`). Even if the Worker injected `TAU_AGENT_PROMPT`,
        the shim would ignore it.

  ## Contracts under test (SPEC-FACTORY-FLEET §6, D-381)

  D-381 pins two delivery post-conditions:

    1. **Worker injects `TAU_AGENT_PROMPT`:** `Worker.open_port_final/5` appends
       `{"TAU_AGENT_PROMPT", brief}` to the `Port.open` `:env` list alongside
       `ns`, `extra_env`, and the D-374 metered scrub. This applies for EVERY
       `agent_mode` (Replay and `:claude_code`).

    2. **Shim reads `TAU_AGENT_PROMPT` into `task.prompt`:** `Runner.main/1`
       reads `System.get_env("TAU_AGENT_PROMPT")` and sets
       `task.prompt = it || ""`. When the var is set, `task.prompt` equals the
       brief. Absent var → `""` (back-compat).

    Corollary: a real `:claude_code` run produces a `claude` argv containing
    `["-p", brief, ...]` (not `["-p", "", ...]`).

  **Orthogonality (D-374):** the metered-spend scrub removes ONLY
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, and `ANTHROPIC_BASE_URL`.
  `TAU_AGENT_PROMPT` MUST NOT be added to the scrub list.

  ## Failure expectations on current branch

    - Test (a): the agent_bin shell script dumps env → `TAU_AGENT_PROMPT` is absent
      from the dump → `assert String.contains?(dump, brief)` fails.

    - Test (b): the shim's fake-claude subprocess receives `-p ""` (not `-p <brief>`)
      in argv → `assert String.contains?(argv_dump, brief)` fails.

    - Test (c): the `ANTHROPIC_*` scrub test should already pass, but we assert
      `TAU_AGENT_PROMPT` is present AND the three `ANTHROPIC_*` vars are absent
      — `assert String.contains?(dump, brief)` fails (env not injected).

  ## AC linkage
    - D-381 — all tests tagged `:d_381`
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_381

  alias Tau.Factory.CodingAgentShim

  @worker_supervisor Tau.Factory.WorkerSupervisor
  @worker_registry Tau.Factory.WorkerRegistry

  # ---------------------------------------------------------------------------
  # Setup helpers (mirrors cost_safety_fence_test.exs idiom)
  # ---------------------------------------------------------------------------

  defp setup_git_repo(tmp_dir) do
    repo_dir = Path.join(tmp_dir, "repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_dir)

    git = fn args ->
      System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])

    %{repo_dir: repo_dir, base_ref: String.trim(sha)}
  end

  defp mk_tmp(tag) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "tau_#{tag}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"prompt_reg_#{tag}_#{n}"
    sup_name = :"prompt_sup_#{tag}_#{n}"

    {:ok, _reg} =
      start_supervised({@worker_registry, name: registry_name}, id: :"reg_#{n}")

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup, registry_name}
  end

  # ---------------------------------------------------------------------------
  # D-381 (a): Worker injects TAU_AGENT_PROMPT into the Port env when a non-empty
  # brief is given.
  #
  # Strategy: use an agent_bin shell script that dumps the value of TAU_AGENT_PROMPT
  # to a file. The Worker spawns it via Port; if the Worker injects TAU_AGENT_PROMPT,
  # the dump will contain the brief. No CodingAgentShim or real claude involved.
  #
  # MUST FAIL on current branch: Worker.open_port_final/5 does NOT append
  # {"TAU_AGENT_PROMPT", brief} to env_list → child process never sees the var →
  # dump says "TAU_AGENT_PROMPT=absent" → assert fails.
  # ---------------------------------------------------------------------------

  describe "D-381 — Worker injects TAU_AGENT_PROMPT into Port env" do
    @tag :d_381
    test "D-381: a Worker spawned with a non-empty brief injects TAU_AGENT_PROMPT into the child Port env" do
      tmp_dir = mk_tmp("d381_env_inject")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      n = System.unique_integer([:positive])
      brief = "Implement the D-381 prompt-delivery feature (unique #{n})"
      dump_file = Path.join(tmp_dir, "env_dump_#{n}.txt")

      # Agent executable: dumps TAU_AGENT_PROMPT to dump_file then exits.
      # Uses the Port exit-0 path (no work_ready frame needed — we only care
      # about the env). This is NOT a real shim; it is a probe script.
      agent_bin = Path.join(tmp_dir, "probe_agent_#{n}")

      File.write!(agent_bin, """
      #!/bin/sh
      VAL="${TAU_AGENT_PROMPT:-absent}"
      printf "TAU_AGENT_PROMPT=${VAL}\\n" > #{dump_file}
      exit 0
      """)

      File.chmod!(agent_bin, 0o755)

      {sup, registry_name} = start_fleet(:d381_env_inject)
      report_to = self()

      # Spawn the Worker with a non-empty brief and agent_mode: :claude_code so
      # the D-374 path is exercised. Provide creds_check_fun: -> :ok to bypass
      # the subscription check (we want to reach Port.open).
      # NEEDED SEAM (D-381): Worker.open_port_final/5 appends
      # {"TAU_AGENT_PROMPT", brief} to env_list.
      # On current branch: brief is stored in Worker state but never injected
      # into the Port env → TAU_AGENT_PROMPT is absent in child → dump says "absent".
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, brief, base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name,
          agent_mode: :claude_code,
          creds_check_fun: fn -> :ok end
        )

      assert_receive {:worker_exit, ^worker_id, _reason},
                     10_000,
                     "D-381: Worker must complete and deliver exit notification within 10s"

      # Allow the child process to finish writing.
      Process.sleep(200)

      assert File.exists?(dump_file),
             "D-381: probe agent must have run and written dump_file=#{dump_file}. " <>
               "If the file is missing, the Port was never opened (e.g. preflight blocked " <>
               "it or the agent_bin crashed before the write). Unexpected with creds_check_fun: -> :ok."

      dump_text = File.read!(dump_file)

      # D-381: TAU_AGENT_PROMPT must contain the brief verbatim.
      # FAILS on current branch: Worker does NOT inject TAU_AGENT_PROMPT →
      # dump contains "TAU_AGENT_PROMPT=absent" → String.contains? is false.
      assert String.contains?(dump_text, brief),
             "D-381: TAU_AGENT_PROMPT was NOT found in child Port env! " <>
               "Worker.open_port_final/5 MUST append {\"TAU_AGENT_PROMPT\", brief} " <>
               "to the Port :env list (alongside ns, extra_env, and the D-374 scrub). " <>
               "dump=#{inspect(dump_text)} expected_brief=#{inspect(brief)}"
    end

    @tag :d_381
    test "D-381: a Worker spawned with an empty brief injects TAU_AGENT_PROMPT as empty string" do
      tmp_dir = mk_tmp("d381_empty_brief")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      n = System.unique_integer([:positive])
      dump_file = Path.join(tmp_dir, "env_dump_empty_#{n}.txt")

      agent_bin = Path.join(tmp_dir, "probe_empty_#{n}")

      File.write!(agent_bin, """
      #!/bin/sh
      # Write a sentinel indicating whether the var is set (even if empty),
      # versus truly absent (unset).
      if [ -z "${TAU_AGENT_PROMPT+x}" ]; then
        printf "TAU_AGENT_PROMPT=UNSET\\n" > #{dump_file}
      else
        printf "TAU_AGENT_PROMPT=EMPTY_OR_SET:${TAU_AGENT_PROMPT}\\n" > #{dump_file}
      fi
      exit 0
      """)

      File.chmod!(agent_bin, 0o755)

      {sup, registry_name} = start_fleet(:d381_empty_brief)
      report_to = self()

      # D-381: an empty brief → TAU_AGENT_PROMPT is set to "" (not absent/unset).
      # Back-compat: absent var → prompt = "" is equivalent, but the Worker MUST
      # still inject the key (even with an empty value) when brief is "".
      # FAILS on current branch: Worker never injects the key → UNSET in child env.
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name,
          agent_mode: :claude_code,
          creds_check_fun: fn -> :ok end
        )

      assert_receive {:worker_exit, ^worker_id, _reason},
                     10_000,
                     "D-381: Worker must complete within 10s"

      Process.sleep(200)

      assert File.exists?(dump_file),
             "D-381: probe agent must have written dump_file=#{dump_file}"

      dump_text = File.read!(dump_file)

      # D-381: var is set (even if empty value).
      # FAILS on current branch: var is absent (UNSET) → dump contains "UNSET".
      refute String.contains?(dump_text, "UNSET"),
             ~s|D-381: TAU_AGENT_PROMPT must be SET in child Port env even when brief is "". | <>
               ~s|Worker MUST inject {"TAU_AGENT_PROMPT", ""} so the var is set. | <>
               "dump=#{inspect(dump_text)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-381 (b): The shim reads TAU_AGENT_PROMPT and passes it as task.prompt,
  # causing the claude argv to carry -p <brief> (not -p "").
  #
  # Strategy: write the CodingAgentShim with adapter: :claude_code, put a fake
  # "claude" script on PATH (dumps argv to a file then exits cleanly), and spawn
  # the Worker with a non-empty brief and agent_mode: :claude_code.
  # The Worker injects TAU_AGENT_PROMPT=brief; the shim reads it → task.prompt=brief;
  # ClaudeCode.start builds argv=["-p", brief, ...]; fake claude records the argv.
  #
  # MUST FAIL on current branch:
  #   (i)  Worker does NOT inject TAU_AGENT_PROMPT → shim sees it as absent.
  #   (ii) Runner.main/1 hardcodes task.prompt="" (lines ~238/258 of shim) even if
  #        TAU_AGENT_PROMPT were set → fake claude receives -p "" in argv.
  # Either defect causes the assert to fail.
  # ---------------------------------------------------------------------------

  describe "D-381 — shim reads TAU_AGENT_PROMPT and delivers it as claude -p <brief>" do
    @tag :d_381
    test "D-381: CodingAgentShim with non-empty brief produces claude argv -p <brief> (not -p '')" do
      tmp_dir = mk_tmp("d381_argv")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      n = System.unique_integer([:positive])
      brief = "Deliver per-unit prompt in real claude argv (unique #{n})"
      argv_dump = Path.join(tmp_dir, "claude_argv_#{n}.txt")

      # Fake "claude" script: dumps all $@ (argv) to argv_dump, then emits a
      # minimal valid stream-json result line so the ClaudeCode parser does not error.
      # The shim will invoke this in place of the real claude.
      fake_claude = Path.join(tmp_dir, "claude")

      File.write!(fake_claude, """
      #!/bin/sh
      printf "%s\\n" "$@" > #{argv_dump}
      printf '{"type":"result","subtype":"success","result":"ok","session_id":"d381-#{n}","is_error":false}\\n'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      # Inject tmp_dir first on PATH so the fake claude is found by the shim.
      old_path = System.get_env("PATH", "")
      System.put_env("PATH", "#{tmp_dir}:#{old_path}")

      on_exit(fn ->
        System.put_env("PATH", old_path)
      end)

      # Write the shim with the ClaudeCode adapter and a git branch.
      branch = "feat/d381-prompt-#{n}"
      shim_bin = Path.join(tmp_dir, "shim_d381_#{n}")

      # D-381: CodingAgentShim.write must exist (already landed in the bridge PR).
      # If the module does not exist, this raises UndefinedFunctionError — correct
      # fail-before state.
      shim_bin =
        CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.ClaudeCode,
          branch: branch
        )

      {sup, registry_name} = start_fleet(:d381_argv)
      report_to = self()

      # D-381: Worker injects TAU_AGENT_PROMPT=brief → shim reads it as task.prompt
      # → ClaudeCode.start builds argv=["-p", brief, ...] → fake claude receives it.
      # FAILS on current branch: Worker doesn't inject, shim hardcodes "" → -p "".
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, brief, base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name,
          agent_mode: :claude_code,
          creds_check_fun: fn -> :ok end
        )

      assert_receive msg
                     when elem(msg, 0) in [:work_ready, :worker_exit] and
                            elem(msg, 1) == worker_id,
                     30_000,
                     "D-381: shim must complete within 30s"

      # Allow the fake claude to finish writing argv_dump.
      Process.sleep(300)

      assert File.exists?(argv_dump),
             "D-381: fake claude must have run and written argv_dump=#{argv_dump}. " <>
               "If missing, the shim did not call ClaudeCode (e.g. it exited before " <>
               "reaching the adapter start call, or PATH was not propagated)."

      argv_text = File.read!(argv_dump)

      # D-381: argv must contain the brief (as the argument to -p).
      # One argv per line — the brief will appear on its own line.
      # FAILS on current branch:
      #   - Worker does NOT inject TAU_AGENT_PROMPT → shim reads "" → argv has "-p" then "".
      #   - Even if injection were fixed, Runner.main/1 hardcodes prompt="" → still "".
      assert String.contains?(argv_text, brief),
             "D-381: claude argv does NOT contain the brief! " <>
               "The shim MUST read System.get_env(\"TAU_AGENT_PROMPT\") into task.prompt " <>
               "and the Worker MUST inject {\"TAU_AGENT_PROMPT\", brief} in the Port env. " <>
               "argv_dump=#{inspect(argv_text)} expected_brief=#{inspect(brief)}"

      # Also assert -p appears in argv (sanity: ClaudeCode always builds -p prompt).
      assert String.contains?(argv_text, "-p"),
             "D-381: claude argv must contain -p flag. argv_dump=#{inspect(argv_text)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-381 (c): ANTHROPIC_* scrub (D-374) is unaffected — TAU_AGENT_PROMPT is NOT
  # added to the scrub list.
  #
  # Strategy: inject canary values for all three ANTHROPIC_* vars via extra_env,
  # also set a non-empty brief, then verify:
  #   (i)  All three ANTHROPIC_* canaries are absent from child env (scrub active).
  #   (ii) TAU_AGENT_PROMPT appears in child env (NOT scrubbed).
  #
  # MUST FAIL on current branch:
  #   - The ANTHROPIC_* scrub already works (D-374 is landed).
  #   - But TAU_AGENT_PROMPT is NOT injected (D-381 not yet done) →
  #     assertion (ii) fails.
  # ---------------------------------------------------------------------------

  describe "D-381 — ANTHROPIC_* scrub is orthogonal to TAU_AGENT_PROMPT" do
    @tag :d_381
    test "D-381: ANTHROPIC_* scrub removes credential vars but TAU_AGENT_PROMPT is present and unscrubbred" do
      tmp_dir = mk_tmp("d381_orthogonal")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      n = System.unique_integer([:positive])
      brief = "Orthogonal prompt for D-381 test (unique #{n})"
      canary_key = "sk-test-D381-ORTH-KEY-#{n}"
      canary_auth = "Bearer-D381-ORTH-TOKEN-#{n}"
      canary_url = "https://proxy-d381-orth-#{n}.example.com"
      dump_file = Path.join(tmp_dir, "orth_dump_#{n}.txt")

      # Probe agent: dumps TAU_AGENT_PROMPT and all three ANTHROPIC_* variables.
      agent_bin = Path.join(tmp_dir, "orth_probe_#{n}")

      File.write!(agent_bin, """
      #!/bin/sh
      PROMPT="${TAU_AGENT_PROMPT:-PROMPT_ABSENT}"
      KEY="${ANTHROPIC_API_KEY:-absent}"
      TOKEN="${ANTHROPIC_AUTH_TOKEN:-absent}"
      BASE="${ANTHROPIC_BASE_URL:-absent}"
      printf "TAU_AGENT_PROMPT=${PROMPT}\\nANTHROPIC_API_KEY=${KEY}\\nANTHROPIC_AUTH_TOKEN=${TOKEN}\\nANTHROPIC_BASE_URL=${BASE}\\n" > #{dump_file}
      exit 0
      """)

      File.chmod!(agent_bin, 0o755)

      {sup, registry_name} = start_fleet(:d381_orth)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, brief, base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name,
          agent_mode: :claude_code,
          creds_check_fun: fn -> :ok end,
          extra_env: [
            {"ANTHROPIC_API_KEY", canary_key},
            {"ANTHROPIC_AUTH_TOKEN", canary_auth},
            {"ANTHROPIC_BASE_URL", canary_url}
          ]
        )

      assert_receive {:worker_exit, ^worker_id, _reason},
                     10_000,
                     "D-381: Worker must complete within 10s"

      Process.sleep(200)

      assert File.exists?(dump_file),
             "D-381: probe agent must have written dump_file=#{dump_file}"

      dump_text = File.read!(dump_file)

      # D-381 (i): TAU_AGENT_PROMPT must contain the brief (NOT scrubbed).
      # FAILS on current branch: Worker never injects TAU_AGENT_PROMPT →
      # dump says "TAU_AGENT_PROMPT=PROMPT_ABSENT".
      assert String.contains?(dump_text, brief),
             "D-381: TAU_AGENT_PROMPT must be present in child Port env (orthogonal to D-374 scrub). " <>
               "Worker MUST inject {\"TAU_AGENT_PROMPT\", brief}. " <>
               "dump=#{inspect(dump_text)} expected_brief=#{inspect(brief)}"

      # D-374 / D-381 (ii): ANTHROPIC_* canaries must be absent (scrub unaffected).
      refute String.contains?(dump_text, canary_key),
             "D-374: ANTHROPIC_API_KEY canary must be scrubbed from child env. " <>
               "dump=#{inspect(dump_text)}"

      refute String.contains?(dump_text, canary_auth),
             "D-374: ANTHROPIC_AUTH_TOKEN canary must be scrubbed from child env. " <>
               "dump=#{inspect(dump_text)}"

      refute String.contains?(dump_text, canary_url),
             "D-374: ANTHROPIC_BASE_URL canary must be scrubbed from child env. " <>
               "dump=#{inspect(dump_text)}"
    end
  end
end
