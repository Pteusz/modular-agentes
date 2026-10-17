defmodule GestaoEquipe.Router do
  @moduledoc """
  Rotas da equipe, montadas pelo painel-base em /equipe (extensao "painel.extensao"). O painel ja exigiu o login; aqui so entra dono ou admin
  (corretor comum recebe 403). Rotas simples (GET/POST), sem LiveView: a tela da equipe e pagina comum.
  """
  import Plug.Conn
  alias GestaoEquipe.EquipeController, as: C

  def init(o), do: o

  @doc "Para onde o painel manda dono/admin depois do login."
  def inicio(usuario), do: if(GestaoEquipe.papel(usuario) in [:dono, :admin], do: "/equipe")

  def call(conn, _) do
    if GestaoEquipe.papel(conn.assigns[:usuario]) in [:dono, :admin] do
      conn = fetch_query_params(conn)
      rotear(conn, conn.method, conn.path_info)
    else
      conn |> send_resp(403, "Acesso negado") |> halt()
    end
  end

  defp rotear(conn, "GET", []), do: ir(conn, :painel)
  defp rotear(conn, "GET", ["corretores"]), do: ir(conn, :lista)
  defp rotear(conn, "GET", ["corretores", "novo"]), do: ir(conn, :novo)
  defp rotear(conn, "POST", ["corretores"]), do: ir(conn, :criar)
  defp rotear(conn, "GET", ["corretores", id]), do: ir(conn, :corretor, %{"id" => id})
  defp rotear(conn, "POST", ["corretores", id, "editar"]), do: ir(conn, :editar, %{"id" => id})
  defp rotear(conn, "POST", ["corretores", id, "desativar"]), do: ir(conn, :desativar, %{"id" => id})
  defp rotear(conn, "POST", ["corretores", id, "reativar"]), do: ir(conn, :reativar, %{"id" => id})
  defp rotear(conn, "POST", ["corretores", id, "excluir"]), do: ir(conn, :excluir, %{"id" => id})
  defp rotear(conn, "POST", ["corretores", id, "sincronizar"]), do: ir(conn, :sincronizar, %{"id" => id})
  defp rotear(conn, "GET", ["ia"]), do: ir(conn, :ia)
  defp rotear(conn, "GET", ["alertas"]), do: ir(conn, :alertas)
  defp rotear(conn, "GET", ["auditoria"]), do: ir(conn, :auditoria)
  defp rotear(conn, "GET", ["admins"]), do: ir(conn, :admins)
  defp rotear(conn, "POST", ["admins"]), do: ir(conn, :criar_admin)
  defp rotear(conn, _, _), do: conn |> send_resp(404, "Não encontrado") |> halt()

  defp ir(conn, acao, extra \\ %{}), do: C.call(%{conn | params: Map.merge(conn.params, extra)}, acao)
end
