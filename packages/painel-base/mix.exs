defmodule PPainelBase.MixProject do
  use Mix.Project
  @version "1.3.0"

  # Dev local (NUCLEO_LOCAL=1, posto pelo mix.exs da raiz): path. No cliente: git + sparse + tag, sem override.
  defp nucleo do
    if System.get_env("NUCLEO_LOCAL"),
      do: {:nucleo, path: "../nucleo"},
      else: {:nucleo, git: System.get_env("NUCLEO_GIT", "https://github.com/Pteusz/modular-agentes.git"), sparse: "packages/nucleo", tag: System.get_env("NUCLEO_TAG", "nucleo-1.1.0")}
  end

  # Versoes exatas aprovadas. Oban 2.24.1 tambem esta aprovada, mas so entra quando houver trabalho em segundo plano (monitor, 4.5).
  def project,
    do: [
      app: :painel_base,
      version: @version,
      elixir: "~> 1.19",
      deps: [
        nucleo(),
        {:phoenix, "== 1.8.15"},
        {:phoenix_live_view, "== 1.2.12"},
        {:bandit, "== 1.12.5"},
        # runtime: false -> o painel sobe o Swoosh sozinho, depois de desligar o api_client (so SMTP; sem hackney)
        {:swoosh, "== 1.28.1", runtime: false},
        {:gen_smtp, "== 1.3.0"},
        {:qr_code, "== 3.2.0"},
        {:jason, "== 1.4.5"}
      ]
    ]

  def application,
    do: [extra_applications: [:logger, :crypto, :ssl, :public_key], mod: {PainelBase.Application, []}, env: [nucleo_pacote: true]]
end
