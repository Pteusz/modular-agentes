# Servidor HTTP falso local (so para testes): aceita conexoes em 127.0.0.1, devolve JSON (ou binario) pelo handler.
# handler: fn %{metodo, caminho, query, headers, corpo} -> {status, mapa | {:bin, bytes}} end
defmodule HttpFalso do
  def start(handler) do
    {:ok, log} = Agent.start_link(fn -> [] end)
    {:ok, ls} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(ls)
    spawn(fn -> aceitar(ls, handler, log) end)
    %{port: port, log: log, ls: ls}
  end

  def parar(%{ls: ls, log: log}) do
    :gen_tcp.close(ls)
    Agent.stop(log)
  end

  def pedidos(%{log: log}), do: Agent.get(log, &Enum.reverse/1)
  def url(%{port: p}), do: "http://127.0.0.1:#{p}"

  defp aceitar(ls, h, log) do
    case :gen_tcp.accept(ls) do
      {:ok, s} ->
        spawn(fn -> atender(s, h, log) end)
        aceitar(ls, h, log)

      _ ->
        :ok
    end
  end

  defp atender(s, h, log) do
    {cab, resto} = ler_cab(s, "")
    [linha | linhas] = String.split(cab, "\r\n")
    [metodo, alvo | _] = String.split(linha, " ")
    headers = for l <- linhas, [k, v] <- [String.split(l, ":", parts: 2)], into: %{}, do: {String.downcase(k), String.trim(v)}

    corpo =
      if headers["transfer-encoding"] == "chunked",
        do: ler_chunked(s, resto),
        else: ler_n(s, resto, String.to_integer(headers["content-length"] || "0"))

    uri = URI.parse(alvo)
    req = %{metodo: metodo, caminho: uri.path, query: URI.decode_query(uri.query || ""), headers: headers, corpo: corpo}
    Agent.update(log, &[req | &1])
    {st, resp} = h.(req)

    {tipo, body} =
      case resp do
        {:bin, b} -> {"application/octet-stream", b}
        m -> {(if String.starts_with?(req.caminho, "/v1/"), do: "application/json", else: "text/javascript; charset=UTF-8"), Jason.encode!(m)}
      end

    :gen_tcp.send(s, ["HTTP/1.1 ", Integer.to_string(st), " X\r\ncontent-type: ", tipo, "\r\ncontent-length: ", Integer.to_string(byte_size(body)), "\r\nconnection: close\r\n\r\n", body])
    :gen_tcp.close(s)
  end

  defp ler_cab(s, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [cab, resto] ->
        {cab, resto}

      _ ->
        {:ok, d} = :gen_tcp.recv(s, 0, 5000)
        ler_cab(s, acc <> d)
    end
  end

  defp ler_n(_s, acc, n) when byte_size(acc) >= n, do: binary_part(acc, 0, n)

  defp ler_n(s, acc, n) do
    {:ok, d} = :gen_tcp.recv(s, 0, 5000)
    ler_n(s, acc <> d, n)
  end

  defp ler_chunked(s, acc) do
    if String.ends_with?(acc, "0\r\n\r\n") do
      dechunk(acc, "")
    else
      {:ok, d} = :gen_tcp.recv(s, 0, 5000)
      ler_chunked(s, acc <> d)
    end
  end

  defp dechunk("0\r\n\r\n" <> _, out), do: out

  defp dechunk(bin, out) do
    [tam, resto] = String.split(bin, "\r\n", parts: 2)
    n = String.to_integer(tam, 16)
    <<dado::binary-size(n), "\r\n", prox::binary>> = resto
    dechunk(prox, out <> dado)
  end
end
