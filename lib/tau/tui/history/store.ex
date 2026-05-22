defmodule Tau.TUI.History.Store do
  @moduledoc """
  Thin impure boundary for persisting per-cwd prompt history as JSONL.

  Path: `Path.join([data_dir, "history", sha256_hex(cwd) <> ".jsonl"])`.

  `data_dir` MUST be supplied explicitly — the caller is responsible for
  providing the correct path. `Tau.TUI.App` passes `Tau.Settings.data_dir()`;
  tests pass a per-test `tmp_dir`. This keeps the store hermetic under
  `mix test` where `Settings.data_dir/0` reads `~/.tau` (D-140).

  Load-time tail-truncation enforces the 100-entry cap (D-143).
  Append writes are POSIX-atomic for lines ≤ 4 KiB (D-148 known limitation).
  """

  @cap 100

  @doc """
  Load history for the given `data_dir` and `cwd`.
  Returns a `Tau.TUI.History` populated from the JSONL file (or empty).
  """
  @spec load(Path.t(), Path.t()) :: Tau.TUI.History.t()
  def load(data_dir, cwd) do
    path = history_path(data_dir, cwd)

    entries =
      if File.regular?(path) do
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&is_binary/1)
        |> Enum.reverse()
        |> Enum.take(@cap)
      else
        []
      end

    %Tau.TUI.History{entries: entries}
  end

  @doc """
  Append a single history entry to the JSONL file.
  Creates parent directories as needed.
  The append is atomic for lines ≤ 4 KiB on POSIX (D-148).
  """
  @spec append(Path.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def append(_data_dir, _cwd, ""), do: :ok

  def append(data_dir, cwd, text) do
    path = history_path(data_dir, cwd)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      line = Jason.encode!(text) <> "\n"
      File.write(path, line, [:append])
    end
  end

  @doc """
  Return the path for a given `data_dir` and `cwd` combination.
  Exposed for testing (D-146 assertion).
  """
  @spec history_path(Path.t(), Path.t()) :: Path.t()
  def history_path(data_dir, cwd) do
    filename = sha256_hex(cwd) <> ".jsonl"
    Path.join([data_dir, "history", filename])
  end

  # --- private ---------------------------------------------------------------

  defp sha256_hex(str) do
    :crypto.hash(:sha256, str) |> Base.encode16(case: :lower)
  end
end
