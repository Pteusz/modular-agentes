defmodule Mix.Tasks.Painel.EmailTeste do
  @shortdoc "Manda um e-mail de teste pelo SMTP da Hostinger (config so por ambiente)"
  @moduledoc """
  Uso: mix painel.email_teste DESTINO

  Le PAINEL_SMTP_USUARIO / PAINEL_SMTP_SENHA (e opcionais PAINEL_SMTP_HOST, PAINEL_SMTP_PORTA, PAINEL_SMTP_REMETENTE) do ambiente
  (carregue /opt/modular-agentes-data/painel.env antes; ver scripts/email_teste.sh). Nao imprime a senha.
  """
  use Mix.Task

  @impl true
  def run([destino]) do
    Mix.Task.run("app.start")
    cfg = PainelBase.Mailer.config_smtp_publica()
    Mix.shell().info("SMTP #{cfg[:relay]}:#{cfg[:port]} ssl=#{cfg[:ssl]} usuario=#{cfg[:username] || "(vazio)"}")

    case PainelBase.Mailer.entregar(PainelBase.Emails.teste(destino), cfg_env: true) do
      {:ok, _} -> Mix.shell().info("Enviado para #{destino}. Confira a caixa de entrada (e o spam).")
      {:error, :smtp_nao_configurado} -> Mix.raise("PAINEL_SMTP_USUARIO/PAINEL_SMTP_SENHA vazios: preencha /opt/modular-agentes-data/painel.env")
      {:error, e} -> Mix.raise("falhou: #{inspect(e |> elem(0))}")
    end
  end

  def run(_), do: Mix.raise("uso: mix painel.email_teste DESTINO")
end
