# Teste da etapa 6.0 (re-pareamento do WhatsApp por QR). Escrito ANTES de construir.
# Rodar: MIX_ENV=test mix test test/etapa60_test.exs
# REGRA: este banco e o de producao. So dados proprios: e-mails tp60.*@exemplo.test, tenants tp60_*. Canal.Simulado, sessoes em diretorio temporario.
# Garante: Conexao.reparear (backup datado, nunca apaga, so o tenant), Conta.reparear (tenant da sessao + auditoria), tela com confirmacao,
# canal Amarula tratando 401/403 como "precisa parear de novo" (backup + QR novo, sem loop) e o rotulo do estado.
defmodule Etapa60Test do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest, only: [live: 2, render_click: 2, has_element?: 3]
  alias Nucleo.{Canal, Conexao, Registro}
  alias PainelBase.{Conta, Formato, Usuarios}
  alias GestaoEquipe.Papeis

  @endpoint PainelBase.Endpoint
  @senha "senha-longa-de-teste-60"

  setup_all do
    Registro.migrar!()
    PainelBase.Banco.migrar!()
    GestaoEquipe.Banco.migrar!()
    limpar()
    raiz = Path.join(System.tmp_dir!(), "tp60_sessoes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(raiz)
    Application.put_env(:painel_base, :iteracoes_pbkdf2, 1000)
    Application.put_env(:gestao_equipe, :tenant_prefixo, "tp60_c")
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
    Postgrex.query!(Registro, "DELETE FROM ge_corretores WHERE tenant_id LIKE 'tp60\\_%' OR equipe LIKE 'tp60\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM ge_auditoria WHERE equipe LIKE 'tp60\\_%' OR alvo LIKE 'tp60\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_auditoria WHERE tenant_id LIKE 'tp60\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_usuarios WHERE email LIKE 'tp60.%@exemplo.test' OR tenant_id LIKE 'tp60\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM pb_tentativas WHERE chave LIKE 'e:tp60.%@exemplo.test' OR chave LIKE 'i:127.%'", [])
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp60\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp60\\_%'", [])
  end

  defp raiz, do: Application.get_env(:nucleo, :sessoes_raiz)

  defp pasta!(tenant, conteudo) do
    p = Path.join(raiz(), tenant)
    File.mkdir_p!(p)
    File.write!(Path.join(p, "creds.term"), conteudo)
    p
  end

  defp backups(tenant) do
    case File.ls(Path.join(raiz(), "_backup")) do
      {:ok, l} -> Enum.filter(l, &String.starts_with?(&1, tenant <> "-"))
      _ -> []
    end
  end

  # dono com tenant proprio e vinculo (canal simulado)
  defp dono!(u) do
    t = "tp60_d#{u}"
    Registro.criar_tenant(t)
    {:ok, dono} = Usuarios.criar(%{email: "tp60.dono#{u}@exemplo.test", nome: "Tp60 Dono", tenant_id: t, senha: @senha, verificado: true})
    :ok = Papeis.definir_dono(dono)
    :ok = GestaoEquipe.garantir_tenant(dono)
    {Usuarios.por_id(dono.id), t}
  end

  defp logado(email), do: build_conn() |> post("/entrar", %{"email" => email, "senha" => @senha}) |> recycle()

  test "Conexao.reparear: move as credenciais para backup datado (sem apagar), so do tenant, e sobe o canal pedindo QR" do
    u = System.unique_integer([:positive])
    {_dono, t} = dono!(u)
    outro = "tp60_o#{u}"
    pasta = pasta!(t, "CRED-VELHA")
    pasta_outro = pasta!(outro, "CRED-OUTRO")

    :ok = Conexao.assinar(t)
    assert {:ok, _} = Conexao.reparear(t, canal_opts: [qr: "SIM-QR-60"])
    assert_receive {:canal_estado, ^t, {:qr, "SIM-QR-60"}}, 2000

    [bk] = backups(t)
    assert bk =~ ~r/^#{t}-\d{8}-\d{6}/
    assert File.read!(Path.join([raiz(), "_backup", bk, "creds.term"])) == "CRED-VELHA", "credenciais preservadas no backup"
    refute File.exists?(Path.join(pasta, "creds.term")), "pasta ativa sem as credenciais antigas"
    assert File.read!(Path.join(pasta_outro, "creds.term")) == "CRED-OUTRO", "outro tenant intocado"
    assert backups(outro) == []

    # sem credenciais: nada a mover, mas ainda sobe o canal (sem erro e sem backup novo)
    File.rm_rf!(pasta)
    assert {:ok, _} = Conexao.reparear(t, canal_opts: [qr: "SIM-QR-60b"])
    assert length(backups(t)) == 1
    Conexao.encerrar(t)
  end

  test "Conta.reparear: usa o tenant da sessao, audita e o QR aparece no estado" do
    u = System.unique_integer([:positive])
    {dono, t} = dono!(u)
    pasta!(t, "CRED-VELHA")
    outro = "tp60_o#{u}"
    pasta!(outro, "CRED-OUTRO")

    :ok = Conexao.assinar(t)
    assert :ok = Conta.reparear(dono, canal_opts: [qr: "SIM-QR-61"])
    assert_receive {:canal_estado, ^t, {:qr, "SIM-QR-61"}}, 2000
    assert length(backups(t)) == 1 and backups(outro) == []
    assert "whatsapp.reparear" in (Conta.auditoria(dono, 20) |> Enum.map(& &1.acao))
    refute Jason.encode!(Conta.auditoria(dono, 20)) =~ "SIM-QR"
    Conexao.encerrar(t)
  end

  test "tela: Parear de novo pede confirmacao antes de executar; cancelar nao faz nada; confirmar faz backup" do
    u = System.unique_integer([:positive])
    {dono, t} = dono!(u)
    pasta!(t, "CRED-VELHA")
    s = logado(dono.email)

    {:ok, view, html} = live(s, "/conta")
    assert html =~ "Parear de novo (QR)"
    refute html =~ "Sim, parear de novo"

    # confirmar sem ter pedido nao executa (evento forjado)
    render_click(view, "reparear")
    assert backups(t) == [] and File.exists?(Path.join([raiz(), t, "creds.term"]))

    html = render_click(view, "pedir_reparear")
    assert html =~ "Sim, parear de novo" and html =~ "Cancelar"
    assert backups(t) == []

    html = render_click(view, "cancelar_reparear")
    refute html =~ "Sim, parear de novo"
    assert backups(t) == []

    render_click(view, "pedir_reparear")
    render_click(view, "reparear")
    assert length(backups(t)) == 1
    refute File.exists?(Path.join([raiz(), t, "creds.term"]))
    refute has_element?(view, "button", "Sim, parear de novo")
    Conexao.encerrar(t)
  end

  test "canal Amarula: 401/403 = precisa parear de novo (backup + QR novo, uma vez); outros erros nao mexem nas credenciais" do
    u = System.unique_integer([:positive])
    {_dono, t} = dono!(u)
    pasta!(t, "CRED-VELHA")
    outro = "tp60_o#{u}"
    pasta!(outro, "CRED-OUTRO")
    s = %{tenant: t, reparo: [canal_opts: [qr: "SIM-QR-63"]], reparando: false, aberto: true, conn: nil, destino: self(), imprimir: false}

    assert Canal.Amarula.credencial_invalida?({:connection_failure, "401"})
    assert Canal.Amarula.credencial_invalida?({:connection_failure, "403"})
    refute Canal.Amarula.credencial_invalida?({:connection_failure, "500"})
    refute Canal.Amarula.credencial_invalida?(:timeout)

    # erro qualquer que nao e de credencial: nada acontece
    assert {:noreply, ^s} = Canal.Amarula.handle_info({:amarula, :error, {:connection_failure, "500"}}, s)
    assert backups(t) == []

    :ok = Conexao.assinar(t)
    assert {:noreply, %{reparando: true, aberto: false}} = Canal.Amarula.handle_info({:amarula, :error, {:connection_failure, "401"}}, s)
    assert_receive {:canal_estado, ^t, {:qr, "SIM-QR-63"}}, 3000
    assert length(backups(t)) == 1
    assert File.read!(Path.join([raiz(), outro, "creds.term"])) == "CRED-OUTRO"

    # novos 401 (retentativas do Amarula) enquanto reparando nao repetem o backup
    s2 = %{s | reparando: true}
    assert {:noreply, ^s2} = Canal.Amarula.handle_info({:amarula, :error, {:connection_failure, "401"}}, s2)
    assert length(backups(t)) == 1
    Conexao.encerrar(t)
  end

  test "canal Amarula: se o novo QR nao puder subir (desativado) o estado fica :precisa_parear" do
    u = System.unique_integer([:positive])
    {_dono, t} = dono!(u)
    pasta!(t, "CRED-VELHA")
    Postgrex.query!(Registro, "UPDATE vinculos SET estado='desativado' WHERE tenant_id=$1", [t])
    s = %{tenant: t, reparo: [], reparando: false, aberto: true, conn: nil, destino: self(), imprimir: false}
    :ok = Conexao.assinar(t)
    Canal.Amarula.handle_info({:amarula, :error, {:connection_failure, "401"}}, s)
    assert_receive {:canal_estado, ^t, :precisa_parear}, 3000
    assert Conexao.estado(t) == :precisa_parear
    Conexao.encerrar(t)
  end

  test "rotulo do estado :precisa_parear na tela" do
    assert {"Precisa parear de novo", _} = Formato.canal(:precisa_parear)
    u = System.unique_integer([:positive])
    {dono, t} = dono!(u)
    Canal.Estado.publicar(t, :precisa_parear)
    {:ok, _view, html} = live(logado(dono.email), "/conta")
    assert html =~ "Precisa parear de novo" and html =~ "Parear de novo (QR)"
    Canal.Estado.publicar(t, :sem_sessao)
  end
end
