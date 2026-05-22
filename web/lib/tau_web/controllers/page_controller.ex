defmodule TauWeb.PageController do
  @moduledoc "Static index page for the `:tau_web` poncho."

  use TauWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
