import Config

if config_env() == :test, do: config(:trafego, oban_opts: [testing: :inline], provedor_ia: Trafego.IA.Falso)
