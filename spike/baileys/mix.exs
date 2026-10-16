defmodule SpikeBaileys.MixProject do
  use Mix.Project
  def project, do: [app: :spike_baileys, version: "0.0.0", elixir: "~> 1.19", deps: [{:baileys_ex, "== 0.1.0-alpha.12"}, {:qr_code, "~> 3.2.0"}]]
  def application, do: [extra_applications: [:logger]]
end
