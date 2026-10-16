defmodule PNucleo.MixProject do
  use Mix.Project
  @version "1.0.0"

  def project,
    do: [
      app: :nucleo,
      version: @version,
      elixir: "~> 1.19",
      deps: [{:amarula, "== 0.5.10"}, {:postgrex, "== 0.22.4"}, {:jason, "== 1.4.5"}]
    ]

  def application,
    do: [extra_applications: [:logger], mod: {Nucleo.Application, []}, env: [nucleo_pacote: true]]
end
