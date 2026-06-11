defmodule Tau.Toolchain.ReportParser do
  @moduledoc """
  Engine-owned, trusted, TOTAL parser for test artifact formats.

  `parse/2` accepts raw artifact bytes and a format tag (supplied by the
  toolchain descriptor's `:report` field) and returns a
  `%Tau.Toolchain.TestReport{}`. The engine selects the parser by format tag;
  the adapter never supplies a parser (SPEC-FACTORY-GATE §4 B5, HR-3).

  ## Totality guarantee (D-306)

  `parse/2` is total: any input bytes, including malformed or empty artifacts,
  yield a defined `%Tau.Toolchain.TestReport{}`. It never raises or crashes.
  Malformed input produces `%TestReport{cases: []}` rather than an exception,
  so a forged or corrupt artifact cannot take down the gate process.

  ## Supported format tags

    * `:junit` — JUnit XML (as emitted by `junit_formatter` / `jest-junit`).
    * `:tap`   — Test Anything Protocol v12/v13.

  Unknown format tags produce `%TestReport{cases: []}` — fail-closed, not a
  fabricated pass.
  """

  alias Tau.Toolchain.TestReport

  @doc """
  Parse `artifact_bytes` according to `format_tag`.

  Returns a `%TestReport{}`. Never raises on any input.

  ## Parameters

    * `artifact_bytes` — binary artifact content (may be empty or malformed).
    * `format_tag`     — `:junit | :tap | atom()`. Unknown tags yield an empty
      report.
  """
  @spec parse(binary(), atom()) :: TestReport.t()
  def parse(artifact_bytes, format_tag) when is_binary(artifact_bytes) do
    cases =
      case format_tag do
        :junit -> parse_junit(artifact_bytes)
        :tap -> parse_tap(artifact_bytes)
        _ -> []
      end

    %TestReport{cases: cases}
  rescue
    _ -> %TestReport{cases: []}
  catch
    _, _ -> %TestReport{cases: []}
  end

  # ---------------------------------------------------------------------------
  # JUnit XML parser (uses :xmerl from OTP — no new deps)
  # ---------------------------------------------------------------------------

  defp parse_junit(""), do: []

  defp parse_junit(bytes) do
    # :xmerl_scan.string/2 requires a char list and returns {xmlElement, rest}.
    # We wrap everything defensively — malformed XML must not crash.
    charlist = :erlang.binary_to_list(bytes)

    case safe_xmerl_scan(charlist) do
      {:ok, doc} -> extract_junit_cases(doc)
      :error -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp safe_xmerl_scan(charlist) do
    # {:quiet, true} suppresses xmerl Logger error output on malformed XML.
    # :xmerl_scan is part of OTP's :xmerl application declared in extra_applications.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    result = apply(:xmerl_scan, :string, [charlist, [{:quiet, true}]])
    {doc, _rest} = result
    {:ok, doc}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp extract_junit_cases(doc) do
    # The document root may be <testsuites> (wrapper) or <testsuite> directly.
    # We find all <testcase> elements recursively.
    doc
    |> find_elements(:testcase)
    |> Enum.map(&testcase_to_map/1)
  end

  defp find_elements(node, tag) do
    # :xmerl elements have shape {:xmlElement, name, ...}
    case node do
      {:xmlElement, ^tag, _, _, _, _, _, _, _, _, _, _} ->
        [node]

      {:xmlElement, _, _, _, _, _, _, _, content, _, _, _} when is_list(content) ->
        Enum.flat_map(content, &find_elements(&1, tag))

      _ ->
        []
    end
  end

  defp testcase_to_map(node) do
    {:xmlElement, :testcase, _, _, _, _, _, attrs, content, _, _, _} = node

    classname = xml_attr_value(attrs, :classname, "")
    name = xml_attr_value(attrs, :name, "")
    id = build_id(classname, name)

    status =
      cond do
        has_child_element(content, :failure) -> :failed
        has_child_element(content, :error) -> :failed
        has_child_element(content, :skipped) -> :skipped
        true -> :passed
      end

    %{id: id, status: status}
  end

  defp xml_attr_value(attrs, key, default) do
    case Enum.find(attrs, fn attr -> elem(attr, 1) == key end) do
      nil -> default
      {:xmlAttribute, _, _, _, _, _, _, _, value, _} -> to_string(value)
    end
  end

  defp has_child_element(content, tag) when is_list(content) do
    Enum.any?(content, fn
      {:xmlElement, ^tag, _, _, _, _, _, _, _, _, _, _} -> true
      _ -> false
    end)
  end

  defp has_child_element(_content, _tag), do: false

  defp build_id("", name), do: name
  defp build_id(classname, ""), do: classname
  defp build_id(classname, name), do: "#{classname}.#{name}"

  # ---------------------------------------------------------------------------
  # TAP parser (line-based; no external dep)
  # ---------------------------------------------------------------------------

  defp parse_tap(""), do: []

  defp parse_tap(bytes) do
    bytes
    |> safe_to_string()
    |> String.split("\n")
    |> Enum.flat_map(&parse_tap_line/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp safe_to_string(bytes) do
    # If the bytes are not valid UTF-8, fall back to Latin-1 interpretation.
    case String.valid?(bytes) do
      true -> bytes
      false -> :unicode.characters_to_binary(bytes, :latin1, :utf8) |> to_string_safe()
    end
  end

  defp to_string_safe(result) do
    case result do
      bin when is_binary(bin) -> bin
      _ -> ""
    end
  end

  defp parse_tap_line(line) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "ok ") ->
        id = tap_test_id(trimmed, "ok ")
        [%{id: id, status: :passed}]

      String.starts_with?(trimmed, "not ok ") ->
        id = tap_test_id(trimmed, "not ok ")
        [%{id: id, status: :failed}]

      true ->
        []
    end
  end

  defp tap_test_id(line, prefix) do
    # "ok N description" or "not ok N description"
    # Strip the prefix, then optionally strip leading number.
    rest = String.slice(line, String.length(prefix), String.length(line))

    case Integer.parse(rest) do
      {_n, remainder} -> String.trim_leading(remainder)
      :error -> rest
    end
  end
end
