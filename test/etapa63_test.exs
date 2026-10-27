# Teste da etapa 6.3 (trafego 1.16.0): a Iara confere o saldo da conta Meta (em DIAS DE VERBA), avisa quando baixo e manda o link de recarga.
# Rodar: MIX_ENV=test mix test test/etapa63_test.exs
# REGRA: tenants tp63_* (so os proprios dados). Plataforma Simulada, nenhuma chamada real, nenhum aviso real.
defmodule Etapa63Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Acesso, Banco, Ferramentas, Monitor, Plano, Saldo}
  alias Trafego.Plataforma.{Meta, Simulada}

  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar provedor_ia)a

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
    pid = self()
    Application.put_env(:trafego, :notificar, fn t, x -> send(pid, {:aviso, t, x}) end)
    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp63\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp63\_%'", [])
  end

  # tenant com conta Simulada; `verba` em centavos/dia (0 = sem campanha ativa); `saldo` = mapa da plataforma ou nil
  defp tenant_pronto(verba, saldo) do
    t = "tp63_#{System.unique_integer([:positive])}"
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    if saldo, do: Simulada.registrar_saldo(conta, saldo)
    if verba > 0, do: plano_ativo(t, verba)
    t
  end

  defp plano_ativo(t, verba) do
    Registro.gravar(t, "trafego_seq", %{"n" => 1})
    Plano.salvar(t, %{"id" => "p1", "status" => "ativa", "campanha_id" => "camp_inexistente", "orcamento_diario" => verba, "teto_total" => verba * 30, "meta" => %{"resultados" => 10, "custo_max" => 1500}})
  end

  defp pre(centavos), do: %{"tipo" => "pre_pago", "saldo" => centavos}
  defp avisos(acc \\ []), do: (receive do {:aviso, t, x} -> avisos([{t, x} | acc]) after 0 -> Enum.reverse(acc) end)
  defp so_saldo(l), do: for({_, x} <- l, x =~ ~r/saldo/i, do: x)
  defp limpo?(t), do: not (t =~ ~r/[—–]|^\s*[-*•] |^\s*\d+[.)] /m)
  defp ferr(t, nome), do: Ferramentas.executar(t, nome, %{}, %{})

  # ------------------------------------------------------------------------------------------------------------------
  test "parse_centavos: o texto de exibicao da Meta vira centavos (milhar, nbsp, sem saldo)" do
    assert Saldo.parse_centavos("Saldo disponível (R$6,99 BRL)") == 699
    assert Saldo.parse_centavos("Saldo disponível (R$ 1.234,56 BRL)") == 123_456
    assert Saldo.parse_centavos("Saldo disponível (R$0,00 BRL)") == 0
    assert Saldo.parse_centavos("Visa ****1234") == nil
    assert Saldo.parse_centavos(nil) == nil
  end

  test "dias de verba: saldo / verba diaria, uma casa para baixo; sem verba nao ha conta" do
    assert Saldo.dias(699, 5000) == 0.1
    assert Saldo.dias(7000, 5000) == 1.4
    assert Saldo.dias(15_000, 5000) == 3.0
    assert Saldo.dias(0, 5000) == 0.0
    assert Saldo.dias(699, 0) == nil
    assert Saldo.dias(nil, 5000) == nil
  end

  test "faixas: menos de 1 dia = critico, menos de 3 = baixo, a partir de 3 = ok" do
    assert Saldo.faixa(0.0) == :critico
    assert Saldo.faixa(0.9) == :critico
    assert Saldo.faixa(1.0) == :baixo
    assert Saldo.faixa(2.9) == :baixo
    assert Saldo.faixa(3.0) == :ok
    assert Saldo.faixa(nil) == :ok
  end

  test "Meta: a resposta real (pre-paga, balance 0) vira saldo pelo funding_source_details; cartao vira pos_pago" do
    real = %{"balance" => "0", "currency" => "BRL", "is_prepay_account" => true, "funding_source_details" => %{"id" => "1", "type" => 20, "display_string" => "Saldo disponível (R$6,99 BRL)"}}
    assert Meta.saldo_da_resposta(real) == {:ok, %{"tipo" => "pre_pago", "saldo" => 699}}
    assert {:ok, %{"tipo" => "pre_pago", "saldo" => nil}} = Meta.saldo_da_resposta(%{real | "funding_source_details" => %{"display_string" => "algo novo"}})
    assert Meta.saldo_da_resposta(%{"is_prepay_account" => false, "balance" => "1200", "currency" => "BRL"}) == {:ok, %{"tipo" => "pos_pago", "saldo" => nil}}
    assert {:error, _} = Meta.saldo_da_resposta(%{"currency" => "BRL"})
    assert {:ok, %{"saldo" => nil}} = Meta.saldo_da_resposta(%{real | "currency" => "USD"})
  end

  test "link de recarga: candidato com o id da conta (sem act_), fallback do Billing Hub com instrucao, ambos trocaveis" do
    assert Saldo.link_recarga("act_1627390175488690", :asset_id) == "https://business.facebook.com/billing_hub/payment_settings?asset_id=1627390175488690"
    assert Saldo.link_recarga("1627390175488690", :asset_id) == "https://business.facebook.com/billing_hub/payment_settings?asset_id=1627390175488690"
    assert Saldo.link_recarga("act_1", :billing_hub) == "https://business.facebook.com/billing_hub/"
    assert Saldo.recarga_texto("act_9", :asset_id) == "https://business.facebook.com/billing_hub/payment_settings?asset_id=9"
    fb = Saldo.recarga_texto("act_9", :billing_hub)
    assert fb =~ "billing_hub/" and fb =~ "9" and fb =~ "Adicionar fundos"
    assert limpo?(fb)
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "saldo_meta: pre-paga em reais, verba somada e dias de verba, com o link da conta certa" do
    t = tenant_pronto(5000, pre(7000))
    {:ok, r, _} = ferr(t, "saldo_meta")
    assert r["tipo"] == "pre_pago" and r["saldo"] == "R$ 70,00" and r["verba_diaria_total"] == "R$ 50,00"
    assert r["dias_de_verba"] == "1,4"
    assert r["link_recarga"] =~ "asset_id=" <> String.replace_prefix("act_" <> t, "act_", "")
    assert r["resumo"] =~ "R$ 70,00" and r["resumo"] =~ "1,4 dias" and r["resumo"] =~ r["link_recarga"]
    assert limpo?(r["resumo"])
  end

  test "saldo_meta: saldo folgado nao empurra link; sem campanha ativa so informa o valor" do
    t = tenant_pronto(5000, pre(100_000))
    {:ok, r, _} = ferr(t, "saldo_meta")
    assert r["dias_de_verba"] == "20" and r["faixa"] == "ok"
    refute r["resumo"] =~ "http"

    t = tenant_pronto(0, pre(7000))
    {:ok, r, _} = ferr(t, "saldo_meta")
    assert r["dias_de_verba"] == nil and r["resumo"] =~ "R$ 70,00" and r["resumo"] =~ "nenhuma campanha ativa"
  end

  test "saldo_meta: conta pos-paga (cartao) diz que nao tem saldo pre-pago e nao fala de recarga" do
    t = tenant_pronto(5000, %{"tipo" => "pos_pago", "saldo" => nil})
    {:ok, r, _} = ferr(t, "saldo_meta")
    assert r["tipo"] == "pos_pago" and r["resumo"] =~ "cartão" and r["resumo"] =~ "não tem saldo pré-pago"
    refute Map.has_key?(r, "link_recarga")
    assert limpo?(r["resumo"])
  end

  test "saldo_meta: leitura indisponivel nao inventa numero (nem derruba a conversa)" do
    t = tenant_pronto(5000, nil)
    assert {:ok, r, _} = ferr(t, "saldo_meta")
    assert r["saldo"] == "indisponivel" and r["resumo"] =~ "Não consegui ler"
    refute r["resumo"] =~ ~r/R\$ \d/

    t = tenant_pronto(5000, pre(nil))
    assert {:ok, %{"saldo" => "indisponivel"}, _} = ferr(t, "saldo_meta")
  end

  test "catalogo: saldo_meta existe e e de leitura; saldo_e_teto aponta para ela e continua sem numero da Meta" do
    assert "saldo_meta" in Ferramentas.nomes()
    refute Ferramentas.acao?("saldo_meta")
    d = Ferramentas.definicoes() |> Enum.find(&(&1["nome"] == "saldo_meta"))
    assert d["descricao"] =~ "dias de verba"
    t = tenant_pronto(5000, pre(7000))
    {:ok, r, _} = ferr(t, "saldo_e_teto")
    assert r["saldo_da_conta_meta"] =~ "saldo_meta" and r["saldo_da_conta_meta"] =~ "indisponivel"
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "aviso: entra em 'baixo' avisa UMA vez, nao repete nas rodadas seguintes; piora para 'critico' avisa de novo" do
    t = tenant_pronto(5000, pre(7000))
    assert :avisou = Saldo.avisar(t)
    assert [{^t, msg}] = avisos()
    assert msg =~ "R$ 70,00" and msg =~ "1,4 dias" and msg =~ "asset_id=" and limpo?(msg)

    assert :quieto = Saldo.avisar(t)
    assert :quieto = Saldo.avisar(t)
    assert avisos() == []

    Simulada.registrar_saldo("act_" <> t, pre(300))
    assert :avisou = Saldo.avisar(t)
    assert [{^t, crit}] = avisos()
    assert crit =~ "menos de um dia" and crit =~ "R$ 3,00" and crit =~ "asset_id=" and limpo?(crit)
    assert :quieto = Saldo.avisar(t)

    # melhora para 'baixo' sem passar de 3 dias: continua o mesmo episodio, sem novo aviso
    Simulada.registrar_saldo("act_" <> t, pre(7000))
    assert :quieto = Saldo.avisar(t)
    assert avisos() == []
  end

  test "aviso: recarga (>= 3 dias) rearma; baixar de novo avisa" do
    t = tenant_pronto(5000, pre(7000))
    assert :avisou = Saldo.avisar(t)
    Simulada.registrar_saldo("act_" <> t, pre(30_000))
    assert :quieto = Saldo.avisar(t)
    Simulada.registrar_saldo("act_" <> t, pre(6000))
    assert :avisou = Saldo.avisar(t)
    assert length(avisos()) == 2
  end

  test "aviso: nada para avisar sem verba ativa, em conta pos-paga, com saldo indisponivel ou folgado" do
    assert :quieto = Saldo.avisar(tenant_pronto(0, pre(100)))
    assert :quieto = Saldo.avisar(tenant_pronto(5000, %{"tipo" => "pos_pago", "saldo" => nil}))
    assert :quieto = Saldo.avisar(tenant_pronto(5000, nil))
    assert :quieto = Saldo.avisar(tenant_pronto(5000, pre(nil)))
    assert :quieto = Saldo.avisar(tenant_pronto(5000, pre(500_000)))
    assert avisos() == []
  end

  test "aviso: falha ao ler o saldo nao derruba nada" do
    t = tenant_pronto(5000, pre(7000))
    Simulada.falhar(:ler_saldo, :rede)
    assert :quieto = Saldo.avisar(t)
    Simulada.falhar(:ler_saldo, nil)
    assert :avisou = Saldo.avisar(t)
  end

  test "Monitor: a rodada avisa o saldo baixo uma vez so (e nao muda o retorno da rodada)" do
    t = tenant_pronto(5000, pre(7000))
    assert [{"p1", _}] = Monitor.rodar(t)
    assert [_] = so_saldo(avisos())
    assert [{"p1", _}] = Monitor.rodar(t)
    assert so_saldo(avisos()) == []
  end
end
