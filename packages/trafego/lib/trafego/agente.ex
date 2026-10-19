defmodule Trafego.Agente do
  @moduledoc """
  Conversa do corretor com o agente de trafego (texto do chat dele consigo mesmo). Papeis:
  planejador (IA, via Trafego.IA): monta/revisa o plano e le a confirmacao em texto livre;
  executor (sem IA), verificador decidivel e monitor (esqueleto) ficam nos proprios modulos.
  Estado: um plano "atual" por tenant (rascunho ou aguardando confirmacao). Nenhuma alteracao sem confirmacao clara:
  ambigua -> repergunta curta; negativa -> recusa. O texto do corretor nao vira evento.

  Voz (etapa 5.1): as funcoes internas decidem os FATOS e devolvem o texto-base; `entregar/5` passa TODA resposta por
  `Trafego.Iara.falar` (persona, primeiro contato, pergunta do horario). Audio e texto sao a mesma coisa para o dominio:
  so uma transcricao duvidosa gera uma pergunta "e isso mesmo?" antes de agir (a fala em duvida fica so em memoria).
  """
  alias Nucleo.Registro
  alias Trafego.{Acesso, Aprendizado, Ativacao, Config, Criativo, Evento, Executor, IA, Iara, Plano, Proposta, TetoIA, Verificador}
  alias Trafego.Iara.Memoria

  @nome "Nucleo.Automacoes.Trafego"
  @repergunta "so pra confirmar se entendi, posso fazer isso mesmo?"
  @sem_desligar "Isso eu nao posso desligar: as atualizacoes diarias fazem parte do meu trabalho com voce. O horario voce muda quando quiser, e so falar, por exemplo, \"muda o horario para 7h\"."
  # resposta curta ao horario: mais que isso e outro assunto (vale o padrao)
  @max_resposta_horario 80

  @doc """
  Processa uma mensagem do corretor (texto, ou a transcricao de um audio). {:ok, resposta} | {:error, motivo}
  Ordem: fala de audio em duvida aguardando "e isso mesmo?"; resposta ao horario das atualizacoes; pedido de desligar/mudar o horario;
  plano aguardando confirmacao; proposta aberta (ativar/pausar) lida em texto curto; plano em rascunho; pedido curto de
  ativar/pausar (vira PROPOSTA); senao plano novo.
  """
  def processar(tenant, texto), do: seguro(tenant, "texto", fn -> gate(tenant, texto, "texto", fn -> conversa(tenant, texto, "texto") end) end)

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
        {:ok, msg} -> entregar(tenant, {:ok, msg}, texto, origem, horario: false)
        erro -> erro
      end
    end
  end

  defp despachar(tenant, texto) do
    plano = Plano.atual(tenant)
    prop = Proposta.atual(tenant)

    cond do
      match?(%{"status" => "aguardando_confirmacao"}, plano) -> confirmar(tenant, plano, texto)
      prop != nil and curto?(texto) -> confirmar_proposta(tenant, prop, texto)
      match?(%{"status" => "rascunho"}, plano) -> planejar(tenant, plano, texto, "complemento")
      (tipo = intencao(texto)) != nil -> propor(tenant, tipo)
      true -> planejar(tenant, Plano.novo(tenant), texto, "novo")
    end
  end

  # ---- conversa (texto e audio): fala em duvida pendente -> horario -> fluxo normal
  defp conversa(tenant, texto, origem) do
    case Memoria.pegar(tenant) do
      nil -> seguir(tenant, texto, origem)
      fala -> audio_pendente(tenant, fala, texto, origem)
    end
  end

  defp seguir(tenant, texto, origem) do
    if Iara.perfil(tenant)["horario_estado"] == "perguntado" and String.length(texto) < @max_resposta_horario do
      resolver_horario(tenant, texto, origem)
    else
      # nao respondeu o horario (outro assunto): vale o padrao
      if Iara.perfil(tenant)["horario_estado"] == "perguntado", do: padrao(tenant)
      continuar(tenant, texto, origem)
    end
  end

  defp continuar(tenant, texto, origem) do
    cond do
      Iara.desligar?(texto) -> entregar(tenant, {:ok, @sem_desligar}, texto, origem, horario: false)
      Iara.mudar_horario?(texto) -> mudar_horario(tenant, texto, origem)
      true -> entregar(tenant, despachar(tenant, texto), texto, origem)
    end
  end

  defp padrao(tenant), do: Iara.atualizar(tenant, %{"horario" => Iara.horario_padrao(), "horario_estado" => "padrao"})

  defp resolver_horario(tenant, texto, origem) do
    case Iara.ler_horario(tenant, texto) do
      {:ok, hh} when is_binary(hh) ->
        definir_horario(tenant, hh, texto, origem)

      {:ok, nil} ->
        padrao(tenant)
        continuar(tenant, texto, origem)

      {:teto, info} ->
        entregar(tenant, {:ok, TetoIA.mensagem(info)}, texto, origem, horario: false)
    end
  end

  defp mudar_horario(tenant, texto, origem) do
    case Iara.ler_horario(tenant, texto) do
      {:ok, hh} when is_binary(hh) ->
        definir_horario(tenant, hh, texto, origem)

      {:ok, nil} ->
        Iara.atualizar(tenant, %{"horario_estado" => "perguntado"})
        entregar(tenant, {:ok, "Claro! Que horas fica melhor pra eu te atualizar todo dia? As atualizacoes eu nao consigo desligar, mas o horario e escolha sua."}, texto, origem, horario: false)

      {:teto, info} ->
        entregar(tenant, {:ok, TetoIA.mensagem(info)}, texto, origem, horario: false)
    end
  end

  defp definir_horario(tenant, hh, texto, origem) do
    Iara.atualizar(tenant, %{"horario" => hh, "horario_estado" => "definido"})
    base = "Anotado! Todo dia as #{hh} eu te atualizo sobre as campanhas. Se quiser mudar, e so pedir." <> retomada(tenant)
    entregar(tenant, {:ok, base}, texto, origem, horario: false)
  end

  # depois de responder o horario, volta ao que estava no ar (uma pergunta so)
  defp retomada(tenant) do
    case Plano.atual(tenant) do
      %{"status" => "rascunho"} = p -> if Plano.vazio?(p), do: "", else: " " <> pergunta_pendente(Plano.pendencias(p))
      %{"status" => "aguardando_confirmacao", "id" => id} -> " Sobre o plano #{id}: voce confirma?"
      _ -> ""
    end
  end

  defp pergunta_pendente([]), do: ""
  defp pergunta_pendente([primeira | _]), do: "Pra fechar o plano preciso de #{Plano.rotulo(primeira)}."

  # fala em duvida (audio): o corretor responde por texto OU audio; "sim" processa a fala como texto
  defp audio_pendente(tenant, fala, texto, origem) do
    if not curto?(texto) do
      Memoria.limpar(tenant)
      seguir(tenant, texto, origem)
    else
      case IA.chamar(tenant, :pequena, :confirmar, %{"texto" => texto, "plano" => nil, "resumo" => "o corretor confirma que e isso mesmo que ele falou no audio"}) do
        {:ok, %{"decisao" => d}, uso} ->
          Evento.custo(tenant, nil, "planejador", "confirmar", uso)
          decidir_audio(tenant, fala, d, texto, origem)

        {:error, {:teto_ia, info}} ->
          entregar(tenant, {:ok, TetoIA.mensagem(info)}, texto, origem, horario: false)

        {:error, _} ->
          entregar(tenant, {:ok, repergunta_audio(fala)}, texto, origem, horario: false)
      end
    end
  end

  defp decidir_audio(tenant, fala, "sim", _texto, _origem) do
    Memoria.limpar(tenant)
    seguir(tenant, fala, "audio")
  end

  defp decidir_audio(tenant, _fala, "nao", texto, origem) do
    Memoria.limpar(tenant)
    entregar(tenant, {:ok, "Ok, deixei esse audio de lado; nada foi alterado. Me conta de novo, por audio ou texto."}, texto, origem, horario: false)
  end

  defp decidir_audio(tenant, fala, _, texto, origem), do: entregar(tenant, {:ok, repergunta_audio(fala)}, texto, origem, horario: false)

  defp repergunta_audio(fala), do: "Ainda nao tenho certeza do que ouvi: \"#{fala}\". E isso mesmo?"

  # ---- voz: texto-base -> fala da Iara (primeiro contato e pergunta do horario incluidos)
  # res: {:ok, base} | {:ok, base, extra} (extra: situacao, dados, plano_id, vazio) | {:error, _}. opts: horario: false = nunca pergunta o horario
  defp entregar(tenant, res, texto, origem, opts \\ [])
  defp entregar(_tenant, {:error, _} = e, _, _, _), do: e
  defp entregar(tenant, {:ok, base}, texto, origem, opts), do: entregar(tenant, {:ok, base, []}, texto, origem, opts)

  defp entregar(tenant, {:ok, base, extra}, texto, origem, opts) do
    perfil = Iara.perfil(tenant)
    primeiro = perfil["apresentada"] != true
    nao_perguntado = perfil["horario_estado"] == "nao_perguntado"
    # primeiro contato sem assunto ("oi"): so se apresenta e pergunta o horario (nada de pergunta do plano junto)
    omitir = primeiro and extra[:situacao] == :falta and extra[:vazio] == true
    perguntar = nao_perguntado and (omitir or (Keyword.get(opts, :horario, true) and ocioso?(tenant)))

    if primeiro, do: Iara.atualizar(tenant, %{"apresentada" => true})
    if perguntar, do: Iara.atualizar(tenant, %{"horario_estado" => "perguntado"})

    falar_opts = [texto: texto, origem: origem, primeiro: primeiro, pergunta_horario: perguntar, omitir_base: omitir]
    {:ok, Iara.falar(tenant, base, falar_opts ++ Keyword.take(extra, [:situacao, :dados, :plano_id, :contexto]))}
  end

  # nada pendente com o corretor (plano, proposta ou audio em duvida)
  defp ocioso?(tenant) do
    plano = Plano.atual(tenant)
    (plano == nil or plano["status"] not in ["rascunho", "aguardando_confirmacao"]) and Proposta.atual(tenant) == nil and Memoria.pegar(tenant) == nil
  end

  # pedido de plano tem varios campos separados por ";" ou e longo: nao e resposta a uma proposta nem pedido de ativar/pausar
  defp curto?(texto), do: String.length(texto) < 120 and not String.contains?(texto, ";")

  defp intencao(texto) do
    n = texto |> String.downcase() |> :unicode.characters_to_nfd_binary() |> String.replace(~r/\p{Mn}/u, "")

    cond do
      not curto?(texto) -> nil
      Regex.match?(~r/\bativ(a|ar|e|em)\b/, n) -> :ativar
      Regex.match?(~r/\bpaus(a|ar|e|em)\b/, n) -> :pausar
      true -> nil
    end
  end

  # ---- ativar / pausar: o agente diz o que vai fazer e pergunta; nada muda antes da confirmacao
  defp propor(tenant, :ativar) do
    plano = Enum.find(Enum.reverse(Plano.listar(tenant)), &(&1 && &1["status"] in ["verificado", "pausada"]))

    if plano == nil do
      {:ok, "Nao ha campanha criada e verificada para ativar. Me conta o que quer anunciar que eu monto o plano; nada foi alterado."}
    else
      case Ativacao.pre_condicoes(tenant, plano) do
        [] -> abrir_proposta(tenant, plano, "ativar", %{})
        motivos -> {:ok, "Nao posso ativar agora: #{Ativacao.explicar(motivos)}. Nada foi alterado."}
      end
    end
  end

  defp propor(tenant, :pausar) do
    case Enum.find(Enum.reverse(Plano.listar(tenant)), &(&1 && &1["status"] == "ativa")) do
      nil -> {:ok, "Nao ha campanha ativa para pausar; nada foi alterado."}
      plano -> abrir_proposta(tenant, plano, "pausar", %{"motivo" => "pedido_do_corretor"})
    end
  end

  defp abrir_proposta(tenant, plano, tipo, extra) do
    prop = Proposta.aberta(tenant, tipo, plano["id"]) || Proposta.criar(tenant, tipo, plano["id"], extra)
    Evento.emitir(tenant, "plano", plano["id"], "planejador", "proposta_" <> tipo, %{"proposta_id" => prop["id"]})
    {:ok, Ativacao.texto(prop, plano)}
  end

  defp confirmar_proposta(tenant, prop, texto) do
    case IA.chamar(tenant, :pequena, :confirmar, %{"texto" => texto, "plano" => prop["plano_id"], "resumo" => "proposta #{prop["tipo"]}"}) do
      {:ok, %{"decisao" => d}, uso} ->
        Evento.custo(tenant, prop["plano_id"], "planejador", "confirmar", uso)
        decidir_proposta(tenant, prop, d)

      {:error, {:teto_ia, info}} ->
        {:ok, TetoIA.mensagem(info)}

      {:error, _} ->
        {:ok, @repergunta}
    end
  end

  defp decidir_proposta(tenant, prop, "sim") do
    Evento.emitir(tenant, "confirmacao", prop["plano_id"], "planejador", "sim", %{"proposta_id" => prop["id"]})
    Proposta.salvar(tenant, Map.put(prop, "status", "confirmado"))

    case Ativacao.executar(tenant, prop["id"]) do
      {:ok, texto} -> {:ok, texto}
      {:error, _} -> {:ok, "Nao consegui executar a proposta #{prop["id"]}; nada foi alterado."}
    end
  end

  defp decidir_proposta(tenant, prop, "nao") do
    Evento.emitir(tenant, "confirmacao", prop["plano_id"], "planejador", "nao", %{"proposta_id" => prop["id"]})
    Proposta.salvar(tenant, Map.put(prop, "status", "recusada"))
    {:ok, "Ok, cancelei a proposta #{prop["id"]}; nada foi alterado."}
  end

  defp decidir_proposta(tenant, prop, _) do
    Evento.emitir(tenant, "confirmacao", prop["plano_id"], "planejador", "ambigua", %{"proposta_id" => prop["id"]})
    {:ok, @repergunta}
  end

  @doc """
  Criativo enviado pelo corretor (bytes + nome do arquivo). Conferencia decidivel (Trafego.Criativo): reprovado nao entra e a
  resposta diz o motivo; aprovado e guardado e vira o criativo do plano em andamento, que volta a pedir confirmacao.
  """
  def receber_criativo(tenant, nome, bytes), do: gate(tenant, nil, "texto", fn -> entregar(tenant, criativo(tenant, nome, bytes), nil, "texto") end)

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
  def receber_midia(tenant, %Amarula.Msg{content: %Amarula.Content.Media{kind: :audio}} = msg), do: seguro(tenant, "audio", fn -> receber_audio(tenant, msg) end)

  def receber_midia(tenant, %Amarula.Msg{content: %Amarula.Content.Media{kind: kind}} = msg) when kind in [:image, :document, :video] do
    seguro(tenant, "midia", fn -> gate(tenant, nil, "texto", fn -> entregar(tenant, midia_criativo(tenant, msg), nil, "texto") end) end)
  end

  def receber_midia(tenant, _msg) do
    gate(tenant, nil, "texto", fn -> entregar(tenant, {:ok, "So aceito imagem (png ou jpg) ou video mp4 como criativo, ou audio (nota de voz)."}, nil, "texto", horario: false) end)
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
    dizer = fn msg -> entregar(tenant, {:ok, msg}, nil, "audio", horario: false) end

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
          "" -> entregar(tenant, {:ok, "Nao consegui entender o audio. Tenta de novo falando mais perto do microfone ou escreve por texto; nada foi alterado."}, nil, "audio", horario: false)
          fala -> audio_como_texto(tenant, fala)
        end

      {:error, {:teto_ia, info}} ->
        entregar(tenant, {:ok, TetoIA.mensagem(info)}, nil, "audio", horario: false)

      {:error, e} ->
        Evento.emitir(tenant, "operacao", nil, "planejador", "audio_falhou", %{"erro" => erro_curto(e)})
        entregar(tenant, {:ok, "Nao consegui transcrever esse audio agora. Tenta de novo em instantes ou escreve por texto; nada foi alterado."}, nil, "audio", horario: false)
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
        entregar(tenant, {:ok, "Nao tenho certeza do que ouvi: #{d}. Entendi: \"#{fala}\". E isso mesmo?"}, fala, "audio", horario: false)

      {:teto, info} ->
        entregar(tenant, {:ok, TetoIA.mensagem(info)}, nil, "audio", horario: false)
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
    concluir_plano(tenant, plano)
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
  defp planejar(tenant, plano, texto, ref) do
    Plano.definir_atual(tenant, plano["id"])
    Evento.emitir(tenant, "pedido", plano["id"], "planejador", ref)

    case IA.chamar(tenant, :media, :planejar, %{"texto" => texto, "plano" => plano}) do
      {:ok, %{"plano" => parcial}, uso} ->
        Evento.custo(tenant, plano["id"], "planejador", "planejar", uso)
        {plano, ignorados} = Plano.mesclar(plano, parcial)

        # id de conta que veio do modelo e ignorado: a conta e a do registro do tenant
        if ignorados != [], do: Evento.emitir(tenant, "operacao", plano["id"], "planejador", "conta_do_modelo_ignorada", %{"erro" => "conta_do_modelo_ignorada"})

        plano = Map.put(plano, "atencao", Aprendizado.atencao(tenant, Plano.situacao(plano)))
        concluir_plano(tenant, plano, texto)

      {:error, {:teto_ia, info}} ->
        {:ok, TetoIA.mensagem(info)}

      {:error, e} ->
        Evento.emitir(tenant, "plano", plano["id"], "planejador", "ia_falhou", %{"erro" => inspect(e)})
        {:ok, "Nao consegui montar o plano agora. Tenta de novo em instantes; nada foi alterado."}
    end
  end

  defp concluir_plano(tenant, plano, texto \\ nil) do
    case Plano.pendencias(plano) do
      [] ->
        plano = Plano.salvar(tenant, Map.put(plano, "status", "aguardando_confirmacao"))
        Evento.emitir(tenant, "plano", plano["id"], "planejador", "aguardando_confirmacao")
        atencao = if plano["atencao"] == [], do: "", else: " Atencao: em situacao parecida a verificacao acusou #{Enum.join(plano["atencao"], ", ")}; vou conferir isso de novo."
        {:ok, Plano.resumo(plano) <> atencao <> " Vou criar tudo PAUSADO, nada sera ativado. Voce confirma?"}

      pend ->
        plano = Plano.salvar(tenant, Map.put(plano, "status", "rascunho"))
        Evento.emitir(tenant, "plano", plano["id"], "planejador", "pendencias", %{"faltam" => pend})
        # uma pergunta por vez: so a primeira pendencia vai pro corretor (a lista toda fica no evento)
        resto = if tl(pend) == [], do: "", else: " O resto a gente ve depois, uma coisa de cada vez."
        faltando = hd(pend)
        ultima = Iara.perfil(tenant)["ultima_pendencia"]
        mesma = is_map(ultima) and ultima["plano_id"] == plano["id"]
        repetida = mesma and ultima["faltando"] == faltando
        Iara.atualizar(tenant, %{"ultima_pendencia" => %{"plano_id" => plano["id"], "faltando" => faltando}})

        # o corretor perguntou (ou mudou de assunto) em vez de responder: a fala leva a pergunta dele e o que ja foi pedido,
        # e o texto fixo nao repete a frase anterior
        base =
          if repetida,
            do: "Ainda preciso de #{Plano.rotulo(faltando)} pra fechar o plano.#{resto}",
            else: "Pra fechar o plano preciso de #{Plano.rotulo(faltando)}.#{resto}"

        contexto = %{
          "respondendo_pergunta" => is_binary(texto) and String.contains?(texto, "?"),
          "ultima_pergunta_feita" => if(mesma, do: Plano.rotulo(ultima["faltando"])),
          "ja_temos" => Map.drop(plano, ~w(id status atencao resultado url_final))
        }

        {:ok, base,
         situacao: :falta, vazio: Plano.vazio?(plano), plano_id: plano["id"], contexto: contexto,
         dados: %{"faltando" => faltando, "faltam_depois" => tl(pend)}}
    end
  end

  # ---- confirmacao em texto livre
  defp confirmar(tenant, plano, texto) do
    case IA.chamar(tenant, :pequena, :confirmar, %{"texto" => texto, "plano" => plano["id"]}) do
      {:ok, %{"decisao" => d}, uso} ->
        Evento.custo(tenant, plano["id"], "planejador", "confirmar", uso)
        decidir(tenant, plano, d)

      {:error, {:teto_ia, info}} ->
        {:ok, TetoIA.mensagem(info)}

      {:error, _} ->
        {:ok, @repergunta}
    end
  end

  defp decidir(tenant, plano, "sim") do
    Evento.emitir(tenant, "confirmacao", plano["id"], "planejador", "sim")
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
             :ok -> "Verificacao: confere com o plano."
             {:divergente, regras} -> "Verificacao acusou divergencia: #{Enum.join(regras, ", ")}."
             {:error, _} -> "Nao consegui reler a campanha para verificar."
           end}

      {:error, e} ->
        Plano.definir_atual(tenant, nil)
        {:ok, "Nao consegui criar a campanha (#{Executor.motivo(e)}). Nada ficou ativo; registrei o erro para a proxima proposta."}
    end
  end

  defp decidir(tenant, plano, "nao") do
    Evento.emitir(tenant, "confirmacao", plano["id"], "planejador", "nao")
    Plano.salvar(tenant, Map.put(plano, "status", "recusado"))
    Plano.definir_atual(tenant, nil)
    {:ok, "Ok, cancelei o plano #{plano["id"]}; nada foi alterado."}
  end

  defp decidir(tenant, plano, _) do
    Evento.emitir(tenant, "confirmacao", plano["id"], "planejador", "ambigua")
    {:ok, @repergunta}
  end
end
