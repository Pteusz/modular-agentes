# Teste da correcao 5.2.1 (numero de WhatsApp normalizado e validado antes de criar, erro parcial traduzido e retomavel,
# mensagens curtas, copy com dados do feed). Rodar: MIX_ENV=test mix test test/etapa521_test.exs
# REGRA: tenants tp521_* (so os proprios dados); feed na fonte tp_teste521. IA pelo provedor Falso; nenhuma chamada real.
defmodule Etapa521Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano, Ficha, Iara, Banco}
  alias Trafego.Plataforma.Simulada

  @base "pedido objetivo vender; imovel Torre Sul; destino whatsapp; pixel 998877; publico casais zona sul; diario R$ 50; teto R$ 500; " <>
          "janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15"
  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar baixar_midia midia_dir provedor_ia feed_fonte)a
  @teto_fala 280

  setup_all do
    Registro.migrar!()
    Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}
    midia = Path.join(System.tmp_dir!(), "midia_tp521_#{System.unique_integer([:positive])}")
    Application.put_env(:trafego, :midia_dir, midia)
    Application.put_env(:trafego, :feed_fonte, "tp_teste521")

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
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp521\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp521\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM feed_imoveis WHERE fonte = 'tp_teste521'", [])
  end

  defp vincular(t) do
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    conta
  end

  defp tenant_pronto, do: (t = "tp521_#{System.unique_integer([:positive])}"; {t, vincular(t)})
  defp msgs({:ok, r}), do: List.wrap(r)
  defp bruto(t, texto), do: msgs(Agente.processar_mensagens(t, texto))
  defp sem_abertura(l), do: Enum.reject(l, &(&1 in [Iara.pergunta_horario() | Iara.apresentacao_mensagens()]))
  defp dizer(t, texto), do: t |> bruto(texto) |> sem_abertura()
  defp junto(l), do: Enum.join(l, "\n")
  defp png(w, h), do: <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, 8, 2, 0, 0, 0, 0::32>> <> :binary.copy(<<0>>, 3000)
  defp foto(t), do: t |> Agente.receber_midia_mensagens(midia(png(1080, 1080))) |> msgs() |> sem_abertura()

  defp midia(conteudo) do
    media = struct(Amarula.Content.Media, kind: :image, mimetype: "image/png", url: conteudo)
    %Amarula.Msg{channel: :teste, type: :media, raw: nil, content: media}
  end

  defp curtas(l), do: for(m <- l, String.length(m) > @teto_fala, do: m)
  defp da_conta(t), do: Enum.filter(Simulada.todas(), &(&1["conta_id"] == "act_#{t}"))

  # tenant com plano de WhatsApp completo, aguardando a foto (numero ja aceito pela ficha)
  defp ate_a_foto(numero, vinculados, opts \\ []) do
    {t, conta} = tenant_pronto()
    if vinculados, do: Simulada.registrar_numeros(conta, vinculados, opts)
    dizer(t, @base <> "; numero #{numero}")
    assert [pede] = dizer(t, "pode fazer sim")
    assert pede =~ "foto ou o video"
    {t, conta}
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "normalizar numero: so digitos, +55 e DDD; sem DDD nao e aceito" do
    assert Ficha.normalizar_numero("97420-8400") == {:sem_ddd, "974208400"}
    assert Ficha.normalizar_numero("(11) 97420-8400") == {:ok, "5511974208400"}
    assert Ficha.normalizar_numero("+55 11 97420-8400") == {:ok, "5511974208400"}
    assert Ficha.normalizar_numero("55 11 97420 8400") == {:ok, "5511974208400"}
    assert Ficha.normalizar_numero("011 97420-8400") == {:ok, "5511974208400"}
    assert Ficha.normalizar_numero("1134208400") == {:ok, "551134208400"}
    assert Ficha.normalizar_numero("123") == :invalido
    assert Ficha.formatar_numero("5511974208400") == "+55 11 97420-8400"
    assert Ficha.formatar_numero("551134208400") == "+55 11 3420-8400"
    assert Ficha.chave_numero("5511974208400") == Ficha.chave_numero("11974208400")
  end

  test "numero sem DDD: a Iara pergunta o DDD em vez de aceitar; so o DDD fecha" do
    {t, _} = tenant_pronto()
    l = dizer(t, @base <> "; numero 97420-8400")
    assert junto(l) =~ "DDD"
    refute junto(l) =~ "Montei o plano"
    plano = Plano.atual(t)
    assert plano["status"] == "rascunho"
    refute to_string(plano["numero"]) =~ ~r/\d/

    l = dizer(t, "numero 11")
    assert hd(l) =~ "Montei o plano"
    assert junto(l) =~ "+55 11 97420-8400"
    assert %{"numero" => "5511974208400", "status" => "aguardando_confirmacao"} = Plano.atual(t)
  end

  test "numero com mascara e +55 e normalizado e aparece formatado no plano" do
    {t, _} = tenant_pronto()
    l = dizer(t, @base <> "; numero +55 (11) 97420-8400")
    assert junto(l) =~ "+55 11 97420-8400"
    assert %{"numero" => "5511974208400"} = Plano.atual(t)
  end

  test "retomada: ajustar o numero e tentar de novo sem repetir a ficha" do
    {t, _} = ate_a_foto("11 97420-8400", ["5511999990000"])
    foto(t)
    antes = Plano.atual(t)

    l = dizer(t, "muda; numero 11 99999-0000")
    assert junto(l) =~ "+55 11 99999-0000"
    assert length(l) == 1, "so volta a mensagem afetada (destino), nao o plano inteiro"
    refute junto(l) =~ "Montei o plano"
    plano = Plano.atual(t)
    assert plano["status"] == "aguardando_confirmacao"
    for k <- ~w(publico pixel teto_total orcamento_diario imovel objetivo), do: assert(plano[k] == antes[k], "mudou #{k}")
    assert get_in(plano, ["criativo", "midia"]) == get_in(antes, ["criativo", "midia"]), "o criativo ja enviado e mantido"

    [fim] = dizer(t, "pode fazer sim")
    assert fim =~ "pausada"
    # a tentativa recusada deixou um rascunho parcial PAUSADO (nunca apagado); a retomada cria a campanha completa
    assert [%{"status" => "PAUSADA"}, %{"status" => "PAUSADA", "conjuntos" => [_ | _]}] = da_conta(t)
  end

  test "retomada pelo 'tenta de novo' depois de vincular na Meta" do
    {t, conta} = ate_a_foto("11 97420-8400", ["5511999990000"])
    foto(t)
    Simulada.registrar_numeros(conta, ["5511999990000", "5511974208400"])
    [fim] = dizer(t, "pode fazer sim")
    assert fim =~ "pausada"
  end

  test "falha parcial: motivo traduzido, rascunho parcial PAUSADO com id e plano retomavel" do
    # leitura dos numeros bloqueada (token sem permissao): tenta criar e a Meta recusa no conjunto de anuncios
    {t, _} = ate_a_foto("11 97420-8400", ["5511999990000"], cega: true)
    l = foto(t)
    txt = junto(l)
    assert [%{"id" => orfa, "status" => "PAUSADA"}] = da_conta(t)
    assert txt =~ orfa and txt =~ "rascunho parcial" and txt =~ "PAUSADO"
    refute txt =~ "graph_100", "o codigo cru da Meta nao vai pro corretor"
    assert txt =~ "continua guardado"
    assert %{"status" => "erro"} = Plano.atual(t)
    assert curtas(l) == []
  end

  test "sem numero: segue com o WhatsApp da Pagina, sem perguntar numero" do
    {t, _} = tenant_pronto()
    l = dizer(t, @base <> "; sem_numero sim")
    assert hd(l) =~ "Montei o plano"
    assert junto(l) =~ "WhatsApp da sua Pagina"
    assert [pede] = dizer(t, "pode fazer sim")
    assert pede =~ "foto ou o video"
    assert [fim] = foto(t)
    assert fim =~ "pausada"
  end

  test "primeira mensagem: apresentacao em 2 mensagens curtas e o horario separado, nenhuma longa" do
    {t, _} = tenant_pronto()
    l = bruto(t, "pedido objetivo vender; imovel Torre Sul")
    assert Enum.take(l, 2) == Iara.apresentacao_mensagens()
    assert length(l) == 3
    assert curtas(l) == [], "falas longas: #{inspect(curtas(l))}"

    # plano completo ja no primeiro contato: apresentacao (2) e so depois o plano
    {t2, _} = tenant_pronto()
    l = bruto(t2, @base <> "; sem_numero sim")
    assert Enum.take(l, 2) == Iara.apresentacao_mensagens()
    assert Enum.at(l, 2) =~ "Montei o plano"
    assert curtas(l) == [], "falas longas: #{inspect(curtas(l))}"
  end

  test "ambiguidade: mensagem curta, separada das perguntas e sem repetir o cabecalho" do
    {t, _} = tenant_pronto()
    [amb, perguntas] = dizer(t, "pedido objetivo vender; imovel Torre Sul; ambiguidade R$ 500 pode ser por dia ou no total")
    assert amb =~ "Fiquei na duvida" and amb =~ "Me confirma?"
    refute amb =~ "1. "
    assert perguntas =~ "1. " and String.starts_with?(perguntas, "Alem disso")
    refute perguntas =~ "Pra montar o plano"
    assert curtas([amb, perguntas]) == []
  end

  test "copy do anuncio usa nome, bairro e dormitorios do imovel do feed" do
    Banco.q(
      "INSERT INTO feed_imoveis (fonte, id, nome, bairro, regiao, dormitorios, valor_centavos, estado_original, imagem, atualizado_em) VALUES ('tp_teste521','77','Torre Sul','Vila Nova','Zona Sul','3',null,null,null,null) ON CONFLICT DO NOTHING",
      []
    )

    {t, _} = tenant_pronto()
    dizer(t, "pedido objetivo vender; imovel Torre Sul; destino site; url https://corretor.com.br/x; pixel 1; diario R$ 50; teto R$ 500")
    texto = Plano.atual(t)["criativo"]["texto"]
    assert texto =~ "Torre Sul" and texto =~ "Vila Nova" and texto =~ "3 dormitorios"
    refute texto =~ "Encontre seu proximo imovel"
    refute String.downcase(texto) =~ ~r/garantia|garantido|valorizacao|rentabilidade|lucro/
  end

  test "nenhuma fala da Iara passa de ~280 caracteres nos fluxos principais" do
    {t, _} = tenant_pronto()

    todas =
      bruto(t, "pedido objetivo vender; imovel Torre Sul") ++
        dizer(t, "destino whatsapp; numero 97420-8400") ++
        dizer(t, "numero 11; diario R$ 50; teto R$ 500; pixel 1") ++
        dizer(t, "muda; diario R$ 60") ++
        dizer(t, "pode fazer sim")

    assert curtas(todas) == [], "falas longas: #{inspect(curtas(todas))}"
  end
end
