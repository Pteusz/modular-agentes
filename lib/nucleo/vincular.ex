defmodule Nucleo.Vincular do
  @moduledoc "Vincular tenant a automacao+versao+canal. Idempotente; cada mudanca real vira evento."
  alias Nucleo.Registro

  @doc "Vincula automacao (modulo com o contrato) checando compatibilidade ANTES de gravar; recusa registra evento."
  def vincular(tenant, mod, canal, camada) when is_atom(mod) do
    case Nucleo.Automacao.compativel(mod, camada) do
      :ok ->
        vincular(tenant, inspect(mod), mod.versao(), canal)

      {:error, motivos} ->
        Registro.criar_tenant(tenant)
        Registro.evento(tenant, "vinculo_recusado", %{"automacao" => inspect(mod), "motivos" => motivos})
        {:error, {:incompativel, motivos}}
    end
  end

  def vincular(tenant, automacao, versao, canal) do
    canal = inspect(canal)
    Registro.criar_tenant(tenant)

    case Registro.vinculo(tenant, automacao) do
      %{versao: ^versao, canal: ^canal} ->
        {:ok, :ja_vinculado}

      anterior ->
        :ok = Registro.gravar_vinculo(tenant, automacao, versao, canal)
        tipo = if anterior, do: "vinculo_atualizado", else: "vinculado"
        Registro.evento(tenant, tipo, %{"automacao" => automacao, "versao" => versao, "canal" => canal})
        {:ok, if(anterior, do: :atualizado, else: :criado)}
    end
  end
end
