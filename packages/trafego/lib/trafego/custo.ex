defmodule Trafego.Custo do
  @moduledoc """
  Custo de tokens em R$ por evento. Modelos reais: preco em USD por milhao de tokens (config :preco_usd_por_milhao, da pagina
  oficial de precos) x cotacao USD->BRL manual (config/env; cotacao diaria e a fonte dela ficam para a 4.5). Sem cotacao ou sem
  preco do modelo real, o custo e nil (nunca inventado). Modelos de teste (provedor falso) usam :preco_brl_por_mil (R$ por mil tokens).
  """
  alias Trafego.Config

  def brl(modelo, tokens_in, tokens_out) do
    case Map.fetch(Config.preco_usd_por_milhao(), modelo) do
      {:ok, {pin, pout}} ->
        case Config.cotacao_usd_brl() do
          nil -> nil
          cotacao -> Float.round((tokens_in * pin + tokens_out * pout) / 1_000_000 * cotacao, 6)
        end

      :error ->
        {pin, pout} = Map.get(Application.get_env(:trafego, :preco_brl_por_mil, %{}), modelo, {0.01, 0.03})
        Float.round(tokens_in / 1000 * pin + tokens_out / 1000 * pout, 6)
    end
  end
end
