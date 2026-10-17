defmodule Mix.Tasks.Equipe.Dono do
  @shortdoc "Cria o dono da equipe (convite por e-mail): mix equipe.dono EMAIL \"NOME\""
  @moduledoc """
  Bootstrap do dono (o primeiro papel da equipe). Cria o tenant da equipe (`config :gestao_equipe, :tenant_equipe`, padrao "equipe"),
  convida o e-mail pelo painel-base e marca o usuario como dono. O dono define a senha pelo link do convite. Se o usuario ja existe, so vira dono.
  """
  use Mix.Task

  def run([email, nome]) do
    Mix.Task.run("app.start")
    tenant = Application.get_env(:gestao_equipe, :tenant_equipe, "equipe")
    Nucleo.Registro.criar_tenant(tenant)

    usuario =
      case PainelBase.Usuarios.por_email(email) do
        nil ->
          case PainelBase.Usuarios.convidar(email, nome, tenant) do
            {:ok, u} -> u
            {:error, e} -> Mix.raise("convite nao enviado: #{inspect(e)}")
          end

        u ->
          u
      end

    GestaoEquipe.Papeis.definir_dono(usuario)
    Mix.shell().info("Dono definido: #{email} (tenant #{tenant}). Ele entra pelo link do convite enviado por e-mail.")
  end

  def run(_), do: Mix.raise("uso: mix equipe.dono EMAIL \"NOME\"")
end
