if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.ModelPropertyTest do
    @moduledoc """
    Properties for `Tau.TUI.App.Model`. Pins the struct field invariants
    and `new/3` constructor semantics.
    """
    use ExUnit.Case, async: true
    use ExUnitProperties

    @moduletag :property

    alias Tau.TUI.App.Model

    defp window_width_gen do
      StreamData.integer(4..400)
    end

    defp runtime_opts_gen do
      StreamData.bind(
        StreamData.member_of([:default, :accept_edits, :plan]),
        fn mode ->
          StreamData.constant(%{permissions_mode: mode})
        end
      )
    end

    property "new/3 wrap_width is always >= 1 for any valid terminal width" do
      check all(
              width <- window_width_gen(),
              opts <- runtime_opts_gen()
            ) do
        session_id = "sess-prop-#{width}"
        context = %{window: %{width: width}}
        model = Model.new(context, session_id, opts)
        assert model.wrap_width >= 1
      end
    end

    property "new/3 permissions_mode matches runtime_opts when present" do
      check all(mode <- StreamData.member_of([:default, :accept_edits, :plan])) do
        opts = %{permissions_mode: mode}
        model = Model.new(%{}, "sess-pm", opts)
        assert model.permissions_mode == mode
      end
    end

    property "new/3 always produces valid initial status and compaction" do
      check all(opts <- runtime_opts_gen()) do
        model = Model.new(%{}, "sess-status", opts)
        assert model.status == :idle
        assert model.compaction == :idle
        assert model.warn_level == :ok
        assert model.context_tokens == 0
        assert model.transcript == []
        assert model.subagents == %{}
        assert model.pending_permissions == []
      end
    end
  end
end
