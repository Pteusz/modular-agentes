defmodule Nucleo.Automacoes.PainelBase do
  @moduledoc """
  Painel web do corretor (login, convite, recuperacao, paginas). Contrato Nucleo.Automacao, versao de contrato MAJOR.MINOR.
  So le dados (via a oferta `trafego.painel` ou outra fonte configurada) e cuida do canal do WhatsApp por tenant (Nucleo.Conexao).
  Nao decide nada pelo corretor: o verificador e vazio e nenhuma acao aqui precisa de aprovacao.
  """
  @behaviour Nucleo.Automacao

  @impl Nucleo.Automacao
  def versao, do: Application.spec(:painel_base, :vsn) |> to_string()

  @impl Nucleo.Automacao
  def contrato, do: %{versao: "1.0", oferece: %{"painel" => "1.0"}, exige: %{"registro" => "1.0", "gancho" => "1.0", "canal.texto" => "1.0"}}

  @impl Nucleo.Automacao
  def referencial, do: %{tipo: :decidivel, regras: []}

  @impl Nucleo.Automacao
  def retencao, do: []

  @impl Nucleo.Automacao
  def aprovacao, do: []
end
