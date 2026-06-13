defmodule Tau.Factory.IssueSelector do
  @moduledoc """
  Real `select_fun` for the Coordinator loop (K) — B10 / D-331 / D-342.

  `IssueSelector.select/1` is the real `select_fun` the Coordinator calls to
  turn "open issues in the assigned milestone" into admittable work. It:

    1. Reads open milestone issues via a **stubbable, read-only `gh` adapter**
       injected as the `:gh_fun` seam — the default real implementation shells
       out `gh issue list --milestone <m> --state open --json number,title,body,labels`
       and decodes the result. Tests inject a stub; NO network call occurs in
       tests (D-331 §4 [C112-B10]).

    2. **Projects against the Ledger** (`Ledger.Reader.latest_unit_snapshots/1`)
       to DROP issues whose unit is already terminal (`:merged` / `:escalated`).
       The projection is READ-ONLY — L is the authority for *what is done* and is
       NEVER written by the selector (D-331, §4 [C112-B10]).

    3. Picks the smallest shippable increment (first admittable open issue in
       tracker order) and freezes a declared scope.

    4. Returns a `work_item` `{issue, scope, hash, branch}`, or `nil` when no
       admittable open issue remains (D-342 — milestone termination signal).

  ## Pinned contract (§4 B10 amendment, PR #470)

    - **Entry point:** `select(opts :: keyword()) :: work_item | nil`.

    - **opts:**
        * `:ledger`    — `GenServer.server()` of a running `Ledger.Writer`
                         (projection source, read-only).
        * `:milestone` — `String.t()`; the assigned milestone title.
        * `:gh_fun`    — `(milestone :: String.t() -> {:ok, [issue_map]})`;
                         the stubbable read-only `gh` adapter. When absent,
                         the real default is used. `issue_map` carries at
                         minimum `"number"` and `"title"` keys (the `--json`
                         projection). This seam follows the codebase's
                         canonical `*_fun` injection pattern.

    - **`unit_id` derivation:** `"unit-<number>"` — a stable, issue-derived id
      so the L-projection aligns with the ids the rest of the factory snapshots
      under (D-331 §4 [C112-B10], pinned in this PR).

    - **Return:** `{issue, scope, hash, branch}` (4-tuple `work_item`) or `nil`.
      `scope` is a non-nil frozen declared scope string; `hash` and `branch` are
      non-empty strings.

  This module is a plain functional module — no GenServer. Pure given injected
  seams (OTP non-negotiable §3: no GenServer wrapping stateless logic).
  """

  alias Tau.Factory.Ledger.Reader, as: LedgerReader

  @terminal_states [:merged, :escalated]

  @typedoc """
  The 4-tuple returned by `select/1` when an admittable issue exists.

  - `issue`  — the raw `issue_map` (or normalised form) carrying at minimum
               `"number"` and `"title"`.
  - `scope`  — frozen declared scope string (non-nil).
  - `hash`   — content hash string (non-empty).
  - `branch` — feature branch name string (non-empty).
  """
  @type work_item ::
          {issue_map :: map(), scope :: String.t(), hash :: String.t(), branch :: String.t()}

  @doc """
  Select the next admittable work item from the assigned milestone.

  ## Options

    - `:ledger`    — `GenServer.server()`; a running `Ledger.Writer`.
    - `:milestone` — `String.t()`; the milestone title to query.
    - `:gh_fun`    — optional; `(String.t() -> {:ok, [map()]})`. Defaults to
                     the real `gh issue list` shell adapter.

  Returns a `work_item` 4-tuple or `nil`.
  """
  @spec select(keyword()) :: work_item() | nil
  def select(opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    milestone = Keyword.fetch!(opts, :milestone)
    gh_fun = Keyword.get(opts, :gh_fun, &default_gh_fun/1)

    {:ok, issues} = gh_fun.(milestone)

    snapshots = LedgerReader.latest_unit_snapshots(ledger)

    issues
    |> Enum.reject(&terminal_in_ledger?(&1, snapshots))
    |> pick_work_item()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Derive the unit_id for an issue using the factory-test convention.
  # MUST match `"unit-<number>"` so the L-projection aligns with ids the rest
  # of the factory snapshots under (D-331 §4 [C112-B10], pinned PR #470).
  defp unit_id_for(%{"number" => number}), do: "unit-#{number}"

  # True when the issue's derived unit_id has a terminal state in L.
  defp terminal_in_ledger?(issue, snapshots) do
    uid = unit_id_for(issue)
    Map.get(snapshots, uid) in @terminal_states
  end

  # Pick the smallest shippable increment: first in tracker order.
  # Freezes a declared scope and derives a deterministic hash and branch name.
  defp pick_work_item([]), do: nil

  defp pick_work_item([issue | _rest]) do
    number = Map.fetch!(issue, "number")
    title = Map.get(issue, "title", "")

    scope = "#{number}: #{title}"
    hash = content_hash(number, title)
    branch = "unit-#{number}"

    {issue, scope, hash, branch}
  end

  # Deterministic content hash for the scope — SHA-256 of "number:title".
  defp content_hash(number, title) do
    :crypto.hash(:sha256, "#{number}:#{title}")
    |> Base.encode16(case: :lower)
  end

  # Default real `gh` adapter: shells out to `gh issue list`.
  # Tests MUST inject a stub via `:gh_fun` — this path is NOT exercised in tests.
  defp default_gh_fun(milestone) do
    cmd =
      "gh issue list --milestone #{shell_escape(milestone)} --state open --json number,title,body,labels"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: false) do
      {output, 0} ->
        Jason.decode(output)

      {output, code} ->
        {:error, {:gh_exit, code, output}}
    end
  end

  defp shell_escape(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
