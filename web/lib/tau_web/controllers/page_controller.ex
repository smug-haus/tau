defmodule TauWeb.PageController do
  use TauWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
