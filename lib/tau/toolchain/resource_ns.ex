defmodule Tau.Toolchain.ResourceNS do
  @moduledoc """
  A single mutable resource namespace declaration returned by
  `Tau.Factory.Toolchain.declare_resource_namespace/1`.

  The Worker fleet (W) allocates a per-worker namespace over exactly this set
  so that concurrent workers do not collide on shared caches (SPEC-FACTORY-GATE
  §4 B9; SPEC-FACTORY-FLEET D-309; `worktree-discipline.md`).

  Fields:

    * `kind` — the resource category:
        - `:env`      — the runtime value is provided to the subprocess via the
                        named environment variable; W overwrites the variable
                        with the per-worker path.
        - `:xdg_data` — the `XDG_DATA_HOME` family (Burrito unpack cache).
        - `:dir`      — a filesystem path (may contain `~`); W creates a
                        per-worker shadow directory.
    * `var`  — the environment variable name (for `:env` and `:xdg_data` kinds).
    * `path` — the filesystem path template (for `:dir` kind; may be `nil`
               for the other kinds).
  """

  @enforce_keys [:kind, :var]

  defstruct [:kind, :var, :path]

  @type kind :: :env | :xdg_data | :dir

  @type t :: %__MODULE__{
          kind: kind(),
          var: String.t(),
          path: String.t() | nil
        }
end
