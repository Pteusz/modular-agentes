defmodule Nucleo.Passo do
  @moduledoc """
  Interface de execucao do laco (separada do contrato `Nucleo.Automacao`, que nao muda).
  `passo/2` recebe a entrada e o estado retido lido de volta (chave => ultimo valor | lista de valores,
  conforme `retencao/0`) e devolve a saida, o estado a reter e as acoes pedidas (passam pelo gancho).
  """
  @callback passo(entrada :: String.t(), retido :: map) :: %{saida: String.t() | nil, retido: map, acoes: [{atom, term}]}
end
