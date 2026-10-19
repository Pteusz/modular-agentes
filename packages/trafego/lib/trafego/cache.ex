defmodule Trafego.Cache do
  @moduledoc """
  Cache curto em memoria da leitura do painel (ETS). Chave = {tenant, conta_id, dias}: nunca cruza tenants nem contas. TTL em
  `config :trafego, :cache_ttl_ms` (padrao 60 s; 0 desliga). So guarda {:ok, _}: erro (token invalido, rede) nunca e cacheado.
  Invalidacao por tenant (`invalidar/1`) a cada criar/editar/pausar/ativar, troca/remocao de conta e token invalido. Cada tenant tem uma
  GERACAO: uma leitura que comecou antes da invalidacao nao grava depois dela (nao ressuscita dado velho). E por VM: outro processo
  do sistema (ex.: o trabalhador) que pause uma campanha so aparece aqui ao fim do TTL.
  """
  use GenServer

  @tabela :trafego_cache
  @varrer_ms 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def ttl_ms, do: Application.get_env(:trafego, :cache_ttl_ms, 60_000)

  @doc "{:ok, valor} | :miss (expirado, ausente ou cache desligado)"
  def ler(chave) do
    with true <- ttl_ms() > 0,
         [{_, valor, expira}] <- :ets.lookup(@tabela, chave),
         true <- expira > agora() do
      {:ok, valor}
    else
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Geracao atual do tenant: guarde ANTES de ler a plataforma e passe a `gravar/3`."
  def geracao(tenant) do
    case :ets.lookup(@tabela, {:geracao, tenant}) do
      [{_, n}] -> n
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Grava so se a geracao do tenant nao mudou desde que a leitura comecou."
  def gravar({tenant, _, _} = chave, valor, geracao) do
    if ttl_ms() > 0 and geracao(tenant) == geracao, do: :ets.insert(@tabela, {chave, valor, agora() + ttl_ms()})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Esquece tudo do tenant (todas as contas e periodos) e passa a geracao."
  def invalidar(tenant) do
    :ets.update_counter(@tabela, {:geracao, tenant}, 1, {{:geracao, tenant}, 0})
    :ets.match_delete(@tabela, {{tenant, :_, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Medicao/teste: esvazia tudo."
  def limpar do
    :ets.match_delete(@tabela, {{:_, :_, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp agora, do: System.monotonic_time(:millisecond)

  @impl true
  def init(_) do
    :ets.new(@tabela, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    Process.send_after(self(), :varrer, @varrer_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:varrer, estado) do
    :ets.select_delete(@tabela, [{{{:_, :_, :_}, :_, :"$1"}, [{:<, :"$1", agora()}], [true]}])
    Process.send_after(self(), :varrer, @varrer_ms)
    {:noreply, estado}
  end

  def handle_info(_, estado), do: {:noreply, estado}
end
