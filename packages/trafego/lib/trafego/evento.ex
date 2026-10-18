defmodule Trafego.Evento do
  @moduledoc """
  Eventos do tenant no formato aprovado: tipo em #{inspect(~w(pedido plano confirmacao operacao verificacao resultado custo_tokens))},
  dados jsonb com plano_id, papel (planejador | executor | verificador | monitor) e ref. No custo_tokens: modelo, tokens_in, tokens_out, custo_brl.
  So metadados: o texto do corretor, a conversa e as credenciais nunca entram aqui.
  """
  alias Nucleo.Registro

  @tipos ~w(pedido plano confirmacao operacao verificacao resultado custo_tokens)
  @papeis ~w(planejador executor verificador monitor)

  def tipos, do: @tipos

  def emitir(tenant, tipo, plano_id, papel, ref, extra \\ %{}) when tipo in @tipos and papel in @papeis do
    Registro.evento(tenant, tipo, Map.merge(extra, %{"plano_id" => plano_id, "papel" => papel, "ref" => ref}))
  end

  @doc "custo_tokens a partir do uso devolvido pelo provedor de IA."
  def custo(tenant, plano_id, papel, ref, %{"modelo" => m, "tokens_in" => ti, "tokens_out" => to}) do
    base = %{"modelo" => m, "tokens_in" => ti, "tokens_out" => to, "custo_brl" => Trafego.Custo.brl(m, ti, to)}

    # modelo cobrado em USD: o evento marca a cotacao (R$ por US$ 1) e a data dela
    extra =
      case Trafego.Custo.cotacao_usada(m) do
        {v, nil} -> Map.put(base, "cotacao", v)
        {v, data} -> Map.merge(base, %{"cotacao" => v, "cotacao_data" => Date.to_iso8601(data)})
        nil -> base
      end

    emitir(tenant, "custo_tokens", plano_id, papel, ref, extra)
  end
end
