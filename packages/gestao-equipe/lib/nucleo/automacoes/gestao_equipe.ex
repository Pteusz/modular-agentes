defmodule Nucleo.Automacoes.GestaoEquipe do
  @moduledoc """
  Gestao de equipe (dono, admins, corretores). Contrato Nucleo.Automacao, versao de contrato MAJOR.MINOR.
  Oferece "gestao.equipe" 1.0. Exige do painel-base a extensao ("painel.extensao"); le o trafego so pela oferta
  "trafego.equipe" (verificada em tempo de execucao: GestaoEquipe.Fonte). Nao decide nada pelo corretor e nao le conversa.
  """
  @behaviour Nucleo.Automacao

  @impl Nucleo.Automacao
  def versao, do: Application.spec(:gestao_equipe, :vsn) |> to_string()

  @impl Nucleo.Automacao
  def contrato,
    do: %{versao: "1.0", oferece: %{"gestao.equipe" => "1.0"}, exige: %{"registro" => "1.0", "gancho" => "1.0", "canal.texto" => "1.0", "painel.extensao" => "1.0"}}

  @impl Nucleo.Automacao
  def referencial, do: %{tipo: :decidivel, regras: []}

  @impl Nucleo.Automacao
  def retencao, do: []

  @impl Nucleo.Automacao
  def aprovacao, do: []
end
