defmodule Tau.CLI.Init.IO do
  @moduledoc """
  Default IO shim for `Tau.CLI.Init`.

  Forwards to the stdlib `IO` module. Tests inject their own shim
  (typically a `GenServer`-free `Agent`-backed module that returns
  pre-canned responses) by passing `io: SomeOther` into
  `Tau.CLI.Init.run/2`.
  """

  @doc "Prompt with `prompt` and return the reply, `:eof`, or `{:error, reason}`."
  @spec gets(String.t()) :: binary() | :eof | {:error, term()}
  def gets(prompt), do: IO.gets(prompt)

  @doc "Write `line` to stdout followed by a newline."
  @spec puts(IO.chardata()) :: :ok
  def puts(line), do: IO.puts(line)

  @doc "Write `chars` to stdout without a trailing newline."
  @spec write(IO.chardata()) :: :ok
  def write(chars), do: IO.write(chars)
end
