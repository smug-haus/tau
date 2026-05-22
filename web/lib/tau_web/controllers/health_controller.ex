defmodule TauWeb.HealthController do
  @moduledoc """
  Liveness health-check endpoint for the `:tau_web` poncho package.

  `GET /health` returns HTTP 200 with a JSON body that includes the core
  `:tau` application version, proving `:tau_web` can reach the path-depped
  `:tau` application at runtime.

  AC-3 / SPEC-WEB-DASHBOARD §4 B1.
  """

  use TauWeb, :controller

  @doc """
  Returns `{"status": "ok", "tau_version": "<version>"}`.

  The `tau_version` field is `to_string(Application.spec(:tau, :vsn))` — the
  OTP application version of the `:tau` core, confirming the path-dep is wired
  at runtime.
  """
  def index(conn, _params) do
    tau_version = to_string(Application.spec(:tau, :vsn))

    conn
    |> put_status(:ok)
    |> json(%{status: "ok", tau_version: tau_version})
  end
end
