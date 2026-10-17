defmodule Trafego.Executor do
  @moduledoc "Executor, sem IA: cria campanha/conjunto/anuncio PAUSADOS segundo o plano confirmado. Passa pelo gancho; conta vem do tenant."
  alias Trafego.{Acesso, Aprendizado, Config, Evento, Gancho, Plano}

  def executar(tenant, plano_id) do
    plano = Plano.ler(tenant, plano_id)

    case Gancho.alterar(tenant, plano, {:criar_campanha, %{"plano_id" => plano_id}}) do
      {:bloquear, _} ->
        {:error, :sem_confirmacao}

      :ok ->
        params = plano |> Plano.params_campanha() |> com_criativo(tenant, plano)

        case Acesso.chamar(tenant, :criar_campanha, [params]) do
          {:ok, %{"id" => cid}} ->
            Plano.salvar(tenant, Map.merge(plano, %{"status" => "executado", "campanha_id" => cid}))
            Evento.emitir(tenant, "operacao", plano_id, "executor", cid, %{"acao" => "criar_campanha"})
            Evento.emitir(tenant, "resultado", plano_id, "executor", "criada_pausada")
            {:ok, cid}

          {:error, e} ->
            m = motivo(e)
            plano = Plano.salvar(tenant, plano |> Map.put("status", "erro") |> parcial(e))
            Evento.emitir(tenant, "operacao", plano["id"], "executor", "criar_campanha", %{"erro" => m})
            Aprendizado.registrar(tenant, plano, "criar_campanha", "erro", "plataforma_#{m}")
            {:error, e}
        end
    end
  end

  @doc "Caminho do criativo recebido do tenant (so o nome do arquivo, nunca um caminho vindo de fora)."
  def caminho_midia(tenant, nome), do: Path.join([Config.midia_dir(), tenant, Path.basename(nome)])

  @doc "Motivo curto e sem dados sensiveis, para evento e resposta."
  def motivo({:parcial, etapa, _}), do: "parcial_#{etapa}"
  def motivo({:http, s}), do: "http_#{s}"
  def motivo({:graph, c, m}) when is_binary(m), do: "graph_#{c}: " <> String.slice(m, 0, 160)
  def motivo(e) when is_atom(e), do: Atom.to_string(e)
  def motivo(_), do: "erro_inesperado"

  # os bytes do criativo vao so ao adaptador (o simulado ignora); arquivo ausente -> o adaptador acusa criativo_ausente
  defp com_criativo(params, tenant, plano) do
    with nome when is_binary(nome) <- get_in(plano, ["criativo", "midia"]),
         {:ok, bytes} <- File.read(caminho_midia(tenant, nome)) do
      Map.put(params, "criativo_bytes", bytes)
    else
      _ -> params
    end
  end

  # criacao interrompida no meio: o que ja existe na plataforma (tudo PAUSADO) fica registrado no plano
  defp parcial(plano, {:parcial, etapa, criados}), do: Map.put(plano, "parcial", %{"etapa" => to_string(etapa), "criados" => criados})
  defp parcial(plano, _), do: plano
end
