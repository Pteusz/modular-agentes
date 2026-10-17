defmodule Nucleo.Canal.Estado do
  @moduledoc """
  Estado da conexao do canal por tenant (para telas): :sem_sessao | :conectando | {:qr, texto} | :conectado | :desconectado.
  Guardado so em memoria (o QR e segredo de pareamento: nunca vai para evento nem log). Quem quiser acompanhar chama
  `assinar/1` e recebe `{:canal_estado, tenant, estado}`.
  """
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def ler(tenant), do: Agent.get(__MODULE__, &Map.get(&1, tenant, :sem_sessao))

  def publicar(tenant, :sem_sessao) do
    Agent.update(__MODULE__, &Map.delete(&1, tenant))
    avisar(tenant, :sem_sessao)
  end

  def publicar(tenant, estado) do
    Agent.update(__MODULE__, &Map.put(&1, tenant, estado))
    avisar(tenant, estado)
  end

  def assinar(tenant), do: with({:ok, _} <- Registry.register(Nucleo.EstadoReg, tenant, nil), do: :ok)

  defp avisar(tenant, estado) do
    Registry.dispatch(Nucleo.EstadoReg, tenant, fn entradas -> for {pid, _} <- entradas, do: send(pid, {:canal_estado, tenant, estado}) end)
    :ok
  end
end
