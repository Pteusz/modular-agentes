defmodule Trafego.Proposta do
  @moduledoc """
  Proposta de alteracao (ativar | pausar | ajustar) sobre um plano (ajustar: verba/teto de uma campanha, com ou sem plano). Regra da 4.5: relatar e autonomo, alterar nao: toda mudanca na
  campanha e uma proposta que o corretor confirma em texto livre. Guardada no registro do tenant em "proposta:<id>".
  Status: aguardando_confirmacao | confirmado | executada | recusada | falhou. A confirmacao vale para a proposta aberta mais recente.
  """
  alias Nucleo.Registro

  def criar(tenant, tipo, plano_id, extra \\ %{}) when tipo in ["ativar", "pausar", "ajustar"] do
    n = ((Registro.ler(tenant, "proposta_seq") || %{})["n"] || 0) + 1
    Registro.gravar(tenant, "proposta_seq", %{"n" => n})
    salvar(tenant, Map.merge(%{"id" => "q#{n}", "tipo" => tipo, "plano_id" => plano_id, "status" => "aguardando_confirmacao"}, extra))
  end

  def salvar(tenant, %{"id" => id} = p) do
    Registro.gravar(tenant, "proposta:" <> id, p)
    p
  end

  def ler(tenant, id), do: Registro.ler(tenant, "proposta:" <> id)

  def listar(tenant) do
    n = (Registro.ler(tenant, "proposta_seq") || %{})["n"] || 0
    for i <- 1..n//1, do: ler(tenant, "q#{i}")
  end

  def abertas(tenant), do: Enum.filter(listar(tenant), &(&1["status"] == "aguardando_confirmacao"))
  def atual(tenant), do: tenant |> abertas() |> List.last()
  def aberta(tenant, tipo, plano_id), do: Enum.find(abertas(tenant), &(&1["tipo"] == tipo and &1["plano_id"] == plano_id))
end

