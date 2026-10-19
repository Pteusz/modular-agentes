defmodule Trafego.Ficha do
  @moduledoc """
  Ficha de estado da conversa de criacao de plano (etapa 5.2; docs/iara.md secao 3 v2). A ficha vive NO CODIGO, dentro do plano
  em rascunho (chave "ficha"), nao so no contexto da IA: objetivo, imovel, verba diaria, teto total, janela, destino, publico,
  criativo e meta. Cada mensagem (texto ou audio) preenche quantos campos der; campo preenchido nunca e perguntado de novo e a
  correcao de um ponto atualiza SO aquele campo.

    * "origem": campo => "corretor" | "iara" (o que a Iara sugeriu aparece como "sugestao minha"; a IA so sugere onde o corretor nao disse)
    * "perguntados": campos do nucleo ja perguntados (o teto perguntado e nao respondido vira SUGESTAO: diario x dias da janela)

  Nucleo (a unica coisa que pode ser perguntada): objetivo, imovel, verba diaria e teto, mais o que o destino exige (numero, url...).
  O resto sai de padroes sensatos (`completar/2`). A entrega do plano sao 4 a 5 mensagens curtas (`mensagens/1`).
  """
  alias Trafego.{Config, Feed, Plano}

  @proibidos ~r/garantid|rentabilidad|sem risco|lucro certo|retorno certo|valorizacao certa|(apenas|somente|so) para (homens|mulheres|casais|solteiros|brancos)|\bidosos\b|familia tradicional/iu

  # ---- leitura
  def ficha(plano), do: Map.merge(%{"origem" => %{}, "perguntados" => []}, plano["ficha"] || %{})
  def origem(plano, chave), do: ficha(plano)["origem"][chave]
  defp sugestao?(plano, chave), do: origem(plano, chave) == "iara"

  defp presente?(v), do: v not in [nil, ""]
  defp positivo?(v), do: is_integer(v) and v > 0

  # ---- aplicar o que a IA extraiu (varios campos de uma vez)
  @doc """
  Mescla a saida do planejador na ficha. Campos ditos pelo corretor entram e viram origem "corretor"; as SUGESTOES da IA
  ("sugeridos": publico e texto do anuncio) so entram onde o corretor nao disse. Devolve {plano, ignorados, %{ambiguidade, sem_teto}}.
  """
  def aplicar(plano, parcial) do
    {extras, parcial} = Map.split(parcial, ["sugeridos", "ambiguidade", "sem_teto"])
    sug = extras |> Map.get("sugeridos") |> List.wrap() |> Enum.filter(&(&1 in ~w(publico criativo)))
    {da_ia, do_corretor} = Map.split(parcial, sug)

    # a sugestao de criativo e so o TEXTO; arquivo e sempre do corretor
    {do_corretor, da_ia} =
      case da_ia["criativo"] do
        %{} = c ->
          midia = Map.take(c, ["midia"]) |> Map.reject(fn {_, v} -> v in [nil, ""] end)
          do_corretor = if midia == %{}, do: do_corretor, else: Map.put(do_corretor, "criativo", midia)
          {do_corretor, Map.put(da_ia, "criativo", Map.take(c, ["texto"]))}

        _ ->
          {do_corretor, da_ia}
      end

    do_corretor = limpo(do_corretor)
    da_ia = da_ia |> limpo() |> Map.reject(fn {k, v} -> v == %{} or ja_dito?(plano, k, v) end)

    {plano, ign} = Plano.mesclar(plano, do_corretor)
    plano = if get_in(do_corretor, ["criativo", "texto"]), do: put_in(plano, ["ficha"], Map.delete(ficha(plano), "reescrita")), else: plano
    plano = Enum.reduce(chaves(do_corretor), plano, &marcar(&2, &1, "corretor"))
    {plano, _} = Plano.mesclar(plano, da_ia)
    plano = Enum.reduce(chaves(da_ia), plano, &marcar(&2, &1, "iara"))

    sem_teto = extras["sem_teto"] == true
    plano = if sem_teto, do: perguntar(plano, ["teto_total"]), else: plano
    {plano, ign, %{ambiguidade: texto_ou_nil(extras["ambiguidade"]), sem_teto: sem_teto}}
  end

  defp limpo(m), do: m |> Map.reject(fn {_, v} -> v in [nil, ""] end) |> Map.new(fn {k, v} -> {k, if(is_map(v), do: limpo(v), else: v)} end)

  defp ja_dito?(plano, "criativo", _), do: origem(plano, "texto") == "corretor"
  defp ja_dito?(plano, k, _), do: origem(plano, k) == "corretor"

  defp chaves(parcial) do
    for {k, v} <- Map.delete(parcial, "conta_id"), c <- chaves(k, v), do: c
  end

  defp chaves("criativo", %{} = c), do: (if presente?(c["texto"]), do: ["texto"], else: []) ++ if(presente?(c["midia"]), do: ["criativo"], else: [])
  defp chaves(k, _), do: [k]

  defp marcar(plano, chave, quem) do
    f = ficha(plano)
    put_in(plano, ["ficha"], %{f | "origem" => Map.put(f["origem"], chave, quem)})
  end

  defp marcar_se_vazio(plano, chave, quem), do: if(origem(plano, chave) == nil, do: marcar(plano, chave, quem), else: plano)

  defp texto_ou_nil(t) when is_binary(t), do: if(String.trim(t) == "", do: nil, else: String.trim(t))
  defp texto_ou_nil(_), do: nil

  def perguntar(plano, campos) do
    f = ficha(plano)
    put_in(plano, ["ficha"], %{f | "perguntados" => Enum.uniq(f["perguntados"] ++ campos)})
  end

  # ---- o que ainda precisa ser perguntado (sempre tudo junto, numerado)
  @doc """
  Avalia a ficha: {:pronto, plano_completo} (nada a perguntar: completa com padroes e marca como sugestao) ou
  {:pergunta, plano, itens} com TODOS os itens que faltam numa lista so. `vazio`: o plano ainda nao tem nada.
  """
  def avaliar(tenant, plano) do
    base = completar(plano, tenant)
    itens = nucleo(plano) ++ extras(base)

    if itens == [], do: {:pronto, base}, else: {:pergunta, plano, itens}
  end

  defp nucleo(p) do
    perguntados = ficha(p)["perguntados"]

    (if presente?(p["objetivo"]) or presente?(p["destino"]) or presente?(p["resultado"]), do: [], else: ["objetivo"]) ++
      (if presente?(p["imovel"]) or presente?(p["url"]) or presente?(p["url_final"]), do: [], else: ["imovel"]) ++
      (if positivo?(p["orcamento_diario"]), do: [], else: ["orcamento_diario"]) ++
      (if positivo?(p["teto_total"]) or "teto_total" in perguntados, do: [], else: ["teto_total"])
  end

  # exigencias do destino e valores invalidos (o resto tem padrao)
  defp extras(base) do
    pend = Plano.pendencias(base)
    Enum.filter(pend, &(&1 in ~w(url pixel numero formulario teto_menor_que_diario teto_acima_do_maximo janela_invalida)))
  end

  @doc "Pergunta unica numerada. `repetida`: ja perguntei algo disso antes (muda o tom, nunca a lista)."
  def perguntas(itens, repetida \\ false) do
    intro = if repetida, do: "Ainda preciso de:", else: "Pra montar o plano me conta:"
    lista = itens |> Enum.with_index(1) |> Enum.map_join("\n", fn {i, n} -> "#{n}. #{pedido(i)}" end)
    intro <> "\n" <> lista <> "\nPode mandar tudo junto, por texto ou audio."
  end

  def pedido("objetivo"), do: "o que voce quer com o anuncio (vender, gerar contatos, divulgar o lancamento...)"
  def pedido("imovel"), do: "qual imovel vai anunciar"
  def pedido("orcamento_diario"), do: "quanto quer gastar por dia (em R$)"
  def pedido("teto_total"), do: "o teto total, o maximo que pode gastar (se nao tiver, eu sugiro um)"
  def pedido("numero"), do: "o numero do WhatsApp que recebe os contatos"
  def pedido("url"), do: "o link do site"
  def pedido("pixel"), do: "o pixel (codigo de rastreio do site)"
  def pedido("formulario"), do: "o id do formulario"
  def pedido("teto_menor_que_diario"), do: "(teto_menor_que_diario) o teto total precisa ser maior que a verba diaria: qual teto voce quer?"
  def pedido("teto_acima_do_maximo"), do: "(teto_acima_do_maximo) o teto passou do maximo permitido (#{Plano.brl(Config.teto_max_centavos())}): qual valor, ate esse limite?"
  def pedido("janela_invalida"), do: "(janela_invalida) a janela ficou invalida: de que dia ate que dia o anuncio roda?"
  def pedido(outro), do: Plano.rotulo(outro)

  # ---- padroes sensatos (sugestao da Iara)
  @doc "Completa so o que esta em branco (e recalcula o que ela mesma sugeriu). Nunca toca num campo dito pelo corretor."
  def completar(plano, tenant) do
    plano
    |> destino(tenant)
    |> janela()
    |> teto()
    |> publico()
    |> copy()
    |> meta()
  end

  defp destino(p, tenant) do
    p =
      if presente?(p["destino"]) do
        p
      else
        d = if presente?(p["url"]), do: "site", else: "whatsapp"
        p |> Map.put("destino", d) |> Map.put("resultado", resultado(d)) |> marcar("destino", "iara")
      end

    if p["destino"] == "whatsapp" and not presente?(p["numero"]) do
      case ultimo_numero(tenant) do
        nil -> p
        n -> p |> Map.put("numero", n) |> marcar_se_vazio("numero", "iara")
      end
    else
      p
    end
  end

  defp resultado("site"), do: "evento_pixel"
  defp resultado("whatsapp"), do: "conversa_iniciada"
  defp resultado(_), do: "lead"

  # o numero de WhatsApp que o corretor ja usou em plano anterior vira sugestao
  defp ultimo_numero(tenant) do
    tenant |> Plano.listar() |> Enum.reverse() |> Enum.find_value(fn p -> p && presente?(p["numero"]) && p["numero"] end)
  end

  defp janela(p) do
    if presente?(get_in(p, ["janela", "inicio"])) and presente?(get_in(p, ["janela", "fim"])) do
      p
    else
      hoje = Date.utc_today()
      ini = get_in(p, ["janela", "inicio"]) || Date.to_iso8601(hoje)
      inicio = case Date.from_iso8601(ini) do {:ok, d} -> d; _ -> hoje end
      fim = Date.add(inicio, Config.janela_padrao_dias() - 1)
      p |> Map.put("janela", %{"inicio" => Date.to_iso8601(inicio), "fim" => Date.to_iso8601(fim)}) |> marcar_se_vazio("janela", "iara")
    end
  end

  defp dias(p) do
    with {:ok, i} <- Date.from_iso8601(get_in(p, ["janela", "inicio"]) || ""), {:ok, f} <- Date.from_iso8601(get_in(p, ["janela", "fim"]) || "") do
      max(Date.diff(f, i) + 1, 1)
    else
      _ -> Config.janela_padrao_dias()
    end
  end

  # teto: so sugere depois de perguntar (ou quando o corretor disse que nao tem); depois recalcula enquanto for dela
  defp teto(p) do
    pergunta_feita = "teto_total" in ficha(p)["perguntados"]
    sugerir = positivo?(p["orcamento_diario"]) and (sugestao?(p, "teto_total") or (not positivo?(p["teto_total"]) and pergunta_feita))

    if sugerir do
      t = min(p["orcamento_diario"] * dias(p), Config.teto_max_centavos())
      p |> Map.put("teto_total", max(t, p["orcamento_diario"])) |> marcar("teto_total", "iara")
    else
      p
    end
  end

  defp publico(p) do
    if presente?(p["publico"]) do
      p
    else
      p |> Map.put("publico", publico_padrao(p)) |> marcar("publico", "iara")
    end
  end

  # por regiao e perfil do imovel; imovel e anuncio de HOUSING: nada de idade, genero, CEP ou perfil de pessoa
  defp publico_padrao(p) do
    case feed(p["imovel"]) do
      %{} = im ->
        onde = [im.bairro, im.regiao] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() |> Enum.join(", ")
        dorm = if presente?(im.dormitorios), do: " de #{im.dormitorios} dormitorios", else: ""
        "pessoas que moram em #{if onde == "", do: "perto do imovel", else: onde} e arredores, interessadas em comprar imovel#{dorm}"

      _ ->
        "pessoas que moram perto do imovel e nas cidades vizinhas, interessadas em comprar imovel"
    end
  end

  defp feed(nil), do: nil

  defp feed(id) do
    Feed.imovel(id)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # texto do anuncio (regras HOUSING): limpa o que a regra nao permite
  defp copy(p) do
    texto = get_in(p, ["criativo", "texto"])

    cond do
      not presente?(texto) ->
        put_texto(p, copy_padrao(p), "iara", false)

      Regex.match?(@proibidos, texto) ->
        limpo = texto |> String.split(~r/(?<=[.!?])\s+/, trim: true) |> Enum.reject(&Regex.match?(@proibidos, &1)) |> Enum.join(" ")
        put_texto(p, if(String.trim(limpo) == "", do: copy_padrao(p), else: limpo), origem(p, "texto") || "iara", true)

      true ->
        p
    end
  end

  defp put_texto(p, texto, quem, reescrita) do
    p = Map.update(p, "criativo", %{"texto" => texto}, &Map.put(&1, "texto", texto))
    p = marcar(p, "texto", quem)
    if reescrita, do: put_in(p, ["ficha"], Map.put(ficha(p), "reescrita", true)), else: p
  end

  defp copy_padrao(p) do
    case feed(p["imovel"]) do
      %{} = im ->
        dorm = if presente?(im.dormitorios), do: ", #{im.dormitorios} dormitorios", else: ""
        onde = if presente?(im.bairro), do: " em #{im.bairro}", else: ""
        "#{im.nome}#{dorm}#{onde}. Chame no WhatsApp e agende sua visita."

      _ ->
        nome = if presente?(p["imovel"]), do: p["imovel"], else: "nosso empreendimento"
        "Conheca #{nome}. Chame no WhatsApp e agende sua visita."
    end
  end

  # meta de custo por resultado: padrao da config; resultados = teto / custo (so enquanto for dela)
  defp meta(p) do
    meta = p["meta"] || %{}
    custo = meta["custo_max"] || Config.custo_resultado_padrao_centavos()
    resultados = meta["resultados"]

    cond do
      not positivo?(p["teto_total"]) ->
        p

      origem(p, "meta") == "corretor" ->
        meta = %{"custo_max" => custo, "resultados" => resultados || max(div(p["teto_total"], custo), 1)}
        Map.put(p, "meta", meta)

      true ->
        p |> Map.put("meta", %{"custo_max" => custo, "resultados" => max(div(p["teto_total"], custo), 1)}) |> marcar("meta", "iara")
    end
  end

  # ---- entrega do plano: 4 a 5 mensagens curtas, uma ideia cada
  @doc "As mensagens do plano (so texto natural): resumo, publico e destino, texto do anuncio, meta e teto, fechamento."
  def mensagens(p) do
    [resumo(p), publico_destino(p), anuncio(p), meta_teto(p), fechamento(p)]
  end

  @doc "Mensagens que mudaram entre dois planos (ajuste em linguagem natural: reenvia so a afetada) + fechamento curto."
  def diferencas(antes, depois) do
    a = mensagens(antes)
    b = mensagens(depois)
    mudadas = for {{x, y}, i} <- Enum.with_index(Enum.zip(Enum.take(a, 4), Enum.take(b, 4))), x != y, do: {i, y}
    textos = Enum.map(mudadas, &elem(&1, 1))

    case textos do
      [] -> []
      _ -> List.update_at(textos, -1, &(&1 <> " Ficou bom assim? Se estiver, me confirma."))
    end
  end

  defp sug(p, chave), do: if(origem(p, chave) == "iara", do: " (sugestao minha)", else: "")

  defp resumo(p) do
    alvo = p["imovel"] || p["url"] || "o anuncio"
    "Montei o plano #{p["id"]} pra #{alvo}. Objetivo: #{objetivo(p)}. Verba: #{Plano.brl(p["orcamento_diario"])} por dia."
  end

  defp objetivo(p) do
    cond do
      presente?(p["objetivo"]) -> p["objetivo"]
      p["resultado"] == "conversa_iniciada" -> "gerar conversas no WhatsApp"
      p["resultado"] == "lead" -> "gerar contatos pelo formulario"
      p["resultado"] == "evento_pixel" -> "levar gente ao site"
      true -> "gerar contatos"
    end
  end

  defp publico_destino(p) do
    "Publico: #{p["publico"]}#{sug(p, "publico")}. Destino: #{destino_txt(p)}#{sug(p, "destino")}."
  end

  defp destino_txt(%{"destino" => "whatsapp"} = p), do: "conversa no WhatsApp#{if presente?(p["numero"]), do: " (" <> p["numero"] <> ")", else: ""}"
  defp destino_txt(%{"destino" => "site"} = p), do: "site#{if presente?(p["url"]), do: " (" <> p["url"] <> ")", else: ""}"
  defp destino_txt(%{"destino" => "formulario"}), do: "formulario"
  defp destino_txt(_), do: "a definir"

  defp anuncio(p) do
    nota = if ficha(p)["reescrita"], do: " Tirei do texto o que a regra de anuncio de imovel nao permite.", else: ""
    "Texto do anuncio#{sug(p, "texto")}: \"#{get_in(p, ["criativo", "texto"])}\".#{nota}"
  end

  defp meta_teto(p) do
    "Meta: #{get_in(p, ["meta", "resultados"])} resultados a ate #{Plano.brl(get_in(p, ["meta", "custo_max"]))} cada#{sug(p, "meta")}. " <>
      "Teto total: #{Plano.brl(p["teto_total"])}#{sug(p, "teto_total")}. Janela: #{get_in(p, ["janela", "inicio"])} a #{get_in(p, ["janela", "fim"])}#{sug(p, "janela")}."
  end

  defp fechamento(p) do
    criativo = if presente?(get_in(p, ["criativo", "midia"])), do: "", else: " A foto ou o video do anuncio eu peco depois que voce aceitar."

    "Conferi: destino com o que precisa, teto dentro do limite (#{Plano.brl(Config.teto_max_centavos())}) e texto dentro das regras de anuncio de imovel.#{criativo} " <>
      "Eu crio tudo PAUSADO; nada vai ao ar. Quer mudar algo? E so falar. Voce confirma?"
  end
end
