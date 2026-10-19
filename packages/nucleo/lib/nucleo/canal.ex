defmodule Nucleo.Canal do
  @moduledoc """
  Contrato do canal (uma sessao por tenant). O canal so entrega ao destino mensagens do chat do
  proprio usuario, como `{:mensagem, texto}` ao pid `destino`; terceiros/grupos sao descartados nele.
  """
  @callback iniciar(tenant :: String.t(), destino :: pid(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback enviar_texto(ref :: term(), texto :: String.t()) :: :ok | {:error, term()}
  @doc """
  Nota de voz (nucleo 1.5.0, opcional: canal sem ele so recebe texto). `bytes` = audio ogg/opus; opts: `:mime` (padrao
  "audio/ogg; codecs=opus") e `:segundos` (duracao; o WhatsApp precisa dela).
  """
  @callback enviar_audio(ref :: term(), bytes :: binary(), opts :: keyword()) :: :ok | {:error, term()}
  @optional_callbacks enviar_audio: 3
end
