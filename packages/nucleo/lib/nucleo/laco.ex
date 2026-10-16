defmodule Nucleo.Laco do
  @moduledoc """
  Laco (esqueleto), um processo por tenant: mensagem entra -> le estado -> gancho -> grava estado -> responde pelo canal.
  Resposta prefixada; envio limitado por `teto_por_min` (config do tenant, padrao 10).
  """
  use GenServer
  alias Nucleo.{Registro, Gancho}

  @prefixo "[agente] "

  def iniciar(tenant, opts \\ []),
    do:
      DynamicSupervisor.start_child(Nucleo.Lacos, %{
        id: tenant,
        start: {GenServer, :start_link, [__MODULE__, {tenant, opts}]},
        restart: :temporary
      })

  def canal(pid), do: GenServer.call(pid, :canal)

  @impl GenServer
  def init({tenant, opts}) do
    mod = opts[:canal] || canal_vinculado(tenant)
    {:ok, ref} = mod.iniciar(tenant, self(), opts[:canal_opts] || [])
    {:ok, %{tenant: tenant, mod: mod, ref: ref, auto: automacao(tenant)}}
  end

  # automacao vinculada que implementa Nucleo.Passo; sem ela vale o esqueleto (contador)
  defp automacao(tenant) do
    for %{tenant: ^tenant, automacao: a} <- Registro.vinculos(),
        mod = Module.concat([a]),
        Code.ensure_loaded?(mod) and function_exported?(mod, :passo, 2),
        reduce: nil,
        do: (_ -> mod)
  end

  defp canal_vinculado(tenant) do
    %{canal: c} = Enum.find(Registro.vinculos(), &(&1.tenant == tenant)) || raise "tenant nao vinculado: #{tenant}"
    String.to_existing_atom("Elixir." <> c)
  end

  @impl GenServer
  def handle_call(:canal, _, s), do: {:reply, s.ref, s}

  @impl GenServer
  def handle_info({:mensagem, texto}, %{auto: auto} = s) when auto != nil do
    retido = for %{chave: k, leitura: l} <- auto.retencao(), into: %{}, do: {k, ler(s.tenant, k, l)}
    r = auto.passo(texto, retido)
    viol = Nucleo.Verificador.violadas(auto.referencial(), %{entrada: texto, saida: r.saida, retido: r.retido})

    if viol == [] do
      for {k, v} <- r.retido, do: Registro.gravar(s.tenant, k, v)
      for {tipo, _} = acao <- r.acoes do
        with {:bloquear, m} <- Nucleo.Gancho.intercepta(s.tenant, acao, auto.aprovacao()),
             do: Registro.evento(s.tenant, "acao_bloqueada", %{"acao" => to_string(tipo), "motivo" => m})
      end

      responder(s, r.saida)
    else
      dados = %{"regras" => Enum.map(viol, &to_string/1)}
      Registro.gravar(s.tenant, "regra_violada", dados)
      Registro.evento(s.tenant, "regra_violada", dados)
    end

    {:noreply, s}
  end

  def handle_info({:mensagem, _texto}, s) do
    n = ((Registro.ler(s.tenant, "contador") || %{})["n"] || 0) + 1
    {:ok, _} = Registro.gravar(s.tenant, "contador", %{"n" => n})
    responder(s, "recebi ##{n}")
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp ler(t, k, :ultimo), do: Registro.ler(t, k)
  defp ler(t, k, :historico), do: Enum.map(Registro.historico(t, k), & &1.valor)

  defp responder(s, texto) do
    teto = Registro.config(s.tenant)["teto_por_min"] || 10

    with :ok <- Gancho.intercepta(s.tenant, {:enviar, texto}),
         {:limite, false} <- {:limite, Registro.eventos_recentes(s.tenant, "enviado", 60) >= teto} do
      case s.mod.enviar_texto(s.ref, @prefixo <> texto) do
        :ok -> Registro.evento(s.tenant, "enviado")
        {:error, e} -> Registro.evento(s.tenant, "envio_falhou", %{"erro" => inspect(e)})
      end
    else
      {:limite, true} -> Registro.evento(s.tenant, "envio_limitado")
      {:bloquear, m} -> Registro.evento(s.tenant, "envio_bloqueado", %{"motivo" => m})
    end
  end
end
