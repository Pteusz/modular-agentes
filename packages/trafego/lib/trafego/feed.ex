defmodule Trafego.Feed do
  @moduledoc """
  Feed de imoveis (tabela wp_produtos do Mateus). Contrato `Feed`: importar uma fonte para o espelho `feed_imoveis` (Postgres) e
  consultar. Adaptador atual: dump .sql em Config.feed_dir (importar/1, importar_do_diretorio/0); uma conexao MySQL somente leitura
  pode entrar depois como outro adaptador, sem mudar quem consulta.
  Mapeamento: id -> id; nome; regiao -> bairro; regiao_base -> regiao; dormitorios (texto livre, vazio = nao informado);
  valor -> "a partir de" em centavos (0 = sem preco, nunca inventado); imagem; updated_at.
  estado_obra (se vazio, estagio_obra) fica em estado_original, SO informativo (ex.: "Lancamento"): imovel nao tem status e esse
  texto nunca vira evento, proposta nem bloqueio (decisao do Mateus, 4.6).
  """
  alias Trafego.{Banco, Config}
  alias Trafego.Feed.Dump


  def fonte, do: Config.feed_fonte()

  @doc "Importa um dump .sql. {:ok, %{importados: n}}"
  def importar(caminho, opts \\ []) do
    fonte = opts[:fonte] || fonte()

    with {:ok, sql} <- File.read(caminho) do
      linhas = sql |> Dump.linhas("wp_produtos") |> Enum.map(&mapear/1) |> Enum.reject(&is_nil(&1.id))

      for l <- linhas do
        Banco.q(
          """
          INSERT INTO feed_imoveis (fonte, id, nome, bairro, regiao, dormitorios, valor_centavos, estado_original, imagem, atualizado_em)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
          ON CONFLICT (fonte, id) DO UPDATE SET nome = EXCLUDED.nome, bairro = EXCLUDED.bairro, regiao = EXCLUDED.regiao,
            dormitorios = EXCLUDED.dormitorios, valor_centavos = EXCLUDED.valor_centavos,
            estado_original = EXCLUDED.estado_original, imagem = EXCLUDED.imagem, atualizado_em = EXCLUDED.atualizado_em, importado_em = now()
          """,
          [fonte, l.id, l.nome, l.bairro, l.regiao, l.dormitorios, l.valor_centavos, l.estado_original, l.imagem, l.atualizado_em]
        )
      end

      {:ok, %{importados: length(linhas)}}
    end
  end

  @doc "Importa o .sql mais recente de Config.feed_dir. {:error, :sem_arquivo} se nao houver."
  def importar_do_diretorio do
    dir = Config.feed_dir()

    case Path.wildcard(Path.join(dir, "*.sql")) |> Enum.sort_by(&File.stat!(&1).mtime) |> List.last() do
      nil -> {:error, :sem_arquivo}
      arq -> importar(arq)
    end
  end

  def imovel(nil), do: nil

  def imovel(id) do
    case Banco.q(
           "SELECT id, nome, bairro, regiao, dormitorios, valor_centavos, estado_original, imagem, atualizado_em FROM feed_imoveis WHERE fonte = $1 AND id = $2",
           [fonte(), to_string(id)]
         ).rows do
      [[i, n, b, r, d, v, e, im, at]] ->
        %{id: i, nome: n, bairro: b, regiao: r, dormitorios: d, valor_centavos: v, estado_original: e, imagem: im, atualizado_em: at}

      _ ->
        nil
    end
  end

  # ---- mapeamento
  defp mapear(row) do
    estado = vazio(row["estado_obra"]) || vazio(row["estagio_obra"])

    %{
      id: vazio(row["id"]),
      nome: vazio(row["nome"]),
      bairro: vazio(row["regiao"]),
      regiao: vazio(row["regiao_base"]),
      dormitorios: vazio(row["dormitorios"]),
      valor_centavos: centavos(row["valor"]),
      estado_original: estado,
      imagem: vazio(row["imagem"]),
      atualizado_em: vazio(row["updated_at"])
    }
  end

  defp vazio(nil), do: nil
  defp vazio(s), do: (case String.trim(to_string(s)) do "" -> nil; v -> v end)


  @doc false
  def centavos(nil), do: nil

  def centavos(s) do
    case Float.parse(String.trim(to_string(s))) do
      {v, _} when v > 0 -> round(v * 100)
      _ -> nil
    end
  end
