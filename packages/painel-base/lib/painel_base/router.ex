defmodule PainelBase.Router do
  use Phoenix.Router, helpers: false
  import Phoenix.LiveView.Router

  @csp "default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self' data:; connect-src 'self'; " <>
         "frame-ancestors 'none'; form-action 'self'; base-uri 'none'; object-src 'none'"

  def cabecalhos(conn, _) do
    Phoenix.Controller.put_secure_browser_headers(conn, %{
      "content-security-policy" => @csp,
      "x-frame-options" => "DENY",
      "referrer-policy" => "same-origin",
      "strict-transport-security" => "max-age=31536000",
      "cache-control" => "no-store"
    })
  end

  pipeline :auth do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {PainelBase.Layouts, :raiz_auth}
    plug :protect_from_forgery
    plug :cabecalhos
    plug PainelBase.Plugs.Ip
  end

  pipeline :app do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {PainelBase.Layouts, :raiz_app}
    plug :protect_from_forgery
    plug :cabecalhos
    plug PainelBase.Plugs.Ip
    plug PainelBase.Plugs.Autenticar
  end

  scope "/", PainelBase do
    pipe_through :auth

    get "/entrar", AuthController, :entrar_form
    post "/entrar", AuthController, :entrar
    post "/sair", AuthController, :sair
    get "/convite/:token", AuthController, :convite_form
    post "/convite/:token", AuthController, :convite
    get "/recuperar", AuthController, :recuperar_form
    post "/recuperar", AuthController, :recuperar
    get "/redefinir/:token", AuthController, :redefinir_form
    post "/redefinir/:token", AuthController, :redefinir
    get "/verificar/:token", AuthController, :verificar_form
    post "/verificar/:token", AuthController, :verificar
  end

  scope "/", PainelBase do
    pipe_through :app

    get "/campanhas/:id", CampanhaController, :show

    live_session :corretor, on_mount: PainelBase.Plugs.Autenticar, layout: {PainelBase.Layouts, :app} do
      live "/", InicioLive
      live "/campanhas", CampanhasLive
      live "/agente", AgenteLive
      live "/conta", ContaLive
    end
  end
end
