# Teste da apresentacao adaptativa (trafego 1.11.0): o primeiro contato e conversa do modelo, uma mensagem por vez, guiada por dados.
# Rodar: MIX_ENV=test mix test test/etapa55_test.exs
# REGRA: tenants tp55_* (so os proprios dados). IA pelo provedor Falso com ROTEIRO (:roteiro_ia). NENHUMA chamada real a OpenAI/Meta.
defmodule Etapa55Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Iara, Banco, Ferramentas}
  alias Trafego.Plataforma.Simulada

  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar provedor_ia numero_cadastrado roteiro_ia openai)a

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
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp55\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp55\\_%'", [])
  end

  # corretor NOVO: sem perfil nenhum (primeiro contato de verdade)
  defp tenant_novo do
    t = "tp55_#{System.unique_integer([:positive])}"
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Nucleo.Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    t
  end

  # apresentacao andada ate a pergunta do horario (sem resposta ainda)
  defp perguntado do
    t = tenant_novo()
    for item <- ~w(quem_sou como_aprendo horario_perguntado), do: Iara.cobrir(t, item)
    t
  end

  defp roteiro(passos), do: Application.put_env(:trafego, :roteiro_ia, passos)
  defp sobra, do: Application.get_env(:trafego, :roteiro_ia)
  defp dizer(t, texto), do: t |> Agente.processar_mensagens(texto) |> then(fn {:ok, r} -> List.wrap(r) end)
  defp eventos(t, ref), do: Banco.q("SELECT dados FROM eventos WHERE tenant_id = $1 AND tipo = 'operacao' ORDER BY id", [t]).rows |> Enum.map(&hd/1) |> Enum.filter(&(&1["ref"] == ref))

  # passo do roteiro que espia a instrucao (politica + ESTADO) que o modelo recebe e devolve outro passo
  defp espia(passo) do
    pid = self()
    fn entrada -> send(pid, {:instrucao, entrada["instrucao"]}) && passo end
  end

  defp instrucao do
    assert_received {:instrucao, i}
    i
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "(i) apresentacao gradual: quem sou -> como aprendo -> horario, UMA mensagem curta por vez" do
    t = tenant_novo()

    roteiro([
      espia({:chamar, "apresentacao", %{"item" => "quem_sou"}}),
      {:texto, "Oi! Eu sou a Iara, da equipe Ataque Total da Cury Construtora. Sou uma IA e cuido das suas campanhas."}
    ])

    r = dizer(t, "oi")
    assert [msg] = r
    assert msg =~ "Iara" and msg =~ "Ataque Total" and msg =~ "Cury Construtora" and msg =~ "IA"
    refute msg =~ "?"
    i = instrucao()
    assert i =~ "se_apresentou=nao" and i =~ "explicou_que_aprende=nao" and i =~ "horario_das_atualizacoes=ainda nao perguntado"
    assert i =~ "proximo item" and i =~ "quem_sou"
    assert sobra() == []
    assert Iara.cobertura(t) == %{"quem_sou" => true, "como_aprendo" => false}
    assert Iara.perfil(t)["horario_estado"] == "nao_perguntado"

    roteiro([
      espia({:chamar, "apresentacao", %{"item" => "como_aprendo"}}),
      {:texto, "Eu me adapto ao seu jeito e aprendo com o tempo, melhorando a cada campanha. Pode mandar audio tambem."}
    ])

    assert [msg2] = dizer(t, "oi, tudo bem?")
    assert msg2 =~ "aprendo" and msg2 =~ "audio"
    i = instrucao()
    assert i =~ "se_apresentou=sim" and i =~ "explicou_que_aprende=nao" and i =~ "como_aprendo"
    assert Iara.cobertura(t) == %{"quem_sou" => true, "como_aprendo" => true}
    assert Iara.perfil(t)["horario_estado"] == "nao_perguntado"

    roteiro([
      espia({:chamar, "apresentacao", %{"item" => "horario_perguntado"}}),
      {:texto, "Qual o melhor horario pra eu te mandar a atualizacao diaria? Se nao me disser, uso 09:00 e voce muda quando quiser."}
    ])

    assert [msg3] = dizer(t, "legal")
    assert msg3 =~ "horario" and msg3 =~ "?"
    i = instrucao()
    assert i =~ "explicou_que_aprende=sim" and i =~ "perguntar_horario"
    assert %{"horario_estado" => "perguntado", "horario_perguntas" => 1} = Iara.perfil(t)
    refute Iara.encerrada?(t)
  end

  test "(i) a politica ensina UM item por mensagem, a ordem e que nao se pergunta o que a pessoa faz" do
    t = tenant_novo()
    roteiro([espia({:texto, "Oi!"})])
    dizer(t, "oi")
    i = instrucao()
    assert i =~ "UM item por mensagem"
    assert i =~ ~r/quem voce e/i and i =~ ~r/aprende/i and i =~ ~r/horario/i
    assert i =~ ~r/Nao pergunte o que ele faz/i
  end

  test "(ii) a politica deixa a Iara dizer que entende audio (o primeiro contato por audio esta na etapa 5.1)" do
    t = tenant_novo()
    roteiro([espia({:texto, "Oi!"})])
    dizer(t, "oi")
    assert instrucao() =~ ~r/entende audio/i
  end

  test "(iii) horario definido ENCERRA a apresentacao: uma frase curta, sem pergunta e sem oferta" do
    t = perguntado()
    roteiro([{:chamar, "combinar_horario", %{"hora" => "08:30"}}, {:texto, "Combinado, todo dia as 08:30."}])
    assert [msg] = dizer(t, "pode ser 8h30")
    assert msg =~ "08:30" and not (msg =~ "?")
    assert Iara.horario(t) == "08:30"
    assert %{"horario_estado" => "definido"} = Iara.perfil(t)
    assert Iara.encerrada?(t)
    assert Iara.proximo_item(t) == nil
    assert eventos(t, "horario_padrao_assumido") == []

    # volta a conversar: o estado diz que a apresentacao acabou
    roteiro([espia({:texto, "Oi! Tudo bem?"})])
    dizer(t, "oi")
    assert instrucao() =~ "apresentacao encerrada"
  end

  test "(iii)(viii) depois do horario o validador barra pergunta e oferta de campanha: corrige uma vez e fica na frase curta" do
    t = perguntado()

    roteiro([
      {:chamar, "combinar_horario", %{"hora" => "07:00"}},
      {:texto, "Combinado, 07:00! Quer que eu monte uma campanha pra voce agora?"},
      {:texto, "Combinado, todo dia as 07:00."}
    ])

    assert [msg] = dizer(t, "7h")
    assert msg == "Combinado, todo dia as 07:00."
    assert sobra() == []

    # texto longo tambem e barrado
    u = perguntado()
    longo = "Combinado, todo dia as 08:30. " <> String.duplicate("Depois a gente conversa sobre tudo com calma e vamos ver o que fazer. ", 5)
    roteiro([{:chamar, "combinar_horario", %{"hora" => "08:30"}}, {:texto, longo}, {:texto, "Combinado, 08:30."}])
    assert ["Combinado, 08:30."] = dizer(u, "8h30")
  end

  test "(iv) sem escolha depois de perguntado: vale o padrao 09:00 (a atualizacao continua ligada)" do
    t = perguntado()
    roteiro([{:texto, "Posso te ajudar com as suas campanhas, os anuncios e o desempenho."}])
    dizer(t, "me conta como esta o desempenho")

    assert %{"horario_estado" => "padrao", "horario" => "09:00"} = Iara.perfil(t)
    assert Iara.horario(t) == "09:00"
    assert Iara.encerrada?(t)
    assert [_] = eventos(t, "horario_padrao_assumido")

    # ele pode mudar depois, sempre
    roteiro([{:chamar, "combinar_horario", %{"hora" => "06:30"}}, {:texto, "Pronto, agora as 06:30."}])
    dizer(t, "muda pra 6h30")
    assert Iara.horario(t) == "06:30" and Iara.perfil(t)["horario_estado"] == "definido"
  end

  test "(iv) perguntou de novo no mesmo turno (hora vaga): continua aguardando; so pergunta duas vezes" do
    t = perguntado()
    roteiro([{:chamar, "apresentacao", %{"item" => "horario_perguntado"}}, {:texto, "Mais tarde quando? Me diz uma hora certinha, ou fico com 09:00?"}])
    assert [msg] = dizer(t, "mais tarde")
    assert msg =~ "?"
    assert %{"horario_estado" => "perguntado", "horario_perguntas" => 2} = Iara.perfil(t)
    assert eventos(t, "horario_padrao_assumido") == []

    # terceira pergunta: a ferramenta recusa; o sistema usa o padrao
    roteiro([
      {:chamar, "apresentacao", %{"item" => "horario_perguntado"}},
      {:texto, "Sem problema, ficamos no horario padrao das 09:00 e voce muda quando quiser."}
    ])

    dizer(t, "sei la")
    assert Iara.perfil(t)["horario_perguntas"] == 2
    assert %{"horario_estado" => "padrao", "horario" => "09:00"} = Iara.perfil(t)
  end

  test "(v) as atualizacoes nao desligam: so o horario muda; hora invalida nao grava nada" do
    t = perguntado()

    roteiro([{:chamar, "lembrar", %{"chave" => "desligar_atualizacao", "valor" => "sim"}}, {:texto, "Isso eu nao posso desligar; so o horario muda."}])
    assert [msg] = dizer(t, "desliga a atualizacao diaria")
    assert msg =~ ~r/nao/i
    assert Iara.perfil(t)["horario_estado"] in ["perguntado", "padrao"]
    refute Map.has_key?(Iara.perfil(t), "desligada")

    u = perguntado()
    roteiro([{:chamar, "combinar_horario", %{"hora" => "nunca"}}, {:texto, "Nao entendi o horario; me diz uma hora, tipo 08:00?"}])
    dizer(u, "nunca")
    assert Iara.horario(u) == "09:00"
    refute Iara.perfil(u)["horario_estado"] == "definido"

    # `lembrar horario_atualizacao` continua valendo e vira o mesmo caminho
    w = perguntado()
    roteiro([{:chamar, "lembrar", %{"chave" => "horario_atualizacao", "valor" => "07:15"}}, {:texto, "Combinado, todo dia as 07:15."}])
    dizer(w, "7:15")
    assert Iara.horario(w) == "07:15" and Iara.encerrada?(w)
  end

  test "(vi) fallback: modelo fora do ar no primeiro contato = UMA mensagem fixa curta, marcada como dita" do
    t = tenant_novo()
    roteiro([{:erro, :indisponivel}])
    assert [msg] = dizer(t, "oi")
    assert msg == Iara.apresentacao_minima()
    assert msg =~ "Iara" and msg =~ "Ataque Total" and msg =~ "IA"
    assert Iara.cobertura(t) == %{"quem_sou" => true, "como_aprendo" => false}

    # ja apresentada: o fallback e o normal, nao repete a apresentacao
    roteiro([{:erro, :indisponivel}])
    assert [msg2] = dizer(t, "oi de novo")
    refute msg2 =~ "Eu sou a Iara"
  end

  test "(vii) UM item por mensagem e na ordem: segundo registro, item repetido e item fora de ordem sao recusados" do
    t = tenant_novo()

    # fora de ordem: nada de como_aprendo nem horario antes de se apresentar
    ctx = %{efeitos: [], leituras: %{}, entrega: nil, entrega_falha: nil, chamadas: []}
    assert {:erro, %{"erro" => "fora_de_ordem"}, _} = Ferramentas.executar(t, "apresentacao", %{"item" => "como_aprendo"}, ctx)
    assert {:erro, %{"erro" => "fora_de_ordem"}, _} = Ferramentas.executar(t, "apresentacao", %{"item" => "horario_perguntado"}, ctx)

    # dois itens na mesma mensagem: o segundo e recusado
    roteiro([
      {:chamar, [{"apresentacao", %{"item" => "quem_sou"}}, {"apresentacao", %{"item" => "como_aprendo"}}]},
      {:texto, "Oi! Eu sou a Iara, da Ataque Total da Cury Construtora, uma IA."}
    ])

    assert [_] = dizer(t, "oi")
    assert Iara.cobertura(t) == %{"quem_sou" => true, "como_aprendo" => false}

    # ja disse quem e: nao repete
    assert {:erro, %{"erro" => "ja_apresentada"}, _} = Ferramentas.executar(t, "apresentacao", %{"item" => "quem_sou"}, ctx)

    # o texto precisa dizer o que foi registrado (nao se grava o que nao foi dito)
    roteiro([{:chamar, "apresentacao", %{"item" => "como_aprendo"}}, {:texto, "Beleza, me diz o que precisa."}, {:texto, "Eu aprendo com o tempo e me adapto ao seu jeito."}])
    assert [msg] = dizer(t, "fala")
    assert msg =~ "aprendo"
    assert sobra() == []
    assert Iara.cobertura(t)["como_aprendo"]
  end

  test "(viii) com plano, proposta ou confirmacao em andamento o estado manda NAO trazer apresentacao; encerrada nao traz nada" do
    t = tenant_novo()
    Iara.cobrir(t, "quem_sou")
    roteiro([espia({:chamar, "planejar", %{"pedido" => "pedido objetivo vender; imovel Torre Sul"}}), {:texto, "Ok."}])
    dizer(t, "quero criar uma campanha do imovel Torre Sul")
    assert instrucao() =~ "proximo item"

    # depois do plano no ar, o proximo turno ja diz para nao trazer apresentacao
    roteiro([espia({:texto, "Seguimos."})])
    dizer(t, "e ai")
    i = instrucao()
    assert i =~ "NAO traga apresentacao" or i =~ "proximo item"

    u = perguntado()
    Iara.definir_horario(u, "09:00")
    roteiro([espia({:texto, "Oi!"})])
    dizer(u, "oi")
    assert instrucao() =~ "apresentacao encerrada: nao traga mais nada dela"
  end

  test "perfil legado (apresentada=true, sem mapa) vale como quem_sou e como_aprendo ja ditos; nova ordem so cobra o horario" do
    t = tenant_novo()
    Iara.atualizar(t, %{"apresentada" => true})
    assert Iara.cobertura(t) == %{"quem_sou" => true, "como_aprendo" => true}
    assert Iara.proximo_item(t) == "perguntar_horario"
    refute Iara.encerrada?(t)
    Iara.assumir_padrao(t)
    assert Iara.encerrada?(t) and Iara.proximo_item(t) == nil
  end
end
