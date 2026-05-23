defmodule Mix.Gate.Common do
  @moduledoc """
  Shared utilities for the three mechanical oracle-separation CI gates.

  Provides git-object inspection helpers used by `Mix.Gate.Mutation` and
  the repo-locator that finds the synthetic git repo containing gating-test
  paths in test environments.
  """

  @doc """
  Returns `true` when `base_ref` names an accessible git object in `repo_dir`.

  Uses `git cat-file -t` to probe the object database without checking out
  any content. Returns `false` on any non-zero exit, including when the ref
  does not exist or the directory is not a git repo.
  """
  @spec ref_accessible?(String.t(), Path.t()) :: boolean()
  def ref_accessible?(base_ref, repo_dir) do
    case System.cmd("git", ["cat-file", "-t", base_ref], cd: repo_dir, stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  Returns `true` when `rel_path` exists as a blob object at `base_ref` in `repo_dir`.

  Uses `git cat-file -e` which exits 0 iff the named object exists in the
  object database and is of the named type.
  """
  @spec path_exists_at_ref?(String.t(), String.t(), Path.t()) :: boolean()
  def path_exists_at_ref?(rel_path, base_ref, repo_dir) do
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

  @doc """
  Locates the git repo root that contains `gating_test_paths` and can resolve `base_ref`.

  Primary: if the first path resolves under `cwd` and `base_ref` is accessible there,
  returns `cwd`. Fallback: recursively searches under `cwd` for a `.git`-bearing
  directory satisfying both conditions, up to `max_depth` levels deep.

  The fallback handles test environments where ExUnit creates per-test subdirectories
  with their own git repos.
  """
  @spec locate_repo_for_gating_tests([String.t()], Path.t(), String.t()) :: Path.t()
  def locate_repo_for_gating_tests([], cwd, _base_ref), do: cwd

  def locate_repo_for_gating_tests([first | _], cwd, base_ref) do
    primary = Path.join(cwd, first)

    if File.exists?(primary) and ref_accessible?(base_ref, cwd) do
      cwd
    else
      find_repo_containing_path_and_ref(first, base_ref, cwd) || cwd
    end
  end

  @doc """
  Depth-limited search for a directory that contains `.git`, hosts `rel_path`, and
  can resolve `base_ref`. Returns the directory path or `nil` if not found within
  `max_depth` levels.
  """
  @spec find_repo_containing_path_and_ref(String.t(), String.t(), Path.t(), non_neg_integer()) ::
          Path.t() | nil
  def find_repo_containing_path_and_ref(rel_path, base_ref, start_dir, max_depth \\ 5) do
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
end
