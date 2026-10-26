defmodule PainelBase.Conta do
  @moduledoc """
  Acoes da tela Conta, sempre sobre o TENANT da sessao (nunca um id vindo da pagina): WhatsApp por QR (conectar, desconectar, reconectar, parear de novo)
  e cadastro manual da conta de anuncios. A credencial e validada de formato aqui, validada na plataforma e guardada CIFRADA pela fonte
  (Fonte -> Trafego, AES-256-GCM, chave so em env); nunca volta para a tela (so mascarada). A auditoria guarda quem, quando e so NOMES de campos.
  """
  require Logger
  alias Nucleo.Conexao
  alias PainelBase.{Banco, Fonte}

  @campos ~w(token conta_id pagina_id instagram_id)
  # codigos fixos que a tela sabe explicar (qualquer outro vira "erro")
  @erros ~w(invalido_token invalido_conta_id invalido_pagina_id invalido_instagram_id token_invalido credencial_invalida inacessivel_pagina inacessivel_conta inacessivel_instagram sem_chave_de_cifra trafego_indisponivel)

  # ---------------------------------------------------------------- WhatsApp

  @doc "Sobe a sessao do WhatsApp do tenant (QR no estado). Uma sessao por tenant: chamar de novo nao duplica. :ok | {:error, motivo}"
  def conectar(usuario, opts \\ []) do
    case Conexao.conectar(usuario.tenant_id, opts) do
      {:ok, _pid} -> auditar(usuario, "whatsapp.conectar")
      {:ok, :ja_conectado, _pid} -> :ok
      {:error, e} -> {:error, e}
    end
  end

  @doc "Derruba a sessao do tenant mantendo as credenciais do aparelho pareado (reconectar volta sem QR)."
  def desconectar(usuario) do
    Conexao.encerrar(usuario.tenant_id)
    auditar(usuario, "whatsapp.desconectar")
  end

  @doc "Reinicia a sessao (aparelho saiu): derruba e sobe de novo, pedindo QR se as credenciais nao servirem mais."
  def reconectar(usuario, opts \\ []) do
    Conexao.encerrar(usuario.tenant_id)

    case Conexao.conectar(usuario.tenant_id, opts) do
      {:ok, _} -> auditar(usuario, "whatsapp.reconectar")
      {:ok, :ja_conectado, _} -> :ok
      {:error, e} -> {:error, e}
    end
  end

  @doc """
  Parear de novo (aparelho removido no celular): derruba a sessao, MOVE as credenciais para um backup datado (nunca apaga) e sobe o canal
  pedindo QR. So o tenant da sessao. Quem chama confirma com a pessoa antes (tela).
  """
  def reparear(usuario, opts \\ []) do
    case Conexao.reparear(usuario.tenant_id, opts) do
      {:error, e} -> {:error, e}
      _ -> auditar(usuario, "whatsapp.reparear")
    end
  end

  # ---------------------------------------------------------------- conta de anuncios

  @doc "Cadastra ou substitui a conta de anuncios do tenant. {:error, codigo} com codigo fixo (nunca o valor digitado)."
  def salvar_anuncios(usuario, params) do
    c = Map.new(@campos, &{&1, limpar(params[&1])})

    with :ok <- validar(c),
         {:ok, _} <- cadastrar(usuario.tenant_id, c) do
      auditar(usuario, "anuncios.salvar", %{"campos" => Enum.filter(@campos, &(c[&1] != ""))})
    else
      {:error, codigo} when is_binary(codigo) -> {:error, codigo}
      {:error, e} -> {:error, codigo(e)}
    end
  end

  @doc "Remove a conta de anuncios do tenant (nada na plataforma e tocado)."
  def remover_anuncios(usuario) do
    Fonte.remover_conta(usuario.tenant_id)
    auditar(usuario, "anuncios.remover")
  end

  defp cadastrar(tenant, c) do
    cred = c |> Map.reject(fn {_, v} -> v == "" end)
    Fonte.cadastrar_conta(tenant, cred)
  end

  defp validar(c) do
    cond do
      not String.match?(c["token"], ~r/^[A-Za-z0-9_\-.|=]{8,512}$/) -> {:error, "invalido_token"}
      not String.match?(c["conta_id"], ~r/^(act_)?\d{5,20}$/) -> {:error, "invalido_conta_id"}
      not String.match?(c["pagina_id"], ~r/^\d{5,20}$/) -> {:error, "invalido_pagina_id"}
      c["instagram_id"] != "" and not String.match?(c["instagram_id"], ~r/^\d{5,20}$/) -> {:error, "invalido_instagram_id"}
      true -> :ok
    end
  end

  defp codigo({:inacessivel, campo}), do: codigo("inacessivel_#{campo}")
  defp codigo(e) when is_atom(e), do: codigo(Atom.to_string(e))
  defp codigo(e) when is_binary(e) and e in @erros, do: e

  defp codigo(e) do
    # so o formato do erro vai para o log (a plataforma pode devolver texto proprio, nunca o token)
    Logger.warning("painel conta: erro sem mensagem propria (#{if is_tuple(e), do: elem(e, 0), else: :outro})")
    "erro"
  end

  defp limpar(nil), do: ""
  defp limpar(v) when is_binary(v), do: String.trim(v)
  defp limpar(_), do: ""

  # ---------------------------------------------------------------- auditoria

  defp auditar(usuario, acao, detalhes \\ %{}) do
    Banco.q("INSERT INTO pb_auditoria (usuario_id, tenant_id, acao, detalhes) VALUES ($1,$2,$3,$4)", [usuario.id, usuario.tenant_id, acao, detalhes])
    :ok
  end

  @doc "Ultimas acoes do PROPRIO usuario na tela Conta (mais recentes primeiro)."
  def auditoria(%{id: id}, limite) do
    Banco.q("SELECT usuario_id, acao, detalhes, em FROM pb_auditoria WHERE usuario_id=$1 ORDER BY id DESC LIMIT $2", [id, limite]).rows
    |> Enum.map(fn [u, acao, det, em] -> %{usuario_id: u, acao: acao, detalhes: det, em: em} end)
  end
end
