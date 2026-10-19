# Teste geral da etapa 4.6, CORRECAO 2 (dono e admin com tenant proprio). Escrito ANTES de construir. Rodar: MIX_ENV=test mix test
# REGRA: este banco e o de producao. Cada teste cria e remove SO os proprios dados (e-mails tp6.*@exemplo.test, tenants tp6_*).
# Nenhum e-mail real (Swoosh.Adapters.Test), nenhum WhatsApp real (Canal.Simulado), sessoes em diretorio temporario.
# Garante: dono/admin com tenant proprio (WhatsApp, QR, estado, plano + confirmacao), telas de corretor abertas a eles, isolamento,
# privacidade (a conversa de cada um e so dele), desativar/excluir e auditoria mantidos, tenant existente do dono preservado.
defmodule Etapa46BTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  alias Nucleo.{Canal, Conexao, Registro, Vincular}
  alias Nucleo.Automacoes.PainelBase, as: ContratoPainel
  alias PainelBase.Usuarios
  alias GestaoEquipe.Papeis
  alias Trafego.Agente
  alias Trafego.Plataforma.Simulada

  @endpoint PainelBase.Endpoint
  @senha "senha-longa-de-teste-46b"
  @pedido "pedido destino site; url https://corretor.com.br/lancamento; pixel 998877; publico publico-x; criativo foto1.png | Apartamento novo; " <>
            "diario R$ 50; teto R$ 500; janela #{Date.utc_today()} #{Date.add(Date.utc_today(), 30)}; meta 20; custo_max R$ 15; observacao SEGREDO-"

  setup_all do
    Registro.migrar!()
    PainelBase.Banco.migrar!()
    GestaoEquipe.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    raiz = Path.join(System.tmp_dir!(), "tp6_sessoes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(raiz)
    Application.put_env(:painel_base, :iteracoes_pbkdf2, 1000)
    Application.put_env(:gestao_equipe, :tenant_prefixo, "tp6_c")
    Application.put_env(:gestao_equipe, :canal, Canal.Simulado)
    Application.put_env(:nucleo, :sessoes_raiz, raiz)

    on_exit(fn ->
      limpar()
      File.rm_rf!(raiz)
      Application.delete_env(:gestao_equipe, :tenant_prefixo)
      Application.delete_env(:gestao_equipe, :canal)
      Application.delete_env(:nucleo, :sessoes_raiz)
    end)

    :ok
  end

  defp limpar do
    # So o que e do teste. Nunca limpar tabela inteira: convites, sessoes e o tenant do Mateus existem aqui.
    Postgrex.query!(Registro, "DELETE FROM ge_corretores WHERE tenant_id LIKE 'tp6\\_%' OR equipe LIKE 'tp6\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM ge_auditoria WHERE equipe LIKE 'tp6\\_%' OR alvo LIKE 'tp6\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_usuarios WHERE email LIKE 'tp6.%@exemplo.test' OR tenant_id LIKE 'tp6\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_tentativas WHERE chave LIKE 'e:tp6.%@exemplo.test' OR chave LIKE 'i:127.%'", [])
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp6\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp6\\_%'", [])
  end

  defp novo, do: build_conn()
  defp entrar(email), do: post(novo(), "/entrar", %{"email" => email, "senha" => @senha})
  defp logado(email), do: entrar(email) |> recycle()
  defp ultimo_email, do: (assert_received({:email, em}); em)
  defp link(em, rota), do: Regex.run(~r{/#{rota}/([A-Za-z0-9_-]+)}, em.text_body) |> List.last()

  defp completar_convite(em) do
    t = link(em, "convite")
    assert redirected_to(post(novo(), "/convite/#{t}", %{"senha" => @senha, "senha_confirmacao" => @senha})) == "/entrar"
  end

  defp vinculos_de(t), do: Registro.contratos(t) |> Map.new(&{&1.automacao, &1.estado})
  defp campanhas(gid), do: Enum.filter(Simulada.todas(), &(&1["conta_id"] == gid))

  # Meta simulada com uma conta por pessoa
  defp meta(u, k) do
    gid = "act_tp6#{u}#{k}"
    tok = "SIM-TOK-46B-#{u}-#{k}"
    Simulada.registrar_conta(gid)
    Simulada.registrar_token(tok, [gid])
    %{"gerenciador_id" => gid, "token" => tok, "pagina_id" => "pg#{u}#{k}", "instagram_id" => "ig#{u}#{k}", "pixel_id" => "px#{u}#{k}"}
  end

  # dono com tenant JA EXISTENTE e com dados (como o `mateus` de producao) + um admin criado por ele
  defp equipe!(u) do
    te = "tp6_eq#{u}"
    Registro.criar_tenant(te)
    Registro.gravar(te, "contador", %{"n" => 7})
    pasta = Path.join(Application.get_env(:nucleo, :sessoes_raiz), te)
    File.mkdir_p!(pasta)
    File.write!(Path.join(pasta, "creds.json"), "{\"antiga\":true}")
    {:ok, dono} = Usuarios.criar(%{email: "tp6.dono#{u}@exemplo.test", nome: "Tp6 Dono", tenant_id: te, senha: @senha, verificado: true})
    :ok = Papeis.definir_dono(dono)
    {:ok, admin} = GestaoEquipe.criar_admin(dono, %{"email" => "tp6.adm#{u}@exemplo.test", "nome" => "Tp6 Admin"})
    completar_convite(ultimo_email())
    {dono, Usuarios.por_id(admin.id), te, pasta}
  end

  test "tenant proprio: o do dono e preservado e vinculado; cada admin ganha o seu; a equipe e uma so" do
    u = System.unique_integer([:positive])
    {dono, admin, te, pasta} = equipe!(u)

    # o tenant do dono e o mesmo de antes: nada apagado, nada duplicado
    assert dono.tenant_id == te
    assert Registro.ler(te, "contador") == %{"n" => 7}
    assert File.read!(Path.join(pasta, "creds.json")) =~ "antiga"
    assert :ok = GestaoEquipe.garantir_tenant(dono)
    assert :ok = GestaoEquipe.garantir_tenant(dono), "idempotente"
    assert Registro.ler(te, "contador") == %{"n" => 7}
    assert %{rows: [[1]]} = Postgrex.query!(Registro, "SELECT count(*)::int FROM tenants WHERE id=$1", [te])
    assert vinculos_de(te)["Nucleo.Automacoes.PainelBase"] == "ativo"
    assert Papeis.equipe(dono) == te

    # o admin tem tenant PROPRIO (nao o do dono), vinculado, e continua na equipe do dono
    assert admin.tenant_id != te
    assert String.starts_with?(admin.tenant_id, "tp6_c")
    assert vinculos_de(admin.tenant_id)["Nucleo.Automacoes.PainelBase"] == "ativo"
    assert Papeis.equipe(admin) == te
    assert admin.id in Enum.map(GestaoEquipe.admins(dono), & &1.id)
    assert admin.id in Enum.map(GestaoEquipe.admins(admin), & &1.id)

    # papel antigo (sem equipe gravada) cai no tenant do usuario
    {:ok, velho} = Usuarios.criar(%{email: "tp6.velho#{u}@exemplo.test", nome: "Tp6 Velho", tenant_id: "tp6_velho#{u}", senha: @senha, verificado: true})
    :ok = Papeis.definir_dono(velho)
    assert Papeis.equipe(velho) == "tp6_velho#{u}"

    # corretor cadastrado pelo admin e da MESMA equipe: o dono o ve, e o contrario
    d = Map.merge(meta(u, 1), %{"nome" => "Carla", "sobrenome" => "S#{u}", "usuario" => "carla6#{u}", "email" => "tp6.carla#{u}@exemplo.test", "numero" => "55119#{String.pad_leading("#{rem(u, 10_000_000)}", 8, "0")}", "filiacao" => "Alfa", "site" => "https://c.com.br"})
    assert {:ok, c} = GestaoEquipe.cadastrar_corretor(admin, d)
    assert c.equipe == te
    assert c.id in Enum.map(GestaoEquipe.listar(dono, %{}), & &1.id)
    assert {:ok, _} = GestaoEquipe.corretor(dono, c.id)
    # e o painel de gestao NAO traz o tenant do admin/dono como se fosse corretor
    refute Enum.any?(GestaoEquipe.listar(dono, %{}), &(&1.tenant_id in [te, admin.tenant_id]))
  end

  test "WhatsApp proprio: QR e estado por pessoa pelo painel, sem vazar entre dono, admin e corretor" do
    u = System.unique_integer([:positive])
    {dono, admin, _te, _} = equipe!(u)
    :ok = GestaoEquipe.garantir_tenant(dono)
    sd = logado(dono.email)
    sa = logado(admin.email)

    # a tela Conta (conexao do WhatsApp) abre para os dois
    assert get(sd, "/conta") |> html_response(200) =~ "Conectar WhatsApp"
    assert get(sa, "/conta") |> html_response(200) =~ "Conectar WhatsApp"

    :ok = Conexao.assinar(dono.tenant_id)
    assert {:ok, _} = Conexao.conectar(dono.tenant_id, canal_opts: [qr: "SIM-QR-DONO"])
    assert_receive {:canal_estado, t, {:qr, "SIM-QR-DONO"}}, 2000
    assert t == dono.tenant_id
    assert Conexao.estado(dono.tenant_id) == {:qr, "SIM-QR-DONO"}
    assert Conexao.estado(admin.tenant_id) == :sem_sessao, "o estado do dono nao e do admin"

    Canal.Estado.publicar(admin.tenant_id, :conectado)
    assert Conexao.estado(admin.tenant_id) == :conectado
    assert Conexao.estado(dono.tenant_id) == {:qr, "SIM-QR-DONO"}
    Conexao.encerrar(dono.tenant_id)
    Canal.Estado.publicar(admin.tenant_id, :sem_sessao)
  end

  test "campanhas pelo agente: plano + confirmacao por WhatsApp, cada um na sua conta; conversa so de quem a teve" do
    u = System.unique_integer([:positive])
    {dono, admin, _te, _} = equipe!(u)
    :ok = GestaoEquipe.garantir_tenant(dono)
    md = meta(u, 1)
    ma = meta(u, 2)
    assert :ok = GestaoEquipe.minha_conta(dono, md)
    assert :ok = GestaoEquipe.minha_conta(admin, ma)
    assert {:error, {:invalido, :credencial}} = GestaoEquipe.minha_conta(admin, Map.put(ma, "token", ""))

    # plano -> confirmacao: o agente propoe e so cria depois do "sim"
    assert {:ok, _} = Agente.processar(dono.tenant_id, @pedido <> "DONO-111")
    assert campanhas(md["gerenciador_id"]) == []
    assert Trafego.Painel.plano_aguardando(dono.tenant_id) != nil
    assert {:ok, _} = Agente.processar(dono.tenant_id, "sim, pode criar")
    assert length(campanhas(md["gerenciador_id"])) == 1

    assert {:ok, _} = Agente.processar(admin.tenant_id, @pedido <> "ADMIN-222")
    assert Trafego.Painel.plano_aguardando(dono.tenant_id) == nil
    assert Trafego.Painel.plano_aguardando(admin.tenant_id) != nil, "o plano do admin e do admin"
    assert {:ok, _} = Agente.processar(admin.tenant_id, "sim, pode criar")
    assert length(campanhas(ma["gerenciador_id"])) == 1
    assert length(campanhas(md["gerenciador_id"])) == 1, "a campanha de um nao vai para a conta do outro"

    # telas de corretor: cada um ve so a propria
    sd = logado(dono.email)
    sa = logado(admin.email)
    for s <- [sd, sa], rota <- ["/", "/campanhas", "/agente", "/conta"], do: assert(get(s, rota) |> html_response(200))
    # a pagina de campanhas lista so as do proprio tenant
    ids_d = for c <- campanhas(md["gerenciador_id"]), do: c["id"]
    ids_a = for c <- campanhas(ma["gerenciador_id"]), do: c["id"]
    assert get(sd, "/campanhas") |> html_response(200) |> then(fn h -> Enum.all?(ids_a, &(not String.contains?(h, &1))) end)
    assert get(sa, "/campanhas") |> html_response(200) |> then(fn h -> Enum.all?(ids_d, &(not String.contains?(h, &1))) end)

    # privacidade: nem a gestao nem o outro veem a conversa; ninguem le o token
    for {s, quem} <- [{sd, "ADMIN-222"}, {sa, "DONO-111"}], rota <- ["/", "/agente", "/campanhas", "/equipe", "/equipe/corretores", "/equipe/ia", "/equipe/alertas", "/equipe/auditoria"] do
      html = get(s, rota) |> html_response(200)
      refute html =~ quem, "#{rota} nao pode mostrar a conversa do outro (#{quem})"
      refute html =~ md["token"]
      refute html =~ ma["token"]
    end

    # o painel de gestao soma so corretores: a conta do dono/admin nao entra
    p = GestaoEquipe.painel(dono)
    assert p.corretores == []
  end

  test "telas: dono e admin abrem as de corretor e as de gestao, com atalho de uma para a outra; corretor continua sem /equipe" do
    u = System.unique_integer([:positive])
    {dono, admin, _te, _} = equipe!(u)
    :ok = GestaoEquipe.garantir_tenant(dono)
    d = Map.merge(meta(u, 3), %{"nome" => "Carla", "sobrenome" => "S#{u}", "usuario" => "carla6#{u}", "email" => "tp6.carla#{u}@exemplo.test", "numero" => "55118#{String.pad_leading("#{rem(u, 10_000_000)}", 8, "0")}", "filiacao" => "Alfa", "site" => "https://c.com.br"})
    {:ok, _} = GestaoEquipe.cadastrar_corretor(admin, d)
    completar_convite(ultimo_email_para(d["email"]))

    # o login continua levando dono/admin a gestao
    assert redirected_to(entrar(dono.email)) == "/equipe"
    assert redirected_to(entrar(admin.email)) == "/equipe"
    sd = logado(dono.email)
    sc = logado(d["email"])

    for rota <- ["/", "/campanhas", "/agente", "/conta"] do
      html = get(sd, rota) |> html_response(200)
      assert html =~ ~s(href="/equipe"), "#{rota}: dono/admin tem atalho para a gestao"
      refute get(sc, rota) |> html_response(200) =~ ~s(href="/equipe"), "#{rota}: corretor nao"
    end

    for rota <- ["/equipe", "/equipe/corretores", "/equipe/ia", "/equipe/alertas", "/equipe/minha-conta"] do
      assert get(sd, rota) |> html_response(200) =~ ~s(href="/"), "#{rota}: atalho para as telas de corretor"
    end

    assert get(sc, "/equipe") |> response(403)
    assert get(sc, "/equipe/minha-conta") |> response(403)
    assert redirected_to(get(novo(), "/equipe/minha-conta")) == "/entrar"
  end

  test "desativar e excluir corretor, e auditoria, seguem valendo para a equipe (dono e admin)" do
    u = System.unique_integer([:positive])
    {dono, admin, te, _} = equipe!(u)
    :ok = GestaoEquipe.garantir_tenant(dono)
    d = Map.merge(meta(u, 4), %{"nome" => "Bia", "sobrenome" => "S#{u}", "usuario" => "bia6#{u}", "email" => "tp6.bia#{u}@exemplo.test", "numero" => "55117#{String.pad_leading("#{rem(u, 10_000_000)}", 8, "0")}", "filiacao" => "Alfa", "site" => "https://b.com.br"})
    {:ok, c} = GestaoEquipe.cadastrar_corretor(admin, d)
    completar_convite(ultimo_email_para(d["email"]))
    assert :ok = GestaoEquipe.minha_conta(dono, meta(u, 5))

    # o dono desativa o corretor que o admin cadastrou; o do dono/admin (tenant proprio) nao e tocado
    Canal.Estado.publicar(dono.tenant_id, :conectado)
    assert :ok = GestaoEquipe.desativar(dono, c.id)
    assert vinculos_de(c.tenant_id) |> Map.values() |> Enum.all?(&(&1 == "desativado"))
    assert vinculos_de(dono.tenant_id)["Nucleo.Automacoes.PainelBase"] == "ativo"
    assert Conexao.estado(dono.tenant_id) == :conectado
    assert :ok = GestaoEquipe.reativar(admin, c.id)
    assert :ok = GestaoEquipe.excluir(admin, c.id, d["usuario"])
    assert Usuarios.por_email(d["email"]) == nil

    # equipe de fora nao alcanca esta equipe
    {:ok, fora} = Usuarios.criar(%{email: "tp6.fora#{u}@exemplo.test", nome: "Tp6 Fora", tenant_id: "tp6_fora#{u}", senha: @senha, verificado: true})
    :ok = Papeis.definir_dono(fora)
    assert {:error, :nao_encontrado} = GestaoEquipe.desativar(fora, c.id)
    assert GestaoEquipe.admins(fora) |> Enum.map(& &1.id) == [fora.id]

    # auditoria da equipe: admin.criar, conta.cadastrar, corretor.*; igual para dono e admin, e nada de segredo
    acoes = fn a -> GestaoEquipe.auditoria(a, 100) |> Enum.map(& &1.acao) end
    for a <- [dono, admin], x <- ~w(admin.criar conta.cadastrar corretor.cadastrar corretor.desativar corretor.reativar corretor.excluir), do: assert(x in acoes.(a), "#{x} na auditoria")
    refute Enum.any?(GestaoEquipe.auditoria(fora, 100), &(&1.alvo =~ te))
    refute inspect(GestaoEquipe.auditoria(dono, 100)) =~ "SIM-TOK-46B"
  end

  test "vincular o tenant do dono de novo (reinicio, deploy) nao duplica nem muda nada" do
    u = System.unique_integer([:positive])
    {dono, _admin, te, _} = equipe!(u)
    :ok = GestaoEquipe.garantir_tenant(dono)
    antes = vinculos_de(te)
    :ok = GestaoEquipe.garantir_tenant(dono)
    assert vinculos_de(te) == antes
    assert {:ok, :criado} = Vincular.vincular("tp6_novo#{u}", ContratoPainel, Canal.Simulado, %{})
  end

  defp ultimo_email_para(email) do
    receive do
      {:email, em} -> if Enum.any?(em.to, fn {_, e} -> e == email end), do: em, else: ultimo_email_para(email)
    after
      2000 -> flunk("sem e-mail para #{email}")
    end
  end
end
