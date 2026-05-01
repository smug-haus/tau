defmodule Tau.Command.Spec do
  @moduledoc """
  Pure tokeniser + binder for slash-command argument specs (#15).

  A spec is a list of entries, each a map of one of three shapes:

      %{kind: :arg,    name: atom, required: bool, default: term}
      %{kind: :flag,   name: atom, default: bool}
      %{kind: :option, name: atom, default: term}

  The author declares the spec via the `command_spec/1` macro on
  `Tau.Command`; the macro lowers to a `parameters/0` callback returning
  this list. The session FSM (`spawn_command_task/4`) invokes
  `tokenize/1` + `bind/2` before calling `execute/2`, so the command body
  receives a bound map instead of a raw tail string.

  ## Tokeniser scope

  Shell-like, deliberately small:

    * whitespace splits tokens
    * single-quoted strings preserve their content verbatim
    * double-quoted strings preserve their content verbatim
    * a backslash before a double-quote inside a `"..."` escapes it
    * unterminated quotes return `{:error, :unterminated_quote}`

  Not supported (out of scope for slash-command tails): heredocs, command
  substitution, glob expansion, variable interpolation, ANSI-C `$'...'`.

  ## Binding rules

    1. Walk tokens left-to-right.
    2. `--<name>=<value>` and `--<name> <value>` bind to `option` entries.
    3. `--<name>` / `--no-<name>` bind to `flag` entries (`--no-<name>`
       sets `false`; otherwise `true`).
    4. Bare tokens fill `arg` entries in declaration order.
    5. After the walk: `arg` entries with `required: true` and no token
       yield `{:error, {:missing_arg, name}}`. Optional `arg`s, `flag`s,
       and `option`s fall back to their `:default` (or `nil` / `false`).
    6. An unknown `--name` or a surplus positional yields
       `{:error, {:unknown_token, token}}`.
  """

  @type entry ::
          %{kind: :arg, name: atom(), required: boolean(), default: term()}
          | %{kind: :flag, name: atom(), default: boolean()}
          | %{kind: :option, name: atom(), default: term()}

  @type spec :: [entry()]

  @type bind_error ::
          {:missing_arg, atom()}
          | {:unknown_token, String.t()}
          | {:missing_value, atom()}
          | :unterminated_quote

  # --- Tokeniser ------------------------------------------------------------

  @doc """
  Tokenise a tail string into a flat list of binary tokens.

  Returns `{:ok, tokens}` or `{:error, :unterminated_quote}`.
  """
  @spec tokenize(String.t()) :: {:ok, [String.t()]} | {:error, :unterminated_quote}
  def tokenize(s) when is_binary(s), do: tokenize(s, :ws, [], [])

  # state: :ws | :bare | :sq | :dq
  # acc:   reverse-list of chars in the current token
  # toks:  reverse-list of completed tokens

  defp tokenize(<<>>, :ws, _acc, toks), do: {:ok, Enum.reverse(toks)}

  defp tokenize(<<>>, :bare, acc, toks),
    do: {:ok, Enum.reverse([acc_to_token(acc) | toks])}

  defp tokenize(<<>>, :sq, _acc, _toks), do: {:error, :unterminated_quote}
  defp tokenize(<<>>, :dq, _acc, _toks), do: {:error, :unterminated_quote}

  defp tokenize(<<c::utf8, rest::binary>>, :ws, _acc, toks) when c in [?\s, ?\t, ?\n, ?\r] do
    tokenize(rest, :ws, [], toks)
  end

  defp tokenize(<<?', rest::binary>>, :ws, _acc, toks), do: tokenize(rest, :sq, [], toks)
  defp tokenize(<<?", rest::binary>>, :ws, _acc, toks), do: tokenize(rest, :dq, [], toks)
  defp tokenize(<<c::utf8, rest::binary>>, :ws, _acc, toks), do: tokenize(rest, :bare, [c], toks)

  defp tokenize(<<c::utf8, rest::binary>>, :bare, acc, toks) when c in [?\s, ?\t, ?\n, ?\r] do
    tokenize(rest, :ws, [], [acc_to_token(acc) | toks])
  end

  defp tokenize(<<?', rest::binary>>, :bare, acc, toks), do: tokenize(rest, :sq, acc, toks)
  defp tokenize(<<?", rest::binary>>, :bare, acc, toks), do: tokenize(rest, :dq, acc, toks)

  defp tokenize(<<c::utf8, rest::binary>>, :bare, acc, toks),
    do: tokenize(rest, :bare, [c | acc], toks)

  defp tokenize(<<?', rest::binary>>, :sq, acc, toks), do: tokenize(rest, :bare, acc, toks)
  defp tokenize(<<c::utf8, rest::binary>>, :sq, acc, toks), do: tokenize(rest, :sq, [c | acc], toks)

  defp tokenize(<<?", rest::binary>>, :dq, acc, toks), do: tokenize(rest, :bare, acc, toks)

  defp tokenize(<<?\\, ?", rest::binary>>, :dq, acc, toks),
    do: tokenize(rest, :dq, [?" | acc], toks)

  defp tokenize(<<?\\, ?\\, rest::binary>>, :dq, acc, toks),
    do: tokenize(rest, :dq, [?\\ | acc], toks)

  defp tokenize(<<c::utf8, rest::binary>>, :dq, acc, toks), do: tokenize(rest, :dq, [c | acc], toks)

  defp acc_to_token(acc), do: acc |> Enum.reverse() |> List.to_string()

  # --- Binder ---------------------------------------------------------------

  @doc """
  Bind tokens to a spec.

  Returns `{:ok, map}` on success, where each entry's `:name` is a key
  with its bound (or default) value. Otherwise returns a tagged
  `{:error, reason}` — see `t:bind_error/0`.
  """
  @spec bind(spec(), [String.t()]) :: {:ok, map()} | {:error, bind_error()}
  def bind(spec, tokens) when is_list(spec) and is_list(tokens) do
    do_bind(tokens, spec, %{})
  end

  defp do_bind([], spec, acc), do: finalise(spec, acc)

  defp do_bind([token | rest], spec, acc) do
    cond do
      String.starts_with?(token, "--") ->
        bind_long_flag_or_option(token, rest, spec, acc)

      true ->
        case next_positional(spec, acc) do
          nil -> {:error, {:unknown_token, token}}
          %{name: name} -> do_bind(rest, spec, Map.put(acc, name, token))
        end
    end
  end

  defp bind_long_flag_or_option("--" <> tail, rest, spec, acc) do
    case String.split(tail, "=", parts: 2) do
      [raw_name, value] ->
        bind_named(raw_name, {:explicit, value}, rest, spec, acc)

      [raw_name] ->
        bind_named(raw_name, :implicit, rest, spec, acc)
    end
  end

  defp bind_named(raw_name, value_form, rest, spec, acc) do
    {looked_up, negated?} = lookup_named(raw_name, spec)

    case {looked_up, value_form, negated?} do
      {nil, _, _} ->
        {:error, {:unknown_token, "--" <> raw_name}}

      {%{kind: :flag, name: name}, :implicit, true} ->
        do_bind(rest, spec, Map.put(acc, name, false))

      {%{kind: :flag, name: name}, :implicit, false} ->
        do_bind(rest, spec, Map.put(acc, name, true))

      {%{kind: :flag}, {:explicit, _}, _} ->
        {:error, {:unknown_token, "--" <> raw_name}}

      {%{kind: :option, name: name}, {:explicit, value}, _} ->
        do_bind(rest, spec, Map.put(acc, name, value))

      {%{kind: :option, name: name}, :implicit, _} ->
        case rest do
          [next | rest2] -> do_bind(rest2, spec, Map.put(acc, name, next))
          [] -> {:error, {:missing_value, name}}
        end
    end
  end

  defp lookup_named(raw_name, spec) do
    atom_name = atomise(raw_name)

    case Enum.find(spec, fn e -> e.kind in [:flag, :option] and e.name == atom_name end) do
      %{} = entry -> {entry, false}
      nil -> lookup_no_prefix(raw_name, spec)
    end
  end

  defp lookup_no_prefix("no-" <> rest, spec) do
    flag_name = atomise(rest)

    case Enum.find(spec, fn e -> e.kind == :flag and e.name == flag_name end) do
      %{} = entry -> {entry, true}
      nil -> {nil, false}
    end
  end

  defp lookup_no_prefix(_, _), do: {nil, false}

  defp atomise(name) when is_binary(name) do
    name
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp next_positional(spec, acc) do
    Enum.find(spec, fn
      %{kind: :arg, name: name} -> not Map.has_key?(acc, name)
      _ -> false
    end)
  end

  defp finalise(spec, acc) do
    Enum.reduce_while(spec, {:ok, acc}, fn entry, {:ok, acc} ->
      case finalise_entry(entry, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp finalise_entry(%{kind: :arg, name: name, required: true} = e, acc) do
    if Map.has_key?(acc, name) do
      {:ok, acc}
    else
      case Map.fetch(e, :default) do
        {:ok, value} -> {:ok, Map.put(acc, name, value)}
        :error -> {:error, {:missing_arg, name}}
      end
    end
  end

  defp finalise_entry(%{kind: :arg, name: name} = e, acc) do
    if Map.has_key?(acc, name) do
      {:ok, acc}
    else
      {:ok, Map.put(acc, name, Map.get(e, :default))}
    end
  end

  defp finalise_entry(%{kind: :flag, name: name} = e, acc) do
    if Map.has_key?(acc, name) do
      {:ok, acc}
    else
      {:ok, Map.put(acc, name, Map.get(e, :default, false))}
    end
  end

  defp finalise_entry(%{kind: :option, name: name} = e, acc) do
    if Map.has_key?(acc, name) do
      {:ok, acc}
    else
      {:ok, Map.put(acc, name, Map.get(e, :default))}
    end
  end

  # --- High-level entry point ----------------------------------------------

  @doc """
  Tokenise `tail` and bind to `spec`. Convenience for the FSM call site.
  """
  @spec parse(spec(), String.t()) :: {:ok, map()} | {:error, bind_error()}
  def parse(spec, tail) when is_list(spec) and is_binary(tail) do
    case tokenize(tail) do
      {:ok, tokens} -> bind(spec, tokens)
      {:error, _} = err -> err
    end
  end

  @doc """
  Format a `bind_error` as a friendly message for the model.
  """
  @spec format_error(bind_error()) :: String.t()
  def format_error({:missing_arg, name}),
    do: "Missing required argument: #{name}"

  def format_error({:unknown_token, token}),
    do: "Unknown argument: #{token}"

  def format_error({:missing_value, name}),
    do: "Option --#{name} requires a value"

  def format_error(:unterminated_quote),
    do: "Unterminated quoted string in arguments"
end
