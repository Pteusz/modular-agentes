defmodule Trafego.Gancho do
  @moduledoc """
  Gancho do dominio: NENHUMA alteracao sem confirmacao. Uma alteracao so passa se o plano esta `confirmado`;
  a decisao passa pelo Nucleo.Gancho (config `aprovado_<acao>` do tenant, liberada so durante a chamada e fechada em seguida).
  """
  alias Nucleo.{Gancho, Registro}

  def alterar(tenant, plano, {tipo, _} = acao) do
    chave = %{"aprovado_#{tipo}" => plano != nil and plano["status"] == "confirmado"}
    Registro.config(tenant, chave)

    try do
      Gancho.intercepta(tenant, acao, Nucleo.Automacoes.Trafego.aprovacao())
    after
      Registro.config(tenant, %{"aprovado_#{tipo}" => false})
    end
  end

  @doc """
  Pausa pre-autorizada (sem "sim"): a unica alteracao que nao pede confirmacao, porque pausar so reduz gasto e se desfaz. Passa pelo mesmo
  Nucleo.Gancho (config `aprovado_pausar_campanha` liberada so durante a chamada). Ativar, retomar, criar e editar seguem exigindo plano/proposta confirmados.
  """
  def pausar_autonoma(tenant) do
    Registro.config(tenant, %{"aprovado_pausar_campanha" => true})

    try do
      Gancho.intercepta(tenant, {:pausar_campanha, %{"autonoma" => true}}, Nucleo.Automacoes.Trafego.aprovacao())
    after
      Registro.config(tenant, %{"aprovado_pausar_campanha" => false})
    end
  end
end
