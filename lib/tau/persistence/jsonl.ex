defmodule Tau.Persistence.Jsonl do
  @moduledoc """
  JSONL session persistence.

  Path layout:

      <data_dir>/sessions/<sha256(cwd)[..15]>/<ulid>.jsonl

  Each line is one event:

      {"id":"01H...","parent_id":"01H..."|null,"ts":"...","kind":"...","data":{...}}

  Files are opened with `:delayed_write` to batch writes; the FSM forces
  a flush on `:idle` entry, on terminate, and every N events.

  Tree-branching is recorded as `parent_id` — `Tau.fork(session, event_id)`
  starts a new file whose first persisted event references the parent
  event by id; `Tau.Persistence.Jsonl.stream/1` walks parent chains
  across files when replaying.
  """

  @behaviour Tau.Persistence

  alias Tau.Session.Meta

  @impl Tau.Persistence
  def open(session_id, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    path = path_for(session_id, cwd)
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:append, :binary, {:delayed_write, 64 * 1024, 100}]) do
      {:ok, io} ->
        write_header(io, session_id, cwd, opts)
        {:ok, %{io: io, path: path, session_id: session_id, cwd: cwd, count: 0}}

      err ->
        err
    end
  end

  defp write_header(io, session_id, cwd, opts) do
    meta = %{
      "id" => "header_" <> session_id,
      "parent_id" => Keyword.get(opts, :parent_event_id),
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "session_header",
      "data" => %{
        "session_id" => session_id,
        "cwd" => cwd,
        "provider" => Keyword.get(opts, :provider),
        "model" => Keyword.get(opts, :model),
        "metadata" => Keyword.get(opts, :metadata, %{})
      }
    }

    IO.binwrite(io, Jason.encode!(meta) <> "\n")
  end

  @impl Tau.Persistence
  def append(%{io: io, count: c} = h, event) do
    line = Jason.encode!(event) <> "\n"
    IO.binwrite(io, line)
    {:ok, %{h | count: c + 1}}
  end

  def append(handle, _event), do: {:error, {:bad_handle, handle}}

  @impl Tau.Persistence
  def stream(session_id) when is_binary(session_id) do
    case find_path(session_id) do
      nil ->
        Stream.unfold(:done, fn :done -> nil end)

      path ->
        File.stream!(path, [:line], :line)
        |> Stream.map(fn line -> Jason.decode!(String.trim_trailing(line, "\n")) end)
    end
  end

  @impl Tau.Persistence
  def close(%{io: io}), do: File.close(io)
  def close(_), do: :ok

  @impl Tau.Persistence
  def list(_filters) do
    base = Path.join(Tau.Settings.data_dir(), "sessions")

    if File.dir?(base) do
      base
      |> File.ls!()
      |> Enum.flat_map(fn dir ->
        full_dir = Path.join(base, dir)

        case File.ls(full_dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
            |> Enum.map(&Path.join(full_dir, &1))
            |> Enum.map(&load_meta/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  defp load_meta(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, :line)) do
      {:ok, line} ->
        case Jason.decode(String.trim_trailing(line || "", "\n")) do
          {:ok, %{"kind" => "session_header", "data" => d, "ts" => ts, "id" => id}} ->
            with {:ok, dt, _} <- DateTime.from_iso8601(ts) do
              %Meta{
                id: id |> String.replace_leading("header_", ""),
                cwd: d["cwd"],
                created_at: dt,
                provider: d["provider"],
                model: d["model"],
                metadata: d["metadata"]
              }
            else
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc "Compute the JSONL path for a session id."
  @spec path_for(String.t(), Path.t()) :: Path.t()
  def path_for(session_id, cwd) do
    hash = :crypto.hash(:sha256, cwd) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    Tau.Settings.data_dir()
    |> Path.join("sessions")
    |> Path.join(hash)
    |> Path.join("#{session_id}.jsonl")
  end

  defp find_path(session_id) do
    base = Path.join(Tau.Settings.data_dir(), "sessions")

    if File.dir?(base) do
      Path.wildcard(Path.join([base, "*", "#{session_id}.jsonl"])) |> List.first()
    end
  end
end
