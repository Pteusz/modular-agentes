defmodule GestaoEquipe.EquipeController do
  @moduledoc """
  Telas da equipe (paginas comuns; formularios POST com token CSRF do painel-base). O ator e SEMPRE o usuario da sessao;
  o corretor vem da URL mas so e achado dentro da equipe do ator. Mensagens por codigo fixo na URL (sem flash, sem texto livre).
  """
  use Phoenix.Controller, formats: [:html], layouts: [html: {PainelBase.Layouts, :app}]
  import Plug.Conn

  @nav [{"/equipe", "Painel", :painel}, {"/equipe/corretores", "Equipe", :equipe}, {"/equipe/ia", "IA", :ia}, {"/equipe/alertas", "Alertas", :alertas}]
  @campos ~w(nome sobrenome usuario email numero filiacao site pagina_id gerenciador_id instagram_id pixel_id)

  defp ator(conn), do: conn.assigns.usuario
  defp pagina(conn, tpl, ativo, extra), do: render(conn, tpl, [nav: @nav, ativo: ativo, papel: GestaoEquipe.papel(ator(conn)), aviso: conn.params["aviso"], erro: conn.params["erro"]] ++ extra)
  defp id(params), do: (case Integer.parse(to_string(params["id"])) do {n, ""} -> n; _ -> 0 end)
  defp nao_encontrado(conn), do: conn |> put_status(404) |> render(:nao_encontrado, nav: @nav, ativo: :equipe)

  def painel(conn, _), do: pagina(conn, :painel, :painel, p: GestaoEquipe.painel(ator(conn)))

  def lista(conn, params) do
    a = ator(conn)
    filtros = Map.take(params, ~w(nome sobrenome numero email filiacao))
    pagina(conn, :lista, :equipe, corretores: GestaoEquipe.listar(a, filtros), filtros: filtros, sugestoes: GestaoEquipe.filiacoes(a))
  end

  def novo(conn, _), do: pagina(conn, :novo, :equipe, v: %{}, sugestoes: GestaoEquipe.filiacoes(ator(conn)), falha: nil)

  def criar(conn, params) do
    a = ator(conn)

    case GestaoEquipe.cadastrar_corretor(a, params) do
      {:ok, c} -> redirect(conn, to: "/equipe/corretores/#{c.id}?aviso=cadastrado")
      {:error, e} -> conn |> put_status(422) |> pagina(:novo, :equipe, v: Map.take(params, @campos), sugestoes: GestaoEquipe.filiacoes(a), falha: codigo(e))
    end
  end

  def corretor(conn, params) do
    a = ator(conn)

    case GestaoEquipe.corretor(a, id(params)) do
      {:ok, c} ->
        pagina(conn, :corretor, :equipe,
          c: c,
          cred: a |> GestaoEquipe.credenciais(c.id) |> Map.drop(["token"]),
          st: GestaoEquipe.status(a, c.id),
          campanhas: GestaoEquipe.campanhas(a, c.id),
          ia: GestaoEquipe.ia(a, c.id),
          sugestoes: GestaoEquipe.filiacoes(a)
        )

      _ ->
        nao_encontrado(conn)
    end
  end

  def editar(conn, params), do: acao(conn, params, "salvo", &GestaoEquipe.editar(ator(conn), id(&1), Map.take(&1, @campos ++ ["token"])))
  def desativar(conn, params), do: acao(conn, params, "desativado", &GestaoEquipe.desativar(ator(conn), id(&1)))
  def reativar(conn, params), do: acao(conn, params, "reativado", &GestaoEquipe.reativar(ator(conn), id(&1)))
  def sincronizar(conn, params), do: acao(conn, params, "sincronizado", &GestaoEquipe.sincronizar(ator(conn), id(&1)))

  def excluir(conn, params) do
    case GestaoEquipe.excluir(ator(conn), id(params), params["confirmacao"]) do
      :ok -> redirect(conn, to: "/equipe/corretores?aviso=excluido")
      {:error, :nao_encontrado} -> nao_encontrado(conn)
      {:error, e} -> redirect(conn, to: "/equipe/corretores/#{id(params)}?erro=#{codigo(e)}")
    end
  end

  # mesma volta para todas: sucesso ou erro, de volta a pagina do corretor com um codigo fixo
  defp acao(conn, params, aviso, fun) do
    case fun.(params) do
      r when r == :ok or elem(r, 0) == :ok -> redirect(conn, to: "/equipe/corretores/#{id(params)}?aviso=#{aviso}")
      {:error, :nao_encontrado} -> nao_encontrado(conn)
      {:error, e} -> redirect(conn, to: "/equipe/corretores/#{id(params)}?erro=#{codigo(e)}")
    end
  end

  def ia(conn, _), do: pagina(conn, :ia, :ia, itens: GestaoEquipe.ia_geral(ator(conn)))
  def alertas(conn, _), do: pagina(conn, :alertas, :alertas, itens: GestaoEquipe.alertas(ator(conn)))
  def auditoria(conn, _), do: pagina(conn, :auditoria, :painel, itens: GestaoEquipe.auditoria(ator(conn), 100))

  def admins(conn, _) do
    if GestaoEquipe.papel(ator(conn)) == :dono,
      do: pagina(conn, :admins, :painel, itens: GestaoEquipe.admins(ator(conn)), falha: nil),
      else: conn |> send_resp(403, "Acesso negado") |> halt()
  end

  def criar_admin(conn, params) do
    case GestaoEquipe.criar_admin(ator(conn), Map.take(params, ~w(nome email))) do
      {:ok, _} -> redirect(conn, to: "/equipe/admins?aviso=admin_criado")
      {:error, :sem_permissao} -> conn |> send_resp(403, "Acesso negado") |> halt()
      {:error, e} -> conn |> put_status(422) |> pagina(:admins, :painel, itens: GestaoEquipe.admins(ator(conn)), falha: codigo(e))
    end
  end

  defp codigo({:duplicado, campo}), do: "duplicado_#{campo}"
  defp codigo({:invalido, campo}), do: "invalido_#{campo}"
  defp codigo(e) when is_atom(e), do: Atom.to_string(e)
  defp codigo(_), do: "erro"
