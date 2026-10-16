defmodule Trafego.Executor do
  @moduledoc "Executor, sem IA: cria campanha/conjunto/anuncio PAUSADOS segundo o plano confirmado. Passa pelo gancho; conta vem do tenant."
  alias Trafego.{Acesso, Aprendizado, Evento, Gancho, Plano}

  def executar(tenant, plano_id) do
    plano = Plano.ler(tenant, plano_id)

    case Gancho.alterar(tenant, plano, {:criar_campanha, %{"plano_id" => plano_id}}) do
      {:bloquear, _} ->
        {:error, :sem_confirmacao}

      :ok ->
        case Acesso.chamar(tenant, :criar_campanha, [Plano.params_campanha(plano)]) do
          {:ok, %{"id" => cid}} ->
            Plano.salvar(tenant, Map.merge(plano, %{"status" => "executado", "campanha_id" => cid}))
            Evento.emitir(tenant, "operacao", plano_id, "executor", cid, %{"acao" => "criar_campanha"})
            Evento.emitir(tenant, "resultado", plano_id, "executor", "criada_pausada")
            {:ok, cid}

          {:error, e} ->
            Plano.salvar(tenant, Map.put(plano, "status", "erro"))
            Evento.emitir(tenant, "operacao", plano_id, "executor", "criar_campanha", %{"erro" => inspect(e)})
            Aprendizado.registrar(tenant, plano, "criar_campanha", "erro", "plataforma_#{e}")
            {:error, e}
        end
    end
  end
end
