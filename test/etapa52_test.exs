# Teste da etapa 5.2 ([Iara] ficha de estado, plano em mensagens curtas, perguntas numeradas, prefixo "[Iara] " por agente).
# Rodar: MIX_ENV=test mix test test/etapa52_test.exs
# REGRA: tenants tp52_* (so os proprios dados). IA pelo provedor Falso; nenhuma chamada real.
defmodule Etapa52Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal, Laco, Conexao}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano}
  alias Trafego.Plataforma.Simulada

  @completo "pedido objetivo vender; imovel Torre Sul; destino site; url https://corretor.com.br/lancamento; pixel 998877; " <>
              "publico casais zona sul; diario R$ 50; teto R$ 500; janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15"
  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar baixar_midia midia_dir audio openai provedor_ia)a
  @proibidos ~w(garantia garantido valorizacao rentabilidade lucro)

  setup_all do
    Registro.migrar!()
    Trafego.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}
    midia = Path.join(System.tmp_dir!(), "midia_tp52_#{System.unique_integer([:positive])}")
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
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp52\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp52\\_%'", [])
  end

  defp vincular(t) do
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    conta
  end

  defp tenant_pronto, do: (t = "tp52_#{System.unique_integer([:positive])}"; vincular(t); t)
  defp msgs({:ok, r}), do: List.wrap(r)
  # a apresentacao do primeiro contato (etapa 5.2.1) e testada na etapa521; aqui sai fora pra olhar o plano
  defp dizer(t, texto), do: t |> Agente.processar_mensagens(texto) |> msgs() |> sem_abertura()
  defp sem_abertura(l), do: Enum.reject(l, &(&1 in [Trafego.Iara.pergunta_horario() | Trafego.Iara.apresentacao_mensagens()]))
  defp junto(l), do: Enum.join(l, "\n")
  defp esperar(f, n \\ 60), do: f.() || (n > 0 && (Process.sleep(50); esperar(f, n - 1)))
  defp png(w, h), do: <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, 8, 2, 0, 0, 0, 0::32>> <> :binary.copy(<<0>>, 3000)

  defp midia(kind, conteudo, extra \\ []) do
    media = struct(Amarula.Content.Media, [kind: kind, mimetype: (if kind == :audio, do: "audio/ogg; codecs=opus", else: "image/png"), url: conteudo] ++ extra)
    %Amarula.Msg{channel: :teste, type: :media, raw: nil, content: media}
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "ficha completa numa mensagem: plano em 5 mensagens curtas, sem perguntas" do
    t = tenant_pronto()
    l = dizer(t, @completo)
    assert length(l) == 5 and Enum.all?(l, &is_binary/1)
    assert hd(l) =~ "Montei o plano" and hd(l) =~ "R$ 50,00"
    assert List.last(l) =~ "Voce confirma?" and List.last(l) =~ "PAUSADO"
    refute Enum.any?(l, &(&1 =~ ~r/^\s*1\. /m)), "nao pode haver pergunta numerada"
    assert %{"status" => "aguardando_confirmacao"} = Plano.atual(t)
  end

  test "faltou o nucleo: UMA mensagem curta, numerada, so com o que falta; nao repete o que ja foi dito" do
    t = tenant_pronto()
    l = dizer(t, "pedido objetivo vender; imovel Torre Sul; destino site; url https://corretor.com.br/x; pixel 1")
    assert [um] = l
    assert um =~ "1. " and um =~ "2. " and um =~ "por dia" and um =~ "teto"
    for ja <- ["objetivo", "imovel", "Torre Sul"], do: refute(um =~ ja, "repetiu: #{ja}")
    for fora <- ~w(criativo janela meta publico), do: refute(String.downcase(um) =~ fora, "perguntou: #{fora}")
    assert %{"status" => "rascunho"} = Plano.atual(t)

    # respondeu so a verba: o teto (ja perguntado) vira sugestao = diario x dias da janela e o plano sai
    l = dizer(t, "diario R$ 40")
    assert hd(l) =~ "Montei o plano"
    assert junto(l) =~ "Teto total: R$ 1200,00 (sugestao minha)"
    assert %{"orcamento_diario" => 4000, "teto_total" => 120_000} = Plano.atual(t)
  end

  test "ficha acumula entre mensagens e nunca pergunta de novo o que ja veio" do
    t = tenant_pronto()
    [p1] = dizer(t, "pedido objetivo vender; destino site; url https://corretor.com.br/x; pixel 1")
    assert p1 =~ "1. " and p1 =~ "por dia" and p1 =~ "teto"
    refute p1 =~ "qual imovel", "o link do site ja identifica o imovel"

    # chegou so uma parte: a pergunta seguinte lista apenas o que ainda falta (e diz o que ja anotou)
    [p2] = dizer(t, "imovel Torre Sul")
    assert p2 =~ "por dia"
    refute p2 =~ "qual imovel"
    # o teto ja foi perguntado uma vez: nao pergunta de novo, sugere
    refute p2 =~ "teto"
    assert %{"imovel" => "Torre Sul", "objetivo" => "vender"} = Plano.atual(t)

    l = dizer(t, "diario R$ 30")
    assert hd(l) =~ "Montei o plano" and junto(l) =~ "Teto total: R$ 900,00 (sugestao minha)"
  end

  test "corrigir um campo muda so ele; ajuste em linguagem natural reenvia so a mensagem afetada" do
    t = tenant_pronto()
    antes = dizer(t, @completo)
    plano_antes = Plano.atual(t)

    l = dizer(t, "muda; diario R$ 80")
    plano = Plano.atual(t)
    assert plano["orcamento_diario"] == 8000
    for k <- ~w(publico url pixel teto_total destino imovel objetivo), do: assert(plano[k] == plano_antes[k], "mudou #{k}")
    assert plano["status"] == "aguardando_confirmacao"
    # so a mensagem do resumo (verba) + o fechamento; as outras ficam como estavam
    assert length(l) < length(antes)
    assert hd(l) =~ "R$ 80,00" and List.last(l) =~ "Ficou bom assim?"
    refute junto(l) =~ "Publico:"
  end

  test "padroes entram marcados como sugestao e o criativo so e pedido depois do plano aceito" do
    t = tenant_pronto()
    l = dizer(t, "pedido objetivo vender; imovel Torre Sul; destino site; url https://corretor.com.br/x; pixel 1; diario R$ 50; teto R$ 500")
    txt = junto(l)
    assert length(l) == 5
    assert txt =~ "sugestao" and txt =~ "Publico:" and txt =~ "30 dias" or txt =~ "Janela"
    plano = Plano.atual(t)
    assert plano["janela"]["inicio"] && plano["meta"]["custo_max"] == 1500
    assert get_in(plano, ["criativo", "midia"]) == nil

    # aceitou: agora sim pede a foto/video; nada foi criado ainda
    [pede] = dizer(t, "pode fazer sim")
    assert pede =~ "foto ou o video"
    assert %{"status" => "aguardando_criativo"} = Plano.atual(t)
    assert Plano.listar(t) |> Enum.all?(&(&1["campanha_id"] in [nil, ""]))

    # chegou o criativo: executa, campanha PAUSADA
    [fim] = t |> Agente.receber_midia_mensagens(midia(:image, png(1080, 1080))) |> msgs() |> sem_abertura()
    assert fim =~ "pausada"
    assert %{"campanha_id" => cid} = Plano.listar(t) |> List.last()
    assert Enum.find(Simulada.todas(), &(&1["id"] == cid))["status"] == "PAUSADA"
  end

  test "copy sugerida nao traz termos proibidos (HOUSING)" do
    t = tenant_pronto()
    l = dizer(t, "pedido objetivo vender; imovel Torre Sul; destino site; url https://corretor.com.br/x; pixel 1; diario R$ 50; teto R$ 500")
    texto = Plano.atual(t)["criativo"]["texto"] |> String.downcase()
    for p <- @proibidos, do: refute(texto =~ p, "copy com #{p}")
    refute junto(l) =~ ~r/\b(idade|genero|cep)\b/i
  end

  test "frases proibidas nunca aparecem e ambiguidade e dita, nao adivinhada" do
    t = tenant_pronto()
    todas = dizer(t, "pedido objetivo vender; imovel Torre Sul") ++ dizer(t, "destino site; url https://corretor.com.br/x; pixel 1") ++ dizer(t, "diario R$ 50; teto R$ 500")
    txt = String.downcase(junto(todas))
    for f <- ["uma coisa de cada vez", "o resto a gente vê depois", "o resto a gente ve depois", "uma coisa por vez"], do: refute(txt =~ f)

    t2 = tenant_pronto()
    [amb] = dizer(t2, "pedido objetivo vender; imovel Torre Sul; ambiguidade R$ 500 pode ser por dia ou no total")
    assert amb =~ "duvida" and amb =~ "R$ 500" and amb =~ "Me confirma?"
    assert Plano.atual(t2)["orcamento_diario"] == nil
  end

  test "audio vale como texto: mesma ficha, mesmo resultado" do
    t = tenant_pronto()
    l = t |> Agente.receber_midia_mensagens(midia(:audio, @completo, seconds: 6, file_length: 9000)) |> msgs() |> sem_abertura()
    assert hd(l) =~ "Montei o plano" and length(l) == 5
    assert %{"status" => "aguardando_confirmacao"} = Plano.atual(t)
  end

  test "pelo laco: prefixo \"[Iara] \" em cada mensagem, ordem mantida, teto_por_min respeitado" do
    t = tenant_pronto()
    {:ok, p} = Conexao.conectar(t)
    ref = Laco.canal(p)
    Canal.Simulado.injetar(ref, :proprio, @completo)
    assert esperar(fn -> Enum.any?(Canal.Simulado.enviadas(ref), &(&1 =~ "Voce confirma?")) end)
    env = Canal.Simulado.enviadas(ref)
    assert length(env) >= 5 and Enum.all?(env, &String.starts_with?(&1, "[Iara] "))
    assert Enum.find_index(env, &(&1 =~ "Montei o plano")) < Enum.find_index(env, &(&1 =~ "Voce confirma?"))
    Conexao.encerrar(t)

    # teto_por_min = 3: so 3 saem, o excedente vai junto na ultima (nada se perde, ordem preservada)
    t2 = tenant_pronto()
    :ok = Registro.config(t2, %{"teto_por_min" => 3})
    {:ok, p2} = Conexao.conectar(t2)
    ref2 = Laco.canal(p2)
    Canal.Simulado.injetar(ref2, :proprio, @completo)
    assert esperar(fn -> Enum.any?(Canal.Simulado.enviadas(ref2), &(&1 =~ "Voce confirma?")) end)
    env2 = Canal.Simulado.enviadas(ref2)
    assert length(env2) == 3 and Enum.all?(env2, &String.starts_with?(&1, "[Iara] "))
    assert junto(env2) =~ "Montei o plano" and List.last(env2) =~ "Voce confirma?"
    Conexao.encerrar(t2)
  end

  test "prefixo e por agente: eco continua com [agente] e o painel mostra [Iara]" do
    assert Contrato.prefixo() == "[Iara] "
    assert Nucleo.Laco.prefixo_padrao() == "[agente] "

    t = tenant_pronto()
    dizer(t, @completo)
    assert %{"prefixo" => "[Iara]", "status" => "aguardando_confirmacao"} = Trafego.Painel.plano_aguardando(t)
  end
end
