defmodule Trafego.Plataforma do
  @moduledoc """
  Contrato de plataforma de anuncios. "Campanha" = campanha + conjunto + anuncio (mapa de chaves string).
  `cred` e a credencial do TENANT (%{"conta_id", "token"}), nunca vinda do provedor de IA.
  Toda campanha e criada PAUSADA. Ativar (4.5) so existe como operacao propria, chamada apenas por Trafego.Ativacao depois de uma
  proposta confirmada pelo corretor; editar_campanha nunca ativa.
  """
  @type cred :: %{String.t() => String.t()}
  @callback validar_credencial(cred) :: {:ok, map} | {:error, term}
  @callback criar_campanha(cred, params :: map) :: {:ok, map} | {:error, term}
  @callback ler_campanha(cred, id :: String.t()) :: {:ok, map} | {:error, term}
  @callback editar_campanha(cred, id :: String.t(), attrs :: map) :: {:ok, map} | {:error, term}
  @callback pausar_campanha(cred, id :: String.t()) :: {:ok, map} | {:error, term}
  @callback ativar_campanha(cred, id :: String.t()) :: {:ok, map} | {:error, term}
  @callback listar_campanhas(cred) :: {:ok, [map]} | {:error, term}
  @doc "Numeros de WhatsApp vinculados a Pagina/conta (so digitos, com 55): a Meta so aceita anunciar com numero vinculado. Leitura, nunca cria nada."
  @callback numeros_vinculados(cred) :: {:ok, [String.t()]} | {:error, term}
  @optional_callbacks numeros_vinculados: 1
  @doc "Metricas dos ultimos `dias` dias de UMA campanha da conta: gasto (centavos), alcance, cliques, mensagens_iniciadas, resultados."
  @callback metricas(cred, id :: String.t(), dias :: pos_integer()) :: {:ok, map} | {:error, term}

  @doc "Adaptador em uso (config :trafego, :plataforma; padrao o simulado)."
  def adaptador do
    case Application.get_env(:trafego, :plataforma) do
      nil -> if System.get_env("TRAFEGO_PLATAFORMA") == "meta", do: Trafego.Plataforma.Meta, else: Trafego.Plataforma.Simulada
      m -> m
    end
  end
end
