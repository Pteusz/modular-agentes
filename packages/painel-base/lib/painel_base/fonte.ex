defmodule PainelBase.Fonte do
  @moduledoc """
  De onde o painel le os dados do corretor. O contrato do painel-base e `painel` 1.0; a oferta `trafego.painel` 1.0 (Trafego.Painel)
  e a fonte padrao. Resolvida em tempo de execucao: o painel-base nao depende do codigo do trafego.
  Toda funcao recebe o TENANT da sessao, nunca um id de conta vindo da pagina.
  """
  def mod, do: Application.get_env(:painel_base, :fonte, Trafego.Painel)

  def plano_aguardando(tenant), do: mod().plano_aguardando(tenant)
  def campanhas(tenant), do: mod().campanhas(tenant)
  def campanha(tenant, id), do: mod().campanha(tenant, id)
  def atividade(tenant), do: mod().atividade(tenant)
  def conta(tenant), do: mod().conta(tenant)
end
