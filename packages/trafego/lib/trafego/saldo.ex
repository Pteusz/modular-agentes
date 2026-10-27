defmodule Trafego.Saldo do
  @moduledoc """
  Saldo da conta de anuncios Meta (etapa 6.3, trafego 1.16.0). So LEITURA: a Iara nunca recarrega nem mexe no teto.
  O saldo e medido em DIAS DE VERBA = saldo / soma da verba diaria dos planos ativos (decisao do Mateus), alem do valor em reais.
  Conta pre-paga: o saldo vem do texto de exibicao do funding_source_details (o campo `balance` da Meta e valor DEVIDO e vem 0 em pre-paga).
  Conta pos-paga (cartao): nao ha saldo a acabar; a Iara so diz isso.
  Aviso (Monitor): faixa :baixo (< 3 dias de verba) e :critico (< 1 dia). Avisa UMA vez ao entrar numa faixa e de novo so se piorar de
  baixo para critico; voltar a 3 dias ou mais rearma. O estado fica na chave `saldo_aviso` do tenant.
  """
  alias Nucleo.Registro
  alias Trafego.{Acesso, Evento, Notificar, Plano}

  @limiar_baixo 3.0
  @limiar_critico 1.0
  # Formato do link de recarga. :asset_id = Billing Hub com o id da conta (NAO confirmado pela Meta: o Mateus valida clicando).
  # Se nao abrir na conta certa, troque so esta linha por :billing_hub (link geral + instrucao de onde clicar).
  @formato :asset_id
  @billing_hub "https://business.facebook.com/billing_hub/"

  # ---- puros
  @doc "Centavos a partir do texto de exibicao da Meta (\"Saldo disponivel (R$6,99 BRL)\"); nil se nao reconhece."
  def parse_centavos(texto) when is_binary(texto) do
    case Regex.run(~r/R\$[\s\x{00A0}]*(\d{1,3}(?:\.\d{3})*|\d+),(\d{2})/u, texto) do
      [_, inteiro, cent] -> String.to_integer(String.replace(inteiro, ".", "")) * 100 + String.to_integer(cent)
      _ -> nil
    end
  end

  def parse_centavos(_), do: nil

  @doc "Dias de verba (uma casa, para baixo); nil sem saldo ou sem verba."
  def dias(saldo, verba) when is_integer(saldo) and is_integer(verba) and verba > 0, do: div(saldo * 10, verba) / 10
  def dias(_, _), do: nil

  def faixa(nil), do: :ok
  def faixa(d) when d < @limiar_critico, do: :critico
  def faixa(d) when d < @limiar_baixo, do: :baixo
  def faixa(_), do: :ok

  def link_recarga(conta, formato \\ @formato)
  def link_recarga(conta, :asset_id), do: @billing_hub <> "payment_settings?asset_id=" <> id_numerico(conta)
  def link_recarga(_conta, :billing_hub), do: @billing_hub

  @doc "Link pronto para a mensagem (o fallback leva a instrucao de onde clicar)."
  def recarga_texto(conta, formato \\ @formato)
  def recarga_texto(conta, :asset_id), do: link_recarga(conta, :asset_id)

  def recarga_texto(conta, :billing_hub),
    do: "#{@billing_hub} (escolha a conta #{id_numerico(conta)} e toque em Adicionar fundos)"

  defp id_numerico(conta), do: conta |> to_string() |> String.replace_prefix("act_", "")

  # ---- leitura
  @doc """
  Le o saldo do tenant. {:ok, %{tipo, saldo, verba, dias, faixa, conta}} | {:error, motivo}.
  `saldo` e nil quando a Meta nao deixa ler o numero; `dias` e nil sem saldo ou sem campanha ativa.
  """
  def ler(tenant) do
    with %{"conta_id" => conta} <- Acesso.conta(tenant),
         {:ok, %{"tipo" => tipo} = s} <- Acesso.chamar(tenant, :ler_saldo, []) do
      verba = verba_diaria(tenant)
      saldo = s["saldo"]
      d = dias(saldo, verba)
      {:ok, %{tipo: tipo, saldo: saldo, verba: verba, dias: d, faixa: faixa(d), conta: conta}}
    else
      nil -> {:error, :sem_conta}
      {:ok, _} -> {:error, :resposta_inesperada}
      {:error, _} = e -> e
    end
  end

  @doc "Soma da verba diaria (centavos) dos planos ativos do sistema."
  def verba_diaria(tenant) do
    for(p <- Plano.listar(tenant), p != nil, p["status"] == "ativa", is_integer(p["orcamento_diario"]), reduce: 0, do: (soma -> soma + p["orcamento_diario"]))
  end

  # ---- textos (sem travessao, sem lista)
  def fmt_dias(d) when d >= 10, do: Integer.to_string(trunc(d))
  def fmt_dias(d), do: d |> :erlang.float_to_binary(decimals: 1) |> String.replace(".", ",")

  def aviso_texto(%{faixa: :critico} = i),
    do: "Atenção: o saldo na Meta (#{Plano.brl(i.saldo)}) cobre menos de um dia de verba e as campanhas podem parar a qualquer momento. Recarregue aqui: #{recarga_texto(i.conta)}"

  def aviso_texto(%{faixa: :baixo} = i),
    do: "Seu saldo na Meta está em #{Plano.brl(i.saldo)}, o que dá uns #{fmt_dias(i.dias)} dias da sua verba atual. Para as campanhas não pararem, vale recarregar: #{recarga_texto(i.conta)}"

  @doc "Frase de resposta a \"quanto tenho de saldo\" (a ferramenta saldo_meta devolve isto como `resumo`)."
  def resumo(%{tipo: "pos_pago"}),
    do: "Sua conta de anúncios é no cartão, então ela não tem saldo pré-pago para acabar: a Meta cobra no cartão conforme o gasto."

  def resumo(%{saldo: nil}),
    do: "Não consegui ler o saldo na Meta agora. Dá pra ver em Pagamentos e faturamento, no Gerenciador de Anúncios."

  def resumo(%{dias: nil} = i),
    do: "Você tem #{Plano.brl(i.saldo)} de saldo na Meta. Como não há nenhuma campanha ativa agora, não dá pra contar os dias de verba."

  def resumo(%{faixa: :ok} = i),
    do: "Você tem #{Plano.brl(i.saldo)} de saldo na Meta, que dá uns #{fmt_dias(i.dias)} dias da sua verba de #{Plano.brl(i.verba)} por dia."

  def resumo(i) do
    dias = if i.dias < 1, do: "menos de um dia", else: "uns #{fmt_dias(i.dias)} dias"
    "Você tem #{Plano.brl(i.saldo)} de saldo na Meta, que dá #{dias} da sua verba de #{Plano.brl(i.verba)} por dia. Pra recarregar: #{recarga_texto(i.conta)}"
  end

  # ---- aviso (chamado pelo Monitor, uma vez por tenant a cada rodada)
  @doc "Avisa o corretor se o saldo entrou numa faixa pior. :avisou | :quieto. Nunca levanta erro."
  def avisar(tenant) do
    if verba_diaria(tenant) > 0 do
      case ler(tenant) do
        {:ok, %{tipo: "pre_pago", saldo: s, faixa: f} = i} when is_integer(s) -> decidir(tenant, f, i)
        _ -> :quieto
      end
    else
      :quieto
    end
  rescue
    _ -> :quieto
  end

  defp decidir(tenant, :ok, _i) do
    if estado(tenant) != nil, do: Registro.gravar(tenant, "saldo_aviso", %{"faixa" => nil})
    :quieto
  end

  defp decidir(tenant, faixa, i) do
    antes = estado(tenant)

    if antes == "critico" or antes == to_string(faixa) do
      :quieto
    else
      Notificar.enviar(tenant, aviso_texto(i))
      Registro.gravar(tenant, "saldo_aviso", %{"faixa" => to_string(faixa)})
      Evento.emitir(tenant, "operacao", nil, "monitor", "aviso_saldo", %{"faixa" => to_string(faixa), "dias" => i.dias})
      :avisou
    end
  end

  defp estado(tenant), do: (Registro.ler(tenant, "saldo_aviso") || %{})["faixa"]
end
