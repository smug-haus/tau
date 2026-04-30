defmodule Tau.Command do
  @moduledoc """
  Behaviour for slash commands.

  A command is invoked when the user types `/<name>` (alone or followed
  by arguments). It returns a `:cont` to inject context into the next
  user prompt, or `:run` to drive the session directly.

  Commands can be defined in three ways:

    1. Programmatically via `use Tau.Extension` + `command "/foo", FooMod`
    2. Markdown files at `~/.tau/commands/*.md` or `<cwd>/.tau/commands/*.md`
       (loaded by `Tau.Commands.Files`).
    3. Skills (with frontmatter) — see `Tau.Skill`.
  """

  @type result ::
          {:inject, String.t()}
          | {:replace, String.t()}
          | {:run, String.t()}
          | :ignore

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback execute(args :: String.t(), ctx :: map()) :: result()
end
