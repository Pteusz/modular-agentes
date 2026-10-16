# Projeto-hospedeiro de desenvolvimento: pacotes por path (no cliente eles vem por git+sparse+tag).
System.put_env("NUCLEO_LOCAL", "1")

defmodule Projeto.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :projeto,
      version: "0.1.0",
      elixir: "~> 1.19",
      test_pattern: "etapa[1234]*_test.exs",
      deps: [{:nucleo, path: "packages/nucleo"}, {:eco, path: "packages/eco"}, {:trafego, path: "packages/trafego"}]
    ]

  def application, do: [extra_applications: [:logger]]
end
