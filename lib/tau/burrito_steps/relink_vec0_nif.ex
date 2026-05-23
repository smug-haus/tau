defmodule Tau.BurritoSteps.RelinkVec0Nif do
  @moduledoc """
  Burrito build step that relinks `vec0.so` (from `sqlite_vec`) against
  musl libc using `zig cc -target <cpu>-linux-musl`.

  ## Background

  `sqlite_vec` ships `vec0.so` as a pre-built binary downloaded from the
  upstream GitHub release (https://github.com/asg017/sqlite-vec). The
  pre-built binary for Linux is linked against glibc (`libc.so.6`). It
  currently contains no `__*_chk` fortified symbols, so it loads inside
  the musl-based Burrito runtime by accident — only base libc symbols are
  referenced. A future upstream rebuild with `-D_FORTIFY_SOURCE=2` would
  silently break boot with:

      Error relocating .../vec0.so: __memcpy_chk: symbol not found

  This step relinks `vec0.so` from the upstream C amalgamation
  (`sqlite-vec.c`) so the shipped binary is provably musl-linked, not
  glibc-linked, regardless of how the upstream pre-built was compiled.

  ## Approach

  1. Download the amalgamation tarball for the configured version from
     GitHub (same version as the hex package's `latest_version`). The
     download is idempotent — if the tarball is already present in the
     system temp dir it is reused.
  2. Extract `sqlite-vec.c` to a temp workspace.
  3. Compile with `zig cc -target <cpu>-linux-musl`, using
     `sqlite3ext.h` from exqlite's vendored c_src as the SQLite API
     header. No ERTS include is required — `vec0.so` is a SQLite
     loadable extension, not an Erlang NIF.
  4. Drop the resulting `.so` over the pre-built binary in the Burrito
     release work tree at `lib/sqlite_vec-*/priv/<version>/vec0.so`.

  Mirrors the structure of `Tau.BurritoSteps.RelinkSqliteNif`.

  ## Why no -fvisibility=hidden

  `RelinkSqliteNif` uses `-fvisibility=hidden` to prevent internal SQLite
  symbols from polluting the global symbol namespace. That is appropriate
  for an Erlang NIF because its internal symbols are not part of its API.

  `vec0.so` is a SQLite *loadable extension*, not a NIF. SQLite's
  `load_extension()` locates the extension's entry point via `dlsym()`.
  With `-fvisibility=hidden` the entry point symbol (`sqlite3_vec_init` /
  `sqlite3_extension_init`) is hidden from `dlsym`, so the lookup returns
  NULL, SQLite fails to initialise the extension, and every subsequent
  `CREATE VIRTUAL TABLE ... USING vec0` returns "no such module: vec0" —
  even though `load_extension` returned success.
  """

  alias Burrito.Builder.Context
  alias Burrito.Builder.Log
  alias Burrito.Builder.Step

  @behaviour Step

  # Amalgamation version and SHA-256 (linux/darwin; content-identical).
  # Keep in sync with deps/sqlite_vec/lib/sqlite_vec/downloader.ex
  # `latest_version` when bumping the hex dep.
  @vec_version "0.1.5"
  @amalgamation_url "https://github.com/asg017/sqlite-vec/releases/download/v#{@vec_version}/sqlite-vec-#{@vec_version}-amalgamation.tar.gz"
  @amalgamation_sha256 "06d24d3a3d2a968a8125779e9cf3856bfac5923f5320d23051aac812522b2bf9"

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

    sqlite_include = sqlite3_include_path()

    # Find vec0.so in the release work tree.
    so_output =
      Path.join(context.work_dir, "lib/sqlite_vec-*/priv/*/vec0.so")
      |> Path.wildcard()
      |> List.first()

    unless so_output do
      Log.error(
        :step,
        "[RelinkVec0Nif] Could not find vec0.so in release tree at #{context.work_dir}/lib/sqlite_vec-*/priv/*/vec0.so"
      )

      exit(1)
    end

    wrapper_c = fetch_amalgamation!()
    # The wrapper's directory contains sqlite-vec.c (included via "#include sqlite-vec.c").
    wrapper_dir = Path.dirname(wrapper_c)
    zig_bin = find_zig!()

    args = [
      "cc",
      "-target",
      zig_target,
      "-O2",
      "-fPIC",
      "-shared",
      # Do NOT pass -fvisibility=hidden for SQLite loadable extensions.
      # Unlike Erlang NIFs (where hiding internal symbols prevents pollution),
      # SQLite extension .so files MUST export their entry-point symbol so that
      # SQLite's dlsym() call in load_extension() can find it. With
      # -fvisibility=hidden every symbol (including sqlite3_vec_init /
      # sqlite3_extension_init) becomes hidden, dlsym returns NULL, and SQLite
      # reports "no such module: vec0" — even though the .so was loaded
      # successfully.
      "-I#{wrapper_dir}",
      "-I#{sqlite_include}",
      "-o",
      so_output,
      wrapper_c
    ]

    Log.info(
      :step,
      "[RelinkVec0Nif] Relinking vec0.so for #{zig_target} (from amalgamation #{@vec_version})"
    )

    Log.info(:step, "[RelinkVec0Nif] #{zig_bin} #{Enum.join(args, " ")}")

    case System.cmd(zig_bin, args, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} ->
        Log.info(:step, "[RelinkVec0Nif] Successfully relinked vec0.so for #{zig_target}")
        context

      {_, exit_code} ->
        Log.error(:step, "[RelinkVec0Nif] zig cc failed with exit code #{exit_code}")
        exit(1)
    end
  end

  # Downloads the amalgamation tarball (idempotent) and extracts sqlite-vec.c
  # to a temp directory. Returns the path to a wrapper .c file that compiles
  # cleanly against musl.
  defp fetch_amalgamation! do
    tarball = Path.join(System.tmp_dir!(), "sqlite-vec-#{@vec_version}-amalgamation.tar.gz")

    unless File.exists?(tarball) do
      Log.info(:step, "[RelinkVec0Nif] Downloading amalgamation from #{@amalgamation_url}")

      case System.cmd("curl", ["-fsSL", "-o", tarball, @amalgamation_url],
             stderr_to_stdout: true,
             into: IO.stream()
           ) do
        {_, 0} -> :ok
        {_, code} -> raise "[RelinkVec0Nif] curl failed (exit #{code}) downloading amalgamation"
      end
    end

    verify_sha256!(tarball)

    extract_dir = Path.join(System.tmp_dir!(), "sqlite-vec-#{@vec_version}-src")
    File.mkdir_p!(extract_dir)

    case System.cmd(
           "tar",
           ["-xzf", tarball, "-C", extract_dir, "sqlite-vec.c", "sqlite-vec.h"],
           stderr_to_stdout: true,
           into: IO.stream()
         ) do
      {_, 0} -> :ok
      {_, code} -> raise "[RelinkVec0Nif] tar extraction failed (exit #{code})"
    end

    # sqlite-vec.c uses BSD-style u_int8_t / u_int16_t / u_int64_t types that
    # musl does not expose by default (they live in sys/types.h under a BSD
    # feature guard). Write a thin wrapper that predeclares them before
    # including the amalgamation so the musl build is clean.
    wrapper_path = Path.join(extract_dir, "sqlite_vec_wrapper.c")

    File.write!(wrapper_path, """
    /* Provide BSD-style u_int types for musl before including the amalgamation. */
    #include <stdint.h>
    typedef uint8_t  u_int8_t;
    typedef uint16_t u_int16_t;
    typedef uint64_t u_int64_t;

    #include "sqlite-vec.c"
    """)

    wrapper_path
  end

  # Verifies the tarball SHA-256 against @amalgamation_sha256. Raises on mismatch.
  defp verify_sha256!(path) do
    hash =
      path
      |> File.stream!([], 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    unless hash == @amalgamation_sha256 do
      raise "[RelinkVec0Nif] SHA-256 mismatch for #{path}:\n  got:      #{hash}\n  expected: #{@amalgamation_sha256}\nDelete the cached tarball and retry."
    end
  end

  defp cpu_triplet(:x86_64), do: "x86_64"
  defp cpu_triplet(:aarch64), do: "aarch64"

  # exqlite vendors sqlite3ext.h alongside sqlite3.h in its c_src directory.
  # This is the SQLite extension API header vec0.so needs.
  defp sqlite3_include_path do
    Mix.Project.deps_paths()
    |> Map.fetch!(:exqlite)
    |> Path.join("c_src")
  end

  defp find_zig! do
    absolute_candidates = [
      Path.expand("~/.local/zig/zig"),
      "/usr/local/bin/zig",
      "/usr/bin/zig"
    ]

    found =
      Enum.find(absolute_candidates, &File.exists?/1) ||
        System.find_executable("zig")

    found ||
      raise "[RelinkVec0Nif] zig not found. Install zig or add it to PATH. " <>
              "Tried: #{Enum.join(absolute_candidates, ", ")} and PATH"
  end
end
