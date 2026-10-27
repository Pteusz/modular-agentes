defmodule Trafego.Acesso do
  @moduledoc """
  Unica porta para a plataforma de anuncios. A conta vem SEMPRE do registro do tenant ("trafego_conta"); quem chama
  (inclusive o provedor de IA) nao informa conta. `conta:` explicita e aceita so para barrar: conta diferente da do tenant e recusada.
  O token e guardado CIFRADO (Trafego.Cifra, AES-256-GCM, chave so em env); so e aberto na hora da chamada, em memoria.
  Status da credencial: "ok" | "token invalido" (a plataforma recusou o token; nenhuma chamada sai ate recadastrar).
  """
  alias Nucleo.Registro
  require Logger
  alias Trafego.{Cache, Cifra, Evento, Plataforma}

  @ops ~w(criar_campanha ler_campanha editar_campanha pausar_campanha ativar_campanha listar_campanhas listar_campanhas_com_metricas metricas numeros_vinculados ler_saldo)a
  # escrevem na plataforma: o cache do painel do tenant e esquecido depois (qualquer que seja o resultado: uma falha parcial tambem muda a conta)
  @escritas ~w(criar_campanha editar_campanha pausar_campanha ativar_campanha)a
  @campos ~w(conta_id pagina_id instagram_id pixel_id)

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

      c |> Map.take(@campos) |> Map.merge(%{"token" => token, "status" => c["status"] || "ok"}) |> Map.merge(Map.take(c, ["avisos"]))
    end
  end

  @doc """
  Cadastra a credencial do tenant depois de validar na plataforma (Meta: pagina, conta de anuncio e Instagram alcancaveis).
  Entrada: "conta_id", "token" e, conforme a plataforma, "pagina_id" e "instagram_id". O erro da plataforma passa direto
  (:token_invalido, {:inacessivel, :pagina | :conta}, :credencial_invalida). Instagram nao bloqueia: nao alcancado/ausente vira aviso "instagram_nao_ligado" no registro.
  """
  def cadastrar(tenant, %{"conta_id" => _, "token" => token} = cred) do
    with {:ok, info} <- Plataforma.adaptador().validar_credencial(cred),
         {:ok, envelope} <- Cifra.cifrar(tenant, token) do
      # Instagram so fica no registro (e portanto so entra no criativo) quando a plataforma o alcancou
      cred = if info["instagram"] in ["nao_ligado", "ausente"], do: Map.delete(cred, "instagram_id"), else: cred

      registro =
        cred
        |> Map.take(@campos)
        |> Map.merge(%{"token_cifrado" => envelope, "chave_id" => Cifra.chave_id(envelope), "status" => "ok", "moeda" => info["moeda"], "avisos" => info["avisos"]})
        |> Map.reject(fn {_, v} -> is_nil(v) end)

      Registro.gravar(tenant, "trafego_conta", registro)
      Cache.invalidar(tenant)
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
              medir(tenant, op, fn -> apply(Plataforma.adaptador(), op, [cred | args]) end) |> marcar(tenant, c, op)
            end
        end
    end
  end

  # medicao: uma linha por chamada a plataforma (so metadados: tenant, operacao, ms, resultado; nunca token nem conta)
  defp medir(tenant, op, fun) do
    t0 = System.monotonic_time(:millisecond)
    r = fun.()
    if op in @escritas, do: Cache.invalidar(tenant)
    Logger.info("trafego.plataforma tenant=#{tenant} op=#{op} ms=#{System.monotonic_time(:millisecond) - t0} resultado=#{resultado(r)}")
    r
  end

  defp resultado({:ok, _}), do: "ok"
  defp resultado({:error, e}) when is_atom(e), do: e
  defp resultado({:error, {k, _}}) when is_atom(k), do: k
  defp resultado(_), do: "erro"

  defp token(tenant, %{"token_cifrado" => env}), do: Cifra.decifrar(tenant, env)
  # registros da 4.1 (credencial simulada em claro) continuam legiveis
  defp token(_, %{"token" => t}) when is_binary(t), do: {:ok, t}
  defp token(_, _), do: {:error, :credencial_ilegivel}

  defp marcar({:error, :token_invalido} = r, tenant, c, op) do
    Registro.gravar(tenant, "trafego_conta", Map.put(c, "status", "token invalido"))
    Cache.invalidar(tenant)
    Evento.emitir(tenant, "operacao", nil, "executor", to_string(op), %{"erro" => "token_invalido"})
    r
  end

  defp marcar(r, _, _, _), do: r
end
