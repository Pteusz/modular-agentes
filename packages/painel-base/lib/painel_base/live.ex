defmodule PainelBase.InicioLive do
  use Phoenix.LiveView
  import PainelBase.Componentes
  alias Nucleo.Conexao
  alias PainelBase.{Formato, Fonte}

  def mount(_p, _s, socket) do
    t = socket.assigns.usuario.tenant_id
    campanhas = case Fonte.campanhas(t) do {:ok, l} -> l; _ -> nil end

    {:ok,
     assign(socket,
       ativo: :inicio,
       plano: Fonte.plano_aguardando(t),
       campanhas: campanhas,
       canal: Formato.canal(Conexao.estado(t))
     )}
  end

  def render(assigns) do
    ~H"""
    <h1>Olá, {@usuario.nome}</h1>
    <section class="cartao">
      <h2>Plano do agente</h2>
      <p :if={@plano}><span class="simbolo" aria-hidden="true">…</span> Há um plano aguardando sua resposta no WhatsApp. <.link navigate="/agente">Ver o plano</.link></p>
      <p :if={!@plano}><span class="simbolo" aria-hidden="true">✓</span> Nenhum plano aguardando.</p>
    </section>
    <section class="cartao">
      <h2>Campanhas</h2>
      <p :if={@campanhas}>{length(@campanhas)} na sua conta. <.link navigate="/campanhas">Ver campanhas</.link></p>
      <p :if={!@campanhas}>Conta de anúncios ainda não conectada.</p>
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

  def mount(_p, _s, socket) do
    resposta = Fonte.campanhas(socket.assigns.usuario.tenant_id)
    {:ok, assign(socket, ativo: :campanhas, resposta: resposta)}
  end

  def render(assigns) do
    ~H"""
    <h1>Campanhas</h1>
    <%= case @resposta do %>
      <% {:ok, []} -> %>
        <p class="apoio">Nenhuma campanha ainda. Peça ao agente pelo WhatsApp.</p>
      <% {:ok, lista} -> %>
        <section :for={c <- lista} class="cartao">
          <h2><.link navigate={"/campanhas/" <> c["id"]}>{c["nome"]}</.link></h2>
          <p><.estado status={c["status"]} /></p>
          <.metricas m={c["metricas"]} cpr={c["custo_por_resultado"]} dias={c["dias"]} />
        </section>
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
        <.fala_agente texto={@plano["resumo"]} />
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
  alias PainelBase.{Formato, Fonte}

  def mount(_p, _s, socket) do
    t = socket.assigns.usuario.tenant_id
    if connected?(socket), do: Conexao.assinar(t)
    {:ok, socket |> assign(ativo: :conta, anuncios: Fonte.conta(t)) |> estado(Conexao.estado(t))}
  end

  def handle_info({:canal_estado, t, e}, socket) do
    # so o estado do PROPRIO tenant da sessao
    if t == socket.assigns.usuario.tenant_id, do: {:noreply, estado(socket, e)}, else: {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("conectar", _, socket) do
    Conexao.conectar(socket.assigns.usuario.tenant_id)
    {:noreply, socket}
  end

  def handle_event("desconectar", _, socket) do
    Conexao.encerrar(socket.assigns.usuario.tenant_id)
    {:noreply, socket}
  end

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
      <div :if={@qr} class="qr-caixa">
        {@qr}
        <p class="apoio">No celular: WhatsApp → Aparelhos conectados → Conectar um aparelho, e leia o código.</p>
      </div>
      <button :if={@canal == :sem_sessao} type="button" class="botao" phx-click="conectar">Conectar WhatsApp</button>
      <button :if={@canal != :sem_sessao} type="button" class="botao secundario" phx-click="desconectar">Desconectar</button>
    </section>
    <section class="cartao">
      <h2>Conta de anúncios</h2>
      <%= if @anuncios do %>
        <dl class="metricas">
          <div><dt>Conta</dt><dd>{@anuncios["conta_id"]}</dd></div>
          <div><dt>Token</dt><dd>{@anuncios["token"]}</dd></div>
          <div><dt>Situação</dt><dd>{@anuncios["status"]}</dd></div>
        </dl>
      <% else %>
        <p class="apoio">Nenhuma conta de anúncios conectada. Fale com o agente pelo WhatsApp para conectar.</p>
      <% end %>
    </section>
    """
  end
end
