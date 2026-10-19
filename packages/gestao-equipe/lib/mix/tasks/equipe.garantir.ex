defmodule Mix.Tasks.Equipe.Garantir do
  @shortdoc "Vincula o tenant PROPRIO de um dono/admin (painel + trafego), sem apagar nada: mix equipe.garantir EMAIL"
  @moduledoc """
  Para o dono que ja existe (ex.: o tenant `mateus`, que so tinha o esqueleto): acrescenta os vinculos do painel-base e do trafego ao
  tenant que ele ja usa. Idempotente; estado, eventos e a sessao do WhatsApp do tenant ficam como estao.
  """
  use Mix.Task

  def run([email]) do
    Mix.Task.run("app.start")

    case PainelBase.Usuarios.por_email(email) do
      nil ->
        Mix.raise("usuario nao encontrado: #{email}")

      u ->
        case GestaoEquipe.garantir_tenant(u) do
          :ok -> Mix.shell().info("Tenant #{u.tenant_id} vinculado (painel e trafego) para #{email}.")
          {:error, e} -> Mix.raise("nao vinculou: #{inspect(e)}")
        end
    end
  end

  def run(_), do: Mix.raise("uso: mix equipe.garantir EMAIL")
end
