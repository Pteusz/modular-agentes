defmodule Trafego.Monitor do
  @moduledoc """
  Monitor: compara resultado e meta do plano e classifica meta_batida | desvio | dados_insuficientes. Roda agendado (Oban) e SO relata:
  emite `resultado` quando o estado muda, avisa o corretor (desvio que queima orcamento avisa na hora; relatorio com limite de
  frequencia) e, no desvio, deixa uma PROPOSTA de pausar. Nunca altera a campanha: alterar e proposta que o corretor confirma.
  Classificacao (decidivel, sem IA): amostra minima = 3x o custo maximo por resultado; abaixo dela nao conclui (a menos que a janela
  tenha acabado). Resultados >= meta com custo por resultado <= maximo = meta_batida; zero resultado, custo acima do maximo ou
  janela encerrada sem meta = desvio; no caminho certo mas sem fechar a meta = dados_insuficientes.
  Queimando: gasto >= teto, ou gasto >= 50% do teto sem resultado ou com custo acima do dobro do maximo.
  """
  alias Trafego.{Acesso, Evento, Notificar, Plano, Proposta}

  @nome "Nucleo.Automacoes.Trafego"
  @alerta_horas 6

  # ---- esqueleto da 4.3 (avaliacao direta com metricas dadas)
  def avaliar(tenant, plano_id, metricas) do
    meta = Plano.ler(tenant, plano_id)["meta"] || %{}

    r =
      case metricas do
        %{"resultados" => n, "custo_por_resultado" => c} when is_integer(n) and n > 0 and is_integer(c) ->
          if n >= meta["resultados"] and c <= meta["custo_max"], do: :meta_batida, else: :desvio

        _ ->
          :dados_insuficientes
      end

    Evento.emitir(tenant, "resultado", plano_id, "monitor", to_string(r))
    r
  end

  # ---- 4.5
  @doc "Todos os tenants da automacao (ou `tenants:`). Devolve %{tenant => [{plano_id, estado}]}."
  def rodar_todos(opts \\ []) do
    tenants = opts[:tenants] || Nucleo.Registro.tenants_da(@nome)
    for t <- tenants, into: %{}, do: {t, rodar(t, opts)}
  end

  @doc "Avalia os planos ATIVOS do tenant. `agora:` (DateTime) so para teste."
  def rodar(tenant, opts \\ []) do
    agora = opts[:agora] || DateTime.utc_now()
    resultado = for %{"status" => "ativa"} = p <- Plano.listar(tenant), do: {p["id"], tratar(tenant, p, agora)}
    Trafego.Saldo.avisar(tenant)
    resultado
  end

  defp tratar(tenant, p, agora) do
    hoje = DateTime.to_date(agora)
    encerrado? = encerrado?(p, hoje)
    metricas = ler_metricas(tenant, p, hoje)
    estado = classificar(p, metricas, encerrado?)

    mudou? = p["ultimo_estado"] != to_string(estado)
    p = registrar_estado(tenant, p, estado)
    if encerrado? or (mudou? and estado != :dados_insuficientes), do: desempenho(tenant, p, estado, metricas, encerrado?, agora)
    p = if estado == :desvio, do: desvio(tenant, p, metricas, agora), else: p
    p = relatorio(tenant, p, metricas, estado, agora, encerrado?)
    p = if encerrado?, do: Map.put(p, "status", "encerrada"), else: p
    Plano.salvar(tenant, p)
    estado
  end

  def classificar(_p, nil, _), do: :dados_insuficientes

  def classificar(p, m, encerrado?) do
    meta = p["meta"] || %{}
    gasto = m["gasto"] || 0
    r = m["resultados"] || 0
    custo_max = meta["custo_max"] || 0
    cpr = if r > 0, do: div(gasto, r)

    cond do
      r > 0 and r >= (meta["resultados"] || 0) and cpr <= custo_max -> :meta_batida
      gasto < 3 * custo_max and not encerrado? -> :dados_insuficientes
      r == 0 -> :desvio
      cpr > custo_max -> :desvio
      encerrado? -> :desvio
      true -> :dados_insuficientes
    end
  end

  def queimando?(p, m) do
    gasto = m["gasto"] || 0
    r = m["resultados"] || 0
    teto = p["teto_total"] || 0
    custo_max = get_in(p, ["meta", "custo_max"]) || 0
    gasto >= teto or (gasto * 2 >= teto and (r == 0 or div(gasto, r) > 2 * custo_max))
  end

  defp registrar_estado(tenant, p, estado) do
    nome = to_string(estado)

    if p["ultimo_estado"] == nome do
      p
    else
      Evento.emitir(tenant, "resultado", p["id"], "monitor", nome)
      Map.put(p, "ultimo_estado", nome)
    end
  end

  # laco de aprendizado: UMA vez por mudanca conclusiva e UMA no fechamento da janela; falha so vira evento (o Monitor segue)
  defp desempenho(tenant, p, estado, metricas, final?, agora) do
    case Trafego.Aprendizado.registrar_desempenho(tenant, p, estado, metricas: metricas, final: final?, agora: agora) do
      :ok -> :ok
      _ -> Evento.emitir(tenant, "resultado", p["id"], "monitor", "erro_registro_desempenho")
    end
  end

  # desvio: proposta de pausar (sem duplicar) e, se esta queimando orcamento, aviso imediato (no maximo a cada #{@alerta_horas}h)
  defp desvio(tenant, p, m, agora) do
    prop = Proposta.aberta(tenant, "pausar", p["id"]) || Proposta.criar(tenant, "pausar", p["id"], %{"motivo" => "desvio_da_meta"})

    if queimando?(p, m) and alerta_liberado?(p, agora) do
      Notificar.enviar(
        tenant,
        "Alerta: o plano #{p["id"]} ja gastou #{Plano.brl(m["gasto"])} (teto #{Plano.brl(p["teto_total"])}) com #{m["resultados"] || 0} resultados, fora da meta. " <>
          "Propus pausar a campanha (proposta #{prop["id"]}); responda confirmando para eu pausar."
      )

      Map.put(p, "alerta_em", DateTime.to_iso8601(agora))
    else
      p
    end
  end

  defp alerta_liberado?(p, agora), do: passou?(p["alerta_em"], agora, @alerta_horas * 3600)

  defp relatorio(tenant, p, m, estado, agora, encerrado?) do
    if encerrado? or passou?(p["relatorio_em"], agora, Trafego.Config.relatorio_horas() * 3600) do
      Notificar.enviar(tenant, texto_relatorio(tenant, p, m, estado, encerrado?))
      Map.put(p, "relatorio_em", DateTime.to_iso8601(agora))
    else
      p
    end
  end

  defp passou?(nil, _, _), do: true

  defp passou?(iso, agora, segundos) do
    case DateTime.from_iso8601(iso) do
      {:ok, antes, _} -> DateTime.diff(agora, antes) >= segundos
      _ -> true
    end
  end

  defp texto_relatorio(tenant, p, m, estado, encerrado?) do
    titulo = if encerrado?, do: "Relatorio final do plano #{p["id"]} (janela encerrada)", else: "Relatorio do plano #{p["id"]}"
    meta = p["meta"] || %{}
    gasto = (m && m["gasto"]) || 0
    r = (m && m["resultados"]) || 0
    cpr = if r > 0, do: "#{Plano.brl(div(gasto, r))} por resultado", else: "sem resultado ainda"

    pendente =
      case Proposta.aberta(tenant, "pausar", p["id"]) do
        nil -> ""
        q -> " Proposta #{q["id"]} (pausar) aguardando sua confirmacao."
      end

    "#{titulo}: gastou #{Plano.brl(gasto)} de #{Plano.brl(p["teto_total"])}; #{r} resultados (meta #{meta["resultados"]}), #{cpr} (maximo #{Plano.brl(meta["custo_max"])}). Situacao: #{situacao(estado)}.#{pendente}"
  end

  defp situacao(:meta_batida), do: "meta batida"
  defp situacao(:desvio), do: "fora da meta"
  defp situacao(:dados_insuficientes), do: "ainda sem dados suficientes para concluir"

  defp ler_metricas(tenant, p, hoje) do
    dias = p |> get_in(["janela", "inicio"]) |> dias_desde(hoje)

    case Acesso.chamar(tenant, :metricas, [p["campanha_id"], dias]) do
      {:ok, m} -> m
      _ -> nil
    end
  end

  defp dias_desde(inicio, hoje) do
    case Date.from_iso8601(inicio || "") do
      {:ok, d} -> Date.diff(hoje, d) |> Kernel.+(1) |> max(1) |> min(90)
      _ -> 30
    end
  end

  defp encerrado?(p, hoje) do
    case Date.from_iso8601(get_in(p, ["janela", "fim"]) || "") do
      {:ok, fim} -> Date.compare(hoje, fim) == :gt
      _ -> false
    end
  end
end
