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
end
