# Teste do laco de aprendizado, passo 1 (trafego 1.13.0): o Monitor grava o DESEMPENHO real do plano no Aprendizado.
# Escrito ANTES de implementar. REGRA: este banco e o de producao. Dados do teste: tenants tp59_*. Plataforma Simulada,
# nenhuma chamada real, nenhum aviso real (notificar = funcao do teste).
defmodule Etapa59Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano, Proposta, Monitor, Aprendizado}
  alias Trafego.Plataforma.Simulada

  @pedido "pedido destino site; url https://corretor.com.br/lancamento; pixel 998877; publico casais 30-45 zona sul; " <>
            "criativo foto1.jpg | Apartamento novo na zona sul; diario R$ 50; teto R$ 500; janela #{Date.utc_today()} #{Date.add(Date.utc_today(), 30)}; meta 20; custo_max R$ 15"

  setup_all do
    Registro.migrar!()
    Trafego.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    on_exit(&limpar/0)
    :ok
  end

  setup do
    pid = self()
    Application.put_env(:trafego, :notificar, fn tenant, texto -> send(pid, {:aviso, tenant, texto}) end)

    on_exit(fn ->
      Application.delete_env(:trafego, :aprendizado_gravar)
      Simulada.falhar(:metricas, nil)
    end)

    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp59\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp59\\_%'", [])
  end

  defp resp({:ok, r}), do: r
  defp avisos(acc \\ []), do: (receive do {:aviso, t, x} -> avisos([{t, x} | acc]) after 0 -> Enum.reverse(acc) end)
  defp status(cid), do: Simulada.todas() |> Enum.find(&(&1["id"] == cid))

  defp montar do
    t = "tp59_#{System.unique_integer([:positive])}"
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    assert resp(Agente.processar(t, @pedido)) =~ "confirma"
    assert resp(Agente.processar(t, "pode fazer sim")) =~ "pausada"
    %{"id" => id, "campanha_id" => cid, "status" => "verificado"} = Plano.listar(t) |> List.last()
    assert resp(Agente.processar(t, "pode ativar a campanha?")) =~ ~r/ativ.*confirma/s
    assert resp(Agente.processar(t, "sim, pode ativar")) =~ "ativa"
    {t, id, cid}
  end

  defp desempenho(t), do: for(r <- Aprendizado.historico(t), r["tipo"] == "desempenho", do: r)
  defp depois(dias), do: DateTime.add(DateTime.utc_now(), dias * 86400)

  @desvio %{"gasto" => 6000, "resultados" => 2}
  @batida %{"gasto" => 20_000, "resultados" => 20}

  test "a: desvio grava 1 registro de desempenho com as metricas e amostra minima atingida" do
    {t, pid, cid} = montar()
    Simulada.injetar_metricas(cid, @desvio)
    assert [{^pid, :desvio}] = Monitor.rodar(t)

    assert [r] = desempenho(t)
    assert r["plano_id"] == pid
    assert r["acao"] == "criar_campanha"
    assert r["resultado"] == "desvio" and r["contra_meta"] == "desvio"
    assert r["situacao"] == Plano.situacao(Plano.ler(t, pid))
    assert r["metricas"] == %{"gasto" => 6000, "resultados" => 2, "custo_por_resultado" => 3000}
    assert r["amostra_minima_atingida"] == true
    assert r["final"] == false
    assert r["regra_violada"] == nil
    assert {:ok, _, _} = DateTime.from_iso8601(r["registrado_em"])
  end

  test "b: meta batida grava 1 registro meta_batida" do
    {t, _pid, cid} = montar()
    Simulada.injetar_metricas(cid, @batida)
    Monitor.rodar(t)
    assert [%{"contra_meta" => "meta_batida", "resultado" => "meta_batida", "amostra_minima_atingida" => true, "final" => false} = r] = desempenho(t)
    assert r["metricas"]["custo_por_resultado"] == 1000
  end

  test "c: abaixo da amostra minima no meio da janela nao grava desempenho" do
    {t, pid, cid} = montar()
    Simulada.injetar_metricas(cid, %{"gasto" => 1000, "resultados" => 0})
    assert [{^pid, :dados_insuficientes}] = Monitor.rodar(t)
    assert desempenho(t) == []
  end

  test "d: rodar duas vezes com o mesmo estado nao duplica" do
    {t, _pid, cid} = montar()
    Simulada.injetar_metricas(cid, @desvio)
    Monitor.rodar(t)
    Monitor.rodar(t)
    assert length(desempenho(t)) == 1
  end

  test "e: de desvio para meta_batida grava 2 registros, na ordem" do
    {t, _pid, cid} = montar()
    Simulada.injetar_metricas(cid, @desvio)
    Monitor.rodar(t)
    Simulada.injetar_metricas(cid, @batida)
    Monitor.rodar(t)
    assert Enum.map(desempenho(t), & &1["contra_meta"]) == ["desvio", "meta_batida"]
  end

  test "f: janela encerrada com leitura de metricas falhando grava 1 final dados_insuficientes e nao duplica" do
    {t, pid, cid} = montar()
    Simulada.injetar_metricas(cid, %{"gasto" => 1000, "resultados" => 0})
    Monitor.rodar(t)
    assert desempenho(t) == []

    Simulada.falhar(:metricas, :indisponivel)
    assert [{^pid, :dados_insuficientes}] = Monitor.rodar(t, agora: depois(60))
    assert [r] = desempenho(t)
    assert r["final"] == true and r["contra_meta"] == "dados_insuficientes" and r["resultado"] == "dados_insuficientes"
    assert r["metricas"] == nil and r["amostra_minima_atingida"] == false
    assert %{"status" => "encerrada"} = Plano.ler(t, pid)

    Monitor.rodar(t, agora: depois(61))
    assert length(desempenho(t)) == 1
  end

  test "f2: encerramento: mudanca conclusiva na mesma rodada = 1 registro final; conclusiva antes + final depois = 2" do
    {t1, _p1, c1} = montar()
    Simulada.injetar_metricas(c1, @desvio)
    Monitor.rodar(t1, agora: depois(60))
    assert [%{"final" => true, "contra_meta" => "desvio", "amostra_minima_atingida" => true}] = desempenho(t1)

    {t2, _p2, c2} = montar()
    Simulada.injetar_metricas(c2, @batida)
    Monitor.rodar(t2)
    Monitor.rodar(t2, agora: depois(60))
    assert [%{"final" => false, "contra_meta" => "meta_batida"}, %{"final" => true, "contra_meta" => "meta_batida"}] = desempenho(t2)

    # desvio final com amostra pequena: sinal fraco, marcado
    {t3, _p3, c3} = montar()
    Simulada.injetar_metricas(c3, %{"gasto" => 1000, "resultados" => 0})
    Monitor.rodar(t3, agora: depois(60))
    assert [%{"final" => true, "contra_meta" => "desvio", "amostra_minima_atingida" => false}] = desempenho(t3)
  end

  test "g: Aprendizado.registrar segue igual e registros antigos nao sao alterados" do
    {t, pid, cid} = montar()
    plano = Plano.ler(t, pid)
    previos = Aprendizado.historico(t)
    Aprendizado.registrar(t, plano, "criar_campanha", "divergente", "regra_x")
    antigo = List.last(Aprendizado.historico(t))

    assert antigo == %{
             "plano_id" => pid, "situacao" => Plano.situacao(plano), "acao" => "criar_campanha", "resultado" => "divergente",
             "contra_meta" => "dados_insuficientes", "regra_violada" => "regra_x"
           }

    Simulada.injetar_metricas(cid, @desvio)
    Monitor.rodar(t)
    assert Aprendizado.historico(t) == previos ++ [antigo, List.last(Aprendizado.historico(t))]
    assert %{"tipo" => "desempenho"} = List.last(Aprendizado.historico(t))
    assert Enum.take(Aprendizado.historico(t), length(previos) + 1) == previos ++ [antigo]
  end

  test "h: atencao e candidatos_catalogo nao mudam com os registros novos" do
    {t, pid, cid} = montar()
    plano = Plano.ler(t, pid)
    Aprendizado.registrar(t, plano, "criar_campanha", "divergente", "regra_x")
    sit = Plano.situacao(plano)
    antes = {Aprendizado.atencao(t, sit), Aprendizado.candidatos_catalogo(t)}
    assert {["regra_x"], [%{regra: "regra_x", ocorrencias: 1}]} = antes

    Simulada.injetar_metricas(cid, @desvio)
    Monitor.rodar(t)
    Simulada.injetar_metricas(cid, @batida)
    Monitor.rodar(t)
    assert length(desempenho(t)) == 2
    assert {Aprendizado.atencao(t, sit), Aprendizado.candidatos_catalogo(t)} == antes
  end

  test "i: o registro cai so no tenant do plano" do
    {ta, _pa, ca} = montar()
    {tb, _pb, cb} = montar()
    Simulada.injetar_metricas(ca, @desvio)
    Simulada.injetar_metricas(cb, %{"gasto" => 100, "resultados" => 0})
    Monitor.rodar(ta)
    Monitor.rodar(tb)
    assert length(desempenho(ta)) == 1
    assert desempenho(tb) == []
  end

  test "j: falha ao gravar o registro nao para o Monitor; emite evento de erro" do
    {t, pid, cid} = montar()
    avisos()
    Application.put_env(:trafego, :aprendizado_gravar, fn _, _, _ -> raise "banco fora" end)
    Simulada.injetar_metricas(cid, %{"gasto" => 26_000, "resultados" => 0})

    assert [{^pid, :desvio}] = Monitor.rodar(t)
    assert desempenho(t) == []
    assert [%{"tipo" => "pausar", "plano_id" => ^pid}] = Proposta.abertas(t)
    assert Enum.any?(avisos(), fn {tt, x} -> tt == t and x =~ pid end)
    assert %{"ultimo_estado" => "desvio"} = Plano.ler(t, pid)
    assert status(cid)["status"] == "ATIVA"

    assert Enum.any?(Registro.eventos(t), fn
             %{tipo: "resultado", dados: %{"papel" => "monitor", "ref" => "erro_registro_desempenho", "plano_id" => ^pid}} -> true
             _ -> false
           end)

    # gravar devolvendo erro tambem nao derruba
    Application.put_env(:trafego, :aprendizado_gravar, fn _, _, _ -> {:error, :x} end)
    Simulada.injetar_metricas(cid, @batida)
    assert [{^pid, :meta_batida}] = Monitor.rodar(t)
  end

  test "k: classificacoes e mensagens do Monitor inalteradas (resultado so na mudanca de estado)" do
    {t, pid, cid} = montar()
    Simulada.injetar_metricas(cid, %{"gasto" => 1000, "resultados" => 0})
    assert [{^pid, :dados_insuficientes}] = Monitor.rodar(t)
    Simulada.injetar_metricas(cid, @batida)
    assert [{^pid, :meta_batida}] = Monitor.rodar(t)
    Simulada.injetar_metricas(cid, @desvio)
    assert [{^pid, :desvio}] = Monitor.rodar(t)
    resultados = for %{tipo: "resultado", dados: %{"papel" => "monitor", "ref" => r}} <- Registro.eventos(t), do: r
    assert resultados == ~w(dados_insuficientes meta_batida desvio)
    assert [%{"tipo" => "pausar"}] = Proposta.abertas(t)
    assert status(cid)["status"] == "ATIVA"
  end

  test "versao" do
    assert to_string(Application.spec(:trafego, :vsn)) == "1.16.0"
  end
end