end

defmodule Trafego.Feed.Dump do
  @moduledoc """
  Leitor de dump mysqldump (so as linhas de INSERT de uma tabela). Tokeniza caractere a caractere: strings com escape de barra e
  aspas dobradas, backticks, NULL, numeros, comentarios (-- e /* */). Sem lista de colunas no INSERT, usa a do CREATE TABLE.
  """

  def linhas(sql, tabela) do
    declaracoes = sql |> tokens([]) |> Enum.chunk_by(&(&1 == :fim)) |> Enum.reject(&(&1 == [:fim]))
    colunas = Enum.find_value(declaracoes, [], &criar_tabela(&1, tabela))
    Enum.flat_map(declaracoes, &inserir(&1, tabela, colunas))
  end

  # ---- declaracoes
  defp criar_tabela([{:word, "CREATE"}, {:word, "TABLE"} | resto], tabela) do
    resto = Enum.drop_while(resto, &match?({:word, w} when w in ["IF", "NOT", "EXISTS"], &1))

    case resto do
      [{:ident, ^tabela}, :abre | corpo] ->
        corpo |> elementos([], [], 1) |> Enum.flat_map(fn
          [{:ident, nome} | _] -> [nome]
          _ -> []
        end)

      _ ->
        nil
    end
  end

  defp criar_tabela(_, _), do: nil

  # divide o corpo do CREATE TABLE nas virgulas de nivel 1
  defp elementos([], atual, acc, _), do: Enum.reverse([Enum.reverse(atual) | acc])
  defp elementos([:fecha | _], atual, acc, 1), do: Enum.reverse([Enum.reverse(atual) | acc])
  defp elementos([:virgula | r], atual, acc, 1), do: elementos(r, [], [Enum.reverse(atual) | acc], 1)
  defp elementos([:abre = t | r], atual, acc, n), do: elementos(r, [t | atual], acc, n + 1)
  defp elementos([:fecha = t | r], atual, acc, n), do: elementos(r, [t | atual], acc, n - 1)
  defp elementos([t | r], atual, acc, n), do: elementos(r, [t | atual], acc, n)

  defp inserir([{:word, "INSERT"}, {:word, "INTO"} | resto], tabela, colunas_tabela) do
    {nome, resto} = nome_tabela(resto)

    if nome != tabela do
      []
    else
      {cols, resto} =
        case resto do
          [:abre | r] ->
            {lista, [:fecha | r2]} = Enum.split_while(r, &(&1 != :fecha))
            {for({:ident, c} <- lista, do: c), r2}

          _ ->
            {colunas_tabela, resto}
        end

      case resto do
        [{:word, "VALUES"} | tuplas] -> tuplas |> tuplas([]) |> Enum.map(&(Enum.zip(cols, &1) |> Map.new()))
        _ -> []
      end
    end
  end

  defp inserir(_, _, _), do: []

  # `banco`.`tabela` ou `tabela`
  defp nome_tabela([{:ident, _}, :ponto, {:ident, t} | r]), do: {t, r}
  defp nome_tabela([{:ident, t} | r]), do: {t, r}
  defp nome_tabela(r), do: {nil, r}

  defp tuplas([], acc), do: Enum.reverse(acc)
  defp tuplas([:virgula | r], acc), do: tuplas(r, acc)

  defp tuplas([:abre | r], acc) do
    {valores, [:fecha | resto]} = Enum.split_while(r, &(&1 != :fecha))
    tuplas(resto, [for(v <- valores, v != :virgula, do: valor(v)) | acc])
  end

  defp tuplas([_ | r], acc), do: tuplas(r, acc)

  defp valor({:str, s}), do: s
  defp valor({:word, w}), do: w
  defp valor(:nulo), do: nil
  defp valor({:ident, i}), do: i

  # ---- tokens
  defp tokens(<<>>, acc), do: Enum.reverse(acc)
  defp tokens(<<c, r::binary>>, acc) when c in [?\s, ?\t, ?\r, ?\n], do: tokens(r, acc)
  defp tokens(<<"--", r::binary>>, acc), do: tokens(pular_linha(r), acc)
  defp tokens(<<"#", r::binary>>, acc), do: tokens(pular_linha(r), acc)
  defp tokens(<<"/*", r::binary>>, acc), do: tokens(pular_bloco(r), acc)
  defp tokens(<<"(", r::binary>>, acc), do: tokens(r, [:abre | acc])
  defp tokens(<<")", r::binary>>, acc), do: tokens(r, [:fecha | acc])
  defp tokens(<<",", r::binary>>, acc), do: tokens(r, [:virgula | acc])
  defp tokens(<<";", r::binary>>, acc), do: tokens(r, [:fim | acc])

  defp tokens(<<"`", r::binary>>, acc) do
    {id, resto} = ate(r, "`", [])
    tokens(resto, [{:ident, id} | acc])
  end

  defp tokens(<<q, r::binary>>, acc) when q in [?', ?"] do
    {s, resto} = texto(r, q, [])
    tokens(resto, [{:str, s} | acc])
  end

  defp tokens(<<".", c, _::binary>> = b, acc) when c not in ?0..?9 do
    <<_, r::binary>> = b
    tokens(r, [:ponto | acc])
  end

  defp tokens(b, acc) do
    {palavra, resto} = palavra(b, [])

    tok =
      case String.upcase(palavra) do
        "NULL" -> :nulo
        up -> if numero?(palavra), do: {:word, palavra}, else: {:word, up}
      end

    tokens(resto, [tok | acc])
  end

  defp numero?(p), do: Regex.match?(~r/^-?\d+(\.\d+)?([eE][-+]?\d+)?$/, p)

  defp pular_linha(<<"\n", r::binary>>), do: r
  defp pular_linha(<<>>), do: <<>>
  defp pular_linha(<<_, r::binary>>), do: pular_linha(r)

  defp pular_bloco(<<"*/", r::binary>>), do: r
  defp pular_bloco(<<>>), do: <<>>
  defp pular_bloco(<<_, r::binary>>), do: pular_bloco(r)

  defp ate(<<"`", r::binary>>, "`", acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), r}
  defp ate(<<>>, _, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}
  defp ate(<<c, r::binary>>, f, acc), do: ate(r, f, [<<c>> | acc])

  # string SQL: barra escapa o proximo caractere; aspas dobradas viram uma aspa
  defp texto(<<q, q, r::binary>>, q, acc), do: texto(r, q, [<<q>> | acc])
  defp texto(<<q, r::binary>>, q, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), r}
  defp texto(<<"\\", c, r::binary>>, q, acc), do: texto(r, q, [escape(c) | acc])
  defp texto(<<>>, _, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}
  defp texto(<<c, r::binary>>, q, acc), do: texto(r, q, [<<c>> | acc])

  defp escape(?n), do: "\n"
  defp escape(?r), do: "\r"
  defp escape(?t), do: "\t"
  defp escape(?0), do: <<0>>
  defp escape(c), do: <<c>>

  defp palavra(<<c, _::binary>> = b, acc) when c in [?\s, ?\t, ?\r, ?\n, ?(, ?), ?,, ?;], do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), b}
  defp palavra(<<>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}
  defp palavra(<<c, r::binary>>, acc), do: palavra(r, [<<c>> | acc])
end
