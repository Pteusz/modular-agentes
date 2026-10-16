defmodule Nucleo.Automacoes.Eco do
  @moduledoc "Automacao de teste, sem dominio: ecoa a entrada com contador e a entrada anterior (estado lido de volta). Molde da versao generica."
  @behaviour Nucleo.Automacao
  @behaviour Nucleo.Passo

  @impl Nucleo.Automacao
  def versao, do: Application.spec(:eco, :vsn) |> to_string()
  @impl Nucleo.Automacao
  def contrato,
    do: %{versao: "1.0", oferece: %{"eco" => "1.0"}, exige: %{"registro" => "1.0", "gancho" => "1.0", "canal.texto" => "1.0"}}

  @impl Nucleo.Automacao
  def referencial,
    do: %{
      tipo: :decidivel,
      regras: [
        %{nome: :nao_vazia, ok?: fn %{saida: s} -> is_binary(s) and s != "" end},
        %{nome: :tamanho_max, ok?: fn %{saida: s} -> String.length(s || "") <= 80 end}
      ]
    }

  @impl Nucleo.Automacao
  def retencao, do: [%{chave: "contagem", leitura: :ultimo}, %{chave: "ultima", leitura: :ultimo}]
  @impl Nucleo.Automacao
  def aprovacao, do: [:gastar]

  @impl Nucleo.Passo
  def passo(entrada, retido) do
    n = ((retido["contagem"] || %{})["n"] || 0) + 1
    antes = (retido["ultima"] || %{})["texto"]
    saida = "eco ##{n}: #{entrada}" <> if(antes, do: " (antes: #{antes})", else: "")

    %{
      saida: saida,
      retido: %{"contagem" => %{"n" => n}, "ultima" => %{"texto" => entrada}},
      acoes: if(String.starts_with?(entrada, "!gastar"), do: [{:gastar, %{"texto" => entrada}}], else: [])
    }
  end
end
