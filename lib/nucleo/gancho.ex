defmodule Nucleo.Gancho do
  @moduledoc "Gancho: toda acao do laco passa aqui antes de executar. Esqueleto: registra e libera, salvo bloqueio por config."
  alias Nucleo.Registro

  @doc "`aprovacao`: acoes que exigem aprovacao do usuario (config `aprovado_<acao>` do tenant a libera)."
  def intercepta(tenant, acao), do: intercepta(tenant, acao, [])
  def intercepta(tenant, {tipo, _dados}, aprovacao) do
    cfg = Registro.config(tenant)

    resultado =
      cond do
        cfg["bloquear_#{tipo}"] -> {:bloquear, "config"}
        tipo in aprovacao and !cfg["aprovado_#{tipo}"] -> {:bloquear, "requer_aprovacao"}
        true -> :ok
      end

    Registro.evento(tenant, "gancho", %{"acao" => to_string(tipo), "resultado" => inspect(resultado)})
    resultado
  end
end
