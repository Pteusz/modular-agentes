# Teste das diretrizes da Iara, passo 1 (trafego 1.12.2): a politica vira lista de diretrizes (condicao em codigo + acao); cada turno injeta
# so as que casam (Trafego.Diretrizes). Nenhuma chamada nova ao modelo. Rodar: MIX_ENV=test mix test test/etapa57_test.exs
# REGRA: tenants tp57_* (so os proprios dados). IA pelo provedor Falso com ROTEIRO (:roteiro_ia). NENHUMA chamada real a OpenAI/Meta.
defmodule Etapa57Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Iara, Banco}
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
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp57\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp57\\_%'", [])
  end

  # corretor NOVO: sem perfil nenhum (primeiro contato de verdade)
  defp tenant_novo do
    t = "tp57_#{System.unique_integer([:positive])}"
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
  defp dizer(t, texto), do: t |> Agente.processar_mensagens(texto) |> then(fn {:ok, r} -> List.wrap(r) end)

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
  defp tem_regras_e_tom(i) do
    for n <- 1..8, do: assert(i =~ "\n#{n}. ", "falta a regra #{n}")
    assert i =~ "JEITO DE ESCREVER"
    assert i =~ "EXEMPLOS DE TOM"
  end

  test "(a) tenant novo (apresentacao pendente): bloco APRESENTACAO, regras f e g, regras 1 a 8 e exemplos de tom" do
    t = tenant_novo()
    roteiro([espia({:texto, "Oi!"})])
    dizer(t, "oi")
    i = instrucao()
    assert i =~ "APRESENTACAO (so enquanto"
    assert i =~ "Horario combinado"
    assert i =~ "Depois dessa pergunta"
    tem_regras_e_tom(i)
  end

  test "(b) apresentacao encerrada: sem bloco APRESENTACAO nem regra f; mantem g, regras 1 a 8 e exemplos de tom" do
    t = perguntado()
    Iara.definir_horario(t, "09:00")
    roteiro([espia({:texto, "Oi!"})])
    dizer(t, "oi")
    i = instrucao()
    refute i =~ "APRESENTACAO (so enquanto"
    refute i =~ "Horario combinado"
    assert i =~ "Depois dessa pergunta"
    assert i =~ "apresentacao encerrada: nao traga mais nada dela"
    tem_regras_e_tom(i)
  end

  test "(c) turno em que o corretor responde o horario: a instrucao do inicio do turno ja tem a regra f" do
    t = perguntado()
    roteiro([espia({:chamar, "combinar_horario", %{"hora" => "08:30"}}), {:texto, "Combinado, todo dia as 08:30. Você já está pronto pra criar a sua primeira campanha comigo?"}])
    dizer(t, "pode ser 8h30")
    i = instrucao()
    assert i =~ "Horario combinado"
    assert i =~ "campanha_perguntada=nao"
    assert Iara.encerrada?(t)
  end

  test "(d) plano em andamento com apresentacao pendente: o bloco continua (a regra d manda atender o pedido) e o ESTADO segue" do
    t = tenant_novo()
    Iara.cobrir(t, "quem_sou")
    roteiro([espia({:chamar, "planejar", %{"pedido" => "pedido objetivo vender; imovel Torre Sul"}}), {:texto, "Ok."}])
    dizer(t, "quero criar uma campanha do imovel Torre Sul")
    instrucao()

    roteiro([espia({:texto, "Seguimos."})])
    dizer(t, "e ai")
    i = instrucao()
    assert i =~ "APRESENTACAO (so enquanto"
    assert i =~ "Horario combinado"
    assert i =~ "Plano em andamento"
    assert i =~ "APRESENTACAO: se_apresentou=sim"
    assert i =~ "NAO traga apresentacao" or i =~ "proximo item"
  end
end
