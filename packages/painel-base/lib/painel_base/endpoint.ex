defmodule PainelBase.Endpoint do
  use Phoenix.Endpoint, otp_app: :painel_base

  # Cookie de sessao: so carrega o token aleatorio da sessao (o resto fica no banco). HttpOnly, SameSite=Lax, Secure, 12 h.
  @sessao [
    store: :cookie,
    key: "_painel_sessao",
    signing_salt: "painel-sessao-v1",
    encryption_salt: "painel-sessao-enc-v1",
    same_site: "Lax",
    http_only: true,
    secure: true,
    max_age: 43_200
  ]

  def opcoes_sessao, do: @sessao

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @sessao]], longpoll: false

  # Tudo servido localmente (fontes Geist incluidas): nenhuma CDN.
  plug Plug.Static, at: "/", from: {:painel_base, "priv/static"}, only: ~w(assets fonts)
  plug Plug.Static, at: "/assets", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)
  plug Plug.Static, at: "/assets", from: {:phoenix_live_view, "priv/static"}, only: ~w(phoenix_live_view.min.js)

  plug Plug.RequestId
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["text/html"], length: 20_000
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @sessao
  plug PainelBase.Router
end
