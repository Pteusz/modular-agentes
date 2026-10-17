defmodule PainelBase.Tokens do
  @moduledoc "Tokens de uso unico (convite, verificacao de e-mail, recuperacao). O banco guarda so o SHA-256; o valor em claro so existe no e-mail."
  import PainelBase.Banco, only: [q: 2]

  @ttl %{"convite" => 7 * 86_400, "verificacao" => 2 * 86_400, "recuperacao" => 3_600}

  def hash(token), do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

  @doc "Cria um token novo (invalida os pendentes do mesmo tipo para o usuario) e devolve o valor em claro."
  def criar(usuario_id, tipo) when is_map_key(@ttl, tipo) do
    q("UPDATE pb_tokens SET usado_em = now() WHERE usuario_id=$1 AND tipo=$2 AND usado_em IS NULL", [usuario_id, tipo])
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    q("INSERT INTO pb_tokens (usuario_id, tipo, token_hash, expira_em) VALUES ($1,$2,$3, now() + make_interval(secs => $4))", [usuario_id, tipo, hash(token), @ttl[tipo] * 1.0])
    token
  end

  @doc "Olha sem gastar: {:ok, usuario_id} | :invalido"
  def ver(token, tipo) when is_binary(token) do
    case q("SELECT usuario_id FROM pb_tokens WHERE token_hash=$1 AND tipo=$2 AND usado_em IS NULL AND expira_em > now()", [hash(token), tipo]).rows do
      [[id]] -> {:ok, id}
      _ -> :invalido
    end
  end

  def ver(_, _), do: :invalido

  @doc "Gasta atomicamente (duas requisicoes simultaneas nao passam as duas): {:ok, usuario_id} | :invalido"
  def consumir(token, tipo) when is_binary(token) do
    case q("UPDATE pb_tokens SET usado_em = now() WHERE token_hash=$1 AND tipo=$2 AND usado_em IS NULL AND expira_em > now() RETURNING usuario_id", [hash(token), tipo]).rows do
      [[id]] -> {:ok, id}
      _ -> :invalido
    end
  end

  def consumir(_, _), do: :invalido
end
