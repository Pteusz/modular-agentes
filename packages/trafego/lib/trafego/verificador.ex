defmodule Trafego.Verificador do
  @moduledoc "Verificador decidivel: le de volta da plataforma e confere com o plano pelas regras do referencial. Divergencia vira evento e registro de aprendizado."
  alias Nucleo.Verificador, as: V
  alias Trafego.{Acesso, Aprendizado, Evento, Plano}

  def verificar(tenant, plano_id) do
    plano = Plano.ler(tenant, plano_id)
    %{"conta_id" => conta} = Acesso.conta(tenant)

    case Acesso.chamar(tenant, :ler_campanha, [plano["campanha_id"]]) do
      {:ok, camp} ->
        viol = V.violadas(Nucleo.Automacoes.Trafego.referencial(), %{plano: plano, campanha: camp, conta_id: conta})
        Evento.emitir(tenant, "verificacao", plano_id, "verificador", plano["campanha_id"], %{"violadas" => Enum.map(viol, &to_string/1)})

        if viol == [] do
          Plano.salvar(tenant, Map.put(plano, "status", "verificado"))
          :ok
        else
          Plano.salvar(tenant, Map.put(plano, "status", "divergente"))
          for r <- viol, do: Aprendizado.registrar(tenant, plano, "criar_campanha", "divergente", to_string(r))
          {:divergente, viol}
        end

      {:error, e} ->
        Evento.emitir(tenant, "verificacao", plano_id, "verificador", plano["campanha_id"], %{"erro" => inspect(e)})
        {:error, e}
    end
  end
end
