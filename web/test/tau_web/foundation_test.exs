defmodule TauWeb.FoundationTest do
  @moduledoc """
  Gating tests for PR #375 / issue #374 — the M7 `:tau_web` foundation.

  These tests are authored BEFORE the `web/` Phoenix poncho project exists.
  Until the implementer scaffolds `web/` (`mix phx.new web --app tau_web
  --no-ecto --no-mailer`, path-depping `:tau`), this module does not compile
  or run — that total-absence failure is the legitimate fail-before state.

  Two non-meta acceptance criteria are gated here:

    * AC-3 — `GET /health` returns HTTP 200, JSON body
      `{"status": "ok", "tau_version": "<v>"}`, proving `:tau_web` reached
      the core `:tau` application.
    * AC-4 — `:tau_web` reuses the running `Tau.PubSub` and does NOT start
      a second `Phoenix.PubSub` instance.

  AC-1, AC-2, AC-5 are `(meta)` — verified by inspection/CI — and are
  intentionally NOT gated here.
  """
  use TauWeb.ConnCase, async: true

  describe "AC-3 — /health route proves :tau_web reached the :tau core" do
    @tag :ac_3
    test "GET /health returns 200 with JSON {status: ok, tau_version: <:tau vsn>}" do
      conn = get(build_conn(), "/health")

      assert conn.status == 200

      assert "application/json" <>
               _ = List.first(Plug.Conn.get_resp_header(conn, "content-type"))

      body = Jason.decode!(conn.resp_body)

      assert body["status"] == "ok"

      # The body must carry the core :tau application version. This is the
      # observable proof that the :tau_web app is running against, and can
      # reach, the path-depped :tau application.
      assert body["tau_version"] == to_string(Application.spec(:tau, :vsn))
    end
  end

  describe "AC-4 — :tau_web reuses Tau.PubSub, starts no second Phoenix.PubSub" do
    @tag :ac_4
    test "TauWeb.Application start spec includes no Phoenix.PubSub child" do
      # Drive the real application start spec — the user-facing path is the
      # OTP application boot. TauWeb.Application.start/2 builds the child
      # list; none of those children may be a Phoenix.PubSub.
      {:ok, children} = supervisor_children(TauWeb.Supervisor)

      pubsub_children =
        Enum.filter(children, fn
          {Phoenix.PubSub, _, _, _} -> true
          {id, _, _, _} when id == Phoenix.PubSub -> true
          _ -> false
        end)

      assert pubsub_children == [],
             "TauWeb must not start its own Phoenix.PubSub; found: " <>
               inspect(pubsub_children)

      # And :tau_web's endpoint must be configured to use the core
      # Tau.PubSub server, not a private one.
      assert Application.get_env(:tau_web, TauWeb.Endpoint)[:pubsub_server] ==
               Tau.PubSub
    end
  end

  # Returns the running children of the named supervisor as
  # `{:ok, [child_spec_or_tuple]}`. Used to inspect what :tau_web actually
  # started, rather than re-deriving it from source.
  defp supervisor_children(sup) do
    {:ok, Supervisor.which_children(sup)}
  end
end
