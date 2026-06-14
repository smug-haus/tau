defmodule Tau.Factory.CostSafetyFenceTest do
  @moduledoc """
  Gating tests for PR #510 (issue #509 — cost-safety fence: no metered-API spend,
  D-374/D-375).

  Written BEFORE production code exists (oracle-separation, factory-loop §4b).
  Broadened in REFINE to cover ALL three metered-spend vectors, not just
  `ANTHROPIC_API_KEY`:

    - `ANTHROPIC_API_KEY`     — primary API key (original coverage)
    - `ANTHROPIC_AUTH_TOKEN`  — metered bearer token honoured by the `claude` CLI
    - `ANTHROPIC_BASE_URL`    — redirects to a (potentially paid) proxy endpoint

  ## D-374 — no-metered-spend, factory plane

  A metered-capable worker (agent mode `:claude_code`) spawns its agent subprocess
  ONLY after a preflight confirms BOTH:

    (a) Subscription creds present/readable (injectable creds_check_fun).
    (b) The child env is scrubbed of ALL THREE metered-spend variables by passing
        `{~c"ANTHROPIC_API_KEY", false}`, `{~c"ANTHROPIC_AUTH_TOKEN", false}`,
        and `{~c"ANTHROPIC_BASE_URL", false}` in the Erlang Port's `{:env, ...}`
        list.

  If either fails → the worker refuses to spawn and exits `:metered_path_refused`
  (fail-closed; NO fallback to the metered path).

  Single enforcement funnel: `Worker.open_port_and_finish/1`.

  ## D-375 — adapter-level scrub, defense-in-depth

  `Tau.CodingAgents.ClaudeCode.start/2` scrubs ALL THREE metered-spend variables
  from the child Port env by default; `ctx[:allow_metered] == true` is the only
  opt-out (which retains all three).

  ## Needed seams (must be added by the implementer)

  1. **`:agent_mode`** — `WorkerSupervisor.spawn/5` opt (atom; `:claude_code`
     activates the D-374 preflight and scrub; absent / other values → no preflight).

  2. **`:creds_check_fun`** — `WorkerSupervisor.spawn/5` opt — a
     `(-> :ok | {:error, :subscription_creds_absent})` zero-arity function.
     Defaults to the real `~/.claude/.credentials.json` check. Tests inject a
     lambda so no real filesystem access occurs.

  ## Failure expectations on current branch

  - D-374 fail-closed test: Worker opens Port despite absent creds → marker
    file appears → `refute File.exists?(marker)` fails.
  - D-374 scrub test: Worker does NOT pass `{~c"ANTHROPIC_API_KEY", false}` /
    `{~c"ANTHROPIC_AUTH_TOKEN", false}` / `{~c"ANTHROPIC_BASE_URL", false}` →
    canaries leak to child → `refute` on canary values in dump fails.
  - D-374 creds-present test: Worker has no `:agent_mode` opt → KeyError on
    spawn → assertion on `{:ok, worker_id}` fails.
  - D-375 default scrub test: No `{:env, ...}` in ClaudeCode Port.open → all
    three canaries leak → `refute` on canary values in dump fails.
  - D-375 allow_metered test: No `{:env, ...}` in Port.open → no `{:ok, _}`
    vs not, but actually tests the presence of canary, which passes vacuously.
    Re-framed: assert the SCRUB is wired (see test body for how this is made
    to fail correctly below).

  ## AC linkage

    - D-374 — all tests tagged `:d_374`
    - D-375 — all tests tagged `:d_375`
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Tau.CodingAgent.Event
  alias Tau.CodingAgents.ClaudeCode
  alias Tau.Factory.CodingAgentShim

  @worker_supervisor Tau.Factory.WorkerSupervisor
  @worker_registry Tau.Factory.WorkerRegistry

  # ---------------------------------------------------------------------------
  # Setup helpers
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
    registry_name = :"fence_reg_#{tag}_#{n}"
    sup_name = :"fence_sup_#{tag}_#{n}"

    {:ok, _reg} =
      start_supervised({@worker_registry, name: registry_name}, id: :"reg_#{n}")

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup, registry_name}
  end

  # A minimal Replay fixture that exits cleanly (no diff → :no_work_product is fine;
  # we only care about what env the child sees, not the work outcome).
  defp probe_fixture do
    [
      %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
      %Event.AssistantText{text: "cost-safety env probe", turn: 0},
      %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 0},
      %Event.Done{exit_status: 0, final_message: nil}
    ]
  end

  # ---------------------------------------------------------------------------
  # D-374: ALL THREE metered-spend variables must be scrubbed from child Port env
  # when spawning a metered-capable worker (agent_mode: :claude_code).
  #
  # Variables:
  #   - ANTHROPIC_API_KEY    (primary key — original coverage)
  #   - ANTHROPIC_AUTH_TOKEN (metered bearer token honoured by the claude CLI)
  #   - ANTHROPIC_BASE_URL   (proxy endpoint redirect — paid spend vector)
  #
  # Strategy: use an agent executable (shell script) that dumps the values of
  # all three variables to a file. The Worker injects canary values via extra_env.
  # Without the scrub, canaries leak; with the scrub they are absent.
  #
  # This test MUST FAIL on current branch because:
  #   (a) Worker has no :agent_mode / :creds_check_fun opts — KeyError on spawn.
  #   (b) Even if spawn succeeded, no {~c"ANTHROPIC_AUTH_TOKEN", false} or
  #       {~c"ANTHROPIC_BASE_URL", false} are added to the Port env, so those
  #       canaries leak to the child.
  # ---------------------------------------------------------------------------

  describe "D-374 — child env scrub" do
    @tag :d_374
    test "D-374: metered worker (agent_mode: :claude_code) scrubs ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, and ANTHROPIC_BASE_URL from child Port env" do
      tmp_dir = mk_tmp("d374_scrub")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      n = System.unique_integer([:positive])
      canary_key = "sk-test-D374-KEY-#{n}"
      canary_auth = "Bearer-D374-TOKEN-#{n}"
      canary_url = "https://proxy-d374-#{n}.example.com"
      dump_file = Path.join(tmp_dir, "env_dump.txt")

      # Agent executable: dumps all three metered-spend variables to dump_file.
      # Uses {packet,4} framing to keep the Worker happy (it expects framed JSON).
      # We emit an empty-but-valid exit so no work_ready fires (acceptable here).
      agent_bin = Path.join(tmp_dir, "dump_env_agent")

      File.write!(agent_bin, """
      #!/bin/sh
      KEY="${ANTHROPIC_API_KEY:-absent}"
      TOKEN="${ANTHROPIC_AUTH_TOKEN:-absent}"
      BASE="${ANTHROPIC_BASE_URL:-absent}"
      printf "ANTHROPIC_API_KEY=${KEY}\\nANTHROPIC_AUTH_TOKEN=${TOKEN}\\nANTHROPIC_BASE_URL=${BASE}\\n" > #{dump_file}
      # Emit exit-0; Worker maps to :no_work_product — acceptable for this test.
      exit 0
      """)

      File.chmod!(agent_bin, 0o755)

      {sup, registry_name} = start_fleet(:d374_scrub)
      report_to = self()

      # D-374: agent_mode: :claude_code activates preflight + scrub.
      # creds_check_fun: -> :ok simulates subscription creds present.
      # extra_env injects all three canaries so that, without scrub, they leak.
      # NEEDED SEAM: Worker must accept :agent_mode and :creds_check_fun opts.
      # On current branch this raises KeyError (unrecognised opts) → spawn fails.
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "d374 scrub probe", base_ref,
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

      # Wait for the worker to exit (Port exits immediately).
      assert_receive {:worker_exit, ^worker_id, _reason},
                     10_000,
                     "D-374: worker must complete and deliver death-cert within 10s"

      # Allow the child process to finish writing the dump file.
      Process.sleep(200)

      assert File.exists?(dump_file),
             "D-374: agent must have run and written dump_file=#{dump_file}. " <>
               "If the file is missing, the Port was never opened (preflight blocked it " <>
               "or the agent crashed before writing). Unexpected with creds_check_fun: -> :ok."

      dump_text = File.read!(dump_file)

      # D-374: ANTHROPIC_API_KEY canary MUST NOT appear — must have been scrubbed.
      refute String.contains?(dump_text, canary_key),
             "D-374: ANTHROPIC_API_KEY canary leaked into child env! " <>
               "Worker MUST pass {~c\"ANTHROPIC_API_KEY\", false} in the Port env. " <>
               "dump=#{inspect(dump_text)} canary=#{inspect(canary_key)}"

      # D-374 (broadened): ANTHROPIC_AUTH_TOKEN canary MUST NOT appear.
      refute String.contains?(dump_text, canary_auth),
             "D-374: ANTHROPIC_AUTH_TOKEN canary leaked into child env! " <>
               "Worker MUST pass {~c\"ANTHROPIC_AUTH_TOKEN\", false} in the Port env to scrub " <>
               "the metered bearer token. This is a new spend vector not scrubbed on current branch. " <>
               "dump=#{inspect(dump_text)} canary=#{inspect(canary_auth)}"

      # D-374 (broadened): ANTHROPIC_BASE_URL canary MUST NOT appear.
      refute String.contains?(dump_text, canary_url),
             "D-374: ANTHROPIC_BASE_URL canary leaked into child env! " <>
               "Worker MUST pass {~c\"ANTHROPIC_BASE_URL\", false} in the Port env to scrub " <>
               "the proxy redirect vector. This is a new spend vector not scrubbed on current branch. " <>
               "dump=#{inspect(dump_text)} canary=#{inspect(canary_url)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-374: fail-closed — creds absent → worker refuses to spawn, no Port opened.
  #
  # MUST FAIL on current branch: Worker has no preflight → Port opens → marker
  # file appears → refute fails.
  # ---------------------------------------------------------------------------

  describe "D-374 — fail-closed: creds absent" do
    @tag :d_374
    test "D-374: metered worker with absent subscription creds refuses to spawn (:metered_path_refused)" do
      tmp_dir = mk_tmp("d374_creds_absent")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      # Marker: if present the Port was opened — a D-374 violation.
      marker = Path.join(tmp_dir, "port_opened_despite_no_creds")

      agent_bin = Path.join(tmp_dir, "marker_agent")

      File.write!(agent_bin, """
      #!/bin/sh
      touch #{marker}
      exit 0
      """)

      File.chmod!(agent_bin, 0o755)

      {sup, registry_name} = start_fleet(:d374_creds_absent)
      report_to = self()

      # D-374: creds_check_fun returns absence → preflight must block Port.open.
      # NEEDED SEAM: Worker must accept :agent_mode and :creds_check_fun.
      # On current branch: Worker has no preflight → Port opens → marker appears.
      result =
        @worker_supervisor.spawn(sup, :implementer, "d374 creds absent", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name,
          agent_mode: :claude_code,
          creds_check_fun: fn -> {:error, :subscription_creds_absent} end
        )

      # Allow init to complete.
      Process.sleep(300)

      # D-374: Port must NEVER have been opened.
      refute File.exists?(marker),
             "D-374: worker opened the agent Port despite absent subscription creds! " <>
               "The preflight MUST block Port.open and exit :metered_path_refused. " <>
               "Marker appeared at #{marker}. " <>
               "Fails on current branch: Worker has no D-374 preflight."

      # D-374: the refusal reason must be :metered_path_refused.
      case result do
        {:ok, worker_id} ->
          assert_receive {:worker_exit, ^worker_id, :metered_path_refused},
                         2_000,
                         "D-374: {:worker_exit, worker_id, :metered_path_refused} must arrive " <>
                           "when subscription creds are absent"

        {:error, :metered_path_refused} ->
          :ok

        {:error, reason} ->
          flunk(
            "D-374: expected refusal with :metered_path_refused; " <>
              "got {:error, #{inspect(reason)}}"
          )
      end
    end

    @tag :d_374
    test "D-374: metered worker with present creds and scrubbed env proceeds (does NOT refuse)" do
      tmp_dir = mk_tmp("d374_creds_present")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      n = System.unique_integer([:positive])
      shim_bin_path = Path.join(tmp_dir, "shim_creds_ok_#{n}")

      # Noop Replay shim (no diff → :no_work_product; that is fine here).
      shim_bin =
        CodingAgentShim.write(shim_bin_path,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: probe_fixture(),
          branch: "feat/d374-creds-present-#{n}"
        )

      {sup, registry_name} = start_fleet(:d374_creds_present)
      report_to = self()

      # D-374: agent_mode: :claude_code + creds present → preflight passes → worker spawns.
      # NEEDED SEAM: Worker must accept :agent_mode and :creds_check_fun.
      # On current branch: Worker does not recognise :agent_mode → KeyError.
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "d374 creds present", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name,
          agent_mode: :claude_code,
          creds_check_fun: fn -> :ok end
        )

      # Worker must complete — any outcome except :metered_path_refused is correct.
      assert_receive msg
                     when elem(msg, 0) in [:work_ready, :worker_exit] and
                            elem(msg, 1) == worker_id,
                     15_000,
                     "D-374: worker with present creds must proceed and complete within 15s"

      case msg do
        {:worker_exit, ^worker_id, :metered_path_refused} ->
          flunk(
            "D-374: worker with PRESENT creds must NOT refuse. " <>
              "Got :metered_path_refused — preflight incorrectly blocked a valid run."
          )

        _ ->
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # D-375: ClaudeCode.start/2 scrubs ALL THREE metered-spend variables from the
  # child Port env by default; ctx[:allow_metered] == true is the only opt-out
  # (which retains all three).
  #
  # Variables scrubbed:
  #   - ANTHROPIC_API_KEY    (primary key — original coverage)
  #   - ANTHROPIC_AUTH_TOKEN (metered bearer token honoured by the claude CLI)
  #   - ANTHROPIC_BASE_URL   (proxy endpoint redirect — paid spend vector)
  #
  # We use a fake "claude" script that dumps all three variable values to a file.
  #
  # D-375 default scrub MUST FAIL on current branch: ClaudeCode.start/2 has no
  # {:env, ...} in its Port.open call → all three keys leak through → canary
  # values appear in dump → refute assertions fail.
  #
  # D-375 allow_metered MUST FAIL on current branch: ClaudeCode.start/2 does
  # not read ctx[:allow_metered] at all → the scrub (once implemented) would
  # not be conditionally bypassed. The allow_metered test asserts:
  #   "when allow_metered is true, ALL THREE vars pass through to child"
  # while the default test asserts:
  #   "when allow_metered is absent, NONE of the three appear in child env"
  # These form a discriminating pair. The default test is the genuine fail-before.
  # ---------------------------------------------------------------------------

  describe "D-375 — adapter-level scrub" do
    @tag :d_375
    test "D-375: ClaudeCode.start/2 default (no allow_metered) scrubs ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, and ANTHROPIC_BASE_URL from child Port env" do
      tmp_dir = mk_tmp("d375_default")

      n = System.unique_integer([:positive])
      canary_key = "sk-ant-D375-KEY-#{n}"
      canary_auth = "Bearer-D375-TOKEN-#{n}"
      canary_url = "https://proxy-d375-default-#{n}.example.com"
      dump_file = Path.join(tmp_dir, "claude_env_default.txt")

      # A fake "claude" that dumps all three metered-spend variables then exits.
      # Outputs valid stream-json so ClaudeCode's parser does not error.
      fake_claude = Path.join(tmp_dir, "claude")

      File.write!(fake_claude, """
      #!/bin/sh
      KEY="${ANTHROPIC_API_KEY:-absent}"
      TOKEN="${ANTHROPIC_AUTH_TOKEN:-absent}"
      BASE="${ANTHROPIC_BASE_URL:-absent}"
      printf "ANTHROPIC_API_KEY=${KEY}\\nANTHROPIC_AUTH_TOKEN=${TOKEN}\\nANTHROPIC_BASE_URL=${BASE}\\n" > #{dump_file}
      printf '{"type":"result","subtype":"success","result":"ok","session_id":"t1","is_error":false}\\n'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      old_path = System.get_env("PATH", "")
      System.put_env("PATH", "#{tmp_dir}:#{old_path}")
      System.put_env("ANTHROPIC_API_KEY", canary_key)
      System.put_env("ANTHROPIC_AUTH_TOKEN", canary_auth)
      System.put_env("ANTHROPIC_BASE_URL", canary_url)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        System.delete_env("ANTHROPIC_API_KEY")
        System.delete_env("ANTHROPIC_AUTH_TOKEN")
        System.delete_env("ANTHROPIC_BASE_URL")
      end)

      workspace = Path.join(tmp_dir, "ws")
      File.mkdir_p!(workspace)

      task = %{prompt: "test", workspace: workspace}
      # D-375: default ctx — scrub MUST apply to all three variables.
      ctx = %{}

      assert {:ok, stream} = ClaudeCode.start(task, ctx),
             "D-375: ClaudeCode.start/2 must return {:ok, stream} for a valid task"

      # Drain to trigger the lazily-opened Port.
      _events = Enum.to_list(stream)

      assert File.exists?(dump_file),
             "D-375: fake claude must have run and written dump_file=#{dump_file}"

      dump_text = File.read!(dump_file)

      # D-375: ANTHROPIC_API_KEY canary must NOT be in the child env.
      refute String.contains?(dump_text, canary_key),
             "D-375: ANTHROPIC_API_KEY canary leaked into ClaudeCode child env by default! " <>
               "ClaudeCode.start/2 MUST pass {~c\"ANTHROPIC_API_KEY\", false} in Port env " <>
               "when ctx[:allow_metered] is not true. " <>
               "dump=#{inspect(dump_text)}"

      # D-375 (broadened): ANTHROPIC_AUTH_TOKEN canary must NOT be in the child env.
      refute String.contains?(dump_text, canary_auth),
             "D-375: ANTHROPIC_AUTH_TOKEN canary leaked into ClaudeCode child env by default! " <>
               "ClaudeCode.start/2 MUST pass {~c\"ANTHROPIC_AUTH_TOKEN\", false} in Port env " <>
               "when ctx[:allow_metered] is not true. " <>
               "This is a new spend vector not scrubbed on current branch. " <>
               "dump=#{inspect(dump_text)}"

      # D-375 (broadened): ANTHROPIC_BASE_URL canary must NOT be in the child env.
      refute String.contains?(dump_text, canary_url),
             "D-375: ANTHROPIC_BASE_URL canary leaked into ClaudeCode child env by default! " <>
               "ClaudeCode.start/2 MUST pass {~c\"ANTHROPIC_BASE_URL\", false} in Port env " <>
               "when ctx[:allow_metered] is not true. " <>
               "This is a new spend vector not scrubbed on current branch. " <>
               "dump=#{inspect(dump_text)}"
    end

    @tag :d_375
    test "D-375: ClaudeCode.start/2 with ctx[:allow_metered] == true passes ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, and ANTHROPIC_BASE_URL through to child" do
      tmp_dir = mk_tmp("d375_allow")

      n = System.unique_integer([:positive])
      canary_key = "sk-ant-D375-ALLOW-KEY-#{n}"
      canary_auth = "Bearer-D375-ALLOW-TOKEN-#{n}"
      canary_url = "https://proxy-d375-allow-#{n}.example.com"
      dump_file = Path.join(tmp_dir, "claude_env_allow.txt")

      fake_claude = Path.join(tmp_dir, "claude")

      File.write!(fake_claude, """
      #!/bin/sh
      KEY="${ANTHROPIC_API_KEY:-absent}"
      TOKEN="${ANTHROPIC_AUTH_TOKEN:-absent}"
      BASE="${ANTHROPIC_BASE_URL:-absent}"
      printf "ANTHROPIC_API_KEY=${KEY}\\nANTHROPIC_AUTH_TOKEN=${TOKEN}\\nANTHROPIC_BASE_URL=${BASE}\\n" > #{dump_file}
      printf '{"type":"result","subtype":"success","result":"ok","session_id":"t2","is_error":false}\\n'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      old_path = System.get_env("PATH", "")
      System.put_env("PATH", "#{tmp_dir}:#{old_path}")
      System.put_env("ANTHROPIC_API_KEY", canary_key)
      System.put_env("ANTHROPIC_AUTH_TOKEN", canary_auth)
      System.put_env("ANTHROPIC_BASE_URL", canary_url)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        System.delete_env("ANTHROPIC_API_KEY")
        System.delete_env("ANTHROPIC_AUTH_TOKEN")
        System.delete_env("ANTHROPIC_BASE_URL")
      end)

      workspace = Path.join(tmp_dir, "ws")
      File.mkdir_p!(workspace)

      task = %{prompt: "test", workspace: workspace}
      # D-375: allow_metered opt-out — all three variables MUST pass through to child.
      ctx = %{allow_metered: true}

      assert {:ok, stream} = ClaudeCode.start(task, ctx),
             "D-375: ClaudeCode.start/2 must return {:ok, stream}"

      _events = Enum.to_list(stream)

      assert File.exists?(dump_file),
             "D-375: fake claude must have run and written dump_file=#{dump_file}"

      dump_text = File.read!(dump_file)

      # D-375: with allow_metered: true, ANTHROPIC_API_KEY MUST pass through (no scrub).
      assert String.contains?(dump_text, canary_key),
             "D-375: with ctx[:allow_metered] == true, ANTHROPIC_API_KEY MUST pass through " <>
               "to child (no scrub). canary not found. dump=#{inspect(dump_text)}"

      # D-375 (broadened): with allow_metered: true, ANTHROPIC_AUTH_TOKEN MUST pass through.
      assert String.contains?(dump_text, canary_auth),
             "D-375: with ctx[:allow_metered] == true, ANTHROPIC_AUTH_TOKEN MUST pass through " <>
               "to child (no scrub). canary not found. dump=#{inspect(dump_text)}"

      # D-375 (broadened): with allow_metered: true, ANTHROPIC_BASE_URL MUST pass through.
      assert String.contains?(dump_text, canary_url),
             "D-375: with ctx[:allow_metered] == true, ANTHROPIC_BASE_URL MUST pass through " <>
               "to child (no scrub). canary not found. dump=#{inspect(dump_text)}"
    end
  end
end
