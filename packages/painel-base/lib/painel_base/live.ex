defmodule PainelBase.InicioLive do
  use Phoenix.LiveView
  import PainelBase.Componentes
  alias Nucleo.Conexao
  alias PainelBase.{Formato, Fonte}

  # A casca nao espera a plataforma: mostra a ultima foto guardada e atualiza em segundo plano (so com a conexao ao vivo).
  def mount(_p, _s, socket) do
    t = socket.assigns.usuario.tenant_id
    conectada = Fonte.conta(t) != nil
    foto = if conectada, do: Fonte.foto(t)
    ao_vivo = conectada and connected?(socket)

    {:ok,
     socket
     |> assign(
       ativo: :inicio,
       plano: Fonte.plano_aguardando(t),
       conectada: conectada,
       total: foto && foto["campanhas_total"],
       atualizando: ao_vivo,
       falhou: false,
       canal: Formato.canal(Conexao.estado(t))
     )
     |> then(fn s -> if ao_vivo, do: start_async(s, :resumo, fn -> Fonte.atualizar_resumo(t) end), else: s end)}
  end

  def handle_async(:resumo, {:ok, {:ok, foto}}, socket) do
    # erro da plataforma (foto com "erro" ou sem total) mantem os ultimos numeros
    total = if foto["erro"], do: nil, else: foto["campanhas_total"]
    {:noreply, assign(socket, atualizando: false, falhou: total == nil and socket.assigns.total == nil, total: total || socket.assigns.total)}
  end

  def handle_async(:resumo, _falha, socket), do: {:noreply, assign(socket, atualizando: false, falhou: socket.assigns.total == nil)}

  def render(assigns) do
    ~H"""
    <h1>Olá, {@usuario.nome}</h1>
    <section class="cartao">
      <h2>Plano do agente</h2>
      <p :if={@plano}><span class="simbolo" aria-hidden="true">…</span> Há um plano aguardando sua resposta no WhatsApp. <.link navigate="/agente">Ver o plano</.link></p>
      <p :if={!@plano}><span class="simbolo" aria-hidden="true">✓</span> Nenhum plano aguardando.</p>
    </section>
    <section class="cartao" id="resumo-campanhas">
      <h2>Campanhas <span :if={@atualizando} class="atualizando" role="status">atualizando…</span></h2>
      <p :if={@total}>{@total} na sua conta. <.link navigate="/campanhas">Ver campanhas</.link></p>
      <p :if={@conectada and !@total and !@falhou}>Carregando… <.link navigate="/campanhas">Ver campanhas</.link></p>
      <p :if={@conectada and @falhou}>Não foi possível ler as campanhas agora. <.link navigate="/campanhas">Ver campanhas</.link></p>
      <p :if={!@conectada}>Conta de anúncios ainda não conectada.</p>
    </section>
    <section class="cartao">
      <h2>WhatsApp</h2>
      <p><span class="simbolo" aria-hidden="true">{elem(@canal, 1)}</span> {elem(@canal, 0)}. <.link navigate="/conta">Gerenciar</.link></p>
    </section>
    """
  end
end

defmodule PainelBase.CampanhasLive do
  use Phoenix.LiveView
  import PainelBase.Componentes
  alias PainelBase.Fonte

  # Casca na hora; as linhas chegam em segundo plano (ou direto, se o cache curto estiver fresco).
  def mount(_p, _s, socket) do
    t = socket.assigns.usuario.tenant_id

    case Fonte.campanhas_em_cache(t) do
      {:ok, lista} ->
        {:ok, assign(socket, ativo: :campanhas, resposta: {:ok, lista})}

      _ ->
        socket = assign(socket, ativo: :campanhas, resposta: :carregando)
        {:ok, if(connected?(socket), do: start_async(socket, :campanhas, fn -> Fonte.campanhas(t) end), else: socket)}
    end
  end

  def handle_async(:campanhas, {:ok, resposta}, socket), do: {:noreply, assign(socket, resposta: resposta)}
  def handle_async(:campanhas, _falha, socket), do: {:noreply, assign(socket, resposta: {:error, :falha})}

  def render(assigns) do
    ~H"""
    <h1>Campanhas</h1>
    <%= case @resposta do %>
      <% :carregando -> %>
        <div id="carregando" aria-busy="true" aria-live="polite">
          <p class="apoio">Carregando campanhas…</p>
          <section :for={_ <- 1..3} class="cartao esqueleto" aria-hidden="true"><span class="linha"></span><span class="linha curta"></span></section>
        </div>
      <% {:ok, []} -> %>
        <p class="apoio">Nenhuma campanha ainda. Peça ao agente pelo WhatsApp.</p>
      <% {:ok, lista} -> %>
        <section :for={c <- lista} class="cartao">
          <h2><.link navigate={"/campanhas/" <> c["id"]}>{c["nome"]}</.link></h2>
          <p><.estado status={c["status"]} /></p>
          <.metricas m={c["metricas"]} cpr={c["custo_por_resultado"]} dias={c["dias"]} />
        </section>
      <% {:error, :timeout} -> %>
        <p class="aviso erro" role="alert"><span class="simbolo" aria-hidden="true">✕</span> A Meta demorou a responder. Tente de novo em instantes.</p>
      <% _ -> %>
        <p class="aviso erro" role="alert"><span class="simbolo" aria-hidden="true">✕</span> Não foi possível ler as campanhas agora. Verifique a conta de anúncios em Conta.</p>
    <% end %>
    """
  end
