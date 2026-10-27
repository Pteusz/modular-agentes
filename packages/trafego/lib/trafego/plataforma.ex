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
  @doc """
  Lista + metricas em poucas chamadas (OPCIONAL, painel rapido): as campanhas da conta, cada uma com a chave "metricas" (mesmo mapa de `metricas/3`).
  Campanha SEM a chave "metricas" = o lote de metricas falhou; o chamador busca uma a uma (caminho antigo). Erro de credencial volta como erro.
  """
  @callback listar_campanhas_com_metricas(cred, dias :: pos_integer()) :: {:ok, [map]} | {:error, term}
  @doc """
  Saldo da conta de anuncios (leitura, 6.3): %{"tipo" => "pre_pago" | "pos_pago", "saldo" => centavos | nil}. `saldo` so existe em
  conta pre-paga e e nil quando a plataforma nao deixa ler o numero.
  """
  @callback ler_saldo(cred) :: {:ok, map} | {:error, term}
  @optional_callbacks numeros_vinculados: 1, listar_campanhas_com_metricas: 2
  @doc "Metricas dos ultimos `dias` dias de UMA campanha da conta: gasto (centavos), alcance, cliques, mensagens_iniciadas, resultados."
  @callback metricas(cred, id :: String.t(), dias :: pos_integer()) :: {:ok, map} | {:error, term}

  @doc "O adaptador em uso sabe listar campanhas com metricas em lote?"
  def lote? do
    mod = adaptador()
    Code.ensure_loaded?(mod) and function_exported?(mod, :listar_campanhas_com_metricas, 2)
  end

  @doc "Adaptador em uso (config :trafego, :plataforma; padrao o simulado)."
  def adaptador do
    case Application.get_env(:trafego, :plataforma) do
      nil -> if System.get_env("TRAFEGO_PLATAFORMA") == "meta", do: Trafego.Plataforma.Meta, else: Trafego.Plataforma.Simulada
      m -> m
    end
  end
end
