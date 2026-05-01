defmodule Tau.CLI.Config do
  @moduledoc """
  Handlers for the `tau config` subcommand group.

  ### Behaviour

    * `tau config` — print the merged settings cascade (managed → user →
      project → local) along with the layer paths that were read.
    * `tau config get <key>` — read a top-level setting (atom-keyed).
    * `tau config set <key> <value>` — write to the local layer
      (`<cwd>/.tau/settings.local.json`) only. Validates the merged
      result against `Tau.Settings.Schema` before writing; rejects
      managed/user/project paths by construction.
    * `--json` on any subcommand emits machine-readable output.

  Returns integer exit codes: 0 success, 1 user error, 2 system error.

  Pure-ish: I/O happens via `IO.puts/2` and `File` because this is the
  CLI surface — `Logger` and telemetry are wrong here, this output is
  the user's primary feedback. Filesystem writes go through helpers
  that are easy to redirect in tests via the `:cwd` option.
  """

  alias Tau.Settings.{Loader, Schema}

  @type opts :: [json: boolean(), cwd: Path.t()]

  @doc "Handler for `tau config` (no subcommand): show the cascade."
  @spec show(opts()) :: 0 | 1 | 2
  def show(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    %{settings: settings, sources: sources} = Loader.load(cwd)

    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(%{settings: settings, sources: sources}))
    else
      IO.puts("# settings cascade")

      if sources == [] do
        IO.puts("(no layers found)")
      else
        Enum.each(sources, &IO.puts("  layer: #{&1}"))
      end

      IO.puts("")
      IO.puts("# merged")
      IO.puts(Jason.encode_to_iodata!(settings, pretty: true))
    end

    0
  end

  @doc "Handler for `tau config get <key>`."
  @spec get(String.t(), opts()) :: 0 | 1
  def get(key, opts \\ []) when is_binary(key) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    %{settings: settings} = Loader.load(cwd)
    atom_key = safe_to_atom(key)
    value = atom_key && Map.get(settings, atom_key)

    cond do
      is_nil(atom_key) ->
        IO.puts(:stderr, "config get: unknown key #{inspect(key)}")
        1

      is_nil(value) and not Map.has_key?(settings, atom_key) ->
        IO.puts(:stderr, "config get: key not set: #{key}")
        1

      Keyword.get(opts, :json, false) ->
        IO.puts(Jason.encode!(value))
        0

      true ->
        case value do
          v when is_binary(v) or is_number(v) or is_boolean(v) -> IO.puts(to_string(v))
          v -> IO.puts(Jason.encode_to_iodata!(v, pretty: true))
        end

        0
    end
  end

  @doc """
  Handler for `tau config set <key> <value>`.

  The value is decoded as JSON if it parses, falling back to the literal
  string. Writes to `<cwd>/.tau/settings.local.json` only — never to
  managed, user, or project layers.
  """
  @spec set(String.t(), String.t(), opts()) :: 0 | 1 | 2
  def set(key, raw_value, opts \\ []) when is_binary(key) and is_binary(raw_value) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    atom_key = safe_to_atom(key)

    cond do
      is_nil(atom_key) ->
        IO.puts(:stderr, "config set: unknown key #{inspect(key)}")
        1

      key not in Schema.known_top_level_keys() ->
        IO.puts(:stderr, "config set: #{key} is not a known top-level setting")
        1

      true ->
        do_set(atom_key, key, decode_value(raw_value), cwd, opts)
    end
  end

  defp do_set(atom_key, str_key, value, cwd, opts) do
    local_path = Path.join(cwd, ".tau/settings.local.json")
    existing = read_local(local_path)
    next = Map.put(existing, str_key, value)

    case validate(next) do
      :ok ->
        with :ok <- File.mkdir_p(Path.dirname(local_path)),
             :ok <- File.write(local_path, Jason.encode_to_iodata!(next, pretty: true)) do
          Tau.Settings.Cache.reload()

          if Keyword.get(opts, :json, false) do
            IO.puts(Jason.encode!(%{ok: true, key: str_key, path: local_path}))
          else
            IO.puts("set #{atom_key} in #{local_path}")
          end

          0
        else
          {:error, reason} ->
            IO.puts(:stderr, "config set: write failed: #{inspect(reason)}")
            2
        end

      {:error, errors} ->
        IO.puts(:stderr, "config set: schema validation failed:")

        Enum.each(errors, fn {msg, path} ->
          IO.puts(:stderr, "  #{path}: #{msg}")
        end)

        1
    end
  end

  defp read_local(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp decode_value(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      _ -> raw
    end
  end

  defp validate(map_with_string_keys) do
    schema = Schema.json_schema() |> ExJsonSchema.Schema.resolve()
    ExJsonSchema.Validator.validate(schema, map_with_string_keys)
  rescue
    e -> {:error, [{Exception.message(e), "#"}]}
  end

  defp safe_to_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end
end
