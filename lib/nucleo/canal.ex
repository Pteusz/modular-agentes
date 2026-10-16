defmodule Nucleo.Canal do
  @moduledoc """
  Contrato do canal (uma sessao por tenant). O canal so entrega ao destino mensagens do chat do
  proprio usuario, como `{:mensagem, texto}` ao pid `destino`; terceiros/grupos sao descartados nele.
  """
  @callback iniciar(tenant :: String.t(), destino :: pid(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback enviar_texto(ref :: term(), texto :: String.t()) :: :ok | {:error, term()}
end
