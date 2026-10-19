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
     |> assign(ativo: :conta, anuncios: Fonte.conta(t), aviso: @avisos[params["aviso"]], erro: @erros[params["erro"]], erro_whatsapp: nil)
     |> estado(Conexao.estado(t))}
  end

  def handle_info({:canal_estado, t, e}, socket) do
    # so o estado do PROPRIO tenant da sessao
    if t == socket.assigns.usuario.tenant_id, do: {:noreply, estado(socket, e)}, else: {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("conectar", _, socket), do: {:noreply, resultado(socket, Conta.conectar(socket.assigns.usuario))}
  def handle_event("reconectar", _, socket), do: {:noreply, resultado(socket, Conta.reconectar(socket.assigns.usuario))}

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
