defmodule GestaoEquipe.Papeis do
  @moduledoc "Papeis da equipe: dono (cria admins) e admin (cadastra corretores). Quem nao tem linha aqui e corretor."
  import GestaoEquipe.Banco, only: [q: 2]

  def papel(%{id: id}) when is_integer(id) do
    case q("SELECT papel FROM ge_papeis WHERE usuario_id=$1", [id]).rows do
      [["dono"]] -> :dono
      [["admin"]] -> :admin
      _ -> nil
    end
  end

  def papel(_), do: nil

  @doc "Define o dono (bootstrap: mix equipe.dono). O dono e um usuario ja existente do painel."
  def definir_dono(%{id: id}) do
    q("INSERT INTO ge_papeis (usuario_id, papel) VALUES ($1,'dono') ON CONFLICT (usuario_id) DO UPDATE SET papel='dono'", [id])
    :ok
  end

  def definir_admin(%{id: id}, por, equipe) do
    q("INSERT INTO ge_papeis (usuario_id, papel, criado_por, equipe) VALUES ($1,'admin',$2,$3) ON CONFLICT (usuario_id) DO NOTHING", [id, por.id, equipe])
    :ok
  end

  @doc """
  A equipe do dono/admin: o tenant do dono. Cada um tem tenant PROPRIO (WhatsApp, campanhas, conversa); a equipe so reune quem gere os corretores.
  Papel antigo sem equipe gravada = o tenant do proprio usuario (o dono sempre foi o tenant da equipe).
  """
  def equipe(%{id: id, tenant_id: t}) when is_integer(id) do
    case q("SELECT equipe FROM ge_papeis WHERE usuario_id=$1", [id]).rows do
      [[e]] when is_binary(e) -> e
      _ -> t
    end
  end

  def admins(equipe) do
    q("SELECT u.id, u.nome, u.email, p.papel FROM ge_papeis p JOIN pb_usuarios u ON u.id=p.usuario_id WHERE COALESCE(p.equipe, u.tenant_id)=$1 ORDER BY p.papel, u.nome", [equipe]).rows
    |> Enum.map(fn [id, nome, email, papel] -> %{id: id, nome: nome, email: email, papel: papel} end)
  end
end