end

defmodule GestaoEquipe.EquipeHTML do
  use Phoenix.Component
  import PainelBase.Componentes, only: [estado: 1, metricas: 1]
  import PainelBase.Layouts, only: [csrf: 1]
  alias PainelBase.Formato

  @avisos %{
    "cadastrado" => "Corretor cadastrado. O convite foi enviado por e-mail: ele define a senha e lê o QR do WhatsApp.",
    "salvo" => "Alterações salvas.",
    "desativado" => "Corretor desativado: o login e o agente estão bloqueados. Dá para reativar.",
    "reativado" => "Corretor reativado.",
    "sincronizado" => "Dados atualizados.",
    "excluido" => "Corretor excluído: dados pessoais apagados e WhatsApp desvinculado. A campanha na Meta não foi apagada.",
    "admin_criado" => "Admin criado. O convite foi enviado por e-mail."
  }
  @erros %{
    "duplicado_usuario" => "Esse usuário já está em uso.",
    "duplicado_email" => "Esse e-mail já está em uso.",
    "duplicado_numero" => "Esse número de WhatsApp já está em uso.",
    "invalido_nome" => "Informe o nome.",
    "invalido_sobrenome" => "Informe o sobrenome.",
    "invalido_email" => "E-mail inválido.",
    "invalido_usuario" => "Usuário inválido (3 a 40 letras, números, ponto, hífen ou _).",
    "invalido_numero" => "Número de WhatsApp inválido (com DDI e DDD).",
    "invalido_credencial" => "Informe o token e o id do gerenciador de anúncios.",
    "credencial_invalida" => "A plataforma recusou a credencial. Nada foi salvo.",
    "trafego_indisponivel" => "O módulo de tráfego não está disponível.",
    "email_falhou" => "Não foi possível enviar o convite por e-mail.",
    "confirmacao" => "Para excluir, digite o usuário do corretor exatamente como está cadastrado.",
    "sem_permissao" => "Sem permissão."
  }

  def mensagem(nil), do: nil
  def mensagem(cod), do: Map.get(@avisos, cod)
  def erro_txt(nil), do: nil
  def erro_txt(cod), do: Map.get(@erros, cod, "Não foi possível concluir.")

  def hora(nil), do: "nunca"
  def hora(%DateTime{} = dt), do: Calendar.strftime(dt, "%d/%m/%Y %H:%M")

  def hora(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> hora(dt)
      _ -> "nunca"
    end
  end

  def reais(v) when is_number(v), do: Formato.brl(round(v * 100))
  def reais(_), do: "—"

  def nome(c), do: String.trim("#{c.nome} #{c.sobrenome}")
  def rotulo_status("ativo"), do: {"Ativo", "▶"}
  def rotulo_status("desativado"), do: {"Desativado", "❚❚"}
  def rotulo_status(_), do: {"—", "•"}

  def token_txt("ok"), do: {"Token válido", "✓"}
  def token_txt("token invalido"), do: {"Token inválido", "✕"}
  def token_txt(o) when o in [nil, "sem conta"], do: {"Sem conta de anúncio", "○"}
  def token_txt(_), do: {"Token sem dados", "?"}

  def alerta_txt(:sessao_caida), do: "Sessão do WhatsApp caiu"
  def alerta_txt(:token_invalido), do: "Token da conta de anúncio inválido"
  def alerta_txt(:campanha_reprovada), do: "Campanha reprovada pela plataforma"
  def alerta_txt(:numero_diferente), do: "WhatsApp pareado é de outro número"

  def acao_txt("corretor.cadastrar"), do: "Cadastrou corretor"
  def acao_txt("corretor.editar"), do: "Editou corretor"
  def acao_txt("corretor.desativar"), do: "Desativou corretor"
  def acao_txt("corretor.reativar"), do: "Reativou corretor"
  def acao_txt("corretor.excluir"), do: "Excluiu corretor"
  def acao_txt("corretor.sincronizar"), do: "Atualizou dados do corretor"
  def acao_txt("admin.criar"), do: "Criou admin"
  def acao_txt(a), do: a

  # ---- pecas
  attr :aviso, :string, default: nil
  attr :erro, :string, default: nil

  def mensagens(assigns) do
    ~H"""
    <p :if={mensagem(@aviso)} class="aviso ok" role="status"><span class="simbolo" aria-hidden="true">✓</span> {mensagem(@aviso)}</p>
    <p :if={@erro} class="aviso erro" role="alert"><span class="simbolo" aria-hidden="true">✕</span> {erro_txt(@erro)}</p>
    """
  end

  attr :nome, :string, required: true
  attr :rotulo, :string, required: true
  attr :valor, :any, default: nil
  attr :tipo, :string, default: "text"
  attr :req, :boolean, default: false
  attr :lista, :string, default: nil
  attr :dica, :string, default: nil

  def campo(assigns) do
    ~H"""
    <label for={"c-" <> @nome}>{@rotulo}</label>
    <input id={"c-" <> @nome} name={@nome} type={@tipo} value={@valor} required={@req} list={@lista} autocomplete="off" />
    <span :if={@dica} class="apoio">{@dica}</span>
    """
  end

  attr :acao, :string, required: true
  attr :v, :map, required: true
  attr :edicao, :boolean, default: false
  attr :sugestoes, :list, default: []
  attr :botao, :string, required: true

  def form_corretor(assigns) do
    ~H"""
    <form method="post" action={@acao} class="formulario">
      <.csrf />
      <h2>Dados</h2>
      <.campo nome="nome" rotulo="Nome" valor={@v["nome"]} req />
      <.campo nome="sobrenome" rotulo="Sobrenome" valor={@v["sobrenome"]} />
      <.campo nome="usuario" rotulo="Usuário" valor={@v["usuario"]} req />
      <.campo nome="email" rotulo="E-mail" tipo="email" valor={@v["email"]} req />
      <.campo nome="numero" rotulo="Número do WhatsApp" tipo="tel" valor={@v["numero"]} req dica="Com DDI e DDD. O corretor lê o QR deste número." />
      <.campo nome="filiacao" rotulo="Filiação" valor={@v["filiacao"]} lista="filiacoes" dica="Texto livre; sugerimos os valores já usados." />
      <datalist id="filiacoes"><option :for={f <- @sugestoes} value={f}></option></datalist>
      <.campo nome="site" rotulo="Site" tipo="url" valor={@v["site"]} />
      <h2>Conta de anúncio</h2>
      <.campo nome="token" rotulo="Token de acesso" tipo="password" req={!@edicao} dica={if @edicao, do: "Deixe em branco para manter o token salvo.", else: "Fica cifrado; ninguém o vê depois."} />
      <.campo nome="gerenciador_id" rotulo="Id do gerenciador de anúncios" valor={@v["gerenciador_id"]} req />
      <.campo nome="pagina_id" rotulo="Id da página" valor={@v["pagina_id"]} />
      <.campo nome="instagram_id" rotulo="Id do Instagram" valor={@v["instagram_id"]} />
      <.campo nome="pixel_id" rotulo="Id do pixel" valor={@v["pixel_id"]} />
      <button type="submit" class="botao">{@botao}</button>
    </form>
    """
  end

  # ---- paginas
  def painel(assigns) do
    ~H"""
    <h1>Painel da equipe</h1>
    <.mensagens aviso={@aviso} erro={@erro} />
    <section class="cartao">
      <dl class="metricas">
        <div><dt>Gasto total (7 dias)</dt><dd>{Formato.brl(@p.gasto_total)}</dd></div>
        <div><dt>Campanhas ativas</dt><dd>{Formato.numero(@p.campanhas_ativas)}</dd></div>
        <div><dt>Custo de IA</dt><dd>{reais(@p.custo_ia_brl)}</dd></div>
      </dl>
    </section>
    <h2>Corretores</h2>
    <p :if={@p.corretores == []} class="apoio">Nenhum corretor ainda. <a href="/equipe/corretores/novo">Cadastrar o primeiro</a>.</p>
    <section :for={c <- @p.corretores} class="cartao">
      <h2><a href={"/equipe/corretores/#{c.id}"}>{nome(c)}</a></h2>
      <p class="apoio">{c.filiacao}</p>
      <dl class="metricas">
        <div><dt>Gasto</dt><dd>{Formato.brl(c.gasto)}</dd></div>
        <div><dt>Campanhas ativas</dt><dd>{c.campanhas_ativas}</dd></div>
        <div><dt>Custo de IA</dt><dd>{reais(c.custo_ia_brl)}</dd></div>
      </dl>
      <p class="linha-estados">
        <span class="estado">{elem(rotulo_status(c.status), 1)} {elem(rotulo_status(c.status), 0)}</span>
        <span class="estado">{elem(Formato.canal(c.whatsapp), 1)} WhatsApp: {elem(Formato.canal(c.whatsapp), 0)}</span>
        <span class="estado">{elem(token_txt(c.token), 1)} {elem(token_txt(c.token), 0)}</span>
      </p>
    </section>
    <p class="apoio">
      <a href="/equipe/auditoria">Log de auditoria</a>
      <span :if={@papel == :dono}> · <a href="/equipe/admins">Administradores</a></span>
    </p>
    """
  end

  def lista(assigns) do
    ~H"""
    <h1>Equipe</h1>
    <.mensagens aviso={@aviso} erro={@erro} />
    <p><a class="botao" href="/equipe/corretores/novo">Cadastrar corretor</a></p>
    <form method="get" action="/equipe/corretores" class="formulario cartao">
      <h2>Filtrar</h2>
      <.campo nome="nome" rotulo="Nome" valor={@filtros["nome"]} />
      <.campo nome="sobrenome" rotulo="Sobrenome" valor={@filtros["sobrenome"]} />
      <.campo nome="numero" rotulo="Número" valor={@filtros["numero"]} />
      <.campo nome="email" rotulo="E-mail" valor={@filtros["email"]} />
      <.campo nome="filiacao" rotulo="Filiação" valor={@filtros["filiacao"]} lista="filiacoes" />
      <datalist id="filiacoes"><option :for={f <- @sugestoes} value={f}></option></datalist>
      <button type="submit" class="botao secundario">Filtrar</button>
    </form>
    <p :if={@corretores == []} class="apoio">Nenhum corretor encontrado.</p>
    <section :for={c <- @corretores} class="cartao">
      <h2><a href={"/equipe/corretores/#{c.id}"}>{nome(c)}</a></h2>
      <p class="apoio">{c.filiacao} · {c.email}</p>
      <p><span class="estado">{elem(rotulo_status(c.status), 1)} {elem(rotulo_status(c.status), 0)}</span></p>
    </section>
    """
  end

  def novo(assigns) do
    ~H"""
    <p class="voltar"><a href="/equipe/corretores">← Equipe</a></p>
    <h1>Cadastrar corretor</h1>
    <p :if={@falha} class="aviso erro" role="alert"><span class="simbolo" aria-hidden="true">✕</span> {erro_txt(@falha)}</p>
    <.form_corretor acao="/equipe/corretores" v={@v} sugestoes={@sugestoes} botao="Cadastrar e enviar convite" />
    """
  end

  def corretor(assigns) do
    assigns = Map.put(assigns, :v, Map.merge(%{"nome" => assigns.c.nome, "sobrenome" => assigns.c.sobrenome, "usuario" => assigns.c.usuario, "email" => assigns.c.email, "numero" => assigns.c.numero, "filiacao" => assigns.c.filiacao, "site" => assigns.c.site}, assigns.cred))

    ~H"""
    <p class="voltar"><a href="/equipe/corretores">← Equipe</a></p>
    <h1>{nome(@c)}</h1>
    <.mensagens aviso={@aviso} erro={@erro} />
    <p>
      <span class="estado">{elem(rotulo_status(@c.status), 1)} {elem(rotulo_status(@c.status), 0)}</span>
      <span class="estado">{elem(Formato.canal(@st.whatsapp), 1)} WhatsApp: {elem(Formato.canal(@st.whatsapp), 0)}</span>
      <span class="estado">{elem(token_txt(@st.token), 1)} {elem(token_txt(@st.token), 0)}</span>
    </p>
    <section class="cartao">
      <h2>Status</h2>
      <p class="apoio">Última sincronização: {hora(@st.sincronizacao)}</p>
      <form method="post" action={"/equipe/corretores/#{@c.id}/sincronizar"}>
        <.csrf />
        <button type="submit" class="botao secundario">Atualizar agora</button>
      </form>
    </section>

    <h2>Campanhas</h2>
    <%= case @campanhas do %>
      <% {:ok, []} -> %>
        <p class="apoio">Nenhuma campanha ainda.</p>
      <% {:ok, lista} -> %>
        <section :for={camp <- lista} class="cartao">
          <h2>{camp["nome"]}</h2>
          <p><.estado status={camp["status"]} /></p>
          <.metricas m={camp["metricas"]} cpr={camp["custo_por_resultado"]} dias={camp["dias"] || 7} />
        </section>
      <% _ -> %>
        <p class="aviso atencao">Campanhas indisponíveis agora (token inválido ou plataforma fora do ar).</p>
    <% end %>

    <section class="cartao">
      <h2>IA</h2>
      <p class="apoio">Custo de IA acumulado: {reais(@ia.custo_ia_brl)}. Só contagens: a conversa do corretor não aparece aqui.</p>
      <ul class="papeis">
        <li :for={p <- @ia.papeis}>
          <strong>{p.papel}</strong>
          <span>Fez {p.fez}</span> · <span>Erros {p.erros}</span> · <span>Aprendeu {p.aprendeu}</span>
        </li>
      </ul>
    </section>

    <h2>Editar cadastro</h2>
    <.form_corretor acao={"/equipe/corretores/#{@c.id}/editar"} v={@v} edicao sugestoes={@sugestoes} botao="Salvar alterações" />

    <section class="cartao">
      <h2>Acesso</h2>
      <%= if @c.status == "ativo" do %>
        <p class="apoio">Desativar bloqueia o login e o agente. Dá para reativar depois.</p>
        <form method="post" action={"/equipe/corretores/#{@c.id}/desativar"}>
          <.csrf />
          <button type="submit" class="botao secundario">Desativar</button>
        </form>
      <% else %>
        <p class="apoio">Este corretor está desativado.</p>
        <form method="post" action={"/equipe/corretores/#{@c.id}/reativar"}>
          <.csrf />
          <button type="submit" class="botao">Reativar</button>
        </form>
      <% end %>
    </section>

    <section class="cartao perigo">
      <h2>Excluir corretor</h2>
      <p class="apoio">Apaga o cadastro, o login e as credenciais e desvincula o WhatsApp. Não dá para desfazer. A campanha na Meta <strong>não</strong> é apagada.</p>
      <form method="post" action={"/equipe/corretores/#{@c.id}/excluir"} class="formulario">
        <.csrf />
        <.campo nome="confirmacao" rotulo={"Digite o usuário (#{@c.usuario}) para confirmar"} req />
        <button type="submit" class="botao perigo">Excluir</button>
      </form>
    </section>
    """
  end

  def ia(assigns) do
    ~H"""
    <h1>IA</h1>
    <p class="apoio">Custo de IA e atividade por corretor. Só metadados; nunca a conversa.</p>
    <p :if={@itens == []} class="apoio">Nenhum corretor ativo.</p>
    <section :for={c <- @itens} class="cartao">
      <h2><a href={"/equipe/corretores/#{c.id}"}>{nome(c)}</a></h2>
      <p>Custo de IA: <strong>{reais(c.custo_ia_brl)}</strong></p>
      <ul class="papeis">
        <li :for={p <- c.papeis}><strong>{p.papel}</strong> <span>Fez {p.fez}</span> · <span>Erros {p.erros}</span> · <span>Aprendeu {p.aprendeu}</span></li>
      </ul>
    </section>
    """
  end

  def alertas(assigns) do
    ~H"""
    <h1>Alertas</h1>
    <p :if={@itens == []} class="aviso ok"><span class="simbolo" aria-hidden="true">✓</span> Tudo em ordem.</p>
    <section :for={a <- @itens} class="cartao alerta">
      <h2><span class="simbolo" aria-hidden="true">!</span> {alerta_txt(a.tipo)}</h2>
      <p><a href={"/equipe/corretores/#{a.corretor_id}"}>{String.trim("#{a.nome} #{a.sobrenome}")}</a></p>
    </section>
    """
  end

  def auditoria(assigns) do
    ~H"""
    <p class="voltar"><a href="/equipe">← Painel</a></p>
    <h1>Auditoria</h1>
    <p :if={@itens == []} class="apoio">Nada registrado ainda.</p>
    <section :for={i <- @itens} class="cartao">
      <p><strong>{acao_txt(i.acao)}</strong> <span class="apoio">por {i.ator_nome} em {hora(i.em)}</span></p>
      <p class="apoio mono">{i.alvo}<span :if={i.detalhes["campos"]}> · campos: {Enum.join(i.detalhes["campos"], ", ")}</span></p>
    </section>
    """
  end

  def admins(assigns) do
    ~H"""
    <p class="voltar"><a href="/equipe">← Painel</a></p>
    <h1>Administradores</h1>
    <.mensagens aviso={@aviso} erro={@erro} />
    <p :if={@falha} class="aviso erro" role="alert"><span class="simbolo" aria-hidden="true">✕</span> {erro_txt(@falha)}</p>
    <section :for={a <- @itens} class="cartao">
      <p><strong>{a.nome}</strong> · {if a.papel == "dono", do: "Dono", else: "Admin"}</p>
      <p class="apoio">{a.email}</p>
    </section>
    <form method="post" action="/equipe/admins" class="formulario">
      <.csrf />
      <h2>Convidar admin</h2>
      <.campo nome="nome" rotulo="Nome" req />
      <.campo nome="email" rotulo="E-mail" tipo="email" req />
      <button type="submit" class="botao">Enviar convite</button>
    </form>
    """
  end

  def nao_encontrado(assigns) do
    ~H"""
    <h1>Não encontrado</h1>
    <p class="apoio"><a href="/equipe/corretores">Voltar para a equipe</a></p>
    """
  end
end
