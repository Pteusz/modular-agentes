# Teste da correcao 5.2.2 (verificacao sem falso divergente, conversa sem codigos internos, sem reenvio do plano apos a foto,
# ambiguidade numa fala so). Rodar: MIX_ENV=test mix test test/etapa522_test.exs
# REGRA: tenants tp522_* (so os proprios dados). IA pelo provedor Falso; nenhuma chamada real.
defmodule Etapa522Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal, Verificador}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano, Iara, Banco}
  alias Trafego.Plataforma.{Simulada, Meta}

  @base "pedido objetivo vender; imovel Torre Sul; destino whatsapp; pixel 998877; publico casais zona sul; diario R$ 50; teto R$ 500; " <>
          "janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15; sem_numero sim"
  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar baixar_midia midia_dir provedor_ia feed_fonte)a
  @proibidas ~w(conta_igual criativo_igual destino_igual orcamento_diario_igual teto_igual janela_igual publico_igual status_pausada)

  setup_all do
    Registro.migrar!()
    Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}
    midia = Path.join(System.tmp_dir!(), "midia_tp522_#{System.unique_integer([:positive])}")
    Application.put_env(:trafego, :midia_dir, midia)

    on_exit(fn ->
      limpar()
      File.rm_rf(midia)
      for {k, v} <- salvo, do: (case v do {:ok, x} -> Application.put_env(:trafego, k, x); :error -> Application.delete_env(:trafego, k) end)
    end)

    :ok
  end

  setup do
    Application.put_env(:trafego, :teto_ia_brl, 1000.0)
    Application.put_env(:trafego, :cotacao_usd_brl, 5.0)
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.Falso)
    Application.put_env(:trafego, :notificar, fn _, _ -> :ok end)
    Application.put_env(:trafego, :baixar_midia, fn %{content: %{url: bytes}} -> {:ok, bytes} end)
    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp522\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp522\_%'", [])
  end

  defp vincular(t) do
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    conta
  end

  defp tenant_pronto, do: (t = "tp522_#{System.unique_integer([:positive])}"; vincular(t); t)
  defp msgs({:ok, r}), do: List.wrap(r)
  defp bruto(t, texto), do: msgs(Agente.processar_mensagens(t, texto))
  defp sem_abertura(l), do: Enum.reject(l, &(&1 in [Iara.pergunta_horario() | Iara.apresentacao_mensagens()]))
  defp dizer(t, texto), do: t |> bruto(texto) |> sem_abertura()
  defp png(w, h), do: <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, 8, 2, 0, 0, 0, 0::32>> <> :binary.copy(<<0>>, 3000)
  defp foto(t), do: t |> Agente.receber_midia_mensagens(midia(png(1080, 1080))) |> msgs() |> sem_abertura()

  defp midia(conteudo) do
    media = struct(Amarula.Content.Media, kind: :image, mimetype: "image/png", url: conteudo)
    %Amarula.Msg{channel: :teste, type: :media, raw: nil, content: media}
  end

  defp sem_codigos(textos),
    do: for(m <- textos, c <- @proibidas ++ ["situacao parecida"], String.contains?(m, c), do: {c, m})

  # ------------------------------------------------------------------------------------------------------------------
  test "conta_igual: act_ dos dois lados e normalizado" do
    regra = Enum.find(Contrato.referencial().regras, &(&1.nome == :conta_igual))
    ok = fn camp, conta -> regra.ok?.(%{campanha: %{"conta_id" => camp}, conta_id: conta, plano: %{}}) end
    assert ok.("act_123", "123")
    assert ok.("act_123", "act_123")
    assert ok.("123", "act_123")
    refute ok.("act_123", "999")
    assert Verificador.violadas(%{tipo: :decidivel, regras: [regra]}, %{campanha: %{"conta_id" => "act_55"}, conta_id: "55", plano: %{}}) == []
  end

  test "criativo: a Meta devolve o nome com sufixo de data e hex; ele sai na normalizacao" do
    assert Meta.nome_criativo("foto-torre-sul 2026-10-19-3fa9c01b") == "foto-torre-sul"
    assert Meta.nome_criativo("foto torre sul 2026-10-19-3fa9c01b") == "foto torre sul"
    assert Meta.nome_criativo("foto-torre-sul") == "foto-torre-sul"
    assert Meta.nome_criativo("foto 2026-10-19") == "foto 2026-10-19"
    assert Meta.nome_criativo(nil) == nil
  end

  test "depois da foto, antes de confirmar: nao reenvia o plano, pede so a confirmacao" do
    t = tenant_pronto()
    assert Enum.any?(dizer(t, @base), &(&1 =~ "Montei o plano"))
    assert %{"status" => "aguardando_confirmacao"} = Plano.atual(t)

    # foto antes de confirmar
    l = foto(t)
    assert [curta] = l
    assert curta =~ "foto" and curta =~ "Confirma"
    refute curta =~ "Montei o plano"
    refute curta =~ "R$ 50"
    assert String.length(curta) < 120
    assert %{"status" => "aguardando_confirmacao"} = Plano.atual(t)

    # confirma: cria pausada e diz o id, sem nomes de regras
    assert [fim] = dizer(t, "pode fazer sim")
    assert fim =~ "pausada" and fim =~ "nada foi ativado" and fim =~ "camp_"
    assert sem_codigos([fim]) == []
    assert [%{"status" => "PAUSADA"}] = Enum.filter(Simulada.todas(), &(&1["conta_id"] == "act_#{t}"))
  end

  test "fluxo normal (confirma, depois a foto): fala final sem codigos internos" do
    t = tenant_pronto()
    dizer(t, @base)
    assert [pede] = dizer(t, "pode fazer sim")
    assert pede =~ "foto ou o video"
    assert [fim] = foto(t)
    assert fim =~ "pausada" and fim =~ "nada foi ativado"
    assert sem_codigos([fim]) == []
  end

  test "divergencia vira portugues claro, nunca o nome da regra" do
    for r <- ~w(status_pausada conta_igual destino_igual orcamento_diario_igual teto_igual janela_igual publico_igual criativo_igual regra_nova) do
      txt = Agente.divergencia(r)
      assert is_binary(txt) and txt != ""
      assert sem_codigos([txt]) == [], "#{r} => #{txt}"
      refute txt =~ "_"
    end
  end

  test "aviso de aprendizado nao cita codigo: mesmo com divergencia registrada antes" do
    t = tenant_pronto()
    plano = %{"id" => "p0", "objetivo" => "vender", "destino" => "whatsapp"}
    Trafego.Aprendizado.registrar(t, plano, "criar_campanha", "divergente", "conta_igual")
    l = dizer(t, @base)
    assert sem_codigos(l) == [], inspect(l)
  end

  test "ambiguidade: uma fala so, curta, sem cabecalho repetido" do
    t = tenant_pronto()
    assert [amb] = dizer(t, "pedido objetivo vender; imovel Torre Sul; ambiguidade R$ 500 pode ser por dia ou no total")
    assert amb =~ "Fiquei na duvida" and amb =~ "Me confirma?"
    assert length(String.split(amb, "Fiquei na duvida")) == 2
    refute amb =~ "Pra montar o plano"
    assert String.length(amb) <= 420
    assert sem_codigos([amb]) == []
  end
end