end

defmodule PainelBase.AgenteLive do
  use Phoenix.LiveView
  import PainelBase.Componentes
  alias PainelBase.Fonte

  @papeis [planejador: "Planejador", executor: "Executor", verificador: "Verificador", monitor: "Monitor"]

  def mount(_p, _s, socket) do
    t = socket.assigns.usuario.tenant_id
    atividade = Fonte.atividade(t)

    {:ok, assign(socket, ativo: :agente, plano: Fonte.plano_aguardando(t), atividade: for({k, nome} <- @papeis, do: {nome, atividade[k]}))}
  end

  # Esta tela so MOSTRA o plano. A autorizacao e dada apenas no WhatsApp: nao ha botao nem acao de confirmar aqui.
  def render(assigns) do
    ~H"""
    <h1>Agente</h1>
    <section class="cartao">
      <h2>Plano aguardando</h2>
      <%= if @plano do %>
        <.fala_agente texto={@plano["resumo"]} prefixo={@plano["prefixo"] || "[agente]"} />
        <p class="aviso atencao"><span class="simbolo" aria-hidden="true">!</span> Para autorizar, responda no WhatsApp. O painel não cria nem ativa nada.</p>
      <% else %>
        <p>Nenhum plano aguardando.</p>
      <% end %>
    </section>
    <section class="cartao">
      <h2>O que o agente fez</h2>
      <ul class="papeis">
        <li :for={{nome, a} <- @atividade}>
          <strong>{nome}</strong>
          <span>Fez {length(a.fez)}</span> · <span>Erros {length(a.erros)}</span> · <span>Aprendeu {length(a.aprendeu)}</span>
        </li>
      </ul>
    </section>
    """
  end
end

