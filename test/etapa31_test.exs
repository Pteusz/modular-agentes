# Teste geral da etapa 3.1 (pacotes separados + encaixe checado ao atualizar). Rodar: MIX_ENV=test mix test
defmodule Etapa31Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Manifesto, Canal}
  alias Nucleo.Automacoes.Eco

  @cliente "/opt/modular-agentes-cliente-exemplo/t31"
  @raiz Path.expand("..", __DIR__)

  # automacao de teste B: exige Eco MAJOR 1
  defmodule B do
    @behaviour Nucleo.Automacao
    def versao, do: "1.0.0"
    def contrato, do: %{versao: "1.0", oferece: %{"b" => "1.0"}, exige: %{"registro" => "1.0", "eco" => "1.0"}}
    def referencial, do: %{tipo: :decidivel, regras: [:r1]}
    def retencao, do: [%{chave: "b", leitura: :ultimo}]
    def aprovacao, do: []
  end

  # novas versoes candidatas da Eco (contrato 1.0 do nucleo; oferta "eco" muda)
  for {nome, v, oferta} <- [{EcoV11, "1.1.0", "1.1"}, {EcoV20, "2.0.0", "2.0"}] do
    defmodule nome do
      @behaviour Nucleo.Automacao
      @v v
      @oferta oferta
      def versao, do: @v
      def contrato, do: %{Eco.contrato() | oferece: %{"eco" => @oferta}}
      defdelegate referencial, to: Eco
      defdelegate retencao, to: Eco
      defdelegate aprovacao, to: Eco
    end
  end

  setup_all do
    Registro.migrar!()
    # limpa tenants de teste (ta*, tb*) para nao acumular no banco
    for t <- ["estado", "eventos", "vinculos"],
        do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'ta%' OR tenant_id LIKE 'tb%'", [])

    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'ta%' OR id LIKE 'tb%'", [])
    :ok
  end

  defp sh(dir, cmd), do: sh(dir, cmd, [])
  defp sh(dir, cmd, env) do
    {out, st} = System.cmd("bash", ["-c", cmd], cd: dir, env: env, stderr_to_stdout: true)
    assert st == 0, "falhou: #{cmd}\n#{out}"
    out
  end

  defp lock(dir), do: dir |> Path.join("mix.lock") |> File.read!() |> String.split("\n", trim: true)

  @tag timeout: 600_000
  test "parte A: cliente fixa nucleo e Eco por tag; trocar so a tag da Eco muda so a Eco; manifesto bate com o carregado" do
    File.rm_rf!(@cliente)
    mono = Path.join(@cliente, "mono")
    cli = Path.join(@cliente, "cliente")
    File.mkdir_p!(mono)
    File.mkdir_p!(cli)
    url = "file://" <> mono
    git = "git -c user.email=t@t -c user.name=t"

    # monorepo de teste = copia dos pacotes reais; tags por pacote
    sh(mono, "cp -r #{@raiz}/packages . && sed -i 's/@version \"1.5.1\"/@version \"1.0.0\"/' packages/nucleo/mix.exs && #{git} init -q && git add -A && #{git} commit -qm v1 && git tag nucleo-1.0.0 && git tag eco-1.0.0")
    sh(mono, "sed -i 's/@version \"1.0.0\"/@version \"1.0.1\"/' packages/eco/mix.exs && git add -A && #{git} commit -qm eco101 && git tag eco-1.0.1")

    File.write!(Path.join(cli, "mix.exs"), """
    defmodule Cliente.MixProject do
      use Mix.Project
      @git "#{url}"
      def project, do: [app: :cliente, version: "0.1.0", elixir: "~> 1.19", deps: [
        {:nucleo, git: @git, sparse: "packages/nucleo", tag: "nucleo-1.0.0"},
        {:eco, git: @git, sparse: "packages/eco", tag: System.get_env("ECO_TAG", "eco-1.0.0")}]]
    end
    """)

    File.cp!(Path.join(@raiz, "packages/nucleo/mix.lock"), Path.join(cli, "mix.lock"))
    env = [{"NUCLEO_GIT", url}, {"MIX_ENV", "dev"}, {"NUCLEO_LOCAL", nil}]
    sh(cli, "mix deps.get", env)
    l1 = lock(cli)
    assert Enum.any?(l1, &(&1 =~ ~s("eco": {:git)))
    assert Enum.any?(l1, &(&1 =~ ~s("nucleo": {:git)))

    valida = fn declarado, env ->
      sh(cli, "mix run --no-start -e 'Application.load(:nucleo); Application.load(:eco); IO.inspect(Nucleo.Manifesto.validar(#{declarado}))' | tail -1", env)
    end

    assert valida.(~s(%{nucleo: "1.0.0", eco: "1.0.0"}), env) =~ ":ok"

    # divergencia (manifesto declara outra versao) e erro
    assert valida.(~s(%{nucleo: "1.0.0", eco: "1.0.1"}), env) =~ "error"

    # troca so a tag da Eco
    env2 = [{"ECO_TAG", "eco-1.0.1"} | env]
    sh(cli, "mix deps.update eco", env2)
    l2 = lock(cli)
    mudou = (l1 -- l2) ++ (l2 -- l1)
    assert mudou != [] and Enum.all?(mudou, &(&1 =~ ~s("eco":)))
    assert valida.(~s(%{nucleo: "1.0.0", eco: "1.0.1"}), env2) =~ ":ok"
  end

  test "parte B: atualizar Eco para 1.1 e aceito; para 2.0 e recusado com evento, estado e manifesto intactos" do
    sfx = System.unique_integer([:positive])
    t = "ta31_#{sfx}"
    sem_eco = "tb31_#{sfx}"
    eco = "Nucleo.Automacoes.Eco"

    # B exige eco 1.x: sem Eco vinculada no tenant, e recusada; com Eco, passa
    assert {:error, {:incompativel, _}} = Vincular.vincular(sem_eco, B, Canal.Simulado, %{})
    assert {:ok, :criado} = Vincular.vincular(t, Eco, Canal.Simulado, %{})
    assert {:ok, :criado} = Vincular.vincular(t, B, Canal.Simulado, %{})
    Registro.gravar(t, "contagem", %{"n" => 7})

    # 1.1 mantem MAJOR 1 e MINOR >= 0: aceito para todos os vinculos
    assert {:ok, ts} = Vincular.atualizar(eco, EcoV11, %{})
    assert t in ts
    assert %{versao: "1.1.0"} = Registro.vinculo(t, eco)

    antes = {Registro.vinculos(), Manifesto.gerar(), Registro.ler(t, "contagem"), Registro.eventos(t)}

    # 2.0 quebra B (exige eco 1): recusa inteira, evento com o vinculo que quebraria
    assert {:error, {:incompativel, qs}} = Vincular.atualizar(eco, EcoV20, %{})
    assert [q] = Enum.filter(qs, &(&1.tenant == t))
    assert q.tenant == t and q.automacao == inspect(B) and hd(q.motivos) =~ "eco"
    ev = Registro.eventos(t) |> Enum.filter(&(&1.tipo == "atualizacao_recusada"))
    assert [%{dados: %{"automacao" => ^eco, "versao" => "2.0.0", "vinculo" => %{"tenant" => ^t, "automacao" => b}}}] = ev
    assert b == inspect(B)

    {v, m, c, evs} = antes
    assert Registro.vinculos() == v
    assert Manifesto.gerar() == m
    assert Registro.ler(t, "contagem") == c
    assert c == %{"n" => 7}
    assert Enum.map(Registro.eventos(t) -- evs, & &1.tipo) == ["atualizacao_recusada"]
    assert %{versao: "1.1.0"} = Registro.vinculo(t, eco)
  end

  # automacao de teste cujo codigo carregado exige uma versao do Eco configuravel (simula "versao carregada diferente")
  defmodule BNovo do
    @behaviour Nucleo.Automacao
    def versao, do: "1.1.0"
    def contrato,
      do: %{versao: "1.0", oferece: %{}, exige: %{"registro" => "1.0", "eco" => Application.get_env(:nucleo, :exige_eco_teste, "2.0")}}
    def referencial, do: %{tipo: :decidivel, regras: [:r1]}
    def retencao, do: []
    def aprovacao, do: []
  end

  defp espera(fun), do: espera(fun, 100)
  defp espera(fun, n) do
    cond do
      fun.() -> true
      n == 0 -> false
      true -> Process.sleep(20); espera(fun, n - 1)
    end
  end

  defp estado(t, a), do: Registro.contratos(t) |> Enum.find(&(&1.automacao == a)) |> Map.get(:estado)
  defp tipos(t), do: Registro.eventos(t) |> Enum.map(& &1.tipo)

  test "parte B.2: inicializacao com versao carregada incompativel desativa so aquele vinculo; compativel atualiza; volta sozinho" do
    sfx = System.unique_integer([:positive])
    {t1, t2, t3} = {"ta31i_#{sfx}", "tb31i_#{sfx}", "tb31j_#{sfx}"}
    eco = "Nucleo.Automacoes.Eco"
    bn = inspect(BNovo)
    sim = inspect(Canal.Simulado)
    Application.put_env(:nucleo, :exige_eco_teste, "2.0")
    on_exit(fn -> Application.delete_env(:nucleo, :exige_eco_teste) end)

    # contrato antigo registrado (compativel); o codigo carregado agora exige eco 2.0
    antigo = %{versao: "1.0", oferece: %{}, exige: %{"registro" => "1.0", "eco" => "1.0"}}
    for t <- [t1, t2, t3], do: Registro.criar_tenant(t)
    for t <- [t1, t2], do: {:ok, :criado} = Vincular.vincular(t, Eco, Canal.Simulado, %{})
    Registro.gravar_vinculo(t1, bn, "0.9.0", sim, antigo)
    Registro.gravar_vinculo(t3, bn, "0.9.0", sim, antigo)
    {:ok, :criado} = Vincular.vincular(t2, B, Canal.Simulado, %{})
    # t2: vinculo sem contrato (como o do tenant mateus) e outro com versao de codigo defasada
    Postgrex.query!(Registro, "UPDATE vinculos SET contrato=NULL, versao='0.9.0' WHERE tenant_id=$1 AND automacao=$2", [t2, eco])
    Postgrex.query!(Registro, "UPDATE vinculos SET versao='0.5.0' WHERE tenant_id=$1 AND automacao=$2", [t2, inspect(B)])

    assert :ok = Nucleo.Inicializacao.validar_todos()

    # incompativel: inativo so naquele tenant/automacao, com evento; a Eco do mesmo tenant segue ativa
    assert estado(t1, bn) == "inativo_incompativel"
    assert estado(t1, eco) == "ativo"
    assert estado(t3, bn) == "inativo_incompativel"
    assert "inativo_incompativel" in tipos(t1)
    assert {t1, bn} in Registro.inativos()

    # outro tenant segue: sem contrato recebe o carregado; versao defasada com contrato compativel so atualiza a versao
    assert estado(t2, eco) == "ativo" and estado(t2, inspect(B)) == "ativo"
    assert "contrato_registrado" in tipos(t2) and "versao_registrada_atualizada" in tipos(t2)
    assert %{versao: "1.0.0"} = Registro.vinculo(t2, inspect(B))
    assert Enum.find(Registro.contratos(t2), &(&1.automacao == eco)).contrato["oferece"] == %{"eco" => "1.0"}

    # a automacao inativa nao roda para o tenant (t3); o tenant t2 segue respondendo
    {:ok, l3} = Nucleo.Laco.iniciar(t3)
    Canal.Simulado.injetar(Nucleo.Laco.canal(l3), :proprio, "oi")
    Process.sleep(200)
    assert Canal.Simulado.enviadas(Nucleo.Laco.canal(l3)) == []
    {:ok, l2} = Nucleo.Laco.iniciar(t2)
    Canal.Simulado.injetar(Nucleo.Laco.canal(l2), :proprio, "oi")
    assert espera(fn -> Canal.Simulado.enviadas(Nucleo.Laco.canal(l2)) == ["[agente] eco #1: oi"] end)

    # na proxima inicializacao volta a ser compativel: reativa sozinho, sem apagar dados
    Application.put_env(:nucleo, :exige_eco_teste, "1.0")
    Nucleo.Inicializacao.validar_todos()
    assert estado(t1, bn) == "ativo" and "vinculo_reativado" in tipos(t1)
    assert %{versao: "1.1.0"} = Registro.vinculo(t1, bn)
  end
end
