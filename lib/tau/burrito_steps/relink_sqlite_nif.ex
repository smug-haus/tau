defmodule Tau.BurritoSteps.RelinkSqliteNif do
  @moduledoc """
  Burrito build step that relinks `sqlite3_nif.so` (from `exqlite`) against
  musl libc using `zig cc -target <cpu>-linux-musl`.

  This step runs **post** `Burrito.Steps.Patch.RecompileNIFs` in the patch
  phase for Linux targets only. `RecompileNIFs` invokes `elixir_make` / `make`
  which links the NIF against the host glibc (introducing `__snprintf_chk`,
  `__strcpy_chk`, and other fortified symbols). The resulting `.so` cannot
  load inside the musl-based Burrito runtime and produces, at startup of the
  packaged binary:

      Error relocating .../sqlite3_nif.so: __snprintf_chk: symbol not found

  This step bypasses `make` entirely and calls `zig cc` directly, compiling
  `sqlite3_nif.c` and `sqlite3.c` (the vendored SQLite amalgamation) with the
  exact set of `-D` flags that exqlite's `Makefile` defines, and emits a fully
  musl-linked shared object into the release work tree.

  Mirrors the structure of `Tau.BurritoSteps.RelinkTermbox`.
  """

  alias Burrito.Builder.Context
  alias Burrito.Builder.Log
  alias Burrito.Builder.Step

  @behaviour Step

  # Exqlite Makefile compile-time definitions (deps/exqlite/Makefile lines
  # ~94-115). Kept in sync manually; if you bump exqlite, re-read the Makefile
  # and update this list. These are the same flags the upstream Makefile passes
  # to `cc` when building sqlite3.c + sqlite3_nif.c.
  @sqlite_defines [
    "-DNDEBUG=1",
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_USE_URI=1",
    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS=1",
    "-DSQLITE_DQS=0",
    "-DHAVE_USLEEP=1",
    "-DALLOW_COVERING_INDEX_SCAN=1",
    "-DENABLE_FTS3_PARENTHESIS=1",
    "-DENABLE_LOAD_EXTENSION=1",
    "-DENABLE_SOUNDEX=1",
    "-DENABLE_STAT4=1",
    "-DENABLE_UPDATE_DELETE_LIMIT=1",
    "-DSQLITE_ENABLE_FTS3=1",
    "-DSQLITE_ENABLE_FTS4=1",
    "-DSQLITE_ENABLE_FTS5=1",
    "-DSQLITE_ENABLE_GEOPOLY=1",
    "-DSQLITE_ENABLE_MATH_FUNCTIONS=1",
    "-DSQLITE_ENABLE_RBU=1",
    "-DSQLITE_ENABLE_RTREE=1",
    "-DSQLITE_OMIT_DEPRECATED=1",
    "-DSQLITE_ENABLE_DBSTAT_VTAB=1"
  ]

  @impl Step
  def execute(%Context{} = context) do
    if linux_target?(context.target) do
      relink(context)
    else
      context
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp linux_target?(%{os: :linux}), do: true
  defp linux_target?(_), do: false

  defp relink(%Context{} = context) do
    cpu_triplet = cpu_triplet(context.target.cpu)
    zig_target = "#{cpu_triplet}-linux-musl"

    exqlite_src = exqlite_src_path()
    sqlite3_c = Path.join(exqlite_src, "c_src/sqlite3.c")
    sqlite3_nif_c = Path.join(exqlite_src, "c_src/sqlite3_nif.c")
    sqlite_include = Path.join(exqlite_src, "c_src")

    erts_include = resolve_erts_include(context.target.erts_source)

    # Find the exqlite priv dir inside the release work tree.
    so_output =
      Path.join(context.work_dir, "lib/exqlite-*/priv/sqlite3_nif.so")
      |> Path.wildcard()
      |> List.first()

    unless so_output do
      Log.error(
        :step,
        "[RelinkSqliteNif] Could not find sqlite3_nif.so in release tree at #{context.work_dir}/lib/exqlite-*/priv/"
      )

      exit(1)
    end

    zig_bin = find_zig!()

    args =
      [
        "cc",
        "-target",
        zig_target,
        "-O2",
        "-fPIC",
        "-shared",
        "-fvisibility=hidden",
        "-I#{erts_include}",
        "-I#{sqlite_include}"
      ] ++
        @sqlite_defines ++
        [
          "-o",
          so_output,
          sqlite3_nif_c,
          sqlite3_c
        ]

    Log.info(:step, "[RelinkSqliteNif] Relinking sqlite3_nif.so for #{zig_target}")
    Log.info(:step, "[RelinkSqliteNif] #{zig_bin} #{Enum.join(args, " ")}")

    case System.cmd(zig_bin, args, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} ->
        Log.info(
          :step,
          "[RelinkSqliteNif] Successfully relinked sqlite3_nif.so for #{zig_target}"
        )

        context

      {_, exit_code} ->
        Log.error(:step, "[RelinkSqliteNif] zig cc failed with exit code #{exit_code}")
        exit(1)
    end
  end

  defp cpu_triplet(:x86_64), do: "x86_64"
  defp cpu_triplet(:aarch64), do: "aarch64"

  defp exqlite_src_path do
    Mix.Project.deps_paths()
    |> Map.fetch!(:exqlite)
  end

  defp resolve_erts_include({:local_unpacked, path: erts_path}) do
    Path.join(erts_path, ["otp*/", "erts*/", "include/"])
    |> Path.expand()
    |> Path.wildcard()
    |> List.first()
    |> then(fn
      nil ->
        # fallback: bundled ERTS may be at the root of erts_path
        Path.join(erts_path, "erts*/include/")
        |> Path.expand()
        |> Path.wildcard()
        |> List.first()

      path ->
        path
    end)
  end

  # Covers the case where the host ERTS is used (same_target? == true)
  defp resolve_erts_include({:runtime, _}) do
    :code.root_dir()
    |> to_string()
    |> Path.join("erts-#{:erlang.system_info(:version)}/include")
  end

  defp resolve_erts_include(_) do
    # Best-effort fallback: use host erl headers
    {root, 0} =
      System.cmd("erl", [
        "-eval",
        "io:format(\"~s\", [code:root_dir()])",
        "-s",
        "init",
        "stop",
        "-noshell"
      ])

    version = :erlang.system_info(:version) |> to_string()
    Path.join(String.trim(root), "erts-#{version}/include")
  end

  defp find_zig! do
    # Check absolute paths first, then fall back to resolving "zig" from PATH
    # via System.find_executable/1 which is safe (no raise on missing).
    absolute_candidates = [
      Path.expand("~/.local/zig/zig"),
      "/usr/local/bin/zig",
      "/usr/bin/zig"
    ]

    found =
      Enum.find(absolute_candidates, &File.exists?/1) ||
        System.find_executable("zig")

    found ||
      raise "[RelinkSqliteNif] zig not found. Install zig or add it to PATH. " <>
              "Tried: #{Enum.join(absolute_candidates, ", ")} and PATH"
  end
end
