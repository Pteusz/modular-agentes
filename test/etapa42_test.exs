# Teste geral da etapa 4.2 (Meta e OpenAI reais atras dos contratos; aqui a parte AUTOMATICA com servidores HTTP falsos locais).
# O ponta a ponta REAL (conta de teste, tudo pausado) so roda depois da aprovacao do Mateus: ver test/etapa42_real.md.
# Rodar: MIX_ENV=test mix test
defmodule Etapa42Test do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Acesso, Agente, Cifra, Criativo, Custo, Plano, Verificador}

  @token "EAAFAKETOKEN123456"
  @chave_openai "sk-teste-FAKE-0001"
  @confirma "so pra confirmar se entendi, posso fazer isso mesmo?"
  @chaves_env ~w(OPENAI_API_KEY TRAFEGO_COTACAO_USD_BRL)
  @app_keys [:plataforma, :provedor_ia, :meta, :openai, :preco_usd_por_milhao, :cotacao_usd_brl, :midia_dir]

  @plano_modelo %{
    "destino" => "site", "url" => "https://corretor.com.br/lancamento", "pixel" => "998877", "numero" => nil, "formulario" => nil,
    "imovel" => nil, "publico" => "casais 30-45 zona sul", "criativo" => %{"midia" => "foto1.png", "texto" => "Apartamento novo na zona sul"},
    "orcamento_diario" => 5000, "teto_total" => 50_000, "janela" => %{"inicio" => "2026-11-01", "fim" => "2026-11-30"},
    "meta" => %{"resultados" => 20, "custo_max" => 1500},
    # modelo mal-comportado tentando impor conta: o dominio ignora
    "conta_id" => "act_222"
  }

  # ---------- Meta falsa (Graph API v26.0)
  defp meta(est, %{metodo: m, caminho: "/v26.0/" <> resto, headers: h, corpo: corpo}) do
    if h["authorization"] != "Bearer " <> Agent.get(est, & &1.token) do
      {401, %{"error" => %{"message" => "Invalid OAuth access token", "type" => "OAuthException", "code" => 190}}}
    else
      rota(est, m, String.split(resto, "/"), corpo)
    end
  end

  defp meta(_, _), do: {404, %{"error" => %{"message" => "versao errada", "code" => 2500}}}

  defp erro100, do: {400, %{"error" => %{"message" => "Unsupported get request", "type" => "GraphMethodException", "code" => 100}}}

  defp rota(_, "GET", ["PAG1"], _), do: {200, %{"id" => "PAG1", "name" => "Pagina"}}
  defp rota(_, "GET", ["IG1"], _), do: {200, %{"id" => "IG1", "username" => "corretor"}}
  defp rota(_, "GET", [c], _) when c in ["act_111", "act_222"], do: {200, %{"id" => c, "account_id" => String.trim_leading(c, "act_"), "account_status" => 1, "currency" => "BRL"}}

  defp rota(est, "GET", [c, "campaigns"], _) when c in ["act_111", "act_222"] do
    dados = Agent.get(est, fn s -> for {_, %{"kind" => "campaign", "conta" => ^c} = o} <- s.objs, do: Map.take(o, ~w(id name status)) end)
    {200, %{"data" => dados}}
  end

  defp rota(est, "GET", [id], _) do
    Agent.get(est, fn s ->
      case s.objs[id] do
        %{"kind" => "campaign"} = c ->
          adsets =
            for {_, %{"kind" => "adset", "campaign_id" => ^id} = a} <- s.objs do
              ads =
                for {_, %{"kind" => "ad", "adset_id" => aid} = ad} <- s.objs, aid == a["id"] do
                  cr = s.objs[Jason.decode!(ad["creative"])["creative_id"]]
                  Map.put(ad, "creative", %{"id" => cr["id"], "name" => cr["name"], "object_story_spec" => Jason.decode!(cr["object_story_spec"])})
                end

              a |> Map.put("targeting", Jason.decode!(a["targeting"])) |> Map.put("promoted_object", Jason.decode!(a["promoted_object"])) |> Map.put("ads", %{"data" => ads})
            end

          {200, Map.merge(c, %{"account_id" => String.trim_leading(c["conta"], "act_"), "adsets" => %{"data" => adsets}})}

        _ ->
          erro100()
      end
    end)
  end

  defp rota(est, "POST", [conta, "adimages"], corpo) when conta in ["act_111", "act_222"] do
    nome = (Regex.run(~r/filename="([^"]+)"/, corpo) || [nil, "arquivo"]) |> List.last()
    Agent.update(est, fn s -> %{s | seq: s.seq + 1} end)
    {200, %{"images" => %{nome => %{"hash" => "HASH_" <> nome}}}}
  end

  # limite minimo de gasto da campanha (R$300), como a Graph real: erro generico + subcodigo e mensagem ao usuario
  defp rota(est, "POST", [conta, "campaigns"], corpo) when conta in ["act_111", "act_222"] do
    if String.to_integer(URI.decode_query(corpo)["spend_cap"] || "30000") < 30_000 do
      {400, %{"error" => %{"message" => "Invalid parameter", "code" => 100, "error_subcode" => 2_446_307, "error_user_msg" => "O limite de gastos da campanha precisa ser pelo menos R$300,00 para essa moeda."}}}
    else
      criar_obj(est, conta, "campaigns", corpo)
    end
  end

  defp rota(est, "POST", [conta, "adsets"], corpo) when conta in ["act_111", "act_222"] do
    if corpo =~ "PAGSEMWA" do
      {400, %{"error" => %{"message" => "Invalid parameter", "code" => 100, "error_subcode" => 2_446_886, "error_user_msg" => "Sua Pagina nao esta vinculada a uma conta do WhatsApp."}}}
    else
      criar_obj(est, conta, "adsets", corpo)
    end
  end

  defp rota(est, "POST", [conta, borda], corpo) when conta in ["act_111", "act_222"] and borda in ~w(adcreatives ads), do: criar_obj(est, conta, borda, corpo)

  defp rota(est, "POST", [id], corpo) do
    Agent.get_and_update(est, fn s ->
      case s.objs[id] do
        nil -> {erro100(), s}
        o -> {{200, %{"success" => true}}, %{s | objs: Map.put(s.objs, id, Map.merge(o, URI.decode_query(corpo)))}}
      end
    end)
  end

  defp rota(_, _, _, _), do: erro100()

  defp criar_obj(est, conta, borda, corpo) do
    kind = %{"campaigns" => "campaign", "adsets" => "adset", "adcreatives" => "creative", "ads" => "ad"}[borda]
    pref = %{"campaign" => "c", "adset" => "s", "creative" => "cr", "ad" => "a"}[kind]

    id =
      Agent.get_and_update(est, fn s ->
        n = s.seq + 1
        id = "#{pref}#{n}"
        obj = corpo |> URI.decode_query() |> Map.merge(%{"id" => id, "kind" => kind, "conta" => conta})
        {id, %{s | seq: n, objs: Map.put(s.objs, id, obj)}}
      end)

    {200, %{"id" => id}}
  end

  defp meta_injetar(est, id, attrs), do: Agent.update(est, fn s -> %{s | objs: Map.update!(s.objs, id, &Map.merge(&1, attrs))} end)
  defp meta_achar(est, kind, campo, valor), do: Agent.get(est, fn s -> Enum.find_value(s.objs, fn {id, o} -> o["kind"] == kind and o[campo] == valor && id end) end)

  # ---------- OpenAI falsa (Responses API)
  defp openai(%{corpo: corpo}) do
    b = Jason.decode!(corpo)
    nome = get_in(b, ["text", "format", "name"])
    usuario = b["input"] |> List.last() |> Map.fetch!("content") |> Jason.decode!()

    cond do
      inspect(usuario) =~ "FALHAR-OPENAI" -> {500, %{"error" => %{"message" => "boom"}}}
      nome == "planejar" -> resposta(b, @plano_modelo)
      nome == "confirmar" -> resposta(b, %{"decisao" => decisao(usuario["resposta_do_corretor"])})
    end
  end

  defp decisao(t) do
    cond do
      t =~ "ENUM-INVALIDO" -> "quem sabe"
      t =~ ~r/talvez|nao sei/ -> "ambiguo"
      t =~ ~r/\bnao\b/ -> "nao"
      t =~ ~r/\bsim\b/ -> "sim"
      true -> "ambiguo"
    end
  end

  defp resposta(b, saida) do
    {200,
     %{
       "id" => "resp_1", "model" => b["model"] <> "-2026-01-01",
       "output" => [%{"type" => "reasoning", "summary" => []}, %{"type" => "message", "content" => [%{"type" => "output_text", "text" => Jason.encode!(saida)}]}],
       "usage" => %{"input_tokens" => 1000, "output_tokens" => 500}
     }}
  end

  # ---------- criativos sinteticos
  defp pad(b), do: b <> :binary.copy(<<0>>, 3000)
  defp png(w, h), do: pad(<<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, 8, 2, 0, 0, 0, 0::32>>)
  defp jpeg(w, h), do: pad(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xC0, 0, 17, 8, h::16, w::16, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1>>)
  defp box(tipo, p), do: <<byte_size(p) + 8::32, tipo::binary, p::binary>>

  defp mp4(w, h) do
    tkhd = box("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::32, 0::64, 0::64, 0::288, w::16, 0::16, h::16, 0::16>>)
    pad(box("ftyp", "isom" <> <<0::32>> <> "isom") <> box("moov", box("trak", tkhd)))
  end

  setup_all do
    Registro.migrar!()
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tm%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tm%'", [])

    {:ok, est} = Agent.start_link(fn -> %{token: @token, objs: %{}, seq: 0} end)
    msrv = HttpFalso.start(&meta(est, &1))
    osrv = HttpFalso.start(&openai/1)
    midia = Path.join(System.tmp_dir!(), "midia_tm_#{System.unique_integer([:positive])}")

    salvo = for k <- @app_keys, do: {k, Application.fetch_env(:trafego, k)}
    salvo_env = for k <- @chaves_env, do: {k, System.get_env(k)}

    Application.put_env(:trafego, :plataforma, Trafego.Plataforma.Meta)
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.OpenAI)
    Application.put_env(:trafego, :meta, base_url: HttpFalso.url(msrv), versao: "v26.0")
    Application.put_env(:trafego, :openai, base_url: HttpFalso.url(osrv), modelos: %{pequena: "modelo-pequena-x", media: "modelo-media-x"}, esforco: %{pequena: "none", media: "low"})
    Application.put_env(:trafego, :preco_usd_por_milhao, %{"modelo-media-x" => {1.0, 4.0}, "modelo-pequena-x" => {0.5, 2.0}})
    Application.put_env(:trafego, :cotacao_usd_brl, 5.0)
    Application.put_env(:trafego, :midia_dir, midia)
    System.put_env("OPENAI_API_KEY", @chave_openai)

    on_exit(fn ->
      for {k, v} <- salvo, do: (case v do {:ok, x} -> Application.put_env(:trafego, k, x); :error -> Application.delete_env(:trafego, k) end)
      for {k, v} <- salvo_env, do: (if v, do: System.put_env(k, v), else: System.delete_env(k))
      HttpFalso.parar(msrv)
      HttpFalso.parar(osrv)
      File.rm_rf(midia)
    end)

    {:ok, est: est, msrv: msrv, osrv: osrv, midia: midia}
  end

  defp resp({:ok, r}), do: r
  defp evs(t, tipo), do: for(%{tipo: ^tipo} = e <- Registro.eventos(t), do: e.dados)
  defp tudo(t), do: Postgrex.query!(Registro, "SELECT valor::text FROM estado WHERE tenant_id=$1 UNION ALL SELECT dados::text FROM eventos WHERE tenant_id=$1", [t]).rows |> Enum.join(" ")
  defp posts(srv), do: Enum.filter(HttpFalso.pedidos(srv), &(&1.metodo == "POST"))

  test "meta e openai (servidores falsos): cifra, validacao, campanha pausada, verificador, conta do tenant, custo, criativo, midia", ctx do
    %{est: est, msrv: msrv, osrv: osrv, midia: midia} = ctx
    u = System.unique_integer([:positive])
    [ta, tb, tc, td] = for l <- ~w(a b c d), do: "tm_#{l}#{u}"
    ok = %{"conta_id" => "act_111", "pagina_id" => "PAG1", "instagram_id" => "IG1", "token" => @token}
    pedido = "quero anunciar o lancamento"

    log =
      capture_log([level: :debug], fn ->
        # ---- 1. cifra: AES-256-GCM, chave so em env, id de chave, presa ao tenant, mascaramento
        {:ok, env1} = Cifra.cifrar(ta, @token)
        refute env1 =~ @token
        assert Cifra.chave_id(env1) == "t1"
        assert {:ok, @token} = Cifra.decifrar(ta, env1)
        assert {:error, _} = Cifra.decifrar(tb, env1)
        meio = div(String.length(env1), 2)
        troca = if String.at(env1, meio) == "A", do: "B", else: "A"
        assert {:error, _} = Cifra.decifrar(ta, String.slice(env1, 0, meio) <> troca <> String.slice(env1, (meio + 1)..-1//1))
        assert Cifra.mascarar(@token) == "****3456"

        chaves = System.get_env("TRAFEGO_CIFRA_CHAVES")
        atual = System.get_env("TRAFEGO_CIFRA_ATUAL")
        System.put_env("TRAFEGO_CIFRA_CHAVES", chaves <> ",t2:" <> Base.encode64(:binary.copy(<<9>>, 32)))
        System.put_env("TRAFEGO_CIFRA_ATUAL", "t2")
        {:ok, env2} = Cifra.cifrar(ta, "outro")
        assert Cifra.chave_id(env2) == "t2"
        assert {:ok, @token} = Cifra.decifrar(ta, env1)
        System.put_env("TRAFEGO_CIFRA_CHAVES", chaves)
        System.put_env("TRAFEGO_CIFRA_ATUAL", atual)
        assert {:error, _} = Cifra.decifrar(ta, env2)
        System.delete_env("TRAFEGO_CIFRA_ATUAL")
        assert {:error, :sem_chave_de_cifra} = Cifra.cifrar(ta, "x")
        System.put_env("TRAFEGO_CIFRA_ATUAL", atual)

        # ---- 2. cadastro valida na Meta: pagina, conta de anuncio e Instagram
        for t <- [ta, tb, tc, td], do: assert({:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{}))
        assert {:error, :token_invalido} = Acesso.cadastrar(ta, %{ok | "token" => "EAAERRADO"})
        assert {:error, {:inacessivel, :pagina}} = Acesso.cadastrar(ta, %{ok | "pagina_id" => "PAGX"})
        assert {:error, {:inacessivel, :conta}} = Acesso.cadastrar(ta, %{ok | "conta_id" => "act_999"})
        assert {:error, {:inacessivel, :pagina}} = Acesso.cadastrar(ta, Map.delete(ok, "pagina_id"))
        assert Acesso.conta(ta) == nil
        # Instagram e opcional: nao alcancado ou ausente NAO bloqueia, vira aviso e o id nao fica no registro
        assert {:ok, "act_111"} = Acesso.cadastrar(ta, %{ok | "instagram_id" => "IGX"})
        sem_ig = Registro.ler(ta, "trafego_conta")
        assert sem_ig["avisos"] == ["instagram_nao_ligado"] and not Map.has_key?(sem_ig, "instagram_id")
        assert {:ok, "act_111"} = Acesso.cadastrar(ta, Map.delete(ok, "instagram_id"))
        refute Map.has_key?(Registro.ler(ta, "trafego_conta"), "instagram_id")
        assert {:error, :token_invalido} = Acesso.cadastrar(ta, %{ok | "instagram_id" => "IGX", "token" => "EAAERRADO"})
        assert {:ok, "act_111"} = Acesso.cadastrar(ta, ok)
        for t <- [tb, tc, td], do: assert({:ok, "act_222"} = Acesso.cadastrar(t, %{ok | "conta_id" => "act_222"}))

        c = Registro.ler(ta, "trafego_conta")
        assert %{"token_cifrado" => _, "chave_id" => "t1", "status" => "ok", "conta_id" => "act_111"} = c
        refute Map.has_key?(c, "token")
        refute Jason.encode!(c) =~ @token
        assert Acesso.mascarado(ta) == %{"conta_id" => "act_111", "pagina_id" => "PAG1", "instagram_id" => "IG1", "token" => "****3456", "status" => "ok"}

        # ---- 3. pedido -> plano pela OpenAI (faixa media); conta imposta pelo modelo e ignorada
        assert resp(Agente.processar(ta, pedido)) =~ "confirma"
        assert %{"status" => "aguardando_confirmacao", "pixel" => "998877"} = Plano.atual(ta)
        refute Map.has_key?(Plano.atual(ta), "conta_id")

        # ---- 4. criativo: conferencia decidivel (reprovado nao entra; aprovado vira o criativo do plano e pede nova confirmacao)
        assert resp(Agente.receber_criativo(ta, "baixa.png", png(400, 400))) =~ "resolucao"
        assert Plano.atual(ta)["criativo"]["midia"] == "foto1.png"
        refute File.exists?(Path.join([midia, ta, "baixa.png"]))
        assert resp(Agente.receber_criativo(ta, "foto2.png", png(1080, 1350))) =~ "confirma"
        assert %{"criativo" => %{"midia" => "foto2.png"}, "status" => "aguardando_confirmacao"} = Plano.atual(ta)
        assert File.exists?(Path.join([midia, ta, "foto2.png"]))

        # ---- 5. confirmacao em texto livre (faixa pequena): ambigua repergunta; clara executa PAUSADO na Meta
        assert resp(Agente.processar(ta, "hmm, talvez, nao sei")) == @confirma
        assert resp(Agente.processar(ta, "ENUM-INVALIDO")) == @confirma
        assert posts(msrv) == []
        r = resp(Agente.processar(ta, "Perfeito, pode fazer sim!"))
        assert r =~ "pausada" and r =~ "confere com o plano"
        assert %{"status" => "verificado", "campanha_id" => cid} = Plano.ler(ta, "p1")

        ps = posts(msrv)
        assert Enum.map(ps, &List.last(String.split(&1.caminho, "/"))) == ~w(adimages campaigns adsets adcreatives ads)
        assert Enum.all?(ps, &String.starts_with?(&1.caminho, "/v26.0/act_111/"))
        forms = for p <- ps, p.headers["content-type"] =~ "urlencoded", do: {List.last(String.split(p.caminho, "/")), URI.decode_query(p.corpo)}
        for {k, f} <- forms, k != "adcreatives", do: assert(f["status"] == "PAUSED")
        refute Enum.any?(ps, &(&1.corpo =~ "ACTIVE"))
        assert %{"special_ad_categories" => ~s(["HOUSING"]), "spend_cap" => "50000", "objective" => "OUTCOME_LEADS"} = forms[:campaigns] || elem(Enum.find(forms, &(elem(&1, 0) == "campaigns")), 1)
        assert %{"daily_budget" => "5000"} = elem(Enum.find(forms, &(elem(&1, 0) == "adsets")), 1)
        assert elem(Enum.find(forms, &(elem(&1, 0) == "adsets")), 1)["promoted_object"] =~ "998877"
        for p <- HttpFalso.pedidos(msrv), p.headers["authorization"] != "Bearer EAAERRADO" do
          assert p.headers["authorization"] == "Bearer " <> @token
          refute p.caminho <> inspect(p.query) <> p.corpo =~ @token
        end

        # ---- 6. verificador confere o que a Meta devolveu; divergencia injetada e acusada
        assert Verificador.verificar(ta, "p1") == :ok
        sid = meta_achar(est, "adset", "campaign_id", cid)
        meta_injetar(est, sid, %{"daily_budget" => "999900"})
        assert {:divergente, [:orcamento_diario_igual]} = Verificador.verificar(ta, "p1")
        meta_injetar(est, sid, %{"daily_budget" => "5000"})
        meta_injetar(est, cid, %{"status" => "ACTIVE"})
        assert {:divergente, [:status_pausada]} = Verificador.verificar(ta, "p1")
        meta_injetar(est, cid, %{"status" => "PAUSED"})
        assert Verificador.verificar(ta, "p1") == :ok

        # ---- 7. a conta de anuncio vem sempre do registro do tenant (token alcanca as duas contas)
        n = length(HttpFalso.pedidos(msrv))
        assert {:error, :conta_barrada} = Acesso.chamar(ta, :listar_campanhas, [], conta: "act_222")
        assert length(HttpFalso.pedidos(msrv)) == n
        assert {:error, :nao_encontrada} = Acesso.chamar(tb, :ler_campanha, [cid])
        assert {:error, :nao_encontrada} = Acesso.chamar(tb, :editar_campanha, [cid, %{"nome" => "x"}])
        assert {:ok, []} = Acesso.chamar(tb, :listar_campanhas, [])
        assert {:error, :ativacao_fora_da_fase} = Acesso.chamar(ta, :editar_campanha, [cid, %{"status" => "ACTIVE"}])
        assert length(posts(msrv)) == 5

        # ---- 8. sem criativo enviado nada e criado pela metade
        assert resp(Agente.processar(tc, pedido)) =~ "confirma"
        r = resp(Agente.processar(tc, "sim, pode fazer"))
        assert r =~ "Nao consegui criar" and r =~ "criativo_ausente"
        assert length(posts(msrv)) == 5

        # ---- 9. falhas da OpenAI: nada executa, plano nao muda
        assert resp(Agente.processar(td, "FALHAR-OPENAI")) =~ "nada foi alterado"
        assert resp(Agente.processar(td, pedido)) =~ "confirma"
        no = length(HttpFalso.pedidos(osrv))
        System.delete_env("OPENAI_API_KEY")
        assert resp(Agente.processar(td, "sim")) == @confirma
        assert length(HttpFalso.pedidos(osrv)) == no
        assert {:error, :sem_chave_openai} = Trafego.IA.OpenAI.chamar(:media, :planejar, %{"texto" => "x", "plano" => %{}})
        System.put_env("OPENAI_API_KEY", @chave_openai)
        assert %{"status" => "aguardando_confirmacao"} = Plano.atual(td)
        assert posts(msrv) |> length() == 5

        # ---- 10. token invalido: status visivel, agente para antes de qualquer chamada, recadastro restaura
        no = length(HttpFalso.pedidos(osrv))
        Agent.update(est, &%{&1 | token: "EAAROTACIONADO"})
        assert {:error, :token_invalido} = Acesso.chamar(ta, :listar_campanhas, [])
        assert Acesso.status(ta) == "token invalido"
        assert Acesso.mascarado(ta)["status"] == "token invalido"
        assert resp(Agente.processar(ta, "quero outra campanha")) =~ "token"
        assert length(HttpFalso.pedidos(osrv)) == no
        assert Enum.any?(evs(ta, "operacao"), &(&1["erro"] == "token_invalido"))
        assert {:ok, _} = Acesso.cadastrar(ta, %{ok | "token" => "EAAROTACIONADO"})
        assert Acesso.status(ta) == "ok"

        # ---- 11. midia recebida pelo canal (Amarula, offline): chega, baixa, confere e entra no plano
        assert %{"status" => "aguardando_confirmacao"} = Plano.atual(td)
        bytes = png(1080, 1350)
        {:ok, enc} = Amarula.Protocol.Messages.Media.encrypt(bytes, :image)
        cdn = HttpFalso.start(fn _ -> {200, {:bin, enc.enc}} end)
        _ = start_supervised(Amarula.Supervisor)
        {:ok, conn} = Amarula.Testing.start_offline(profile: "tm42_#{u}")

        proto = %Amarula.Protocol.Proto.Message{
          imageMessage: %Amarula.Protocol.Proto.Message.ImageMessage{
            url: HttpFalso.url(cdn) <> "/m", mimetype: "image/png", mediaKey: enc.media_key, fileSha256: enc.file_sha256,
            fileEncSha256: enc.file_enc_sha256, fileLength: enc.file_length, width: 1080, height: 1350
          }
        }

        Amarula.Testing.deliver(conn, proto, from: "5511999990000@s.whatsapp.net")
        assert_receive {:amarula, :messages_upsert, %{messages: [%Amarula.Msg{type: :media, content: %Amarula.Content.Media{kind: :image}} = msg]}}, 5000
        assert {:ok, ^bytes} = Amarula.download_media(msg)
        r = resp(Agente.receber_midia(td, msg))
        assert r =~ "confirma"
        assert [arq] = File.ls!(Path.join(midia, td))
        assert String.ends_with?(arq, ".png")
        assert Plano.atual(td)["criativo"]["midia"] == arq
        HttpFalso.parar(cdn)
      end)

    # ---- 12. custo de tokens por evento, em R$ (USD por milhao x cotacao manual de config)
    custos = evs(ta, "custo_tokens")
    assert Enum.any?(custos, &(&1["modelo"] == "modelo-media-x" and &1["tokens_in"] == 1000 and &1["tokens_out"] == 500 and perto?(&1["custo_brl"], 0.015)))
    assert Enum.any?(custos, &(&1["modelo"] == "modelo-pequena-x" and perto?(&1["custo_brl"], 0.0075)))
    cot = Application.fetch_env!(:trafego, :cotacao_usd_brl)
    Application.delete_env(:trafego, :cotacao_usd_brl)
    assert Custo.brl("modelo-media-x", 1000, 500) == nil
    Application.put_env(:trafego, :cotacao_usd_brl, cot)

    # ---- 13. OpenAI: modelo por faixa vem de config; chave so no header; nada de conta nem token no corpo
    op = HttpFalso.pedidos(osrv)
    assert Enum.all?(op, &(&1.caminho == "/v1/responses" and &1.headers["authorization"] == "Bearer " <> @chave_openai))
    [b1 | _] = for p <- op, do: Jason.decode!(p.corpo)
    assert %{"model" => "modelo-media-x", "store" => false, "reasoning" => %{"effort" => "low"}} = b1
    assert %{"type" => "json_schema", "strict" => true, "name" => "planejar"} = get_in(b1, ["text", "format"])
    assert Enum.any?(op, &(Jason.decode!(&1.corpo)["model"] == "modelo-pequena-x"))
    for p <- op, do: refute(p.corpo =~ "act_" or p.corpo =~ @token or p.corpo =~ @chave_openai)

    # ---- 14. conferencia decidivel de formato, proporcao e resolucao
    assert {:ok, %{formato: "png", largura: 1080, altura: 1350}} = Criativo.conferir(png(1080, 1350))
    assert {:ok, %{formato: "jpeg", largura: 1080, altura: 1080}} = Criativo.conferir(jpeg(1080, 1080))
    assert {:ok, %{formato: "mp4", largura: 1080, altura: 1920}} = Criativo.conferir(mp4(1080, 1920))
    assert {:error, [:resolucao_baixa]} = Criativo.conferir(png(400, 400))
    assert {:error, [:proporcao_fora_do_aceito]} = Criativo.conferir(png(2400, 1080))
    assert {:error, [:resolucao_baixa, :proporcao_fora_do_aceito]} = Criativo.conferir(png(500, 100))
    assert {:error, [:formato_nao_suportado]} = Criativo.conferir(pad("GIF89a"))
    assert {:error, [:arquivo_ilegivel]} = Criativo.conferir(<<137, 80, 78, 71, 13, 10, 26, 10, 1, 2>>)

    # ---- 16. criativo so leva instagram_user_id quando o Instagram foi validado; sem ele usa so a pagina
    cred = %{"conta_id" => "act_111", "pagina_id" => "PAG1", "token" => "EAAROTACIONADO", "moeda" => "BRL"}
    params = %{"nome" => "x", "destino" => "site", "objetivo" => "lead", "orcamento_diario" => 5000, "teto_total" => 50_000, "publico" => "p",
               "janela" => %{"inicio" => "2026-11-01", "fim" => "2026-11-30"}, "pixel" => "998877", "url" => "https://c.com.br",
               "criativo" => %{"midia" => "a.png", "texto" => "t"}, "criativo_bytes" => png(1080, 1350)}
    antes = length(posts(msrv))
    assert {:ok, _} = Trafego.Plataforma.Meta.criar_campanha(cred, params)
    assert {:ok, _} = Trafego.Plataforma.Meta.criar_campanha(Map.put(cred, "instagram_id", "IG1"), params)
    specs = for p <- Enum.drop(posts(msrv), antes), String.ends_with?(p.caminho, "/adcreatives"), do: URI.decode_query(p.corpo)["object_story_spec"]
    assert [sem, com] = specs
    assert sem =~ "PAG1" and not (sem =~ "instagram_user_id")
    assert com =~ "PAG1" and com =~ ~s("instagram_user_id":"IG1")

    # ---- 17. erro da Graph traz subcodigo e mensagem ao usuario (antes so "Invalid parameter"); nada e criado
    baixo = Map.put(params, "teto_total", 20_000)
    antes = length(posts(msrv))
    assert {:error, {:graph, 100, msg}} = Trafego.Plataforma.Meta.criar_campanha(cred, baixo)
    assert msg =~ "sub=2446307" and msg =~ "R$300"
    novos = Enum.drop(posts(msrv), antes)
    assert Enum.all?(novos, &(String.ends_with?(&1.caminho, "/adimages") or String.ends_with?(&1.caminho, "/campaigns")))
    assert {:ok, _} = Trafego.Plataforma.Meta.criar_campanha(cred, Map.put(params, "teto_total", 30_000))

    assert Trafego.Executor.motivo({:graph, 100, "sub=1 x"}) == "graph_100: sub=1 x"

    # ---- 18. conjunto recusado (pagina sem WhatsApp Business): campanha ja criada fica PAUSADA registrada no parcial, com o motivo da Meta
    wa = Map.merge(params, %{"destino" => "whatsapp", "numero" => "5511999990000"})
    assert {:error, {:parcial, "adsets", %{"campanha_id" => _, "erro" => erro}}} = Trafego.Plataforma.Meta.criar_campanha(Map.put(cred, "pagina_id", "PAGSEMWA"), wa)
    assert erro =~ "graph_100" and erro =~ "WhatsApp"

    # ---- 15. segredo nunca em log, evento nem estado; a conversa do corretor nao vira evento
    todos = Enum.map_join([ta, tb, tc, td], " ", &tudo/1)
    for s <- [@token, @chave_openai, "EAAROTACIONADO", "EAAERRADO"], do: (refute log =~ s; refute todos =~ s)
    for trecho <- ["Perfeito", "talvez", "quero anunciar", "FALHAR-OPENAI"], do: refute(todos =~ trecho)
  end

  defp perto?(v, esperado), do: is_number(v) and abs(v - esperado) < 1.0e-6
end
