defmodule Tau.Providers.Shared.ContentTransformTest do
  @moduledoc """
  Examples + properties for `Tau.Providers.Shared.ContentTransform`
  (ADR-0012). Pinned invariants:

    * `:thinking` blocks NEVER survive any cross-provider transform.
    * `:image` blocks survive iff the destination has `vision == true`.
    * `cache_control` keys survive iff `prompt_caching == true`.
    * The transform is idempotent on a fixed `(from, to)` pair.

  The property suite uses `StreamData` and is gated by
  `@moduletag :property` per non-negotiable #6.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Providers.Shared.ContentTransform

  defmodule VisionProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_, _, _), do: {:ok, []}

    @impl true
    def capabilities,
      do: %{thinking: true, tools: true, vision: true, prompt_caching: true, parallel_tools: true}

    @impl true
    def default_model, do: "vision"
  end

  defmodule TextOnlyProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_, _, _), do: {:ok, []}

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: true,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl true
    def default_model, do: "text-only"
  end

  describe "transform/3 — examples" do
    test "thinking blocks are stripped on cross-provider hop" do
      msg = %Assistant{
        content: [
          %{type: :thinking, text: "secret reasoning", signature: "sig-1"},
          %{type: :text, text: "visible answer"}
        ],
        timestamp: DateTime.utc_now()
      }

      [out] = ContentTransform.transform([msg], VisionProvider, TextOnlyProvider)

      refute Enum.any?(out.content, &match?(%{type: :thinking}, &1))
      assert Enum.any?(out.content, &match?(%{type: :text, text: "visible answer"}, &1))
    end

    test "thinking blocks are stripped even on same-vision-capable hop" do
      # The signature is provider-bound; even a thinking-capable target
      # can't trust it cross-provider. Strip unconditionally.
      msg = %Assistant{
        content: [%{type: :thinking, text: "x", signature: "s"}],
        timestamp: DateTime.utc_now()
      }

      [out] = ContentTransform.transform([msg], VisionProvider, VisionProvider)
      assert out.content == []
    end

    test "image blocks survive when destination has vision" do
      msg = %User{
        content: [
          %{type: :text, text: "look:"},
          %{type: :image, data: "PNGBYTES", media_type: "image/png"}
        ],
        timestamp: DateTime.utc_now()
      }

      [out] = ContentTransform.transform([msg], VisionProvider, VisionProvider)

      assert Enum.any?(out.content, &match?(%{type: :image}, &1))
    end

    test "image blocks downgrade to text placeholder for non-vision target" do
      msg = %User{
        content: [%{type: :image, data: "ABCD", media_type: "image/png"}],
        timestamp: DateTime.utc_now()
      }

      [out] = ContentTransform.transform([msg], VisionProvider, TextOnlyProvider)

      assert [%{type: :text, text: text}] = out.content
      assert text =~ "image"
      assert text =~ "image/png"
      assert text =~ "4 bytes"
    end

    test "cache_control is dropped for non-caching destination" do
      msg = %Assistant{
        content: [%{type: :text, text: "hi", cache_control: %{type: "ephemeral"}}],
        timestamp: DateTime.utc_now()
      }

      [out] = ContentTransform.transform([msg], VisionProvider, TextOnlyProvider)

      assert [%{type: :text, text: "hi"} = block] = out.content
      refute Map.has_key?(block, :cache_control)
    end

    test "cache_control is preserved for caching-capable destination" do
      msg = %Assistant{
        content: [%{type: :text, text: "hi", cache_control: %{type: "ephemeral"}}],
        timestamp: DateTime.utc_now()
      }

      [out] = ContentTransform.transform([msg], VisionProvider, VisionProvider)

      assert [%{cache_control: %{type: "ephemeral"}}] = out.content
    end

    test "tool_call ids are sanitized for the destination provider" do
      messages = [
        %Assistant{
          content: [%{type: :tool_call, id: "call|with|pipes", name: "Read", arguments: %{}}],
          timestamp: DateTime.utc_now()
        },
        %ToolResult{
          tool_call_id: "call|with|pipes",
          tool_name: "Read",
          content: "ok",
          timestamp: DateTime.utc_now()
        }
      ]

      [a, tr] = ContentTransform.transform(messages, VisionProvider, Tau.Providers.Anthropic)
      [tc] = a.content

      # Anthropic regex doesn't allow `|` — id was rewritten in tandem.
      refute String.contains?(tc.id, "|")
      assert tc.id == tr.tool_call_id
    end

    test "User content given as a binary string is left alone" do
      msg = %User{content: "plain string", timestamp: DateTime.utc_now()}
      [out] = ContentTransform.transform([msg], VisionProvider, TextOnlyProvider)
      assert out.content == "plain string"
    end
  end

  # --- properties -----------------------------------------------------------

  @moduletag :property

  defp text_block_gen do
    StreamData.bind(StreamData.string(:alphanumeric, min_length: 1, max_length: 32), fn t ->
      StreamData.constant(%{type: :text, text: t})
    end)
  end

  defp thinking_block_gen do
    StreamData.bind(StreamData.string(:alphanumeric, min_length: 1, max_length: 16), fn t ->
      StreamData.constant(%{type: :thinking, text: t, signature: "sig"})
    end)
  end

  defp image_block_gen do
    StreamData.bind(StreamData.binary(min_length: 1, max_length: 16), fn d ->
      StreamData.constant(%{type: :image, data: d, media_type: "image/png"})
    end)
  end

  defp block_gen do
    StreamData.one_of([text_block_gen(), thinking_block_gen(), image_block_gen()])
  end

  defp message_gen do
    StreamData.bind(StreamData.list_of(block_gen(), min_length: 0, max_length: 6), fn blocks ->
      StreamData.constant(%Assistant{content: blocks, timestamp: DateTime.utc_now()})
    end)
  end

  property "thinking blocks NEVER survive any cross-provider transform" do
    check all(
            messages <- StreamData.list_of(message_gen(), min_length: 0, max_length: 4),
            from <- StreamData.member_of([VisionProvider, TextOnlyProvider]),
            to <- StreamData.member_of([VisionProvider, TextOnlyProvider])
          ) do
      out = ContentTransform.transform(messages, from, to)

      refute Enum.any?(out, fn %{content: c} ->
               is_list(c) and Enum.any?(c, &match?(%{type: :thinking}, &1))
             end)
    end
  end

  property "image blocks survive iff destination has vision" do
    check all(
            messages <- StreamData.list_of(message_gen(), min_length: 1, max_length: 4),
            to <- StreamData.member_of([VisionProvider, TextOnlyProvider])
          ) do
      out = ContentTransform.transform(messages, VisionProvider, to)
      caps = to.capabilities()

      images_after =
        out
        |> Enum.flat_map(fn
          %{content: c} when is_list(c) -> c
          _ -> []
        end)
        |> Enum.count(&match?(%{type: :image}, &1))

      images_before =
        messages
        |> Enum.flat_map(fn
          %{content: c} when is_list(c) -> c
          _ -> []
        end)
        |> Enum.count(&match?(%{type: :image}, &1))

      if caps.vision do
        assert images_after == images_before
      else
        assert images_after == 0
      end
    end
  end

  property "transform/3 is idempotent on a fixed (from, to) pair" do
    check all(
            messages <- StreamData.list_of(message_gen(), min_length: 0, max_length: 4),
            to <- StreamData.member_of([VisionProvider, TextOnlyProvider])
          ) do
      once = ContentTransform.transform(messages, VisionProvider, to)
      twice = ContentTransform.transform(once, to, to)

      # Idempotence on the *destination* pair: applying the same
      # (to, to) transform after the first cross-provider hop is a
      # no-op modulo id-sanitization (which is itself stable).
      assert once == twice
    end
  end
end
