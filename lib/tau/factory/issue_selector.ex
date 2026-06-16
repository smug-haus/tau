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

  ## Pinned contract (§4 B10 amendment, PR #470, updated PR #505)

    - **Entry point:** `select(opts :: keyword()) :: work_item | nil`.

    - **opts:**
        * `:ledger`        — `GenServer.server()` of a running `Ledger.Writer`
                             (projection source, read-only).
        * `:milestone`     — `String.t()`; the assigned milestone title.
        * `:gh_fun`        — optional; `(String.t() -> {:ok, [map()]})`. Defaults to
                             the real `gh issue list` shell adapter.
        * `:elaborate_fun` — optional; `(issue_map -> ConflictCheck.scope())`.
                             Defaults to the pure heuristic elaborator (D-370).
                             The injected function is called with the raw `issue_map`
                             and its return value becomes `work_item.scope`.

    - **`unit_id` derivation:** `"unit-<number>"` — a stable, issue-derived id
      so the L-projection aligns with the ids the rest of the factory snapshots
      under (D-331 §4 [C112-B10], pinned in this PR).

    - **Return:** `{issue, scope, hash, branch}` (4-tuple `work_item`) or `nil`.
      `scope` is a `ConflictCheck.scope()` map; `hash` and `branch` are
      non-empty strings (D-369 — closes [C124-B10] latent type error).

  ## Elaboration (D-369 / D-370 / D-371)

  The default elaborator (`elaborate_issue/1`) is pure and network-free on the
  admission path. It harvests scope signals from machine-readable issue fields:

  - `files`      — `lib/`, `test/`, `web/`, `docs/` path patterns cited anywhere
                   in the issue title or body (without a `:NN` line reference).
  - `codepoints` — `file:line` patterns where a file path is followed by `:NN`.
                   Only explicit `file:line` citations produce codepoints; a file
                   cited without a line produces a whole-`files` entry instead
                   (over-declaration, [C127-B10] / [C128-B10]).
  - `specs`      — `SPEC-<NAME>.md` citations → `:spec_<NAME>` atoms.
  - `resources`  — reserved; label-derived resources (empty in this PR).
  - `deps`       — `blocked-by: #NN` / `blocked by #NN` → `"unit-NN"`.

  When no `files` AND no `specs` are extracted, a **universal-conflict sentinel**
  is returned (D-371): it clears an empty in-flight set but conflicts against any
  non-empty member, enforcing serialization of unscopable units.

  This module is a plain functional module — no GenServer. Pure given injected
  seams (OTP non-negotiable §3: no GenServer wrapping stateless logic).
  """

  alias Tau.Factory.ConflictCheck
  alias Tau.Factory.Ledger.Reader, as: LedgerReader

  @terminal_states [:merged, :escalated]

  # Regex for file paths: lib/, test/, web/, docs/ prefix, then the path component
  # (letters, digits, underscores, hyphens, dots, slashes).
  # capture: :all_but_first extracts the inner group (the path itself).
  @file_path_re ~r/((?:lib|test|web|docs)\/[\w.\/\-]+\.\w+)/

  # Regex for file:line citations (file path followed by colon + digits).
  # Groups: [full_match, path, prefix, line_str] — use :all_but_first.
  @file_line_re ~r/((?:lib|test|web|docs)\/[\w.\/\-]+\.\w+):(\d+)/

  # Regex for SPEC-NAME.md citations — captures the NAME part.
  @spec_re ~r/SPEC-([\w\-]+)\.md/

  # Regex for "blocked-by: #N" or "blocked by #N" (case-insensitive).
  @blocked_by_re ~r/blocked[- ]by[:\s]+#(\d+)/i

  @typedoc """
  The 4-tuple returned by `select/1` when an admittable issue exists.

  - `issue`  — the raw `issue_map` carrying at minimum `"number"` and `"title"`.
  - `scope`  — a `ConflictCheck.scope()` map (D-369 — never a String).
  - `hash`   — content hash string (non-empty).
  - `branch` — feature branch name string (non-empty).
  """
  @type work_item ::
          {issue_map :: map(), scope :: ConflictCheck.scope(), hash :: String.t(),
           branch :: String.t()}

  @doc """
  Select the next admittable work item from the assigned milestone.

  ## Options

    - `:ledger`        — `GenServer.server()`; a running `Ledger.Writer`.
    - `:milestone`     — `String.t()`; the milestone title to query.
    - `:gh_fun`        — optional; `(String.t() -> {:ok, [map()]})`. Defaults to
                         the real `gh issue list` shell adapter.
    - `:elaborate_fun` — optional; `(map() -> ConflictCheck.scope())`. Defaults
                         to the pure heuristic elaborator (D-370).
    - `:fetch_fun`     — optional; `(-> {:ok, String.t()})`. Performs a
                         `git fetch origin` and resolves the current `origin/main`
                         HEAD SHA. The resolved SHA is used as the `base_ref`
                         (branch field) in the returned work_item, establishing a
                         system-established ref derived from fresh `origin/main`
                         (INV-WF-9 / [C214-B2], SPEC-FACTORY-FLEET §4 B2).
                         Defaults to the real `git fetch` + SHA-resolution adapter.
                         Tests MUST inject a stub via `:fetch_fun`.

  Returns a `work_item` 4-tuple or `nil`.
  """
  @spec select(keyword()) :: work_item() | nil
  def select(opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    milestone = Keyword.fetch!(opts, :milestone)
    gh_fun = Keyword.get(opts, :gh_fun, &default_gh_fun/1)
    elaborate_fun = Keyword.get(opts, :elaborate_fun, &elaborate_issue/1)
    fetch_fun = Keyword.get(opts, :fetch_fun, &default_fetch_fun/0)

    {:ok, origin_main_sha} = fetch_fun.()
    {:ok, issues} = gh_fun.(milestone)

    snapshots = LedgerReader.latest_unit_snapshots(ledger)

    issues
    |> Enum.reject(&terminal_in_ledger?(&1, snapshots))
    |> pick_work_item(elaborate_fun, origin_main_sha)
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
  # Elaborates the declared scope and derives a deterministic hash and branch name.
  # INV-WF-9: the branch (base_ref) is rooted in the system-established
  # origin/main SHA resolved by the fetch_fun, not derived from the issue number.
  defp pick_work_item([], _elaborate_fun, _origin_main_sha), do: nil

  defp pick_work_item([issue | _rest], elaborate_fun, origin_main_sha) do
    number = Map.fetch!(issue, "number")
    title = Map.get(issue, "title", "")

    scope = elaborate_fun.(issue)
    hash = content_hash(number, title)
    branch = origin_main_sha

    {issue, scope, hash, branch}
  end

  # ---------------------------------------------------------------------------
  # Default elaborator — D-369 / D-370 / D-371
  # ---------------------------------------------------------------------------

  @doc false
  @spec elaborate_issue(map()) :: ConflictCheck.scope()
  def elaborate_issue(issue_map) do
    title = Map.get(issue_map, "title", "")
    body = Map.get(issue_map, "body", "") || ""
    text = title <> "\n" <> body

    # Extract file:line codepoints first (these are NARROWER citations).
    # A file:line citation goes into :codepoints ONLY, not into :files.
    file_line_pairs = extract_file_line_pairs(text)
    codepointed_files = MapSet.new(file_line_pairs, fn {path, _line} -> path end)

    # Extract whole-file citations: files cited WITHOUT an explicit :line.
    # Over-declaration: if any match lacks a line, put it in :files, never in
    # :codepoints. A file cited WITH a line does NOT produce a :files entry.
    all_files = extract_files(text)
    whole_files = MapSet.difference(all_files, codepointed_files)

    # SPEC citations → :specs atoms
    specs = extract_specs(text)

    # blocked-by deps → "unit-NN" strings
    deps = extract_deps(text)

    # Codepoints as {path, :line_NN} tuples
    codepoints = MapSet.new(file_line_pairs, fn {path, line} -> {path, :"line_#{line}"} end)

    # D-371: no files AND no specs → universal-conflict sentinel
    if MapSet.size(whole_files) == 0 and MapSet.size(specs) == 0 and
         MapSet.size(codepoints) == 0 do
      sentinel_scope()
    else
      %{
        deps: deps,
        files: whole_files,
        codepoints: codepoints,
        specs: specs,
        resources: MapSet.new()
      }
    end
  end

  # Extract all file paths (any of the recognized prefixes) from text.
  # Returns a MapSet of path strings.
  # Uses :all_but_first to get only the captured group (the path), not the full match.
  defp extract_files(text) do
    @file_path_re
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(&List.first/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # Extract file:line pairs from text.
  # Returns a list of {path_string, line_integer} tuples.
  # Groups: [path, line_str] (all_but_first drops the full match).
  defp extract_file_line_pairs(text) do
    @file_line_re
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.flat_map(fn
      [path, line_str] ->
        case Integer.parse(line_str) do
          {line, ""} -> [{path, line}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  # Extract SPEC citations → MapSet of atoms like :spec_FACTORY_CORE
  defp extract_specs(text) do
    @spec_re
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [name] ->
      name
      |> String.replace("-", "_")
      |> String.upcase()
      |> then(&:"spec_#{&1}")
    end)
    |> MapSet.new()
  end

  # Extract "blocked-by: #N" deps → list of "unit-N" strings
  defp extract_deps(text) do
    @blocked_by_re
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [num_str] -> "unit-#{num_str}" end)
  end

  # D-371 sentinel: universal-conflict scope.
  # Clears against empty in-flight (ConflictCheck treats it as :clear);
  # conflicts against any non-empty in-flight (ConflictCheck.clear?/2 checks
  # the :universal_conflict flag before any set comparison).
  defp sentinel_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new(),
      universal_conflict: true
    }
  end

  # Deterministic content hash for the work item — SHA-256 of "number:title".
  defp content_hash(number, title) do
    :crypto.hash(:sha256, "#{number}:#{title}")
    |> Base.encode16(case: :lower)
  end

  # Default real fetch adapter: runs `git fetch origin` then resolves
  # the current `origin/main` HEAD SHA (INV-WF-9).
  # Tests MUST inject a stub via `:fetch_fun` — this path is NOT exercised in tests.
  defp default_fetch_fun do
    with {_, 0} <- System.cmd("git", ["fetch", "origin"], stderr_to_stdout: true),
         {sha, 0} <- System.cmd("git", ["rev-parse", "origin/main"], stderr_to_stdout: true) do
      {:ok, String.trim(sha)}
    else
      {output, code} -> {:error, {:git_exit, code, output}}
    end
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
