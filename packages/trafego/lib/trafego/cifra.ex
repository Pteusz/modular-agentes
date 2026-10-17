defmodule Trafego.Cifra do
  @moduledoc """
  Cifra das credenciais de anuncio: AES-256-GCM (:crypto), chave SO em env, com id de chave (rotacao) e o tenant como AAD
  (credencial cifrada de um tenant nao abre em outro). Formato guardado: "<id>.<base64url(iv ++ tag ++ cifrado)>".
    * TRAFEGO_CIFRA_CHAVES = "id:base64_de_32_bytes,id2:base64..." (todas as chaves ainda validas, para ler o que foi cifrado antes)
    * TRAFEGO_CIFRA_ATUAL  = id da chave usada para cifrar daqui em diante
  A chave e o texto claro nunca vao para log, evento nem estado. Tela: so `mascarar/1`.
  """

  @doc "{:ok, envelope} | {:error, :sem_chave_de_cifra | :chave_invalida}"
  def cifrar(tenant, texto) when is_binary(tenant) and is_binary(texto) do
    with {:ok, id, chave} <- atual() do
      iv = :crypto.strong_rand_bytes(12)
      {cifrado, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, chave, iv, texto, tenant, 16, true)
      {:ok, id <> "." <> Base.url_encode64(iv <> tag <> cifrado, padding: false)}
    end
  end

  @doc "{:ok, texto} | {:error, motivo}. Nunca levanta excecao."
  def decifrar(tenant, envelope) when is_binary(tenant) and is_binary(envelope) do
    with [id, b64] <- String.split(envelope, ".", parts: 2),
         {:ok, chave} <- chave(id),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), cifrado::binary>>} <- Base.url_decode64(b64, padding: false),
         texto when is_binary(texto) <- :crypto.crypto_one_time_aead(:aes_256_gcm, chave, iv, cifrado, tenant, tag, false) do
      {:ok, texto}
    else
      {:error, :sem_chave_de_cifra} = e -> e
      {:error, :chave_invalida} = e -> e
      _ -> {:error, :cifra_invalida}
    end
  rescue
    _ -> {:error, :cifra_invalida}
  end

  def decifrar(_, _), do: {:error, :cifra_invalida}

  @doc "Id da chave com que o envelope foi cifrado."
  def chave_id(envelope) when is_binary(envelope), do: envelope |> String.split(".", parts: 2) |> hd()

  @doc "Para tela: so os 4 ultimos caracteres."
  def mascarar(texto) when is_binary(texto) do
    if String.length(texto) > 8, do: "****" <> String.slice(texto, -4, 4), else: "****"
  end

  def mascarar(_), do: "****"

  defp atual do
    with id when is_binary(id) and id != "" <- System.get_env("TRAFEGO_CIFRA_ATUAL"),
         {:ok, chave} <- chave(id) do
      {:ok, id, chave}
    else
      {:error, :chave_invalida} -> {:error, :chave_invalida}
      _ -> {:error, :sem_chave_de_cifra}
    end
  end

  defp chave(id) do
    case Map.fetch(chaves(), id) do
      {:ok, c} -> {:ok, c}
      :error -> if System.get_env("TRAFEGO_CIFRA_CHAVES") in [nil, ""], do: {:error, :sem_chave_de_cifra}, else: {:error, :chave_invalida}
    end
  end

  # chaves malformadas (nao base64 ou diferente de 32 bytes) sao ignoradas: nunca cifra com chave fraca
  defp chaves do
    for par <- String.split(System.get_env("TRAFEGO_CIFRA_CHAVES") || "", ",", trim: true),
        [id, b64] <- [String.split(String.trim(par), ":", parts: 2)],
        {:ok, <<_::binary-size(32)>> = k} <- [Base.decode64(b64)],
        into: %{},
        do: {id, k}
  end
end
