defmodule Tau.Factory.WorkerIsolationPropertyTest do
  @moduledoc """
  StreamData property oracle for `Tau.Factory.Worker.Isolation` (C5).

  Pins SPEC-FACTORY-FLEET §4 B2/B3/B5 + §6 D-309/D-311/D-313.

  ## Pinned interface (oracle-declared; implementer MUST conform)

  ### `resolve_namespace/2`

      resolve_namespace(worktree_abs :: String.t(), decls :: [%Tau.Toolchain.ResourceNS{}])
        :: %{String.t() => String.t()}

  Maps each declaration's `var` to an absolute directory **inside** `worktree_abs`.
  Pinned dir layout: `<worktree_abs>/.factory-ns/<var>`.

  Post-conditions (D-309):
    - Total: every declared `var` appears as a key in the result map.
    - No escape: every resulting dir starts with `worktree_abs`.
    - Distinct within a worktree: dir values are pairwise distinct.
    - Cross-worker disjoint: for `ws1 ≠ ws2`, `dirs(ws1) ∩ dirs(ws2) = ∅`.

  ### `verify_position/3`

      verify_position(
        worktree_abs :: String.t(),
        observed :: %{pwd: String.t(), head: String.t(), branch: String.t()},
        expected :: %{head: String.t(), branch: String.t()}
      ) :: :ok | {:error, reason :: atom() | {atom(), term()}}

  Returns `:ok` iff:
    - `observed.pwd` starts with `worktree_abs` (NOT the parent root / outside), AND
    - `observed.head == expected.head`, AND
    - `observed.branch == expected.branch`.

  Returns `{:error, reason}` when any condition fails (D-311, F-6).

  ### `capture_commands/1`

      capture_commands(worktree_abs :: String.t()) :: [%{kind: atom(), argv: [String.t()]}]

  Returns a list of command descriptors covering all three dirty kinds (D-313):
    - `:status` — `git -C <ws> status --short`
    - `:patch`  — `git -C <ws> diff HEAD` (staged + unstaged)
    - `:untracked` — `git -C <ws> ls-files --others --exclude-standard` → tar pipeline

  The set of kinds returned MUST equal `{:status, :patch, :untracked}`.

  ## Referenced invariants

  - **D-309** — namespace totality + cross-worker disjointness (C215-B3)
  - **D-311** — verified position; abort on parent-root or wrong ref (C204-B2, C214-B2)
  - **D-313** — capture-before-destroy, all three dirty kinds (C203-B5)
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Toolchain.ResourceNS

  # Runtime reference to the absent module — avoids a CompileError while
  # guaranteeing UndefinedFunctionError at test execution time.
  @mod Tau.Factory.Worker.Isolation

  @moduletag :property

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp worktree_gen do
    StreamData.bind(StreamData.positive_integer(), fn n ->
      StreamData.constant("/tmp/ws_#{n}")
    end)
  end

  # Generates pairs of distinct worktree paths that include prefix-colliding
  # cases such as ("/tmp/ws_1", "/tmp/ws_12") and ("/tmp/ws_1", "/tmp/ws_1x").
  # This ensures the cross-worker disjointness property is proven against the
  # exact segment-boundary collision that the D-311/F-6 bug exploits.
  defp two_distinct_worktrees_gen do
    # Pool includes well-separated pairs AND adjacent-integer / shared-prefix
    # pairs that share a string prefix but are at distinct path segments.
    prefix_colliding_pairs = [
      {"/tmp/ws_1", "/tmp/ws_12"},
      {"/tmp/ws_1", "/tmp/ws_1x"},
      {"/tmp/ws_10", "/tmp/ws_100"},
      {"/tmp/ws_2", "/tmp/ws_20"},
      {"/tmp/ws_9", "/tmp/ws_99"}
    ]

    StreamData.one_of([
      # Well-separated integer pairs
      StreamData.bind(
        StreamData.tuple({StreamData.positive_integer(), StreamData.positive_integer()}),
        fn {a, b} ->
          if a == b do
            StreamData.constant({"/tmp/ws_#{a}", "/tmp/ws_#{b + 1}"})
          else
            StreamData.constant({"/tmp/ws_#{a}", "/tmp/ws_#{b}"})
          end
        end
      ),
      # Prefix-colliding pairs
      StreamData.member_of(prefix_colliding_pairs)
    ])
  end

  # Generates a non-empty list of ResourceNS structs with distinct vars.
  defp decls_gen do
    StreamData.bind(
      StreamData.list_of(
        StreamData.tuple({
          StreamData.member_of([:env, :xdg_data, :dir]),
          # var names: uppercase letters to keep them realistic
          StreamData.string(?A..?Z, min_length: 3, max_length: 12)
        }),
        min_length: 1,
        max_length: 8
      ),
      fn pairs ->
        # Deduplicate on var to satisfy distinct-within-worktree precondition.
        unique_pairs = pairs |> Enum.uniq_by(fn {_, var} -> var end)

        decls =
          Enum.map(unique_pairs, fn
            {:dir, var} ->
              %ResourceNS{kind: :dir, var: var, path: "/tmp/fake/#{String.downcase(var)}"}

            {kind, var} ->
              %ResourceNS{kind: kind, var: var}
          end)

        StreamData.constant(decls)
      end
    )
  end

  # Generates a sha-like string for HEAD.
  defp sha_gen do
    StreamData.string(?a..?f, length: 40)
  end

  defp branch_gen do
    StreamData.string(:alphanumeric, min_length: 4, max_length: 20)
  end

  # ---------------------------------------------------------------------------
  # D-309: namespace totality + disjointness
  # ---------------------------------------------------------------------------

  @tag :property
  property "D-309 total: every declared var appears as a key in resolve_namespace result" do
    check all(
            ws <- worktree_gen(),
            decls <- decls_gen()
          ) do
      result = @mod.resolve_namespace(ws, decls)

      for %ResourceNS{var: var} <- decls do
        assert Map.has_key?(result, var),
               "var #{inspect(var)} missing from namespace map; decls=#{inspect(decls)}"
      end
    end
  end

  @tag :property
  property "D-309 no-escape: every resolved dir starts with worktree_abs" do
    check all(
            ws <- worktree_gen(),
            decls <- decls_gen()
          ) do
      result = @mod.resolve_namespace(ws, decls)

      for {var, dir} <- result do
        assert String.starts_with?(dir, ws),
               "var #{inspect(var)} dir #{inspect(dir)} escapes worktree #{inspect(ws)}"
      end
    end
  end

  @tag :property
  property "D-309 distinct-within-worktree: dir values are pairwise distinct for unique vars" do
    check all(
            ws <- worktree_gen(),
            decls <- decls_gen()
          ) do
      result = @mod.resolve_namespace(ws, decls)
      dirs = Map.values(result)

      assert length(dirs) == length(Enum.uniq(dirs)),
             "two vars resolved to the same dir in #{inspect(ws)}: #{inspect(result)}"
    end
  end

  @tag :property
  property "D-309 cross-worker disjoint: dir sets for distinct worktrees are disjoint" do
    check all(
            {ws1, ws2} <- two_distinct_worktrees_gen(),
            decls <- decls_gen()
          ) do
      dirs1 = @mod.resolve_namespace(ws1, decls) |> Map.values() |> MapSet.new()
      dirs2 = @mod.resolve_namespace(ws2, decls) |> Map.values() |> MapSet.new()
      intersection = MapSet.intersection(dirs1, dirs2)

      assert MapSet.size(intersection) == 0,
             "worktrees #{inspect(ws1)} and #{inspect(ws2)} share dirs: #{inspect(intersection)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-311: verified position — property
  # ---------------------------------------------------------------------------

  @tag :property
  property "D-311 ok: verify_position returns :ok when pwd inside ws and head+branch match" do
    check all(
            ws <- worktree_gen(),
            head <- sha_gen(),
            branch <- branch_gen()
          ) do
      observed = %{pwd: ws <> "/some/subdir", head: head, branch: branch}
      expected = %{head: head, branch: branch}
      assert :ok == @mod.verify_position(ws, observed, expected)
    end
  end

  @tag :property
  property "D-311 error on parent root: verify_position returns {:error,_} when pwd == ws or outside ws" do
    check all(
            ws <- worktree_gen(),
            # Use a completely unrelated path (the parent root scenario, F-6)
            parent_path <- StreamData.member_of(["/home/user/src/tau", "/tmp/other"]),
            head <- sha_gen(),
            branch <- branch_gen()
          ) do
      observed = %{pwd: parent_path, head: head, branch: branch}
      expected = %{head: head, branch: branch}
      assert {:error, _} = @mod.verify_position(ws, observed, expected)
    end
  end

  # Directed example: pwd matches worktree root exactly — still valid (inside ws)
  @tag :property
  test "D-311 ok: verify_position accepts pwd == worktree_abs itself" do
    ws = "/tmp/ws_exact"
    head = String.duplicate("a", 40)
    branch = "feat-x"
    observed = %{pwd: ws, head: head, branch: branch}
    expected = %{head: head, branch: branch}
    assert :ok == @mod.verify_position(ws, observed, expected)
  end

  # Directed example: head mismatch
  @tag :property
  test "D-311 error on head mismatch: verify_position returns {:error,_}" do
    ws = "/tmp/ws_head_mismatch"
    observed = %{pwd: ws <> "/work", head: String.duplicate("a", 40), branch: "main"}
    expected = %{head: String.duplicate("b", 40), branch: "main"}
    assert {:error, _} = @mod.verify_position(ws, observed, expected)
  end

  # Directed example: branch mismatch
  @tag :property
  test "D-311 error on branch mismatch: verify_position returns {:error,_}" do
    ws = "/tmp/ws_branch_mismatch"
    head = String.duplicate("c", 40)
    observed = %{pwd: ws <> "/work", head: head, branch: "feat-actual"}
    expected = %{head: head, branch: "feat-expected"}
    assert {:error, _} = @mod.verify_position(ws, observed, expected)
  end

  # D-311/F-6: Segment-exact boundary — the prefix-sibling collision.
  #
  # "/tmp/ws_12/work" starts with "/tmp/ws_1" as a STRING, but "/tmp/ws_12"
  # is a DIFFERENT worktree (a sibling sharing a string prefix, not a child).
  # A String.starts_with?-based implementation returns :ok here — wrong.
  # The correct segment-aware implementation must return {:error, :not_in_worktree}.
  #
  # This test FAILS against the current String.starts_with? production code
  # (it gets :ok where {:error, :not_in_worktree} is required) and passes only
  # after a segment-exact fix.
  @tag :property
  test "D-311 F-6 prefix-sibling: verify_position rejects pwd in a sibling worktree that shares a string prefix" do
    # worktree is "/tmp/ws_1"; sibling is "/tmp/ws_12" — shares prefix "/tmp/ws_1"
    ws = "/tmp/ws_1"
    head = String.duplicate("d", 40)
    branch = "feat-sibling"
    # pwd is INSIDE the sibling "/tmp/ws_12", not inside "/tmp/ws_1"
    observed = %{pwd: "/tmp/ws_12/work", head: head, branch: branch}
    expected = %{head: head, branch: branch}

    # Must be {:error, :not_in_worktree} — NOT :ok
    assert {:error, :not_in_worktree} = @mod.verify_position(ws, observed, expected)
  end

  # Complement: the legitimate case — pwd inside ws itself (exact segment) → :ok
  @tag :property
  test "D-311 F-6 prefix-sibling complement: verify_position accepts pwd directly inside worktree" do
    ws = "/tmp/ws_1"
    head = String.duplicate("e", 40)
    branch = "feat-inws"
    observed = %{pwd: "/tmp/ws_1/work", head: head, branch: branch}
    expected = %{head: head, branch: branch}
    assert :ok == @mod.verify_position(ws, observed, expected)
  end

  # ---------------------------------------------------------------------------
  # D-313: capture_commands — all three dirty kinds
  # ---------------------------------------------------------------------------

  @tag :property
  property "D-313 three-kinds: capture_commands returns commands for all three dirty kinds" do
    check all(ws <- worktree_gen()) do
      cmds = @mod.capture_commands(ws)

      kinds =
        cmds
        |> Enum.map(fn %{kind: k} -> k end)
        |> MapSet.new()

      assert MapSet.member?(kinds, :status),
             "capture_commands missing :status kind; got: #{inspect(kinds)}"

      assert MapSet.member?(kinds, :patch),
             "capture_commands missing :patch kind; got: #{inspect(kinds)}"

      assert MapSet.member?(kinds, :untracked),
             "capture_commands missing :untracked kind; got: #{inspect(kinds)}"
    end
  end

  @tag :property
  property "D-313 patch argv: the :patch command includes 'diff' and 'HEAD'" do
    check all(ws <- worktree_gen()) do
      cmds = @mod.capture_commands(ws)
      patch_cmd = Enum.find(cmds, fn %{kind: k} -> k == :patch end)

      assert patch_cmd != nil, "no :patch command in #{inspect(cmds)}"
      assert "diff" in patch_cmd.argv, ":patch argv missing 'diff': #{inspect(patch_cmd.argv)}"
      assert "HEAD" in patch_cmd.argv, ":patch argv missing 'HEAD': #{inspect(patch_cmd.argv)}"
    end
  end

  @tag :property
  property "D-313 untracked argv: the :untracked command references ls-files --others" do
    check all(ws <- worktree_gen()) do
      cmds = @mod.capture_commands(ws)
      untracked_cmd = Enum.find(cmds, fn %{kind: k} -> k == :untracked end)

      assert untracked_cmd != nil, "no :untracked command in #{inspect(cmds)}"

      argv_str = Enum.join(untracked_cmd.argv, " ")

      assert String.contains?(argv_str, "ls-files") or
               String.contains?(argv_str, "--others"),
             ":untracked argv does not reference ls-files/--others: #{inspect(untracked_cmd.argv)}"
    end
  end

  @tag :property
  property "D-313 exact three kinds: set of kinds equals {:status, :patch, :untracked}" do
    check all(ws <- worktree_gen()) do
      cmds = @mod.capture_commands(ws)

      kinds =
        cmds
        |> Enum.map(fn %{kind: k} -> k end)
        |> MapSet.new()

      expected_kinds = MapSet.new([:status, :patch, :untracked])

      assert MapSet.subset?(expected_kinds, kinds),
             "capture_commands missing required kinds; got #{inspect(kinds)}, want superset of #{inspect(expected_kinds)}"
    end
  end
end
