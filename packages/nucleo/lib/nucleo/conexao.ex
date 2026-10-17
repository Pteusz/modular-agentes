defmodule Nucleo.Conexao do
  @moduledoc """
  Ciclo de vida da sessao do canal por tenant (uma sessao por tenant: o laco e nomeado pelo tenant).
  `conectar/2` sobe o laco (e com ele o canal); `estado/1` le o estado publicado (inclui o QR); `encerrar/1` derruba.
  """
  alias Nucleo.{Canal.Estado, Laco}

  def conectar(tenant, opts \\ []) do
    if Enum.any?(Nucleo.Registro.contratos(tenant), &(&1.estado == "desativado")), do: {:error, :desativado}, else: iniciar(tenant, opts)
  end

  defp iniciar(tenant, opts) do
    case Laco.iniciar(tenant, Keyword.update(opts, :canal_opts, [imprimir_qr: false], &Keyword.put_new(&1, :imprimir_qr, false))) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, :ja_conectado, pid}
      {:error, e} -> {:error, e}
    end
  end

  def pid(tenant), do: (case Registry.lookup(Nucleo.LacoReg, tenant) do [{pid, _}] -> pid; _ -> nil end)

  defdelegate estado(tenant), to: Estado, as: :ler
  defdelegate assinar(tenant), to: Estado

  def encerrar(tenant) do
    case pid(tenant) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Nucleo.Lacos, pid)
    end

    Estado.publicar(tenant, :sem_sessao)
  end

  @doc """
  Desvincula o tenant do WhatsApp: derruba o laco e apaga a pasta da sessao (credenciais do aparelho pareado).
  O aparelho ainda aparece em "aparelhos conectados" no celular ate a pessoa remover la. Nada na Meta e tocado.
  """
  def desvincular(tenant) do
    encerrar(tenant)
    File.rm_rf!(Path.join(Application.get_env(:nucleo, :sessoes_raiz, "/opt/modular-agentes-data/amarula"), tenant))
    :ok
  end
end
