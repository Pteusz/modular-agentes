defmodule GestaoEquipe.Banco do
  @moduledoc """
  Tabelas da gestao (mesmo Postgres do registro). Idempotente.
    * ge_papeis: quem e dono/admin (corretor nao tem linha).
    * ge_corretores: cadastro. Credenciais so CIFRADAS (JSON cifrado com a cifra do trafego, tenant como AAD). `equipe` = tenant do
      dono/admins: cada equipe so enxerga os proprios corretores. Depois de excluir, todos os campos pessoais ficam NULL (a linha fica so como tumulo).
    * ge_auditoria: fato + ids + NOMES de campos, nunca valores pessoais.
  """
  def q(sql, params \\ []), do: Postgrex.query!(Nucleo.Registro, sql, params)

  def migrar! do
    for sql <- [
          """
          CREATE TABLE IF NOT EXISTS ge_papeis (
            usuario_id bigint PRIMARY KEY REFERENCES pb_usuarios(id) ON DELETE CASCADE,
            papel text NOT NULL CHECK (papel IN ('dono','admin')),
            criado_por bigint,
            criado_em timestamptz NOT NULL DEFAULT now()
          )
          """,
          """
          CREATE TABLE IF NOT EXISTS ge_corretores (
            id bigserial PRIMARY KEY,
            equipe text NOT NULL,
            tenant_id text NOT NULL UNIQUE,
            usuario_id bigint,
            nome text, sobrenome text, usuario text, email text, numero text, filiacao text, site text,
            credenciais_cifradas text,
            status text NOT NULL DEFAULT 'ativo' CHECK (status IN ('ativo','desativado','excluido')),
            criado_por bigint,
            criado_em timestamptz NOT NULL DEFAULT now(),
            atualizado_em timestamptz NOT NULL DEFAULT now()
          )
          """,
          "CREATE UNIQUE INDEX IF NOT EXISTS ge_corretores_usuario ON ge_corretores (lower(usuario))",
          "CREATE UNIQUE INDEX IF NOT EXISTS ge_corretores_email ON ge_corretores (lower(email))",
          "CREATE UNIQUE INDEX IF NOT EXISTS ge_corretores_numero ON ge_corretores (numero)",
          """
          CREATE TABLE IF NOT EXISTS ge_auditoria (
            id bigserial PRIMARY KEY,
            em timestamptz NOT NULL DEFAULT now(),
            equipe text,
            ator_usuario_id bigint,
            ator_nome text,
            acao text NOT NULL,
            alvo text,
            detalhes jsonb NOT NULL DEFAULT '{}'
          )
          """
        ],
        do: q(sql)

    :ok
  end
end
