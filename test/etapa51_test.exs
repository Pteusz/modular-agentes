# Teste da etapa 5.1 (Iara: persona em todas as respostas, primeiro contato e horario, audio tratado como texto).
# Escrito ANTES de construir. Rodar: MIX_ENV=test mix test test/etapa51_test.exs
# REGRA: tenants tpi_* (so os proprios dados, nunca limpar tabela inteira). Nenhuma chamada real: IA pelo provedor Falso, por um
# espiao que embrulha o Falso, e (adaptador) por servidor HTTP falso local. Nenhum audio em disco.
defmodule IaEspia do
  @moduledoc false
  # Embrulha o Falso: :falar devolve "Iara: " + texto-base composto. Modos (Process.get(:espia)): :erro | :vazio | :perde_valor.
  # Cada chamada avisa o processo do teste ({:ia, tarefa, entrada}); as chamadas rodam no processo do teste.
  @behaviour Trafego.IA
  alias Trafego.IA.Falso

  @impl true
  def chamar(faixa, :falar, entrada) do
    send(self(), {:ia, :falar, entrada})

    case Process.get(:espia) do
      :erro -> {:error, :boom}
      :vazio -> {:ok, %{"texto" => "   "}, uso(faixa)}
      :perde_valor -> {:ok, %{"texto" => "Iara: tudo certo, ja resolvi aqui."}, uso(faixa)}
      _ ->
        {:ok, %{"texto" => t}, u} = Falso.chamar(faixa, :falar, entrada)
        {:ok, %{"texto" => "Iara: " <> t}, u}
    end
  end

  def chamar(faixa, tarefa, entrada) do
    send(self(), {:ia, tarefa, entrada})
    Falso.chamar(faixa, tarefa, entrada)
  end

  @impl true
  def transcrever(bytes, meta), do: Falso.transcrever(bytes, meta)

  defp uso(faixa), do: %{"modelo" => "falso-#{faixa}", "tokens_in" => 100, "tokens_out" => 50}
end

