defmodule Nucleo.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    children = [
      {Postgrex, Nucleo.Registro.opcoes()},
      {DynamicSupervisor, name: Nucleo.Lacos, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Nucleo.Sup)
  end
end
