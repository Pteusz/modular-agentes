# Teste geral da etapa 4.3 (painel-base, pagina do corretor, WhatsApp pelo site, midia do canal). Rodar: MIX_ENV=test mix test
# Servidor HTTP/SMTP so locais e falsos; o e-mail REAL da Hostinger so e provado no ambiente do Mateus (scripts/email_teste.sh).
defmodule SmtpFalso do
  @moduledoc false
  # Servidor SMTP local minimo (gen_smtp_server): guarda as mensagens recebidas num Agent.
  @behaviour :gen_smtp_server_session
  def init(_host, _n, _ip, agente), do: {:ok, "220 falso ESMTP", agente}
  def handle_HELO(_h, s), do: {:ok, 655_360, s}
  def handle_EHLO(_h, ext, s), do: {:ok, ext, s}
  def handle_MAIL(_de, s), do: {:ok, s}
  def handle_MAIL_extension(_e, s), do: {:ok, s}
  def handle_RCPT(_para, s), do: {:ok, s}
  def handle_RCPT_extension(_e, s), do: {:ok, s}
  def handle_DATA(_de, _para, dados, agente) do
    Agent.update(agente, &[dados | &1])
    {:ok, "ok", agente}
  end

  def handle_STARTTLS(s), do: s
  def handle_RSET(s), do: s
  def handle_VRFY(_a, s), do: {:error, "252 nao verificado", s}
  def handle_other(_v, _a, s), do: {"500 nao", s}
  def code_change(_o, s, _e), do: {:ok, s}
  def terminate(r, s), do: {r, s}
end

