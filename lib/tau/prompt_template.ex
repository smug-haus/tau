defmodule Tau.PromptTemplate do
  @moduledoc """
  Struct representing a user-defined prompt template.

  A prompt template is a Markdown file under `<cwd>/.tau/prompts/` or
  `~/.tau/prompts/` with an optional YAML frontmatter block.  It is
  invoked as a slash command: `/name [args...]`.

  Frontmatter keys:

      ---
      description: "Refactor a module for OTP compliance"
      variables:
        - module
        - function
      ---

  `variables` is an ordered list of positional argument names.  When
  absent from frontmatter, the variable list is derived by scanning the
  body for `{{name}}` tokens in first-appearance order, excluding the
  reserved context names (`cwd`, `date`, `user`, `cursor`, `args`).
  """

  @enforce_keys [:name, :body, :path, :variables]
  defstruct [:name, :body, :path, :variables, description: ""]

  @type t :: %__MODULE__{
          name: String.t(),
          body: String.t(),
          path: Path.t(),
          description: String.t(),
          variables: [String.t()]
        }

  @reserved ~w[cwd date user cursor args]

  @doc """
  Reserved context variable names that are never treated as positional
  arguments.  These are injected by the session at render time.
  """
  @spec reserved() :: [String.t()]
  def reserved, do: @reserved
end
