defmodule Trafego.Plataforma do
  @moduledoc """
  Contrato de plataforma de anuncios. "Campanha" = campanha + conjunto + anuncio (mapa de chaves string).
  `cred` e a credencial do TENANT (%{"conta_id", "token"}), nunca vinda do provedor de IA.
  Nao ha ativar: nesta fase toda campanha e criada e mantida PAUSADA.
  """
  @type cred :: %{String.t() => String.t()}
  @callback validar_credencial(cred) :: {:ok, map} | {:error, term}
  @callback criar_campanha(cred, params :: map) :: {:ok, map} | {:error, term}
  @callback ler_campanha(cred, id :: String.t()) :: {:ok, map} | {:error, term}
  @callback editar_campanha(cred, id :: String.t(), attrs :: map) :: {:ok, map} | {:error, term}
  @callback pausar_campanha(cred, id :: String.t()) :: {:ok, map} | {:error, term}
  @callback listar_campanhas(cred) :: {:ok, [map]} | {:error, term}
  @doc "Metricas dos ultimos `dias` dias de UMA campanha da conta: gasto (centavos), alcance, cliques, mensagens_iniciadas, resultados."
  @callback metricas(cred, id :: String.t(), dias :: pos_integer()) :: {:ok, map} | {:error, term}

  @doc "Adaptador em uso (config :trafego, :plataforma; padrao o simulado)."
  def adaptador, do: Application.get_env(:trafego, :plataforma, Trafego.Plataforma.Simulada)
end
