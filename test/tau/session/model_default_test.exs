defmodule Tau.Session.ModelDefaultTest do
  @moduledoc """
  D-002 (SPEC-USER-TURN [C29]): `Tau.start_session/1` MUST resolve a
  non-nil model before reaching `:start_provider`. The resolution
  happens at session init using `provider.default_model()`. Without
  this, `data.model` stays nil through telemetry, persistence, and
  the assembler — which is the silent stall behind the user-reported
  "TUI does nothing" symptom (post AC-1 manual verification).
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-model-default-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  test "start_session with no model resolves to the provider's default" do
    {:ok, sid} = start_session_for_test(provider: Tau.Providers.Replay)

    {:ok, snap} = Tau.snapshot(sid)

    assert snap.model == Tau.Providers.Replay.default_model(),
           "Expected model resolved to provider default; got #{inspect(snap.model)}"

    refute is_nil(snap.model), "data.model MUST NOT be nil"
  end

  test "start_session with explicit model preserves the explicit value" do
    {:ok, sid} = start_session_for_test(provider: Tau.Providers.Replay, model: "custom-model")

    {:ok, snap} = Tau.snapshot(sid)

    assert snap.model == "custom-model"
  end

  test "start_session with no provider uses default provider's default model" do
    {:ok, sid} = start_session_for_test([])

    {:ok, snap} = Tau.snapshot(sid)

    assert snap.model == snap.provider.default_model(),
           "Expected default-provider's default_model; got #{inspect(snap.model)} for provider #{inspect(snap.provider)}"
  end
end
