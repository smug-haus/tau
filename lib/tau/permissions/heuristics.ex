defmodule Tau.Permissions.Heuristics do
  @moduledoc """
  Pure heuristics over tool-call arguments.

  Used by `Tau.Permissions.Evaluator` to make `:accept_edits` mode
  argument-aware on `Bash`: a non-destructive shell command (e.g.
  `npm test`, `ls -la`) auto-allows; a destructive one (e.g.
  `rm -rf /`, `sudo …`, `dd …`, fork bombs, raw disk writes) denies.

  False positives on legitimate `rm`/`sudo` usage are acceptable here
  because this gate only steers the `:accept_edits` auto-allow path —
  callers that hit a false positive get `:deny`, then fall through to
  an interactive prompt the same way `:ask` would have. False
  negatives, in contrast, would silently let a destructive command
  through under `:accept_edits`, which is what we are protecting
  against.
  """

  # Pre-compiled patterns. Compiled once at module-load via the
  # `Macro.escape/1` trick: `Regex.compile!/1` is allowed in module
  # attributes because it's a regular function call evaluated at
  # compile time.
  @patterns [
    ~r/rm\s+-r/,
    ~r/rm\s+-f/,
    ~r/sudo\s+/,
    ~r/dd\s+/,
    ~r/mkfs(\.\w+)?\s/,
    ~r/shred\s/,
    # Classic bash fork bomb. Match the literal sequence; whitespace
    # inside the brace block is part of the canonical form.
    ~r/:\(\)\{ :\|:&\};:/,
    # Raw write to a primary disk device.
    ~r/>\s*\/dev\/sd[a-z]/
  ]

  @doc """
  Returns `true` when `args` carries a `command` string matching one
  of the destructive-shell patterns.

  Accepts the canonical `Bash` tool argument shape — a map with a
  string `"command"` key — and tolerates the atom `:command` key for
  callers that haven't normalised yet. Anything else (`nil`, missing
  key, non-string command) returns `false`.
  """
  @spec destructive_bash?(map() | nil) :: boolean()
  def destructive_bash?(nil), do: false

  def destructive_bash?(args) when is_map(args) do
    case command(args) do
      cmd when is_binary(cmd) -> Enum.any?(@patterns, &Regex.match?(&1, cmd))
      _ -> false
    end
  end

  def destructive_bash?(_), do: false

  defp command(%{"command" => cmd}), do: cmd
  defp command(%{command: cmd}), do: cmd
  defp command(_), do: nil
end
