defmodule PainelBase.Usuarios do
  @moduledoc """
  Usuarios do painel (um por corretor, preso a UM tenant). Convite por e-mail -> senha -> login. Sem 2FA nesta etapa.
  O tenant do usuario e gravado no convite pelo operador; nada vindo de formulario escolhe tenant.
  """
  require Logger
  import PainelBase.Banco, only: [q: 2]
  alias PainelBase.{Emails, Mailer, Senha, Sessoes, Tentativas, Tokens}

  @colunas "id, tenant_id, email, nome, senha_hash, verificado_em, ativo"

  def por_email(email) when is_binary(email), do: q("SELECT #{@colunas} FROM pb_usuarios WHERE email=$1", [normalizar(email)]).rows |> mapa()
  def por_email(_), do: nil
  @doc "Liga/desliga o acesso (reversivel). Desligar derruba as sessoes; quem esta inativo nao entra."
  def ativar(id, ativo?) when is_boolean(ativo?) do
    q("UPDATE pb_usuarios SET ativo=$2 WHERE id=$1", [id, ativo?])
    if not ativo?, do: Sessoes.revogar_todas(id)
    :ok
  end

  @doc "Apaga o usuario e o que e dele (tokens e sessoes vao junto). Irreversivel."
  def remover(id), do: q("DELETE FROM pb_usuarios WHERE id=$1", [id]) && :ok

  def por_id(id), do: q("SELECT #{@colunas} FROM pb_usuarios WHERE id=$1", [id]).rows |> mapa()

  defp mapa([[id, t, e, n, h, v, a]]), do: %{id: id, tenant_id: t, email: e, nome: n, senha_hash: h, verificado_em: v, ativo: a}
  defp mapa(_), do: nil

  defp normalizar(email), do: email |> String.trim() |> String.downcase()

  @doc "Convida: cria o usuario sem senha e manda o e-mail com o link. {:ok, usuario} | {:error, :ja_existe | :email_invalido | :email_falhou}"
  def convidar(email, nome, tenant) do
    email = normalizar(email)
    existente = por_email(email)

    cond do
      not String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) -> {:error, :email_invalido}
      existente && existente.senha_hash -> {:error, :ja_existe}
      true -> enviar(existente || criar_sem_senha(email, nome, tenant), :convite)
    end
  end

  defp criar_sem_senha(email, nome, tenant) do
    q("INSERT INTO pb_usuarios (tenant_id, email, nome) VALUES ($1,$2,$3)", [tenant, email, nome])
    por_email(email)
  end

  @doc "Cria usuario ja com senha (uso administrativo e testes). attrs: email, nome, tenant_id, senha, verificado."
  def criar(%{email: email, nome: nome, tenant_id: tenant, senha: senha} = attrs) do
    case Senha.validar(senha, senha) do
      :ok ->
        q("INSERT INTO pb_usuarios (tenant_id, email, nome, senha_hash, verificado_em) VALUES ($1,$2,$3,$4, CASE WHEN $5::boolean THEN now() END)", [
          tenant,
          normalizar(email),
          nome,
          Senha.hash(senha),
          attrs[:verificado] == true
        ])

        {:ok, por_email(email)}

      {:error, _} = e ->
        e
    end
  end

  def enviar_verificacao(usuario) do
    with {:ok, _} <- enviar(usuario, :verificacao), do: :ok
  end

  @doc "Pedido de recuperacao. Sempre :ok para quem chama (nao revela se o e-mail existe); so manda se a conta existe, esta ativa e tem senha."
  def recuperar(email) do
    email = normalizar(email)
    u = por_email(email)

    if u && u.ativo && u.senha_hash && not Tentativas.bloqueado?("r", email) do
      Tentativas.falha("r", email)
      enviar(u, :recuperacao)
    end

    :ok
  end

  defp enviar(u, tipo) do
    token = Tokens.criar(u.id, Atom.to_string(tipo))

    case Mailer.entregar(apply(Emails, tipo, [u, token])) do
      {:ok, _} ->
        {:ok, u}

      {:error, e} ->
        Logger.warning("painel: e-mail #{tipo} nao enviado (#{inspect(motivo(e))})")
        {:error, :email_falhou}
    end
  end

  # nunca despeja a resposta crua do SMTP (pode ecoar dados): so a classe do erro
  defp motivo(e) when is_atom(e), do: e
  defp motivo(e) when is_tuple(e) and is_atom(elem(e, 0)), do: elem(e, 0)
  defp motivo(_), do: :erro

  @doc "Define a senha pelo convite. Aceitar o convite prova o e-mail (verifica). {:ok, usuario} | {:error, mensagem} | :invalido"
  def aceitar_convite(token, senha, confirmacao), do: com_senha(token, "convite", senha, confirmacao)

  @doc "Redefine a senha pela recuperacao; derruba todas as sessoes."
  def redefinir(token, senha, confirmacao), do: com_senha(token, "recuperacao", senha, confirmacao)

  defp com_senha(token, tipo, senha, confirmacao) do
    with {:ok, _} <- Tokens.ver(token, tipo),
         :ok <- Senha.validar(senha, confirmacao),
         {:ok, id} <- Tokens.consumir(token, tipo) do
      q("UPDATE pb_usuarios SET senha_hash=$2, verificado_em = COALESCE(verificado_em, now()) WHERE id=$1", [id, Senha.hash(senha)])
      Sessoes.revogar_todas(id)
      {:ok, por_id(id)}
    end
  end

  def verificar_email(token) do
    with {:ok, id} <- Tokens.consumir(token, "verificacao") do
      q("UPDATE pb_usuarios SET verificado_em = COALESCE(verificado_em, now()) WHERE id=$1", [id])
      :ok
    end
  end

  @doc """
  Login. {:ok, usuario} | :bloqueado | :nao_verificado | :invalido. Falha igual para e-mail inexistente e senha errada.
  Conta bloqueada nao confere nem a senha certa. `ip` entra no limite por IP.
  """
  def autenticar(email, senha, ip) do
    email = normalizar(to_string(email))

    if Tentativas.bloqueado?("e", email) or Tentativas.bloqueado?("i", ip) do
      :bloqueado
    else
      u = por_email(email)
      certa? = Senha.conferir?(to_string(senha), u && u.senha_hash)

      cond do
        u && u.ativo && certa? && u.verificado_em == nil ->
          :nao_verificado

        u && u.ativo && certa? ->
          Tentativas.zerar("e", email)
          {:ok, u}

        true ->
          Tentativas.falha("e", email)
          Tentativas.falha("i", ip)
          :invalido
      end
    end
  end
end
