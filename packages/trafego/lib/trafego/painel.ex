defmodule Trafego.Painel do
  @moduledoc """
  Leitura para o painel (oferta "trafego.painel" 1.1). Leitura, mais o cadastro/remocao da propria conta de anuncios (4.7); nada aqui cria, edita ou ativa campanha. Toda funcao recebe o TENANT
  da sessao (nunca um id de conta): a conta vem do registro do tenant (Trafego.Acesso). Nao devolve token, nem texto da conversa.
  """
  alias Trafego.{AbaIA, Acesso, Plano}

  @dias 7

  @doc "Plano aguardando confirmacao (a autorizacao e SO no WhatsApp) ou nil."
  def plano_aguardando(tenant) do
    case Plano.atual(tenant) do
      %{"status" => "aguardando_confirmacao"} = p -> p |> Map.put("resumo", Plano.resumo(p)) |> Map.put("prefixo", "[Iara]")
      _ -> nil
    end
  end

  @doc "Campanhas da conta do tenant com metricas dos ultimos 7 dias. {:ok, [campanha]} | {:error, motivo}"
  def campanhas(tenant, dias \\ @dias) do
    with {:ok, lista} <- Acesso.chamar(tenant, :listar_campanhas, []) do
      {:ok, Enum.map(lista, &com_metricas(tenant, &1, dias))}
    end
  end

  @doc "Uma campanha da conta do tenant (outro id, de outra conta, e :nao_encontrada)."
  def campanha(tenant, id, dias \\ @dias) do
    with {:ok, c} <- Acesso.chamar(tenant, :ler_campanha, [id]), do: {:ok, com_metricas(tenant, c, dias)}
  end

  def atividade(tenant), do: AbaIA.projetar(tenant)

  @doc "Cadastro manual pelo proprio usuario (oferta 1.1): valida na plataforma e grava cifrada no tenant da sessao. {:ok, conta_id} | {:error, motivo}"
  def cadastrar_conta(tenant, cred), do: Acesso.cadastrar(tenant, cred)

  @doc "Remove a conta e a foto de sincronizacao do tenant. Nada na plataforma e tocado."
  def remover_conta(tenant), do: Trafego.Equipe.remover_conta(tenant)

  @doc "Conta para tela (token mascarado) ou nil."
  def conta(tenant), do: Acesso.mascarado(tenant)

  def custo_por_resultado(%{"gasto" => g, "resultados" => r}) when is_integer(g) and is_integer(r) and r > 0, do: div(g, r)
  def custo_por_resultado(_), do: nil

  defp com_metricas(tenant, c, dias) do
    m =
      case Acesso.chamar(tenant, :metricas, [c["id"], dias]) do
        {:ok, m} -> m
        _ -> nil
      end

    c |> Map.take(~w(id nome status destino orcamento_diario teto_total janela)) |> Map.merge(%{"metricas" => m, "dias" => dias, "custo_por_resultado" => m && custo_por_resultado(m)})
  end
end
