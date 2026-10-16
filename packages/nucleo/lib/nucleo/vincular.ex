defmodule Nucleo.Vincular do
  @moduledoc "Vincular tenant a automacao+versao+canal. Idempotente; cada mudanca real vira evento. Encaixe checado ao vincular e ao atualizar."
  alias Nucleo.{Automacao, Registro}

  @doc "Vincula automacao (modulo com o contrato) checando compatibilidade ANTES de gravar; recusa registra evento."
  def vincular(tenant, mod, canal, camada) when is_atom(mod) do
    nome = inspect(mod)
    Registro.criar_tenant(tenant)

    case Automacao.compativel(mod, Map.merge(camada, ofertas(tenant, nome, nil))) do
      :ok ->
        gravar(tenant, nome, mod.versao(), canal, mod.contrato())

      {:error, motivos} ->
        Registro.evento(tenant, "vinculo_recusado", %{"automacao" => nome, "motivos" => motivos})
        {:error, {:incompativel, motivos}}
    end
  end

  def vincular(tenant, automacao, versao, canal), do: gravar(tenant, automacao, versao, canal, nil)

  @doc """
  Registra nova versao (modulo `mod`) da automacao `nome` para todos os tenants vinculados a ela, reverificando
  todos os vinculos que a envolvem (a propria exigencia e a exigencia das outras automacoes do tenant sobre o que ela oferece).
  Se algum quebrar, recusa a atualizacao inteira: evento atualizacao_recusada, nada e gravado.
  """
  def atualizar(nome, mod, camada) when is_binary(nome) and is_atom(mod) do
    tenants = Registro.tenants_da(nome)
    quebras = Enum.flat_map(tenants, &quebras(&1, nome, mod, camada))

    if quebras == [] do
      for t <- tenants do
        %{canal: canal} = Registro.vinculo(t, nome)
        gravar(t, nome, mod.versao(), canal, mod.contrato())
      end

      {:ok, tenants}
    else
      for q <- quebras do
        Registro.evento(q.tenant, "atualizacao_recusada", %{
          "automacao" => nome,
          "versao" => mod.versao(),
          "vinculo" => %{"tenant" => q.tenant, "automacao" => q.automacao, "motivos" => q.motivos}
        })
      end

      {:error, {:incompativel, quebras}}
    end
  end

  defp quebras(t, nome, mod, camada) do
    proprio =
      case Automacao.compativel(mod, Map.merge(camada, ofertas(t, nome, nil))) do
        :ok -> []
        {:error, motivos} -> [%{tenant: t, automacao: nome, motivos: motivos}]
      end

    # as outras automacoes do tenant, vistas com a oferta nova no lugar da antiga
    outras =
      for %{automacao: a, contrato: c} <- Registro.contratos(t), a != nome, c != nil,
          fornece = camada |> Map.merge(Automacao.capacidades_nucleo()) |> Map.merge(ofertas(t, a, nome)) |> Map.merge(mod.contrato().oferece),
          motivos = Automacao.nao_atendidas(c["exige"], fornece),
          motivos != [],
          do: %{tenant: t, automacao: a, motivos: motivos}

    proprio ++ outras
  end

  # ofertas dos contratos registrados das automacoes do tenant, exceto `excluir` e `tambem`
  defp ofertas(tenant, excluir, tambem) do
    for %{automacao: a, contrato: c} <- Registro.contratos(tenant), a != excluir, a != tambem, c != nil, reduce: %{} do
      acc -> Map.merge(acc, c["oferece"])
    end
  end

  defp gravar(tenant, automacao, versao, canal, contrato) do
    canal = if is_atom(canal), do: inspect(canal), else: canal
    Registro.criar_tenant(tenant)

    case Registro.vinculo(tenant, automacao) do
      %{versao: ^versao, canal: ^canal} ->
        {:ok, :ja_vinculado}

      anterior ->
        :ok = Registro.gravar_vinculo(tenant, automacao, versao, canal, contrato)
        tipo = if anterior, do: "vinculo_atualizado", else: "vinculado"
        Registro.evento(tenant, tipo, %{"automacao" => automacao, "versao" => versao, "canal" => canal})
        {:ok, if(anterior, do: :atualizado, else: :criado)}
    end
  end
end
