defmodule GestaoEquipe.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    GestaoEquipe.Banco.migrar!()
    # registra as telas no painel-base (o painel nao sabe quem e)
    ext = Application.get_env(:painel_base, :extensoes, [])
    Application.put_env(:painel_base, :extensoes, Keyword.put(ext, :equipe, GestaoEquipe.Router))
    Supervisor.start_link([], strategy: :one_for_one, name: GestaoEquipe.Sup)
  end
end
