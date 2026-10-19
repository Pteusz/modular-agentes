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

  def audio(chave, padrao \\ nil), do: Application.get_env(:trafego, :audio, []) |> Keyword.get(chave, padrao)

  @doc "Tabela de precos de transcricao em USD por minuto: %{modelo => preco}."
  def preco_usd_por_minuto, do: Application.get_env(:trafego, :preco_usd_por_minuto, %{})

  @doc "Voz da Iara (TTS): modelo, voz, formato, chars_por_segundo (estimativa de duracao), max_chars, instrucoes."
  def voz(chave, padrao \\ nil), do: Application.get_env(:trafego, :voz, []) |> Keyword.get(chave, padrao)

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

  @doc "Teto mensal de custo de IA por corretor, em R$ (aviso a 80%, bloqueio a 100%). Padrao R$ 50; env TRAFEGO_TETO_IA_BRL."
  def teto_ia_brl, do: numero(Application.get_env(:trafego, :teto_ia_brl) || System.get_env("TRAFEGO_TETO_IA_BRL")) || 50.0

  @doc "Teto total maximo de um plano nesta instalacao, em centavos. Padrao R$ 5.000; env TRAFEGO_TETO_MAX_BRL (em R$)."
  def teto_max_centavos do
    case Application.get_env(:trafego, :teto_max_centavos) do
      n when is_integer(n) and n > 0 -> n
      _ -> if(v = numero(System.get_env("TRAFEGO_TETO_MAX_BRL")), do: round(v * 100), else: 500_000)
    end
  end

  @doc "Janela padrao sugerida pela Iara (dias a partir de hoje). Padrao 30."
  def janela_padrao_dias, do: Application.get_env(:trafego, :janela_padrao_dias, 30)

  @doc "Custo maximo por resultado sugerido quando o corretor nao diz, em centavos. Padrao R$ 15."
  def custo_resultado_padrao_centavos, do: Application.get_env(:trafego, :custo_resultado_padrao_centavos, 1500)

  @doc "Horas minimas entre relatorios de um mesmo plano. Padrao 24."
  def relatorio_horas, do: Application.get_env(:trafego, :relatorio_horas, 24)

  def feed_fonte, do: Application.get_env(:trafego, :feed_fonte, "wp_produtos")
  def feed_dir, do: Application.get_env(:trafego, :feed_dir) || System.get_env("TRAFEGO_FEED_DIR") || "/opt/modular-agentes-data/feed"
  def ptax_base_url, do: Application.get_env(:trafego, :ptax_base_url, "https://olinda.bcb.gov.br")

  defp numero(n) when is_number(n) and n > 0, do: n

  defp numero(s) when is_binary(s) do
    case Float.parse(String.replace(s, ",", ".")) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp numero(_), do: nil

  def midia_dir,
    do: Application.get_env(:trafego, :midia_dir) || System.get_env("TRAFEGO_MIDIA_DIR") || Path.join(System.tmp_dir!(), "trafego_midia")
end
