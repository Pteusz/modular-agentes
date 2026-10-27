defmodule Trafego.Agente do
  @moduledoc """
  Conversa do corretor com o agente de trafego (texto do chat dele consigo mesmo). Papeis:
  planejador (IA, via Trafego.IA): monta/revisa o plano e le a confirmacao em texto livre;
  executor (sem IA), verificador decidivel e monitor (esqueleto) ficam nos proprios modulos.
  Estado: um plano "atual" por tenant (rascunho ou aguardando confirmacao). Nenhuma alteracao sem confirmacao clara:
  ambigua -> repergunta curta; negativa -> recusa. O texto do corretor nao vira evento.

  Voz (etapa 5.1): as funcoes internas decidem os FATOS e devolvem o texto-base; `entregar/4` passa TODA resposta por
  `Trafego.Iara.falar` (persona). A apresentacao (primeiro contato, horario das atualizacoes) nao e injetada aqui: e conduzida pela
  conversa (Trafego.Conversa), uma mensagem por vez. Audio e texto sao a mesma coisa para o dominio:
  so uma transcricao duvidosa gera uma pergunta "e isso mesmo?" antes de agir (a fala em duvida fica so em memoria).
  """
  alias Nucleo.Registro
  alias Trafego.{Acesso, Aprendizado, Ativacao, Config, Criativo, Evento, Executor, Conversa, Ficha, IA, Iara, Plano, Proposta, TetoIA, Verificador}
  alias Trafego.Iara.Memoria

  @nome "Nucleo.Automacoes.Trafego"
  @repergunta "so pra confirmar se entendi, posso fazer isso mesmo?"

  @doc "Como `processar_mensagens/2`, mas com as mensagens do plano juntas num texto so (separadas por linha em branco)."
  def processar(tenant, texto), do: tenant |> processar_mensagens(texto) |> juntar()

  @doc "Como `receber_midia_mensagens/2`, com o texto juntado."
  def receber_midia(tenant, msg), do: tenant |> receber_midia_mensagens(msg) |> juntar()

  @doc "Como `receber_criativo_mensagens/3`, com o texto juntado."
  def receber_criativo(tenant, nome, bytes), do: tenant |> receber_criativo_mensagens(nome, bytes) |> juntar()

  defp juntar({:ok, [_ | _] = l}), do: {:ok, Enum.join(l, "

")}
  defp juntar(r), do: r

  @doc """
  Processa uma mensagem do corretor (texto, ou a transcricao de um audio). {:ok, resposta} | {:error, motivo}
  `resposta` e um texto, ou uma lista de textos curtos (o plano sai em 4 a 5 mensagens; o Laco envia uma a uma).
  Ordem: fala de audio em duvida aguardando "e isso mesmo?"; plano aguardando confirmacao;
  proposta aberta (ativar/pausar); senao a CONVERSA (Trafego.Conversa: o modelo escolhe ferramentas, o codigo valida a saida).
  Nos leitores de sim/nao, o que nao for sim nem nao vai para a conversa, que responde e retoma a confirmacao pendente.
  """
  def processar_mensagens(tenant, texto), do: seguro(tenant, "texto", fn -> gate(tenant, texto, "texto", fn -> conversa(tenant, texto, "texto") end) end)

  # Nenhuma excecao deixa o corretor no silencio (o Laco so registra o evento): vira resposta amigavel. O evento leva so o tipo
  # da excecao (nunca a mensagem, que poderia carregar conteudo do corretor).
  defp seguro(tenant, origem, f) do
    f.()
  rescue
    e ->
      Evento.emitir(tenant, "operacao", nil, "planejador", "conversa_excecao", %{"erro" => inspect(e.__struct__), "origem" => origem})
      {:ok, texto_falha(origem)}
  catch
    tipo, _ ->
      Evento.emitir(tenant, "operacao", nil, "planejador", "conversa_excecao", %{"erro" => inspect(tipo), "origem" => origem})
      {:ok, texto_falha(origem)}
  end

  defp texto_falha("audio"), do: "Tive um problema ao tratar esse audio. Tenta mandar de novo ou escreve por texto; nada foi alterado."
  defp texto_falha(_), do: "Tive um problema aqui e nao consegui tratar sua mensagem. Tenta de novo em instantes; nada foi alterado."

  # ativo + credencial valida antes de qualquer coisa (sem IA, sem gasto); token invalido responde na voz da Iara
  defp gate(tenant, texto, origem, f) do
    with :ok <- ativo(tenant) do
      case credencial(tenant) do
        :ok -> f.()
        {:ok, msg} -> entregar(tenant, {:ok, msg}, texto, origem)
        erro -> erro
      end
    end
  end

  defp despachar(tenant, texto) do
    plano = Plano.atual(tenant)
    prop = Proposta.atual(tenant)

    cond do
      match?(%{"status" => "aguardando_confirmacao"}, plano) -> confirmar(tenant, plano, texto)
      match?(%{"status" => "aguardando_criativo"}, plano) -> esperar_criativo(tenant, plano, texto)
      match?(%{"status" => "erro"}, plano) -> retomar(tenant, plano, texto)
      prop != nil -> confirmar_proposta(tenant, prop, texto)
      true -> Conversa.responder(tenant, texto)
    end
  end

  # a conversa respondeu o que nao era sim nem nao; a confirmacao pendente volta no fim, uma pergunta so
  defp conversar_pendente(tenant, texto) do
    case Conversa.responder(tenant, texto) do
      {:ok, lista, extra} when is_list(lista) ->
        ultima = List.last(lista)

        if extra[:situacao] == :plano or String.contains?(ultima, "confirma"),
          do: {:ok, lista, extra},
          else: {:ok, List.replace_at(lista, -1, ultima <> retomada_pendente(tenant)), extra}

      outro ->
        outro
    end
  end

  defp retomada_pendente(tenant) do
    case retomada(tenant) do
      "" -> if Proposta.atual(tenant), do: " Sobre a proposta: você confirma?", else: ""
      r -> r
    end
  end

  # ---- conversa (texto e audio): fala em duvida pendente -> fluxo normal
  defp conversa(tenant, texto, origem) do
    case Memoria.pegar(tenant) do
      nil -> seguir(tenant, texto, origem)
      fala -> audio_pendente(tenant, fala, texto, origem)
    end
  end

  defp seguir(tenant, texto, origem), do: entregar(tenant, despachar(tenant, texto), texto, origem)

  # depois de responder outro assunto, volta ao que estava no ar (uma pergunta so)
  defp retomada(tenant) do
    case Plano.atual(tenant) do
      %{"status" => "rascunho"} = p -> if Plano.vazio?(p), do: "", else: " " <> pergunta_pendente(tenant, p)
      %{"status" => "aguardando_confirmacao", "id" => _id} -> " Sobre o plano: você confirma?"
      %{"status" => "aguardando_criativo", "id" => _id} -> " Sobre o plano: falta só a foto ou o vídeo do anúncio."
      %{"status" => "erro", "id" => _id} -> " O plano parou por erro: me diz o que ajustar que eu tento de novo."
      _ -> ""
    end
  end

  defp pergunta_pendente(tenant, plano) do
    case Ficha.avaliar(tenant, plano) do
      {:pergunta, p, itens} -> Ficha.perguntas(itens, true, p)
      _ -> ""
    end
  end

  # fala em duvida (audio): o corretor responde por texto OU audio; "sim" processa a fala como texto
  defp audio_pendente(tenant, fala, texto, origem) do
    if not resposta_curta?(texto) do
      Memoria.limpar(tenant)
      seguir(tenant, texto, origem)
    else
      case IA.chamar(tenant, :pequena, :confirmar, %{"texto" => texto, "plano" => nil, "resumo" => "o corretor confirma que e isso mesmo que ele falou no audio"}) do
        {:ok, %{"decisao" => d}, uso} ->
          Evento.custo(tenant, nil, "planejador", "confirmar", uso)
          decidir_audio(tenant, fala, d, texto, origem)

        {:error, {:teto_ia, info}} ->
          entregar(tenant, {:ok, TetoIA.mensagem(info)}, texto, origem)

        {:error, _} ->
          entregar(tenant, {:ok, repergunta_audio(fala)}, texto, origem)
      end
    end
  end

  defp decidir_audio(tenant, fala, "sim", _texto, _origem) do
    Memoria.limpar(tenant)
    seguir(tenant, fala, "audio")
  end

  defp decidir_audio(tenant, _fala, "nao", texto, origem) do
    Memoria.limpar(tenant)
    entregar(tenant, {:ok, "Ok, deixei esse audio de lado; nada foi alterado. Me conta de novo, por audio ou texto."}, texto, origem)
  end

  defp decidir_audio(tenant, fala, _, texto, origem), do: entregar(tenant, {:ok, repergunta_audio(fala)}, texto, origem)

  defp repergunta_audio(fala), do: "Ainda nao tenho certeza do que ouvi: \"#{fala}\". E isso mesmo?"

  # ---- voz: texto-base -> fala da Iara
  # res: {:ok, base} | {:ok, base, extra} (extra: situacao, dados, plano_id, vazio) | {:error, _}
  defp entregar(tenant, res, texto, origem) do
    r = entrega(tenant, res, texto, origem)
    with {:ok, saida} <- r, do: Conversa.registrar(tenant, texto, saida)
    r
  end

  defp entrega(_tenant, {:error, _} = e, _, _), do: e
  defp entrega(tenant, {:ok, base}, texto, origem), do: entrega(tenant, {:ok, base, []}, texto, origem)

  # plano em varias mensagens curtas (texto fixo, sem IA)
  defp entrega(_tenant, {:ok, [_ | _] = lista, _extra}, _texto, _origem), do: {:ok, lista}

  defp entrega(tenant, {:ok, base, extra}, texto, origem) when is_binary(base) do
    falar_opts = [texto: texto, origem: origem] ++ Keyword.take(extra, [:situacao, :dados, :plano_id, :contexto, :fixo, :numeradas])
    {:ok, Iara.falar(tenant, base, falar_opts)}
  end

  # resposta curta a uma pergunta do sistema (so a fala de audio em duvida usa): texto longo ou com ";" e outro assunto
  defp resposta_curta?(texto), do: String.length(texto) < 120 and not String.contains?(texto, ";")

  defp confirmar_proposta(tenant, prop, texto) do
    case IA.chamar(tenant, :pequena, :confirmar, %{"texto" => texto, "plano" => prop["plano_id"], "resumo" => "proposta #{prop["tipo"]}"}) do
      {:ok, %{"decisao" => d}, uso} ->
        Evento.custo(tenant, prop["plano_id"], "planejador", "confirmar", uso)
        decidir_proposta(tenant, prop, d, texto)

      {:error, {:teto_ia, info}} ->
        {:ok, TetoIA.mensagem(info)}

      {:error, _} ->
        {:ok, @repergunta}
    end
  end

  defp decidir_proposta(tenant, prop, "sim", _texto) do
    Evento.emitir(tenant, "confirmacao", prop["plano_id"], "planejador", "sim", %{"proposta_id" => prop["id"]})
    Proposta.salvar(tenant, Map.put(prop, "status", "confirmado"))

    case Ativacao.executar(tenant, prop["id"]) do
      {:ok, texto} -> {:ok, texto}
      {:error, _} -> {:ok, "Não consegui executar a proposta; nada foi alterado."}
    end
  end

  defp decidir_proposta(tenant, prop, "nao", _texto) do
    Evento.emitir(tenant, "confirmacao", prop["plano_id"], "planejador", "nao", %{"proposta_id" => prop["id"]})
    Proposta.salvar(tenant, Map.put(prop, "status", "recusada"))
    {:ok, "Ok, cancelei a proposta; nada foi alterado."}
  end

  defp decidir_proposta(tenant, prop, _, texto) do
    Evento.emitir(tenant, "confirmacao", prop["plano_id"], "planejador", "ambigua", %{"proposta_id" => prop["id"]})
    conversar_pendente(tenant, texto)
  end

  @doc """
  Criativo enviado pelo corretor (bytes + nome do arquivo). Conferencia decidivel (Trafego.Criativo): reprovado nao entra e a
  resposta diz o motivo; aprovado e guardado e vira o criativo do plano em andamento, que volta a pedir confirmacao.
  """
  def receber_criativo_mensagens(tenant, nome, bytes), do: gate(tenant, nil, "texto", fn -> entregar(tenant, criativo(tenant, nome, bytes), nil, "texto") end)

  defp criativo(tenant, nome, bytes) do
    case Plano.atual(tenant) do
      nil ->
        {:ok, "Nao ha plano em andamento; me conta o que quer anunciar e depois manda o criativo."}

      plano ->
        case Criativo.conferir(bytes) do
          {:ok, info} -> aceitar_criativo(tenant, plano, nome, bytes, info)
          {:error, motivos} -> {:ok, "Esse criativo nao serve: #{Criativo.explicar(motivos)}. Manda outro arquivo."}
        end
    end
  end

  @doc """
  Midia que chegou pelo canal (Amarula). Baixa e passa pela mesma conferencia. Se nao der para baixar, avisa e propoe
  alternativa (mandar como documento ou colocar o arquivo no painel) em vez de fingir que recebeu.
  """
  def receber_midia_mensagens(tenant, %Amarula.Msg{content: %Amarula.Content.Media{kind: :audio}} = msg), do: seguro(tenant, "audio", fn -> receber_audio(tenant, msg) end)

  def receber_midia_mensagens(tenant, %Amarula.Msg{content: %Amarula.Content.Media{kind: kind}} = msg) when kind in [:image, :document, :video] do
    seguro(tenant, "midia", fn -> gate(tenant, nil, "texto", fn -> entregar(tenant, midia_criativo(tenant, msg), nil, "texto") end) end)
  end

  def receber_midia_mensagens(tenant, _msg) do
    gate(tenant, nil, "texto", fn -> entregar(tenant, {:ok, "So aceito imagem (png ou jpg) ou video mp4 como criativo, ou audio (nota de voz)."}, nil, "texto") end)
  end

  defp midia_criativo(tenant, msg) do
    case baixar(msg) do
      {:ok, bytes} when is_binary(bytes) ->
        with {:ok, info} <- Criativo.conferir(bytes) do
          criativo(tenant, "criativo_#{System.unique_integer([:positive])}" <> extensao(info.formato), bytes)
        else
          {:error, motivos} -> {:ok, "Esse criativo nao serve: #{Criativo.explicar(motivos)}. Manda outro arquivo."}
        end

      _ ->
        Evento.emitir(tenant, "operacao", nil, "planejador", "midia_nao_baixou", %{"erro" => "download_falhou"})
        {:ok, "Recebi o aviso da midia mas nao consegui baixar o arquivo. Tenta mandar de novo como documento (sem compressao) ou coloca o arquivo no painel."}
    end
  end

  # ---- audio (nota de voz): baixa na memoria, transcreve (com o teto de IA) e a fala entra no fluxo normal COMO TEXTO
  # (decisao do Mateus em 2026-10-19: audio confirma plano, ativar e pausar como o texto). Se a transcricao ficou duvidosa ou
  # ambigua, a Iara diz o que ficou ambiguo e pergunta "e isso mesmo?" antes de agir (a fala fica so em memoria, por pouco tempo).
  # O audio e a transcricao nao vao para disco, evento ou log; so metadados (segundos, custo).
  defp receber_audio(tenant, %Amarula.Msg{content: c}) do
    max_seg = Config.audio(:max_segundos, 120)
    max_bytes = Config.audio(:max_bytes, 10_000_000)
    dizer = fn msg -> entregar(tenant, {:ok, msg}, nil, "audio") end

    gate(tenant, nil, "audio", fn ->
      cond do
        is_integer(c.seconds) and c.seconds > max_seg ->
          dizer.("Esse audio e muito longo (limite de #{max_seg} segundos). Manda um mais curto ou escreve por texto; nada foi alterado.")

        is_integer(c.file_length) and c.file_length > max_bytes ->
          dizer.("Esse audio e muito grande para eu transcrever. Manda um mais curto ou escreve por texto; nada foi alterado.")

        true ->
          case baixar(%Amarula.Msg{channel: :audio, type: :media, raw: nil, content: c}) do
            {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > max_bytes ->
              dizer.("Esse audio e muito grande para eu transcrever. Manda um mais curto ou escreve por texto; nada foi alterado.")

            {:ok, bytes} when is_binary(bytes) ->
              transcrever_audio(tenant, bytes, c)

            _ ->
              Evento.emitir(tenant, "operacao", nil, "planejador", "audio_nao_baixou", %{"erro" => "download_falhou"})
              dizer.("Recebi o aviso do audio mas nao consegui baixar. Tenta mandar de novo ou escreve por texto; nada foi alterado.")
          end
      end
    end)
  end

  defp transcrever_audio(tenant, bytes, c) do
    # sem duracao no aviso: estima por ~2 KB/s (nota de voz opus), para cima, so para o custo
    segundos = if is_integer(c.seconds) and c.seconds > 0, do: c.seconds, else: max(1, ceil(byte_size(bytes) / 2000))

    case IA.transcrever(tenant, bytes, %{mime: c.mimetype, segundos: segundos}) do
      {:ok, texto, uso} ->
        Evento.custo_audio(tenant, "planejador", "transcrever", uso)
        Evento.emitir(tenant, "operacao", nil, "planejador", "audio_transcrito", %{"segundos" => uso["segundos"]})

        case if(String.valid?(texto), do: String.trim(texto), else: "") do
          "" -> entregar(tenant, {:ok, "Nao consegui entender o audio. Tenta de novo falando mais perto do microfone ou escreve por texto; nada foi alterado."}, nil, "audio")
          fala -> audio_como_texto(tenant, fala)
        end

      {:error, {:teto_ia, info}} ->
        entregar(tenant, {:ok, TetoIA.mensagem(info)}, nil, "audio")

      {:error, e} ->
        Evento.emitir(tenant, "operacao", nil, "planejador", "audio_falhou", %{"erro" => erro_curto(e)})
        entregar(tenant, {:ok, "Nao consegui transcrever esse audio agora. Tenta de novo em instantes ou escreve por texto; nada foi alterado."}, nil, "audio")
    end
  end

  defp erro_curto({tipo, _}) when is_atom(tipo), do: Atom.to_string(tipo)
  defp erro_curto(e) when is_atom(e), do: Atom.to_string(e)
  defp erro_curto(_), do: "erro"

  # Audio = texto. So se a transcricao ficou duvidosa a Iara diz o que ficou ambiguo e pergunta "e isso mesmo?" (fala so em memoria).
  defp audio_como_texto(tenant, fala) do
    case Iara.duvida_audio(tenant, fala) do
      :ok ->
        conversa(tenant, fala, "audio")

      {:duvida, d} ->
        Memoria.guardar(tenant, fala)
        entregar(tenant, {:ok, "Nao tenho certeza do que ouvi: #{d}. Entendi: \"#{fala}\". E isso mesmo?"}, fala, "audio")

      {:teto, info} ->
        entregar(tenant, {:ok, TetoIA.mensagem(info)}, nil, "audio")
    end
  end

  # download pelo canal; trocavel por config (:trafego, :baixar_midia) para teste sem rede
  defp baixar(msg), do: Application.get_env(:trafego, :baixar_midia, &Amarula.download_media/1).(msg)

  defp extensao("png"), do: ".png"
  defp extensao("jpeg"), do: ".jpg"
  defp extensao("mp4"), do: ".mp4"

  defp aceitar_criativo(tenant, plano, nome, bytes, info) do
    nome = Path.basename(nome)
    caminho = Executor.caminho_midia(tenant, nome)
    File.mkdir_p!(Path.dirname(caminho))
    File.write!(caminho, bytes)
    texto = get_in(plano, ["criativo", "texto"])
    plano = Map.put(plano, "criativo", Map.reject(%{"midia" => nome, "texto" => texto}, fn {_, v} -> is_nil(v) end))
    Evento.emitir(tenant, "operacao", plano["id"], "planejador", "criativo_recebido", %{"formato" => info.formato, "largura" => info.largura, "altura" => info.altura})

    # plano ja aceito esperando so o criativo: com ele, executa (campanha PAUSADA); senao volta a conferir o plano
    case plano["status"] do
      "aguardando_criativo" ->
        executar_plano(tenant, plano)

      # plano ja mostrado, so faltava a foto: nao reenvia o plano, so confirma que recebeu e pede o sim
      "aguardando_confirmacao" ->
        Plano.salvar(tenant, plano)
        {:ok, "Recebi a foto, esta ok. Confirma pra eu criar tudo pausado?", situacao: :plano, plano_id: plano["id"]}

      _ ->
        concluir_plano(tenant, plano)
    end
  end

  # credencial ausente ou recusada pela plataforma: o agente nao gasta IA nem tenta nada ate o corretor recadastrar
  defp credencial(tenant) do
    cond do
      Acesso.conta(tenant) == nil -> {:error, :sem_conta}
      Acesso.status(tenant) == "token invalido" -> {:ok, "O token de acesso da Meta esta invalido ou expirou. Preciso de um token novo para continuar; nada foi alterado."}
      true -> :ok
    end
  end

  defp ativo(tenant) do
    if Enum.any?(Registro.contratos(tenant), &(&1.automacao == @nome and &1.estado == "ativo")), do: :ok, else: {:error, :inativo}
  end

  # ---- planejador
  @doc false
  # porta da ferramenta `planejar` da conversa: o mesmo planejador de sempre (IA :planejar + Ficha)
  def planejar_pedido(tenant, plano, texto, ref), do: planejar(tenant, plano, texto, ref)

  defp planejar(tenant, plano, texto, ref) do
    Plano.definir_atual(tenant, plano["id"])
    Evento.emitir(tenant, "pedido", plano["id"], "planejador", ref)

    case IA.chamar(tenant, :media, :planejar, %{"texto" => texto, "plano" => plano}) do
      {:ok, %{"plano" => parcial}, uso} ->
        Evento.custo(tenant, plano["id"], "planejador", "planejar", uso)
        antes = if plano["status"] == "aguardando_confirmacao", do: plano
        {plano, ignorados, extras} = Ficha.aplicar(plano, parcial)

        # id de conta que veio do modelo e ignorado: a conta e a do registro do tenant
        if ignorados != [], do: Evento.emitir(tenant, "operacao", plano["id"], "planejador", "conta_do_modelo_ignorada", %{"erro" => "conta_do_modelo_ignorada"})

        plano = Map.put(plano, "atencao", Aprendizado.atencao(tenant, Plano.situacao(plano)))
        concluir_plano(tenant, plano, texto, extras: extras, antes: antes)

      {:error, {:teto_ia, info}} ->
        {:ok, TetoIA.mensagem(info)}

      {:error, e} ->
        Evento.emitir(tenant, "plano", plano["id"], "planejador", "ia_falhou", %{"erro" => inspect(e)})
        {:ok, "Nao consegui montar o plano agora. Tenta de novo em instantes; nada foi alterado."}
    end
  end

  # Ficha (etapa 5.2): com o nucleo (objetivo, imovel, verba diaria, teto) o plano sai; faltando algo, UMA mensagem com tudo
  # numerado. `antes`: plano que estava aguardando confirmacao (ajuste: reenvia so as mensagens que mudaram).
  defp concluir_plano(tenant, plano, texto \\ nil, opts \\ []) do
    extras = opts[:extras] || %{}

    case Ficha.avaliar(tenant, plano) do
      {:pronto, completo} ->
        if extras[:ambiguidade], do: perguntar(tenant, plano, [], texto, extras), else: pronto(tenant, completo, opts[:antes])

      {:pergunta, plano, itens} ->
        perguntar(tenant, plano, itens, texto, extras)
    end
  end

  defp pronto(tenant, plano, antes) do
    plano = Plano.salvar(tenant, Map.put(plano, "status", "aguardando_confirmacao"))
    Evento.emitir(tenant, "plano", plano["id"], "planejador", "aguardando_confirmacao")

    case antes && Ficha.diferencas(antes, plano) do
      nil -> {:ok, Ficha.mensagens(plano), situacao: :plano, plano_id: plano["id"]}
      [] -> {:ok, "Não vi nada diferente no plano. O que voce quer mudar?"}
      diferentes -> {:ok, diferentes, situacao: :plano, plano_id: plano["id"]}
    end
  end

  # uma fala so: a duvida e, se faltar algo, o que falta (um item vai na mesma frase, sem lista nem cabecalho)
  defp duvida_e_perguntas(duvida, [item], plano, _), do: duvida <> " Alem disso, me diz " <> Ficha.pedido(item, plano) <> "."
  defp duvida_e_perguntas(duvida, _itens, _plano, perguntas), do: duvida <> "\n" <> perguntas

  defp perguntar(tenant, plano, itens, texto, extras) do
    plano = if "teto_total" in itens, do: Ficha.perguntar(plano, ["teto_total"]), else: plano
    plano = Plano.salvar(tenant, Map.put(plano, "status", "rascunho"))
    Evento.emitir(tenant, "plano", plano["id"], "planejador", "pendencias", %{"faltam" => itens})
    ultima = Iara.perfil(tenant)["ultima_pendencia"]
    mesma = is_map(ultima) and ultima["plano_id"] == plano["id"]
    repetida = mesma and ultima["faltando"] == itens
    Iara.atualizar(tenant, %{"ultima_pendencia" => %{"plano_id" => plano["id"], "faltando" => itens}})

    duvida = if extras[:ambiguidade], do: "Fiquei na duvida: #{extras[:ambiguidade]}. Me confirma?"
    perguntou = is_binary(texto) and String.contains?(texto, "?")
    perguntas = if itens != [], do: Ficha.perguntas(itens, repetida, plano, duvida != nil)

    # duvida e lista saem em mensagens separadas (curtas); so se o corretor fez uma pergunta e a IA responde, vai junto
    base =
      cond do
        itens == [] -> duvida
        duvida == nil -> perguntas
        perguntou -> duvida <> "\n" <> perguntas
        true -> duvida_e_perguntas(duvida, itens, plano, perguntas)
      end

    contexto = %{
      "respondendo_pergunta" => perguntou,
      "ultima_pergunta_feita" => if(mesma, do: inspect(ultima["faltando"])),
      "ja_temos" => Map.drop(plano, ~w(id status atencao resultado url_final ficha))
    }

    # texto fixo (a lista numerada nao depende da IA); so passa pela fala se o corretor fez uma pergunta
    {:ok, base,
     situacao: :falta, vazio: Plano.vazio?(plano), plano_id: plano["id"], contexto: contexto, fixo: not perguntou, numeradas: length(itens),
     dados: %{"faltando" => itens}}
  end

  # plano aceito, falta so o arquivo: nada foi executado ainda
  defp esperar_criativo(tenant, plano, texto) do
    case IA.chamar(tenant, :pequena, :confirmar, %{"texto" => texto, "plano" => plano["id"], "resumo" => "o corretor ainda vai mandar a foto ou o video do anuncio; 'nao' cancela o plano"}) do
      {:ok, %{"decisao" => "nao"}, uso} ->
        Evento.custo(tenant, plano["id"], "planejador", "confirmar", uso)
        decidir(tenant, plano, "nao")

      {:ok, _, uso} ->
        Evento.custo(tenant, plano["id"], "planejador", "confirmar", uso)
        conversar_pendente(tenant, texto)

      {:error, {:teto_ia, info}} ->
        {:ok, TetoIA.mensagem(info)}

      {:error, _} ->
        {:ok, lembrete_criativo(plano)}
    end
  end

  defp lembrete_criativo(_plano), do: "Ainda aguardo a foto (png ou jpg) ou o video (mp4) do anúncio do plano; nada foi criado. Manda por aqui, ou diz que cancela."

  # ---- confirmacao em texto livre
  defp confirmar(tenant, plano, texto) do
    case IA.chamar(tenant, :pequena, :confirmar, %{"texto" => texto, "plano" => plano["id"]}) do
      {:ok, %{"decisao" => d}, uso} ->
        Evento.custo(tenant, plano["id"], "planejador", "confirmar", uso)
        # pedido de mudanca em linguagem natural: ajusta so o que ele disse e reenvia so as mensagens afetadas
        cond do
          d == "ajuste" -> planejar(tenant, plano, texto, "ajuste")
          d in ["sim", "nao"] -> decidir(tenant, plano, d)
          true ->
            Evento.emitir(tenant, "confirmacao", plano["id"], "planejador", "ambigua")
            conversar_pendente(tenant, texto)
        end

      {:error, {:teto_ia, info}} ->
        {:ok, TetoIA.mensagem(info)}

      {:error, _} ->
        {:ok, repergunta(plano)}
    end
  end

  defp repergunta(plano) do
    if Ficha.ficha(plano)["erro_execucao"] == true,
      do: "O plano parou por causa do erro. Me diz o que ajustar que eu tento de novo, ou fala \"cancela\" que eu descarto.",
      else: @repergunta
  end

  defp decidir(tenant, plano, "sim") do
    Evento.emitir(tenant, "confirmacao", plano["id"], "planejador", "sim")

    if get_in(plano, ["criativo", "midia"]) in [nil, ""] do
      Plano.salvar(tenant, Map.put(plano, "status", "aguardando_criativo"))
      Evento.emitir(tenant, "plano", plano["id"], "planejador", "aguardando_criativo")
      {:ok, "Fechado! Falta so a foto ou o video do anuncio: me manda por aqui (imagem png ou jpg, ou video mp4). Quando chegar eu crio tudo PAUSADO; nada vai ao ar."}
    else
      executar_plano(tenant, plano)
    end
  end

  defp decidir(tenant, plano, "nao") do
    Evento.emitir(tenant, "confirmacao", plano["id"], "planejador", "nao")
    Plano.salvar(tenant, Map.put(plano, "status", "recusado"))
    Plano.definir_atual(tenant, nil)
    {:ok, "Ok, cancelei o plano; nada foi alterado."}
  end

  defp executar_plano(tenant, plano) do
    Plano.salvar(tenant, Map.put(plano, "status", "confirmado"))

    case Executor.executar(tenant, plano["id"]) do
      {:ok, cid} ->
        plano = Plano.ler(tenant, plano["id"])
        verif = Verificador.verificar(tenant, plano["id"])
        if verif == :ok, do: Aprendizado.registrar(tenant, plano, "criar_campanha", "ok")
        Plano.definir_atual(tenant, nil)

        {:ok,
         "Criei a campanha #{cid} pausada (nada foi ativado). " <>
           case verif do
             :ok -> "Conferi na Meta e esta igual ao plano."
             {:divergente, regras} -> "Mas conferi na Meta e #{Enum.map_join(regras, "; ", &divergencia/1)}. Confere la antes de ativar."
             {:error, _} -> "Nao consegui reler a campanha para verificar."
           end}

      {:error, e} ->
        # o plano continua o atual (status erro, ficha preservada): o corretor so ajusta o que falhou, sem repetir tudo
        {:ok, falha(tenant, plano, e)}
    end
  end

  # divergencia do verificador em portugues claro (nunca o nome interno da regra)
  @doc false
  def divergencia(regra) do
    case to_string(regra) do
      "status_pausada" -> "a campanha nao esta pausada"
      "conta_igual" -> "a conta de anuncios e outra"
      "destino_igual" -> "o destino do anuncio ficou diferente do plano"
      "orcamento_diario_igual" -> "o orcamento diario ficou diferente do plano"
      "teto_igual" -> "o teto total ficou diferente do plano"
      "janela_igual" -> "as datas ficaram diferentes do plano"
      "publico_igual" -> "o publico ficou diferente do plano"
      "criativo_igual" -> "a foto ou o texto do anuncio ficou diferente do plano"
      _ -> "algo ficou diferente do plano"
    end
  end

  # causa real em portugues + o que ficou na Meta + as saidas (mensagens curtas, texto fixo)
  defp falha(tenant, _plano, e) do
    id = Executor.campanha_parcial(e)

    rascunho =
      if id,
        do: "Ficou um rascunho parcial PAUSADO na Meta (campanha #{id}); nao foi ao ar e eu nao apaguei nada.",
        else: "Nao criei nada na Meta; nada foi ativado."

    saidas =
      if Executor.numero_nao_vinculado?(e) do
        vinculados =
          case Acesso.chamar(tenant, :numeros_vinculados, []) do
            {:ok, [_ | _] = l} -> " Vinculados na sua Pagina: #{Enum.map_join(l, ", ", &Ficha.formatar_numero/1)}."
            _ -> ""
          end

        "Voce pode: 1. vincular o numero a sua Pagina na Meta e me avisar; 2. me passar outro numero ja vinculado.#{vinculados} 3. seguir sem numero (o anuncio abre o WhatsApp ligado a Pagina)."
      end

    [
      "Nao consegui criar a campanha: #{Executor.explicar(e)}.",
      rascunho,
      saidas,
      "Seu plano continua guardado: me diz o que ajustar (ex.: o numero) e eu tento de novo."
    ]
    |> Enum.reject(&is_nil/1)
  end

  # plano parado por erro de execucao: "tenta de novo" ou um ajuste (ex.: o numero) volta ao plano com a ficha preservada
  defp retomar(tenant, plano, texto) do
    plano = plano |> Map.delete("parcial") |> Map.put("status", "aguardando_confirmacao")
    Plano.salvar(tenant, plano)
    Evento.emitir(tenant, "plano", plano["id"], "planejador", "retomado_apos_erro")
    confirmar(tenant, plano, texto)
  end
end
