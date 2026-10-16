defmodule Trafego.Monitor do
  @moduledoc """
  Monitor (esqueleto, sem IA e sem agendamento; o Oban entra na 4.5): compara metricas e meta do plano e emite `resultado`
  com meta_batida | desvio | dados_insuficientes. Metricas: %{"resultados" => n, "custo_por_resultado" => centavos} ou nil.
  """
  alias Trafego.{Evento, Plano}

  def avaliar(tenant, plano_id, metricas) do
    meta = Plano.ler(tenant, plano_id)["meta"] || %{}

    r =
      case metricas do
        %{"resultados" => n, "custo_por_resultado" => c} when is_integer(n) and n > 0 and is_integer(c) ->
          if n >= meta["resultados"] and c <= meta["custo_max"], do: :meta_batida, else: :desvio

        _ ->
          :dados_insuficientes
      end

    Evento.emitir(tenant, "resultado", plano_id, "monitor", to_string(r))
    r
  end
end
