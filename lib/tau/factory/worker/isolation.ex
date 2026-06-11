defmodule Tau.Factory.Worker.Isolation do
  @moduledoc """
  Pure helper functions for per-worker isolation in the Factory Worker fleet.

  All functions are stateless path and command computations — no processes,
  no filesystem side-effects, no shell invocations. The Worker (P4d-2) calls
  these to derive paths and build command descriptors; execution is the
  caller's responsibility.

  ## Invariants enforced

    * **D-309** — namespace totality and cross-worker disjointness. Every
      declared `var` maps to a directory rooted strictly inside the given
      worktree, so two distinct worktrees yield disjoint directory sets.
    * **D-311** — position verification. A `pwd` outside the worktree or a
      mismatched HEAD/branch always returns `{:error, reason}`.
    * **D-313** — capture-before-destroy command set. All three dirty-state
      kinds (`:status`, `:patch`, `:untracked`) are always present.
  """

  alias Tau.Toolchain.ResourceNS

  @typedoc "Absolute path to the worker's worktree root."
  @type worktree_abs :: String.t()

  @typedoc "Map from environment-variable name to its per-worker directory."
  @type namespace_map :: %{String.t() => String.t()}

  @typedoc "Observed runtime position of a worker process."
  @type observed :: %{pwd: String.t(), head: String.t(), branch: String.t()}

  @typedoc "Expected git ref and branch for the worker."
  @type expected :: %{head: String.t(), branch: String.t()}

  @typedoc "A single command descriptor for the capture-before-destroy sequence."
  @type command :: %{kind: atom(), argv: [String.t()]}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Resolve per-worker namespace directories for a list of resource declarations.

  For each `%ResourceNS{var: var}` in `decls`, maps `var` to the absolute
  directory `<worktree_abs>/.factory-ns/<var>`. The result map is **total**
  over `decls`: every declared `var` appears as a key. All resulting dirs are
  rooted inside `worktree_abs`, guaranteeing cross-worker disjointness when
  worktrees differ (D-309).

  This function only computes paths — it does NOT create directories.
  """
  @spec resolve_namespace(worktree_abs(), [ResourceNS.t()]) :: namespace_map()
  def resolve_namespace(worktree_abs, decls) do
    Map.new(decls, fn %ResourceNS{var: var} ->
      {var, Path.join([worktree_abs, ".factory-ns", var])}
    end)
  end

  @doc """
  Verify that a worker process is positioned inside the expected worktree and
  at the expected git ref.

  Returns `:ok` iff all three conditions hold:
    1. `observed.pwd` starts with `worktree_abs` (the worker is inside its worktree).
    2. `observed.head == expected.head` (correct commit).
    3. `observed.branch == expected.branch` (correct branch).

  Returns `{:error, reason}` where `reason` is the atom naming the first
  failing check (D-311, F-6):
    * `:not_in_worktree` — `pwd` is outside the worktree (e.g. parent root).
    * `:head_mismatch`   — HEAD does not match the expected commit SHA.
    * `:branch_mismatch` — the checked-out branch does not match.
  """
  @spec verify_position(worktree_abs(), observed(), expected()) ::
          :ok | {:error, atom() | {atom(), term()}}
  def verify_position(worktree_abs, observed, expected) do
    cond do
      not String.starts_with?(observed.pwd, worktree_abs) ->
        {:error, :not_in_worktree}

      observed.head != expected.head ->
        {:error, :head_mismatch}

      observed.branch != expected.branch ->
        {:error, :branch_mismatch}

      true ->
        :ok
    end
  end

  @doc """
  Build the list of command descriptors for capturing all dirty state in a
  worktree before destroying it (D-313, C203/C209).

  Returns exactly three descriptors — one per dirty kind:
    * `:status`    — `git -C <ws> status --short`
    * `:patch`     — `git -C <ws> diff HEAD` (staged + unstaged modifications)
    * `:untracked` — `git -C <ws> ls-files --others --exclude-standard`

  These descriptors are **not** executed here. The caller (WorkspaceJanitor,
  P4d-3) runs them in order and pipes the untracked list into a tar archive.
  """
  @spec capture_commands(worktree_abs()) :: [command()]
  def capture_commands(worktree_abs) do
    [
      %{
        kind: :status,
        argv: ["git", "-C", worktree_abs, "status", "--short"]
      },
      %{
        kind: :patch,
        argv: ["git", "-C", worktree_abs, "diff", "HEAD"]
      },
      %{
        kind: :untracked,
        argv: ["git", "-C", worktree_abs, "ls-files", "--others", "--exclude-standard"]
      }
    ]
  end
end
