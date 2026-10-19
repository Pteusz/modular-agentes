defmodule Trafego.Equipe do
  @moduledoc """
  Fronteira do trafego para a gestao de equipe (oferta "trafego.equipe" 1.0). A gestao NAO conhece o resto do pacote: le o que
  precisa so por aqui. Toda funcao recebe o TENANT do corretor; nada devolve token em claro nem texto da conversa.
    * `validar_credencial/1`, `cadastrar_conta/2`, `remover_conta/1` - ciclo da conta de anuncio do corretor;
    * `resumo/2` e `sincronizar/1` - gasto, campanhas ativas/reprovadas e status do token (foto guardada em "trafego_sync");
    * `campanhas/1` - leitura ao vivo para a pagina do corretor; `atividade/1` - aba IA; `custo_ia/1` - soma dos custo_tokens;
    * `cifrar/2` e `decifrar/2` - a mesma cifra (AES-256-GCM, tenant como AAD) para a gestao guardar as credenciais.
  """
  alias Nucleo.Registro
  alias Trafego.{AbaIA, Acesso, Cifra, Painel, Plataforma}

  @chave_sync "trafego_sync"
  @reprovadas ~w(REPROVADA DISAPPROVED WITH_ISSUES)
  @ativas ~w(ATIVA ACTIVE)

  @doc "Valida a credencial na plataforma sem gravar nada. :ok | {:error, motivo da plataforma}"
  def validar_credencial(cred) do
    with {:ok, _} <- Plataforma.adaptador().validar_credencial(cred), do: :ok
  end

  @doc "Cadastra a conta do tenant (token cifrado). Entrada: conta_id, token, pagina_id, instagram_id, pixel_id."
  def cadastrar_conta(tenant, cred), do: Acesso.cadastrar(tenant, cred)

  @doc "Remove a conta e a foto de sincronizacao do tenant (todas as versoes). Nada na plataforma e tocado."
  def remover_conta(tenant) do
    Trafego.Cache.invalidar(tenant)
    Registro.apagar_chave(tenant, "trafego_conta")
    Registro.apagar_chave(tenant, @chave_sync)
  end

  def cifrar(tenant, texto), do: Cifra.cifrar(tenant, texto)
  def decifrar(tenant, envelope), do: Cifra.decifrar(tenant, envelope)

  @doc "Campanhas ao vivo da conta do tenant (com metricas de 7 dias). {:ok, [campanha]} | {:error, motivo}"
  def campanhas(tenant), do: Painel.campanhas(tenant)

  @doc "Aba IA do tenant: so metadados dos eventos."
  def atividade(tenant), do: AbaIA.projetar(tenant)

  @doc "Soma do custo de IA (R$) dos eventos custo_tokens do tenant; custo sem preco conhecido nao entra."
  def custo_ia(tenant) do
    for %{tipo: "custo_tokens", dados: %{"custo_brl" => c}} <- Registro.eventos(tenant), is_number(c), reduce: 0.0, do: (acc -> acc + c)
  end

  @doc """
  Foto do tenant: %{"token", "sincronizado_em", "campanhas_ativas", "reprovadas", "gasto"}. Usa a foto guardada se tiver menos de
  `max_idade` segundos (padrao 300); senao sincroniza. Tenant sem conta devolve token "sem conta".
  """
  def resumo(tenant, max_idade \\ 300) do
    case Registro.ler(tenant, @chave_sync) do
      %{"sincronizado_em" => em} = foto -> if idade(em) <= max_idade, do: com_token(tenant, foto), else: elem(sincronizar(tenant), 1)
      _ -> elem(sincronizar(tenant), 1)
    end
  end

  @doc "Ultima foto guardada (sem tocar na plataforma) com o status atual do token, ou nil se nunca sincronizou."
  def foto(tenant) do
    case Registro.ler(tenant, @chave_sync) do
      %{"sincronizado_em" => _} = foto -> com_token(tenant, foto)
      _ -> nil
    end
  end

  @doc """
  Le a plataforma e guarda a foto. {:ok, resumo}; sem conta ou com erro, o resumo traz o motivo em "erro".
  `fresco: false` aceita o cache curto de campanhas (padrao true = le agora).
  """
  def sincronizar(tenant), do: sincronizar(tenant, [])

  def sincronizar(tenant, opts) do
    # com erro da plataforma (token caiu, fora do ar) valem os ultimos numeros conhecidos: o painel nao zera de repente
    anterior = Registro.ler(tenant, @chave_sync) || %{}
    zero = %{"campanhas_ativas" => 0, "reprovadas" => 0, "gasto" => 0}
    base = zero |> Map.merge(Map.take(anterior, Map.keys(zero))) |> Map.put("sincronizado_em", DateTime.utc_now() |> DateTime.to_iso8601())

    foto =
      case Acesso.conta(tenant) do
        nil ->
          base
        _ ->
          case Painel.campanhas(tenant, Painel.dias_padrao(), fresco: Keyword.get(opts, :fresco, true)) do
            {:ok, lista} ->
              Map.merge(Map.merge(base, zero), %{
                "campanhas_ativas" => Enum.count(lista, &(estado(&1) in @ativas)),
                "reprovadas" => Enum.count(lista, &(estado(&1) in @reprovadas)),
                "campanhas_total" => length(lista),
                "gasto" => lista |> Enum.map(&(get_in(&1, ["metricas", "gasto"]) || 0)) |> Enum.sum()
              })

            {:error, e} when e in [:token_invalido, :credencial_invalida] ->
              marcar_invalido(tenant)
              Map.put(base, "erro", "token_invalido")

            {:error, e} ->
              Map.put(base, "erro", inspect(e))
          end
      end

    Registro.gravar(tenant, @chave_sync, foto)
    {:ok, com_token(tenant, foto)}
  end

  defp estado(c), do: c["status"] |> to_string() |> String.upcase()

  defp com_token(tenant, foto), do: Map.put(foto, "token", Acesso.status(tenant) || "sem conta")

  # a plataforma recusou o token que ja foi aceito um dia: mesmo estado que o Acesso grava quando a Meta devolve 190
  defp marcar_invalido(tenant) do
    with %{} = c <- Acesso.conta(tenant), true <- c["status"] != "token invalido", do: Registro.gravar(tenant, "trafego_conta", Map.put(c, "status", "token invalido"))
    :ok
  end

  defp idade(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt)
      _ -> 1_000_000
    end
  end
end
