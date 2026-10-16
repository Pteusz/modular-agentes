# Spike etapa 0 (BaileysEx): QR ou reconecta; fala SO no chat do proprio usuario; nao registra conteudo.
# Uso: mix run spike.exs SEGUNDOS
alias BaileysEx.Auth.NativeFilePersistence
alias BaileysEx.Connection.Transport.MintWebSocket
Logger.configure(level: :info)
secs = String.to_integer(List.first(System.argv()) || "120")
t0 = System.monotonic_time(:millisecond)
rss = fn ->
  [_, kb] = Regex.run(~r/VmRSS:\s+(\d+)/, File.read!("/proc/self/status"))
  String.to_integer(kb)
end
log = fn m -> IO.puts("[#{div(System.monotonic_time(:millisecond) - t0, 1000)}s rss=#{div(rss.(), 1024)}MB] #{m}") end
parent = self()
# binary_to_term([:safe]) exige atoms ja existentes: carrega todos os modulos antes
Application.load(:baileys_ex)
for m <- Application.spec(:baileys_ex, :modules) || [], do: Code.ensure_loaded(m)
{:ok, pa} = NativeFilePersistence.use_native_file_auth_state("/opt/modular-agentes-data/baileys/mateus")

opts =
  Keyword.merge(pa.connect_opts,
    transport: {MintWebSocket, []},
    config: BaileysEx.Connection.Config.new(reconnect_policy: :restart_required, max_retries: 10),
    on_qr: fn qr -> send(parent, {:qr, qr}) end,
    on_connection: fn u -> send(parent, {:conn, u}) end
  )

{:ok, conn} = BaileysEx.connect(pa.state, opts)
BaileysEx.subscribe_raw(conn, fn ev ->
  if Map.has_key?(ev, :creds_update) do
    with {:ok, a} <- BaileysEx.auth_state(conn), do: pa.save_creds.(a)
  end
end)
BaileysEx.subscribe(conn, fn
  {:message, m} -> send(parent, {:msg, m})
  _ -> :ok
end)
log.("conectando")
Process.send_after(self(), :stop, secs * 1000)
Process.send_after(self(), :tick, 15_000)

own_user = fn ->
  {:ok, a} = BaileysEx.auth_state(conn)
  id = (a.me && Map.get(a.me, :id)) || ""
  id |> String.split("@") |> hd() |> String.split(":") |> hd()
end

own_ids = fn ->
  {:ok, a} = BaileysEx.auth_state(conn)
  for k <- [:id, :lid], v = a.me && Map.get(a.me, k), v, do: v |> String.split("@") |> hd() |> String.split(":") |> hd()
end

loop = fn loop, sent ->
  receive do
    {:qr, qr} ->
      {:ok, q} = QRCode.create(qr)
      m = q.matrix |> Enum.map(&List.to_tuple/1) |> List.to_tuple()
      n = tuple_size(m)
      cell = fn r, c -> if r >= 0 and r < n and c >= 0 and c < n and elem(elem(m, r), c) == 1, do: 1, else: 0 end
      art =
        for r <- Enum.take_every(-2..(n + 1), 2), into: "" do
          row =
            for c <- -2..(n + 1), into: "" do
              case {cell.(r, c), cell.(r + 1, c)} do
                {1, 1} -> "█"
                {1, 0} -> "▀"
                {0, 1} -> "▄"
                _ -> " "
              end
            end
          row <> "\n"
        end
      IO.puts("\n" <> to_string(art) <> "\n"); log.("QR novo"); loop.(loop, sent)

    {:conn, %{connection: :open}} ->
      log.("OPEN")
      if sent do
        loop.(loop, sent)
      else
        jid = own_user.() <> "@s.whatsapp.net"
        log.("send -> #{inspect(BaileysEx.send_message(conn, jid, %{text: "[agente] canal ok"}), limit: 3)}")
        loop.(loop, true)
      end

    {:conn, u} -> log.("conn #{inspect(Map.drop(u, [:qr]), limit: 5)}"); loop.(loop, sent)

    {:msg, %{key: %{remote_jid: rj, from_me: fm}}} ->
      if fm and own_ids.() |> Enum.any?(&(&1 != "" and String.starts_with?(to_string(rj), &1 <> "@"))), do: log.("chat proprio (conteudo nao registrado)"), else: log.("IGNORADA fora do chat proprio (from_me=#{inspect(fm)})")
      loop.(loop, sent)

    :tick -> log.("tick"); Process.send_after(self(), :tick, 15_000); loop.(loop, sent)
    :stop -> log.("fim")
    _ -> loop.(loop, sent)
  end
end
loop.(loop, false)
