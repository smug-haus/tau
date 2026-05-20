defmodule Tau.BurritoSteps.RelinkSqliteNifTest do
  @moduledoc """
  Sanity-checks for the `Tau.BurritoSteps.RelinkSqliteNif` Burrito step.

  The real proof of correctness for this module is an empirical Burrito build
  + smoke run against the packaged binary (issue #261). These tests catch
  cheap regressions: module-load, behaviour shape, and non-Linux passthrough.
  """

  use ExUnit.Case, async: true

  alias Tau.BurritoSteps.RelinkSqliteNif

  describe "module shape" do
    test "implements the Burrito.Builder.Step behaviour" do
      behaviours = RelinkSqliteNif.module_info(:attributes) |> Keyword.get_values(:behaviour)
      assert Burrito.Builder.Step in List.flatten(behaviours)
    end

    test "exports execute/1" do
      assert function_exported?(RelinkSqliteNif, :execute, 1)
    end
  end

  describe "execute/1" do
    test "returns the context unchanged for non-Linux targets" do
      target = %Burrito.Builder.Target{
        alias: :darwin_arm64,
        os: :darwin,
        cpu: :aarch64,
        cross_build: false,
        qualifiers: [],
        erts_source: {:runtime, []},
        debug?: false
      }

      context = %Burrito.Builder.Context{
        target: target,
        mix_release: %Mix.Release{
          name: :tau,
          version: "0.0.0",
          path: System.tmp_dir!(),
          version_path: System.tmp_dir!(),
          applications: [],
          boot_scripts: %{},
          erts_source: nil,
          erts_version: ~c"15.0",
          config_providers: [],
          options: [],
          overlays: [],
          steps: []
        },
        work_dir: System.tmp_dir!(),
        self_dir: System.tmp_dir!(),
        extra_build_env: [],
        halted: false
      }

      assert RelinkSqliteNif.execute(context) == context
    end
  end
end
