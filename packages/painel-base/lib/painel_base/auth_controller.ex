defmodule PainelBase.AuthController do
  use Phoenix.Controller, formats: [:html], layouts: [html: {PainelBase.Layouts, :auth}]
  import Plug.Conn
  alias PainelBase.{Sessoes, Tokens, Usuarios}

  def entrar_form(conn, _), do: render(conn, :entrar, erro: nil, email: "")

  def entrar(conn, %{"email" => email, "senha" => senha}) when is_binary(email) and is_binary(senha) do
    case Usuarios.autenticar(email, senha, conn.assigns.ip) do
      {:ok, u} ->
        token = Sessoes.criar(u.id)
        conn |> configure_session(renew: true) |> put_session(:sessao_token, token) |> redirect(to: PainelBase.Extensao.inicio(u))

      :bloqueado ->
        conn |> put_status(429) |> render(:entrar, erro: "Muitas tentativas. Aguarde alguns minutos e tente de novo.", email: "")

      :nao_verificado ->
        render(conn, :entrar, erro: "Verifique seu e-mail: confirme o endereço pelo link que enviamos antes de entrar.", email: email)

      :invalido ->
        render(conn, :entrar, erro: "E-mail ou senha inválidos.", email: email)
    end
  end

  def entrar(conn, _), do: render(conn, :entrar, erro: "E-mail ou senha inválidos.", email: "")

  def sair(conn, _) do
    Sessoes.revogar(get_session(conn, :sessao_token))
    conn |> configure_session(drop: true) |> redirect(to: "/entrar")
  end

  # ---- convite -> definir senha ----
  def convite_form(conn, %{"token" => token}), do: formulario_senha(conn, token, "convite", :convite, nil)

  def convite(conn, %{"token" => token} = p), do: definir(conn, token, "convite", :convite, &Usuarios.aceitar_convite/3, p)

  # ---- recuperacao ----
  def recuperar_form(conn, _), do: render(conn, :recuperar, enviado: false)

  def recuperar(conn, %{"email" => email}) when is_binary(email) do
    # Resposta identica com ou sem conta. Em producao o envio roda a parte (o tempo de resposta tambem nao revela a conta).
    if Application.get_env(:painel_base, :recuperar_async, true),
      do: Task.start(fn -> Usuarios.recuperar(email) end),
      else: Usuarios.recuperar(email)

    render(conn, :recuperar, enviado: true)
  end

  def recuperar(conn, _), do: render(conn, :recuperar, enviado: true)

  def redefinir_form(conn, %{"token" => token}), do: formulario_senha(conn, token, "recuperacao", :redefinir, nil)

  def redefinir(conn, %{"token" => token} = p), do: definir(conn, token, "recuperacao", :redefinir, &Usuarios.redefinir/3, p)

  # GET so confere (leitores de e-mail e antivirus abrem links sozinhos); quem gasta o token e o POST do botao.
  def verificar_form(conn, %{"token" => token}) do
    case Tokens.ver(token, "verificacao") do
      {:ok, _} -> render(conn, :verificar, token: token)
      :invalido -> invalido(conn)
    end
  end

  def verificar(conn, %{"token" => token}) do
    case Usuarios.verificar_email(token) do
      :ok -> redirect(conn, to: "/entrar")
      _ -> invalido(conn)
    end
  end

  # ---- internos ----
  defp formulario_senha(conn, token, tipo, pagina, erro) do
    case Tokens.ver(token, tipo) do
      {:ok, _} -> render(conn, pagina, token: token, erro: erro)
      :invalido -> invalido(conn)
    end
  end

  defp definir(conn, token, tipo, pagina, fun, p) do
    senha = if is_binary(p["senha"]), do: p["senha"]
    conf = if is_binary(p["senha_confirmacao"]), do: p["senha_confirmacao"]

    case fun.(token, senha, conf) do
      {:ok, _} -> redirect(conn, to: "/entrar")
      {:error, msg} -> conn |> formulario_senha(token, tipo, pagina, msg)
      _ -> invalido(conn)
    end
  end

  defp invalido(conn), do: conn |> put_status(410) |> render(:invalido)
end
