defmodule Nucleo.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    children = [
      {Postgrex, Nucleo.Registro.opcoes()},
      {DynamicSupervisor, name: Nucleo.Lacos, strategy: :one_for_one}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: Nucleo.Sup)
    Task.start(fn -> try do Nucleo.Registro.migrar!(); Nucleo.Inicializacao.validar_todos() rescue e -> require Logger; Logger.warning("inicializacao nao validou: " <> Exception.message(e)) end end)
    {:ok, sup}
  end
end
