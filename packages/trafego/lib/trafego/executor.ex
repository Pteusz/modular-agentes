defmodule Trafego.Executor do
  @moduledoc "Executor, sem IA: cria campanha/conjunto/anuncio PAUSADOS segundo o plano confirmado. Passa pelo gancho; conta vem do tenant."
  alias Trafego.{Acesso, Aprendizado, Config, Evento, Ficha, Gancho, Plano}

  def executar(tenant, plano_id) do
    plano = Plano.ler(tenant, plano_id)

    case Gancho.alterar(tenant, plano, {:criar_campanha, %{"plano_id" => plano_id}}) do
      {:bloquear, _} ->
        {:error, :sem_confirmacao}

      :ok ->
        # antes de criar QUALQUER coisa na plataforma: numero de WhatsApp valido e vinculado (leitura, nao cria nada)
        case checar_numero(tenant, plano) do
          {:ok, numero} ->
            params = plano |> Plano.params_campanha() |> Map.put("numero", numero) |> com_criativo(tenant, plano)

            case Acesso.chamar(tenant, :criar_campanha, [params]) do
              {:ok, %{"id" => cid}} ->
                Plano.salvar(tenant, Map.merge(plano, %{"status" => "executado", "campanha_id" => cid}))
                Evento.emitir(tenant, "operacao", plano_id, "executor", cid, %{"acao" => "criar_campanha"})
                Evento.emitir(tenant, "resultado", plano_id, "executor", "criada_pausada")
                {:ok, cid}

              {:error, e} ->
                falhou(tenant, plano, e)
            end

          {:error, e} ->
            falhou(tenant, plano, e)
        end
    end
  end

  defp falhou(tenant, plano, e) do
    m = motivo(e)
    plano = Plano.salvar(tenant, plano |> Map.put("status", "erro") |> parcial(e) |> Ficha.marcar_erro())
    Evento.emitir(tenant, "operacao", plano["id"], "executor", "criar_campanha", %{"erro" => m})
    Aprendizado.registrar(tenant, plano, "criar_campanha", "erro", "plataforma_#{m}")
    {:error, e}
  end

  # WhatsApp: numero normalizado (+55 e DDD) e vinculado a Pagina. Sem numero (so a Pagina) segue. Se nao deu para ler os vinculados
  # (token sem permissao, plataforma fora), tenta criar e o erro da Meta e traduzido (`explicar/1`).
  defp checar_numero(tenant, %{"destino" => "whatsapp", "numero" => n}) when n not in [nil, ""] do
    case Ficha.normalizar_numero(n) do
      {:ok, ok} ->
        case Acesso.chamar(tenant, :numeros_vinculados, []) do
          {:ok, lista} when is_list(lista) ->
            if Enum.any?(lista, &(Ficha.chave_numero(&1) == Ficha.chave_numero(ok))), do: {:ok, ok}, else: {:error, {:numero_nao_vinculado, lista}}

          _ ->
            {:ok, ok}
        end

      {:sem_ddd, _} ->
        {:error, :numero_sem_ddd}

      :invalido ->
        {:error, :numero_invalido}
    end
  end

  defp checar_numero(_tenant, plano), do: {:ok, plano["numero"]}

  @doc "A causa em portugues claro (uma frase, sem dados sensiveis) para o corretor."
  def explicar({:parcial, _etapa, %{"erro" => m}}) when is_binary(m), do: if(m =~ "not linked", do: explicar({:numero_nao_vinculado, nil}), else: "a Meta recusou: #{m}")
  def explicar({:numero_nao_vinculado, _}), do: "esse numero de WhatsApp nao esta vinculado a sua Pagina na Meta, e a Meta so deixa anunciar com numero vinculado"
  def explicar(:numero_sem_ddd), do: "o numero de WhatsApp ficou sem DDD"
  def explicar(:numero_invalido), do: "nao consegui entender o numero de WhatsApp"
  def explicar(:token_invalido), do: "o acesso da Meta venceu ou foi revogado"
  def explicar({:limite_de_taxa, _}), do: "a Meta pediu pra esperar um pouco (limite de uso)"
  def explicar(:criativo_reprovado), do: "a Meta nao aceitou a imagem do anuncio"
  def explicar({:graph, _, m}) when is_binary(m), do: if(m =~ "not linked", do: explicar({:numero_nao_vinculado, nil}), else: "a Meta recusou: #{String.slice(m, 0, 160)}")
  def explicar(e), do: "deu um erro (#{motivo(e)})"

  @doc "Erro por numero de WhatsApp nao vinculado (lista os vinculados quando a leitura trouxe)."
  def numero_nao_vinculado?({:numero_nao_vinculado, _}), do: true
  def numero_nao_vinculado?({:parcial, _, %{"erro" => m}}) when is_binary(m), do: m =~ "not linked"
  def numero_nao_vinculado?({:graph, _, m}) when is_binary(m), do: m =~ "not linked"
  def numero_nao_vinculado?(_), do: false

  @doc "Id da campanha parcial (criada e deixada PAUSADA) quando a criacao parou no meio."
  def campanha_parcial({:parcial, _, %{"campanha_id" => id}}), do: id
  def campanha_parcial(_), do: nil

  @doc "Caminho do criativo recebido do tenant (so o nome do arquivo, nunca um caminho vindo de fora)."
  def caminho_midia(tenant, nome), do: Path.join([Config.midia_dir(), tenant, Path.basename(nome)])

  @doc "Motivo curto e sem dados sensiveis, para evento e resposta."
  def motivo({:numero_nao_vinculado, _}), do: "numero_nao_vinculado"
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
