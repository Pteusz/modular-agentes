defmodule Trafego.Config do
  @moduledoc """
  Configuracao do pacote (nada fixo no codigo). Valores padrao ficam no env da aplicacao (mix.exs) e podem ser trocados por
  config da instancia; segredos vem SO de variaveis de ambiente (/opt/modular-agentes-data), nunca do repositorio:
    * OPENAI_API_KEY, TRAFEGO_CIFRA_CHAVES / TRAFEGO_CIFRA_ATUAL (ver Trafego.Cifra)
    * TRAFEGO_COTACAO_USD_BRL (cotacao manual ate a 4.5), TRAFEGO_MIDIA_DIR (criativos recebidos)
  """

  def meta, do: Application.get_env(:trafego, :meta, [])
  def meta(chave, padrao \\ nil), do: Keyword.get(meta(), chave, padrao)

  def openai, do: Application.get_env(:trafego, :openai, [])
  def openai(chave, padrao \\ nil), do: Keyword.get(openai(), chave, padrao)

  def openai_chave, do: System.get_env("OPENAI_API_KEY")

  def criativo(chave, padrao \\ nil), do: Application.get_env(:trafego, :criativo, []) |> Keyword.get(chave, padrao)

  @doc "Tabela de precos em USD por milhao de tokens: %{modelo => {entrada, saida}}."
  def preco_usd_por_milhao, do: Application.get_env(:trafego, :preco_usd_por_milhao, %{})

  @doc "Cotacao USD->BRL manual (config ou env). nil se nao informada."
  def cotacao_usd_brl do
    case Application.get_env(:trafego, :cotacao_usd_brl) || System.get_env("TRAFEGO_COTACAO_USD_BRL") do
      n when is_number(n) and n > 0 ->
        n

      s when is_binary(s) ->
        case Float.parse(String.replace(s, ",", ".")) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def midia_dir,
    do: Application.get_env(:trafego, :midia_dir) || System.get_env("TRAFEGO_MIDIA_DIR") || Path.join(System.tmp_dir!(), "trafego_midia")
end
