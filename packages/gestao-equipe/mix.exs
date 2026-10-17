defmodule PGestaoEquipe.MixProject do
  use Mix.Project
  @version "1.0.0"

  # Dev local (NUCLEO_LOCAL=1, posto pelo mix.exs da raiz): path. No cliente: git + sparse + tag, sem override.
  defp nucleo do
    if System.get_env("NUCLEO_LOCAL"),
      do: {:nucleo, path: "../nucleo"},
      else: {:nucleo, git: System.get_env("NUCLEO_GIT", "https://github.com/Pteusz/modular-agentes.git"), sparse: "packages/nucleo", tag: System.get_env("NUCLEO_TAG", "nucleo-1.2.0")}
  end

  # O painel-base e a casca (login, convite, layout). O trafego NAO e dependencia: a gestao o le so pela oferta "trafego.equipe" (GestaoEquipe.Fonte).
  defp painel_base do
    if System.get_env("NUCLEO_LOCAL"),
      do: {:painel_base, path: "../painel-base"},
      else: {:painel_base, git: System.get_env("NUCLEO_GIT", "https://github.com/Pteusz/modular-agentes.git"), sparse: "packages/painel-base", tag: System.get_env("PAINEL_BASE_TAG", "painel-base-1.1.0")}
  end

  def project, do: [app: :gestao_equipe, version: @version, elixir: "~> 1.19", deps: [nucleo(), painel_base(), {:jason, "== 1.4.5"}]]

  def application, do: [extra_applications: [:logger], mod: {GestaoEquipe.Application, []}, env: [nucleo_pacote: true]]
end
