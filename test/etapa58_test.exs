# Teste das diretrizes da Iara, passo 2 (trafego 1.12.3): marcador "pergunta aberta" (regra g), `valida` por diretriz e ferramentas
# oferecidas so quando a diretriz casa. Nenhuma chamada nova ao modelo. Rodar: MIX_ENV=test mix test test/etapa58_test.exs
# REGRA: tenants tp58_* (so os proprios dados). IA pelo provedor Falso com ROTEIRO (:roteiro_ia). NENHUMA chamada real a OpenAI/Meta.
defmodule Etapa58Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Iara, Banco, Diretrizes}
  alias Trafego.Plataforma.Simulada

  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar provedor_ia numero_cadastrado roteiro_ia openai)a
  @g "acabou de perguntar"
  @quem_sou "Oi! Eu sou a Iara, da equipe Ataque Total da Cury Construtora. Sou uma IA e cuido das suas campanhas. Você já anunciou imóvel por conta própria?"
  @fecha "Combinado, todo dia as 08:30. Você já está pronto pra criar a sua primeira campanha comigo?"

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
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp58\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp58\\_%'", [])
  end

  defp tenant_novo do
    t = "tp58_#{System.unique_integer([:positive])}"
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Nucleo.Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    t
  end

  defp perguntado do
    t = tenant_novo()
    for item <- ~w(quem_sou como_aprendo horario_perguntado), do: Iara.cobrir(t, item)
    t
  end

  # fecha a apresentacao pelo caminho normal: horario combinado + pergunta de primeira campanha (liga o marcador)
  defp com_pergunta_aberta do
    t = perguntado()
    roteiro([{:chamar, "combinar_horario", %{"hora" => "08:30"}}, {:texto, @fecha}])
    assert [@fecha] = dizer(t, "8h30")
    t
  end

  # apresentacao encerrada sem a pergunta ter sido feita (padrao assumido)
  defp encerrada_sem_pergunta do
    t = perguntado()
    Iara.assumir_padrao(t)
    t
  end

  defp roteiro(passos), do: Application.put_env(:trafego, :roteiro_ia, passos)
  defp sobra, do: Application.get_env(:trafego, :roteiro_ia)
  defp dizer(t, texto), do: t |> Agente.processar_mensagens(texto) |> then(fn {:ok, r} -> List.wrap(r) end)

  defp espia(passo) do
    pid = self()
    fn entrada -> send(pid, {:entrada, entrada}) && passo end
  end

  defp entrada do
    assert_received {:entrada, e}
    e
  end

  defp instrucao, do: entrada()["instrucao"]
  defp nomes(e), do: Enum.map(e["ferramentas"], & &1["nome"])

  # ---- A: marcador pergunta_aberta / regra g
  test "(A) marcador desligado: a instrucao nao tem a regra g, com a apresentacao pendente ou encerrada" do
    t = tenant_novo()
    roteiro([espia({:texto, "Oi!"})])
    dizer(t, "oi")
    i = instrucao()
    assert i =~ "APRESENTACAO (so enquanto"
    refute i =~ @g
    refute i =~ "Depois dessa pergunta"

    u = encerrada_sem_pergunta()
    roteiro([espia({:texto, "Oi! Tudo bem?"})])
    dizer(u, "oi")
    refute instrucao() =~ @g
    refute Iara.perfil(u)["pergunta_aberta"] == true
  end

  test "(A) ligado logo depois da pergunta da primeira campanha: a instrucao do turno seguinte tem a regra g" do
    t = com_pergunta_aberta()
    assert Iara.perfil(t)["pergunta_aberta"] == true
    assert Iara.perfil(t)["campanha_perguntada"] == true

    roteiro([espia({:texto, "Beleza, vamos nessa. Me conta qual imóvel você quer divulgar?"})])
    dizer(t, "bora")
    i = instrucao()
    assert i =~ @g
    assert i =~ "campanha_perguntada=sim"
    assert i =~ "apresentacao encerrada"
  end

  test "(A) o turno que liga o marcador nao o desliga; o corretor responde e ele desliga" do
    t = perguntado()
    roteiro([espia({:chamar, "combinar_horario", %{"hora" => "08:30"}}), {:texto, @fecha}])
    dizer(t, "8h30")
    refute entrada()["instrucao"] =~ @g
    assert Iara.perfil(t)["pergunta_aberta"] == true

    roteiro([espia({:texto, "Fechou, qual imóvel você quer anunciar primeiro?"})])
    dizer(t, "sim")
    assert instrucao() =~ @g
    assert Iara.perfil(t)["pergunta_aberta"] == false
    assert Iara.campanha_perguntada?(t)

    roteiro([espia({:texto, "Tá na mão. Me diz o nome do imóvel?"})])
    dizer(t, "ok")
    refute instrucao() =~ @g
  end

  test "(A) fallback (modelo falha) nao desliga o marcador" do
    t = com_pergunta_aberta()
    roteiro([{:erro, :indisponivel}])
    dizer(t, "sim")
    assert Iara.perfil(t)["pergunta_aberta"] == true

    roteiro([espia({:texto, "Bora então, qual imóvel vamos divulgar?"})])
    dizer(t, "sim")
    assert instrucao() =~ @g
    assert Iara.perfil(t)["pergunta_aberta"] == false
  end

  test "(A) fallback do fechamento (modelo falha duas vezes) tambem liga o marcador" do
    t = perguntado()
    ruim = "Combinado, todo dia as 07:00."
    roteiro([{:chamar, "combinar_horario", %{"hora" => "07:00"}}, {:texto, ruim}, {:texto, ruim}])
    dizer(t, "7h")
    assert Iara.perfil(t)["pergunta_aberta"] == true
  end

  test "(A) tenant legado (campanha_perguntada true, sem marcador): sem a regra g e sem erro" do
    t = perguntado()
    Iara.atualizar(t, %{"horario" => "09:00", "horario_estado" => "definido", "campanha_perguntada" => true})
    refute Map.has_key?(Iara.perfil(t), "pergunta_aberta")
    roteiro([espia({:texto, "Oi! Tudo bem?"})])
    assert ["Oi! Tudo bem?"] = dizer(t, "oi")
    refute instrucao() =~ @g
    assert Iara.campanha_perguntada?(t)
  end

  test "(A) a regra g mantem o sentido (conversa normal, sem repetir pergunta, nao insiste) e a linha ESTADO nao muda" do
    t = com_pergunta_aberta()
    roteiro([espia({:texto, "Beleza, qual imóvel vamos divulgar?"})])
    dizer(t, "bora")
    i = instrucao()
    assert i =~ "`planejar`"
    assert i =~ "sem insistir"
    assert i =~ "APRESENTACAO: se_apresentou=sim; explicou_que_aprende=sim; horario_das_atualizacoes=combinado, 08:30; campanha_perguntada=sim. apresentacao encerrada: nao traga mais nada dela."
  end

  # ---- C: ferramentas oferecidas
  test "(C) apresentacao pendente: oferece `apresentacao`; encerrada: nao oferece; combinar_horario e lembrar sempre" do
    t = tenant_novo()
    roteiro([espia({:texto, "Oi!"})])
    dizer(t, "oi")
    n = nomes(entrada())
    assert "apresentacao" in n and "combinar_horario" in n and "lembrar" in n

    for u <- [encerrada_sem_pergunta(), com_pergunta_aberta()] do
      roteiro([espia({:texto, "Oi! Tudo bem?"})])
      dizer(u, "oi")
      n = nomes(entrada())
      refute "apresentacao" in n
      assert "combinar_horario" in n and "lembrar" in n
      assert ~w(campanhas imoveis saldo_e_teto ficha planejar pausar propor_ativar propor_criar) -- n == []
    end
  end

  test "(C) combinar_horario fora da apresentacao continua funcionando (mudar o horario depois)" do
    t = com_pergunta_aberta()
    roteiro([{:chamar, "combinar_horario", %{"hora" => "06:00"}}, {:texto, "Troquei pra 06:00."}])
    assert ["Troquei pra 06:00."] = dizer(t, "muda pra 6h")
    assert Iara.horario(t) == "06:00"
  end

  test "(C) o contexto de diretrizes declara as ferramentas e os validadores por diretriz" do
    t = tenant_novo()
    ctx = Diretrizes.contexto(t)
    assert "apresentacao" in Diretrizes.oferecidas(ctx)
    assert :sem_gancho in Diretrizes.validadores(ctx) and :apresentacao_nao_dita in Diretrizes.validadores(ctx)
    t = perguntado()
    Iara.assumir_padrao(t)
    ctx = Diretrizes.contexto(t)
    assert Diretrizes.validadores(ctx) == []
    assert "apresentacao" in Diretrizes.restritas()
    refute "apresentacao" in Diretrizes.oferecidas(ctx)
  end

  # ---- B: validadores (mesmas rejeicoes de antes)
  defp rejeita(t, texto_ruim, texto_bom, passos_antes \\ []) do
    roteiro(passos_antes ++ [{:texto, texto_ruim}, {:texto, texto_bom}])
    assert [^texto_bom] = dizer(t, "oi")
    assert sobra() == []
  end

  test "(B) globais rejeitam como antes, com a apresentacao encerrada" do
    t = com_pergunta_aberta()
    # vazio
    rejeita(t, "", "Oi, tudo bem?")
    # numero_inventado
    rejeita(t, "Seu CPL foi 777 hoje.", "Beleza, me diz o que quer ver.")
    # afirma_sem_executar
    rejeita(t, "Pausei a campanha.", "Posso pausar se você quiser.")
    # frase_de_desligar
    rejeita(t, "Infelizmente nao da para desligar isso.", "Posso mudar o horário, qual seria?")
    # encerrou_longo (mudanca de horario depois da pergunta: sem "?")
    roteiro([{:chamar, "combinar_horario", %{"hora" => "06:00"}}, {:texto, "Troquei pra 06:00. Quer montar a campanha agora?"}, {:texto, "Troquei pra 06:00."}])
    assert ["Troquei pra 06:00."] = dizer(t, "muda pra 6h")
    assert sobra() == []
  end

  test "(B) validadores da apresentacao rejeitam como antes (apresentacao_nao_dita, sem_gancho, fechamento longo)" do
    # apresentacao_nao_dita: registrou quem_sou mas o texto nao diz Iara
    t = tenant_novo()
    rejeita(t, "Oi, tudo bem por aí? Qual imóvel você vende hoje?", @quem_sou, [{:chamar, "apresentacao", %{"item" => "quem_sou"}}])
    assert Iara.cobertura(t)["quem_sou"]

    # sem_gancho: entrega um item sem terminar numa pergunta
    u = tenant_novo()
    rejeita(u, "Oi! Eu sou a Iara, da Ataque Total, uma IA.", @quem_sou, [{:chamar, "apresentacao", %{"item" => "quem_sou"}}])

    # fechamento: horario combinado sem a pergunta de primeira campanha
    v = perguntado()
    rejeita(v, "Combinado, todo dia as 08:30.", @fecha, [{:chamar, "combinar_horario", %{"hora" => "08:30"}}])

    # fechamento longo
    w = perguntado()
    longo = "Combinado, todo dia as 08:30. " <> String.duplicate("Depois a gente conversa sobre tudo com calma e vamos ver o que fazer. ", 5) <> "Já quer criar a primeira campanha?"
    rejeita(w, longo, @fecha, [{:chamar, "combinar_horario", %{"hora" => "08:30"}}])
  end

  test "(B) o ctx de casamento e o do inicio do turno: o ultimo item coberto no meio do turno nao desliga o validador" do
    t = perguntado()
    assert Iara.proximo_item(t) == "aguardar_horario"
    # a ferramenta encerra a apresentacao no meio do turno; o validador do fechamento continua valendo
    roteiro([{:chamar, "combinar_horario", %{"hora" => "08:30"}}, {:texto, "Combinado, todo dia as 08:30."}, {:texto, @fecha}])
    assert [@fecha] = dizer(t, "8h30")
    assert sobra() == []
    assert Iara.proximo_item(t) == nil
  end
end
