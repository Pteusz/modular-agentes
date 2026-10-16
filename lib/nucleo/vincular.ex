defmodule Nucleo.Vincular do
  @moduledoc "Vincular tenant a automacao+versao+canal. Idempotente; cada mudanca real vira evento."
  alias Nucleo.Registro

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
