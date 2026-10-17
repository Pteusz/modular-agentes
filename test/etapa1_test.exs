# Teste geral da etapa 1 (nucleo minimo). Rodar: source env.sh && source /opt/modular-agentes-data/db.env && mix test

defmodule Etapa1Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Manifesto, Laco, Canal}

  setup_all do
    Registro.migrar!()
    :ok
  end

  setup do
    sfx = System.unique_integer([:positive])
    {:ok, a: "ta#{sfx}", b: "tb#{sfx}"}
  end

  defp espera(fun, n \\ 50) do
    cond do
      fun.() -> true
      n == 0 -> false
      true -> Process.sleep(20); espera(fun, n - 1)
    end
  end

  test "dois tenants: vinculo idempotente, estado isolado, laco le o estado de volta, canal filtra, manifesto exato", %{a: a, b: b} do
    # vincular: idempotente e registrado como evento
    assert {:ok, :criado} = Vincular.vincular(a, "esqueleto", "0.1.0", Canal.Simulado)
    assert {:ok, :ja_vinculado} = Vincular.vincular(a, "esqueleto", "0.1.0", Canal.Simulado)
    assert {:ok, :criado} = Vincular.vincular(b, "esqueleto", "0.1.0", Canal.Simulado)
    assert [%{tipo: "vinculado"}] = Registro.eventos(a) |> Enum.filter(&(&1.tipo == "vinculado"))

    # registro: estado versionado e isolado
    {:ok, 1} = Registro.gravar(a, "nota", %{"v" => "segredo-a"})
    {:ok, 2} = Registro.gravar(a, "nota", %{"v" => "segredo-a2"})
    assert %{"v" => "segredo-a2"} = Registro.ler(a, "nota")
    assert [_, _] = Registro.historico(a, "nota")
    assert Registro.ler(b, "nota") == nil
    refute inspect(Registro.eventos(b)) =~ "segredo"

    # laco por tenant, canal simulado com o mesmo contrato
    {:ok, la} = Laco.iniciar(a)
    {:ok, lb} = Laco.iniciar(b)
    ca = Laco.canal(la)
    cb = Laco.canal(lb)

    Canal.Simulado.injetar(ca, :proprio, "oi")
    Canal.Simulado.injetar(ca, :proprio, "oi de novo")
    Canal.Simulado.injetar(cb, :proprio, "ola")
    Canal.Simulado.injetar(ca, :terceiro, "intruso")
    assert espera(fn -> length(Canal.Simulado.enviadas(ca)) == 2 and length(Canal.Simulado.enviadas(cb)) == 1 end)

    # saida prefixada; estado do laco lido de volta (contador por tenant)
    assert Enum.all?(Canal.Simulado.enviadas(ca), &String.starts_with?(&1, "[agente] "))
    assert List.last(Canal.Simulado.enviadas(ca)) =~ "#2"
    assert List.last(Canal.Simulado.enviadas(cb)) =~ "#1"
    assert Registro.ler(a, "contador")["n"] == 2
    assert Registro.ler(b, "contador")["n"] == 1

    # canal ignora fora do chat proprio
    assert Canal.Simulado.ignoradas(ca) == 1
    refute espera(fn -> Enum.any?(Canal.Simulado.enviadas(ca), &(&1 =~ "intruso")) end, 5)

    # teto de envio por tenant
    :ok = Registro.config(b, %{"teto_por_min" => 1})
    Canal.Simulado.injetar(cb, :proprio, "outra")
    assert espera(fn -> Enum.any?(Registro.eventos(b), &(&1.tipo == "envio_limitado")) end)
    assert length(Canal.Simulado.enviadas(cb)) == 1

    # gancho intercepta
    assert Enum.any?(Registro.eventos(a), &(&1.tipo == "gancho"))

    # manifesto: versoes exatas
    m = Manifesto.gerar()
    assert m.amarula == "0.5.10"
    assert m.elixir =~ ~r/^\d+\.\d+\.\d+/
    assert m.otp =~ ~r/^\d+/
    assert m.vinculos |> Enum.any?(&(&1.tenant == a and &1.automacao == "esqueleto" and &1.versao == "0.1.0"))
    refute Enum.any?(Map.values(Map.drop(m, [:vinculos])), &(&1 =~ ~r/[~><]/))
  end

  test "canal real (Amarula): filtro do chat proprio, sem rede" do
    own = fn msg -> msg.own end
    assert {:entregar, "x"} = Canal.Amarula.filtrar(%{own: true, type: :text, content: "x"}, own)
    assert :ignorar = Canal.Amarula.filtrar(%{own: false, type: :text, content: "x"}, own)
    assert {:midia, _} = Canal.Amarula.filtrar(%{own: true, type: :media, content: nil}, own)
    assert :ignorar = Canal.Amarula.filtrar(%{own: false, type: :media, content: nil}, own)
  end
end
