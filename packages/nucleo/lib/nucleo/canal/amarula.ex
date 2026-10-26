defmodule Nucleo.Canal.Amarula do
  @moduledoc """
  Canal real (Amarula 0.5.10). Sessao em /opt/modular-agentes-data/amarula/<tenant>.
  So entrega ao laco o que vem do chat do proprio usuario: texto como `{:mensagem, texto}` e midia como `{:midia, msg}`
  (o download fica com quem trata a midia); sem confirmacao de leitura; nao registra conteudo.
  Lista de permissao (1.5.1): a sala tem de ser a propria conta (consigo mesmo); grupos/broadcast/newsletter/terceiros nunca entram.
  O envio (`enviar_texto/audio`) vai sempre para a propria conta, nunca para destino vindo de mensagem.
  Credencial recusada pelo WhatsApp (401/403, ex.: aparelho removido em Dispositivos vinculados): publica `:precisa_parear`, guarda as
  credenciais num backup e reinicia o canal do tenant (`Nucleo.Conexao.reparear/2`) para gerar QR novo, em vez de insistir ate desistir.
  O QR e o estado da conexao vao para `Nucleo.Canal.Estado` (so memoria); o QR so e impresso no terminal com `imprimir_qr: true` (padrao do pareamento manual).
  """
  @behaviour Nucleo.Canal
  use GenServer
  require Logger
  alias Nucleo.Canal.Estado
  alias Nucleo.Conexao

  @raiz_padrao "/opt/modular-agentes-data/amarula"

  @doc "Pasta das sessoes (configuravel: `config :nucleo, :sessoes_raiz`)."
  def raiz, do: Application.get_env(:nucleo, :sessoes_raiz, @raiz_padrao)

  @doc """
  Decide se uma Amarula.Msg entra no laco (puro; testavel sem rede). Lista de permissao estrita: so passa se
  `own_chat?` confirmar E a sala (`channel`, sem device) for uma das `contas` proprias (PN ou LID); grupo, broadcast,
  newsletter, chat de outra pessoa e sala desconhecida nunca entram. Sem `contas` nada entra.
  """
  def filtrar(msg, own_chat?, contas \\ []) do
    cond do
      motivo(msg, own_chat?, contas) != :ok -> :ignorar
      msg.type == :text and is_binary(msg.content) -> {:entregar, msg.content}
      msg.type == :media -> {:midia, msg}
      true -> :ignorar
    end
  end

  @doc "`:ok` se a mensagem e da conversa consigo mesmo; senao `{motivo, servidor}` (so diagnostico: sem texto e sem numero)."
  def motivo(msg, own_chat?, contas) do
    case Map.get(msg, :channel) do
      %Amarula.Address{kind: :group} ->
        {:grupo, "g.us"}

      %Amarula.Address{kind: kind} = sala when kind in [:pn, :lid] ->
        if Enum.any?(contas, &Amarula.Address.same_account?(&1, sala)) and own_chat?.(msg), do: :ok, else: {:nao_e_proprio, servidor(sala)}

      _ ->
        {:sem_sala, "desconhecido"}
    end
  end

  defp servidor(%Amarula.Address{kind: :pn}), do: "s.whatsapp.net"
  defp servidor(%Amarula.Address{kind: :lid}), do: "lid"
  defp servidor(_), do: "desconhecido"

  # identidades proprias (PN e LID) da conta pareada; qualquer falha = lista vazia (nada entra)
  defp contas_proprias(conn) do
    me = get_in(GenServer.call(conn, :get_auth_creds), [:me]) || %{}
    [me[:id], me[:lid]] |> Enum.reject(&is_nil/1) |> Enum.map(&Amarula.Address.parse/1) |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc "O erro de conexao do Amarula e credencial recusada (401 = deslogado, 403 = banido/invalido)?"
  def credencial_invalida?({:connection_failure, motivo}) when motivo in ["401", "403"], do: true
  def credencial_invalida?(_), do: false

  @impl Nucleo.Canal
  def iniciar(tenant, destino, opts), do: GenServer.start_link(__MODULE__, {tenant, destino, opts})
  @impl Nucleo.Canal
  def enviar_texto(ref, texto), do: GenServer.call(ref, {:enviar, texto}, 30_000)
  @impl Nucleo.Canal
  def enviar_audio(ref, bytes, opts), do: GenServer.call(ref, {:enviar_audio, bytes, opts}, 60_000)

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

    {:ok,
     %{
       conn: conn,
       destino: destino,
       tenant: tenant,
       aberto: false,
       imprimir: Keyword.get(opts, :imprimir_qr, true),
       reparo: [canal_opts: opts],
       reparando: false
     }}
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

  # nota de voz (ptt) ogg/opus: o Amarula nao processa midia, entao passa a duracao e o mime
  def handle_call({:enviar_audio, bytes, opts}, _from, %{aberto: true, conn: c} = s) do
    {:ok, jid} = Amarula.Address.to_jid(%{Amarula.own_address(c) | device: 0})

    r =
      case Amarula.send_media(c, jid, :audio, bytes, ptt: true, seconds: opts[:segundos] || 1, mimetype: opts[:mime] || "audio/ogg; codecs=opus") do
        {:ok, _} -> :ok
        other -> {:error, other}
      end

    {:reply, r, s}
  end

  def handle_call({:enviar, _}, _from, s), do: {:reply, {:error, :desconectado}, s}
  def handle_call({:enviar_audio, _, _}, _from, s), do: {:reply, {:error, :desconectado}, s}

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
    contas = contas_proprias(s.conn)
    own = &Amarula.own_chat?(s.conn, &1)

    for m <- msgs do
      case filtrar(m, own, contas) do
        {:entregar, t} -> send(s.destino, {:mensagem, t})
        {:midia, msg} -> send(s.destino, {:midia, msg})
        :ignorar -> registrar_ignorada(motivo(m, own, contas))
      end
    end

    {:noreply, s}
  end

  # 401/403: o laco (e este canal) e derrubado pela tarefa, entao ela roda solta; uma vez so, as retentativas seguintes caem no fim
  def handle_info({:amarula, :error, erro}, %{reparando: false} = s) do
    if credencial_invalida?(erro) do
      Logger.warning("canal: credenciais recusadas (#{elem(erro, 1)}), pareando de novo tenant=#{s.tenant}")
      Estado.publicar(s.tenant, :precisa_parear)
      {tenant, reparo} = {s.tenant, s.reparo}

      Task.start(fn ->
        case Conexao.reparear(tenant, reparo) do
          {:error, _} -> Estado.publicar(tenant, :precisa_parear)
          _ -> :ok
        end
      end)

      {:noreply, %{s | reparando: true, aberto: false}}
    else
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  # diagnostico sem conteudo nem numero: so o motivo e o tipo de servidor da sala
  defp registrar_ignorada({motivo, servidor}), do: Logger.debug("canal: mensagem ignorada motivo=#{motivo} servidor=#{servidor}")
  defp registrar_ignorada(:ok), do: :ok
end
