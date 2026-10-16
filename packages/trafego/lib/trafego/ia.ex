defmodule Trafego.IA do
  @moduledoc """
  Contrato "provedor de IA" (trocar de modelo/provedor nao muda o dominio). `faixa`: :pequena (ler confirmacao,
  conferir criativo) ou :media (criar/revisar plano). `tarefa`: :planejar | :confirmar.
  Devolve a saida e o uso (modelo, tokens_in, tokens_out) para o evento custo_tokens. O provedor nunca informa id de conta.
  """
  @callback chamar(faixa :: :pequena | :media, tarefa :: atom, entrada :: map) :: {:ok, saida :: map, uso :: map} | {:error, term}

  def provedor, do: Application.get_env(:trafego, :provedor_ia, Trafego.IA.Falso)
end
