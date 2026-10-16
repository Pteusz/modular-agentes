# Spike etapa 0: pareia (QR) ou reconecta, fala SO no chat do proprio usuario.
# Uso: AMARULA_DATA_DIR=/opt/modular-agentes-data/amarula mix run spike.exs SEGUNDOS
secs = String.to_integer(List.first(System.argv()) || "120")
t0 = System.monotonic_time(:millisecond)
rss = fn ->
  [_, kb] = Regex.run(~r/VmRSS:\s+(\d+)/, File.read!("/proc/self/status"))
  String.to_integer(kb)
end
log = fn m -> IO.puts("[#{div(System.monotonic_time(:millisecond) - t0, 1000)}s rss=#{div(rss.(), 1024)}MB] #{m}") end

Logger.configure(level: :info)
{:ok, _sup} = Amarula.Supervisor.start_link([])

{:ok, conn} =
  Amarula.new(%{profile: :mateus, sync_full_history: false, sync_history: false})
  |> Amarula.connect(parent_pid: self())

log.("conectando")
Process.send_after(self(), :stop, secs * 1000)
Process.send_after(self(), :tick, 15_000)

loop = fn loop, sent ->
  receive do
    {:amarula, :connection_update, %{qr: qr}} when is_binary(qr) ->
      {:ok, art} = Amarula.render_qr(qr)
      IO.puts("\n" <> art <> "\n")
      log.("QR novo (escaneie: WhatsApp > Aparelhos conectados)")
      loop.(loop, sent)

    {:amarula, :connection_update, %{connection: :open}} ->
      log.("OPEN")
      if sent do
        loop.(loop, sent)
      else
        {:ok, jid} = Amarula.Address.to_jid(%{Amarula.own_address(conn) | device: 0})
        log.("enviando 1 msg ao proprio chat")
        log.("send_text -> #{inspect(Amarula.send_text(conn, jid, "[agente] canal ok"))}")
        loop.(loop, true)
      end

    {:amarula, :connection_update, other} ->
      log.("update #{inspect(Map.drop(other, [:qr]), limit: 5)}")
      loop.(loop, sent)

    {:amarula, :messages_upsert, %{messages: msgs}} ->
      for m <- msgs do
        if Amarula.own_chat?(conn, m) do
          log.("chat proprio: #{inspect(m.type)} (conteudo nao registrado)")
        else
          log.("IGNORADA msg fora do chat proprio (from_me=#{inspect(m.from_me)})")
        end
      end
      loop.(loop, sent)

    :tick -> log.("tick"); Process.send_after(self(), :tick, 15_000); loop.(loop, sent)
    :stop -> log.("fim"); :ok
    {:amarula, ev, _} -> log.("evento #{ev}"); loop.(loop, sent)
    _ -> loop.(loop, sent)
  end
end

loop.(loop, false)
Amarula.disconnect(conn)
