defmodule Trafego.Painel do
  @moduledoc """
  Leitura para o painel (oferta "trafego.painel" 1.1). Leitura, mais o cadastro/remocao da propria conta de anuncios (4.7); nada aqui cria, edita ou ativa campanha. Toda funcao recebe o TENANT
  da sessao (nunca um id de conta): a conta vem do registro do tenant (Trafego.Acesso). Nao devolve token, nem texto da conversa.
  """
  require Logger
  alias Trafego.{AbaIA, Acesso, Cache, Plano, Plataforma}

  @dias 7
  # fallback (caminho antigo, metricas campanha a campanha): poucas em paralelo, cada uma com prazo
  @paralelas 4
  @prazo_metrica 10_000
  @sem_fallback [:token_invalido, :credencial_invalida, :sem_conta, :timeout]

  @doc "Plano aguardando confirmacao (a autorizacao e SO no WhatsApp) ou nil."
  def plano_aguardando(tenant) do
    case Plano.atual(tenant) do
      %{"status" => "aguardando_confirmacao"} = p -> p |> Map.put("resumo", Plano.resumo(p)) |> Map.put("prefixo", "[Iara]")
      _ -> nil
    end
  end

  def dias_padrao, do: @dias

  @doc """
  Campanhas da conta do tenant com metricas dos ultimos 7 dias. {:ok, [campanha]} | {:error, motivo}
  Cache curto por tenant+conta+periodo (Trafego.Cache; `fresco: true` ignora e renova). Sem cache, a plataforma em lote responde em
  2 chamadas (lista + metricas de todas); sem lote, ou se o lote de metricas falhar, as metricas vem uma a uma (em paralelo limitado).
  """
  def campanhas(tenant, dias \\ @dias, opts \\ []) do
    with {:ok, conta} <- conta_utilizavel(tenant) do
      chave = {tenant, conta["conta_id"], dias}

      case if(opts[:fresco], do: :miss, else: Cache.ler(chave)) do
        {:ok, lista} ->
          {:ok, lista}

        :miss ->
          geracao = Cache.geracao(tenant)
          t0 = System.monotonic_time(:millisecond)

          with {:ok, lista, origem} <- carregar(tenant, dias) do
            Cache.gravar(chave, lista, geracao)
            Logger.info("trafego.painel tenant=#{tenant} campanhas=#{length(lista)} origem=#{origem} ms=#{System.monotonic_time(:millisecond) - t0}")
            {:ok, lista}
          end
      end
    end
  end

  @doc "So o que ja esta em cache fresco (sem tocar na plataforma): {:ok, [campanha]} | :miss. Para a tela abrir na hora."
  def campanhas_em_cache(tenant, dias \\ @dias) do
    case Acesso.conta(tenant) do
      %{"conta_id" => conta, "status" => status} when status != "token invalido" -> Cache.ler({tenant, conta, dias})
      %{"conta_id" => conta} -> if Acesso.status(tenant) == "token invalido", do: :miss, else: Cache.ler({tenant, conta, dias})
      _ -> :miss
    end
  end

  @doc "Ultima foto guardada da home (sem tocar na plataforma) ou nil. Chaves de Trafego.Equipe.resumo, mais \"campanhas_total\" quando conhecido."
  def foto(tenant), do: Trafego.Equipe.foto(tenant)

  @doc "Atualiza a foto da home lendo a plataforma (usa o cache curto). {:ok, foto}"
  def atualizar_resumo(tenant), do: Trafego.Equipe.sincronizar(tenant, fresco: false)

  @doc "Uma campanha da conta do tenant (outro id, de outra conta, e :nao_encontrada)."
  def campanha(tenant, id, dias \\ @dias) do
    with {:ok, c} <- Acesso.chamar(tenant, :ler_campanha, [id]) do
      m =
        case Acesso.chamar(tenant, :metricas, [c["id"], dias]) do
          {:ok, m} -> m
          _ -> nil
        end

      {:ok, montar(Map.put(c, "metricas", m), dias)}
    end
  end

  def atividade(tenant), do: AbaIA.projetar(tenant)

  @doc "Cadastro manual pelo proprio usuario (oferta 1.1): valida na plataforma e grava cifrada no tenant da sessao. {:ok, conta_id} | {:error, motivo}"
  def cadastrar_conta(tenant, cred), do: Acesso.cadastrar(tenant, cred)

  @doc "Remove a conta e a foto de sincronizacao do tenant. Nada na plataforma e tocado."
  def remover_conta(tenant), do: Trafego.Equipe.remover_conta(tenant)

  @doc "Conta para tela (token mascarado) ou nil."
  def conta(tenant), do: Acesso.mascarado(tenant)

  def custo_por_resultado(%{"gasto" => g, "resultados" => r}) when is_integer(g) and is_integer(r) and r > 0, do: div(g, r)
  def custo_por_resultado(_), do: nil

  defp conta_utilizavel(tenant) do
    case Acesso.conta(tenant) do
      nil -> {:error, :sem_conta}
      %{"status" => "token invalido"} -> {:error, :token_invalido}
      c -> {:ok, c}
    end
  end

  defp carregar(tenant, dias) do
    if Plataforma.lote?() do
      case Acesso.chamar(tenant, :listar_campanhas_com_metricas, [dias]) do
        {:ok, lista} ->
          origem = if Enum.all?(lista, &Map.has_key?(&1, "metricas")), do: :lote, else: :lote_parcial
          {:ok, Enum.map(completar(tenant, lista, dias), &montar(&1, dias)), origem}

        # o lote falhou por outro motivo que token/conta/prazo: cai no caminho antigo (listagem + metricas uma a uma)
        {:error, e} when e not in @sem_fallback ->
          uma_a_uma(tenant, dias)

        {:error, _} = erro ->
          erro
      end
    else
      uma_a_uma(tenant, dias)
    end
  end

  defp uma_a_uma(tenant, dias) do
    with {:ok, lista} <- Acesso.chamar(tenant, :listar_campanhas, []) do
      {:ok, Enum.map(completar(tenant, lista, dias), &montar(&1, dias)), :uma_a_uma}
    end
  end

  # campanha sem "metricas" (plataforma sem lote ou lote de metricas que falhou): busca uma a uma, em paralelo limitado; erro/prazo = nil
  defp completar(tenant, lista, dias) do
    faltam = for c <- lista, not Map.has_key?(c, "metricas"), do: c["id"]

    achadas =
      Task.Supervisor.async_stream_nolink(Trafego.TaskSupervisor, faltam, fn id -> Acesso.chamar(tenant, :metricas, [id, dias]) end,
        max_concurrency: @paralelas,
        timeout: @prazo_metrica,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(faltam)
      |> Map.new(fn
        {{:ok, {:ok, m}}, id} -> {id, m}
        {_, id} -> {id, nil}
      end)

    for c <- lista, do: if(Map.has_key?(c, "metricas"), do: c, else: Map.put(c, "metricas", achadas[c["id"]]))
  end

  defp montar(%{"metricas" => m} = c, dias) do
    c |> Map.take(~w(id nome status destino orcamento_diario teto_total janela)) |> Map.merge(%{"metricas" => m, "dias" => dias, "custo_por_resultado" => m && custo_por_resultado(m)})
  end
end
