defmodule Trafego.Custo do
  @moduledoc """
  Custo de tokens em R$. Precos por mil tokens (entrada, saida) em R$ por modelo vem de config (:trafego, :preco_brl_por_mil);
  nada fixo no codigo para modelos reais. Cotacao diaria e a fonte dela ficam para a 4.5 (item em aberto, aguarda o Mateus):
  aqui o preco ja e dado em R$ e o modelo falso usa um valor de teste.
  """
  def brl(modelo, tokens_in, tokens_out) do
    {pin, pout} = Map.get(Application.get_env(:trafego, :preco_brl_por_mil, %{}), modelo, {0.01, 0.03})
    Float.round(tokens_in / 1000 * pin + tokens_out / 1000 * pout, 6)
  end
end
