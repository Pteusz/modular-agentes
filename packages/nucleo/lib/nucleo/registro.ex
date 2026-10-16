defmodule Nucleo.Registro do
  @moduledoc "Registro: estado versionado por tenant (so inserts), eventos e vinculos. Fica no Postgres, fora do codigo."
  Postgrex.Types.define(Nucleo.PgTipos, [], json: Jason)

  def opcoes do
    u = URI.parse(System.get_env("DATABASE_URL") || "ecto://modular:modular@localhost/modular_agentes")
    [user, pass] = String.split(u.userinfo, ":", parts: 2)

    [name: __MODULE__, hostname: u.host, port: u.port || 5432, username: user, password: pass,
     database: String.trim_leading(u.path, "/"), types: Nucleo.PgTipos, pool_size: 5]
  end

  defp q(sql, params \\ []), do: Postgrex.query!(__MODULE__, sql, params)

  def migrar! do
    for sql <- [
          "CREATE TABLE IF NOT EXISTS tenants (id text PRIMARY KEY, criado_em timestamptz NOT NULL DEFAULT now())",
          """
          CREATE TABLE IF NOT EXISTS estado (tenant_id text NOT NULL REFERENCES tenants(id), chave text NOT NULL,
            versao int NOT NULL, valor jsonb NOT NULL, em timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (tenant_id, chave, versao))
          """,
          """
          CREATE TABLE IF NOT EXISTS eventos (id bigserial PRIMARY KEY, tenant_id text NOT NULL REFERENCES tenants(id),
            tipo text NOT NULL, dados jsonb NOT NULL DEFAULT '{}', em timestamptz NOT NULL DEFAULT now())
          """,
          """
          CREATE TABLE IF NOT EXISTS vinculos (tenant_id text NOT NULL REFERENCES tenants(id), automacao text NOT NULL,
            versao text NOT NULL, canal text NOT NULL, em timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (tenant_id, automacao))
          """
        ],
        do: q(sql)

    q("ALTER TABLE vinculos ADD COLUMN IF NOT EXISTS contrato jsonb")
    :ok
  end

  def criar_tenant(id), do: q("INSERT INTO tenants (id) VALUES ($1) ON CONFLICT DO NOTHING", [id]).num_rows == 1

  def gravar(tenant, chave, valor) do
    r =
      q(
        """
        INSERT INTO estado (tenant_id, chave, versao, valor)
        SELECT $1::text, $2::text, COALESCE(MAX(versao), 0) + 1, $3::jsonb FROM estado WHERE tenant_id = $1 AND chave = $2
        RETURNING versao
        """,
        [tenant, chave, valor]
      )

    {:ok, hd(hd(r.rows))}
  end

  def ler(tenant, chave) do
    r = q("SELECT valor FROM estado WHERE tenant_id=$1 AND chave=$2 ORDER BY versao DESC LIMIT 1", [tenant, chave])

    case r.rows do
      [[v]] -> v
      [] -> nil
    end
  end

  def historico(tenant, chave) do
    q("SELECT versao, valor FROM estado WHERE tenant_id=$1 AND chave=$2 ORDER BY versao", [tenant, chave]).rows
    |> Enum.map(fn [v, val] -> %{versao: v, valor: val} end)
  end

  def config(tenant), do: ler(tenant, "config") || %{}

  def config(tenant, mapa) do
    gravar(tenant, "config", Map.merge(config(tenant), mapa))
    :ok
  end

  def evento(tenant, tipo, dados \\ %{}) do
    q("INSERT INTO eventos (tenant_id, tipo, dados) VALUES ($1,$2,$3)", [tenant, tipo, dados])
    :ok
  end

  def eventos(tenant) do
    q("SELECT tipo, dados, em FROM eventos WHERE tenant_id=$1 ORDER BY id", [tenant]).rows
    |> Enum.map(fn [t, d, em] -> %{tipo: t, dados: d, em: em} end)
  end

  def eventos_recentes(tenant, tipo, segundos) do
    q("SELECT count(*) FROM eventos WHERE tenant_id=$1 AND tipo=$2 AND em > now() - make_interval(secs => $3)", [
      tenant,
      tipo,
      segundos * 1.0
    ]).rows
    |> hd()
    |> hd()
  end

  def vinculo(tenant, automacao) do
    case q("SELECT versao, canal FROM vinculos WHERE tenant_id=$1 AND automacao=$2", [tenant, automacao]).rows do
      [[v, c]] -> %{versao: v, canal: c}
      [] -> nil
    end
  end

  def vinculos do
    q("SELECT tenant_id, automacao, versao, canal FROM vinculos ORDER BY 1,2").rows
    |> Enum.map(fn [t, a, v, c] -> %{tenant: t, automacao: a, versao: v, canal: c} end)
  end

  def gravar_vinculo(tenant, automacao, versao, canal), do: gravar_vinculo(tenant, automacao, versao, canal, nil)

  @doc "Grava o vinculo; contrato (mapa) e o encaixe registrado da versao. Sem contrato, mantem o anterior."
  def gravar_vinculo(tenant, automacao, versao, canal, contrato) do
    q(
      """
      INSERT INTO vinculos (tenant_id, automacao, versao, canal, contrato) VALUES ($1,$2,$3,$4,$5)
      ON CONFLICT (tenant_id, automacao) DO UPDATE SET versao = EXCLUDED.versao, canal = EXCLUDED.canal,
        contrato = COALESCE(EXCLUDED.contrato, vinculos.contrato)
      """,
      [tenant, automacao, versao, canal, contrato]
    )

    :ok
  end

  @doc "Contratos registrados dos vinculos do tenant: [%{automacao, contrato}] (contrato nil se vinculado so por versao)."
  def contratos(tenant) do
    q("SELECT automacao, contrato FROM vinculos WHERE tenant_id=$1 ORDER BY 1", [tenant]).rows
    |> Enum.map(fn [a, c] -> %{automacao: a, contrato: c} end)
  end

  def tenants_da(automacao), do: q("SELECT tenant_id FROM vinculos WHERE automacao=$1 ORDER BY 1", [automacao]).rows |> List.flatten()
end
