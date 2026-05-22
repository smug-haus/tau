defmodule TauWeb.Router do
  use TauWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TauWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TauWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Health check endpoint — AC-3 (SPEC-WEB-DASHBOARD §4 B1).
  # Proves :tau_web reached the :tau core application by including its version.
  scope "/", TauWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:tau_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TauWeb.Telemetry
    end
  end
end
