defmodule PainelBase.Config do
  @moduledoc """
  Configuracao do painel. Segredos (SECRET_KEY_BASE, senha do SMTP) vem SO do ambiente (/opt/modular-agentes-data/painel.env), nunca do repositorio.
    * PAINEL_SERVIDOR=1 sobe o servidor HTTP; sem isso o pacote carrega mas nao escuta porta (ex.: mix test, mix painel.convidar).
    * PAINEL_PORTA (4100), PAINEL_IP (ip de escuta, padrao 127.0.0.1; atras do nginx em Docker use o IP do gateway da rede), PAINEL_HOST (dominio publico),
      PAINEL_URL_BASE (https://dominio, usada nos links dos e-mails), SECRET_KEY_BASE (>= 64 caracteres, obrigatoria quando serve).
    * PAINEL_SMTP_HOST (smtp.hostinger.com), PAINEL_SMTP_PORTA (465), PAINEL_SMTP_USUARIO, PAINEL_SMTP_SENHA, PAINEL_SMTP_REMETENTE.
  """

  def porta, do: env_int("PAINEL_PORTA", 4100)
  def host, do: System.get_env("PAINEL_HOST") || "localhost"
  def url_base, do: String.trim_trailing(System.get_env("PAINEL_URL_BASE") || "http://localhost:#{porta()}", "/")

  @doc "Monta a config do Endpoint a partir do ambiente (antes de ele subir)."
  def preparar_endpoint do
    servir = System.get_env("PAINEL_SERVIDOR") == "1"
    segredo = System.get_env("SECRET_KEY_BASE")

    if servir and (not is_binary(segredo) or byte_size(segredo) < 64),
      do: raise("SECRET_KEY_BASE ausente ou curta (minimo 64 caracteres) em /opt/modular-agentes-data/painel.env")

    host = host()
    publico = host != "localhost"

    base = [
      url: [host: host, scheme: if(publico, do: "https", else: "http"), port: if(publico, do: 443, else: porta())],
      # HTTP/2 desligado: o nginx fala HTTP/1.1 com o app (ver advisories EEF-CVE-2026-105659/105660 do Bandit 1.12.5)
      http: [ip: ip(), port: porta(), http_2_options: [enabled: false]],
      adapter: Bandit.PhoenixAdapter,
      server: servir,
      secret_key_base: segredo || Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false),
      check_origin: if(publico, do: ["https://" <> host], else: ["//localhost", "//127.0.0.1"]),
      pubsub_server: PainelBase.PubSub,
      live_view: [signing_salt: "painel-lv-v1"],
      render_errors: [formats: [html: PainelBase.ErroHTML], layout: false]
    ]

    atual = Application.get_env(:painel_base, PainelBase.Endpoint, [])
    Application.put_env(:painel_base, PainelBase.Endpoint, Keyword.merge(base, atual))
  end

  defp ip do
    case System.get_env("PAINEL_IP") do
      nil -> {127, 0, 0, 1}
      s -> with {:ok, ip} <- :inet.parse_address(String.to_charlist(s)), do: ip
    end
  end

  defp env_int(k, padrao) do
    case Integer.parse(System.get_env(k) || "") do
      {n, ""} -> n
      _ -> padrao
    end
  end
end
