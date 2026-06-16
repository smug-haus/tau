defmodule Tau.Factory.InvWf1RebarCacheIsolationTest do
  @moduledoc """
  Gating test for issue #611 — INV-WF-1.

  INV-WF-1 statement: Every mutable $HOME-namespace resource a worker's
  build/test/agent may touch MUST be declared in the Toolchain adapter's
  resource-namespace declaration such that the worker's namespace map
  (produced by `resolve_namespace/2`) contains the **correct** environment
  variable name the tool actually reads — not an arbitrary label that the
  tool ignores.

  The specific gap (rationale from audit finding):

    `Tau.Factory.Toolchain.Elixir.declare_resource_namespace/1` declares
    `%ResourceNS{kind: :dir, var: "REBAR3_CACHE", path: "~/.cache/rebar3"}`.

    Rebar3 does NOT read `REBAR3_CACHE` to locate its cache; the correct
    environment variable is `REBAR_CACHE_HOME`.  Setting `REBAR3_CACHE` in
    the worker's subprocess environment has no effect on rebar3's behaviour,
    so concurrent workers continue to write to the shared `~/.cache/rebar3`
    on disk — the HOME-namespace cache race the invariant exists to prevent.

  This test exercises the full user-facing path:

    1. `Tau.Factory.Toolchain.for(:elixir)` — atom dispatch to adapter.
    2. `adapter.declare_resource_namespace(%{})` — declaration extraction.
    3. `Tau.Factory.Worker.Isolation.resolve_namespace(ws, decls)` — namespace
       map computation.

  It asserts that the resulting namespace map contains `"REBAR_CACHE_HOME"`
  as a key (the env var rebar3 actually reads), NOT the currently-declared
  `"REBAR3_CACHE"` (which rebar3 ignores).

  The test FAILS against current production code: the adapter declares
  `REBAR3_CACHE`, so `resolve_namespace/2` produces a map with
  `"REBAR3_CACHE"` and no `"REBAR_CACHE_HOME"` key.  The fix requires
  the adapter to declare `var: "REBAR_CACHE_HOME"` so that the resolved
  namespace map includes the key rebar3 reads.
  """

  use ExUnit.Case, async: true

  @tag :inv_wf_1
  test "INV-WF-1: Elixir adapter's resolved namespace map contains REBAR_CACHE_HOME (the env var rebar3 actually reads)" do
    # Step 1 — atom dispatch to the Elixir adapter (the real entry point).
    adapter = Tau.Factory.Toolchain.for(:elixir)

    # Guard: dispatch must succeed.
    refute match?({:error, _}, adapter),
           "Tau.Factory.Toolchain.for(:elixir) must return the adapter module, got: #{inspect(adapter)}"

    # Step 2 — extract the resource namespace declarations.
    decls = adapter.declare_resource_namespace(%{})

    assert is_list(decls) and length(decls) > 0,
           "declare_resource_namespace/1 must return a non-empty list; got: #{inspect(decls)}"

    # Step 3 — resolve the namespace map through the real isolation helper.
    worktree = "/tmp/inv_wf_1_test_worker"
    ns_map = Tau.Factory.Worker.Isolation.resolve_namespace(worktree, decls)

    # The resolved map MUST contain "REBAR_CACHE_HOME" — the env var rebar3
    # actually reads (https://www.rebar3.org/docs/configuration/global-configuration/).
    # If the adapter incorrectly declares "REBAR3_CACHE" instead, rebar3
    # ignores the override and the shared ~/.cache/rebar3 race persists (INV-WF-1).
    assert Map.has_key?(ns_map, "REBAR_CACHE_HOME"),
           """
           INV-WF-1 VIOLATED: resolved namespace map does not contain "REBAR_CACHE_HOME".
           Rebar3 reads REBAR_CACHE_HOME to locate its cache directory; it does NOT read
           REBAR3_CACHE.  A worker that sets only REBAR3_CACHE cannot prevent the shared
           ~/.cache/rebar3 race under concurrency.

           Current ns_map keys: #{inspect(Map.keys(ns_map))}
           Current declarations: #{inspect(Enum.map(decls, & &1.var))}

           Fix: change the Elixir adapter's rebar3 ResourceNS declaration from
             %ResourceNS{kind: :dir, var: "REBAR3_CACHE", path: "~/.cache/rebar3"}
           to
             %ResourceNS{kind: :dir, var: "REBAR_CACHE_HOME", path: "~/.cache/rebar3"}
           """

    # The per-worker path for the rebar3 cache must be inside the worktree.
    rebar_dir = Map.fetch!(ns_map, "REBAR_CACHE_HOME")

    assert String.starts_with?(rebar_dir, worktree),
           """
           INV-WF-1 VIOLATED: REBAR_CACHE_HOME resolved to a path outside the worker worktree.
           Expected a path under #{inspect(worktree)}, got: #{inspect(rebar_dir)}
           """
  end
end
