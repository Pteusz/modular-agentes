# Teste geral da etapa 4.6 (correcoes). Escrito ANTES de construir. Rodar: MIX_ENV=test mix test
# REGRA: este banco e o de producao. Dados do teste: tenants tp6_*, fonte de feed/cotacao "tp_teste6". Plataforma simulada,
# IA falsa, aviso = funcao do teste. Nenhum e-mail, nenhum WhatsApp real.
# CORRECAO 1: imovel nao tem status; nao existe "esgotado/vendido" (nem evento, nem proposta, nem bloqueio de ativacao).
defmodule Etapa46Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Plano, Proposta, Feed}
  alias Trafego.Plataforma.Simulada

  @pedido "pedido destino site; url https://corretor.com.br/lancamento; pixel 998877; publico casais 30-45 zona sul; " <>
            "criativo foto1.jpg | Apartamento novo na zona sul; diario R$ 50; teto R$ 500; janela #{Date.utc_today()} #{Date.add(Date.utc_today(), 30)}; meta 20; custo_max R$ 15"
  @chaves ~w(cotacao_usd_brl teto_ia_brl teto_max_centavos notificar cotacao_fonte feed_fonte)a

  setup_all do
    Registro.migrar!()
    Trafego.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}
    Application.put_env(:trafego, :cotacao_fonte, "tp_teste6")
    Application.put_env(:trafego, :feed_fonte, "tp_teste6")
    Application.put_env(:trafego, :teto_ia_brl, 1000.0)

    on_exit(fn ->
      limpar()
      for {k, v} <- salvo, do: (case v do {:ok, x} -> Application.put_env(:trafego, k, x); :error -> Application.delete_env(:trafego, k) end)
    end)

    :ok
  end

  setup do
    pid = self()
    Application.put_env(:trafego, :notificar, fn tenant, texto -> send(pid, {:aviso, tenant, texto}) end)
    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp6\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp6\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM feed_imoveis WHERE fonte = 'tp_teste6'", [])
    Postgrex.query!(Registro, "DELETE FROM trafego_cotacao WHERE fonte = 'tp_teste6'", [])
  end

  defp resp({:ok, r}), do: r
  defp avisos(acc \\ []), do: (receive do {:aviso, t, x} -> avisos([{t, x} | acc]) after 0 -> Enum.reverse(acc) end)

  defp vincular(t) do
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
  end

  defp montar(extra) do
    t = "tp6_#{System.unique_integer([:positive])}"
    vincular(t)
    assert resp(Agente.processar(t, @pedido <> extra)) =~ "confirma"
    assert resp(Agente.processar(t, "pode fazer sim")) =~ "pausada"
    %{"id" => id, "campanha_id" => cid, "status" => "verificado"} = Plano.listar(t) |> List.last()
    {t, id, cid}
  end

  defp status(cid), do: Simulada.todas() |> Enum.find(&(&1["id"] == cid))

  @dump """
  INSERT INTO `wp_produtos` (`id`, `imagem`, `nome`, `regiao`, `regiao_base`, `dormitorios`, `estagio_obra`, `valor`, `estado_obra`, `updated_at`) VALUES
  (1, 'a.jpg', 'Luzes do Rio', 'Piedade', 'Zona Norte', '2 e 3 dorms', 'Em obras', 0.00, 'Lancamento', '2026-10-01 10:00:00'),
  (2, 'b.jpg', 'Parque d\\'Agua', 'Barra', 'Zona Oeste', '', 'Pronto', 450000.50, 'ESGOTADO', '2026-10-02 10:00:00'),
  (3, 'c.jpg', 'Vista Mar', 'Leblon', 'Zona Sul', '1 dorm', 'Pronto', 0.00, 'Vendido', '2026-10-03 10:00:00'),
  (4, 'd.jpg', 'Aurora', 'Tijuca', 'Zona Norte', '2 dorms', 'Pronto', 300000.00, 'Sold out', '2026-10-04 10:00:00');
  """

  describe "correcao 1: imovel sem status (nada de esgotado/vendido)" do
    test "o feed serve id, nome, bairro, regiao, dormitorios, valor, imagem e data; sem status e sem lista de esgotados" do
      arq = Path.join(System.tmp_dir!(), "tp6_feed_#{System.unique_integer([:positive])}.sql")
      File.write!(arq, @dump)
      on_exit(fn -> File.rm(arq) end)

      assert {:ok, r} = Feed.importar(arq)
      assert r == %{importados: 4}

      im = Feed.imovel("2")
      assert %{id: "2", nome: "Parque d'Agua", bairro: "Barra", regiao: "Zona Oeste", valor_centavos: 45_000_050, imagem: "b.jpg", atualizado_em: "2026-10-02 10:00:00"} = im
      assert %{dormitorios: nil} = im
      refute Map.has_key?(im, :status)
      # o estado da obra, se mantido, e so informativo
      assert Feed.imovel("1").estado_original == "Lancamento"
      # reimportar nao duplica
      assert {:ok, %{importados: 4}} = Feed.importar(arq)

      # a coluna de status saiu do desenho da tabela
      cols = Postgrex.query!(Registro, "SELECT column_name FROM information_schema.columns WHERE table_name = 'feed_imoveis'", []).rows |> List.flatten()
      refute "status" in cols
      assert "estado_original" in cols
    end

    test "imovel com estado_obra Esgotado/Vendido/Sold out: nenhum evento, nenhuma proposta, nenhum aviso, ativacao liberada" do
      arq0 = Path.join(System.tmp_dir!(), "tp6_feed0_#{System.unique_integer([:positive])}.sql")
      arq = Path.join(System.tmp_dir!(), "tp6_feed1_#{System.unique_integer([:positive])}.sql")
      File.write!(arq0, String.replace(@dump, ["ESGOTADO", "Vendido", "Sold out"], "Lancamento"))
      File.write!(arq, @dump)
      on_exit(fn -> File.rm(arq0); File.rm(arq) end)

      {:ok, _} = Feed.importar(arq0)
      {t, _pid, cid} = montar("; imovel 2")
      # o dump agora traz o imovel do plano com estado_obra ESGOTADO, mesmo antes de ativar
      {:ok, _} = Feed.importar(arq)

      refute function_exported?(Feed, :verificar_planos, 0)
      refute function_exported?(Feed, :verificar_planos, 1)
      refute function_exported?(Feed, :esgotado?, 1)

      # ativar nao e barrado por causa do imovel
      assert resp(Agente.processar(t, "pode ativar a campanha?")) =~ ~r/ativ.*confirma/s
      assert resp(Agente.processar(t, "sim, pode ativar")) =~ "ativa"
      assert status(cid)["status"] == "ATIVA"

      # e depois de ativa, importar de novo nao gera evento, proposta nem aviso
      {:ok, _} = Feed.importar(arq)
      assert [] == for(%{tipo: "operacao", dados: %{"ref" => "imovel_esgotado"}} <- Registro.eventos(t), do: 1)
      assert Proposta.abertas(t) == []
      assert status(cid)["status"] == "ATIVA"
      refute Enum.any?(avisos(), fn {tt, x} -> tt == t and x =~ ~r/esgotad|vendid/i end)
    end

    test "o codigo do trafego nao conhece mais 'esgotado'" do
      raiz = Path.expand("../packages/trafego/lib", __DIR__)
      achados = for arq <- Path.wildcard(raiz <> "/**/*.ex"), File.read!(arq) =~ ~r/esgotad|imovel_esgotado/i, do: Path.relative_to(arq, raiz)
      assert achados == []
      assert Trafego.Ativacao.explicar(["imovel_esgotado"]) == "imovel_esgotado"
    end
  end
end
