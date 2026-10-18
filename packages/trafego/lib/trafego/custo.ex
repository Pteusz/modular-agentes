defmodule Trafego.Custo do
  @moduledoc """
  Custo de tokens em R$ por evento. Modelos reais: preco em USD por milhao de tokens (config :preco_usd_por_milhao, da pagina
  oficial de precos) x cotacao USD->BRL (R$ por US$ 1). Cotacao, em ordem: valor explicito em config da aplicacao (:cotacao_usd_brl),
  a cotacao PTAX do Banco Central guardada com a data (Trafego.Cotacao, buscada por dia pelo Oban; falhou a fonte, vale a ultima
  conhecida) e, so como ultimo recurso manual, TRAFEGO_COTACAO_USD_BRL. Sem cotacao ou sem preco do modelo real, o custo e nil
  (nunca inventado). Modelos de teste (provedor falso) usam :preco_brl_por_mil (R$ por mil tokens).
  """
  alias Trafego.{Config, Cotacao}

  def brl(modelo, tokens_in, tokens_out) do
    case Map.fetch(Config.preco_usd_por_milhao(), modelo) do
      {:ok, {pin, pout}} ->
        case cotacao() do
          nil -> nil
          {cotacao, _data} -> Float.round((tokens_in * pin + tokens_out * pout) / 1_000_000 * cotacao, 6)
        end

      :error ->
        {pin, pout} = Map.get(Application.get_env(:trafego, :preco_brl_por_mil, %{}), modelo, {0.01, 0.03})
        Float.round(tokens_in / 1000 * pin + tokens_out / 1000 * pout, 6)
    end
  end

  @doc "{valor, data | nil} da cotacao em uso (data so quando vem da PTAX), ou nil."
  def cotacao do
    cond do
      (v = Application.get_env(:trafego, :cotacao_usd_brl)) && is_number(v) && v > 0 -> {v, nil}
      c = atual_ptax() -> {c.usd_brl, c.data}
      v = Config.cotacao_usd_brl() -> {v, nil}
      true -> nil
    end
  end

  @doc "Cotacao usada para um modelo (nil se o modelo nao e cobrado em USD)."
  def cotacao_usada(modelo), do: if(Map.has_key?(Config.preco_usd_por_milhao(), modelo), do: cotacao())

  @doc "Provedor real sem cotacao: o custo nao seria contado, entao o teto de IA falha fechado."
  def cotacao_ausente? do
    Trafego.IA.provedor() != Trafego.IA.Falso and cotacao() == nil
  end

  defp atual_ptax do
    Cotacao.atual()
  rescue
    _ -> nil
  end
end
