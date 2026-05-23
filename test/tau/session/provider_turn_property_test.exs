defmodule Tau.Session.ProviderTurnPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduledoc false

  @moduletag :property

  alias Tau.Session.ProviderTurn

  defp provider_generator do
    member_of([Tau.Providers.Anthropic, Tau.Providers.Replay])
  end

  property "describe_provider_error returns a binary for any reason" do
    check all(reason <- one_of([atom(:alphanumeric), string(:printable), integer()])) do
      result = ProviderTurn.describe_provider_error(reason)
      assert is_binary(result)
    end
  end

  property "describe_provider_error returns non-empty string for known atoms" do
    known = [
      :missing_api_key,
      :oauth_expired,
      :oauth_missing_scope,
      :oauth_malformed,
      :circuit_open
    ]

    check all(atom <- member_of(known)) do
      result = ProviderTurn.describe_provider_error(atom)
      assert is_binary(result) and result != ""
    end
  end

  property "lookup_fallback_chain returns a list for any atom" do
    check all(provider <- provider_generator()) do
      chain = ProviderTurn.lookup_fallback_chain(provider)
      assert is_list(chain)
    end
  end

  property "maybe_replace returns data unchanged when value is nil" do
    check all(key <- atom(:alphanumeric)) do
      data = %{some: :value}
      assert ProviderTurn.maybe_replace(data, key, nil) == data
    end
  end

  property "maybe_replace sets the key when value is non-nil" do
    check all(
            key <- atom(:alphanumeric),
            value <- integer()
          ) do
      data = %{}
      result = ProviderTurn.maybe_replace(data, key, value)
      assert Map.get(result, key) == value
    end
  end
end
