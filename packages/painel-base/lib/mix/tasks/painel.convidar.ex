defmodule Mix.Tasks.Painel.Convidar do
  @shortdoc "Convida um corretor para o painel (envia o e-mail de convite)"
  @moduledoc """
  Uso: mix painel.convidar EMAIL "NOME" TENANT

  Cria o usuario (sem senha) preso ao tenant informado e envia o convite por e-mail (SMTP so por ambiente).
  O tenant tem de existir no registro. O link do convite vale por 7 dias e so serve uma vez.
  """
  use Mix.Task

  @impl true
  def run([email, nome, tenant]) do
    Mix.Task.run("app.start")

    unless Postgrex.query!(Nucleo.Registro, "SELECT 1 FROM tenants WHERE id=$1", [tenant]).num_rows == 1,
      do: Mix.raise("tenant #{inspect(tenant)} nao existe no registro")

    case PainelBase.Usuarios.convidar(email, nome, tenant) do
      {:ok, _} -> Mix.shell().info("Convite enviado para #{email}.")
      {:error, :ja_existe} -> Mix.raise("ja existe um usuario com senha para #{email}")
      {:error, :email_invalido} -> Mix.raise("e-mail invalido")
      {:error, :email_falhou} -> Mix.raise("usuario criado, mas o e-mail nao saiu (SMTP nao configurado em /opt/modular-agentes-data/painel.env?). Rode de novo depois de configurar.")
    end
  end

  def run(_), do: Mix.raise(~s(uso: mix painel.convidar EMAIL "NOME" TENANT))
end
