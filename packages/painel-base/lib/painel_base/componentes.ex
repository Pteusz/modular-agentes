defmodule PainelBase.Componentes do
  @moduledoc "Pecas de tela compartilhadas. Estado sempre com texto e simbolo (nao so cor); fala do agente em bloco Nevoa com [agente]."
  use Phoenix.Component
  alias PainelBase.Formato

  attr :status, :string, required: true

  def estado(assigns) do
    {rotulo, simbolo} = Formato.status(assigns.status)
    assigns = assign(assigns, rotulo: rotulo, simbolo: simbolo)

    ~H"""
    <span class="estado"><span class="simbolo" aria-hidden="true">{@simbolo}</span> {@rotulo}</span>
    """
  end

  attr :m, :map, default: nil
  attr :cpr, :any, default: nil
  attr :dias, :integer, default: 7

  def metricas(assigns) do
    ~H"""
    <p class="periodo">Últimos {@dias} dias</p>
    <dl :if={@m} class="metricas">
      <div><dt>Gasto</dt><dd>{Formato.brl(@m["gasto"])}</dd></div>
      <div><dt>Alcance</dt><dd>{Formato.numero(@m["alcance"])}</dd></div>
      <div><dt>Cliques</dt><dd>{Formato.numero(@m["cliques"])}</dd></div>
      <div><dt>Mensagens iniciadas</dt><dd>{Formato.numero(@m["mensagens_iniciadas"])}</dd></div>
      <div><dt>Custo por resultado</dt><dd>{if @cpr, do: Formato.brl(@cpr), else: "—"}</dd></div>
    </dl>
    <p :if={!@m} class="apoio">Métricas indisponíveis agora.</p>
    """
  end

  attr :texto, :string, required: true
  attr :prefixo, :string, default: "[agente]"

  def fala_agente(assigns) do
    ~H"""
    <div class="fala"><span class="prefixo">{@prefixo}</span> {@texto}</div>
    """
  end
end
