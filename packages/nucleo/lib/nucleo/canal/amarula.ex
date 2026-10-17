defmodule Nucleo.Canal.Amarula do
  @moduledoc """
  Canal real (Amarula 0.5.10). Sessao em /opt/modular-agentes-data/amarula/<tenant>.
  So entrega ao laco o que vem do chat do proprio usuario: texto como `{:mensagem, texto}` e midia como `{:midia, msg}`
  (o download fica com quem trata a midia); sem confirmacao de leitura; nao registra conteudo.
  O QR e o estado da conexao vao para `Nucleo.Canal.Estado` (so memoria); o QR so e impresso no terminal com `imprimir_qr: true` (padrao do pareamento manual).
  """
  @behaviour Nucleo.Canal
  use GenServer
  alias Nucleo.Canal.Estado

  @raiz_padrao "/opt/modular-agentes-data/amarula"

  @doc "Pasta das sessoes (configuravel: `config :nucleo, :sessoes_raiz`)."
  def raiz, do: Application.get_env(:nucleo, :sessoes_raiz, @raiz_padrao)

  @doc "Decide se uma Amarula.Msg entra no laco (puro; testavel sem rede)."
  def filtrar(msg, own_chat?) do
    cond do
      not own_chat?.(msg) -> :ignorar
      msg.type == :text and is_binary(msg.content) -> {:entregar, msg.content}
      msg.type == :media -> {:midia, msg}
      true -> :ignorar
    end
  end

  @impl Nucleo.Canal
  def iniciar(tenant, destino, opts), do: GenServer.start_link(__MODULE__, {tenant, destino, opts})
  @impl Nucleo.Canal
  def enviar_texto(ref, texto), do: GenServer.call(ref, {:enviar, texto}, 30_000)

  @impl GenServer
  def init({tenant, destino, opts}) do
    dir = Keyword.get(opts, :dir, Path.join(raiz(), tenant))
    File.mkdir_p!(dir)
    Amarula.Supervisor.start_link([])
    Estado.publicar(tenant, :conectando)

    {:ok, conn} =
      Amarula.new(%{
        profile: String.to_atom(tenant),
        sync_full_history: false,
        sync_history: false,
        storage: {Amarula.Storage.File, root: dir}
      })
      |> Amarula.connect(parent_pid: self())

    {:ok, %{conn: conn, destino: destino, tenant: tenant, aberto: false, imprimir: Keyword.get(opts, :imprimir_qr, true)}}
  end

  # numero realmente pareado (para a gestao conferir com o cadastrado); nunca derruba o canal
  defp publicar_numero(s) do
    Estado.publicar_numero(s.tenant, Amarula.own_address(s.conn).user |> to_string() |> String.replace(~r/\D/, ""))
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
    Estado.publicar(s.tenant, {:qr, qr})

    if s.imprimir do
      {:ok, art} = Amarula.render_qr(qr)
      IO.puts("\n#{art}\n[#{s.tenant}] escaneie o QR (WhatsApp > Aparelhos conectados)")
    end

    {:noreply, s}
  end

  def handle_info({:amarula, :connection_update, %{connection: :open}}, s) do
    Estado.publicar(s.tenant, :conectado)
    publicar_numero(s)
    {:noreply, %{s | aberto: true}}
  end

  def handle_info({:amarula, :connection_update, %{connection: :close}}, s) do
    Estado.publicar(s.tenant, :desconectado)
    {:noreply, %{s | aberto: false}}
  end

  def handle_info({:amarula, :messages_upsert, %{messages: msgs}}, s) do
    for m <- msgs do
      case filtrar(m, &Amarula.own_chat?(s.conn, &1)) do
        {:entregar, t} -> send(s.destino, {:mensagem, t})
        {:midia, msg} -> send(s.destino, {:midia, msg})
        :ignorar -> :ok
      end
    end

    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}
end