defmodule Etapa51Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Iara, Plano, Proposta, TetoIA}
  alias Trafego.Plataforma.Simulada

  @pedido "pedido destino site; url https://corretor.com.br/lancamento; pixel 998877; publico casais 30-45 zona sul; " <>
            "criativo foto1.jpg | Apartamento novo na zona sul; diario R$ 50; teto R$ 500; janela #{Date.utc_today()} #{Date.add(Date.utc_today(), 30)}; meta 20; custo_max R$ 15"
  @chaves ~w(cotacao_usd_brl teto_ia_brl teto_max_centavos preco_brl_por_mil preco_usd_por_milhao notificar baixar_midia midia_dir audio openai provedor_ia)a

  setup_all do
    Registro.migrar!()
    Trafego.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}
    salvo_env = System.get_env("OPENAI_API_KEY")
    midia = Path.join(System.tmp_dir!(), "midia_tpi_#{System.unique_integer([:positive])}")
    Application.put_env(:trafego, :midia_dir, midia)

    on_exit(fn ->
      limpar()
      File.rm_rf(midia)
      for {k, v} <- salvo, do: (case v do {:ok, x} -> Application.put_env(:trafego, k, x); :error -> Application.delete_env(:trafego, k) end)
      if salvo_env, do: System.put_env("OPENAI_API_KEY", salvo_env), else: System.delete_env("OPENAI_API_KEY")
    end)

    {:ok, midia: midia}
  end

  setup do
    Application.put_env(:trafego, :teto_ia_brl, 1000.0)
    Application.put_env(:trafego, :cotacao_usd_brl, 5.0)
    Application.put_env(:trafego, :provedor_ia, IaEspia)
    Process.delete(:espia)
    pid = self()
    Application.put_env(:trafego, :notificar, fn tenant, texto -> send(pid, {:aviso, tenant, texto}) end)

    Application.put_env(:trafego, :baixar_midia, fn %{content: %{url: bytes}} -> if bytes == :falha, do: {:error, :x}, else: {:ok, bytes} end)
    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tpi\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tpi\\_%'", [])
  end

  defp resp({:ok, r}), do: r
  defp dizer(t, texto), do: resp(Agente.processar(t, texto))

  defp audio(fala, extra \\ []) do
    media = struct(Amarula.Content.Media, [kind: :audio, mimetype: "audio/ogg; codecs=opus", seconds: 6, file_length: 9_000, url: fala] ++ extra)
    %Amarula.Msg{channel: :teste, type: :media, raw: nil, content: media}
  end

  defp falar_audio(t, fala), do: resp(Agente.receber_midia(t, audio(fala)))

  defp vincular(t) do
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    conta
  end

  defp novo, do: "tpi_#{System.unique_integer([:positive])}"
  defp tenant_pronto, do: (t = novo(); vincular(t); t)
  defp custos(t), do: Registro.eventos(t) |> Enum.filter(&(&1.tipo == "custo_tokens"))
  defp refs(t, ref), do: custos(t) |> Enum.filter(&(&1.dados["ref"] == ref))
  defp confirmacoes(t), do: Registro.eventos(t) |> Enum.count(&(&1.tipo == "confirmacao"))
  defp status(cid), do: Simulada.todas() |> Enum.find(&(&1["id"] == cid))

  # tenant com a apresentacao e a pergunta de horario ja resolvidas e campanha criada PAUSADA
  defp montar do
    t = tenant_pronto()
    assert dizer(t, @pedido) =~ "confirma"
    assert dizer(t, "pode fazer sim") =~ "pausada"
    %{"campanha_id" => cid} = Plano.listar(t) |> List.last()
    {t, cid}
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "persona: o texto de persona traz identidade, escopo, estilo e limites" do
    p = Iara.persona()
    for trecho <- ["Iara", "Ataque Total", "Cury Construtora", "uma IA", "aprende", "recusa", "UMA pergunta", "propoe", "WhatsApp", "2 a 3 linhas"],
        do: assert(p =~ trecho, "persona sem: #{trecho}")

    assert Iara.apresentacao() =~ "Iara" and Iara.apresentacao() =~ "Ataque Total" and Iara.apresentacao() =~ "IA"
    assert Iara.apresentacao() =~ "aprendo com o tempo" and Iara.apresentacao() =~ ~r/me adapto/i
    assert Iara.pergunta_horario() =~ "horario" and Iara.pergunta_horario() =~ "?" and Iara.pergunta_horario() =~ "9h"
  end

  test "TODA resposta ao corretor passa pela fala da Iara (texto, ativar, pausar, confirmar, erro) e carrega os fatos do texto-base" do
    t = tenant_pronto()
    r = dizer(t, @pedido)
    assert r =~ "Iara: " and r =~ "Voce confirma?" and r =~ "R$ 50,00"
    assert_received {:ia, :falar, e}
    assert e["base"] =~ "R$ 50,00" and e["base"] =~ "Voce confirma?"
    assert e["mensagem_do_corretor"] =~ "pedido destino site" and e["origem"] == "texto"

    for texto <- ["pode fazer sim", "ativa a campanha", "sim, pode ativar", "pausa a campanha", "sim, pode pausar", "ativa a campanha", "nao, deixa"] do
      r = dizer(t, texto)
      assert String.starts_with?(r, "Iara: "), "sem a voz da Iara: #{texto} -> #{r}"
      assert_received {:ia, :falar, _}
    end

    # sem campanha para ativar, erro de credencial: tambem na voz dela, com o mesmo significado
    u = novo()
    vincular(u)
    assert dizer(u, "ativa a campanha") =~ ~r/nao ha campanha.*nada foi alterado/is
    {:ok, _} = Acesso.cadastrar(u, %{"conta_id" => "act_#{u}", "token" => "SIM-#{u}"})
    Registro.gravar(u, "trafego_conta", Map.put(Acesso.conta(u), "status", "token invalido"))
    r = dizer(u, "oi")
    assert r =~ ~r/token/i and r =~ "nada foi alterado"
  end

  test "fala fora do contrato (erro, vazia, sem os valores do texto-base) cai no texto fixo com o mesmo significado" do
    t = tenant_pronto()
    # primeira volta sem fala: apresentacao + base fixos
    Process.put(:espia, :erro)
    r = dizer(t, @pedido)
    refute r =~ "Iara: "
    assert r =~ "Eu sou a Iara" and r =~ "Voce confirma?" and r =~ "R$ 50,00" and r =~ "PAUSADO"

    Process.put(:espia, :vazio)
    assert dizer(tenant_pronto(), "ativa a campanha") =~ ~r/nao ha campanha|nao posso ativar/i

    # a IA "resolveu" mas sumiu com os valores: o texto fixo vale
    Process.put(:espia, :perde_valor)
    u = tenant_pronto()
    r = dizer(u, @pedido)
    refute r =~ "ja resolvi"
    assert r =~ "R$ 50,00" and r =~ "Voce confirma?"
  end

  test "custo da fala entra no custo_tokens em R$ e no teto; teto bloqueado nao chama a IA de fala e mantem a mensagem do teto" do
    t = tenant_pronto()
    dizer(t, @pedido)
    assert [%{dados: d} | _] = refs(t, "falar")
    assert d["custo_brl"] > 0 and d["papel"] == "planejador" or d["custo_brl"] > 0
    assert_in_delta TetoIA.gasto(t), Enum.sum(for e <- custos(t), do: e.dados["custo_brl"]), 1.0e-6
    assert TetoIA.gasto(t) > Enum.sum(for e <- refs(t, "planejar"), do: e.dados["custo_brl"])

    # trava no valor gasto: bloqueado
    Application.put_env(:trafego, :teto_ia_brl, TetoIA.gasto(t))
    assert {:bloqueado, _} = TetoIA.status(t)
    n = length(custos(t))
    receive do {:ia, _, _} -> :ok after 0 -> :ok end
    flush()
    r = dizer(t, "quero anunciar outro lancamento")
    assert r =~ ~r/teto de IA/i and r =~ "nada foi alterado"
    refute r =~ "Iara: "
    refute_received {:ia, :falar, _}
    assert length(custos(t)) == n
    # sem horario: decisao do codigo (sem IA) continua valendo
    assert Iara.horario(t) == "09:00"
  end

  test "uma pergunta por vez: pergunta so a primeira pendencia, aproveita o que ja foi dito e guarda as demais" do
    t = tenant_pronto()
    r = dizer(t, "pedido destino site; url https://corretor.com.br/lancamento; pixel 998877; publico casais 30-45")
    assert r =~ "criativo"
    for outro <- ~w(orcamento teto janela meta), do: refute(r =~ outro, "perguntou junto: #{outro}")
    assert_received {:ia, :falar, e}
    assert "orcamento_diario" in e["dados"]["faltam_depois"] and "meta" in e["dados"]["faltam_depois"]
    refute "criativo" in e["dados"]["faltam_depois"]
    assert Registro.eventos(t) |> Enum.any?(&(&1.dados["ref"] == "pendencias" and "orcamento_diario" in &1.dados["faltam"] and "criativo" in &1.dados["faltam"]))

    # o que ele ja disse nao e perguntado de novo; vai uma por vez ate fechar
    r = dizer(t, "criativo foto1.jpg | Apartamento novo")
    assert r =~ "orcamento" and not (r =~ "criativo")
    r = dizer(t, "diario R$ 50")
    assert r =~ "teto"
    assert dizer(t, "teto R$ 500; janela #{Date.utc_today()} #{Date.add(Date.utc_today(), 30)}") =~ "meta"
    assert dizer(t, "meta 20; custo_max R$ 15") =~ "Voce confirma?"
    # valores invalidos mantem o codigo no texto (significado do erro)
    u = tenant_pronto()
    assert dizer(u, String.replace(@pedido, "teto R$ 500", "teto R$ 999999999")) =~ "teto_acima_do_maximo"
  end

  test "primeiro contato: se apresenta uma vez so, por corretor, e pergunta o melhor horario sem pergunta duplicada" do
    t = tenant_pronto()
    assert Iara.perfil(t)["apresentada"] == false
    r = dizer(t, "oi")
    assert r =~ "Eu sou a Iara" and r =~ "Ataque Total" and r =~ "Cury Construtora" and r =~ "IA" and r =~ "aprendo com o tempo"
    assert r =~ "melhor horario" and r =~ "9h" and r =~ "?"
    refute r =~ ~r/falta/i, "nada de pergunta do plano junto da pergunta de horario"
    assert %{"apresentada" => true, "horario_estado" => "perguntado"} = Iara.perfil(t)

    # nunca mais se apresenta
    dizer(t, "8h30")
    r = dizer(t, "quero anunciar um lancamento")
    refute r =~ "Eu sou a Iara"

    # outro corretor tem o proprio primeiro contato
    u = tenant_pronto()
    assert Iara.perfil(u)["apresentada"] == false
    assert dizer(u, "oi") =~ "Eu sou a Iara"
    # audio no primeiro contato tambem
    v = tenant_pronto()
    assert falar_audio(v, "oi") =~ "Eu sou a Iara"
  end

  test "horario: definido pelo corretor, padrao 9h se nao responder, muda depois, nunca desliga" do
    # definido
    t = tenant_pronto()
    dizer(t, "oi")
    r = dizer(t, "pode ser 8h30")
    assert r =~ "08:30" or r =~ "8h30"
    assert Iara.horario(t) == "08:30" and Iara.perfil(t)["horario_estado"] == "definido"
    assert Registro.ler(t, "iara_perfil")["horario"] == "08:30"

    # nao respondeu (mudou de assunto): padrao 09:00 e a mensagem segue o fluxo normal
    u = tenant_pronto()
    dizer(u, "oi")
    r = dizer(u, @pedido)
    assert r =~ "Voce confirma?"
    assert Iara.horario(u) == "09:00" and Iara.perfil(u)["horario_estado"] == "padrao"

    # primeiro contato com pedido de plano: a pergunta de horario espera o plano sair do caminho (uma pergunta por vez)
    v = tenant_pronto()
    r = dizer(v, @pedido)
    assert r =~ "Eu sou a Iara" and r =~ "Voce confirma?"
    refute r =~ "melhor horario"
    r = dizer(v, "pode fazer sim")
    assert r =~ "pausada" and r =~ "melhor horario"
    assert Iara.perfil(v)["horario_estado"] == "perguntado"
    dizer(v, "ativa a campanha")
    assert Iara.horario(v) == "09:00"

    # mudar depois: direto ou em duas voltas
    assert dizer(t, "muda o horario das atualizacoes para 7h") =~ ~r/07:00|7h/
    assert Iara.horario(t) == "07:00"
    r = dizer(t, "quero mudar o horario")
    assert r =~ ~r/que horas|qual horario/i and r =~ "?"
    assert dizer(t, "18:15") =~ ~r/18:15|18h15/
    assert Iara.horario(t) == "18:15"

    # desligar nao pode: explica e oferece so mudar o horario
    antes = Iara.perfil(t)
    r = dizer(t, "para de me mandar as atualizacoes")
    assert r =~ ~r/nao (da|posso)/i and r =~ "horario"
    assert Iara.perfil(t) == antes
    refute r =~ ~r/desliguei|desativei|cancelei as atualiza/i

    assert Iara.normalizar_horario("8") == "08:00"
    assert Iara.normalizar_horario("23:59") == "23:59"
    assert Iara.normalizar_horario("25:00") == nil and Iara.normalizar_horario("abc") == nil and Iara.normalizar_horario(nil) == nil
  end

  test "audio e texto: confirmar plano, ativar e pausar por audio valem; sem trava e sem eco fixo" do
    {t, cid} = montar()
    base = confirmacoes(t)

    r = falar_audio(t, "pode ativar a campanha")
    assert r =~ "confirma"
    refute r =~ ~r/por texto|audio nao confirma|Entendi pelo audio|por seguranca/i
    assert [%{"tipo" => "ativar", "status" => "aguardando_confirmacao"}] = Proposta.listar(t)
    assert status(cid)["status"] == "PAUSADA"

    r = falar_audio(t, "sim, pode ativar")
    assert r =~ ~r/ativ/i
    assert status(cid)["status"] == "ATIVA"
    assert confirmacoes(t) == base + 1

    assert falar_audio(t, "pausa a campanha") =~ ~r/pausar.*confirma/is
    assert falar_audio(t, "nao, cancela") =~ ~r/cancel/i
    assert status(cid)["status"] == "ATIVA"
    falar_audio(t, "pausa a campanha")
    assert falar_audio(t, "sim") =~ ~r/paus/i
    assert status(cid)["status"] == "PAUSADA"

    # plano por audio de ponta a ponta
    u = tenant_pronto()
    conta = "act_#{u}"
    r = falar_audio(u, @pedido)
    assert r =~ "Voce confirma?"
    refute r =~ ~r/por texto|Entendi pelo audio/i
    assert Simulada.todas() |> Enum.filter(&(&1["conta_id"] == conta)) == []
    assert falar_audio(u, "pode fazer sim") =~ "pausada"
    assert Simulada.todas() |> Enum.filter(&(&1["conta_id"] == conta)) |> length() == 1
    assert_received {:ia, :falar, %{"origem" => "audio"}}
  end

  test "audio duvidoso ou ambiguo: a Iara diz o que ficou ambiguo e pergunta 'e isso mesmo?' antes de agir; a resposta e texto normal" do
    {t, cid} = montar()
    r = falar_audio(t, "ativa a campanha inaudivel")
    assert r =~ ~r/isso mesmo\?/i
    assert r =~ "inaudivel" or r =~ ~r/nao tenho certeza|nao entendi bem/i
    assert Proposta.listar(t) == [], "nada foi feito antes da confirmacao da transcricao"
    assert status(cid)["status"] == "PAUSADA"

    # ambigua curta: repergunta e mantem a fala em memoria
    assert dizer(t, "talvez") =~ ~r/isso mesmo\?/i
    assert Proposta.listar(t) == []
    # sim: a fala entra como texto no fluxo normal (ai sim abre a proposta de ativar)
    r = dizer(t, "sim, isso mesmo")
    assert r =~ "confirma"
    assert [%{"tipo" => "ativar", "status" => "aguardando_confirmacao"}] = Proposta.listar(t)
    assert Trafego.Iara.Memoria.pegar(t) == nil

    # nao: descarta e nada acontece
    {u, _} = montar()
    falar_audio(u, "ativa a campanha ???")
    assert dizer(u, "nao, nao era isso") =~ ~r/ok|sem problema|tudo bem/i
    assert Proposta.listar(u) == []
    assert Trafego.Iara.Memoria.pegar(u) == nil

    # mensagem nova e longa: descarta a fala duvidosa e segue como mensagem normal
    {w, _} = montar()
    falar_audio(w, "ativa a campanha inaudivel")
    dizer(w, "quero pausar nada, so queria saber como esta o desempenho das minhas campanhas desta semana no geral por favor, e tambem queria entender melhor como funciona o custo por resultado de cada anuncio")
    assert Trafego.Iara.Memoria.pegar(w) == nil
    assert Proposta.listar(w) == []
  end

  test "privacidade: transcricao em duvida so em memoria; audio e fala nunca vao para evento, disco ou log", %{midia: midia} do
    t = tenant_pronto()
    segredo = "meu cpf e um assunto pessoal xyzzy inaudivel"
    log = ExUnit.CaptureLog.capture_log(fn -> falar_audio(t, segredo) end)
    refute log =~ "xyzzy"
    assert Trafego.Iara.Memoria.pegar(t) =~ "xyzzy"
    todo = Registro.eventos(t) |> Enum.map(&Jason.encode!(&1.dados)) |> Enum.join(" ")
    refute todo =~ "xyzzy"
    refute inspect(Registro.ler(t, "trafego_atual")) =~ "xyzzy"
    refute inspect(Registro.ler(t, "iara_perfil")) =~ "xyzzy"
    refute Path.wildcard(Path.join(midia, "**/*")) |> Enum.any?(&File.regular?/1)
    # a fala em duvida nao e mandada a IA de fala (so a descricao da duvida)
    assert_received {:ia, :checar_transcricao, _}
    Trafego.Iara.Memoria.limpar(t)
  end

  test "adaptador OpenAI: persona nas instrucoes, esquemas estritos para fala, horario e transcricao, custo em R$" do
    pid = self()

    resposta = fn texto, ti, to ->
      {200, %{"status" => "completed", "output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => Jason.encode!(texto)}]}], "usage" => %{"input_tokens" => ti, "output_tokens" => to}}}
    end

    srv =
      HttpFalso.start(fn %{caminho: c, corpo: corpo} ->
        b = Jason.decode!(corpo)
        nome = get_in(b, ["text", "format", "name"])
        send(pid, {:openai, c, b})

        case nome do
          "falar" -> resposta.(%{"texto" => "Oi, sou a Iara! Seu plano p1 ta pronto, confirma?"}, 1000, 200)
          "horario" -> resposta.(%{"horario" => "08:30"}, 100, 10)
          "checar_transcricao" -> resposta.(%{"duvida" => nil}, 100, 10)
          _ -> {500, %{}}
        end
      end)

    on_exit(fn -> :gen_tcp.close(srv.ls) end)
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.OpenAI)
    Application.put_env(:trafego, :openai, base_url: HttpFalso.url(srv), timeout: 2_000, modelos: %{pequena: "modelo-pequena-x", media: "modelo-media-x"})
    Application.put_env(:trafego, :preco_usd_por_milhao, %{"modelo-pequena-x" => {1.0, 4.0}, "modelo-media-x" => {2.0, 8.0}})
    System.put_env("OPENAI_API_KEY", "sk-teste-5-1")
    t = novo()
    vincular(t)

    texto = Iara.falar(t, "Plano p1: pronto. Voce confirma?", situacao: :plano_pronto, texto: "quero anunciar")
    assert texto == "Oi, sou a Iara! Seu plano p1 ta pronto, confirma?"
    assert_received {:openai, "/v1/responses", b}
    assert b["store"] == false and get_in(b, ["text", "format", "strict"]) == true and get_in(b, ["text", "format", "name"]) == "falar"
    assert get_in(b, ["text", "format", "schema", "required"]) == ["texto"]
    [%{"content" => instrucao}, %{"content" => usuario}] = b["input"]
    assert instrucao =~ "Iara" and instrucao =~ "Ataque Total" and instrucao =~ "Cury Construtora"
    assert usuario =~ "Plano p1: pronto" and usuario =~ "quero anunciar"
    refute usuario =~ "act_" or usuario =~ "SIM-"

    # custo da fala em R$: 1000 in x US$1/M + 200 out x US$4/M = US$ 0,0018 x 5,00 = R$ 0,009
    assert [%{dados: d}] = refs(t, "falar")
    assert_in_delta d["custo_brl"], 0.009, 1.0e-6
    assert_in_delta TetoIA.gasto(t), 0.009, 1.0e-6

    assert {:ok, "08:30"} = Iara.ler_horario(t, "pode ser as 8h30")
    assert_received {:openai, _, %{"text" => %{"format" => %{"name" => "horario", "strict" => true}}}}
    assert :ok = Iara.duvida_audio(t, "ativa a campanha")
    assert_received {:openai, _, %{"text" => %{"format" => %{"name" => "checar_transcricao", "strict" => true}}}}

    # erro HTTP do provedor: fala vira texto fixo; horario nao entendido; transcricao sem duvida
    srv2 = HttpFalso.start(fn _ -> {500, %{}} end)
    on_exit(fn -> :gen_tcp.close(srv2.ls) end)
    Application.put_env(:trafego, :openai, base_url: HttpFalso.url(srv2), timeout: 2_000, modelos: %{pequena: "modelo-pequena-x", media: "modelo-media-x"})
    assert Iara.falar(t, "Plano p1: pronto. Voce confirma?") == "Plano p1: pronto. Voce confirma?"
    assert {:ok, nil} = Iara.ler_horario(t, "8h")
    assert :ok = Iara.duvida_audio(t, "x")
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.Falso)
  end

  test "contrato: a Iara e oferecida (trafego.iara 1.0) e o perfil entra na retencao" do
    c = Contrato.contrato()
    assert %{versao: "1.5", oferece: %{"trafego.iara" => "1.0", "trafego" => "1.0", "trafego.painel" => "1.1"}} = c
    assert Enum.any?(Contrato.retencao(), &(&1.chave == "iara_perfil"))
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
