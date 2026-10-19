defmodule Nucleo.Canal.Simulado do
  @moduledoc """
  Canal simulado com o mesmo contrato; `injetar/3` imita mensagem entrando, `injetar_midia/3` imita midia.
  Com `opts[:qr]` fica aguardando pareamento (`parear/1`) e publica o QR; sem ele ja nasce conectado.
  """
  @behaviour Nucleo.Canal
  use GenServer
  alias Nucleo.Canal.Estado

  @impl Nucleo.Canal
  def iniciar(tenant, destino, opts), do: GenServer.start_link(__MODULE__, {tenant, destino, opts})
  @impl Nucleo.Canal
  def enviar_texto(ref, texto), do: GenServer.call(ref, {:enviar, texto})
  @impl Nucleo.Canal
  def enviar_audio(ref, bytes, opts), do: GenServer.call(ref, {:enviar_audio, bytes, opts})

  def injetar(ref, :proprio, texto), do: GenServer.cast(ref, {:entra, texto})
  def injetar(ref, :terceiro, _texto), do: GenServer.cast(ref, :ignora)
  def injetar_midia(ref, :proprio, msg), do: GenServer.cast(ref, {:midia, msg})
  def injetar_midia(ref, :terceiro, _msg), do: GenServer.cast(ref, :ignora)
  def parear(ref), do: GenServer.call(ref, :parear)
  def enviadas(ref), do: GenServer.call(ref, :enviadas)
  @doc "Notas de voz enviadas: [{bytes, opts}]."
  def audios(ref), do: GenServer.call(ref, :audios)
  @doc "Tudo que saiu, em ordem: [{:texto, t} | {:audio, bytes}]."
  def sequencia(ref), do: GenServer.call(ref, :sequencia)
  def ignoradas(ref), do: GenServer.call(ref, :ignoradas)

  @impl GenServer
  def init({tenant, destino, opts}) do
    Estado.publicar(tenant, :conectando)

    case opts[:qr] do
      qr when is_binary(qr) -> Estado.publicar(tenant, {:qr, qr})
      _ -> Estado.publicar(tenant, :conectado)
    end

    {:ok, %{tenant: tenant, destino: destino, env: [], aud: [], seq: [], ign: 0}}
  end

  @impl GenServer
  def handle_call({:enviar, t}, _, s), do: {:reply, :ok, %{s | env: s.env ++ [t], seq: s.seq ++ [{:texto, t}]}}
  def handle_call({:enviar_audio, b, o}, _, s), do: {:reply, :ok, %{s | aud: s.aud ++ [{b, o}], seq: s.seq ++ [{:audio, b}]}}
  def handle_call(:audios, _, s), do: {:reply, s.aud, s}
  def handle_call(:sequencia, _, s), do: {:reply, s.seq, s}
  def handle_call(:enviadas, _, s), do: {:reply, s.env, s}
  def handle_call(:ignoradas, _, s), do: {:reply, s.ign, s}
  def handle_call(:parear, _, s), do: {:reply, Estado.publicar(s.tenant, :conectado), s}

  @impl GenServer
  def handle_cast({:entra, t}, s) do
    send(s.destino, {:mensagem, t})
    {:noreply, s}
  end

  def handle_cast({:midia, msg}, s) do
    send(s.destino, {:midia, msg})
    {:noreply, s}
  end

  def handle_cast(:ignora, s), do: {:noreply, %{s | ign: s.ign + 1}}
end
