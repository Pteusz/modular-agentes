defmodule GestaoEquipe.Auditoria do
  @moduledoc "Log de auditoria da equipe: quem fez o que e em qual corretor (tenant). Detalhes so com NOMES de campos, nunca valores pessoais."
  import GestaoEquipe.Banco, only: [q: 2]

  def registrar(ator, acao, alvo, detalhes \\ %{}) do
    q("INSERT INTO ge_auditoria (equipe, ator_usuario_id, ator_nome, acao, alvo, detalhes) VALUES ($1,$2,$3,$4,$5,$6)", [
      GestaoEquipe.Papeis.equipe(ator),
      ator.id,
      ator.nome,
      acao,
      alvo,
      detalhes
    ])

    :ok
  end

  def listar(equipe, limite) do
    q("SELECT id, em, ator_nome, acao, alvo, detalhes FROM ge_auditoria WHERE equipe=$1 ORDER BY id DESC LIMIT $2", [equipe, limite]).rows
    |> Enum.map(fn [id, em, ator, acao, alvo, det] -> %{id: id, em: em, ator_nome: ator, acao: acao, alvo: alvo, detalhes: det} end)
  end
end
