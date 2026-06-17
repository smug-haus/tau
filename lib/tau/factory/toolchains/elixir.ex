defmodule Tau.Factory.Toolchain.Elixir do
  @moduledoc """
  Bootstrap / self-host Toolchain adapter for Elixir projects.

  Implements `Tau.Factory.Toolchain` for `:elixir` language projects
  (SPEC-FACTORY-GATE §4 §4.1). Every callback is a pure function that returns
  declarative data describing the mix recipe. No subprocess is launched, no
  filesystem is touched, no verdict is returned (HR-3).

  ## mutation_descriptor/1 and the engine-generated runner script

  The gate engine generates an ExUnit runner script (with an inline JUnit
  formatter) into the workspace before calling `mutation_descriptor/1`. It
  passes the script and artifact paths via `ctx` (`:script_rel` and
  `:artifact_rel` keys). `mutation_descriptor/1` uses these to return a
  `["mix", "run", script_rel]` invocation that:
    - does NOT start with `"elixir"` (D-S2 seam contract, SPEC §4 B4),
    - reports in `:junit` format (engine-owned JUnit formatter in the script),
    - works on ANY Elixir project without external deps.

  When ctx does not carry `:script_rel` / `:artifact_rel` (e.g. in unit tests
  that call the adapter directly), static defaults are returned — the descriptor
  shape is valid for seam-contract tests; at runtime the engine always provides
  the ctx keys.

  ## Resource namespaces

  The Elixir toolchain uses the following HOME-namespace caches that must be
  isolated per worker (SPEC-FACTORY-GATE §4 B9; `worktree-discipline.md`):

    * `XDG_DATA_HOME` — Burrito unpack cache (`~/.local/share/.burrito/`).
    * `MIX_HOME`      — Mix global configuration and dependencies.
    * `HEX_HOME`      — Hex package cache.
    * `~/.cache/rebar3` — Rebar3 build cache (`:dir` kind).
  """

  @behaviour Tau.Factory.Toolchain

  @impl Tau.Factory.Toolchain
  def install_deps(_ctx), do: %{argv: ~w(mix deps.get), env: %{}}

  @impl Tau.Factory.Toolchain
  def build(_ctx), do: %{argv: ~w(mix compile --warnings-as-errors), env: %{}}

  @impl Tau.Factory.Toolchain
  def package(_ctx) do
    %{
      argv: ~w(mix release tau --overwrite),
      env: %{"MIX_ENV" => "prod"}
    }
  end

  @impl Tau.Factory.Toolchain
  def test_descriptor(_ctx) do
    %Tau.Toolchain.TestDescriptor{
      argv: ~w(mix test),
      env: %{"MIX_ENV" => "test"},
      report: :junit,
      artifact: "_build/test/lib/tau/test-junit-report.xml"
    }
  end

  @impl Tau.Factory.Toolchain
  def mutation_descriptor(ctx) do
    # Use engine-provided ctx keys when present; fall back to static defaults
    # so the descriptor is a valid %TestDescriptor{} even when ctx is empty
    # (e.g. in seam-contract unit tests that call the adapter directly).
    script_rel = Map.get(ctx, :script_rel, "_gate_runner.exs")
    artifact_rel = Map.get(ctx, :artifact_rel, "_gate_report.xml")

    %Tau.Toolchain.TestDescriptor{
      argv: ["mix", "run", script_rel],
      env: %{"MIX_ENV" => "test"},
      report: :junit,
      artifact: artifact_rel
    }
  end

  @impl Tau.Factory.Toolchain
  def lint(_ctx) do
    %Tau.Toolchain.LintDescriptor{
      steps: [
        %{argv: ~w(mix compile --warnings-as-errors), report: :exit_status},
        %{argv: ~w(mix format --check-formatted), report: :exit_status},
        %{argv: ~w(mix credo --strict), report: :exit_status},
        %{argv: ~w(mix dialyzer), report: :exit_status}
      ]
    }
  end

  @impl Tau.Factory.Toolchain
  def declare_resource_namespace(_ctx) do
    [
      %Tau.Toolchain.ResourceNS{kind: :xdg_data, var: "XDG_DATA_HOME"},
      %Tau.Toolchain.ResourceNS{kind: :env, var: "MIX_HOME"},
      %Tau.Toolchain.ResourceNS{kind: :env, var: "HEX_HOME"},
      %Tau.Toolchain.ResourceNS{kind: :dir, var: "REBAR3_CACHE", path: "~/.cache/rebar3"}
    ]
  end

  @impl Tau.Factory.Toolchain
  def project_manifest_file(_ctx), do: "mix.exs"
end
