defmodule Mix.Gate.Mutation do
  @moduledoc """
  Gate 5.3 — Mutation check.

  Keeps the declared gating-test paths at HEAD (test-author's state), reverts
  every other tracked path to `base_ref` (the PR's merge-base with `main`),
  runs the gating tests via `mix test`, then restores the repo to HEAD.

  `base_ref` is the PR's merge-base with `main` (i.e. `git merge-base
  origin/main HEAD`). Because the test-author touches only the declared
  gating-test paths — which the mutation check snapshots and restores
  separately — reverting "everything else" to the merge-base reverts no
  test-author work. The merge-base and the conceptual "pre-implementer" state
  are equivalent.

  The destructive revert sequence runs inside a `try/after` block. The
  `after` clause restores the working tree to HEAD unconditionally — whether
  the check succeeds, fails, or raises. This closes the safety gap where a
  process kill or compile error mid-run would leave the repo in a partially
  reverted state (D-NNN: see `.code_audit/00-synthesis.md` §9 finding #14).

  Returns:
  - `:ok` — ≥1 gating test fails against the reverted tree (suite is discriminating).
  - `:not_applicable` — either (a) every declared gating-test path lives in a Mix
    project whose nearest-ancestor `mix.exs` is absent at `base_ref` (PR-created
    project; no pre-implementer code to mutate), or (b) `git diff --name-only
    base_ref HEAD` reports no changed paths outside the declared gating-test paths
    (no production delta — test-only, docs-only, or delete-only change where the
    deleted files are all within the gating-test set; nothing to mutate).
  - `{:error, :all_passed}` — all gating tests pass against the reverted tree
    (vacuous suite).
  - `{:error, {:runner_crashed, detail}}` — `mix test` exited without producing
    a valid `"N tests, M failures"` summary (compile error or process crash).
    Callers MUST treat this as an infrastructure failure, not a gate verdict.
  """

  alias Mix.Gate.Common
  alias Tau.Factory.Gate.Mutation, as: PureMutation

  @doc """
  Orchestrates the mutation check in the current working directory's git repo.

  Takes `gating_test_paths` (repo-relative paths to gating-test files) and
  `base_ref` (a git ref representing the pre-implementer state). Reverts all
  tracked files except the gating-test paths to `base_ref`, runs the gating
  tests, and restores HEAD in an `after` block that fires unconditionally.
  """
  @spec mutation_check([String.t()], String.t()) ::
          :ok
          | :not_applicable
          | {:error, :all_passed}
          | {:error, {:runner_crashed, String.t()}}
  def mutation_check(gating_test_paths, base_ref)
      when is_list(gating_test_paths) and is_binary(base_ref) do
    repo_dir = Common.locate_repo_for_gating_tests(gating_test_paths, File.cwd!(), base_ref)

    if project_creation_pr?(gating_test_paths, base_ref, repo_dir) do
      :not_applicable
    else
      mutation_check_in(gating_test_paths, base_ref, repo_dir)
    end
  end

  # Returns true iff gating_test_paths is non-empty AND every path's enclosing
  # Mix project (nearest ancestor mix.exs) is absent at base_ref — i.e. every
  # gating test lives in a PR-created project.
  #
  # Conservative: a path with NO ancestor mix.exs is treated as NOT PR-created.
  # A mixed PR (some paths in existing projects, some in new ones) returns false
  # — the N/A short-circuit applies only when ALL paths are PR-created.
  defp project_creation_pr?([], _base_ref, _repo_dir), do: false

  defp project_creation_pr?(gating_test_paths, base_ref, repo_dir) do
    Enum.all?(gating_test_paths, fn test_path ->
      case find_enclosing_mix_exs(test_path, repo_dir) do
        nil ->
          false

        mix_exs_relpath ->
          not Common.path_exists_at_ref?(mix_exs_relpath, base_ref, repo_dir)
      end
    end)
  end

  # Walk up from the gating-test file's directory to find the nearest ancestor
  # directory containing a mix.exs, returning its repo-relative path, or nil.
  defp find_enclosing_mix_exs(test_path, repo_dir) do
    start_dir = test_path |> Path.dirname()
    do_find_mix_exs(start_dir, repo_dir)
  end

  defp do_find_mix_exs(rel_dir, repo_dir) do
    mix_exs_relpath =
      if rel_dir == "." do
        "mix.exs"
      else
        Path.join(rel_dir, "mix.exs")
      end

    abs_mix_exs = Path.join(repo_dir, mix_exs_relpath)

    if File.exists?(abs_mix_exs) do
      mix_exs_relpath
    else
      parent = Path.dirname(rel_dir)

      if parent == rel_dir do
        nil
      else
        do_find_mix_exs(parent, repo_dir)
      end
    end
  end

  defp mutation_check_in(gating_test_paths, base_ref, repo_dir) do
    {all_files_str, 0} = System.cmd("git", ["ls-files"], cd: repo_dir)
    all_files = all_files_str |> String.split("\n", trim: true)

    paths_to_revert = all_files -- gating_test_paths

    if no_production_delta?(gating_test_paths, base_ref, repo_dir) do
      :not_applicable
    else
      gating_snapshots = snapshot_files(gating_test_paths, repo_dir)

      try do
        revert_to_base(paths_to_revert, base_ref, repo_dir)
        restore_snapshots(gating_snapshots, repo_dir)
        run_gating_tests(gating_test_paths, repo_dir)
      after
        restore_head(all_files, repo_dir)
      end
    end
  end

  # Returns true iff the PR's entire diff (base_ref → HEAD) lies within the
  # declared gating-test paths — i.e. no production delta outside those paths.
  #
  # Uses `git diff --name-only base_ref HEAD` which reports ALL changed paths
  # regardless of whether they are additions, modifications, deletions, or
  # renames (unlike `git ls-files`, which only lists files present at HEAD and
  # therefore silently omits deleted production files). If the set of changed
  # paths minus the gating-test paths is empty, there is no production delta.
  defp no_production_delta?(gating_test_paths, base_ref, repo_dir) do
    case System.cmd(
           "git",
           ["diff", "--name-only", base_ref, "HEAD"],
           cd: repo_dir,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        changed = output |> String.split("\n", trim: true)
        production_changed = changed -- gating_test_paths
        production_changed == []

      _ ->
        # If the diff command fails (e.g. invalid base_ref), assume there IS a
        # production delta so we don't silently skip the mutation check.
        false
    end
  end

  defp snapshot_files(paths, repo_dir) do
    Enum.map(paths, fn rel_path ->
      abs = Path.join(repo_dir, rel_path)

      content =
        case File.read(abs) do
          {:ok, c} -> c
          {:error, _} -> nil
        end

      {rel_path, content}
    end)
  end

  # Revert each non-gating path to base_ref individually, handling two cases:
  #   - path exists at base_ref: git checkout base_ref -- <path>
  #   - path was PR-added (absent at base_ref): delete it
  defp revert_to_base([], _base_ref, _repo_dir), do: :ok

  defp revert_to_base(paths, base_ref, repo_dir) do
    Enum.each(paths, fn rel_path ->
      if Common.path_exists_at_ref?(rel_path, base_ref, repo_dir) do
        {_, 0} = System.cmd("git", ["checkout", base_ref, "--", rel_path], cd: repo_dir)
      else
        abs = Path.join(repo_dir, rel_path)
        _ = File.rm(abs)
      end
    end)

    :ok
  end

  defp restore_snapshots(snapshots, repo_dir) do
    Enum.each(snapshots, fn {rel_path, content} ->
      if content != nil do
        abs = Path.join(repo_dir, rel_path)
        File.mkdir_p!(Path.dirname(abs))
        File.write!(abs, content)
      end
    end)
  end

  defp restore_head(paths, repo_dir) do
    {_, _} = System.cmd("git", ["checkout", "HEAD", "--" | paths], cd: repo_dir)
    :ok
  end

  # Run the gating tests and apply the pure judge/1 predicate from
  # Tau.Factory.Gate.Mutation. Distinguishes three outcomes:
  #
  #   - ≥1 failure  → PureMutation.judge/1 → {:pass, _}  → :ok
  #   - 0 failures  → PureMutation.judge/1 → {:fail, _}  → {:error, :all_passed}
  #   - no summary  → {:error, {:runner_crashed, output}}
  defp run_gating_tests(gating_test_paths, repo_dir) do
    output =
      if File.exists?(Path.join(repo_dir, "mix.exs")) do
        run_via_mix(gating_test_paths, repo_dir)
      else
        run_via_elixir(gating_test_paths, repo_dir)
      end

    case parse_test_summary(output) do
      {:ok, failures} ->
        # Build a minimal report and delegate to the pure judge/1.
        cases = build_minimal_cases(failures)
        report = %{cases: cases}

        case PureMutation.judge(report) do
          {:pass, _killed} -> :ok
          {:fail, :no_test_failed} -> {:error, :all_passed}
        end

      :no_summary ->
        {:error, {:runner_crashed, output}}
    end
  end

  # Build a minimal cases list from a failure count. We do not have individual
  # test IDs from the text summary, so we synthesise them as "failed_N" for
  # each failed test. The judge/1 contract only requires :status fields.
  defp build_minimal_cases(0), do: []

  defp build_minimal_cases(failures) do
    Enum.map(1..failures, fn i -> %{id: "failed_#{i}", status: :failed} end)
  end

  defp run_via_mix(gating_test_paths, repo_dir) do
    {output, _} =
      System.cmd("mix", ["test" | gating_test_paths], cd: repo_dir, stderr_to_stdout: true)

    output
  end

  # Run gating tests with `elixir` directly for minimal synthetic repos that
  # lack a mix.exs. Requires lib/*.ex files in the repo, then requires the
  # gating test files. Safe for single-module mini-repos.
  defp run_via_elixir(gating_test_paths, repo_dir) do
    lib_files = find_lib_files_recursive(repo_dir)

    requires =
      (lib_files ++ gating_test_paths)
      |> Enum.map_join("\n", fn p -> ~s[Code.require_file("#{p}", "#{repo_dir}")] end)

    runner = """
    ExUnit.start()
    #{requires}
    ExUnit.run()
    """

    runner_path =
      Path.join(repo_dir, "_mutation_runner_#{:erlang.unique_integer([:positive])}.exs")

    File.write!(runner_path, runner)

    {output, _} =
      try do
        System.cmd("elixir", [runner_path], cd: repo_dir, stderr_to_stdout: true)
      after
        File.rm(runner_path)
      end

    output
  end

  # Parse the ExUnit summary line, e.g. "3 tests, 1 failure" or "3 tests, 0 failures".
  # Returns {:ok, failure_count} or :no_summary.
  defp parse_test_summary(output) do
    case Regex.run(~r/\d+ tests?,\s*(\d+) failures?/, output) do
      [_, failures_str] -> {:ok, String.to_integer(failures_str)}
      nil -> :no_summary
    end
  end

  defp find_lib_files_recursive(repo_dir) do
    lib_dir = Path.join(repo_dir, "lib")

    if File.dir?(lib_dir) do
      do_find_ex_files(lib_dir, repo_dir)
    else
      []
    end
  end

  defp do_find_ex_files(dir, repo_dir) do
    case File.ls(dir) do
      {:error, _} ->
        []

      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          abs = Path.join(dir, entry)
          rel = Path.relative_to(abs, repo_dir)

          cond do
            File.regular?(abs) and String.ends_with?(entry, ".ex") -> [rel]
            File.dir?(abs) -> do_find_ex_files(abs, repo_dir)
            true -> []
          end
        end)
    end
  end
end
