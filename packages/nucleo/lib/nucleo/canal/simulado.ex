defmodule Nucleo.Canal.Simulado do
  @moduledoc "Canal simulado com o mesmo contrato; `injetar/3` imita mensagem entrando."
  @behaviour Nucleo.Canal
  use GenServer

  @impl Nucleo.Canal
  def iniciar(tenant, destino, _opts), do: GenServer.start_link(__MODULE__, {tenant, destino})
  @impl Nucleo.Canal
  def enviar_texto(ref, texto), do: GenServer.call(ref, {:enviar, texto})

  def injetar(ref, :proprio, texto), do: GenServer.cast(ref, {:entra, texto})
  def injetar(ref, :terceiro, _texto), do: GenServer.cast(ref, :ignora)
  def enviadas(ref), do: GenServer.call(ref, :enviadas)
  def ignoradas(ref), do: GenServer.call(ref, :ignoradas)

  @impl GenServer
  def init({_t, destino}), do: {:ok, %{destino: destino, env: [], ign: 0}}
  @impl GenServer
  def handle_call({:enviar, t}, _, s), do: {:reply, :ok, %{s | env: s.env ++ [t]}}
  def handle_call(:enviadas, _, s), do: {:reply, s.env, s}
  def handle_call(:ignoradas, _, s), do: {:reply, s.ign, s}
  @impl GenServer
  def handle_cast({:entra, t}, s) do
    send(s.destino, {:mensagem, t})
    {:noreply, s}
  end

  def handle_cast(:ignora, s), do: {:noreply, %{s | ign: s.ign + 1}}
end
