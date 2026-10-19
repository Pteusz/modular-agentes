defmodule PainelBase.Banco do
  @moduledoc "Tabelas do painel (mesmo Postgres do registro). Idempotente. Nada de segredo em claro: senha em PBKDF2, tokens e sessoes so por hash SHA-256."

  def q(sql, params \\ []), do: Postgrex.query!(Nucleo.Registro, sql, params)

  def migrar! do
    for sql <- [
          """
          CREATE TABLE IF NOT EXISTS pb_usuarios (
            id bigserial PRIMARY KEY,
            tenant_id text NOT NULL,
            email text NOT NULL UNIQUE,
            nome text NOT NULL,
            senha_hash text,
            verificado_em timestamptz,
            ativo boolean NOT NULL DEFAULT true,
            criado_em timestamptz NOT NULL DEFAULT now()
          )
          """,
          """
          CREATE TABLE IF NOT EXISTS pb_tokens (
            id bigserial PRIMARY KEY,
            usuario_id bigint NOT NULL REFERENCES pb_usuarios(id) ON DELETE CASCADE,
            tipo text NOT NULL,
            token_hash text NOT NULL UNIQUE,
            expira_em timestamptz NOT NULL,
            usado_em timestamptz,
            criado_em timestamptz NOT NULL DEFAULT now()
          )
          """,
          """
          CREATE TABLE IF NOT EXISTS pb_sessoes (
            id bigserial PRIMARY KEY,
            usuario_id bigint NOT NULL REFERENCES pb_usuarios(id) ON DELETE CASCADE,
            token_hash text NOT NULL UNIQUE,
            expira_em timestamptz NOT NULL,
            criado_em timestamptz NOT NULL DEFAULT now()
          )
          """,
          """
          CREATE TABLE IF NOT EXISTS pb_tentativas (
            id bigserial PRIMARY KEY,
            chave text NOT NULL,
            em timestamptz NOT NULL DEFAULT now()
          )
          """,
          "CREATE INDEX IF NOT EXISTS pb_tentativas_chave ON pb_tentativas (chave, em)",
          # auditoria das acoes sensiveis do proprio usuario na tela Conta: quem, quando e so NOMES de campos (nunca valores)
          """
          CREATE TABLE IF NOT EXISTS pb_auditoria (
            id bigserial PRIMARY KEY,
            usuario_id bigint NOT NULL,
            tenant_id text NOT NULL,
            acao text NOT NULL,
            detalhes jsonb NOT NULL DEFAULT '{}'::jsonb,
            em timestamptz NOT NULL DEFAULT now()
          )
          """,
          "CREATE INDEX IF NOT EXISTS pb_auditoria_usuario ON pb_auditoria (usuario_id, id)"
        ] do
      q(sql)
    end

    :ok
  end
end
