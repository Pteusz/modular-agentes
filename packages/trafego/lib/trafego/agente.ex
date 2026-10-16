defmodule Trafego.Agente do
  @moduledoc """
  Conversa do corretor com o agente de trafego (texto do chat dele consigo mesmo). Papeis:
  planejador (IA, via Trafego.IA): monta/revisa o plano e le a confirmacao em texto livre;
  executor (sem IA), verificador decidivel e monitor (esqueleto) ficam nos proprios modulos.
  Estado: um plano "atual" por tenant (rascunho ou aguardando confirmacao). Nenhuma alteracao sem confirmacao clara:
  ambigua -> repergunta curta; negativa -> recusa. O texto do corretor nao vira evento.
  """
  alias Nucleo.Registro
  alias Trafego.{Aprendizado, Evento, Executor, IA, Plano, Verificador}

  @nome "Nucleo.Automacoes.Trafego"
  @repergunta "so pra confirmar se entendi, posso fazer isso mesmo?"

  @doc "Processa uma mensagem do corretor. {:ok, resposta} | {:error, motivo}"
  def processar(tenant, texto) do
    with :ok <- ativo(tenant), %{} <- Trafego.Acesso.conta(tenant) || {:error, :sem_conta} do
      case Plano.atual(tenant) do
        %{"status" => "aguardando_confirmacao"} = p -> confirmar(tenant, p, texto)
        %{"status" => "rascunho"} = p -> planejar(tenant, p, texto, "complemento")
        nil -> planejar(tenant, Plano.novo(tenant), texto, "novo")
      end
    end
  end

  defp ativo(tenant) do
    if Enum.any?(Registro.contratos(tenant), &(&1.automacao == @nome and &1.estado == "ativo")), do: :ok, else: {:error, :inativo}
  end

  # ---- planejador
  defp planejar(tenant, plano, texto, ref) do
    Plano.definir_atual(tenant, plano["id"])
    Evento.emitir(tenant, "pedido", plano["id"], "planejador", ref)

    case IA.provedor().chamar(:media, :planejar, %{"texto" => texto, "plano" => plano}) do
      {:ok, %{"plano" => parcial}, uso} ->
        Evento.custo(tenant, plano["id"], "planejador", "planejar", uso)
        {plano, ignorados} = Plano.mesclar(plano, parcial)

        # id de conta que veio do modelo e ignorado: a conta e a do registro do tenant
        if ignorados != [], do: Evento.emitir(tenant, "operacao", plano["id"], "planejador", "conta_do_modelo_ignorada", %{"erro" => "conta_do_modelo_ignorada"})

        plano = Map.put(plano, "atencao", Aprendizado.atencao(tenant, Plano.situacao(plano)))
        concluir_plano(tenant, plano)

      {:error, e} ->
        Evento.emitir(tenant, "plano", plano["id"], "planejador", "ia_falhou", %{"erro" => inspect(e)})
        {:ok, "Nao consegui montar o plano agora. Tenta de novo em instantes; nada foi alterado."}
    end
  end

  defp concluir_plano(tenant, plano) do
    case Plano.pendencias(plano) do
      [] ->
        plano = Plano.salvar(tenant, Map.put(plano, "status", "aguardando_confirmacao"))
        Evento.emitir(tenant, "plano", plano["id"], "planejador", "aguardando_confirmacao")
        atencao = if plano["atencao"] == [], do: "", else: " Atencao: em situacao parecida a verificacao acusou #{Enum.join(plano["atencao"], ", ")}; vou conferir isso de novo."
        {:ok, Plano.resumo(plano) <> atencao <> " Vou criar tudo PAUSADO, nada sera ativado. Voce confirma?"}

      pend ->
        plano = Plano.salvar(tenant, Map.put(plano, "status", "rascunho"))
        Evento.emitir(tenant, "plano", plano["id"], "planejador", "pendencias", %{"faltam" => pend})
        {:ok, "Para fechar o plano falta: #{Enum.join(pend, ", ")}. Me manda isso que eu monto."}
    end
  end

  # ---- confirmacao em texto livre
  defp confirmar(tenant, plano, texto) do
    case IA.provedor().chamar(:pequena, :confirmar, %{"texto" => texto, "plano" => plano["id"]}) do
      {:ok, %{"decisao" => d}, uso} ->
        Evento.custo(tenant, plano["id"], "planejador", "confirmar", uso)
        decidir(tenant, plano, d)

      {:error, _} ->
        {:ok, @repergunta}
    end
  end

  defp decidir(tenant, plano, "sim") do
    Evento.emitir(tenant, "confirmacao", plano["id"], "planejador", "sim")
    Plano.salvar(tenant, Map.put(plano, "status", "confirmado"))

    case Executor.executar(tenant, plano["id"]) do
      {:ok, cid} ->
        plano = Plano.ler(tenant, plano["id"])
        verif = Verificador.verificar(tenant, plano["id"])
        if verif == :ok, do: Aprendizado.registrar(tenant, plano, "criar_campanha", "ok")
        Plano.definir_atual(tenant, nil)

        {:ok,
         "Criei a campanha #{cid} pausada (nada foi ativado). " <>
           case verif do
             :ok -> "Verificacao: confere com o plano."
             {:divergente, regras} -> "Verificacao acusou divergencia: #{Enum.join(regras, ", ")}."
             {:error, _} -> "Nao consegui reler a campanha para verificar."
           end}

      {:error, e} ->
        Plano.definir_atual(tenant, nil)
        {:ok, "Nao consegui criar a campanha (#{e}). Nada ficou ativo; registrei o erro para a proxima proposta."}
    end
  end

  defp decidir(tenant, plano, "nao") do
    Evento.emitir(tenant, "confirmacao", plano["id"], "planejador", "nao")
    Plano.salvar(tenant, Map.put(plano, "status", "recusado"))
    Plano.definir_atual(tenant, nil)
    {:ok, "Ok, cancelei o plano #{plano["id"]}; nada foi alterado."}
  end

  defp decidir(tenant, plano, _) do
    Evento.emitir(tenant, "confirmacao", plano["id"], "planejador", "ambigua")
    {:ok, @repergunta}
  end
end
