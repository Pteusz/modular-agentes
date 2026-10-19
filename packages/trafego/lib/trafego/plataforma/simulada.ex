defmodule Trafego.Plataforma.Simulada do
  @moduledoc "Adaptador simulado em memoria. Token alcanca um conjunto de contas (pode alcancar mais que a do tenant)."
  @behaviour Trafego.Plataforma
  use Agent

  def start_link(_ \\ []), do: Agent.start_link(fn -> %{contas: MapSet.new(), tokens: %{}, campanhas: %{}, seq: 0, numeros: %{}, cegas: MapSet.new(), chamadas: %{}, latencia: 0, falhas: %{}} end, name: __MODULE__)

  # ---- ajuda de teste (lado da "plataforma")
  def registrar_conta(id), do: Agent.update(__MODULE__, fn s -> %{s | contas: MapSet.put(s.contas, id)} end)
  def registrar_token(token, alcance), do: Agent.update(__MODULE__, fn s -> %{s | tokens: Map.put(s.tokens, token, alcance)} end)
  @doc "Numeros de WhatsApp vinculados a conta (a Meta so cria o conjunto com um deles). `cega: true`: a leitura dos numeros falha (token sem permissao)."
  def registrar_numeros(conta, lista, opts \\ []),
    do: Agent.update(__MODULE__, fn s -> %{s | numeros: Map.put(s.numeros, conta, lista), cegas: if(opts[:cega], do: MapSet.put(s.cegas, conta), else: MapSet.delete(s.cegas, conta))} end)

  @doc "Medicao: chamadas recebidas por operacao do contrato (%{op => n}); cada funcao do contrato conta uma."
  def chamadas, do: Agent.get(__MODULE__, & &1.chamadas)
  def total_chamadas, do: chamadas() |> Map.values() |> Enum.sum()
  def zerar_chamadas, do: Agent.update(__MODULE__, &%{&1 | chamadas: %{}})
  @doc "Latencia artificial (ms) em CADA chamada do contrato (como a rede da Meta). 0 desliga."
  def latencia(ms), do: Agent.update(__MODULE__, &%{&1 | latencia: ms})
  @doc "Faz a operacao falhar com `motivo` (nil desfaz). Ex.: falhar(:listar_campanhas_com_metricas, :rede)."
  def falhar(op, motivo), do: Agent.update(__MODULE__, fn s -> %{s | falhas: if(motivo, do: Map.put(s.falhas, op, motivo), else: Map.delete(s.falhas, op))} end)

  # conta a chamada, espera a latencia injetada (fora do Agent: chamadas em paralelo esperam juntas) e aplica a falha injetada
  defp passo(op) do
    {ms, falha} = Agent.get_and_update(__MODULE__, fn s -> {{s.latencia, s.falhas[op]}, %{s | chamadas: Map.update(s.chamadas, op, 1, &(&1 + 1))}} end)
    if ms > 0, do: Process.sleep(ms)
    if falha, do: {:error, falha}, else: :ok
  end

  def todas, do: Agent.get(__MODULE__, fn s -> s.campanhas |> Map.values() |> Enum.sort_by(fn c -> c["n"] end) end)
  @doc "Injeta divergencia: altera campos da campanha por fora do executor."
  def injetar(id, attrs), do: Agent.update(__MODULE__, fn s -> %{s | campanhas: Map.update!(s.campanhas, id, fn c -> Map.merge(c, attrs) end)} end)

  @doc "Metricas que a plataforma devolveria para a campanha (gasto em centavos)."
  def injetar_metricas(id, m), do: Agent.update(__MODULE__, fn s -> %{s | campanhas: Map.update!(s.campanhas, id, fn c -> Map.put(c, "metricas", m) end)} end)

  # ---- contrato
  @impl true
  def validar_credencial(cred) do
    with :ok <- passo(:validar_credencial),
         do: Agent.get(__MODULE__, &if(autoriza?(&1, cred), do: {:ok, %{"conta_id" => cred["conta_id"]}}, else: {:error, :credencial_invalida}))
  end

  @impl true
  def numeros_vinculados(cred) do
    with :ok <- passo(:numeros_vinculados), do: numeros(cred)
  end

  defp numeros(cred) do
    Agent.get(__MODULE__, fn s ->
      case s.numeros[cred["conta_id"]] do
        nil -> {:error, :indisponivel}
        lista -> if MapSet.member?(s.cegas, cred["conta_id"]), do: {:error, :indisponivel}, else: {:ok, lista}
      end
    end)
  end

  @impl true
  def criar_campanha(cred, p) do
    with :ok <- passo(:criar_campanha), do: criar(cred, p)
  end

  defp criar(cred, p) do
    Agent.get_and_update(__MODULE__, fn s ->
      lista = s.numeros[cred["conta_id"]]
      chave = Trafego.Ficha.chave_numero(p["numero"])

      cond do
        not autoriza?(s, cred) ->
          {{:error, :credencial_invalida}, s}

        # como a Meta: a campanha nasce e o conjunto recusa o numero nao vinculado (fica uma campanha orfa pausada)
        p["destino"] == "whatsapp" and p["numero"] not in [nil, ""] and is_list(lista) and not Enum.any?(lista, &(Trafego.Ficha.chave_numero(&1) == chave)) ->
          n = s.seq + 1
          orfa = %{"id" => "camp_#{n}", "n" => n, "conta_id" => cred["conta_id"], "nome" => p["nome"], "status" => "PAUSADA", "conjuntos" => []}
          erro = %{"campanha_id" => orfa["id"], "erro" => "graph_100: Falha ao criar campanha: This WhatsApp phone number is not linked to your account"}
          {{:error, {:parcial, "adsets", erro}}, %{s | seq: n, campanhas: Map.put(s.campanhas, orfa["id"], orfa)}}

        true ->
          n = s.seq + 1
          # sempre pausada, qualquer que seja o pedido
          c = %{
            "id" => "camp_#{n}", "n" => n, "conta_id" => cred["conta_id"], "nome" => p["nome"], "status" => "PAUSADA",
            "objetivo" => p["objetivo"], "destino" => p["destino"], "orcamento_diario" => p["orcamento_diario"],
            "teto_total" => p["teto_total"], "janela" => p["janela"],
            "conjuntos" => [
              %{"id" => "conj_#{n}", "status" => "PAUSADA", "publico" => p["publico"],
                "anuncios" => [%{"id" => "anu_#{n}", "status" => "PAUSADA", "criativo" => p["criativo"]}]}
            ]
          }

          {{:ok, c}, %{s | seq: n, campanhas: Map.put(s.campanhas, c["id"], c)}}
      end
    end)
  end

  @impl true
  def ler_campanha(cred, id) do
    with :ok <- passo(:ler_campanha), do: Agent.get(__MODULE__, &acha(&1, cred, id))
  end

  @impl true
  def listar_campanhas(cred) do
    with :ok <- passo(:listar_campanhas), do: listar(cred)
  end

  defp listar(cred) do
    Agent.get(__MODULE__, fn s ->
      if autoriza?(s, cred),
        do: {:ok, s.campanhas |> Map.values() |> Enum.filter(fn c -> c["conta_id"] == cred["conta_id"] end) |> Enum.sort_by(fn c -> c["n"] end) |> Enum.map(&Map.delete(&1, "metricas"))},
        else: {:error, :credencial_invalida}
    end)
  end

  @impl true
  def metricas(cred, id, _dias) do
    with :ok <- passo(:metricas), do: metricas_de(cred, id)
  end

  defp metricas_de(cred, id) do
    with {:ok, c} <- Agent.get(__MODULE__, &acha(&1, cred, id)) do
      {:ok, Map.merge(%{"gasto" => 0, "alcance" => 0, "cliques" => 0, "mensagens_iniciadas" => 0, "resultados" => 0}, c["metricas"] || %{})}
    end
  end

  # lote: UMA chamada devolve a lista com as metricas de cada campanha (como o insights da conta com level=campaign)
  @impl true
  def listar_campanhas_com_metricas(cred, _dias) do
    with :ok <- passo(:listar_campanhas_com_metricas),
         {:ok, lista} <- listar(cred) do
      {:ok, for(c <- lista, {:ok, m} <- [metricas_de(cred, c["id"])], do: Map.put(c, "metricas", m))}
    end
  end

  @impl true
  def editar_campanha(_cred, _id, %{"status" => st}) when st != "PAUSADA", do: {:error, :ativacao_fora_da_fase}

  def editar_campanha(cred, id, attrs) do
    with :ok <- passo(:editar_campanha), do: editar(cred, id, attrs)
  end

  defp editar(cred, id, attrs) do
    Agent.get_and_update(__MODULE__, fn s ->
      case acha(s, cred, id) do
        {:ok, c} ->
          c = Map.merge(c, Map.take(attrs, ~w(nome orcamento_diario teto_total janela)))
          {{:ok, c}, %{s | campanhas: Map.put(s.campanhas, id, c)}}

        e ->
          {e, s}
      end
    end)
  end

  @impl true
  def pausar_campanha(cred, id) do
    with :ok <- passo(:pausar_campanha), do: mudar_status(cred, id, "PAUSADA")
  end

  @impl true
  def ativar_campanha(cred, id) do
    with :ok <- passo(:ativar_campanha), do: mudar_status(cred, id, "ATIVA")
  end

  # campanha, conjuntos e anuncios mudam juntos (o verificador le os tres)
  defp mudar_status(cred, id, status) do
    Agent.get_and_update(__MODULE__, fn s ->
      case acha(s, cred, id) do
        {:ok, c} ->
          conjuntos = for j <- c["conjuntos"] || [], do: %{j | "status" => status, "anuncios" => for(a <- j["anuncios"], do: %{a | "status" => status})}
          c = %{c | "status" => status, "conjuntos" => conjuntos}
          {{:ok, c}, %{s | campanhas: Map.put(s.campanhas, id, c)}}

        e ->
          {e, s}
      end
    end)
  end

  defp autoriza?(s, %{"conta_id" => conta, "token" => token}), do: MapSet.member?(s.contas, conta) and conta in Map.get(s.tokens, token, [])
  defp autoriza?(_, _), do: false

  defp acha(s, cred, id) do
    if autoriza?(s, cred) do
      conta = cred["conta_id"]

      case s.campanhas[id] do
        %{"conta_id" => ^conta} = camp -> {:ok, camp}
        _ -> {:error, :nao_encontrada}
      end
    else
      {:error, :credencial_invalida}
    end
  end
end
