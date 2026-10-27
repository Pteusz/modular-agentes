# Teste da etapa 6.3.1 (trafego 1.16.1): pergunta fixa da ficha sai em UMA mensagem so, sem id interno (p1) e com acentos.
# Rodar: MIX_ENV=test mix test test/etapa631_test.exs
# REGRA: tenants tp631_* (so os proprios dados). IA pelo provedor Falso com ROTEIRO (:roteiro_ia). NENHUMA chamada real.
defmodule Etapa631Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano, Iara, Banco}
  alias Trafego.Plataforma.Simulada

  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar provedor_ia numero_cadastrado roteiro_ia)a

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
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp631\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp631\_%'", [])
  end

  defp tenant_pronto do
    t = "tp631_#{System.unique_integer([:positive])}"
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Nucleo.Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    Iara.atualizar(t, %{"apresentada" => true, "horario_estado" => "definido", "horario" => "09:00"})
    t
  end

  defp roteiro(passos), do: Application.put_env(:trafego, :roteiro_ia, passos)
  defp dizer(t, texto), do: t |> Agente.processar_mensagens(texto) |> then(fn {:ok, r} -> List.wrap(r) end)

  test "'Vamos nessa' com pergunta aberta + planejar sem destino: UMA mensagem, a pergunta fixa acentuada, sem p1" do
    t = tenant_pronto()
    Iara.marcar_campanha_perguntada(t)
    roteiro([
      {:chamar, "planejar", %{"pedido" => "pedido objetivo vender"}},
      {:texto, "Beleza! Pra campanha p1, você prefere receber contatos por formulário, WhatsApp ou site?"}
    ])

    assert [msg] = dizer(t, "Vamos nessa")
    assert msg == "Que tipo de campanha você quer fazer: com formulário, levando pro WhatsApp ou levando pro site?"
    refute msg =~ "p1"
    assert Plano.atual(t)["id"] == "p1"
  end

  test "lista 'Pra montar o plano me conta:' tambem sai sozinha, sem o texto livre do modelo" do
    t = tenant_pronto()
    roteiro([
      {:chamar, "planejar", %{"pedido" => "pedido objetivo vender; imovel Torre Sul; destino whatsapp"}},
      {:texto, "Show! Pra montar a campanha p1 preciso de umas coisas."}
    ])

    assert [msg] = dizer(t, "quero anunciar a Torre Sul no whatsapp")
    assert msg =~ "Pra montar o plano me conta:" and msg =~ "1. "
    assert msg =~ "Pode mandar tudo junto, por texto ou áudio."
    refute msg =~ "Show" or msg =~ "p1"
  end

  test "texto livre do modelo que cita 'campanha p1' perde o id interno" do
    t = tenant_pronto()
    {:ok, _} = Acesso.chamar(t, :criar_campanha, [%{"nome" => "Apartamento Centro", "objetivo" => "vender", "destino" => "site", "orcamento_diario" => 5000, "teto_total" => 50_000, "janela" => %{"inicio" => "2026-11-01", "fim" => "2026-11-30"}}])
    roteiro([{:chamar, "campanhas", %{"ref" => nil, "dias" => nil}}, {:texto, "Você tem 1 campanha: c1. A campanha p1 está pausada."}])
    assert [msg] = dizer(t, "como estão minhas campanhas?")
    assert msg =~ "A campanha está pausada."
    refute msg =~ "p1"
  end

  test "retomada do plano pendente nao mostra o id" do
    t = tenant_pronto()
    assert [_] = dizer(t, "pedido objetivo vender; imovel Torre Sul; destino whatsapp; pixel 998877; publico casais zona sul; diario R$ 50; teto R$ 500; janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15; sem_numero sim") |> Enum.take(1)
    roteiro([{:texto, "Em geral leva uns dias."}])
    l = t |> dizer("isso demora?") |> Enum.join("\n")
    assert l =~ "Sobre o plano: você confirma?"
    refute l =~ "p1"
  end
end
