defmodule PainelBase.Sessoes do
  @moduledoc "Sessao no servidor: o cookie leva so um token aleatorio; aqui fica o hash, o dono e a validade. Sair ou trocar a senha revoga."
  import PainelBase.Banco, only: [q: 2]
  alias PainelBase.Tokens

  @ttl 12 * 3600

  def criar(usuario_id) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    q("INSERT INTO pb_sessoes (usuario_id, token_hash, expira_em) VALUES ($1,$2, now() + make_interval(secs => $3))", [usuario_id, Tokens.hash(token), @ttl * 1.0])
    token
  end

  @doc "Usuario da sessao (ativo e verificado) ou nil. O tenant vem DAQUI, nunca de parametro da requisicao."
  def usuario(token) when is_binary(token) do
    case q(
           """
           SELECT u.id, u.tenant_id, u.email, u.nome FROM pb_sessoes s JOIN pb_usuarios u ON u.id = s.usuario_id
           WHERE s.token_hash=$1 AND s.expira_em > now() AND u.ativo AND u.verificado_em IS NOT NULL
           """,
           [Tokens.hash(token)]
         ).rows do
      [[id, tenant, email, nome]] -> %{id: id, tenant_id: tenant, email: email, nome: nome}
      _ -> nil
    end
  end

  def usuario(_), do: nil

  def revogar(token) when is_binary(token), do: q("DELETE FROM pb_sessoes WHERE token_hash=$1", [Tokens.hash(token)]) && :ok
  def revogar(_), do: :ok
  def revogar_todas(usuario_id), do: q("DELETE FROM pb_sessoes WHERE usuario_id=$1", [usuario_id]) && :ok
end
