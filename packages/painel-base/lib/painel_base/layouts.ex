defmodule PainelBase.Layouts do
  @moduledoc "Casca das paginas: raiz sem JS (entrada/recuperacao), raiz com LiveView (area logada), cabecalho com a marca e navegacao inferior (mobile first)."
  use Phoenix.Component

  @nav [{"/", "Início", :inicio}, {"/campanhas", "Campanhas", :campanhas}, {"/agente", "Agente", :agente}, {"/conta", "Conta", :conta}]

  # Dois aneis sobrepostos com um ponto, em cobalto.
  def marca(assigns) do
    ~H"""
    <svg class="marca" viewBox="0 0 40 24" width="40" height="24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true" focusable="false">
      <circle cx="14" cy="12" r="9" /><circle cx="26" cy="12" r="9" /><circle cx="20" cy="12" r="2.3" fill="currentColor" stroke="none" />
    </svg>
    """
  end

  def csrf(assigns) do
    ~H"""
    <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
    """
  end

  # ---- raizes (documento HTML) ----
  def raiz_auth(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="pt-BR">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>modular agentes</title>
        <link rel="preload" href="/fonts/Geist-Variable.woff2" as="font" type="font/woff2" crossorigin />
        <link rel="stylesheet" href="/assets/app.css" />
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  def raiz_app(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="pt-BR">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>modular agentes</title>
        <link rel="preload" href="/fonts/Geist-Variable.woff2" as="font" type="font/woff2" crossorigin />
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer src="/assets/phoenix.min.js"></script>
        <script defer src="/assets/phoenix_live_view.min.js"></script>
        <script defer src="/assets/app.js"></script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  # ---- miolo ----
  def auth(assigns) do
    ~H"""
    <main class="auth">
      <div class="marca-linha"><.marca /><span class="nome">modular agentes</span></div>
      {@inner_content}
    </main>
    """
  end

  def app(assigns) do
    assigns = assigns |> Map.put_new_lazy(:nav, fn -> @nav ++ PainelBase.Extensao.nav(assigns[:usuario]) end) |> Map.put_new(:ativo, nil)

    ~H"""
    <header class="topo">
      <div class="marca-linha"><.marca /><span class="nome">modular agentes</span></div>
    </header>
    <main class="miolo">{@inner_content}</main>
    <nav class="inferior" aria-label="Principal">
      <.link :for={{href, rotulo, chave} <- @nav} navigate={href} aria-current={if @ativo == chave, do: "page"} class={if @ativo == chave, do: "ativo"}>
        <span class="rotulo">{rotulo}</span>
      </.link>
    </nav>
    """
  end
end
