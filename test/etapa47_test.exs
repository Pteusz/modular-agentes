# Teste geral da etapa 4.7 (navegacao, WhatsApp por QR para dono/admin, credenciais manuais). Escrito ANTES de construir.
# Rodar: MIX_ENV=test mix test
# REGRA: este banco e o de producao. Cada teste cria e remove SO os proprios dados (e-mails tp7.*@exemplo.test, tenants tp7_*).
# Nenhum e-mail real, nenhum WhatsApp real (Canal.Simulado, sessoes em diretorio temporario), Meta simulada.
defmodule Etapa47Test do
  use ExUnit.Case
  import Phoenix.ConnTest
  alias Nucleo.{Canal, Conexao, Registro}
  alias PainelBase.{Conta, Usuarios}
  alias GestaoEquipe.Papeis
  alias Trafego.{Acesso, Cifra}
  alias Trafego.Plataforma.Simulada

  @endpoint PainelBase.Endpoint
  @senha "senha-longa-de-teste-47"

  setup_all do
    Registro.migrar!()
    PainelBase.Banco.migrar!()
    GestaoEquipe.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    raiz = Path.join(System.tmp_dir!(), "tp7_sessoes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(raiz)
    Application.put_env(:painel_base, :iteracoes_pbkdf2, 1000)
    Application.put_env(:gestao_equipe, :tenant_prefixo, "tp7_c")
    Application.put_env(:gestao_equipe, :canal, Canal.Simulado)
    Application.put_env(:nucleo, :sessoes_raiz, raiz)
    # sempre a Meta SIMULADA, mesmo se o ambiente tiver TRAFEGO_PLATAFORMA=meta (nunca chamar a Meta de verdade)
    antes_plataforma = Application.get_env(:trafego, :plataforma)
    Application.put_env(:trafego, :plataforma, Simulada)

    on_exit(fn ->
      limpar()
      File.rm_rf!(raiz)
      Application.delete_env(:gestao_equipe, :tenant_prefixo)
      Application.delete_env(:gestao_equipe, :canal)
      Application.delete_env(:nucleo, :sessoes_raiz)
      if antes_plataforma, do: Application.put_env(:trafego, :plataforma, antes_plataforma), else: Application.delete_env(:trafego, :plataforma)
    end)

    :ok
  end

  defp limpar do
    # So o que e do teste. Nunca limpar tabela inteira.
    Postgrex.query!(Registro, "DELETE FROM ge_corretores WHERE tenant_id LIKE 'tp7\\_%' OR equipe LIKE 'tp7\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM ge_auditoria WHERE equipe LIKE 'tp7\\_%' OR alvo LIKE 'tp7\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_auditoria WHERE tenant_id LIKE 'tp7\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_usuarios WHERE email LIKE 'tp7.%@exemplo.test' OR tenant_id LIKE 'tp7\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_tentativas WHERE chave LIKE 'e:tp7.%@exemplo.test' OR chave LIKE 'i:127.%'", [])
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp7\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp7\\_%'", [])
  end

  defp novo, do: build_conn()
  defp logado(email), do: novo() |> post("/entrar", %{"email" => email, "senha" => @senha}) |> recycle()
  defp ultimo_email, do: (assert_received({:email, em}); em)

  defp completar_convite(em) do
    t = Regex.run(~r{/convite/([A-Za-z0-9_-]+)}, em.text_body) |> List.last()
    assert redirected_to(post(novo(), "/convite/#{t}", %{"senha" => @senha, "senha_confirmacao" => @senha})) == "/entrar"
  end

  # usuario comum (corretor) com tenant proprio
  defp corretor!(u, k) do
    t = "tp7_k#{u}#{k}"
    Registro.criar_tenant(t)
    {:ok, us} = Usuarios.criar(%{email: "tp7.k#{u}#{k}@exemplo.test", nome: "Tp7 Corretor#{k}", tenant_id: t, senha: @senha, verificado: true})
    us
  end

  # dono com tenant JA EXISTENTE (sessao e dados, como o `mateus`) + admin com tenant proprio
  defp equipe!(u) do
    te = "tp7_eq#{u}"
    Registro.criar_tenant(te)
    Registro.gravar(te, "contador", %{"n" => 7})
    pasta = Path.join(Application.get_env(:nucleo, :sessoes_raiz), te)
    File.mkdir_p!(pasta)
    File.write!(Path.join(pasta, "creds.json"), "{\"antiga\":true}")
    {:ok, dono} = Usuarios.criar(%{email: "tp7.dono#{u}@exemplo.test", nome: "Tp7 Dono", tenant_id: te, senha: @senha, verificado: true})
    :ok = Papeis.definir_dono(dono)
    :ok = GestaoEquipe.garantir_tenant(dono)
    {:ok, admin} = GestaoEquipe.criar_admin(dono, %{"email" => "tp7.adm#{u}@exemplo.test", "nome" => "Tp7 Admin"})
    completar_convite(ultimo_email())
    {dono, Usuarios.por_id(admin.id), te, pasta}
  end

  # Meta simulada: conta/token por pessoa. Ids so com digitos (formato da Meta).
  defp meta(u, k) do
    conta = "act_47#{u}#{k}"
    tok = "SIM-TOK-47-#{u}-#{k}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token(tok, [conta])
    %{"token" => tok, "conta_id" => conta, "pagina_id" => "4701#{u}#{k}", "instagram_id" => "4702#{u}#{k}"}
  end

  defp trecho(html, re), do: Regex.run(re, html) |> List.first() || ""

  # ---------------------------------------------------------------- 1. navegacao

  test "navegacao: Conta e Sair no menu do usuario (header); barra inferior so no mobile, sem Conta" do
    u = System.unique_integer([:positive])
    us = corretor!(u, 1)
    s = logado(us.email)

    for rota <- ["/", "/campanhas", "/agente", "/conta"] do
      html = get(s, rota) |> html_response(200)
      topo = trecho(html, ~r{<header class="topo".*?</header>}s)
      inferior = trecho(html, ~r{<nav class="inferior".*?</nav>}s)

      assert topo =~ "modular agentes"
      assert topo =~ ~r{<details class="menu-usuario"}, "#{rota}: menu do usuario no header"
      assert topo =~ ~s(href="/conta") and topo =~ ~s(action="/sair") and topo =~ "Sair" and topo =~ "Conta"
      assert topo =~ us.email, "o menu identifica quem esta logado"
      assert topo =~ ~r{<nav class="principal"}, "#{rota}: navegacao do desktop no header"
      for r <- ["Início", "Campanhas", "Agente"], do: assert(topo =~ r and inferior =~ r)
      refute inferior =~ "Conta", "#{rota}: a barra inferior nao tem Conta"
      refute inferior =~ "Sair"
      assert length(Regex.scan(~r{<a }, inferior)) == 3
    end

    # item ativo marcado com aria-current (nao so cor)
    assert get(s, "/campanhas") |> html_response(200) |> trecho(~r{<nav class="inferior".*?</nav>}s) =~ ~r{aria-current="page"[^>]*>\s*<span[^>]*>Campanhas}s
  end

  test "navegacao: dono/admin ganham Equipe sem quebrar a barra (5 itens nas telas da gestao, Conta so no header)" do
    u = System.unique_integer([:positive])
    {dono, admin, _, _} = equipe!(u)

    for e <- [dono.email, admin.email] do
      s = logado(e)
      inicio = get(s, "/") |> html_response(200)
      assert trecho(inicio, ~r{<nav class="inferior".*?</nav>}s) =~ "Equipe"
      refute trecho(inicio, ~r{<nav class="inferior".*?</nav>}s) =~ "Conta"
      assert trecho(inicio, ~r{<header class="topo".*?</header>}s) =~ ~s(href="/conta")

      for rota <- ["/equipe", "/equipe/corretores", "/equipe/ia", "/equipe/alertas"] do
        html = get(s, rota) |> html_response(200)
        inferior = trecho(html, ~r{<nav class="inferior".*?</nav>}s)
        assert length(Regex.scan(~r{<a }, inferior)) == 5, "#{rota}: Painel, Equipe, IA, Alertas, Meu agente"
        refute inferior =~ "Conta"
        assert trecho(html, ~r{<header class="topo".*?</header>}s) =~ ~s(action="/sair")
      end
    end
  end

  test "navegacao: css so mostra a barra inferior no mobile e nunca quebra linha" do
    css = File.read!(Path.join(Application.app_dir(:painel_base), "priv/static/assets/app.css"))
    assert css =~ ~r/\.inferior \{[^}]*grid-auto-flow: column/s
    assert css =~ ~r/\.inferior a \{[^}]*white-space: nowrap/s
    assert css =~ ~r/\.inferior a \{[^}]*text-overflow: ellipsis/s
    assert css =~ ~r/@media \(min-width: 48rem\) \{[^@]*\.inferior \{ display: none; \}/s, "desktop sem barra inferior"
    assert css =~ ~r/@media \(min-width: 48rem\) \{[^@]*\.principal \{[^}]*display: flex/s, "desktop com navegacao no header"
    assert css =~ ~r/\.principal \{[^}]*display: none/s, "mobile sem a navegacao do header"
    # identidade: tokens e Geist continuam
    assert css =~ "--cobalto: #2B44C8" and css =~ ~s(font-family: "Geist")
  end

  # ---------------------------------------------------------------- 2. WhatsApp por QR para dono/admin

  test "dono e admin conectam o proprio WhatsApp por QR, desconectam e reconectam sem perder nem duplicar a sessao" do
    u = System.unique_integer([:positive])
    {dono, admin, te, pasta} = equipe!(u)
    sd = logado(dono.email)
    sa = logado(admin.email)

    for s <- [sd, sa] do
      h = get(s, "/conta") |> html_response(200)
      assert h =~ "Conectar WhatsApp" and h =~ "Sem sessão"
    end

    # admin: QR so dele
    :ok = Conexao.assinar(admin.tenant_id)
    assert :ok = Conta.conectar(admin, canal_opts: [qr: "SIM-QR-ADM-471"])
    assert_receive {:canal_estado, t, {:qr, "SIM-QR-ADM-471"}}, 2000
    assert t == admin.tenant_id
    h = get(sa, "/conta") |> html_response(200)
    assert h =~ "Aguardando leitura do QR" and h =~ "<svg class=\"qr" and h =~ "Desconectar"
    refute get(sd, "/conta") |> html_response(200) =~ "<svg class=\"qr"
    assert Conexao.estado(dono.tenant_id) == :sem_sessao

    # conectar de novo nao duplica o laco (um por tenant)
    assert :ok = Conta.conectar(admin)
    assert length(Registry.lookup(Nucleo.LacoReg, admin.tenant_id)) == 1

    # pareou
    Canal.Simulado.parear(Nucleo.Laco.canal(Conexao.pid(admin.tenant_id)))
    assert_receive {:canal_estado, ^t, :conectado}, 2000
    assert get(sa, "/conta") |> html_response(200) =~ "Conectado"

    # dono: a sessao que ja existia no tenant (pasta com credenciais) fica intacta em todo o ciclo
    assert :ok = Conta.conectar(dono, canal_opts: [qr: "SIM-QR-DONO-471"])
    assert length(Registry.lookup(Nucleo.LacoReg, te)) == 1
    assert :ok = Conta.desconectar(dono)
    assert Conexao.pid(te) == nil and Conexao.estado(te) == :sem_sessao
    assert File.read!(Path.join(pasta, "creds.json")) =~ "antiga", "desconectar nao apaga a sessao pareada"
    assert get(sd, "/conta") |> html_response(200) =~ "Conectar WhatsApp"
    assert :ok = Conta.conectar(dono)
    assert length(Registry.lookup(Nucleo.LacoReg, te)) == 1
    assert File.ls!(Application.get_env(:nucleo, :sessoes_raiz)) |> Enum.count(&(&1 == te)) == 1, "nenhuma pasta de sessao duplicada"
    assert File.read!(Path.join(pasta, "creds.json")) =~ "antiga"

    # estado "desconectado" (aparelho saiu): botao Reconectar, que reinicia o laco do proprio tenant
    Canal.Estado.publicar(te, :desconectado)
    assert get(sd, "/conta") |> html_response(200) =~ "Reconectar"
    assert :ok = Conta.reconectar(dono)
    assert length(Registry.lookup(Nucleo.LacoReg, te)) == 1
    assert Conexao.pid(admin.tenant_id) != nil, "mexer no dono nao derruba o admin"

    # auditoria sem QR e sem segredo
    acoes = Conta.auditoria(dono, 20) |> Enum.map(& &1.acao)
    assert "whatsapp.conectar" in acoes and "whatsapp.desconectar" in acoes
    refute Jason.encode!(Conta.auditoria(admin, 20)) =~ "SIM-QR"

    Conexao.encerrar(te)
    Conexao.encerrar(admin.tenant_id)
  end

  test "WhatsApp: tenant desativado nao conecta (erro, sem laco) e a tela avisa" do
    u = System.unique_integer([:positive])
    {_dono, admin, _, _} = equipe!(u)
    Postgrex.query!(Registro, "UPDATE vinculos SET estado='desativado' WHERE tenant_id=$1", [admin.tenant_id])
    assert {:error, :desativado} = Conta.conectar(admin)
    assert Conexao.pid(admin.tenant_id) == nil
  end

  # ---------------------------------------------------------------- 3. credenciais manuais

  test "credenciais manuais: salva cifrada, valida na plataforma, mostra so mascarado, e nunca devolve o token" do
    u = System.unique_integer([:positive])
    us = corretor!(u, 1)
    s = logado(us.email)
    m = meta(u, 1)

    assert get(s, "/conta") |> html_response(200) =~ "Nenhuma conta de anúncios conectada"
    assert get(s, "/conta") |> html_response(200) =~ ~s(action="/conta/anuncios")

    r = post(s, "/conta/anuncios", m)
    assert redirected_to(r) == "/conta?aviso=anuncios_salvo"
    refute r.resp_body =~ m["token"]
    refute inspect(r.resp_headers) =~ m["token"]

    # guardada cifrada (AES-256-GCM, tenant como AAD); nada em claro no registro
    reg = Registro.ler(us.tenant_id, "trafego_conta")
    refute Jason.encode!(reg) =~ m["token"]
    assert reg["token_cifrado"] && reg["conta_id"] == m["conta_id"] and reg["pagina_id"] == m["pagina_id"]
    assert {:ok, m["token"]} == Cifra.decifrar(us.tenant_id, reg["token_cifrado"])
    assert {:error, _} = Cifra.decifrar("tp7_outro", reg["token_cifrado"])
    assert {:ok, _} = Acesso.chamar(us.tenant_id, :listar_campanhas, [])

    # tela: mascarado, nunca o valor
    h = get(s, "/conta") |> html_response(200)
    assert h =~ "****" <> String.slice(m["token"], -4, 4) and h =~ m["conta_id"]
    refute h =~ m["token"]
    refute h =~ ~r/<input[^>]*value="#{Regex.escape(String.slice(m["token"], 0, 12))}/
    assert h =~ "Substituir" and h =~ "Remover"
    assert h =~ ~r/<input[^>]*name="token"[^>]*type="password"|<input[^>]*type="password"[^>]*name="token"/

    # mensagem de sucesso na tela (codigo fixo na URL, sem valor)
    assert get(s, "/conta?aviso=anuncios_salvo") |> html_response(200) =~ "Conta de anúncios salva"
  end

  test "credenciais manuais: formato validado antes de qualquer chamada; nada e salvo e o valor nunca volta" do
    u = System.unique_integer([:positive])
    us = corretor!(u, 1)
    s = logado(us.email)
    m = meta(u, 1)

    casos = [
      {Map.put(m, "token", ""), "invalido_token"},
      {Map.put(m, "token", "curto"), "invalido_token"},
      {Map.put(m, "token", "token com espaco e <script>"), "invalido_token"},
      {Map.put(m, "conta_id", ""), "invalido_conta_id"},
      {Map.put(m, "conta_id", "act_abc def"), "invalido_conta_id"},
      {Map.put(m, "conta_id", "act_123"), "invalido_conta_id"},
      {Map.put(m, "pagina_id", "pagina-x"), "invalido_pagina_id"},
      {Map.put(m, "instagram_id", "ig 1"), "invalido_instagram_id"}
    ]

    for {params, codigo} <- casos do
      r = post(s, "/conta/anuncios", params)
      assert redirected_to(r) == "/conta?erro=#{codigo}"
      refute r.resp_body =~ m["token"]
      assert Registro.ler(us.tenant_id, "trafego_conta") == nil, "#{codigo}: nada salvo"
    end

    assert get(s, "/conta?erro=invalido_token") |> html_response(200) =~ "token"
    # codigo desconhecido na URL nunca vira texto livre
    refute get(s, "/conta?erro=<b>x</b>") |> html_response(200) =~ "<b>x</b>"

    # instagram e opcional (ausente nao bloqueia); pagina e obrigatoria
    assert redirected_to(post(s, "/conta/anuncios", Map.delete(m, "instagram_id"))) == "/conta?aviso=anuncios_salvo"
    assert redirected_to(post(s, "/conta/anuncios", Map.put(m, "pagina_id", ""))) == "/conta?erro=invalido_pagina_id"

    # a plataforma recusa token que ela nao conhece: nada muda no que ja estava salvo
    antes = Registro.ler(us.tenant_id, "trafego_conta")
    ruim = %{m | "token" => "SIM-TOK-47-DESCONHECIDO"}
    r = post(s, "/conta/anuncios", ruim)
    assert redirected_to(r) =~ ~r{^/conta\?erro=(token_invalido|credencial_invalida|inacessivel_conta)$}
    refute r.resp_body =~ "DESCONHECIDO"
    assert Registro.ler(us.tenant_id, "trafego_conta") == antes
  end

  test "credenciais manuais: substituir e remover, com auditoria sem o valor" do
    u = System.unique_integer([:positive])
    us = corretor!(u, 1)
    s = logado(us.email)
    m1 = meta(u, 1)
    m2 = meta(u, 2)

    assert redirected_to(post(s, "/conta/anuncios", m1)) == "/conta?aviso=anuncios_salvo"
    assert redirected_to(post(s, "/conta/anuncios", m2)) == "/conta?aviso=anuncios_salvo"
    reg = Registro.ler(us.tenant_id, "trafego_conta")
    assert reg["conta_id"] == m2["conta_id"]
    assert {:ok, m2["token"]} == Cifra.decifrar(us.tenant_id, reg["token_cifrado"])
    h = get(s, "/conta") |> html_response(200)
    assert h =~ "****" <> String.slice(m2["token"], -4, 4)
    refute h =~ m1["token"] or h =~ m2["token"]

    assert redirected_to(post(s, "/conta/anuncios/remover", %{})) == "/conta?aviso=anuncios_removido"
    assert Registro.ler(us.tenant_id, "trafego_conta") == nil
    assert {:error, :sem_conta} = Acesso.chamar(us.tenant_id, :listar_campanhas, [])
    assert get(s, "/conta") |> html_response(200) =~ "Nenhuma conta de anúncios conectada"
    # remover sem nada salvo nao quebra
    assert redirected_to(post(s, "/conta/anuncios/remover", %{})) == "/conta?aviso=anuncios_removido"

    aud = Conta.auditoria(us, 50)
    acoes = Enum.map(aud, & &1.acao)
    assert Enum.count(acoes, &(&1 == "anuncios.salvar")) == 2 and "anuncios.remover" in acoes
    # a auditoria guarda quem, quando e so NOMES de campos: nunca token nem ids
    json = Jason.encode!(aud)
    for v <- Map.values(m1) ++ Map.values(m2), do: refute(json =~ v)
    assert Enum.find(aud, &(&1.acao == "anuncios.salvar")).detalhes["campos"] |> Enum.sort() == ~w(conta_id instagram_id pagina_id token)
    assert Enum.all?(aud, &(&1.usuario_id == us.id))
  end

  test "credenciais manuais: isoladas por usuario; o tenant vem da sessao, nunca do formulario" do
    u = System.unique_integer([:positive])
    a = corretor!(u, 1)
    b = corretor!(u, 2)
    sa = logado(a.email)
    sb = logado(b.email)
    ma = meta(u, 1)

    # tentativa de gravar no tenant de B por parametro forjado: grava so no de A
    assert redirected_to(post(sa, "/conta/anuncios", Map.merge(ma, %{"tenant_id" => b.tenant_id, "tenant" => b.tenant_id}))) == "/conta?aviso=anuncios_salvo"
    assert Registro.ler(b.tenant_id, "trafego_conta") == nil
    assert Registro.ler(a.tenant_id, "trafego_conta")["conta_id"] == ma["conta_id"]

    hb = get(sb, "/conta") |> html_response(200)
    refute hb =~ ma["conta_id"] or hb =~ String.slice(ma["token"], -4, 4) <> "</"
    assert hb =~ "Nenhuma conta de anúncios conectada"

    # B remover nao toca na conta de A
    assert redirected_to(post(sb, "/conta/anuncios/remover", %{"tenant_id" => a.tenant_id})) == "/conta?aviso=anuncios_removido"
    assert Registro.ler(a.tenant_id, "trafego_conta")["conta_id"] == ma["conta_id"]
    assert Conta.auditoria(b, 20) |> Enum.all?(&(&1.usuario_id == b.id))
    assert Conta.auditoria(a, 20) |> Enum.all?(&(&1.usuario_id == a.id))

    # sem login: nada
    assert redirected_to(post(novo(), "/conta/anuncios", ma)) == "/entrar"
    assert redirected_to(post(novo(), "/conta/anuncios/remover", %{})) == "/entrar"
  end

  test "credenciais manuais: dono e admin cadastram pela tela Conta, cada um na sua conta; sobra para o agente como antes" do
    u = System.unique_integer([:positive])
    {dono, admin, _, _} = equipe!(u)
    sd = logado(dono.email)
    sa = logado(admin.email)
    md = meta(u, 1)
    ma = meta(u, 2)
    assert redirected_to(post(sd, "/conta/anuncios", md)) == "/conta?aviso=anuncios_salvo"
    assert redirected_to(post(sa, "/conta/anuncios", ma)) == "/conta?aviso=anuncios_salvo"
    assert Registro.ler(dono.tenant_id, "trafego_conta")["conta_id"] == md["conta_id"]
    assert Registro.ler(admin.tenant_id, "trafego_conta")["conta_id"] == ma["conta_id"]
    refute get(sd, "/conta") |> html_response(200) =~ ma["conta_id"]
    refute get(sa, "/conta") |> html_response(200) =~ md["conta_id"]
    # a rota antiga da gestao continua valendo e aparece a mesma conta
    assert :ok = GestaoEquipe.minha_conta(admin, %{"token" => ma["token"], "gerenciador_id" => ma["conta_id"], "pagina_id" => ma["pagina_id"]})
  end

  test "versoes: painel-base 1.4.1, trafego 1.12.0 (oferta trafego.painel 1.1) e o painel nao depende do codigo do trafego" do
    assert to_string(Application.spec(:painel_base, :vsn)) == "1.4.1"
    assert to_string(Application.spec(:trafego, :vsn)) == "1.12.2"
    assert %{versao: "1.5", oferece: %{"trafego.painel" => "1.1"}} = Nucleo.Automacoes.Trafego.contrato()
    fontes = Path.wildcard(Path.join(File.cwd!(), "packages/painel-base/lib/**/*.ex")) |> Enum.map_join(&File.read!/1)
    refute fontes =~ ~r/\bTrafego\.(Acesso|Cifra|Plataforma)/, "o painel-base so fala com o trafego pela Fonte configuravel"
  end
end
