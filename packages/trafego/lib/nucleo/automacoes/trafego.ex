defmodule Nucleo.Automacoes.Trafego do
  @moduledoc """
  Automacao de trafego pago (base generica). Contrato Nucleo.Automacao 1.0, versao de contrato MAJOR.MINOR.
  Plataforma de anuncios e provedor de IA ficam atras de contratos proprios (Trafego.Plataforma, Trafego.IA);
  o encaixe com o nucleo e o mesmo da Eco. Ponto de entrada: Trafego.Agente.processar/2.
  """
  @behaviour Nucleo.Automacao

  @impl Nucleo.Automacao
  def versao, do: Application.spec(:trafego, :vsn) |> to_string()

  @impl Nucleo.Automacao
  def contrato,
    do: %{versao: "1.0", oferece: %{"trafego" => "1.0"}, exige: %{"registro" => "1.0", "gancho" => "1.0", "canal.texto" => "1.0"}}

  @doc "Verificador decidivel: o que a plataforma devolveu bate com o plano. ctx: %{plano, campanha, conta_id}."
  @impl Nucleo.Automacao
  def referencial do
    igual = fn campo -> fn %{plano: p, campanha: c} -> p[campo] == c[campo] end end

    %{
      tipo: :decidivel,
      regras: [
        %{nome: :status_pausada, ok?: fn %{campanha: c} -> c["status"] == "PAUSADA" end},
        %{nome: :conta_igual, ok?: fn %{campanha: c, conta_id: id} -> c["conta_id"] == id end},
        %{nome: :destino_igual, ok?: igual.("destino")},
        %{nome: :orcamento_diario_igual, ok?: igual.("orcamento_diario")},
        %{nome: :teto_igual, ok?: igual.("teto_total")},
        %{nome: :janela_igual, ok?: igual.("janela")},
        %{nome: :publico_igual, ok?: fn %{plano: p, campanha: c} -> get_in(c, ["conjuntos", Access.at(0), "publico"]) == p["publico"] end},
        %{nome: :criativo_igual, ok?: fn %{plano: p, campanha: c} -> get_in(c, ["conjuntos", Access.at(0), "anuncios", Access.at(0), "criativo"]) == p["criativo"] end}
      ]
    }
  end

  @impl Nucleo.Automacao
  def retencao,
    do: [
      %{chave: "trafego_conta", leitura: :ultimo},
      %{chave: "trafego_atual", leitura: :ultimo},
      %{chave: "trafego_seq", leitura: :ultimo},
      %{chave: "aprendizado", leitura: :historico}
    ]

  @impl Nucleo.Automacao
  def aprovacao, do: [:criar_campanha, :editar_campanha, :pausar_campanha]
end
