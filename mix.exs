defmodule Nucleo.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :nucleo,
      version: "0.1.0",
      elixir: "~> 1.19",
      test_pattern: "etapa1_test.exs",
      deps: [{:amarula, "== 0.5.10"}, {:postgrex, "== 0.22.4"}, {:jason, "== 1.4.5"}]
    ]

  def application, do: [extra_applications: [:logger], mod: {Nucleo.Application, []}]
end
