defmodule Nucleo.Conexao do
  @moduledoc """
  Ciclo de vida da sessao do canal por tenant (uma sessao por tenant: o laco e nomeado pelo tenant).
  `conectar/2` sobe o laco (e com ele o canal); `estado/1` le o estado publicado (inclui o QR); `encerrar/1` derruba;
  `reparear/2` guarda as credenciais num backup datado e sobe de novo pedindo QR.
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
  Pareia de novo (aparelho removido no celular, credenciais mortas): derruba o laco, MOVE a pasta de credenciais do tenant para
  `<sessoes>/_backup/<tenant>-AAAAMMDD-HHMMSS` (nunca apaga; so a pasta deste tenant) e sobe o canal, que sem credenciais pede QR.
  """
  def reparear(tenant, opts \\ []) do
    encerrar(tenant)
    guardar_credenciais(tenant)
    conectar(tenant, opts)
  end

  defp guardar_credenciais(tenant) do
    pasta = Path.join(raiz(), tenant)

    if Path.basename(tenant) == tenant and match?({:ok, [_ | _]}, File.ls(pasta)) do
      base = Path.join([raiz(), "_backup", "#{tenant}-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}"])
      File.mkdir_p!(Path.dirname(base))
      File.rename!(pasta, livre(base, base, 1))
    end

    :ok
  end

  # destino que ainda nao existe (dois backups no mesmo segundo ganham -2, -3...)
  defp livre(base, candidato, n), do: if(File.exists?(candidato), do: livre(base, "#{base}-#{n + 1}", n + 1), else: candidato)

  defp raiz, do: Application.get_env(:nucleo, :sessoes_raiz, "/opt/modular-agentes-data/amarula")

  @doc """
  Desvincula o tenant do WhatsApp: derruba o laco e apaga a pasta da sessao (credenciais do aparelho pareado).
  O aparelho ainda aparece em "aparelhos conectados" no celular ate a pessoa remover la. Nada na Meta e tocado.
  """
  def desvincular(tenant) do
    encerrar(tenant)
    File.rm_rf!(Path.join(raiz(), tenant))
    :ok
  end
end
