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
    do: %{
      versao: "1.5",
      oferece: %{"trafego" => "1.0", "trafego.painel" => "1.1", "trafego.equipe" => "1.0", "trafego.monitor" => "1.0", "trafego.iara" => "1.0"},
      exige: %{"registro" => "1.0", "gancho" => "1.0", "canal.texto" => "1.0"}
    }

  # a Meta devolve "act_<id>"; o tenant guarda so o numero (ou com act_): compara sem o prefixo
  defp sem_act(id), do: id |> to_string() |> String.replace_prefix("act_", "")

  @doc "Verificador decidivel: o que a plataforma devolveu bate com o plano. ctx: %{plano, campanha, conta_id}."
  @impl Nucleo.Automacao
  def referencial do
    igual = fn campo -> fn %{plano: p, campanha: c} -> p[campo] == c[campo] end end

    %{
      tipo: :decidivel,
      regras: [
        %{nome: :status_pausada, ok?: fn %{campanha: c} -> c["status"] == "PAUSADA" end},
        %{nome: :conta_igual, ok?: fn %{campanha: c, conta_id: id} -> sem_act(c["conta_id"]) == sem_act(id) end},
        %{nome: :destino_igual, ok?: igual.("destino")},
        %{nome: :orcamento_diario_igual, ok?: igual.("orcamento_diario")},
        %{nome: :teto_igual, ok?: igual.("teto_total")},
        %{nome: :janela_igual, ok?: igual.("janela")},
        %{nome: :publico_igual, ok?: fn %{plano: p, campanha: c} -> get_in(c, ["conjuntos", Access.at(0), "publico"]) == p["publico"] end},
        %{nome: :criativo_igual, ok?: fn %{plano: p, campanha: c} -> get_in(c, ["conjuntos", Access.at(0), "anuncios", Access.at(0), "criativo"]) == p["criativo"] end}
      ]
    }
  end

  @doc "Prefixo das mensagens da Iara no WhatsApp e no painel (Nucleo.Laco usa; padrao dos outros agentes: \"[agente] \")."
  def prefixo, do: "[Iara] "

  @doc "Conversa do corretor (texto do chat dele consigo mesmo) -> resposta do agente. O laco chama; ver Nucleo.Laco."
  def conversar(tenant, texto) do
    tenant |> Trafego.Agente.processar_mensagens(texto) |> Trafego.Iara.Texto.limpar_saida() |> Trafego.Voz.aplicar_seguro(tenant, "texto") |> Trafego.Iara.Texto.limpar_saida()
  end

  @doc "Janela (ms) para juntar mensagens do corretor em sequencia num so turno (Nucleo.Laco). Config `:trafego, :junta_ms`; padrao 3000, 0 desliga."
  def junta_ms, do: Application.get_env(:trafego, :junta_ms, 3000)

  @doc "Midia que chegou pelo canal (criativo pelo WhatsApp)."
  def midia(tenant, msg) do
    origem = if match?(%Amarula.Msg{content: %Amarula.Content.Media{kind: :audio}}, msg), do: "audio", else: "texto"
    tenant |> Trafego.Agente.receber_midia_mensagens(msg) |> Trafego.Iara.Texto.limpar_saida() |> Trafego.Voz.aplicar_seguro(tenant, origem) |> Trafego.Iara.Texto.limpar_saida()
  end

  @impl Nucleo.Automacao
  def retencao,
    do: [
      %{chave: "trafego_conta", leitura: :ultimo},
      %{chave: "trafego_atual", leitura: :ultimo},
      %{chave: "trafego_seq", leitura: :ultimo},
      %{chave: "proposta_seq", leitura: :ultimo},
      %{chave: "aprendizado", leitura: :historico},
      %{chave: "iara_perfil", leitura: :ultimo}
    ]

  @impl Nucleo.Automacao
  def aprovacao, do: [:criar_campanha, :editar_campanha, :pausar_campanha, :ativar_campanha]
end
