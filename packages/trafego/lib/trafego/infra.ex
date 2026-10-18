defmodule Trafego.Repo do
  @moduledoc "Repo Ecto SO para o Oban (fila de tarefas agendadas). Mesmo Postgres do registro; URL de DATABASE_URL. Tabela de migracao propria."
  use Ecto.Repo, otp_app: :trafego, adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_tipo, cfg) do
    url = System.get_env("DATABASE_URL") || "ecto://modular:modular@localhost/modular_agentes"
    {:ok, cfg |> Keyword.put(:url, url) |> Keyword.put_new(:pool_size, 3) |> Keyword.put(:migration_source, "trafego_schema_migrations")}
  end
end

defmodule Trafego.MigracaoOban do
  @moduledoc false
  use Ecto.Migration
  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down(version: 1)
end

defmodule Trafego.Application do
  @moduledoc """
  Sobe o Repo e o Oban do pacote. Fila e cron so ficam ligados com TRAFEGO_AGENDADOR=1 (producao); sem isso o Oban sobe parado
  (e em teste roda :inline por config, sem gravar no banco). Tabelas do pacote e do Oban sao criadas de forma idempotente.
  """
  use Application

  @impl true
  def start(_tipo, _args) do
    Trafego.Banco.migrar!()

    children = [
      Trafego.Repo,
      %{id: :migrar_oban, start: {Trafego.Banco, :migrar_oban, []}},
      {Oban, oban_config()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Trafego.Supervisor)
  end

  def oban_config do
    base =
      if System.get_env("TRAFEGO_AGENDADOR") == "1",
        do: [queues: [trafego: 3], plugins: [{Oban.Plugins.Cron, crontab: Trafego.Agendador.crontab()}, {Oban.Plugins.Pruner, max_age: 86_400}]],
        else: [queues: [], plugins: []]

    Keyword.merge([repo: Trafego.Repo] ++ base, Application.get_env(:trafego, :oban_opts, []))
  end
end

defmodule Trafego.Banco do
  @moduledoc "Tabelas do pacote (mesmo Postgres do registro). Idempotente. feed_imoveis e trafego_cotacao levam `fonte` para o teste usar a propria fonte sem tocar nos dados reais."

  def q(sql, params \\ []), do: Postgrex.query!(Nucleo.Registro, sql, params)

  def migrar! do
    q("""
    CREATE TABLE IF NOT EXISTS trafego_cotacao (
      fonte text NOT NULL, data date NOT NULL, usd_brl double precision NOT NULL, obtida_em timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (fonte, data)
    )
    """)

    q("""
    CREATE TABLE IF NOT EXISTS feed_imoveis (
      fonte text NOT NULL, id text NOT NULL, nome text, bairro text, regiao text, dormitorios text, valor_centavos bigint,
      status text NOT NULL, estado_original text, imagem text, atualizado_em text, importado_em timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (fonte, id)
    )
    """)

    :ok
  end

  @doc "Filho de supervisao: roda a migracao do Oban de forma sincrona e nao deixa processo (:ignore)."
  def migrar_oban do
    Ecto.Migrator.run(Trafego.Repo, [{20_260_101_000_001, Trafego.MigracaoOban}], :up, all: true, log: false)
    :ignore
  end
end

defmodule Trafego.Agendador do
  @moduledoc "Tarefas agendadas (Oban Cron, horario UTC): monitor a cada 30 min, cotacao PTAX diaria, feed de imoveis de hora em hora."
  def crontab, do: [{"*/30 * * * *", Trafego.Workers.Monitor}, {"30 17 * * *", Trafego.Workers.Cotacao}, {"5 * * * *", Trafego.Workers.Feed}]
end

defmodule Trafego.Workers.Monitor do
  @moduledoc "Avalia as campanhas ativas de todos os tenants do trafego (args \"tenants\" restringe, para teste). Nunca altera campanha: so evento, aviso e proposta."
  use Oban.Worker, queue: :trafego, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Trafego.Monitor.rodar_todos(tenants: args["tenants"])
    :ok
  end
end

defmodule Trafego.Workers.Cotacao do
  @moduledoc "Busca a cotacao PTAX do dia. Falha da fonte nao derruba nada: vale a ultima conhecida (o custo marca a data)."
  use Oban.Worker, queue: :trafego, max_attempts: 3

  @impl Oban.Worker
  def perform(_job), do: (case Trafego.Cotacao.atualizar() do {:ok, _} -> :ok; {:error, e} -> {:error, e} end)
end

defmodule Trafego.Workers.Feed do
  @moduledoc "Importa o dump .sql mais recente de Trafego.Config.feed_dir e confere os planos com imovel (esgotado -> evento e proposta de pausar)."
  use Oban.Worker, queue: :trafego, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    case Trafego.Feed.importar_do_diretorio() do
      {:ok, _} -> Trafego.Feed.verificar_planos()
      {:error, :sem_arquivo} -> :ok
      {:error, e} -> {:error, e}
    end
  end
end

defmodule Trafego.Notificar do
  @moduledoc "Aviso proativo ao corretor (chat dele consigo mesmo, pelo laco). `config :trafego, :notificar` (fn tenant, texto) troca o destino, para teste."
  alias Nucleo.Registro

  def enviar(tenant, texto) do
    case Application.get_env(:trafego, :notificar) do
      f when is_function(f, 2) ->
        f.(tenant, texto)

      _ ->
        if Code.ensure_loaded?(Nucleo.Laco) and function_exported?(Nucleo.Laco, :avisar, 2) do
          with {:error, e} <- Nucleo.Laco.avisar(tenant, texto), do: Registro.evento(tenant, "aviso_nao_enviado", %{"erro" => inspect(e)})
        else
          Registro.evento(tenant, "aviso_nao_enviado", %{"erro" => "laco_sem_avisar"})
        end
    end

    :ok
  end
end
