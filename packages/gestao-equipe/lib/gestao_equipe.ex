defmodule GestaoEquipe do
  @moduledoc """
  Gestao de equipe: papeis (dono cria admins; admin cadastra corretores), cadastro com credenciais cifradas, lista com filtro,
  desativar (reversivel) x excluir (apaga dados pessoais), painel geral, status, alertas e auditoria.
  O admin ve METADADOS do corretor (campanhas, gasto, custo de IA, status). Nunca a conversa. O trafego so e lido por GestaoEquipe.Fonte.
  Cada equipe (tenant do dono/admins) enxerga so os proprios corretores.
  """
  alias GestaoEquipe.{Auditoria, Fonte, Papeis}
  alias Nucleo.{Canal, Conexao, Registro, Vincular}
  alias PainelBase.Usuarios
  import GestaoEquipe.Banco, only: [q: 1, q: 2]

  @colunas ~w(id equipe tenant_id usuario_id nome sobrenome usuario email numero filiacao site status)
  @texto ~w(nome sobrenome usuario email numero filiacao site)
  @cred ~w(token pagina_id gerenciador_id instagram_id pixel_id)
  @obrigatorios_cred ~w(token gerenciador_id)

  defdelegate papel(usuario), to: Papeis

  # ---------------------------------------------------------------- papeis

  @doc "So o dono cria admin (convite por e-mail pelo painel-base)."
  def criar_admin(ator, attrs) do
    if papel(ator) == :dono do
      nome = limpar(attrs["nome"])
      email = limpar(attrs["email"]) |> String.downcase()

      cond do
        nome == "" -> {:error, {:invalido, :nome}}
        not email_ok?(email) -> {:error, {:invalido, :email}}
        Usuarios.por_email(email) != nil -> {:error, {:duplicado, :email}}
        true ->
          # tenant PROPRIO do admin (WhatsApp, campanhas e conversa so dele); a equipe continua a do dono
          tenant = novo_tenant_admin()

          case Usuarios.convidar(email, nome, tenant) do
            {:ok, u} ->
              case vincular(tenant) do
                :ok ->
                  Papeis.definir_admin(u, ator, Papeis.equipe(ator))
                  Auditoria.registrar(ator, "admin.criar", "usuario:#{u.id}", %{"tenant" => tenant})
                  {:ok, u}

                {:error, _} = e ->
                  desfazer(tenant, 0)
                  e
              end

            {:error, :email_invalido} -> {:error, {:invalido, :email}}
            {:error, e} -> {:error, e}
          end
      end
    else
      {:error, :sem_permissao}
    end
  end

  def admins(ator), do: with(:ok <- permitir(ator), do: Papeis.admins(Papeis.equipe(ator)))

  defp novo_tenant_admin, do: prefixo() <> "a" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  @doc """
  Garante o tenant do proprio dono/admin: vincula o painel e o trafego. Idempotente e so ACRESCENTA: o que ja existe no tenant
  (estado, eventos, sessao do WhatsApp, vinculos antigos) fica como esta. Serve ao dono ja existente (ex.: `mateus`).
  """
  def garantir_tenant(ator), do: with(:ok <- permitir(ator), do: vincular(ator.tenant_id))

  @doc "Conta de anuncios do PROPRIO dono/admin (os corretores usam o cadastro). Valida na plataforma, grava cifrada no tenant dele."
  def minha_conta(ator, attrs) do
    c = Map.new(@cred, &{&1, limpar(attrs[&1])})

    with :ok <- permitir(ator),
         :ok <- if(Enum.any?(@obrigatorios_cred, &(c[&1] == "")), do: {:error, {:invalido, :credencial}}, else: :ok),
         :ok <- Fonte.validar_credencial(para_fonte(c)),
         {:ok, _} <- Fonte.cadastrar_conta(ator.tenant_id, para_fonte(c)) do
      Auditoria.registrar(ator, "conta.cadastrar", ator.tenant_id, %{"campos" => Enum.filter(@cred, &(c[&1] != ""))})
    end
  end

  # ---------------------------------------------------------------- cadastro

  def cadastrar_corretor(ator, attrs) do
    with :ok <- permitir(ator),
         {:ok, c} <- validar(attrs),
         :ok <- unico(c, nil, nil),
         :ok <- Fonte.validar_credencial(para_fonte(c)) do
      criar(ator, c)
    end
  end

  defp criar(ator, c) do
    [[id]] = q("SELECT nextval(pg_get_serial_sequence('ge_corretores','id'))").rows
    tenant = "#{prefixo()}#{id}"

    with {:ok, env} <- Fonte.cifrar(tenant, Jason.encode!(Map.take(c, @cred))),
         :ok <- inserir(ator, id, tenant, c, env),
         :ok <- vincular(tenant),
         {:ok, _} <- Fonte.cadastrar_conta(tenant, para_fonte(c)),
         {:ok, u} <- convidar(c, tenant) do
      q("UPDATE ge_corretores SET usuario_id=$2 WHERE id=$1", [id, u.id])
      Auditoria.registrar(ator, "corretor.cadastrar", tenant, %{"id" => id})
      achar(id)
    else
      {:error, _} = e ->
        desfazer(tenant, id)
        e
    end
  end

  defp inserir(ator, id, tenant, c, env) do
    q(
      "INSERT INTO ge_corretores (id, equipe, tenant_id, nome, sobrenome, usuario, email, numero, filiacao, site, credenciais_cifradas, criado_por) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
      [id, Papeis.equipe(ator), tenant, c["nome"], c["sobrenome"], c["usuario"], c["email"], c["numero"], c["filiacao"], c["site"], env, ator.id]
    )

    :ok
  rescue
    e in Postgrex.Error -> {:error, duplicado(e)}
  end

  defp duplicado(%Postgrex.Error{postgres: %{constraint: "ge_corretores_usuario"}}), do: {:duplicado, :usuario}
  defp duplicado(%Postgrex.Error{postgres: %{constraint: "ge_corretores_email"}}), do: {:duplicado, :email}
  defp duplicado(%Postgrex.Error{postgres: %{constraint: "ge_corretores_numero"}}), do: {:duplicado, :numero}
  defp duplicado(e), do: raise(e)

  defp vincular(tenant) do
    canal = Application.get_env(:gestao_equipe, :canal, Canal.Amarula)

    Enum.reduce_while(automacoes(), :ok, fn mod, :ok ->
      case Vincular.vincular(tenant, mod, canal, %{}) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  # painel-base (login/QR) e, se instalado, o trafego
  defp automacoes, do: Enum.filter([Nucleo.Automacoes.PainelBase, Module.concat(["Nucleo", "Automacoes", "Trafego"])], &Code.ensure_loaded?/1)

  defp convidar(c, tenant) do
    case Usuarios.convidar(c["email"], c["nome"], tenant) do
      {:ok, u} -> {:ok, u}
      {:error, :ja_existe} -> {:error, {:duplicado, :email}}
      {:error, :email_invalido} -> {:error, {:invalido, :email}}
      {:error, e} -> {:error, e}
    end
  end

  # cadastro que falhou no meio: nao deixa tenant, usuario, conta nem linha para tras
  defp desfazer(tenant, id) do
    q("DELETE FROM ge_corretores WHERE id=$1", [id])
    Fonte.remover_conta(tenant)
    q("DELETE FROM pb_usuarios WHERE tenant_id=$1", [tenant])
    for t <- ~w(estado eventos vinculos), do: q("DELETE FROM #{t} WHERE tenant_id=$1", [tenant])
    q("DELETE FROM tenants WHERE id=$1", [tenant])
    :ok
  end

  defp prefixo, do: Application.get_env(:gestao_equipe, :tenant_prefixo, "c")

  # ---------------------------------------------------------------- validacao

  defp validar(attrs) do
    c = Map.new(@texto ++ @cred, &{&1, limpar(attrs[&1])})
    c = c |> Map.update!("email", &String.downcase/1) |> Map.update!("numero", &digitos/1)

    cond do
      c["nome"] == "" -> {:error, {:invalido, :nome}}
      not email_ok?(c["email"]) -> {:error, {:invalido, :email}}
      not usuario_ok?(c["usuario"]) -> {:error, {:invalido, :usuario}}
      not numero_ok?(c["numero"]) -> {:error, {:invalido, :numero}}
      Enum.any?(@obrigatorios_cred, &(c[&1] == "")) -> {:error, {:invalido, :credencial}}
      true -> {:ok, c}
    end
  end

  defp limpar(nil), do: ""
  defp limpar(v), do: v |> to_string() |> String.trim()
  defp digitos(v), do: String.replace(v, ~r/\D/, "")
  defp email_ok?(e), do: String.match?(e, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  defp usuario_ok?(u), do: String.match?(u, ~r/^[\w.\-]{3,40}$/u)
  defp numero_ok?(n), do: String.length(n) in 10..15

  defp para_fonte(c), do: %{"conta_id" => c["gerenciador_id"]} |> Map.merge(Map.take(c, ~w(token pagina_id instagram_id pixel_id))) |> Map.reject(fn {_, v} -> v == "" end)

  # usuario, e-mail e numero unicos entre os corretores nao excluidos (e e-mail tambem entre os usuarios do painel).
  # `c` pode ter so parte dos campos (edicao); `id` e o proprio corretor, `meu` o usuario do painel dele.
  defp unico(c, id, meu) do
    id = id || 0

    cond do
      c["usuario"] && existe?("lower(usuario)=lower($1)", c["usuario"], id) -> {:error, {:duplicado, :usuario}}
      c["email"] && (existe?("lower(email)=lower($1)", c["email"], id) or outro_usuario?(c["email"], meu)) -> {:error, {:duplicado, :email}}
      c["numero"] && existe?("numero=$1", c["numero"], id) -> {:error, {:duplicado, :numero}}
      true -> :ok
    end
  end

  defp existe?(cond, valor, id), do: q("SELECT 1 FROM ge_corretores WHERE #{cond} AND id <> $2 AND status <> 'excluido' LIMIT 1", [valor, id]).rows != []

  defp outro_usuario?(email, meu) do
    case Usuarios.por_email(email) do
      nil -> false
      u -> u.id != meu
    end
  end

  # ---------------------------------------------------------------- consulta

  defp permitir(ator), do: if(papel(ator) in [:dono, :admin], do: :ok, else: {:error, :sem_permissao})

  defp achar(id) do
    case q("SELECT #{Enum.join(@colunas, ", ")} FROM ge_corretores WHERE id=$1", [id]).rows do
      [linha] -> {:ok, @colunas |> Enum.zip(linha) |> Map.new() |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)}
      [] -> {:error, :nao_encontrado}
    end
  end

  @doc "O corretor (nao excluido) da equipe do ator. {:ok, corretor} | {:error, :sem_permissao | :nao_encontrado}"
  def corretor(ator, id) do
    with :ok <- permitir(ator), {:ok, c} <- achar(id) do
      if c.equipe == Papeis.equipe(ator) and c.status != "excluido", do: {:ok, c}, else: {:error, :nao_encontrado}
    end
  end

  @filtros ~w(nome sobrenome email filiacao usuario)

  @doc "Lista com filtro cruzado (E): nome, sobrenome, e-mail, filiacao, usuario (trecho, sem caixa) e numero (trecho de digitos)."
  def listar(ator, filtros) do
    with :ok <- permitir(ator) do
      {clausulas, params} =
        Enum.reduce(@filtros, {["equipe = $1", "status <> 'excluido'"], [Papeis.equipe(ator)]}, fn k, {cl, ps} = acc ->
          case limpar(filtros[k]) do
            "" -> acc
            v -> {cl ++ ["lower(#{k}) LIKE '%' || lower($#{length(ps) + 1}) || '%' ESCAPE '\\'"], ps ++ [escapar(v)]}
          end
        end)

      {clausulas, params} =
        case digitos(limpar(filtros["numero"])) do
          "" -> {clausulas, params}
          n -> {clausulas ++ ["numero LIKE '%' || $#{length(params) + 1} || '%'"], params ++ [n]}
        end

      q("SELECT id FROM ge_corretores WHERE #{Enum.join(clausulas, " AND ")} ORDER BY lower(nome), id", params).rows
      |> Enum.map(fn [id] -> elem(achar(id), 1) end)
    end
  end

  defp escapar(v), do: String.replace(v, ["\\", "%", "_"], fn c -> "\\" <> c end)

  @doc "Valores de filiacao ja usados (sem repeticao), para sugerir no cadastro."
  def filiacoes(ator) do
    with :ok <- permitir(ator) do
      q("SELECT DISTINCT filiacao FROM ge_corretores WHERE equipe=$1 AND status <> 'excluido' AND filiacao IS NOT NULL AND filiacao <> '' ORDER BY 1", [Papeis.equipe(ator)]).rows
      |> List.flatten()
    end
  end

  @doc "Credenciais decifradas (token, pagina_id, gerenciador_id, instagram_id, pixel_id). So para quem edita; nunca vao para tela em claro."
  def credenciais(ator, id) do
    with {:ok, c} <- corretor(ator, id), do: decifrar(c)
  end

  defp decifrar(c) do
    [[env]] = q("SELECT credenciais_cifradas FROM ge_corretores WHERE id=$1", [c.id]).rows

    with true <- is_binary(env),
         {:ok, json} <- Fonte.decifrar(c.tenant_id, env),
         {:ok, mapa} <- Jason.decode(json) do
      mapa
    else
      _ -> %{}
    end
  end

  # ---------------------------------------------------------------- edicao

  def editar(ator, id, attrs) do
    with {:ok, atual} <- corretor(ator, id),
         {:ok, campos} <- campos_editados(atual, attrs),
         :ok <- unico(Map.take(campos, ~w(usuario email numero)), atual.id, atual.usuario_id) do
      cred_ant = decifrar(atual)
      novas = for k <- @cred, v = limpar(attrs[k]), v != "", v != cred_ant[k], into: %{}, do: {k, v}
      cred_nova = Map.merge(cred_ant, novas)

      with {:ok, env} <- trocar_credencial(atual, cred_nova, novas) do
        gravar_edicao(atual, campos, env)
        mudou = Enum.sort(Map.keys(campos) ++ Map.keys(novas))
        if mudou != [], do: Auditoria.registrar(ator, "corretor.editar", atual.tenant_id, %{"campos" => mudou})
        achar(atual.id)
      end
    end
  end

  # so os campos presentes e diferentes; nome/e-mail/usuario/numero mantem as regras do cadastro
  defp campos_editados(atual, attrs) do
    campos =
      for k <- @texto, Map.has_key?(attrs, k), v = normalizar(k, limpar(attrs[k])), v != Map.get(atual, String.to_atom(k)), into: %{}, do: {k, v}

    cond do
      campos["nome"] == "" -> {:error, {:invalido, :nome}}
      campos["email"] && not email_ok?(campos["email"]) -> {:error, {:invalido, :email}}
      campos["usuario"] && not usuario_ok?(campos["usuario"]) -> {:error, {:invalido, :usuario}}
      campos["numero"] && not numero_ok?(campos["numero"]) -> {:error, {:invalido, :numero}}
      true -> {:ok, campos}
    end
  end

  defp normalizar("email", v), do: String.downcase(v)
  defp normalizar("numero", v), do: digitos(v)
  defp normalizar(_, v), do: v

  defp trocar_credencial(_atual, _cred, novas) when map_size(novas) == 0, do: {:ok, nil}

  defp trocar_credencial(atual, cred, _novas) do
    fonte = para_fonte(cred)

    with :ok <- Fonte.validar_credencial(fonte),
         {:ok, _} <- Fonte.cadastrar_conta(atual.tenant_id, fonte),
         {:ok, env} <- Fonte.cifrar(atual.tenant_id, Jason.encode!(Map.take(cred, @cred))) do
      {:ok, env}
    end
  end

  defp gravar_edicao(atual, campos, env) do
    ordem = Map.keys(campos) ++ if(env, do: ["credenciais_cifradas"], else: [])
    valores = Enum.map(Map.keys(campos), &campos[&1]) ++ if(env, do: [env], else: [])

    if ordem != [] do
      sets = ordem |> Enum.with_index(2) |> Enum.map_join(", ", fn {k, i} -> "#{k}=$#{i}" end)
      q("UPDATE ge_corretores SET #{sets}, atualizado_em=now() WHERE id=$1", [atual.id | valores])
    end

    # o login e o nome de tela seguem o cadastro
    if atual.usuario_id && (campos["email"] || campos["nome"]) do
      q("UPDATE pb_usuarios SET email = COALESCE($2, email), nome = COALESCE($3, nome) WHERE id=$1", [atual.usuario_id, campos["email"], campos["nome"]])
    end

    :ok
  rescue
    e in Postgrex.Error -> {:error, duplicado(e)}
  end

  # ---------------------------------------------------------------- desativar / excluir

  @doc "Desativa (reversivel): bloqueia o login, derruba as sessoes e o laco, e marca os vinculos como desativados (o agente nao volta a falar)."
  def desativar(ator, id) do
    with {:ok, c} <- corretor(ator, id) do
      q("UPDATE ge_corretores SET status='desativado', atualizado_em=now() WHERE id=$1", [id])
      if c.usuario_id, do: Usuarios.ativar(c.usuario_id, false)
      for v <- Registro.contratos(c.tenant_id), do: Registro.marcar_estado(c.tenant_id, v.automacao, "desativado")
      Conexao.encerrar(c.tenant_id)
      Auditoria.registrar(ator, "corretor.desativar", c.tenant_id)
    end
  end

  def reativar(ator, id) do
    with {:ok, c} <- corretor(ator, id) do
      q("UPDATE ge_corretores SET status='ativo', atualizado_em=now() WHERE id=$1", [id])
      if c.usuario_id, do: Usuarios.ativar(c.usuario_id, true)
      for v <- Registro.contratos(c.tenant_id), v.estado == "desativado", do: Registro.marcar_estado(c.tenant_id, v.automacao, "ativo")
      Nucleo.Inicializacao.validar(c.tenant_id)
      Auditoria.registrar(ator, "corretor.reativar", c.tenant_id)
    end
  end

  @doc """
  Exclui de verdade: apaga os dados pessoais (cadastro, usuario do painel, credenciais) e desvincula a sessao do WhatsApp.
  Exige a confirmacao digitada (o usuario do corretor). A campanha na Meta NAO e apagada. Irreversivel.
  """
  def excluir(ator, id, confirmacao) do
    with {:ok, c} <- corretor(ator, id) do
      if limpar(confirmacao) == c.usuario and c.usuario != "" do
        Conexao.desvincular(c.tenant_id)
        Fonte.remover_conta(c.tenant_id)
        if c.usuario_id, do: Usuarios.remover(c.usuario_id)
        for v <- Registro.contratos(c.tenant_id), do: Registro.marcar_estado(c.tenant_id, v.automacao, "desativado")

        q(
          "UPDATE ge_corretores SET status='excluido', usuario_id=NULL, nome=NULL, sobrenome=NULL, usuario=NULL, email=NULL, numero=NULL, filiacao=NULL, site=NULL, credenciais_cifradas=NULL, atualizado_em=now() WHERE id=$1",
          [id]
        )

        Auditoria.registrar(ator, "corretor.excluir", c.tenant_id)
      else
        {:error, :confirmacao}
      end
    end
  end

  # ---------------------------------------------------------------- painel, status, alertas

  @doc "Painel geral: gasto total, campanhas ativas e custo de IA por corretor (so corretores ativos entram nas somas)."
  def painel(ator) do
    with :ok <- permitir(ator) do
      linhas = ator |> listar(%{}) |> resumos() |> Enum.map(&linha/1)
      ativos = Enum.filter(linhas, &(&1.status == "ativo"))

      %{
        gasto_total: ativos |> Enum.map(& &1.gasto) |> Enum.sum(),
        campanhas_ativas: ativos |> Enum.map(& &1.campanhas_ativas) |> Enum.sum(),
        custo_ia_brl: ativos |> Enum.map(& &1.custo_ia_brl) |> Enum.sum(),
        corretores: linhas
      }
    end
  end

  # leitura concorrente (cada corretor tem a propria conta de anuncio); o que atrasar ou cair vira "sem dados"
  defp resumos(corretores) do
    corretores
    |> Task.async_stream(fn c -> {c, if(c.status == "ativo", do: Fonte.resumo(c.tenant_id), else: %{})} end, max_concurrency: 8, timeout: 20_000, on_timeout: :kill_task)
    |> Enum.zip(corretores)
    |> Enum.map(fn
      {{:ok, par}, _} -> par
      {_, c} -> {c, %{}}
    end)
  end

  defp linha({c, r}) do
    ativo? = c.status == "ativo"

    Map.merge(c, %{
      gasto: r["gasto"] || 0,
      campanhas_ativas: r["campanhas_ativas"] || 0,
      reprovadas: r["reprovadas"] || 0,
      token: r["token"],
      sincronizacao: r["sincronizado_em"],
      custo_ia_brl: if(ativo?, do: Fonte.custo_ia(c.tenant_id), else: 0.0),
      whatsapp: Conexao.estado(c.tenant_id)
    })
  end

  @doc "Status do corretor: WhatsApp, token e ultima sincronizacao."
  def status(ator, id) do
    with {:ok, c} <- corretor(ator, id) do
      r = Fonte.resumo(c.tenant_id)
      %{whatsapp: Conexao.estado(c.tenant_id), token: r["token"], sincronizacao: r["sincronizado_em"], reprovadas: r["reprovadas"] || 0, numero: Canal.Estado.numero(c.tenant_id)}
    end
  end

  def sincronizar(ator, id) do
    with {:ok, c} <- corretor(ator, id) do
      {:ok, foto} = Fonte.sincronizar(c.tenant_id)
      Auditoria.registrar(ator, "corretor.sincronizar", c.tenant_id)
      {:ok, foto}
    end
  end

  def campanhas(ator, id) do
    with {:ok, c} <- corretor(ator, id), do: Fonte.campanhas(c.tenant_id)
  end

  @doc "Aba IA do corretor: so contagens por papel (fez, erros, aprendeu) e custo. Nunca a conversa."
  def ia(ator, id) do
    with {:ok, c} <- corretor(ator, id), do: %{custo_ia_brl: Fonte.custo_ia(c.tenant_id), papeis: papeis(Fonte.atividade(c.tenant_id))}
  end

  defp papeis(atividade) do
    for {papel, a} <- Enum.sort(atividade), is_map(a), do: %{papel: papel, fez: length(a.fez), erros: length(a.erros), aprendeu: length(a.aprendeu)}
  end

  @doc "Custo de IA por corretor ativo, para a aba IA geral."
  def ia_geral(ator) do
    with :ok <- permitir(ator) do
      for c <- listar(ator, %{}), c.status == "ativo", do: Map.merge(c, %{custo_ia_brl: Fonte.custo_ia(c.tenant_id), papeis: papeis(Fonte.atividade(c.tenant_id))})
    end
  end

  @doc "Alertas dos corretores ativos: sessao caida, token invalido, campanha reprovada, numero diferente do cadastrado."
  def alertas(ator) do
    with :ok <- permitir(ator) do
      ator |> listar(%{}) |> Enum.filter(&(&1.status == "ativo")) |> resumos() |> Enum.flat_map(&alertas_de/1)
    end
  end

  defp alertas_de({c, r}) do
    base = %{corretor_id: c.id, nome: c.nome, sobrenome: c.sobrenome}

    tipos =
      [
        Conexao.estado(c.tenant_id) == :desconectado && :sessao_caida,
        r["token"] == "token invalido" && :token_invalido,
        (r["reprovadas"] || 0) > 0 && :campanha_reprovada,
        numero_diferente?(c) && :numero_diferente
      ]

    for t <- tipos, t, do: Map.put(base, :tipo, t)
  end

  # o numero realmente pareado (publicado pelo canal) precisa terminar igual ao cadastrado
  defp numero_diferente?(c) do
    case Canal.Estado.numero(c.tenant_id) do
      nil -> false
      pareado -> String.slice(pareado, -8, 8) != String.slice(c.numero || "", -8, 8)
    end
  end

  def auditoria(ator, limite \\ 100) do
    with :ok <- permitir(ator), do: Auditoria.listar(Papeis.equipe(ator), limite)
  end
end
