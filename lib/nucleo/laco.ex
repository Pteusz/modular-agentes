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
    {:ok, %{tenant: tenant, mod: mod, ref: ref}}
  end

  defp canal_vinculado(tenant) do
    %{canal: c} = Enum.find(Registro.vinculos(), &(&1.tenant == tenant)) || raise "tenant nao vinculado: #{tenant}"
    String.to_existing_atom("Elixir." <> c)
  end

  @impl GenServer
  def handle_call(:canal, _, s), do: {:reply, s.ref, s}

  @impl GenServer
  def handle_info({:mensagem, _texto}, s) do
    n = ((Registro.ler(s.tenant, "contador") || %{})["n"] || 0) + 1
    {:ok, _} = Registro.gravar(s.tenant, "contador", %{"n" => n})
    responder(s, "recebi ##{n}")
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

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
