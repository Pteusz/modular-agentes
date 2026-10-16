defmodule Trafego.Plataforma.Simulada do
  @moduledoc "Adaptador simulado em memoria. Token alcanca um conjunto de contas (pode alcancar mais que a do tenant)."
  @behaviour Trafego.Plataforma
  use Agent

  def start_link(_ \\ []), do: Agent.start_link(fn -> %{contas: MapSet.new(), tokens: %{}, campanhas: %{}, seq: 0} end, name: __MODULE__)

  # ---- ajuda de teste (lado da "plataforma")
  def registrar_conta(id), do: Agent.update(__MODULE__, fn s -> %{s | contas: MapSet.put(s.contas, id)} end)
  def registrar_token(token, alcance), do: Agent.update(__MODULE__, fn s -> %{s | tokens: Map.put(s.tokens, token, alcance)} end)
  def todas, do: Agent.get(__MODULE__, fn s -> s.campanhas |> Map.values() |> Enum.sort_by(fn c -> c["n"] end) end)
  @doc "Injeta divergencia: altera campos da campanha por fora do executor."
  def injetar(id, attrs), do: Agent.update(__MODULE__, fn s -> %{s | campanhas: Map.update!(s.campanhas, id, fn c -> Map.merge(c, attrs) end)} end)

  # ---- contrato
  @impl true
  def validar_credencial(cred),
    do: Agent.get(__MODULE__, &if(autoriza?(&1, cred), do: {:ok, %{"conta_id" => cred["conta_id"]}}, else: {:error, :credencial_invalida}))

  @impl true
  def criar_campanha(cred, p) do
    Agent.get_and_update(__MODULE__, fn s ->
      if autoriza?(s, cred) do
        n = s.seq + 1
        # sempre pausada, qualquer que seja o pedido
        c = %{
          "id" => "camp_#{n}", "n" => n, "conta_id" => cred["conta_id"], "nome" => p["nome"], "status" => "PAUSADA",
          "objetivo" => p["objetivo"], "destino" => p["destino"], "orcamento_diario" => p["orcamento_diario"],
          "teto_total" => p["teto_total"], "janela" => p["janela"],
          "conjuntos" => [
            %{"id" => "conj_#{n}", "status" => "PAUSADA", "publico" => p["publico"],
              "anuncios" => [%{"id" => "anu_#{n}", "status" => "PAUSADA", "criativo" => p["criativo"]}]}
          ]
        }

        {{:ok, c}, %{s | seq: n, campanhas: Map.put(s.campanhas, c["id"], c)}}
      else
        {{:error, :credencial_invalida}, s}
      end
    end)
  end

  @impl true
  def ler_campanha(cred, id), do: Agent.get(__MODULE__, &acha(&1, cred, id))

  @impl true
  def listar_campanhas(cred) do
    Agent.get(__MODULE__, fn s ->
      if autoriza?(s, cred),
        do: {:ok, s.campanhas |> Map.values() |> Enum.filter(fn c -> c["conta_id"] == cred["conta_id"] end) |> Enum.sort_by(fn c -> c["n"] end)},
        else: {:error, :credencial_invalida}
    end)
  end

  @impl true
  def editar_campanha(_cred, _id, %{"status" => st}) when st != "PAUSADA", do: {:error, :ativacao_fora_da_fase}

  def editar_campanha(cred, id, attrs) do
    Agent.get_and_update(__MODULE__, fn s ->
      case acha(s, cred, id) do
        {:ok, c} ->
          c = Map.merge(c, Map.take(attrs, ~w(nome orcamento_diario teto_total janela)))
          {{:ok, c}, %{s | campanhas: Map.put(s.campanhas, id, c)}}

        e ->
          {e, s}
      end
    end)
  end

  @impl true
  def pausar_campanha(cred, id), do: editar_campanha(cred, id, %{"status" => "PAUSADA"})

  defp autoriza?(s, %{"conta_id" => conta, "token" => token}), do: MapSet.member?(s.contas, conta) and conta in Map.get(s.tokens, token, [])
  defp autoriza?(_, _), do: false

  defp acha(s, cred, id) do
    if autoriza?(s, cred) do
      conta = cred["conta_id"]

      case s.campanhas[id] do
        %{"conta_id" => ^conta} = camp -> {:ok, camp}
        _ -> {:error, :nao_encontrada}
      end
    else
      {:error, :credencial_invalida}
    end
  end
end
