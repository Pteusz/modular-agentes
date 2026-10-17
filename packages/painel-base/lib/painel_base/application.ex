defmodule PainelBase.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    # Swoosh so para SMTP (gen_smtp): sem cliente HTTP, entao sem hackney.
    Application.put_env(:swoosh, :api_client, false)
    {:ok, _} = Application.ensure_all_started(:swoosh)
    # o log de requisicoes do Phoenix nunca mostra senha, token de link nem CSRF
    # o Phoenix ja compilou o filtro no boot; trocamos por lista (ele recompila a cada uso)
    Application.put_env(:phoenix, :filter_parameters, ~w(senha senha_confirmacao password token _csrf_token))
    PainelBase.Config.preparar_endpoint()
    PainelBase.Banco.migrar!()

    children = [{Phoenix.PubSub, name: PainelBase.PubSub}, PainelBase.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: PainelBase.Sup)
  end
end
