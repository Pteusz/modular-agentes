defmodule Nucleo.Gancho do
  @moduledoc "Gancho: toda acao do laco passa aqui antes de executar. Esqueleto: registra e libera, salvo bloqueio por config."
  alias Nucleo.Registro

  def intercepta(tenant, {tipo, _dados}) do
    resultado = if Registro.config(tenant)["bloquear_#{tipo}"], do: {:bloquear, "config"}, else: :ok
    Registro.evento(tenant, "gancho", %{"acao" => to_string(tipo), "resultado" => inspect(resultado)})
    resultado
  end
end
