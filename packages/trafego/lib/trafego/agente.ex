defmodule Trafego.Agente do
  @moduledoc """
  Conversa do corretor com o agente de trafego (texto do chat dele consigo mesmo). Papeis:
  planejador (IA, via Trafego.IA): monta/revisa o plano e le a confirmacao em texto livre;
  executor (sem IA), verificador decidivel e monitor (esqueleto) ficam nos proprios modulos.
  Estado: um plano "atual" por tenant (rascunho ou aguardando confirmacao). Nenhuma alteracao sem confirmacao clara:
  ambigua -> repergunta curta; negativa -> recusa. O texto do corretor nao vira evento.
  """
  alias Nucleo.Registro
  alias Trafego.{Acesso, Aprendizado, Ativacao, Config, Criativo, Evento, Executor, IA, Plano, Proposta, TetoIA, Verificador}

  @nome "Nucleo.Automacoes.Trafego"
  @repergunta "so pra confirmar se entendi, posso fazer isso mesmo?"

  @doc """
  Processa uma mensagem do corretor. {:ok, resposta} | {:error, motivo}
  Ordem: plano aguardando confirmacao; proposta aberta (ativar/pausar) lida em texto curto; plano em rascunho; pedido curto de
  ativar/pausar (vira PROPOSTA); senao plano novo.
  """
  def processar(tenant, texto) do
    with :ok <- ativo(tenant), :ok <- credencial(tenant) do
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
  def receber_criativo(tenant, nome, bytes) do
    with :ok <- ativo(tenant), :ok <- credencial(tenant) do
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
  end

  @doc """
  Midia que chegou pelo canal (Amarula). Baixa e passa pela mesma conferencia. Se nao der para baixar, avisa e propoe
  alternativa (mandar como documento ou colocar o arquivo no painel) em vez de fingir que recebeu.
  """
  def receber_midia(tenant, %Amarula.Msg{content: %Amarula.Content.Media{kind: :audio}} = msg), do: receber_audio(tenant, msg)

  def receber_midia(tenant, %Amarula.Msg{content: %Amarula.Content.Media{kind: kind}} = msg) when kind in [:image, :document, :video] do
    case baixar(msg) do
      {:ok, bytes} when is_binary(bytes) ->
        with {:ok, info} <- Criativo.conferir(bytes) do
          receber_criativo(tenant, "criativo_#{System.unique_integer([:positive])}" <> extensao(info.formato), bytes)
        else
          {:error, motivos} -> {:ok, "Esse criativo nao serve: #{Criativo.explicar(motivos)}. Manda outro arquivo."}
        end

      _ ->
        Evento.emitir(tenant, "operacao", nil, "planejador", "midia_nao_baixou", %{"erro" => "download_falhou"})
        {:ok, "Recebi o aviso da midia mas nao consegui baixar o arquivo. Tenta mandar de novo como documento (sem compressao) ou coloca o arquivo no painel."}
    end
  end

  def receber_midia(_tenant, _msg), do: {:ok, "So aceito imagem (png ou jpg) ou video mp4 como criativo, ou audio (nota de voz)."}

  # ---- audio (nota de voz): baixa na memoria, transcreve (com o teto de IA) e o texto entra no fluxo normal.
  # A transcricao pode errar: o agente repete o que entendeu e confirmacao (plano, ativar, pausar) so vale por TEXTO.
  # O audio e a transcricao nao vao para disco, evento ou log; so metadados (segundos, custo).
  defp receber_audio(tenant, %Amarula.Msg{content: c}) do
    max_seg = Config.audio(:max_segundos, 120)
    max_bytes = Config.audio(:max_bytes, 10_000_000)

    with :ok <- ativo(tenant), :ok <- credencial(tenant) do
      cond do
        is_integer(c.seconds) and c.seconds > max_seg ->
          {:ok, "Esse audio e muito longo (limite de #{max_seg} segundos). Manda um mais curto ou escreve por texto; nada foi alterado."}

        is_integer(c.file_length) and c.file_length > max_bytes ->
          {:ok, "Esse audio e muito grande para eu transcrever. Manda um mais curto ou escreve por texto; nada foi alterado."}

        true ->
          case baixar(%Amarula.Msg{channel: :audio, type: :media, raw: nil, content: c}) do
            {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > max_bytes -> {:ok, "Esse audio e muito grande para eu transcrever. Manda um mais curto ou escreve por texto; nada foi alterado."}
            {:ok, bytes} when is_binary(bytes) -> transcrever_audio(tenant, bytes, c)
            _ ->
              Evento.emitir(tenant, "operacao", nil, "planejador", "audio_nao_baixou", %{"erro" => "download_falhou"})
              {:ok, "Recebi o aviso do audio mas nao consegui baixar. Tenta mandar de novo ou escreve por texto; nada foi alterado."}
          end
      end
    end
  end

  defp transcrever_audio(tenant, bytes, c) do
    # sem duracao no aviso: estima por ~2 KB/s (nota de voz opus), para cima, so para o custo
    segundos = if is_integer(c.seconds) and c.seconds > 0, do: c.seconds, else: max(1, ceil(byte_size(bytes) / 2000))

    case IA.transcrever(tenant, bytes, %{mime: c.mimetype, segundos: segundos}) do
      {:ok, texto, uso} ->
        Evento.custo_audio(tenant, "planejador", "transcrever", uso)
        Evento.emitir(tenant, "operacao", nil, "planejador", "audio_transcrito", %{"segundos" => uso["segundos"]})

        case String.trim(texto) do
          "" -> {:ok, "Nao consegui entender o audio. Tenta de novo falando mais perto do microfone ou escreve por texto; nada foi alterado."}
          fala -> processar_audio(tenant, fala)
        end

      {:error, {:teto_ia, info}} ->
        {:ok, TetoIA.mensagem(info)}

      {:error, e} ->
        Evento.emitir(tenant, "operacao", nil, "planejador", "audio_falhou", %{"erro" => erro_curto(e)})
        {:ok, "Nao consegui transcrever esse audio agora. Tenta de novo em instantes ou escreve por texto; nada foi alterado."}
    end
  end

  defp erro_curto({tipo, _}) when is_atom(tipo), do: Atom.to_string(tipo)
  defp erro_curto(e) when is_atom(e), do: Atom.to_string(e)
  defp erro_curto(_), do: "erro"

  # Com plano ou proposta aguardando confirmacao, audio NUNCA responde a ela (nem sim nem nao): so repete o que entendeu.
  defp processar_audio(tenant, fala) do
    eco = "Entendi pelo audio: \"#{fala}\"."

    if Plano.atual(tenant)["status"] == "aguardando_confirmacao" or Proposta.atual(tenant) != nil do
      {:ok, eco <> " Por seguranca, confirmar ou cancelar so vale por texto: responda sim ou nao escrevendo. Nada foi alterado."}
    else
      with {:ok, resposta} <- processar(tenant, fala) do
        pendente? = Plano.atual(tenant)["status"] == "aguardando_confirmacao" or Proposta.atual(tenant) != nil
        sufixo = if pendente?, do: " Para confirmar, responda por texto (sim ou nao); audio nao confirma.", else: ""
        {:ok, eco <> " " <> resposta <> sufixo}
      end
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
        concluir_plano(tenant, plano)

      {:error, {:teto_ia, info}} ->
        {:ok, TetoIA.mensagem(info)}

      {:error, e} ->
        Evento.emitir(tenant, "plano", plano["id"], "planejador", "ia_falhou", %{"erro" => inspect(e)})
        {:ok, "Nao consegui montar o plano agora. Tenta de novo em instantes; nada foi alterado."}
    end
  end

  defp concluir_plano(tenant, plano) do
    case Plano.pendencias(plano) do
      [] ->
        plano = Plano.salvar(tenant, Map.put(plano, "status", "aguardando_confirmacao"))
        Evento.emitir(tenant, "plano", plano["id"], "planejador", "aguardando_confirmacao")
        atencao = if plano["atencao"] == [], do: "", else: " Atencao: em situacao parecida a verificacao acusou #{Enum.join(plano["atencao"], ", ")}; vou conferir isso de novo."
        {:ok, Plano.resumo(plano) <> atencao <> " Vou criar tudo PAUSADO, nada sera ativado. Voce confirma?"}

      pend ->
        plano = Plano.salvar(tenant, Map.put(plano, "status", "rascunho"))
        Evento.emitir(tenant, "plano", plano["id"], "planejador", "pendencias", %{"faltam" => pend})
        {:ok, "Para fechar o plano falta: #{Enum.join(pend, ", ")}. Me manda isso que eu monto."}
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
