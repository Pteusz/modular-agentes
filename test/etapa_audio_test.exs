# Teste da etapa "audio" (nota de voz do WhatsApp -> transcricao -> fluxo normal do agente). Escrito ANTES de construir.
# Rodar: MIX_ENV=test mix test test/etapa_audio_test.exs
# REGRA: tenants tpa_* (so os proprios dados). Nenhuma chamada real: transcricao pelo provedor Falso (os bytes do "audio" SAO o texto
# falado) e, no teste do adaptador, por servidor HTTP falso local. Nenhum arquivo de audio e escrito em disco.
defmodule EtapaAudioTest do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano, Proposta, TetoIA, Custo}
  alias Trafego.Plataforma.Simulada

  @pedido "pedido destino site; url https://corretor.com.br/lancamento; pixel 998877; publico casais 30-45 zona sul; " <>
            "criativo foto1.jpg | Apartamento novo na zona sul; diario R$ 50; teto R$ 500; janela #{Date.utc_today()} #{Date.add(Date.utc_today(), 30)}; meta 20; custo_max R$ 15"
  @chaves ~w(cotacao_usd_brl teto_ia_brl teto_max_centavos preco_brl_por_mil preco_brl_por_min preco_usd_por_minuto notificar baixar_midia midia_dir audio openai provedor_ia)a

  setup_all do
    Registro.migrar!()
    Trafego.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}
    salvo_env = System.get_env("OPENAI_API_KEY")
    Application.put_env(:trafego, :teto_ia_brl, 1000.0)
    Application.put_env(:trafego, :cotacao_usd_brl, 5.0)
    midia = Path.join(System.tmp_dir!(), "midia_tpa_#{System.unique_integer([:positive])}")
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
    pid = self()
    Application.put_env(:trafego, :notificar, fn tenant, texto -> send(pid, {:aviso, tenant, texto}) end)
    # download falso: o "arquivo" e o texto que o corretor falou (campo url so carrega isso no teste); conta os downloads
    {:ok, n} = Agent.start_link(fn -> 0 end)

    Application.put_env(:trafego, :baixar_midia, fn %{content: %{url: bytes}} ->
      Agent.update(n, &(&1 + 1))
      if bytes == :falha, do: {:error, :x}, else: {:ok, bytes}
    end)

    {:ok, baixados: n}
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tpa\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tpa\\_%'", [])
  end

  defp resp({:ok, r}), do: r

  # mensagem de audio como o Amarula entrega (nota de voz = ogg/opus)
  defp audio(fala, extra \\ []) do
    media = struct(Amarula.Content.Media, [kind: :audio, mimetype: "audio/ogg; codecs=opus", seconds: 6, file_length: 9_000, url: fala] ++ extra)
    %Amarula.Msg{channel: :teste, type: :media, raw: nil, content: media}
  end

  defp vincular(t) do
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    conta
  end

  defp novo, do: "tpa_#{System.unique_integer([:positive])}"

  # tenant com campanha criada PAUSADA e verificada (pelo texto)
  defp montar do
    t = novo()
    vincular(t)
    assert resp(Agente.processar(t, @pedido)) =~ "confirma"
    assert resp(Agente.processar(t, "pode fazer sim")) =~ "pausada"
    %{"id" => id, "campanha_id" => cid} = Plano.listar(t) |> List.last()
    {t, id, cid}
  end

  defp status(cid), do: Simulada.todas() |> Enum.find(&(&1["id"] == cid))
  defp confirmacoes(t), do: Registro.eventos(t) |> Enum.count(&(&1.tipo == "confirmacao"))
  defp custos(t), do: Registro.eventos(t) |> Enum.filter(&(&1.tipo == "custo_tokens"))
  defp so_audio(t), do: custos(t) |> Enum.filter(&(&1.dados["ref"] == "transcrever"))

  # ------------------------------------------------------------------------------------------------------------------
  # REGRA MUDADA por decisao do Mateus em 2026-10-19 (etapa 5.1): audio e tratado COMO TEXTO em tudo (inclusive confirmar plano,
  # ativar e pausar). Nao ha mais trava "so por texto" nem eco "Entendi pelo audio". Transcricao duvidosa: pergunta "e isso mesmo?".
  test "audio com pedido de ativar: propoe e o 'sim' em audio confirma, como no texto" do
    {t, pid, cid} = montar()
    base = confirmacoes(t)

    r = resp(Agente.receber_midia(t, audio("pode ativar a campanha")))
    assert r =~ "confirma"
    refute r =~ ~r/por texto|Entendi pelo audio|audio nao confirma/i
    assert [%{"tipo" => "ativar", "status" => "aguardando_confirmacao", "plano_id" => ^pid}] = Proposta.listar(t)
    assert status(cid)["status"] == "PAUSADA"

    r = resp(Agente.receber_midia(t, audio("sim, pode ativar")))
    assert r =~ ~r/ativ/i
    refute r =~ ~r/por texto/i
    assert status(cid)["status"] == "ATIVA"
    assert confirmacoes(t) == base + 1
  end

  test "audio com pedido de pausar: 'sim' em audio pausa; 'nao' em audio cancela" do
    {t, _pid, cid} = montar()
    assert resp(Agente.processar(t, "ativa a campanha")) =~ "confirma"
    assert resp(Agente.processar(t, "sim, pode ativar")) =~ "ativa"
    assert status(cid)["status"] == "ATIVA"

    assert resp(Agente.receber_midia(t, audio("pausa a campanha"))) =~ ~r/pausar.*confirma/is
    assert status(cid)["status"] == "ATIVA"
    assert resp(Agente.receber_midia(t, audio("nao, deixa assim"))) =~ ~r/cancel/i
    assert status(cid)["status"] == "ATIVA"
    assert resp(Agente.receber_midia(t, audio("pausa a campanha"))) =~ "confirma"
    assert resp(Agente.receber_midia(t, audio("sim"))) =~ ~r/paus/i
    assert status(cid)["status"] == "PAUSADA"
  end

  test "audio com o pedido de campanha entra no fluxo normal (plano) e confirmar o plano por audio cria a campanha" do
    t = novo()
    conta = vincular(t)
    r = resp(Agente.receber_midia(t, audio(@pedido)))
    assert r =~ "confirma"
    refute r =~ ~r/por texto/i
    assert %{"status" => "aguardando_confirmacao"} = Plano.atual(t)
    assert Simulada.todas() |> Enum.filter(&(&1["conta_id"] == conta)) == []

    assert resp(Agente.receber_midia(t, audio("pode fazer sim"))) =~ "pausada"
    assert Simulada.todas() |> Enum.filter(&(&1["conta_id"] == conta)) |> length() == 1
    assert confirmacoes(t) == 1
  end

  test "limites e erros: duracao, tamanho, download, transcricao vazia ou com falha respondem sem alterar nada e sem custo", %{baixados: n} do
    {t, _pid, cid} = montar()
    antes = length(so_audio(t))

    r = resp(Agente.receber_midia(t, audio("x", seconds: 9_999)))
    assert r =~ ~r/longo/i and r =~ ~r/texto/i
    r = resp(Agente.receber_midia(t, audio("x", file_length: 50_000_000)))
    assert r =~ ~r/grande/i
    assert Agent.get(n, & &1) == 0, "limite barra ANTES de baixar"

    # tamanho real conferido depois do download (o cabecalho pode mentir)
    Application.put_env(:trafego, :audio, max_bytes: 100)
    assert resp(Agente.receber_midia(t, audio(String.duplicate("a", 500), file_length: 50))) =~ ~r/grande/i
    Application.delete_env(:trafego, :audio)

    assert resp(Agente.receber_midia(t, audio(:falha))) =~ ~r/nao consegui baixar/i
    assert resp(Agente.receber_midia(t, audio("   "))) =~ ~r/nao consegui entender/i
    antes = antes + 1

    # provedor de transcricao quebrado: mensagem amigavel, nada alterado
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.OpenAI)
    Application.put_env(:trafego, :openai, base_url: "http://127.0.0.1:1", timeout: 500)
    System.put_env("OPENAI_API_KEY", "sk-falsa")
    assert resp(Agente.receber_midia(t, audio("ativa"))) =~ ~r/nao consegui transcrever/i
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.Falso)

    assert status(cid)["status"] == "PAUSADA"
    assert Proposta.listar(t) == []
    assert length(so_audio(t)) == antes
    # o texto continua funcionando
    assert resp(Agente.processar(t, "ativa a campanha")) =~ "confirma"
  end

  test "custo da transcricao entra em R$ (cotacao) no custo_tokens e conta no teto de R$ por corretor" do
    t = novo()
    vincular(t)
    Application.put_env(:trafego, :preco_usd_por_minuto, %{"gpt-transcribe" => 0.0045})
    # 60 s a US$ 0,0045/min x R$ 5,00 = R$ 0,0225
    assert_in_delta Custo.brl_audio("gpt-transcribe", 60), 0.0225, 1.0e-6
    assert_in_delta Custo.brl_audio("gpt-transcribe", 30), 0.01125, 1.0e-6
    Application.put_env(:trafego, :preco_brl_por_min, %{"falso-audio" => 0.6})

    assert resp(Agente.receber_midia(t, audio("quero anunciar", seconds: 60))) =~ "Iara"
    assert [%{dados: d}] = so_audio(t)
    assert d["modelo"] == "falso-audio" and d["segundos"] == 60
    assert_in_delta d["custo_brl"], 0.6, 1.0e-6
    assert_in_delta TetoIA.gasto(t), Enum.sum(for e <- custos(t), do: e.dados["custo_brl"]), 1.0e-6

    # teto: aviso a 80%, bloqueio a 100%; bloqueado nao transcreve
    Application.put_env(:trafego, :teto_ia_brl, 0.7)
    on_exit(fn -> Application.put_env(:trafego, :teto_ia_brl, 1000.0) end)
    assert {:aviso, _} = TetoIA.status(t)
    # a transcricao ainda foi permitida (aviso), mas ao interpretar a fala o teto ja estourou: responde o teto, sem alterar nada
    assert resp(Agente.receber_midia(t, audio("outra", seconds: 60))) =~ ~r/teto de IA/i
    assert {:bloqueado, _} = TetoIA.status(t)
    n = length(custos(t))
    r = resp(Agente.receber_midia(t, audio("mais uma", seconds: 60)))
    assert r =~ ~r/teto de IA/i and r =~ "nada foi alterado" and not (r =~ "mais uma")
    assert length(custos(t)) == n
  end

  test "privacidade: nem o audio nem a transcricao vao para eventos, disco ou log; sobra so metadado", %{midia: midia} do
    t = novo()
    vincular(t)
    segredo = "meu cpf e um assunto pessoal xyzzy"
    log = ExUnit.CaptureLog.capture_log(fn -> assert is_binary(resp(Agente.receber_midia(t, audio(segredo)))) end)
    refute log =~ "xyzzy"
    todo = Registro.eventos(t) |> Enum.map(&Jason.encode!(&1.dados)) |> Enum.join(" ")
    refute todo =~ "xyzzy"
    refute inspect(Registro.ler(t, "trafego_atual")) =~ "xyzzy"
    assert Registro.eventos(t) |> Enum.any?(&(&1.tipo == "operacao" and &1.dados["ref"] == "audio_transcrito" and &1.dados["segundos"] == 6))
    # nada gravado em disco (o audio so existe em memoria)
    refute Path.wildcard(Path.join(midia, "**/*")) |> Enum.any?(&File.regular?/1)
  end

  test "adaptador OpenAI: multipart para /v1/audio/transcriptions com gpt-transcribe e pt; custo por minuto x cotacao" do
    pid = self()

    srv =
      HttpFalso.start(fn %{caminho: c, corpo: corpo, headers: h} ->
        cond do
          corpo =~ "FALHAR" ->
            {500, %{"error" => %{"message" => "boom"}}}

          true ->
            send(pid, {:pedido, c, h, corpo})
            {200, %{"text" => "ativa a campanha", "usage" => %{"type" => "duration", "seconds" => 6}}}
        end
      end)

    on_exit(fn -> :gen_tcp.close(srv.ls) end)
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.OpenAI)
    Application.put_env(:trafego, :openai, base_url: HttpFalso.url(srv), timeout: 2_000, transcricao: [modelo: "gpt-transcribe", idioma: "pt"])
    Application.put_env(:trafego, :preco_usd_por_minuto, %{"gpt-transcribe" => 0.0045})
    System.put_env("OPENAI_API_KEY", "sk-teste-audio")
    t = novo()
    vincular(t)

    assert {:ok, "ativa a campanha", %{"modelo" => "gpt-transcribe", "segundos" => 6}} =
             Trafego.IA.OpenAI.transcrever(<<1, 2, 3>>, %{mime: "audio/ogg; codecs=opus", segundos: 6})

    assert_receive {:pedido, caminho, headers, corpo}
    assert caminho =~ "/v1/audio/transcriptions"
    assert headers["authorization"] == "Bearer sk-teste-audio"
    assert headers["content-type"] =~ "multipart/form-data"
    assert corpo =~ "gpt-transcribe" and corpo =~ ~r/name="language"\r\n\r\npt/ and corpo =~ ~r/filename="audio\.ogg"/

    # a fala da Iara cai no texto fixo (o servidor falso so responde transcricao): o audio foi tratado como "ativa a campanha"
    assert resp(Agente.receber_midia(t, audio("qualquer"))) =~ ~r/nao ha campanha/i
    assert [%{dados: d}] = so_audio(t)
    assert d["modelo"] == "gpt-transcribe" and d["segundos"] == 6
    assert_in_delta d["custo_brl"], 6 / 60 * 0.0045 * 5.0, 1.0e-6
    assert d["cotacao"] == 5.0

    System.delete_env("OPENAI_API_KEY")
    assert {:error, :sem_chave_openai} = Trafego.IA.OpenAI.transcrever(<<1>>, %{mime: "audio/ogg", segundos: 1})
    System.put_env("OPENAI_API_KEY", "sk-teste-audio")
    assert {:error, {:http, 500}} = Trafego.IA.OpenAI.transcrever("FALHAR", %{mime: "audio/ogg", segundos: 1})
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.Falso)
  end

  test "pelo canal: nota de voz entregue ao laco recebe resposta com prefixo; so o chat proprio entra" do
    t = novo()
    vincular(t)
    {:ok, p} = Nucleo.Conexao.conectar(t)
    ref = Nucleo.Laco.canal(p)
    Canal.Simulado.injetar_midia(ref, :terceiro, audio("oi"))
    Canal.Simulado.injetar_midia(ref, :proprio, audio("quero anunciar um lancamento"))

    esperar = fn f -> Enum.reduce_while(1..50, false, fn _, _ -> if f.(), do: {:halt, true}, else: (Process.sleep(100); {:cont, false}) end) end
    assert esperar.(fn -> Enum.any?(Canal.Simulado.enviadas(ref), &(&1 =~ "Iara")) end)
    assert Enum.all?(Canal.Simulado.enviadas(ref), &String.starts_with?(&1, "[Iara] "))
    assert Canal.Simulado.ignoradas(ref) == 1

    # o filtro do Amarula ja entrega audio proprio ao laco como midia
    m = audio("x")
    assert {:midia, ^m} = Canal.Amarula.filtrar(m, fn _ -> true end)
    assert :ignorar = Canal.Amarula.filtrar(m, fn _ -> false end)
  end
end
