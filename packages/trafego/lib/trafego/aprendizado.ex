defmodule Trafego.Aprendizado do
  @moduledoc """
  Aprendizado minimo por tenant (estado "aprendizado", so inserts): situacao (destino, publico, orcamento, criativo), acao,
  resultado, resultado contra a meta e a REGRA VIOLADA nomeada. Ao propor, o agente le registros de situacoes parecidas.
  Promocao ao catalogo da automacao e manual: aqui so a estrutura (candidatos_catalogo), sem promover nada.
  """
  alias Nucleo.Registro

  def registrar(tenant, plano, acao, resultado, regra \\ nil) do
    Registro.gravar(tenant, "aprendizado", %{
      "plano_id" => plano["id"], "situacao" => Trafego.Plano.situacao(plano), "acao" => acao, "resultado" => resultado,
      "contra_meta" => "dados_insuficientes", "regra_violada" => regra
    })

    :ok
  end

  @doc """
  Registro de DESEMPENHO real do plano (laco de aprendizado): so insert, regra_violada nil (nao entra em atencao/candidatos).
  opts: `metricas:` (mapa da plataforma ou nil), `final:` (janela encerrada), `agora:` (DateTime). Devolve :ok | {:error, motivo};
  nunca levanta. `:aprendizado_gravar` (fn tenant, chave, valor) e so uma costura de teste.
  """
  def registrar_desempenho(tenant, plano, estado, opts \\ []) do
    m = opts[:metricas]
    gasto = m && (m["gasto"] || 0)
    r = (m && (m["resultados"] || 0)) || 0
    custo_max = get_in(plano, ["meta", "custo_max"]) || 0
    agora = opts[:agora] || DateTime.utc_now()

    valor = %{
      "tipo" => "desempenho", "plano_id" => plano["id"], "situacao" => Trafego.Plano.situacao(plano), "acao" => "criar_campanha",
      "resultado" => to_string(estado), "contra_meta" => to_string(estado),
      "metricas" => m && %{"gasto" => gasto, "resultados" => r, "custo_por_resultado" => if(r > 0, do: div(gasto, r))},
      "amostra_minima_atingida" => m != nil and gasto >= 3 * custo_max, "final" => opts[:final] == true,
      "regra_violada" => nil, "registrado_em" => DateTime.to_iso8601(agora)
    }

    gravar = Application.get_env(:trafego, :aprendizado_gravar, &Registro.gravar/3)

    case gravar.(tenant, "aprendizado", valor) do
      {:error, e} -> {:error, e}
      _ -> :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def historico(tenant), do: tenant |> Registro.historico("aprendizado") |> Enum.map(& &1.valor)

  @doc "Registros de situacao parecida: mesmo destino e (mesmo publico ou orcamento diario dentro de 50%)."
  def parecidos(tenant, sit) do
    for r <- historico(tenant), s = r["situacao"], s["destino"] == sit["destino"], publico?(s, sit) or orcamento?(s, sit), do: r
  end

  defp publico?(a, b), do: a["publico"] != nil and a["publico"] == b["publico"]

  defp orcamento?(%{"orcamento_diario" => x}, %{"orcamento_diario" => y}) when is_integer(x) and is_integer(y),
    do: abs(x - y) <= max(x, y) / 2

  defp orcamento?(_, _), do: false

  @doc "Regras violadas distintas em situacoes parecidas (o que o planejador deve ter em conta)."
  def atencao(tenant, sit), do: for(r <- parecidos(tenant, sit), r["regra_violada"], uniq: true, do: r["regra_violada"])

  @doc "Estrutura de promocao manual: regras violadas com contagem. Nada e promovido automaticamente."
  def candidatos_catalogo(tenant) do
    for {regra, n} <- historico(tenant) |> Enum.map(& &1["regra_violada"]) |> Enum.reject(&is_nil/1) |> Enum.frequencies(),
        do: %{regra: regra, ocorrencias: n}
  end
end
