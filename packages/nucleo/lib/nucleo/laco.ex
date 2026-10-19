defmodule Nucleo.Laco do
  @moduledoc """
  Laco (esqueleto), um processo por tenant: mensagem entra -> le estado -> gancho -> grava estado -> responde pelo canal.
  Resposta prefixada; envio limitado por `teto_por_min` (config do tenant, padrao 10).

  Prefixo: padrao "[agente] "; a automacao pode ter o seu (callback opcional `prefixo/0`, ex.: "[Iara] ") e ele vale para respostas
  e avisos. `conversar/2` pode devolver `{:ok, [textos]}`: cada mensagem sai separada, em ordem, com prefixo, dentro do teto_por_min
  (o que nao couber no orcamento restante vai junto na ultima mensagem; se nao resta nada, e um unico `envio_limitado`).
  Pausa entre mensagens: config do tenant `pausa_envio_ms` (padrao 0).

  Nota de voz (1.5.0): cada elemento da resposta pode ser `{:audio, bytes, opts, texto}` em vez de texto. Sai por `enviar_audio/3` do
  canal, SEM prefixo (voz nao tem prefixo textual), e conta no teto_por_min como qualquer mensagem; o gancho `{:enviar, texto}` ve o
  texto equivalente. Canal sem `enviar_audio` ou envio que falha = o mesmo `texto` sai como mensagem de texto, com prefixo (nunca silencia).
  """
  use GenServer
  alias Nucleo.{Registro, Gancho}

  @prefixo "[agente] "

  @doc false
  def prefixo_padrao, do: @prefixo

  def iniciar(tenant, opts \\ []),
    do:
      DynamicSupervisor.start_child(Nucleo.Lacos, %{
        id: tenant,
        start: {GenServer, :start_link, [__MODULE__, {tenant, opts}, [name: {:via, Registry, {Nucleo.LacoReg, tenant}}]]},
        restart: :temporary
      })

  def canal(pid), do: GenServer.call(pid, :canal)

  @doc """
  Aviso proativo do agente ao corretor (nao e resposta a uma mensagem): sai pelo mesmo caminho de `responder/2`, com o prefixo,
  o teto de envio e o gancho. {:error, :sem_laco} se o laco do tenant nao esta de pe (o chamador registra que nao enviou).
  """
  def avisar(tenant, texto) when is_binary(texto) do
    case Registry.lookup(Nucleo.LacoReg, tenant) do
      [{pid, _}] -> GenServer.cast(pid, {:avisar, texto})
      [] -> {:error, :sem_laco}
    end
  end

  @impl GenServer
  def init({tenant, opts}) do
    Nucleo.Inicializacao.validar(tenant)
    mod = opts[:canal] || canal_vinculado(tenant)
    {:ok, ref} = mod.iniciar(tenant, self(), opts[:canal_opts] || [])
    auto = automacao(tenant)
    conv = conversa(tenant)
    {:ok, %{tenant: tenant, mod: mod, ref: ref, auto: auto, conv: conv, prefixo: prefixo(conv, auto)}}
  end

  defp prefixo(conv, auto) do
    Enum.find_value([conv, auto], @prefixo, fn m ->
      is_atom(m) and m != nil and m != :inativo and Code.ensure_loaded?(m) and function_exported?(m, :prefixo, 0) && m.prefixo()
    end)
  end

  # automacao ATIVA que conversa em texto livre (conversar/2) e/ou trata midia (midia/2), sem ser um Passo.
  # Ex.: trafego. Passo (Eco) tem precedencia: se existe, o laco usa o passo.
  defp conversa(tenant) do
    for %{automacao: a, estado: "ativo"} <- Registro.contratos(tenant),
        mod = Module.concat([a]),
        Code.ensure_loaded?(mod) and function_exported?(mod, :conversar, 2),
        reduce: nil,
        do: (_ -> mod)
  end

  # automacao ATIVA vinculada que implementa Nucleo.Passo; sem ela vale o esqueleto (contador).
  # Se so ha vinculo inativo_incompativel ou desativado (pelo admin), a automacao nao roda para este tenant (:inativo).
  @doc false
  def automacao(tenant) do
    linhas = Registro.contratos(tenant)

    ativa =
      for %{automacao: a, estado: "ativo"} <- linhas,
          mod = Module.concat([a]),
          Code.ensure_loaded?(mod) and function_exported?(mod, :passo, 2),
          reduce: nil,
          do: (_ -> mod)

    if ativa == nil and Enum.any?(linhas, &(&1.estado in ["inativo_incompativel", "desativado"])), do: :inativo, else: ativa
  end

  defp canal_vinculado(tenant) do
    %{canal: c} = Enum.find(Registro.vinculos(), &(&1.tenant == tenant)) || raise "tenant nao vinculado: #{tenant}"
    String.to_existing_atom("Elixir." <> c)
  end

  @impl GenServer
  def handle_call(:canal, _, s), do: {:reply, s.ref, s}

  @impl GenServer
  def handle_cast({:avisar, texto}, s) do
    responder(s, texto)
    {:noreply, s}
  end

  @impl GenServer
  def handle_info({:mensagem, _}, %{auto: :inativo} = s), do: {:noreply, s}
  def handle_info({:midia, _}, %{auto: :inativo} = s), do: {:noreply, s}

  def handle_info({:midia, msg}, %{conv: conv} = s) when conv != nil do
    if function_exported?(conv, :midia, 2), do: conversar(s, fn -> conv.midia(s.tenant, msg) end)
    {:noreply, s}
  end

  def handle_info({:midia, _}, s), do: {:noreply, s}

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

  def handle_info({:mensagem, texto}, %{conv: conv} = s) when conv != nil do
    conversar(s, fn -> conv.conversar(s.tenant, texto) end)
    {:noreply, s}
  end

  def handle_info({:mensagem, _texto}, s) do
    n = ((Registro.ler(s.tenant, "contador") || %{})["n"] || 0) + 1
    {:ok, _} = Registro.gravar(s.tenant, "contador", %{"n" => n})
    responder(s, "recebi ##{n}")
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  # o texto/midia do corretor nao vira evento: so o resultado (resposta enviada ou falha sem conteudo)
  defp conversar(s, f) do
    case f.() do
      {:ok, resposta} when is_binary(resposta) or (is_tuple(resposta) and elem(resposta, 0) == :audio) -> responder(s, resposta)
      {:ok, [_ | _] = respostas} -> responder_lista(s, respostas)
      {:error, e} -> Registro.evento(s.tenant, "conversa_falhou", %{"erro" => inspect(e)})
      _ -> :ok
    end
  rescue
    e -> Registro.evento(s.tenant, "conversa_falhou", %{"erro" => e.__struct__ |> inspect()})
  end

  defp ler(t, k, :ultimo), do: Registro.ler(t, k)
  defp ler(t, k, :historico), do: Enum.map(Registro.historico(t, k), & &1.valor)

  defp responder(s, {:audio, _, _, texto} = item) do
    teto = Registro.config(s.tenant)["teto_por_min"] || 10

    with :ok <- Gancho.intercepta(s.tenant, {:enviar, texto}),
         {:limite, false} <- {:limite, Registro.eventos_recentes(s.tenant, "enviado", 60) >= teto} do
      enviar(s, item)
    else
      {:limite, true} -> Registro.evento(s.tenant, "envio_limitado")
      {:bloquear, m} -> Registro.evento(s.tenant, "envio_bloqueado", %{"motivo" => m})
    end
  end

  defp responder(s, texto) do
    teto = Registro.config(s.tenant)["teto_por_min"] || 10

    with :ok <- Gancho.intercepta(s.tenant, {:enviar, texto}),
         {:limite, false} <- {:limite, Registro.eventos_recentes(s.tenant, "enviado", 60) >= teto} do
      enviar(s, texto)
    else
      {:limite, true} -> Registro.evento(s.tenant, "envio_limitado")
      {:bloquear, m} -> Registro.evento(s.tenant, "envio_bloqueado", %{"motivo" => m})
    end
  end

  defp enviar(s, {:audio, bytes, opts, texto}) do
    Code.ensure_loaded(s.mod)

    r = if function_exported?(s.mod, :enviar_audio, 3), do: s.mod.enviar_audio(s.ref, bytes, opts), else: {:error, :sem_audio}

    case r do
      :ok ->
        Registro.evento(s.tenant, "enviado", %{"tipo" => "audio"})

      {:error, e} ->
        Registro.evento(s.tenant, "audio_falhou", %{"erro" => inspect(e)})
        enviar(s, texto)
    end
  end

  defp enviar(s, texto) do
    case s.mod.enviar_texto(s.ref, s.prefixo <> texto) do
      :ok -> Registro.evento(s.tenant, "enviado")
      {:error, e} -> Registro.evento(s.tenant, "envio_falhou", %{"erro" => inspect(e)})
    end
  end

  defp texto_de({:audio, _, _, t}), do: t
  defp texto_de(t), do: t

  # varias mensagens em ordem; cada uma com prefixo; respeita o teto_por_min restante
  defp responder_lista(s, textos) do
    cfg = Registro.config(s.tenant)
    teto = cfg["teto_por_min"] || 10
    restante = teto - Registro.eventos_recentes(s.tenant, "enviado", 60)
    pausa = cfg["pausa_envio_ms"] || 0

    cond do
      restante <= 0 ->
        Registro.evento(s.tenant, "envio_limitado")

      length(textos) <= restante ->
        textos |> Enum.with_index() |> Enum.each(fn {t, i} -> if i > 0 and pausa > 0, do: Process.sleep(pausa); responder(s, t) end)

      true ->
        {cabem, resto} = Enum.split(textos, restante - 1)
        Enum.each(cabem, &responder(s, &1))
        responder(s, resto |> Enum.map(&texto_de/1) |> Enum.join("

"))
    end
  end
end
