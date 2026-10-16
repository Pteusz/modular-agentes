defmodule Nucleo.Canal.Amarula do
  @moduledoc """
  Canal real (Amarula 0.5.10). Sessao em /opt/modular-agentes-data/amarula/<tenant>.
  So entrega mensagens de texto do chat do proprio usuario; sem confirmacao de leitura; nao registra conteudo.
  """
  @behaviour Nucleo.Canal
  use GenServer

  @raiz "/opt/modular-agentes-data/amarula"

  @doc "Decide se uma Amarula.Msg entra no laco (puro; testavel sem rede)."
  def filtrar(msg, own_chat?) do
    if own_chat?.(msg) and msg.type == :text and is_binary(msg.content),
      do: {:entregar, msg.content},
      else: :ignorar
  end

  @impl Nucleo.Canal
  def iniciar(tenant, destino, opts), do: GenServer.start_link(__MODULE__, {tenant, destino, opts})
  @impl Nucleo.Canal
  def enviar_texto(ref, texto), do: GenServer.call(ref, {:enviar, texto}, 30_000)

  @impl GenServer
  def init({tenant, destino, opts}) do
    dir = Keyword.get(opts, :dir, Path.join(@raiz, tenant))
    File.mkdir_p!(dir)
    Amarula.Supervisor.start_link([])

    {:ok, conn} =
      Amarula.new(%{
        profile: String.to_atom(tenant),
        sync_full_history: false,
        sync_history: false,
        storage: {Amarula.Storage.File, root: dir}
      })
      |> Amarula.connect(parent_pid: self())

    {:ok, %{conn: conn, destino: destino, tenant: tenant, aberto: false}}
  end

  @impl GenServer
  def handle_call({:enviar, t}, _from, %{aberto: true, conn: c} = s) do
    {:ok, jid} = Amarula.Address.to_jid(%{Amarula.own_address(c) | device: 0})

    r =
      case Amarula.send_text(c, jid, t) do
        {:ok, _} -> :ok
        other -> {:error, other}
      end

    {:reply, r, s}
  end

  def handle_call({:enviar, _}, _from, s), do: {:reply, {:error, :desconectado}, s}

  @impl GenServer
  def handle_info({:amarula, :connection_update, %{qr: qr}}, s) when is_binary(qr) do
    {:ok, art} = Amarula.render_qr(qr)
    IO.puts("\n#{art}\n[#{s.tenant}] escaneie o QR (WhatsApp > Aparelhos conectados)")
    {:noreply, s}
  end

  def handle_info({:amarula, :connection_update, %{connection: :open}}, s), do: {:noreply, %{s | aberto: true}}
  def handle_info({:amarula, :connection_update, %{connection: :close}}, s), do: {:noreply, %{s | aberto: false}}

  def handle_info({:amarula, :messages_upsert, %{messages: msgs}}, s) do
    for m <- msgs do
      case filtrar(m, &Amarula.own_chat?(s.conn, &1)) do
        {:entregar, t} -> send(s.destino, {:mensagem, t})
        :ignorar -> :ok
      end
    end

    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}
end
