defmodule PEco.MixProject do
  use Mix.Project
  @version "1.0.0"

  # Dev local (NUCLEO_LOCAL=1, posto pelo mix.exs da raiz): path. No cliente: git + sparse + tag, sem override.
  defp nucleo do
    if System.get_env("NUCLEO_LOCAL"),
      do: {:nucleo, path: "../nucleo"},
      else: {:nucleo, git: System.get_env("NUCLEO_GIT", "https://github.com/Pteusz/modular-agentes.git"), sparse: "packages/nucleo", tag: System.get_env("NUCLEO_TAG", "nucleo-1.0.0")}
  end

  def project, do: [app: :eco, version: @version, elixir: "~> 1.19", deps: [nucleo()]]
  def application, do: [extra_applications: [:logger], env: [nucleo_pacote: true]]
end
