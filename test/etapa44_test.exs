# Teste geral da etapa 4.4 (gestao de equipe). Rodar: MIX_ENV=test mix test
# REGRA: este banco e o de producao. Cada teste cria e remove SO os proprios dados (e-mails tp*@exemplo.test, tenants tp_*).
# Nenhum e-mail real (Swoosh.Adapters.Test), nenhum WhatsApp real (Canal.Simulado), sessoes em diretorio temporario.
defmodule Etapa44Test do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Plug.Conn
  alias Nucleo.{Canal, Conexao, Registro, Vincular}
  alias Nucleo.Automacoes.PainelBase, as: ContratoPainel
  alias Nucleo.Automacoes.Trafego, as: ContratoTrafego
  alias Nucleo.Automacoes.GestaoEquipe, as: ContratoGestao
  alias PainelBase.Usuarios
  alias Trafego.Agente
  alias Trafego.Plataforma.Simulada

  @endpoint PainelBase.Endpoint
  @senha "senha-longa-de-teste-44"
  @pedido "pedido destino site; url https://corretor.com.br/lancamento; pixel 998877; publico publico-x; criativo foto1.png | Apartamento novo; " <>
            "diario R$ 50; teto R$ 500; janela 2026-11-01 2026-11-30; meta 20; custo_max R$ 15; observacao SEGREDO-PRIVADO-777"

  setup_all do
    Registro.migrar!()
    PainelBase.Banco.migrar!()
    GestaoEquipe.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    raiz = Path.join(System.tmp_dir!(), "tp_sessoes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(raiz)
    Application.put_env(:painel_base, :iteracoes_pbkdf2, 1000)
    Application.put_env(:gestao_equipe, :tenant_prefixo, "tp_c")
    Application.put_env(:gestao_equipe, :canal, Canal.Simulado)
    Application.put_env(:nucleo, :sessoes_raiz, raiz)

    on_exit(fn ->
      limpar()
      File.rm_rf!(raiz)
      Application.delete_env(:gestao_equipe, :tenant_prefixo)
      Application.delete_env(:gestao_equipe, :canal)
      Application.delete_env(:gestao_equipe, :tenant_equipe)
      Application.delete_env(:nucleo, :sessoes_raiz)
    end)

    {:ok, raiz: raiz}
  end

  defp limpar do
    # So o que e do teste. Nunca limpar tabela inteira: convites e sessoes reais existem aqui.
    Postgrex.query!(Registro, "DELETE FROM ge_corretores WHERE tenant_id LIKE 'tp\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM ge_auditoria WHERE ator_nome LIKE 'Tp %' OR alvo LIKE 'tp\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_usuarios WHERE email LIKE 'tp%@exemplo.test' OR tenant_id LIKE 'tp\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_tentativas WHERE chave LIKE 'e:tp%@exemplo.test' OR chave LIKE 'i:127.%'", [])
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp\\_%'", [])
  end

  defp novo, do: build_conn()
  defp entrar(email, senha \\ @senha), do: post(novo(), "/entrar", %{"email" => email, "senha" => senha})
  defp logado(email), do: entrar(email) |> recycle()
  defp ultimo_email, do: (assert_received({:email, em}); em)
  defp link(em, rota), do: Regex.run(~r{/#{rota}/([A-Za-z0-9_-]+)}, em.text_body) |> List.last()
  defp esperar(f, n \\ 60), do: (f.() || (n > 0 && (Process.sleep(50); esperar(f, n - 1))))
  defp numero(u, k), do: "+55 11 9" <> String.pad_leading("#{rem(u, 1_000_000) * 10 + k}", 8, "0")

  defp completar_convite(em) do
    t = link(em, "convite")
    assert redirected_to(post(novo(), "/convite/#{t}", %{"senha" => @senha, "senha_confirmacao" => @senha})) == "/entrar"
  end

  # dono + admin prontos para login; o tenant da equipe e proprio do teste
  defp equipe!(u) do
    te = "tp_eq#{u}"
    Application.put_env(:gestao_equipe, :tenant_equipe, te)
    Registro.criar_tenant(te)
    {:ok, dono} = Usuarios.criar(%{email: "tp.dono#{u}@exemplo.test", nome: "Tp Dono", tenant_id: te, senha: @senha, verificado: true})
    :ok = GestaoEquipe.Papeis.definir_dono(dono)
    {:ok, admin} = GestaoEquipe.criar_admin(dono, %{"email" => "tp.adm#{u}@exemplo.test", "nome" => "Tp Admin"})
    completar_convite(ultimo_email())
    {dono, Usuarios.por_id(admin.id)}
  end

  defp dados(u, k \\ 1, extra \\ %{}) do
    Map.merge(
      %{
        "nome" => "Carla#{k}", "sobrenome" => "Souza#{u}x#{k}", "usuario" => "carla#{u}x#{k}", "email" => "tp.carla#{u}x#{k}@exemplo.test",
        "numero" => numero(u, k), "filiacao" => "Alfa#{u}", "site" => "https://carla#{k}.com.br",
        "token" => "SIM-TOK-#{u}-#{k}", "pagina_id" => "pg#{u}#{k}", "gerenciador_id" => "act_tpg#{u}#{k}", "instagram_id" => "ig#{u}#{k}", "pixel_id" => "px#{u}#{k}"
      },
      extra
    )
  end

  defp plataforma(d) do
    Simulada.registrar_conta(d["gerenciador_id"])
    Simulada.registrar_token(d["token"], [d["gerenciador_id"]])
  end

  defp vinculos_de(t), do: Registro.contratos(t) |> Map.new(&{&1.automacao, &1.estado})

  test "contrato do pacote, manifesto e papeis" do
    u = System.unique_integer([:positive])
    assert ContratoGestao.contrato() |> Map.take([:versao, :oferece]) == %{versao: "1.0", oferece: %{"gestao.equipe" => "1.0"}}
    assert ContratoGestao.versao() == to_string(Application.spec(:gestao_equipe, :vsn))
    carregados = Nucleo.Manifesto.carregados()
    assert carregados[:gestao_equipe] == ContratoGestao.versao()
    assert :ok = Nucleo.Manifesto.validar(carregados)
    # o trafego passa a oferecer a fronteira da equipe, sem quebrar a oferta anterior
    assert %{"trafego" => "1.0", "trafego.painel" => "1.0", "trafego.equipe" => "1.0"} = ContratoTrafego.contrato().oferece

    {dono, admin} = equipe!(u)
    assert GestaoEquipe.papel(dono) == :dono
    assert GestaoEquipe.papel(admin) == :admin

    # admin nao cria admin; usuario comum nao cadastra corretor
    assert {:error, :sem_permissao} = GestaoEquipe.criar_admin(admin, %{"email" => "tp.x#{u}@exemplo.test", "nome" => "Tp X"})
    {:ok, comum} = Usuarios.criar(%{email: "tp.comum#{u}@exemplo.test", nome: "Tp Comum", tenant_id: "tp_eq#{u}", senha: @senha, verificado: true})
    assert GestaoEquipe.papel(comum) == nil
    assert {:error, :sem_permissao} = GestaoEquipe.cadastrar_corretor(comum, dados(u))
    assert {:error, :sem_permissao} = GestaoEquipe.listar(comum, %{})
  end

  test "cadastro: campos do G3, credenciais cifradas, unicidade, tenant vinculado, convite e QR" do
    u = System.unique_integer([:positive])
    {_dono, admin} = equipe!(u)
    d = dados(u)
    plataforma(d)

    antes = Postgrex.query!(Registro, "SELECT count(*) FROM tenants WHERE id LIKE 'tp\\_c%'", []).rows
    assert {:ok, c} = GestaoEquipe.cadastrar_corretor(admin, d)
    assert c.tenant_id =~ ~r/^tp_c\d+$/

    # tenant vinculado ao tráfego e ao painel, ativos
    assert %{"trafego" => "ativo", "painel-base" => "ativo"} = vinculos_de(c.tenant_id)

    # nenhum segredo em claro na tabela da gestao
    [[linha]] = Postgrex.query!(Registro, "SELECT row_to_json(g)::text FROM ge_corretores g WHERE id=$1", [c.id]).rows
    for segredo <- [d["token"], d["pagina_id"], d["gerenciador_id"], d["instagram_id"], d["pixel_id"]], do: refute(linha =~ segredo)
    assert linha =~ d["email"] and linha =~ d["usuario"]
    assert GestaoEquipe.credenciais(admin, c.id) |> Map.take(~w(token pagina_id gerenciador_id instagram_id pixel_id)) ==
             Map.take(d, ~w(token pagina_id gerenciador_id instagram_id pixel_id))

    # a conta foi cadastrada no tráfego do tenant (token cifrado la tambem)
    assert %{"conta_id" => "act_tpg" <> _} = Trafego.Acesso.conta(c.tenant_id)
    assert Trafego.Acesso.status(c.tenant_id) == "ok"
    refute inspect(Trafego.Acesso.conta(c.tenant_id)) =~ d["token"]

    # unicidade: usuario, e-mail (sem caixa) e numero (mesmos digitos, outra formatacao)
    t0 = Registro.tenants_vinculados() |> length()
    assert {:error, {:duplicado, :usuario}} = GestaoEquipe.cadastrar_corretor(admin, dados(u, 2, %{"usuario" => String.upcase(d["usuario"])}))
    assert {:error, {:duplicado, :email}} = GestaoEquipe.cadastrar_corretor(admin, dados(u, 3, %{"email" => String.upcase(d["email"])}))
    num = d["numero"] |> String.replace(~r/\D/, "")
    assert {:error, {:duplicado, :numero}} = GestaoEquipe.cadastrar_corretor(admin, dados(u, 4, %{"numero" => "(#{String.slice(num, 0, 2)}) #{String.slice(num, 2..-1//1)}"}))
    assert Registro.tenants_vinculados() |> length() == t0, "falha de cadastro nao deixa tenant para tras"
    assert [[n1]] = Postgrex.query!(Registro, "SELECT count(*) FROM tenants WHERE id LIKE 'tp\\_c%'", []).rows
    assert [[n0]] = antes
    assert n1 == n0 + 1

    # campos obrigatorios
    assert {:error, {:invalido, :email}} = GestaoEquipe.cadastrar_corretor(admin, dados(u, 5, %{"email" => "sem-arroba"}))
    assert {:error, {:invalido, :nome}} = GestaoEquipe.cadastrar_corretor(admin, dados(u, 6, %{"nome" => ""}))

    # token recusado pela plataforma: nada e criado
    assert {:error, :credencial_invalida} = GestaoEquipe.cadastrar_corretor(admin, dados(u, 7, %{"token" => "SIM-NAO-EXISTE"}))

    # convite pelo painel-base: o corretor define a senha, entra e le o QR
    em = ultimo_email_para(d["email"])
    assert Enum.map(em.to, &elem(&1, 1)) == [d["email"]]
    completar_convite(em)
    sc = logado(d["email"])
    assert get(sc, "/") |> html_response(200) =~ "Carla1"
    :ok = Conexao.assinar(c.tenant_id)
    assert {:ok, _} = Conexao.conectar(c.tenant_id, canal_opts: [qr: "SIM-QR-CARLA"])
    assert get(sc, "/conta") |> html_response(200) =~ "<svg class=\"qr"
    Conexao.encerrar(c.tenant_id)

    # a auditoria registrou o cadastro sem dados pessoais
    [a | _] = GestaoEquipe.auditoria(admin, 50) |> Enum.filter(&(&1.acao == "corretor.cadastrar" and &1.alvo == c.tenant_id))
    refute inspect(a) =~ d["email"] or inspect(a) =~ d["token"] or inspect(a) =~ d["numero"]
  end

  defp ultimo_email_para(email) do
    receive do
      {:email, em} -> if(Enum.map(em.to, &elem(&1, 1)) == [email], do: em, else: ultimo_email_para(email))
    after
      500 -> flunk("sem e-mail para #{email}")
    end
  end

  test "lista com filtro cruzado, sugestao de filiacao e edicao" do
    u = System.unique_integer([:positive])
    {_dono, admin} = equipe!(u)
    d1 = dados(u, 1)
    d2 = dados(u, 2, %{"nome" => "Davi", "filiacao" => "Beta#{u}"})
    d3 = dados(u, 3, %{"filiacao" => "Alfa#{u}"})
    for d <- [d1, d2, d3], do: plataforma(d)
    [{:ok, c1}, {:ok, c2}, {:ok, c3}] = for d <- [d1, d2, d3], do: GestaoEquipe.cadastrar_corretor(admin, d)

    ids = fn filtros -> GestaoEquipe.listar(admin, filtros) |> Enum.map(& &1.id) |> Enum.sort() end
    todos = Enum.sort([c1.id, c2.id, c3.id])
    assert ids.(%{"filiacao" => "alfa#{u}"}) == Enum.sort([c1.id, c3.id]), "filiacao sem caixa, por trecho"
    assert ids.(%{"nome" => "davi"}) -- todos == [] and c2.id in ids.(%{"nome" => "davi"})
    assert ids.(%{"sobrenome" => "souza#{u}x2"}) == [c2.id]
    assert ids.(%{"email" => "CARLA#{u}X3@"}) == [c3.id]
    assert ids.(%{"numero" => String.replace(d1["numero"], ~r/\D/, "") |> String.slice(-7..-1//1)}) == [c1.id], "numero por digitos"
    assert ids.(%{"filiacao" => "alfa#{u}", "nome" => "carla3"}) == [c3.id], "filtros se cruzam (E)"
    assert ids.(%{"filiacao" => "beta#{u}", "nome" => "carla1"}) == []
    assert Enum.sort(ids.(%{"sobrenome" => "souza#{u}x"})) == todos

    sug = GestaoEquipe.filiacoes(admin)
    assert Enum.count(sug, &(&1 == "Alfa#{u}")) == 1, "sugestao sem repeticao"
    assert "Beta#{u}" in sug

    # edicao: branco mantem credenciais; token novo e validado e cifrado; unicidade vale na edicao
    assert {:ok, e} = GestaoEquipe.editar(admin, c1.id, %{"filiacao" => "Nova#{u}", "site" => "https://novo.com.br", "token" => ""})
    assert e.filiacao == "Nova#{u}"
    assert GestaoEquipe.credenciais(admin, c1.id)["token"] == d1["token"]
    assert "Nova#{u}" in GestaoEquipe.filiacoes(admin)
    Simulada.registrar_token("SIM-NOVO-#{u}", [d1["gerenciador_id"]])
    assert {:ok, _} = GestaoEquipe.editar(admin, c1.id, %{"token" => "SIM-NOVO-#{u}"})
    assert GestaoEquipe.credenciais(admin, c1.id)["token"] == "SIM-NOVO-#{u}"
    assert {:error, :credencial_invalida} = GestaoEquipe.editar(admin, c1.id, %{"token" => "SIM-FALSO-#{u}"})
    assert GestaoEquipe.credenciais(admin, c1.id)["token"] == "SIM-NOVO-#{u}", "token recusado nao troca o salvo"
    assert {:error, {:duplicado, :email}} = GestaoEquipe.editar(admin, c1.id, %{"email" => d2["email"]})

    ed = GestaoEquipe.auditoria(admin, 50) |> Enum.filter(&(&1.acao == "corretor.editar" and &1.alvo == c1.tenant_id))
    assert length(ed) >= 2
    assert Enum.any?(ed, &(&1.detalhes["campos"] == ["filiacao", "site"] or Enum.sort(&1.detalhes["campos"]) == ["filiacao", "site"]))
    refute inspect(ed) =~ "SIM-NOVO" or inspect(ed) =~ "novo.com.br"
  end

  test "desativar bloqueia o agente (reversivel); excluir apaga dados pessoais e a sessao; campanha na Meta fica" do
    u = System.unique_integer([:positive])
    {_dono, admin} = equipe!(u)
    d = dados(u)
    plataforma(d)
    {:ok, c} = GestaoEquipe.cadastrar_corretor(admin, d)
    completar_convite(ultimo_email_para(d["email"]))
    t = c.tenant_id

    # uma campanha real (simulada) do corretor
    assert {:ok, _} = Agente.processar(t, @pedido)
    assert {:ok, _} = Agente.processar(t, "sim, pode criar")
    campanhas = fn -> Enum.filter(Simulada.todas(), &(&1["conta_id"] == d["gerenciador_id"])) end
    assert length(campanhas.()) == 1

    # sessao de WhatsApp em andamento + pasta de sessao em disco
    assert {:ok, pid} = Conexao.conectar(t)
    pasta = Path.join(Application.get_env(:nucleo, :sessoes_raiz), t)
    File.mkdir_p!(pasta)
    File.write!(Path.join(pasta, "creds.json"), "{}")
    sc = logado(d["email"])
    assert get(sc, "/") |> html_response(200) =~ "Carla1"

    # ---- desativar
    assert :ok = GestaoEquipe.desativar(admin, c.id)
    assert Conexao.pid(t) == nil and Conexao.estado(t) == :sem_sessao, "laco derrubado"
    assert vinculos_de(t) |> Map.values() |> Enum.all?(&(&1 == "desativado"))
    assert entrar(d["email"]) |> html_response(200) =~ "E-mail ou senha inválidos", "login barrado"
    assert redirected_to(get(sc, "/")) == "/entrar", "sessoes revogadas"
    assert {:error, :desativado} = Conexao.conectar(t), "o agente nao volta a falar"
    assert Nucleo.Laco.automacao(t) == :inativo
    refute Process.alive?(pid), "laco antigo morto"
    assert length(campanhas.()) == 1
    assert File.exists?(pasta), "desativar nao apaga a sessao"
    assert Enum.any?(GestaoEquipe.listar(admin, %{"usuario" => d["usuario"]}), &(&1.status == "desativado"))

    # a revalidacao da inicializacao nao reativa o que o admin desativou
    Nucleo.Inicializacao.validar_todos()
    assert vinculos_de(t) |> Map.values() |> Enum.all?(&(&1 == "desativado"))

    # ---- reativar volta tudo
    assert :ok = GestaoEquipe.reativar(admin, c.id)
    assert %{"trafego" => "ativo", "painel-base" => "ativo"} = vinculos_de(t)
    assert redirected_to(entrar(d["email"])) == "/"
    assert {:ok, _} = Conexao.conectar(t)
    Conexao.encerrar(t)
    assert :ok = GestaoEquipe.desativar(admin, c.id)

    # ---- excluir exige a confirmacao digitada e so vale com a ordem explicita
    assert {:error, :confirmacao} = GestaoEquipe.excluir(admin, c.id, "")
    assert {:error, :confirmacao} = GestaoEquipe.excluir(admin, c.id, "outro")
    assert Usuarios.por_email(d["email"]) != nil
    assert :ok = GestaoEquipe.excluir(admin, c.id, d["usuario"])

    [linha] = Postgrex.query!(Registro, "SELECT row_to_json(g)::text FROM ge_corretores g WHERE id=$1", [c.id]).rows |> List.flatten()
    for pessoal <- [d["nome"], d["sobrenome"], d["usuario"], d["email"], String.replace(d["numero"], ~r/\D/, ""), d["site"], d["filiacao"]], do: refute(linha =~ pessoal)
    assert linha =~ "excluido"
    for segredo <- [d["token"], d["pagina_id"], d["gerenciador_id"], d["instagram_id"], d["pixel_id"]], do: refute(linha =~ segredo)
    assert Usuarios.por_email(d["email"]) == nil
    assert Postgrex.query!(Registro, "SELECT count(*) FROM pb_usuarios WHERE email=$1", [d["email"]]).rows == [[0]]
    assert Trafego.Acesso.conta(t) == nil, "credenciais removidas (todas as versoes)"
    assert Registro.historico(t, "trafego_conta") == []
    refute File.exists?(pasta), "sessao do WhatsApp desvinculada"
    assert Conexao.pid(t) == nil
    assert length(campanhas.()) == 1, "a campanha na Meta NAO e apagada"
    assert GestaoEquipe.listar(admin, %{"usuario" => d["usuario"]}) == []
    # numero e usuario podem ser reaproveitados por outro cadastro depois da exclusao
    Simulada.registrar_conta("act_tpr#{u}")
    Simulada.registrar_token("SIM-TOK-#{u}-r", ["act_tpr#{u}"])
    assert {:ok, _} = GestaoEquipe.cadastrar_corretor(admin, dados(u, 1, %{"token" => "SIM-TOK-#{u}-r", "gerenciador_id" => "act_tpr#{u}"}))

    # auditoria: registra o fato, nunca o dado pessoal
    ac = GestaoEquipe.auditoria(admin, 100) |> Enum.filter(&(&1.alvo == t))
    for acao <- ~w(corretor.cadastrar corretor.desativar corretor.reativar corretor.excluir), do: assert(Enum.any?(ac, &(&1.acao == acao)), acao)
    refute inspect(ac) =~ d["email"] or inspect(ac) =~ d["usuario"] or inspect(ac) =~ d["token"]
  end

  test "o admin ve metadados do corretor e nunca a conversa dele; acesso por papel" do
    u = System.unique_integer([:positive])
    {_dono, admin} = equipe!(u)
    d = dados(u)
    plataforma(d)
    {:ok, c} = GestaoEquipe.cadastrar_corretor(admin, d)
    completar_convite(ultimo_email_para(d["email"]))
    t = c.tenant_id
    assert {:ok, _} = Agente.processar(t, @pedido)
    assert {:ok, _} = Agente.processar(t, "sim, pode criar")
    [camp] = Enum.filter(Simulada.todas(), &(&1["conta_id"] == d["gerenciador_id"]))
    Simulada.injetar(camp["id"], %{"nome" => "Lancamento Zona Sul #{u}", "status" => "ATIVA"})
    Simulada.injetar_metricas(camp["id"], %{"gasto" => 4560, "alcance" => 12_000, "cliques" => 340, "mensagens_iniciadas" => 12, "resultados" => 12})
    Trafego.Evento.custo(t, "p1", "planejador", "plano", %{"modelo" => "claude-sonnet-5-5", "tokens_in" => 1000, "tokens_out" => 500})

    sa = logado("tp.adm#{u}@exemplo.test")
    # admin entra na area da equipe; o corretor nao
    assert redirected_to(entrar("tp.adm#{u}@exemplo.test")) == "/equipe"
    sc = logado(d["email"])
    assert get(sc, "/equipe") |> response(403)
    assert get(sc, "/equipe/corretores") |> response(403)
    assert redirected_to(get(novo(), "/equipe")) == "/entrar"

    paginas =
      for rota <- ["/equipe", "/equipe/corretores", "/equipe/corretores/#{c.id}", "/equipe/ia", "/equipe/alertas", "/equipe/auditoria"],
          do: {rota, get(sa, rota) |> html_response(200)}

    for {rota, html} <- paginas do
      refute html =~ "SEGREDO-PRIVADO-777", "#{rota} nao pode mostrar a observacao/conversa do corretor"
      refute html =~ d["token"], "#{rota} nao mostra token"
    end

    pagina = Map.new(paginas)["/equipe/corretores/#{c.id}"]
    for trecho <- ["Carla1", "Lancamento Zona Sul #{u}", "R$ 45,60", "Ativa", "IA", "Desativar", "Excluir"], do: assert(pagina =~ trecho, trecho)
    painel = Map.new(paginas)["/equipe"]
    assert painel =~ "R$ 45,60" and painel =~ "Carla1"

    # funcoes de contexto: painel geral, custo de IA por corretor, status
    p = GestaoEquipe.painel(admin)
    assert p.gasto_total >= 4560 and p.campanhas_ativas >= 1
    [linha] = Enum.filter(p.corretores, &(&1.id == c.id))
    assert linha.gasto == 4560 and linha.campanhas_ativas == 1 and linha.custo_ia_brl > 0

    # alertas: sessao caida, token invalido, campanha reprovada, numero diferente do QR
    Nucleo.Canal.Estado.publicar(t, :conectado)
    st = GestaoEquipe.status(admin, c.id)
    assert st.whatsapp == :conectado and st.token == "ok"
    refute Enum.any?(GestaoEquipe.alertas(admin), &(&1.corretor_id == c.id))
    Nucleo.Canal.Estado.publicar(t, :desconectado)
    Simulada.injetar(camp["id"], %{"status" => "WITH_ISSUES"})
    Nucleo.Canal.Estado.publicar_numero(t, "5511000000000")
    Simulada.registrar_token(d["token"], [])
    assert {:ok, _} = GestaoEquipe.sincronizar(admin, c.id)
    tipos = for a <- GestaoEquipe.alertas(admin), a.corretor_id == c.id, do: a.tipo
    for tipo <- ~w(sessao_caida token_invalido campanha_reprovada numero_diferente)a, do: assert(tipo in tipos, inspect(tipo))
    st = GestaoEquipe.status(admin, c.id)
    assert st.token == "token invalido" and st.sincronizacao != nil
    assert get(sa, "/equipe/alertas") |> html_response(200) =~ "Carla1"
  end

  test "instancia de uma pessoa funciona sem o pacote: nada de fora depende dele" do
    u = System.unique_integer([:positive])
    raiz = Path.expand("../packages", __DIR__)
    for pacote <- ~w(nucleo eco trafego painel-base) do
      fontes = Path.wildcard(Path.join([raiz, pacote, "{lib,mix.exs}/**/*.{ex,exs}"])) ++ [Path.join([raiz, pacote, "mix.exs"])]
      for f <- fontes, File.regular?(f), do: refute(File.read!(f) =~ ~r/GestaoEquipe|gestao_equipe/, "#{f} referencia o pacote da equipe")
    end

    # o pacote da equipe so le o trafego pela fronteira oferecida
    lib = Path.wildcard(Path.join([raiz, "gestao-equipe", "lib", "**", "*.ex"]))
    assert lib != []
    for f <- lib, linha <- File.read!(f) |> String.split("\n"), linha =~ ~r/Trafego\./ do
      assert linha =~ ~r/Trafego\.Equipe|Nucleo\.Automacoes\.Trafego|Trafego\.Plataforma\.Simulada|#/, "#{f}: #{linha}"
    end

    # sem extensao registrada: /equipe nao existe e o painel do corretor segue igual
    te = "tp_s#{u}"
    Registro.criar_tenant(te)
    assert {:ok, :criado} = Vincular.vincular(te, ContratoPainel, Canal.Simulado, %{})
    {:ok, _} = Usuarios.criar(%{email: "tp.solo#{u}@exemplo.test", nome: "Tp Solo", tenant_id: te, senha: @senha, verificado: true})
    antes = Application.get_env(:painel_base, :extensoes)
    Application.put_env(:painel_base, :extensoes, [])
    restaurar = fn -> if antes, do: Application.put_env(:painel_base, :extensoes, antes), else: Application.delete_env(:painel_base, :extensoes) end
    on_exit(restaurar)
    s = logado("tp.solo#{u}@exemplo.test")
    assert redirected_to(entrar("tp.solo#{u}@exemplo.test")) == "/"
    assert get(s, "/equipe") |> response(404)
    assert get(s, "/") |> html_response(200) =~ "Tp Solo"
    assert get(s, "/campanhas") |> html_response(200)
    restaurar.()
  end
end