defmodule PainelBase.ContaLive do
  use Phoenix.LiveView
  import PainelBase.Layouts, only: [csrf: 1]
  alias Nucleo.Conexao
  alias PainelBase.{Conta, Formato, Fonte}

  @avisos %{"anuncios_salvo" => "Conta de anúncios salva.", "anuncios_removido" => "Conta de anúncios removida."}
  @erros %{
    "invalido_token" => "O token parece inválido (use o token de acesso, sem espaços).",
    "invalido_conta_id" => "O ID da conta de anúncios deve ter só números (pode começar com act_).",
    "invalido_pagina_id" => "O ID da página é obrigatório e deve ter só números.",
    "invalido_instagram_id" => "O ID do Instagram deve ter só números (ou fique em branco).",
    "token_invalido" => "A plataforma recusou o token.",
    "credencial_invalida" => "A plataforma recusou as credenciais informadas.",
    "inacessivel_conta" => "Esse token não alcança essa conta de anúncios.",
    "inacessivel_pagina" => "Esse token não alcança essa página.",
    "inacessivel_instagram" => "Esse token não alcança esse Instagram.",
    "sem_chave_de_cifra" => "Não foi possível guardar com segurança (chave de cifra ausente).",
    "trafego_indisponivel" => "O módulo de anúncios não está disponível agora.",
    "erro" => "Não foi possível salvar. Confira os dados e tente de novo."
  }

  def mount(params, _s, socket) do
    t = socket.assigns.usuario.tenant_id
    if connected?(socket), do: Conexao.assinar(t)

    {:ok,
     socket
     |> assign(ativo: :conta, anuncios: Fonte.conta(t), aviso: @avisos[params["aviso"]], erro: @erros[params["erro"]], erro_whatsapp: nil, confirmando_reparear: false)
     |> estado(Conexao.estado(t))}
  end

  def handle_info({:canal_estado, t, e}, socket) do
    # so o estado do PROPRIO tenant da sessao
    if t == socket.assigns.usuario.tenant_id, do: {:noreply, estado(socket, e)}, else: {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("conectar", _, socket), do: {:noreply, resultado(socket, Conta.conectar(socket.assigns.usuario))}
  def handle_event("reconectar", _, socket), do: {:noreply, resultado(socket, Conta.reconectar(socket.assigns.usuario))}

  # parear de novo desfaz o pareamento atual: so executa depois do pedido e da confirmacao, sempre no tenant da sessao
  def handle_event("pedir_reparear", _, socket), do: {:noreply, assign(socket, confirmando_reparear: true)}
  def handle_event("cancelar_reparear", _, socket), do: {:noreply, assign(socket, confirmando_reparear: false)}

  def handle_event("reparear", _, %{assigns: %{confirmando_reparear: true}} = socket) do
    {:noreply, socket |> assign(confirmando_reparear: false) |> then(&resultado(&1, Conta.reparear(&1.assigns.usuario)))}
  end

  def handle_event("reparear", _, socket), do: {:noreply, socket}

  def handle_event("desconectar", _, socket) do
    Conta.desconectar(socket.assigns.usuario)
    {:noreply, assign(socket, erro_whatsapp: nil)}
  end

  defp resultado(socket, :ok), do: assign(socket, erro_whatsapp: nil)
  defp resultado(socket, {:error, :desativado}), do: assign(socket, erro_whatsapp: "O WhatsApp está desativado neste ambiente.")
  defp resultado(socket, {:error, _}), do: assign(socket, erro_whatsapp: "Não foi possível conectar o WhatsApp agora. Tente de novo.")

  defp estado(socket, e) do
    qr =
      with {:qr, texto} <- e, {:ok, svg} <- Formato.qr_svg(texto) do
        Phoenix.HTML.raw(svg)
      else
        _ -> nil
      end

    assign(socket, canal: e, rotulo: Formato.canal(e), qr: qr)
  end

  def render(assigns) do
    ~H"""
    <h1>Conta</h1>
    <section class="cartao">
      <h2>Acesso</h2>
      <p>{@usuario.nome}<br /><span class="apoio">{@usuario.email}</span></p>
      <form method="post" action="/sair"><.csrf /><button type="submit" class="botao secundario">Sair</button></form>
    </section>
    <section class="cartao">
      <h2>WhatsApp</h2>
      <p class="estado"><span class="simbolo" aria-hidden="true">{elem(@rotulo, 1)}</span> {elem(@rotulo, 0)}</p>
      <p :if={@erro_whatsapp} class="erro" role="alert">{@erro_whatsapp}</p>
      <div :if={@qr} class="qr-caixa">
        {@qr}
        <p class="apoio">No celular: WhatsApp → Aparelhos conectados → Conectar um aparelho, e leia o código.</p>
      </div>
      <button :if={@canal == :sem_sessao} type="button" class="botao" phx-click="conectar">Conectar WhatsApp</button>
      <button :if={@canal == :desconectado} type="button" class="botao" phx-click="reconectar">Reconectar</button>
      <button :if={@canal != :sem_sessao} type="button" class="botao secundario" phx-click="desconectar">Desconectar</button>
      <button :if={!@confirmando_reparear} type="button" class="botao secundario" phx-click="pedir_reparear">Parear de novo (QR)</button>
      <div :if={@confirmando_reparear} class="aviso" role="alertdialog">
        <p>Isso desfaz o pareamento atual e pede um QR novo; as credenciais antigas ficam guardadas num backup. Continuar?</p>
        <button type="button" class="botao" phx-click="reparear">Sim, parear de novo</button>
        <button type="button" class="botao secundario" phx-click="cancelar_reparear">Cancelar</button>
      </div>
    </section>
    <section class="cartao">
      <h2>Conta de anúncios</h2>
      <p :if={@aviso} class="aviso" role="status">{@aviso}</p>
      <p :if={@erro} class="erro" role="alert">{@erro}</p>
      <%= if @anuncios do %>
        <dl class="metricas">
          <div><dt>Conta</dt><dd>{@anuncios["conta_id"]}</dd></div>
          <div><dt>Token</dt><dd>{@anuncios["token"]}</dd></div>
          <div><dt>Situação</dt><dd>{@anuncios["status"]}</dd></div>
        </dl>
        <details class="substituir">
          <summary class="botao secundario">Substituir</summary>
          <.form_anuncios />
        </details>
        <form method="post" action="/conta/anuncios/remover">
          <.csrf /><button type="submit" class="botao secundario">Remover</button>
        </form>
      <% else %>
        <p class="apoio">Nenhuma conta de anúncios conectada. Informe os dados abaixo ou fale com o agente pelo WhatsApp.</p>
        <.form_anuncios />
      <% end %>
    </section>
    """
  end

  defp form_anuncios(assigns) do
    ~H"""
    <form method="post" action="/conta/anuncios" class="campos" autocomplete="off">
      <.csrf />
      <label>Token de acesso<input type="password" name="token" required autocomplete="off" /></label>
      <label>ID da conta de anúncios<input type="text" name="conta_id" required inputmode="numeric" placeholder="act_1234567890" autocomplete="off" /></label>
      <label>ID da página<input type="text" name="pagina_id" required inputmode="numeric" autocomplete="off" /></label>
      <label>ID do Instagram (opcional)<input type="text" name="instagram_id" inputmode="numeric" autocomplete="off" /></label>
      <button type="submit" class="botao">Salvar</button>
    </form>
    """
  end
end
