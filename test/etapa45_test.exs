# Teste geral da etapa 4.5 (ativacao com confirmacao, monitor agendado, relatorios, teto de IA, cotacao, feed de imoveis).
# Escrito ANTES de construir. Rodar: MIX_ENV=test mix test
# REGRA: este banco e o de producao. Dados do teste: tenants tp5_*, fonte "tp_teste" (feed e cotacao). Oban em modo :inline
# (nao grava no banco). Nenhuma plataforma real, nenhuma IA real, nenhum aviso real (notificar = funcao do teste).
defmodule Etapa45Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano, Proposta, Monitor, Cotacao, Custo, TetoIA, Feed, Evento}
  alias Trafego.Plataforma.{Simulada, Meta}

  @confirma "so pra confirmar se entendi, posso fazer isso mesmo?"
  @pedido "pedido destino site; url https://corretor.com.br/lancamento; pixel 998877; publico casais 30-45 zona sul; " <>
            "criativo foto1.jpg | Apartamento novo na zona sul; diario R$ 50; teto R$ 500; janela #{Date.utc_today()} #{Date.add(Date.utc_today(), 30)}; meta 20; custo_max R$ 15"

  @chaves ~w(cotacao_usd_brl teto_ia_brl preco_brl_por_mil notificar cotacao_fonte feed_fonte ptax_base_url relatorio_horas preco_usd_por_milhao)a

  setup_all do
    Registro.migrar!()
    Trafego.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}
    Application.put_env(:trafego, :cotacao_fonte, "tp_teste")
    Application.put_env(:trafego, :feed_fonte, "tp_teste")
    Application.put_env(:trafego, :teto_ia_brl, 1000.0)

    on_exit(fn ->
      limpar()
      for {k, v} <- salvo, do: (case v do {:ok, x} -> Application.put_env(:trafego, k, x); :error -> Application.delete_env(:trafego, k) end)
    end)

    :ok
  end

  setup do
    pid = self()
    Application.put_env(:trafego, :notificar, fn tenant, texto -> send(pid, {:aviso, tenant, texto}) end)
    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp5\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp5\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM feed_imoveis WHERE fonte = 'tp_teste'", [])
    Postgrex.query!(Registro, "DELETE FROM trafego_cotacao WHERE fonte = 'tp_teste'", [])
  end

  defp resp({:ok, r}), do: r
  defp avisos(acc \\ []), do: (receive do {:aviso, t, x} -> avisos([{t, x} | acc]) after 0 -> Enum.reverse(acc) end)
  defp evs(t, ref), do: for(%{tipo: "operacao", dados: %{"ref" => ^ref} = d} <- Registro.eventos(t), do: d)
  defp resultados(t), do: for(%{tipo: "resultado", dados: %{"papel" => "monitor", "ref" => r}} <- Registro.eventos(t), do: r)

  defp vincular(t) do
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    conta
  end

  # tenant com campanha criada PAUSADA e verificada (fluxo da 4.1); devolve {tenant, plano_id, campanha_id}
  defp montar(extra \\ "") do
    t = "tp5_#{System.unique_integer([:positive])}"
    vincular(t)
    assert resp(Agente.processar(t, @pedido <> extra)) =~ "confirma"
    assert resp(Agente.processar(t, "pode fazer sim")) =~ "pausada"
    %{"id" => id, "campanha_id" => cid, "status" => "verificado"} = Plano.listar(t) |> List.last()
    {t, id, cid}
  end

  defp status(cid), do: Simulada.todas() |> Enum.find(&(&1["id"] == cid))

  defp ativar!(t, cid) do
    assert resp(Agente.processar(t, "pode ativar a campanha?")) =~ ~r/ativ.*confirma/s
    assert resp(Agente.processar(t, "sim, pode ativar")) =~ "ativa"
    assert status(cid)["status"] == "ATIVA"
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "ativacao so com confirmacao clara em texto livre; ambigua repergunta; negativa nao muda nada; tudo passa pelo gancho" do
    {t, pid, cid} = montar()
    assert status(cid)["status"] == "PAUSADA"

    # o pedido de ativar so cria PROPOSTA (diz o que vai fazer e pergunta); nada muda na plataforma
    r = resp(Agente.processar(t, "pode ativar a campanha?"))
    assert r =~ ~r/ativar/i and r =~ "confirma" and not (r =~ pid)
    assert [%{"tipo" => "ativar", "status" => "aguardando_confirmacao", "plano_id" => ^pid}] = Proposta.listar(t)
    assert status(cid)["status"] == "PAUSADA"

    # ambigua: repergunta curta, nada executa (varias vezes)
    assert resp(Agente.processar(t, "hmm, talvez, nao sei ainda")) =~ "você confirma?"
    assert resp(Agente.processar(t, "sim mas nao")) =~ "você confirma?"
    assert status(cid)["status"] == "PAUSADA"
    assert [%{"status" => "aguardando_confirmacao"}] = Proposta.listar(t)

    # sem confirmacao o gancho barra mesmo chamando direto
    [%{"id" => prop}] = Proposta.listar(t)
    assert {:error, :sem_confirmacao} = Trafego.Ativacao.executar(t, prop)
    assert status(cid)["status"] == "PAUSADA"

    # negativa: proposta recusada, nada muda, nada pendente
    assert resp(Agente.processar(t, "nao, cancela")) =~ "nada foi alterado"
    assert [%{"status" => "recusada"}] = Proposta.listar(t)
    assert Proposta.abertas(t) == []
    assert status(cid)["status"] == "PAUSADA"

    # nova proposta + confirmacao clara: ativa e VERIFICA lendo de volta (campanha, conjunto e anuncio)
    assert resp(Agente.processar(t, "ativa a campanha")) =~ "confirma"
    assert resp(Agente.processar(t, "Perfeito, pode ativar sim!")) =~ ~r/ativ/i
    camp = status(cid)
    assert camp["status"] == "ATIVA"
    assert [%{"status" => "ATIVA", "anuncios" => [%{"status" => "ATIVA"}]}] = camp["conjuntos"]
    assert %{"status" => "ativa"} = Plano.ler(t, pid)
    assert Enum.any?(Proposta.listar(t), &(&1["status"] == "executada" and &1["tipo"] == "ativar"))
    assert Enum.any?(Registro.eventos(t), &(&1.tipo == "confirmacao"))

    # a conversa do corretor nunca vira evento
    todo = Registro.eventos(t) |> Enum.map(&Jason.encode!(&1.dados)) |> Enum.join(" ")
    for trecho <- ["Perfeito", "talvez", "cancela"], do: refute(todo =~ trecho)
  end

  test "teto alto dito pelo corretor nao e barrado: o plano pede confirmacao e nada e criado antes do sim" do
    t = "tp5_#{System.unique_integer([:positive])}"
    conta = vincular(t)
    r = resp(Agente.processar(t, String.replace(@pedido, "teto R$ 500", "teto R$ 20000")))
    assert r =~ "confirma" and not (r =~ "maximo")
    assert %{"status" => "aguardando_confirmacao", "teto_total" => 2_000_000} = Plano.atual(t)
    assert Simulada.todas() |> Enum.filter(&(&1["conta_id"] == conta)) == []
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "monitor: meta_batida, dados_insuficientes e desvio; desvio gera PROPOSTA e nao altera a campanha" do
    {t, pid, cid} = montar()
    ativar!(t, cid)

    # poucos dados (gasto abaixo da amostra minima de 3x o custo maximo): nao conclui
    Simulada.injetar_metricas(cid, %{"gasto" => 1000, "resultados" => 0})
    assert [{^pid, :dados_insuficientes}] = Monitor.rodar(t)

    # meta batida: 20 resultados a R$ 10 cada (<= R$ 15)
    Simulada.injetar_metricas(cid, %{"gasto" => 20_000, "resultados" => 20})
    assert [{^pid, :meta_batida}] = Monitor.rodar(t)
    assert Proposta.abertas(t) == []

    # desvio que nao queima orcamento: custo por resultado acima do maximo
    Simulada.injetar_metricas(cid, %{"gasto" => 6000, "resultados" => 2})
    avisos()
    assert [{^pid, :desvio}] = Monitor.rodar(t)
    # proposta de pausar, nunca alteracao: a campanha continua ATIVA ate o corretor confirmar
    assert [%{"tipo" => "pausar", "status" => "aguardando_confirmacao", "plano_id" => ^pid}] = Proposta.abertas(t)
    assert status(cid)["status"] == "ATIVA"
    # rodar de novo nao duplica a proposta
    Monitor.rodar(t)
    assert length(Proposta.abertas(t)) == 1
    # resultado so e emitido quando o estado muda
    assert resultados(t) == ~w(dados_insuficientes meta_batida desvio)

    # confirmar a proposta (texto livre) e que pausa
    assert resp(Agente.processar(t, "pode pausar")) =~ ~r/paus/i
    assert status(cid)["status"] == "PAUSADA"
    assert %{"status" => "pausada"} = Plano.ler(t, pid)
  end

  test "desvio que queima orcamento avisa na hora; relatorio com limite de frequencia" do
    {t, pid, cid} = montar()
    ativar!(t, cid)
    Application.put_env(:trafego, :relatorio_horas, 24)
    avisos()

    # queimando: gasto >= 50% do teto (R$ 250) sem nenhum resultado
    Simulada.injetar_metricas(cid, %{"gasto" => 26_000, "resultados" => 0})
    agora = DateTime.utc_now()
    assert [{^pid, :desvio}] = Monitor.rodar(t, agora: agora)
    msgs = avisos() |> Enum.map(&elem(&1, 1))
    assert Enum.any?(msgs, &(&1 =~ ~r/alerta|queim|gast/i and not (&1 =~ pid)))
    assert status(cid)["status"] == "ATIVA"
    assert [%{"tipo" => "pausar"}] = Proposta.abertas(t)

    # relatorio: um resumo por janela; chamadas seguidas nao reenviam, 25h depois envia de novo
    avisos()
    Monitor.rodar(t, agora: DateTime.add(agora, 3600))
    assert Enum.count(avisos(), fn {_, x} -> x =~ ~r/relatorio|resumo/i end) == 0
    Monitor.rodar(t, agora: DateTime.add(agora, 25 * 3600))
    assert Enum.count(avisos(), fn {_, x} -> x =~ ~r/relatorio|resumo/i end) == 1
  end

  test "plano com a janela encerrada vira encerrada, com relatorio final; isolamento entre tenants" do
    {ta, pa, ca} = montar()
    {tb, pb, cb} = montar()
    ativar!(ta, ca)
    ativar!(tb, cb)
    Simulada.injetar_metricas(ca, %{"gasto" => 20_000, "resultados" => 20})
    Simulada.injetar_metricas(cb, %{"gasto" => 100, "resultados" => 0})
    avisos()

    assert [{^pa, :meta_batida}] = Monitor.rodar(ta)
    assert [{^pb, :dados_insuficientes}] = Monitor.rodar(tb)
    assert resultados(ta) == ["meta_batida"]
    assert resultados(tb) == ["dados_insuficientes"]

    Monitor.rodar(ta, agora: DateTime.add(DateTime.utc_now(), 60 * 86400))
    assert %{"status" => "encerrada"} = Plano.ler(ta, pa)
    assert %{"status" => "ativa"} = Plano.ler(tb, pb)
    assert Enum.any?(avisos(), fn {tt, x} -> tt == ta and x =~ ~r/final|encerr/i end)
  end

  test "agendador Oban: tres workers (monitor, cotacao, feed); em teste roda inline" do
    nomes = Trafego.Agendador.crontab() |> Enum.map(fn {_cron, w} -> w end)
    for w <- [Trafego.Workers.Monitor, Trafego.Workers.Cotacao, Trafego.Workers.Feed], do: assert(w in nomes)
    assert Application.get_env(:trafego, :oban_opts)[:testing] == :inline
    assert :ok = Trafego.Workers.Monitor.perform(%Oban.Job{args: %{"tenants" => []}})
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "teto de IA em R$ por corretor: aviso a 80%, bloqueio a 100%; bloqueado nao chama IA nem altera nada" do
    t = "tp5_#{System.unique_integer([:positive])}"
    conta = vincular(t)
    Application.put_env(:trafego, :teto_ia_brl, 5.0)
    on_exit(fn -> Application.put_env(:trafego, :teto_ia_brl, 1000.0) end)
    avisos()

    assert TetoIA.status(t) == :ok
    Evento.emitir(t, "custo_tokens", nil, "planejador", "x", %{"modelo" => "falso-media", "tokens_in" => 1, "tokens_out" => 1, "custo_brl" => 4.2})
    assert {:aviso, %{gasto: g, teto: 5.0}} = TetoIA.status(t)
    assert_in_delta g, 4.2, 0.001

    # com aviso ainda segue, e avisa o corretor uma unica vez no mes
    assert resp(Agente.processar(t, @pedido)) =~ "confirma"
    assert Enum.count(avisos(), fn {_, x} -> x =~ ~r/teto de IA/i end) <= 1

    Evento.emitir(t, "custo_tokens", nil, "planejador", "x", %{"modelo" => "falso-media", "tokens_in" => 1, "tokens_out" => 1, "custo_brl" => 1.0})
    assert {:bloqueado, _} = TetoIA.status(t)
    antes = Registro.eventos(t) |> Enum.count(&(&1.tipo == "custo_tokens"))

    r = resp(Agente.processar(t, "pode fazer sim"))
    assert r =~ ~r/teto de IA/i and r =~ "nada foi alterado"
    assert Simulada.todas() |> Enum.filter(&(&1["conta_id"] == conta)) == []
    assert Registro.eventos(t) |> Enum.count(&(&1.tipo == "custo_tokens")) == antes
    assert length(evs(t, "teto_ia_bloqueado")) >= 1

    # o teto de um corretor nao bloqueia outro
    Application.put_env(:trafego, :teto_ia_brl, 1000.0)
    {t2, _, _} = montar()
    assert TetoIA.status(t2) == :ok
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "cotacao PTAX: busca diaria, volta ate achar dia util, guarda com a data e usa a ultima conhecida na falha" do
    ptax = fn %{caminho: c, query: q} ->
      assert c =~ "CotacaoDolarDia"

      if q["@dataCotacao"] == "'10-16-2026'",
        do: {200, %{"value" => [%{"cotacaoCompra" => 5.0, "cotacaoVenda" => 5.05, "dataHoraCotacao" => "2026-10-16 13:06:52.1"}]}},
        else: {200, %{"value" => []}}
    end

    Application.delete_env(:trafego, :cotacao_usd_brl)
    srv = HttpFalso.start(ptax)
    Application.put_env(:trafego, :ptax_base_url, HttpFalso.url(srv))

    assert Cotacao.atual() == nil
    assert {:ok, %{usd_brl: 5.05, data: ~D[2026-10-16]}} = Cotacao.atualizar(hoje: ~D[2026-10-18])
    assert %{usd_brl: 5.05, data: ~D[2026-10-16]} = Cotacao.atual()

    # falha da fonte: continua valendo a ultima conhecida
    HttpFalso.parar(srv)
    assert {:error, _} = Cotacao.atualizar(hoje: ~D[2026-10-19])
    assert %{usd_brl: 5.05, data: ~D[2026-10-16]} = Cotacao.atual()

    Application.put_env(:trafego, :preco_usd_por_milhao, %{"modelo-real-x" => {1.0, 4.0}})
    assert_in_delta Custo.brl("modelo-real-x", 1_000_000, 0), 5.05, 0.0001

    # o evento de custo marca a cotacao e a data usadas
    t = "tp5_#{System.unique_integer([:positive])}"
    vincular(t)
    Evento.custo(t, nil, "planejador", "planejar", %{"modelo" => "modelo-real-x", "tokens_in" => 1_000_000, "tokens_out" => 0})
    assert [%{dados: %{"cotacao" => 5.05, "cotacao_data" => "2026-10-16"}}] = Registro.eventos(t) |> Enum.filter(&(&1.tipo == "custo_tokens"))
  end

  # ------------------------------------------------------------------------------------------------------------------
  @dump """
  -- dump de teste (mesmo formato do mysqldump da wp_produtos; so as colunas usadas)
  INSERT INTO `wp_produtos` (`id`, `imagem`, `nome`, `regiao`, `regiao_base`, `dormitorios`, `estagio_obra`, `valor`, `estado_obra`, `updated_at`) VALUES
  (1, 'a.jpg', 'Luzes do Rio', 'Piedade', 'Zona Norte', '2 e 3 dorms', 'Em obras', 0.00, 'Lancamento', '2026-10-01 10:00:00'),
  (2, 'b.jpg', 'Parque d\\'Agua', 'Barra', 'Zona Oeste', '', 'Pronto', 450000.50, 'ESGOTADO', '2026-10-02 10:00:00'),
  (3, 'c.jpg', 'Vista; Mar', 'Leblon', 'Zona Sul', '1 dorm', 'Pronto', 0.00, '', '2026-10-03 10:00:00');
  """

  # 4.6: imovel nao tem status; esgotado/vendido deixou de existir (ver etapa46_test.exs)
  test "feed: importa o dump .sql (id, nome, bairro, regiao, dormitorios, valor, imagem, data); estado da obra e so informativo" do
    arq = Path.join(System.tmp_dir!(), "tp5_feed_#{System.unique_integer([:positive])}.sql")
    File.write!(arq, @dump)
    on_exit(fn -> File.rm(arq) end)

    assert {:ok, %{importados: 3}} = Feed.importar(arq)
    assert %{id: "2", nome: "Parque d'Agua", bairro: "Barra", valor_centavos: 45_000_050, estado_original: "ESGOTADO"} = Feed.imovel("2")
    # valor 0 = sem preco (nunca inventar faixa); dormitorios vazio = nao informado
    assert %{valor_centavos: nil} = Feed.imovel("1")
    assert %{dormitorios: nil} = Feed.imovel("2")
    # reimportar nao duplica
    assert {:ok, %{importados: 3}} = Feed.importar(arq)
  end

  test "Meta: ativar fica travado ate a liberacao explicita (nao ha ativacao real sem o Mateus)" do
    srv = HttpFalso.start(fn _ -> {200, %{"success" => true}} end)
    on_exit(fn -> try do HttpFalso.parar(srv) catch :exit, _ -> :ok end end)
    antes = Application.get_env(:trafego, :meta)
    Application.put_env(:trafego, :meta, base_url: HttpFalso.url(srv), versao: "v26.0")
    on_exit(fn -> if antes, do: Application.put_env(:trafego, :meta, antes), else: Application.delete_env(:trafego, :meta) end)

    assert {:error, :ativacao_nao_liberada} = Meta.ativar_campanha(%{"conta_id" => "act_1", "token" => "X"}, "123")
    assert HttpFalso.pedidos(srv) == []
  end
end
