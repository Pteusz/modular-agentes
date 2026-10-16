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
