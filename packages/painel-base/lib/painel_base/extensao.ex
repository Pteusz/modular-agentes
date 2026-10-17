defmodule PainelBase.Extensao do
  @moduledoc """
  Ponto de extensao do painel (oferta "painel.extensao" 1.0). Outros pacotes registram um plug/router em
  `config :painel_base, :extensoes, equipe: MeuRouter`; o painel encaminha `/equipe/*` para ele, ja atras do login.
  A extensao pode ter `nav/0` e `inicio/1` (pagina inicial depois do login, por usuario). Sem extensao registrada: 404.
  O painel nunca depende de quem se registra.
  """
  import Plug.Conn

  def init(chave), do: chave

  def call(conn, chave) do
    case Keyword.get(Application.get_env(:painel_base, :extensoes, []), chave) do
      nil -> conn |> send_resp(404, "Não encontrado") |> halt()
      mod -> mod.call(conn, mod.init([]))
    end
  end

  @doc "Para onde o usuario vai depois de entrar: a primeira extensao que responder, senao \"/\"."
  def inicio(usuario) do
    Enum.find_value(Application.get_env(:painel_base, :extensoes, []), "/", fn {_, mod} ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :inicio, 1) && mod.inicio(usuario)
    end)
  end
end
