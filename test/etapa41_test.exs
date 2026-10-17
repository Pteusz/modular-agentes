# Teste geral da etapa 4.1 (base generica de agentes, plataforma SIMULADA, provedor de IA falso). Rodar: MIX_ENV=test mix test
defmodule Etapa41Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano, Aprendizado, Verificador, Executor, Monitor, AbaIA, Gancho}
  alias Trafego.Plataforma.Simulada

  @nome "Nucleo.Automacoes.Trafego"
  @confirma "so pra confirmar se entendi, posso fazer isso mesmo?"
  @tipos ~w(pedido plano confirmacao operacao verificacao resultado custo_tokens)

  @pedido "pedido destino site; url https://corretor.com.br/lancamento; publico casais 30-45 zona sul; " <>
            "criativo foto1.jpg | Apartamento novo na zona sul; diario R$ 50; teto R$ 500; janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15"

  # versoes candidatas do pacote (mesmo encaixe de contrato; a oferta "trafego" muda)
  for {nome, v, cv} <- [{TrafegoV11, "1.1.0", "1.1"}, {TrafegoV20, "2.0.0", "2.0"}] do
    defmodule nome do
      @behaviour Nucleo.Automacao
      @v v
      @cv cv
      def versao, do: @v
      def contrato, do: %{Contrato.contrato() | versao: @cv, oferece: %{"trafego" => @cv}}
      defdelegate referencial, to: Contrato
      defdelegate retencao, to: Contrato
      defdelegate aprovacao, to: Contrato
    end
  end

  setup_all do
    Registro.migrar!()

    for t <- ["estado", "eventos", "vinculos"],
        do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tf%'", [])

    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tf%'", [])
    start_supervised!(Simulada)
    :ok
  end

  defp texto_eventos(t), do: t |> Registro.eventos() |> Enum.map(&Jason.encode!(&1.dados)) |> Enum.join(" ")
  defp tipos(t), do: for(%{tipo: x} <- Registro.eventos(t), x in @tipos, do: x)
  defp evs(t, tipo), do: for(%{tipo: ^tipo} = e <- Registro.eventos(t), do: e.dados)
  defp resp({:ok, r}), do: r

  test "trafego: pedido, plano, confirmacao, execucao pausada, verificador, isolamento, aprendizado, atualizacao" do
    ta = "tf_a#{System.unique_integer([:positive])}"
    tb = "tf_b#{System.unique_integer([:positive])}"
    ca = "act_#{ta}"
    cb = "act_#{tb}"

    # plataforma simulada: o token de A alcanca tambem a conta de B (o isolamento nao pode depender do token)
    Simulada.registrar_conta(ca)
    Simulada.registrar_conta(cb)
    Simulada.registrar_token("SIM-TOKEN-A", [ca, cb])
    Simulada.registrar_token("SIM-TOKEN-B", [cb])

    # contrato Nucleo.Automacao com a versao de contrato MAJOR.MINOR e o mesmo encaixe da Eco
    assert %{versao: "1.2", oferece: %{"trafego" => "1.0", "trafego.painel" => "1.0", "trafego.equipe" => "1.0"}} = Contrato.contrato()
    assert :ok = Nucleo.Automacao.compativel(Contrato)

    for t <- [ta, tb], do: assert({:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{}))
    # credencial invalida (conta fora do alcance do token) e recusada na validacao; id de conta vem do cadastro do tenant
    assert {:error, :credencial_invalida} = Acesso.cadastrar(tb, %{"conta_id" => ca, "token" => "SIM-TOKEN-B"})
    assert {:ok, _} = Acesso.cadastrar(ta, %{"conta_id" => ca, "token" => "SIM-TOKEN-A"})
    assert {:ok, _} = Acesso.cadastrar(tb, %{"conta_id" => cb, "token" => "SIM-TOKEN-B"})

    # ---- pedido incompleto: o plano pede o que falta (exigencia do destino site: url e pixel)
    r = resp(Agente.processar(ta, @pedido))
    assert r =~ "pixel"
    assert %{"status" => "rascunho", "destino" => "site", "resultado" => "evento_pixel", "id" => id1} = Plano.atual(ta)
    refute r =~ "posso fazer"
    assert Simulada.todas() == []

    # ---- complemento: exigencias satisfeitas, o plano aguarda confirmacao (nada executado)
    r = resp(Agente.processar(ta, "pixel 998877"))
    assert r =~ "confirma"
    assert %{"status" => "aguardando_confirmacao", "pixel" => "998877"} = Plano.atual(ta)
    assert Simulada.todas() == []

    # gancho: nenhuma alteracao sem confirmacao (executor e gancho barram o plano nao confirmado)
    assert {:error, :sem_confirmacao} = Executor.executar(ta, id1)
    assert {:bloquear, _} = Gancho.alterar(ta, Plano.ler(ta, id1), {:criar_campanha, %{}})
    assert Simulada.todas() == []

    # ---- confirmacao ambigua: repergunta curta, nada executa
    assert resp(Agente.processar(ta, "hmm, talvez, nao sei ainda")) == @confirma
    assert resp(Agente.processar(ta, "sim mas nao")) == @confirma
    assert %{"status" => "aguardando_confirmacao", "id" => ^id1} = Plano.atual(ta)
    assert Simulada.todas() == []

    # ---- negativa: plano recusado, nada executa, nada fica pendente
    assert resp(Agente.processar(ta, "nao, cancela isso")) =~ "nada foi alterado"
    assert %{"status" => "recusado"} = Plano.ler(ta, id1)
    assert Plano.atual(ta) == nil
    assert Simulada.todas() == []

    # ---- novo pedido completo + confirmacao clara em texto livre: executa PAUSADO
    assert resp(Agente.processar(ta, @pedido <> "; pixel 998877")) =~ "confirma"
    assert %{"id" => id2} = Plano.atual(ta)
    assert id2 != id1
    r = resp(Agente.processar(ta, "Perfeito, pode fazer sim!"))
    assert r =~ "pausada"
    assert [camp] = Simulada.todas()
    assert %{"status" => "PAUSADA", "conta_id" => ^ca} = camp
    assert %{"status" => "verificado", "campanha_id" => cid} = Plano.ler(ta, id2)
    assert cid == camp["id"]
    assert Plano.atual(ta) == nil
    # conjunto e anuncio vieram junto, tambem pausados
    assert [%{"anuncios" => [%{"criativo" => %{"midia" => "foto1.jpg"}}]}] = camp["conjuntos"]

    # ---- eventos do tenant no formato aprovado
    for t <- @tipos, do: assert(t in tipos(ta), "falta evento #{t}")
    for e <- Registro.eventos(ta), e.tipo in @tipos do
      assert %{"plano_id" => _, "papel" => papel, "ref" => _} = e.dados
      assert papel in ~w(planejador executor verificador monitor)
    end

    assert [%{"modelo" => m, "tokens_in" => ti, "tokens_out" => to, "custo_brl" => c} | _] = evs(ta, "custo_tokens")
    assert is_binary(m) and is_integer(ti) and is_integer(to) and is_number(c)
    assert Enum.all?(evs(ta, "verificacao"), &(&1["ref"] != nil))

    # a conversa do corretor consigo mesmo nunca vira evento, e segredo nunca aparece
    todo = texto_eventos(ta)
    for trecho <- ["casais", "talvez", "Perfeito", "cancela", "Apartamento novo", "SIM-TOKEN"], do: refute(todo =~ trecho)

    # ---- verificador acusa divergencia injetada; vira registro de aprendizado com a regra nomeada
    assert Verificador.verificar(ta, id2) == :ok
    Simulada.injetar(cid, %{"orcamento_diario" => 999_900})
    assert {:divergente, [:orcamento_diario_igual]} = Verificador.verificar(ta, id2)
    assert %{"status" => "divergente"} = Plano.ler(ta, id2)
    assert [%{"violadas" => ["orcamento_diario_igual"]} | _] = evs(ta, "verificacao") |> Enum.reverse()
    assert [%{"regra_violada" => "orcamento_diario_igual", "acao" => "criar_campanha"} | _] = Aprendizado.historico(ta) |> Enum.reverse()

    # ---- erro vira registro e muda a proposta seguinte (estado lido de volta): situacao parecida traz atencao
    assert resp(Agente.processar(ta, @pedido <> "; pixel 998877")) =~ "orcamento_diario_igual"
    assert %{"status" => "aguardando_confirmacao", "atencao" => ["orcamento_diario_igual"], "id" => id3} = Plano.atual(ta)
    sim = Aprendizado.parecidos(ta, %{"destino" => "site", "publico" => "casais 30-45 zona sul", "orcamento_diario" => 5000})
    assert "orcamento_diario_igual" in Enum.map(sim, & &1["regra_violada"])
    # situacao de outro destino nao traz a atencao
    assert [] = Aprendizado.parecidos(ta, %{"destino" => "whatsapp", "publico" => "outro", "orcamento_diario" => 100})

    # ---- dois tenants, contas diferentes, sem se enxergarem
    assert resp(Agente.processar(tb, @pedido <> "; pixel 112233; conta " <> ca)) =~ "confirma"
    assert %{"atencao" => [], "id" => idb} = Plano.atual(tb)
    # o provedor de IA tentou impor a conta de A: o id de conta ignorado, a conta e a do registro do tenant
    refute Map.has_key?(Plano.atual(tb), "conta_id")
    assert resp(Agente.processar(tb, "claro, confirmo")) =~ "pausada"
    assert %{"campanha_id" => cid_b} = Plano.ler(tb, idb)
    assert [%{"conta_id" => ^cb}] = Simulada.todas() |> Enum.filter(&(&1["id"] == cid_b))
    assert Simulada.todas() |> Enum.count(&(&1["conta_id"] == ca)) == 1

    assert {:ok, [%{"id" => ^cid}]} = Acesso.chamar(ta, :listar_campanhas, [])
    assert {:ok, [%{"id" => ^cid_b}]} = Acesso.chamar(tb, :listar_campanhas, [])
    assert {:error, :nao_encontrada} = Acesso.chamar(tb, :ler_campanha, [cid])
    assert {:error, :nao_encontrada} = Acesso.chamar(tb, :pausar_campanha, [cid])

    # ---- agente barrado ao acessar conta de outro tenant (mesmo com token que alcanca)
    assert {:error, :conta_barrada} = Acesso.chamar(tb, :listar_campanhas, [], conta: ca)
    assert {:error, :conta_barrada} = Acesso.chamar(tb, :criar_campanha, [%{}], conta: ca)
    assert Simulada.todas() |> Enum.count(&(&1["conta_id"] == ca)) == 1
    assert Enum.any?(evs(tb, "operacao"), &(&1["erro"] == "conta_barrada"))

    # ---- nenhuma campanha ativa: a plataforma nao aceita ativar nesta fase
    assert {:error, :ativacao_fora_da_fase} = Acesso.chamar(ta, :editar_campanha, [cid, %{"status" => "ATIVA"}])
    assert Simulada.todas() |> Enum.all?(&(&1["status"] == "PAUSADA"))

    # ---- aba IA e projecao dos eventos; monitor (esqueleto) e aprendizado so da estrutura
    aba = AbaIA.projetar(ta)
    assert %{planejador: %{fez: [_ | _]}, executor: %{fez: [_ | _]}, verificador: %{erros: [_ | _]}} = aba
    assert Monitor.avaliar(ta, id2, nil) == :dados_insuficientes
    assert [%{regra: "orcamento_diario_igual", ocorrencias: 1}] = Aprendizado.candidatos_catalogo(ta)

    # ---- atualizar a versao do pacote trafego preserva o estado e o plano pendente continua valido
    antes = for t <- [ta, tb], do: {t, Plano.listar(t), Aprendizado.historico(t), Registro.ler(t, "trafego_conta"), Registro.ler(t, "trafego_atual")}
    assert {:ok, tenants} = Vincular.atualizar(@nome, TrafegoV11, %{})
    assert ta in tenants and tb in tenants
    assert %{versao: "1.1.0"} = Registro.vinculo(ta, @nome)
    depois = for t <- [ta, tb], do: {t, Plano.listar(t), Aprendizado.historico(t), Registro.ler(t, "trafego_conta"), Registro.ler(t, "trafego_atual")}
    assert antes == depois

    # versao incompativel (MAJOR 2) e recusada; versao e estado ficam
    assert {:error, {:incompativel, _}} = Vincular.atualizar(@nome, TrafegoV20, %{})
    assert %{versao: "1.1.0"} = Registro.vinculo(ta, @nome)
    assert depois == (for t <- [ta, tb], do: {t, Plano.listar(t), Aprendizado.historico(t), Registro.ler(t, "trafego_conta"), Registro.ler(t, "trafego_atual")})

    # o plano pendente de A (id3) segue de onde parou, com a versao nova
    assert %{"id" => ^id3, "status" => "aguardando_confirmacao"} = Plano.atual(ta)
    assert resp(Agente.processar(ta, "sim, pode fazer")) =~ "pausada"
    assert %{"status" => status} = Plano.ler(ta, id3)
    assert status in ["verificado", "divergente"]
  end
end
