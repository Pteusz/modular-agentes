defmodule Trafego.Acesso do
  @moduledoc """
  Unica porta para a plataforma de anuncios. A conta vem SEMPRE do registro do tenant ("trafego_conta"); quem chama
  (inclusive o provedor de IA) nao informa conta. `conta:` explicita e aceita so para barrar: conta diferente da do tenant e recusada.
  """
  alias Nucleo.Registro
  alias Trafego.{Evento, Plataforma}

  @ops ~w(criar_campanha ler_campanha editar_campanha pausar_campanha listar_campanhas)a

  def conta(tenant), do: Registro.ler(tenant, "trafego_conta")

  @doc "Cadastra a credencial do tenant depois de validar na plataforma. (Cifra no banco entra na 4.2; aqui so credenciais simuladas.)"
  def cadastrar(tenant, %{"conta_id" => _, "token" => _} = cred) do
    case Plataforma.adaptador().validar_credencial(cred) do
      {:ok, _} ->
        Registro.gravar(tenant, "trafego_conta", Map.take(cred, ["conta_id", "token"]))
        {:ok, cred["conta_id"]}

      {:error, _} ->
        {:error, :credencial_invalida}
    end
  end

  def chamar(tenant, op, args, opts \\ []) when op in @ops do
    case conta(tenant) do
      nil ->
        {:error, :sem_conta}

      %{"conta_id" => id} = cred ->
        if opts[:conta] in [nil, id] do
          apply(Plataforma.adaptador(), op, [cred | args])
        else
          Evento.emitir(tenant, "operacao", nil, "executor", to_string(op), %{"erro" => "conta_barrada"})
          {:error, :conta_barrada}
        end
    end
  end
end
