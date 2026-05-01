defmodule Tau.CLI.Init.IO do
  @moduledoc """
  Default IO shim for `Tau.CLI.Init`.

  Forwards to the stdlib `IO` module. Tests inject their own shim
  (typically a `GenServer`-free `Agent`-backed module that returns
  pre-canned responses) by passing `io: SomeOther` into
  `Tau.CLI.Init.run/2`.
  """

  @spec gets(String.t()) :: binary() | :eof | {:error, term()}
  def gets(prompt), do: IO.gets(prompt)

  @spec puts(IO.chardata()) :: :ok
  def puts(line), do: IO.puts(line)

  @spec write(IO.chardata()) :: :ok
  def write(chars), do: IO.write(chars)
end
