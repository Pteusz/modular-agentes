defmodule Trafego.Iara do
  @moduledoc """
  Iara: a voz do agente de trafego (etapa 5.1; docs/iara.md secoes 1 e 2). Uma persona unica aplicada a TODAS as respostas
  do agente ao corretor: o dominio (executor, verificador, confirmacao em texto livre, tetos) continua decidivel no codigo e
  produz o texto-base com os FATOS; `falar/3` pede a IA (tarefa :falar) para dizer isso em texto natural curto de WhatsApp.
  Qualquer falha da geracao (erro, teto de IA, texto vazio/longo, valores do texto-base perdidos) volta ao texto-base fixo:
  o significado de erros e bloqueios nunca depende da IA. O custo da geracao entra no custo_tokens (R$) e no teto do corretor.

  Perfil por corretor (registro "iara_perfil"): apresentada, horario (HH:MM; padrao 09:00) e horario_estado
  (nao_perguntado | perguntado | definido | padrao). A atualizacao diaria nao tem opcao de desligar (decisao do Mateus; regra no codigo, a Iara nao a comenta): so o horario muda.

  Apresentacao (trafego 1.11.0): NAO ha texto pronto nem pipeline; o primeiro contato e conversa do modelo (Trafego.Conversa) guiada pela
  politica + este estado, que sao DADOS: "apresentacao" => %{"quem_sou" => bool, "como_aprendo" => bool} (o que a Iara REALMENTE disse),
  "horario_estado", "horario_perguntas" (quantas vezes perguntou o horario). "apresentada" espelha quem_sou (compativel com o formato antigo:
  perfil antigo com apresentada=true e sem "apresentacao" vale como quem_sou e como_aprendo ja ditos). Um item por mensagem; horario
  combinado ou assumido (padrao) = apresentacao encerrada; ao combinar, a Iara confirma o horario e pergunta se ele ja quer criar a primeira
  campanha (trafego 1.12.1; "campanha_perguntada" marca que foi feita e nunca se repete). Unico texto fixo: `apresentacao_minima/0`, so se o modelo falhar no primeiro contato.
  """
  alias Nucleo.Registro
  alias Trafego.{Evento, IA, TetoIA}

  @chave "iara_perfil"
  @horario_padrao "09:00"
  @max_chars 900

  # fallback de seguranca (modelo falhou no primeiro contato): UMA mensagem curta, nunca varias
  @apresentacao_minima "Oi! Eu sou a Iara, da equipe Ataque Total da Cury Construtora, uma IA que cuida das suas campanhas de anúncios. Deu um probleminha aqui agora, me manda de novo daqui a pouco."

  def apresentacao_minima, do: @apresentacao_minima
  def horario_padrao, do: @horario_padrao

  @doc "Instrucao de persona (usada pelo provedor de IA real em todas as geracoes de fala)."
  def persona,
    do: """
    Voce e a Iara, da equipe Ataque Total da Cury Construtora. Fala com corretores de imoveis pelo WhatsApp, como colega de equipe: informal e direta, sem giria pesada.
    Voce e uma IA e assume isso se perguntarem; nunca finge ser humana. Diz abertamente que aprende com o tempo (melhora a cada campanha).
    Seu assunto e so campanhas de anuncios, feed de imoveis e desempenho das campanhas DO PROPRIO corretor; qualquer outro assunto voce recusa com educacao e volta ao trabalho.
    O corretor decide e voce propoe: nunca diga que fez ou vai fazer uma alteracao que o texto-base nao diz.
    Jeito de falar: como colega no zap. Mensagem curta (1 ou 2 frases; 3 so quando precisa), palavras de todo dia ("pra", "tá", "beleza"), sem texto de central de atendimento. Espelhe o jeito do corretor (seco com quem é seco, solto com quem brinca). Sem markdown, sem travessão, sem lista com marcadores. Emoji raro: só se ele usar, e um no máximo. Varie a abertura e o fim das mensagens; não feche toda mensagem com oferta nem use clichê ("com certeza", "fico à disposição", "ótima pergunta"). Traduza termos técnicos (pixel, CPM, conjunto, público) para a linguagem dele (reais por dia, até quando, quantos contatos).
    Aproveite tudo que ele ja disse e nao repita o que ja esta no plano. Pergunte so o que o texto-base pedir (ou houver ambiguidade de verdade); se o texto-base trouxer uma lista numerada de perguntas, mantenha a lista inteira, numerada, numa unica mensagem.
    Os FATOS do texto-base mandam: mantenha todos os valores, datas, ids (p1, q1, c...) e o significado de avisos, bloqueios e erros ("nada foi alterado", "pausada", "teto de IA"); nunca invente dado, numero ou resultado.
    """

  # ---- perfil
  def perfil(tenant), do: Map.merge(%{"apresentada" => false, "horario" => nil, "horario_estado" => "nao_perguntado"}, Registro.ler(tenant, @chave) || %{})

  def atualizar(tenant, mudancas) do
    Registro.gravar(tenant, @chave, Map.merge(perfil(tenant), mudancas))
    :ok
  end

  # ---- apresentacao (estado em dados; o texto e do modelo)
  @itens_apresentacao ~w(quem_sou como_aprendo)
  @max_perguntas_horario 2

  @doc "O que a Iara realmente ja disse na apresentacao: %{\"quem_sou\" => bool, \"como_aprendo\" => bool}."
  def cobertura(tenant) do
    p = perfil(tenant)

    c =
      case p["apresentacao"] do
        %{} = m -> m
        _ -> if p["apresentada"] == true, do: %{"quem_sou" => true, "como_aprendo" => true}, else: %{}
      end

    Map.new(@itens_apresentacao, &{&1, c[&1] == true})
  end

  @doc "Registra o que foi DITO: \"quem_sou\" | \"como_aprendo\" | \"horario_perguntado\" (conta a pergunta; o estado vira perguntado)."
  def cobrir(tenant, item) when item in @itens_apresentacao do
    mud = %{"apresentacao" => Map.put(cobertura(tenant), item, true)}
    atualizar(tenant, if(item == "quem_sou", do: Map.put(mud, "apresentada", true), else: mud))
  end

  def cobrir(tenant, "horario_perguntado") do
    p = perfil(tenant)
    atualizar(tenant, %{"apresentacao" => cobertura(tenant), "horario_estado" => "perguntado", "horario_perguntas" => (p["horario_perguntas"] || 0) + 1})
  end

  def perguntas_horario(tenant), do: perfil(tenant)["horario_perguntas"] || 0
  def max_perguntas_horario, do: @max_perguntas_horario

  @doc "Grava o horario que o corretor escolheu (\"HH:MM\" ja normalizado)."
  def definir_horario(tenant, hh), do: atualizar(tenant, %{"horario" => hh, "horario_estado" => "definido"})

  @doc "Sem escolha depois de perguntar: vale o padrao (a atualizacao continua ligada)."
  def assumir_padrao(tenant), do: atualizar(tenant, %{"horario" => @horario_padrao, "horario_estado" => "padrao"})

  @doc "Apresentacao encerrada: disse quem e, como aprende e o horario esta combinado (ou assumido)."
  def encerrada?(tenant) do
    c = cobertura(tenant)
    c["quem_sou"] and c["como_aprendo"] and perfil(tenant)["horario_estado"] in ["definido", "padrao"]
  end

  @doc """
  A pergunta de primeira campanha (gancho do fechamento da apresentacao, trafego 1.12.1) ja foi feita? Campo "campanha_perguntada";
  perfil que ja tinha horario combinado ou assumido (antes da 1.12.1) conta como feita, para a pergunta nunca ser repetida.
  """
  def campanha_perguntada?(tenant) do
    p = perfil(tenant)
    p["campanha_perguntada"] == true or p["horario_estado"] in ["definido", "padrao"]
  end

  @doc "Marca a pergunta de primeira campanha como feita (a apresentacao acabou; o proximo sim ja e conversa normal de campanha)."
  def marcar_campanha_perguntada(tenant), do: atualizar(tenant, %{"campanha_perguntada" => true})

  @doc "Proximo item (UM so): \"quem_sou\" | \"como_aprendo\" | \"perguntar_horario\" | \"aguardar_horario\" | nil (encerrada)."
  def proximo_item(tenant) do
    c = cobertura(tenant)
    estado = perfil(tenant)["horario_estado"]

    cond do
      not c["quem_sou"] -> "quem_sou"
      not c["como_aprendo"] -> "como_aprendo"
      estado == "nao_perguntado" -> "perguntar_horario"
      estado == "perguntado" -> "aguardar_horario"
      true -> nil
    end
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

  # ---- voz (etapa 5.2.3): preferencia por audio ou texto, guardada no perfil ("voz": "audio" | "texto"; sem ela, a Iara acompanha o corretor)
  @doc "Preferencia de resposta do corretor: \"audio\" | \"texto\" | nil (acompanha: audio com audio, texto com texto)."
  def voz_preferida(tenant), do: perfil(tenant)["voz"]

  # ---- fala
  @doc """
  Texto-base -> texto natural da Iara. opts: situacao, dados (mapa), texto (do corretor), origem ("texto" | "audio"), plano_id.
  Nunca falha: erro ou texto fora do contrato = texto fixo (o proprio texto-base).
  """
  def falar(tenant, base, opts \\ []) do
    if opts[:fixo] == true or match?({:bloqueado, _}, TetoIA.status(tenant)) do
      base
    else
      entrada = %{
        "situacao" => to_string(opts[:situacao] || "geral"),
        "base" => base,
        "mensagem_do_corretor" => opts[:texto],
        "origem" => opts[:origem] || "texto",
        "dados" => opts[:dados] || %{},
        "plano" => opts[:plano_id]
      }

      entrada = Map.merge(entrada, opts[:contexto] || %{})

      case IA.chamar(tenant, :pequena, :falar, entrada) do
        {:ok, %{"texto" => t}, uso} ->
          Evento.custo(tenant, opts[:plano_id], "planejador", "falar", uso)
          if valido?(t, base, opts), do: String.trim(t), else: base

        _ ->
          base
      end
    end
  end

  @doc "Texto sem IA (o que o provedor Falso devolve na fala): o proprio texto-base."
  def compor(base, _opts \\ []), do: base

  defp valido?(t, base, opts) when is_binary(t) do
    t = String.trim(t)
    t != "" and String.length(t) <= @max_chars and valores_mantidos?(base, t) and numeradas_mantidas?(t, opts[:numeradas])
  end

  defp valido?(_, _, _), do: false

  # lista numerada de perguntas (etapa 5.2): a fala precisa manter todos os numeros "1." ... "n."
  defp numeradas_mantidas?(_t, n) when n in [nil, 0], do: true
  defp numeradas_mantidas?(t, n), do: Enum.all?(1..n, &String.contains?(t, "#{&1}."))

  # todo numero (2+ digitos, exceto zeros como em ",00") do texto-base precisa continuar no texto
  defp valores_mantidos?(base, t) do
    ~r/\d{2,}/ |> Regex.scan(base) |> List.flatten() |> Enum.reject(&(String.trim(&1, "0") == "")) |> Enum.all?(&String.contains?(t, &1))
  end

  # ---- transcricao (IA pequena; custo no teto)
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
