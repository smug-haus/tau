defmodule Tau.Permissions.Matcher do
  @moduledoc """
  Behaviour for permission rule matchers.

  A rule is `{:allow | :deny | :ask, matcher_module, compiled_rule}`. The
  evaluator walks rules in priority order (deny → ask → allow); first
  match wins.

  Default matchers ship in `Tau.Permissions.Matchers.*`:

    * `Always`     — matches anything (used for blanket allow/deny on a tool)
    * `Glob`       — `Bash(npm run *)`, `Read(./.env)` shell-glob style
    * `PathPrefix` — `Read(./src/)` matches any file under `./src/`
    * `Domain`     — `WebFetch(domain:github.com)`
    * `Regex`      — `Bash(re:^git\\s+log)` for advanced cases
  """

  @type rule :: term()
  @type tool_name :: String.t()

  @callback match?(rule(), tool_name(), args :: map(), ctx :: map()) :: boolean()
end
