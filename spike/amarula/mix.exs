defmodule SpikeAmarula.MixProject do
  use Mix.Project
  def project, do: [app: :spike_amarula, version: "0.0.0", elixir: "~> 1.19", deps: [{:amarula, "== 0.5.10"}]]
  def application, do: [extra_applications: [:logger]]
end