defmodule Trafego.Ativacao do
  @moduledoc """
  Ativar e pausar campanha, SO a partir de proposta confirmada (passa pelo gancho do dominio). Antes de propor e de novo antes
  de executar, as pre-condicoes decidiveis: plano verificado, janela nao encerrada,
  credencial ok, campanha realmente PAUSADA na plataforma. Depois de ativar, le a campanha de volta e confere.
  """
  alias Trafego.{Acesso, Evento, Executor, Gancho, Plano, Proposta}

  @motivos %{
    "plano_nao_verificado" => "o plano ainda nao foi criado e verificado",
    "janela_encerrada" => "a janela do plano ja acabou",
    "credencial_invalida" => "o acesso a plataforma esta invalido",
    "campanha_nao_esta_pausada" => "a campanha nao esta pausada na plataforma",
    "campanha_ilegivel" => "nao consegui ler a campanha na plataforma"
  }

  def explicar(motivos), do: Enum.map_join(motivos, "; ", &Map.get(@motivos, &1, &1))

  def pre_condicoes(tenant, plano, hoje \\ Date.utc_today()) do
    lido = Acesso.chamar(tenant, :ler_campanha, [plano["campanha_id"]])

    Enum.reject(
      [
        plano["status"] not in ["verificado", "pausada"] && "plano_nao_verificado",
        janela_encerrada?(plano, hoje) && "janela_encerrada",
        Acesso.status(tenant) != "ok" && "credencial_invalida",
        (case lido do
           {:ok, %{"status" => "PAUSADA"}} -> false
           {:ok, _} -> "campanha_nao_esta_pausada"
           _ -> "campanha_ilegivel"
         end)
      ],
      &(&1 == false)
    )
  end

  def janela_encerrada?(plano, hoje) do
    case Date.from_iso8601(get_in(plano, ["janela", "fim"]) || "") do
      {:ok, fim} -> Date.compare(fim, hoje) == :lt
      _ -> false
    end
  end

  @doc "Texto da proposta: diz o que vai fazer e pergunta."
  def texto(%{"tipo" => "ativar"}, plano) do
    "Vou ATIVAR a campanha #{plano["campanha_id"]} (#{Plano.resumo(plano)}) Depois de ativar ela passa a gastar de verdade: " <>
      "#{Plano.brl(plano["orcamento_diario"])} por dia, ate #{Plano.brl(plano["teto_total"])} no total. Você confirma?"
  end

  def texto(%{"tipo" => "pausar"} = prop, plano) do
    motivo =
      case prop["motivo"] do
        "desvio_da_meta" -> "ela esta fora da meta"
        _ -> "voce pediu"
      end

    "Vou PAUSAR a campanha #{plano["campanha_id"]} porque #{motivo}. Pausar nao apaga nada e da para ativar de novo depois. Você confirma?"
  end

  def texto(%{"tipo" => "ajustar"} = prop, _plano) do
    "Vou ajustar a campanha #{prop["campanha_nome"]}: #{mudancas(prop)}. Você confirma?"
  end

  # "antes → depois" so do que muda; o valor e o que o corretor disse
  defp mudancas(prop) do
    [
      prop["verba_diaria"] && "verba diaria #{Plano.brl(prop["verba_antes"])} → #{Plano.brl(prop["verba_diaria"])}",
      prop["teto_total"] && "teto total #{Plano.brl(prop["teto_antes"])} → #{Plano.brl(prop["teto_total"])}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  @doc "Executa a proposta CONFIRMADA. {:ok, texto} | {:error, :sem_confirmacao} | {:error, motivo}"
  def executar(tenant, prop_id) do
    prop = Proposta.ler(tenant, prop_id)
    acao = %{"ativar" => :ativar_campanha, "ajustar" => :editar_campanha}[prop["tipo"]] || :pausar_campanha

    case Gancho.alterar(tenant, prop, {acao, %{"proposta_id" => prop_id}}) do
      {:bloquear, _} -> {:error, :sem_confirmacao}
      :ok -> rodar(tenant, prop, prop["plano_id"] && Plano.ler(tenant, prop["plano_id"]))
    end
  end

  @doc """
  Pausa AUTONOMA (a unica sem "sim"): campanha escolhida na conversa, motivo obrigatorio gravado no evento. Passa pelo gancho do dominio,
  le a campanha de volta e confere; plano ligado a campanha (se houver) vira "pausada". :ok | {:error, motivo}
  """
  def pausar_autonoma(tenant, campanha_id, plano, motivo) when is_binary(motivo) and motivo != "" do
    pid = plano && plano["id"]

    with {:gancho, :ok} <- {:gancho, Gancho.pausar_autonoma(tenant)},
         {:ok, %{"status" => "PAUSADA"}} <- Acesso.chamar(tenant, :pausar_campanha, [campanha_id]) do
      if plano, do: Plano.salvar(tenant, Map.put(plano, "status", "pausada"))
      Evento.emitir(tenant, "operacao", pid, "executor", campanha_id, %{"acao" => "pausar_campanha", "autonoma" => true, "motivo" => String.slice(motivo, 0, 200)})
      :ok
    else
      {:gancho, _} ->
        {:error, :sem_liberacao}

      {:ok, outro} ->
        Evento.emitir(tenant, "operacao", pid, "executor", "pausar", %{"erro" => "pausa_nao_confere:#{outro["status"]}", "autonoma" => true})
        {:error, :pausa_nao_confere}

      {:error, e} ->
        Evento.emitir(tenant, "operacao", pid, "executor", "pausar", %{"erro" => Executor.motivo(e), "autonoma" => true})
        {:error, e}
    end
  end

  defp rodar(tenant, %{"tipo" => "ativar"} = prop, plano) do
    case pre_condicoes(tenant, plano) do
      [] ->
        cid = plano["campanha_id"]

        case Acesso.chamar(tenant, :ativar_campanha, [cid]) do
          {:ok, %{"status" => "ATIVA"} = c} ->
            Plano.salvar(tenant, Map.merge(plano, %{"status" => "ativa", "ultimo_estado" => nil}))
            fechar(tenant, prop, plano, "executada", "ativar_campanha", cid)
            Evento.emitir(tenant, "resultado", plano["id"], "executor", "ativada")
            {:ok, "Pronto: a campanha #{c["id"]} esta ativa e confere com o plano (campanha, conjunto e anuncio). Vou acompanhar os resultados contra a meta e te aviso; qualquer ajuste eu so faco com a sua confirmacao."}

          {:ok, outro} ->
            # leitura de volta nao bate: volta para PAUSADA por seguranca e registra
            Acesso.chamar(tenant, :pausar_campanha, [cid])
            falhou(tenant, prop, plano, "ativacao_nao_confere:#{outro["status"]}")
            {:ok, "A plataforma nao confirmou a ativacao completa (#{outro["status"]}); pausei tudo de novo por seguranca. Nada ficou ativo."}

          {:error, e} ->
            falhou(tenant, prop, plano, Executor.motivo(e))
            {:ok, falha_texto(e)}
        end

      motivos ->
        falhou(tenant, prop, plano, Enum.join(motivos, ","))
        {:ok, "Nao ativei: #{explicar(motivos)}. Nada foi alterado."}
    end
  end

  defp rodar(tenant, %{"tipo" => "pausar"} = prop, plano) do
    cid = plano["campanha_id"]

    case Acesso.chamar(tenant, :pausar_campanha, [cid]) do
      {:ok, %{"status" => "PAUSADA"}} ->
        Plano.salvar(tenant, Map.put(plano, "status", "pausada"))
        fechar(tenant, prop, plano, "executada", "pausar_campanha", cid)
        {:ok, "Pausei a campanha #{cid} e conferi: ela esta pausada. Para voltar, me peca para ativar de novo."}

      other ->
        falhou(tenant, prop, plano, (case other do {:error, e} -> Executor.motivo(e); _ -> "pausa_nao_confere" end))
        {:ok, "Nao consegui confirmar a pausa da campanha #{cid}. Confira no Gerenciador de Anuncios; registrei o erro."}
    end
  end

  # ajuste de verba/teto: relê a campanha, revalida, edita so o que foi dito e confere lendo de volta; o status da campanha nao muda
  defp rodar(tenant, %{"tipo" => "ajustar"} = prop, plano) do
    cid = prop["campanha_id"]
    attrs = Map.reject(%{"orcamento_diario" => prop["verba_diaria"], "teto_total" => prop["teto_total"]}, fn {_, v} -> is_nil(v) end)

    with {:ok, %{"status" => st} = atual} when st in ["ATIVA", "PAUSADA"] <- Acesso.chamar(tenant, :ler_campanha, [cid]),
         :ok <- ajuste_coerente(atual, attrs),
         {:ok, _} <- Acesso.chamar(tenant, :editar_campanha, [cid, attrs]),
         {:ok, depois} <- Acesso.chamar(tenant, :ler_campanha, [cid]),
         true <- Enum.all?(attrs, fn {k, v} -> depois[k] == v end) do
      if plano, do: Plano.salvar(tenant, Map.merge(plano, attrs))
      fechar(tenant, prop, plano, "executada", "editar_campanha", cid)
      {:ok, "Pronto: ajustei a campanha #{prop["campanha_nome"]} (#{mudancas(prop)}) e conferi na plataforma."}
    else
      {:ok, outro} ->
        st = outro["status"] || "indisponivel"
        falhou(tenant, prop, plano, "campanha_nao_ajustavel:#{st}")
        {:ok, "Nao ajustei: a campanha #{prop["campanha_nome"]} esta #{st} na plataforma e so ajusto campanha ativa ou pausada. Nada foi alterado."}

      {:incoerente, motivo} ->
        falhou(tenant, prop, plano, motivo)
        {:ok, "Nao ajustei: com os valores que a campanha tem agora o teto ficaria menor ou igual a verba diaria. Nada foi alterado."}

      false ->
        falhou(tenant, prop, plano, "ajuste_nao_confere")
        {:ok, "A plataforma nao confirmou o ajuste da campanha #{prop["campanha_nome"]}. Confira no Gerenciador de Anuncios; registrei o erro."}

      {:error, e} ->
        falhou(tenant, prop, plano, Executor.motivo(e))
        {:ok, "Nao consegui ajustar a campanha #{prop["campanha_nome"]} (#{Executor.motivo(e)}). Confira no Gerenciador de Anuncios; registrei o erro."}
    end
  end

  # o teto resultante tem que ficar maior que a verba resultante, com o que a campanha tem agora
  defp ajuste_coerente(atual, attrs) do
    verba = attrs["orcamento_diario"] || atual["orcamento_diario"]
    teto = attrs["teto_total"] || atual["teto_total"]
    if is_integer(verba) and is_integer(teto) and teto <= verba, do: {:incoerente, "teto_menor_que_a_verba"}, else: :ok
  end

  defp falha_texto(:ativacao_nao_liberada), do: "A ativacao real ainda nao foi liberada neste ambiente; nada foi alterado."
  defp falha_texto(e), do: "Nao consegui ativar (#{Executor.motivo(e)}). Nada foi alterado."

  defp fechar(tenant, prop, plano, status, acao, cid) do
    Proposta.salvar(tenant, Map.put(prop, "status", status))
    Evento.emitir(tenant, "operacao", plano["id"], "executor", cid, %{"acao" => acao, "proposta_id" => prop["id"]})
  end

  defp falhou(tenant, prop, plano, motivo) do
    Proposta.salvar(tenant, prop |> Map.put("status", "falhou") |> Map.put("erro", motivo))
    Evento.emitir(tenant, "operacao", plano["id"], "executor", prop["tipo"], %{"erro" => motivo, "proposta_id" => prop["id"]})
  end
end

defmodule Trafego.Cotacao do
  @moduledoc """
  Cotacao USD->BRL (R$ por US$ 1): PTAX de venda do Banco Central (Olinda, sem chave), buscada por dia pelo Oban e guardada com a
  data. Dia sem cotacao (fim de semana, feriado): volta ate 7 dias. Falha da fonte: vale a ultima conhecida (o evento de custo marca a data).
  """
  alias Trafego.Banco

  @caminho "/olinda/servico/PTAX/versao/v1/odata/CotacaoDolarDia(dataCotacao=@dataCotacao)"

  def fonte, do: Application.get_env(:trafego, :cotacao_fonte, "ptax")
  def base_url, do: Application.get_env(:trafego, :ptax_base_url, "https://olinda.bcb.gov.br")

  def atual(opts \\ []) do
    case Banco.q("SELECT usd_brl, data FROM trafego_cotacao WHERE fonte = $1 ORDER BY data DESC LIMIT 1", [opts[:fonte] || fonte()]).rows do
      [[v, d]] -> %{usd_brl: v, data: d}
      _ -> nil
    end
  end

  def atualizar(opts \\ []), do: procurar(opts[:hoje] || Date.utc_today(), 0)

  defp procurar(_hoje, n) when n >= 7, do: {:error, :sem_cotacao}

  defp procurar(hoje, n) do
    dia = Date.add(hoje, -n)

    case buscar(dia) do
      {:ok, nil} ->
        procurar(hoje, n + 1)

      {:ok, v} ->
        Banco.q(
          "INSERT INTO trafego_cotacao (fonte, data, usd_brl) VALUES ($1,$2,$3) ON CONFLICT (fonte, data) DO UPDATE SET usd_brl = EXCLUDED.usd_brl, obtida_em = now()",
          [fonte(), dia, v]
        )

        {:ok, %{usd_brl: v, data: dia}}

      {:error, _} = e ->
        e
    end
  end

  defp buscar(dia) do
    data = "'" <> String.pad_leading("#{dia.month}", 2, "0") <> "-" <> String.pad_leading("#{dia.day}", 2, "0") <> "-#{dia.year}'"

    case Req.get(base_url() <> @caminho, params: [{"@dataCotacao", data}, {"$format", "json"}], decode_body: false, retry: false, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: b}} ->
        case Jason.decode(b) do
          {:ok, %{"value" => [%{"cotacaoVenda" => v} | _]}} when is_number(v) and v > 0 -> {:ok, v * 1.0}
          {:ok, %{"value" => []}} -> {:ok, nil}
          _ -> {:error, :resposta_invalida}
        end

      {:ok, %{status: s}} ->
        {:error, {:http, s}}

      {:error, e} ->
        {:error, e}
    end
  end
