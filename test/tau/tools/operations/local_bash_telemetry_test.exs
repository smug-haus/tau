defmodule Tau.Tools.Operations.LocalBashTelemetryTest do
  @moduledoc """
  Verifies that `Tau.Tools.Operations.Local.bash/2` captures stderr
  separately from stdout and emits `[:tau, :tool, :bash, :stderr]`
  telemetry whenever stderr is non-empty. Issue #11.

  Pre-fix the bash/2 helper used `:stderr_to_stdout`, returned
  `stderr: ""` always, and never emitted the telemetry event — so
  observability of bash failures by stderr alone was impossible.
  """
  use ExUnit.Case, async: false

  alias Tau.Tools.Operations.Local

  setup do
    handler_id = "bash-stderr-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:tau, :tool, :bash, :stderr],
      fn _e, m, meta, _ -> send(parent, {:bash_stderr, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "captures stderr separately and fires telemetry with the stderr blob" do
    {:ok, %{stdout: out, stderr: err, exit_status: status}} =
      Local.bash(~s|echo to-stdout && echo to-stderr 1>&2|)

    assert status == 0
    assert out =~ "to-stdout"
    refute out =~ "to-stderr"
    assert err =~ "to-stderr"

    assert_receive {:bash_stderr, %{bytes: bytes}, %{stderr: stderr_body}}, 500
    assert bytes == byte_size(stderr_body)
    assert stderr_body =~ "to-stderr"
  end

  test "does not fire telemetry when stderr is empty" do
    {:ok, %{stdout: out, stderr: err, exit_status: 0}} = Local.bash("echo only-stdout")

    assert out =~ "only-stdout"
    assert err == ""

    refute_receive {:bash_stderr, _, _}, 200
  end

  test "captures stderr from a command that exits non-zero" do
    {:ok, %{stdout: out, stderr: err, exit_status: status}} =
      Local.bash(~s|echo before-fail && echo failure-msg 1>&2 && exit 7|)

    assert status == 7
    assert out =~ "before-fail"
    assert err =~ "failure-msg"

    assert_receive {:bash_stderr, _, %{stderr: stderr_body}}, 500
    assert stderr_body =~ "failure-msg"
  end
end
