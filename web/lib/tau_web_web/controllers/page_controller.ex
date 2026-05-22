defmodule TauWebWeb.PageController do
  use TauWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
