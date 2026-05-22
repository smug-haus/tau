defmodule Tau.Factory.Gate do
  @moduledoc """
  Pure module implementing the three mechanical oracle-separation CI gates
  for the factory loop (issue #370 / PR-B).

  All three functions are side-effect-free with respect to module state —
  no process, no ETS, no GenServer. `mutation_check/2` shells out to run
  tests in the supplied git repo directory; that is its only I/O.

  ## Gate 5.1 — AC-to-test linkage (`ac_linkage/2`)

  Parses every `AC-N` / `D-NNN` token from the draft-PR body and returns
  the subset not found (as a test name substring or `@tag`) in any of the
  supplied gating-test source strings.

  ## Gate 5.2 — Masking detection (`masking_violations/1`)

  Scans a unified diff for removed assertion lines (lines starting with
  `-` that contain `assert`, `refute`, `assert_receive`, or
  `assert_raise`). Detection-only — returns the list for review.

  ## Gate 5.3 — Mutation check (`mutation_check/2`)

  `base_ref` is the PR's merge-base with `main` (computed by
  `git merge-base origin/main HEAD`). In practice this equals the
  "pre-implementer" state because the test-author's commits touch only the
  declared gating-test paths — which the mutation check snapshots and
  restores separately — so reverting every other path to the merge-base
  reverts no test-author work.

  Keeps the declared gating-test paths at HEAD, reverts every other path
  to `base_ref`, runs the gating tests via `mix test`, and returns:

  - `:ok` when ≥1 test fails (the tests are discriminating).
  - `{:error, :all_passed}` when no test fails (the gating suite is vacuous).
  - `{:error, {:runner_crashed, detail}}` when `mix test` does not emit a
    valid `"N tests, M failures"` summary — e.g. a compile error or process
    crash crashed the runner before it could produce a summary. This outcome
    is DISTINCT from both `:ok` and `{:error, :all_passed}`; callers MUST
    NOT treat a runner crash as a genuine test result.
  """

  # ---------------------------------------------------------------------------
  # Gate 5.1 — AC-to-test linkage
  # ---------------------------------------------------------------------------

  @doc """
  Returns `:ok` when every `AC-N` / `D-NNN` token in `pr_body` appears in
  at least one of `gating_test_sources` (as a test name substring or
  `@tag`), or `{:error, missing}` listing those that do not.

  Token format:
  - `AC-N` — one or more digits, e.g. `AC-1`, `AC-12`
  - `D-NNN` — one or more digits, e.g. `D-200`, `D-031`

  Matching is case-insensitive on the tag side (`:ac_1`, `:d_200`) and
  substring on the test-name side (`"AC-1: ..."`, `"D-200: ..."`).
  """
  @spec ac_linkage(String.t(), [String.t()]) :: :ok | {:error, [String.t()]}
  def ac_linkage(pr_body, gating_test_sources)
      when is_binary(pr_body) and is_list(gating_test_sources) do
    claimed = parse_ac_tokens(pr_body)
    missing = Enum.reject(claimed, &token_covered?(&1, gating_test_sources))

    case missing do
      [] -> :ok
      _ -> {:error, missing}
    end
  end

  # Parse all AC-N and D-NNN tokens from the PR body.
  defp parse_ac_tokens(pr_body) do
    ac_pattern = ~r/\bAC-\d+\b/
    d_pattern = ~r/\bD-\d+\b/

    ac_tokens = Regex.scan(ac_pattern, pr_body) |> List.flatten()
    d_tokens = Regex.scan(d_pattern, pr_body) |> List.flatten()

    (ac_tokens ++ d_tokens) |> Enum.uniq()
  end

  # Check if a token (e.g. "AC-1" or "D-200") is covered in any source.
  defp token_covered?(token, sources) do
    # Normalise to tag form: "AC-1" -> "ac_1", "D-200" -> "d_200"
    tag_form = token |> String.downcase() |> String.replace("-", "_")
    # Also match as substring in test names, e.g. "AC-1: ..." or "D-200: ..."
    Enum.any?(sources, fn source ->
      String.contains?(source, ":#{tag_form}") or
        String.contains?(source, "\"#{token}") or
        String.contains?(source, "\"#{tag_form}")
    end)
  end

  # ---------------------------------------------------------------------------
  # Gate 5.2 — Masking detection
  # ---------------------------------------------------------------------------

  @doc """
  Scans `unified_diff` for removed assertion lines.

  A removed assertion line is a `-`-prefixed line (not `---` file header)
  whose content contains `assert`, `refute`, `assert_receive`, or
  `assert_raise`.

  Returns a list of maps `%{file: String.t(), line: integer(), removed: String.t()}`.
  `line` is the original-file line number (parsed from `@@ -L,N` hunks).
  `removed` is the raw content of the `-` line (without the leading `-`).
  """
  @spec masking_violations(String.t()) :: [
          %{file: String.t(), line: integer(), removed: String.t()}
        ]
  def masking_violations(unified_diff) when is_binary(unified_diff) do
    lines = String.split(unified_diff, "\n")
    parse_diff_lines(lines, nil, 0, [])
  end

  # State machine over diff lines:
  #   current_file — path of file being diffed (nil until first "diff --git")
  #   orig_line    — current original-file line counter (reset per hunk)
  defp parse_diff_lines([], _file, _orig_line, acc), do: Enum.reverse(acc)

  defp parse_diff_lines([h | t], current_file, orig_line, acc) do
    cond do
      # File header — e.g. "+++ b/test/foo.exs"
      String.starts_with?(h, "+++ b/") ->
        file = String.slice(h, 6..-1//1)
        parse_diff_lines(t, file, orig_line, acc)

      # Hunk header — e.g. "@@ -3,7 +3,6 @@"
      String.starts_with?(h, "@@") ->
        orig = parse_hunk_orig_line(h)
        parse_diff_lines(t, current_file, orig, acc)

      # Removed line (but not the "---" file header)
      String.starts_with?(h, "-") and not String.starts_with?(h, "---") ->
        content = String.slice(h, 1..-1//1)

        acc2 =
          if assertion_line?(content) do
            [%{file: current_file, line: orig_line, removed: content} | acc]
          else
            acc
          end

        # Removed lines advance the original-file counter
        parse_diff_lines(t, current_file, orig_line + 1, acc2)

      # Added line — does NOT advance original-file counter
      String.starts_with?(h, "+") and not String.starts_with?(h, "+++") ->
        parse_diff_lines(t, current_file, orig_line, acc)

      # Context line — advances original-file counter
      true ->
        parse_diff_lines(t, current_file, orig_line + 1, acc)
    end
  end

  @assertion_keywords ~w[assert refute assert_receive assert_raise]

  defp assertion_line?(content) do
    Enum.any?(@assertion_keywords, &String.contains?(content, &1))
  end

  # Parse the original starting line from a hunk header like "@@ -3,7 +3,6 @@"
  defp parse_hunk_orig_line(hunk_header) do
    case Regex.run(~r/@@ -(\d+)/, hunk_header) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Gate 5.3 — Mutation check
  # ---------------------------------------------------------------------------

  @doc """
  Orchestrates the mutation check in the current working directory's git repo.

  Keeps `gating_test_paths` at HEAD (test-author's state), reverts all other
  paths to `base_ref` (the PR's merge-base with `main`), runs the gating
  tests via `mix test`, then restores the repo to HEAD.

  `base_ref` is the PR's merge-base with `main` (i.e. `git merge-base
  origin/main HEAD`). The test-author touches only the declared gating-test
  paths, which the mutation check snapshots and restores separately, so
  reverting "everything else" to the merge-base reverts no test-author work —
  the merge-base and the conceptual "pre-implementer" state are equivalent.

  Returns:
  - `:ok` when ≥1 gating test fails against the reverted tree (tests discriminate).
  - `{:error, :all_passed}` when no gating test fails (vacuous suite).
  - `{:error, {:runner_crashed, detail}}` when `mix test` exits without
    producing a valid `"N tests, M failures"` summary — e.g. a compile error
    or process crash prevented the run from completing. Callers MUST treat this
    as an infrastructure failure, not a genuine test result.

  The check is performed in the process's current working directory, which must
  be a git repository. The gating-test paths are kept at their HEAD state;
  all other tracked files are reverted to `base_ref` for the duration of the
  check, then restored.
  """
  @spec mutation_check([String.t()], String.t()) ::
          :ok | {:error, :all_passed} | {:error, {:runner_crashed, String.t()}}
  def mutation_check(gating_test_paths, base_ref)
      when is_list(gating_test_paths) and is_binary(base_ref) do
    repo_dir = locate_repo_for_gating_tests(gating_test_paths, File.cwd!(), base_ref)
    mutation_check_in(gating_test_paths, base_ref, repo_dir)
  end

  # Locate the git repo root that contains the gating test files AND the given
  # base_ref commit.
  #
  # Primary: if the first gating test path resolves under `cwd` AND `base_ref`
  # is accessible in `cwd`'s git repo, use `cwd` directly.
  # Fallback: search recursively under `cwd` for a `.git`-bearing directory
  # that (a) contains the first gating test path and (b) can resolve `base_ref`.
  # This fallback handles test environments where ExUnit creates a per-test
  # subdirectory with its own git repo (e.g. `:tmp_dir` tests).
  defp locate_repo_for_gating_tests([], cwd, _base_ref), do: cwd

  defp locate_repo_for_gating_tests([first | _], cwd, base_ref) do
    primary = Path.join(cwd, first)

    if File.exists?(primary) and ref_accessible?(base_ref, cwd) do
      cwd
    else
      find_repo_containing_path_and_ref(first, base_ref, cwd) || cwd
    end
  end

  # Check if `base_ref` is accessible as a git object in `repo_dir`.
  defp ref_accessible?(base_ref, repo_dir) do
    case System.cmd("git", ["cat-file", "-t", base_ref], cd: repo_dir, stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # Depth-limited recursive search for a directory that:
  #   - contains a `.git` subdirectory,
  #   - has the relative `rel_path` under it, and
  #   - can resolve `base_ref` as a git object.
  defp find_repo_containing_path_and_ref(rel_path, base_ref, start_dir, max_depth \\ 5) do
    do_find_repo(rel_path, base_ref, start_dir, max_depth)
  end

  defp do_find_repo(_rel_path, _base_ref, _dir, 0), do: nil

  defp do_find_repo(rel_path, base_ref, dir, depth) do
    case File.ls(dir) do
      {:error, _} ->
        nil

      {:ok, entries} ->
        subdirs =
          entries
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.reject(&(Path.basename(&1) |> String.starts_with?(".")))

        Enum.find_value(subdirs, fn subdir ->
          git_dir = Path.join(subdir, ".git")
          candidate = Path.join(subdir, rel_path)

          if File.exists?(git_dir) and File.exists?(candidate) and
               ref_accessible?(base_ref, subdir) do
            subdir
          else
            do_find_repo(rel_path, base_ref, subdir, depth - 1)
          end
        end)
    end
  end

  defp mutation_check_in(gating_test_paths, base_ref, repo_dir) do
    # Capture HEAD content of gating test files (before any reverting)
    gating_snapshots = snapshot_files(gating_test_paths, repo_dir)

    # Get all tracked files in HEAD of the repo
    {all_files_str, 0} = System.cmd("git", ["ls-files"], cd: repo_dir)
    all_files = all_files_str |> String.split("\n", trim: true)

    # Files to revert = all tracked files minus the gating test paths
    paths_to_revert = all_files -- gating_test_paths

    # Revert non-gating files to base_ref (pre-implementer state).
    # PR-added files are absent at base_ref and must be deleted rather than
    # checked out — git checkout base -- <absent-path> fails or is a no-op.
    revert_to_base(paths_to_revert, base_ref, repo_dir)

    # Restore gating test files to their HEAD content (test-author state)
    restore_snapshots(gating_snapshots, repo_dir)

    # Run the gating tests against the reverted tree via mix test.
    # mix resolves compile order correctly, avoiding fs-order require issues.
    result = run_gating_tests(gating_test_paths, repo_dir)

    # Restore all files to HEAD (clean up mutation state)
    restore_head(all_files, repo_dir)

    result
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
      if path_exists_at_ref?(rel_path, base_ref, repo_dir) do
        {_, 0} = System.cmd("git", ["checkout", base_ref, "--", rel_path], cd: repo_dir)
      else
        # PR-added file: absent at base_ref, must be removed to produce the
        # pre-implementer tree. git checkout base -- <absent> would fail.
        abs = Path.join(repo_dir, rel_path)
        _ = File.rm(abs)
      end
    end)

    :ok
  end

  # Returns true iff rel_path exists as a blob object at base_ref in the repo.
  defp path_exists_at_ref?(rel_path, base_ref, repo_dir) do
    case System.cmd(
           "git",
           ["cat-file", "-e", "#{base_ref}:#{rel_path}"],
           cd: repo_dir,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
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

  # Run the gating tests, distinguishing three outcomes by parsing the ExUnit
  # "N tests, M failures" summary line:
  #
  #   - summary present, M > 0  → :ok                           (tests discriminate)
  #   - summary present, M == 0 → {:error, :all_passed}         (vacuous suite)
  #   - no summary at all       → {:error, {:runner_crashed, output}}
  #                               (compile error / process crash / no mix.exs)
  #
  # Uses `mix test` when a mix.exs is present in repo_dir (the normal CI case).
  # Falls back to a direct `elixir` runner for minimal synthetic repos (tests).
  # Both paths parse the same ExUnit summary line.
  defp run_gating_tests(gating_test_paths, repo_dir) do
    output =
      if File.exists?(Path.join(repo_dir, "mix.exs")) do
        run_via_mix(gating_test_paths, repo_dir)
      else
        run_via_elixir(gating_test_paths, repo_dir)
      end

    case parse_test_summary(output) do
      {:ok, failures} when failures > 0 ->
        :ok

      {:ok, 0} ->
        {:error, :all_passed}

      :no_summary ->
        {:error, {:runner_crashed, output}}
    end
  end

  # Run gating tests with `mix test` (compile-order-correct; requires mix.exs).
  defp run_via_mix(gating_test_paths, repo_dir) do
    {output, _} =
      System.cmd("mix", ["test" | gating_test_paths], cd: repo_dir, stderr_to_stdout: true)

    output
  end

  # Run gating tests with `elixir` directly for minimal synthetic repos.
  # Requires lib/*.ex files in the repo, then requires the gating test files.
  # For single-module mini-repos this is compile-order-safe.
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
    # Match lines like "3 tests, 1 failure" or "5 tests, 2 failures" or "1 test, 0 failures"
    case Regex.run(~r/\d+ tests?,\s*(\d+) failures?/, output) do
      [_, failures_str] -> {:ok, String.to_integer(failures_str)}
      nil -> :no_summary
    end
  end

  # Recursively collect .ex files under the repo's lib/ directory.
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
