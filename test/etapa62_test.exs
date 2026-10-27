# Teste da etapa 6.2 (trafego 1.15.0): a Iara pergunta o TIPO de campanha (destino) antes de todo o resto do plano.
# Rodar: MIX_ENV=test mix test test/etapa62_test.exs
# REGRA: tenants tp62_* (so os proprios dados). IA pelo provedor Falso; nenhuma chamada real.
defmodule Etapa62Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Banco}
  alias Trafego.Plataforma.Simulada

  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar provedor_ia)a
  @completo "pedido objetivo vender; imovel Torre Sul; destino whatsapp; pixel 998877; publico casais zona sul; diario R$ 50; teto R$ 500; " <>
              "janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15; sem_numero sim"

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
    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp62\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp62\_%'", [])
  end

  defp tenant_pronto do
    t = "tp62_#{System.unique_integer([:positive])}"
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    t
  end

  defp dizer(t, texto), do: t |> Agente.processar_mensagens(texto) |> elem(1) |> List.wrap()
  defp junto(l), do: Enum.join(l, "\n")
  defp pergunta_tipo?(l), do: junto(l) =~ "tipo de campanha"

  defp limpo?(l), do: not (junto(l) =~ ~r/[—–]|^\s*[-*•] /m)

  # ------------------------------------------------------------------------------------------------------------------
  test "ponta a ponta: so o imovel -> pergunta do tipo; 'whatsapp' -> lista com o que falta, sem repetir o tipo" do
    t = tenant_pronto()
    l = dizer(t, "pedido imovel Torre Sul")
    assert [tipo] = l
    assert tipo =~ "formulário" and tipo =~ "WhatsApp" and tipo =~ "site"
    refute tipo =~ "Pra montar o plano"
    refute tipo =~ ~r/^\d\./m
    assert limpo?(l)

    l = dizer(t, "pedido destino whatsapp")
    refute pergunta_tipo?(l)
    txt = junto(l)
    assert txt =~ "Pra montar o plano me conta:"
    assert txt =~ "quanto quer gastar por dia" and txt =~ "teto total" and txt =~ "número do WhatsApp"
    refute txt =~ "qual imóvel", "o imovel ja foi dito"
  end

  test "sem imovel dito: depois do tipo a lista pede imovel, verba e teto" do
    t = tenant_pronto()
    assert pergunta_tipo?(dizer(t, "pedido objetivo vender"))
    txt = t |> dizer("pedido destino whatsapp") |> junto()
    assert txt =~ "Pra montar o plano me conta:"
    assert txt =~ "qual imóvel" and txt =~ "quanto quer gastar por dia" and txt =~ "teto total"
    refute txt =~ "tipo de campanha"
  end

  test "tudo de uma vez (com o destino): nao pergunta o tipo e monta o plano" do
    t = tenant_pronto()
    l = dizer(t, @completo)
    assert hd(l) =~ "Montei o plano"
    refute pergunta_tipo?(l)
  end

  test "site: pede o link e o pixel (e o que falta), nunca o tipo de novo" do
    t = tenant_pronto()
    assert pergunta_tipo?(dizer(t, "pedido imovel Torre Sul"))
    txt = t |> dizer("pedido destino site") |> junto()
    assert txt =~ "link do site" and txt =~ "pixel"
    refute txt =~ "tipo de campanha"
  end

  test "resposta ambigua nao decide: reexplica em uma frase, sem sugerir, e pergunta de novo" do
    t = tenant_pronto()
    assert pergunta_tipo?(dizer(t, "pedido imovel Torre Sul"))
    l = dizer(t, "pedido tanto faz")
    assert [re] = l
    assert re =~ "formulário" and re =~ "WhatsApp" and re =~ "site" and re =~ "Qual dos três"
    refute re =~ ~r/recomendo|sugiro|melhor opcao|indico/i
    refute re =~ "Pra montar o plano"
    assert limpo?(l)

    # decidiu: segue a lista
    assert dizer(t, "pedido destino formulario") |> junto() =~ "o id do formulário"
  end

  test "destino ja dito antes (rascunho ou primeira fala): nao pergunta o tipo" do
    t = tenant_pronto()
    txt = t |> dizer("pedido destino site; imovel Torre Sul") |> junto()
    refute txt =~ "tipo de campanha"
    assert txt =~ "Pra montar o plano me conta:" and txt =~ "link do site" and txt =~ "pixel"
    # mensagem seguinte tambem nao pergunta
    refute t |> dizer("pedido diario R$ 50") |> pergunta_tipo?()
  end

  test "versao do pacote" do
    assert to_string(Application.spec(:trafego, :vsn)) == "1.16.1"
  end
end