end

defmodule Trafego.TetoIA do
  @moduledoc """
  Teto de custo de IA por corretor, em R$ por mes (soma dos eventos custo_tokens do mes). Aviso a 80%, bloqueio a 100%.
  Bloqueado: nenhuma chamada de IA, nada e alterado. Sem cotacao com provedor real, o custo nao seria contado: bloqueia (falha fechada).
  """
  alias Nucleo.Registro
  alias Trafego.{Banco, Config, Cotacao, Custo}

  def gasto(tenant) do
    [[v]] =
      Banco.q(
        "SELECT COALESCE(SUM((dados->>'custo_brl')::float8), 0) FROM eventos WHERE tenant_id = $1 AND tipo = 'custo_tokens' AND em >= date_trunc('month', now())",
        [tenant]
      ).rows

    v
  end

  @doc ":ok | {:aviso, %{gasto, teto}} | {:bloqueado, %{gasto, teto} | %{motivo: :sem_cotacao}}"
  def status(tenant) do
    teto = Config.teto_ia_brl()
    g = gasto(tenant)

    cond do
      Custo.cotacao_ausente?() -> {:bloqueado, %{motivo: :sem_cotacao, gasto: g, teto: teto}}
      g >= teto -> {:bloqueado, %{gasto: g, teto: teto}}
      g >= teto * 0.8 -> {:aviso, %{gasto: g, teto: teto}}
      true -> :ok
    end
  end

  @doc "Uma vez por mes para cada nivel (aviso, bloqueio): true na primeira vez."
  def primeira_vez?(tenant, nivel) do
    chave = "teto_ia_#{nivel}"
    mes = Calendar.strftime(Date.utc_today(), "%Y-%m")

    if (Registro.ler(tenant, chave) || %{})["mes"] == mes do
      false
    else
      Registro.gravar(tenant, chave, %{"mes" => mes})
      true
    end
  end

  def brl(v), do: "R$ " <> (v |> Kernel.*(1.0) |> :erlang.float_to_binary(decimals: 2) |> String.replace(".", ","))

  def mensagem(%{motivo: :sem_cotacao}),
    do: "Estou sem a cotacao do dolar para contar o custo de IA, por seguranca nao uso a IA agora e nada foi alterado."

  def mensagem(%{gasto: g, teto: t}),
    do: "Atingi o teto de IA do mes (#{brl(g)} de #{brl(t)}); por isso nao interpreto mensagens agora e nada foi alterado. Volto no proximo mes ou quando o teto for revisado."

  # evita aviso de compilacao se Cotacao nao for usada acima
  def cotacao, do: Cotacao.atual()
end
