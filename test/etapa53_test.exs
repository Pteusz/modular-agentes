# Teste da etapa 5.3 (a Iara escolhe ferramentas: laco de conversa, ferramentas, validador de saida, pausa pre-autorizada).
# Rodar: MIX_ENV=test mix test test/etapa53_test.exs
# REGRA: tenants tp53_* (so os proprios dados). IA pelo provedor Falso com ROTEIRO (:roteiro_ia); o adaptador OpenAI contra servidor HTTP
# falso local. NENHUMA chamada real a OpenAI/Meta.
defmodule Etapa53Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano, Proposta, Iara, Banco, Ferramentas, Conversa}
  alias Trafego.Plataforma.Simulada

  @completo "pedido objetivo vender; imovel Torre Sul; destino whatsapp; pixel 998877; publico casais zona sul; diario R$ 50; teto R$ 500; " <>
              "janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15"
  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar provedor_ia numero_cadastrado roteiro_ia openai)a
  @falha "Nao consegui concluir isso agora; nada foi alterado."

  setup_all do
    Registro.migrar!()
    Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}

    on_exit(fn ->
      limpar()
      for {k, v} <- salvo, do: (case v do {:ok, x} -> Application.put_env(:trafego, k, x); :error -> Application.delete_env(:trafego, k) end)
    end)

    :ok
  end

  setup do
    Application.put_env(:trafego, :teto_ia_brl, 1000.0)
    Application.put_env(:trafego, :cotacao_usd_brl, 5.0)
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.Falso)
    Application.put_env(:trafego, :notificar, fn _, _ -> :ok end)
    Application.put_env(:trafego, :numero_cadastrado, fn _ -> "(11) 97420-8400" end)
    Application.delete_env(:trafego, :roteiro_ia)
    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp53\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp53\\_%'", [])
  end

  defp tenant_pronto do
    t = "tp53_#{System.unique_integer([:positive])}"
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Nucleo.Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    # ja conhecida e com horario definido: so interessa a conversa
    Iara.atualizar(t, %{"apresentada" => true, "horario_estado" => "definido", "horario" => "09:00"})
    t
  end

  defp campanha(t, nome, status \\ "ATIVA", metricas \\ nil) do
    {:ok, c} = Acesso.chamar(t, :criar_campanha, [%{"nome" => nome, "objetivo" => "vender", "destino" => "site", "orcamento_diario" => 5000, "teto_total" => 50_000, "janela" => %{"inicio" => "2026-11-01", "fim" => "2026-11-30"}}])
    if status == "ATIVA", do: Simulada.injetar(c["id"], %{"status" => "ATIVA"})
    if metricas, do: Simulada.injetar_metricas(c["id"], metricas)
    c["id"]
  end

  defp status(t, id), do: (with {:ok, c} <- Acesso.chamar(t, :ler_campanha, [id]), do: c["status"])
  defp roteiro(passos), do: Application.put_env(:trafego, :roteiro_ia, passos)
  defp sobra, do: Application.get_env(:trafego, :roteiro_ia)
  defp dizer(t, texto), do: t |> Agente.processar_mensagens(texto) |> then(fn {:ok, r} -> List.wrap(r) end)
  defp junto(l), do: Enum.join(l, "\n")
  defp eventos(t, tipo), do: Banco.q("SELECT dados FROM eventos WHERE tenant_id = $1 AND tipo = $2 ORDER BY id", [t, tipo]).rows |> Enum.map(&hd/1)

  # ------------------------------------------------------------------------------------------------------------------
  test "\"veja quantas campanhas eu tenho\": le e responde; nada de plano novo nem pergunta de ficha" do
    t = tenant_pronto()
    campanha(t, "Apartamento Centro")
    campanha(t, "Casa Praia", "PAUSADA")
    roteiro([{:chamar, "campanhas", %{"ref" => nil, "dias" => nil}}, {:texto, "Voce tem 2 campanhas: c1 ativa e c2 pausada."}])

    l = dizer(t, "veja quantas campanhas eu tenho")
    assert junto(l) =~ "2 campanhas"
    refute junto(l) =~ ~r/objetivo|imovel|verba/i
    assert Plano.listar(t) == [] and Plano.atual(t) == nil
    assert sobra() == []
  end

  test "sem roteiro o Falso nao cria plano para uma frase solta (pedido sem \";\" cai na resposta padrao)" do
    t = tenant_pronto()
    assert junto(dizer(t, "bom dia")) =~ "campanhas"
    assert Plano.listar(t) == []
  end

  test "pausa pela conversa: 1 candidato age com motivo; o motivo vai para o evento e para a resposta" do
    t = tenant_pronto()
    a = campanha(t, "Apartamento Centro")
    b = campanha(t, "Casa Praia")
    roteiro([{:chamar, "pausar", %{"ref" => "apartamento", "motivo" => "o custo por contato passou da meta"}}, {:texto, "Feito, a do apartamento esta pausada."}])

    l = junto(dizer(t, "pausa a do apartamento"))
    assert status(t, a) == "PAUSADA" and status(t, b) == "ATIVA"
    assert l =~ "Pausei Apartamento Centro porque o custo por contato passou da meta"
    ev = Enum.find(eventos(t, "operacao"), &(&1["acao"] == "pausar_campanha"))
    assert ev["motivo"] =~ "custo por contato" and ev["autonoma"] == true
  end

  test "pausa: 2+ candidatos pergunta qual (nada muda); 0 candidatos diz que nao achou" do
    t = tenant_pronto()
    a = campanha(t, "Apartamento Centro")
    b = campanha(t, "Apartamento Praia")
    roteiro([{:chamar, "pausar", %{"ref" => "apartamento", "motivo" => "pedido do corretor"}}, {:texto, "Achei duas: c1 e c2. Qual delas?"}])
    assert junto(dizer(t, "pausa a do apartamento")) =~ "Qual delas"
    assert status(t, a) == "ATIVA" and status(t, b) == "ATIVA"

    roteiro([{:chamar, "pausar", %{"ref" => "cobertura", "motivo" => "pedido do corretor"}}, {:texto, "Nao achei nenhuma campanha de cobertura."}])
    assert junto(dizer(t, "pausa a da cobertura")) =~ "Nao achei"
    assert status(t, a) == "ATIVA" and status(t, b) == "ATIVA"
  end

  test "pausar exige motivo e so fala de campanha da conta: args invalidos, ferramenta inexistente e conta_id sao recusados" do
    t = tenant_pronto()
    a = campanha(t, "Apartamento Centro")
    roteiro([{:chamar, "pausar", %{"ref" => "c1"}}, {:chamar, "campanhas", %{"ref" => nil, "dias" => nil}}, {:chamar, "pausar", %{"ref" => "c1", "motivo" => ""}}, {:texto, "Preciso do motivo para pausar."}])
    assert junto(dizer(t, "pausa a c1")) =~ "motivo"
    assert status(t, a) == "ATIVA"

    roteiro([{:chamar, "apagar_tudo", %{}}, {:chamar, "campanhas", %{"ref" => nil, "dias" => nil, "conta_id" => "act_outra"}}, {:texto, "Nao faco isso."}])
    # duas falhas seguidas cortam o laco
    assert junto(dizer(t, "apaga tudo")) =~ @falha
    assert status(t, a) == "ATIVA"

    roteiro([{:chamar, "apagar_tudo", %{}}, {:texto, "Isso eu nao tenho como fazer, mas posso mostrar suas campanhas."}])
    assert junto(dizer(t, "apaga tudo")) =~ "nao tenho como"
  end

  test "\"como foi ontem\": desempenho vem da ferramenta; numero inventado e rejeitado e corrigido uma vez" do
    t = tenant_pronto()
    campanha(t, "Apartamento Centro", "ATIVA", %{"gasto" => 4000, "resultados" => 4})
    roteiro([{:chamar, "campanhas", %{"ref" => nil, "dias" => 1}}, {:texto, "Ontem a c1 gastou R$ 41,00 e trouxe 4 contatos."}, {:texto, "Ontem a c1 gastou R$ 40,00 e trouxe 4 contatos."}])
    l = junto(dizer(t, "como foi ontem"))
    assert l =~ "R$ 40,00" and l =~ "4 contatos" and not (l =~ "41")
    assert Enum.any?(eventos(t, "operacao"), &(&1["ref"] == "conversa_texto_rejeitado"))
    assert sobra() == []
  end

  test "numero inventado persistindo vira fallback com o texto-base montado por codigo" do
    t = tenant_pronto()
    campanha(t, "Apartamento Centro", "ATIVA", %{"gasto" => 4000, "resultados" => 4})
    roteiro([{:chamar, "campanhas", %{"ref" => nil, "dias" => 1}}, {:texto, "Gastou R$ 999,00."}, {:texto, "Gastou R$ 999,00 mesmo."}])
    l = junto(dizer(t, "como foi ontem"))
    assert l =~ @falha and l =~ "Suas campanhas: c1 Apartamento Centro (ATIVA" and l =~ "R$ 40,00" and not (l =~ "999")
  end

  test "texto que diz \"pausei\" sem execucao e rejeitado; corrigido uma vez, depois fallback; nada muda" do
    t = tenant_pronto()
    a = campanha(t, "Apartamento Centro")
    roteiro([{:texto, "Pausei a campanha do apartamento."}, {:texto, "Pronto, pausei."}])
    l = junto(dizer(t, "pausa a do apartamento"))
    assert l =~ @falha and status(t, a) == "ATIVA"

    roteiro([{:texto, "Ativei a campanha."}, {:texto, "Posso propor a ativacao se ela estiver verificada."}])
    assert junto(dizer(t, "ativa ai")) =~ "propor"
    assert status(t, a) == "ATIVA"
  end

  test "pedido ambiguo: uma pergunta curta, sem efeito; fora de escopo: recusa educada, sem efeito" do
    t = tenant_pronto()
    a = campanha(t, "Apartamento Centro")
    roteiro([{:texto, "Voce quer ver o desempenho ou montar uma campanha nova?"}])
    assert junto(dizer(t, "faz aquilo la")) =~ "desempenho ou montar"
    roteiro([{:texto, "Isso foge do que eu faco: so cuido das suas campanhas, do feed e do desempenho."}])
    assert junto(dizer(t, "me indica um restaurante")) =~ "so cuido das suas campanhas"
    assert status(t, a) == "ATIVA" and Plano.listar(t) == []
  end

  test "limites: mesma chamada 2x corta; 6 chamadas ao modelo; 8 ferramentas" do
    t = tenant_pronto()
    campanha(t, "Apartamento Centro")
    leitura = {:chamar, "campanhas", %{"ref" => nil, "dias" => nil}}

    roteiro([leitura, leitura, {:texto, "nao devia chegar aqui"}])
    l = junto(dizer(t, "campanhas"))
    assert l =~ @falha and l =~ "Suas campanhas: c1" and length(sobra()) == 1

    roteiro(for(n <- 1..8, do: {:chamar, "campanhas", %{"ref" => nil, "dias" => n}}))
    assert junto(dizer(t, "campanhas")) =~ @falha
    assert length(sobra()) == 2

    roteiro([{:chamar, for(n <- 1..9, do: {"campanhas", %{"ref" => nil, "dias" => n}})}, {:texto, "nao devia chegar aqui"}])
    assert junto(dizer(t, "campanhas")) =~ @falha
    assert length(sobra()) == 1
  end

  test "uma acao por mensagem: a segunda e recusada" do
    t = tenant_pronto()
    a = campanha(t, "Apartamento Centro")
    b = campanha(t, "Casa Praia")
    roteiro([{:chamar, [{"pausar", %{"ref" => "apartamento", "motivo" => "custo alto"}}, {"pausar", %{"ref" => "casa", "motivo" => "custo alto"}}]}, {:texto, "Pausei so uma agora."}])
    dizer(t, "pausa as duas")
    assert status(t, a) == "PAUSADA" and status(t, b) == "ATIVA"
  end

  test "teto de IA: a conversa responde a mensagem do teto e nao altera nada" do
    t = tenant_pronto()
    a = campanha(t, "Apartamento Centro")
    Application.put_env(:trafego, :teto_ia_brl, 5.0)
    Trafego.Evento.emitir(t, "custo_tokens", nil, "planejador", "x", %{"modelo" => "falso-media", "tokens_in" => 1, "tokens_out" => 1, "custo_brl" => 6.0})
    roteiro([{:chamar, "pausar", %{"ref" => "apartamento", "motivo" => "custo alto"}}])
    l = junto(dizer(t, "pausa a do apartamento"))
    assert l =~ "teto" and status(t, a) == "ATIVA"
    assert length(sobra()) == 1
  end

  test "sim/nao com outra pergunta no meio: a conversa responde e a confirmacao do plano volta; o sim depois vale" do
    t = tenant_pronto()
    campanha(t, "Apartamento Centro")
    assert hd(dizer(t, @completo)) =~ "Montei o plano"
    assert Plano.atual(t)["status"] == "aguardando_confirmacao"

    roteiro([{:chamar, "campanhas", %{"ref" => nil, "dias" => nil}}, {:texto, "Voce tem 1 campanha: c1."}])
    l = junto(dizer(t, "antes: quantas campanhas eu tenho?"))
    assert l =~ "1 campanha" and l =~ "Sobre o plano p1: voce confirma?"
    assert Plano.atual(t)["status"] == "aguardando_confirmacao"

    l2 = junto(dizer(t, "sim"))
    assert l2 =~ "foto ou o video"
    assert Plano.atual(t)["status"] == "aguardando_criativo"
  end

  test "proposta aberta: resposta que nao e sim nem nao vai para a conversa e a pergunta volta; nao cancela" do
    t = tenant_pronto()
    id = campanha(t, "Apartamento Centro", "PAUSADA")
    plano = Plano.salvar(t, Map.merge(Plano.novo(t), %{"status" => "verificado", "campanha_id" => id, "orcamento_diario" => 5000, "teto_total" => 50_000}))
    prop = Proposta.criar(t, "ativar", plano["id"])

    roteiro([{:texto, "Em geral campanhas novas levam uns dias para render."}])
    l = junto(dizer(t, "isso demora pra render?"))
    assert l =~ "Sobre a proposta #{prop["id"]}: voce confirma?"
    assert Proposta.ler(t, prop["id"])["status"] == "aguardando_confirmacao" and status(t, id) == "PAUSADA"

    assert junto(dizer(t, "nao")) =~ "cancelei a proposta"
    assert Proposta.ler(t, prop["id"])["status"] == "recusada"
  end

  test "propor_ativar so cria a proposta (campanha segue pausada); nao existe ferramenta que ative ou receba conta" do
    t = tenant_pronto()
    id = campanha(t, "Apartamento Centro", "PAUSADA")
    plano = Plano.salvar(t, Map.merge(Plano.novo(t), %{"status" => "verificado", "campanha_id" => id, "orcamento_diario" => 5000, "teto_total" => 50_000, "janela" => %{"inicio" => "2026-11-01", "fim" => "2099-11-30"}}))
    roteiro([{:chamar, "propor_ativar", %{"ref" => "apartamento"}}, {:texto, ""}])
    l = junto(dizer(t, "ativa a do apartamento"))
    assert l =~ "Voce confirma?" and l =~ "ATIVAR"
    assert (p = Proposta.atual(t)) && p["tipo"] == "ativar" && p["plano_id"] == plano["id"]
    assert status(t, id) == "PAUSADA"

    nomes = Ferramentas.nomes()
    refute Enum.any?(nomes, &(&1 =~ ~r/ativar$|ativa$|desligar|verba|orcamento|editar/ and &1 != "propor_ativar"))
    for d <- Ferramentas.definicoes() do
      props = Map.keys(d["parametros"]["properties"])
      refute Enum.any?(props, &(&1 =~ ~r/conta|token|account/)), "ferramenta #{d["nome"]} recebe conta"
      assert d["parametros"]["additionalProperties"] == false and Enum.sort(d["parametros"]["required"]) == Enum.sort(props)
    end
  end

  test "lembrar: horario e preferencia de voz pela conversa; a atualizacao diaria nao tem como ser desligada" do
    t = tenant_pronto()
    roteiro([{:chamar, "lembrar", %{"chave" => "horario_atualizacao", "valor" => "07:30"}}, {:texto, "Anotado: te atualizo todo dia as 07:30."}])
    assert junto(dizer(t, "muda o horario pra 7 e meia")) =~ "07:30"
    assert Iara.horario(t) == "07:30"

    roteiro([{:chamar, "lembrar", %{"chave" => "preferencia_voz", "valor" => "audio"}}, {:texto, "Fechado, respondo por audio."}])
    dizer(t, "responde em audio")
    assert Iara.perfil(t)["voz"] == "audio"

    roteiro([{:chamar, "lembrar", %{"chave" => "desligar_atualizacao", "valor" => "sim"}}, {:texto, "Isso eu nao posso desligar, so o horario."}])
    assert junto(dizer(t, "desliga as atualizacoes")) =~ "nao posso desligar"
    assert Iara.horario(t) == "07:30"
  end

  test "ferramentas de leitura: saldo_e_teto sem saldo da Meta, imoveis como dado, ficha, resultado truncado em ~2 KB" do
    t = tenant_pronto()
    {:ok, r, _} = Ferramentas.executar(t, "saldo_e_teto", %{}, %{})
    assert r["saldo_da_conta_meta"] =~ "indisponivel" and r["teto_de_ia_do_mes"] =~ "R$"

    {:ok, r, _} = Ferramentas.executar(t, "ficha", %{}, %{})
    assert r["plano"] == nil
    {:ok, r, _} = Ferramentas.executar(t, "imoveis", %{"busca" => nil}, %{})
    assert is_list(r["imoveis"]) and r["aviso"] =~ "DADOS"

    grande = %{"campanhas" => for(i <- 1..80, do: %{"id" => "c#{i}", "nome" => String.duplicate("x", 40), "status" => "ATIVA"})}
    json = Ferramentas.codificar(grande)
    assert byte_size(json) <= 2048 and json =~ ~r/\+\d+ itens/
  end

  test "ids curtos e ref ambiguo: c2 resolve; nome em dois devolve candidatas" do
    t = tenant_pronto()
    campanha(t, "Apartamento Centro")
    campanha(t, "Apartamento Praia")
    {:ok, r, _} = Ferramentas.executar(t, "campanhas", %{"ref" => "c2", "dias" => nil}, %{})
    assert [%{"id" => "c2", "nome" => "Apartamento Praia"}] = r["campanhas"]
    {:ok, r, _} = Ferramentas.executar(t, "campanhas", %{"ref" => "apartamento", "dias" => nil}, %{})
    assert r["ambigua"] == true and length(r["candidatas"]) == 2
    {:ok, r, _} = Ferramentas.executar(t, "campanhas", %{"ref" => "terreno", "dias" => nil}, %{})
    assert r["encontradas"] == 0
  end

  test "validador: numeros e verbos (unidade)" do
    fontes = ["{\"gasto\":\"R$ 40,00\",\"id\":\"c1\"}", "quero ver 7 dias"]
    assert Conversa.numero_inventado("gastou R$ 40, em 7 dias na c1", fontes) == nil
    assert Conversa.numero_inventado("gastou R$ 41,00", fontes) == "41,00"
    assert Conversa.numero_inventado("sem numero", fontes) == nil
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "adaptador OpenAI: turno com function calling estrito, sem conta nas ferramentas, e a saida volta no formato neutro" do
    srv = HttpFalso.start(&openai/1)
    Application.put_env(:trafego, :openai, base_url: HttpFalso.url(srv), modelos: %{pequena: "m-p", media: "m-m"}, esforco: %{pequena: "low", media: "medium"})
    System.put_env("OPENAI_API_KEY", "chave-de-teste")

    on_exit(fn ->
      System.delete_env("OPENAI_API_KEY")
      :gen_tcp.close(srv.ls)
    end)

    entrada = %{"instrucao" => "persona", "itens" => [%{"papel" => "corretor", "texto" => "veja minhas campanhas"}], "ferramentas" => Ferramentas.definicoes()}
    assert {:ok, %{"chamadas" => [%{"id" => "call_1", "nome" => "campanhas", "args" => %{"ref" => nil}}], "bruto" => bruto}, %{"modelo" => "m-m", "tokens_in" => 10}} = Trafego.IA.OpenAI.turno(:media, entrada)

    itens = entrada["itens"] ++ [%{"papel" => "chamadas", "bruto" => bruto}, %{"papel" => "resultado", "id" => "call_1", "saida" => "{\"total\":1}"}]
    assert {:ok, %{"texto" => "Voce tem 1 campanha."}, _} = Trafego.IA.OpenAI.turno(:media, %{entrada | "itens" => itens})

    [primeiro, segundo] = HttpFalso.pedidos(srv) |> Enum.map(&Jason.decode!(&1.corpo))
    assert primeiro["store"] == false and primeiro["parallel_tool_calls"] == false and primeiro["reasoning"]["effort"] == "medium"
    assert Enum.all?(primeiro["tools"], &(&1["strict"] == true and &1["type"] == "function"))
    refute inspect(primeiro["tools"]) =~ "conta_id"
    assert Enum.any?(segundo["input"], &(&1["type"] == "function_call_output" and &1["call_id"] == "call_1"))
  end

  defp openai(%{corpo: corpo}) do
    b = Jason.decode!(corpo)
    usage = %{"input_tokens" => 10, "output_tokens" => 5}

    if Enum.any?(b["input"], &(is_map(&1) and &1["type"] == "function_call_output")) do
      {200, %{"status" => "completed", "usage" => usage, "output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Voce tem 1 campanha."}]}]}}
    else
      {200, %{"status" => "completed", "usage" => usage, "output" => [%{"type" => "function_call", "name" => "campanhas", "call_id" => "call_1", "arguments" => "{\"ref\":null,\"dias\":null}"}]}}
    end
  end
end
