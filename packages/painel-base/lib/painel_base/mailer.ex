defmodule PainelBase.Mailer do
  @moduledoc """
  Envio de e-mail (Swoosh + gen_smtp). Producao: SMTP da Hostinger (smtp.hostinger.com, 465, SSL/TLS) com usuario e senha SO de variaveis
  de ambiente. Sem usuario/senha nao tenta enviar ({:error, :smtp_nao_configurado}). Em teste, `config :painel_base, :mailer_adapter` troca o adaptador.
  """
  use Swoosh.Mailer, otp_app: :painel_base

  @doc "Configuracao do SMTP vinda do ambiente (contem a senha: nao logar)."
  def config_smtp do
    host = System.get_env("PAINEL_SMTP_HOST") || "smtp.hostinger.com"

    [
      adapter: Swoosh.Adapters.SMTP,
      relay: host,
      port: porta(),
      ssl: true,
      tls: :never,
      auth: :always,
      username: System.get_env("PAINEL_SMTP_USUARIO"),
      password: System.get_env("PAINEL_SMTP_SENHA"),
      no_mx_lookups: true,
      retries: 1,
      sockopts: tls_opts(host)
    ]
  end

  @doc "O mesmo, sem a senha (para log e tela)."
  def config_smtp_publica, do: config_smtp() |> Keyword.delete(:password) |> Keyword.delete(:sockopts)

  def remetente, do: System.get_env("PAINEL_SMTP_REMETENTE") || System.get_env("PAINEL_SMTP_USUARIO")

  @doc "Entrega. opts: `config:` (keyword Swoosh completo, p.ex. servidor local de teste) | `cfg_env: true` (ignora a troca de adaptador de teste)."
  def entregar(email, opts \\ []) do
    adaptador = Application.get_env(:painel_base, :mailer_adapter)

    cond do
      opts[:config] -> deliver(email, opts[:config])
      adaptador && !opts[:cfg_env] -> deliver(email, adapter: adaptador)
      true -> via_env(email)
    end
  end

  defp via_env(email) do
    cfg = config_smtp()

    if blank?(cfg[:username]) or blank?(cfg[:password]),
      do: {:error, :smtp_nao_configurado},
      else: deliver(email, cfg)
  end

  defp blank?(v), do: v in [nil, ""]

  defp porta do
    case Integer.parse(System.get_env("PAINEL_SMTP_PORTA") || "") do
      {n, ""} -> n
      _ -> 465
    end
  end

  # verifica o certificado do servidor (cadeia + nome); nada de verify_none
  # verify_peer sempre, com os CAs do sistema. O gen_smtp injeta {depth, 0} nas conexoes SSL e isso derruba cadeias com
  # intermediarias (Hostinger/Sectigo: :max_path_length_reached); depth: 10 vem antes dele.
  defp tls_opts(host),
    do: [
      depth: 10,
      versions: [:"tlsv1.2", :"tlsv1.3"],
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
end
