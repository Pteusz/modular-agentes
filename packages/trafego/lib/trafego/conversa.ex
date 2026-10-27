defmodule Trafego.Conversa do
  @moduledoc """
  Laco da conversa: o modelo escolhe as ferramentas (Trafego.Ferramentas) e responde; o codigo cuida do resto. Contexto = persona da Iara
  + politica curta + resumo do estado (plano, proposta, ultimas trocas). Nada de ordem de perguntas nem lista de campos no prompt: o que
  falta no plano quem diz e a Ficha (ferramenta `planejar`/`ficha`).

  Limites por mensagem: 6 chamadas ao modelo, 8 chamadas de ferramenta, a mesma chamada com os mesmos argumentos 2x corta, 1 acao
  (efeito) por mensagem, 2 falhas seguidas cortam. Estourou ou deu erro: "Nao consegui concluir isso agora; nada foi alterado." + texto-base
  montado por codigo a partir da leitura que ja veio.

  Validador de saida: todo numero do texto final precisa estar num resultado de ferramenta do turno, na mensagem do corretor ou na
  ficha do plano; texto que diz "pausei/ativei/criei/alterei" sem a execucao real no turno e rejeitado. Falhou: UMA correcao pedida ao
  modelo; persistindo, fallback. Teto de custo de IA: a mesma mensagem do TetoIA, sem alterar nada.

  Apresentacao (trafego 1.12.1): sem texto pronto nem pipeline. A politica ensina o procedimento (um item por mensagem: quem sou,
  como aprendo, horario das atualizacoes) e o ESTADO traz, em dados, o que ja foi dito (Trafego.Iara.cobertura/horario). O modelo registra
  o que disse com `apresentacao` (persistido so depois que o texto passa no validador) e grava o horario com `combinar_horario`. Perguntado
  e sem escolha dele (ou ignorado), vale o padrao 9h; horario combinado = apresentacao encerrada: UMA frase confirmando o horario + pergunta natural se ele ja quer criar a
  primeira campanha (validada como gancho; uma vez so, marcada em `Iara.marcar_campanha_perguntada/1`). Falha do
  modelo no primeiro contato: UMA mensagem fixa curta (`Iara.apresentacao_minima/0`), marcada como dita.

  Devolve `{:ok, [textos], extra}` (lista de mensagens curtas) ou `{:ok, texto}` no teto.
  """
  alias Nucleo.Registro
  alias Trafego.{Diretrizes, Evento, Ferramentas, IA, Iara, Plano, Proposta, TetoIA}
  alias Trafego.Iara.{Memoria, Texto}

  @max_modelo 6
  @max_ferramentas 8
  @max_falhas 2
  @max_historico 12
  @chave "conversa_historico"
  @falha "Nao consegui concluir isso agora; nada foi alterado."

  @doc "Responde a mensagem do corretor. `origem`: \"texto\" | \"audio\"."
  def responder(tenant, texto, _origem \\ "texto") do
    historico = historico(tenant)
    plano_id = get_in(Plano.atual(tenant) || %{}, ["id"])
    diretrizes = Diretrizes.contexto(tenant)
    ctx = %{efeitos: [], leituras: %{}, entrega: nil, entrega_falha: nil, chamadas: []}

    base = %{
      instrucao: Iara.persona() <> "\n" <> Diretrizes.montar(diretrizes) <> "\n" <> estado(tenant, diretrizes.proximo_item),
      itens: historico ++ [%{"papel" => "corretor", "texto" => texto}],
      permitido: [texto, inspect(Plano.atual(tenant)), Iara.horario_padrao(), Iara.horario(tenant)],
      vistos: MapSet.new(),
      modelo: 0,
      ferramentas: 0,
      falhas: 0,
      corrigiu: false,
      plano_id: plano_id,
      horario_inicial: Iara.perfil(tenant)["horario_estado"],
      campanha_perguntada: Iara.campanha_perguntada?(tenant),
      pergunta_aberta: diretrizes.pergunta_aberta,
      validadores: Diretrizes.validadores(diretrizes),
      definicoes: Enum.reject(Ferramentas.definicoes(), &(&1["nome"] in Diretrizes.ocultas(diretrizes))),
      ocupado: ocupado?(tenant)
    }

    laco(tenant, base, ctx)
  end

  @doc "Guarda a troca (texto do corretor e o que a Iara respondeu) para o resumo das ultimas ~6 trocas."
  def registrar(_tenant, nil, _saida), do: :ok

  def registrar(tenant, texto, saida) do
    resposta = saida |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.join(" ") |> String.slice(0, 400)

    if resposta != "" do
      itens = (historico(tenant) ++ [%{"papel" => "corretor", "texto" => String.slice(texto, 0, 400)}, %{"papel" => "iara", "texto" => resposta}]) |> Enum.take(-@max_historico)
      Registro.gravar(tenant, @chave, %{"itens" => itens})
    end

    :ok
  end

  def historico(tenant), do: ((Registro.ler(tenant, @chave) || %{})["itens"] || []) |> Enum.take(-@max_historico)

  # ---- laco
  defp laco(tenant, %{modelo: n} = st, ctx) when n >= @max_modelo, do: fallback(tenant, ctx, st)

  defp laco(tenant, st, ctx) do
    entrada = %{"instrucao" => st.instrucao, "itens" => st.itens, "ferramentas" => st.definicoes}
    st = %{st | modelo: st.modelo + 1}

    case IA.turno(tenant, :media, entrada, st.plano_id) do
      {:ok, saida, uso} ->
        Evento.custo(tenant, st.plano_id, "planejador", "conversa", uso)
        passo(tenant, saida, st, ctx)

      {:error, {:teto_ia, info}} ->
        {:ok, TetoIA.mensagem(info)}

      {:error, e} ->
        Evento.emitir(tenant, "operacao", st.plano_id, "planejador", "conversa_ia_falhou", %{"erro" => erro_curto(e)})
        fallback(tenant, ctx, st)
    end
  end

  defp passo(tenant, %{"texto" => t}, st, ctx) when is_binary(t) do
    t = t |> Texto.limpar() |> String.trim()
    cx = inferir_apresentacao(tenant, t, ctx)

    case validar(t, st, cx) do
      :ok ->
        finalizar(tenant, t, cx, st)

      {:erro, motivo} when not st.corrigiu ->
        Evento.emitir(tenant, "operacao", st.plano_id, "planejador", "conversa_texto_rejeitado", %{"motivo" => aviso(motivo)})
        aviso = "Sua resposta foi rejeitada: #{aviso(motivo)} Reescreva usando so o que as ferramentas devolveram (ou chame a ferramenta que falta), sem afirmar nada que nao foi executado."
        laco(tenant, %{st | corrigiu: true, itens: st.itens ++ [%{"papel" => "iara", "texto" => t}, %{"papel" => "aviso", "texto" => aviso}]}, ctx)

      {:erro, motivo} ->
        Evento.emitir(tenant, "operacao", st.plano_id, "planejador", "conversa_texto_rejeitado", %{"motivo" => aviso(motivo)})
        fallback(tenant, ctx, st)
    end
  end

  defp passo(tenant, %{"chamadas" => [_ | _] = chamadas} = saida, st, ctx) do
    st = %{st | itens: st.itens ++ [%{"papel" => "chamadas", "bruto" => saida["bruto"] || []}]}

    case rodar_chamadas(tenant, chamadas, st, ctx) do
      {:corte, st, ctx} -> fallback(tenant, ctx, st)
      {:ok, st, ctx} -> laco(tenant, st, ctx)
    end
  end

  defp passo(tenant, _saida_estranha, st, ctx), do: fallback(tenant, ctx, st)

  defp rodar_chamadas(_tenant, [], st, ctx), do: {:ok, st, ctx}

  defp rodar_chamadas(tenant, [c | resto], st, ctx) do
    nome = c["nome"]
    args = c["args"]
    chave = {nome, args}

    cond do
      st.ferramentas >= @max_ferramentas -> {:corte, st, ctx}
      MapSet.member?(st.vistos, chave) -> {:corte, st, ctx}
      not is_map(args) -> responder_chamada(tenant, c, {:erro, %{"erro" => "argumentos_invalidos", "motivo" => "os argumentos precisam ser um objeto JSON valido"}, ctx}, resto, st)
      Ferramentas.acao?(nome) and ctx.efeitos != [] and Enum.any?(ctx.efeitos, &(elem(&1, 0) in [:pausou, :planejou, :propos])) ->
        responder_chamada(tenant, c, {:erro, %{"erro" => "uma_acao_por_mensagem", "obs" => "ja houve uma acao nesta mensagem; explique ao corretor e deixe o resto para a proxima"}, ctx}, resto, st)
      true -> responder_chamada(tenant, c, Ferramentas.executar(tenant, nome, args, ctx), resto, st)
    end
  end

  defp responder_chamada(tenant, c, {tipo, resultado, ctx}, resto, st) do
    texto = Ferramentas.codificar(resultado)
    Evento.emitir(tenant, "operacao", st.plano_id, "planejador", "conversa_ferramenta", %{"ferramenta" => to_string(c["nome"]), "ok" => tipo == :ok})
    ctx = Map.update(ctx, :chamadas, [c["nome"]], &(&1 ++ [c["nome"]]))

    st = %{
      st
      | ferramentas: st.ferramentas + 1,
        vistos: MapSet.put(st.vistos, {c["nome"], c["args"]}),
        falhas: if(tipo == :ok, do: 0, else: st.falhas + 1),
        itens: st.itens ++ [%{"papel" => "resultado", "id" => c["id"], "saida" => texto}],
        permitido: [texto | st.permitido]
    }

    if st.falhas >= @max_falhas, do: {:corte, st, ctx}, else: rodar_chamadas(tenant, resto, st, ctx)
  end

  # ---- validador de saida
  # Globais sempre; os da apresentacao (`valida` da diretriz) so se ela casou no INICIO do turno (st.validadores). Ordem fixa.
  @validadores ~w(numero_inventado afirma_sem_executar apresentacao_nao_dita sem_gancho frase_de_desligar fechamento_longo encerrou_longo)a
  @globais ~w(numero_inventado afirma_sem_executar frase_de_desligar encerrou_longo)a

  defp validar(texto, st, ctx) do
    cond do
      texto == "" and ctx.entrega == nil -> {:erro, :vazio}
      texto == "" -> :ok
      true -> Enum.find_value(@validadores, :ok, fn v -> if v in @globais or v in st.validadores, do: rodar(v, texto, st, ctx) end)
    end
  end

  defp rodar(:numero_inventado, texto, st, _ctx), do: if((n = numero_inventado(texto, st.permitido)) != nil, do: {:erro, {:numero, n}})
  defp rodar(:afirma_sem_executar, texto, _st, ctx), do: if((v = afirma_sem_executar(texto, ctx)) != nil, do: {:erro, {:afirmacao, v}})
  defp rodar(:apresentacao_nao_dita, texto, _st, ctx), do: if((i = apresentacao_nao_dita(texto, ctx)) != nil, do: {:erro, {:apresentacao, i}})
  defp rodar(:sem_gancho, texto, st, ctx), do: if(sem_gancho?(texto, st, ctx), do: {:erro, :sem_gancho})
  defp rodar(:frase_de_desligar, texto, _st, _ctx), do: if((f = frase_de_desligar(texto)) != nil, do: {:erro, {:desligar, f}})
  defp rodar(:fechamento_longo, texto, st, ctx), do: if(lembrou_horario?(ctx) and fecha_apresentacao?(st, ctx) and String.length(texto) > 300, do: {:erro, :encerramento})

  defp rodar(:encerrou_longo, texto, st, ctx),
    do: if(lembrou_horario?(ctx) and not fecha_apresentacao?(st, ctx) and (String.contains?(texto, "?") or String.length(texto) > 200), do: {:erro, :encerramento})

  # o item registrado precisa aparecer no texto (o estado grava so o que foi realmente dito)
  defp apresentacao_nao_dita(texto, ctx) do
    n = norm(texto)

    Enum.find_value(ctx.efeitos, fn
      {:apresentou, "quem_sou"} -> if String.contains?(n, "iara"), do: nil, else: "quem_sou"
      {:apresentou, "como_aprendo"} -> if n =~ ~r/aprend|adapt|melhor/, do: nil, else: "como_aprendo"
      {:apresentou, "horario_perguntado"} -> if String.contains?(n, "?") and n =~ ~r/hora|\d\s*h/, do: nil, else: "horario_perguntado"
      _ -> nil
    end)
  end

  # gancho: a mensagem que entrega um item da apresentacao (sem encerrar) termina numa pergunta de verdade, que vale ele responder.
  # Criterio: a ultima frase e uma pergunta com 4 palavras ou mais ("Ja mexeu com anuncio de imovel?" vale; "Certo?" / "Entendeu?" nao).
  # O fechamento (horario combinado pela primeira vez, sem outra acao) tambem exige gancho: a pergunta de primeira campanha.
  defp sem_gancho?(texto, st, ctx) do
    entrega = Enum.any?(ctx.efeitos, &match?({:apresentou, _}, &1))
    encerra = Enum.any?(ctx.efeitos, &(&1 == {:lembrou, "horario_atualizacao"}))
    ((entrega and not encerra) or fecha_apresentacao?(st, ctx)) and not gancho?(texto)
  end

  # horario combinado e nada mais nesta mensagem, antes de a pergunta de primeira campanha ter sido feita, sem plano/proposta no ar
  defp fecha_apresentacao?(st, ctx) do
    so_horario(ctx) and Enum.any?(ctx.efeitos, &(&1 == {:lembrou, "horario_atualizacao"})) and not st.campanha_perguntada and not st.ocupado
  end

  defp so_horario(ctx), do: ctx.chamadas != [] and Enum.all?(ctx.chamadas, &(&1 in ["combinar_horario", "lembrar"]))

  @doc false
  def gancho?(texto) do
    limpo = texto |> String.trim() |> String.replace(~r/[^\p{L}\p{N}?!.]+$/u, "")

    String.ends_with?(limpo, "?") and
      (limpo |> String.trim_trailing("?") |> String.split(~r/[.!?]+\s+/u) |> List.last() |> String.split() |> length()) >= 4
  end

  @desligar ~r/\bnao\s+(da|posso|pode|consigo|e possivel|tem como|ha como)\b.{0,15}\b(desligar|desativar)|impossivel\s+(desligar|desativar)|nao\s+(pode|podem)\s+ser\s+(desligad|desativad)/u

  @doc false
  # frase que fala que nao da para desligar (a regra continua no codigo; a Iara nao a comenta nem a nega com "nao posso")
  def frase_de_desligar(texto) do
    case Regex.run(@desligar, norm(texto)) do
      [f | _] -> f
      nil -> nil
    end
  end

  # horario combinado e nada mais nesta mensagem: confirma em uma frase curta. No fechamento da apresentacao (`fechamento_longo`, da
  # diretriz :apresentacao) leva a pergunta de primeira campanha (ate 300 caracteres); numa mudanca de horario posterior (`encerrou_longo`,
  # global; pergunta ja feita) fica sem "?" e curta.
  defp lembrou_horario?(ctx), do: so_horario(ctx) and Enum.any?(ctx.efeitos, &(&1 == {:lembrou, "horario_atualizacao"}))

  defp aviso({:numero, n}), do: "o numero \"#{n}\" nao aparece em nenhum resultado de ferramenta, na mensagem do corretor nem na ficha."
  defp aviso({:afirmacao, v}), do: "voce afirmou \"#{v}\" mas nenhuma ferramenta executou isso nesta mensagem."
  defp aviso(:vazio), do: "a resposta veio vazia."
  defp aviso({:apresentacao, i}), do: "voce registrou \"#{i}\" na apresentacao mas o texto nao diz isso (registre so o que disse)."
  defp aviso(:sem_gancho), do: "a mensagem da apresentacao precisa terminar com uma pergunta natural (4 palavras ou mais) que valha ele responder, ligada ao que ele falou (no fechamento do horario: se ele ja esta pronto pra criar a primeira campanha com voce)."
  defp aviso({:desligar, _}), do: "nao diga que \"nao da\" ou \"nao pode\" desligar; se ele pediu, ofereca ajustar o horario das atualizacoes, curto e natural."
  defp aviso(:encerramento), do: "o horario ficou combinado: confirme em UMA frase curta (se ainda nao perguntou, termine com a pergunta de primeira campanha; se ja perguntou, sem pergunta nenhuma)."

  @numero ~r/\d+(?:[.,]\d+)*/

  @doc false
  # primeiro numero do texto que nao esta nas fontes permitidas (ou nil). Normaliza: so digitos, sem zeros a esquerda; "R$ 50" casa com "R$ 50,00".
  def numero_inventado(texto, fontes) do
    ok =
      fontes
      |> Enum.flat_map(&Regex.scan(@numero, &1))
      |> Enum.flat_map(fn [t] -> variantes(t) end)
      |> MapSet.new()

    texto |> then(&Regex.scan(@numero, &1)) |> Enum.map(&hd/1) |> Enum.find(fn t -> normalizar(t) != "0" and not MapSet.member?(ok, normalizar(t)) end)
  end

  defp normalizar(t) do
    d = String.replace(t, ~r/\D/, "") |> String.trim_leading("0")
    if d == "", do: "0", else: d
  end

  # um numero da fonte vale tambem sem os centavos zerados ("R$ 50,00" ~ "50")
  defp variantes(t) do
    n = normalizar(t)
    if String.ends_with?(t, ",00") or String.ends_with?(t, ".00"), do: [n, normalizar(String.slice(t, 0, String.length(t) - 3))], else: [n]
  end

  @verbos ~r/\b(pausei|ativei|criei|alterei|mudei|editei|desativei|cancelei|apaguei|excluí|exclui|aumentei|diminui|reduzi|subi|desliguei)\b/

  defp afirma_sem_executar(texto, ctx) do
    n = texto |> String.downcase() |> :unicode.characters_to_nfd_binary() |> String.replace(~r/\p{Mn}/u, "")

    case Regex.run(@verbos, n) do
      [_, "pausei"] -> if Enum.any?(ctx.efeitos, &match?({:pausou, _}, &1)), do: nil, else: "pausei"
      [_, v] when v in ["alterei", "mudei"] -> if Enum.any?(ctx.efeitos, &match?({:lembrou, _}, &1)), do: nil, else: v
      [_, v] -> v
      nil -> nil
    end
  end

  # ---- saida
  defp finalizar(tenant, texto, ctx, st) do
    registrar_apresentacao(tenant, ctx, st)
    nt = norm(texto)
    # a entrega montada por codigo (resumo/proposta) nao e repetida se o modelo ja a reproduziu
    entrega = Enum.reject(entrega_textos(ctx.entrega), &(is_binary(&1) and String.contains?(nt, norm(&1))))
    partes = [texto, pausas_sem_motivo(texto, ctx)] ++ entrega
    saida(tenant, partes, ctx)
  end

  # registro automatico do item da apresentacao (sem chamada extra ao modelo): so se for o proximo item, nada esta no ar e o texto
  # realmente o diz. O modelo pode ainda registrar com a ferramenta `apresentacao`; o que ele ja registrou vale.
  defp inferir_apresentacao(tenant, texto, ctx) do
    feitos = for {:apresentou, i} <- ctx.efeitos, do: i
    so_horario = ctx.chamadas != [] and Enum.any?(ctx.chamadas, &(&1 in ["combinar_horario", "lembrar"]))

    if feitos != [] or so_horario or ocupado?(tenant) do
      ctx
    else
      n = norm(texto)

      item =
        case Iara.proximo_item(tenant) do
          "quem_sou" -> if n =~ ~r/\biara\b/ and n =~ ~r/\b(ia|inteligencia artificial)\b/, do: "quem_sou"
          "como_aprendo" -> if n =~ ~r/aprend|adapt|melhoro/, do: "como_aprendo"
          i when i in ["perguntar_horario", "aguardar_horario"] -> if String.ends_with?(String.trim(n), "?") and n =~ ~r/hora|\d\s*h\b/, do: "horario_perguntado"
          _ -> nil
        end

      if item, do: %{ctx | efeitos: ctx.efeitos ++ [{:apresentou, item}]}, else: ctx
    end
  end

  defp ocupado?(tenant) do
    plano = Plano.atual(tenant)
    (plano != nil and plano["status"] in ["rascunho", "aguardando_confirmacao", "aguardando_criativo"]) or Proposta.atual(tenant) != nil or Memoria.pegar(tenant) != nil
  end

  # grava o que a Iara realmente disse; perguntou o horario e ele nao escolheu (ou mudou de assunto): vale o padrao 9h
  defp registrar_apresentacao(tenant, ctx, st) do
    for {:apresentou, item} <- ctx.efeitos, do: Iara.cobrir(tenant, item)
    if fecha_apresentacao?(st, ctx), do: Iara.marcar_campanha_perguntada(tenant)
    # o corretor respondeu a pergunta aberta (marcador do INICIO do turno; o turno que a faz nao a fecha). Fallback nao passa por aqui.
    if st.pergunta_aberta, do: Iara.fechar_pergunta(tenant)

    reperguntou = Enum.any?(ctx.efeitos, &(&1 == {:apresentou, "horario_perguntado"}))

    if st.horario_inicial == "perguntado" and Iara.perfil(tenant)["horario_estado"] == "perguntado" and not reperguntou do
      Iara.assumir_padrao(tenant)
      Evento.emitir(tenant, "operacao", st.plano_id, "planejador", "horario_padrao_assumido", %{"horario" => Iara.horario_padrao()})
    end

    :ok
  end

  # pausa carrega o motivo: se o modelo nao disse (campanha + motivo), o codigo anexa "Pausei X porque ..."
  defp pausas_sem_motivo(texto, ctx) do
    n = norm(texto)

    for {:pausou, info} <- ctx.efeitos, not (String.contains?(n, norm(info.nome)) and String.contains?(n, "porque")), into: [] do
      "Pausei #{info.nome} porque #{info.motivo}."
    end
    |> Enum.join(" ")
  end

  defp saida(tenant, partes, ctx) do
    lista = partes |> List.flatten() |> Enum.map(&to_string/1) |> Enum.map(&Texto.limpar/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    Evento.emitir(tenant, "operacao", nil, "planejador", "conversa_resposta", %{"efeitos" => Enum.map(ctx.efeitos, &elem(&1, 0))})

    case lista do
      [] -> {:ok, [@falha], []}
      _ -> {:ok, lista, entrega_extra(ctx.entrega)}
    end
  end

  defp entrega_textos({:ok, base, _extra}), do: List.wrap(base)
  defp entrega_textos({:ok, base}), do: List.wrap(base)
  defp entrega_textos(_), do: []

  defp entrega_extra({:ok, _, extra}) when is_list(extra), do: Keyword.take(extra, [:situacao, :plano_id])
  defp entrega_extra(_), do: []

  # estourou limite, erro do modelo ou texto rejeitado 2x
  defp fallback(tenant, ctx, st) do
    if ctx.efeitos == [] and ctx.entrega == nil and not Iara.cobertura(tenant)["quem_sou"],
      do: primeiro_contato_fixo(tenant, ctx),
      else: fallback_normal(tenant, ctx, st)
  end

  # modelo falhou no primeiro contato: UMA mensagem fixa curta (apresentacao minima), marcada como dita
  defp primeiro_contato_fixo(tenant, ctx) do
    Iara.cobrir(tenant, "quem_sou")
    saida(tenant, [Iara.apresentacao_minima()], ctx)
  end

  defp fallback_normal(tenant, ctx, st) do
    if fecha_apresentacao?(st, ctx), do: fechamento_fixo(tenant, ctx), else: fallback_comum(tenant, ctx)
  end

  # modelo falhou no fechamento: o horario ja foi gravado; confirma e pergunta da primeira campanha (variacao pelo horario)
  @fechamentos [
    "Fechado, todo dia às %{hh}. Já quer criar a sua primeira campanha comigo?",
    "Combinado, às %{hh} todo dia. Bora montar a sua primeira campanha agora?",
    "Pronto, ficou %{hh}. Você já está pronto pra criar a primeira campanha comigo?"
  ]

  defp fechamento_fixo(tenant, ctx) do
    hh = Iara.horario(tenant)
    modelo = Enum.at(@fechamentos, :erlang.phash2({tenant, hh}, length(@fechamentos)))
    Iara.marcar_campanha_perguntada(tenant)
    saida(tenant, [String.replace(modelo, "%{hh}", hh)], ctx)
  end

  defp fallback_comum(tenant, ctx) do
    pausas = for {:pausou, i} <- ctx.efeitos, do: "Pausei #{i.nome} porque #{i.motivo}."
    cabeca = if ctx.efeitos == [] and ctx.entrega == nil, do: @falha, else: "Nao consegui concluir tudo agora."

    saida(tenant, [cabeca, pausas, texto_base(ctx.leituras)] ++ entrega_textos(ctx.entrega), ctx)
  end

  # texto-base montado por codigo a partir da leitura que ja veio (nunca do modelo)
  defp texto_base(%{"campanhas" => %{"campanhas" => [_ | _] = l}}) do
    "Suas campanhas: " <> Enum.map_join(l, "; ", fn c -> "#{c["id"]} #{c["nome"]} (#{c["status"]}#{if c["gasto"], do: ", gasto #{c["gasto"]}"})" end) <> "."
  end

  defp texto_base(%{"saldo_e_teto" => %{"teto_de_ia_do_mes" => t, "gasto_de_ia_no_mes" => g}}), do: "Teto de IA do mes: #{t} (gasto #{g})."
  defp texto_base(_), do: ""

  # ---- estado (resumo para o modelo; nunca lista de campos)
  defp estado(tenant, proximo) do
    plano = Plano.atual(tenant)
    prop = Proposta.atual(tenant)

    linhas =
      [
        plano && "Plano em andamento #{plano["id"]} (#{plano["status"]}). #{situacao_plano(plano)}",
        prop && "Proposta aberta #{prop["id"]} (#{if prop["tipo"] == "ajustar", do: "ajustar a campanha #{prop["campanha_nome"]}", else: "#{prop["tipo"]} do plano #{prop["plano_id"]}"}), aguardando o sim ou nao do corretor; ele nao respondeu isso agora: responda o que ele perguntou e o sistema retoma a confirmacao.",
        plano == nil && prop == nil && "Nao ha plano nem proposta abertos."
      ]
      |> Enum.filter(& &1)

    "ESTADO:\n" <> Enum.join(linhas, "\n") <> "\n" <> estado_apresentacao(tenant, plano, prop, proximo)
  end

  # dados, nao roteiro: o que ja foi dito, o horario e o unico proximo item (a politica ensina o que fazer com ele)
  defp estado_apresentacao(tenant, _plano, _prop, proximo) do
    c = Iara.cobertura(tenant)
    p = Iara.perfil(tenant)
    sn = fn v -> if v, do: "sim", else: "nao" end

    horario =
      case p["horario_estado"] do
        "definido" -> "combinado, #{p["horario"]}"
        "padrao" -> "padrao #{p["horario"]} (ele nao escolheu)"
        "perguntado" -> "perguntado #{Iara.perguntas_horario(tenant)}x, sem escolha ainda"
        _ -> "ainda nao perguntado"
      end

    ocupado = ocupado?(tenant)
    campanha = Iara.campanha_perguntada?(tenant)

    quando =
      cond do
        proximo == nil and not campanha -> "o horario foi combinado: confirme em uma frase e termine perguntando se ele ja esta pronto pra criar a primeira campanha (regra f)."
        proximo == nil -> "apresentacao encerrada: nao traga mais nada dela."
        ocupado -> "ha plano, proposta ou confirmacao em andamento: NAO traga apresentacao agora, atenda o que esta no ar."
        true -> "proximo item (UM so, e so se a mensagem dele deixar espaco): #{proximo}."
      end

    "APRESENTACAO: se_apresentou=#{sn.(c["quem_sou"])}; explicou_que_aprende=#{sn.(c["como_aprendo"])}; horario_das_atualizacoes=#{horario}; campanha_perguntada=#{sn.(campanha)}. #{quando}"
  end

  defp situacao_plano(%{"status" => "aguardando_confirmacao"}), do: "O corretor precisa responder sim ou nao ao resumo; nao execute nada por ele."
  defp situacao_plano(%{"status" => "aguardando_criativo"}), do: "Falta so a foto ou o video do anuncio."
  defp situacao_plano(%{"status" => "rascunho"} = p), do: if(Plano.vazio?(p), do: "Vazio.", else: "Em montagem; use `planejar` com a resposta dele ou `ficha` para ver o que falta.")
  defp situacao_plano(_), do: ""

  defp norm(t), do: t |> to_string() |> String.downcase() |> :unicode.characters_to_nfd_binary() |> String.replace(~r/\p{Mn}/u, "")

  defp erro_curto({tipo, _}) when is_atom(tipo), do: Atom.to_string(tipo)
  defp erro_curto(e) when is_atom(e), do: Atom.to_string(e)
  defp erro_curto(_), do: "erro"
end
