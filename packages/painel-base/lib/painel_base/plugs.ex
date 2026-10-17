defmodule PainelBase.Plugs.Ip do
  @moduledoc """
  IP do cliente para o limite de tentativas. Atras do nginx o remote_ip e do proxy (rede privada): so nesse caso vale o ULTIMO item do
  X-Forwarded-For (o que o proprio nginx acrescentou). Vindo direto da internet o cabecalho e ignorado (qualquer um poderia forja-lo).
  """
  import Plug.Conn

  def init(o), do: o

  def call(conn, _) do
    ip = if privado?(conn.remote_ip), do: encaminhado(conn) || conn.remote_ip, else: conn.remote_ip
    assign(conn, :ip, ip |> :inet.ntoa() |> to_string())
  end

  defp encaminhado(conn) do
    with [valor | _] <- get_req_header(conn, "x-forwarded-for"),
         ultimo = valor |> String.split(",") |> List.last() |> String.trim(),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(ultimo)) do
      ip
    else
      _ -> nil
    end
  end

  defp privado?({127, _, _, _}), do: true
  defp privado?({10, _, _, _}), do: true
  defp privado?({172, b, _, _}) when b in 16..31, do: true
  defp privado?({192, 168, _, _}), do: true
  defp privado?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp privado?(_), do: false
end

defmodule PainelBase.Plugs.Autenticar do
  @moduledoc """
  Exige sessao valida. O TENANT vem sempre da sessao no servidor (nunca de parametro, cookie legivel ou formulario).
  Como plug (paginas comuns) e como on_mount (LiveView).
  """
  import Plug.Conn
  alias PainelBase.Sessoes

  def init(o), do: o

  def call(conn, _) do
    case Sessoes.usuario(get_session(conn, :sessao_token)) do
      nil -> conn |> configure_session(drop: true) |> Phoenix.Controller.redirect(to: "/entrar") |> halt()
      usuario -> assign(conn, :usuario, usuario)
    end
  end

  def on_mount(:default, _params, session, socket) do
    case Sessoes.usuario(session["sessao_token"]) do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/entrar")}

      usuario ->
        # o formulario de sair, dentro do LiveView, precisa do mesmo token CSRF da sessao
        if csrf = session["_csrf_token"], do: Process.put(:plug_unmasked_csrf_token, csrf)
        {:cont, Phoenix.Component.assign(socket, :usuario, usuario)}
    end
  end
end
