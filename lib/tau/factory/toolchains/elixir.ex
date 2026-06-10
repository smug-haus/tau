defmodule Tau.Factory.Toolchain.Elixir do
  @moduledoc """
  Bootstrap / self-host Toolchain adapter for Elixir projects.

  Implements `Tau.Factory.Toolchain` for `:elixir` language projects
  (SPEC-FACTORY-GATE §4 §4.1). Every callback is a pure function that returns
  declarative data describing the mix recipe. No subprocess is launched, no
  filesystem is touched, no verdict is returned (HR-3).

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
      argv: ~w(mix test --formatter JUnitFormatter),
      env: %{"MIX_ENV" => "test"},
      report: :junit,
      artifact: "_build/test/lib/tau/test-junit-report.xml"
    }
  end

  @impl Tau.Factory.Toolchain
  def mutation_descriptor(ctx) do
    %{test_descriptor(ctx) | argv: ~w(mix test --only gating --formatter JUnitFormatter)}
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
end
