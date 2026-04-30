defmodule Tau.Skill do
  @moduledoc """
  A skill: a markdown body + frontmatter that the model can invoke as
  a slash-command-like operation.

  Loaded by `Tau.Skills.Loader`; registered in `Tau.Skills.Registry`
  by `name`.
  """

  @enforce_keys [:name, :body, :path]
  defstruct [
    :name,
    :body,
    :path,
    description: "",
    allowed_tools: [],
    disable_model_invocation: false,
    paths: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          body: String.t(),
          path: Path.t(),
          description: String.t(),
          allowed_tools: [String.t()],
          disable_model_invocation: boolean(),
          paths: [String.t()]
        }
end
