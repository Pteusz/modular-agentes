# Teste geral da etapa 3 (automacao de teste, sem dominio). Rodar: MIX_ENV=test mix test
defmodule Etapa3Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Laco, Canal}
  alias Nucleo.Automacoes.Eco

  setup_all do
    Registro.migrar!()
    :ok
  end

  setup do: {:ok, t: "te#{System.unique_integer([:positive])}"}

  defp espera(fun), do: espera(fun, 100)
  defp espera(fun, n) do
    cond do
      fun.() -> true
      n == 0 -> false
      true -> Process.sleep(20); espera(fun, n - 1)
    end
  end

  defp envia(canal, texto, n) do
    Canal.Simulado.injetar(canal, :proprio, texto)
    assert espera(fn -> length(Canal.Simulado.enviadas(canal)) == n end)
    List.last(Canal.Simulado.enviadas(canal))
  end

  test "laco completo com automacao de teste: verificador, estado lido de volta, atualizacao de versao, gancho", %{t: t} do
    # o molde implementa o contrato aprovado e encaixa no vinculo
    assert :ok = Nucleo.Automacao.compativel(Eco)
    assert {:ok, :criado} = Vincular.vincular(t, Eco, Canal.Simulado, %{})
    {:ok, l1} = Laco.iniciar(t)
    c = Laco.canal(l1)

    # estado retido e lido de volta na execucao seguinte MUDA a saida
    assert envia(c, "oi", 1) == "[agente] eco #1: oi"
    assert envia(c, "tudo bem", 2) == "[agente] eco #2: tudo bem (antes: oi)"
    assert Registro.ler(t, "contagem") == %{"n" => 2}

    # verificador decidivel acusa a regra violada; saida barrada, estado nao avanca
    longo = String.duplicate("x", 100)
    Canal.Simulado.injetar(c, :proprio, longo)
    assert espera(fn -> Enum.any?(Registro.eventos(t), &(&1.tipo == "regra_violada")) end)
    ev = Enum.find(Registro.eventos(t), &(&1.tipo == "regra_violada"))
    assert ev.dados["regras"] == ["tamanho_max"]
    assert Registro.ler(t, "regra_violada") == %{"regras" => ["tamanho_max"]}
    assert length(Canal.Simulado.enviadas(c)) == 2
    assert Registro.ler(t, "contagem") == %{"n" => 2}

    # gancho intercepta a acao que exige aprovacao
    assert envia(c, "!gastar 10", 3) == "[agente] eco #3: !gastar 10 (antes: tudo bem)"
    b = Enum.find(Registro.eventos(t), &(&1.tipo == "acao_bloqueada"))
    assert b.dados == %{"acao" => "gastar", "motivo" => "requer_aprovacao"}

    # atualizar a versao da automacao preserva o estado do tenant
    GenServer.stop(l1)
    assert {:ok, :atualizado} = Vincular.vincular(t, "Nucleo.Automacoes.Eco", "0.2.0", Canal.Simulado)
    assert %{versao: "0.2.0"} = Registro.vinculo(t, "Nucleo.Automacoes.Eco")
    {:ok, l2} = Laco.iniciar(t)
    c2 = Laco.canal(l2)
    assert envia(c2, "voltei", 1) == "[agente] eco #4: voltei (antes: !gastar 10)"

    # outro tenant nao enxerga o estado
    assert Registro.ler(t <> "x", "contagem") == nil
  end
end