defmodule Etapa43Test do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Plug.Conn
  import ExUnit.CaptureLog
  alias Nucleo.{Canal, Conexao, Laco, Registro, Vincular}
  alias Nucleo.Automacoes.PainelBase, as: ContratoPainel
  alias Nucleo.Automacoes.Trafego, as: ContratoTrafego
  alias PainelBase.Usuarios
  alias Trafego.{Acesso, Agente}
  alias Trafego.Plataforma.Simulada

  @endpoint PainelBase.Endpoint
  @senha_a "senha-da-ana-1234"
  @senha_b "senha-do-bruno-5678"
  @pedido "pedido destino site; url https://corretor.com.br/lancamento; pixel 998877; publico %s; criativo foto1.png | Apartamento novo; " <>
            "diario R$ 50; teto R$ 500; janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15; observacao SEGREDO-PRIVADO-777"

  defp png(w, h),
    do: (fn b -> b <> :binary.copy(<<0>>, 64) end).(<<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, 8, 2, 0, 0, 0, 0::32>>)

  setup_all do
    Registro.migrar!()
    PainelBase.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    Application.put_env(:painel_base, :iteracoes_pbkdf2, 1000)
    on_exit(&limpar/0)
    :ok
  end

  defp limpar do
    # So o que e do teste: este banco e o de producao, convites e sessoes reais nao podem ser apagados aqui.
    Postgrex.query!(Registro, "DELETE FROM pb_usuarios WHERE email LIKE 'tp%@exemplo.test'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_tentativas WHERE chave LIKE 'e:tp%@exemplo.test' OR chave LIKE 'i:127.%' OR chave LIKE 'r:tp%'", [])
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp\\_%'", [])
  end

  defp novo, do: build_conn()
  defp entrar(email, senha), do: post(novo(), "/entrar", %{"email" => email, "senha" => senha})
  defp logado(email, senha), do: entrar(email, senha) |> recycle()
  defp tokens_do(email), do: Postgrex.query!(Registro, "SELECT t.tipo FROM pb_tokens t JOIN pb_usuarios u ON u.id=t.usuario_id WHERE u.email=$1", [email]).rows
  defp ultimo_email, do: (assert_received({:email, em}); em)
  defp link(em, rota), do: Regex.run(~r{/#{rota}/([A-Za-z0-9_-]+)}, em.text_body) |> List.last()
  defp esperar(f, n \\ 60), do: (f.() || (n > 0 && (Process.sleep(50); esperar(f, n - 1))))

  test "painel-base: convite, senha, login, campanhas proprias, plano, WhatsApp, isolamento, privacidade, midia pelo canal" do
    u = System.unique_integer([:positive])
    {ta, tb, tc} = {"tp_a#{u}", "tp_b#{u}", "tp_c#{u}"}
    {ea, eb} = {"tp.ana#{u}@exemplo.test", "tp.bruno#{u}@exemplo.test"}
    {ca, cb} = {"act_#{ta}", "act_#{tb}"}

    # ---- contrato do pacote: vincula como a Eco e o Trafego; manifesto bate com o carregado
    for t <- [ta, tb, tc] do
      assert {:ok, :criado} = Vincular.vincular(t, ContratoPainel, Canal.Simulado, %{})
      assert {:ok, :criado} = Vincular.vincular(t, ContratoTrafego, Canal.Simulado, %{})
    end

    assert ContratoPainel.versao() == to_string(Application.spec(:painel_base, :vsn))
    carregados = Nucleo.Manifesto.carregados()
    assert carregados[:painel_base] == ContratoPainel.versao()
    assert :ok = Nucleo.Manifesto.validar(carregados)

    # ---- 1. convite por e-mail -> senha -> login
    assert {:ok, _} = Usuarios.convidar(ea, "Ana Corretora", ta)
    em = ultimo_email()
    assert Enum.map(em.to, &elem(&1, 1)) == [ea]
    token = link(em, "convite")
    refute inspect(Usuarios.por_email(ea)) =~ token, "o token nunca fica em claro no banco"
    assert [[hash]] = Postgrex.query!(Registro, "SELECT token_hash FROM pb_tokens t JOIN pb_usuarios u ON u.id=t.usuario_id WHERE u.email=$1", [ea]).rows
    refute hash == token

    assert entrar(ea, @senha_a) |> html_response(200) =~ "E-mail ou senha inválidos", "convite ainda nao aceito: sem senha"
    pagina = get(novo(), "/convite/#{token}") |> html_response(200)
    assert get(novo(), "/convite/#{token}") |> html_response(200) =~ "Definir senha", "GET duplo nao gasta o convite"
    assert pagina =~ "Definir senha" and pagina =~ "_csrf_token"
    assert post(novo(), "/convite/#{token}", %{"senha" => "curta", "senha_confirmacao" => "curta"}) |> html_response(200) =~ "pelo menos 10 caracteres"
    assert post(novo(), "/convite/#{token}", %{"senha" => @senha_a, "senha_confirmacao" => "outra-coisa-aqui"}) |> html_response(200) =~ "não conferem"

    log =
      capture_log(fn ->
        assert redirected_to(post(novo(), "/convite/#{token}", %{"senha" => @senha_a, "senha_confirmacao" => @senha_a})) == "/entrar"
      end)

    refute log =~ @senha_a
    assert %{verificado_em: %DateTime{}, senha_hash: "pbkdf2-sha256$" <> _ = h} = Usuarios.por_email(ea)
    refute h =~ @senha_a
    assert get(novo(), "/convite/#{token}") |> html_response(410) =~ "inválido ou já usado", "convite e de uso unico"

    # convite expirado
    assert {:ok, _} = Usuarios.convidar("tp.velho#{u}@exemplo.test", "Velho", ta)
    velho = ultimo_email() |> link("convite")
    Postgrex.query!(Registro, "UPDATE pb_tokens SET expira_em = now() - interval '1 hour'", [])
    assert get(novo(), "/convite/#{velho}") |> html_response(410) =~ "inválido ou já usado"

    # sessao: sem login volta para a entrada; cookie seguro; cabecalhos de seguranca
    assert redirected_to(get(novo(), "/")) == "/entrar"
    assert redirected_to(get(novo(), "/campanhas")) == "/entrar"
    c = entrar(ea, @senha_a)
    assert redirected_to(c) == "/"
    [cookie] = for {"set-cookie", v} <- c.resp_headers, v =~ "_painel_sessao", do: v
    assert cookie =~ "HttpOnly" and cookie =~ "SameSite=Lax" and cookie =~ ~r/secure/i
    assert get_resp_header(c, "content-security-policy") |> hd() =~ "default-src 'self'"
    assert get_resp_header(c, "x-frame-options") == ["DENY"]

    # ---- 2. limite de tentativas
    {:ok, _} = Usuarios.criar(%{email: "tp.lim#{u}@exemplo.test", nome: "Lim", tenant_id: tc, senha: "uma-senha-longa-123", verificado: true})
    for _ <- 1..5, do: assert(entrar("tp.lim#{u}@exemplo.test", "errada-errada-1") |> html_response(200) =~ "E-mail ou senha inválidos")
    assert entrar("tp.lim#{u}@exemplo.test", "uma-senha-longa-123") |> html_response(429) =~ "Muitas tentativas"

    # ---- 3. verificacao de e-mail
    {:ok, nv} = Usuarios.criar(%{email: "tp.nv#{u}@exemplo.test", nome: "Nao Verificado", tenant_id: tc, senha: "uma-senha-longa-123", verificado: false})
    assert entrar("tp.nv#{u}@exemplo.test", "uma-senha-longa-123") |> html_response(200) =~ "Verifique seu e-mail"
    :ok = Usuarios.enviar_verificacao(nv)
    tv = ultimo_email() |> link("verificar")
    assert get(novo(), "/verificar/#{tv}") |> html_response(200) =~ "Confirmar e-mail"
    assert get(novo(), "/verificar/#{tv}") |> html_response(200) =~ "Confirmar e-mail", "GET nao gasta o token"
    assert entrar("tp.nv#{u}@exemplo.test", "uma-senha-longa-123") |> html_response(200) =~ "Verifique seu e-mail"
    assert post(novo(), "/verificar/#{tv}") |> redirected_to() == "/entrar"
    assert redirected_to(entrar("tp.nv#{u}@exemplo.test", "uma-senha-longa-123")) == "/"
    assert get(novo(), "/verificar/#{tv}") |> html_response(410) =~ "inválido ou já usado"
    assert post(novo(), "/verificar/#{tv}") |> html_response(410) =~ "inválido ou já usado"

    # ---- 4. recuperacao de senha (mesma resposta com e sem conta; so o e-mail da conta recebe)
    r1 = post(novo(), "/recuperar", %{"email" => ea})
    r2 = post(novo(), "/recuperar", %{"email" => "tp.ninguem#{u}@exemplo.test"})
    assert r1.status == r2.status and html_response(r1, 200) == html_response(r2, 200)
    assert html_response(r1, 200) =~ "Se o e-mail existir"
    rec = ultimo_email()
    assert Enum.map(rec.to, &elem(&1, 1)) == [ea]
    refute_received {:email, _}
    tr = link(rec, "redefinir")
    sessao_antiga = logado(ea, @senha_a)
    assert get(sessao_antiga, "/") |> html_response(200) =~ "Ana Corretora"
    nova = "senha-nova-da-ana-99"
    assert redirected_to(post(novo(), "/redefinir/#{tr}", %{"senha" => nova, "senha_confirmacao" => nova})) == "/entrar"
    assert entrar(ea, @senha_a) |> html_response(200) =~ "E-mail ou senha inválidos"
    assert redirected_to(entrar(ea, nova)) == "/"
    assert post(novo(), "/redefinir/#{tr}", %{"senha" => nova, "senha_confirmacao" => nova}) |> html_response(410) =~ "inválido ou já usado"
    assert redirected_to(get(sessao_antiga, "/")) == "/entrar", "redefinir a senha derruba as sessoes antigas"
    assert tokens_do(ea) != nil

    # ---- 5. dados dos dois corretores (plataforma simulada: o token de A alcanca tambem a conta de B)
    Simulada.registrar_conta(ca)
    Simulada.registrar_conta(cb)
    Simulada.registrar_token("SIM-A", [ca, cb])
    Simulada.registrar_token("SIM-B", [cb])
    assert {:ok, _} = Acesso.cadastrar(ta, %{"conta_id" => ca, "token" => "SIM-A"})
    assert {:ok, _} = Acesso.cadastrar(tb, %{"conta_id" => cb, "token" => "SIM-B"})
    {:ok, _} = Usuarios.criar(%{email: eb, nome: "Bruno Corretor", tenant_id: tb, senha: @senha_b, verificado: true})

    for {t, pub, nome, m} <- [
          {ta, "publico-exclusivo-A", "Lancamento Zona Sul A", %{"gasto" => 4560, "alcance" => 12_000, "cliques" => 340, "mensagens_iniciadas" => 12, "resultados" => 12}},
          {tb, "publico-exclusivo-B", "Reforma Centro B", %{"gasto" => 99_900, "alcance" => 777_000, "cliques" => 4242, "mensagens_iniciadas" => 3, "resultados" => 3}}
        ] do
      assert {:ok, r} = Agente.processar(t, String.replace(@pedido, "%s", pub))
      assert r =~ "confirma"
      assert {:ok, r} = Agente.processar(t, "sim, pode criar")
      assert r =~ "pausada"
      [camp] = Enum.filter(Simulada.todas(), &(&1["conta_id"] == "act_#{t}"))
      Simulada.injetar(camp["id"], %{"nome" => nome})
      Simulada.injetar_metricas(camp["id"], m)
    end

    [camp_a] = Enum.filter(Simulada.todas(), &(&1["conta_id"] == ca))
    [camp_b] = Enum.filter(Simulada.todas(), &(&1["conta_id"] == cb))

    # um plano aguardando confirmacao so para A (o painel MOSTRA; a autorizacao e no WhatsApp)
    assert {:ok, r} = Agente.processar(ta, String.replace(@pedido, "%s", "publico-aguardando-A"))
    assert r =~ "confirma"

    sa = logado(ea, nova)
    sb = logado(eb, @senha_b)

    inicio = get(sa, "/") |> html_response(200)
    for rotulo <- ~w(Início Campanhas Agente Conta), do: assert(inicio =~ rotulo)
    assert inicio =~ "viewport" and inicio =~ "modular agentes"

    pa = get(sa, "/campanhas") |> html_response(200)
    assert pa =~ "Lancamento Zona Sul A" and pa =~ "Pausada"
    assert pa =~ "R$ 45,60" and pa =~ "12.000" and pa =~ "340" and pa =~ "R$ 3,80" and pa =~ "7 dias"
    refute pa =~ "Reforma Centro B" or pa =~ "999,00" or pa =~ "777.000"

    pb = get(sb, "/campanhas") |> html_response(200)
    assert pb =~ "Reforma Centro B" and pb =~ "R$ 999,00" and pb =~ "777.000"
    refute pb =~ "Lancamento Zona Sul A" or pb =~ "45,60"

    detalhe = get(sa, "/campanhas/#{camp_a["id"]}") |> html_response(200)
    for k <- ["Gasto", "Alcance", "Cliques", "Mensagens iniciadas", "Custo por resultado"], do: assert(detalhe =~ k)
    # A pede a campanha de B pelo id: nao existe para ele (e o id da conta nunca vem da pagina)
    assert get(sa, "/campanhas/#{camp_b["id"]}") |> html_response(404)
    assert get(sb, "/campanhas/#{camp_a["id"]}") |> html_response(404)
    refute get(sa, "/campanhas/#{camp_b["id"]}") |> response(404) =~ "Reforma Centro B"

    # plano aguardando: aparece para A, nunca para B, e SEM botao de confirmar (autorizacao so no WhatsApp)
    ag = get(sa, "/agente") |> html_response(200)
    assert ag =~ "publico-aguardando-A" and ag =~ "R$ 50,00" and ag =~ "responda no WhatsApp"
    refute ag =~ ~r/<button[^>]*>[^<]*confirm/i
    refute ag =~ ~r/phx-click="[^"]*(confirm|autoriz|aprov)/i
    refute ag =~ ~r/<form[^>]*confirm/i
    agb = get(sb, "/agente") |> html_response(200)
    assert agb =~ "Nenhum plano aguardando" and not (agb =~ "publico-aguardando-A")
    assert agb =~ "Fez"

    # ---- 6. privacidade: a conversa do corretor consigo mesmo nunca aparece (painel, eventos, aba IA)
    todos = [inicio, pa, pb, ag, agb, get(sa, "/conta") |> html_response(200)]
    for h <- todos, do: refute(h =~ "SEGREDO-PRIVADO-777")
    for t <- [ta, tb], do: refute(t |> Registro.eventos() |> Enum.map_join(" ", &Jason.encode!(&1.dados)) =~ "SEGREDO-PRIVADO-777")

    # ---- 7. WhatsApp pelo site: estado e QR por tenant, uma sessao por tenant
    contaa = get(sa, "/conta") |> html_response(200)
    assert contaa =~ ea and contaa =~ "Sem sessão" and contaa =~ "****"
    refute contaa =~ "EAA", "token nunca na tela"
    assert Conexao.estado(ta) == :sem_sessao
    :ok = Conexao.assinar(ta)
    assert {:ok, pid} = Conexao.conectar(ta, canal_opts: [qr: "SIM-QR-DA-ANA-123"])
    assert {:ok, :ja_conectado, ^pid} = Conexao.conectar(ta)
    assert length(Registry.lookup(Nucleo.LacoReg, ta)) == 1
    assert_receive {:canal_estado, ^ta, {:qr, "SIM-QR-DA-ANA-123"}}, 2000

    qr_a = get(sa, "/conta") |> html_response(200)
    assert qr_a =~ "Aguardando leitura do QR" and qr_a =~ "<svg"
    refute get(sb, "/conta") |> html_response(200) =~ "<svg class=\"qr"
    assert get(sb, "/conta") |> html_response(200) =~ "Sem sessão"
    refute ta |> Registro.eventos() |> Enum.map_join(" ", &Jason.encode!(&1.dados)) =~ "SIM-QR-DA-ANA-123", "QR nao vai para evento"

    Canal.Simulado.parear(Laco.canal(pid))
    assert_receive {:canal_estado, ^ta, :conectado}, 2000
    on = get(sa, "/conta") |> html_response(200)
    assert on =~ "Conectado" and not (on =~ "<svg class=\"qr")
    assert Conexao.estado(tb) == :sem_sessao

    # ---- 8. mesmo chat do agente com o Laco: texto vira conversa e MIDIA do canal chega ao Agente.receber_midia
    Postgrex.query!(Registro, "DELETE FROM estado WHERE tenant_id = $1 AND chave LIKE 'plano:%'", [tc])
    Simulada.registrar_conta("act_#{tc}")
    Simulada.registrar_token("SIM-C", ["act_#{tc}"])
    assert {:ok, _} = Acesso.cadastrar(tc, %{"conta_id" => "act_#{tc}", "token" => "SIM-C"})
    antes = Application.get_env(:trafego, :baixar_midia)
    Application.put_env(:trafego, :baixar_midia, fn _msg -> {:ok, png(1080, 1350)} end)
    on_exit(fn -> if antes, do: Application.put_env(:trafego, :baixar_midia, antes), else: Application.delete_env(:trafego, :baixar_midia) end)
    midia_dir = Path.join(System.tmp_dir!(), "etapa43_midia_#{u}")
    Application.put_env(:trafego, :midia_dir, midia_dir)
    on_exit(fn -> Application.delete_env(:trafego, :midia_dir); File.rm_rf(midia_dir) end)

    assert {:ok, pc} = Conexao.conectar(tc)
    ref = Laco.canal(pc)
    sem_criativo = "pedido destino site; url https://c.com.br/x; pixel 1; publico casais; diario R$ 50; teto R$ 500; janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15"
    Canal.Simulado.injetar(ref, :proprio, sem_criativo)
    assert esperar(fn -> Enum.any?(Canal.Simulado.enviadas(ref), &(&1 =~ "Montei o plano")) end), "texto do canal chega ao agente de trafego"
    assert Enum.all?(Canal.Simulado.enviadas(ref), &String.starts_with?(&1, "[Iara] "))

    msg = %Amarula.Msg{channel: :teste, type: :media, raw: nil, content: %Amarula.Content.Media{kind: :image, mimetype: "image/png"}}
    Canal.Simulado.injetar_midia(ref, :proprio, msg)
    assert esperar(fn -> get_in(Trafego.Plano.atual(tc) || %{}, ["criativo", "midia"]) != nil end), "midia entregue pelo canal chegou ao Agente.receber_midia"
    assert %{"status" => "aguardando_confirmacao", "criativo" => %{"midia" => arq}} = Trafego.Plano.atual(tc)
    assert File.exists?(Path.join([midia_dir, tc, arq]))

    # midia de terceiro e descartada no canal; filtro do Amarula separa texto, midia propria e o resto
    own = fn _ -> true end
    nao = fn _ -> false end
    assert {:midia, ^msg} = Canal.Amarula.filtrar(msg, own)
    assert :ignorar = Canal.Amarula.filtrar(msg, nao)
    assert {:entregar, "oi"} = Canal.Amarula.filtrar(%Amarula.Msg{channel: :t, type: :text, raw: nil, content: "oi"}, own)
    assert :ignorar = Canal.Amarula.filtrar(%Amarula.Msg{channel: :t, type: :reaction, raw: nil, content: nil}, own)
    Canal.Simulado.injetar_midia(ref, :terceiro, msg)
    Process.sleep(100)
    assert Canal.Simulado.ignoradas(ref) == 1

    for t <- [ta, tc], do: Conexao.encerrar(t)

    # ---- 9. logout invalida o token no servidor; senha nunca em log
    out = post(sa, "/sair")
    assert redirected_to(out) == "/entrar"
    assert redirected_to(get(sa, "/")) == "/entrar", "cookie antigo nao vale mais depois de sair"
  end

  test "assets locais: fontes Geist, sem CDN, nada externo" do
    css = get(novo(), "/assets/app.css") |> response(200)
    refute css =~ ~r{https?://}
    assert css =~ "Geist" and css =~ "#2B44C8" and css =~ "#F7F6F2"
    for f <- ~w(Geist-Variable.woff2 GeistMono-Variable.woff2) do
      r = get(novo(), "/fonts/#{f}")
      assert r.status == 200 and byte_size(r.resp_body) > 10_000
    end

    login = get(novo(), "/entrar") |> html_response(200)
    refute login =~ ~r{(src|href)="https?://}, "nenhum recurso externo na pagina"
    assert login =~ "_csrf_token" and login =~ "Esqueci a senha"
    assert get(novo(), "/assets/phoenix_live_view.min.js") |> response(200) =~ "LiveView"
  end

  test "e-mail: Hostinger SMTP 465 SSL so por env; entrega real de ponta a ponta contra SMTP local" do
    amb = ~w(PAINEL_SMTP_HOST PAINEL_SMTP_PORTA PAINEL_SMTP_USUARIO PAINEL_SMTP_SENHA)
    salvo = for k <- amb, do: {k, System.get_env(k)}
    on_exit(fn -> for {k, v} <- salvo, do: (if v, do: System.put_env(k, v), else: System.delete_env(k)) end)
    for k <- amb, do: System.delete_env(k)

    System.put_env("PAINEL_SMTP_USUARIO", "agente@exemplo.test")
    System.put_env("PAINEL_SMTP_SENHA", "senha-smtp-secreta")
    cfg = PainelBase.Mailer.config_smtp()
    assert cfg[:adapter] == Swoosh.Adapters.SMTP
    assert cfg[:relay] == "smtp.hostinger.com" and cfg[:port] == 465 and cfg[:ssl] == true
    assert cfg[:username] == "agente@exemplo.test" and cfg[:auth] == :always
    refute inspect(PainelBase.Mailer.config_smtp_publica()) =~ "senha-smtp-secreta"

    System.delete_env("PAINEL_SMTP_SENHA")
    assert {:error, :smtp_nao_configurado} = PainelBase.Mailer.entregar(Swoosh.Email.new(to: "x@y.test", from: "a@b.test", subject: "s", text_body: "t"), cfg_env: true)

    # entrega real via Swoosh.Adapters.SMTP contra um servidor SMTP local
    {:ok, agente} = Agent.start_link(fn -> [] end)
    {:ok, livre} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, porta} = :inet.port(livre)
    :gen_tcp.close(livre)
    {:ok, srv} = :gen_smtp_server.start(SmtpFalso, [{:port, porta}, {:sessionoptions, [callbackoptions: agente]}, {:address, {127, 0, 0, 1}}])

    local = [adapter: Swoosh.Adapters.SMTP, relay: "127.0.0.1", port: porta, ssl: false, tls: :never, auth: :never, no_mx_lookups: true]
    mail = Swoosh.Email.new(to: "dest@exemplo.test", from: "agente@exemplo.test", subject: "Teste de entrega 4.3", text_body: "corpo do teste")
    assert {:ok, _} = PainelBase.Mailer.entregar(mail, config: local)
    assert esperar(fn -> Agent.get(agente, & &1) != [] end)
    assert Agent.get(agente, & &1) |> hd() =~ "Teste de entrega 4.3"
    :gen_smtp_server.stop(srv)
  end
end
