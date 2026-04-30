defmodule Tau.Command.ContextTest do
  use ExUnit.Case, async: true

  alias Tau.Command.Context

  test "new/1 fills sensible defaults and accepts overrides" do
    ctx = Context.new(session_id: "sess_1")

    assert ctx.session_id == "sess_1"
    assert ctx.cwd == nil
    assert ctx.permissions_mode == :default
    assert ctx.metadata == %{}
    assert is_function(ctx.emit, 1)
    assert ctx.emit.(:any) == :ok
  end

  test "new/1 propagates explicit fields" do
    parent = self()

    emit = fn payload ->
      send(parent, {:emit, payload})
      :ok
    end

    ctx =
      Context.new(
        session_id: "sess_2",
        cwd: "/tmp/work",
        permissions_mode: :plan,
        emit: emit,
        metadata: %{user: "alice"}
      )

    assert ctx.cwd == "/tmp/work"
    assert ctx.permissions_mode == :plan
    assert ctx.metadata == %{user: "alice"}

    ctx.emit.({:hi, 1})
    assert_receive {:emit, {:hi, 1}}
  end

  test "new/1 raises when session_id is missing" do
    assert_raise KeyError, fn -> Context.new([]) end
  end
end
