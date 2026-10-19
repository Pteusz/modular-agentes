defmodule Trafego.Iara do
  @moduledoc """
  Iara: a voz do agente de trafego (etapa 5.1; docs/iara.md secoes 1 e 2). Uma persona unica aplicada a TODAS as respostas
  do agente ao corretor: o dominio (executor, verificador, confirmacao em texto livre, tetos) continua decidivel no codigo e
  produz o texto-base com os FATOS; `falar/3` pede a IA (tarefa :falar) para dizer isso em texto natural curto de WhatsApp.
  Qualquer falha da geracao (erro, teto de IA, texto vazio/longo, valores do texto-base perdidos) volta ao texto-base fixo:
  o significado de erros e bloqueios nunca depende da IA. O custo da geracao entra no custo_tokens (R$) e no teto do corretor.

  Perfil por corretor (registro "iara_perfil"): apresentada, horario (HH:MM; padrao 09:00) e horario_estado
  (nao_perguntado | perguntado | definido | padrao). Nesta etapa so guarda a preferencia de horario; o envio diario e a 5.3.
  As atualizacoes NAO podem ser desligadas (decisao do Mateus): so o horario muda.
  """
  alias Nucleo.Registro
  alias Trafego.{Evento, IA, TetoIA}

  @chave "iara_perfil"
  @horario_padrao "09:00"
  @max_chars 900

  @apresentacao "Oi! Eu sou a Iara, da equipe Ataque Total da Cury Construtora. Sou uma IA e cuido das suas campanhas de anuncios, do feed de imoveis e do desempenho. Me adapto ao seu jeito e aprendo com o tempo, melhorando a cada campanha. Se preferir, pode me mandar audio que eu entendo."
  @pergunta_horario "Qual o melhor horario para eu te atualizar todo dia sobre as campanhas? Se voce nao disser, uso 9h; da para mudar depois."

  # a apresentacao sai em 2 mensagens curtas (quem sou; que aprendo com o tempo), nunca num bloco so
  @apresentacao_msgs [
    "Oi! Eu sou a Iara, da equipe Ataque Total da Cury Construtora. Sou uma IA e cuido das suas campanhas de anuncios, do feed de imoveis e do desempenho.",
    "Me adapto ao seu jeito e aprendo com o tempo, melhorando a cada campanha. Se preferir, pode me mandar audio que eu entendo."
  ]

  def apresentacao, do: @apresentacao
  def apresentacao_mensagens, do: @apresentacao_msgs
  def pergunta_horario, do: @pergunta_horario
  def horario_padrao, do: @horario_padrao

  @doc "Instrucao de persona (usada pelo provedor de IA real em todas as geracoes de fala)."
  def persona,
    do: """
    Voce e a Iara, da equipe Ataque Total da Cury Construtora. Fala com corretores de imoveis pelo WhatsApp, como colega de equipe: informal e direta, sem giria pesada.
    Voce e uma IA e assume isso se perguntarem; nunca finge ser humana. Diz abertamente que aprende com o tempo (melhora a cada campanha).
    Seu assunto e so campanhas de anuncios, feed de imoveis e desempenho das campanhas DO PROPRIO corretor; qualquer outro assunto voce recusa com educacao e volta ao trabalho.
    O corretor decide e voce propoe: nunca diga que fez ou vai fazer uma alteracao que o texto-base nao diz.
    Estilo WhatsApp: 2 a 3 linhas curtas, sem markdown, sem emoji em excesso. Acompanhe o ritmo e o nivel do corretor e traduza termos tecnicos (pixel, CPM, conjunto, publico) para a linguagem dele (reais por dia, ate quando, quantos contatos).
    Aproveite tudo que ele ja disse e nao repita o que ja esta no plano. Pergunte so o que o texto-base pedir (ou houver ambiguidade de verdade); se o texto-base trouxer uma lista numerada de perguntas, mantenha a lista inteira, numerada, numa unica mensagem.
    Os FATOS do texto-base mandam: mantenha todos os valores, datas, ids (p1, q1, c...) e o significado de avisos, bloqueios e erros ("nada foi alterado", "pausada", "teto de IA"); nunca invente dado, numero ou resultado.
    """

  # ---- perfil
  def perfil(tenant), do: Map.merge(%{"apresentada" => false, "horario" => nil, "horario_estado" => "nao_perguntado"}, Registro.ler(tenant, @chave) || %{})

  def atualizar(tenant, mudancas) do
    Registro.gravar(tenant, @chave, Map.merge(perfil(tenant), mudancas))
    :ok
  end

  @doc "Horario das atualizacoes diarias do corretor (\"HH:MM\"); padrao 09:00."
  def horario(tenant), do: perfil(tenant)["horario"] || @horario_padrao

  @doc "Normaliza para \"HH:MM\" ou nil."
  def normalizar_horario(h) when is_binary(h) do
    case Regex.run(~r/^\s*(\d{1,2})(?::(\d{2}))?\s*$/, h) do
      [_, hh] -> hora(hh, "00")
      [_, hh, mm] -> hora(hh, mm)
      _ -> nil
    end
  end

  def normalizar_horario(_), do: nil

  defp hora(hh, mm) do
    {h, m} = {String.to_integer(hh), String.to_integer(mm)}
    if h in 0..23 and m in 0..59, do: :io_lib.format("~2..0B:~2..0B", [h, m]) |> IO.iodata_to_binary()
  end

  # ---- intencoes decidiveis (texto curto)
  defp norm(t), do: t |> String.downcase() |> :unicode.characters_to_nfd_binary() |> String.replace(~r/\p{Mn}/u, "")

  @doc "Pedido de desligar/parar as atualizacoes (nao permitido)."
  def desligar?(texto) do
    n = norm(texto)

    String.length(n) < 160 and
      (Regex.match?(~r/\b(desliga|desligar|desativa|desativar|cancela|cancelar|pare|parar|para de|chega de)\b.*\b(atualizac\w*|atualizar|avisos?|relatorios?|mensagens?)\b/, n) or
         Regex.match?(~r/\b(nao quero|nao preciso|sem)\b.*\b(atualizac\w*|avisos? diarios?|relatorios?)\b/, n))
  end

  @doc "Pedido de mudar o horario das atualizacoes."
  def mudar_horario?(texto) do
    n = norm(texto)

    String.length(n) < 160 and
      Regex.match?(~r/\b(muda|mudar|mude|troca|trocar|troque|altera|alterar|prefiro|melhor)\b.*\b(horario|hora)\b/, n)
  end

  # ---- voz (etapa 5.2.3): preferencia por audio ou texto, guardada no perfil ("voz": "audio" | "texto"; sem ela, a Iara acompanha o corretor)
  @doc "Preferencia de resposta do corretor: \"audio\" | \"texto\" | nil (acompanha: audio com audio, texto com texto)."
  def voz_preferida(tenant), do: perfil(tenant)["voz"]

  @doc "Pedido explicito de como responder: :audio | :texto | nil. Texto curto; \"so texto\" / \"para de mandar audio\" = :texto."
  def preferencia_voz(texto) do
    n = norm(texto)

    cond do
      String.length(n) >= 120 ->
        nil

      Regex.match?(~r/\b(so|apenas|somente)\b.*\b(texto|escrito|escrever)\b/, n) or
        Regex.match?(~r/\b(responde|responda|manda|mande|escreve|escreva|volta|voltar|prefiro|quero)\b.*\b(texto|escrito)\b/, n) or
          Regex.match?(~r/\b(para|pare|chega|sem|nao (quero|manda|mande|precisa))\b.*\b(audio|voz)\b/, n) ->
        :texto

      Regex.match?(~r/\b(responde|responda|manda|mande|fala|fale|me responde|prefiro|quero|so|sempre)\b.*\b(audio|voz)\b/, n) ->
        :audio

      true ->
        nil
    end
  end

  # ---- fala
  @doc """
  Texto-base -> texto natural da Iara. opts: situacao, dados (mapa), texto (do corretor), origem ("texto" | "audio"),
  plano_id, primeiro (primeiro contato), pergunta_horario, omitir_base. Nunca falha: erro ou texto fora do contrato = texto fixo.
  """
  def falar(tenant, base, opts \\ []) do
    fixo = compor(base, opts)

    if opts[:fixo] == true or match?({:bloqueado, _}, TetoIA.status(tenant)) do
      fixo
    else
      entrada = %{
        "situacao" => to_string(opts[:situacao] || "geral"),
        "base" => base,
        "mensagem_do_corretor" => opts[:texto],
        "origem" => opts[:origem] || "texto",
        "primeiro_contato" => opts[:primeiro] || false,
        "perguntar_horario" => opts[:pergunta_horario] || false,
        "omitir_base" => opts[:omitir_base] || false,
        "dados" => opts[:dados] || %{},
        "plano" => opts[:plano_id]
      }

      entrada = Map.merge(entrada, opts[:contexto] || %{})

      case IA.chamar(tenant, :pequena, :falar, entrada) do
        {:ok, %{"texto" => t}, uso} ->
          Evento.custo(tenant, opts[:plano_id], "planejador", "falar", uso)
          if valido?(t, base, opts), do: String.trim(t), else: fixo

        _ ->
          fixo
      end
    end
  end

  @doc "Texto fixo (sem IA): apresentacao + texto-base + pergunta de horario, conforme o caso. Tambem e o que o provedor Falso devolve."
  def compor(base, opts \\ []) do
    [
      if(opts[:primeiro], do: @apresentacao),
      if(not (opts[:omitir_base] || false), do: base),
      if(opts[:pergunta_horario], do: @pergunta_horario)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp valido?(t, base, opts) when is_binary(t) do
    t = String.trim(t)

    t != "" and String.length(t) <= @max_chars and
      (not (opts[:primeiro] || false) or t =~ "Iara") and
      (not (opts[:pergunta_horario] || false) or t =~ "?") and
      ((opts[:omitir_base] || false) or valores_mantidos?(base, t)) and numeradas_mantidas?(t, opts[:numeradas])
  end

  defp valido?(_, _, _), do: false

  # lista numerada de perguntas (etapa 5.2): a fala precisa manter todos os numeros "1." ... "n."
  defp numeradas_mantidas?(_t, n) when n in [nil, 0], do: true
  defp numeradas_mantidas?(t, n), do: Enum.all?(1..n, &String.contains?(t, "#{&1}."))

  # todo numero (2+ digitos, exceto zeros como em ",00") do texto-base precisa continuar no texto
  defp valores_mantidos?(base, t) do
    ~r/\d{2,}/ |> Regex.scan(base) |> List.flatten() |> Enum.reject(&(String.trim(&1, "0") == "")) |> Enum.all?(&String.contains?(t, &1))
  end

  # ---- horario e transcricao (IA pequena; custo no teto)
  @doc "Le um horario no texto do corretor: {:ok, \"HH:MM\" | nil} | {:teto, info}. Erro do provedor = nil (nao entendi)."
  def ler_horario(tenant, texto) do
    case IA.chamar(tenant, :pequena, :horario, %{"texto" => texto}) do
      {:ok, %{"horario" => h}, uso} ->
        Evento.custo(tenant, nil, "planejador", "horario", uso)
        {:ok, normalizar_horario(h)}

      {:error, {:teto_ia, info}} ->
        {:teto, info}

      _ ->
        {:ok, nil}
    end
  end

  @doc "Confere se a transcricao de um audio ficou duvidosa/ambigua: :ok | {:duvida, descricao} | {:teto, info}. Erro do provedor = :ok."
  def duvida_audio(tenant, fala) do
    case IA.chamar(tenant, :pequena, :checar_transcricao, %{"transcricao" => fala}) do
      {:ok, %{"duvida" => d}, uso} ->
        Evento.custo(tenant, nil, "planejador", "checar_transcricao", uso)
        if is_binary(d) and String.trim(d) != "", do: {:duvida, String.trim(d)}, else: :ok

      {:error, {:teto_ia, info}} ->
        {:teto, info}

      _ ->
        :ok
    end
  end
end

defmodule Trafego.Iara.Memoria do
  @moduledoc """
  Transcricao de audio em duvida, SO em memoria (nunca em disco, evento ou log), por corretor e por pouco tempo: a Iara
  perguntou "e isso mesmo?" e espera a resposta em texto. Reiniciar o sistema descarta (o corretor so repete).
  """
  use Agent
  @ttl_ms 600_000

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def guardar(tenant, fala), do: Agent.update(__MODULE__, &Map.put(&1, tenant, {fala, System.monotonic_time(:millisecond)}))

  def pegar(tenant) do
    case Agent.get(__MODULE__, &Map.get(&1, tenant)) do
      {fala, t} -> if System.monotonic_time(:millisecond) - t < @ttl_ms, do: fala, else: (limpar(tenant); nil)
      nil -> nil
    end
  end

  def limpar(tenant), do: Agent.update(__MODULE__, &Map.delete(&1, tenant))
end
