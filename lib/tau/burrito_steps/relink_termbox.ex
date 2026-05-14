defmodule Tau.BurritoSteps.RelinkTermbox do
  @moduledoc """
  Burrito build step that relinks `termbox_bindings.so` against musl libc
  using `zig cc -target <cpu>-linux-musl`.

  This step runs **post** `Burrito.Steps.Patch.RecompileNIFs` in the patch
  phase for Linux targets only. `RecompileNIFs` uses `elixir_make` / `make`
  which links against the host glibc (introducing `__snprintf_chk` and other
  fortified symbols). The resulting `.so` cannot load in the musl-based Burrito
  runtime and produces:

      Error relocating .../termbox_bindings.so: __snprintf_chk: symbol not found

  This step bypasses `make` entirely and calls `zig cc` directly, compiling
  `termbox_bindings.c` and linking it against the pre-built static
  `libtermbox.a` (which is already present in the `ex_termbox` source tree
  after `RecompileNIFs` has run). The result is a fully musl-linked shared
  object that loads cleanly in the Burrito wrapper.
  """

  alias Burrito.Builder.Context
  alias Burrito.Builder.Log
  alias Burrito.Builder.Step

  @behaviour Step

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

    ex_termbox_src = ex_termbox_src_path()
    libtermbox_a = Path.join(ex_termbox_src, "c_src/termbox/build/src/libtermbox.a")
    termbox_bindings_c = Path.join(ex_termbox_src, "c_src/termbox_bindings.c")
    termbox_include = Path.join(ex_termbox_src, "c_src/termbox/src")

    erts_include = resolve_erts_include(context.target.erts_source)

    # Find the ex_termbox priv dir inside the release work tree
    so_output =
      Path.join(context.work_dir, "lib/ex_termbox-*/priv/termbox_bindings.so")
      |> Path.wildcard()
      |> List.first()

    unless so_output do
      Log.error(:step, "[RelinkTermbox] Could not find termbox_bindings.so in release tree at #{context.work_dir}/lib/ex_termbox-*/priv/")
      exit(1)
    end

    zig_bin = find_zig!()

    args = [
      "cc",
      "-target", zig_target,
      "-O2",
      "-fPIC",
      "-shared",
      "-I#{erts_include}",
      "-I#{termbox_include}",
      "-o", so_output,
      termbox_bindings_c,
      libtermbox_a
    ]

    Log.info(:step, "[RelinkTermbox] Relinking termbox_bindings.so for #{zig_target}")
    Log.info(:step, "[RelinkTermbox] #{zig_bin} #{Enum.join(args, " ")}")

    case System.cmd(zig_bin, args, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} ->
        Log.info(:step, "[RelinkTermbox] Successfully relinked termbox_bindings.so for #{zig_target}")
        context

      {_, exit_code} ->
        Log.error(:step, "[RelinkTermbox] zig cc failed with exit code #{exit_code}")
        exit(1)
    end
  end

  defp cpu_triplet(:x86_64), do: "x86_64"
  defp cpu_triplet(:aarch64), do: "aarch64"

  defp ex_termbox_src_path do
    Mix.Project.deps_paths()
    |> Map.fetch!(:ex_termbox)
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
    {root, 0} = System.cmd("erl", ["-eval", "io:format(\"~s\", [code:root_dir()])", "-s", "init", "stop", "-noshell"])
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
      raise "[RelinkTermbox] zig not found. Install zig or add it to PATH. " <>
              "Tried: #{Enum.join(absolute_candidates, ", ")} and PATH"
  end
end
