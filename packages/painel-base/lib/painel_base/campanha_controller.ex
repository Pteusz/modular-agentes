defmodule PainelBase.CampanhaController do
  use Phoenix.Controller, formats: [:html], layouts: [html: {PainelBase.Layouts, :app}]
  import Plug.Conn
  alias PainelBase.Fonte

  # O id vem da URL, mas a conta vem do tenant da sessao: id de outra conta e "nao encontrada" (404), igual a id que nao existe.
  def show(conn, %{"id" => id}) when is_binary(id) do
    case Fonte.campanha(conn.assigns.usuario.tenant_id, id) do
      {:ok, c} -> render(conn, :show, c: c, ativo: :campanhas)
      _ -> conn |> put_status(404) |> render(:nao_encontrada, ativo: :campanhas)
    end
  end

  def show(conn, _), do: conn |> put_status(404) |> render(:nao_encontrada, ativo: :campanhas)
end

defmodule PainelBase.CampanhaHTML do
  use Phoenix.Component
  import PainelBase.Componentes

  def show(assigns) do
    ~H"""
    <p class="voltar"><a href="/campanhas">← Campanhas</a></p>
    <h1>{@c["nome"]}</h1>
    <p><.estado status={@c["status"]} /></p>
    <section class="cartao">
      <.metricas m={@c["metricas"]} cpr={@c["custo_por_resultado"]} dias={@c["dias"]} />
    </section>
    """
  end

  def nao_encontrada(assigns) do
    ~H"""
    <h1>Campanha não encontrada</h1>
    <p class="apoio">Ela não existe na sua conta. <a href="/campanhas">Ver minhas campanhas</a></p>
    """
  end
end
