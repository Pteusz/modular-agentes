# Teste da etapa 5.2.3 (numero do WhatsApp vem do cadastro sem perguntar; a Iara fala por audio; prefixo "[Iara] ").
# Rodar: MIX_ENV=test mix test test/etapa523_test.exs
# REGRA: tenants tp523_* (so os proprios dados). IA pelo provedor Falso (a fala tambem: os bytes sao "FALA:" + texto);
# NENHUMA chamada real a OpenAI/Meta. O adaptador OpenAI de fala e testado contra servidor HTTP falso local.
defmodule Etapa523Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal, Laco, Conexao}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano, Iara, Voz, Cadastro, TetoIA, Banco}
  alias Trafego.Plataforma.Simulada

  @completo "pedido objetivo vender; imovel Torre Sul; destino whatsapp; pixel 998877; publico casais zona sul; diario R$ 50; teto R$ 500; " <>
              "janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15"
  @chaves ~w(cotacao_usd_brl teto_ia_brl preco_brl_por_min notificar baixar_midia midia_dir provedor_ia numero_cadastrado openai)a
  @aviso "Montei o plano, olha ai."

  # provedor com fala que falha (a transcricao e as falas continuam as do Falso)
  defmodule FalaQuebrada do
    @behaviour Trafego.IA
    defdelegate chamar(f, t, e), to: Trafego.IA.Falso
    defdelegate transcrever(b, m), to: Trafego.IA.Falso
    defdelegate turno(f, e), to: Trafego.IA.Falso
    def sintetizar(_), do: {:error, {:http, 500}}
  end

  # provedor sem fala nenhuma (callback opcional ausente)
  defmodule SemFala do
    @behaviour Trafego.IA
    defdelegate chamar(f, t, e), to: Trafego.IA.Falso
    defdelegate transcrever(b, m), to: Trafego.IA.Falso
    defdelegate turno(f, e), to: Trafego.IA.Falso
  end

  # canal que so entende texto (sem enviar_audio/3)
  defmodule CanalSoTexto do
    @behaviour Nucleo.Canal
    defdelegate iniciar(t, d, o), to: Nucleo.Canal.Simulado
    defdelegate enviar_texto(r, t), to: Nucleo.Canal.Simulado
  end

  setup_all do
    Registro.migrar!()
    Banco.migrar!()

    Postgrex.query!(
      Registro,
      "CREATE TABLE IF NOT EXISTS ge_corretores (id bigserial PRIMARY KEY, equipe text NOT NULL, tenant_id text NOT NULL UNIQUE, numero text, status text NOT NULL DEFAULT 'ativo')",
      []
    )

    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}
    midia = Path.join(System.tmp_dir!(), "midia_tp523_#{System.unique_integer([:positive])}")
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
    Application.put_env(:trafego, :numero_cadastrado, fn _ -> "(11) 97420-8400" end)
    Application.delete_env(:trafego, :preco_brl_por_min)
    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp523\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp523\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM ge_corretores WHERE tenant_id LIKE 'tp523\\_%'", [])
  end

  defp vincular(t, canal) do
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, canal, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    conta
  end

  defp tenant_pronto(canal \\ Canal.Simulado), do: (t = "tp523_#{System.unique_integer([:positive])}"; vincular(t, canal); t)
  defp msgs({:ok, r}), do: List.wrap(r)
  defp dizer(t, texto), do: t |> Agente.processar_mensagens(texto) |> msgs()
  defp junto(l), do: Enum.join(l, "\n")
  defp esperar(f, n \\ 80), do: f.() || (n > 0 && (Process.sleep(50); esperar(f, n - 1)))

  defp audio(fala) do
    media = struct(Amarula.Content.Media, kind: :audio, mimetype: "audio/ogg; codecs=opus", seconds: 6, file_length: 9_000, url: fala)
    %Amarula.Msg{channel: :teste, type: :media, raw: nil, content: media}
  end

  defp custos_voz(t), do: Banco.q("SELECT dados FROM eventos WHERE tenant_id = $1 AND tipo = 'custo_tokens' AND dados->>'ref' = 'voz' ORDER BY id", [t]).rows |> Enum.map(&hd/1)

  # ------------------------------------------------------------------------------------------------------------------
  # 1) numero do cadastro, sem perguntar
  test "o numero vem do cadastro: nada de pergunta, ficha preenchida e marcada como do cadastro" do
    t = tenant_pronto()
    l = dizer(t, @completo)
    assert hd(l) =~ "Montei o plano" and length(l) == 5
    refute junto(l) =~ ~r/numero do WhatsApp/i
    plano = Plano.atual(t)
    assert plano["numero"] == "5511974208400"
    assert plano["ficha"]["origem"]["numero"] == "cadastro"
    assert junto(l) =~ "do seu cadastro" and junto(l) =~ "97420-8400"
    assert plano["status"] == "aguardando_confirmacao"
  end

  test "o numero e normalizado (55 + DDD + numero, so digitos), venha como vier no cadastro" do
    for {bruto, esperado} <- [{"11974208400", "5511974208400"}, {"+55 (21) 98877-6655", "5521988776655"}, {"5511974208400", "5511974208400"}] do
      Application.put_env(:trafego, :numero_cadastrado, fn _ -> bruto end)
      assert Cadastro.numero("tp523_x") == esperado
    end

    # sem DDD / ilegivel = como se nao houvesse
    for ruim <- ["974208400", "abc", "", nil] do
      Application.put_env(:trafego, :numero_cadastrado, fn _ -> ruim end)
      assert Cadastro.numero("tp523_x") == nil
    end
  end

  test "so se o cadastro nao tem numero ela pergunta (uma vez); o numero dito vale e vem como do corretor" do
    Application.put_env(:trafego, :numero_cadastrado, fn _ -> nil end)
    t = tenant_pronto()
    l = dizer(t, @completo)
    assert junto(l) =~ ~r/numero do WhatsApp/i
    refute junto(l) =~ "Montei o plano"
    l2 = dizer(t, "numero 21988776655")
    assert hd(l2) =~ "Montei o plano"
    plano = Plano.atual(t)
    assert plano["numero"] == "5521988776655" and plano["ficha"]["origem"]["numero"] == "corretor"
    refute junto(l2) =~ "do seu cadastro"
  end

  test "\"usa outro numero\" vale so para aquele plano: o cadastro continua sendo o destino dos proximos" do
    t = tenant_pronto()
    dizer(t, @completo)
    assert Plano.atual(t)["numero"] == "5511974208400"
    l = dizer(t, "muda; numero 21988776655")
    assert Plano.atual(t)["numero"] == "5521988776655"
    assert Plano.atual(t)["ficha"]["origem"]["numero"] == "corretor"
    assert is_list(l)
    assert Cadastro.numero(t) == "5511974208400"
    t2 = tenant_pronto()
    dizer(t2, @completo)
    assert Plano.atual(t2)["numero"] == "5511974208400"
  end

  test "fonte real: ge_corretores (ativo) e, na falta dele, o numero pareado; desativado nao conta" do
    Application.delete_env(:trafego, :numero_cadastrado)
    t = "tp523_banco_#{System.unique_integer([:positive])}"
    assert Cadastro.numero(t) == nil
    n = "11" <> (for _ <- 1..9, into: "", do: Integer.to_string(Enum.random(0..9)))
    Postgrex.query!(Registro, "INSERT INTO ge_corretores (equipe, tenant_id, numero) VALUES ('tp523_eq', $1, $2)", [t, n])
    assert Cadastro.numero(t) == "55" <> n
    Postgrex.query!(Registro, "UPDATE ge_corretores SET status = 'desativado' WHERE tenant_id = $1", [t])
    assert Cadastro.numero(t) == nil
    Nucleo.Canal.Estado.publicar_numero(t, "5521988776655")
    assert Cadastro.numero(t) == "5521988776655"
  end

  # ------------------------------------------------------------------------------------------------------------------
  # 2) prefixo
  test "prefixo [Iara] no WhatsApp (laco) e no painel; eco continua com [agente]" do
    assert Contrato.prefixo() == "[Iara] "
    assert Laco.prefixo_padrao() == "[agente] "
    t = tenant_pronto()
    {:ok, p} = Conexao.conectar(t)
    ref = Laco.canal(p)
    Canal.Simulado.injetar(ref, :proprio, @completo)
    assert esperar(fn -> Enum.any?(Canal.Simulado.enviadas(ref), &(&1 =~ "Voce confirma?")) end)
    env = Canal.Simulado.enviadas(ref)
    assert Enum.all?(env, &String.starts_with?(&1, "[Iara] ")) and Canal.Simulado.audios(ref) == []
    refute Enum.any?(env, &String.starts_with?(&1, "Iara: "))
    Conexao.encerrar(t)

    t2 = tenant_pronto()
    dizer(t2, @completo)
    assert %{"prefixo" => "[Iara]"} = Trafego.Painel.plano_aguardando(t2)
  end

  # ------------------------------------------------------------------------------------------------------------------
  # 3) audio
  test "a lista de perguntas diz que da para mandar audio" do
    Application.put_env(:trafego, :numero_cadastrado, fn _ -> nil end)
    t = tenant_pronto()
    dizer(t, "quero anunciar")
    assert junto(dizer(t, "pedido objetivo vender")) =~ ~r/audio/i
  end

  test "regra de uso: audio -> falas conversacionais curtas em voz; dados para conferir continuam em texto" do
    t = tenant_pronto()

    {:ok, r} =
      Voz.aplicar(
        t,
        {:ok, ["Oi, tudo certo por aqui?", "Montei o plano p1 pra Torre Sul. Verba: R$ 50,00 por dia.", "Texto do anuncio: \"Apartamento novo\".", "Voce confirma?"]},
        "audio"
      )

    assert [{:audio, "FALA:Oi, tudo certo por aqui?", op, "Oi, tudo certo por aqui?"}, {:audio, "FALA:" <> @aviso, _, @aviso}, plano, anuncio, {:audio, "FALA:Voce confirma?", _, _}] = r
    assert op[:mime] =~ "opus" and op[:segundos] >= 1
    assert plano =~ "Montei o plano p1" and anuncio =~ "Apartamento novo"

    # resposta unica vira um elemento so; dado (numero, R$, id, link) nunca vira voz
    assert {:ok, {:audio, "FALA:Fechado, ja te aviso.", _, _}} = Voz.aplicar(t, {:ok, "Fechado, ja te aviso."}, "audio")
    for dado <- ["Campanha camp_1 criada, PAUSADA.", "Verba de R$ 50 por dia.", "Veja https://x.com/a", "Sao 5 mensagens", String.duplicate("a ", 150)] do
      assert {:ok, ^dado} = Voz.aplicar(t, {:ok, dado}, "audio")
    end

    # texto -> texto; erro passa direto
    assert {:ok, ["Oi, tudo certo por aqui?", "Voce confirma?"]} = Voz.aplicar(t, {:ok, ["Oi, tudo certo por aqui?", "Voce confirma?"]}, "texto")
    assert {:error, :x} = Voz.aplicar(t, {:error, :x}, "audio")
  end

  test "pelo laco: audio recebido volta nota de voz (sem prefixo) e plano em texto com [Iara]; texto recebido volta so texto" do
    t = tenant_pronto()
    {:ok, p} = Conexao.conectar(t)
    ref = Laco.canal(p)
    Canal.Simulado.injetar_midia(ref, :proprio, audio(@completo))
    assert esperar(fn -> Enum.any?(Canal.Simulado.enviadas(ref), &(&1 =~ "Montei o plano")) and Enum.any?(Canal.Simulado.audios(ref), fn {b, _} -> b =~ "olha ai" end) end),
           inspect({Canal.Simulado.sequencia(ref), Nucleo.Registro.eventos_recentes(t, "audio_falhou", 600)})
    seq = Canal.Simulado.sequencia(ref)
    {_, i} = seq |> Enum.with_index() |> Enum.find(fn {x, _} -> x == {:audio, "FALA:" <> @aviso} end)
    assert {:texto, "[Iara] Montei o plano" <> _} = Enum.at(seq, i + 1)
    audios = Canal.Simulado.audios(ref)
    assert Enum.all?(audios, fn {b, o} -> String.starts_with?(b, "FALA:") and not (b =~ "[Iara]") and o[:mime] =~ "opus" end)
    assert Enum.all?(Canal.Simulado.enviadas(ref), &String.starts_with?(&1, "[Iara] "))
    # dados do plano seguem em texto: nenhuma nota de voz leva numero
    refute Enum.any?(audios, fn {b, _} -> b =~ ~r/\d/ end)
    assert Enum.any?(Canal.Simulado.enviadas(ref), &(&1 =~ "R$ 50"))
    Conexao.encerrar(t)

    t2 = tenant_pronto()
    {:ok, p2} = Conexao.conectar(t2)
    ref2 = Laco.canal(p2)
    Canal.Simulado.injetar(ref2, :proprio, @completo)
    assert esperar(fn -> Enum.any?(Canal.Simulado.enviadas(ref2), &(&1 =~ "Voce confirma?")) end)
    assert Canal.Simulado.audios(ref2) == []
    Conexao.encerrar(t2)
  end

  test "preferencia explicita: \"responde em audio\" / \"so texto\" fica no perfil e manda sobre a origem" do
    # 5.3: a preferencia nao sai mais de regex; o modelo a grava pela ferramenta `lembrar` (lista fechada de chaves)
    on_exit(fn -> Application.delete_env(:trafego, :roteiro_ia) end)
    t = tenant_pronto()
    assert Iara.voz_preferida(t) == nil
    Application.put_env(:trafego, :roteiro_ia, [{:chamar, "lembrar", %{"chave" => "preferencia_voz", "valor" => "audio"}}, {:texto, "Fechado, daqui pra frente respondo em audio."}])
    assert junto(dizer(t, "responde em audio")) =~ ~r/audio/i
    assert Iara.perfil(t)["voz"] == "audio" and Iara.voz_preferida(t) == "audio"
    # persiste: agora ate a mensagem escrita volta em voz
    assert {:ok, {:audio, _, _, "Voce confirma?"}} = Voz.aplicar(t, {:ok, "Voce confirma?"}, "texto")

    Application.put_env(:trafego, :roteiro_ia, [{:chamar, "lembrar", %{"chave" => "preferencia_voz", "valor" => "texto"}}, {:texto, "Combinado, so texto."}])
    assert junto(dizer(t, "so texto")) =~ ~r/texto/i
    assert Iara.perfil(t)["voz"] == "texto"
    # texto manda ate sobre um audio recebido
    assert {:ok, ["Voce confirma?"]} = Voz.aplicar(t, {:ok, ["Voce confirma?"]}, "audio")
    assert {:ok, "Voce confirma?"} = Voz.aplicar(t, {:ok, "Voce confirma?"}, "audio")
    # a preferencia nao e dos outros
    t2 = tenant_pronto()
    assert {:ok, {:audio, _, _, _}} = Voz.aplicar(t2, {:ok, "Voce confirma?"}, "audio")
  end

  test "falha na sintese nunca silencia: cai para texto (erro do provedor, provedor sem voz, canal sem audio)" do
    t = tenant_pronto()
    entrada = ["Oi, tudo certo por aqui?", "Montei o plano p1 pra Torre Sul.", "Voce confirma?"]

    for prov <- [FalaQuebrada, SemFala] do
      Application.put_env(:trafego, :provedor_ia, prov)
      assert {:ok, ^entrada} = Voz.aplicar(t, {:ok, entrada}, "audio")
    end

    assert custos_voz(t) == []

    # pelo laco com o provedor quebrado: tudo sai em texto, com prefixo
    Application.put_env(:trafego, :provedor_ia, FalaQuebrada)
    t2 = tenant_pronto()
    {:ok, p} = Conexao.conectar(t2)
    ref = Laco.canal(p)
    Canal.Simulado.injetar_midia(ref, :proprio, audio(@completo))
    assert esperar(fn -> Enum.any?(Canal.Simulado.enviadas(ref), &(&1 =~ "Voce confirma?")) end)
    assert Canal.Simulado.audios(ref) == [] and Enum.all?(Canal.Simulado.enviadas(ref), &String.starts_with?(&1, "[Iara] "))
    Conexao.encerrar(t2)

    # canal que nao tem enviar_audio: a fala sai como texto, com prefixo
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.Falso)
    t3 = tenant_pronto(CanalSoTexto)
    {:ok, p3} = Conexao.conectar(t3)
    ref3 = Laco.canal(p3)
    Canal.Simulado.injetar_midia(ref3, :proprio, audio(@completo))
    assert esperar(fn -> Enum.any?(Canal.Simulado.enviadas(ref3), &(&1 =~ "Voce confirma?")) end)
    assert Canal.Simulado.audios(ref3) == [] and Enum.all?(Canal.Simulado.enviadas(ref3), &String.starts_with?(&1, "[Iara] "))
    assert Enum.any?(Canal.Simulado.enviadas(ref3), &(&1 =~ "Montei o plano"))
    Conexao.encerrar(t3)
  end

  test "custo da voz entra no custo_tokens e no teto; teto bloqueado = texto, sem parar a Iara" do
    # R$ 1,00 por segundo estimado (15 caracteres = 1 s) e teto de R$ 3,00
    Application.put_env(:trafego, :preco_brl_por_min, %{"falso-voz" => 60.0})
    Application.put_env(:trafego, :teto_ia_brl, 3.0)
    t = tenant_pronto()
    fala = "Oi, tudo certo por aqui?"
    assert {:ok, [a1, a2, "Voce confirma?" = ultimo]} = Voz.aplicar(t, {:ok, [fala, fala, "Voce confirma?"]}, "audio")
    assert {:audio, _, _, ^fala} = a1
    assert {:audio, _, _, ^fala} = a2
    assert ultimo == "Voce confirma?"

    [c1, c2] = custos_voz(t)
    assert c1["modelo"] == "falso-voz" and c1["caracteres"] == String.length(fala) and c1["segundos"] == 2
    assert_in_delta c1["custo_brl"], 2.0, 1.0e-6
    assert_in_delta TetoIA.gasto(t), 4.0, 1.0e-6
    assert c2["custo_brl"] == c1["custo_brl"]
    assert {:bloqueado, _} = TetoIA.status(t)

    # bloqueado: nem tenta falar; a resposta sai em texto e a conversa segue
    assert {:ok, ["Oi, tudo certo por aqui?"]} = Voz.aplicar(t, {:ok, ["Oi, tudo certo por aqui?"]}, "audio")
    assert length(custos_voz(t)) == 2
    l = dizer(t, "oi")
    assert is_list(l) and Enum.all?(l, &is_binary/1)

    # a custo da voz de outro corretor nao conta no teto deste
    t2 = tenant_pronto()
    assert :ok = TetoIA.status(t2)
  end

  test "adaptador OpenAI: POST /v1/audio/speech com gpt-4o-mini-tts, voz feminina, instrucoes de tom e opus; custo estimado por duracao" do
    pid = self()

    srv =
      HttpFalso.start(fn %{caminho: c, corpo: corpo, headers: h} ->
        if corpo =~ "FALHAR" do
          {500, %{"error" => %{"message" => "boom"}}}
        else
          send(pid, {:pedido, c, h, Jason.decode!(corpo)})
          {200, {:bin, "OggS-bytes-de-teste"}}
        end
      end)

    on_exit(fn -> :gen_tcp.close(srv.ls) end)
    System.put_env("OPENAI_API_KEY", "sk-teste-voz")
    Application.put_env(:trafego, :openai, base_url: HttpFalso.url(srv), timeout: 2_000)

    assert {:ok, "OggS-bytes-de-teste", uso} = Trafego.IA.OpenAI.sintetizar("Oi, tudo certo por aqui?")
    assert uso["modelo"] == "gpt-4o-mini-tts" and uso["mime"] =~ "ogg" and uso["mime"] =~ "opus" and uso["caracteres"] == 24 and uso["segundos"] == 2

    assert_receive {:pedido, "/v1/audio/speech", headers, corpo}
    assert headers["authorization"] == "Bearer sk-teste-voz"
    assert %{"model" => "gpt-4o-mini-tts", "voice" => voz, "input" => "Oi, tudo certo por aqui?", "response_format" => "opus", "instructions" => instr} = corpo
    assert voz in ~w(marin cedar coral nova shimmer sage)
    assert instr =~ ~r/portugues do Brasil/i and instr =~ ~r/feminina/i and instr =~ ~r/calorosa/i and instr =~ ~r/objetiva/i

    # custo em R$: US$/min (tabela) x cotacao; duracao estimada por caracteres
    assert_in_delta Trafego.Custo.brl_audio("gpt-4o-mini-tts", 60), 0.015 * 5.0, 1.0e-6

    assert {:error, {:http, 500}} = Trafego.IA.OpenAI.sintetizar("FALHAR")
    System.delete_env("OPENAI_API_KEY")
    assert {:error, :sem_chave_openai} = Trafego.IA.OpenAI.sintetizar("oi")
    System.put_env("OPENAI_API_KEY", "sk-teste-voz")
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.Falso)
    System.delete_env("OPENAI_API_KEY")
  end

  test "versoes: nucleo 1.5.1 (canal com enviar_audio opcional) e trafego 1.11.0" do
    assert to_string(Application.spec(:nucleo, :vsn)) == "1.5.1"
    assert to_string(Application.spec(:trafego, :vsn)) == "1.11.0"
    assert {:enviar_audio, 3} in Nucleo.Canal.behaviour_info(:optional_callbacks)
    assert {:enviar_audio, 3} in Nucleo.Canal.behaviour_info(:callbacks)
    Code.ensure_loaded!(Nucleo.Canal.Simulado)
    Code.ensure_loaded!(Nucleo.Canal.Amarula)
    assert function_exported?(Nucleo.Canal.Simulado, :enviar_audio, 3) and function_exported?(Nucleo.Canal.Amarula, :enviar_audio, 3)
  end
end
