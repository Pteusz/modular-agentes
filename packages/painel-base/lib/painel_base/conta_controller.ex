defmodule PainelBase.ContaController do
  @moduledoc "Formularios da tela Conta (conta de anuncios). O tenant e sempre o da sessao; qualquer tenant vindo do formulario e ignorado. Volta para /conta com um codigo fixo na URL (sem valor)."
  use Phoenix.Controller, formats: [:html]
  alias PainelBase.Conta

  def salvar_anuncios(conn, params) do
    case Conta.salvar_anuncios(conn.assigns.usuario, Map.take(params, ~w(token conta_id pagina_id instagram_id))) do
      :ok -> redirect(conn, to: "/conta?aviso=anuncios_salvo")
      {:error, codigo} -> redirect(conn, to: "/conta?erro=#{codigo}")
    end
  end

  def remover_anuncios(conn, _params) do
    Conta.remover_anuncios(conn.assigns.usuario)
    redirect(conn, to: "/conta?aviso=anuncios_removido")
  end
end
