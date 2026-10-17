defmodule PainelBase.Senha do
  @moduledoc """
  Senha com PBKDF2-HMAC-SHA256 (:crypto). Formato guardado: `pbkdf2-sha256$iteracoes$sal_b64$hash_b64`; a verificacao usa as
  iteracoes gravadas (da para subir o custo sem invalidar senhas antigas) e compara em tempo constante.
  """
  @iteracoes 600_000
  @min 10
  @max 200

  def hash(senha) do
    sal = :crypto.strong_rand_bytes(16)
    n = Application.get_env(:painel_base, :iteracoes_pbkdf2, @iteracoes)
    "pbkdf2-sha256$#{n}$#{Base.encode64(sal)}$#{Base.encode64(derivar(senha, sal, n))}"
  end

  def conferir?(senha, "pbkdf2-sha256$" <> resto) when is_binary(senha) do
    with [n, sal, h] <- String.split(resto, "$"),
         {n, ""} <- Integer.parse(n),
         {:ok, sal} <- Base.decode64(sal),
         {:ok, esperado} <- Base.decode64(h) do
      :crypto.hash_equals(derivar(senha, sal, n), esperado)
    else
      _ -> false
    end
  end

  # sem senha gravada (convite pendente) ou formato desconhecido: gasta o mesmo tempo e recusa
  def conferir?(senha, _) do
    derivar(to_string(senha), "sal-falso-0123456", Application.get_env(:painel_base, :iteracoes_pbkdf2, @iteracoes))
    false
  end

  @doc "Regras da senha nova. :ok | {:error, mensagem}"
  def validar(senha, confirmacao) do
    cond do
      not is_binary(senha) or String.length(senha) < @min -> {:error, "A senha precisa ter pelo menos #{@min} caracteres."}
      String.length(senha) > @max -> {:error, "A senha pode ter no máximo #{@max} caracteres."}
      senha != confirmacao -> {:error, "As senhas não conferem."}
      true -> :ok
    end
  end

  defp derivar(senha, sal, n), do: :crypto.pbkdf2_hmac(:sha256, senha, sal, n, 32)
end
