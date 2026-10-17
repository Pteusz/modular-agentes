defmodule GestaoEquipe.Fonte do
  @moduledoc """
  Unica porta da gestao para o trafego: a oferta "trafego.equipe" 1.0 (modulo `Trafego.Equipe`, trocavel por
  `config :gestao_equipe, :fonte`). Chamadas em tempo de execucao: sem o trafego instalado a gestao continua de pe, sem metricas.
  """
  @vazio %{"token" => "sem trafego", "sincronizado_em" => nil, "campanhas_ativas" => 0, "reprovadas" => 0, "gasto" => 0}

  def modulo, do: Application.get_env(:gestao_equipe, :fonte, Module.concat(["Trafego", "Equipe"]))

  @doc "A fonte esta carregada e (na fonte padrao) o trafego oferece trafego.equipe com MAJOR 1."
  def disponivel? do
    Code.ensure_loaded?(modulo()) and oferta_ok?()
  end

  defp oferta_ok? do
    contrato = Module.concat(["Nucleo", "Automacoes", "Trafego"])

    case Application.get_env(:gestao_equipe, :fonte) do
      nil -> Code.ensure_loaded?(contrato) and major(contrato.contrato().oferece["trafego.equipe"]) == 1
      _ -> true
    end
  end

  defp major(nil), do: nil
  defp major(v), do: v |> String.split(".") |> hd() |> String.to_integer()

  def validar_credencial(cred), do: if(disponivel?(), do: modulo().validar_credencial(cred), else: {:error, :trafego_indisponivel})
  def cadastrar_conta(t, cred), do: if(disponivel?(), do: modulo().cadastrar_conta(t, cred), else: {:error, :trafego_indisponivel})
  def remover_conta(t), do: if(disponivel?(), do: modulo().remover_conta(t), else: :ok)
  def cifrar(t, texto), do: if(disponivel?(), do: modulo().cifrar(t, texto), else: {:error, :trafego_indisponivel})
  def decifrar(t, env), do: if(disponivel?(), do: modulo().decifrar(t, env), else: {:error, :trafego_indisponivel})
  def resumo(t), do: if(disponivel?(), do: modulo().resumo(t), else: @vazio)
  def sincronizar(t), do: if(disponivel?(), do: modulo().sincronizar(t), else: {:ok, @vazio})
  def custo_ia(t), do: if(disponivel?(), do: modulo().custo_ia(t), else: 0.0)
  def campanhas(t), do: if(disponivel?(), do: modulo().campanhas(t), else: {:error, :trafego_indisponivel})
  def atividade(t), do: if(disponivel?(), do: modulo().atividade(t), else: %{})
end
