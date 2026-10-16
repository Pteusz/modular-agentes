defmodule Trafego.Acesso do
  @moduledoc """
  Unica porta para a plataforma de anuncios. A conta vem SEMPRE do registro do tenant ("trafego_conta"); quem chama
  (inclusive o provedor de IA) nao informa conta. `conta:` explicita e aceita so para barrar: conta diferente da do tenant e recusada.
  O token e guardado CIFRADO (Trafego.Cifra, AES-256-GCM, chave so em env); so e aberto na hora da chamada, em memoria.
  Status da credencial: "ok" | "token invalido" (a plataforma recusou o token; nenhuma chamada sai ate recadastrar).
  """
  alias Nucleo.Registro
  alias Trafego.{Cifra, Evento, Plataforma}

  @ops ~w(criar_campanha ler_campanha editar_campanha pausar_campanha listar_campanhas)a
  @campos ~w(conta_id pagina_id instagram_id)

  def conta(tenant), do: Registro.ler(tenant, "trafego_conta")

  def status(tenant), do: if(c = conta(tenant), do: c["status"] || "ok")

  @doc "Para tela: ids e token mascarado (4 ultimos caracteres), nunca o token."
  def mascarado(tenant) do
    with %{} = c <- conta(tenant) do
      token =
        case token(tenant, c) do
          {:ok, t} -> Cifra.mascarar(t)
          _ -> "****"
        end

      c |> Map.take(@campos) |> Map.merge(%{"token" => token, "status" => c["status"] || "ok"})
    end
  end

  @doc """
  Cadastra a credencial do tenant depois de validar na plataforma (Meta: pagina, conta de anuncio e Instagram alcancaveis).
  Entrada: "conta_id", "token" e, conforme a plataforma, "pagina_id" e "instagram_id". O erro da plataforma passa direto
  (:token_invalido, {:inacessivel, :pagina | :conta | :instagram}, :credencial_invalida).
  """
  def cadastrar(tenant, %{"conta_id" => _, "token" => token} = cred) do
    with {:ok, info} <- Plataforma.adaptador().validar_credencial(cred),
         {:ok, envelope} <- Cifra.cifrar(tenant, token) do
      registro =
        cred
        |> Map.take(@campos)
        |> Map.merge(%{"token_cifrado" => envelope, "chave_id" => Cifra.chave_id(envelope), "status" => "ok", "moeda" => info["moeda"]})
        |> Map.reject(fn {_, v} -> is_nil(v) end)

      Registro.gravar(tenant, "trafego_conta", registro)
      {:ok, cred["conta_id"]}
    end
  end

  def chamar(tenant, op, args, opts \\ []) when op in @ops do
    case conta(tenant) do
      nil ->
        {:error, :sem_conta}

      %{"conta_id" => id} = c ->
        cond do
          opts[:conta] not in [nil, id] ->
            Evento.emitir(tenant, "operacao", nil, "executor", to_string(op), %{"erro" => "conta_barrada"})
            {:error, :conta_barrada}

          c["status"] == "token invalido" ->
            {:error, :token_invalido}

          true ->
            with {:ok, tk} <- token(tenant, c) do
              cred = c |> Map.take(@campos ++ ["moeda"]) |> Map.put("token", tk)
              apply(Plataforma.adaptador(), op, [cred | args]) |> marcar(tenant, c, op)
            end
        end
    end
  end

  defp token(tenant, %{"token_cifrado" => env}), do: Cifra.decifrar(tenant, env)
  # registros da 4.1 (credencial simulada em claro) continuam legiveis
  defp token(_, %{"token" => t}) when is_binary(t), do: {:ok, t}
  defp token(_, _), do: {:error, :credencial_ilegivel}

  defp marcar({:error, :token_invalido} = r, tenant, c, op) do
    Registro.gravar(tenant, "trafego_conta", Map.put(c, "status", "token invalido"))
    Evento.emitir(tenant, "operacao", nil, "executor", to_string(op), %{"erro" => "token_invalido"})
    r
  end

  defp marcar(r, _, _, _), do: r
end
