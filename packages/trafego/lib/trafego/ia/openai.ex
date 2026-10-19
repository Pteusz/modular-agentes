defmodule Trafego.IA.OpenAI do
  @moduledoc """
  Provedor de IA real (OpenAI, API Responses) atras de Trafego.IA. Modelo e esforco de raciocinio por faixa vem de config
  (:openai, :modelos / :esforco); a chave so de OPENAI_API_KEY. Saida estruturada (json_schema estrito, store: false:
  nada fica guardado no lado da OpenAI). O provedor nunca recebe nem devolve id de conta: a entrada e so texto do pedido e plano.
  Devolve {:ok, saida, %{"modelo", "tokens_in", "tokens_out"}} (modelo = o configurado, que e a chave da tabela de precos).
  """
  @behaviour Trafego.IA
  alias Trafego.Config

  @decisoes ~w(sim nao ambiguo)
  @destinos ~w(site whatsapp formulario)

  @impl true
  def chamar(faixa, tarefa, entrada) when faixa in [:pequena, :media] and tarefa in [:planejar, :confirmar] do
    with {:ok, chave} <- chave(),
         {:ok, modelo} <- modelo(faixa),
         {:ok, corpo} <- pedir(chave, corpo(faixa, modelo, tarefa, entrada)),
         {:ok, texto, uso} <- extrair(corpo, modelo),
         {:ok, saida} <- decodificar(texto),
         {:ok, saida} <- validar(tarefa, saida) do
      {:ok, saida, uso}
    end
  end

  @doc """
  Transcricao (v1/audio/transcriptions, multipart). Modelo e idioma de config (:openai, :transcricao). Os bytes so existem em memoria.
  Uso devolvido: %{modelo, segundos} (duracao informada pela API quando vem; senao a do WhatsApp).
  """
  @impl true
  def transcrever(bytes, %{mime: mime, segundos: segundos}) do
    cfg = Config.openai(:transcricao, [])
    modelo = Keyword.get(cfg, :modelo, "gpt-transcribe")

    with {:ok, chave} <- chave(),
         {:ok, corpo} <- pedir_audio(chave, modelo, Keyword.get(cfg, :idioma, "pt"), bytes, mime),
         %{"text" => texto} when is_binary(texto) <- corpo do
      seg = get_in(corpo, ["usage", "seconds"])
      {:ok, texto, %{"modelo" => modelo, "segundos" => if(is_number(seg) and seg > 0, do: ceil(seg), else: segundos)}}
    else
      {:error, _} = e -> e
      _ -> {:error, :resposta_inesperada}
    end
  end

  defp pedir_audio(chave, modelo, idioma, bytes, mime) do
    url = Config.openai(:base_url, "https://api.openai.com") <> "/v1/audio/transcriptions"
    {ext, tipo} = formato(mime)

    campos = [file: {bytes, filename: "audio." <> ext, content_type: tipo}, model: modelo, language: idioma, response_format: "json"]

    case Req.request(method: :post, url: url, form_multipart: campos, headers: [{"authorization", "Bearer " <> chave}], retry: false, receive_timeout: Config.openai(:timeout, 60_000)) do
      {:ok, %{status: 200, body: b}} when is_map(b) -> {:ok, b}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, ex} -> {:error, {:rede, ex |> Exception.message() |> String.slice(0, 120)}}
    end
  end

  # extensao e content-type pelo mime do WhatsApp (nota de voz = audio/ogg; codecs=opus)
  defp formato(mime) do
    m = (mime || "") |> String.downcase()

    cond do
      m =~ "ogg" or m =~ "opus" -> {"ogg", "audio/ogg"}
      m =~ "mpeg" or m =~ "mp3" -> {"mp3", "audio/mpeg"}
      m =~ "mp4" or m =~ "m4a" or m =~ "aac" -> {"m4a", "audio/mp4"}
      m =~ "wav" -> {"wav", "audio/wav"}
      m =~ "webm" -> {"webm", "audio/webm"}
      true -> {"ogg", "audio/ogg"}
    end
  end

  defp chave do
    case Config.openai_chave() do
      c when is_binary(c) and c != "" -> {:ok, c}
      _ -> {:error, :sem_chave_openai}
    end
  end

  defp modelo(faixa) do
    case Map.get(Config.openai(:modelos, %{}), faixa) do
      m when is_binary(m) and m != "" -> {:ok, m}
      _ -> {:error, {:sem_modelo, faixa}}
    end
  end

  # ---- pedido
  defp corpo(faixa, modelo, :planejar, e) do
    base(faixa, modelo, "planejar", instrucao_planejar(), planejar_schema(), %{
      "hoje" => Date.utc_today() |> Date.to_iso8601(),
      "pedido_do_corretor" => e["texto"],
      "plano_atual" => Map.drop(e["plano"] || %{}, ["id", "status", "atencao", "conta_id"]),
      "criativo_recebido" => get_in(e, ["plano", "criativo", "midia"])
    })
  end

  defp corpo(faixa, modelo, :confirmar, e) do
    base(faixa, modelo, "confirmar", instrucao_confirmar(), confirmar_schema(), %{"plano_resumo" => e["resumo"], "resposta_do_corretor" => e["texto"]})
  end

  defp base(faixa, modelo, nome, instrucao, schema, usuario) do
    %{
      "model" => modelo, "store" => false, "max_output_tokens" => Config.openai(:max_tokens, 4000),
      "reasoning" => %{"effort" => Map.get(Config.openai(:esforco, %{}), faixa, "low")},
      "input" => [%{"role" => "system", "content" => instrucao}, %{"role" => "user", "content" => Jason.encode!(usuario)}],
      "text" => %{"format" => %{"type" => "json_schema", "name" => nome, "strict" => true, "schema" => schema}}
    }
  end

  defp pedir(chave, corpo) do
    url = Config.openai(:base_url, "https://api.openai.com") <> "/v1/responses"

    case Req.request(method: :post, url: url, json: corpo, headers: [{"authorization", "Bearer " <> chave}], retry: false, receive_timeout: Config.openai(:timeout, 60_000)) do
      {:ok, %{status: 200, body: b}} when is_map(b) -> {:ok, b}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, ex} -> {:error, {:rede, ex |> Exception.message() |> String.slice(0, 120)}}
    end
  end

  # ---- resposta
  defp extrair(%{"output" => out} = r, modelo) do
    partes = for %{"type" => "message", "content" => c} <- out, p <- c, do: p

    cond do
      Enum.any?(partes, &(&1["type"] == "refusal")) -> {:error, :recusado_pelo_modelo}
      r["status"] == "incomplete" -> {:error, :resposta_incompleta}
      true -> texto_e_uso(partes, r["usage"], modelo)
    end
  end

  defp extrair(_, _), do: {:error, :resposta_inesperada}

  defp texto_e_uso(partes, %{"input_tokens" => ti, "output_tokens" => to}, modelo) when is_integer(ti) and is_integer(to) do
    case Enum.find(partes, &(&1["type"] == "output_text")) do
      %{"text" => t} when is_binary(t) -> {:ok, t, %{"modelo" => modelo, "tokens_in" => ti, "tokens_out" => to}}
      _ -> {:error, :resposta_inesperada}
    end
  end

  defp texto_e_uso(_, _, _), do: {:error, :resposta_inesperada}

  defp decodificar(texto) do
    case Jason.decode(texto) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, :saida_invalida}
    end
  end

  defp validar(:confirmar, %{"decisao" => d} = s) when d in @decisoes, do: {:ok, Map.take(s, ["decisao"])}
  defp validar(:confirmar, _), do: {:error, :saida_invalida}
  defp validar(:planejar, %{} = plano), do: {:ok, %{"plano" => limpar(plano)}}

  # nulos (campo nao informado) saem; o dominio so ve o que o corretor disse
  defp limpar(m) when is_map(m) do
    m |> Enum.map(fn {k, v} -> {k, limpar(v)} end) |> Enum.reject(fn {_, v} -> v in [nil, "", %{}] end) |> Map.new()
  end

  defp limpar(v), do: v

  # ---- instrucoes e esquemas
  defp instrucao_planejar,
    do: """
    Voce monta o PLANO de uma campanha de anuncios de um corretor de imoveis, a partir do pedido dele (portugues informal).
    Preencha so o que o corretor disse ou o plano atual ja tem; o que nao foi dito fica nulo. Nunca invente valores.
    Dinheiro em CENTAVOS de real (R$ 50 = 5000). destino: site (precisa url e pixel), whatsapp (precisa numero) ou formulario (precisa formulario).
    criativo.midia so pode ser o arquivo ja recebido (campo criativo_recebido); se nao ha arquivo, deixe nulo. criativo.texto e o texto do anuncio.
    janela em datas AAAA-MM-DD (use "hoje" para datas relativas). meta: resultados desejados e custo_max por resultado (centavos).
    Nao existe conta de anuncio no plano: nao pergunte nem informe ids de conta. A campanha sera criada PAUSADA.
    """

  defp instrucao_confirmar,
    do: """
    O corretor respondeu a uma pergunta de confirmacao do plano resumido. Classifique a resposta:
    "sim" so se for uma autorizacao clara para executar; "nao" se recusou ou mandou cancelar; "ambiguo" em qualquer duvida,
    condicao, pergunta, pedido de mudanca ou assunto diferente. Na duvida, "ambiguo".
    """

  defp confirmar_schema,
    do: %{"type" => "object", "additionalProperties" => false, "required" => ["decisao"], "properties" => %{"decisao" => %{"type" => "string", "enum" => @decisoes}}}

  defp planejar_schema do
    nulo = fn tipo -> %{"type" => [tipo, "null"]} end
    obj = fn props -> %{"type" => ["object", "null"], "additionalProperties" => false, "required" => Map.keys(props), "properties" => props} end

    props = %{
      "destino" => %{"type" => ["string", "null"], "enum" => @destinos ++ [nil]},
      "url" => nulo.("string"), "pixel" => nulo.("string"), "numero" => nulo.("string"), "formulario" => nulo.("string"), "imovel" => nulo.("string"),
      "publico" => nulo.("string"),
      "criativo" => obj.(%{"midia" => nulo.("string"), "texto" => nulo.("string")}),
      "orcamento_diario" => nulo.("integer"), "teto_total" => nulo.("integer"),
      "janela" => obj.(%{"inicio" => nulo.("string"), "fim" => nulo.("string")}),
      "meta" => obj.(%{"resultados" => nulo.("integer"), "custo_max" => nulo.("integer")})
    }

    %{"type" => "object", "additionalProperties" => false, "required" => Map.keys(props), "properties" => props}
  end
end
