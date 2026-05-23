defmodule Tau.Session.ModelSwapPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Tau.Session.ModelSwap

  defp make_data(model \\ "claude-3-opus") do
    %{
      id: "test-session",
      model: model,
      provider: Tau.Providers.Replay,
      persist_handle: nil,
      persistence: nil
    }
  end

  property "swap_model accepts any non-blank binary" do
    check all(model <- string(:printable, min_length: 1)) do
      trimmed = String.trim(model)

      if trimmed != "" do
        data = make_data()
        assert {:ok, updated, _old} = ModelSwap.swap_model(data, model)
        assert updated.model == model
      else
        data = make_data()
        assert {:error, :invalid_model} = ModelSwap.swap_model(data, model)
      end
    end
  end

  property "swap_model rejects nil" do
    check all(_ <- constant(nil)) do
      assert {:error, :invalid_model} = ModelSwap.swap_model(make_data(), nil)
    end
  end

  property "swap_model rejects empty string" do
    check all(_ <- constant(nil)) do
      assert {:error, :invalid_model} = ModelSwap.swap_model(make_data(), "")
    end
  end

  property "swap_model rejects whitespace-only strings" do
    whitespace = [" ", "\t", "\n"]

    check all(ws_parts <- list_of(member_of(whitespace), min_length: 1)) do
      spaces = Enum.join(ws_parts)
      assert {:error, :invalid_model} = ModelSwap.swap_model(make_data(), spaces)
    end
  end

  property "swap_model is idempotent — swapping to current model succeeds" do
    check all(model <- string(:alphanumeric, min_length: 1)) do
      data = make_data(model)
      assert {:ok, updated, ^model} = ModelSwap.swap_model(data, model)
      assert updated.model == model
    end
  end

  property "maybe_replace returns data unchanged when value is nil" do
    check all(key <- atom(:alphanumeric)) do
      data = %{a: 1, b: 2}
      assert ModelSwap.maybe_replace(data, key, nil) == data
    end
  end

  property "maybe_replace sets key when value is non-nil" do
    check all(
            key <- atom(:alphanumeric),
            value <- integer()
          ) do
      data = %{}
      result = ModelSwap.maybe_replace(data, key, value)
      assert Map.get(result, key) == value
    end
  end
end
