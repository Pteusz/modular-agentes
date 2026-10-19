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

  # Leitura rapida (opcional na fonte): o painel abre com o que ja foi guardado e atualiza em segundo plano.
  @doc "Ultima foto guardada da home (sem tocar na plataforma) ou nil."
  def foto(tenant), do: if(exporta?(:foto, 1), do: mod().foto(tenant))

  @doc "Atualiza a foto da home (pode usar cache curto). {:ok, foto} | {:error, motivo}"
  def atualizar_resumo(tenant) do
    if exporta?(:atualizar_resumo, 1) do
      mod().atualizar_resumo(tenant)
    else
      with {:ok, lista} <- campanhas(tenant), do: {:ok, %{"campanhas_total" => length(lista)}}
    end
  end

  @doc "Campanhas ja em cache fresco ({:ok, lista}) ou :miss; nunca toca na plataforma."
  def campanhas_em_cache(tenant), do: if(exporta?(:campanhas_em_cache, 1), do: mod().campanhas_em_cache(tenant), else: :miss)

  defp exporta?(f, a), do: Code.ensure_loaded?(mod()) and function_exported?(mod(), f, a)

  @doc "Cadastro manual da conta de anuncios (oferta trafego.painel 1.1): valida na plataforma e guarda cifrado. {:ok, _} | {:error, motivo}"
  def cadastrar_conta(tenant, cred), do: mod().cadastrar_conta(tenant, cred)

  @doc "Remove a conta de anuncios do tenant (nada na plataforma e tocado)."
  def remover_conta(tenant), do: mod().remover_conta(tenant)
end
