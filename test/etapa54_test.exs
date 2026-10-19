# Teste do painel rapido (5.4). Rodar: MIX_ENV=test mix test test/etapa54_test.exs
# REGRA: este banco e o de producao. So dados proprios: tenants tp_painel_rapido*, e-mails tp54.*@exemplo.test.
# Garante: lote (1 chamada em vez de 1+2N, numeros identicos, fallback), cache por tenant (TTL, invalidacao, sem erro de token),
# Meta com HTTP falso (2 pedidos em vez de 1+2N, paginacao, campanha sem linha = zeros, prazo), casca das telas < 300 ms com 2 s de latencia.
defmodule Etapa54Test do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest, only: [live: 2, render: 1, render_async: 1, render_async: 2]
  alias Nucleo.Registro
  alias PainelBase.Usuarios
  alias Trafego.{Acesso, Cache, Cifra, Equipe, Painel}
  alias Trafego.Plataforma.Simulada

  @endpoint PainelBase.Endpoint
  @t "tp_painel_rapido"
  @tm "tp_painel_rapido_meta"
  @n 5
  @senha "senha-longa-de-teste-54"
  @cred %{"conta_id" => "act_540", "token" => "TK540", "pagina_id" => "p1"}

  setup_all do
    Registro.migrar!()
    PainelBase.Banco.migrar!()
    limpar()
    Registro.criar_tenant(@t)
    Registro.criar_tenant(@tm)
    start_supervised!(Simulada)
    Simulada.registrar_conta("act_540")
    Simulada.registrar_token("TK540", ["act_540"])
    {:ok, _} = Acesso.cadastrar(@t, @cred)
    Application.put_env(:painel_base, :iteracoes_pbkdf2, 1000)

    for i <- 1..@n do
      {:ok, c} = Simulada.criar_campanha(%{"conta_id" => "act_540", "token" => "TK540"}, %{"nome" => "Camp #{i}", "destino" => "site", "orcamento_diario" => 5000, "teto_total" => 50000, "janela" => %{"inicio" => "2026-11-01", "fim" => "2026-11-30"}})
      Simulada.injetar_metricas(c["id"], %{"gasto" => i * 1000, "alcance" => i * 100, "cliques" => i * 10, "mensagens_iniciadas" => i, "resultados" => i})
    end

    on_exit(fn -> limpar() end)
    :ok
  end

  setup do
    Cache.limpar()
    Registro.apagar_chave(@tm, "trafego_conta")
    Simulada.latencia(0)
    for op <- ~w(listar_campanhas_com_metricas listar_campanhas metricas)a, do: Simulada.falhar(op, nil)
    Simulada.zerar_chamadas()
    Application.delete_env(:trafego, :cache_ttl_ms)
    :ok
  end

  defp limpar do
    for t <- [@t, @tm], c <- ~w(trafego_conta trafego_sync), do: Registro.apagar_chave(t, c)
    Postgrex.query!(Registro, "DELETE FROM pb_usuarios WHERE email LIKE 'tp54.%@exemplo.test'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_tentativas WHERE chave LIKE 'e:tp54.%@exemplo.test'", [])
    for tabela <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{tabela} WHERE tenant_id IN ($1, $2)", [@t, @tm])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id IN ($1, $2)", [@t, @tm])
  end

  defp numeros(lista), do: Map.new(lista, &{&1["id"], {&1["nome"], &1["status"], &1["metricas"], &1["custo_por_resultado"]}})

  # o que a tela mostrava ANTES: listagem + metricas campanha a campanha
  defp caminho_antigo(tenant) do
    {:ok, lista} = Acesso.chamar(tenant, :listar_campanhas, [])

    for c <- lista, into: %{} do
      {:ok, m} = Acesso.chamar(tenant, :metricas, [c["id"], 7])
      {c["id"], {c["nome"], c["status"], m, Painel.custo_por_resultado(m)}}
    end
  end

  describe "lote (Simulada)" do
    test "MEDICAO: com 100 ms por chamada, o carregamento cai de 1+N chamadas para 1" do
      Simulada.latencia(100)
      {us, {:ok, lista}} = :timer.tc(fn -> Painel.campanhas(@t, 7, fresco: true) end)
      assert length(lista) >= @n
      assert Simulada.chamadas() == %{listar_campanhas_com_metricas: 1}
      IO.puts("MEDICAO lote N=#{length(lista)} chamadas=#{Simulada.total_chamadas()} tempo=#{div(us, 1000)}ms (antes: #{1 + length(lista)} chamadas, ~#{(1 + length(lista)) * 100}ms)")
      assert div(us, 1000) < 400
    end

    test "mesmos numeros que o caminho antigo" do
      {:ok, lista} = Painel.campanhas(@t, 7, fresco: true)
      assert numeros(lista) == caminho_antigo(@t)
      assert Enum.all?(lista, &(&1["dias"] == 7))
    end

    test "o lote falha: cai no caminho antigo, com os mesmos numeros" do
      Simulada.falhar(:listar_campanhas_com_metricas, {:graph, 1, "falha do lote"})
      {:ok, lista} = Painel.campanhas(@t, 7, fresco: true)
      assert Simulada.chamadas()[:listar_campanhas] == 1
      assert Simulada.chamadas()[:metricas] == length(lista)
      Simulada.falhar(:listar_campanhas_com_metricas, nil)
      assert numeros(lista) == caminho_antigo(@t)
    end

    test "metrica de uma campanha que falha vira nil, sem derrubar a lista" do
      Simulada.falhar(:listar_campanhas_com_metricas, {:graph, 1, "x"})
      Simulada.falhar(:metricas, :rede)
      assert {:ok, lista} = Painel.campanhas(@t, 7, fresco: true)
      assert length(lista) >= @n and Enum.all?(lista, &(&1["metricas"] == nil))
    end

    test "token invalido no lote e erro (sem fallback) e nao fica em cache" do
      Simulada.falhar(:listar_campanhas_com_metricas, :token_invalido)
      assert {:error, :token_invalido} = Painel.campanhas(@t, 7, fresco: true)
      assert Simulada.chamadas() == %{listar_campanhas_com_metricas: 1}
      assert Painel.campanhas_em_cache(@t) == :miss
      Simulada.falhar(:listar_campanhas_com_metricas, nil)
      {:ok, _} = Acesso.cadastrar(@t, @cred)
    end
  end

  describe "cache por tenant" do
    test "segunda leitura nao chama a plataforma" do
      {:ok, a} = Painel.campanhas(@t)
      assert Simulada.total_chamadas() == 1
      assert {:ok, ^a} = Painel.campanhas(@t)
      assert {:ok, ^a} = Painel.campanhas_em_cache(@t)
      assert Simulada.total_chamadas() == 1
      assert {:ok, _} = Painel.campanhas(@t, 7, fresco: true)
      assert Simulada.total_chamadas() == 2
    end

    test "TTL configuravel (e 0 desliga)" do
      Application.put_env(:trafego, :cache_ttl_ms, 20)
      {:ok, _} = Painel.campanhas(@t)
      Process.sleep(40)
      assert Painel.campanhas_em_cache(@t) == :miss
      {:ok, _} = Painel.campanhas(@t)
      assert Simulada.total_chamadas() == 2
      Application.put_env(:trafego, :cache_ttl_ms, 0)
      {:ok, _} = Painel.campanhas(@t)
      {:ok, _} = Painel.campanhas(@t)
      assert Simulada.total_chamadas() == 4
    end

    test "pausar, ativar, criar e editar invalidam" do
      {:ok, [c | _]} = Painel.campanhas(@t)
      id = c["id"]
      nova = %{"nome" => "Nova 54", "destino" => "site", "orcamento_diario" => 5000, "teto_total" => 50000, "janela" => %{"inicio" => "2026-11-01", "fim" => "2026-11-30"}}

      for {op, args} <- [pausar_campanha: [id], ativar_campanha: [id], editar_campanha: [id, %{"status" => "PAUSADA"}], criar_campanha: [nova]] do
        {:ok, _} = Painel.campanhas(@t)
        assert {:ok, _} = Painel.campanhas_em_cache(@t), "#{op}: antes deveria estar em cache"
        Acesso.chamar(@t, op, args)
        assert Painel.campanhas_em_cache(@t) == :miss, "#{op} deveria invalidar o cache"
      end
    end

    test "troca de conta invalida; outro tenant e outra conta nao veem o cache" do
      {:ok, _} = Painel.campanhas(@t)
      assert {:error, :sem_conta} = Painel.campanhas(@tm)
      assert Painel.campanhas_em_cache(@tm) == :miss
      {:ok, _} = Acesso.cadastrar(@t, @cred)
      assert Painel.campanhas_em_cache(@t) == :miss
      {:ok, _} = Painel.campanhas(@t)
      Simulada.registrar_conta("act_541")
      Simulada.registrar_token("TK541", ["act_541"])
      {:ok, _} = Acesso.cadastrar(@t, %{"conta_id" => "act_541", "token" => "TK541", "pagina_id" => "p1"})
      assert {:ok, []} = Painel.campanhas(@t), "outra conta nao enxerga o cache da anterior"
      {:ok, _} = Acesso.cadastrar(@t, @cred)
    end
  end

  describe "Meta (HTTP falso)" do
    setup do
      Application.put_env(:trafego, :plataforma, Trafego.Plataforma.Meta)
      antes = Application.get_env(:trafego, :meta)
      {:ok, env} = Cifra.cifrar(@tm, "TKM")
      Registro.gravar(@tm, "trafego_conta", %{"conta_id" => "act_540", "token_cifrado" => env, "chave_id" => Cifra.chave_id(env), "status" => "ok"})

      on_exit(fn ->
        Application.delete_env(:trafego, :plataforma)
        if antes, do: Application.put_env(:trafego, :meta, antes), else: Application.delete_env(:trafego, :meta)
      end)

      :ok
    end

    @ids ~w(9001 9002 9003 9004 9005)
    defp linha(id) do
      i = String.to_integer(id) - 9000

      %{
        "campaign_id" => id, "spend" => "#{i * 10}.50", "reach" => "#{i * 100}", "clicks" => "#{i * 7}",
        "actions" => [%{"action_type" => "onsite_conversion.messaging_conversation_started_7d", "value" => "#{i}"}, %{"action_type" => "lead", "value" => "1"}]
      }
    end

    # a campanha 9003 nao tem linha de insights (sem gasto no periodo)
    defp servidor(opts) do
      HttpFalso.start(fn %{caminho: caminho, query: q} ->
        cond do
          String.ends_with?(caminho, "/act_540/campaigns") ->
            {200, %{"data" => for(id <- @ids, do: %{"id" => id, "name" => "Meta #{id}", "status" => "ACTIVE"})}}

          opts[:insights_conta_falha] && String.ends_with?(caminho, "/act_540/insights") ->
            {500, %{}}

          String.ends_with?(caminho, "/act_540/insights") ->
            linhas = for id <- @ids, id != "9003", do: linha(id)

            {fatia, paging} =
              cond do
                opts[:paginas] != 2 -> {linhas, %{}}
                q["after"] == nil -> {Enum.take(linhas, 2), %{"cursors" => %{"after" => "CUR1"}, "next" => "http://x"}}
                true -> {Enum.drop(linhas, 2), %{}}
              end

            {200, %{"data" => fatia, "paging" => paging}}

          String.ends_with?(caminho, "/insights") ->
            id = caminho |> String.split("/") |> Enum.at(-2)
            {200, %{"data" => if(id == "9003", do: [], else: [linha(id)])}}

          true ->
            {200, %{"id" => caminho |> String.split("/") |> List.last(), "account_id" => "540"}}
        end
      end)
    end

    defp apontar(srv, extra \\ []) do
      on_exit(fn ->
        try do
          HttpFalso.parar(srv)
        catch
          :exit, _ -> :ok
        end
      end)

      Application.put_env(:trafego, :meta, [base_url: HttpFalso.url(srv), versao: "v26.0"] ++ extra)
    end

    test "2 pedidos HTTP em vez de 1+2N, com os mesmos numeros" do
      srv = servidor([])
      apontar(srv)
      {:ok, lista} = Painel.campanhas(@tm, 7, fresco: true)
      lote = HttpFalso.pedidos(srv)
      assert length(lote) == 2
      assert Enum.map(lote, &Path.basename(&1.caminho)) == ["campaigns", "insights"]
      q = Enum.at(lote, 1).query
      assert q["level"] == "campaign" and q["fields"] =~ "campaign_id" and q["fields"] =~ "spend" and q["time_range"] =~ "since"
      refute Enum.any?(lote, &(&1.caminho =~ ~r{/\d+$})), "nenhum get_da_conta por campanha"

      antes = length(HttpFalso.pedidos(srv))
      antigo = caminho_antigo(@tm)
      assert length(HttpFalso.pedidos(srv)) - antes == 1 + 2 * length(lista), "o caminho antigo fazia 1+2N pedidos"
      assert numeros(lista) == antigo
      assert lista |> Enum.find(&(&1["id"] == "9003")) |> Map.get("metricas") == %{"gasto" => 0, "alcance" => 0, "cliques" => 0, "mensagens_iniciadas" => 0, "resultados" => 0}
      assert lista |> Enum.find(&(&1["id"] == "9002")) |> Map.get("metricas") == %{"gasto" => 2050, "alcance" => 200, "cliques" => 14, "mensagens_iniciadas" => 2, "resultados" => 3}
    end

    test "insights paginado: segue o cursor e casa tudo" do
      srv = servidor(paginas: 2)
      apontar(srv)
      {:ok, lista} = Painel.campanhas(@tm, 7, fresco: true)
      peds = HttpFalso.pedidos(srv)
      assert length(peds) == 3
      assert Enum.at(peds, 2).query["after"] == "CUR1"
      assert lista |> Enum.find(&(&1["id"] == "9005")) |> get_in(["metricas", "gasto"]) == 5050
      assert numeros(lista) == caminho_antigo(@tm)
    end

    test "insights da conta falha: cai nas metricas uma a uma, mesmos numeros" do
      srv = servidor(insights_conta_falha: true)
      apontar(srv)
      {:ok, lista} = Painel.campanhas(@tm, 7, fresco: true)
      assert length(HttpFalso.pedidos(srv)) == 2 + 2 * length(lista)
      assert numeros(lista) == caminho_antigo(@tm)
    end

    test "Meta lenta: erro :timeout no prazo, sem travar" do
      srv =
        HttpFalso.start(fn _ ->
          Process.sleep(600)
          {200, %{"data" => []}}
        end)

      apontar(srv, timeout_leitura: 150)
      {us, r} = :timer.tc(fn -> Painel.campanhas(@tm, 7, fresco: true) end)
      assert r == {:error, :timeout}
      assert div(us, 1000) < 500
      assert Painel.campanhas_em_cache(@tm) == :miss
    end
  end

  describe "telas com latencia de 2 s na plataforma" do
    setup do
      e = "tp54.corretor@exemplo.test"
      {:ok, _} = Usuarios.criar(%{email: e, nome: "Tp54 Corretor", tenant_id: @t, senha: @senha, verificado: true})
      sessao = post(build_conn(), "/entrar", %{"email" => e, "senha" => @senha}) |> recycle()
      on_exit(fn -> Postgrex.query!(Registro, "DELETE FROM pb_usuarios WHERE email = $1", [e]) end)
      {:ok, sessao: sessao}
    end

    test "/campanhas: casca em menos de 300 ms, linhas depois", %{sessao: s} do
      Simulada.latencia(2000)
      {us, {:ok, view, html}} = :timer.tc(fn -> live(s, "/campanhas") end)
      assert div(us, 1000) < 300, "casca levou #{div(us, 1000)} ms"
      assert html =~ "Campanhas" and html =~ "Carregando campanhas" and html =~ "esqueleto"
      refute html =~ "Camp 1"
      cheio = render_async(view, 10_000)
      assert cheio =~ "Camp 1" and cheio =~ "Camp 5" and cheio =~ "R$ 50,00"
      refute cheio =~ "Carregando campanhas"
      assert Simulada.chamadas() == %{listar_campanhas_com_metricas: 1}
    end

    test "/campanhas: cache fresco abre com as linhas na hora, sem chamar a plataforma", %{sessao: s} do
      {:ok, _} = Painel.campanhas(@t)
      Simulada.zerar_chamadas()
      Simulada.latencia(2000)
      {us, {:ok, _view, html}} = :timer.tc(fn -> live(s, "/campanhas") end)
      assert div(us, 1000) < 300 and html =~ "Camp 1" and html =~ "Camp 5"
      assert Simulada.total_chamadas() == 0
    end

    test "/campanhas: erro da plataforma mostra mensagem amigavel", %{sessao: s} do
      Simulada.falhar(:listar_campanhas_com_metricas, :timeout)
      {:ok, view, _} = live(s, "/campanhas")
      assert render_async(view) =~ "A Meta demorou a responder"
    end

    test "home: casca na hora com a ultima foto, atualiza em segundo plano; erro mantem os numeros", %{sessao: s} do
      {:ok, foto} = Equipe.sincronizar(@t)
      total = foto["campanhas_total"]
      assert total >= @n
      Cache.limpar()
      Simulada.zerar_chamadas()
      Simulada.latencia(2000)

      {us, {:ok, view, html}} = :timer.tc(fn -> live(s, "/") end)
      assert div(us, 1000) < 300, "casca levou #{div(us, 1000)} ms"
      assert html =~ "#{total} na sua conta" and html =~ "atualizando"
      assert render_async(view, 10_000) =~ "#{total} na sua conta"
      refute render(view) =~ "atualizando"
      assert Simulada.total_chamadas() == 1

      # a Meta cai: continua a ultima foto
      Cache.limpar()
      Simulada.latencia(0)
      Simulada.falhar(:listar_campanhas_com_metricas, :rede)
      Simulada.falhar(:listar_campanhas, :rede)
      {:ok, v2, h2} = live(s, "/")
      assert h2 =~ "#{total} na sua conta"
      assert render_async(v2) =~ "#{total} na sua conta"
    end

    test "home sem conta: nao conectada, sem chamar a plataforma" do
      e = "tp54.semconta@exemplo.test"
      {:ok, _} = Usuarios.criar(%{email: e, nome: "Sem Conta", tenant_id: @tm, senha: @senha, verificado: true})
      sessao = post(build_conn(), "/entrar", %{"email" => e, "senha" => @senha}) |> recycle()
      {:ok, _, html} = live(sessao, "/")
      assert html =~ "ainda não conectada"
      assert Simulada.total_chamadas() == 0
    end
  end
end
